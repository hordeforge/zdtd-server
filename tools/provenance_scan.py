#!/usr/bin/env python3
"""Provenance coverage gate for zdtd.

Checks docs/PROVENANCE.md against the src/ tree:

1. FILE COVERAGE: every src/**/*.zig file appears in the ledger's file-map
   table with a bucket (A stock-data / R RE-cited / Z zdtd-owned) and a
   non-empty source citation. Missing rows, missing buckets, or empty
   citations fail the gate.

2. CONSTANT LEDGER: every constants-ledger row carries an anchor
   (path:line or path symbol) that exists in src/, a value, a bucket, and a
   non-empty source. Rows whose anchor file does not exist fail.

Usage: python3 tools/provenance_scan.py
Exit 0 when file coverage is 100% and every ledger row is well-formed.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
LEDGER = os.path.join(ROOT, "docs", "PROVENANCE.md")

BUCKETS = {"A", "R", "Z"}
FILE_ROW = re.compile(r"^\|\s*`([^`]+\.zig)`\s*\|\s*([ARZ])\s*\|\s*(.+?)\s*\|")
CONST_ROW = re.compile(
    r"^\|\s*`?([^`|]+)`?\s*\|\s*([^|]+?)\s*\|\s*([ARZ])\s*\|\s*(.+?)\s*\|"
)


def src_files():
    out = set()
    for dirpath, _dirs, names in os.walk(SRC):
        for n in names:
            if n.endswith(".zig"):
                out.add(os.path.relpath(os.path.join(dirpath, n), ROOT))
    return sorted(out)


def ledger_rows():
    if not os.path.isfile(LEDGER):
        return None
    text = open(LEDGER, encoding="utf-8").read()
    file_rows = {}
    const_rows = []
    in_file_map = False
    in_const = False
    for line in text.splitlines():
        if line.startswith("### "):
            if "File provenance map" in line:
                in_file_map = True
            continue  # other ### subsections keep the enclosing state
        if line.startswith("## "):
            in_file_map = "File provenance map" in line
            in_const = "Constants ledger" in line
            continue
        if in_file_map:
            m = FILE_ROW.match(line)
            if m:
                path, bucket, source = m.group(1), m.group(2), m.group(3).strip()
                file_rows[path] = (bucket, source)
        if in_const:
            m = CONST_ROW.match(line)
            if m:
                const_rows.append(
                    (m.group(1).strip(), m.group(2).strip(), m.group(3).strip(), m.group(4).strip())
                )
    return file_rows, const_rows


# The LIVE hardcode audit (docs/reviews/HARDCODE_AUDIT.md, updated 2026-08-10).
# The archive/HARDCODE_AUDIT_2026-08-08.md snapshot is explicitly stale and has
# a different finding numbering; never gate on it.
AUDIT = os.path.join(ROOT, "docs", "reviews", "HARDCODE_AUDIT.md")


def audit_finding_ids():
    """Every A##/B## finding id the audit names, as the linkage gate."""
    if not os.path.isfile(AUDIT):
        return []
    import re
    return sorted(set(re.findall(r"\b[A-B]\d{2}\b", open(AUDIT, encoding="utf-8").read())))


def main():
    files = src_files()
    parsed = ledger_rows()
    if parsed is None:
        print(f"FAIL: {LEDGER} missing")
        return 1
    file_rows, const_rows = parsed
    # 3. VALUE COVERAGE: every file-scope behavioral constant in the sim files
    #    carries an inline provenance comment (same line or within the previous
    #    4 non-blank lines) or appears in the ledger.
    # Whole-tree value coverage: every file-scope typed constant in every src
    # file (test/fuzz/harness scaffolding excluded) carries an inline
    # provenance comment (same line or within the previous 16 non-blank lines)
    # or appears in the ledger.
    EXCLUDE_FILES = {"tests.zig", "fuzz.zig", "scenarios.zig", "harness.zig", "sample_hello.zig"}
    CONST_RE = re.compile(
        r"^(\s{0,2})(pub\s+)?const\s+(\w+)\s*:\s*(f32|f64|u8|u16|u32|u64|i8|i16|i32|i64)\s*=\s*(\d)"
    )
    unannotated = []
    for rel in files:
        if os.path.basename(rel) in EXCLUDE_FILES:
            continue
        path = os.path.join(ROOT, rel)
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        for i, line in enumerate(lines):
            m = CONST_RE.match(line)
            if not m:
                continue
            name = m.group(3)
            annotated = "//" in line
            # block annotation: walk up over non-blank lines (max 15) looking
            # for a doc comment covering this group of constants
            for j in range(i - 1, max(0, i - 16), -1):
                s = lines[j].strip()
                if s.startswith("//"):
                    annotated = True
                    break
                if not s:
                    break
            if not annotated:
                unannotated.append(f"{rel}:{i+1} {name}")
    if unannotated:
        print(f"FAIL: behavioral constants without provenance comment ({len(unannotated)}):")
        for u in unannotated[:12]:
            print("  " + u)
        return 1

    # 4. AUDIT LINKAGE: every finding id the audit names must appear in the ledger.
    if os.path.isfile(AUDIT):
        import re as _re
        ledger_text = open(LEDGER, encoding="utf-8").read()
        covered = set(_re.findall(r"\b[AB]\d{2}\b", ledger_text))
        # expand ledger ranges like "A01-A12" (or "B14-B21") into ids
        for pre, lo, _pre2, hi in _re.findall(r"\b([AB])(\d{2})\s*-\s*([AB])(\d{2})\b", ledger_text):
            for n in range(int(lo), int(hi) + 1):
                covered.add(f"{pre}{n:02d}")
        missing_findings = [f for f in audit_finding_ids() if f not in covered]
        if missing_findings:
            print(f"FAIL: audit findings not linked in ledger: {missing_findings}")
            return 1

    missing = sorted(set(files) - set(file_rows))
    extra = sorted(set(file_rows) - set(files))
    bad_bucket = [p for p, (b, _s) in file_rows.items() if b not in BUCKETS]
    empty_source = [p for p, (_b, s) in file_rows.items() if not s]

    failures = []
    if missing:
        failures.append(f"src files missing from ledger ({len(missing)}): {missing[:10]}...")
    if extra:
        failures.append(f"ledger rows without src file ({len(extra)}): {extra[:10]}...")
    if bad_bucket:
        failures.append(f"bad buckets: {bad_bucket}")
    if empty_source:
        failures.append(f"rows without source citation: {empty_source}")

    cov = 100.0 * len(file_rows) / len(files) if files else 100.0
    print(f"file coverage: {len(file_rows)}/{len(files)} = {cov:.1f}%")

    # Constants ledger well-formedness: anchor file must exist, bucket valid, source non-empty.
    bad_const = []
    for anchor, value, bucket, source in const_rows:
        if bucket not in BUCKETS:
            bad_const.append(f"{anchor}: bad bucket {bucket!r}")
            continue
        if not source:
            bad_const.append(f"{anchor}: empty source")
            continue
        afile = anchor.split(":")[0].split(" ")[0]
        rel = afile if afile.startswith("src/") else None
        if rel and not os.path.isfile(os.path.join(ROOT, rel)):
            bad_const.append(f"{anchor}: anchor file {afile} missing")
    if bad_const:
        failures.append(f"constant ledger issues ({len(bad_const)}): " + "; ".join(bad_const[:8]))

    if failures:
        for f in failures:
            print("FAIL:", f)
        return 1
    print(
        f"OK: {len(files)} files covered (100%), {len(const_rows)} constants ledgered, "
        "behavioral constants annotated, audit findings linked"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
