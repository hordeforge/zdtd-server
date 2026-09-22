//! Loot table tests: weights, abundance, gates, rolls.
//!
//! Split out of assets/loot.zig (same tests, moved verbatim).

const std = @import("std");
const loot = @import("loot.zig");
const LootTable = loot.LootTable;
const abundanceOptionName = loot.abundanceOptionName;
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");
const requirements = @import("requirements.zig");
const sandbox = @import("sandbox.zig");
const EntryGate = loot.EntryGate;
const LootGateCtx = loot.LootGateCtx;
const GateKind = loot.GateKind;
const LootBuffSink = loot.LootBuffSink;
const LootContainer = loot.LootContainer;
const ProbScale = loot.ProbScale;
const QtyScale = loot.QtyScale;
const Stack = loot.Stack;
const loadFromPath = loot.loadFromPath;
const loadFromSlice = loot.loadFromSlice;
const max_entries = loot.max_entries;
const max_roll_stacks = loot.max_roll_stacks;
const randomUseTimes = loot.randomUseTimes;

test "pickWeight clamps malformed probs instead of trapping the cast" {
    // Normal probs are milliprobs.
    try std.testing.expectEqual(@as(u32, 500), LootTable.pickWeight(0.5));
    // Negative, NaN and zero fail closed at the weight-1 floor (a panic in
    // the float->u32 cast before the clamp).
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(-2.0));
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(0));
    // Huge finite probs cap under maxInt(u32) instead of trapping; a
    // non-finite prob fails closed at the weight-1 floor.
    try std.testing.expectEqual(@as(u32, 4_000_000_000), LootTable.pickWeight(1.0e9));
    try std.testing.expectEqual(@as(u32, 1), LootTable.pickWeight(std.math.inf(f32)));
}

test "loot abundance scales counts, keeps at least one" {
    var lt = LootTable.builtin();
    var base: [max_roll_stacks]Stack = undefined;
    const nb = lt.rollContainer("woodenChest", 1, 12345, &base, .{});
    lt.abundance_pct = 200;
    var big: [max_roll_stacks]Stack = undefined;
    const ng = lt.rollContainer("woodenChest", 1, 12345, &big, .{});
    try std.testing.expectEqual(nb, ng);
    // Every non-fallback stack doubles (same seed → same base counts).
    var i: usize = 0;
    while (i < nb) : (i += 1) {
        try std.testing.expectEqualStrings(base[i].item_name, big[i].item_name);
        try std.testing.expectEqual(base[i].count * 2, big[i].count);
    }
    // A tiny abundance still yields at least 1 per stack.
    lt.abundance_pct = 1;
    var small: [max_roll_stacks]Stack = undefined;
    const ns = lt.rollContainer("woodenChest", 1, 12345, &small, .{});
    i = 0;
    while (i < ns) : (i += 1) try std.testing.expect(small[i].count >= 1);
}

test "scaleCount saturates at the u16 cap instead of trapping" {
    var lt = LootTable.builtin();
    // Max stock abundance (1000) times a modded count past 6553 would exceed
    // u16 in the scaled product; the roll saturates at the stack cap.
    lt.abundance_pct = 1000;
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), lt.scaleCount(10000, true, 1.0));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), lt.scaleCount(65535, true, 1.0));
    // Mid-range values still scale normally.
    lt.abundance_pct = 200;
    try std.testing.expectEqual(@as(u16, 200), lt.scaleCount(100, true, 1.0));
    // The floor keeps at least one even for a tiny count and abundance.
    lt.abundance_pct = 1;
    try std.testing.expectEqual(@as(u16, 1), lt.scaleCount(1, true, 1.0));
    // ignore_loot_abundance passes the raw count through unmodified.
    lt.abundance_pct = 1000;
    try std.testing.expectEqual(@as(u16, 65535), lt.scaleCount(65535, false, 1.0));
    // The group's abundance_type factor multiplies the global abundance, and 0
    // means the category is disabled (stock `abundance *= mult`).
    lt.abundance_pct = 100;
    try std.testing.expectEqual(@as(u16, 50), lt.scaleCount(100, true, 0.5));
    try std.testing.expectEqual(@as(u16, 0), lt.scaleCount(100, true, 0.0));
}

test "builtin loot roll" {
    const t = LootTable.builtin();
    var stacks: [max_roll_stacks]Stack = undefined;
    const n = t.rollContainer("EntityLootContainerRegular", 1, 42, &stacks, .{});
    try std.testing.expect(n >= 1);
    try std.testing.expect(stacks[0].count >= 1);
}

test "load stock loot when present" {
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.groups.len > 50);
    try std.testing.expect(t.containers.len > 20);
    try std.testing.expect(t.containerByName("woodenChest") != null);
    var stacks: [max_roll_stacks]Stack = undefined;
    // Fail-closed rolls mean a single seed can legitimately come up empty
    // (stock prob gates); some seed in a spread must still yield loot.
    var total: usize = 0;
    var seed: u32 = 0;
    while (seed < 32) : (seed += 1) {
        total += t.rollContainer("woodenChest", 7, seed, &stacks, .{});
    }
    try std.testing.expect(total >= 1);
}

test "lootcontainer count picks that many entries (count 0 is empty)" {
    // Stock LootContainer.count -> minCount/maxCount via ParseMinMaxCount
    // (LootFromXml IL_0060-0095, default 1,1) and Spawn rolls one pick count
    // clamped to the slots; SpawnLootItemsFromList then makes exactly that
    // many prob-weighted picks (302 stock containers carry count: 268 one,
    // 33 zero, one "1,2").
    const src =
        \\<lootcontainers>
        \\<lootcontainer name="one" size="6,2">
        \\  <item name="a"/>
        \\  <item name="b"/>
        \\  <item name="c"/>
        \\</lootcontainer>
        \\<lootcontainer name="zero" size="6,2" count="0">
        \\  <item name="a"/>
        \\  <item name="b"/>
        \\</lootcontainer>
        \\<lootcontainer name="range" size="6,2" count="1,2">
        \\  <item name="a"/>
        \\  <item name="b"/>
        \\  <item name="c"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(u16, 1), t.containerByName("one").?.pick_min);
    try std.testing.expectEqual(@as(u16, 1), t.containerByName("one").?.pick_max);
    try std.testing.expectEqual(@as(u16, 0), t.containerByName("zero").?.pick_max);
    try std.testing.expectEqual(@as(u16, 1), t.containerByName("range").?.pick_min);
    try std.testing.expectEqual(@as(u16, 2), t.containerByName("range").?.pick_max);

    var stacks: [8]Stack = undefined;
    var seed: u32 = 0;
    var saw_two = false;
    while (seed < 200) : (seed += 1) {
        // Default count picks exactly one of the three entries.
        try std.testing.expectEqual(@as(usize, 1), t.rollContainer("one", 1, seed, &stacks, .{}));
        // count="0" spawns nothing at all.
        try std.testing.expectEqual(@as(usize, 0), t.rollContainer("zero", 1, seed, &stacks, .{}));
        // count="1,2" stays inside the range.
        const rn = t.rollContainer("range", 1, seed, &stacks, .{});
        try std.testing.expect(rn >= 1 and rn <= 2);
        if (rn == 2) saw_two = true;
    }
    try std.testing.expect(saw_two);
}

