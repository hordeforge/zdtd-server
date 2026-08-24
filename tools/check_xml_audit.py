#!/usr/bin/env python3
"""Deterministic XML-data audit gate for zdtd.

Replaces the manual "check every Data/Config .xml for hardcoded values"
review with two programmatic checks (docs/XML_DATA_AUDIT.md is the written
record; this script is the machine check):

1. COVERAGE CONTRACT: every `Data/Config/*.xml` in the operator's game dir
   must appear in the audit doc's per-file table (docs/XML_DATA_AUDIT.md),
   and every table row must still exist on disk. A game update that adds or
   renames a stock XML file fails the gate until the file is re-audited.

2. NAME-LITERAL SCAN: stock names (block/item/buff/quest/entity/recipe/
   loot/trader/vehicle/biome/entityspawner names) extracted from the
   loader-consumed XMLs must not appear as string literals in production
   Zig outside the documented allowlist. Loader code (src/assets/**) and
   wire RE tables (src/wire/**) are exempt by design; test blocks are
   skipped. A literal that matches a stock name and is not allowlisted is
   a hardcode candidate the audit must classify.

Usage: python3 tools/check_xml_audit.py [--game-dir DIR] [--src DIR] [--audit DOC]
Exit 0 = clean (or game dir absent -> skipped with a notice, matching the
loaders' SkipZigTest convention). Exit 1 = violation.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_GAME = os.path.expanduser(
    "~/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server"
)
SRC = os.path.join(ROOT, "src")
AUDIT = os.path.join(ROOT, "docs", "XML_DATA_AUDIT.md")

# Files the server actually reads values from -> (xml tag, name attribute)
# pairs to extract stock names from. XMLs the server only forwards to the
# client (config_files.zig LoadLocal) are intentionally not scanned: their
# values are parsed client-side.
NAME_TAGS = {
    "blocks.xml": ["block"],
    "items.xml": ["item"],
    "buffs.xml": ["buff"],
    "quests.xml": ["quest"],
    "entityclasses.xml": ["entity_class"],
    "entitygroups.xml": ["entitygroup"],
    "recipes.xml": ["recipe"],
    "loot.xml": ["lootgroup", "lootcontainer"],
    "traders.xml": ["trader_info", "trader_item_group"],
    "vehicles.xml": ["vehicle"],
    "biomes.xml": ["biome"],
    "spawning.xml": ["spawn", "entityspawner"],
    "progression.xml": ["skill", "perk", "attribute"],
    "materials.xml": ["material"],
    "npc.xml": ["npc_info"],
    "painting.xml": ["painting"],
}

# Documented selection keys / offline fallback names (docs/XML_DATA_AUDIT.md
# "Offline fallbacks" section). These literals are data-bound lookups into a
# loaded table, or the builtin offline name map; each entry cites why.
ALLOWLIST = {
    # Stock-name selection keys resolved through a loaded table (never values).
    "buffInjuryBleeding",  # hooks.zig bleed-smell radius
    "bloodMoon",  # weather.zig horde-night weather group
    "Scouts1", "Scouts2", "ScoutsFeral", "ScoutsRadiated",  # aidirector spawners
    "autoTurret",  # game.zig turret wattsByName lookup
    "airDrop",  # tick.zig airdrop loot container (data-bound ref)
    "supply_drop",  # tick.zig nav-object class sent to the client
    "keystoneBlock",  # game.zig land-claim keystone idByName
    "cntWoodenChestClosed",  # replicate_te.zig seed-chest idByName (+ pin)
    "foodCanChili",  # init_assets.zig items-load smoke probe (byStockName)
    "ZombiesAll",  # init_assets.zig director default entitygroup
    # Bedroll respawn blocks: stock defines no "is-bedroll" property, so the
    # name list resolves through AssignIds at runtime (game.zig isBedroll).
    "bedroll", "bedrollRed", "bedrollOrange", "bedrollYellow",
    "bedrollGreen", "bedrollBlue", "bedrollPurple", "bedrollPink",
    # Biome enumeration / default (init_assets.zig director seeding,
    # world/biomes.zig color-table defaults) and biome terr* pin fallbacks.
    "pine_forest", "burnt_forest", "desert", "snow", "wasteland",
    "terrStone", "terrBedrock", "terrDirt", "terrForestGround", "terrSand",
    "terrSandStone", "terrSnow", "terrTopSoil", "terrBurntForestGround",
    "terrDesertGround", "terrDestroyedStone", "terrDestroyedGrass", "water",
    # TerrainIds resolve keys (world/store.zig, dump-only).
    "air", "terrainFiller", "terrainFillerAdaptive",
    # Power-block offline pins (ecs/powerblocks.zig + init_assets.zig).
    "generatorbank", "solarbank", "batterybank", "electricwirerelay",
    "electricfencepost", "electrictimerrelay", "switch", "pressureplate",
    "dartTrap", "bladeTrap",
    # Offline class_table default (ecs/world.zig, stock ^healthNormalFeral 550).
    "zombieBoeFeral",
    # Offline loot-bag entity class default (ecs/world.zig class_table).
    "EntityLootContainerRegular",
    # Offline builtin name map (ecs/inventory.zig mirrors assets/items.zig;
    # only used when no game-dir loads).
    "resourceScrapIron", "resourceScrapLead", "foodCanBeef",
    "ammo9mmBulletBall", "medicalFirstAidBandage", "meleeToolRepairT0StoneAxe",
    "casinoCoin", "resourceWood", "meleeWpnClubT0WoodenClub",
    "resourceCobblestones", "armorPrimitiveHelmet", "questItem",
}


# Value-level scan: stock numeric literals pinned by the audit
# (docs/XML_DATA_AUDIT.md fixed rows). A literal may appear in loader
# (src/assets), wire (src/wire), fuzz, tests, or the explicitly listed
# files (config floors / documented fallbacks). Any other production
# occurrence is a hardcode-regression candidate that must be triaged.
# Floats only: bare integers (40, 100, 8) are too common (buffer sizes,
# loop bounds) to be diagnostic; decimal literals are distinctive.
VALUE_ITEMS = {
    "1.6": "items.xml meleeHand Range (zombie hand reach)",
    "2.4": "items.xml passive MaxRange (club/axe reach)",
    "0.02": "rules.vehicle.fuel_per_m floor (sell markdown default)",
}
# Files (relative to src/) beyond loader/wire/test where the literal is a
# documented floor, RE conversion or zdtd-owned constant; any other
# production file with the literal is a violation. Reasons per entry.
VALUE_ALLOWED = {
    "ecs/rules.zig": {"0.02", "1.6"},  # fuel_per_m floor; zombie ai gravity -1.6
    "server/game/hooks.zig": {"0.02"},  # sell-markdown fallback (RULES_CONFIG STOCK fallbacks)
    "server/game/trader.zig": {"0.02"},  # sell-markdown fallback (same)
    "world/worldgen.zig": {"0.02", "1.6"},  # procedural noise frequency + shaping (zdtd-owned)
    "ecs/systems.zig": {"1.6"},  # eye-height + chase-speed RE conversions (not melee range)
}


def extract_stock_names(config_dir):
    """Stock name set from the loader-consumed XMLs in Data/Config."""
    names = set()
    for fname, tags in NAME_TAGS.items():
        path = os.path.join(config_dir, fname)
        if not os.path.isfile(path):
            continue
        with open(path, "r", errors="replace") as fh:
            data = fh.read()
        for tag in tags:
            for m in re.finditer(r"<\s*%s\b[^>]*?name=\"([^\"]+)\"" % re.escape(tag), data):
                names.add(m.group(1))
    return names


def strip_zig_line(line):
    """Remove string literals and comments so brace counting is accurate."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"//.*$", "", line)
    return line


