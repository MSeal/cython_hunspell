__all__ = ['hunspell']

# Temporary fix for Python 3.10
import collections
from collections import abc
collections.MutableMapping = abc.MutableMapping

from ._version import __version__  # noqa: F401
from .hunspell import HunspellWrap as Hunspell, HunspellFilePathError  # noqa: F401