test "loot prob templates gate entries by loot stage" {
    const src =
        \\<lootcontainers>
        \\<loot_settings poi_tier_mod="0.05,0.1,0.15" poi_tier_bonus="3,6,9"/>
        \\<lootprobtemplates>
        \\  <lootprobtemplate name="veryLowDelayed">
        \\    <loot level="0,14" prob="0"/>
        \\    <loot level="15,999999" prob=".05"/>
        \\  </lootprobtemplate>
        \\  <lootprobtemplate name="guaranteed">
        \\    <loot level="1,999999" prob="1"/>
        \\  </lootprobtemplate>
        \\</lootprobtemplates>
        \\<lootgroup name="g">
        \\  <item name="always" loot_prob_template="guaranteed"/>
        \\  <item name="plain"/>
        \\</lootgroup>
        \\<lootcontainer name="c" size="6,2">
        \\  <item name="gated" loot_prob_template="veryLowDelayed"/>
        \\  <item name="plain"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.prob_templates.len);
    try std.testing.expectEqual(@as(usize, 3), t.poi_tier_mod.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), t.poi_tier_mod[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), t.poi_tier_bonus[0], 0.0001);

    const cont = t.containerByName("c").?;
    const gated = cont.entries[0];
    const plain = cont.entries[1];
    // veryLowDelayed: zero below stage 15, .05 at and above it.
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.entryProb(gated, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t.entryProb(gated, 14), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.entryProb(gated, 15), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), t.entryProb(gated, 999999), 0.0001);
    // Above the last band nothing matches, so the entry's own prob applies.
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(gated, 1_000_000), 0.0001);
    // An entry with no template is stage-blind (unchanged behaviour).
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(plain, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), t.entryProb(plain, 5000), 0.0001);

    // The zero band must suppress the item across every seed, and the .05 band
    // must let it through at least once.
    var stacks: [max_roll_stacks]Stack = undefined;
    var seen_low: usize = 0;
    var seen_high: usize = 0;
    var seed: u32 = 0;
    while (seed < 400) : (seed += 1) {
        var n = t.rollContainer("c", 0, seed, &stacks, .{});
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "gated")) seen_low += 1;
        }
        n = t.rollContainer("c", 40, seed, &stacks, .{});
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "gated")) seen_high += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), seen_low);
    try std.testing.expect(seen_high >= 1);
}

test "all-gated roll yields an empty container, not fabricated items" {
    const src =
        \\<lootcontainers>
        \\<lootprobtemplates>
        \\  <lootprobtemplate name="never">
        \\    <loot level="0,999999" prob="0"/>
        \\  </lootprobtemplate>
        \\</lootprobtemplates>
        \\<lootcontainer name="emptyOk" size="6,2">
        \\  <item name="gatedA" loot_prob_template="never"/>
        \\  <item name="gatedB" prob="0"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    var stacks: [max_roll_stacks]Stack = undefined;
    var seed: u32 = 0;
    while (seed < 50) : (seed += 1) {
        const n = t.rollContainer("emptyOk", 30, seed, &stacks, .{});
        try std.testing.expectEqual(@as(usize, 0), n);
    }
}

test "stock loot item entries leave quality to the template" {
    // Stock writes `quality` only on the <loot> rows inside a
    // <lootqualitytemplate>, never on an <item>. This pins that fact and the
    // template path it implies: the parsed entries carry no override, and the
    // template still resolves a quality for them.
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    var entries: usize = 0;
    for (lt.groups) |g| {
        for (g.entries[0..g.entry_n]) |e| {
            try std.testing.expectEqual(@as(u8, 0), e.quality);
            entries += 1;
        }
    }
    for (lt.containers) |c| {
        for (c.entries[0..c.entry_n]) |e| {
            try std.testing.expectEqual(@as(u8, 0), e.quality);
            entries += 1;
        }
    }
    try std.testing.expect(entries > 100);
    // The template rows did parse (a rename would empty the picks).
    try std.testing.expect(lt.quality_templates.len > 0);
    var picks: usize = 0;
    for (lt.quality_templates) |qt| {
        for (qt.bands) |band| picks += band.picks.len;
    }
    try std.testing.expect(picks > 100);
}

test "loot entry tags feed the LootProb scale" {
    // Stock getProbability folds the player's LootProb passives onto the
    // entry's prob with the entry's own `tags=` as the query set, and that
    // value is the entry's normalized weight in the pick. A provider that
    // answers 1.0 raises the tagged entry's share, 0 removes it.
    const src =
        \\<lootcontainers>
        \\<lootcontainer name="tagc" size="6,1">
        \\  <item name="taggedThing" prob="0.5" tags="tagA"/>
        \\  <item name="plainThing" prob="0.5"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    try std.testing.expectEqualStrings("tagA", lt.containerByName("tagc").?.entries[0].tags);

    const Fx = struct {
        answer: f32 = 1.0,
        seen_tags: []const u8 = "",
        fn scale(ctx: ?*anyopaque, tags: []const u8, base: f32) f32 {
            const f: *@This() = @ptrCast(@alignCast(ctx.?));
            f.seen_tags = tags;
            return if (f.answer < 0) base else f.answer;
        }
    };
    var stacks: [4]Stack = undefined;
    var fx: Fx = .{ .answer = -1 };
    const sink = ProbScale{ .ctx = &fx, .scale = Fx.scale };
    const count_tagged = struct {
        fn run(t: *const LootTable, ps: ?ProbScale, out: []Stack) usize {
            var hits: usize = 0;
            var seed: u32 = 1;
            while (seed <= 60) : (seed += 1) {
                const n = t.rollContainer("tagc", 1, seed, out, .{ .prob_scale = ps });
                for (out[0..n]) |st| {
                    if (std.mem.eql(u8, st.item_name, "taggedThing")) hits += 1;
                }
            }
            return hits;
        }
    }.run;
    const base = count_tagged(&lt, sink, &stacks);
    try std.testing.expect(base > 0 and base < 60);
    try std.testing.expectEqualStrings("tagA", fx.seen_tags);

    fx.answer = 1.0;
    const full = count_tagged(&lt, sink, &stacks);
    try std.testing.expect(full > base);

    fx.answer = 0;
    const none = count_tagged(&lt, sink, &stacks);
    try std.testing.expectEqual(@as(usize, 0), none);
}

