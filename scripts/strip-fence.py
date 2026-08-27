#!/usr/bin/env python3
"""Remove a fenced block (and blank lines immediately before it) from a file.

Used by `desks-ctl restore` to take the plugin's require() hook back out of
hyprland.lua without disturbing anything the user wrote around it.

Like append-fence.py, the file is opened once with O_NOFOLLOW so a symlink
planted at the path is refused rather than followed, and the rewrite happens
through that same descriptor -- no separate check-then-open race.

Exit codes:
  0  fence removed (or nothing to remove)
  4  refused: path is a symlink
  5  refused: path missing or not a regular file
  1  any other error
"""
import errno
import os
import stat
import sys

EXIT_OK = 0
EXIT_SYMLINK = 4
EXIT_NOT_REGULAR = 5


def strip_fence(path: str, begin: str, end: str) -> int:
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
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

        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        lines = b"".join(chunks).decode("utf-8").splitlines()

        out: list[str] = []
        skipping = False
        removed = False
        for line in lines:
            if not skipping and line.strip() == begin:
                while out and out[-1].strip() == "":
                    out.pop()
                skipping = True
                removed = True
                continue
            if skipping:
                if line.strip() == end:
                    skipping = False
                continue
            out.append(line)

        if removed:
            payload = ("\n".join(out) + "\n").encode("utf-8")
            os.lseek(fd, 0, os.SEEK_SET)
            os.write(fd, payload)
            os.ftruncate(fd, len(payload))
        return EXIT_OK
    finally:
        os.close(fd)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: strip-fence.py <file> <begin-marker> <end-marker>")
    sys.exit(strip_fence(sys.argv[1], sys.argv[2], sys.argv[3]))
