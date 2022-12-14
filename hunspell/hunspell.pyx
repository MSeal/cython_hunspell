import os
import hashlib
from .platform import detect_cpus
from cacheman.cachewrap import NonPersistentCache
from cacheman.cacher import get_cache_manager
from cacheman.autosync import TimeCount, AutoSyncCache
from locale import getpreferredencoding

from libc.stdlib cimport *
from libc.string cimport *
from cython.operator cimport dereference as deref

# Use full path for cimport ONLY!
from hunspell.thread cimport *

class HunspellFilePathError(IOError):
    pass

WIN32_LONG_PATH_PREFIX = "\\\\?\\"

ctypedef enum action_type:
    add,
    remove,
    stem,
    analyze,
    spell,
    suggest,
    suffix_suggest

cdef action_type action_to_enum(basestring action):
    if action == 'add':
        return add
    elif action == 'remove':
        return remove
    elif action == 'spell':
        return spell
    elif action == 'analyze':
        return analyze
    elif action == 'stem':
        return stem
    elif action == 'suggest':
        return suggest
    elif action == 'suffix_suggest':
        return suffix_suggest
    else:
        raise ValueError("Unexpected action {} for hunspell".format(action))

cdef basestring action_to_string(action_type action_e):
    if action_e == add:
        return 'add'
    elif action_e == remove:
        return 'remove'
    elif action_e == spell:
        return 'spell'
    elif action_e == analyze:
        return 'analyze'
    elif action_e == stem:
        return 'stem'
    elif action_e == suggest:
        return 'suggest'
    elif action_e == suffix_suggest:
        return 'suffix_suggest'
    else:
        raise ValueError("Unexpected action {} for hunspell".format(action_e))

def valid_encoding(basestring encoding):
    try:
        "".encode(encoding, 'strict')
        return encoding
    except LookupError:
        return 'ascii'

def md5(basestring input):
    return hashlib.md5(input.encode('utf-8')).hexdigest()

cdef int copy_to_c_string(basestring py_string, char **holder, basestring encoding) except -1:
    if isinstance(py_string, bytes):
        return byte_to_c_string(<bytes>py_string, holder, encoding)
    else:
        return byte_to_c_string(<bytes>py_string.encode(encoding, 'strict'), holder, encoding)

cdef int byte_to_c_string(bytes py_byte_string, char **holder, basestring encoding) except -1:
    cdef size_t str_len = len(py_byte_string)
    cdef char *c_raw_string = py_byte_string
    holder[0] = <char *>malloc((str_len + 1) * sizeof(char)) # deref doesn't support left-hand assignment
    if deref(holder) is NULL:
        raise MemoryError()
    strncpy(deref(holder), c_raw_string, str_len)
    holder[0][str_len] = 0
    return str_len

cdef unicode c_string_to_unicode_no_except(char* s, basestring encoding):
    # Convert c_string to python unicode
    try:
        return s.decode(encoding, 'strict')
    except UnicodeDecodeError:
        return u""

#//////////////////////////////////////////////////////////////////////////////
# Thread Worker
#//////////////////////////////////////////////////////////////////////////////

cdef struct ThreadWorkerArgs:
    # Structure for defining worker args

    # Thread ID
    int tid
    # Pointer to Hunspell Dictionary
    Hunspell *hspell
    # Number of words that this thread will check
    int n_words
    # Array of C strings, length of Array is n_words
    char **word_list
    # Array (of length n_words) of arrays of C strings
    char ***output_array_ptr
    # Array (of length n_words) of integers, each the length of the corresponding C string array
    int *output_counts
    # Determines if the thread is executing a stem or suggestion callback
    action_type action_e

cdef void *hunspell_worker(void *argument) nogil:
    cdef ThreadWorkerArgs args
    cdef int i
    args = deref(<ThreadWorkerArgs *>argument)

    for i from 0 <= i < args.n_words:
        if args.action_e == stem:
            args.output_counts[i] = args.hspell.stem(args.output_array_ptr + i, deref(args.word_list + i))
        elif args.action_e == analyze:
            args.output_counts[i] = args.hspell.analyze(args.output_array_ptr + i, deref(args.word_list + i))
        elif args.action_e == suggest:
            args.output_counts[i] = args.hspell.suggest(args.output_array_ptr + i, deref(args.word_list + i))
        elif args.action_e == suffix_suggest:
            args.output_counts[i] = args.hspell.suffix_suggest(args.output_array_ptr + i, deref(args.word_list + i))

    return NULL

