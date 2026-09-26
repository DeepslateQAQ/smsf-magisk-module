#!/usr/bin/env python3
"""Fail if two test harnesses can pick the same port.

Every harness takes its ports from a per-run band (base + $$ % width) so that
concurrent runs -- or a leftover process from an earlier one -- cannot clobber
each other. An overlap between two harnesses only ever shows up as mysterious
cross-talk inside an unrelated suite, so it is checked here instead.
"""
import glob
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

ASSIGN = re.compile(r'^\s*([A-Z_]*PORT[A-Z_]*)="\$\{\w+:-([^}]*)\}"')
SWEEP = re.compile(r'^\$\(\((\d+) \+ \$\$ % (\d+)\)\)$')
NUMBER = re.compile(r'^(\d+)$')
PLUS_ONE = re.compile(r'^\$\(\((\w+PORT) \+ 1\)\)$')
PLUS_ONE_LINE = re.compile(r'([A-Z_]*PORT[A-Z_]*)="\$\(\((\w+PORT) \+ 1\)\)"')


def bands_of(path):
    """[(name, lo, hi)] for one harness, with +1 follow-ups resolved."""
    fixed, sweep, pending = [], [], []
    derived_lines = []
    for line in open(path):
        plus = PLUS_ONE_LINE.search(line)
        if plus:
            derived_lines.append(plus.groups())
        match = ASSIGN.match(line)
        if not match:
            continue
        name, expr = match.group(1), match.group(2)
        number = NUMBER.match(expr)
        if number:
            value = int(number.group(1))
            fixed.append([name, value, value])
            continue
        band = SWEEP.match(expr)
        if band:
            base, width = int(band.group(1)), int(band.group(2))
            sweep.append([name, base, base + width - 1])
            continue
    bands = fixed + sweep
    # ports expressed as another one + 1 (e.g. BAD_PORT) are not defaults
    for name, source in pending + derived_lines:
        src = [b for b in bands if b[0] == source]
        if src:
            bands.append([name, src[-1][2] + 1, src[-1][2] + 1])
    return bands


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else str(REPO / "tests")
    all_bands = []
    harnesses = set()
    declaring = 0
    unparsed = 0
    for path in sorted(glob.glob(root + "/test_*.sh")):
        bands = bands_of(path)
        assigns_ports = "PORT" in open(path).read()
        if assigns_ports:
            declaring += 1
            if not bands:
                print("unparsed: %s assigns a PORT but yielded no band" % path)
                unparsed += 1
        for name, lo, hi in bands:
            all_bands.append((path, name, lo, hi))
            harnesses.add(path)

    if unparsed:
        return 1
    # A checker that silently reads nothing must not report success: every harness
    # that declares a port must have produced a band. (test_install.sh declares
    # none, so it is not part of the floor.)
    if len(all_bands) < declaring:
        print("too few bands parsed: %d for %d harnesses that declare ports"
              % (len(all_bands), declaring))
        return 1

    overlaps = 0
    for i, a in enumerate(all_bands):
        for b in all_bands[i + 1:]:
            if a[2] <= b[3] and b[2] <= a[3]:
                print("overlap: %s %s [%d-%d] vs %s %s [%d-%d]"
                      % (a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]))
                overlaps += 1
    if overlaps:
        return 1
    for path, name, lo, hi in all_bands:
        print("  %-24s %-12s %d-%d" % (path.replace("tests/", ""), name, lo, hi))
    print("ports ok: %d bands across %d harnesses, all disjoint"
          % (len(all_bands), len(harnesses)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
