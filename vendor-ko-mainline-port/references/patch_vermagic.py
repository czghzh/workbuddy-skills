#!/usr/bin/env python3
"""Rewrite the vermagic version field of prebuilt kernel modules in place.

usage: patch_vermagic.py <old-vermagic> <new-vermagic> module.ko [module.ko ...]

The replacement must be the same length; differing PREEMPT/SMP flags mean the
two kernels were built with different configs and an equal-length swap is not
possible.
"""
import os
import shutil
import sys


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2

    old = argv[1].encode()
    new = argv[2].encode()
    if len(old) != len(new):
        print(f"refusing: '{argv[1]}' and '{argv[2]}' differ in length "
              f"({len(old)} vs {len(new)})")
        return 1

    status = 0
    for name in argv[3:]:
        with open(name, "rb") as fh:
            data = fh.read()

        n = data.count(old)
        if n != 1:
            print(f"  !! {name}: {n} occurrences of old vermagic, skipped")
            status = 1
            continue

        tmp = name + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(data.replace(old, new))
        shutil.copystat(name, tmp)
        os.replace(tmp, name)
        print(f"  OK {name}: 1 replacement, size {len(data)}")

    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
