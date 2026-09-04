#!/usr/bin/env python3
"""Swap-mutation check for the positional wire builders.

A stock package body carries no field names: the client reads it by position,
so the field order IS the contract. A test that only asserts a length, a
version int, or "not empty" cannot see a reordering, and four of those slipped
through review by hand (GameStats slots 4..7, PlayerProfile names, and two
more) because the neighbouring fields shared a value: swapping two adjacent
writes of the same type and the same constant emits identical bytes, so the
test passes either way and proves nothing.

This finds them mechanically. For every adjacent pair of same-width writes in a
builder, swap the two lines, run the suite, and record whether anything failed.
A surviving mutant means no test distinguishes those two positions.

Usage:
  python3 tools/wire_order_mutants.py [--file src/wire/packages.zig] [--limit N]
  python3 tools/wire_order_mutants.py --list      # show mutants, run nothing

Not part of `make check`: a full run is one `zig build test` per mutant and
takes hours. It is a periodic audit tool, run when a positional builder gains
fields.

**Run it alone, and never read the source while it runs.** It edits files in
src/wire/ in place and restores each one before moving on, so a `zig build`,
`make check`, or editor save at the same time either compiles a mutated tree or
races the restore. Interrupting it mid-mutant leaves one swap behind: check
`git diff src/wire/` afterwards. It refuses to start on a dirty tree for the
same reason - a pre-existing edit is indistinguishable from a leftover mutation.

The subtler trap is reading the code while it runs. A `[SURVIVED]` line names a
pair by file and line, and the obvious next step is to open that file - which,
mid-run, shows some *other* mutant in place. That reads as a real ordering bug
and it is not one. Always diff a survivor against `git show HEAD:<file>` before
believing it; a genuine finding is a gap in the *tests*, and the code at HEAD is
usually correct.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIRE = os.path.join(ROOT, "src", "wire")

# Writer calls whose wire width is fixed by the method name. Two adjacent
# writes are swap-safe to test only when both sides encode the same width:
# swapping a u8 with an i32 shifts every later field and any length assertion
# catches it, which is not the blind spot being hunted.
WIDTH = {
    "writeByte": 1,
    "writeBool": 1,
    "writeU16": 2,
    "writeI16": 2,
    "writeU32": 4,
    "writeI32": 4,
    "writeF32": 4,
    "writeI64": 8,
    "writeU64": 8,
}
WRITE_RE = re.compile(r"^(\s*)try w\.(write\w+)\(([^;]*)\);\s*(//.*)?$")

# How many pairs filter_is_live() may try before declaring a filter useless.
# One kill proves the filter reaches the file; a run of survivors at the top of
# a file is a real finding, not a reason to refuse.
PROBE_PAIRS = 8


def mutants_for(path):
    """Yield (line_index, description) for each swappable adjacent pair."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    out = []
    for i in range(len(lines) - 1):
        a = WRITE_RE.match(lines[i])
        b = WRITE_RE.match(lines[i + 1])
        if not a or not b:
            continue
        if a.group(2) not in WIDTH or b.group(2) not in WIDTH:
            continue
        # Same width only: a differing width is caught by any length check.
        if WIDTH[a.group(2)] != WIDTH[b.group(2)]:
            continue
        # Identical argument text means the swap is a no-op on the bytes.
        # Those pairs are unobservable by construction, not a test gap.
        if a.group(3).strip() == b.group(3).strip():
            continue
        out.append((i, f"{a.group(2)}({a.group(3).strip()}) <-> {b.group(2)}({b.group(3).strip()})"))
    return lines, out


def run_suite(test_filter=None):
    """True when the test suite passes.

    With a filter the run is ~90x faster (2.6 s against 4 min), which is the
    difference between auditing a file and auditing the tree. The filter is a
    loaded gun: `zig build test` exits 0 when a filter matches nothing, so a
    typo would report every mutant as killed by a suite that ran no tests.
    Callers must prove the filter selects something first - see
    filter_is_live().
    """
    cmd = ["zig", "build", "test"]
    if test_filter:
        cmd.append(f"-Dtest-filter={test_filter}")
    r = subprocess.run(
        cmd,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return r.returncode == 0


def filter_is_live(test_filter, path, lines, mutants):
    """True when `test_filter` selects a test that the file under audit can fail.

    A filter matching nothing exits 0, and so would every mutant after it, so
    the report would read "all killed" from a suite that ran no tests. Proving
    otherwise needs a probe that the filtered tests actually execute.

    An appended `@compileError` does not work: Zig never evaluates it in code
    nothing references, and the filtered build exits 0 with the file broken.
    The probe here is the tool's own mutation applied to the first candidate
    pair. If the filtered suite cannot notice a swapped field there, it cannot
    judge any other pair in the file either.
    """
    if not mutants:
        return False
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    # Try several pairs, not just the first: a leading pair may be a genuine
    # test gap, and refusing to run on that would hide the very finding the
    # audit exists for. One kill anywhere proves the filter reaches this file.
    try:
        for idx, _desc in mutants[:PROBE_PAIRS]:
            probe = list(lines)
            probe[idx], probe[idx + 1] = probe[idx + 1], probe[idx]
            with open(path, "w", encoding="utf-8") as fh:
                fh.writelines(probe)
            if not run_suite(test_filter):
                return True
        return False
    finally:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)