def production_literals(path):
    """Yield (line_no, literal) for bare-word string literals in non-test code.

    Test blocks are tracked by brace depth from a top-level `test` keyword;
    loader (src/assets), wire (src/wire) and the fuzz harness (src/fuzz.zig)
    are exempt by the caller. Literals inside comments or string content
    (e.g. a `// Stock substitutes "missingBlock"` note) are not extracted.
    """
    in_test = False
    depth = 0
    out = []
    with open(path, "r", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            if not in_test:
                if re.match(r"^\s*test\b", raw):
                    in_test = True
                    depth = 0
                else:
                    # Literal extraction: strip comments only (a quoted stock
                    # name inside a comment is not a hardcode); strings stay.
                    # Bare words plus `name:name` shapes (frameShapes:cube).
                    no_comments = re.sub(r"//.*$", "", raw)
                    for m in re.finditer(r'"([a-zA-Z0-9_]+(?::[a-zA-Z0-9_]+)?)"', no_comments):
                        out.append((lineno, m.group(1)))
            if in_test:
                stripped = strip_zig_line(raw)
                depth += stripped.count("{") - stripped.count("}")
                if depth <= 0:
                    in_test = False
                    depth = 0
    return out


def audit_coverage(game_dir, audit_path):
    """Every Data/Config/*.xml must be listed in the audit doc and vice versa."""
    if not os.path.isfile(audit_path):
        print("check_xml_audit: audit doc missing: %s" % audit_path)
        return False
    with open(audit_path, "r", errors="replace") as fh:
        doc = fh.read()
    section = doc.split("## Per-file coverage", 1)[1].split("\n## ", 1)[0]
    doc_files = set(
        m.group(1)
        for m in re.finditer(r"^\|\s*`?([A-Za-z0-9_.]+\.xml)`?\s*\|", section, re.M)
    )
    disk_files = set(
        f for f in os.listdir(game_dir)
        if f.endswith(".xml") and os.path.isfile(os.path.join(game_dir, f))
    )
    missing_in_doc = disk_files - doc_files
    stale_in_doc = doc_files - disk_files
    ok = True
    if missing_in_doc:
        ok = False
        print("check_xml_audit: XML on disk but NOT audited in %s:" % audit_path)
        for f in sorted(missing_in_doc):
            print("  - %s" % f)
    if stale_in_doc:
        print("check_xml_audit: audit doc lists files absent from Data/Config:")
        for f in sorted(stale_in_doc):
            print("  - %s" % f)
    return ok


def scan_src(src_dir, stock_names):
    """Bare-word literals in production (non-test, non-loader, non-wire) code
    that match a stock XML name and are not allowlisted."""
    violations = []
    for root, _dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        if rel == "assets" or rel.startswith("assets" + os.sep):
            continue
        if rel == "wire" or rel.startswith("wire" + os.sep):
            continue
        for fname in sorted(files):
            if not fname.endswith(".zig"):
                continue
            path = os.path.join(root, fname)
            if os.path.normpath(path) == os.path.normpath(os.path.join(src_dir, "fuzz.zig")):
                continue  # fuzz harness: stock names are fuzz inputs, not server logic
            for lineno, lit in production_literals(path):
                if lit in stock_names and lit not in ALLOWLIST:
                    relpath = os.path.relpath(path, src_dir)
                    violations.append((relpath, lineno, lit))
    return violations


def production_floats(path):
    """Decimal float literals in non-test production lines (comments stripped)."""
    in_test = False
    depth = 0
    out = []
    with open(path, "r", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            if not in_test:
                if re.match(r"^\s*test\b", raw):
                    in_test = True
                    depth = 0
                else:
                    no_comments = re.sub(r"//.*$", "", raw)
                    for m in re.finditer(r"(?<![A-Za-z0-9_])(\d+\.\d+)", no_comments):
                        out.append((lineno, m.group(1)))
            if in_test:
                stripped = strip_zig_line(raw)
                depth += stripped.count("{") - stripped.count("}")
                if depth <= 0:
                    in_test = False
                    depth = 0
    return out


def scan_values(src_dir):
    """Stock numeric literals in production code outside their allowed files."""
    violations = []
    for root, _dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        if rel == "assets" or rel.startswith("assets" + os.sep):
            continue
        if rel == "wire" or rel.startswith("wire" + os.sep):
            continue
        for fname in sorted(files):
            if not fname.endswith(".zig"):
                continue
            path = os.path.join(root, fname)
            if os.path.normpath(path) == os.path.normpath(os.path.join(src_dir, "fuzz.zig")):
                continue
            relpath = os.path.relpath(path, src_dir)
            allowed = VALUE_ALLOWED.get(relpath, set())
            for lineno, lit in production_floats(path):
                if lit in VALUE_ITEMS and lit not in allowed:
                    violations.append((relpath, lineno, lit, VALUE_ITEMS[lit]))
    return violations


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", default=DEFAULT_GAME)
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--audit", default=AUDIT)
    args = ap.parse_args()

    config_dir = os.path.join(args.game_dir, "Data", "Config")
    if not os.path.isdir(config_dir):
        print("check_xml_audit: game dir not found (%s); skipped" % config_dir)
        return 0

    ok = audit_coverage(config_dir, args.audit)

    stock_names = extract_stock_names(config_dir)
    print("check_xml_audit: stock names extracted=%d" % len(stock_names))
    violations = scan_src(args.src, stock_names)
    if violations:
        ok = False
        print("check_xml_audit: stock XML names used as literals outside loaders:")
        for rel, lineno, lit in violations:
            print("  %s:%d  %s" % (rel, lineno, lit))

    value_violations = scan_values(args.src)
    if value_violations:
        ok = False
        print("check_xml_audit: stock XML numeric literals outside loaders/allowlist:")
        for rel, lineno, lit, why in value_violations:
            print("  %s:%d  %s  (%s)" % (rel, lineno, lit, why))

    if not ok:
        print("check_xml_audit: FAIL")
        return 1
    print("check_xml_audit: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
