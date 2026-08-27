#!/usr/bin/env python3
"""Read Unified Desks state safely and print it as one small JSON line.

The bar widget must never open these paths itself. Quickshell is a single
long-running process hosting the whole shell, and both paths are predictable
and replaceable by any same-user process, so a naive open is a denial of
service against the entire desktop:

  * a FIFO makes open() or read() block forever, hanging the shell;
  * an enormous regular file makes a read exhaust memory;
  * a device node can block or misbehave in its own ways.

Every open here is therefore O_RDONLY | O_NONBLOCK | O_NOFOLLOW, and the
resulting *descriptor* is validated with fstat before a single byte is read --
so there is no check/open race, a symlink is refused by the kernel, a FIFO or
device is rejected because it is not a regular file, and O_NONBLOCK means even
a FIFO that slipped through could not block. Reads are capped, so an oversized
file costs a fixed number of bytes rather than its full size.

Only the parsed result crosses back to QML:

    {"desks": 5, "installed": true}
"""
import errno
import json
import os
import stat
import sys

HOME = os.path.expanduser("~")
CONFIG_PATH = os.path.join(HOME, ".config/omarchy/unified-desks.conf")
INSTALLED_PATH = os.path.join(HOME, ".config/hypr/unified-desks.lua")

DEFAULT_DESKS = 5
MIN_DESKS = 1
MAX_DESKS = 10

# The config file holds one small number. Anything larger is not ours; cap the
# read so a huge file costs this many bytes and no more.
CONFIG_READ_CAP = 64
# Refuse outright if the file is implausibly large for its purpose.
CONFIG_SIZE_CAP = 4096


def open_regular(path: str, size_cap: int | None = None):
    """Open a path as a regular file, or return None.

    O_NONBLOCK keeps a FIFO from blocking the open, O_NOFOLLOW makes the kernel
    refuse a symlink in the same syscall, and the fstat runs on the descriptor
    we already hold, so nothing can be swapped underneath us afterwards.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            os.close(fd)
            return None
        if size_cap is not None and info.st_size > size_cap:
            os.close(fd)
            return None
        return fd
    except OSError:
        os.close(fd)
        return None


def read_desk_count() -> int:
    fd = open_regular(CONFIG_PATH, size_cap=CONFIG_SIZE_CAP)
    if fd is None:
        return DEFAULT_DESKS

    try:
        try:
            raw = os.read(fd, CONFIG_READ_CAP)
        except OSError as exc:
            # EAGAIN can only happen on a non-regular file, which fstat already
            # ruled out; treat any read failure as "use the default".
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return DEFAULT_DESKS
            raise
    finally:
        os.close(fd)

    text = raw.decode("utf-8", errors="replace").strip().split("\n", 1)[0]
    digits = ""
    for char in text.strip():
        if not char.isdigit():
            break
        digits += char

    if not digits:
        return DEFAULT_DESKS

    try:
        count = int(digits)
    except ValueError:
        return DEFAULT_DESKS

    if count < MIN_DESKS or count > MAX_DESKS:
        return DEFAULT_DESKS
    return count


def is_installed() -> bool:
    # Existence and type only -- the contents are never read.
    fd = open_regular(INSTALLED_PATH)
    if fd is None:
        return False
    os.close(fd)
    return True


if __name__ == "__main__":
    try:
        state = {"desks": read_desk_count(), "installed": is_installed()}
    except Exception:
        state = {"desks": DEFAULT_DESKS, "installed": False}
    sys.stdout.write(json.dumps(state) + "\n")