test "qty_scale scales spawned counts and drops zeroed stacks" {
    // `SpawnItem` applies `(int)GetValue(81 LootQuantity)` per spawned stack.
    const src =
        \\<lootcontainers>
        \\<lootcontainer name="qtyc" size="6,1">
        \\  <item name="tenThing" count="10,10"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const Fx = struct {
        mult: f32 = 1.0,
        seen_name: []const u8 = "",
        fn scale(ctx: ?*anyopaque, item_name: []const u8, entry_tags: []const u8, base: u16) u16 {
            const f: *@This() = @ptrCast(@alignCast(ctx.?));
            f.seen_name = item_name;
            _ = entry_tags;
            return @intFromFloat(@as(f32, @floatFromInt(base)) * f.mult);
        }
    };
    var stacks: [4]Stack = undefined;
    var fx: Fx = .{};
    const sink = QtyScale{ .ctx = &fx, .scale = Fx.scale };
    const n = lt.rollContainer("qtyc", 1, 7, &stacks, .{ .qty_scale = sink });
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("tenThing", fx.seen_name);
    try std.testing.expectEqual(@as(u16, 10), stacks[0].count);
    // Without a sink the count passes through untouched.
    const m = lt.rollContainer("qtyc", 1, 7, &stacks, .{});
    try std.testing.expectEqual(@as(usize, 1), m);
    try std.testing.expectEqual(@as(u16, 10), stacks[0].count);
    // A zeroed scale drops the stack (stock IL_0058 early-out).
    fx.mult = 0;
    const z = lt.rollContainer("qtyc", 1, 7, &stacks, .{ .qty_scale = sink });
    try std.testing.expectEqual(@as(usize, 0), z);
}

test "random_durability marks the stack and the wear formula matches stock" {
    // LootContainer IL_032D: `UseTimes = (int)(MaxUseTimes * RandomRange(0.2,
    // 0.8))`. The roll only marks the stack; the fill path owns MaxUseTimes.
    try std.testing.expectEqual(@as(f32, 0), randomUseTimes(0, 12345));
    var s: u32 = 1;
    while (s <= 200) : (s += 1) {
        const v = randomUseTimes(100, s);
        try std.testing.expect(v >= 20 and v <= 80);
        try std.testing.expectEqual(v, randomUseTimes(100, s)); // deterministic
    }
    // An absurd cap saturates the cast instead of trapping.
    try std.testing.expect(randomUseTimes(std.math.maxInt(u32), 7) > 0);

    const src =
        \\<lootgroups>
        \\<lootgroup name="duraGroup" count="all">
        \\  <item name="toolWorn" random_durability="true"/>
        \\  <item name="toolPristine" random_durability="false"/>
        \\  <item name="toolPlain"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const g = lt.groupByName("duraGroup").?;
    try std.testing.expect(g.entries[0].random_durability);
    try std.testing.expect(!g.entries[1].random_durability);
    try std.testing.expect(!g.entries[2].random_durability);
    var stacks: [8]Stack = undefined;
    const n = lt.rollGroup("duraGroup", 1, 7, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(stacks[0].random_durability);
    try std.testing.expect(!stacks[1].random_durability);
    try std.testing.expect(!stacks[2].random_durability);
}

test "loot entry buffs are reported only for spawned entries" {
    // Stock collects a spawned entry's `buffsToAdd` during the roll and applies
    // the list to the opener after it (`ExecuteBuffActions`). The sink reports
    // exactly the entries that spawned: a gated entry that refuses reports
    // nothing, an ungated sibling still does.
    const src =
        \\<lootgroups>
        \\<lootgroup name="buffGroup" count="all">
        \\  <item name="bookA" buffs="buffPerkBookwormSuccess"/>
        \\  <item name="bookB" buffs="buffX,buffY">
        \\    <requirement class="Progression" name="perkTreasureHunter" operation="GTE" value="4"/>
        \\  </item>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    try std.testing.expectEqualStrings("buffPerkBookwormSuccess", lt.groupByName("buffGroup").?.entries[0].buffs);

    const Rec = struct {
        n: usize = 0,
        names: [8][]const u8 = .{""} ** 8,
        fn add(ctx: ?*anyopaque, name: []const u8) void {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            if (r.n < r.names.len) {
                r.names[r.n] = name;
                r.n += 1;
            }
        }
    };
    var stacks: [8]Stack = undefined;
    var rec: Rec = .{};
    const sink = LootBuffSink{ .ctx = &rec, .add = Rec.add };

    // No opener: the Progression gate refuses, so only bookA's buff is seen.
    _ = lt.rollGroup("buffGroup", 1, 7, &stacks, 0, "", .{ .buffs = sink });
    try std.testing.expectEqual(@as(usize, 1), rec.n);
    try std.testing.expectEqualStrings("buffPerkBookwormSuccess", rec.names[0]);

    // A level-4 opener: both entries spawn and all three names are reported.
    const levels = [_]requirements.NameLevel{.{ .name = "perkTreasureHunter", .level = 4 }};
    const player: requirements.Ctx = .{ .levels = &levels };
    rec = .{};
    _ = lt.rollGroup("buffGroup", 1, 7, &stacks, 0, "", .{ .player = player, .buffs = sink });
    try std.testing.expectEqual(@as(usize, 3), rec.n);
    try std.testing.expectEqualStrings("buffPerkBookwormSuccess", rec.names[0]);
    try std.testing.expectEqualStrings("buffX", rec.names[1]);
    try std.testing.expectEqualStrings("buffY", rec.names[2]);
}

test "loot_stage_count_mod grows the count with the loot stage" {
    // LootContainer IL_017F: count += RoundToInt(count * lootstageCountMod *
    // lootStage), applied to the sandbox-scaled count. Stock's 84 uses are all
    // 0.01 on ammo rows.
    const src =
        \\<lootgroups>
        \\<lootgroup name="ammoGroup" count="all">
        \\  <item name="ammoBox" count="10" loot_stage_count_mod="0.01"/>
        \\  <item name="ammoPlain" count="10"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const g = lt.groupByName("ammoGroup").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), g.entries[0].loot_stage_count_mod, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), g.entries[1].loot_stage_count_mod);

    var stacks: [8]Stack = undefined;
    // Stage 0 (the no-gamestage floor): nothing added.
    var n = lt.rollGroup("ammoGroup", 0, 5, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    for (stacks[0..n]) |st| try std.testing.expectEqual(@as(u16, 10), st.count);
    // Stage 50: 10 + round(10 * 0.01 * 50) = 15 for the modded entry only.
    n = lt.rollGroup("ammoGroup", 50, 5, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    for (stacks[0..n]) |st| {
        if (std.mem.eql(u8, st.item_name, "ammoBox")) {
            try std.testing.expectEqual(@as(u16, 15), st.count);
        } else {
            try std.testing.expectEqual(@as(u16, 10), st.count);
        }
    }
}

test "stock loot entries carry loot_stage_count_mod on ammo groups" {
    // Guards the attribute name/parse against a stock update: group9mmSmall's
    // rounds carry the 0.01 stage growth.
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    const g = lt.groupByName("group9mmSmall") orelse return error.TestUnexpectedResult;
    var seen: usize = 0;
    for (g.entries[0..g.entry_n]) |e| {
        if (e.loot_stage_count_mod > 0) {
            try std.testing.expectApproxEqAbs(@as(f32, 0.01), e.loot_stage_count_mod, 1e-6);
            seen += 1;
        }
    }
    try std.testing.expect(seen > 0);
}

test "loot entry quality overrides the quality template" {
    // 698 stock entries carry a single `quality="1..6"`. Stock seeds the
    // entry's minQuality/maxQuality from the caller and a `quality` attribute
    // overrides them, so the entry spawns at that fixed quality instead of the
    // template roll.
    const src =
        \\<lootcontainers>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,999999" default_quality="1">
        \\    <loot quality="1" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="fixedQ">
        \\  <item name="weaponFixed" quality="6"/>
        \\  <item name="weaponTemplate"/>
        \\</lootgroup>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    const g = t.groupByName("fixedQ").?;
    try std.testing.expectEqual(@as(u8, 6), g.entries[0].quality);
    try std.testing.expectEqual(@as(u8, 0), g.entries[1].quality);

    // The template alone always yields quality 1 here; the fixed entry must
    // still come out at 6 with the group's template inherited (count="all").
    const src2 =
        \\<lootgroups>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,999999" default_quality="1">
        \\    <loot quality="1" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="allFixed" count="all" loot_quality_template="qualTest">
        \\  <item name="weaponFixed" quality="6"/>
        \\  <item name="weaponTemplate"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var t2 = try loadFromSlice(std.testing.allocator, src2);
    defer t2.deinit();
    var stacks: [8]Stack = undefined;
    const n = t2.rollGroup("allFixed", 1, 42, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    for (stacks[0..n]) |st| {
        if (std.mem.eql(u8, st.item_name, "weaponFixed")) {
            try std.testing.expectEqual(@as(u8, 6), st.quality);
        } else {
            try std.testing.expectEqual(@as(u8, 1), st.quality);
        }
    }
}

test "loot quality template rolls quality by loot stage" {
    const src =
        \\<lootcontainers>
        \\<lootqualitytemplate name="qualTest">
        \\  <qualitytemplate level="0,9" default_quality="1">
        \\    <loot quality="1" prob="0.5"/>
        \\    <loot quality="2" prob="1"/>
        \\  </qualitytemplate>
        \\  <qualitytemplate level="10,999999" default_quality="6">
        \\    <loot quality="4" prob="0.1"/>
        \\    <loot quality="6" prob="1"/>
        \\  </qualitytemplate>
        \\</lootqualitytemplate>
        \\<lootgroup name="g">
        \\  <item name="weaponA"/>
        \\</lootgroup>
        \\<lootcontainer name="c" size="6,2" loot_quality_template="qualTest">
        \\  <item name="weaponA"/>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.quality_templates.len);
    try std.testing.expectEqualStrings("qualTest", t.containerByName("c").?.quality_template);
    // Stage 1: band 0-9, picks 1 (p.5) then 2 (p1) - quality in {1,2}.
    var stacks: [16]Stack = undefined;
    var saw_hi = false;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const n = t.rollContainer("c", 1, 9000 + i, &stacks, .{});
        for (stacks[0..n]) |s| {
            try std.testing.expect(s.quality == 1 or s.quality == 2);
            if (s.quality == 2) saw_hi = true;
        }
    }
    try std.testing.expect(saw_hi);
    // Stage 15: band 10+, picks 4 (p.1) then 6 (p1) - quality in {4,6}.
    var saw_6 = false;
    i = 0;
    while (i < 200) : (i += 1) {
        const n = t.rollContainer("c", 15, 7000 + i, &stacks, .{});
        for (stacks[0..n]) |s| {
            try std.testing.expect(s.quality == 4 or s.quality == 6);
            if (s.quality == 6) saw_6 = true;
        }
    }
    try std.testing.expect(saw_6);
    std.debug.print("PASS loot quality: template rolls quality by loot stage\n", .{});
}

