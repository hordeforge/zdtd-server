#!/usr/bin/env python3
"""Generate src/assets/passive_effects.zig from the stock PassiveEffects enum.

The wire id an `ItemValue` stat entry carries is the enum's numeric value, i.e.
its declaration order (`PassiveEffects.il.txt` lists the members in order, so
`None` = 0). The RE dump is the source of truth; this keeps the Zig table in
sync with it instead of hand-copying 204 names.

Usage: python3 tools/gen_passive_effects.py [il-dir]
"""
import re
import sys
from pathlib import Path

DEFAULT_IL = Path(__file__).resolve().parents[2] / "7dtd-engine-research" / "il" / "full-v3.2.0" / "_global"
OUT = Path(__file__).resolve().parents[1] / "src" / "assets" / "passive_effects.zig"


def members(il_dir: Path) -> list[str]:
    text = (il_dir / "PassiveEffects.il.txt").read_text()
    line = next(l for l in text.splitlines() if l.startswith("// fields:"))
    names = []
    for part in line[len("// fields: "):].split(","):
        m = re.fullmatch(r"\s*PassiveEffects (\w+)\s*", part)
        if m:
            names.append(m.group(1))
    if not names or names[0] != "None":
        raise SystemExit("unexpected PassiveEffects field list")
    return names


def main() -> int:
    il_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_IL
    names = members(il_dir)
    rows = "\n".join(f'    .{{ .name = "{n}", .id = {i} }},' for i, n in enumerate(names))
    OUT.write_text(
        "//! Stock `PassiveEffects` ordinals: the numeric id an `ItemValue` stat entry\n"
        "//! carries on the wire (`ItemValue::Write` IL=323 writes `(byte)Stat.type`).\n"
        "//!\n"
        "//! Generated from the stock enum's declaration order (`None` = 0); regenerate\n"
        "//! with `python3 tools/gen_passive_effects.py`. Do not hand-edit.\n"
        "\n"
        "const std = @import(\"std\");\n"
        "\n"
        "/// Number of enum members, `Count` (the sentinel) included.\n"
        f"pub const count: usize = {len(names)};\n"
        "\n"
        "pub const Entry = struct { name: []const u8, id: u8 };\n"
        "\n"
        "pub const table = [_]Entry{\n"
        f"{rows}\n"
        "};\n"
        "\n"
        "/// Enum value of `name`, or null when the name is not a member. Stock's\n"
        "/// `EnumUtils.Parse<PassiveEffects>(name, false)` is case-sensitive.\n"
        "pub fn idOfName(name: []const u8) ?u8 {\n"
        "    for (table) |e| {\n"
        "        if (std.mem.eql(u8, e.name, name)) return e.id;\n"
        "    }\n"
        "    return null;\n"
        "}\n"
        "\n"
        "/// Member name of `id`, or null past the end of the enum.\n"
        "pub fn nameOfId(id: u8) ?[]const u8 {\n"
        "    if (id >= table.len) return null;\n"
        "    return table[id].name;\n"
        "}\n"
        "\n"
        "test \"stock PassiveEffects ordinals\" {\n"
        "    // Anchors from the RE dumps: the enum's field order is the ordinal, and\n"
        "    // docs/gameplay/items.md pins these five by number.\n"
        "    try std.testing.expectEqual(@as(?u8, 0), idOfName(\"None\"));\n"
        "    try std.testing.expectEqual(@as(?u8, 1), idOfName(\"EntityDamage\"));\n"
        "    try std.testing.expectEqual(@as(?u8, 76), idOfName(\"EconomicValue\"));\n"
        "    try std.testing.expectEqual(@as(?u8, 79), idOfName(\"LootProb\"));\n"
        "    try std.testing.expectEqual(@as(?u8, 112), idOfName(\"StaminaLoss\"));\n"
        "    try std.testing.expectEqual(@as(?u8, 141), idOfName(\"HarvestCount\"));\n"
        "    try std.testing.expectEqual(@as(?u8, 163), idOfName(\"TargetArmor\"));\n"
        "    // The name lookup is case-sensitive, like stock's Parse(name, false).\n"
        "    try std.testing.expectEqual(@as(?u8, null), idOfName(\"entitydamage\"));\n"
        "    try std.testing.expectEqual(@as(?u8, null), idOfName(\"NoSuchEffect\"));\n"
        "    // Round-trip and the sentinel at the end of the enum.\n"
        "    for (table) |e| try std.testing.expectEqualStrings(e.name, nameOfId(e.id).?);\n"
        "    try std.testing.expectEqualStrings(\"Count\", nameOfId(@intCast(count - 1)).?);\n"
        "    try std.testing.expectEqual(@as(?[]const u8, null), nameOfId(255));\n"
        "}\n",
        encoding="utf-8",
    )
    print(f"wrote {OUT} with {len(names)} members")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
