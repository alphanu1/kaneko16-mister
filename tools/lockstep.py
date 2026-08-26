#!/usr/bin/env python3
"""Diff the core's 68000 data-access trace against MAME's, access by access.

Hard rule 6: a debugging session starts by getting MAME to the same point and
comparing. This is that comparison, automated, and it is the check that found
the MCU RAM read misalignment -- a fault no unit test could see, because every
module involved was correct on its own and the bug was in how one of them asked
for a burst.

  tools/lockstep.py <mame trace> <core trace>

Both files are "aaaaaa R dddd mmmm" lines. The core's trace is the shorter of
the two and its last line may be partial, so a divergence on the final line is
reported as truncation rather than as a difference -- otherwise every run would
end in a false failure.
"""
import sys


def load(path):
    with open(path) as f:
        return f.read().rstrip("\n").split("\n")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    m, o = load(sys.argv[1]), load(sys.argv[2])
    n = min(len(m), len(o))
    if n == 0:
        sys.exit("lockstep: one of the traces is empty")

    for i in range(n):
        if m[i] == o[i]:
            continue
        # The core's trace is cut where the run stopped; a mismatch on its very
        # last line is that cut, not a divergence.
        if i == len(o) - 1 and m[i].startswith(o[i]):
            break
        print(f"lockstep: DIVERGES at access {i + 1} of {n}")
        for k in range(max(0, i - 4), min(n, i + 5)):
            mark = "   <<<" if k == i else ""
            print(f"  {k + 1:8d}  MAME {m[k]:24s}  CORE {o[k]}{mark}")
        return 1

    print(f"lockstep: {n} accesses identical "
          f"(MAME {len(m)}, core {len(o)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
