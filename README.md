[![Build Status](https://travis-ci.org/MSeal/cython_hunspell.svg?branch=master)](https://travis-ci.org/MSeal/cython_hunspell)
[![PyPI version shields.io](https://img.shields.io/pypi/v/CyHunspell.svg)](https://pypi.python.org/pypi/CyHunspell/)
[![PyPI pyversions](https://img.shields.io/pypi/pyversions/CyHunspell.svg)](https://pypi.python.org/pypi/CyHunspell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# hunspell-hitalent
Cython wrapper on Hunspell Dictionary

## Description
This repository provides a wrapper on Hunspell to be used natively in Python. The
module uses cython to link between the C++ and Python code, with some additional
features. There's very little Python overhead as all the heavy lifting is done
on the C++ side of the module interface, which gives optimal performance.

The hunspell library will cache any corrections, you can use persistent caching by
adding the `use_disk_cache` argument to a Hunspell constructor. Otherwise it uses
in-memory caching.

## Installing

For the simplest install simply run:

    pip install hunspell-hitalent

This will install the hunspell 1.7.0 C++ bindings on your behalf for your platform.

## Dependencies

cacheman -- for (optionally asynchronous) persistent caching

## Non-Python Dependencies

### hunspell

The library installs [hunspell](http://hunspell.github.io/) version 1.7.0. As new version of hunspell become
available this library will provide new versions to match.

## Features

Spell checking & spell suggestions
* See http://hunspell.github.io/

## How to use

Below are some simple examples for how to use the repository.

### Creating a Hunspell object

```python
from hunspell import Hunspell
h = Hunspell()
```

You now have a usable hunspell object that can make basic queries for you.

```python
h.spell('test') # True
```

### Spelling

It's a simple task to ask if a particular word is in the dictionary.

```python
h.spell('correct') # True
h.spell('incorect') # False
```

This will only ever return True or False, and won't give suggestions about why it
might be wrong. It also depends on your choice of dictionary.

### Suggestions

If you want to get a suggestion from Hunspell, it can provide a corrected label
given a basestring input.

```python
h.suggest('incorect') # ('incorrect', 'correction', corrector', 'correct', 'injector')
```

The suggestions are in sorted order, where the lower the index the closer to the
input string.

#### Suffix Match

```python
h.suffix_suggest('do') # ('doing', 'doth', 'doer', 'doings', 'doers', 'doest')
```

### Stemming

The module can also stem words, providing the stems for pluralization and other
inflections.

```python
h.stem('testers') # ('tester', 'test')
h.stem('saves') # ('save',)
```

#### Analyze

Like stemming but return morphological analysis of the input instead.

```python
h.analyze('permanently') # (' st:permanent fl:Y',)
```

#### Generate

Generate methods are *NOT* provided at this time due to the 1.7.0 build not producing
any results for any inputs, included the documented one. If this is fixed or someone
identifies the issue in the call pattern this will be added to the library in the
future.

### Bulk Requests

You can also request bulk actions against Hunspell. This will trigger a threaded
(without a gil) request to perform the action requested. Currently just 'suggest'
and 'stem' are bulk requestable.

```python
h.bulk_suggest(['correct', 'incorect'])
# {'incorect': ('incorrect', 'correction', 'corrector', 'correct', 'injector'), 'correct': ('correct',)}
h.bulk_suffix_suggest(['cat', 'do'])
# {'do': ('doing', 'doth', 'doer', 'doings', 'doers', 'doest'), 'cat': ('cater', 'cats', "cat's", 'caters')}
h.bulk_stem(['stems', 'currencies'])
# {'currencies': ('currency',), 'stems': ('stem',)}
h.bulk_analyze(['dog', 'permanently'])
# {'permanently': (' st:permanent fl:Y',), 'dog': (' st:dog',)}
```

By default it spawns number of CPUs threads to perform the operation. You can
overwrite the concurrency as well.

```python
h.set_concurrency(4) # Four threads will now be used for bulk requests
```

### Dictionaries

You can also specify the language or dictionary you wish to use.

```python
h = Hunspell('en_CA') # Canadian English
```

By default you have the following dictionaries available
* en_AU
* en_CA
* en_GB
* en_NZ
* en_US
* en_ZA

However you can download your own and point Hunspell to your custom dictionaries.

```python
h = Hunspell('en_GB-large', hunspell_data_dir='/custom/dicts/dir')
```

#### Adding Dictionaries

You can also add new dictionaries at runtime by calling the add_dic method.

```python
h.add_dic(os.path.join(PATH_TO, 'special.dic'))
```

#### Adding words

You can add individual words to a dictionary at runtime.

```python
h.add('sillly')
```

Furthermore you can attach an affix to the word when doing this by providing a
second argument

```python
h.add('silllies', "is:plural")
```

#### Removing words

Much like adding, you can remove words.

```python
h.remove(word)
```

### Asynchronous Caching

If you want to have Hunspell cache suggestions and stems you can pass it a directory
to house such caches.

```python
h = Hunspell(disk_cache_dir='/tmp/hunspell/cache/dir')
```

This will save all suggestion and stem requests periodically and in the background.
The cache will fork after a number of new requests over particular time ranges and
save the cache contents while the rest of the program continues onward. Yo'll never
have to explicitly save your caches to disk, but you can if you so choose.

```python
h.save_cache()
```

Otherwise the Hunspell object will cache such requests locally in memory and not
persist that memory.

## Language Preferences

* Google Style Guide
* Object Oriented (with a few exceptions)

## Known Workarounds

- On Windows very long file paths, or paths saved in a different encoding than the system require special handling by Hunspell to load dictionary files. To circumvent this on Windows setups, either set `system_encoding='UTF-8'` in the `Hunspell` constructor or set the environment variable `HUNSPELL_PATH_ENCODING=UTF-8`. Then you must re-encode your `hunspell_data_dir` in UTF-8 by passing that argument name to the `Hunspell` constructor or setting the `HUNSPELL_DATA` environment variable. This is a restriction of Hunspell / Windows operations.

## Author
Author(s): Tim Rodriguez and Matthew Seal

## License
MIT
