#!/usr/bin/env python3
"""Prove a refactor changed nothing.

Captures the whole suite's output, and compares it to a capture taken before
the change. A pure refactor must produce a byte-identical result; anything
that differs is either a behavior change or a bug, and either way it is
something to look at rather than something to explain away.

    python tools/parity.py before      # on the unmodified tree
    ...make the change...
    python tools/parity.py after       # prints the verdict

Why this exists rather than a shell one-liner: the one-liner was reporting a
difference on every run, and the difference was NOISE. The stress test prints
peak memory after 32 races, and that figure moves 15 KB run to run against
identical code because it depends on when the collector happened to run. Twice
I read a number inside that band as evidence the refactor had improved
something. It had not.

So the noise is filtered HERE, once, with the reason written down -- rather
than being re-judged by eye every time, which is how it got misread.

Anything filtered is listed in the verdict, so a filter can never quietly hide
a real regression: you always see what was ignored and can decide whether that
was right.
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(HERE, ".parity")

# Lines that legitimately differ run to run on identical code.
#
# Keep this list SHORT and justified. Every entry is a place the suite reports
# something the code does not fully determine; adding one to silence an
# inconvenient difference is how a parity check stops being worth running.
NOISE = [
    (re.compile(r"^\s*memory\s*:"),
     "peak memory: depends on when the GC ran, moves ~15 KB between runs "
     "of identical code"),
    # Everything stress_test measures in seconds. These are wall clock on a
    # machine doing other things, and they are the POINT of that test -- it
    # reports them so a human can look. They are simply not evidence about a
    # refactor, and comparing them makes every run differ.
    (re.compile(r"^\s*(no cup|with cup|drift|overhead|evening)\s*:"),
     "wall-clock timing: varies with whatever else the machine is doing"),
    (re.compile(r"^\s*\d+(\.\d+)? us/tick"),
     "per-tick timing, same reason"),
    (re.compile(r"^\s*outbound \d"),
     "derived from the timing above"),
    (re.compile(r"^\s*\(test harness overhead excluded:"),
     "wall-clock timing, same reason"),
]

# Server log chatter is not test output; it is the plugin narrating itself.
CHATTER = re.compile(r"^\[RaceManager\]")


def capture():
    tests = sorted(
        os.path.join("tests", f)
        for f in os.listdir(os.path.join(HERE, "tests"))
        if f.endswith(".lua")
    )
    lines, ignored = [], []
    for t in tests:
        lines.append("=== %s ===" % os.path.basename(t))
        try:
            out = subprocess.run(
                ["lua", t], cwd=HERE, capture_output=True, text=True, timeout=600
            ).stdout
        except subprocess.TimeoutExpired:
            lines.append("  TIMED OUT")
            continue
        for line in out.splitlines():
            if CHATTER.match(line):
                continue
            noisy = next((why for rx, why in NOISE if rx.match(line)), None)
            if noisy:
                ignored.append((os.path.basename(t), line.strip(), noisy))
                continue
            lines.append(line)
    return lines, ignored


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("before", "after"):
        print(__doc__)
        return 2

    lines, ignored = capture()
    os.makedirs(STORE, exist_ok=True)
    path = os.path.join(STORE, mode + ".txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    if ignored:
        print("ignored as run-to-run noise:")
        for test, line, why in ignored:
            print("  %-22s %s" % (test, line))
            print("  %-22s   ^ %s" % ("", why))
        print()

    if mode == "before":
        print("baseline captured: %d lines. Make the change, then: "
              "python tools/parity.py after" % len(lines))
        return 0

    prev = os.path.join(STORE, "before.txt")
    if not os.path.exists(prev):
        print("no baseline. Run `python tools/parity.py before` first.")
        return 2
    with open(prev, encoding="utf-8") as f:
        old = f.read().split("\n")

    if old == lines:
        print("PARITY: %d lines, byte-identical. Nothing observable changed."
              % len(lines))
        return 0

    print("DIFFERENCES -- this is not a pure refactor:")
    import difflib
    for d in difflib.unified_diff(old, lines, "before", "after", lineterm="", n=1):
        print("  " + d)
    return 1


if __name__ == "__main__":
    sys.exit(main())