test "count=all groups spawn every entry; force_prob gates independently" {
    const src =
        \\<lootcontainers>
        \\<lootgroup name="allGroup" count="all">
        \\  <item name="a" prob="0"/>
        \\  <item name="b" prob="0.0001"/>
        \\  <item name="c" prob="1"/>
        \\  <item name="gated" prob="1" force_prob="true"/>
        \\</lootgroup>
        \\<lootgroup name="pickGroup" count="1">
        \\  <item name="x" force_prob="true" prob="0"/>
        \\  <item name="y" force_prob="true" prob="1"/>
        \\  <item name="z"/>
        \\</lootgroup>
        \\</lootcontainers>
    ;
    var t = try loadFromSlice(std.testing.allocator, src);
    defer t.deinit();
    const ag = t.groupByName("allGroup").?;
    try std.testing.expect(ag.pick_all);
    try std.testing.expectEqual(@as(u8, 4), ag.entry_n);
    // count="all": every entry spawns once regardless of prob; the force_prob
    // entry gates on its own prob (1 here so it stays).
    var stacks: [16]Stack = undefined;
    const n = t.rollGroup("allGroup", 1, 7, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 4), n);
    var saw_all = true;
    for ([_][]const u8{ "a", "b", "c", "gated" }) |want| {
        var seen = false;
        for (stacks[0..n]) |s| {
            if (std.mem.eql(u8, s.item_name, want)) seen = true;
        }
        if (!seen) saw_all = false;
    }
    try std.testing.expect(saw_all);
    // force_prob prob=0 is never picked from the pick pool.
    var s2: [16]Stack = undefined;
    var i: u32 = 0;
    var saw_x = false;
    while (i < 200) : (i += 1) {
        const n2 = t.rollGroup("pickGroup", 1, 1000 + i, &s2, 0, "", .{});
        for (s2[0..n2]) |s| {
            if (std.mem.eql(u8, s.item_name, "x")) saw_x = true;
        }
    }
    try std.testing.expect(!saw_x);
    std.debug.print("PASS loot: count=all spawns every entry, force_prob gates\n", .{});
}

test "stock groups parse past the old 32-entry cap (perkBooks)" {
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // perkBooks has 133 entries; the cap must not truncate stock groups.
    if (t.groupByName("perkBooks")) |g| {
        try std.testing.expect(g.entry_n >= 100);
        try std.testing.expect(g.entry_n <= max_entries);
    }
}

test "loot rolls stay deterministic for a given stage and seed" {
    const t = LootTable.builtin();
    var a: [max_roll_stacks]Stack = undefined;
    var b: [max_roll_stacks]Stack = undefined;
    const na = t.rollContainer("woodenChest", 37, 99, &a, .{});
    const nb = t.rollContainer("woodenChest", 37, 99, &b, .{});
    try std.testing.expectEqual(na, nb);
    for (a[0..na], b[0..nb]) |x, y| {
        try std.testing.expectEqualStrings(x.item_name, y.item_name);
        try std.testing.expectEqual(x.count, y.count);
    }
    // Stage 0 and the i32 extremes must not trap.
    _ = t.rollContainer("woodenChest", 0, 1, &a, .{});
    _ = t.rollContainer("woodenChest", std.math.minInt(i32), 1, &a, .{});
    _ = t.rollContainer("woodenChest", std.math.maxInt(i32), 1, &a, .{});
}

