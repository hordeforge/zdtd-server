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
import argparse
import os
import pathlib
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
    "persisted_container_size", "persisted_sign_size", "save_capacity", "meta_shift", "meta2_shift",
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
    "max_net_polls_per_tick", "max_info_polls_per_tick", "max_webui_polls_per_tick",
    "basket_record_max", "zen_rec_basket", "owner_record_max", "zen_rec_owner",
    "power_record_bytes", "zen_rec_power", "bag_record_max", "zen_rec_bag",
    "zen_rec_supply_crate", "zen_rec_backpack",
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


def research_citation_errors(root, research_docs):
    root = pathlib.Path(root)
    research_docs = pathlib.Path(research_docs)
    citation = re.compile(
        r"7dtd-engine-research/docs/"
        r"([A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.md)"
    )
    errors = []
    for directory, pattern in (("docs", "*.md"), ("src", "*.zig")):
        for path in sorted((root / directory).rglob(pattern)):
            text = path.read_text(encoding="utf-8")
            for line_number, line in enumerate(text.splitlines(), 1):
                for match in citation.finditer(line):
                    if not (research_docs / match.group(1)).is_file():
                        errors.append(
                            f"{path.relative_to(root)}:{line_number} -> "
                            f"7dtd-engine-research/docs/{match.group(1)}"
                        )
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--research-root", type=pathlib.Path,
        help="research repository path (default: sibling 7dtd-engine-research)",
    )
    args = parser.parse_args()
    research_root = args.research_root or pathlib.Path(ROOT).parent / "7dtd-engine-research"
    research_docs = research_root / "docs"
    if args.research_root is not None and not research_docs.is_dir():
        parser.error(f"research docs directory missing: {research_docs}")
    files = src_files()
    parsed = ledger_rows()
    if parsed is None:
        print(f"FAIL: {LEDGER} missing", file=sys.stderr)
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
        print(
            f"FAIL: behavioral constants without provenance comment ({len(unannotated)}):",
            file=sys.stderr,
        )
        for u in unannotated[:12]:
            print("  " + u, file=sys.stderr)
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
        print(
            f"FAIL: audit findings not linked in ledger: {missing_findings}",
            file=sys.stderr,
        )
        return 1

    # 5. CROSS-REPO CITATIONS: every full-path ../7dtd-engine-research/docs/<file>.md
    #    reference in zdtd docs resolves to an existing research doc.
    bad_cites = []
    if research_docs.is_dir():
        bad_cites = research_citation_errors(ROOT, research_docs)
    else:
        print(
            f"SKIP: research citations not checked (missing {research_docs})",
            file=sys.stderr,
        )
    if bad_cites:
        print(
            f"FAIL: research-doc citations that do not resolve ({len(bad_cites)}):",
            file=sys.stderr,
        )
        for c in sorted(set(bad_cites))[:10]:
            print("  " + c, file=sys.stderr)
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

    # 7b. BUILDER RE CITATIONS. AGENTS rule 16: field order, types and lengths
    #     come from the RE, so every body builder in src/wire/ names its source.
    #     This started
    #     as a ratchet at 34 (2026-09-04) and reached 0 the same day; it is now a
    #     hard rule, since a new builder that cannot say where its layout comes
    #     from has not been checked against stock. A builder whose body is
    #     deliberately zdtd's own says so instead ("not a stock layout"), which
    #     is the other honest answer. Citing a builder is also what makes an
    #     automated field-order diff against inventories/netpackage-bodies.md
    #     possible, which is how a layout regression gets caught rather than
    #     reasoned about.
    MAX_UNCITED_BUILDERS = 0
    uncited = []
    for wire_name in sorted(os.listdir(os.path.join(ROOT, "src/wire"))):
        if not wire_name.endswith(".zig"):
            continue
        builder_src = open(
            os.path.join(ROOT, "src/wire", wire_name), encoding="utf-8"
        ).read()
        cited_builders = set()
        for m in re.finditer(
            r"((?:^///[^\n]*\n)+)pub fn (build\w+)\(", builder_src, re.M
        ):
            doc = m.group(1)
            if (
                "NetPackage" in doc
                or "asm.il" in doc
                or "IL=" in doc
                or "RE " in doc
                or "not a stock" in doc
                or "not the stock" in doc
            ):
                cited_builders.add(m.group(2))
        all_builders = set(re.findall(r"pub fn (build\w+)\(", builder_src))
        uncited += [f"{wire_name}:{b}" for b in sorted(all_builders - cited_builders)]
    if len(uncited) > MAX_UNCITED_BUILDERS:
        failures.append(
            f"body builders without an RE citation: {len(uncited)} "
            f"({', '.join(uncited[:6])}) - cite the "
            "RE source in the doc comment (AGENTS rule 16)"
        )

    # 7c. PARSER RE CITATIONS. Same rule as 7b for the read side, and the read
    #     side is the one that touches untrusted bytes: a parser whose field
    #     order is wrong desyncs the reader on a body a client really sends.
    #     Went 37 -> 0 on 2026-09-04 and is now a hard rule, like the builders.
    #     Citing them is not bookkeeping: writing the citation for
    #     parseCollectBody found that the field naming the collector was never
    #     read, and the sweep of the parsers with no builder twin found the
    #     EntityRadius scale error and the TraderData length overlap.
    MAX_UNCITED_PARSERS = 0
    uncited_parsers = []
    for wire_name in sorted(os.listdir(os.path.join(ROOT, "src/wire"))):
        if not wire_name.endswith(".zig"):
            continue
        psrc = open(os.path.join(ROOT, "src/wire", wire_name), encoding="utf-8").read()
        cited_p = set()
        for m in re.finditer(r"((?:^///[^\n]*\n)+)pub fn (parse\w+)\(", psrc, re.M):
            doc = m.group(1)
            if (
                "NetPackage" in doc
                or "asm.il" in doc
                or "IL=" in doc
                or "RE " in doc
                or "not a stock" in doc
                or "not the stock" in doc
            ):
                cited_p.add(m.group(2))
        all_p = set(re.findall(r"pub fn (parse\w+)\(", psrc))
        uncited_parsers += [f"{wire_name}:{p}" for p in sorted(all_p - cited_p)]
    if len(uncited_parsers) > MAX_UNCITED_PARSERS:
        failures.append(
            f"body parsers without an RE citation: {len(uncited_parsers)} "
            f"({', '.join(uncited_parsers[:6])}) - cite the "
            "RE source in the doc comment (AGENTS rule 16)"
        )

    # 7. PACKAGE EMISSION COVERAGE: every registered stock package name the
    #    server never references must be accounted for in the docs. Registering
    #    a name without a sender is legitimate (the negotiated name-to-id map
    #    must match stock either way), but it has to be a recorded decision
    #    rather than an oversight: a wire package we silently never send is the
    #    exact shape of gap this project keeps finding. See DIVERGENCES 3b.
    pkg_src = open(os.path.join(ROOT, "src/wire/packages.zig"), encoding="utf-8").read()
    registered = sorted(set(re.findall(r'"(NetPackage\w+)"', pkg_src)))
    # 7a. The advertised map size is a load-bearing number (the client uses
    #     server-advertised ids), and the docs quoted a stale 189 against a file
    #     holding 191 for some time. Keep the two in step.
    mapping_m = re.search(
        r"pub const default_mappings = \[_\]\[\]const u8\{(.*?)\n\};", pkg_src, re.S
    )
    if mapping_m:
        n_mapped = len(re.findall(r'"(NetPackage\w+)"', mapping_m.group(1)))
        gap = open(os.path.join(ROOT, "docs/GAP_ANALYSIS.md"), encoding="utf-8").read()
        if not re.search(rf"PackageIds name table \({n_mapped} stock names", gap):
            failures.append(
                f"default_mappings has {n_mapped} names but the GAP_ANALYSIS "
                "'PackageIds name table (N stock names, exact set)' row disagrees "
                "- update the row when the map changes"
            )
    referenced = set()
    for dirpath, _dirs, names in os.walk(os.path.join(ROOT, "src/server")):
        for n in names:
            if not n.endswith(".zig"):
                continue
            text = open(os.path.join(dirpath, n), encoding="utf-8", errors="replace").read()
            referenced.update(re.findall(r'"(NetPackage\w+)"', text))
    doc_text = ""
    for doc in ("docs/GAP_ANALYSIS.md", "docs/DIVERGENCES.md"):
        doc_text += open(os.path.join(ROOT, doc), encoding="utf-8", errors="replace").read()
    # Checks 7d and 7i ask for a divergence-register row specifically, so they
    # read this file alone: a passing mention in the 6k-line GAP_ANALYSIS is
    # not the artifact either failure text is asking the author to write.
    divergences_text = open(
        os.path.join(ROOT, "docs/DIVERGENCES.md"), encoding="utf-8", errors="replace"
    ).read()
    never_sent = [n for n in registered if n not in referenced]
    undocumented = []
    for name in never_sent:
        short = name[len("NetPackage"):]
        if name in doc_text or re.search(rf"\b{re.escape(short)}\b", doc_text):
            continue
        undocumented.append(name)
    if undocumented:
        failures.append(
            "registered packages the server never sends and no doc mentions "
            f"({len(undocumented)}): " + ", ".join(undocumented[:8])
            + " - record the decision in DIVERGENCES 3b or GAP_ANALYSIS"
        )

    # 7d. ACCEPT-AND-DROP COVERAGE: the mirror of 7. A C2S handler that matches
    #     a stock package, mutates nothing and returns is a deliberate refusal
    #     to reproduce stock behaviour, and that is a divergence whether or not
    #     the refusal is right. Two of these (AddVelocity, DropItemsContainer)
    #     sat undocumented until 2026-09-04, both with the reasoning present at
    #     the code site but absent from the page a reader checks. Require the
    #     package name to appear in the docs.
    drop_undocumented = []
    c2s_dir = os.path.join(ROOT, "src/server/c2s")
    for fname in sorted(os.listdir(c2s_dir)):
        if not fname.endswith(".zig"):
            continue
        text = open(os.path.join(c2s_dir, fname), encoding="utf-8", errors="replace").read()
        for m in re.finditer(
            r'if \(std\.mem\.eql\(u8, name, "(NetPackage\w+)"\)\)(.*?)'
            r'(?=\n    if \(std\.mem\.eql|\Z)',
            text,
            re.S,
        ):
            pkg, body = m.group(1), m.group(2)
            # `self.<anything>(` covers the helper-call form (handleQuestEvent,
            # savePlayers, dropClientSlot); the old fixed subsystem list read
            # four real mutators as silent drops. `c.<field> =` covers the
            # per-client state a handler writes directly (MapPosition's middle).
            mutates = re.search(
                r"self\.\w+[.(]|c\.\w+ = |broadcast|sendGame|relayBody|send\w+\(",
                body.replace("self.harness.counters.inc", "__counter"),
            )
            if mutates:
                continue
            # DIVERGENCES only: the failure text asks for a register row, and
            # a short-name word match anywhere in GAP_ANALYSIS is not one.
            if pkg in divergences_text:
                continue
            drop_undocumented.append(f"{fname}:{pkg}")
    if drop_undocumented:
        failures.append(
            "C2S handlers that accept a stock package and drop it, with no doc "
            f"row ({len(drop_undocumented)}): " + ", ".join(drop_undocumented[:8])
            + " - add the stock behaviour and the reason to DIVERGENCES 1"
        )

    # 7e. NO-TRUTHFUL-VALUE FIELDS: DIVERGENCES 2 names the wire fields zdtd
    #     sends as 0 because it drops the client blob stock relays, and says
    #     synthesising them would invent numbers stock never derived
    #     server-side. That promise lives only in prose: nothing stopped a
    #     later change from writing an accumulator into one of those fields and
    #     leaving the page claiming otherwise. Read the field names out of the
    #     doc and require each one to still be written as a literal 0.
    #
    #     The doc is the source of the list, so removing a field there is the
    #     way to stop asserting it - which is correct, because that removal is
    #     exactly the edit a reviewer should see.
    div_path = os.path.join(ROOT, "docs", "DIVERGENCES.md")
    zero_field_violations = []
    if os.path.isfile(div_path):
        div_text = open(div_path, encoding="utf-8", errors="replace").read()
        sec = re.search(
            r"^## 2\. Fields with no truthful server-side value(.*?)^## ",
            div_text,
            re.S | re.M,
        )
        if sec:
            body_text = sec.group(1)
            # The section ends with an explicit carve-out ("Not in this group:
            # killedZombies and killedPlayers ... do ride the wire"). Those are
            # named to say the opposite, so reading the whole section for field
            # names would assert exactly what it denies.
            carve = re.search(r"^Not in this group:(.*)$", body_text, re.S | re.M)
            excluded = set(re.findall(r"`(\w+)`", carve.group(1))) if carve else set()
            if carve:
                body_text = body_text[: carve.start()]
            claimed = set(re.findall(r"`(\w+)`", body_text)) - excluded
            # Only names that are actually written somewhere in src/wire.
            xp_path = os.path.join(ROOT, "src/wire/stock_xp.zig")
            xp_text = open(xp_path, encoding="utf-8", errors="replace").read()
            for field in sorted(claimed):
                # The write line carries the field name as a trailing comment.
                m = re.search(
                    rf"^\s*try w\.write\w+\(([^;]*)\);\s*//\s*{re.escape(field)}\b",
                    xp_text,
                    re.M,
                )
                if not m:
                    continue  # not a stock_xp field (e.g. killedZombies prose)
                if m.group(1).strip() != "0":
                    zero_field_violations.append(f"{field} = {m.group(1).strip()}")
    if zero_field_violations:
        failures.append(
            "DIVERGENCES 2 says these fields are sent as 0 for lack of a "
            f"truthful value, but they are not ({len(zero_field_violations)}): "
            + ", ".join(zero_field_violations)
            + " - either revert the value or move the field out of that section"
        )

    # 7f. AUDIT-TOOL SELF-CHECK. wire_order_mutants.py decides which swapped
    #     pairs are worth reporting, and its literal filter is the part that
    #     can go wrong silently: too loose and it drops real findings, too
    #     tight and it floods the report with pairs no test could ever
    #     distinguish. `make check` only byte-compiles tools/*.py, so pin the
    #     behaviour here where it actually runs.
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    try:
        from wire_order_mutants import literal_value
    except ImportError as e:
        failures.append(f"cannot import the mutation audit's literal filter: {e}")
    else:
        cases = [
            ("false", 0), ("true", 1), ("0", 0), ("-5", -5), ("0x10", 16),
            # Not literals: their value is unknowable here, so they must stay
            # reportable rather than be dropped as indistinguishable.
            ("v.game_difficulty", None), ('""', None), ("dens[0]", None),
        ]
        for arg, want in cases:
            got = literal_value(arg)
            if got != want:
                failures.append(
                    f"wire_order_mutants.literal_value({arg!r}) is {got!r}, want {want!r}"
                )

    # 7g. LENGTH GATES ON A TRUST BOUNDARY. A handler that picks between two
    #     body layouts by length is safe only when no stock body can reach the
    #     gate value, and a stock body's length is rarely fixed: it carries a
    #     PlatformUserIdentifier whose two strings vary with the account.
    #     parseSetBlockChanges keyed a legacy layout off `body.len == 14`, and a
    #     player on "Steam" with a 3-character id hit it exactly: an empty
    #     change list decoded as one change with x/y/z read out of the identity
    #     bytes. Only the reach check downstream kept that from being a world
    #     edit. The arithmetic that rules a collision out is what a reviewer
    #     needs and what nobody writes down, so require a comment near every
    #     length gate.
    length_gate_re = re.compile(r"\b(?:body|data|payload)\.len\s*(?:==|>=)\s*(\w+)")
    undocumented_gates = []
    for rel in ("src/server/c2s", "src/wire"):
        for dirpath, _dirs, names in os.walk(os.path.join(ROOT, rel)):
            for n in sorted(names):
                if not n.endswith(".zig"):
                    continue
                path = os.path.join(dirpath, n)
                lines = open(path, encoding="utf-8", errors="replace").readlines()
                in_test = False
                for i, line in enumerate(lines):
                    if line.startswith("test "):
                        in_test = True
                    elif in_test and line.startswith("}"):
                        in_test = False
                    if in_test or not length_gate_re.search(line):
                        continue
                    if "//" not in "".join(lines[max(0, i - 12):i + 3]):
                        undocumented_gates.append(f"{os.path.relpath(path, ROOT)}:{i + 1}")
    if undocumented_gates:
        failures.append(
            "length gates on a C2S/wire body with no nearby comment "
            f"({len(undocumented_gates)}): " + ", ".join(undocumented_gates[:8])
            + " - state which stock lengths are reachable and why they miss "
            "this gate (DIVERGENCES 3, 'prove the lengths cannot meet')"
        )

    # 7h. WIRE WRITERS OUTSIDE src/wire/. Both audit tools are scoped to
    #     src/wire/: wire_order_mutants.py only walks that directory, and the
    #     builder/parser coverage counts only name functions defined there. A
    #     stock body assembled anywhere else is invisible to both, which is how
    #     the empty NetPackageHoldingItem in game/join.zig carried a swappable
    #     entityId/count pair that no test could see - on the join path, sent
    #     to every client. Pin the known set: a new writer outside src/wire/
    #     must either move into a builder (AGENTS rule 14, one stock shape one
    #     builder) or be added here with the reason it cannot.
    allowed_wire_writers = {
        # Writes to disk, not to the wire.
        "src/server/persist.zig",
        # Test-only bodies: fixtures the tests feed themselves.
        "src/server/scenarios.zig",
        "src/server/game/tests.zig",
        "src/server/game/harness.zig",
        # Holds a Writer only to carry a buffer into writeHoldingItem; the
        # bytes are the builder's. Its two hand-rolled bodies are gone: the
        # empty HoldingItem now goes through writeHoldingItem and the
        # NameIdMapping payload through buildNameIdMappingPayload, both after
        # a hand mutation showed the suite could not see a swapped pair there.
        "src/server/game/join.zig",
        # The SharedQuest remove body on disconnect. Still open-coded, but a
        # party scenario catches a swapped pair (mutation-checked 2026-09-04),
        # and it is not a shape any builder already emits.
        "src/server/game/session_drop.zig",
        # Test-only Equipment.Write fixtures for applyEquipmentBody; production
        # paths only call apply* on client bodies (parse stays in wire/).
        "src/server/inv_apply.zig",
    }
    writer_re = re.compile(r"\b(?:wire_)?binary\.Writer\b")
    unexpected_writers = []
    for path in sorted(pathlib.Path(ROOT, "src").rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith("src/wire/") or rel in allowed_wire_writers:
            continue
        if writer_re.search(path.read_text(encoding="utf-8", errors="replace")):
            unexpected_writers.append(rel)
    if unexpected_writers:
        failures.append(
            "wire writers outside src/wire/, unlisted "
            f"({len(unexpected_writers)}): " + ", ".join(unexpected_writers[:8])
            + " - the wire audits do not reach these; move the body into a "
            "builder or list it in provenance_scan 7h with the reason"
        )

    # 7i. INBOUND HANDLERS FOR ToClient-ONLY PACKAGES. Stock declares a
    #     direction per package (`get_PackageDirection`, NetPackageDirection:
    #     0 Both, 1 ToServer, 2 ToClient). The phase gate lets everything
    #     through once a peer reaches .playing, so a handler claiming a
    #     ToClient name accepts a package stock never processes server-side.
    #     NetPackageCloseAllWindows was relayed to every other peer that way,
    #     letting any client close another player's UI. Accepting one and
    #     dropping it is a legitimate choice; doing it silently is not, so
    #     require the name to appear in DIVERGENCES with its reasoning.
    #     Skipped when the research repo is absent, like check 5.
    il_dir = research_root / "il" / "full-v3.2.0" / "_global"
    if il_dir.is_dir():
        pkgs_src = pathlib.Path(ROOT, "src/wire/packages.zig").read_text(
            encoding="utf-8", errors="replace"
        )
        table = re.search(
            r"pub const default_mappings = \[_\]\[\]const u8\{(.*?)\n\};", pkgs_src, re.S
        )
        advertised = re.findall(r'"(NetPackage\w+)"', table.group(1)) if table else []
        to_client = set()
        for name in advertised:
            il = il_dir / f"{name}.il.txt"
            if not il.is_file():
                continue
            body = re.search(
                r"get_PackageDirection\(\) IL=\d+\n(.*?)\nIL_\d+: ret",
                il.read_text(encoding="utf-8", errors="replace"),
                re.S,
            )
            if not body:
                continue  # no override: inherits NetPackage's Both
            val = re.search(r"ldc\.i4(?:\.s)?[. ](\d+)", body.group(1))
            if val and int(val.group(1)) == 2:
                to_client.add(name)
        # Only an `eql` comparison means the handler treats the name as
        # inbound; a sendGame call naming it is the opposite direction.
        inbound = set()
        for path in sorted(pathlib.Path(ROOT, "src/server/c2s").glob("*.zig")):
            for m in re.finditer(
                r'std\.mem\.eql\(u8, (?:name|pkg_name), "(NetPackage\w+)"\)',
                path.read_text(encoding="utf-8", errors="replace"),
            ):
                inbound.add(m.group(1))
        undocumented_inbound = sorted(
            n for n in inbound & to_client if n not in divergences_text
        )
        if undocumented_inbound:
            failures.append(
                "C2S handlers claiming a stock ToClient-only package, with no "
                f"doc row ({len(undocumented_inbound)}): "
                + ", ".join(undocumented_inbound[:8])
                + " - stock never processes these server-side; record the "
                "accept-and-drop in DIVERGENCES 1 or stop claiming the name"
            )

        # 7j. THE MIRROR OF 7i: packages the stock CLIENT sends that reach no
        #     handler here. 7i catches claiming a name stock never sends us;
        #     this catches ignoring one it does. Both directions have gone
        #     wrong: three names (EntityStatChanged, GameEventResponse,
        #     SharedPartyKill) were listed as handled in GAP_ANALYSIS while
        #     having no C2S arm at all, and PlayerLaserSight sat filed under
        #     "Twitch integration" - a wrong category is how a real gap stays
        #     invisible. The senders are recovered from the IL rather than
        #     trusted from prose: walk back from each SendToServer call to the
        #     nearest GetPackage<T> / ParsePackage<T> that supplies it.
        senders: set[str] = set()
        src_re = re.compile(
            r"NetPackageManager::(?:GetPackage|ParsePackage)<(?:class )?(NetPackage\w+)>"
        )
        for il_path in il_dir.glob("*.il.txt"):
            text = il_path.read_text(encoding="utf-8", errors="replace")
            if "SendToServer(" not in text:
                continue
            lines = text.split("\n")
            for i, line in enumerate(lines):
                if "::SendToServer(" not in line:
                    continue
                # 40 lines back covers the Setup-argument runs in these dumps.
                for j in range(i, max(-1, i - 40), -1):
                    m = src_re.search(lines[j])
                    if m:
                        senders.add(m.group(1))
                        break
        # Only names zdtd advertises can arrive at all: an unregistered one has
        # no id in the negotiated map.
        # Unlike 7d/7i this accepts a backticked short name: the existing prose
        # names these by short form inside the category paragraphs, and the
        # point here is "is there a stated reason", not "is it in the register"
        # (an ignored client sender need not be an authority divergence). The
        # backticks still keep it from matching ordinary prose words.
        # A name the docs call SHIPPED or WORKS gets no excuse: that claim is
        # exactly what has to match the code. This is the failure the check
        # exists for - three names were listed as handled while having no C2S
        # arm - so a doc mention must not be able to satisfy it.
        claimed_done = set()
        # The status is the first word of the next table cell, so anchor on the
        # pipe. Matching loose text instead reads the word out of an
        # explanation ("was scored SHIPPED until...") and mistakes a corrected
        # row for a live claim.
        for m in re.finditer(
            r"(NetPackage\w+)`?[^|\n]{0,60}\|\s*(SHIPPED|WORKS)\b", doc_text
        ):
            claimed_done.add(m.group(1))
        unhandled_senders = sorted(
            n
            for n in senders & set(advertised)
            if n not in inbound
            and (
                n in claimed_done
                or (
                    n not in doc_text
                    and f"`{n[len('NetPackage'):]}`" not in doc_text
                )
            )
        )
        if unhandled_senders:
            failures.append(
                "packages the stock client sends that reach no C2S handler and "
                f"no doc row ({len(unhandled_senders)}): "
                + ", ".join(unhandled_senders[:8])
                + " - handle it, or record why it is ignored in DIVERGENCES 3b"
            )

        # 7k. THE OTHER DIRECTION: packages the stock SERVER sends that zdtd
        #     never emits. 7j covers what arrives; this covers what should
        #     leave. It found NetPackageSetAttackTarget, which stock fans out
        #     of every AI target change and zdtd computed but never published,
        #     leaving every remote zombie reading as untargeted on the client.
        #     Same recovery shape, different call set.
        server_send = re.compile(
            r"::(?:SendPackage|SendToPlayers|SendPacketToTrackedPlayers"
            r"|SendPacketToTrackedPlayersAndTrackedEntity)\("
        )
        server_senders: set[str] = set()
        for il_path in il_dir.glob("*.il.txt"):
            text = il_path.read_text(encoding="utf-8", errors="replace")
            if not server_send.search(text):
                continue
            lines = text.split("\n")
            for i, line in enumerate(lines):
                if not server_send.search(line):
                    continue
                for j in range(i, max(-1, i - 40), -1):
                    m = src_re.search(lines[j])
                    if m:
                        server_senders.add(m.group(1))
                        break
        emitted_names: set[str] = set()
        # Only a real send counts. Matching every quoted occurrence would let a
        # test that merely looks the id up, or a doc comment, stand in for the
        # emit - which is the exact confusion this check exists to catch.
        # Not `files`: that name holds the src file list this function reports
        # its coverage over, and shadowing it here silently reported 44 files
        # instead of 201.
        # The send verbs actually used in src/server, measured rather than
        # guessed. `idOf`, `framed`, `eql` and `injectFramed` are deliberately
        # absent: they look a name up, frame a body, match an inbound package
        # or feed a test, none of which is emitting one.
        emit_re = re.compile(
            r'\b(?:sendGame|sendGameCritical|sendGameBudget|sendFramedReliable'
            r'|broadcast|broadcastExcept|broadcastNear|relayBodyAll'
            r'|relayBodyExcept|sendCompressed)\s*\([^)]{0,80}?"(NetPackage\w+)"'
        )
        for dirpath, _dirs, srv_names in os.walk(os.path.join(ROOT, "src/server")):
            for fname in srv_names:
                if fname.endswith(".zig"):
                    emitted_names.update(
                        emit_re.findall(
                            open(
                                os.path.join(dirpath, fname),
                                encoding="utf-8",
                                errors="replace",
                            ).read()
                        )
                    )
        unsent = sorted(
            n
            for n in server_senders & set(advertised)
            if n not in emitted_names
            and (
                n in claimed_done
                or (
                    n not in doc_text
                    and f"`{n[len('NetPackage'):]}`" not in doc_text
                )
            )
        )
        if unsent:
            failures.append(
                "packages the stock server sends that zdtd never emits and no "
                f"doc row covers ({len(unsent)}): "
                + ", ".join(unsent[:8])
                + " - emit it, or record why it is not sent in DIVERGENCES 3b"
            )

    if failures:
        for f in failures:
            print("FAIL:", f, file=sys.stderr)
        return 1
    print(
        f"OK: {len(files)} files covered (100%), {len(const_rows)} constants ledgered, "
        "behavioral constants annotated, audit findings linked, "
        f"{len(never_sent)} never-sent packages all documented"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