#//////////////////////////////////////////////////////////////////////////////
cdef class HunspellWrap(object):
    # C-realm properties
    cdef Hunspell *_cxx_hunspell
    cdef public int max_threads
    cdef public basestring lang
    cdef public basestring _cache_manager_name
    cdef public basestring _hunspell_dir
    cdef public basestring _dic_encoding
    cdef public basestring _system_encoding
    cdef public object _suggest_cache
    cdef public object _suffix_cache
    cdef public object _analyze_cache
    cdef public object _stem_cache
    cdef char *affpath
    cdef char *dpath

    cdef basestring prefix_win_utf8_hunspell_path(self, basestring path):
        if os.name == 'nt' and self._system_encoding.lower().replace('-', '') == 'utf8':
            return WIN32_LONG_PATH_PREFIX + path
        else:
            return path

    cdef Hunspell *_create_hspell_inst(self, basestring lang) except *:
        # C-realm Create Hunspell Instance
        if self.affpath:
            free(self.affpath)
        self.affpath = NULL
        if self.dpath:
            free(self.dpath)
        self.dpath = NULL
        cdef Hunspell *holder = NULL

        pyaffpath = os.path.join(self._hunspell_dir, '{}.aff'.format(lang))
        pydpath = os.path.join(self._hunspell_dir, '{}.dic'.format(lang))
        for fpath in (pyaffpath, pydpath):
            if not os.path.isfile(fpath) or not os.access(fpath, os.R_OK):
                raise HunspellFilePathError("File '{}' not found or accessible".format(fpath))

        next_str = pyaffpath
        try:
            copy_to_c_string(
                self.prefix_win_utf8_hunspell_path(pyaffpath),
                &self.affpath,
                self._system_encoding
            )
            next_str = pydpath
            copy_to_c_string(
                self.prefix_win_utf8_hunspell_path(pydpath),
                &self.dpath,
                self._system_encoding
            )
        except UnicodeEncodeError as e:
            raise HunspellFilePathError(
                "File path ('{path}') encoding did not match locale encoding ('{enc}'): {err}".format(
                    path=next_str, enc=self._system_encoding, err=str(e))
            )
        holder = new Hunspell(self.affpath, self.dpath)
        if holder is NULL:
            raise MemoryError()

        return holder

    def __init__(self, basestring lang='en_US', basestring cache_manager="hunspell",
            basestring disk_cache_dir=None, basestring hunspell_data_dir=None,
            basestring system_encoding=None):
        # TODO - make these LRU caches so that you don't destroy your memory!
        if hunspell_data_dir is None:
            hunspell_data_dir = os.environ.get("HUNSPELL_DATA")
        if hunspell_data_dir is None:
            hunspell_data_dir = os.path.join(os.path.dirname(__file__), 'dictionaries')
        if system_encoding is None:
            system_encoding = os.environ.get("HUNSPELL_PATH_ENCODING")
        if system_encoding is None:
            system_encoding = getpreferredencoding()
        self._hunspell_dir = os.path.abspath(hunspell_data_dir)
        self._system_encoding = system_encoding

        self.lang = lang
        self._cxx_hunspell = self._create_hspell_inst(lang)
        # csutil.hxx defines the encoding for this value as #define SPELL_ENCODING "ISO8859-1"
        self._dic_encoding = valid_encoding(c_string_to_unicode_no_except(self._cxx_hunspell.get_dic_encoding(), 'ISO8859-1'))
        self.max_threads = detect_cpus()

        self._cache_manager_name = cache_manager
        manager = get_cache_manager(self._cache_manager_name)
        if disk_cache_dir:
            manager.cache_directory = disk_cache_dir

        suggest_cache_name = "hunspell_suggest_{lang}_{hash}".format(
            lang=lang, hash=md5(self._hunspell_dir))
        suffix_cache_name = "hunspell_suffix_{lang}_{hash}".format(
            lang=lang, hash=md5(self._hunspell_dir))
        analyze_cache_name = "hunspell_analyze_{lang}_{hash}".format(
            lang=lang, hash=md5(self._hunspell_dir))
        stem_cache_name = "hunspell_stem_{lang}_{hash}".format(
            lang=lang, hash=md5(self._hunspell_dir))

        if not manager.cache_registered(suggest_cache_name):
            if disk_cache_dir:
                custom_time_checks = [TimeCount(60, 1000000), TimeCount(300, 10000), TimeCount(900, 1)]
                AutoSyncCache(suggest_cache_name, cache_manager=manager, time_checks=custom_time_checks)
            else:
                NonPersistentCache(suggest_cache_name, cache_manager=manager)

        if not manager.cache_registered(suffix_cache_name):
            if disk_cache_dir:
                custom_time_checks = [TimeCount(60, 1000000), TimeCount(300, 10000), TimeCount(900, 1)]
                AutoSyncCache(suffix_cache_name, cache_manager=manager, time_checks=custom_time_checks)
            else:
                NonPersistentCache(suffix_cache_name, cache_manager=manager)

        if not manager.cache_registered(analyze_cache_name):
            if disk_cache_dir:
                custom_time_checks = [TimeCount(60, 1000000), TimeCount(300, 10000), TimeCount(900, 1)]
                AutoSyncCache(analyze_cache_name, cache_manager=manager, time_checks=custom_time_checks)
            else:
                NonPersistentCache(analyze_cache_name, cache_manager=manager)

        if not manager.cache_registered(stem_cache_name):
            if disk_cache_dir:
                custom_time_checks = [TimeCount(60, 1000000), TimeCount(300, 10000), TimeCount(900, 1)]
                AutoSyncCache(stem_cache_name, cache_manager=manager, time_checks=custom_time_checks)
            else:
                NonPersistentCache(stem_cache_name, cache_manager=manager)

        self._suggest_cache = manager.retrieve_cache(suggest_cache_name)
        self._suffix_cache = manager.retrieve_cache(suffix_cache_name)
        self._analyze_cache = manager.retrieve_cache(analyze_cache_name)
        self._stem_cache = manager.retrieve_cache(stem_cache_name)

    def __dealloc__(self):
        del self._cxx_hunspell
        if self.affpath is not NULL:
            free(self.affpath)
        if self.dpath is not NULL:
            free(self.dpath)

    def get_action_cache(self, action_type action_e):
        if action_e == stem:
            return self._stem_cache
        elif action_e == analyze:
            return self._analyze_cache
        elif action_e == suggest:
            return self._suggest_cache
        elif action_e == suffix_suggest:
            return self._suffix_cache
        else:
            raise ValueError("Unexpected action {} for caching".format(action_to_string(action_e)))

    def add_dic(self, basestring dpath, basestring key=None):
        # Python load extra dictionaries
        cdef char *c_path = NULL
        cdef char *c_key = NULL
        copy_to_c_string(dpath, &c_path, 'UTF-8')
        try:
            if key:
                copy_to_c_string(key, &c_key, 'UTF-8')
            try:
                return self._cxx_hunspell.add_dic(c_path, c_key)
            finally:
                if c_key is not NULL:
                    free(c_key)
        finally:
            if c_path is not NULL:
                free(c_path)

    def add(self, basestring word, basestring example=None):
        # Python add individual word to dictionary
        cdef char *c_word = NULL
        cdef char *c_example = NULL
        copy_to_c_string(word, &c_word, self._dic_encoding)
        try:
            if example:
                copy_to_c_string(example, &c_example, self._dic_encoding)
                try:
                    return self._cxx_hunspell.add_with_affix(c_word, c_example)
                finally:
                    if c_example is not NULL:
                        free(c_example)
            else:
                return self._cxx_hunspell.add(c_word)
        finally:
            if c_word is not NULL:
                free(c_word)

    def add_with_affix(self, basestring word, basestring example):
        return self.add(word, example)

    def remove(self, basestring word):
        # Python remove individual word from dictionary
        cdef char *c_word = NULL
        copy_to_c_string(word, &c_word, self._dic_encoding)
        try:
            return self._cxx_hunspell.remove(c_word)
        finally:
            if c_word is not NULL:
                free(c_word)

    def spell(self, basestring word):
        # Python individual word spellcheck
        cdef char *c_word = NULL
        copy_to_c_string(word, &c_word, self._dic_encoding)
        try:
            return self._cxx_hunspell.spell(c_word) != 0
        finally:
            if c_word is not NULL:
                free(c_word)

    def analyze(self, basestring word):
        # Python individual word analyzing
        return self.c_tuple_action(analyze, word)

    def stem(self, basestring word):
        # Python individual word stemming
        return self.c_tuple_action(stem, word)

    def suggest(self, basestring word):
        # Python individual word suggestions
        return self.c_tuple_action(suggest, word)

    def suffix_suggest(self, basestring word):
        # Python individual word suffix suggestions
        return self.c_tuple_action(suffix_suggest, word)

    def action(self, basestring action, basestring word):
        cdef action_type action_e = action_to_enum(action)
        if action_e == add:
            return self.add(word)
        elif action_e == remove:
            return self.remove(word)
        elif action_e == spell:
            return self.spell(word)
        else:
            return self.c_tuple_action(action_e, word)

    def bulk_suggest(self, words):
        return self.c_bulk_action(suggest, words)

    def bulk_suffix_suggest(self, words):
        return self.c_bulk_action(suffix_suggest, words)

    def bulk_analyze(self, words):
        return self.c_bulk_action(analyze, words)

    def bulk_stem(self, words):
        return self.c_bulk_action(stem, words)

    def save_cache(self):
        self._suggest_cache.save()
        self._suffix_cache.save()
        self._analyze_cache.save()
        self._stem_cache.save()

    def clear_cache(self):
        self._suggest_cache.clear()
        self._suffix_cache.clear()
        self._analyze_cache.clear()
        self._stem_cache.clear()

    def set_concurrency(self, max_threads):
        self.max_threads = max_threads

    ###################
    # C-Operations
    ###################

    cdef tuple c_tuple_action(self, action_type action_e, basestring word):
        cdef char **s_list = NULL
        cdef char *c_word = NULL
        cdef list results_list
        cdef tuple result

        cache = self.get_action_cache(action_e)
        if word in cache:
            return cache[word]

        copy_to_c_string(word, &c_word, self._dic_encoding)

        try:
            if action_e == stem:
                count = self._cxx_hunspell.stem(&s_list, c_word)
            elif action_e == analyze:
                count = self._cxx_hunspell.analyze(&s_list, c_word)
            elif action_e == suggest:
                count = self._cxx_hunspell.suggest(&s_list, c_word)
            elif action_e == suffix_suggest:
                count = self._cxx_hunspell.suffix_suggest(&s_list, c_word)
            else:
                raise ValueError("Unexpected tuple action {} for hunspell".format(action_to_string(action_e)))

            results_list = []
            for i from 0 <= i < count:
                results_list.append(c_string_to_unicode_no_except(s_list[i], self._dic_encoding))
            self._cxx_hunspell.free_list(&s_list, count)

            result = tuple(results_list)
            cache[word] = result
            return result
        finally:
            if c_word is not NULL:
                free(c_word)

    cdef dict c_bulk_action(self, action_type action_e, words):
        '''Accepts a list of words, returns a dict of words mapped to a list
        # of their hunspell suggestions'''
        cdef dict ret_dict = {}
        cdef list unknown_words = []

        cache = self.get_action_cache(action_e)

        for word in words:
            if action_e == suggest and self.spell(word):
                # No need to check correctly spelled words
                ret_dict[word] = (word,)
            elif word in cache:
                ret_dict[word] = cache[word]
            else:
                # This will turn into a tuple when completed
                ret_dict[word] = []
                unknown_words.append(word)

        if unknown_words:
            self._bulk_unknown_words(unknown_words, action_e, ret_dict)

        return ret_dict

    cdef void _c_threaded_bulk_action(self, char **word_array, char ***output_array, int n_words, action_type action_e, int *output_counts) except *:
        '''C realm thread dispatcher'''
        # Allocate all memory per thread
        cdef thread_t **threads = <thread_t **>calloc(self.max_threads, sizeof(thread_t *))
        cdef ThreadWorkerArgs *thread_args = <ThreadWorkerArgs *>calloc(self.max_threads, sizeof(ThreadWorkerArgs))
        cdef int rc, i, stride

        if thread_args is NULL or threads is NULL:
            raise MemoryError()

        try:
            # Divide workload between threads
            words_per_thread = n_words // self.max_threads
            words_distributed = 0
            # If uneven, round down on workers per thread (but the last thread will have extra work to do)
            if n_words == 0 or n_words % self.max_threads != 0:
                words_per_thread = (n_words - (n_words % self.max_threads)) // self.max_threads

            for i from 0 <= i < self.max_threads:
                stride = i * words_per_thread
                thread_args[i].tid = i
                thread_args[i].action_e = action_e

                # Allocate one Hunspell Dict per thread since it isn't safe.
                thread_args[i].hspell = self._create_hspell_inst(self.lang)

                # Account for leftovers
                if i == self.max_threads - 1:
                    thread_args[i].n_words = n_words - words_distributed
                else:
                    thread_args[i].n_words = words_per_thread
                    words_distributed += words_per_thread

                # Find the stride into each array
                thread_args[i].word_list = &word_array[stride]
                thread_args[i].output_array_ptr = &output_array[stride]
                thread_args[i].output_counts = &output_counts[stride]

                # Create thread
                threads[i] = thread_create(&hunspell_worker, <void *> &thread_args[i])
                if threads[i] is NULL:
                    raise OSError("Could not create thread")

            # wait for each thread to complete
            for i from 0 <= i < self.max_threads:
                # block until thread i completes
                rc = thread_join(threads[i])
                if rc:
                    raise OSError(rc, "Could not join thread")

                # Free Hunspell Dict
                del thread_args[i].hspell
        finally:
            # Free top level stuff
            if thread_args is not NULL:
                free(thread_args)
            dealloc_threads(threads, self.max_threads)

    cdef void _parse_bulk_results(self, dict ret_dict, list unknown_words, int *output_counts, char ***output_array) except *:
        '''Parse the return of a bulk action'''
        cdef int unknown_len = len(unknown_words)
        cdef int i, j
        for i from 0 <= i < unknown_len:
            for j from 0 <= j < output_counts[i]:
                ret_dict[unknown_words[i]].append(c_string_to_unicode_no_except(output_array[i][j], self._dic_encoding))
            ret_dict[unknown_words[i]] = tuple(ret_dict[unknown_words[i]])
        for i from 0 <= i < unknown_len:
            # Free each suggestion list
            self._cxx_hunspell.free_list(output_array + i, output_counts[i])

    cdef void _bulk_unknown_words(self, list unknown_words, action_type action_e, dict ret_dict) except *:
        cdef int unknown_len = len(unknown_words)
        # C version of: ["foo", "bar", "baz"]
        cdef char ***output_array = NULL
        cdef int *output_counts = NULL
        cdef char **word_array = <char **>calloc(unknown_len, sizeof(char *))

        cache = self.get_action_cache(action_e)

        if word_array is NULL:
            raise MemoryError()
        for i, unknown_word in enumerate(unknown_words):
            copy_to_c_string(unknown_word, &word_array[i], self._dic_encoding)

        # Create output arrays
        # Array of arrays of C strings (e.g. [["food", ...], ["bar"], ["bad", ...]])
        # This array will be divided evenly amongst the threads for the return values
        # of Hunspell.suggest(), each call returns an array of C strings
        output_array = <char ***>calloc(unknown_len, sizeof(char **))

        # Array of integers, each the length of the corresponding C string array
        # This array will be divided evenly amongst the threads for the length of the
        # arrays returned by each call to Hunspell.suggest()
        output_counts = <int *>calloc(unknown_len, sizeof(int))
        if output_counts is NULL or output_array is NULL:
            raise MemoryError()

        try:
            # Schedule bulk job
            self._c_threaded_bulk_action(word_array, output_array, unknown_len, action_e, output_counts)

            # Parse the return
            self._parse_bulk_results(ret_dict, unknown_words, output_counts, output_array)

            # Add ret_dict words to cache
            for i from 0 <= i < unknown_len:
                cache[unknown_words[i]] = ret_dict[unknown_words[i]]
            self._cxx_hunspell.free_list(&word_array, unknown_len)
        finally:
            # Free top level stuff
            if output_array is not NULL:
                free(output_array)
            if output_counts is not NULL:
                free(output_counts)