test "stock loot prob templates load and band the real items" {
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.prob_templates.len > 10);
    // loot_settings ships five POI tiers.
    try std.testing.expectEqual(@as(usize, 5), t.poi_tier_mod.len);
    try std.testing.expectEqual(@as(usize, 5), t.poi_tier_bonus.len);
    // At least one item row must reference a template, else the resolve step
    // silently did nothing.
    var referenced: usize = 0;
    for (t.groups) |g| {
        var i: u8 = 0;
        while (i < g.entry_n) : (i += 1) {
            if (g.entries[i].prob_template != 0) referenced += 1;
        }
    }
    try std.testing.expect(referenced > 100);
    // ProbT0's documented mid band: level 20,21 → prob 1.
    for (t.prob_templates) |p| {
        if (!std.mem.eql(u8, p.name, "ProbT0")) continue;
        var hit = false;
        for (p.bands) |b| {
            if (b.min_level == 20 and b.max_level == 21) {
                try std.testing.expectApproxEqAbs(@as(f32, 1), b.prob, 0.0001);
                hit = true;
            }
        }
        try std.testing.expect(hit);
    }
}

test "reward group rolls fixed first picks or prob-weighted choices" {
    const xml_text =
        \\<loot>
        \\  <lootgroup name="groupQuestWeapons">
        \\    <item name="gunPistolT2" count="1" prob="1"/>
        \\    <item name="gunRifleT2" count="1" prob="1"/>
        \\    <item name="meleeClubT2" count="1" prob="1"/>
        \\  </lootgroup>
        \\</loot>
    ;
    var lt = try loadFromSlice(std.testing.allocator, xml_text);
    defer lt.deinit();
    var stacks: [8]Stack = undefined;
    // isfixed: the first two entries, deterministic.
    const nf = lt.rollGroupPicks("groupQuestWeapons", 1, 42, 2, true, &stacks, .{});
    try std.testing.expectEqual(@as(usize, 2), nf);
    try std.testing.expectEqualStrings("gunPistolT2", stacks[0].item_name);
    try std.testing.expectEqualStrings("gunRifleT2", stacks[1].item_name);
    // Weighted picks: each pick resolves to one of the three.
    const nw = lt.rollGroupPicks("groupQuestWeapons", 1, 42, 3, false, &stacks, .{});
    try std.testing.expectEqual(@as(usize, 3), nw);
    var i: usize = 0;
    while (i < nw) : (i += 1) {
        try std.testing.expect(std.mem.eql(u8, stacks[i].item_name, "gunPistolT2") or
            std.mem.eql(u8, stacks[i].item_name, "gunRifleT2") or
            std.mem.eql(u8, stacks[i].item_name, "meleeClubT2"));
    }
    // Unknown group returns nothing (fail closed).
    try std.testing.expectEqual(@as(usize, 0), lt.rollGroupPicks("noSuchGroup", 1, 1, 1, false, &stacks, .{}));
}

test "container group rolls are prob-weighted, not uniform" {
    // Stock LootContainer probability: an entry's prob weights it relative
    // to the group sum, so a 0.9 item drops ~9x as often as a 0.1 one and a
    // 0-prob item never drops. The old rollGroup picked a uniform index.
    const xml_text =
        \\<loot>
        \\  <lootgroup name="gWeighted">
        \\    <item name="commonItem" count="1" prob="0.9"/>
        \\    <item name="rareItem" count="1" prob="0.1"/>
        \\    <item name="neverItem" count="1" prob="0"/>
        \\  </lootgroup>
        \\  <lootcontainer name="cWeighted" count="1" loot_quality_template="qualityNoTier">
        \\    <item group="gWeighted"/>
        \\  </lootcontainer>
        \\</loot>
    ;
    var lt = try loadFromSlice(std.testing.allocator, xml_text);
    defer lt.deinit();
    var stacks: [8]Stack = undefined;
    var common: usize = 0;
    var rare: usize = 0;
    var never: usize = 0;
    var s: u32 = 1;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        s = s *% 1103515245 +% 12345;
        const n = lt.rollContainer("cWeighted", 1, s, &stacks, .{});
        try std.testing.expectEqual(@as(usize, 1), n);
        if (std.mem.eql(u8, stacks[0].item_name, "commonItem")) {
            common += 1;
        } else if (std.mem.eql(u8, stacks[0].item_name, "rareItem")) {
            rare += 1;
        } else {
            never += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), never);
    // ~90/10 split with a wide tolerance band (no flaky seed edge).
    try std.testing.expect(common > rare * 4);
    try std.testing.expect(common + rare == 4000);
}

test "stock loot.xml container flags parse" {
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    // unique_item + destroy_on_close="empty" on the reachable quest rewards.
    const mags = lt.containerByName("questRewardSkillMagazines").?;
    try std.testing.expect(mags.unique_item);
    try std.testing.expectEqual(@as(u8, 2), mags.destroy_on_close);
    // ignore_loot_abundance on a twitch carrier.
    const tw = lt.containerByName("twitch_tier0weapon").?;
    try std.testing.expect(tw.ignore_abundance);
}

