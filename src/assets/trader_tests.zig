//! Trader catalog tests: rolls, quality, restock.
//!
//! Split out of assets/traders.zig (same tests, moved verbatim).

const std = @import("std");
const traders = @import("traders.zig");
const TraderTable = traders.TraderTable;
const RolledItem = traders.RolledItem;
const QualityPolicy = traders.QualityPolicy;
const parseRefsBody = traders.parseRefsBody;
const rng_util = @import("../util/rng.zig");
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");
const Group = traders.Group;
const ItemRef = traders.ItemRef;
const TraderInfo = traders.TraderInfo;
const loadFromPath = traders.loadFromPath;
const max_traders = traders.max_traders;

test "trader table parses stock traderAlways and group refs with attrs" {
    const path = stock_paths.configFile("traders.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.groups.len >= 5);
    try std.testing.expect(t.trader_always_refs.len >= 5);
    // Group refs keep their count ranges and unique_only (the old parser
    // dropped them): traderAlways lists groupDyeMods unique_only count=4.
    var saw_dye_unique = false;
    for (t.trader_always_refs) |r| {
        if (r.group and std.mem.eql(u8, r.name, "groupDyeMods")) {
            saw_dye_unique = r.unique_only and r.count_min == 4 and r.count_max == 4;
        }
    }
    try std.testing.expect(saw_dye_unique);
    // Ammo refs carry count ranges (40,150), and a prob-gated ref parses.
    var saw_ammo_range = false;
    var saw_prob = false;
    for (t.trader_always_refs) |r| {
        if (!r.group and std.mem.eql(u8, r.name, "ammoGasCan")) {
            saw_ammo_range = r.count_min == 5000 and r.count_max == 10000;
        }
    }
    if (t.groupByName("ammoAll")) |g| {
        for (g.refs) |r| {
            if (r.prob < 1) saw_prob = true;
        }
    }
    try std.testing.expect(saw_ammo_range);
    try std.testing.expect(saw_prob);
}

test "trader table parses trader_info blocks with per-trader items and attrs" {
    const path = stock_paths.configFile("traders.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // The five NPC traders (joel=1 jen=2 bob=6 hugh=7 rekt=8) plus vending
    // (4,10) and player-owned/rentable (3,5) all exist as trader_info blocks.
    try std.testing.expect(t.trader_infos.len >= 10);
    for ([_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) |want| {
        try std.testing.expect(t.traderInfo(want) != null);
    }
    // Joel (1): armor specialty + general blocks, refs preserved in order.
    const joel = t.traderInfo(1).?;
    try std.testing.expect(joel.open_time.len > 0);
    try std.testing.expectEqualStrings("4:05", joel.open_time);
    try std.testing.expectEqualStrings("21:50", joel.close_time);
    try std.testing.expect(!joel.is_vending);
    try std.testing.expect(joel.allow_sell);
    try std.testing.expect(joel.refs.len >= 10);
    var saw_armor_group = false;
    var saw_direct_name = false;
    for (joel.refs) |r| {
        if (r.group and std.mem.eql(u8, r.name, "groupArmorLight")) saw_armor_group = true;
        if (!r.group and std.mem.eql(u8, r.name, "armorParts")) saw_direct_name = true;
    }
    try std.testing.expect(saw_armor_group);
    try std.testing.expect(saw_direct_name);
    // Vending trader 4 is always open (no hours), does not buy from players.
    const vend = t.traderInfo(4).?;
    try std.testing.expect(vend.is_vending);
    try std.testing.expect(!vend.allow_sell);
    // Player-owned 3 and rentable 5 carry their flags; 5 has hours like the NPCs.
    const po = t.traderInfo(3).?;
    try std.testing.expect(po.player_owned);
    try std.testing.expect(!po.allow_sell);
    try std.testing.expectEqual(@as(f32, 1.0), po.override_buy_markup);
    const rent = t.traderInfo(5).?;
    try std.testing.expect(rent.rentable);
    try std.testing.expectEqual(@as(i32, 2500), rent.rent_cost);
    try std.testing.expectEqual(@as(i32, 30), rent.rent_time);
    // Jen (2) is a different list from Joel (1): roll both with a seeded rng
    // and the first rolled names differ (Jen sells food, Joel armor).
    const jen = t.traderInfo(2).?;
    var outj: [128]RolledItem = undefined;
    var rng_j = rng_util.XorShift32.init(7);
    const ojn = t.rollAllRefs(jen.refs, &rng_j, .{}, 1.0, &outj);
    try std.testing.expect(ojn > 0);
    var out_joel: [128]RolledItem = undefined;
    var rng_j2 = rng_util.XorShift32.init(7);
    const ojn2 = t.rollAllRefs(joel.refs, &rng_j2, .{}, 1.0, &out_joel);
    try std.testing.expect(ojn2 > 0);
    try std.testing.expect(!std.mem.eql(u8, out_joel[0].name, outj[0].name));
}

/// Names the roll tests treat as quality-bearing (the items-table stand-in).
const TestQualityNames = struct {
    names: []const []const u8,

    fn resolve(ctx: ?*anyopaque, name: []const u8) bool {
        const self: *const TestQualityNames = @ptrCast(@alignCast(ctx.?));
        for (self.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Stock-default policy (max_tier 6, fallback range 1..6). Tests that
    /// exercise the clamp override `max_tier` on the result.
    fn policy(self: *const TestQualityNames) QualityPolicy {
        return .{
            .has_quality = &resolve,
            .has_quality_ctx = @constCast(self),
        };
    }
};

test "roll stays deterministic and honours count ranges and unique_only" {
    const refs = [_]ItemRef{
        .{ .name = "ammoA", .count_min = 40, .count_max = 150 },
        .{ .name = "ammoB", .count_min = 1, .count_max = 1 },
        .{ .name = "gunA", .quality_lo = 2, .quality_hi = 6 },
    };
    const quality_names = TestQualityNames{ .names = &.{"gunA"} };
    const policy = quality_names.policy();
    var t = TraderTable.empty();
    var out: [16]RolledItem = undefined;
    var rng_a = rng_util.XorShift32.init(99);
    const n = t.rollAllRefs(&refs, &rng_a, policy, 1.0, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(out[0].count >= 40 and out[0].count <= 150);
    try std.testing.expectEqual(@as(u16, 1), out[1].count);
    try std.testing.expect(out[2].quality >= 2 and out[2].quality <= 6);
    // Same seed → same roll (deterministic sim input).
    var rng_b = rng_util.XorShift32.init(99);
    var out2: [16]RolledItem = undefined;
    const n2 = t.rollAllRefs(&refs, &rng_b, policy, 1.0, &out2);
    try std.testing.expectEqual(n, n2);
    for (out[0..n], out2[0..n2]) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.count, b.count);
        try std.testing.expectEqual(a.quality, b.quality);
    }
    // Sandbox abundance (TraderItemAbundance; the LowDefaultHigh set) scales
    // the rolled count, then floors at 1 - same seed, same roll first.
    var rng_c = rng_util.XorShift32.init(99);
    var out3: [16]RolledItem = undefined;
    const n3 = t.rollAllRefs(&refs, &rng_c, policy, 2.0, &out3);
    try std.testing.expectEqual(n, n3);
    try std.testing.expectEqual(out[0].count * 2, out3[0].count);
}

test "unique_only group picks distinct refs" {
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer {
        arena_holder.deinit();
        std.testing.allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    const items = [_]ItemRef{
        .{ .name = "modA", .prob = 100 },
        .{ .name = "modB", .prob = 100 },
        .{ .name = "modC", .prob = 100 },
    };
    const gname = arena.dupe(u8, "groupMods") catch return error.OutOfMemory;
    const g = Group{ .name = gname, .refs = &items, .count_min = 3, .count_max = 3, .unique_only = true };
    var t = TraderTable.empty();
    t.groups = &[_]Group{g};
    // The group ref: count=3 rounds × group count=3 picks = 9 picks from 3
    // items, unique → each item at most once per group roll, so at most 3
    // distinct names per roll and every name appears at most once per round.
    const refs = [_]ItemRef{.{ .name = gname, .group = true, .count_min = 3, .count_max = 3 }};
    var out: [16]RolledItem = undefined;
    var rng = rng_util.XorShift32.init(5);
    const n = t.rollAllRefs(&refs, &rng, .{}, 1.0, &out);
    try std.testing.expect(n >= 3);
    var seen: [3]bool = .{false} ** 3;
    for (out[0..n]) |r| {
        if (std.mem.eql(u8, r.name, "modA")) seen[0] = true;
        if (std.mem.eql(u8, r.name, "modB")) seen[1] = true;
        if (std.mem.eql(u8, r.name, "modC")) seen[2] = true;
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}

test "traderInfo fails closed on unset and out-of-range TraderIDs" {
    const infos = [_]TraderInfo{ .{ .id = 5, .rentable = true }, .{ .id = 0 } };
    const t: TraderTable = .{ .trader_infos = &infos };
    try std.testing.expect(t.traderInfo(5) != null);
    try std.testing.expect(t.traderInfo(6) == null);
    // blocks.xml floors an absent TraderID to 0, so 0 means "not declared"
    // even when a row claims that id.
    try std.testing.expect(t.traderInfo(0) == null);
    // A negative or past-u16 TraderID (patched blocks.xml, hand-edited vending
    // save) must miss the table, not trap in a narrowing cast at the caller.
    try std.testing.expect(t.traderInfo(-1) == null);
    try std.testing.expect(t.traderInfo(std.math.maxInt(u16) + 1) == null);
    try std.testing.expect(t.traderInfo(std.math.maxInt(i32)) == null);
}

test "trader_info scan survives adjacent blocks with no whitespace" {
    const xml_text =
        \\<traders>
        \\  <trader_item_group name="traderAlways"><item name="medicalBandage" count="3,5"/></trader_item_group>
        \\  <trader_info id="1" open_time="4:05" close_time="21:50"><trader_items><item name="armorParts"/></trader_items></trader_info><trader_info id="2" is_vending="true"><trader_items><item group="traderAlways"/></trader_items></trader_info>
        \\</traders>
    ;
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer {
        arena_holder.deinit();
        std.testing.allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    const clean = try xml.stripComments(std.testing.allocator, xml_text);
    defer std.testing.allocator.free(clean);
    var infos: std.ArrayList(TraderInfo) = .empty;
    defer infos.deinit(std.testing.allocator);
    var j: usize = 0;
    while (j < clean.len and infos.items.len < max_traders) {
        const ti = std.mem.findPos(u8, clean, j, "<trader_info ") orelse break;
        j = ti + 13;
        const idv = xml.attr(clean, ti, "id") orelse continue;
        const id = std.fmt.parseInt(u16, idv, 10) catch continue;
        const gt = std.mem.findPos(u8, clean, ti, ">") orelse break;
        const self_closing = gt > ti and clean[gt - 1] == '/';
        var refs: []const ItemRef = &.{};
        if (!self_closing) {
            const close = std.mem.findPos(u8, clean, gt, "</trader_info>") orelse break;
            refs = try parseRefsBody(arena, std.testing.allocator, clean[gt + 1 .. close]);
            j = close + "</trader_info>".len;
        }
        try infos.append(std.testing.allocator, .{ .id = id, .refs = refs });
    }
    try std.testing.expectEqual(@as(usize, 2), infos.items.len);
    try std.testing.expectEqual(@as(u16, 1), infos.items[0].id);
    try std.testing.expectEqual(@as(u16, 2), infos.items[1].id);
    try std.testing.expectEqual(@as(usize, 1), infos.items[0].refs.len);
}

test "traders root economy attributes parse (currency_item, markup)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/traders.xml", .{dir});
    try io_fs.writeFile(path, "<traders buy_markup=\"3\" sell_markdown=\"0.2\" currency_item=\"dukeCoin\" >\n" ++
        "  <trader_item_group name=\"groupTest\">\n" ++
        "    <item name=\"resourceWood\" count=\"10\"/>\n" ++
        "  </trader_item_group>\n" ++
        "  <trader_info id=\"1\" name=\"Joel\">\n" ++
        "    <trader_items>\n" ++
        "      <item name=\"resourceWood\" count=\"10\"/>\n" ++
        "    </trader_items>\n" ++
        "  </trader_info>\n" ++
        "</traders>\n");
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 3), t.buy_markup);
    try std.testing.expectEqual(@as(f32, 0.2), t.sell_markdown);
    try std.testing.expectEqualStrings("dukeCoin", t.currency_item);
    // Unset currency_item stays empty (Game falls back to the stock name).
    var p2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path2 = try std.fmt.bufPrint(&p2, "{s}/traders2.xml", .{dir});
    try io_fs.writeFile(path2, "<traders buy_markup=\"2\" >\n" ++
        "  <trader_item_group name=\"groupTest\">\n" ++
        "    <item name=\"resourceWood\" count=\"1\"/>\n" ++
        "  </trader_item_group>\n" ++
        "  <trader_info id=\"1\" name=\"Joel\">\n" ++
        "    <trader_items><item name=\"resourceWood\" count=\"1\"/></trader_items>\n" ++
        "  </trader_info>\n" ++
        "</traders>\n");
    var t2 = try loadFromPath(std.testing.allocator, path2);
    defer t2.deinit();
    try std.testing.expectEqualStrings("", t2.currency_item);
}

test "quality-less entry rolls the default range for a quality item only" {
    // Stock parses a `quality`-less <item> with minQualityBase =
    // maxQualityBase = -1 (TradersFromXml.il:558-563); SpawnItem substitutes
    // 1..6 for a quality-bearing item and leaves everything else alone.
    const refs = [_]ItemRef{
        .{ .name = "gunPistol" },
        .{ .name = "resourceWood", .count_min = 10, .count_max = 10 },
    };
    const quality_names = TestQualityNames{ .names = &.{"gunPistol"} };
    var t = TraderTable.empty();
    // One seed can land anywhere in 1..6; sweep so the range, not one draw,
    // is what the test pins.
    var saw_above_one = false;
    var seed: u32 = 1;
    while (seed <= 32) : (seed += 1) {
        var rng = rng_util.XorShift32.init(seed);
        var out: [8]RolledItem = undefined;
        const n = t.rollAllRefs(&refs, &rng, quality_names.policy(), 1.0, &out);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expectEqualStrings("gunPistol", out[0].name);
        try std.testing.expect(out[0].quality >= 1 and out[0].quality <= 6);
        if (out[0].quality > 1) saw_above_one = true;
        // A stackable has no effect_group, so no quality is rolled at all.
        try std.testing.expectEqualStrings("resourceWood", out[1].name);
        try std.testing.expectEqual(@as(u8, 1), out[1].quality);
    }
    try std.testing.expect(saw_above_one);
}

test "explicit quality attribute wins over the default range" {
    const refs = [_]ItemRef{.{ .name = "gunPistol", .quality_lo = 3, .quality_hi = 3 }};
    const quality_names = TestQualityNames{ .names = &.{"gunPistol"} };
    var t = TraderTable.empty();
    var seed: u32 = 1;
    while (seed <= 8) : (seed += 1) {
        var rng = rng_util.XorShift32.init(seed);
        var out: [4]RolledItem = undefined;
        const n = t.rollAllRefs(&refs, &rng, quality_names.policy(), 1.0, &out);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(@as(u8, 3), out[0].quality);
    }
}

test "TraderMaxTier clamps the roll and gates the spawn" {
    // SpawnItem IL_015F-0175: maxQuality clamps to TraderMaxTier unless the
    // cap is -1. IL_0011-0020: a cap of 0 drops quality items entirely.
    // IL_0177-017C: an explicit min above the cap drops the item too.
    const refs = [_]ItemRef{
        .{ .name = "gunPistol" },
        .{ .name = "resourceWood", .count_min = 5, .count_max = 5 },
    };
    const quality_names = TestQualityNames{ .names = &.{"gunPistol"} };
    var t = TraderTable.empty();

    var policy_clamped = quality_names.policy();
    policy_clamped.max_tier = 2;
    var seed: u32 = 1;
    while (seed <= 32) : (seed += 1) {
        var rng = rng_util.XorShift32.init(seed);
        var out: [8]RolledItem = undefined;
        const n = t.rollAllRefs(&refs, &rng, policy_clamped, 1.0, &out);
        try std.testing.expectEqual(@as(usize, 2), n);
        try std.testing.expect(out[0].quality >= 1 and out[0].quality <= 2);
    }

    // Cap 0: the gun is not written to out[] at all, the stackable still is.
    var policy_zero = quality_names.policy();
    policy_zero.max_tier = 0;
    var rng_zero = rng_util.XorShift32.init(11);
    var out_zero: [8]RolledItem = undefined;
    const nz = t.rollAllRefs(&refs, &rng_zero, policy_zero, 1.0, &out_zero);
    try std.testing.expectEqual(@as(usize, 1), nz);
    try std.testing.expectEqualStrings("resourceWood", out_zero[0].name);

    // Explicit min 5 with a cap of 3 leaves max < min, so nothing spawns.
    const high_refs = [_]ItemRef{.{ .name = "gunPistol", .quality_lo = 5, .quality_hi = 6 }};
    var policy_low = quality_names.policy();
    policy_low.max_tier = 3;
    var rng_low = rng_util.XorShift32.init(11);
    var out_low: [8]RolledItem = undefined;
    try std.testing.expectEqual(@as(usize, 0), t.rollAllRefs(&high_refs, &rng_low, policy_low, 1.0, &out_low));

    // max_tier -1 disables the clamp: the full default range comes back.
    var policy_uncapped = quality_names.policy();
    policy_uncapped.max_tier = -1;
    var saw_six = false;
    seed = 1;
    while (seed <= 64) : (seed += 1) {
        var rng = rng_util.XorShift32.init(seed);
        var out: [8]RolledItem = undefined;
        _ = t.rollAllRefs(&refs, &rng, policy_uncapped, 1.0, &out);
        if (out[0].quality == 6) saw_six = true;
    }
    try std.testing.expect(saw_six);
}

test "quality-less trader entries parse as the stock -1 base pair" {
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer {
        arena_holder.deinit();
        std.testing.allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();
    const body = "<item name=\"plain\"/><item name=\"ranged\" quality=\"2,4\"/>";
    const refs = try parseRefsBody(arena, std.testing.allocator, body);
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqual(@as(i16, -1), refs[0].quality_lo);
    try std.testing.expectEqual(@as(i16, -1), refs[0].quality_hi);
    try std.testing.expectEqual(@as(i16, 2), refs[1].quality_lo);
    try std.testing.expectEqual(@as(i16, 4), refs[1].quality_hi);
    // A modlet bound past the wire byte clamps at parse; a negative one falls
    // back to the unset sentinel. Neither may reach the u8 quality cast.
    const wild = "<item name=\"huge\" quality=\"300,900\"/><item name=\"neg\" quality=\"-4\"/>";
    const wild_refs = try parseRefsBody(arena, std.testing.allocator, wild);
    try std.testing.expectEqual(@as(usize, 2), wild_refs.len);
    try std.testing.expectEqual(@as(i16, 255), wild_refs[0].quality_lo);
    try std.testing.expectEqual(@as(i16, 255), wild_refs[0].quality_hi);
    try std.testing.expectEqual(@as(i16, -1), wild_refs[1].quality_lo);

    // The clamped bound still survives the roll as a valid wire quality.
    const quality_names = TestQualityNames{ .names = &.{"huge"} };
    var policy = quality_names.policy();
    policy.max_tier = -1;
    var t = TraderTable.empty();
    var rng = rng_util.XorShift32.init(3);
    var out: [4]RolledItem = undefined;
    try std.testing.expectEqual(@as(usize, 1), t.rollAllRefs(wild_refs[0..1], &rng, policy, 1.0, &out));
    try std.testing.expectEqual(@as(u8, 255), out[0].quality);
}
