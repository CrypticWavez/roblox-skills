"""A simulated case-insensitive filesystem for Python tests that run on case-sensitive Linux.

Windows (NTFS) and macOS (APFS) open `Packages` when only `packages` exists. case_insensitive_paths()
patches pathlib.Path so exists, is_dir, is_file and iterdir resolve each path component the same way:
the exact name first, else the stored entry whose name matches ignoring case. Directory listings keep
the stored names, as those filesystems do, so code that compares names from iterdir() sees `packages`.
Only these four methods are patched; open() and read_text() still need the exact name.
"""
import contextlib
from pathlib import Path
from unittest import mock

PATCHED = ("exists", "is_dir", "is_file", "iterdir")


def fold(path, real):
    """The stored path a case-insensitive lookup of path opens (path itself when nothing matches)."""
    path = Path(path)
    if real["exists"](path):
        return path
    current = Path(path.anchor) if path.anchor else Path(".")
    for part in path.parts[1:] if path.anchor else path.parts:
        candidate = current / part
        if not real["exists"](candidate):
            try:
                candidate = next(c for c in real["iterdir"](current) if c.name.casefold() == part.casefold())
            except (StopIteration, OSError):
                return path
        current = candidate
    return current


@contextlib.contextmanager
def case_insensitive_paths():
    real = {name: getattr(Path, name) for name in PATCHED}

    def lookup(name):
        return lambda self, *args, **kwargs: real[name](fold(self, real), *args, **kwargs)

    def iterdir(self):
        for child in real["iterdir"](fold(self, real)):
            yield self / child.name

    with contextlib.ExitStack() as stack:
        for name in ("exists", "is_dir", "is_file"):
            stack.enter_context(mock.patch.object(Path, name, lookup(name)))
        stack.enter_context(mock.patch.object(Path, "iterdir", iterdir))
        yield