test "stock loot: a requirement-gated entry is omitted, not rolled at 100%" {
    // `groupWorkingStiffsCrate` carries `<item group="groupWorkingStiffsBooks"
    // count="1">` with a `<requirement class="RandomRoll" value=
    // "@$perkBookwormChance">` child. Stock evaluates the roll against the cvar
    // (absent without perkBookworm = 0, so the gate refuses); the entry has no
    // `prob`, i.e. 1.0, so ignoring the requirement put a book in every crate.
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();

    const crate = lt.groupByName("groupWorkingStiffsCrate") orelse return error.SkipZigTest;
    var gated = false;
    for (crate.entries[0..crate.entry_n]) |e| {
        if (std.mem.eql(u8, e.name, "groupWorkingStiffsBooks")) {
            try std.testing.expectEqual(GateKind.random_roll, e.gate.kind);
            try std.testing.expectEqualStrings("perkBookwormChance", e.gate.value_cvar);
            try std.testing.expectEqual(requirements.Compare.le, e.gate.op);
            gated = true;
        } else if (std.mem.eql(u8, e.name, "groupWorkingStiffs01")) {
            try std.testing.expectEqual(GateKind.none, e.gate.kind);
        }
    }
    try std.testing.expect(gated);

    // The roll proof uses a fixture: the stock crate also reaches
    // groupWorkingStiffsBooks through the ungated groupWorkingStiffs03, so a
    // name scan over a real crate roll cannot isolate this gate.
    const cvars = @import("cvars.zig");
    const src =
        \\<loot>
        \\<lootgroup name="gatedCrate" count="all">
        \\  <item group="gatedBooks" count="1">
        \\    <requirement class="RandomRoll" min_max="0,100" operation="LTE" value="@$perkBookwormChance"/>
        \\  </item>
        \\  <item name="filler" count="1"/>
        \\</lootgroup>
        \\<lootgroup name="gatedBooks" count="1">
        \\  <item name="aBook"/>
        \\</lootgroup>
        \\</loot>
    ;
    var ft = try loadFromSlice(std.testing.allocator, src);
    defer ft.deinit();
    var stacks: [max_roll_stacks]Stack = undefined;
    // No opener: the RandomRoll refuses, so only the filler spawns.
    var seed: u32 = 1;
    while (seed <= 100) : (seed += 1) {
        const n = ft.rollGroup("gatedCrate", 1, seed, &stacks, 0, "", .{});
        try std.testing.expect(n >= 1);
        for (stacks[0..n]) |st| {
            try std.testing.expect(!std.mem.eql(u8, st.item_name, "aBook"));
        }
    }
    // With the cvar at 100 the gate passes and the book group rolls.
    var store: cvars.Set = .{};
    _ = store.apply("perkBookwormChance", .set, 100);
    const player: requirements.Ctx = .{ .cvars = &store };
    var saw_book = false;
    seed = 1;
    while (seed <= 100) : (seed += 1) {
        const n = ft.rollGroup("gatedCrate", 1, seed, &stacks, 0, "", .{ .player = player });
        for (stacks[0..n]) |st| {
            if (std.mem.eql(u8, st.item_name, "aBook")) saw_book = true;
        }
    }
    try std.testing.expect(saw_book);
}

test "stock loot: a Biome-gated entry rolls in its biome, omitted elsewhere" {
    // `groupShamwaySafe` (count="all") carries
    // `<item name="plantedGraceCorn1Schematic"><requirement class="Biome"
    // biomes="wasteland"/></item>` next to a RandomRoll-gated book group. The
    // biome gate is answerable at roll time (the container's own biome), so it
    // resolves; the RandomRoll stays omitted until its cvar exists.
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var lt = try loadFromPath(std.testing.allocator, path);
    defer lt.deinit();
    const g = lt.groupByName("groupShamwaySafe") orelse return error.SkipZigTest;
    var saw_biome = false;
    var saw_other = false;
    for (g.entries[0..g.entry_n]) |e| {
        if (std.mem.eql(u8, e.name, "plantedGraceCorn1Schematic")) {
            try std.testing.expectEqual(GateKind.biome, e.gate.kind);
            try std.testing.expectEqualStrings("wasteland", e.gate.biomes);
            saw_biome = true;
        }
        if (std.mem.eql(u8, e.name, "booksAllScaled")) {
            try std.testing.expectEqual(GateKind.random_roll, e.gate.kind);
            saw_other = true;
        }
    }
    try std.testing.expect(saw_biome and saw_other);

    var stacks: [32]Stack = undefined;
    const in_biome = lt.rollGroup("groupShamwaySafe", 1, 7, &stacks, 0, "", .{ .biome_name = "wasteland" });
    var got_corn = false;
    for (stacks[0..in_biome]) |st| {
        if (std.mem.eql(u8, st.item_name, "plantedGraceCorn1Schematic")) got_corn = true;
    }
    try std.testing.expect(got_corn);
    const off_biome = lt.rollGroup("groupShamwaySafe", 1, 7, &stacks, 0, "", .{ .biome_name = "forest" });
    for (stacks[0..off_biome]) |st| {
        try std.testing.expect(!std.mem.eql(u8, st.item_name, "plantedGraceCorn1Schematic"));
    }
    // No biome in the ctx: the gate cannot be answered, so it is omitted.
    const no_ctx = lt.rollGroup("groupShamwaySafe", 1, 7, &stacks, 0, "", .{});
    for (stacks[0..no_ctx]) |st| {
        try std.testing.expect(!std.mem.eql(u8, st.item_name, "plantedGraceCorn1Schematic"));
    }

    // The evaluator itself: ungated always, biome by name, other never.
    try std.testing.expect((EntryGate{}).allowed(.{}));
    try std.testing.expect(!(EntryGate{ .kind = .other }).allowed(.{ .biome_name = "wasteland" }));
    try std.testing.expect((EntryGate{ .kind = .biome, .biomes = "forest,wasteland" }).allowed(.{ .biome_name = "wasteland" }));
    try std.testing.expect(!(EntryGate{ .kind = .biome, .biomes = "forest" }).allowed(.{ .biome_name = "wasteland" }));
    try std.testing.expect(!(EntryGate{ .kind = .biome, .biomes = "forest" }).allowed(.{}));
}

