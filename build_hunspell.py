#
# This is a cross-platform shared library prep/build mechanism.
# Tested on:
# OSX, Ubuntu, Fedora, and Windows
#
import os
import glob
import platform
import re
import sys
import shutil
from subprocess import Popen, PIPE
from tar_download import download_and_extract
from distutils.sysconfig import get_python_lib
try:
    from subprocess import getstatusoutput
except ImportError:
    from commands import getstatusoutput

BASE_DIR = os.path.abspath(os.path.dirname(__file__))

def include_dirs():
    return [
        os.path.abspath(os.path.join(BASE_DIR, 'hunspell')),
        os.path.abspath(os.path.join(BASE_DIR, 'external', 'hunspell-1.7.0', 'src')),
    ]

def run_proc_delay_print(*args):
    proc = Popen(args, stdout=PIPE, stderr=PIPE)
    stdout, stderr = proc.communicate()
    for line in stdout.decode(encoding='utf-8').split('\n'):
        print(line)
    for line in stderr.decode(encoding='utf-8').split('\n'):
        print(line, file=sys.stderr)
    if proc.returncode != 0:
        raise RuntimeError("Process '{}' returned with a non-zero exit code".format(args))

def build_hunspell_package(directory, force_build=False):
    if platform.system() == 'Windows':
        raise RuntimeError("Cannot build directly for windows OS. Please build manually by follow instructions at /libs/msvc/README")

    build_path = os.path.join(BASE_DIR, 'external', 'build')
    hunspell_so_dir = os.path.join(BASE_DIR, 'hunspell')
    lib_path = os.path.join(build_path, 'lib')
    if not os.path.exists(build_path):
        os.makedirs(build_path)

    if platform.system() == 'Linux':
        hunspell_library_name = 'libhunspell-1.7.so.0'
        export_lib_name = ':'+hunspell_library_name
        build_lib_path = os.path.join(BASE_DIR, 'external', 'build', 'lib', 'libhunspell-1.7.so.0.0.1')
    else: # OSX
        hunspell_library_name = 'libhunspell-1.7.0.dylib'
        export_lib_name = 'hunspell-1.7.0'
        build_lib_path = os.path.join(BASE_DIR, 'external', 'build', 'lib', 'libhunspell-1.7.0.dylib')
    hunspell_so_path = os.path.join(hunspell_so_dir, hunspell_library_name)

    olddir = os.getcwd()
    if force_build or not os.path.exists(hunspell_so_path):
        if os.path.exists(lib_path):
            shutil.rmtree(lib_path)
        try:
            os.chdir(directory)
            run_proc_delay_print('autoreconf', '-vfi')
            run_proc_delay_print('./configure', '--prefix='+build_path)
            run_proc_delay_print('make')
            run_proc_delay_print('make', 'install')
        finally:
            os.chdir(olddir)

        print("Built Hunspell library files:")
        for filename in os.listdir(lib_path):
            if os.path.isfile(os.path.join(lib_path, filename)):
                print('\t' + filename)
        # Copy to our runtime location
        os.makedirs(hunspell_so_dir, exist_ok=True)
        shutil.copyfile(build_lib_path, hunspell_so_path)
        print("Copied binary to '{}'".format(hunspell_so_path))

    return export_lib_name, hunspell_so_dir

def pkgconfig(**kw):
    kw['include_dirs'] = include_dirs()
    kw['library_dirs'] = []
    kw['libraries'] = []
    kw['extra_link_args'] = []
    kw['language'] = 'c++'
    # Need to set the linker locations
    if platform.system() == 'Linux':
        kw['runtime_library_dirs'] = [os.path.join('$ORIGIN')]
    if platform.system() == 'Darwin':
        # See https://stackoverflow.com/questions/9795793/shared-library-dependencies-with-distutils
        kw['extra_link_args'] = ['-Wl,-rpath,"@loader_path/']
    # If changing to a dynamic link dependency
    # if platform.system() == 'Windows':
    #     # See https://stackoverflow.com/questions/62662816/how-do-i-use-the-correct-dll-files-to-enable-3rd-party-c-libraries-in-a-cython-c
    #     for filename in os.listdir(os.path.join(BASE_DIR, 'libs', 'msvc')):
    #         shutil.copyfile(os.path.join(BASE_DIR, 'libs', 'msvc', filename), os.path.join(BASE_DIR, 'hunspell', filename))

    if not os.path.exists(os.path.join(BASE_DIR, 'external', 'hunspell-1.7.0')):
        # Prepare for hunspell if it's missing
        download_and_extract('https://github.com/hunspell/hunspell/archive/v1.7.0.tar.gz',
            os.path.join(BASE_DIR, 'external'))
        kw['include_dirs'] = include_dirs()

    if platform.system() == 'Windows':
        # These should be hardcoded to both architectures
        kw['libraries'] = ['libhunspell-msvc14-x64', 'libhunspell-msvc14-x86']
        kw['library_dirs'] = [os.path.join(BASE_DIR, 'libs', 'msvc')]
        kw['extra_link_args'] = ['/NODEFAULTLIB:libucrt.lib ucrt.lib']
    else:
        force_build = os.environ.get('CYHUNSPELL_FORCE_BUILD', False)
        if force_build == '0' or force_build == 0:
            force_build = False
        lib_name, lib_path = build_hunspell_package(os.path.join(BASE_DIR, 'external', 'hunspell-1.7.0'), force_build)
        kw['library_dirs'] = [lib_path]
        kw['libraries'] = [lib_name]

    return kw

def clean_hunspell_build_dir():
    build_path = os.path.join(BASE_DIR, 'external', 'build')
    if os.path.exists(build_path):
        shutil.rmtree(build_path)

def repair_darwin_link_dep_path():
    # Needed for darwin generated SO files to correctly look in the @loader_path for shared dependencies
    build_lib_path = os.path.join(BASE_DIR, 'external', 'build', 'lib', 'libhunspell-1.7.0.dylib')
    for parent_lib_path in glob.glob(os.path.join(BASE_DIR, 'hunspell', '*.so')):
        run_proc_delay_print('install_name_tool', '-change', build_lib_path, '@loader_path/libhunspell-1.7.0.dylib', parent_lib_path)
        print("Changed lib path '{}' to '@loader_path/libhunspell-1.7.0.dylib' in {}".format(build_lib_path, parent_lib_path))
