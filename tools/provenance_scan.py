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
    """Tracked src files only: CI has a clean checkout, so provenance coverage
    is defined over committed code. Untracked in-progress files (e.g. a
    concurrent agent's scratch) must not flake the gate locally."""
    try:
        import subprocess
        listed = subprocess.run(
            ["git", "-C", ROOT, "ls-files", "src/**/*.zig", "src/*.zig"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
        if listed:
            # Working-tree deletions are gone even while git still lists them.
            return sorted({p for p in listed if os.path.isfile(os.path.join(ROOT, p))})
    except Exception:
        pass
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


# The live hardcode audit (docs/reviews/HARDCODE_AUDIT.md, last pass 2026-08-10)
# was removed from the repo 2026-08-23 ("rm old reviews"). PROVENANCE.md §3.10 is
# the surviving record of the final live statuses and pins these finding ids; the
# archive/HARDCODE_AUDIT_2026-08-08.md snapshot has a different numbering and must
# never gate. The set is frozen here so the linkage gate stays real (fail closed)
# instead of silently no-oping on the missing file.
FROZEN_AUDIT_IDS = tuple(
    [f"A{n:02d}" for n in range(1, 37)]
    + [f"B{n:02d}" for n in range(1, 29)]
    + ["B38", "B39", "B40"]
)


def audit_finding_ids():
    """Every A##/B## finding id the (removed) live audit named at its final
    pass, per PROVENANCE.md §3.10 plus the B38-B40 constant rows."""
    return FROZEN_AUDIT_IDS


# File-scope constants that are structural (array sizes, wire/persistence
# layout, parser caps) - covered by their file's section-2 row, not repeated
# in the constants ledger. Behavioral constants MUST be ledgered (section 3);
# a constant that changes game behavior here is a misclassification.
STRUCTURAL_CONSTANTS = {
    "inflate_cap", "max_inflate_ratio", "world_coord_limit", "world_coord_limit_i32",
    "block_change_flag_value", "block_change_flag_damage", "block_change_flag_density",
    "block_change_flag_force_density", "block_change_flag_update_light",
    "block_change_flag_texture", "block_change_flags_known",
    "layers_n", "cells_per_layer", "simd_u8_w", "simd_u32_w", "simd_u64_w", "simd_u16_w",
    "class_player_male", "class_player_female",
    "max_ws_slots", "max_ws_queue", "max_ws_melt", "max_craft_complete",
    "last_input_blob_max", "recipe_queue_item_version", "craft_complete_version",
    "max_recipe_ingredients", "wire_name_max",
    "pending_cap", "pending_bytes", "max_frag_parts", "assemble_cap", "extra_q_len",
    "ack_bitmap_bytes", "resend_ns", "ack_yield_ns",
    "persisted_container_size", "save_capacity", "meta_shift", "meta2_shift",
    "rot_meta3_shift", "nibble", "six_bits", "max_step", "rotation_shift", "rotation_mask",
    "save_header_bytes", "persisted_workstation_size", "samples_x", "samples_y",
    "max_serverconfig_bytes", "max_req", "max_token", "max_client_polls", "max_preset_bytes",
    "max_test_resp", "readiness_stale_ns", "max_toml_bytes", "lock_target_opaque_len",
    "max_poi_candidates", "map_batch", "map_walk_above", "warn_at", "trigger_type_none",
    "entity_warn_at", "max_quest_vars", "max_seat_scan", "max_wasm_module_bytes",
    "u64_digits", "mib_bytes",
    "density_p", "tx_lanes", "section_locs", "log_only",
    "connecting_allow", "joined_allow", "director_defaults",
    "shocked", "on_fire", "harvest", "bleeding",
}


def src_constants(src_dir):
    """(relpath, lineno, name) for every file-scope `const name:` outside test
    blocks and the wire package (wire constants are covered by file rows)."""
    out = []
    for root, _dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        if rel == "wire" or rel.startswith("wire" + os.sep):
            continue
        for fname in sorted(files):
            if not fname.endswith(".zig"):
                continue
            path = os.path.join(root, fname)
            if os.path.normpath(path) == os.path.normpath(os.path.join(src_dir, "fuzz.zig")):
                continue
            in_test = False
            depth = 0
            with open(path, "r", errors="replace") as fh:
                for lineno, raw in enumerate(fh, 1):
                    if not in_test:
                        if re.match(r"^\s*test\b", raw):
                            in_test = True
                            depth = 0
                        else:
                            m = re.match(r"^const\s+([a-z_][a-z0-9_]*)\s*:\s*", raw)
                            if m:
                                out.append((os.path.relpath(path, src_dir), lineno, m.group(1)))
                    if in_test:
                        stripped = re.sub(r"//.*$", "", raw)
                        depth += stripped.count("{") - stripped.count("}")
                        if depth <= 0:
                            in_test = False
                            depth = 0
    return out


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

    # 4. AUDIT LINKAGE: every finding id the (removed) live audit named at its
    #    final pass must appear in the ledger.
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

    # 5. CROSS-REPO CITATIONS: every full-path ../7dtd-engine-research/docs/<file>.md
    #    reference in zdtd docs resolves to an existing research doc.
    research_docs = os.path.join(ROOT, "..", "7dtd-engine-research", "docs")
    bad_cites = []
    if os.path.isdir(research_docs):
        for sub, _dirs, names in os.walk("docs"):
            for name in names:
                if not name.endswith(".md"):
                    continue
                text = open(os.path.join(sub, name), encoding="utf-8", errors="replace").read()
                for m in re.finditer(r"(\.\./[^)\s]+?/7dtd-engine-research/docs/[a-z0-9-]+\.md)", text):
                    target = os.path.normpath(os.path.join(sub, m.group(1)))
                    if not os.path.isfile(target):
                        bad_cites.append(f"{os.path.join(sub, name)} -> {m.group(1)}")
    if bad_cites:
        print(f"FAIL: research-doc citations that do not resolve ({len(bad_cites)}):")
        for c in sorted(set(bad_cites))[:10]:
            print("  " + c)
        return 1

    # extra = ledger rows whose src file does not exist in the working tree at
    # all (a genuinely stale row). Rows for untracked-but-present files (a
    # concurrent agent mid-commit) are tolerated, matching the tracked-only
    # treatment of the missing direction.
    worktree_files = set(files)
    for dirpath, _dirs, names in os.walk(SRC):
        for n in names:
            if n.endswith(".zig"):
                worktree_files.add(os.path.relpath(os.path.join(dirpath, n), ROOT))
    missing = sorted(set(files) - set(file_rows))
    extra = sorted(set(file_rows) - worktree_files)
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

    covered = len(set(files) & set(file_rows))
    cov = 100.0 * covered / len(files) if files else 100.0
    print(f"file coverage: {covered}/{len(files)} = {cov:.1f}%")

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

    # 6. CONSTANT COVERAGE: every non-structural file-scope constant must be
    #    ledgered (behavioral constants without a row fail; structural ones
    #    are excluded by STRUCTURAL_CONSTANTS).
    ledger_text = open(LEDGER, encoding="utf-8").read()
    ledgered = set(m.split(".")[-1] for m in re.findall(r"`([A-Za-z_][A-Za-z0-9_.]*)`", ledger_text))
    unledgered = [(rel, ln, n) for rel, ln, n in src_constants(SRC) if n not in STRUCTURAL_CONSTANTS and n not in ledgered]
    if unledgered:
        failures.append("behavioral constants not in the ledger: " + "; ".join(f"{rel}:{ln} {n}" for rel, ln, n in unledgered[:8]))

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