test "loot requirement gates: Progression, CVar, RandomRoll and SandboxOption" {
    // `LootEntryRequirementProgression` / `CVar` / `RandomRoll` read the
    // opening player's state. The evaluator takes the same requirements.Ctx the
    // buff/perk VM uses, so the progression and cvar semantics live in one
    // place. A missing opener ctx leaves every one of them refused (the entry
    // stays omitted), which is the pre-evaluator behaviour.
    const cvars = @import("cvars.zig");
    var store: cvars.Set = .{};
    _ = store.apply("perkBookwormChance", .set, 50);
    _ = store.apply("perkBookworm", .set, 1);
    const levels = [_]requirements.NameLevel{
        .{ .name = "perkTreasureHunter", .level = 5 },
    };
    const player: requirements.Ctx = .{ .levels = &levels, .cvars = &store };
    const no_player: LootGateCtx = .{};

    // Progression: GTE 4 passes at level 5, fails at a level below it, and an
    // unknown progression name fails closed (stock ProgressionLevel refuses).
    const prog = EntryGate{ .kind = .progression, .arg = "perkTreasureHunter", .op = .ge, .value = 4 };
    try std.testing.expect(prog.allowed(.{ .player = player }));
    try std.testing.expect(!prog.allowed(no_player));
    const prog_hi = EntryGate{ .kind = .progression, .arg = "perkTreasureHunter", .op = .ge, .value = 6 };
    try std.testing.expect(!prog_hi.allowed(.{ .player = player }));
    const prog_eq5 = EntryGate{ .kind = .progression, .arg = "perkTreasureHunter", .op = .eq, .value = 5 };
    try std.testing.expect(prog_eq5.allowed(.{ .player = player }));
    const prog_unknown = EntryGate{ .kind = .progression, .arg = "perkNope", .op = .ge, .value = 1 };
    try std.testing.expect(!prog_unknown.allowed(.{ .player = player }));

    // CVar: EQ 1 passes on the set cvar, fails on another value/name.
    const cvar = EntryGate{ .kind = .cvar, .arg = "perkBookworm", .op = .eq, .value = 1 };
    try std.testing.expect(cvar.allowed(.{ .player = player }));
    const cvar_zero = EntryGate{ .kind = .cvar, .arg = "perkBookworm", .op = .eq, .value = 0 };
    try std.testing.expect(!cvar_zero.allowed(.{ .player = player }));

    // RandomRoll (`min_max="0,100" operation="LTE" value="@$perkBookwormChance"`):
    // LeftSide = Lerp(min, max, roll), RightSide = the cvar. chance 50 passes at
    // roll 0.5 and fails at 0.6; chance 100 always passes; chance 0 passes only
    // at roll 0 (the stock `RandomFloat` boundary).
    const roll50 = EntryGate{
        .kind = .random_roll,
        .op = .le,
        .value_cvar = "perkBookwormChance",
        .min_max = .{ 0, 100 },
    };
    try std.testing.expect(roll50.allowed(.{ .player = player, .roll = 0.5 }));
    try std.testing.expect(!roll50.allowed(.{ .player = player, .roll = 0.6 }));
    try std.testing.expect(!roll50.allowed(no_player));
    var zero_store: cvars.Set = .{};
    _ = zero_store.apply("perkBookwormChance", .set, 0);
    const zero_player: requirements.Ctx = .{ .levels = &levels, .cvars = &zero_store };
    try std.testing.expect(roll50.allowed(.{ .player = zero_player, .roll = 0 }));
    try std.testing.expect(!roll50.allowed(.{ .player = zero_player, .roll = 0.01 }));
    // A literal value (a modded row) needs no cvar.
    const roll_lit = EntryGate{ .kind = .random_roll, .op = .le, .value = 25, .min_max = .{ 0, 100 } };
    try std.testing.expect(roll_lit.allowed(.{ .player = player, .roll = 0.2 }));
    try std.testing.expect(!roll_lit.allowed(.{ .player = player, .roll = 0.3 }));

    // SandboxOption compares the option's value under the decoded code. Stock
    // `HarvestingOutput EQ 0` means "output disabled": a boolean-truthiness
    // test would pass where it must fail, so pin both polarities.
    const sb = @import("sandbox.zig");
    const ho = sb.optionByName("HarvestingOutput").?;
    const gate_off = EntryGate{ .kind = .sandbox, .arg = "HarvestingOutput", .op = .eq, .value = 0 };
    const gate_on = EntryGate{ .kind = .sandbox, .arg = "HarvestingOutput", .op = .eq, .value = 1 };
    // Code index 0 = the option's first value set entry (0 = disabled).
    const groups_off = [_]sb.Group{.{ .option_id = ho.id, .index = 0 }};
    const off_ctx: requirements.Ctx = .{ .levels = &levels, .cvars = &store, .sandbox_groups = &groups_off };
    try std.testing.expect(gate_off.allowed(.{ .player = off_ctx }));
    try std.testing.expect(!gate_on.allowed(.{ .player = off_ctx }));
    // The index whose LootAbundanceValues entry is 1.0 (the stock "100%").
    const ho_set = sb.findSet(ho.set_name).?;
    var one_idx: u8 = 0;
    for (ho_set.floats, 0..) |f, i| {
        if (f == 1.0) {
            one_idx = @intCast(i);
            break;
        }
    }
    const groups_on = [_]sb.Group{.{ .option_id = ho.id, .index = one_idx }};
    const on_ctx: requirements.Ctx = .{ .levels = &levels, .cvars = &store, .sandbox_groups = &groups_on };
    try std.testing.expect(!gate_off.allowed(.{ .player = on_ctx }));
    try std.testing.expect(gate_on.allowed(.{ .player = on_ctx }));
    // Unknown option / no opener refuse.
    const gate_bad = EntryGate{ .kind = .sandbox, .arg = "NoSuchOption", .op = .eq, .value = 0 };
    try std.testing.expect(!gate_bad.allowed(.{ .player = off_ctx }));
    try std.testing.expect(!gate_off.allowed(no_player));
}

test "loot requirement gates: parse the stock shapes from XML" {
    const src =
        \\<lootcontainers>
        \\<lootcontainer name="gateTest" size="8,1" count="2">
        \\  <item name="casinoCoin" count="100,200">
        \\    <requirement class="Progression" name="perkTreasureHunter" operation="GTE" value="4"/>
        \\  </item>
        \\  <item name="resourceScrapIron">
        \\    <requirement class="RandomRoll" seed_type="Random" min_max="0,100" operation="LTE" value="@$perkBookwormChance"/>
        \\  </item>
        \\  <item name="resourceScrapBrass">
        \\    <requirement class="CVar" cvar="perkBookworm" operation="Equals" value="1"/>
        \\  </item>
        \\  <item name="resourceScrapLead">
        \\    <requirement class="SandboxOption" option="HarvestingOutput" operation="EQ" value="0"/>
        \\  </item>
        \\</lootcontainer>
        \\</lootcontainers>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const c = lt.containerByName("gateTest") orelse return error.TestUnexpectedResult;
    // Entry order is document order; each gate keeps the class it parsed.
    try std.testing.expectEqual(GateKind.progression, c.entries[0].gate.kind);
    try std.testing.expectEqualStrings("perkTreasureHunter", c.entries[0].gate.arg);
    try std.testing.expectEqual(requirements.Compare.ge, c.entries[0].gate.op);
    try std.testing.expectEqual(@as(f32, 4), c.entries[0].gate.value);
    try std.testing.expectEqual(GateKind.random_roll, c.entries[1].gate.kind);
    try std.testing.expectEqual(@as(f32, 0), c.entries[1].gate.min_max[0]);
    try std.testing.expectEqual(@as(f32, 100), c.entries[1].gate.min_max[1]);
    try std.testing.expectEqualStrings("perkBookwormChance", c.entries[1].gate.value_cvar);
    try std.testing.expectEqual(GateKind.cvar, c.entries[2].gate.kind);
    try std.testing.expectEqualStrings("perkBookworm", c.entries[2].gate.arg);
    // "Equals" is a stock spelling of EQ (OperationTypes).
    try std.testing.expectEqual(requirements.Compare.eq, c.entries[2].gate.op);
    // SandboxOption parses its option name and compares numerically.
    try std.testing.expectEqual(GateKind.sandbox, c.entries[3].gate.kind);
    try std.testing.expectEqualStrings("HarvestingOutput", c.entries[3].gate.arg);
    try std.testing.expectEqual(requirements.Compare.eq, c.entries[3].gate.op);
    try std.testing.expectEqual(@as(f32, 0), c.entries[3].gate.value);
}

