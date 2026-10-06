"""A simulated case-insensitive filesystem for Python tests that run on case-sensitive Linux.

Windows (NTFS) and macOS (APFS) open `Packages` when only `packages` exists. case_insensitive_paths()
patches pathlib.Path so exists, is_dir, is_file and iterdir resolve each path component the same way:
the exact name first, else the stored entry whose name matches ignoring case. Directory listings keep
the stored names, as those filesystems do, so code that compares names from iterdir() sees `packages`.
Only these four methods are patched; open() and read_text() still need the exact name.
wally_clean(project) does what `wally install` does first on such a filesystem.
"""
import contextlib
import shutil
from pathlib import Path
from unittest import mock

PATCHED = ("exists", "is_dir", "is_file", "iterdir")
REAL = {name: getattr(Path, name) for name in PATCHED}  # captured before any patch
WALLY_DIRS = ("Packages", "ServerPackages", "DevPackages")


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


def wally_clean(project):
    """Wally 0.3.2 `wally install` starts with Installation::clean (src/installation.rs): remove_dir_all on
    project/Packages, ServerPackages and DevPackages, ignoring NotFound. Here each name is looked up the way
    NTFS and APFS do (fold); returns the stored names it removed."""
    removed = []
    for name in WALLY_DIRS:
        stored = fold(Path(project) / name, REAL)
        if REAL["is_dir"](stored):
            shutil.rmtree(stored)
            removed.append(stored.name)
    return removed


@contextlib.contextmanager
def case_insensitive_paths():
    real = REAL

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