def wire_tree_dirty():
    """Uncommitted changes under src/wire, as a list of paths."""
    r = subprocess.run(
        ["git", "status", "--porcelain", "--", "src/wire"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        return []  # not a git checkout: nothing to protect
    return [ln[3:] for ln in r.stdout.splitlines() if ln.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="single file under src/wire (default: all)")
    ap.add_argument("--limit", type=int, default=0, help="stop after N mutants")
    ap.add_argument("--list", action="store_true", help="list mutants, run nothing")
    ap.add_argument(
        "--test-filter",
        help=(
            "run only tests whose name contains this substring (~90x faster). "
            "Requires --file: the filter has to match tests covering the file "
            "under audit, and it is probed for liveness before any mutant runs"
        ),
    )
    args = ap.parse_args()

    if args.test_filter and not args.file:
        print("--test-filter requires --file", file=sys.stderr)
        return 2

    # Refuse to mutate a dirty tree: an interrupted earlier run leaves one swap
    # behind, and it would be indistinguishable from a real edit. Listing is
    # read-only and always allowed.
    if not args.list:
        dirty = wire_tree_dirty()
        if dirty:
            print("refusing to run: uncommitted changes under src/wire", file=sys.stderr)
            for p in dirty:
                print("  " + p, file=sys.stderr)
            print(
                "commit, stash, or restore them first (an interrupted run "
                "leaves exactly one swapped pair behind)",
                file=sys.stderr,
            )
            return 2

    if args.file:
        targets = [os.path.join(ROOT, args.file)]
    else:
        targets = [
            os.path.join(WIRE, n) for n in sorted(os.listdir(WIRE)) if n.endswith(".zig")
        ]

    # Prove the filter can fail before trusting any result from it. Without
    # this a mistyped filter selects nothing, every run exits 0, and the report
    # reads "all killed" from a suite that tested nothing.
    if args.test_filter and not args.list:
        probe_lines, probe_muts = mutants_for(targets[0])
        if not filter_is_live(args.test_filter, targets[0], probe_lines, probe_muts):
            print(
                f"refusing to run: --test-filter {args.test_filter!r} selects no "
                f"test that fails for any of the first {PROBE_PAIRS} swapped pairs "
                f"in {os.path.relpath(targets[0], ROOT)}, so every mutant would be "
                "reported killed by a suite that never exercised the file",
                file=sys.stderr,
            )
            return 2

    total = 0
    survived = []
    for path in targets:
        lines, muts = mutants_for(path)
        rel = os.path.relpath(path, ROOT)
        if args.list:
            for idx, desc in muts:
                print(f"{rel}:{idx + 1}: {desc}")
            total += len(muts)
            continue

        for idx, desc in muts:
            if args.limit and total >= args.limit:
                break
            total += 1
            backup = tempfile.mktemp(suffix=".zig")
            shutil.copyfile(path, backup)
            try:
                swapped = list(lines)
                swapped[idx], swapped[idx + 1] = swapped[idx + 1], swapped[idx]
                with open(path, "w", encoding="utf-8") as fh:
                    fh.writelines(swapped)
                passed = run_suite(args.test_filter)
            finally:
                shutil.copyfile(backup, path)
                os.unlink(backup)
            mark = "SURVIVED" if passed else "killed"
            print(f"[{mark}] {rel}:{idx + 1}: {desc}", flush=True)
            if passed:
                survived.append(f"{rel}:{idx + 1}: {desc}")

    if args.list:
        print(f"\n{total} swappable adjacent pairs")
        return 0

    print(f"\n{total} mutants, {len(survived)} survived")
    if survived:
        print("\nNo test distinguishes these positions:")
        for s in survived:
            print("  " + s)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
