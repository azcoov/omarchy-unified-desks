#!/usr/bin/env python3
"""Append a fenced block to a Hyprland config without ever following a symlink.

A shell `>>` redirect resolves the path at open time and follows whatever
symlink sits there, and a separate `[[ -L ... ]]` test beforehand is a
time-of-check/time-of-use race: the path can be swapped between the test and
the redirect. Opening once with O_NOFOLLOW closes both holes in a single
syscall -- the kernel refuses (ELOOP) when the final component is a symlink.

The same descriptor is used to read the current contents and to append, so the
"is the fence already present?" check cannot be raced either.

Exit codes:
  0  fence appended
  3  fence already present, nothing written
  4  refused: path is a symlink
  5  refused: path missing or not a regular file
  1  any other error
"""
import errno
import os
import stat
import sys

EXIT_APPENDED = 0
EXIT_PRESENT = 3
EXIT_SYMLINK = 4
EXIT_NOT_REGULAR = 5


def append_fence(path: str, begin: str, end: str, line: str) -> int:
    try:
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return EXIT_SYMLINK
        if exc.errno == errno.ENOENT:
            return EXIT_NOT_REGULAR
        raise

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return EXIT_NOT_REGULAR

        # Read through the same descriptor the append will use.
        os.lseek(fd, 0, os.SEEK_SET)
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        current = b"".join(chunks).decode("utf-8", errors="replace")

        if begin in current:
            return EXIT_PRESENT

        block = "\n{}\n{}\n{}\n".format(begin, line, end)
        if current and not current.endswith("\n"):
            block = "\n" + block
        os.write(fd, block.encode("utf-8"))
        return EXIT_APPENDED
    finally:
        os.close(fd)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("usage: append-fence.py <file> <begin-marker> <end-marker> <line>")
    sys.exit(append_fence(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]))