test "abundance_type maps to the stock sandbox count options" {
    // RE loot-economy.md 8.3: `GetCountMultiplierFromSandbox(AbundanceLootModTypes)`
    // -> the per-category count modifier; the option names are the stock
    // `*LootCount` sandbox options.
    try std.testing.expectEqualStrings("FoodLootCount", abundanceOptionName("Food").?);
    try std.testing.expectEqualStrings("DrinkLootCount", abundanceOptionName("Drinks").?);
    try std.testing.expectEqualStrings("AmmoLootCount", abundanceOptionName("Ammo").?);
    try std.testing.expectEqualStrings("MedicalLootCount", abundanceOptionName("Meds").?);
    try std.testing.expectEqualStrings("ResourceLootCount", abundanceOptionName("Resources").?);
    try std.testing.expectEqualStrings("ArmorLootCount", abundanceOptionName("Armor").?);
    try std.testing.expectEqualStrings("MeleeLootCount", abundanceOptionName("Melee").?);
    try std.testing.expectEqualStrings("RangedLootCount", abundanceOptionName("Ranged").?);
    try std.testing.expectEqualStrings("DukesLootCount", abundanceOptionName("Dukes").?);
    try std.testing.expectEqualStrings("CraftingMagazinesLootCount", abundanceOptionName("Magazines").?);
    try std.testing.expectEqualStrings("BookLootCount", abundanceOptionName("Books").?);
    try std.testing.expect(abundanceOptionName("None") == null);
    try std.testing.expect(abundanceOptionName("nonsense") == null);
    // Every mapped option exists in the stock sandbox table and is a float in
    // the LootAbundanceValues set (the modifier is a multiplier, not a percent).
    const names = [_][]const u8{
        "FoodLootCount",     "DrinkLootCount",             "AmmoLootCount",  "MedicalLootCount",
        "ResourceLootCount", "ArmorLootCount",             "MeleeLootCount", "RangedLootCount",
        "DukesLootCount",    "CraftingMagazinesLootCount", "BookLootCount",
    };
    for (names) |n| {
        const o = sandbox.optionByName(n) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("LootAbundanceValues", o.set_name);
        try std.testing.expectEqual(sandbox.Kind.float, o.kind);
    }
}

test "abundance_type scales the group's counts from the sandbox code" {
    const src =
        \\<lootgroups>
        \\<lootgroup name="bookGroup" count="all" abundance_type="Books">
        \\  <item name="resourceWood" count="100"/>
        \\</lootgroup>
        \\</lootgroups>
    ;
    var lt = try loadFromSlice(std.testing.allocator, src);
    defer lt.deinit();
    const g = lt.groupByName("bookGroup").?;
    try std.testing.expectEqualStrings("Books", g.abundance_type);

    var stacks: [max_roll_stacks]Stack = undefined;
    // No sandbox ctx: the factor is 1.0 and the count is the raw 100.
    const plain = lt.rollGroup("bookGroup", 1, 7, &stacks, 0, "", .{});
    try std.testing.expectEqual(@as(usize, 1), plain);
    try std.testing.expectEqual(@as(u16, 100), stacks[0].count);

    // A code carrying BookLootCount at half abundance: index 3 of
    // LootAbundanceValues = 0.5. The option id encodes to two base-26 letters,
    // so decode a real code string rather than hand-building the group.
    const opt = sandbox.optionByName("BookLootCount").?;
    var code_buf: [8]u8 = undefined;
    const code = std.fmt.bufPrint(&code_buf, "A{c}{c}D", .{
        @as(u8, 'A') + @as(u8, @intCast(opt.id / 26)),
        @as(u8, 'A') + @as(u8, @intCast(opt.id % 26)),
    }) catch unreachable;
    var decoded: [4]sandbox.Group = undefined;
    const decoded_n = sandbox.decode(code, &decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded_n);
    try std.testing.expectEqual(opt.id, decoded[0].option_id);
    try std.testing.expectEqual(@as(u8, 3), decoded[0].index);
    const half = decoded[0..1];
    const player: requirements.Ctx = .{ .sandbox_groups = half };
    const scaled = lt.rollGroup("bookGroup", 1, 7, &stacks, 0, "", .{ .player = player });
    try std.testing.expectEqual(@as(usize, 1), scaled);
    try std.testing.expect(stacks[0].count < 100 and stacks[0].count >= 1);

    // Index 0 = 0.0: the category is disabled and spawns none of it.
    const off = [_]sandbox.Group{.{ .option_id = opt.id, .index = 0 }};
    const off_ctx: requirements.Ctx = .{ .sandbox_groups = &off };
    const none = lt.rollGroup("bookGroup", 1, 7, &stacks, 0, "", .{ .player = off_ctx });
    try std.testing.expectEqual(@as(usize, 0), none);
}

test "stock loot groups drop the seven client-conditional holiday entries" {
    const path = stock_paths.configFile("loot.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // The seven rows all gate `groupHolidayGear` inside count="all" groups.
    for ([_][]const u8{
        "groupZpackBoss",
        "groupReinforcedChestT1",
        "groupReinforcedChestT2",
        "groupReinforcedChestT3",
        "groupHardenedChestT4",
        "groupHardenedChestT5",
        "groupHiddenStash",
    }) |gname| {
        const g = t.groupByName(gname) orelse return error.TestUnexpectedResult;
        var i: u8 = 0;
        while (i < g.entry_n) : (i += 1) {
            try std.testing.expect(!std.mem.eql(u8, g.entries[i].name, "groupHolidayGear"));
        }
    }
}

test "client-evaluated loot conditionals never reach the server tables" {
    // Stock runs XmlPatcher::ApplyConditionalXmlBlocks with an evaluator, so a
    // `<conditional evaluator="client">` block belongs to the client build
    // only. The seven stock rows are `event('christmas')` holiday-gear entries
    // inside count="all" groups; flattening them put a christmas item in every
    // Zpack boss, reinforced/hardened chest and hidden stash, all year.
    const src =
        \\<loot>
        \\  <lootgroup name="groupMixed" count="all">
        \\    <item name="resourceWood" count="1"/>
        \\    <conditional evaluator="client">
        \\      <if cond="event('christmas')">
        \\        <item group="groupHolidayGear" loot_prob_template="low" force_prob="true"/>
        \\      </if>
        \\    </conditional>
        \\    <item name="resourceRockSmall" count="1"/>
        \\  </lootgroup>
        \\  <lootgroup name="groupHolidayGear" count="1">
        \\    <item name="resourceWood" count="5"/>
        \\  </lootgroup>
        \\  <lootcontainer name="cntMixed" size="8,6" count="1">
        \\    <item group="groupMixed" count="1"/>
        \\    <conditional evaluator='client'>
        \\      <if cond="event('christmas')">
        \\        <item name="resourceRockSmall" count="3"/>
        \\      </if>
        \\    </conditional>
        \\  </lootcontainer>
        \\</loot>
    ;
    const path = ".zdtd_test_loot_conditional.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const g = t.groupByName("groupMixed").?;
    try std.testing.expectEqual(@as(u8, 2), g.entry_n);
    var i: u8 = 0;
    while (i < g.entry_n) : (i += 1) {
        try std.testing.expect(!std.mem.eql(u8, g.entries[i].name, "groupHolidayGear"));
    }
    const c = t.containerByName("cntMixed").?;
    try std.testing.expectEqual(@as(u8, 1), c.entry_n);
    try std.testing.expectEqualStrings("groupMixed", c.entries[0].name);
}
