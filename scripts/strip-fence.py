#!/usr/bin/env python3
"""Remove a fenced block (and any blank lines immediately before it) from a file.

Used by desks-ctl restore to take the plugin's require() hook back out of
hyprland.lua without disturbing anything the user wrote around it.
"""
import sys


def strip_fence(path: str, begin: str, end: str) -> bool:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

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
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(out) + "\n")
    return removed


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: strip-fence.py <file> <begin-marker> <end-marker>")
    strip_fence(sys.argv[1], sys.argv[2], sys.argv[3])
