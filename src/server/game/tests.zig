//! Game integration tests: peerIpKey, player persist, claims, evidence, etc.
//! Bodies are verbatim copies from src/server/game.zig (kept as integration tests
//! that exercise Game helpers). This file is imported via src/server/root.zig so
//! `zig build test` aggregates them; game.zig no longer carries the suite inline.

const std = @import("std");
const Game = @import("../game.zig").Game;
const game_mod = @import("../game.zig");
const game = @import("../game.zig");
const ln_peer = @import("../../litenet/peer.zig");
const wire_binary = @import("../../wire/binary.zig");
const platform_user = @import("../../wire/platform_user.zig");
const io_fs = @import("../../util/io_fs.zig");
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const light_te_mod = @import("../../world/light_te.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const schedule = @import("../../ecs/schedule.zig");
const game_hooks = @import("../game/hooks.zig");
const clock = @import("../../util/clock.zig");
const util_sim = @import("../../util/sim.zig");
const wire_frame = @import("../../wire/frame.zig");
const wire_stock_buff = @import("../../wire/stock_buff.zig");
const assets_unity_hash = @import("../../assets/unity_hash.zig");
const assets_biome_layers = @import("../../assets/biome_layers.zig");
const sleepers_mod = @import("../../world/sleepers.zig");
const replicate_te = @import("../replicate_te.zig");
const containers_mod = @import("../../world/containers.zig");
const chunk_fill_mod = @import("../game/chunk_fill.zig");
const c2s_misc = @import("../c2s/misc.zig");
const plugin_mod = @import("../../plugin/root.zig");
const plugin_api = @import("../../plugin/api.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const ecs_buff = @import("../../ecs/buff.zig");
const assets_progression = @import("../../assets/progression.zig");
const requirements = @import("../../assets/requirements.zig");
const assets_entitygroups = @import("../../assets/entitygroups.zig");
const assets_traders = @import("../../assets/traders.zig");
const assets_npc = @import("../../assets/npc.zig");
const game_craft = @import("../game/craft.zig");
const parallel = @import("../../util/parallel.zig");
const stock_paths = @import("../../util/stock_paths.zig");
const zpv2DropName = game.zpv2DropName;

test "peerIpKey covers ipv4 mapped ipv6 and pure ipv6" {
    var p: ln_peer.Peer = .{};
    p.addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } };
    try std.testing.expectEqual(@as(u32, 0x7f000001), Game.peerIpKey(&p));

    p.addr = .{ .ip6 = .{
        .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 2 },
        .port = 1,
    } };
    try std.testing.expectEqual(@as(u32, 0xc0a80102), Game.peerIpKey(&p));

    p.addr = .{ .ip6 = .{
        .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        .port = 1,
    } };
    const k = Game.peerIpKey(&p);
    try std.testing.expect(k != 0);
    try std.testing.expect(k != 0x7f000001);
}

test "zpv2DropName removes matching player record only" {
    // Two minimal records: Alice (inv=0,j=0), Bob (inv=0,j=0).
    // each: name_len|name|x,y,z,coins (16 bytes)|inv_n|jn
    var buf: [128]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZPV2");
    o = 8;
    // Alice
    buf[o] = 5;
    o += 1;
    @memcpy(buf[o..][0..5], "Alice");
    o += 5;
    @memset(buf[o..][0..16], 0);
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    // Bob
    buf[o] = 3;
    o += 1;
    @memcpy(buf[o..][0..3], "Bob");
    o += 3;
    @memset(buf[o..][0..16], 0);
    o += 16;
    buf[o] = 0;
    o += 1;
    buf[o] = 0;
    o += 1;
    std.mem.writeInt(u32, buf[4..8], 2, .little);

    const dropped = try zpv2DropName(std.testing.allocator, buf[0..o], "Alice");
    defer if (dropped.blob) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u32, 1), dropped.removed);
    try std.testing.expect(dropped.blob != null);
    const out = dropped.blob.?;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expect(std.mem.find(u8, out, "Alice") == null);
    try std.testing.expect(std.mem.find(u8, out, "Bob") != null);

    const none = try zpv2DropName(std.testing.allocator, buf[0..o], "Carol");
    try std.testing.expectEqual(@as(u32, 0), none.removed);
    try std.testing.expect(none.blob == null);
}

test "zpv2DropName accepts the current ZPV12 save (wipeplayer on a v12 file)" {
    // The wipe path must accept the current magic 'C' (v12) save, not just
    // the pre-letter versions; a minimal v12 record has prog=0 (no progression
    // tail, so the v11/v12 skill/mod tails are not walked).
    var buf: [128]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZPVC");
    o = 8;
    buf[o] = 5; // name_len
    o += 1;
    @memcpy(buf[o..][0..5], "Alice");
    o += 5;
    @memset(buf[o..][0..16], 0); // x,y,z,coins
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 0; // prog = 0 (no progression tail)
    o += 1;
    std.mem.writeInt(u32, buf[4..8], 1, .little);

    const dropped = try zpv2DropName(std.testing.allocator, buf[0..o], "Alice");
    defer if (dropped.blob) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u32, 1), dropped.removed);
    const out = dropped.blob.?;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[4..8], .little));
}

test "players zpv7 round-trips use_times (tool durability) across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        g.sim.inventory[ps] = .{};
        const last = ecs.components.max_inv_slots - 1;
        g.sim.inventory[ps].slots[last] = .{ .item_id = 2, .count = 1, .quality = 4, .meta = 0, .use_times = 42.5, .seed = 777 };
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        const last = ecs.components.max_inv_slots - 1;
        try std.testing.expectEqual(@as(u16, 2), g.sim.inventory[ps].slots[last].item_id);
        try std.testing.expectEqual(@as(f32, 42.5), g.sim.inventory[ps].slots[last].use_times);
        // ZPV10: the plantable's seed survives a restart too.
        try std.testing.expectEqual(@as(u16, 777), g.sim.inventory[ps].slots[last].seed);
        // A fresh slot has no phantom durability.
        try std.testing.expectEqual(@as(f32, 0), g.sim.inventory[ps].slots[0].use_times);
    }
}

test "players zpv8 round-trips hp (relog keeps wounds) across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        // Wounded, not dead (hp scale is 0..max, players max 100): the
        // record must carry the 37.5 across a restart instead of the
        // fresh-full spawn the pre-ZPV8 path granted.
        g.sim.health[ps].hp = 37.5;
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        try std.testing.expectEqual(@as(f32, 37.5), g.sim.health[ps].hp);
    }
}

test "players zpv7 tail gains full hp on save (ZPV8 migration)" {
    // Hand-built ZPV7 file with a progression tail but no hp field. The save
    // must insert hp=1.0 (full, the pre-ZPV8 relog behavior) so the v8 tail
    // walk stays aligned, and a restart must still see a live player.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var buf: [512]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[o..][0..4], "ZPV7");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little);
    o += 4;
    buf[o] = 3; // name_len "Ulf" (not the harness client: keeps the carry path live)
    o += 1;
    @memcpy(buf[o..][0..3], "Ulf");
    o += 3;
    @memset(buf[o..][0..16], 0); // xyz + coins
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 1; // prog: tail present
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // level
    o += 2;
    std.mem.writeInt(u64, buf[o..][0..8], 1000, .little); // xp
    o += 8;
    inline for ([_]f32{ 60, 100, 70, 100 }) |f| {
        std.mem.writeInt(u32, buf[o..][0..4], @bitCast(f), .little);
        o += 4;
    }
    buf[o] = 0; // buff_n
    o += 1;
    buf[o] = 0; // bed_present (v4+ tail layout)
    o += 1;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&capture);
        try g.savePlayers();
    }
    {
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings("ZPVG", data[0..4]);
    }
    {
        // The record is carried, not rewritten (its name is not the harness
        // client's), so the migrated tail is checked in the file: level 5 and
        // the inserted full-hp sentinel, both at the v12 tail offsets.
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        const persist = @import("../persist.zig");
        _ = try persist.zpvRecordLen(data, 8, 14);
        const tail_at = 8 + 1 + 3 + 16 + 1 + 0 + 1 + 0 + 1; // name, pos, inv_n=0, jn=0, prog
        try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, data[tail_at..][0..2], .little));
        std.debug.print("PASS zpv7->zpv8: carried tail gains full hp on save\n", .{});
    }
}

test "players zpv9 round-trips game-stage born time (days-alive) across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        // A player who has been alive for a while: born 10 days ago (advance
        // the clock first so the subtraction cannot underflow).
        g.sim.director.clock.day = 15;
        cl.game_stage_born_world_time = g.sim.director.clock.worldTimeBits() - 10 * assets_gamestages.ticks_per_day;
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        // The restore runs after the join-time `if (!was_joined)` set, so the
        // persisted born time wins: days-alive (and the gamestage) survives.
        // (The world clock ticks between the two Games, so assert the
        // invariant - ~1 day alive - not an exact born value.)
        // The world clock ticks between the two Games (and the saved clock
        // restores day 15), so assert the invariant: the persisted born time
        // survives (not a fresh reset) and days-alive is ~10.
        const now = g.sim.director.clock.worldTimeBits();
        try std.testing.expect(cl.game_stage_born_world_time > 0);
        try std.testing.expect(cl.game_stage_born_world_time < now);
        try std.testing.expectEqual(@as(u16, 10), assets_gamestages.daysAlive(now, cl.game_stage_born_world_time, 99));
    }
}

test "players zpv11 round-trips skill points and purchased perk levels" {
    // The spend ledger (skill_points + skill_levels) must survive a restart
    // so the level-scaled VM effects restore: purchases are no longer lost.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        cl.skill_points = 3;
        cl.skill_levels[0] = .{ .name = "perkLightEater", .level = 2 };
        cl.skill_levels[1] = .{ .name = "attGeneral", .level = 1 };
        cl.skill_level_n = 2;
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        // The restore resolves ledger names against the progression catalog
        // (arena lifetime); give the second Game the same tree.
        const attrs = [_]assets_progression.AttrDef{
            .{ .name = "attGeneral", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
        };
        const perks = [_]assets_progression.PerkDef{
            .{ .name = "perkLightEater", .max_level = 5, .parent_attr = "attGeneral" },
        };
        g.progression_table.attributes = &attrs;
        g.progression_table.perks = &perks;
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        try std.testing.expectEqual(@as(u32, 3), cl.skill_points);
        try std.testing.expectEqual(@as(u8, 2), cl.skill_level_n);
        try std.testing.expectEqualStrings("perkLightEater", cl.skill_levels[0].name);
        try std.testing.expectEqual(@as(u8, 2), cl.skill_levels[0].level);
        try std.testing.expectEqualStrings("attGeneral", cl.skill_levels[1].name);
        try std.testing.expectEqual(@as(u8, 1), cl.skill_levels[1].level);
    }
}

test "players zpv12 round-trips item mods across restart" {
    // ZPV12 appends the attached mod ids to each inventory slot record, so a
    // modded weapon keeps its attachments through a relog (the mods' stat
    // effects are client-side; the ids re-render the attachments).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(0).?;
        var slot = &g.sim.inventory[ps].slots[0];
        slot.item_id = 30;
        slot.count = 1;
        slot.quality = 5;
        slot.mods = .{ 12, 13, 0, 0 };
        slot.mod_n = 2;
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(0).?;
        const slot = g.sim.inventory[ps].slots[0];
        try std.testing.expectEqual(@as(u16, 30), slot.item_id);
        try std.testing.expectEqual(@as(u8, 2), slot.mod_n);
        try std.testing.expectEqual(@as(u16, 12), slot.mods[0]);
        try std.testing.expectEqual(@as(u16, 13), slot.mods[1]);
    }
}

test "players v14 record gains an absent identity section on save (ZPV15 migration)" {
    // A v14 ('E') file has no identity section. The save must append the absent
    // marker byte so the v15 record walk stays aligned, and the upgrade must not
    // invent an identity the client never presented: a legacy row keeps matching
    // by name until its owner logs in with a platform id.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const persist_mod = @import("../persist.zig");
    var buf: [1024]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZPVE");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little); // record count
    o += 4;
    // Named after the harness client ("Bot"), which presents no platform id:
    // this is the migration path where a legacy row is the only key it has.
    const name = "Bot";
    buf[o] = @intCast(name.len);
    o += 1;
    @memcpy(buf[o..][0..name.len], name);
    o += name.len;
    @memset(buf[o..][0..16], 0); // x,y,z f32s + coins
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 1; // prog 1
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // level
    o += 2;
    std.mem.writeInt(u64, buf[o..][0..8], 12345, .little); // xp
    o += 8;
    @memset(buf[o..][0..16], 0); // food/max/water/max
    o += 16;
    std.mem.writeInt(u32, buf[o..][0..4], @bitCast(@as(f32, 1.0)), .little); // hp (v8+)
    o += 4;
    @memset(buf[o..][0..8], 0); // born_world_time (v9+)
    o += 8;
    buf[o] = 0; // buff_n
    o += 1;
    buf[o] = 0; // bed_present 0
    o += 1;
    @memset(buf[o..][0..5], 0); // ZPV11 skill tail: points + skill_n
    o += 5;
    buf[o] = 0; // ZPV13 backpacks
    o += 1;
    @memset(buf[o..][0..persist_mod.zpv_stats_tail_len], 0); // ZPV14 counters
    o += persist_mod.zpv_stats_tail_len;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        // The legacy record restored by name, so level 5 came through.
        try std.testing.expectEqual(@as(u16, 5), cl.level);
        try g.savePlayers();
    }

    const data = try io_fs.readFileAll(std.testing.allocator, zsv);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("ZPVG", data[0..4]);
    // The rewritten record walks cleanly under the v15 layout. The identity
    // section is the absent marker because the harness client presented no
    // platform id, so this row is still name-keyed (ADR 0038 notices it).
    const rec_len = try persist_mod.zpvRecordLen(data, 8, persist_mod.persist_version);
    try std.testing.expect(rec_len > 0 and rec_len < data.len);
    const span = try persist_mod.zpvRecordSpan(data, 8, persist_mod.persist_version);
    try std.testing.expect(span.identity_off != 0);
    try std.testing.expectEqual(@as(u8, 0), data[span.identity_off]);
}

test "players restore matches on platform identity, not on a typed name (ZPV15)" {
    // DIVERGENCES 1.6: saves were keyed by login name alone, so a client could
    // load another player's inventory, level and XP by typing their name.
    // Stock keys PlayerDataFile on PrimaryId.CombinedString (asm.il 1884842).
    // This is the theft case: same name, different account.
    const id_a: platform_user.Id = .{ .platform = "EOS", .id = "acct-a" };
    const id_b: platform_user.Id = .{ .platform = "EOS", .id = "acct-b" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClientAs(&capture, id_a);
        try std.testing.expect(cl.puid_primary.get() != null);
        const ps = g.sim.playerByPeer(cl.slot).?;
        g.sim.inventory[ps] = .{};
        g.sim.inventory[ps].slots[ecs.components.max_inv_slots - 1] =
            .{ .item_id = 2, .count = 1, .quality = 4, .use_times = 7.5 };
        cl.deaths = 4;
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClientAs(&capture, id_b);
        const ps = g.sim.playerByPeer(cl.slot).?;
        // Same display name ("Bot"), different account: nothing restored.
        try std.testing.expectEqual(@as(u16, 0), g.sim.inventory[ps].slots[ecs.components.max_inv_slots - 1].item_id);
        try std.testing.expectEqual(@as(i32, 0), cl.deaths);
        try g.savePlayers();
    }

    {
        // The owner reconnects: its row is still there, under its identity.
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClientAs(&capture, id_a);
        const ps = g.sim.playerByPeer(cl.slot).?;
        try std.testing.expectEqual(@as(u16, 2), g.sim.inventory[ps].slots[ecs.components.max_inv_slots - 1].item_id);
        try std.testing.expectEqual(@as(f32, 7.5), g.sim.inventory[ps].slots[ecs.components.max_inv_slots - 1].use_times);
        try std.testing.expectEqual(@as(i32, 4), cl.deaths);
    }
}

test "players zpv10 record gains an empty skill tail on save (ZPV11 migration)" {
    // A v10 ('A') file has no skill tail; the save must append the empty
    // tail (skill_points 0, skill_n 0) so the v11 record walk stays aligned
    // and the record length is consistent across the carried boundary.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    // Hand-build the smallest v10 file: one record, no inventory/journal, a
    // v3 tail (prog 0), no bedroll (v4+ presence byte 0).
    var buf: [128]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZPVA");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little); // record count
    o += 4;
    const name = "tester";
    buf[o] = @intCast(name.len);
    o += 1;
    @memcpy(buf[o..][0..name.len], name);
    o += name.len;
    @memset(buf[o..][0..16], 0); // x,y,z f32s + coins
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 1; // prog 1: a real progression tail
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // level
    o += 2;
    std.mem.writeInt(u64, buf[o..][0..8], 12345, .little); // xp
    o += 8;
    @memset(buf[o..][0..16], 0); // food/max/water/max
    o += 16;
    std.mem.writeInt(u32, buf[o..][0..4], @bitCast(@as(f32, 1.0)), .little); // hp (v8+)
    o += 4;
    @memset(buf[o..][0..8], 0); // born_world_time (v9+)
    o += 8;
    buf[o] = 0; // buff_n
    o += 1;
    buf[o] = 0; // bed_present 0
    o += 1;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        // Saving carries the v10 record (no joined client matches its name)
        // and must re-emit it with the ZPV11 header + empty skill tail.
        try g.savePlayers();
    }
    const data = try io_fs.readFileAll(std.testing.allocator, zsv);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(u8, 'G'), data[3]);
    // Record length via the v14 walker: name(7) + 16 + inv(1) + jn(1) +
    // prog(1) + level(2) + xp(8) + stats(16) + hp(4) + born(8) + buff_n(1) +
    // bed(1) + skills(5) + backpacks(1, an empty marker list) + the v14
    // counters(12) (the fixture has no inventory slots, so the ZPV12 slot
    // widening changes nothing).
    try std.testing.expectEqual(@as(usize, 1 + name.len + 16 + 1 + 1 + 1 + 2 + 8 + 16 + 4 + 8 + 1 + 1 + 5 + 1 + 12 + 1), game_mod.zpvRecordLen(data, 8, @import("../persist.zig").persist_version));
}

test "players zpv10 inventory slots widen to the ZPV12 stride" {
    // The v10 fixture above carries no inventory, so the slot stride never
    // enters its record walk - moving the v10 boundary in zpvSlotStride left
    // the whole suite green. A v10 slot is 13 bytes (item, count, quality,
    // meta, use_times, seed); v12 adds four mod ids, so a carried record grows
    // by exactly that difference and keeps the slot's values.
    const persist = @import("../persist.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var buf: [256]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZPVA"); // v10
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little);
    o += 4;
    const name = "slotter";
    buf[o] = @intCast(name.len);
    o += 1;
    @memcpy(buf[o..][0..name.len], name);
    o += name.len;
    @memset(buf[o..][0..16], 0); // x,y,z,coins
    o += 16;
    buf[o] = 1; // inv_n: one slot
    o += 1;
    // v10 slot: item u16 | count u16 | quality u8 | meta u16 | use_times f32 | seed u16
    @memset(buf[o..][0..persist.zpvSlotStride(10)], 0);
    std.mem.writeInt(u16, buf[o..][0..2], 42, .little);
    std.mem.writeInt(u16, buf[o + 2 ..][0..2], 7, .little);
    buf[o + 4] = 3;
    std.mem.writeInt(u16, buf[o + 11 ..][0..2], 99, .little); // seed
    o += persist.zpvSlotStride(10);
    buf[o] = 0; // jn
    o += 1;
    // prog 0 ends the record: bed_present and the skill tail both live inside
    // the prog==1 branch, so appending them here would be extra bytes.
    buf[o] = 0;
    o += 1;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try g.savePlayers();
    }

    const data = try io_fs.readFileAll(std.testing.allocator, zsv);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(u8, 'G'), data[3]); // carried to v16
    // No prog tail on this fixture, so the ZPV13 marker list (which lives
    // inside the prog block) adds nothing to the length.
    const want = 1 + name.len + 16 + 1 + persist.zpvSlotStride(persist.persist_version) + 1 + 1;
    try std.testing.expectEqual(want, game_mod.zpvRecordLen(data, 8, persist.persist_version));
    // The slot's leading fields survived the widening at their own offsets.
    const slot_at = 8 + 1 + name.len + 16 + 1;
    try std.testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, data[slot_at..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, data[slot_at + 2 ..][0..2], .little));
}

test "players zpv8 tail gains a zero born time on save (ZPV9 migration)" {
    // Hand-built ZPV8 file with a tail (prog, level, xp, stats, hp). The save
    // must insert born_world_time=0 (the pre-ZPV9 days-alive behavior) so the
    // v9 tail walk stays aligned, and a restart must restore the tail values.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var buf: [512]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[o..][0..4], "ZPV8");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little);
    o += 4;
    buf[o] = 3; // name_len "Ida" (not the harness client: keeps the carry path live)
    o += 1;
    @memcpy(buf[o..][0..3], "Ida");
    o += 3;
    @memset(buf[o..][0..16], 0); // xyz + coins
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 1; // prog: tail present
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // level
    o += 2;
    std.mem.writeInt(u64, buf[o..][0..8], 1000, .little); // xp
    o += 8;
    inline for ([_]f32{ 60, 100, 70, 100 }) |f| {
        std.mem.writeInt(u32, buf[o..][0..4], @bitCast(f), .little);
        o += 4;
    }
    std.mem.writeInt(u32, buf[o..][0..4], @bitCast(@as(f32, 0.4)), .little); // hp
    o += 4;
    buf[o] = 0; // buff_n
    o += 1;
    buf[o] = 0; // bed_present
    o += 1;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&capture);
        try g.savePlayers();
    }
    {
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings("ZPVG", data[0..4]);
    }
    {
        // Carried, not rewritten, so the migrated tail is read from the file:
        // level 5 and the v8 hp (0.4) both survive, and the record still walks
        // under the v12 layout with born_world_time inserted.
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        const persist = @import("../persist.zig");
        _ = try persist.zpvRecordLen(data, 8, 14);
        const tail_at = 8 + 1 + 3 + 16 + 1 + 1 + 1; // name, pos, inv_n=0, jn=0, prog
        try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, data[tail_at..][0..2], .little));
        const hp_at = tail_at + 2 + 8 + 16; // level, xp, four survival floats
        try std.testing.expectEqual(@as(f32, 0.4), @as(f32, @bitCast(std.mem.readInt(u32, data[hp_at..][0..4], .little))));
        std.debug.print("PASS zpv8->zpv9: carried tail gains zero born time on save\n", .{});
    }
}

test "players zpv7 inventory + tail migrate to zpv9 on save" {
    // Hand-built ZPV7 file with one 11-byte inventory slot AND a tail. The
    // save must insert hp + born into the tail (the slots are already the
    // 11-byte shape) and a restart must restore the item and tail values.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var buf: [512]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[o..][0..4], "ZPV7");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little);
    o += 4;
    // Deliberately NOT "Bot", the harness client's name: a matching record is
    // rewritten from live state, which is what made this fixture exercise the
    // rewrite path instead of the v7 carry it is named for.
    buf[o] = 3; // name_len "Ana"
    o += 1;
    @memcpy(buf[o..][0..3], "Ana");
    o += 3;
    @memset(buf[o..][0..16], 0); // xyz + coins
    o += 16;
    buf[o] = 1; // inv_n
    o += 1;
    // v7 slot records are already 11 bytes (item, count, quality, meta,
    // use_times f32); the tail is what lacks hp/born.
    std.mem.writeInt(u16, buf[o..][0..2], 7, .little); // item
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], 3, .little); // count
    o += 2;
    buf[o] = 4; // quality
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // meta
    o += 2;
    // 3.14159 rather than a round number on purpose: its little-endian bytes
    // are D0 0F 49 40, none of them zero. A carry that walks the slot with the
    // pre-v7 7-byte stride reads `jn` out of this field and gets 208 instead
    // of 0, which the journal walk then rejects. With 10.0 (00 00 20 41) the
    // misread lands on a zero byte and the whole disagreement stays invisible.
    std.mem.writeInt(u32, buf[o..][0..4], @bitCast(@as(f32, 3.14159)), .little); // use_times
    o += 4;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 1; // prog: tail present
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // level
    o += 2;
    std.mem.writeInt(u64, buf[o..][0..8], 1000, .little); // xp
    o += 8;
    inline for ([_]f32{ 60, 100, 70, 100 }) |f| {
        std.mem.writeInt(u32, buf[o..][0..4], @bitCast(f), .little);
        o += 4;
    }
    buf[o] = 0; // buff_n
    o += 1;
    buf[o] = 0; // bed_present
    o += 1;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&capture);
        try g.savePlayers();
    }
    {
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings("ZPVG", data[0..4]);
    }
    {
        // The carried record is not the harness client's, so verify it in the
        // file: the slot must have widened to the v12 stride with its four
        // fields intact, and the record must still walk cleanly.
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        const persist = @import("../persist.zig");
        const slot_at = 8 + 1 + 3 + 16 + 1;
        try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, data[slot_at..][0..2], .little));
        try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, data[slot_at + 2 ..][0..2], .little));
        try std.testing.expectEqual(@as(u8, 4), data[slot_at + 4]);
        try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, data[slot_at + 5 ..][0..2], .little));
        try std.testing.expectEqual(@as(f32, 3.14159), @as(f32, @bitCast(std.mem.readInt(u32, data[slot_at + 7 ..][0..4], .little))));
        // Walking the record with the v12 stride must land inside the file.
        _ = try persist.zpvRecordLen(data, 8, 14);
        std.debug.print("PASS zpv7->zpv12: carried slot widened to the current stride\n", .{});
    }
}

test "players zpv6 inventory migrates to zpv7 slots on save" {
    // Hand-built ZPV6 file with one 7-byte inventory slot (no use_times).
    // savePlayers must widen the slot record to 11 bytes (zero use_times)
    // and a restart must restore the item.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var buf: [256]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[o..][0..4], "ZPV6");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little);
    o += 4;
    buf[o] = 3; // name_len "Eve" (not the harness client: keeps the carry path live)
    o += 1;
    @memcpy(buf[o..][0..3], "Eve");
    o += 3;
    @memset(buf[o..][0..16], 0); // xyz + coins
    o += 16;
    buf[o] = 1; // inv_n
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 7, .little); // item
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], 3, .little); // count
    o += 2;
    buf[o] = 4; // quality
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 5, .little); // meta
    o += 2;
    buf[o] = 0; // jn
    o += 1;
    buf[o] = 0; // prog: no tail (so no v4 bed byte either)
    o += 1;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&capture);
        try g.savePlayers();
    }
    {
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings("ZPVG", data[0..4]);
    }
    {
        // Carried, not rewritten, so the widened slot is checked in the file:
        // the four v6 fields keep their offsets and the record walks under the
        // v12 stride.
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        const persist = @import("../persist.zig");
        _ = try persist.zpvRecordLen(data, 8, 14);
        const slot_at = 8 + 1 + 3 + 16 + 1;
        try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, data[slot_at..][0..2], .little));
        try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, data[slot_at + 2 ..][0..2], .little));
        try std.testing.expectEqual(@as(u8, 4), data[slot_at + 4]);
        try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, data[slot_at + 5 ..][0..2], .little));
        std.debug.print("PASS zpv6->zpv12: legacy 7-byte slot widened to the current stride\n", .{});
    }
}

test "players zpv3 preserves every inventory slot across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        g.sim.inventory[ps] = .{};
        const last = ecs.components.max_inv_slots - 1;
        g.sim.inventory[ps].slots[last] = .{ .item_id = 2, .count = 3, .quality = 4, .meta = 5 };
        try g.savePlayers();
    }

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        try std.testing.expectEqual(@as(u16, 0), g.sim.inventory[ps].slots[0].count);
        const last = ecs.components.max_inv_slots - 1;
        try std.testing.expectEqual(@as(u16, 2), g.sim.inventory[ps].slots[last].item_id);
        try std.testing.expectEqual(@as(u16, 3), g.sim.inventory[ps].slots[last].count);
        try std.testing.expectEqual(@as(u8, 4), g.sim.inventory[ps].slots[last].quality);
        try std.testing.expectEqual(@as(u16, 5), g.sim.inventory[ps].slots[last].meta);
    }
}

test "players zpv3 round-trips level xp stats and buffs across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    // Two full save/restart cycles: the second proves the round-trip is not
    // order dependent (the restored record is re-saved and re-read).
    var round: u32 = 0;
    while (round < 2) : (round += 1) {
        {
            const g = try Game.create(std.testing.allocator, world_dir, 0);
            defer {
                g.deinit();
                std.testing.allocator.destroy(g);
            }
            var capture: ln_peer.Capture = .{};
            const cl = try g.attachJoinedClient(&capture);
            const ps = g.sim.playerByPeer(cl.slot).?;
            g.clients[cl.slot].level = 7;
            g.clients[cl.slot].xp = 12345;
            g.sim.health[ps].food = 42;
            g.sim.health[ps].food_max = 100;
            g.sim.health[ps].water = 33;
            g.sim.health[ps].water_max = 100;
            const bs = g.sim.buffsMut(ps);
            bs.slots[0] = .{
                .active = true,
                .def_id = 5,
                .stack_mult = 2,
                .duration_ticks = 400,
                .update_ticks = 7,
                .update_rate_ticks = 20,
                .duration_max = 20,
                .remove_on_death = false,
            };
            try g.savePlayers();
        }
        {
            const g = try Game.create(std.testing.allocator, world_dir, 0);
            defer {
                g.deinit();
                std.testing.allocator.destroy(g);
            }
            var capture: ln_peer.Capture = .{};
            const cl = try g.attachJoinedClient(&capture);
            const ps = g.sim.playerByPeer(cl.slot).?;
            try std.testing.expectEqual(@as(u16, 7), g.clients[cl.slot].level);
            try std.testing.expectEqual(@as(u64, 12345), g.clients[cl.slot].xp);
            try std.testing.expectEqual(@as(f32, 42), g.sim.health[ps].food);
            try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].food_max);
            try std.testing.expectEqual(@as(f32, 33), g.sim.health[ps].water);
            try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].water_max);
            const bs = g.sim.buffsMut(ps);
            try std.testing.expect(bs.slots[0].active);
            try std.testing.expectEqual(@as(u16, 5), bs.slots[0].def_id);
            try std.testing.expectEqual(@as(u8, 2), bs.slots[0].stack_mult);
            try std.testing.expectEqual(@as(u32, 400), bs.slots[0].duration_ticks);
            try std.testing.expectEqual(@as(f32, 20), bs.slots[0].duration_max);
            try std.testing.expect(!bs.slots[0].remove_on_death);
        }
    }
}

test "players save keeps a joined-but-not-writable client record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    // Seed a persisted record: a joined, spawned player with a real inventory
    // item is saved so the on-disk file has a record for "Bot".
    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        g.sim.inventory[ps] = .{};
        // item 2 (resourceWood) stacks; item 9 is meleeClub, which caps at 1,
        // so a count of 7 there was never a legal inventory and the load
        // clamp now corrects it. The subject here is record carry-forward.
        g.sim.inventory[ps].slots[3] = .{ .item_id = 2, .count = 7, .quality = 5, .meta = 1 };
        try g.savePlayers();
    }

    // Second save while the client is joined but has no writable sim state.
    // Setting entity_id to 0 simulates the "joined but not yet spawned" window.
    // Matching only "joined + name" classified this client as online and
    // silently dropped the persisted record, since the fresh-write loop skips
    // it; the carry-forward must keep the record because this save cannot.
    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        g.clients[cl.slot].entity_id = 0;
        try g.savePlayers();
    }

    // The persisted inventory must survive the carried-forward record.
    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        try std.testing.expectEqual(@as(u16, 2), g.sim.inventory[ps].slots[3].item_id);
        try std.testing.expectEqual(@as(u16, 7), g.sim.inventory[ps].slots[3].count);
    }
}

test "players zpv3 restore skips a preceding record's progression tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    // Hand-built ZPV3 file: Alice first WITH a progression tail, then Bot with
    // one too. The restore scan must consume Alice's tail to reach Bot; before
    // the fix it misread Alice's tail bytes as a record and bailed corrupt.
    var buf: [512]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[o..][0..4], "ZPV3");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 2, .little);
    o += 4;
    const writeRec = struct {
        fn call(b: []u8, pos: *usize, name: []const u8, level: u16, xp: u64, food: f32) void {
            const oo = pos.*;
            b[oo] = @intCast(name.len);
            pos.* += 1;
            @memcpy(b[pos.*..][0..name.len], name);
            pos.* += name.len;
            @memset(b[pos.*..][0..16], 0); // xyz + coins
            pos.* += 16;
            b[pos.*] = 0; // inv_n
            pos.* += 1;
            b[pos.*] = 0; // jn
            pos.* += 1;
            b[pos.*] = 1; // prog: tail present
            pos.* += 1;
            std.mem.writeInt(u16, b[pos.*..][0..2], level, .little);
            pos.* += 2;
            std.mem.writeInt(u64, b[pos.*..][0..8], xp, .little);
            pos.* += 8;
            inline for ([_]f32{ food, 100, 50, 100 }) |f| {
                std.mem.writeInt(u32, b[pos.*..][0..4], @as(u32, @bitCast(f)), .little);
                pos.* += 4;
            }
            b[pos.*] = 0; // buff_n
            pos.* += 1;
        }
    }.call;
    writeRec(&buf, &o, "Alice", 3, 100, 50);
    writeRec(&buf, &o, "Bot", 9, 555, 42);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    try std.testing.expectEqual(@as(u16, 9), g.clients[cl.slot].level);
    try std.testing.expectEqual(@as(u64, 555), g.clients[cl.slot].xp);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expectEqual(@as(f32, 42), g.sim.health[ps].food);
    try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].food_max);
}

test "players zpv4 journal upgrades to zpv5 on save and round-trips" {
    // Hand-built ZPV4 file with one 10-byte journal entry (no name/rect).
    // savePlayers must re-encode it into the ZPV5 shape (name + rect) so the
    // file stays uniformly parseable, then a restart restores the same quest.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var buf: [256]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[o..][0..4], "ZPV4");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 1, .little);
    o += 4;
    buf[o] = 3; // name_len "Bot": deliberately the harness client, so the
    // record is rewritten from live state - this test is about the restore
    // side resolving the v4 entry to a quest name, which only happens there.
    o += 1;
    @memcpy(buf[o..][0..3], "Bot");
    o += 3;
    @memset(buf[o..][0..16], 0); // xyz + coins
    o += 16;
    buf[o] = 0; // inv_n
    o += 1;
    buf[o] = 1; // jn
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 1, .little); // def_id (clear_the_noise)
    o += 2;
    std.mem.writeInt(i32, buf[o..][0..4], 99, .little); // quest_code
    o += 4;
    buf[o] = 1; // flags: active
    o += 1;
    std.mem.writeInt(u16, buf[o..][0..2], 2, .little); // progress
    o += 2;
    buf[o] = 1; // phase
    o += 1;
    buf[o] = 0; // prog: no tail (so no v4 bed byte either)
    o += 1;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsv = try std.fmt.bufPrint(&path_buf, "{s}/players.zsv", .{world_dir});
    try io_fs.writeFile(zsv, buf[0..o]);

    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        // Restored from the v4 entry (no name): def_id 1 = clear_the_noise.
        var found = false;
        for (&g.sim.journal[ps].slots) |*s| {
            if (s.active and s.def_id == 1 and s.quest_code == 99) {
                try std.testing.expectEqual(@as(u16, 2), s.progress);
                found = true;
            }
        }
        try std.testing.expect(found);
        // Save re-encodes to ZPV5: the journal entry gains the quest name.
        try g.savePlayers();
    }
    {
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings("ZPVG", data[0..4]);
        try std.testing.expect(std.mem.find(u8, data, "clear_the_noise") != null);
    }
    // Restart: the re-encoded ZPV5 file round-trips the same active quest.
    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        var found = false;
        for (&g.sim.journal[ps].slots) |*s| {
            if (s.active and s.def_id == 1 and s.quest_code == 99) {
                try std.testing.expectEqual(@as(u16, 2), s.progress);
                found = true;
            }
        }
        try std.testing.expect(found);
        std.debug.print("PASS zpv4->zpv5: legacy journal upgraded in place and round-trips\n", .{});
    }
}

test "land claim removed when keystone breaks and expires offline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    g.sim.director.clock.day = 30;
    g.registerClaim(250, 70, 250, cl.entity_id);
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // Breaking a non-keystone block does not remove the claim, so it must not
    // take a marker off the wire either.
    cap.clear();
    g.removeClaimAt(249, 70, 250);
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    try std.testing.expect(cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) == null);
    // Breaking the keystone removes it and takes the map marker off the wire
    // (TEFeatureLandClaim.OnDestroy IL=28 broadcasts the remove-by-position
    // form with EnumMapObjectType 15).
    cap.clear();
    g.removeClaimAt(250, 70, 250);
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
    {
        const rm = cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(packages.map_marker_remove_by_position, std.mem.readInt(i32, rm[0..4], .little));
        try std.testing.expectEqual(@as(f32, 250), @as(f32, @bitCast(std.mem.readInt(u32, rm[4..8], .little))));
        try std.testing.expectEqual(@as(f32, 70), @as(f32, @bitCast(std.mem.readInt(u32, rm[8..12], .little))));
        try std.testing.expectEqual(@as(f32, 250), @as(f32, @bitCast(std.mem.readInt(u32, rm[12..16], .little))));
        try std.testing.expectEqual(
            @intFromEnum(packages.MapObjectType.land_claim),
            std.mem.readInt(i32, rm[16..20], .little),
        );
    }
    // Expiry: an offline claim past the window is released on the day roll,
    // and every removal path (expiry here, keystone break above) takes the
    // marker off the wire through the same hook.
    g.registerClaim(250, 70, 250, cl.entity_id);
    g.markClaimsForEntity(cl.entity_id, false);
    g.land_claims[0].owner_seen_day = g.sim.director.clock.day - 10;
    cap.clear();
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
    try std.testing.expect(cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) != null);
    // Expiry disabled (0) keeps even a very old offline claim.
    g.registerClaim(250, 70, 250, cl.entity_id);
    g.land_claim_expiry_days = 0;
    g.markClaimsForEntity(cl.entity_id, false);
    g.land_claims[0].owner_seen_day = 1;
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // An online claim never expires.
    g.land_claim_expiry_days = 3;
    g.markClaimsForEntity(cl.entity_id, true);
    g.land_claims[0].owner_seen_day = 1;
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // Erasure: a claim carries the owner's login name, so wipeplayer has to
    // release it or the name outlives the players.zsv record in claims.zlc.
    try std.testing.expect(g.land_claims[0].owner_name_len > 0);
    var owner: [32]u8 = undefined;
    const on = g.land_claims[0].owner_name_len;
    @memcpy(owner[0..on], g.land_claims[0].owner_name[0..on]);
    try std.testing.expectEqual(@as(u32, 0), g.dropClaimsForName("someone-else"));
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    cap.clear();
    try std.testing.expectEqual(@as(u32, 1), g.dropClaimsForName(owner[0..on]));
    try std.testing.expect(cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) != null);
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
}

test "land claim count and dead-zone gates refuse over-limit and adjacent claims" {
    // Stock LandClaimCount / LandClaimDeadZone: a claim past the owner's
    // count or inside another claim's dead zone is not registered.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    g.land_claim_count = 2;
    g.land_claim_dead_zone = 60;
    // First claim: allowed.
    try std.testing.expect(g.claimAllowed(cl.entity_id, 100, 70, 100));
    g.registerClaim(100, 70, 100, cl.entity_id);
    // Second, far away: allowed (under the count, outside the dead zone).
    try std.testing.expect(g.claimAllowed(cl.entity_id, 400, 70, 400));
    g.registerClaim(400, 70, 400, cl.entity_id);
    try std.testing.expectEqual(@as(usize, 2), g.land_claims_n);
    // Over the count: refused.
    try std.testing.expect(!g.claimAllowed(cl.entity_id, 700, 70, 700));
    // Inside the dead zone of claim (100,100): refused.
    try std.testing.expect(!g.claimAllowed(cl.entity_id, 130, 70, 100));
    // A different owner is not counted against this one.
    g.registerClaim(700, 70, 700, cl.entity_id + 1000);
    try std.testing.expectEqual(@as(usize, 3), g.land_claims_n);
    // With count headroom, a far claim passes the dead-zone gate.
    g.land_claim_count = 5;
    try std.testing.expect(g.claimAllowed(cl.entity_id, 900, 70, 900));
    // Dead zone 0 disables the adjacency check.
    g.land_claim_dead_zone = 0;
    try std.testing.expect(g.claimAllowed(cl.entity_id, 105, 70, 105));
    // Count 0 disables the count check.
    g.land_claim_count = 0;
    try std.testing.expect(g.claimAllowed(cl.entity_id, 105, 70, 105));
}

test "land claims hold past the old 256 cap and survive restart (GAP 12)" {
    // The claim table was 256: the 257th register silently vanished. Now 1024;
    // register 300 and prove the save/restart round trip keeps every claim.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        g.registerClaim(@intCast(1000 + i * 2), 70, @intCast(i), cl.entity_id);
    }
    try std.testing.expectEqual(@as(usize, 300), g.land_claims_n);
    try g.saveClaims();

    const g2 = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g2.deinit();
        std.testing.allocator.destroy(g2);
    }
    try std.testing.expectEqual(@as(usize, 300), g2.land_claims_n);
    std.debug.print("PASS claims-cap: 300 claims round-trip (cap was 256)\n", .{});
}

test "block durability has no eviction cap (GAP 12)" {
    // The damage store was a global FIFO: past the cap the oldest damaged
    // block's damage reverted mid-fight. Damage now lives in the chunk damage
    // plane (per-chunk, persisted by ZCH3), so any number of distinct damaged
    // blocks keeps its absolute value.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        _ = try g.addBlockDamage(@intCast(200 + i), 70, 300, 5);
    }
    var ok = true;
    i = 0;
    while (i < 300) : (i += 1) {
        if (g.getBlockHp(@intCast(200 + i), 70, 300) != 5) ok = false;
    }
    try std.testing.expect(ok);
    std.debug.print("PASS blockhp-nocap: 300 damaged blocks retain damage\n", .{});
}

test "block durability survives far past the old 1024 cap" {
    // Regression for the GAP 12 eviction flaw: 2000 distinct damaged blocks
    // all keep their absolute damage (the old table capped at 1024 and reset
    // the oldest entry mid-fight).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = try g.addBlockDamage(@intCast(500 + i), 70, 400, 3);
    }
    var ok = true;
    i = 0;
    while (i < 2000) : (i += 1) {
        if (g.getBlockHp(@intCast(500 + i), 70, 400) != 3) ok = false;
    }
    try std.testing.expect(ok);
    std.debug.print("PASS blockhp-nocap: 2000 damaged blocks retain damage\n", .{});
}

test "evidence JSONL flush writes the ring to a file (P4)" {
    // admin `evidence dump` persists the ring; the file must round-trip the
    // formatted JSONL lines (no secrets, no packets).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    g.evidence.record(.{ .tick = 7, .peer_local = 2, .entity_id = 103, .detector = .bounds, .severity = .strong, .surface = .block, .observed = 100, .bound = 96 });
    g.evidence.record(.{ .tick = 9, .detector = .phase, .severity = .hard });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/evidence.jsonl", .{world_dir});
    const n = try g.dumpEvidenceFile(path);
    try std.testing.expectEqual(@as(usize, 2), n);
    const read = try io_fs.readFileAll(std.testing.allocator, path);
    defer std.testing.allocator.free(read);
    try std.testing.expect(std.mem.find(u8, read, "\"det\":\"bounds\"") != null);
    try std.testing.expect(std.mem.find(u8, read, "\"sev\":\"hard\"") != null);
}

test "offline init failure restores deterministic sim globals" {
    util_sim.disable();
    try std.testing.expectError(error.SecretRequired, Game.createWithOptions(
        std.testing.allocator,
        ".zdtd_cfg_cache/dst_init_failure",
        0,
        .{ .webui_port = 1 },
    ));
    try std.testing.expect(!util_sim.isEnabled());
    // createWithOptions errdefer must clear the process-global config S2C
    // cache: buildCache runs before webui.listen, and a stuck cache_built
    // would skip rebuild on the next Game.create in this process.
    try std.testing.expect(!@import("config_files.zig").cacheBuiltForTest());
}

test "offline successful step advances exactly one virtual tick" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/dst_step_clock", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    const before = clock.monoNs();
    try g.step();
    try std.testing.expectEqual(before + util_sim.tick_ns, clock.monoNs());
}

test "offline init records default DST run seed" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/dst_run_seed", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expectEqual(util_sim.default_seed, util_sim.getSeed());
}

test "mem uptime counts from Game init, not raw boot-relative mono" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/mem_uptime", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Offline init pins the virtual epoch at util_sim.default_start_ns (1 s).
    // 89m59s of elapsed makes raw monoNs/60 round into the next minute, so the
    // stock `mem` line must show the init-relative value (89m), not 90m.
    clock.setVirtualNs(g.start_mono_ns + 89 * std.time.ns_per_min + 59 * std.time.ns_per_s);
    var out: [256]u8 = undefined;
    g.admin_reply_len = 0;
    g.admin_reply_sink = &out;
    defer g.admin_reply_sink = null;
    g.replyMem();
    const text = out[0..g.admin_reply_len];
    try std.testing.expect(std.mem.startsWith(u8, text, "Time: 89m "));
}

test "offline steps replay same world_time for same seed" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    // Unique per invocation: concurrent test processes share .zdtd_cfg_cache,
    // so fixed dir names would race on each other's saved clock state.
    const ts = clock.monoNs();
    var dir_a_buf: [128]u8 = undefined;
    var dir_b_buf: [128]u8 = undefined;
    // The buffers hold far more than the fixed prefix plus a u64, so the
    // formats cannot fail; unreachable keeps the paths from ever aliasing "."
    // (which the teardown below would then delete).
    const dir_a = std.fmt.bufPrint(&dir_a_buf, ".zdtd_cfg_cache/dst_replay_a_{d}", .{ts}) catch unreachable;
    const dir_b = std.fmt.bufPrint(&dir_b_buf, ".zdtd_cfg_cache/dst_replay_b_{d}", .{ts}) catch unreachable;
    // Unique names mean nothing reclaims these worlds otherwise: without the
    // teardown every run leaves two more world dirs under .zdtd_cfg_cache.
    defer io_fs.removeDirTree(dir_a);
    defer io_fs.removeDirTree(dir_b);
    var t_a: u64 = 0;
    var t_b: u64 = 0;
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir_a, 0, .{
            .worldgen_seed = 99,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqual(@as(u64, 99), util_sim.getSeed());
        var i: u32 = 0;
        while (i < 20) : (i += 1) try g.step();
        t_a = g.sim.director.clock.worldTimeBits();
    }
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir_b, 0, .{
            .worldgen_seed = 99,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var i: u32 = 0;
        while (i < 20) : (i += 1) try g.step();
        t_b = g.sim.director.clock.worldTimeBits();
    }
    try std.testing.expectEqual(t_a, t_b);
}

test "same seed replays identical outbound wire history (byte diff)" {
    // Stronger than the world_time oracle above: a full recorded payload
    // history (join bundle + 24 ticks through a Capture peer) must replay
    // byte-for-byte from the seed, so a divergent second run can be diffed
    // against the first instead of trusting one scalar.
    io_fs.mkdirPath(".zdtd_cfg_cache");
    // Unique dirs per invocation: offline games persist clock state and the
    // cache dir is shared across concurrent test processes.
    const ts = clock.monoNs();
    var dir_a_buf: [128]u8 = undefined;
    var dir_b_buf: [128]u8 = undefined;
    // Cannot fail (fixed prefix plus a u64 into 128 bytes); unreachable keeps
    // the paths from ever aliasing "." and being deleted by the teardown.
    const dir_a = std.fmt.bufPrint(&dir_a_buf, ".zdtd_cfg_cache/dst_wire_a_{d}", .{ts}) catch unreachable;
    const dir_b = std.fmt.bufPrint(&dir_b_buf, ".zdtd_cfg_cache/dst_wire_b_{d}", .{ts}) catch unreachable;
    // Unique names mean nothing reclaims these worlds otherwise.
    defer io_fs.removeDirTree(dir_a);
    defer io_fs.removeDirTree(dir_b);

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir_a, 0, .{
            .worldgen_seed = 0xBAD_5EED,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        _ = try g.attachJoinedClient(&cap_a);
        var i: u32 = 0;
        while (i < 24) : (i += 1) try g.step();
    }
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir_b, 0, .{
            .worldgen_seed = 0xBAD_5EED,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        _ = try g.attachJoinedClient(&cap_b);
        var i: u32 = 0;
        while (i < 24) : (i += 1) try g.step();
    }
    try std.testing.expectEqual(cap_a.n, cap_b.n);
    var si: usize = 0;
    while (si < cap_a.n) : (si += 1) {
        try std.testing.expectEqual(cap_a.slots[si].len, cap_b.slots[si].len);
        try std.testing.expectEqualSlices(
            u8,
            cap_a.slots[si].data[0..cap_a.slots[si].len],
            cap_b.slots[si].data[0..cap_b.slots[si].len],
        );
    }
}

test "offline challenge Guid replays from the DST run seed" {
    // Under sim mode the pre-auth challenge must not sample OS entropy: it
    // rides the first outbound Capture slot and would break byte-for-byte
    // wire replay for the same seed.
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const ts = clock.monoNs();
    var dir_a_buf: [128]u8 = undefined;
    var dir_b_buf: [128]u8 = undefined;
    const dir_a = std.fmt.bufPrint(&dir_a_buf, ".zdtd_cfg_cache/dst_chal_a_{d}", .{ts}) catch unreachable;
    const dir_b = std.fmt.bufPrint(&dir_b_buf, ".zdtd_cfg_cache/dst_chal_b_{d}", .{ts}) catch unreachable;
    defer io_fs.removeDirTree(dir_a);
    defer io_fs.removeDirTree(dir_b);

    var ch_a: [16]u8 = undefined;
    var ch_b: [16]u8 = undefined;
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir_a, 0, .{
            .worldgen_seed = 0xC4A11E46,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var cap: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&cap);
        ch_a = cl.challenge;
        try std.testing.expect(!std.mem.eql(u8, &ch_a, &[_]u8{0} ** 16));
    }
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir_b, 0, .{
            .worldgen_seed = 0xC4A11E46,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var cap: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&cap);
        ch_b = cl.challenge;
    }
    try std.testing.expectEqualSlices(u8, &ch_a, &ch_b);
}

test "ban expiry under virtual wall is seed-stable" {
    // Offline Game enables the virtual clock: wallSeconds must not sample host
    // REALTIME or ban add/expire cannot replay from a seed.
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/dst_ban_wall", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expect(util_sim.isEnabled());
    // default_start_ns = 1s → wall epoch second 1.
    try std.testing.expectEqual(@as(i64, 1), clock.wallSeconds());
    try std.testing.expect(g.ban_list.add("Eve", clock.wallSeconds() + 2, "tmp"));
    try std.testing.expect(g.ban_list.banned("Eve", clock.wallSeconds()));
    clock.advanceNs(3_000_000_000);
    try std.testing.expectEqual(@as(i64, 4), clock.wallSeconds());
    try std.testing.expect(!g.ban_list.banned("Eve", clock.wallSeconds()));
}

test "world clock persists across a restart (BM calendar survives)" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const dir = ".zdtd_cfg_cache/clock_persist";
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        // Day 5, 12:30 - deinit saves clock.zcl.
        g.sim.director.clock.day = 5;
        g.sim.director.clock.hours = 12.5;
    }
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqual(@as(u32, 5), g.sim.director.clock.day);
        try std.testing.expectApproxEqAbs(@as(f32, 12.5), g.sim.director.clock.hours, 0.001);
    }

    // The round trip covers the write side. restoreClock also has to survive a
    // corrupt or older file without taking the server down, and none of those
    // paths had a test: it keeps whatever the fresh roll produced instead.
    {
        var path_buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/clock.zcl", .{dir});

        // Shorter than the 12-byte ZCL1 head: rejected, clock left untouched.
        try io_fs.writeFile(p, "ZCL2\x00\x00");
        const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        // A fresh world starts at day 1; the truncated file must not have
        // moved it, and must not have panicked getting there.
        try std.testing.expectEqual(@as(u32, 1), g.sim.director.clock.day);
    }

    {
        // A ZCL1 file restores the world time only. Written at full ZCL2 length
        // with a nonzero tail on purpose: the loader must gate the blood-moon
        // fields on the magic, not on the byte count, or it reads a ZCL1 tail
        // that was never a schedule. bm_freq 0 is what a fresh clock has, so a
        // magic-blind read would show up as 0xEEEEEEEE here.
        var path_buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/clock.zcl", .{dir});
        var zcl1: [28]u8 = @splat(0xEE);
        @memcpy(zcl1[0..4], "ZCL1");
        // Day 3 = (3 - 1) * 24000 world-time units.
        std.mem.writeInt(u64, zcl1[4..12], 2 * 24000, .little);
        try io_fs.writeFile(p, &zcl1);
        const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqual(@as(u32, 3), g.sim.director.clock.day);
        // The 0xEE tail must not have been read as a blood-moon schedule.
        try std.testing.expect(g.sim.director.clock.bm_freq != 0xEEEEEEEE);
    }
}

test "setgamepref applies runtime GameStats prefs and broadcasts" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const dir = ".zdtd_cfg_cache/pref_set_test";
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const gs_id = packages.idOf("NetPackageGameStats").?;
    try std.testing.expectEqual(@as(u8, 1), g.sim.director.difficulty); // Adventurer default

    // A writable pref applies to the sim and reaches the client as a fresh
    // GameStats blob (HUD difficulty / blood-moon day follow the server).
    cap.clear();
    g.runAdminLine("setgamepref GameDifficulty 3", "test");
    try std.testing.expectEqual(@as(u8, 3), g.sim.director.difficulty);
    try std.testing.expect(cap.findPkgId(gs_id) != null);

    // Values clamp to the config loader's range.
    g.runAdminLine("setgamepref GameDifficulty 99", "test");
    try std.testing.expectEqual(@as(u8, 5), g.sim.director.difficulty);

    // Another writable key.
    g.runAdminLine("setgamepref BloodMoonFrequency 14", "test");
    try std.testing.expectEqual(@as(u32, 14), g.sim.director.clock.bloodmoon_frequency);

    // Unknown / startup-only prefs keep the read-only reply and touch nothing.
    const info_port_before = g.info_port;
    g.runAdminLine("setgamepref ServerPort 9999", "test");
    try std.testing.expectEqual(info_port_before, g.info_port);
}

test "sleeper scan job batch matches the serial pass" {
    var vols: [64]sleepers_mod.Volume = undefined;
    for (&vols, 0..) |*v, i| {
        const x: i32 = @intCast(i * 10);
        v.* = .{ .x0 = x, .y0 = 0, .z0 = 0, .x1 = x + 4, .y1 = 8, .z1 = 4 };
    }
    vols[3].triggered = true;
    var st: sleepers_mod.Store = .{ .volumes = vols[0..] };
    const px = [_]f32{ 1, 31, 101 };
    const py = [_]f32{ 1, 1, 1 };
    const pz = [_]f32{ 1, 1, 1 };
    var serial: [vols.len]u8 = .{0} ** vols.len;
    var batched: [vols.len]u8 = .{0} ** vols.len;

    const base = Game.SleeperScanCtx{ .sl = &st, .px = &px, .py = &py, .pz = &pz, .hit = serial[0..] };
    Game.SleeperScanCtx.work(base, 0, vols.len);
    var par = base;
    par.hit = batched[0..];
    // 64 >= parallel.min_parallel_items, so this really fans out.
    parallel.forRanges(vols.len, par, Game.SleeperScanCtx.work);

    try std.testing.expectEqualSlices(u8, serial[0..], batched[0..]);
    try std.testing.expectEqual(@as(u8, 1), serial[0]);
    // Already triggered: never re-tested, never re-spawned.
    try std.testing.expectEqual(@as(u8, 0), serial[3]);
    try std.testing.expectEqual(@as(u8, 1), serial[10]);
}

test "path step hook sees walls and terrain, and the snapshot agrees" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/terrain_snap", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const ch = try g.world.getOrCreate(.{ .x = 0, .z = 0 });
    const surface: i32 = ch.heightAt(2, 3);
    const from_y: i32 = surface + 1;
    // Two-course wall built through the public API: too tall to step onto and
    // no headroom on the first course.
    try g.world.setBlockWorld(2, surface + 1, 3, world_store.block_stone);
    try g.world.setBlockWorld(2, surface + 2, 3, world_store.block_stone);

    // Baseline: snapshot off, the locked hook answers.
    g.terrain_snapshot_on = false;
    const open_y: i32 = @as(i32, ch.heightAt(5, 5)) + 1;
    try std.testing.expectEqual(@as(?i32, null), Game.pathStepAt(g, 1, 3, from_y, 2, 3));
    try std.testing.expectEqual(@as(?i32, open_y), Game.pathStepAt(g, 4, 5, open_y, 5, 5));

    const px = [_]f32{0};
    const pz = [_]f32{0};
    try std.testing.expectEqual(@as(usize, 1), g.terrain_snap.rebuild(&g.world, &px, &pz));
    g.terrain_snapshot_on = true;
    // The wall column is out of the step band: the snapshot misses and the
    // locked hook still reports it blocked.
    try std.testing.expectEqual(@as(?i32, null), Game.pathStepAt(g, 1, 3, from_y, 2, 3));
    try std.testing.expect(g.terrain_snap.misses.load(.monotonic) > 0);
    // Open terrain is answered lock-free.
    const before_misses = g.terrain_snap.misses.load(.monotonic);
    try std.testing.expectEqual(@as(?i32, open_y), Game.pathStepAt(g, 4, 5, open_y, 5, 5));
    try std.testing.expectEqual(before_misses, g.terrain_snap.misses.load(.monotonic));

    // Outside the window: falls through to the locked hook, which still
    // generates the chunk on demand exactly as before.
    const before = g.world.chunks.count();
    _ = Game.pathStepAt(g, 4000, 4000, from_y, 4001, 4000);
    try std.testing.expectEqual(before + 1, g.world.chunks.count());
}

test "parallel solid/water/sight probes share one world without corruption" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/terrain_hooks_par", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // The port-0 offline Game pins DST serial scheduling; this test needs real
    // fan-out so several workers enter the chunk-generating probes at once.
    // (Pre-2026-08 audit these hooks reached World.getOrCreate unlocked:
    // concurrent getOrPut/rehash on the chunk map plus non-atomic touch_seq.
    // sight_fn had the same hole until it took terrain_mu like solid/water.)
    defer parallel.setForceSerial(false);
    parallel.setForceSerial(false);
    const Probe = struct {
        g: *Game,
        fn work(ctx: @This(), begin: usize, end: usize) void {
            const solid = ctx.g.sim.solid_fn.?;
            const water = ctx.g.sim.water_fn.?;
            const sight = ctx.g.sim.sight_fn.?;
            var i = begin;
            while (i < end) : (i += 1) {
                // Interleave coordinates across a 128x128 block area (64
                // chunks) so every worker inserts into the same chunk keys.
                const x: i32 = @as(i32, @intCast(i % 128)) - 64;
                const z: i32 = @as(i32, @intCast((i / 128) % 128)) - 64;
                _ = solid(ctx.g, x, 61, z);
                _ = water(ctx.g, x, 60, z);
                _ = sight(ctx.g, x, 62, z);
            }
        }
    };
    parallel.forRanges(128 * 128, Probe{ .g = g }, Probe.work);
    // All workers joined: the map is consistent and answers stably.
    try std.testing.expect(g.world.chunks.count() >= 64);
    const s0 = g.sim.solid_fn.?(g, 3, 61, 3);
    try std.testing.expectEqual(s0, g.sim.solid_fn.?(g, 3, 61, 3));
    const sight0 = g.sim.sight_fn.?(g, 3, 62, 3);
    try std.testing.expectEqual(sight0, g.sim.sight_fn.?(g, 3, 62, 3));
}

test "deco suppression follows the prefab AllowDecorations property" {
    // V3.2.0 changelog-3.2.0 §4.5: world (biome) decorations are suppressed
    // inside a POI footprint unless the prefab sets AllowDecorations="true".
    // The sampler's per-deco-chunk cache is built from the real Navezgane
    // decoration list, so this exercises the data path, not a fixture.
    const game_dir = stock_paths.dedicated_server;
    const map_dir = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map_dir)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir, .map_dir = map_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const pf = if (g.world.prefabs) |*p| p else return error.SkipZigTest;
    // One pass over the shipped decorations: the first non-part POI that did
    // not opt into decorations gives a deterministic point inside a suppressed
    // footprint, and the map must also ship at least one opted-in prefab so the
    // gate is not trivially all-true.
    var inside: ?struct { x: i32, z: i32 } = null;
    var allowed_found = false;
    var suppressed_found = false;
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (qd.allow_decorations) {
            allowed_found = true;
            continue;
        }
        suppressed_found = true;
        if (inside != null) continue;
        const b = pf.boundsXZ(i);
        if (b.x1 - b.x0 < 4 or b.z1 - b.z0 < 4) continue;
        inside = .{ .x = @divTrunc(b.x0 + b.x1, 2), .z = @divTrunc(b.z0 + b.z1, 2) };
    }
    try std.testing.expect(suppressed_found);
    try std.testing.expect(allowed_found);
    const c0 = inside orelse return error.SkipZigTest;
    const deco_shard = @import("deco.zig");
    try std.testing.expect(deco_shard.decoSuppressedAt(g, c0.x, c0.z));
    // The species sampler turns a suppressed cell into no deco at all: the
    // client must not receive a block id it would try to model inside the POI.
    try std.testing.expectEqual(@as(usize, 0), Game.decoSpeciesAt(g, c0.x, c0.z).n);
    // Far from every footprint nothing is suppressed.
    try std.testing.expect(!deco_shard.decoSuppressedAt(g, c0.x + 4000, c0.z + 4000));
}

test "deco burst is biome driven and mirrors into the block store" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/deco_biome", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Without a biome map there is nothing to drive density: fail closed.
    try std.testing.expect(g.world.biomes == null);
    try std.testing.expectEqual(@as(usize, 0), Game.decoSpeciesAt(g, 0, 0).n);

    // One-biome map covering the join window, and one distant-deco species that
    // always passes the roll so the placement path is actually exercised.
    const biome_id: u8 = 3;
    const side: i32 = 64;
    const cells = try std.testing.allocator.alloc(u8, @intCast(side * side));
    @memset(cells, biome_id);
    g.world.biomes = .{
        .width = side,
        .height = side,
        .r = cells,
        .allocator = std.testing.allocator,
        .half_w = @divTrunc(side, 2),
        .half_h = @divTrunc(side, 2),
        .scale = 16,
    };
    const tree_id: u16 = 24629; // treeOakSml01 in the bundled dump
    var set: assets_biome_layers.DecoSet = .{};
    set.blocks[0] = .{ .block_id = tree_id, .prob = 1.0 };
    set.n = 1;
    g.world.biome_layers_table.decos[biome_id] = set;
    try std.testing.expect(g.world.biome_layers_table.hasDecos());
    try std.testing.expectEqual(@as(usize, 1), Game.decoSpeciesAt(g, 0, 0).n);
    try std.testing.expectEqual(tree_id, Game.decoSpeciesAt(g, 0, 0).items[0].block_id);

    // The mirror needs the dump to resolve the id back to a MultiBlockDim.
    g.maxdamage.tryMergeBundledAssignIds(std.testing.allocator);
    if (g.maxdamage.idNameCount() == 0) return error.SkipZigTest;

    var cache: Game.DecoDimCache = .{};
    const h = try g.world.heightWorld(3, 5);
    const o: packages.stock_deco.DecoObj = .{
        .x = 3,
        .y = @intCast(h + 1),
        .z = 5,
        .real_y = @floatFromInt(h + 1),
        .block_raw = tree_id,
    };
    // The world dir survives between runs (deinit saves chunks), so clear the
    // target cell rather than assume a pristine column.
    try g.world.setBlockDecoWorld(3, @intCast(h + 1), 5, g.world.terrain_ids.air);
    try std.testing.expect(g.mirrorDeco(&cache, o));
    try std.testing.expectEqual(tree_id, try g.world.blockWorld(3, @intCast(h + 1), 5));
    // Terrain surface must not follow the tree up.
    try std.testing.expectEqual(h, try g.world.heightWorld(3, 5));
    // Cached: a second object of the same species must not rescan the dump, and
    // must still be skipped because the anchor is now a decoration.
    try std.testing.expectEqual(@as(usize, 1), cache.n);
    try std.testing.expect(!g.mirrorDeco(&cache, o));

    // An id with no name in the dump places nothing rather than a bare parent.
    const unknown: packages.stock_deco.DecoObj = .{ .x = 9, .y = 60, .z = 9, .real_y = 60, .block_raw = 0xfffe };
    try std.testing.expect(!g.mirrorDeco(&cache, unknown));
    try std.testing.expect(try g.world.blockWorld(9, 60, 9) != 0xfffe);
}

test "zombie chases over real terrain and stays on the surface" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/path_terrain", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const sp = g.world.primarySpawn();
    const sx: f32 = @floatFromInt(sp.x);
    const sy: f32 = @floatFromInt(sp.y);
    const sz: f32 = @floatFromInt(sp.z);
    const zid = g.sim.spawnZombie(sx + 8, sy, sz, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    _ = g.sim.spawnPlayer(sx, sy, sz, 0).?;
    const x0 = g.sim.transform[zs].x;
    var i: usize = 0;
    while (i < 40) : (i += 1) try g.step();
    // Closed on the player: the real step predicate must not read as a sealed
    // world (the old height+1 probe made every column open, this one must make
    // open ground passable).
    try std.testing.expect(g.sim.transform[zs].x < x0 - 1.0);
    // Feet sit on the column the body is standing over, not at spawn height.
    const wx: i32 = @floor(g.sim.transform[zs].x);
    const wz: i32 = @floor(g.sim.transform[zs].z);
    const h: i32 = try g.world.heightWorld(wx, wz);
    try std.testing.expectEqual(@as(f32, @floatFromInt(h + 1)), g.sim.transform[zs].y);
}

test "[perf] switches run on the live step path" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/perf_switches", 0, .{
        .async_chunk_flush = true,
        .terrain_snapshot = true,
        .job_batches = true,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expect(g.terrain_snapshot_on);
    try std.testing.expect(g.job_batches);
    try std.testing.expect(g.world.async_flush);
    // Offline Game runs force-serial, so the flush must stay inline there.
    try std.testing.expect(!g.world.asyncEnabled());

    try g.world.setBlockWorld(4, 70, 4, world_store.block_stone);
    var i: u32 = 0;
    while (i < 3) : (i += 1) try g.step();
    // Snapshot rebuild is on the live path, not dead code.
    try std.testing.expect(g.harness.prof.histOf(.terrain_snap).count >= 3);
}

test "power visuals rewrite block meta once per state change" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/power_visuals", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try g.world.setBlockWorld(8, 70, 8, world_store.block_stone);
    const id = g.sim.power.addNodeAt(.consumer, 8, 70, 8, 10).?;
    const ni = g.sim.power.indexOfId(id).?;
    g.sim.power.nodes[ni].powered = true;

    replicate_te.broadcastPowerVisuals(g);
    const raw = g.blockRawAt(8, 70, 8);
    try std.testing.expectEqual(world_store.block_stone, world_store.typeId(raw));
    try std.testing.expectEqual(
        packages.block_meta_on | packages.block_meta_powered,
        packages.blockMeta(raw),
    );

    // Nothing flipped: the second pass must not touch the block or emit a
    // packet. Power visuals write through to the chunk plane (GAP 13), so
    // clearing the sparse mirror alone leaves the powered bits on the chunk;
    // the observable is that those bits stay put without a second write.
    g.clearBlockRaw(8, 70, 8);
    replicate_te.broadcastPowerVisuals(g);
    try std.testing.expectEqual(
        packages.block_meta_on | packages.block_meta_powered,
        packages.blockMeta(g.blockRawAt(8, 70, 8)),
    );

    // Losing power is an edge, so it writes meta 0 again.
    g.sim.power.nodes[ni].powered = false;
    replicate_te.broadcastPowerVisuals(g);
    try std.testing.expectEqual(@as(u8, 0), packages.blockMeta(g.blockRawAt(8, 70, 8)));
}

test "player game stage tracks level, days survived and deaths" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/gamestage", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Stock config defaults when gamestages.xml is absent (asm.il .cctor ~1093405).
    g.gamestages.config = .{ .difficulty_bonus = 1.2, .days_alive_change_when_killed = 2 };
    const c = &g.clients[0];
    c.joined = true;
    c.level = 10;
    g.sim.director.clock.day = 0;
    g.sim.director.clock.hours = 0;
    c.game_stage_born_world_time = g.sim.director.clock.worldTimeBits();
    // Day zero: level only, floored after the difficulty bonus (10 * 1.2 = 12).
    try std.testing.expectEqual(@as(i32, 12), g.gameStageOf(0));
    // Four days survived: (10 + 4) * 1.2 = 16.8 → 16, the header's example.
    // Stock days are 1-based: day 5 is four days after the day-0 birth.
    g.sim.director.clock.day = 5;
    try std.testing.expectEqual(@as(i32, 16), g.gameStageOf(0));
    // Days alive caps at the player level: 25 days at level 10 is 10.
    g.sim.director.clock.day = 26;
    try std.testing.expectEqual(@as(i32, 24), g.gameStageOf(0));
    // A death costs daysAliveChangeWhenKilled days off the streak.
    const before = c.game_stage_born_world_time;
    c.game_stage_born_world_time = assets_gamestages.bornAtAfterDeath(
        g.gamestages.config,
        g.sim.director.clock.worldTimeBits(),
        before,
    );
    try std.testing.expectEqual(before + 2 * assets_gamestages.ticks_per_day, c.game_stage_born_world_time);
    // Still capped to level, so the stage is unchanged at 25 days.
    try std.testing.expectEqual(@as(i32, 24), g.gameStageOf(0));
    // Loot stage is level driven and independent of days survived.
    try std.testing.expectEqual(@as(i32, 10), g.lootStageOf(0));
    try std.testing.expectEqual(@as(i32, 10), g.partyLootStage());
    // A single player's party stage is just their own stage.
    try std.testing.expectEqual(@as(i32, 24), g.partyStageAround(0, 0, -1));
}

test "party stage weights the second player by diminishing returns" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/partystage", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    g.gamestages.config = .{ .difficulty_bonus = 1, .starting_weight = 1, .diminishing_returns = 0.5 };
    g.sim.director.clock.day = 0;
    g.sim.director.clock.hours = 0;
    const now = g.sim.director.clock.worldTimeBits();
    for ([_]struct { slot: usize, level: u16 }{ .{ .slot = 0, .level = 40 }, .{ .slot = 1, .level = 20 } }) |p| {
        const c = &g.clients[p.slot];
        c.joined = true;
        c.level = p.level;
        c.game_stage_born_world_time = now;
    }
    try std.testing.expectEqual(@as(i32, 40), g.gameStageOf(0));
    try std.testing.expectEqual(@as(i32, 20), g.gameStageOf(1));
    // 40 * 1 + 20 * 0.5 = 50 (CalcPartyLevel, asm.il ~1093305).
    try std.testing.expectEqual(@as(i32, 50), g.partyStageAround(0, 0, -1));
    // Highest party loot stage, not the sum.
    try std.testing.expectEqual(@as(i32, 40), g.partyLootStage());
    // Per-player party loot stage: ungrouped players use their own stage;
    // grouped, the party high water mark (Party.GetHighestLootStage).
    g.clients[0].entity_id = 100;
    g.clients[1].entity_id = 101;
    try std.testing.expectEqual(@as(i32, 40), g.lootStageForPlayer(0));
    try std.testing.expectEqual(@as(i32, 20), g.lootStageForPlayer(1));
    try std.testing.expect(g.parties.acceptInvite(100, 101) != null);
    try std.testing.expectEqual(@as(i32, 40), g.lootStageForPlayer(1));
    // No joined players is stage 0, and the loot floor stays at 1.
    g.clients[0].joined = false;
    g.clients[1].joined = false;
    try std.testing.expectEqual(@as(i32, 0), g.partyStageAround(0, 0, -1));
    try std.testing.expectEqual(@as(i32, 1), g.partyLootStage());
}

test "sleeper volume groups resolve through the gamestage ladder" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/sleepergs", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Synthetic tables: the stock POI group name is a gamestage group, never an
    // entitygroup, so the pre-gamestage lookup could only reach defaultZombie.
    var gs = try assets_gamestages.loadFromSlice(std.testing.allocator,
        \\<gamestages>
        \\  <group name="1GroupGenericZombie" spawner="SleeperGSList"/>
        \\  <spawner name="SleeperGSList">
        \\    <gamestage stage="0"><spawn group="ZombiesAll" num="3" maxAlive="2"/></gamestage>
        \\  </spawner>
        \\</gamestages>
    );
    g.gamestages.deinit();
    g.gamestages = gs;
    gs = undefined;

    // A one-entry entity group so the pick is deterministic and distinguishable
    // from defaultZombie (which is zombieBoe in the builtin table).
    const stag_entries = [_]assets_entitygroups.Entry{.{ .name = "animalStag", .weight = 1 }};
    const stage_groups = [_]assets_entitygroups.Group{
        .{ .name = "ZombiesAll", .entries = &stag_entries, .weight_sum = 1 },
    };
    g.entitygroups.deinit();
    g.entitygroups = .{ .groups = &stage_groups };

    const walker = g.entities.defaultZombie();
    // Both stock spellings clean to the same key and reach a real class.
    for ([_][]const u8{ "GroupGenericZombie", "S_-Group_Generic_Zombie" }) |name| {
        const sg = g.gamestages.sleeperEntityGroup(name, 0) orelse return error.GroupUnresolved;
        try std.testing.expectEqualStrings("ZombiesAll", sg.group);
        try std.testing.expectEqual(@as(u16, 3), sg.num);
        try std.testing.expectEqual(@as(u16, 2), sg.max_alive);
        // The class comes from the stage's entitygroup, not the default walker.
        const def = g.resolveSleeperClass(name, sg, 11);
        try std.testing.expectEqualStrings("animalStag", def.name);
        try std.testing.expect(!std.mem.eql(u8, walker.name, def.name));
    }
    // A stage below the ladder's first entry resolves to nothing (stock returns
    // null from GetStage), so the old entityclass/entitygroup path still runs.
    try std.testing.expect(g.gamestages.sleeperEntityGroup("GroupGenericZombie", -1) == null);
    try std.testing.expectEqualStrings(walker.name, g.resolveSleeperClass("NoSuchThing", null, 3).name);
}

test "console replies use the stock error and listing shapes" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    // Start from a fresh world: a previous run's persisted vehicles would
    // bloat listents rows past the 8 KiB reply sink and drop the total line.
    io_fs.removeDirTree(".zdtd_cfg_cache/admin_stock_shapes");
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/admin_stock_shapes", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var sink: [8192]u8 = undefined;

    try std.testing.expectEqualStrings(
        "*** ERROR: unknown command 'frobnicate'\n",
        adminRun(g, &sink, "frobnicate 1"),
    );
    try std.testing.expectEqualStrings(
        "Wrong number of arguments, expected 1 or 3, found 2.\n",
        adminRun(g, &sink, "settime 1 2"),
    );
    try std.testing.expectEqualStrings("Day must be >= 1\n", adminRun(g, &sink, "settime 0 1 1"));
    try std.testing.expectEqualStrings(
        "\"noon\" is not a valid integer.\n",
        adminRun(g, &sink, "settime 1 noon 0"),
    );
    // No players joined: both listings are just the stock total line.
    try std.testing.expectEqualStrings("Total of 0 in the game\n", adminRun(g, &sink, "listplayers"));
    try std.testing.expectEqualStrings("Total of 0 in the game\n", adminRun(g, &sink, "listplayerids"));
    // A miss on a player target reports the stock resolution error.
    try std.testing.expectEqualStrings(
        "\"Alice\" is not a valid entity id, player name or user id.\n",
        adminRun(g, &sink, "kick Alice"),
    );

    const help = adminRun(g, &sink, "help");
    try std.testing.expect(std.mem.startsWith(u8, help, "*** Generic Console Help ***\n"));
    try std.testing.expect(std.mem.find(u8, help, "*** List of Commands ***\n") != null);
    try std.testing.expect(std.mem.find(u8, help, " => lists all players\n") != null);

    // `help <topic>` resolves the usage line; an unknown topic gets the same
    // unknown-command reply a bare miss gets.
    try std.testing.expectEqualStrings("usage: kick <name/entity id/user id> [reason]\n", adminRun(g, &sink, "help kick"));
    try std.testing.expectEqualStrings("usage: gettime\n", adminRun(g, &sink, "help gt"));
    try std.testing.expectEqualStrings("*** ERROR: unknown command 'frobnicate'\n", adminRun(g, &sink, "help frobnicate"));

    // settime takes stock world time and reports it back verbatim.
    try std.testing.expectEqualStrings("Set time to 12000\n", adminRun(g, &sink, "settime day"));
    try std.testing.expectEqual(@as(u32, 1), g.sim.director.clock.day);
    try std.testing.expectEqual(@as(f32, 12), g.sim.director.clock.hours);
    try std.testing.expectEqualStrings("Set time to 24000\n", adminRun(g, &sink, "settime night"));
    try std.testing.expectEqual(@as(u32, 2), g.sim.director.clock.day);
    try std.testing.expectEqual(@as(f32, 0), g.sim.director.clock.hours);
    // A lone numeric is RAW world time (1000 = 1 h), not a day: the stock
    // playtest barrier sends `settime 22000` for the blood-moon night.
    try std.testing.expectEqualStrings("Set time to 22000\n", adminRun(g, &sink, "settime 22000"));
    // gettime / daysToBloodMoon follow the jittered CalcNextDay schedule
    // (BloodMoonRange), not the plain frequency modulus.
    g.sim.director.clock.bloodmoon_frequency = 7;
    const d0 = g.daysToBloodMoon();
    try std.testing.expect(d0 >= 1 and d0 <= 7);

    // listents rows carry the stock field order for the seeded zombies.
    const ents = adminRun(g, &sink, "listents");
    try std.testing.expect(std.mem.find(u8, ents, ", pos=(") != null);
    try std.testing.expect(std.mem.find(u8, ents, ", rot=(") != null);
    try std.testing.expect(std.mem.find(u8, ents, ", lifetime=float.Max, remote=False, dead=False, health=") != null);
    try std.testing.expect(std.mem.find(u8, ents, "in the game\n") != null);

    try std.testing.expect(std.mem.startsWith(u8, adminRun(g, &sink, "chunkcache"), "Chunks: "));
    try std.testing.expect(std.mem.startsWith(u8, adminRun(g, &sink, "mem"), "Time: "));
    try std.testing.expect(std.mem.find(u8, adminRun(g, &sink, "gg ServerPort"), "GamePref.ServerPort = ") != null);
}

test "admin, whitelist and ban lists persist across a restart" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const dir = ".zdtd_cfg_cache/admin_lists_persist";
    var sink: [8192]u8 = undefined;
    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqualStrings(
            "Alice added with permission level of 0.\n",
            adminRun(g, &sink, "admin add Alice 0"),
        );
        try std.testing.expectEqualStrings(
            "Bob added to whitelist.\n",
            adminRun(g, &sink, "whitelist add Bob"),
        );
        try std.testing.expect(std.mem.startsWith(u8, adminRun(g, &sink, "ban add Carol 1 day rude"), "Carol banned until "));
        // An expired ban must not survive the round-trip.
        _ = g.ban_list.add("Dave", clock.wallSeconds() - 1, "old");
        g.saveAdminLists();
    }
    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        const admins = adminRun(g, &sink, "admin list");
        try std.testing.expect(std.mem.find(u8, admins, "0: Alice (stored name: Alice)\n") != null);
        try std.testing.expect(std.mem.find(u8, adminRun(g, &sink, "whitelist list"), "  Bob (stored name: Bob)\n") != null);
        const bans = adminRun(g, &sink, "ban list");
        try std.testing.expect(std.mem.find(u8, bans, "Carol) - rude\n") != null);
        try std.testing.expect(std.mem.find(u8, bans, "Dave") == null);

        try std.testing.expectEqualStrings(
            "Carol removed from ban list.\n",
            adminRun(g, &sink, "ban remove Carol"),
        );
        try std.testing.expectEqualStrings(
            "Alice removed from permissions list.\n",
            adminRun(g, &sink, "admin remove Alice"),
        );
        try std.testing.expectEqualStrings(
            "Alice was not on permissions list.\n",
            adminRun(g, &sink, "admin remove Alice"),
        );
        try std.testing.expectEqualStrings(
            "Bob removed from the whitelist.\n",
            adminRun(g, &sink, "whitelist remove Bob"),
        );
    }
}

/// Run one console line against a Game and capture the reply the way the webui
/// path does, so a test asserts the exact bytes an operator tool would read.
fn adminRun(g: *Game, sink: []u8, line: []const u8) []const u8 {
    g.admin_reply_len = 0;
    g.admin_reply_sink = sink;
    g.runAdminLine(line, "test");
    g.admin_reply_sink = null;
    return sink[0..g.admin_reply_len];
}

test "survival: food/water deplete, starvation damages, well-fed regens, S2C syncs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot).?;
    // Pin the clock rate so one tickSurvival(1.0) call is exactly one in-game
    // hour regardless of the default day-length config (1000 world ticks per
    // in-game hour, stock TimeOfDayIncPerSec rate).
    g.sim.director.clock.time_of_day_inc_per_sec = 1000;
    g.sim.health[ps].food = 100;
    g.sim.health[ps].water = 100;
    g.sim.health[ps].hp = 100;
    const st_id = packages.idOf("NetPackageEntityStatChanged").?;

    // One in-game hour: food -2, water -2.5.
    cap.clear();
    g.tickSurvival(1.0);
    try std.testing.expect(g.sim.health[ps].food < 100);
    try std.testing.expect(g.sim.health[ps].water < 100);
    try std.testing.expect(cap.findPkgId(st_id) != null); // S2C sync fired

    // Starvation: exhausted food drains hp (12/game-hour).
    g.sim.health[ps].food = 0;
    g.sim.health[ps].water = 100;
    const hp_before = g.sim.health[ps].hp;
    g.tickSurvival(1.0);
    try std.testing.expect(g.sim.health[ps].hp < hp_before);

    // Well-fed regen: fed + hydrated restores hp (10/game-hour), capped.
    g.sim.health[ps].hp = 50;
    g.sim.health[ps].food = 90;
    g.sim.health[ps].water = 90;
    g.tickSurvival(1.0);
    try std.testing.expect(g.sim.health[ps].hp > 50);
    try std.testing.expect(g.sim.health[ps].hp <= g.sim.health[ps].max_hp);

    // Clamp at zero: depletion never goes negative.
    g.sim.health[ps].food = 0.5;
    g.sim.health[ps].water = 0.5;
    g.tickSurvival(1.0);
    try std.testing.expect(g.sim.health[ps].food == 0);
    try std.testing.expect(g.sim.health[ps].water == 0);

    // Stamina: sprinting drains (MovementState 3), idle regenerates, and the
    // stale timer lapses the sprint latch without further speed updates.
    g.sim.health[ps].stamina = 50;
    cl.sprint_speed = 5;
    cl.sprint_stale_cd = 5.0; // outlives the 0.2 s tick below
    g.tickSurvival(0.2);
    try std.testing.expect(g.sim.health[ps].stamina < 50);
    // Stale expiry clears the latch even if no EntitySpeeds arrives.
    cl.sprint_stale_cd = 0.1;
    g.tickSurvival(0.2);
    try std.testing.expectEqual(@as(f32, 0), cl.sprint_speed);
    const st_before = g.sim.health[ps].stamina;
    g.tickSurvival(0.2);
    try std.testing.expect(g.sim.health[ps].stamina > st_before);
    try std.testing.expect(g.sim.health[ps].stamina <= g.sim.health[ps].stamina_max);
}

test "survival: zero decay rates do not disable the rest of the pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.director.clock.time_of_day_inc_per_sec = 1000;
    // presets/builder.toml zeroes both rates; only the two decay writes may be
    // skipped then (the old early return also skipped stamina, drowning,
    // radiation and the buff lifecycle).
    g.sim.rules.progression.food_depletion_per_hour = 0;
    g.sim.rules.progression.water_depletion_per_hour = 0;
    g.sim.health[ps].food = 100;
    g.sim.health[ps].water = 100;
    g.sim.health[ps].stamina = 50;
    cl.sprint_speed = 5;
    cl.sprint_stale_cd = 5.0;
    g.tickSurvival(0.2);
    try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].food);
    try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].water);
    // Sprint drain lives in the same pass and must still run.
    try std.testing.expect(g.sim.health[ps].stamina < 50);
}

test "compressible packages send deflated frames the parser can read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    // A byte-diverse payload (stock chunk data is far from compressible
    // trivially; 251-period bytes still exercise the deflate window).
    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 251);
    const pkgs_under_test = [_][]const u8{ "NetPackageChunk", "NetPackageSignDataResponse" };
    for (pkgs_under_test) |pkg_name| {
        cap.clear();
        try std.testing.expect(g.trySendCompressed(cl.peer.?, pkg_name, &payload));
        const pkg_id = packages.idOf(pkg_name).?;
        var pkgs: [8]wire_frame.Package = undefined;
        var found = false;
        for (cap.slots[0..cap.n]) |s| {
            const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
            for (pkgs[0..pn]) |p| {
                if (p.id == pkg_id and std.mem.eql(u8, p.body, &payload)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "stock client quest name gate accepts every stock family" {
    const g = try Game.create(std.testing.allocator, ".zdtd_cfg_cache/questname", 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // The builtin catalog (no stock_xml) exercises the prefix gate directly.
    try std.testing.expect(g.isStockClientQuestName("quest_whiteRiverCitizen1"));
    try std.testing.expect(g.isStockClientQuestName("tier1_clear"));
    try std.testing.expect(g.isStockClientQuestName("intro_buried_supplies"));
    try std.testing.expect(g.isStockClientQuestName("test_fixture"));
    try std.testing.expect(g.isStockClientQuestName("challengegroup_reward_homesteading"));
    try std.testing.expect(g.isStockClientQuestName("treasure_01"));
    try std.testing.expect(!g.isStockClientQuestName("invented_quest"));
    try std.testing.expect(!g.isStockClientQuestName(""));
}

test "vehicles and turrets persist across restart (entities.zen)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        const v = g.sim.spawnVehicleEx(.minibike, 10, 70, 20, 200, 12, 1).?;
        const vs = g.sim.slotOfNetId(v).?;
        g.sim.vehicle[vs].fuel = 55;
        g.sim.transform[vs].yaw = 90;
        const t = g.sim.spawnTurret(30, 70, 40).?;
        const ts = g.sim.slotOfNetId(t).?;
        g.sim.turret[ts].ammo = 42;
        try g.saveEntities();
    }
    {
        // Game.create restores entities.zen automatically.
        const g2 = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g2.deinit();
            std.testing.allocator.destroy(g2);
        }
        // Game.create also spawns its demo world vehicle/turret, so match the
        // persisted ones by their saved values rather than first-match.
        var found_v = false;
        var found_t = false;
        var i: usize = 0;
        while (i < ecs.max_entities) : (i += 1) {
            if (!g2.sim.alive[i] or !g2.sim.mask[i].transform) continue;
            if (g2.sim.kind[i] == .vehicle and g2.sim.vehicle[i].fuel == 55) {
                found_v = true;
                try std.testing.expectEqual(@as(f32, 90), g2.sim.transform[i].yaw);
                try std.testing.expectEqual(ecs.components.VehicleKind.minibike, g2.sim.vehicle[i].kind);
            }
            if (g2.sim.kind[i] == .turret and g2.sim.turret[i].ammo == 42) {
                found_t = true;
            }
        }
        try std.testing.expect(found_v and found_t);
    }
}

test "vehicle basket C2S applies and echoes to peers" {
    // RE NetPackageBag (research dedicated-misc-systems.md vehicle storage
    // pin v2): wire = entityId i32 + blobLen u16 + Bag.Write blob (version 1
    // + u16 count + ItemStacks). The client's OnBagModified sends the bag;
    // zdtd applies it to the vehicle's basket and echoes the body to the
    // other clients (the stock S2C sender is unpinned).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    const v = g.sim.spawnVehicleEx(.minibike, 256, 70, 260, 500, 12, 1).?;
    const vs = g.sim.slotOfNetId(v).?;
    try g.seatRider(ca.entity_id, vs, systems.seat_any); // driver seat 0

    // Build the Bag blob: version 1 + 1 slot (wood x5, absolute stock type).
    var blob: [256]u8 = undefined;
    var bw = wire_binary.Writer{ .buf = &blob };
    try bw.writeByte(1);
    try bw.writeU16(1);
    try packages.stock_inv.writeItemStack(&bw, .{ .type_id = 65536 + 7, .count = 5 });
    var body: [300]u8 = undefined;
    var w = wire_binary.Writer{ .buf = &body };
    try w.writeI32(v);
    try w.writeU16(@intCast(bw.pos));
    @memcpy(body[w.pos..][0..bw.pos], blob[0..bw.pos]);
    const body_len = w.pos + bw.pos;

    cap_a.clear();
    cap_b.clear();
    var fb: [512]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageBag", body[0..body_len]));
    const bag_id = packages.idOf("NetPackageBag").?;
    try std.testing.expectEqual(@as(u8, 1), g.sim.vehicle[vs].basket_n);
    try std.testing.expectEqual(@as(u16, 7), g.sim.vehicle[vs].basket[0].item_id); // wood
    try std.testing.expectEqual(@as(u16, 5), g.sim.vehicle[vs].basket[0].count);
    try std.testing.expect(cap_a.findPkgId(bag_id) == null); // sender excluded
    try std.testing.expect(cap_b.findPkgId(bag_id) != null); // peer hears the echo
    std.debug.print("PASS vehicle basket: C2S apply + peer echo, sender excluded\n", .{});
}

test "power nodes rebuild from chunk blocks after restart (scanChunkPower)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // The registry is built from game data (blocks.xml) at load; a test world
    // has none, so seed two synthetic power block ids through the same build
    // path a stock install would use.
    const PowerStub = struct {
        power_class_by_name: std.StringHashMapUnmanaged([]const u8) = .{},
        pub fn idByName(_: *const @This(), name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "generatorbank")) return 20001;
            if (std.mem.eql(u8, name, "batterybank")) return 20002;
            return null;
        }
        pub fn wattsByName(_: *const @This(), name: []const u8) ?f32 {
            if (std.mem.eql(u8, name, "generatorbank")) return 1000;
            if (std.mem.eql(u8, name, "batterybank")) return 50;
            return null;
        }
    };
    var stub: PowerStub = .{};
    try stub.power_class_by_name.put(std.testing.allocator, "generatorbank", "Generator");
    try stub.power_class_by_name.put(std.testing.allocator, "batterybank", "BatteryBank");
    defer stub.power_class_by_name.deinit(std.testing.allocator);
    g.power_registry = ecs.powerblocks.Registry.build(&stub);
    const gen_id: u16 = 20001;
    const cons_id: u16 = 20002;
    _ = g.sim.power.removeAt(8, 70, 8);
    _ = g.sim.power.removeAt(10, 70, 8);
    // Rebuild the plane with the power blocks at fixed cells.
    const ch = try g.world.getOrCreate(.{ .x = 0, .z = 0 });
    const blocks = ch.blocks.?;
    blocks[8 + 8 * 16 + 70 * 256] = gen_id;
    blocks[10 + 8 * 16 + 70 * 256] = cons_id;
    g.scanChunkPower(ch, 0, 0);
    // Presence alone is a weak check: a rebuild that registered every power
    // block as the same node kind, or dropped the watts, would still put a
    // node at both cells. Assert what the scan is actually for - the class and
    // rating each block id resolves to through the registry.
    const gi = g.sim.power.indexOfPosition(8, 70, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ecs.electric.NodeKind.generator, g.sim.power.nodes[gi].kind);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), g.sim.power.nodes[gi].watts, 0.01);

    const ci = g.sim.power.indexOfPosition(10, 70, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ecs.electric.NodeKind.battery, g.sim.power.nodes[ci].kind);

    // A cell with no power block must not gain a node.
    try std.testing.expect(g.sim.power.indexOfPosition(9, 70, 8) == null);
}

test "a latched switch comes back on after a restart, not off" {
    // The grid is runtime state rebuilt from the block plane, and the rebuild
    // ran applyToNode, which latches a switch off because that is right for a
    // freshly placed one. A switch read off disk is not freshly placed: the
    // player's latch is in the block meta the SetBlock path wrote and the ZCH3
    // plane kept. Every restart therefore switched every powered base off
    // while the clients still rendered the switches as on.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const SwitchStub = struct {
        power_class_by_name: std.StringHashMapUnmanaged([]const u8) = .{},
        pub fn idByName(_: *const @This(), name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "switch")) return 20003;
            return null;
        }
        pub fn wattsByName(_: *const @This(), name: []const u8) ?f32 {
            if (std.mem.eql(u8, name, "switch")) return 0;
            return null;
        }
    };
    var stub: SwitchStub = .{};
    try stub.power_class_by_name.put(std.testing.allocator, "switch", "Switch");
    defer stub.power_class_by_name.deinit(std.testing.allocator);
    g.power_registry = ecs.powerblocks.Registry.build(&stub);
    const switch_id: u16 = 20003;

    const ch = try g.world.getOrCreate(.{ .x = 0, .z = 0 });
    const blocks = ch.blocks.?;
    // Two switches off the same plane: one saved latched on, one off. Both
    // must come back the way the meta records them, so a scan that simply
    // forced one value would fail on the other.
    blocks[4 + 4 * 16 + 70 * 256] = packages.withBlockMeta(@as(u32, switch_id), packages.block_meta_on);
    blocks[6 + 4 * 16 + 70 * 256] = packages.withBlockMeta(@as(u32, switch_id), 0);
    g.scanChunkPower(ch, 0, 0);

    const on_i = g.sim.power.indexOfPosition(4, 70, 4) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.power.nodes[on_i].is_switch);
    try std.testing.expect(g.sim.power.nodes[on_i].on);

    const off_i = g.sim.power.indexOfPosition(6, 70, 4) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.power.nodes[off_i].is_switch);
    try std.testing.expect(!g.sim.power.nodes[off_i].on);
}

test "trader POIs spawn their NPC classes on a stock map" {
    const game_dir = stock_paths.dedicated_server;
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/poi_traders", 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Pad trader plus the five trader POIs (Jen/Bob/Hugh/Joel/Rekt), each
    // carrying its own class hash and trader_info stock.
    var n: usize = 0;
    var saw_bob = false;
    var si: ecs.Slot = 0;
    while (si < ecs.max_entities) : (si += 1) {
        if (!g.sim.alive[si] or !g.sim.mask[si].trader) continue;
        n += 1;
        if (g.sim.class_id[si].hash == packages.stock_entity.class_npc_trader_bob) saw_bob = true;
    }
    try std.testing.expect(n >= 6);
    try std.testing.expect(saw_bob);
}

test "POI reset restores baked blocks over player edits" {
    const game_dir = stock_paths.dedicated_server;
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    // Own throwaway world dir: a `.zdtd_cfg_cache/poi_reset` world left by an
    // older run of this test is painted by a previous code generation, so the
    // reset would compare against stale baked blocks (AGENTS: tests never
    // write into the repo).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var g = try Game.createWithOptions(std.testing.allocator, world_dir, 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const pf = if (g.world.prefabs) |*p| p else return error.TestUnexpectedResult;
    // First trader POI with a baked block table.
    var di: ?usize = null;
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (!qd.is_trader_area) continue;
        if (pf.getTtsBlocks(d.name) == null) continue;
        di = i;
        break;
    }
    const idx = di orelse return error.TestUnexpectedResult;
    const d = pf.items[idx];
    // A non-air block near the stamp surface to edit and restore.
    var target: ?[3]i32 = null;
    outer: for (0..@as(usize, @intCast(d.size_x))) |lx| {
        for (0..@as(usize, @intCast(d.size_z))) |lz| {
            const by = d.stampY() + 1;
            const y_hi = @min(by + 10, 255);
            var y: i32 = by;
            while (y <= y_hi) : (y += 1) {
                const bid = g.world.blockWorld(d.x + @as(i32, @intCast(lx)), y, d.z + @as(i32, @intCast(lz))) catch 0;
                if (bid == 0) continue;
                target = .{ d.x + @as(i32, @intCast(lx)), y, d.z + @as(i32, @intCast(lz)) };
                break :outer;
            }
        }
    }
    const t = target orelse return error.TestUnexpectedResult;
    const orig = (try g.world.blockWorld(t[0], t[1], t[2]));
    // Player edit wipes the block; the quest dedication resets it.
    try g.setBlock(t[0], t[1], t[2], 0);
    try std.testing.expectEqual(@as(u16, 0), try g.world.blockWorld(t[0], t[1], t[2]));
    g.resetPoiBlocks(t[0], t[2]);
    try std.testing.expectEqual(orig, try g.world.blockWorld(t[0], t[1], t[2]));

    // The stores keyed by position are not part of the block plane, so a
    // reset that only repaints blocks leaves the previous occupant's tile
    // entity behind: a power node with no block still feeding the grid, a
    // container still holding its slots under whatever the POI bakes there.
    // Clear the block first so the reset actually rewrites this cell, then
    // plant both stores. Planting them before the break would let the break's
    // own spill consume them, and the reset would find nothing to displace.
    try g.setBlock(t[0], t[1], t[2], 0);
    _ = g.sim.power.addNodeAt(.generator, t[0], t[1], t[2], 1000);
    try std.testing.expect(g.sim.power.indexOfPosition(t[0], t[1], t[2]) != null);
    const cpos = containers_mod.PosKey{ .x = t[0], .y = t[1], .z = t[2] };
    const cont = g.containers.getOrCreate(cpos, 8, orig) orelse return error.TestUnexpectedResult;
    cont.slots[0] = .{ .item_id = 7, .count = 5, .quality = 1 };
    try std.testing.expect(g.containers.get(cpos) != null);

    const bags_before = g.sim.countKind(.loot_bag);
    g.resetPoiBlocks(t[0], t[2]);
    try std.testing.expectEqual(orig, try g.world.blockWorld(t[0], t[1], t[2]));
    try std.testing.expect(g.sim.power.indexOfPosition(t[0], t[1], t[2]) == null);
    try std.testing.expect(g.containers.get(cpos) == null);
    // The reset restores the POI to its authored state; it does not mine it
    // out. Spilling the displaced contents would let a player farm a POI by
    // re-taking the quest that resets it.
    try std.testing.expectEqual(bags_before, g.sim.countKind(.loot_bag));
}

test "biome spawn groups resolve per-biome spawning.xml rules on a stock map" {
    const game_dir = stock_paths.dedicated_server;
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/biome_spawn_groups", 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const bm = g.world.biomes orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.world.biome_layers_table.loaded);
    // Scan the map for one wasteland cell (biomemap id 8) and one pine_forest
    // cell (id 3) instead of pinning fragile world coords.
    var wasteland: ?[2]i32 = null;
    var pine: ?[2]i32 = null;
    var wx: i32 = -1600;
    while (wx <= 1600 and (wasteland == null or pine == null)) : (wx += 32) {
        var wz: i32 = -1600;
        while (wz <= 1600) : (wz += 32) {
            const bid = bm.atWorld(wx, wz) orelse continue;
            if (bid == 8 and wasteland == null) wasteland = .{ wx, wz };
            if (bid == 3 and pine == null) pine = .{ wx, wz };
        }
    }
    const w = wasteland orelse return error.TestUnexpectedResult;
    const p = pine orelse return error.TestUnexpectedResult;
    const fx = @as(f32, @floatFromInt(w[0]));
    const fz = @as(f32, @floatFromInt(w[1]));
    // The fn takes a callback-style ctx first (director binding uses the
    // same shape): pass the game as ctx; null would panic on the deref.
    const w_night = Game.biomeGroupName(g, fx, fz, .night, "fallback");
    const w_day = Game.biomeGroupName(g, fx, fz, .day, "fallback");
    const p_night = Game.biomeGroupName(g, @floatFromInt(p[0]), @floatFromInt(p[1]), .night, "fallback");
    try std.testing.expectEqualStrings("ZombiesWastelandNight", w_night);
    try std.testing.expectEqualStrings("ZombiesWasteland", w_day);
    try std.testing.expectEqualStrings("ZombiesNight", p_night);
    // Unknown biome ids / missing biome map fall back instead of guessing.
    try std.testing.expectEqualStrings("fallback", Game.biomeGroupName(g, 99999, 99999, .night, "fallback"));
}

test "per-trader stock and hours come from trader_info + npc.xml" {
    const traders_path = stock_paths.configFile("traders.xml");
    const npc_path = stock_paths.configFile("npc.xml");
    if (!io_fs.fileExists(traders_path)) return error.SkipZigTest;
    const tt = try assets_traders.loadFromPath(std.testing.allocator, traders_path);
    if (!io_fs.fileExists(npc_path)) return error.SkipZigTest;
    const nt = try assets_npc.loadFromPath(std.testing.allocator, npc_path);

    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/trader_info_stock", 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // No config dirs here, so create left the tables empty: own the stock files.
    g.traders.deinit();
    g.traders = tt;
    g.npc.deinit();
    g.npc = nt;

    try std.testing.expectEqual(@as(u16, 6), g.npc.traderIdForClass("npcTraderBob"));
    try std.testing.expectEqual(@as(u16, 2), g.npc.traderIdForClass("Trader Jen"));
    try std.testing.expectEqualStrings("trader_rekt_quests", g.npc.questListForTrader(8).?);

    // Pad trader gets Jen's trader_info (2) and her own list, not traderAlways.
    var jen: ?i32 = null;
    var si: ecs.Slot = 0;
    while (si < ecs.max_entities) : (si += 1) {
        if (g.sim.alive[si] and g.sim.mask[si].trader) {
            g.sim.trader_stock[si].trader_info_id = 2;
            jen = g.sim.network_id[si].id;
            break;
        }
    }
    const jen_id = jen orelse return error.TestUnexpectedResult;
    g.fillTraderFromXml(jen_id);
    const jslot = g.sim.slotOfNetId(jen_id).?;
    // Offline game has the ~12-item builtin table, so at least one of Jen's
    // refs must resolve; the exact count depends on items.xml coverage.
    try std.testing.expect(g.sim.trader_stock[jslot].n >= 1);

    // Joel's trader_info (1) fills a different list: some (item, count)
    // pair among the first entries differs from Jen's.
    const joel_id = g.sim.spawnTrader("npcTraderJoel", 100, 70, 100, 1, 5000).?;
    g.fillTraderFromXml(joel_id);
    const kslot = g.sim.slotOfNetId(joel_id).?;
    const a = &g.sim.trader_stock[jslot];
    const b = &g.sim.trader_stock[kslot];
    try std.testing.expect(a.n >= 1 and b.n >= 1);
    var differs = false;
    const m = @min(a.n, b.n);
    for (a.entries[0..m], b.entries[0..m]) |x, y| {
        if (x.item != y.item or x.count != y.count) differs = true;
    }
    try std.testing.expect(differs);

    // Hours gate: Jen (4:05–21:50) is open at noon, closed at 03:00; a
    // vending trader_info (4) and unknown ids (fixtures) never gate.
    g.sim.director.clock.hours = 12.0;
    try std.testing.expect(g.traderIsOpen(jslot));
    g.sim.director.clock.hours = 3.0;
    try std.testing.expect(!g.traderIsOpen(jslot));
    const vend_id = g.sim.spawnTrader("vending", 110, 70, 110, 4, 5000).?;
    const vslot = g.sim.slotOfNetId(vend_id).?;
    try std.testing.expect(g.traderIsOpen(vslot));
    const unk_id = g.sim.spawnTrader("Trader", 120, 70, 120, 0, 5000).?;
    const uslot = g.sim.slotOfNetId(unk_id).?;
    try std.testing.expect(g.traderIsOpen(uslot));
}

test "biome gamestage and lootstage modifiers apply from biomes.xml" {
    // Stock get_gameStage / GetLootStage scale by the biome under the player
    // (progression.md 5): snow has gamestage_modifier=3 / bonus=30 and
    // lootstage_modifier=1.5 / bonus=15, pine_forest 0/0. The same player in
    // the snow biome must read a higher stage than in the forest.
    const game_dir = stock_paths.dedicated_server;
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/biome_stage_mods", 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const bm = g.world.biomes orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.world.biome_layers_table.loaded);
    // snow biomemap id 1, pine_forest id 3.
    var snow: ?[2]i32 = null;
    var pine: ?[2]i32 = null;
    var wx: i32 = -1600;
    while (wx <= 1600 and (snow == null or pine == null)) : (wx += 32) {
        var wz: i32 = -1600;
        while (wz <= 1600) : (wz += 32) {
            const bid = bm.atWorld(wx, wz) orelse continue;
            if (bid == 1 and snow == null) snow = .{ wx, wz };
            if (bid == 3 and pine == null) pine = .{ wx, wz };
        }
    }
    const s = snow orelse return error.TestUnexpectedResult;
    const p = pine orelse return error.TestUnexpectedResult;
    const snow_mods = g.world.biome_layers_table.biomeMods("snow");
    try std.testing.expectEqual(@as(f32, 3), snow_mods.game_mod);
    try std.testing.expectEqual(@as(f32, 30), snow_mods.game_bonus);
    try std.testing.expectEqual(@as(f32, 1.5), snow_mods.loot_mod);
    try std.testing.expectEqual(@as(f32, 15), snow_mods.loot_bonus);
    const pine_mods = g.world.biome_layers_table.biomeMods("pine_forest");
    try std.testing.expectEqual(@as(f32, 0), pine_mods.game_mod);
    try std.testing.expectEqual(@as(f32, 0), pine_mods.game_bonus);

    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.director.clock.day = 10;
    cl.game_stage_born_world_time = g.sim.director.clock.worldTimeBits() - 5 * assets_gamestages.ticks_per_day;
    cl.level = 10;
    // Move the player into each biome and compare the stages.
    g.sim.transform[ps].x = @floatFromInt(p[0]);
    g.sim.transform[ps].z = @floatFromInt(p[1]);
    const pine_stage = g.gameStageOf(cl.slot);
    const pine_loot = g.lootStageOf(cl.slot);
    g.sim.transform[ps].x = @floatFromInt(s[0]);
    g.sim.transform[ps].z = @floatFromInt(s[1]);
    const snow_stage = g.gameStageOf(cl.slot);
    const snow_loot = g.lootStageOf(cl.slot);
    try std.testing.expect(snow_stage > pine_stage);
    try std.testing.expect(snow_loot > pine_loot);
    // Sanity: forest stage = (level + days) x stock difficultyBonus 1.2 =
    // 15 x 1.2 = 18; forest loot stage = level = 10 (no biome terms).
    try std.testing.expectEqual(@as(i32, 18), pine_stage);
    try std.testing.expectEqual(@as(i32, 10), pine_loot);
    // Snow: (10 x (1 + 3) + 5 + 30) x 1.2 = 90; loot (10 x 2.5 + 15) = 40.
    try std.testing.expectEqual(@as(i32, 90), snow_stage);
    try std.testing.expectEqual(@as(i32, 40), snow_loot);
    std.debug.print("PASS biome-stage-mods: snow {d}/{d} > pine {d}/{d}\n", .{ snow_stage, snow_loot, pine_stage, pine_loot });
}

test "enter bundle ships ChunkClusterInfo before spawn points (infinite world)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    _ = cl;
    const pkg_id = packages.idOf("NetPackageChunkClusterInfo").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var found = false;
    for (cap.slots[0..cap.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id) {
                // Flat world → infinite cluster: (0,0)/(0,0), bInfinite=true,
                // pos (0,0,0), name = world name.
                var rd: wire_binary.Reader = .{ .data = p.body };
                var name_buf: [64]u8 = undefined;
                const name = try rd.readString(&name_buf);
                try std.testing.expectEqualStrings("zdtd", name);
                try std.testing.expectEqual(@as(i32, 0), try rd.readI32());
                try std.testing.expectEqual(@as(i32, 0), try rd.readI32());
                try std.testing.expectEqual(@as(i32, 0), try rd.readI32());
                try std.testing.expectEqual(@as(i32, 0), try rd.readI32());
                try std.testing.expectEqual(true, try rd.readBool());
                found = true;
            }
        }
    }
    try std.testing.expect(found);
}

test "waypoint invites relay to allies (Friends) and all (Everyone)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    var cap_c: ln_peer.Capture = .{};
    const id_a: platform_user.Id = .{ .platform = "Steam", .id = "1001" };
    const id_b: platform_user.Id = .{ .platform = "Steam", .id = "1002" };
    const id_c: platform_user.Id = .{ .platform = "Steam", .id = "1003" };
    const ca = try g.attachJoinedClientAs(&cap_a, id_a);
    const cb = try g.attachJoinedClientAs(&cap_b, id_b);
    const cc = try g.attachJoinedClientAs(&cap_c, id_c);
    _ = cb;
    _ = cc;
    try g.allies.setStatus(id_a, id_b, .allies);

    const pkg_id = packages.idOf("NetPackageWaypoint").?;
    var pkgs: [8]wire_frame.Package = undefined;

    // Friends-mode invite from A: only the ally B receives it.
    var wp: packages.WaypointInvite = .{ .pos = .{ 1, 2, 3 } };
    wp.invite_mode = 0;
    wp.inviter_entity_id = ca.entity_id;
    var body_buf: [512]u8 = undefined;
    const body = try packages.buildWaypointInviteBody(&body_buf, &wp, ca.entity_id);
    var frame_buf: [640]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageWaypoint", body);
    cap_b.clear();
    cap_c.clear();
    try g.injectFramed(ca, framed);

    var b_got = false;
    var c_got = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id) b_got = true;
        }
    }
    for (cap_c.slots[0..cap_c.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id) c_got = true;
        }
    }
    try std.testing.expect(b_got);
    try std.testing.expect(!c_got);

    // Everyone-mode invite from A: the non-ally C receives it too.
    wp.invite_mode = 1;
    const body2 = try packages.buildWaypointInviteBody(&body_buf, &wp, ca.entity_id);
    const framed2 = try packages.framed(&frame_buf, "NetPackageWaypoint", body2);
    cap_c.clear();
    try g.injectFramed(ca, framed2);
    c_got = false;
    for (cap_c.slots[0..cap_c.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id) c_got = true;
        }
    }
    try std.testing.expect(c_got);
}

test "game message relays verbatim to all clients including sender" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    // EntityWasKilled(1) | mainEntityId | secondaryEntityId.
    var body: [9]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeByte(1);
    try w.writeI32(ca.entity_id);
    try w.writeI32(-1);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageGameMessage", &body);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, framed);

    const pkg_id = packages.idOf("NetPackageGameMessage").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var a_got = false;
    var b_got = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id and std.mem.eql(u8, p.body, &body)) a_got = true;
        }
    }
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id and std.mem.eql(u8, p.body, &body)) b_got = true;
        }
    }
    try std.testing.expect(a_got);
    try std.testing.expect(b_got);
}

test "sound at position relays to all clients except the owning player" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    var body: [128]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeF32(10);
    try w.writeF32(20);
    try w.writeF32(30);
    try w.writeString("Sounds/explosions/boom");
    try w.writeByte(0);
    try w.writeI32(30);
    try w.writeI32(ca.entity_id); // the owner (sender) must NOT hear the echo
    var frame_buf: [256]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageSoundAtPosition", w.written());
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, framed);

    const pkg_id = packages.idOf("NetPackageSoundAtPosition").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var a_got = false;
    var b_got = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id) a_got = true;
        }
    }
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pkg_id) b_got = true;
        }
    }
    try std.testing.expect(!a_got);
    try std.testing.expect(b_got);
}

test "entity award kill server is handled without re-crediting kills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);

    // Seed known credit state so a silent re-credit is observable. The C2S
    // report must not bump kills or XP (already credited on the death path).
    ca.zombie_kills = 3;
    ca.player_kills = 1;
    ca.xp = 9001;

    // killerEntityId i32 | killedEntityId i32 (a client kill report; the
    // server already credited the kill at the death path, so the handler
    // validates and drops instead of double-crediting).
    var body: [8]u8 = undefined;
    std.mem.writeInt(i32, body[0..4], ca.entity_id, .little);
    std.mem.writeInt(i32, body[4..8], 200, .little);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityAwardKillServer", &body);
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    try g.injectFramed(ca, framed);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));
    try std.testing.expectEqual(@as(u16, 3), ca.zombie_kills);
    try std.testing.expectEqual(@as(u16, 1), ca.player_kills);
    try std.testing.expectEqual(@as(u64, 9001), ca.xp);
}

test "platform-id ban rejects a rejoin with the same identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const id: platform_user.Id = .{ .platform = "Steam", .id = "76561198000000000" };
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClientAs(&cap, id);
    const now = clock.wallSeconds();
    try std.testing.expect(g.ban_list.addId("Steam", "76561198000000000", "X", now + 3600, "test"));
    var cap2: ln_peer.Capture = .{};
    // Same platform id is rejected at the login gate (identity-ban), even
    // though the harness login name is the generic "Bot".
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClientAs(&cap2, id));
    // Name-keyed bans still gate the name-only path (no platform session).
    try std.testing.expect(g.ban_list.add("Bot", now + 3600, "test"));
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClient(&cap2));
}

test "whitelist gates the join: listed and admins enter, others are denied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const id_a: platform_user.Id = .{ .platform = "Steam", .id = "1001" };
    const id_c: platform_user.Id = .{ .platform = "Steam", .id = "1003" };
    // Whitelist holds A (composite key, serveradmin.xml form) and B by name.
    try std.testing.expect(g.whitelist.add("Steam:1001", 0));
    try std.testing.expect(g.whitelist.add("Bob", 0));

    var cap: ln_peer.Capture = .{};
    // A is whitelisted by composite -> joins.
    _ = try g.attachJoinedClientAs(&cap, id_a);
    // An unlisted identity is denied (NotOnWhitelist).
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClientAs(&cap, id_c));
    // A name-keyed whitelist entry still gates the name-only path.
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClient(&cap));
    // Admins bypass the whitelist (AdminUsers.HasEntry, IL=71).
    try std.testing.expect(g.admin_list.add("Steam:1003", 0));
    _ = try g.attachJoinedClientAs(&cap, id_c);
}

test "name-keyed admin entry does not grant a platform peer who spoofs the name" {
    // Deny side of the permission matrix: a client-supplied display name must
    // not mint admin rights when the peer already presented a platform id
    // (stock AdminUsers.HasEntry keys on PlatformId only, IL=30).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expect(g.admin_list.add("Bot", 0)); // name-keyed owner entry
    const spoof: platform_user.Id = .{ .platform = "Steam", .id = "attacker" };
    var cap: ln_peer.Capture = .{};
    // Harness login name is always "Bot"; with a platform id that must not
    // inherit the name-keyed admin row.
    const c = try g.attachJoinedClientAs(&cap, spoof);
    try std.testing.expectEqual(@as(u16, 1000), g.permLevelOf(c));
    try std.testing.expect(!g.permissionListHit(&g.admin_list, c));
    // No-platform sessions still resolve name-keyed entries (loadgen).
    var cap2: ln_peer.Capture = .{};
    const bot = try g.attachJoinedClient(&cap2);
    try std.testing.expectEqual(@as(u16, 0), g.permLevelOf(bot));
}

test "name-keyed whitelist entry does not admit a platform peer with that name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Whitelist is name-keyed "Bot"; a Steam peer logging in as Bot must not
    // slip through on the display name alone.
    try std.testing.expect(g.whitelist.add("Bot", 0));
    var cap: ln_peer.Capture = .{};
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClientAs(&cap, .{ .platform = "Steam", .id = "spoof" }));
    // No-platform "Bot" still matches the name-keyed row.
    _ = try g.attachJoinedClient(&cap);
}

test "admin add from player console cannot grant a more privileged level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Mid-level admin (5) with `admin` delegated to level 5.
    try std.testing.expect(g.admin_list.add("Bot", 5));
    try std.testing.expect(g.setCommandLevel("admin", 5));
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expectEqual(@as(u16, 5), g.permLevelOf(c));

    cap.clear();
    var body: [64]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeString("admin add Eve 0");
    var fb: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageConsoleCmdServer", w.written()));
    const cid = packages.idOf("NetPackageConsoleCmdClient").?;
    const resp = cap.findPkgId(cid) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, resp, "cannot grant a more privileged level") != null);
    try std.testing.expect(g.admin_list.find("Eve") == null);
}

test "admin target key uses the platform id for an online session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const id: platform_user.Id = .{ .platform = "Steam", .id = "76561198000000000" };
    var key_cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClientAs(&key_cap, id);
    _ = ca;
    // The online target resolves to the platform composite, so a rename
    // cannot lose admin/whitelist standing (stock keys on the identifier).
    var buf: [96]u8 = undefined;
    const key = g.adminTargetKey(.{ .name = "Bot" }, &buf);
    try std.testing.expectEqualStrings("Steam:76561198000000000", key);
    // An offline/unknown target keeps the name key.
    const nk = g.adminTargetKey(.{ .name = "OfflinePlayer" }, &buf);
    try std.testing.expectEqualStrings("OfflinePlayer", nk);
}

test "reserved and admin slots let privileged players join a full server" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .max_players = 2,
        .reserved_slots = 1,
        .reserved_slots_permission = 0,
        .admin_slots = 1,
        .admin_slots_permission = 5,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const norm_a: platform_user.Id = .{ .platform = "Steam", .id = "1001" };
    const norm_b: platform_user.Id = .{ .platform = "Steam", .id = "1002" };
    const norm_c: platform_user.Id = .{ .platform = "Steam", .id = "1003" };
    const adm: platform_user.Id = .{ .platform = "Steam", .id = "1009" };
    var cap: ln_peer.Capture = .{};
    // Two normal players fill the server (max 2).
    _ = try g.attachJoinedClientAs(&cap, norm_a);
    _ = try g.attachJoinedClientAs(&cap, norm_b);
    // A third normal player is denied at the cap (PlayerLimitExceeded).
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClientAs(&cap, norm_c));
    // The admin slot takes a level-1 admin (perm 1 <= admin perms 5) while
    // total < max + admin_slots (2 < 3), using the headroom.
    try std.testing.expect(g.admin_list.add("Steam:1010", 1));
    _ = try g.attachJoinedClientAs(&cap, .{ .platform = "Steam", .id = "1010" });
    // The reserved slot then takes the level-0 admin (privileged 0 < max -
    // reserved = 1); a fourth normal player stays denied at every tier.
    try std.testing.expect(g.admin_list.add("Steam:1009", 0));
    _ = try g.attachJoinedClientAs(&cap, adm);
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClientAs(&cap, .{ .platform = "Steam", .id = "1004" }));
}

test "serveradmin.xml hot-reload replaces the XML-sourced entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const sa_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "serveradmin.xml" });
    defer std.testing.allocator.free(sa_path);
    const xml_v1 =
        \\<adminTools>
        \\  <blacklist>
        \\    <blacklisted platform="Steam" userid="5001" name="A" unbandate="2030-01-01 00:00:00" reason="v1" />
        \\  </blacklist>
        \\</adminTools>
    ;
    try io_fs.writeFile(sa_path, xml_v1);
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .serveradmin_path = sa_path,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    try std.testing.expect(g.ban_list.bannedId("Steam", "5001", 1893427199)); // before 2030-01-01
    // A runtime ban survives the reload.
    try std.testing.expect(g.ban_list.add("Runtime", 1893427200 + 86400, "cmd"));

    // Edit the file: replace the XML ban with another id (and drop an admin).
    const xml_v2 =
        \\<adminTools>
        \\  <blacklist>
        \\    <blacklisted platform="Steam" userid="5002" name="B" unbandate="2030-01-01 00:00:00" reason="v2" />
        \\  </blacklist>
        \\</adminTools>
    ;
    try io_fs.writeFile(sa_path, xml_v2);
    // Offline Game runs under the virtual clock, so sleepNs only advances sim
    // time and cannot move filesystem mtime. Force the poll to see a change
    // instead of depending on host mtime granularity.
    g.serveradmin_mtime = 0;
    g.serveradmin_reload_timer = 0;
    g.tickServerAdminReload();
    try std.testing.expect(!g.ban_list.bannedId("Steam", "5001", 1893427199)); // replaced
    try std.testing.expect(g.ban_list.bannedId("Steam", "5002", 1893427199)); // new
    try std.testing.expect(g.ban_list.banned("Runtime", 1893427199 + 86400)); // untouched
}

test "particle effects relay to all clients except the causing owner; stealth is a no-op" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    // ParticleEffect: owner (sender) must not hear the echo.
    var body: [256]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeI32(7);
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1);
    try w.writeByte(255);
    try w.writeByte(0);
    try w.writeByte(0);
    try w.writeByte(255);
    try w.writeString("Sounds/blood");
    try w.writeString("");
    try w.writeF32(1); // volumeScale
    // ParticleEffect::Write tail, ahead of the package's own fields.
    try w.writeI32(0); // parentEntityId
    try w.writeByte(0); // attachment
    try w.writeI32(ca.entity_id);
    try w.writeBool(true);
    try w.writeBool(false);
    var frame_buf: [512]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageParticleEffect", w.written());
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, framed);
    const pe_id = packages.idOf("NetPackageParticleEffect").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var a_got = false;
    var b_got = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pe_id) a_got = true;
        }
    }
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == pe_id) b_got = true;
        }
    }
    try std.testing.expect(!a_got);
    try std.testing.expect(b_got);

    // EntityStealth: handled without applying the client's claimed stealth
    // bits (server owns crouch/smell). A non-zero data word must not flip
    // crouching or raise unhandled.
    const ps_a = g.sim.playerByPeer(ca.slot) orelse return error.TestUnexpectedResult;
    const crouch_before = g.sim.player[ps_a].crouching;
    var sb: [6]u8 = undefined;
    std.mem.writeInt(i32, sb[0..4], ca.entity_id, .little);
    std.mem.writeInt(u16, sb[4..6], 0xffff, .little);
    var framed2: [128]u8 = undefined;
    const f2 = try packages.framed(&framed2, "NetPackageEntityStealth", &sb);
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    try g.injectFramed(ca, f2);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));
    try std.testing.expectEqual(crouch_before, g.sim.player[ps_a].crouching);
}

test "quest goto/treasure point reports are handled without double-completion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(ca.slot) orelse return error.TestUnexpectedResult;
    // Plant a journal row directly: join may already hold the starter, and
    // catalog ids are not stable enough for a hard-coded accept. The C2S
    // arms must not flip completed / progress / phase on this entry.
    try std.testing.expect(g.sim.mask[ps].journal);
    const slot = g.sim.journal[ps].findFree() orelse return error.TestUnexpectedResult;
    const code: i32 = 4242;
    slot.* = .{
        .def_id = 65000,
        .quest_code = code,
        .active = true,
        .completed = false,
        .ready_turn_in = false,
        .progress = 2,
        .phase = 1,
        .poi = .{},
    };
    const progress_before = slot.progress;
    const phase_before = slot.phase;

    var frame_buf: [256]u8 = undefined;
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    // GotoPoint report (traderId + playerId + questCode + padding).
    var gb: [48]u8 = undefined;
    @memset(&gb, 0);
    std.mem.writeInt(i32, gb[0..4], 1, .little);
    std.mem.writeInt(i32, gb[4..8], ca.entity_id, .little);
    std.mem.writeInt(i32, gb[8..12], code, .little);
    const f1 = try packages.framed(&frame_buf, "NetPackageQuestGotoPoint", &gb);
    try g.injectFramed(ca, f1);
    // TreasurePoint update (action 2): dig telemetry only, no dig-site reply.
    var tb: [48]u8 = undefined;
    @memset(&tb, 0);
    tb[0] = packages.quest_point_update_treasure;
    std.mem.writeInt(i32, tb[1..5], code, .little);
    const f2 = try packages.framed(&frame_buf, "NetPackageQuestTreasurePoint", &tb);
    try g.injectFramed(ca, f2);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));

    try std.testing.expect(slot.active);
    try std.testing.expect(!slot.completed);
    try std.testing.expectEqual(progress_before, slot.progress);
    try std.testing.expectEqual(phase_before, slot.phase);
    try std.testing.expectEqual(code, slot.quest_code);
}

test "entity physics report is handled without touching the sim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(ca.slot) orelse return error.TestUnexpectedResult;
    const x0 = g.sim.transform[ps].x;
    const y0 = g.sim.transform[ps].y;
    const z0 = g.sim.transform[ps].z;

    // Stock 58-byte body with an impossible claimed pose. Applying it would
    // teleport the player; the handler must validate and drop.
    var body: [58]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeU16(0); // Flags
    try w.writeI32(ca.entity_id);
    try w.writeF32(9999); // pos
    try w.writeF32(9999);
    try w.writeF32(9999);
    var i: usize = 0;
    while (i < 10) : (i += 1) try w.writeF32(0); // quat + velocity + angular
    try std.testing.expectEqual(@as(usize, 58), w.written().len);

    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityPhysics", w.written());
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    const malformed_before = g.harness.counters.get(.c2s_malformed);
    try g.injectFramed(ca, framed);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));
    try std.testing.expectEqual(malformed_before, g.harness.counters.get(.c2s_malformed));
    try std.testing.expectEqual(x0, g.sim.transform[ps].x);
    try std.testing.expectEqual(y0, g.sim.transform[ps].y);
    try std.testing.expectEqual(z0, g.sim.transform[ps].z);
}

test "entity ragdoll relays to other clients, not the owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    var body: [64]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeI32(ca.entity_id);
    try w.writeByte(0x01); // flags: duration block
    try w.writeF32(1);
    try w.writeI16(2);
    try w.writeF32(1);
    try w.writeF32(2);
    try w.writeF32(3);
    try w.writeF32(4);
    try w.writeF32(5);
    try w.writeF32(6);
    try w.writeF32(7);
    try w.writeF32(8);
    try w.writeF32(9);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityRagdoll", w.written());
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, framed);
    const rg_id = packages.idOf("NetPackageEntityRagdoll").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var a_got = false;
    var b_got = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == rg_id) a_got = true;
        }
    }
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == rg_id) b_got = true;
        }
    }
    try std.testing.expect(!a_got);
    try std.testing.expect(b_got);
}

test "power wire edges persist and reconnect after a restart (entities.zen)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        const gen = g.sim.power.addNodeAt(.generator, 10, 70, 10, 1000).?;
        const con = g.sim.power.addNodeAt(.consumer, 20, 70, 20, 100).?;
        try std.testing.expect(g.sim.power.connect(gen, con));
        // Game.create's demo world also wires its own grid; ours is present.
        try std.testing.expect(g.sim.power.wire_n >= 1);
        try g.saveEntities();
    }
    {
        // Game.create restores entities.zen automatically: the wire queues as
        // pending (the fresh grid has no nodes yet).
        const g2 = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g2.deinit();
            std.testing.allocator.destroy(g2);
        }
        // The demo world's own grid is present too; our saved edge is among
        // the pending set by its endpoint positions.
        var pending_mine = false;
        for (g2.sim.power.pending_wires[0..g2.sim.power.pending_wire_n]) |wp| {
            const mine = (wp.ax == 10 and wp.ay == 70 and wp.az == 10 and wp.bx == 20 and wp.by == 70 and wp.bz == 20) or
                (wp.ax == 20 and wp.ay == 70 and wp.az == 20 and wp.bx == 10 and wp.by == 70 and wp.bz == 10);
            if (mine) pending_mine = true;
        }
        try std.testing.expect(pending_mine);
        // The nodes rebuild from the block grid (scanChunkPower); replay the
        // same positions and reconnect - the edge is restored.
        const gen2 = g2.sim.power.addNodeAt(.generator, 10, 70, 10, 1000).?;
        _ = g2.sim.power.addNodeAt(.consumer, 20, 70, 20, 100).?;
        g2.sim.power.reconnectPending();
        try std.testing.expectEqual(@as(usize, 0), g2.sim.power.pending_wire_n);
        try std.testing.expect(g2.sim.power.wire_n >= 1);
        var wired = false;
        for (g2.sim.power.wires[0..g2.sim.power.wire_n]) |wd| {
            if (wd.a == gen2 or wd.b == gen2) wired = true;
        }
        try std.testing.expect(wired);
    }
}

test "in-game console runs admin verbs for admins, denies players" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const adm: platform_user.Id = .{ .platform = "Steam", .id = "7001" };
    try std.testing.expect(g.admin_list.add("Steam:7001", 0));
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClientAs(&cap_a, adm);
    const cb = try g.attachJoinedClient(&cap_b);

    // Admin runs a mutating verb: the admin dispatcher replies (gettime here,
    // an admin-accessible read; the reply proves the routing works).
    var body: [128]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeString("gettime");
    var frame_buf: [256]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageConsoleCmdServer", w.written());
    cap_a.clear();
    try g.injectFramed(ca, framed);
    const cc_id = packages.idOf("NetPackageConsoleCmdClient").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var got_reply = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == cc_id) got_reply = true;
        }
    }
    try std.testing.expect(got_reply);

    // A player (not in the admin list) still gets the deny.
    var body2: [128]u8 = undefined;
    var w2: wire_binary.Writer = .{ .buf = &body2 };
    try w2.writeString("settime 12");
    const framed2 = try packages.framed(&frame_buf, "NetPackageConsoleCmdServer", w2.written());
    cap_b.clear();
    try g.injectFramed(cb, framed2);
    var denied = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == cc_id and std.mem.find(u8, p.body, "permission denied") != null) denied = true;
        }
    }
    try std.testing.expect(denied);
}

test "quest objective events mirror to party members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    try std.testing.expect(g.parties.acceptInvite(ca.entity_id, cb.entity_id) != null);

    // Stock re-broadcasts only case 0 (treasure_radius_break) and case 2
    // (block_activated) to the party; case 1 (treasure_complete) is
    // server-local (NetPackageQuestObjectiveUpdate.ProcessPackage IL=180
    // calls FinishTreasureQuest and does not fan out).
    const ou_id = packages.idOf("NetPackageQuestObjectiveUpdate").?;
    var frame_buf: [128]u8 = undefined;
    var pkgs: [8]wire_frame.Package = undefined;

    // block_activated: mirrored to the party member B.
    var body: [64]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeI32(ca.entity_id);
    try w.writeI32(42);
    try w.writeByte(2); // BlockActivated
    try w.writeI32(10);
    try w.writeI32(70);
    try w.writeI32(20);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageQuestObjectiveUpdate", w.written()));
    var b_got = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == ou_id) b_got = true;
        }
    }
    try std.testing.expect(b_got);

    // treasure_complete: server-local, so B gets no QuestObjectiveUpdate.
    var body2: [64]u8 = undefined;
    var w2: wire_binary.Writer = .{ .buf = &body2 };
    try w2.writeI32(ca.entity_id);
    try w2.writeI32(42);
    try w2.writeByte(1); // TreasureComplete
    try w2.writeI32(10);
    try w2.writeI32(70);
    try w2.writeI32(20);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageQuestObjectiveUpdate", w2.written()));
    var leaked = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == ou_id) leaked = true;
        }
    }
    try std.testing.expect(!leaked);

    // treasure_radius_break: the relay is rebuilt with blockPos zeroed, the
    // way stock's 3-arg Setup does (case 2 above keeps the raw position).
    var body3: [64]u8 = undefined;
    var w3: wire_binary.Writer = .{ .buf = &body3 };
    try w3.writeI32(ca.entity_id);
    try w3.writeI32(42);
    try w3.writeByte(0); // TreasureRadiusBreak
    try w3.writeI32(10);
    try w3.writeI32(70);
    try w3.writeI32(20);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageQuestObjectiveUpdate", w3.written()));
    const rq = cap_b.findPkgId(ou_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), rq[8]); // eventType
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, rq[9..13], .little)); // blockPos x zeroed
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, rq[13..17], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, rq[17..21], .little));
}

test "poi lockout reports bedroll and land claim homes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var lock_cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&lock_cap);
    _ = ca;
    // The home-lockout hook reports the bedroll / land-claim bits that
    // questCheckPoiLockout maps to LockReason.bedroll / .land_claim.
    g.clients[0].has_bed = true;
    g.clients[0].bed_x = 250;
    g.clients[0].bed_y = 70;
    g.clients[0].bed_z = 250;
    var bits = game_hooks.homeLockout(g, g.clients[0].entity_id, 250, 250);
    try std.testing.expect((bits & 1) != 0);
    // Move the bed away; a land claim at the POI center reports bit 2.
    g.clients[0].bed_x = 10;
    g.clients[0].bed_z = 10;
    g.registerClaim(250, 70, 250, g.clients[0].entity_id);
    bits = game_hooks.homeLockout(g, g.clients[0].entity_id, 250, 250);
    try std.testing.expect((bits & 2) != 0);
    // With neither home present, no bits fire.
    g.removeClaimAt(250, 70, 250);
    g.clients[0].has_bed = false;
    bits = game_hooks.homeLockout(g, g.clients[0].entity_id, 250, 250);
    try std.testing.expectEqual(@as(u8, 0), bits);
}

test "breaking a bedroll clears the owner respawn point" {
    // Stock PersistentPlayerList.SpawnPointRemoved: removing the placed
    // bedroll block drops has_bed so the player respawns at the default.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const bed_id = g.maxdamage.idByName("bedroll") orelse return error.SkipZigTest;
    g.clients[0].has_bed = true;
    g.clients[0].bed_x = 100;
    g.clients[0].bed_y = 70;
    g.clients[0].bed_z = 200;
    // The bedroll block at the bed position is removed: respawn clears.
    g.noteBlockRemoved(100, 70, 200, bed_id);
    try std.testing.expect(!g.clients[0].has_bed);
    // A different block / position leaves an unrelated bed alone.
    g.clients[0].has_bed = true;
    g.clients[0].bed_x = 101;
    g.noteBlockRemoved(100, 70, 200, bed_id);
    try std.testing.expect(g.clients[0].has_bed);
    g.noteBlockRemoved(101, 70, 200, bed_id);
    try std.testing.expect(!g.clients[0].has_bed);
    // A non-bedroll removal never touches the respawn.
    g.clients[0].has_bed = true;
    g.noteBlockRemoved(101, 70, 200, 42);
    try std.testing.expect(g.clients[0].has_bed);
    std.debug.print("PASS bedroll-break: removal clears the owner respawn point\n", .{});
}

test "active quest stage modifiers scale the player gamestage" {
    // Stock get_gameStage adds the active quest's QuestClass gamestage_mod /
    // gamestage_bonus onto the stage (progression.md 5): an infested clear
    // (mod .6, bonus 30) pushes the player's stage up while active.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const phases = [_]ecs.quest.PhaseSpec{.{ .kind = .kill_zombies, .required = 3 }};
    const defs = [_]ecs.quest.QuestDef{
        .{
            .id = 69,
            .kind = .kill_zombies,
            .name = "plain_clear",
            .title = "Plain",
            .target_count = 3,
            .phases = &phases,
            .highest_phase = 1,
            .objective_phases = &[_]u8{1},
        },
        .{
            .id = 70,
            .kind = .kill_zombies,
            .name = "infested_clear",
            .title = "Infested",
            .target_count = 3,
            .gamestage_mod = 0.6,
            .gamestage_bonus = 30,
            .phases = &phases,
            .highest_phase = 1,
            .objective_phases = &[_]u8{1},
        },
    };
    g.sim.catalog = .{ .defs = &defs, .starter_id = 69, .source = .builtin };
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    g.sim.director.clock.day = 10;
    cl.level = 10;
    cl.game_stage_born_world_time = g.sim.director.clock.worldTimeBits() - 5 * assets_gamestages.ticks_per_day;
    // No active quest: plain (level + days) stage.
    try std.testing.expectEqual(@as(i32, 15), g.gameStageOf(cl.slot));
    try std.testing.expect(systems.questAccept(&g.sim, cl.slot, 70));
    // With the infested quest active: (10 * (1 + 0.6) + 5 + 30) = 51.
    try std.testing.expectEqual(@as(i32, 51), g.gameStageOf(cl.slot));
}

test "POI difficulty tier scales the loot stage (POITierMod/Bonus)" {
    // GetLootStage applies loot_settings POITierMod/Bonus indexed by the
    // DifficultyTier-1 of the POI the player stands in. A tier-2 POI (mod
    // 0.1, bonus 6) pushes a level-10 player's loot stage to 10*(1.1)+6 = 17.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const mods = [_]f32{ 0.05, 0.1, 0.15, 0.2, 0.25 };
    const bonus = [_]f32{ 3, 6, 9, 12, 15 };
    g.loot.poi_tier_mod = &mods;
    g.loot.poi_tier_bonus = &bonus;
    const Tier = struct {
        fn tier(_: ?*anyopaque, _: f32, _: f32) u8 {
            return 2;
        }
    };
    g.sim.poi_tier_ctx = null;
    g.sim.poi_tier_fn = &Tier.tier;
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    cl.level = 10;
    // No POI tier hook -> 10; with the tier-2 stub -> 10*(1+0.1)+6 = 17.
    g.sim.poi_tier_fn = null;
    try std.testing.expectEqual(@as(i32, 10), g.lootStageOf(cl.slot));
    g.sim.poi_tier_fn = &Tier.tier;
    try std.testing.expectEqual(@as(i32, 17), g.lootStageOf(cl.slot));
}

test "quest reward stage scales by quest tier (GetTraderStage)" {
    // Stock GetRewardItem rolls quest rewards with gameStage =
    // GetTraderStage(tier) = Level*(1+quest_tier_mod[tier-1]) (RE
    // progression.md GetTraderStage IL=46): level 10 at tier 3 with the
    // stock root quest_tier_mod="0,0.05,0.1,..." -> 10*(1.1) = 11.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const mods = [_]f32{ 0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3 };
    g.traders.quest_tier_mod = &mods;
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    cl.level = 10;
    const def = ecs.quest.QuestDef{ .id = 1, .kind = .kill_zombies, .name = "r", .title = "R", .difficulty_tier = 3 };
    try std.testing.expectEqual(@as(i32, 11), g.questRewardStage(def, cl.slot));
    // Tier 6 clamps to mods[5]=0.25: 10*(1.25) = 12.5 -> 12.
    var def6 = def;
    def6.difficulty_tier = 6;
    try std.testing.expectEqual(@as(i32, 12), g.questRewardStage(def6, cl.slot));
    // No tier -> the party loot stage fallback (level = 10).
    var def0 = def;
    def0.difficulty_tier = 0;
    try std.testing.expectEqual(@as(i32, 10), g.questRewardStage(def0, cl.slot));
}

test "on_perk_spend verdict denies and scales through the C2S spend handler" {
    // ADR 0033: the on_perk_spend verdict rides the spend request on top of
    // the catalog validation - <0 denies (no SP spent, no echo), >0 scales
    // the skill-point cost by percent. The stat deltas stay native.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const attrs = [_]assets_progression.AttrDef{
        .{ .name = "attGeneral", .max_level = 10, .base_cost = 1, .cost_mult = 1.14 },
    };
    const perks = [_]assets_progression.PerkDef{
        .{ .name = "perkLightEater", .max_level = 5 },
        .{ .name = "perkForbidden", .max_level = 5 },
    };
    g.progression_table.attributes = &attrs;
    g.progression_table.perks = &perks;
    g.progression.skill_points_per_level = 1;

    // A verdict gate: deny perkForbidden, double the cost of everything else.
    const gate = plugin_api.PluginVTable{
        .name = "perkgate",
        .on_perk_spend = struct {
            fn f(_: *const plugin_api.Host, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
                _ = player;
                _ = level;
                _ = cost;
                if (std.mem.eql(u8, skill, "perkForbidden")) return -1;
                if (std.mem.eql(u8, skill, "perkLightEater")) return 200;
                return 0;
            }
        }.f,
    };
    try std.testing.expect(g.plugins.register(&gate));
    g.plugins.enableAll();

    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    cl.skill_points = 10;
    try std.testing.expectEqual(@as(u16, 1), cl.level);

    const body_of = struct {
        // Inherited NetPackageEntitySetSkillLevelClient body: the entity id
        // leads, ahead of the skill name and level.
        fn build(entity_id: i32, skill: []const u8, level: i32) [64]u8 {
            var b: [64]u8 = undefined;
            var w = wire_binary.Writer{ .buf = &b };
            w.writeI32(entity_id) catch {};
            w.writeString(skill) catch {};
            w.writeI32(level) catch {};
            return b;
        }
    };

    // Denied: the purchase is refused, no SP spent, no level granted.
    var body = body_of.build(cl.entity_id, "perkForbidden", 1);
    _ = try c2s_misc.handle(g, cl, cl.peer.?, "NetPackageEntitySetSkillLevelServer", body[0..]);
    try std.testing.expectEqual(@as(u8, 0), g.skillLevelOf(cl.slot, "perkForbidden"));
    try std.testing.expectEqual(@as(u32, 10), cl.skill_points);

    // Scaled 200%: catalog cost 1 becomes 2, spent from the balance.
    body = body_of.build(cl.entity_id, "perkLightEater", 1);
    _ = try c2s_misc.handle(g, cl, cl.peer.?, "NetPackageEntitySetSkillLevelServer", body[0..]);
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(cl.slot, "perkLightEater"));
    try std.testing.expectEqual(@as(u32, 8), cl.skill_points);

    // The native dispatch helper agrees.
    try std.testing.expectEqual(@as(i32, -1), g.perkSpendVerdict(cl.entity_id, "perkForbidden", 1, 1));
    try std.testing.expectEqual(@as(i32, 200), g.perkSpendVerdict(cl.entity_id, "perkLightEater", 1, 1));
    try std.testing.expectEqual(@as(i32, 0), g.perkSpendVerdict(cl.entity_id, "otherPerk", 1, 1));
    g.plugins.shutdown();
    std.debug.print("PASS perk-spend verdict: deny + 200% scale through the C2S handler\n", .{});
}

test "GameEventRequest: IL=211 party gate + on_game_event verdict through the C2S handler" {
    // ADR 0035: stock ProcessPackage IL=211 sender/party validation, then
    // the on_game_event verdict (plugin-owned execution policy) - <0 denies
    // the event (no response), 0 keeps the stock APPROVED ack. The
    // gameevents.xml phase-machine engine stays plugin territory.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    const gate = plugin_api.PluginVTable{
        .name = "gameeventgate",
        .on_game_event = struct {
            fn f(_: *const plugin_api.Host, player: i32, event: []const u8, target: i32, var_count: i32) i32 {
                _ = player;
                _ = target;
                _ = var_count;
                if (std.mem.eql(u8, event, "denied_event")) return -1;
                return 0;
            }
        }.f,
    };
    try std.testing.expect(g.plugins.register(&gate));
    g.plugins.enableAll();

    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    const cb = try g.attachJoinedClient(&cap);
    const resp_id = packages.idOf("NetPackageGameEventResponse").?;

    const req_of = struct {
        fn build(event: []const u8, target: i32) [160]u8 {
            var b: [160]u8 = undefined;
            var w = wire_binary.Writer{ .buf = &b };
            w.writeString(event) catch {};
            w.writeI32(target) catch {}; // entityID
            w.writeString("") catch {}; // extraData
            w.writeString("") catch {}; // tag
            w.writeBool(false) catch {}; // isTwitchEvent
            w.writeBool(false) catch {}; // crateShare
            w.writeBool(false) catch {}; // allowRefunds
            w.writeString("") catch {}; // sequenceLink
            w.writeByte(0) catch {}; // variables count
            return b;
        }
    };

    // Another player not in the party: silently dropped, no response.
    var body = req_of.build("cross_event", cb.entity_id);
    cap.clear();
    _ = try c2s_misc.handle(g, ca, ca.peer.?, "NetPackageGameEventRequest", body[0..]);
    try std.testing.expect(cap.findPkgId(resp_id) == null);

    // Party target: allowed by the IL=211 gate, APPROVED ack sent.
    try std.testing.expect(g.parties.acceptInvite(ca.entity_id, cb.entity_id) != null);
    body = req_of.build("party_event", cb.entity_id);
    cap.clear();
    _ = try c2s_misc.handle(g, ca, ca.peer.?, "NetPackageGameEventRequest", body[0..]);
    try std.testing.expect(cap.findPkgId(resp_id) != null);

    // Non-player target (unknown id): stock gates only on EntityPlayer
    // targets, so the ack still fires.
    body = req_of.build("entity_event", 7777);
    cap.clear();
    _ = try c2s_misc.handle(g, ca, ca.peer.?, "NetPackageGameEventRequest", body[0..]);
    try std.testing.expect(cap.findPkgId(resp_id) != null);

    // Plugin deny: no response even for the sender's own target.
    body = req_of.build("denied_event", ca.entity_id);
    cap.clear();
    _ = try c2s_misc.handle(g, ca, ca.peer.?, "NetPackageGameEventRequest", body[0..]);
    try std.testing.expect(cap.findPkgId(resp_id) == null);

    g.plugins.shutdown();
    std.debug.print("PASS GameEventRequest: IL=211 party gate + on_game_event verdict\n", .{});
}

// Test capture (module scope: the nested vtable fn cannot close over locals).
var stat_obs_calls: usize = 0;

test "on_stat_changed observer fires from the survival pass" {
    // ADR 0034: the stat-changed observer is a pure observer - the sim stays
    // authority. A food-depleted player triggers one call per tick.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    stat_obs_calls = 0;
    const obs = plugin_api.PluginVTable{
        .name = "statobs",
        .on_stat_changed = struct {
            fn f(_: *const plugin_api.Host, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
                _ = player;
                _ = hp;
                _ = food;
                _ = water;
                _ = stamina;
                _ = level;
                _ = xp;
                stat_obs_calls += 1;
            }
        }.f,
    };
    try std.testing.expect(g.plugins.register(&obs));
    g.plugins.enableAll();
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    // Deplete food so the survival pass changes it; a few ticks must fire.
    g.sim.health[ps].food = 1;
    var i: usize = 0;
    while (i < 10) : (i += 1) try g.step();
    try std.testing.expect(stat_obs_calls >= 5); // food keeps dropping each tick
    g.plugins.shutdown();
}

test "restored buffs re-apply through the effects VM (recompute-from-set)" {
    // ZPV3 carries active buffs; the passive-effects VM folds the active set
    // every survival tick, so a restored buff's tracked deltas apply with no
    // re-application pass - the revertible recompute shape pays for the
    // restart for free.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const defs = [_]assets_buffs.BuffDef{
        .{
            .name = "testRegen",
            .passives = &.{.{ .name = "HealthChangeOT", .op = .base_add, .value = 2 }},
        },
    };
    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        g.buffs = assets_buffs.Table{ .defs = &defs };
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        const set = g.sim.buffsMut(ps);
        _ = ecs_buff.add(set, .{
            .def_id = 0,
            .duration = 0,
            .stack_type = ecs_buff.StackType.ignore,
            .update_rate_ticks = 20,
            .remove_on_death = true,
        }, ecs_buff.duration_from_class, -1, 0, 0, 0);
        try g.savePlayers();
    }
    {
        const g = try Game.create(std.testing.allocator, world_dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        g.buffs = assets_buffs.Table{ .defs = &defs };
        var capture: ln_peer.Capture = .{};
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        // The restored buff folds through the VM without any re-apply pass.
        var req_counts: requirements.Counts = .{};
        const totals = assets_buffs.effectTotals(&g.buffs, &g.sim.buffs[ps], .{}, &req_counts);
        try std.testing.expectApproxEqAbs(@as(f32, 2), totals.hp_ot, 0.0001);
    }
}

test "EntityTagCompare resolves the player-only burning rows from stock buffs.xml" {
    // buffBurningFlamingArrow ships both halves of the pair: the player half is
    // `passive_effect HealthChangeOT base_subtract 4,12.3,15` gated
    // `EntityTagCompare tags="player"`, and a non-player half gated by the `!`
    // twin. Before the gate kind existed both were refused (fail closed, counted
    // in requirement_unsupported), so this buff dealt no health damage at all.
    // The entity class `Tags` (entityclasses.xml, inherited through `extends`)
    // now decide it and the tick feeds them through Ctx.entity_tags.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const def_id = g.buffs.indexOfName("buffBurningFlamingArrow") orelse return error.SkipZigTest;
    const def = g.buffs.byId(def_id).?;
    // Data level: the player tag set folds the row (duration 0 is the curve's
    // first anchor, value 4), the zombie set folds the `!` twin (same value),
    // and a caller with no tag set refuses instead of assuming one.
    var pc: requirements.Counts = .{};
    const player = assets_buffs.trackedDeltas(&def, 0, .{ .entity_tags = "entity,player,human" }, &pc);
    try std.testing.expectApproxEqAbs(@as(f32, -4), player.hp_ot, 0.001);
    try std.testing.expectEqual(@as(u32, 0), pc.unsupported);
    var zc: requirements.Counts = .{};
    const zomb = assets_buffs.trackedDeltas(&def, 0, .{ .entity_tags = "entity,zombie,walker" }, &zc);
    try std.testing.expectApproxEqAbs(@as(f32, -4), zomb.hp_ot, 0.001);
    try std.testing.expectEqual(@as(u32, 0), zc.unsupported);
    var nc: requirements.Counts = .{};
    const none = assets_buffs.trackedDeltas(&def, 0, .{}, &nc);
    try std.testing.expectEqual(@as(f32, 0), none.hp_ot);
    try std.testing.expect(nc.unsupported > 0);
    // The loader keeps the class Tags the gate reads.
    const pdef = g.entities.byHash(packages.stock_entity.class_player_male) orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.find(u8, pdef.tags, "player") != null);
    // Tick level: the live player's class Tags reach the VM, so the burning row
    // lands and the player loses health on the survival pass.
    g.sim.health[ps].hp = 90;
    g.sim.health[ps].max_hp = 100;
    g.sim.health[ps].base_max_hp = 100;
    g.sim.health[ps].food = 100;
    g.sim.health[ps].water = 100;
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = def_id,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    const before = g.sim.health[ps].hp;
    try g.step();
    try std.testing.expect(g.sim.health[ps].hp < before);
}

test "equipped item passives fold into the survival VM (stock data)" {
    // Stock `EffectManager.GetValue` layers 7/8 fold the holding item and the
    // equipment items alongside buffs and perks. Asserting on stock items.xml:
    // armorAthleticOutfit HealthMax "2,4,6,8,10,20" (Q6 = +20) and
    // armorEnforcerOutfit's flat GeneralDamageResist 0.05. Before this the item
    // rows were parsed for the resist curves only, so armor gave no max stats.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].max_hp, 0.001);
    const slotOfItem = struct {
        fn f(g_: *Game, ps_: ecs.Slot, id: u16) u16 {
            for (g_.sim.inventory[ps_].slots, 0..) |s, i| {
                if (s.item_id == id) return @intCast(i);
            }
            return 0;
        }
    }.f;
    const outfit = g.items.byName("armorAthleticOutfit") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, outfit.id, 1));
    var from = slotOfItem(g, ps, outfit.id);
    g.sim.inventory[ps].slots[from].quality = 6;
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 0));
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 120), g.sim.health[ps].max_hp, 0.001);
    // Revertible: moving the piece out of the slot restores the base max on the
    // next recompute (no inverse bookkeeping).
    var free: u16 = 0;
    for (g.sim.inventory[ps].slots[0..ecs.components.inv_equip_start], 0..) |s, i| {
        if (s.count == 0) {
            free = @intCast(i);
            break;
        }
    }
    try std.testing.expect(ecs.inventory.move(&g.sim, cl.slot, ecs.components.inv_equip_start, free, 1));
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].max_hp, 0.001);
    // A second piece's flat GeneralDamageResist reaches the damage cache. Its
    // row is gated `ProgressionLevel perkEnforcerApparel Equals 1`, so the item
    // fold also proves item gates evaluate against the player's ledger.
    const enforcer = g.items.byName("armorEnforcerOutfit") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, enforcer.id, 1));
    from = slotOfItem(g, ps, enforcer.id);
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 1));
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.sim.buff_general_resist[ps], 0.0001);
    cl.skill_levels[0] = .{ .name = "perkEnforcerApparel", .level = 1 };
    cl.skill_level_n = 1;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), g.sim.buff_general_resist[ps], 0.0001);
}

test "rogue armor quiets stealth noise while crouching (NoiseMultiplier)" {
    // Stock `PlayerStealth.CalcVolume`/`NotifyNoise` multiply the volume by
    // `GetValue(88 NoiseMultiplier)`. armorRogueOutfit carries Q6 -.2 gated
    // `CVarCompare _crouching`, which the server mirrors from the move flags;
    // perkFromTheShadows level 5 folds -.5 untagged. The survival tick caches
    // the product for the stealth legs.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.sim.stealth_noise_mult[ps], 0.0001);
    const rogue = g.items.byName("armorRogueOutfit") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, rogue.id, 1));
    var from: u16 = 0;
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == rogue.id) {
            from = @intCast(i);
            break;
        }
    }
    g.sim.inventory[ps].slots[from].quality = 6;
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 0));
    // Standing: the _crouching gate refuses, the fold stays neutral.
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.sim.stealth_noise_mult[ps], 0.0001);
    // Crouched: the gate passes and Q6 -.2 joins (1 x 0.8).
    _ = cl.cvars.apply("_crouching", .set, 1);
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), g.sim.stealth_noise_mult[ps], 0.0001);
    // Plus perkFromTheShadows 5 (-.5): 0.8 x 0.5.
    cl.skill_levels[0] = .{ .name = "perkFromTheShadows", .level = 5 };
    cl.skill_level_n = 1;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), g.sim.stealth_noise_mult[ps], 0.0001);
    // Revertible: standing again drops both crouch-gated rows (the perk's
    // whole effect_group requires _crouching too).
    _ = cl.cvars.apply("_crouching", .set, 0);
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.sim.stealth_noise_mult[ps], 0.0001);
}

test "rogue armor dims stealth light in the dark (LightMultiplier)" {
    // Stock `PlayerStealth.TickServer` blends GetValue(89 LightMultiplier)
    // into lightLevel as (0.32 + 0.68 x p). armorRogueOutfit carries Q6 -.3
    // gated `_lightlevel` LTE 65; the broadcast mirrors the pre-blend light
    // x100 into that cvar (IL_00B9), and perkNightStalkerSilentNight folds an
    // ungated -.05. The survival tick caches the product for the sight legs.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    // Pin the Rules knob to neutral so the test asserts the pure VM fold
    // (the column otherwise scales by the 0.89 operator default).
    g.sim.rules.ai.stealth_light_passive = 1.0;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.sim.stealth_light_mult[ps], 0.0001);
    const rogue = g.items.byName("armorRogueOutfit") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, rogue.id, 1));
    var from: u16 = 0;
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == rogue.id) {
            from = @intCast(i);
            break;
        }
    }
    g.sim.inventory[ps].slots[from].quality = 6;
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 0));
    // Dark (ambient 0, no held light): the pre-blend mirror reads 0, the LTE
    // 65 gate passes, Q6 -.3 joins. The whole effect_group also requires
    // _crouching, so crouch first (pre-blend stays 0 in the dark).
    _ = cl.cvars.apply("_crouching", .set, 1);
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get("_lightlevel"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), g.sim.stealth_light_mult[ps], 0.0001);
    // Plus perkNightStalkerSilentNight (-.05, night-gated): 0.7 x 0.95.
    // Midnight forces IsNight.
    g.sim.director.clock.hours = 0;
    cl.skill_levels[0] = .{ .name = "perkNightStalkerSilentNight", .level = 1 };
    cl.skill_level_n = 1;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.665), g.sim.stealth_light_mult[ps], 0.0001);
    // Revertible: taking the armor off restores the perk-only leg.
    try std.testing.expect(ecs.inventory.move(&g.sim, cl.slot, ecs.components.inv_equip_start, from, 1));
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), g.sim.stealth_light_mult[ps], 0.0001);
    // Bright: a directly-applied 100 refuses the LTE 65 armor gate while the
    // night-gated (still night) perk row keeps folding.
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 0));
    _ = cl.cvars.apply("_lightlevel", .set, 100);
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), g.sim.stealth_light_mult[ps], 0.0001);
    // The broadcast mirrors the live pre-blend light x100 into `_lightlevel`
    // (IL_00B9); at this midnight ambient it overwrites the 100 above with
    // the dark value, which re-opens the armor gate. The mirror lags one
    // broadcast (16 ticks); the re check uses a loose band since the ambient
    // drifts slightly across the lag window.
    try stepTicks(g, 20);
    const expect_mirror = systems.stealthLightPreBlend(g.sim.ambient_light, g.sim.heldLightFor(ps), g.sim.player[ps].crouching) * 100.0;
    try std.testing.expectApproxEqAbs(expect_mirror, cl.cvars.get("_lightlevel"), 2.0);
}

test "rogue helmet raises loot stage (LootStage passive 159)" {
    // Stock `EntityPlayer.GetLootStage` multiplies the floored total by
    // GetValue(159 LootStage) (IL_00E1). armorRogueHelmet carries an ungated
    // tiered row (Q6 +.2); perkLuckyLooter level 5 folds +.25 on top.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    cl.level = 10;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.sim.loot_stage_mult[ps], 0.0001);
    try std.testing.expectEqual(@as(i32, 10), g.lootStageOf(cl.slot));
    const helm = g.items.byName("armorRogueHelmet") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, helm.id, 1));
    var from: u16 = 0;
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == helm.id) {
            from = @intCast(i);
            break;
        }
    }
    g.sim.inventory[ps].slots[from].quality = 6;
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 0));
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), g.sim.loot_stage_mult[ps], 0.0001);
    try std.testing.expectEqual(@as(i32, 12), g.lootStageOf(cl.slot));
    // Plus perkLuckyLooter 5 (+.25): 1.2 x 1.25 = 1.5, floor(10) x 1.5 = 15.
    cl.skill_levels[0] = .{ .name = "perkLuckyLooter", .level = 5 };
    cl.skill_level_n = 1;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), g.sim.loot_stage_mult[ps], 0.0001);
    try std.testing.expectEqual(@as(i32, 15), g.lootStageOf(cl.slot));
}

test "PainTolerance resists stun buffs (BuffResistance passive 197)" {
    // Stock `EntityBuffs::HasImmunity` rolls GetValue(197) over the incoming
    // buff's NameTag: perkPainTolerance 5 resists
    // buffInjuryStunned01/02 at 1.0 (always refuses). Level 0 takes it.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInjuryStunned01", cl.entity_id));
    // Drop it so the later adds re-roll instead of stacking.
    const stun_id = g.buffs.indexOfName("buffInjuryStunned01").?;
    _ = ecs_buff.remove(&g.sim.buffs[ps], stun_id);
    try std.testing.expect(g.addProgressionLevel(cl.slot, "perkPainTolerance", 5));
    // Resist 1.0: draw < 1.0 always, refused every time (10/10).
    var refused: u8 = 0;
    var k: u8 = 0;
    while (k < 10) : (k += 1) {
        if (!g.addCatalogBuff(cl.entity_id + k, ps, "buffInjuryStunned01", cl.entity_id)) refused += 1;
    }
    try std.testing.expectEqual(@as(u8, 10), refused);
}

test "NightStalker steal heals on hit (HealthSteal passive 167)" {
    // Stock `ProcessDamageResponse` heals the attacker by damage x
    // GetValue(167): perkNightStalkerComplete carries HealthSteal +.5 behind
    // night + crouch + sleeping-victim gates. The fold path is exercised
    // here at unit level (the C2S leg calls the same fold): with the book
    // owned the fold is nonzero only when the gates could pass, and zero
    // without it.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.healthGainLossMult(cl.slot, "HealthSteal"), 0.0001);
    try std.testing.expect(g.addProgressionLevel(cl.slot, "perkNightStalkerComplete", 1));
    // Night-gated: day keeps it at 0 even with the book owned.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.healthGainLossMult(cl.slot, "HealthSteal"), 0.0001);
}

test "held torch burn proc lands on the victim" {
    // Held-item `onSelfAttackedOther` rows: the torch's Fire Proc group adds
    // buffBurningElement to the victim on a hit (RandomRoll ≤ 30 per hit +
    // `_underwater` gate; `_underwater` unset reads 0 → passes). Sweep hits
    // like the Dentist test; the victim sink applies the target=other add.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const torch = g.items.byName("meleeToolTorch") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, torch.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == torch.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = torch.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    try std.testing.expect(torch.triggered.len > 0);
    const burn_id = g.buffs.indexOfName("buffBurningElement").?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    var landed = false;
    var k: u32 = 0;
    while (k < 4000 and !landed) : (k += 1) {
        g.tick_n += 1;
        g.fireAttackedOther(ps, zs, 0);
        if (g.sim.buffs[zs].find(burn_id) != null) landed = true;
    }
    try std.testing.expect(landed);
}

test "Boomstick stun lands on the victim (target=other AddBuff)" {
    // `onSelfAttackedOther` AddBuff rows with `target="other"` apply to the
    // victim (shotgun stuns), not the attacker. perkBoomstick 0 fires
    // buffInjuryStunned01Shotgun on the zombie the attacker hit.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    // Seed the ledger directly (purchase validation needs attribute
    // levels; the fold visits owned entries and the row gates check the
    // level itself).
    const boom = g.progression_table.perks;
    var found_pk = false;
    for (boom) |pk| {
        if (std.mem.eql(u8, pk.name, "perkBoomstick")) {
            found_pk = true;
            break;
        }
    }
    try std.testing.expect(found_pk);
    cl.skill_levels[0] = .{ .name = g.progression_table.perks[0].name, .level = 1 };
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkBoomstick")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    // The group gate needs a Boomstick-tagged held item. Hand one over.
    const gun = g.items.byName("gunShotgunT0PipeShotgun") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, gun.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == gun.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = gun.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }

    g.fireAttackedOther(ps, zs, 0);

    const stun_id = g.buffs.indexOfName("buffInjuryStunned02Shotgun").?;
    try std.testing.expect(g.sim.buffs[zs].find(stun_id) != null);
    // Attacker does not carry the victim's stun.
    try std.testing.expect(g.sim.buffs[ps].find(stun_id) == null);
}

test "MachineGunner refunds stamina on hit (attacked ModifyStats)" {
    // `onSelfAttackedOther` ModifyStats rows were evaluated but never
    // applied: perkMachineGunner 3 refunds +2 stamina per landed hit (gated
    // `ItemHasTags tags="perkMachineGunner"` + victim alive).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkMachineGunner")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 3 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.sim.health[ps].stamina = 50;
    g.sim.health[ps].stamina_max = 100;
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 50), g.sim.health[ps].stamina, 0.001);
    // Hold a MachineGunner-tagged item: +2 lands.
    const gun = g.items.byName("gunMGT0PipeMachineGun") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, gun.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == gun.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = gun.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 52), g.sim.health[ps].stamina, 0.001);
}

test "PummelPete combo counter rises per hit (attacked ModifyCVar)" {
    // `onSelfAttackedOther` self ModifyCVar rows apply through the shared
    // evaluator: perkPummelPete adds 1 to .PummelPeteCombo per landed hit,
    // which the buffPerkPummelPete stack chain reads for its bonus-ready
    // flag. Victim is a live zombie so IsAlive target=other passes.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPummelPete")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 3 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    // Group gate needs a PummelPete-tagged held item.
    const club = g.items.byName("meleeWpnClubT0WoodenClub") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, club.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == club.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = club.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get(".PummelPeteCombo"), 0.001);
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cl.cvars.get(".PummelPeteCombo"), 0.001);
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 2), cl.cvars.get(".PummelPeteCombo"), 0.001);
}

test "victim-directed cvar writes land on player victims" {
    // `target="other"` ModifyCVar rows write the victim's store when the
    // victim is a player: PistolPeteComplete's bleedCounter add fires on a
    // player victim (zombie victims stay recorded-only, no cvar store).
    // Held 9mm pistol gates the group; victim in range.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const ps = g.sim.playerByPeer(ca.slot).?;
    const vs = g.sim.playerByPeer(cb.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPistolPeteComplete")) {
            ca.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    ca.skill_level_n = 1;
    const pistol = g.items.byName("gunHandgunT0PipePistol") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, ca.slot, pistol.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == pistol.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = pistol.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    g.sim.transform[ps] = .{ .x = 256, .y = 70, .z = 256, .yaw = 0 };
    g.sim.transform[vs] = .{ .x = 257, .y = 70, .z = 256, .yaw = 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), cb.cvars.get("bleedCounter"), 0.001);
    g.fireAttackedOther(ps, vs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cb.cvars.get("bleedCounter"), 0.001);
    // Attacker's own store is untouched by the victim-directed row.
    try std.testing.expectApproxEqAbs(@as(f32, 0), ca.cvars.get("bleedCounter"), 0.001);
}

test "zombie fist infection lands on player victim" {
    // Attacker class hand_item rows: meleeHandZombie01's ungated
    // onSelfAttackedOther ModifyCVar add 10 to infectionCounter on the
    // target=other (the player victim), remapped onto the player's store.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_v: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap_v);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    // The effect group gates on the victim already being infected
    // (CVarCompare infectionCounter GT 0 target=other): zombies escalate
    // existing infection, never start it. Seed 1 first.
    _ = cl.cvars.apply("infectionCounter", .set, 1);
    g.fireAttackedSelf(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 11), cl.cvars.get("infectionCounter"), 0.001);
    g.fireAttackedSelf(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 21), cl.cvars.get("infectionCounter"), 0.001);
}

test "zombie victim carries bleedCounter through the cvar column" {
    // Zombie victims now own a lazy cvar store like stock EntityBuffs:
    // PistolPeteComplete's 9mm onSelfAttackedOther row adds bleedCounter
    // (LT 1 gate passes on 0), and the next hit's GT 0 gate lands the bleed
    // buff on the zombie. Previously zombies carried no store and the rows
    // were recorded-only.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPistolPeteComplete")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const pistol = g.items.byName("gunHandgunT0PipePistol") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, pistol.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == pistol.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = pistol.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    g.sim.transform[ps] = .{ .x = 256, .y = 70, .z = 256, .yaw = 0 };
    const zid = g.sim.spawnZombie(257, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.sim.transform[zs] = .{ .x = 257, .y = 70, .z = 256, .yaw = 0 };
    // First hit: bleedCounter 0 → 1 on the zombie's own column.
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), g.sim.entity_cvars[zs].get("bleedCounter"), 0.001);
    // Second hit: GT 0 gate passes → buffInjuryBleeding lands on the zombie.
    const bleed_id = g.buffs.indexOfName("buffInjuryBleeding").?;
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expect(g.sim.buffs[zs].find(bleed_id) != null);
}

test "BarBrawling rage grants on taking a hit (onOtherDamagedSelf)" {
    // The victim's `onOtherDamagedSelf` fires when a landed hit applies
    // damage: perkBarBrawling6RageMode grants the rage buff when holding a
    // perkBrawler weapon (knuckles). The damage-apply event was previously
    // unfired.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkBarBrawling6RageMode")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const knucks = g.items.byName("meleeWpnKnucklesT0LeatherKnuckles") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, knucks.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == knucks.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = knucks.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    const rage_id = g.buffs.indexOfName("buffBarBrawling6RageMode").?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    try std.testing.expect(g.sim.buffs[ps].find(rage_id) == null);
    g.fireAttackedSelf(ps, zs, 0);
    try std.testing.expect(g.sim.buffs[ps].find(rage_id) != null);
}

test "combat entry grants the magnum criminal-pursuit buff" {
    // `onCombatEntered` fires on the out-of-combat -> in-combat transition
    // (a landed hit after the idle window): holding the 44 magnum with
    // Enforcer Criminal Pursuit 1 grants its 20 s stamina buff. Previously
    // the trigger was never fired.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkEnforcerCriminalPursuit")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const magnum = g.items.byName("gunHandgunT2Magnum44") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, magnum.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == magnum.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = magnum.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    const pursuit_id = g.buffs.indexOfName("buffEnforcerCriminalPursuit").?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    try std.testing.expect(g.sim.buffs[ps].find(pursuit_id) == null);
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expect(g.sim.buffs[ps].find(pursuit_id) != null);
    // Re-entry within the idle window does not double-grant (already active);
    // the buff is the same instance.
    g.fireAttackedOther(ps, zs, 0);
    try std.testing.expect(g.sim.buffs[ps].find(pursuit_id) != null);
}

test "fall impact escalates the leg-injury counter" {
    // A self-fall damage claim (failing dtype) fires onSelfFallImpact on the
    // check buff: the `_fallSpeed`-gated rows add to $legHurtCounter and grant
    // buffPlayerFallingDamage. The rising counter is the server's leg-injury
    // escalation stock applies on bad landings.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    _ = g.tickSurvival(1.0); // grants the check buffs (buffStatusCheck01) on entered-game
    const check_id = g.buffs.indexOfName("buffStatusCheck01").?;
    try std.testing.expect(g.sim.buffs[ps].find(check_id) != null);
    // A sprained leg escalates on each bad landing (the leg buffs carry the
    // $legHurtCounter + buffLegGetsWorse rows); the check buff's own row
    // adds buffPlayerFallingDamage at any impact.
    _ = cl.cvars.apply("$legHurtCounter", .set, 0);
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffLegSprained", cl.entity_id));
    g.fireFallImpact(ps, 25);
    try std.testing.expect(cl.cvars.get("$legHurtCounter") > 0);
    const fall_dmg_id = g.buffs.indexOfName("buffPlayerFallingDamage").?;
    try std.testing.expect(g.sim.buffs[ps].find(fall_dmg_id) != null);
}

test "zombie fist applies exactly one wound per hit (fireOneBuff)" {
    // The zombie hand's AddBuff row is `fireOneBuff="true"` with 7 weighted
    // wound buffs: stock picks ONE by cumulative weight, not all. Seed the
    // group gate, hit, and assert only one of the seven is active.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_v: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap_v);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    _ = cl.cvars.apply("infectionCounter", .set, 1);
    const wound_names = [_][]const u8{ "buffFatiguedTrigger", "buffArmSprainedCHTrigger", "buffLegSprainedCHTrigger", "buffLaceration", "buffAbrasionCatch", "buffInjuryStunned01CHTrigger", "buffInjuryBleedingTwo" };
    var ids: [7]u16 = undefined;
    for (wound_names, 0..) |n, i| ids[i] = g.buffs.indexOfName(n).?;
    g.fireAttackedSelf(ps, zs, 0);
    var active: usize = 0;
    for (ids) |id| {
        if (g.sim.buffs[ps].find(id) != null) active += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), active);
}

test "buffInfectionMain escalates the infection counter" {
    // buffInfectionMain's update row adds `@_InfectionRate` to
    // infectionCounter every update tick: the infection worsens over time
    // server-side, gating the stage buffs and cure logic.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInfectionMain", cl.entity_id));
    _ = cl.cvars.apply("infectionCounter", .set, 0);
    _ = cl.cvars.apply("_InfectionRate", .set, 1);
    var k: u32 = 0;
    while (k < 600 and cl.cvars.get("infectionCounter") <= 0) : (k += 1) {
        g.tick_n += 1;
        _ = schedule.run(&g.sim, 0.05);
        _ = g.tickSurvival(0.05);
    }
    try std.testing.expect(cl.cvars.get("infectionCounter") > 0);
}

test "victim PackMule display buff fires on being hit" {
    // Victim-side progression rows: the victim's own purchased
    // perkPackMule 1 fires buffPackMuleDisplay when hit (5% RandomRoll gate
    // may refuse; the row path is what this proves, so retry a few hits).
    // Before this the victim event only evaluated buff rows, never the
    // victim's own perk rows.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    var capture2: ln_peer.Capture = .{};
    const cl2 = try g.attachJoinedClient(&capture2);
    const atk = g.sim.playerByPeer(cl2.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPackMule")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    cl.entered_game_fired = true;
    const disp_id = g.buffs.indexOfName("buffPackMuleDisplay").?;
    // The 5% RandomRoll gate is seeded per event (entity id x tick through
    // a SplitMix64 finalizer), so sweeping ticks passes near-certainly; the
    // other gates (PackMule 1, victim alive, no injury buffs, not attached)
    // all pass.
    var landed = false;
    var k: u32 = 0;
    while (k < 4000 and !landed) : (k += 1) {
        g.tick_n += 1;
        g.fireAttackedSelf(ps, atk, 0);
        if (g.sim.buffs[ps].find(disp_id) != null) landed = true;
    }
    try std.testing.expect(landed);
}

test "died rows set infectionCounter on player death" {
    // `onSelfDied` fires in the hp-replicate death path: buffInfection04's
    // row sets infectionCounter to 1 on the dead player's cvars.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInfection04", cl.entity_id));
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get("infectionCounter"), 0.001);
    // Radiation pool's died row removes itself (non-Twitch live row).
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffRadiationPool", cl.entity_id));
    const rad_id = g.buffs.indexOfName("buffRadiationPool").?;
    try std.testing.expect(g.sim.buffs[ps].find(rad_id) != null);
    g.fireDied(ps);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cl.cvars.get("infectionCounter"), 0.001);
    const rad = g.sim.buffs[ps].find(rad_id);
    try std.testing.expect(rad == null or rad.?.flags.remove);
}

test "leave-game rows clear harvest buff on disconnect" {
    // `onSelfLeaveGame` fires in the session-drop path before the entity is
    // destroyed: buffHarvest's self-remove row flags it. Assert the flag
    // (the reap that follows never runs on a destroyed entity).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffHarvest", cl.entity_id));
    const hid = g.buffs.indexOfName("buffHarvest").?;
    try std.testing.expect(g.sim.buffs[ps].find(hid) != null);
    g.fireLeaveGame(ps);
    const inst = g.sim.buffs[ps].find(hid).?;
    try std.testing.expect(inst.flags.remove);
}

test "CharismaticNature shares level with party member" {
    // `target="selfOtherPlayers"` fan-out: buying CharismaticNature writes
    // CharismaticNatureLevel onto party members' cvars and grants the group
    // buff, so their own buff rows scale.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    try std.testing.expect(g.parties.acceptInvite(ca.entity_id, cb.entity_id) != null);
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkCharismaticNature")) {
            ca.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    ca.skill_level_n = 1;
    // addProgressionLevel refuses delta 0; call the (file-private) fire path
    // through a 1-step bump from a zeroed ledger instead.
    ca.skill_levels[0].level = 0;
    _ = g.addProgressionLevel(ca.slot, "perkCharismaticNature", 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cb.cvars.get("CharismaticNatureLevel"), 0.001);
    const grp_id = g.buffs.indexOfName("buffPerkCharismaticNature").?;
    const cb_ps = g.sim.playerByPeer(cb.slot).?;
    try std.testing.expect(g.sim.buffs[cb_ps].find(grp_id) != null);
}

test "multi-name RemoveBuff fans out (splint ladder)" {
    // Stock splits `buff=` on commas into buffNames: buffLegCast's start row
    // removes sprained+splinted+broken together. The recorded-list applier
    // must split too (previously the whole comma string failed lookup and
    // nothing was removed).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffLegSprained", cl.entity_id));
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffLegSplinted", cl.entity_id));
    const sprain_id = g.buffs.indexOfName("buffLegSprained").?;
    const splint_id = g.buffs.indexOfName("buffLegSplinted").?;
    try std.testing.expect(g.sim.buffs[ps].find(sprain_id) != null);
    try std.testing.expect(g.sim.buffs[ps].find(splint_id) != null);
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffLegCast", cl.entity_id));
    g.tickSurvival(1.0);
    try std.testing.expect(g.sim.buffs[ps].find(sprain_id) == null or g.sim.buffs[ps].find(sprain_id).?.flags.remove);
    try std.testing.expect(g.sim.buffs[ps].find(splint_id) == null or g.sim.buffs[ps].find(splint_id).?.flags.remove);
}

test "delayed kill stamina lands after 1s" {
    // `delay=` ModifyStats rows defer: JavelinMaster 1 kill refunds +10
    // stamina after 1.0 s (20 ticks), not immediately. Gated ItemHasTags
    // perkJavelinMaster + victim alive.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkJavelinMaster")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const spear = g.items.byName("meleeWpnSpearT0StoneSpear") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, spear.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == spear.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = spear.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    g.sim.health[ps].stamina = 50;
    g.sim.health[ps].stamina_max = 100;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.fireKilledOther(ps, zs);
    // Not yet: deferred 20 ticks out.
    try std.testing.expectApproxEqAbs(@as(f32, 50), g.sim.health[ps].stamina, 0.001);
    var k: u8 = 0;
    while (k < 25) : (k += 1) {
        g.tick_n += 1;
        g.tickSurvival(0.05);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), g.sim.health[ps].stamina, 0.001);
}

test "power-attack kill refunds stamina via IsSecondaryAttack" {
    // perkBatterUpComplete's club power-kill group gates on the book at 1 +
    // `ItemHasTags club` + `IsSecondaryAttack`: the held club declares Action1
    // (the heavy attack), which IL=65 resolves to `Actions[1] != null` — a
    // weapon shape, not the swing type. Without the supplier the group
    // refused and a club kill scored no refund.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkBatterUpComplete")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const club = g.items.byName("meleeWpnClubT0WoodenClub") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, club.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == club.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = club.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    g.sim.health[ps].stamina = 50;
    g.sim.health[ps].stamina_max = 100;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.fireKilledOther(ps, zs);
    var k: u8 = 0;
    while (k < 25) : (k += 1) {
        g.tick_n += 1;
        g.tickSurvival(0.05);
    }
    // The 1000-power refund clears the 100 cap (full refill on a club kill).
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].stamina, 0.001);
}

test "cure-all flags typed buffs only" {
    // `RemoveAllNegativeBuffs` clears buffs whose DamageType is set and
    // leaves untyped ones: abrasion (Bashing) flags, the berserker buff
    // (no type) stays. Driven through the regen start row.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffBerserker", cl.entity_id));
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInjuryAbrasion", cl.entity_id));
    const harv_id = g.buffs.indexOfName("buffBerserker").?;
    const abr_id = g.buffs.indexOfName("buffInjuryAbrasion").?;
    cl.level = 1;
    // The applier is file-private; drive the real path through the regen
    // buff's own start row instead. One survival tick fires starts without
    // giving abrasion's own update self-remove time to reap it.
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffNearDeathRegen", cl.entity_id));
    g.tickSurvival(1.0);
    const abr = g.sim.buffs[ps].find(abr_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(abr.flags.remove);
    try std.testing.expect(!g.sim.buffs[ps].find(harv_id).?.flags.remove);
}

test "bleeding drains HP via cvar-scaled HealthChangeOT" {
    // buffInjuryBleeding's passive HealthChangeOT base_subtract reads
    // `value="@$bleedAmount"`: the start row sets $bleedAmount =
    // bleedCounter / 2, so a 4-stack bleed drains 2 HP per second through
    // the active-buff fold.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].hp = 100;
    g.sim.health[ps].max_hp = 100;
    _ = cl.cvars.apply("bleedCounter", .set, 4);
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInjuryBleeding", cl.entity_id));
    _ = g.tickSurvival(1.0);
    // 4/2 = 2 per second; well-fed/regen could add a small offset, so assert
    // the drain dominates rather than the exact bar.
    try std.testing.expect(g.sim.health[ps].hp < 99);
    try std.testing.expect(g.sim.health[ps].hp > 90);
}

test "spawn-heal finish restores bars" {
    // Finish-event stat restores: buffEntitySpawnHeal's finish rows add 30000
    // Health/Stamina (clamped to max). Previously applyTriggeredBuffs dropped
    // res.mods, so finish stats never applied.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].hp = 10;
    g.sim.health[ps].max_hp = 100;
    g.sim.health[ps].stamina = 10;
    g.sim.health[ps].stamina_max = 100;
    const def_id = g.buffs.indexOfName("buffEntitySpawnHeal").?;
    g.fireBuffFinish(ps, def_id);
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].hp, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].stamina, 0.001);
}

test "church-bell ring spawns the aggressive horde" {
    // The full chain: a bell block's onSelfDamagedBlock fires block_bell_spawn
    // (TriggerHasTags churchbell, gated by buffDukeNote), and the sequence -
    // now supported with SpawnEntity + the RandomRoll gate - spawns 4
    // SleeperGSList zombies around the player. Roll the 99% gate; run the
    // sequence directly with the Duke note present.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const bell = g.blocks.byName("churchBell") orelse return error.SkipZigTest;
    try std.testing.expect(bell.tags.len > 0);
    // The killer fires the buff rows on a bell hit: the check buff's
    // CallGameEvent gate needs the Duke note.
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffDukeNote", cl.entity_id));
    const before = g.sim.countKind(.zombie);
    g.fireBlockDamaged(ps, bell.id);
    // The sequence is now supported (SpawnEntity + RandomRoll absorbed).
    const seq = g.gameevents.find("block_bell_spawn") orelse return error.SkipZigTest;
    try std.testing.expect(seq.supported);
    _ = g.runGameEventSequence(cl.slot, "block_bell_spawn");
    try std.testing.expect(g.sim.countKind(.zombie) > before);
    // Same-tick re-run must not spawn a second horde.
    const after_first = g.sim.countKind(.zombie);
    try std.testing.expect(!g.runGameEventSequence(cl.slot, "block_bell_spawn"));
    try std.testing.expectEqual(after_first, g.sim.countKind(.zombie));
}

test "heal-health cvar add heals per update" {
    // `value="@cvar"` Health adds resolve at execute time: buffHealHealth's
    // update row adds @medRegHealthIncSpeed per due update while the medical
    // pool lasts. Seed the pool like a bandage use would.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].hp = 50;
    g.sim.health[ps].max_hp = 100;
    _ = cl.cvars.apply("medicalRegHealthAmount", .set, 30);
    _ = cl.cvars.apply("medRegHealthIncSpeed", .set, 2);
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffHealHealth", cl.entity_id));
    var k: u8 = 0;
    while (k < 25) : (k += 1) {
        _ = ecs.schedule.run(&g.sim, 0.05);
        g.tickSurvival(0.05);
    }
    try std.testing.expect(g.sim.health[ps].hp > 50);
}

test "ranged ray-hit bleeds the victim (onSelfPrimaryActionRayHit)" {
    // ItemActionRanged fires onSelfPrimaryActionRayHit (MinEvent 25) on a hit;
    // perkAgilityMastery's bleed row bleeds the victim (bleedCounter add 1,
    // gated bleedCounter LT 1 at 0). The C2S damage claim cannot say
    // melee-vs-ranged, so the held weapon's `ranged` tag picks the ray-hit
    // path; a melee club takes the onSelfAttackedOther path and does not
    // bleed through this row.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkAgilityMastery")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 3 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const gun = g.items.byName("gunHandgunT0PipePistol") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, gun.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == gun.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = gun.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    try std.testing.expect(g.heldWeaponIsRanged(ps));
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.fireRayHit(ps, zs, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), g.sim.entity_cvars[zs].get("bleedCounter"), 0.001);
    // The melee path (fireAttackedOther) does not apply the ray-hit bleed.
    const club = g.items.byName("meleeWpnClubT0WoodenClub") orelse return error.SkipZigTest;
    g.sim.inventory[ps].slots[0] = .{ .item_id = club.id, .count = 1, .quality = 1 };
    try std.testing.expect(!g.heldWeaponIsRanged(ps));
    const zid2 = g.sim.spawnZombie(258, 70, 256, 40).?;
    const zs2 = g.sim.slotOfNetId(zid2).?;
    g.fireAttackedOther(ps, zs2, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.sim.entity_cvars[zs2].get("bleedCounter"), 0.001);
}

test "level-curved ModifyCVar indexes the perk's level" {
    // perkPhysician's onSelfProgressionUpdate row sets
    // `$medicRegHealthIncreaseSpeed` from a curve (2, 2.5, 3, ...); stock
    // Execute picks valueList[CalculatedLevel-1], so level 2 must write 2.5,
    // not the first segment 2.0. Feeding the changed perk's level into the
    // ctx resolves it.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPhysician")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    try std.testing.expect(g.addProgressionLevel(0, "perkPhysician", 1));
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), cl.cvars.get("$medicRegHealthIncreaseSpeed"), 0.001);
}

test "forgetting elixir resets progression and refunds points" {
    // Grandpa's Forgetting Elixir's `ResetProgression reset_skills="true"`
    // row: stock Progression::ResetProgression refunds CalculatedCostForLevel
    // for every perk/attribute level above base, then attribute->1 / perk->0.
    // The eat-path item rows now fire it, so the respec lands server-side.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    cl.skill_levels[0] = .{ .name = "attStrength", .level = 2 };
    cl.skill_levels[1] = .{ .name = "perkPummelPete", .level = 3 };
    cl.skill_level_n = 2;
    cl.skill_points = 0;
    // Expected refund: attribute level 2 costs cost(2); perk level 3 costs
    // cost(1)+cost(2)+cost(3) (perk base cost 1 each per the purchase path).
    var expect: u32 = 0;
    for (g.progression_table.attributes) |a| {
        if (std.mem.eql(u8, a.name, "attStrength")) {
            var l: u8 = 2;
            while (l <= 2) : (l += 1) expect += g.skillCostOf(cl.slot, a.name, l) orelse 1;
        }
    }
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkPummelPete")) {
            var l: u8 = 1;
            while (l <= 3) : (l += 1) expect += g.skillCostOf(cl.slot, pk.name, l) orelse 1;
        }
    }
    const elixir = g.items.byName("drinkJarGrandpasForgettingElixir") orelse return error.SkipZigTest;
    g.fireItemUseBuffs(ps, elixir.id);
    // attStrength back to base 1, perk back to 0, refunded points banked.
    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(cl.slot, "attStrength"));
    try std.testing.expectEqual(@as(u8, 0), g.skillLevelOf(cl.slot, "perkPummelPete"));
    try std.testing.expectEqual(expect, cl.skill_points);
}

test "consumable item use grants its buffs (onSelfPrimaryActionEnd)" {
    // ItemActionEat fires onSelfPrimaryActionEnd on the dedicated server; the
    // eaten item's AddBuff rows are the consumable grants (beer's stamina
    // buff, fire-extinguish, coffee, drugs). The eat path now fires them with
    // the pool cvars suppressed (EatProps owns food/water/HP), so the buffs
    // land without double-restoring.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const beer = g.items.byName("drinkJarBeer") orelse return error.SkipZigTest;
    const beer_id = g.buffs.indexOfName("buffBeer").?;
    const ext_id = g.buffs.indexOfName("buffExtinguishFire").?;
    // On fire: the extinguish group (gated `HasBuff buffIsOnFire`) grants
    // buffExtinguishFire; the Drink Tier 3 group (gated `!HasBuff
    // buffIsOnFire`) refuses beer.
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffIsOnFire", cl.entity_id));
    g.fireItemUseBuffs(ps, beer.id);
    try std.testing.expect(g.sim.buffs[ps].find(beer_id) == null);
    try std.testing.expect(g.sim.buffs[ps].find(ext_id) != null);
    // Second client, not on fire: the gates flip — beer grants, extinguish
    // refuses.
    var cap2: ln_peer.Capture = .{};
    const cl2 = try g.attachJoinedClient(&cap2);
    const ps2 = g.sim.playerByPeer(cl2.slot).?;
    g.fireItemUseBuffs(ps2, beer.id);
    try std.testing.expect(g.sim.buffs[ps2].find(beer_id) != null);
    try std.testing.expect(g.sim.buffs[ps2].find(ext_id) == null);
    // The beer duration cvar seeds through the merge on the not-on-fire
    // client (the buff's update rows drain it to expire the stamina boost),
    // while the food/water/HP pool cvars stay absent (EatProps owns the
    // restore; seeding them would double-drain through buffProcessConsumables).
    try std.testing.expect(cl2.cvars.get("$buffBeerDuration") > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl2.cvars.get("$foodAmountAdd"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl2.cvars.get("foodHealthAmount"), 0.001);
}

test "consumable buff expires when its duration cvars drain" {
    // The full chain: SlowMetabolism's metabolism cvar feeds the drain
    // ($buffBeerDuration subtract @.dummy each update, dummy =
    // $MetabolismDuration/2), and the buff's RemoveBuff row gates on
    // `$buffBeerDuration LTE 0`. With the duration seeded by the eat path,
    // the buff wears off server-side after enough updates.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    // SlowMetabolism level 1 sets $MetabolismDuration = 1 (the first curve
    // segment); drink a beer so the duration cvar seeds.
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkSlowMetabolism")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    try std.testing.expect(g.addProgressionLevel(0, "perkSlowMetabolism", 1));
    const beer = g.items.byName("drinkJarBeer") orelse return error.SkipZigTest;
    const beer_id = g.buffs.indexOfName("buffBeer").?;
    g.fireItemUseBuffs(ps, beer.id);
    try std.testing.expect(g.sim.buffs[ps].find(beer_id) != null);
    var k: u32 = 0;
    while (k < 30000 and g.sim.buffs[ps].find(beer_id) != null and cl.cvars.get("$buffBeerDuration") > 0) : (k += 1) {
        g.tick_n += 1;
        _ = schedule.run(&g.sim, 0.05);
        _ = g.tickSurvival(0.05);
    }
    // The RemoveBuff row flags removal on the crossing update; a couple more
    // full ticks let the buff tick reap the flagged slot.
    var r: u8 = 0;
    while (r < 5 and g.sim.buffs[ps].find(beer_id) != null) : (r += 1) {
        g.tick_n += 1;
        _ = schedule.run(&g.sim, 0.05);
        _ = g.tickSurvival(0.05);
    }
    try std.testing.expect(g.sim.buffs[ps].find(beer_id) == null);
    // The onSelfBuffRemove row cleared the duration cvars as the RemoveBuff
    // action flagged it (the post-update remove pass fires the cleanup);
    // no lingering $buffBeerDuration/.dummy state into the next beer.
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get("$buffBeerDuration"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get(".dummy"), 0.001);
}

test "infection04 start subtract kills instantly" {
    // Immediate Health subtract: buffInfection04's start row subtracts
    // 99999999 once (the infection kill blow at max counter). Previously only
    // Health adds applied; the kill blow never touched the bar.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].hp = 100;
    g.sim.health[ps].max_hp = 100;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInfection04", cl.entity_id));
    g.tickSurvival(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.sim.health[ps].hp, 0.001);
}

test "radiation pool drains 20 stamina per update" {
    // Immediate Stamina ModifyStats: buffRadiationPool's update row subtracts
    // 20 stamina per due update (previously parsed but never applied).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].stamina = 100;
    g.sim.health[ps].stamina_max = 100;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffRadiationPool", cl.entity_id));
    const before = g.sim.health[ps].stamina;
    // update_rate 1 = 20 world ticks per update; drive the world clock so the
    // buff tick marks the update due, then run survival to apply the row.
    var k: u8 = 0;
    while (k < 25) : (k += 1) {
        _ = ecs.schedule.run(&g.sim, 0.05);
        g.tickSurvival(0.05);
    }
    // 20 drained by the update row; other legs may add small offsets, so
    // assert the drain dominates.
    try std.testing.expect(g.sim.health[ps].stamina < before - 10);
    try std.testing.expect(g.sim.health[ps].stamina > before - 30);
}

test "puking start drains 50 water immediately" {
    // Immediate Food/Water ModifyStats: buffPuking01's start row subtracts 50
    // water once (previously only Health adds applied; the drain was parsed
    // but never touched the bars).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].water = 100;
    g.sim.health[ps].water_max = 100;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffPuking01", cl.entity_id));
    const before = g.sim.health[ps].water;
    g.tickSurvival(1.0);
    // 50 drained by the start row (observed 51.985: the tick's water
    // restore adds ~2 on top); assert the drain dominates, not the exact bar.
    try std.testing.expect(g.sim.health[ps].water < before - 40);
    try std.testing.expect(g.sim.health[ps].water > before - 60);
}

test "MotherLode penalizes harvest XP via Harvesting tag" {
    // Harvest passes `"Harvesting"` through awardXpTagged so the
    // PlayerExpGain perc_add rows scale it: perkMotherLode 1 is -10%
    // (SalvageOps/MotherLode mining penalty; night-stalker coffee -5%).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    cl.level = 1;
    // Grant MotherLode 1 then award 100 Harvesting XP.
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkMotherLode")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const before = cl.xp;
    g.awardXpTagged(cl.slot, 100, "Harvesting");
    const gained = cl.xp - before;
    // -10% → 90 XP.
    try std.testing.expectEqual(@as(u64, 90), gained);
}

test "TwilightThief scales kill XP at night (PlayerExpGain Kill)" {
    // Stock `AddKillXP` passes useBonus, so PlayerExpGain Kill rows fold:
    // perkNightStalkerTwilightThief +.05 behind IsNight. Day keeps base.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    try std.testing.expect(g.addProgressionLevel(cl.slot, "perkNightStalkerTwilightThief", 1));
    const before = g.clients[cl.slot].xp;
    g.killXpAward(cl.slot, 200, 100, false, 0);
    const gained = g.clients[cl.slot].xp - before;
    if (g.sim.director.clock.isNight()) {
        try std.testing.expectEqual(@as(u64, 210), gained);
    } else {
        try std.testing.expectEqual(@as(u64, 200), gained);
    }
}

test "stamina regen scales with water fraction (StaminaOT water gate)" {
    // Stock `UpdatePlayerStaminaOT` IL=139: the positive leg scales by
    // max(water%, 0.2). A dehydrated player regens at the 0.2 floor.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].water = 100;
    g.sim.health[ps].water_max = 100;
    g.sim.health[ps].stamina = 0;
    g.sim.health[ps].stamina_max = 100;
    try g.step();
    const wet_gain = g.sim.health[ps].stamina;
    try std.testing.expect(wet_gain > 0);
    g.sim.health[ps].water = 0;
    g.sim.health[ps].stamina = 0;
    try g.step();
    const dry_gain = g.sim.health[ps].stamina;
    try std.testing.expect(dry_gain > 0);
    try std.testing.expect(dry_gain < wet_gain);
}

test "fatigued victim takes scaled damage (HealthLoss passive 107)" {
    // Stock `Stat.Tick` scales an applied loss by GetValue(LossPassive):
    // buffFatigued carries HealthLoss +.1, so a 10.0 hit lands 11.0.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.healthGainLossMult(cl.slot, "HealthLoss"), 0.0001);
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffFatigued", cl.entity_id));
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), g.healthGainLossMult(cl.slot, "HealthLoss"), 0.0001);
}

test "rogue set bonus scales dukes stacks (LootQuantity passive 81)" {
    // Stock `SpawnItem` scales the rolled count by GetValue(81 LootQuantity)
    // over the spawned item's tags (IL_0040). buffRogueSetBonus carries
    // tiered dukes rows (Equals N lowest quality -> +.05..+.3); with four
    // Q1 rogue pieces the Equals-1 row folds, so a 20-dukes stack lands 21.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    // No rows: the base count passes through.
    try std.testing.expectEqual(@as(u16, 20), g.lootQtyScale(cl.slot, ps, "casinoCoin", "", 20));
    // Four Q1 rogue pieces + the set bonus buff: Equals-1 row (+.05) folds
    // over the spawned item's own "dukes" tags.
    for ([_][]const u8{ "armorRogueHelmet", "armorRogueOutfit", "armorRogueGloves", "armorRogueBoots" }, 0..) |name, i| {
        const def = g.items.byName(name) orelse return error.SkipZigTest;
        g.sim.inventory[ps].slots[ecs.components.inv_equip_start + i] = .{ .item_id = def.id, .count = 1, .quality = 1 };
    }
    const bonus = g.buffs.indexOfName("buffRogueSetBonus") orelse return error.SkipZigTest;
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = bonus,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    try std.testing.expectEqual(@as(u16, 21), g.lootQtyScale(cl.slot, ps, "casinoCoin", "", 20));
    // An unrelated item's tags see no row: unchanged.
    try std.testing.expectEqual(@as(u16, 20), g.lootQtyScale(cl.slot, ps, "resourceWood", "", 20));
}

test "kill trigger fires SiphoningStrikes heal on zombie kill" {
    // `onSelfKilledOther` rows on the killer's purchased perks: Siphoning
    // Strikes 1 heals +2 HP on a melee kill (gated `ItemHasTags tags="melee"`
    // + not starving). Progression rows previously had no kill event at all.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.addProgressionLevel(cl.slot, "perkSiphoningStrikes", 1));
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.sim.health[ps].hp = 50;
    g.sim.health[ps].max_hp = 100;
    // Empty hand: the ItemHasTags gate refuses, no heal.
    g.sim.inventory[ps].holding = ecs.components.inv_no_holding;
    g.fireKilledOther(ps, zs);
    try std.testing.expectApproxEqAbs(@as(f32, 50), g.sim.health[ps].hp, 0.001);
    // Hold a melee-tagged item: +2 HP lands, clamped at max. The give lands
    // in the bag; move it to the toolbelt hand the held-tags reader checks.
    const axe = g.items.byName("meleeToolRepairT0StoneAxe") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, axe.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == axe.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = axe.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    g.fireKilledOther(ps, zs);
    try std.testing.expectApproxEqAbs(@as(f32, 52), g.sim.health[ps].hp, 0.001);
}

test "morale start otherAOE cripples nearby zombies" {
    // `target="otherAOE"` start rows fan out around the holder at start
    // time (stock centers the range cube on Self): adding
    // buffSledgeSaga3CrippledMorale cripples living zombies within 3 m of the
    // killer. A distant zombie stays clean.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const crip_id = g.buffs.indexOfName("buffCrippledMorale").?;
    const near = g.sim.spawnZombie(257, 70, 256, 40).?;
    const near_s = g.sim.slotOfNetId(near).?;
    const far = g.sim.spawnZombie(300, 70, 300, 40).?;
    const far_s = g.sim.slotOfNetId(far).?;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffSledgeSaga3CrippledMorale", cl.entity_id));
    g.tickSurvival(1.0);
    try std.testing.expect(g.sim.buffs[near_s].find(crip_id) != null);
    try std.testing.expect(g.sim.buffs[far_s].find(crip_id) == null);
}

test "kill trigger grants Dentist silver on tagged zombie kill" {
    // `EntityTagCompare target="other"` on the kill event: FortitudeMastery
    // 3+ with a brawler-tagged held item grants buffPerkTheDentistSilver on
    // walker/crawler/bandit kills (5% RandomRoll gate may refuse, so sweep a
    // few kills like the PackMule test). Proves the kill-event foreign-tag
    // fill resolves instead of refusing.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkFortitudeMastery")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 3 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const knuck = g.items.byName("meleeWpnKnucklesT0LeatherKnuckles") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, knuck.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == knuck.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = knuck.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    const dent_id = g.buffs.indexOfName("buffPerkTheDentistSilver").?;
    var landed = false;
    var k: u32 = 0;
    while (k < 4000 and !landed) : (k += 1) {
        g.tick_n += 1;
        const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
        const zs = g.sim.slotOfNetId(zid).?;
        g.fireKilledOther(ps, zs);
        if (g.sim.buffs[ps].find(dent_id) != null) landed = true;
    }
    try std.testing.expect(landed);
    // The Dentist buff's start row calls action_give_silver: the Client
    // sequence response goes to the killer. Tick survival so the start rows
    // fire, then assert a GameEventResponse reached the killer's capture.
    g.tickSurvival(1.0);
    const ev_id = packages.idOf("NetPackageGameEventResponse").?;
    var found_event = false;
    var i: usize = 0;
    while (i < capture.n) : (i += 1) {
        const msg = capture.slots[i].data[0..capture.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == ev_id) found_event = true;
        }
    }
    try std.testing.expect(found_event);
}

test "kill trigger clears FortitudeMastery bleeds on zombie kill" {
    // `onSelfKilledOther` RemoveBuff rows: perkFortitudeMastery clears
    // buffInjuryBleeding on the killer (ungated first row). The kill event
    // applies removes through the same path as adds.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkFortitudeMastery")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 1 };
            break;
        }
    }
    cl.skill_level_n = 1;
    try std.testing.expect(g.addCatalogBuff(cl.entity_id, ps, "buffInjuryBleeding", cl.entity_id));
    const bleed_id = g.buffs.indexOfName("buffInjuryBleeding").?;
    try std.testing.expect(g.sim.buffs[ps].find(bleed_id) != null);
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.fireKilledOther(ps, zs);
    // Removal flags the instance (the buff tick reaps it); assert the flag.
    const inst = g.sim.buffs[ps].find(bleed_id).?;
    try std.testing.expect(inst.flags.remove);
}

test "kill trigger grants Berserker on club kill at Strength 5" {
    // Kill-event self-gated AddBuff: StrengthMastery 5 + club-family held
    // item grants buffBerserker on kill (ItemHasTags multi-tag list).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (g.progression_table.perks) |pk| {
        if (std.mem.eql(u8, pk.name, "perkStrengthMastery")) {
            cl.skill_levels[0] = .{ .name = pk.name, .level = 5 };
            break;
        }
    }
    cl.skill_level_n = 1;
    const club = g.items.byName("meleeWpnClubT0WoodenClub") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, club.id, 1));
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == club.id) {
            g.sim.inventory[ps].slots[i] = .{};
            g.sim.inventory[ps].slots[0] = .{ .item_id = club.id, .count = 1, .quality = 1 };
            g.sim.inventory[ps].holding = 0;
            break;
        }
    }
    const bers_id = g.buffs.indexOfName("buffBerserker").?;
    const zid = g.sim.spawnZombie(256, 70, 256, 40).?;
    const zs = g.sim.slotOfNetId(zid).?;
    g.fireKilledOther(ps, zs);
    try std.testing.expect(g.sim.buffs[ps].find(bers_id) != null);
}

test "perkHardTarget's movement-gated GeneralDamageResist folds while moving" {
    // perkHardTarget's `GeneralDamageResist base_add level="1,5" value=".05,.25"`
    // sits in an effect_group gated `EntityHasMovementTag tags="walking,running"`.
    // The survival tick feeds the client's reported movement state as the
    // CurrentMovementTag set, so the row folds while walking or running and
    // drops at idle, which is not in the row's tag list.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    cl.skill_levels[0] = .{ .name = "perkHardTarget", .level = 5 };
    cl.skill_level_n = 1;
    try std.testing.expectEqual(@as(f32, 0), g.sim.buff_general_resist[ps]);
    cl.move_tag = .running;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), g.sim.buff_general_resist[ps], 0.001);
    cl.move_tag = .walking;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), g.sim.buff_general_resist[ps], 0.001);
    cl.move_tag = .idle;
    try g.step();
    try std.testing.expectEqual(@as(f32, 0), g.sim.buff_general_resist[ps]);
}

test "perkPainTolerance GeneralDamageResist reaches the damage choke cache" {
    // perkPainTolerance's untagged `GeneralDamageResist base_add level="1,5"
    // value=".05,.25"` row is passive 40, which EntityAlive::DamageEntity reads
    // with an empty tag set. The survival tick's untagged VM fold now caches it
    // per entity so every player-damage choke consumes it; before this the row
    // folded into a TrackedDeltas field nothing read.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expectEqual(@as(f32, 0), g.sim.buff_general_resist[ps]);
    cl.skill_levels[0] = .{ .name = "perkPainTolerance", .level = 5 };
    cl.skill_level_n = 1;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), g.sim.buff_general_resist[ps], 0.001);
    // Revertible like the rest of the VM: dropping the perk clears it.
    cl.skill_level_n = 0;
    try g.step();
    try std.testing.expectEqual(@as(f32, 0), g.sim.buff_general_resist[ps]);
}

test "perk max-stat deltas recompute max_hp revertibly" {
    // perkFortitudeMastery HealthMax is level="4,5" value="50,100": with the
    // perk at level 5 the survival pass recomputes max_hp = 100 + 100 = 200;
    // dropping the perk restores the 100 base (recompute-from-set).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    g.sim.health[ps].base_max_hp = 100;
    g.sim.health[ps].max_hp = 100;
    // Own FortitudeMastery at level 5 (the ledger drives the VM fold).
    cl.skill_levels[0] = .{ .name = "perkFortitudeMastery", .level = 5 };
    cl.skill_level_n = 1;
    var i: usize = 0;
    while (i < 3) : (i += 1) try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 200), g.sim.health[ps].max_hp, 0.001);
    // Revertible: dropping the perk restores the base on the next fold.
    cl.skill_level_n = 0;
    while (i < 6) : (i += 1) try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].max_hp, 0.001);
}

test "perk tagged StaminaChangeOT stays out of the idle regen; StaminaMax applies" {
    // perkRuleOneCardio: StaminaChangeOT .1,.2,.3,.3,.3 tags="running,swimmingRun"
    // + StaminaMax 25,50 (explicit 5-level anchors). At level 5 the max
    // recomputes to 150. The tagged row is a sprint modifier: an untagged query
    // never matches it (PassiveEffect::hasMatchingTag IL=53), so idle regen is
    // the plain 8/s and the row no longer inflates it.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    cl.skill_levels[0] = .{ .name = "perkRuleOneCardio", .level = 5 };
    cl.skill_level_n = 1;
    // The max-stat recompute needs the survival pass; run it once to set the
    // 150 cap, then measure the regen over one tick.
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 150), g.sim.health[ps].stamina_max, 0.001);
    g.sim.health[ps].stamina = 10;
    const before = g.sim.health[ps].stamina;
    try g.step();
    const gained = g.sim.health[ps].stamina - before;
    // dt at 20 TPS = 0.05 s: 8 x 0.05 = 0.4 per tick, with no tagged bonus.
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), gained, 0.01);
    // The same rows DO fold when the query carries their tag: the tagged fold
    // is what the sprint leg will consume.
    var counts: requirements.Counts = .{};
    const running = assets_progression.perkTotals(&g.progression_table, cl.skill_levels[0..cl.skill_level_n], .{ .tags = "running" }, &counts);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), running.stamina_ot, 0.0001);
    const untagged = assets_progression.perkTotals(&g.progression_table, cl.skill_levels[0..cl.skill_level_n], .{}, &counts);
    try std.testing.expectEqual(@as(f32, 0), untagged.stamina_ot);
}

test "sprint drain consumes running-tagged StaminaChangeOT (perkRuleOneCardio)" {
    // Rules floor is 12/s. Cardio L5 adds StaminaChangeOT perc_add 0.3 tags=running,
    // so sprint drain becomes 12 - 0.3*stamina_max/100 per second. At max 150 that
    // is 12 - 0.45 = 11.55/s. Idle must still ignore the tagged row (covered above).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    cl.skill_levels[0] = .{ .name = "perkRuleOneCardio", .level = 5 };
    cl.skill_level_n = 1;
    try g.step();
    const stam_max = g.sim.health[ps].stamina_max;
    try std.testing.expect(stam_max > 0);
    g.sim.health[ps].stamina = 100;
    cl.sprint_speed = 5;
    cl.sprint_stale_cd = 5.0;
    cl.move_tag = .running;
    const before = g.sim.health[ps].stamina;
    g.tickSurvival(1.0);
    const lost = before - g.sim.health[ps].stamina;
    // 12 - 0.3 * stam_max / 100
    const expected = 12.0 - 0.3 * stam_max / 100.0;
    try std.testing.expectApproxEqAbs(expected, lost, 0.05);
}

test "walk regen consumes walking-tagged StaminaChangeOT (armorFarmerHelmet)" {
    // Rules regen is 8/s. One medium armor piece adds StaminaChangeOT perc_add
    // -.0281 tags=walking, so walk regen becomes 8 + (-.0281)*stamina_max/100.
    // At max 150 that is 8 - 0.04215 = 7.95785/s. Idle (move_tag=.idle) must
    // ignore the tagged row (same gate as the cardio idle test).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const helm = g.items.byName("armorFarmerHelmet").?;
    g.sim.inventory[ps].slots[ecs.components.inv_equip_start] = .{ .item_id = helm.id, .count = 1, .quality = 1 };
    try g.step();
    // Spawn stamina_max is data-driven (often 100); fold against the live max.
    const stam_max = g.sim.health[ps].stamina_max;
    try std.testing.expect(stam_max > 0);
    g.sim.health[ps].stamina = 50;
    cl.sprint_speed = 0;
    // Keep the stale timer from clearing move_tag mid-tick.
    cl.sprint_stale_cd = 0;
    cl.move_tag = .walking;
    const before = g.sim.health[ps].stamina;
    g.tickSurvival(1.0);
    const gained = g.sim.health[ps].stamina - before;
    // 8 + (-0.0281)*stam_max/100
    const expected = 8.0 + (-0.0281) * stam_max / 100.0;
    try std.testing.expectApproxEqAbs(expected, gained, 0.05);
    // Idle must not apply the walking row.
    g.sim.health[ps].stamina = 50;
    cl.move_tag = .idle;
    const before_idle = g.sim.health[ps].stamina;
    g.tickSurvival(1.0);
    const gained_idle = g.sim.health[ps].stamina - before_idle;
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), gained_idle, 0.05);
}

test "FoodChangeOT and WaterChangeOT join the survival totals" {
    // UpdatePlayerFoodOT / UpdatePlayerWaterOT (IL=71): GetValue(115/123) * dt
    // joins Stat.regenAmount; Stat.Tick adds it. Rules depletion is the floor;
    // VM OT composes on top. Stock messmeup FoodChangeOT base_subtract 10 and
    // buffBurningEnvironment WaterChangeOT base_subtract .3. use_buff needs the
    // stock survival table (buffStatusCheck01), so keep game-dir buffs intact.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    g.sim.rules.progression.food_depletion_per_hour = 0;
    g.sim.rules.progression.water_depletion_per_hour = 0;
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const food_id = g.buffs.indexOfName("messmeup") orelse return error.SkipZigTest;
    const water_id = g.buffs.indexOfName("buffBurningEnvironment") orelse return error.SkipZigTest;
    // Join/tickSurvival onSelfEnteredGame re-adds class buffs (NewbieCoat
    // Food/WaterChangeOT +2). Wipe after arming entered_game_fired so the
    // lifecycle does not put them back, then keep only the OT rows under test.
    cl.entered_game_fired = true;
    for (&g.sim.buffsMut(ps).slots) |*s| s.* = .{};
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = food_id,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = water_id,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    g.sim.health[ps].food = 50;
    g.sim.health[ps].water = 50;
    g.tickSurvival(1.0);
    // messmeup Food/WaterChangeOT -10; BurningEnvironment WaterChangeOT -0.3
    try std.testing.expectApproxEqAbs(@as(f32, 40), g.sim.health[ps].food, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 39.7), g.sim.health[ps].water, 0.05);
}

test "HungerMultiplier scales negative FoodChangeOT (loss sandbox modifier)" {
    // `UpdatePlayerFoodOT` IL=71: a negative regenAmount is multiplied by
    // `Stat.LossSandboxModifier`, which `UpdateSandboxOptions` IL=21 loads
    // from option 161 HungerMultiplier. Water runs option 162 ThirstMultiplier.
    // Triplets: [GFG]=161@6, [GGI]=162@8; the StaminaUsage set is
    // {0,.25,.5,.75,1,1.25,1.5,1.75,2}, so index 6 ("G") = 1.5 and
    // index 8 ("I") = 2.0. use_buff needs the stock survival table, so keep
    // game-dir buffs intact and wipe only the player's BuffSet.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    g.sim.rules.progression.food_depletion_per_hour = 0;
    g.sim.rules.progression.water_depletion_per_hour = 0;
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const food_id = g.buffs.indexOfName("messmeup") orelse return error.SkipZigTest;
    cl.entered_game_fired = true;
    for (&g.sim.buffsMut(ps).slots) |*s| s.* = .{};
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = food_id,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    // HungerMultiplier 1.5 on the -10 messmeup food OT; ThirstMultiplier 2.0
    // on its -10 water OT.
    g.sandbox_code = "AGFGGGI";
    g.sim.health[ps].food = 50;
    g.sim.health[ps].water = 50;
    g.tickSurvival(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 35), g.sim.health[ps].food, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 30), g.sim.health[ps].water, 0.05);
}

test "the armor-set bonus is granted from xml when the full set is worn" {
    // buffBikerSetBonus is never added by name anywhere in zdtd: it comes from
    // buffStatusCheck02's onSelfBuffUpdate AddBuff row, gated
    // `ArmorGroupCount group_name="groupBiker" Equals 4` + `!HasBuff`, and is
    // revoked by the LTE 3 row. The tier value is the buff's own
    // PhysicalDamageResist row gated on ArmorGroupLowestQuality. All of it is
    // data: items.xml ArmorGroup, buffs.xml rows.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const bonus = g.buffs.indexOfName("buffBikerSetBonus").?;
    try std.testing.expect(g.sim.buffs[ps].find(bonus) == null);
    // Full set at qualities 5/4/4/3: count 4, lowest 3 (slot order must not
    // decide the minimum).
    const pieces = [_]struct { name: []const u8, quality: u8 }{
        .{ .name = "armorBikerHelmet", .quality = 5 },
        .{ .name = "armorBikerOutfit", .quality = 4 },
        .{ .name = "armorBikerGloves", .quality = 4 },
        .{ .name = "armorBikerBoots", .quality = 3 },
    };
    for (pieces, 0..) |pc, i| {
        const def = g.items.byName(pc.name).?;
        g.sim.inventory[ps].slots[ecs.components.inv_equip_start + i] = .{ .item_id = def.id, .count = 1, .quality = pc.quality };
    }
    try stepTicks(g, 46);
    try std.testing.expect(g.sim.buffs[ps].find(bonus) != null);
    try std.testing.expectApproxEqAbs(@as(f32, 3), g.sim.buff_phys_resist[ps], 0.001);
    // Losing one piece fires the LTE 3 RemoveBuff row. Stock marks the buff
    // Remove and the buff tick deletes it on the following tick, so the same
    // tick's armor fold still sees it.
    g.sim.inventory[ps].slots[ecs.components.inv_equip_start + 3] = .{};
    // The revoke row fires on the status buff's own update rate, and the buff
    // tick reaps a flagged instance on the following tick, so step until it is
    // gone and record that it was flagged on the way.
    var saw_flag = false;
    var wait: usize = 0;
    while (wait < 60) : (wait += 1) {
        try g.step();
        const inst = g.sim.buffs[ps].find(bonus) orelse break;
        if (inst.flags.remove) saw_flag = true;
    }
    try std.testing.expect(saw_flag);
    try std.testing.expect(g.sim.buffs[ps].find(bonus) == null);
    // The client sees exactly one removal: the flagged buff is relayed by the
    // expiry drain, not by the row that flagged it (relaying both would send a
    // second NetPackageAddRemoveBuff for the same buff).
    var removes: u32 = 0;
    const ar_id = packages.idOf("NetPackageAddRemoveBuff").?;
    for (capture.slots[0..capture.n]) |sl| {
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(sl.data[0..sl.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != ar_id) continue;
            var nb: [128]u8 = undefined;
            const v = wire_stock_buff.parseAddRemoveBuff(p.body, &nb) catch continue;
            if (!v.adding and std.mem.eql(u8, v.name, "buffBikerSetBonus")) removes += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), removes);
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.sim.buff_phys_resist[ps], 0.001);
    // A different set's pieces do not grant the biker bonus.
    const nomad = g.items.byName("armorNomadHelmet").?;
    g.sim.inventory[ps].slots[ecs.components.inv_equip_start] = .{ .item_id = nomad.id, .count = 1, .quality = 3 };
    try stepTicks(g, 46);
    try std.testing.expect(g.sim.buffs[ps].find(bonus) == null);
}

test "the survival pass reads the held item's tags for HoldingItemHasTags" {
    // The tick fills the ctx from the held toolbelt slot, so a row gated
    // HoldingItemHasTags (IL=37) folds only while a matching item is in hand.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const reqs = [_]requirements.Requirement{.{
        .kind = .holding_item_has_tags,
        .name = "HoldingItemHasTags",
        .list = "perkDeadEye",
    }};
    const perks = [_]assets_progression.PerkDef{.{
        .name = "perkHoldTest",
        .max_level = 1,
        .passives = &.{.{ .name = "HealthMax", .op = .base_add, .value = 50, .reqs = &reqs }},
    }};
    g.progression_table.perks = &perks;
    cl.skill_levels[0] = .{ .name = "perkHoldTest", .level = 1 };
    cl.skill_level_n = 1;
    g.sim.health[ps].base_max_hp = 100;
    // Empty hand: the gate refuses.
    g.sim.inventory[ps].holding = ecs.components.inv_no_holding;
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].max_hp, 0.001);
    // A hunting rifle carries perkDeadEye in its Tags property.
    const rifle = g.items.byName("gunRifleT1HuntingRifle").?;
    g.sim.inventory[ps].holding = 0;
    g.sim.inventory[ps].slots[0] = .{ .item_id = rifle.id, .count = 1 };
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 150), g.sim.health[ps].max_hp, 0.001);
}

test "the survival pass resolves a sandbox-gated row from the server code" {
    // The tick decodes Game.sandbox_code once and hands the groups to the
    // requirement ctx, so SandboxOptionBool (IL=18) reads the operator's
    // setting. A hand-built perk row with a literal value makes the gate
    // visible in max_hp, unlike buffStatusCheck01's @cvar rows.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const reqs = [_]requirements.Requirement{.{
        .kind = .sandbox_option_bool,
        .name = "SandboxOptionBool",
        .arg = "PlayerLevelBonusApplied",
    }};
    const perks = [_]assets_progression.PerkDef{.{
        .name = "perkSandboxTest",
        .max_level = 1,
        .passives = &.{.{ .name = "HealthMax", .op = .base_add, .value = 50, .reqs = &reqs }},
    }};
    g.progression_table.perks = &perks;
    cl.skill_levels[0] = .{ .name = "perkSandboxTest", .level = 1 };
    cl.skill_level_n = 1;
    g.sim.health[ps].base_max_hp = 100;
    // "AALA" = option AL (id 11 = PlayerLevelBonusApplied) at index A (No):
    // the gated row refuses, so only the 100 base max remains. The explicit
    // polarities are pinned here rather than the no-code default because
    // buffStatusCheck01's cvar updates are stateful across ticks; the census
    // default itself is pinned in the sandbox/buffs/requirements tests.
    g.sandbox_code = "AALA";
    try stepTicks(g, 46);
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.sim.health[ps].max_hp, 0.001);
    // "AALB" (Yes) lets the row apply: 150 = base 100 + the synthetic 50.
    g.sandbox_code = "AALB";
    g.sim.health[ps].base_max_hp = 100;
    try stepTicks(g, 46);
    // 150 = base 100 + the synthetic perk's 50, with the level bonus at zero.
    // Accounted row by row now that `value="@cvar"` operands are live:
    // buffStatusCheck01 adds buffLevelUpTracking (`PlayerLevel GT
    // @$LastPlayerLevel`, 1 > 0), whose update row sets `$LastPlayerLevel` to 1
    // and then closes its own guard; check01's update sets
    // `$PlayerLevelBonus = @$LastPlayerLevel` (1) and its `PlayerLevel LT 2` row
    // subtracts 1, so `HealthMax base_add @$PlayerLevelBonus` contributes 0. The
    // -1 this scenario used to see came from the operand being a constant 0,
    // which kept `$LastPlayerLevel` at 0 forever.
    try std.testing.expectApproxEqAbs(@as(f32, 150), g.sim.health[ps].max_hp, 0.001);
}

test "crafting tier follows the stock crafting-skill rows" {
    // Recipe.GetCraftingTier (IL=22): base 1 folded with the player's crafting
    // skill rows whose tags match the recipe's tag set (which includes the
    // recipe name), at the skill's purchased level. craftingRepairTools'
    // claw-hammer row is base_add 1,2,3,4,5,5 at levels 8,12,16,20,25,50.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const recipe = g.recipes.byName("meleeToolRepairT1ClawHammer") orelse return error.SkipZigTest;
    // No skill points: the row's curve is outside its level window, so the
    // tier stays at the base 1.
    try std.testing.expectEqual(@as(u8, 1), game_craft.craftingTierFor(g, cl.slot, recipe));
    // Level 16 lands inside the 12..16 segment (value 3): base 1 + 3 = 4.
    cl.skill_levels[0] = .{ .name = "craftingRepairTools", .level = 16 };
    cl.skill_level_n = 1;
    try std.testing.expectEqual(@as(u8, 4), game_craft.craftingTierFor(g, cl.slot, recipe));
    // Level 50 is the last anchor (value 5): base 1 + 5 = 6, the quality cap.
    cl.skill_levels[0].level = 50;
    try std.testing.expectEqual(@as(u8, 6), game_craft.craftingTierFor(g, cl.slot, recipe));
    // A recipe whose tag set matches no Skill/Perk CraftingTier row stays at 1.
    const stone = g.recipes.byName("resourceWood") orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(u8, 1), game_craft.craftingTierFor(g, cl.slot, stone));
}

test "crafting consumes tier-scaled ingredients and yields a tier-quality item" {
    // Recipe.CanCraft: with UseIngredientModifier the required count is the
    // recipe's CraftingIngredientCount at the crafting tier, so armorPrimitive
    // Helmet's base 5 fibers/wood becomes 15 at tier 3 (row level 2,3,4,5,6 =
    // +5,+10,+15,+20,+30). The crafted item then carries the tier as quality.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const recipe = g.recipes.byName("armorPrimitiveHelmet") orelse return error.SkipZigTest;
    const ridx: u16 = blk: {
        for (g.recipes.defs, 0..) |d, i| {
            if (std.mem.eql(u8, d.name, recipe.name)) break :blk @intCast(i);
        }
        return error.SkipZigTest;
    };
    // craftingArmor level 4: the primitive row lands on value 2 (tier 3).
    cl.skill_levels[0] = .{ .name = "craftingArmor", .level = 4 };
    cl.skill_level_n = 1;
    try std.testing.expectEqual(@as(u8, 3), game_craft.craftingTierFor(g, cl.slot, recipe));

    const out_id = g.ecsIdFromItemName("armorPrimitiveHelmet");
    const fibers = g.ecsIdFromItemName("resourceYuccaFibers");
    const wood = g.ecsIdFromItemName("resourceWood");
    const cloth = g.ecsIdFromItemName("resourceCloth");
    const tape = g.ecsIdFromItemName("resourceDuctTape");
    // 14 fibers is one short of the tier-3 requirement.
    try std.testing.expect(g.sim.depositItem(ps, fibers, 14));
    try std.testing.expect(g.sim.depositItem(ps, wood, 15));
    try std.testing.expect(g.sim.depositItem(ps, cloth, 1));
    try std.testing.expect(g.sim.depositItem(ps, tape, 1));
    try std.testing.expect(!g.tryCraft(cl.slot, ridx, 1));
    try std.testing.expect(g.sim.depositItem(ps, fibers, 1));
    try std.testing.expect(g.tryCraft(cl.slot, ridx, 1));

    var found_quality: u8 = 0;
    for (g.sim.inventory[ps].slots[0..ecs.components.inv_equip_start]) |sl| {
        if (sl.item_id == out_id and sl.count > 0) found_quality = sl.quality;
    }
    try std.testing.expectEqual(@as(u8, 3), found_quality);
}

test "the survival pass folds the armor query into buff_phys_resist" {
    // god carries an untagged PhysicalDamageResist 200 row and a
    // coredamageresist-tagged one. Equipment::GetTotalPhysicalArmorRating
    // (IL=887) queries passive 41 with that tag, so the per-tick cache the
    // armor fold fills is 400. Before the tag split it was the untagged 200.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const god = g.buffs.indexOfName("god").?;
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = god,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 400), g.sim.buff_phys_resist[ps], 0.001);
}

/// Zero every active buff's elapsed counter so a measured tick sees fresh
/// buffs (duration-anchored rows are time-scaled).
/// Advance `n` ticks. The buff lifecycle events are rate-driven now (stock runs
/// `onSelfBuffUpdate` on the buff's own `<update_rate>`, seconds * 20 ticks:
/// check01 40, check02 44), so a scenario that expects a check buff's rows to
/// have run must wait out that rate rather than assume one tick.
fn stepTicks(g: *Game, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try g.step();
}

fn resetBuffAges(set: *ecs.components.BuffSet) void {
    for (&set.slots) |*slot| {
        if (slot.active) slot.duration_ticks = 0;
    }
}

test "a gated perk row stops folding when its requirement fails" {
    // perkHealingFactor's HealthChangeOT row is gated
    // `!HasBuff buffStatusHungry03,buffStatusThirsty03` (progression.xml). The
    // survival pass resolves that gate against the live BuffSet, so a starving
    // or dehydrated player must not get the regen. Before the requirement
    // evaluator existed the row folded unconditionally.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const h = &g.sim.health[ps];
    h.base_max_hp = 100;
    h.max_hp = 100;
    cl.skill_levels[0] = .{ .name = "perkHealingFactor", .level = 5 };
    cl.skill_level_n = 1;
    // Stage 1 of both bars (40% of max): neither starving nor well fed, so the
    // perk's HealthChangeOT is the only positive HP term.
    h.hp = 50;
    h.food = 0.4 * h.food_max;
    h.water = 0.4 * h.water_max;
    try g.step();
    try std.testing.expect(h.hp > 50);
    // NewbieCoat lands via onSelfEnteredGame on that first step and carries
    // ungated +2/s Food/Water/HealthChangeOT (duration 0,20); blank its slot
    // now so the dehydrated settle and measured ticks below see only the rows
    // under test.
    if (g.buffs.indexOfName("buffNewbieCoat")) |nc| {
        if (g.sim.buffsMut(ps).find(nc)) |slot| slot.* = .{};
    }

    // Dehydrated (1% of max -> stage 3): the stage buffs go active during the
    // pass, so the negated HasBuff gate refuses the regen. Settle first: a stage
    // change marks the stale buff Remove and the buff tick reaps it on the next
    // tick, and the stage rows are themselves gated on not already carrying a
    // stage buff, so the two measured ticks must start from the same settled set
    // with the same buff ages.
    h.hp = 50;
    h.food = 0.4 * h.food_max;
    h.water = 0.01 * h.water_max;
    try stepTicks(g, 46);
    const thirsty03 = g.buffs.indexOfName("buffStatusThirsty03").?;
    try std.testing.expect(g.sim.buffs[ps].find(thirsty03) != null);

    resetBuffAges(g.sim.buffsMut(ps));
    h.hp = 50;
    h.food = 0.4 * h.food_max;
    h.water = 0.01 * h.water_max;
    try g.step();
    const with_perk = h.hp;

    // The same dehydrated tick with the perk removed: an identical result is the
    // proof the gated row contributed nothing.
    resetBuffAges(g.sim.buffsMut(ps));
    h.hp = 50;
    h.food = 0.4 * h.food_max;
    h.water = 0.01 * h.water_max;
    cl.skill_level_n = 0;
    try g.step();
    try std.testing.expectApproxEqAbs(with_perk, h.hp, 0.0001);
}

test "every active buff fires its onSelfBuffStart rows once" {
    // buffShocked's onSelfBuffStart rows write $buffShockedDamage (the row that
    // matches its gates) and $buffShockedDisplay. Before the lifecycle sweep only
    // buffStatusCheck01/02 were driven at all, so no other buff's start rows ran.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const shocked = g.buffs.indexOfName("buffShocked") orelse return error.SkipZigTest;
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get("$buffShockedDamage"), 0.001);
    _ = ecs_buff.add(g.sim.buffsMut(ps), .{
        .def_id = shocked,
        .duration = 0,
        .stack_type = ecs_buff.StackType.ignore,
        .update_rate_ticks = 20,
        .remove_on_death = false,
    }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    try g.step();
    // The ungated `set -5` row applies at the default state.
    try std.testing.expectApproxEqAbs(@as(f32, -5), cl.cvars.get("$buffShockedDamage"), 0.001);
    // Fired once, not every tick: a second pass leaves the value alone.
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, -5), cl.cvars.get("$buffShockedDamage"), 0.001);
}

test "the armour status buffs gate on the worn-armour rating" {
    // check01's buffStatusArmorLow/High/Broken rows read
    // `StatCompareCurrent stat="Armor"`, which resolves since the rating reached
    // the gate ctx. A bare player (rating 0) is "broken armour": the LTE 0.1 row
    // applies, the 0.25/0.75 ones do not.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const broken = g.buffs.indexOfName("buffStatusArmorBroken") orelse return error.SkipZigTest;
    const low = g.buffs.indexOfName("buffStatusArmorLow") orelse return error.SkipZigTest;
    try stepTicks(g, 46);
    try std.testing.expectApproxEqAbs(@as(f32, 0), g.sim.buff_phys_resist[ps], 0.001);
    try std.testing.expect(g.sim.buffs[ps].find(broken) != null);
    try std.testing.expect(g.sim.buffs[ps].find(low) == null);
}

test "an entity can hold a full stock buff set, not just eight" {
    // The stage machine alone needs the six hunger/thirst stages plus the level
    // tracker, and a real player also carries the check buffs, an injury and a
    // weather buff. At the old cap of 8 the thirst stages (added last) fell off
    // the end of the fixed set and were re-added every tick.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const names = [_][]const u8{
        "buffStatusHungry01",  "buffStatusHungry02",        "buffStatusHungry03",
        "buffStatusThirsty01", "buffStatusThirsty02",       "buffStatusThirsty03",
        "buffLevelUpTracking", "buffBiomeProgressionCheck", "buffCheckScreenEffects",
        "buffSmellCheck",
    };
    for (names) |n| {
        const id = g.buffs.indexOfName(n) orelse return error.SkipZigTest;
        _ = ecs_buff.add(g.sim.buffsMut(ps), .{
            .def_id = id,
            .duration = 0,
            .stack_type = ecs_buff.StackType.ignore,
            .update_rate_ticks = 20,
            .remove_on_death = false,
        }, ecs_buff.duration_from_class, -1, 0, 0, 0);
    }
    for (names) |n| {
        const id = g.buffs.indexOfName(n).?;
        try std.testing.expect(g.sim.buffs[ps].find(id) != null);
    }
    try std.testing.expectEqual(@as(u8, names.len), g.sim.buffs[ps].count());
}

test "the entity class Buffs list parses from entityclasses.xml" {
    // entityclasses.xml playerMale `Buffs="buffStatusCheck01,buffStatusCheck02"`.
    // The parsed list is the input stock applies to the class when it enters the
    // game; activating it in the server (and the survival dynamics that shift
    // with check01's own passives folding) is the next step, not this one.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const pdef = g.entities.byHash(assets_unity_hash.class_player_male) orelse return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 2), pdef.buffs.len);
    try std.testing.expectEqualStrings("buffStatusCheck01", pdef.buffs[0]);
    try std.testing.expectEqualStrings("buffStatusCheck02", pdef.buffs[1]);
    // Every name resolves in the buff catalog (fail closed otherwise).
    for (pdef.buffs) |b| try std.testing.expect(g.buffs.indexOfName(b) != null);
    // The class list is applied when the player enters the game, so both check
    // buffs are active from the first survival pass (their own passives then
    // fold and the client is told about them).
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    for (pdef.buffs) |b| {
        try std.testing.expect(g.sim.buffs[ps].find(g.buffs.indexOfName(b).?) == null);
    }
    try g.step();
    for (pdef.buffs) |b| {
        try std.testing.expect(g.sim.buffs[ps].find(g.buffs.indexOfName(b).?) != null);
    }
}

test "the armor-perk chain derives its CVars from the worn items" {
    // buffStatusCheck02's light-armor chain, all data: `WornItems tags="lightArmor"
    // Equals N` picks `.ArmorLightWorn`, `ProgressionLevel perkLightArmor` picks
    // `.ArmorLightLevel`, and `.ArmorLightTotal` is `set @.ArmorLightLevel` then
    // `multiply @.ArmorLightWorn`. Before WornItems existed the first row refused
    // closed, so the whole chain (and the `PhysicalDamageResist = @.ArmorLightTotal`
    // passive it feeds) read 0.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    cl.skill_levels[0] = .{ .name = "perkLightArmor", .level = 1 };
    cl.skill_level_n = 1;
    // Four light-armor pieces (items.xml Tags carry `lightArmor`).
    const pieces = [_][]const u8{ "armorPrimitiveHelmet", "armorPrimitiveOutfit", "armorPrimitiveGloves", "armorPrimitiveBoots" };
    for (pieces, 0..) |name, i| {
        const def = g.items.byName(name).?;
        g.sim.inventory[ps].slots[ecs.components.inv_equip_start + i] = .{ .item_id = def.id, .count = 1, .quality = 1 };
    }
    try stepTicks(g, 46);
    // level 1 * 4 worn pieces.
    try std.testing.expectApproxEqAbs(@as(f32, 4), cl.cvars.get(".ArmorLightWorn"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cl.cvars.get(".ArmorLightLevel"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4), cl.cvars.get(".ArmorLightTotal"), 0.001);
    // buffStatusCheck02 is an active buff now (entity class Buffs=), so its own
    // `PhysicalDamageResist base_add @.ArmorLightTotal` row folds: the armour
    // rating gains exactly the derived total.
    const with_perk_resist = g.sim.buff_phys_resist[ps];
    try std.testing.expect(with_perk_resist >= 4);
    // Without the perk the effect_group gate refuses the chain and the
    // "remove if not in use" group drops the total.
    cl.skill_levels[0] = .{ .name = "perkLightArmor", .level = 0 };
    try stepTicks(g, 46);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cl.cvars.get(".ArmorLightTotal"), 0.001);
    try std.testing.expectApproxEqAbs(with_perk_resist - 4, g.sim.buff_phys_resist[ps], 0.001);
}

test "the check buffs' entered-game rows set their CVars and add their buffs" {
    // buffStatusCheck01 carries the entered-game rows: stock writes the hazard
    // durations as CVars and adds buffBiomeProgressionCheck/buffCheckScreenEffects.
    // zdtd fires the event once per client session now; before this the CVar
    // store did not exist and onSelfEnteredGame never ran.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const prog = g.buffs.indexOfName("buffBiomeProgressionCheck") orelse return error.SkipZigTest;
    try std.testing.expect(g.sim.buffs[ps].find(prog) == null);
    try std.testing.expect(!cl.entered_game_fired);
    try g.step();
    try std.testing.expect(cl.entered_game_fired);
    // Values are the stock XML's (buffs.xml onSelfEnteredGame rows).
    try std.testing.expectApproxEqAbs(@as(f32, 25200), cl.cvars.get("$infectionMaxDuration"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3600), cl.cvars.get("$dysenteryMaxDuration"), 0.001);
    try std.testing.expect(g.sim.buffs[ps].find(prog) != null);
    // The add is relayed so the client sees the same buff set.
    const ar_id = packages.idOf("NetPackageAddRemoveBuff").?;
    var saw_progression = false;
    for (capture.slots[0..capture.n]) |sl| {
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(sl.data[0..sl.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != ar_id) continue;
            var nb: [128]u8 = undefined;
            const v = wire_stock_buff.parseAddRemoveBuff(p.body, &nb) catch continue;
            if (v.adding and std.mem.eql(u8, v.name, "buffBiomeProgressionCheck")) saw_progression = true;
        }
    }
    try std.testing.expect(saw_progression);
    // Fired once: a second pass leaves the same values.
    try g.step();
    try std.testing.expectApproxEqAbs(@as(f32, 25200), cl.cvars.get("$infectionMaxDuration"), 0.001);
}

test "the survival stage buff tracks the thresholds and clears on recovery" {
    // buffStatusCheck01's stage rows are gated on their own stage buff
    // (`!HasBuff buffStatusThirsty03,...`), so the active stage cannot be read
    // back out of the row requests: it comes from the thresholds in buffs.xml
    // (buffs.survival). Starving and dehydrated to stage 3 must leave exactly the
    // stage-3 buffs, and eating/drinking back to full must drop them again
    // (stock clears the stages from the healing buffs' onSelfBuffStart rows;
    // zdtd drives the same removal from the thresholds).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&capture);
    const ps = g.sim.playerByPeer(cl.slot).?;
    const h = &g.sim.health[ps];
    h.base_max_hp = 100;
    h.max_hp = 100;
    const thirsty03 = g.buffs.indexOfName("buffStatusThirsty03").?;
    const hungry03 = g.buffs.indexOfName("buffStatusHungry03").?;
    // One step to let onSelfEnteredGame land NewbieCoat (ungated +2/s
    // Food/WaterChangeOT, duration 0,20), then blank its slot so the settle
    // below keeps the bars under the 2% stage threshold.
    try g.step();
    if (g.buffs.indexOfName("buffNewbieCoat")) |nc| {
        if (g.sim.buffsMut(ps).find(nc)) |slot| slot.* = .{};
    }
    // Stage 3 of both bars (<= 2% of max). The transition tick requests every
    // passing stage row (nothing is active yet), so the lower stages are marked
    // Remove on the next tick and reaped on the one after.
    h.food = 0.01 * h.food_max;
    h.water = 0.01 * h.water_max;
    try stepTicks(g, 46);
    try std.testing.expect(g.sim.buffs[ps].find(thirsty03) != null);
    try std.testing.expect(g.sim.buffs[ps].find(hungry03) != null);
    // The lower stages must not survive the transition.
    for ([_][]const u8{
        "buffStatusThirsty01", "buffStatusThirsty02",
        "buffStatusHungry01",  "buffStatusHungry02",
    }) |name| {
        const id = g.buffs.indexOfName(name).?;
        try std.testing.expect(g.sim.buffs[ps].find(id) == null);
    }
    h.food = h.food_max;
    h.water = h.water_max;
    try stepTicks(g, 46);
    try std.testing.expect(g.sim.buffs[ps].find(thirsty03) == null);
    try std.testing.expect(g.sim.buffs[ps].find(hungry03) == null);
}

test "breaking a container spills its pre-filled contents" { // 449 LootList blocks are CompositeTileEntity containers; their contents
    // live in the sim container store and must drop on break (the eviction
    // path spilled them; the break path dropped nothing).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var capture: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&capture);
    const pos = containers_mod.PosKey{ .x = 10, .y = 70, .z = 20 };
    const cont = g.containers.getOrCreate(pos, 8, 1) orelse return error.TestUnexpectedResult;
    cont.slots[0] = .{ .item_id = 2, .count = 3, .quality = 1 };
    chunk_fill_mod.tryContainerSpill(g, 10, 70, 20);
    // The store entry is gone and a loot bag carries the item.
    try std.testing.expect(g.containers.get(pos) == null);
    var found = false;
    for (g.sim.alive, 0..) |alive, i| {
        if (!alive or !g.sim.mask[i].loot_bag or !g.sim.mask[i].inventory) continue;
        for (g.sim.inventory[i].slots) |sl| {
            if (sl.item_id == 2 and sl.count == 3) found = true;
        }
    }
    try std.testing.expect(found);
}

test "the three client-sent reports the server must not apply are handled and dropped" {
    // Recovered 2026-09-06 by scanning the v3.2.0 IL for every NetPackage type
    // that reaches ConnectionManager::SendToServer: 98 names, three of which
    // had no C2S arm at all while GAP_ANALYSIS claimed they did. Each one is a
    // report of state zdtd owns, so the handler must consume it (no unhandled
    // count) and change nothing (DIVERGENCES 1.15 to 1.17).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(ca.slot).?;

    g.sim.health[ps].hp = 42;
    g.clients[ca.slot].xp = 555;
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    var frame_buf: [128]u8 = undefined;

    // 1.15 EntityStatChanged: the stock 21-byte body claiming full health for
    // the sender's own entity. Applying it would be a self-heal.
    var stat_body: [21]u8 = undefined;
    const stat = try packages.buildEntityStatChangedBody(
        &stat_body,
        ca.entity_id,
        -1,
        .health,
        100,
        100,
        0,
    );
    try std.testing.expectEqual(@as(usize, 21), stat.len);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageEntityStatChanged", stat));
    try std.testing.expectEqual(@as(f32, 42), g.sim.health[ps].hp);

    // 1.17 SharedPartyKill: a forwarded party kill worth 100000 xp. Applying it
    // would mint xp for a kill the server never saw.
    var kill_body: [16]u8 = undefined;
    const kill = try packages.stock_party.buildSharedKillBody(&kill_body, .{
        .entity_type = 1,
        .xp = 100000,
        .entity_id = 900,
        .killer_id = ca.entity_id,
    });
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageSharedPartyKill", kill));
    try std.testing.expectEqual(@as(u64, 555), g.clients[ca.slot].xp);

    // 1.16 GameEventResponse: responseType 11 is the one arm a stock client
    // sends (BlockGameEvent block damage). zdtd keeps no event-sequence state.
    var ev_body: [8]u8 = undefined;
    @memset(&ev_body, 0);
    ev_body[0] = 11;
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageGameEventResponse", &ev_body));

    // All three reached a handler: none of them raised the unhandled counter.
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));

    // Truncated bodies are rejected as malformed, not trusted or trapped on.
    const malformed_before = g.harness.counters.get(.c2s_malformed);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageEntityStatChanged", stat[0..20]));
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageSharedPartyKill", kill[0..15]));
    try std.testing.expect(g.harness.counters.get(.c2s_malformed) >= malformed_before + 2);
    try std.testing.expectEqual(@as(f32, 42), g.sim.health[ps].hp);
}

test "the laser sight relays to other players but not back to the sender" {
    // Stock NetPackagePlayerLaserSight ProcessPackage (IL=70): the server
    // re-sends the body to every client except the sender's own entity, so a
    // player sees a mate's laser dot. Filed as Twitch integration in
    // GAP_ANALYSIS until 2026-09-06, which is why it went unimplemented.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    const ls_id = packages.idOf("NetPackagePlayerLaserSight").?;
    var frame_buf: [128]u8 = undefined;
    var pkgs: [8]wire_frame.Package = undefined;

    // entityId i32 | active bool | position Vector3 = 17 bytes (read IL=16).
    var body: [17]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeI32(ca.entity_id);
    try w.writeBool(true);
    try w.writeF32(10.5);
    try w.writeF32(64);
    try w.writeF32(-3.25);
    try std.testing.expectEqual(@as(usize, 17), w.written().len);

    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackagePlayerLaserSight", w.written()));

    var a_got = false;
    var b_body: ?[]const u8 = null;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == ls_id) a_got = true;
        }
    }
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == ls_id) b_body = p.body;
        }
    }
    // No self-echo (AGENTS rule 19), and the mate gets the body verbatim.
    try std.testing.expect(!a_got);
    const relayed = b_body orelse return error.TestUnexpectedResult;
    const parsed = try packages.parseLaserSight(relayed);
    try std.testing.expectEqual(ca.entity_id, parsed.entity_id);
    try std.testing.expect(parsed.active);
    try std.testing.expectEqual(@as(f32, 10.5), parsed.x);
    try std.testing.expectEqual(@as(f32, -3.25), parsed.z);

    // Claiming another player's entity is an ownership reject, not a relay:
    // without the check a peer could paint a dot on anyone.
    var spoof: [17]u8 = undefined;
    var sw: wire_binary.Writer = .{ .buf = &spoof };
    try sw.writeI32(ca.entity_id + 1000);
    try sw.writeBool(true);
    try sw.writeF32(1);
    try sw.writeF32(2);
    try sw.writeF32(3);
    cap_b.clear();
    const rejects_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackagePlayerLaserSight", sw.written()));
    try std.testing.expectEqual(rejects_before + 1, g.harness.counters.get(.ownership_rejects));
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            try std.testing.expect(p.id != ls_id);
        }
    }
}

test "a fresh login sends the empty AuthConfirmation for the client to echo" {
    // Stock AuthFinalizer.Authorize (IL=10) sends an empty AuthConfirmation
    // as the last authorizer step; the client echoes it (ProcessPackage
    // IL_002E) and the server's ReplyReceived completes auth. The echo arm
    // existed without the send, so the round-trip never started.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const ac_id = packages.idOf("NetPackageAuthConfirmation") orelse
        return error.TestUnexpectedResult;
    var pkgs: [8]wire_frame.Package = undefined;
    var saw = false;
    for (cap.slots[0..cap.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != ac_id) continue;
            // Empty body: read IL=1 touches nothing past the base header.
            try std.testing.expectEqual(@as(usize, 0), p.body.len);
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "an owner receives their parked vehicles as a waypoint list" {
    // Stock VehicleManager.UpdateVehicleWaypointsForPlayer (IL=69): the
    // server ships the owner's (entityId, pos) vehicle pairs as
    // NetPackageEntityWaypointList with listType Vehicle (0) so their map
    // shows where they parked. Unowned vehicles are nobody's waypoints.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{});
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;
    const wl_id = packages.idOf("NetPackageEntityWaypointList") orelse
        return error.TestUnexpectedResult;

    const v = g.sim.spawnVehicleEx(.minibike, 256, 70, 260, 500, 12, 1).?;
    const vs = g.sim.slotOfNetId(v).?;
    g.sim.vehicle[vs].owner_slot = @intCast(ca.slot);
    const u = g.sim.spawnVehicleEx(.minibike, 300, 70, 300, 500, 12, 1).?;
    _ = u; // unowned: must not appear in anyone's list

    cap_a.clear();
    cap_b.clear();
    try g.sendVehicleWaypoints(ca.peer.?, ca.slot);
    var pkgs: [8]wire_frame.Package = undefined;
    var saw = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != wl_id) continue;
            // listType i16 Vehicle=0, count i32, then (id i32, 3xf32).
            try std.testing.expect(p.body.len >= 6);
            try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, p.body[0..2], .little));
            try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, p.body[2..6], .little));
            try std.testing.expectEqual(v, std.mem.readInt(i32, p.body[6..10], .little));
            // The position follows the id, x/y/z in order. Only the id was
            // asserted, so the wire-order audit found x, y and z
            // interchangeable: a reorder would have parked a remote player's
            // map marker at the wrong coordinates with the suite green. Read
            // the sim's value so the assertion survives any spawn snapping.
            const vpos = g.sim.transform[vs];
            try std.testing.expectEqual(vpos.x, @as(f32, @bitCast(std.mem.readInt(u32, p.body[10..14], .little))));
            try std.testing.expectEqual(vpos.y, @as(f32, @bitCast(std.mem.readInt(u32, p.body[14..18], .little))));
            try std.testing.expectEqual(vpos.z, @as(f32, @bitCast(std.mem.readInt(u32, p.body[18..22], .little))));
            saw = true;
        }
    }
    try std.testing.expect(saw);
    // The other client gets nothing from this send.
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            try std.testing.expect(p.id != wl_id);
        }
    }
}

test "a generator's remaining fuel survives a restart instead of refilling" {
    // The grid rebuilds from the block plane, and applyToNode sets a
    // generator's tank to max_fuel because that is right for a freshly placed
    // one. Nothing carried the burnt-down level across, so every restart was a
    // free refuel, and a trigger's delay/duration and a motion sensor's
    // TargetType came back at their defaults the same way. None of those has a
    // block-meta home (the switch latch does), so they ride their own
    // entities.zen record, queued at load and applied when the chunk scan
    // rebuilds the node.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const PowerStub = struct {
        power_class_by_name: std.StringHashMapUnmanaged([]const u8) = .{},
        pub fn idByName(_: *const @This(), name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "generatorbank")) return 20001;
            return null;
        }
        pub fn wattsByName(_: *const @This(), name: []const u8) ?f32 {
            if (std.mem.eql(u8, name, "generatorbank")) return 1000;
            return null;
        }
        pub fn maxFuelByName(_: *const @This(), name: []const u8) ?f32 {
            if (std.mem.eql(u8, name, "generatorbank")) return 1000;
            return null;
        }
        pub fn outputPerFuelByName(_: *const @This(), name: []const u8) ?f32 {
            if (std.mem.eql(u8, name, "generatorbank")) return 10;
            return null;
        }
    };
    const persist = @import("../persist.zig");
    const gen_id: u16 = 20001;
    const gx: i32 = 8;
    const gy: i32 = 70;
    const gz: i32 = 8;
    const burnt_to: f32 = 250;

    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var stub: PowerStub = .{};
        try stub.power_class_by_name.put(std.testing.allocator, "generatorbank", "Generator");
        defer stub.power_class_by_name.deinit(std.testing.allocator);
        g.power_registry = ecs.powerblocks.Registry.build(&stub);

        const ch = try g.world.getOrCreate(.{ .x = 0, .z = 0 });
        const blocks = ch.blocks.?;
        blocks[@intCast(gx + gz * 16 + gy * 256)] = gen_id;
        g.scanChunkPower(ch, 0, 0);
        const ni = g.sim.power.indexOfPosition(gx, gy, gz) orelse return error.TestUnexpectedResult;
        // A fresh scan fills the tank; run it down as play would.
        try std.testing.expectApproxEqAbs(@as(f32, 1000), g.sim.power.nodes[ni].fuel_or_energy, 0.01);
        g.sim.power.nodes[ni].fuel_or_energy = burnt_to;
        g.sim.power.nodes[ni].delay_idx = 3;
        g.sim.power.nodes[ni].duration_idx = 2;
        g.sim.power.nodes[ni].target_type = 8;
        try persist.saveEntities(g);
    }

    {
        const g = try Game.create(std.testing.allocator, dir, 0);
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        var stub: PowerStub = .{};
        try stub.power_class_by_name.put(std.testing.allocator, "generatorbank", "Generator");
        defer stub.power_class_by_name.deinit(std.testing.allocator);
        g.power_registry = ecs.powerblocks.Registry.build(&stub);

        try persist.loadEntities(g);
        // Queued, not applied: no chunk has been scanned, so the node this
        // record names does not exist yet.
        try std.testing.expect(g.sim.power.pending_state_n > 0);
        try std.testing.expect(g.sim.power.indexOfPosition(gx, gy, gz) == null);

        const ch = try g.world.getOrCreate(.{ .x = 0, .z = 0 });
        const blocks = ch.blocks.?;
        blocks[@intCast(gx + gz * 16 + gy * 256)] = gen_id;
        g.scanChunkPower(ch, 0, 0);

        const ni = g.sim.power.indexOfPosition(gx, gy, gz) orelse return error.TestUnexpectedResult;
        try std.testing.expectApproxEqAbs(burnt_to, g.sim.power.nodes[ni].fuel_or_energy, 0.01);
        try std.testing.expectEqual(@as(u8, 3), g.sim.power.nodes[ni].delay_idx);
        try std.testing.expectEqual(@as(u8, 2), g.sim.power.nodes[ni].duration_idx);
        try std.testing.expectEqual(@as(i32, 8), g.sim.power.nodes[ni].target_type);
        // Applied records are dropped, so a second scan cannot re-apply stale
        // state over what the sim has done since.
        try std.testing.expectEqual(@as(usize, 0), g.sim.power.pending_state_n);
    }
}

test "a destroyed authored light does not come back on the next TE scan" {
    // Lights are rebuilt from prefab TE data on the chunk scan, and
    // `te_scanned` is per-session. So a lamp a player destroyed cleared its
    // store entry, and the next restart re-scanned the prefab and put it
    // straight back on a cell that is now air - the chunk stream then shipped
    // a light for a block nobody can see.
    const game_dir = stock_paths.dedicated_server;
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/light_rescan", 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    // Find a chunk whose scan produces at least one light.
    var found: ?struct { cx: i32, cz: i32, x: i32, y: i32, z: i32 } = null;
    const pf = if (g.world.prefabs) |*p| p else return error.SkipZigTest;
    for (pf.items) |d| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const cx = @divFloor(d.x, 16);
        const cz = @divFloor(d.z, 16);
        const ch = g.world.getOrCreate(.{ .x = cx, .z = cz }) catch continue;
        g.ensurePrefabStorageInChunk(ch, cx, cz);
        var li: usize = 0;
        while (li < light_te_mod.max_lights) : (li += 1) {
            if (!g.light_te.used[li]) continue;
            const l = &g.light_te.items[li];
            if (@divFloor(l.x, 16) != cx or @divFloor(l.z, 16) != cz) continue;
            found = .{ .cx = cx, .cz = cz, .x = l.x, .y = l.y, .z = l.z };
            break;
        }
        if (found != null) break;
    }
    const f = found orelse return error.SkipZigTest;
    const lpos = light_te_mod.PosKey{ .x = f.x, .y = f.y, .z = f.z };
    try std.testing.expect(g.light_te.get(lpos) != null);

    // Destroy the lamp the way any removal path does, then force a re-scan
    // the way a restart does (te_scanned is runtime state).
    try g.world.setBlockWorld(f.x, f.y, f.z, 0);
    g.noteBlockRemoved(f.x, f.y, f.z, 0);
    try std.testing.expect(g.light_te.get(lpos) == null);

    const ch2 = try g.world.getOrCreate(.{ .x = f.cx, .z = f.cz });
    ch2.te_scanned = false;
    g.ensurePrefabStorageInChunk(ch2, f.cx, f.cz);
    try std.testing.expect(g.light_te.get(lpos) == null);
}

test "a mined-out prefab container does not come back on the next TE scan" {
    // Same shape as the light case: prefab containers are rebuilt from TE data
    // by the chunk scan, `te_scanned` is per-session, and the branch created
    // one even when the cell held no block (falling back to the seed-chest id).
    // So every prefab chest a player mined out returned on the next restart,
    // with a fresh loot roll. The seed chest has its own placement in
    // init_world and does not need that fallback.
    const game_dir = stock_paths.dedicated_server;
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/cont_rescan", 0, .{
        .map_dir = map,
        .game_dir = game_dir,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    // Find a chunk whose scan produces a prefab container, rather than
    // assuming a particular POI holds one.
    var found: ?struct { cx: i32, cz: i32, pos: containers_mod.PosKey } = null;
    const pf = if (g.world.prefabs) |*p| p else return error.SkipZigTest;
    for (pf.items) |d| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const cx = @divFloor(d.x, 16);
        const cz = @divFloor(d.z, 16);
        const ch = g.world.getOrCreate(.{ .x = cx, .z = cz }) catch continue;
        g.ensurePrefabStorageInChunk(ch, cx, cz);
        var ci: usize = 0;
        while (ci < containers_mod.max_containers) : (ci += 1) {
            if (!g.containers.used[ci]) continue;
            const cont = &g.containers.items[ci];
            if (cont.player_storage) continue;
            if (@divFloor(cont.pos.x, 16) != cx or @divFloor(cont.pos.z, 16) != cz) continue;
            found = .{ .cx = cx, .cz = cz, .pos = cont.pos };
            break;
        }
        if (found != null) break;
    }
    const f = found orelse return error.SkipZigTest;
    try std.testing.expect(g.containers.get(f.pos) != null);

    // Mine it out through the shared removal hook, then force the re-scan a
    // restart performs.
    try g.world.setBlockWorld(f.pos.x, f.pos.y, f.pos.z, 0);
    g.noteBlockRemoved(f.pos.x, f.pos.y, f.pos.z, 0);
    try std.testing.expect(g.containers.get(f.pos) == null);

    const ch2 = try g.world.getOrCreate(.{ .x = f.cx, .z = f.cz });
    ch2.te_scanned = false;
    g.ensurePrefabStorageInChunk(ch2, f.cx, f.cz);
    try std.testing.expect(g.containers.get(f.pos) == null);
}

test "a POI reset discards container contents instead of spilling them" {
    // Stock's reset regenerates the chunk back to its prefab state (RE
    // server-browser-prefabs.md 3.2 ResetBlocksAndRebuild), which discards
    // what was there. Once noteBlockRemoved gained the ground spill, the reset
    // inherited it and started dropping every displaced container as a bag -
    // so a player could farm a POI by re-taking the quest that resets it.
    // This covers the helper offline; "POI reset restores baked blocks over
    // player edits" covers the reset call site, but needs a stock install.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }

    const cx: i32 = 300;
    const cy: i32 = 70;
    const cz: i32 = 300;
    const seedContainer = struct {
        fn call(gm: *Game, x: i32, y: i32, z: i32) !void {
            const cont = gm.containers.getOrCreate(.{ .x = x, .y = y, .z = z }, 8, 1) orelse
                return error.TestUnexpectedResult;
            cont.slots[0] = .{ .item_id = 7, .count = 9, .quality = 1 };
        }
    }.call;

    // A reset displaces the container: the entry goes, the contents do not
    // reach the ground.
    try seedContainer(g, cx, cy, cz);
    const bags_before_reset = g.sim.countKind(.loot_bag);
    g.noteBlockRemovedEx(cx, cy, cz, 1, false);
    try std.testing.expect(g.containers.get(.{ .x = cx, .y = cy, .z = cz }) == null);
    try std.testing.expectEqual(bags_before_reset, g.sim.countKind(.loot_bag));

    // A removal at the same cell still spills, so the two are genuinely
    // different rather than the spill having been dropped everywhere.
    try seedContainer(g, cx, cy, cz);
    const bags_before_break = g.sim.countKind(.loot_bag);
    g.noteBlockRemoved(cx, cy, cz, 1);
    try std.testing.expect(g.containers.get(.{ .x = cx, .y = cy, .z = cz }) == null);
    try std.testing.expect(g.sim.countKind(.loot_bag) > bags_before_break);
}

test "queued-verb policy: a denied verb is dropped before the command buffer" {
    // Interception (paper 3.2.3 / ADR 0039): the effective per-module policy is
    // checked at the `zdtd.queue` boundary, so a denied verb never reaches the
    // ECS buffer or the host `bot` family. Operator denies add over the module's
    // own declaration and operator allows clear it (right-biased merge).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.create(std.testing.allocator, dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const wasm_host = @import("wasm_host.zig");
    g.wasm_plugins.loadAll(
        std.testing.allocator,
        &[_][]const u8{"assets/fixtures/plugin_hello.wasm"},
        &g.wasm_ctx,
        .{},
    );
    defer g.wasm_plugins.shutdown();
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.n);

    const say_bit = plugin_mod.manifest.QueueVerb.say.bit();
    // The operator list names the module by its wasm stem here (`plugin_hello`
    // for assets/fixtures/plugin_hello.wasm); applyPluginPolicy matches the
    // manifest name, the stem or the directory, and logs the effective policy.
    const deny = [_]plugin_mod.manifest.PolicyEntry{.{ .module = "plugin_hello", .mask = say_bit }};
    wasm_host.applyPluginPolicy(g, &deny, &.{});
    try std.testing.expectEqual(say_bit, g.wasm_plugins.slots[0].denied);

    const before = g.sim.commands.n;
    wasm_host.wasmQueue(&g.wasm_ctx, 1, "say denied hello");
    try std.testing.expectEqual(before, g.sim.commands.n);
    try std.testing.expectEqual(@as(u64, 1), g.harness.counters.get(.plugin_verbs_denied));

    // A verb the policy allows still reaches the buffer.
    wasm_host.wasmQueue(&g.wasm_ctx, 1, "spawn 1 2 3 10");
    try std.testing.expectEqual(before + 1, g.sim.commands.n);

    // Native source 0 is not a policy subject.
    wasm_host.wasmQueue(&g.wasm_ctx, 0, "say native hello");
    try std.testing.expectEqual(before + 2, g.sim.commands.n);

    // Operator allow clears the module's own deny.
    g.wasm_plugins.slots[0].op_allow = say_bit;
    g.wasm_plugins.slots[0].refreshDenied();
    wasm_host.wasmQueue(&g.wasm_ctx, 1, "say allowed hello");
    try std.testing.expectEqual(before + 3, g.sim.commands.n);
    try std.testing.expectEqual(@as(u64, 1), g.harness.counters.get(.plugin_verbs_denied));

    // `spawn` also covers `bot spawn` (review F10): both create an entity, so
    // a policy that forbids entity creation cannot be bypassed through the bot
    // family. Other bot sub-verbs stay behind the `bot` verb alone.
    const spawn_bit = plugin_mod.manifest.QueueVerb.spawn.bit();
    g.wasm_plugins.slots[0].op_allow = 0;
    g.wasm_plugins.slots[0].module_deny = spawn_bit;
    g.wasm_plugins.slots[0].refreshDenied();
    const bots_before = g.bots.n;
    wasm_host.wasmQueue(&g.wasm_ctx, 1, "bot spawn 5 5");
    try std.testing.expectEqual(@as(u64, 2), g.harness.counters.get(.plugin_verbs_denied));
    try std.testing.expectEqual(bots_before, g.bots.n);
    wasm_host.wasmQueue(&g.wasm_ctx, 1, "bot count");
    try std.testing.expectEqual(@as(u64, 2), g.harness.counters.get(.plugin_verbs_denied));
}

test "starter_zombies gates the near-spawn demo hostiles" {
    // `[sim] starter_zombies`: the demo seeds (2 zombies + sleeper + animal)
    // are a zdtd convenience; stock spawns them lazily through the AIDirector
    // (docs/DIVERGENCES.md). The switch must leave the world genuinely empty
    // when off and keep the demo world populated when on (default).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const off_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "off" });
    defer std.testing.allocator.free(off_dir);
    io_fs.mkdirPath(off_dir);
    const g_off = try Game.createWithOptions(std.testing.allocator, off_dir, 0, .{ .starter_zombies = false });
    defer {
        g_off.deinit();
        std.testing.allocator.destroy(g_off);
    }
    try std.testing.expectEqual(@as(u32, 0), g_off.sim.countKind(.zombie));
    try std.testing.expectEqual(@as(u32, 0), g_off.sim.countKind(.animal));

    const on_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "on" });
    defer std.testing.allocator.free(on_dir);
    io_fs.mkdirPath(on_dir);
    const g_on = try Game.create(std.testing.allocator, on_dir, 0);
    defer {
        g_on.deinit();
        std.testing.allocator.destroy(g_on);
    }
    try std.testing.expectEqual(@as(u32, 3), g_on.sim.countKind(.zombie));
    try std.testing.expectEqual(@as(u32, 1), g_on.sim.countKind(.animal));

    // `[sim] demo_seed = false` takes the whole near-spawn demo set with it:
    // the trader, the minibike, the seed chest and the demo turret, not just
    // the hostiles. docs/DIVERGENCES.md 6.2 documents the pair.
    const none_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "none" });
    defer std.testing.allocator.free(none_dir);
    io_fs.mkdirPath(none_dir);
    const g_none = try Game.createWithOptions(std.testing.allocator, none_dir, 0, .{ .demo_seed = false });
    defer {
        g_none.deinit();
        std.testing.allocator.destroy(g_none);
    }
    try std.testing.expectEqual(@as(u32, 0), g_none.sim.countKind(.zombie));
    try std.testing.expectEqual(@as(u32, 0), g_none.sim.countKind(.animal));
    try std.testing.expectEqual(@as(u32, 0), g_none.sim.countKind(.trader));
    try std.testing.expectEqual(@as(u32, 0), g_none.sim.countKind(.vehicle));
    try std.testing.expectEqual(@as(u32, 0), g_none.sim.countKind(.turret));
    // The default world seeds all four kinds, so the switch is not vacuous.
    try std.testing.expect(g_on.sim.countKind(.trader) > 0);
    try std.testing.expect(g_on.sim.countKind(.vehicle) > 0);
    try std.testing.expect(g_on.sim.countKind(.turret) > 0);
}

test "spawn_starter_kit config replaces the built-in kit and fails closed" {
    // `[sim] spawn_starter_kit` is server policy (ADR 0010): stock defines its
    // kit in code, so zdtd makes it config. A configured spec resolves names
    // through items.xml, omits unknown names, and clamps counts to
    // Stacknumber; an absent spec keeps the historical four-row default.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    const kit_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "kit" });
    defer std.testing.allocator.free(kit_dir);
    io_fs.mkdirPath(kit_dir);
    const g = try Game.createWithOptions(std.testing.allocator, kit_dir, 0, .{
        .spawn_starter_kit = " foodCanBeef:2 , noSuchItem:3, resourceWood:9999 ",
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const beef = g.items.ecsIdByName("foodCanBeef");
    const wood = g.items.ecsIdByName("resourceWood");
    const coin = g.items.ecsIdByName("casinoCoin");
    try std.testing.expect(beef != 0 and wood != 0 and coin != 0);
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expectEqual(@as(u32, 2), g.sim.inventory[ps].countItem(beef));
    // The unknown row is omitted rather than falling back to the default kit.
    try std.testing.expectEqual(@as(u32, 0), g.sim.inventory[ps].countItem(coin));
    const wood_n = g.sim.inventory[ps].countItem(wood);
    try std.testing.expect(wood_n > 0);
    try std.testing.expect(wood_n <= @as(u32, g.sim.maxStack(wood)));

    const def_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "default" });
    defer std.testing.allocator.free(def_dir);
    io_fs.mkdirPath(def_dir);
    const g2 = try Game.create(std.testing.allocator, def_dir, 0);
    defer {
        g2.deinit();
        std.testing.allocator.destroy(g2);
    }
    var cap2: ln_peer.Capture = .{};
    const cl2 = try g2.attachJoinedClient(&cap2);
    const ps2 = g2.sim.playerByPeer(cl2.slot).?;
    try std.testing.expectEqual(@as(u32, 5), g2.sim.inventory[ps2].countItem(beef));
    try std.testing.expectEqual(@as(u32, 50), g2.sim.inventory[ps2].countItem(coin));
}

test "loot prob passives scale tagged entries (stock perkDeadEye)" {
    // progression.xml's perkDeadEye carries
    // `<passive_effect name="LootProb" operation="perc_add" level="1,5"
    // value="2,10" tags="rifleSkill"/>` and the same for `ammo762mm`. The loot
    // fold answers a tagged entry's probabilty from the opener's purchased
    // perk rows, so a Dead Eye 5 player sees +10% on rifle-tagged loot and an
    // unrelated tag is untouched.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .game_dir = game_dir,
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot).?;
    // Fresh character: every tag folds to the base.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.lootProbScale(cl.slot, ps, "ammo762mm", 0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.lootProbScale(cl.slot, ps, "shotgunSkill", 0.5), 1e-4);

    // Dead Eye 5: `perc_add 10` on the rifle/ammo762mm rows.
    try std.testing.expect(g.addProgressionLevel(cl.slot, "perkDeadEye", 5));
    const rifle = g.lootProbScale(cl.slot, ps, "ammo762mm", 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), rifle, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), g.lootProbScale(cl.slot, ps, "rifleSkill", 0.5), 1e-3);
    // An untagged query never sees a tagged row.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.lootProbScale(cl.slot, ps, "shotgunSkill", 0.5), 1e-4);

    // Equipped-item rows fold at their quality tier: armorFarmerHelmet carries
    // `LootProb perc_add 2,4,6,8,10,20 tier=1..6 tags="seedSkill"`.
    const helmet = g.items.ecsIdByName("armorFarmerHelmet");
    if (helmet != 0) {
        const esi: usize = @import("../../ecs/components.zig").inv_equip_start;
        g.sim.inventory[ps].slots[esi] = .{ .item_id = helmet, .count = 1, .quality = 6 };
        try std.testing.expectApproxEqAbs(@as(f32, 0.6), g.lootProbScale(cl.slot, ps, "seedSkill", 0.5), 1e-3);
        g.sim.inventory[ps].slots[esi].quality = 1;
        try std.testing.expectApproxEqAbs(@as(f32, 0.51), g.lootProbScale(cl.slot, ps, "seedSkill", 0.5), 1e-3);
        // An unrelated query still ignores the helmet row (shotgunSkill has no
        // LootProb row on any worn item or purchased perk here).
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.lootProbScale(cl.slot, ps, "shotgunSkill", 0.5), 1e-3);
        g.sim.inventory[ps].slots[esi] = .{};
    }
}

test "loot entry mods install on the spawned gun" {
    // Stock `ItemValue.createDefaultModItems` (IL=759): a looted item's `mods=`
    // list names slot tags (`barrelAttachments`) or contributed tags (`scope`);
    // each resolves to a fitting modifier, installs when the roll passes
    // `mod_chance`, and halves the chance after every install. The 5 stock gun
    // entries use 0.5 / 1. The modifiers are item classes in the same id space
    // as items.xml (`ItemTable.addItemClasses`), so the installed id resolves
    // back to the modifier catalog and encodes on the wire.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .game_dir = game_dir,
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const pistol = g.items.ecsIdByName("gunHandgunT1Pistol");
    const sniper = g.items.ecsIdByName("gunRifleT3SniperRifle");
    if (pistol == 0 or sniper == 0) return error.SkipZigTest;
    // The modifier rows are item classes: their ECS id resolves and maps to an
    // absolute stock type past ItemsStartHere (the client's item id space).
    const barrel_mod = g.items.ecsIdByName("modGunBarrelExtender");
    try std.testing.expect(barrel_mod != 0);
    try std.testing.expect(g.items.stockTypeFor(barrel_mod) > @import("../../assets/items.zig").items_start_here);
    g.loot.deinit();
    g.loot = try @import("../../assets/loot.zig").loadFromSlice(std.testing.allocator,
        \\<lootgroups>
        \\<lootgroup name="gunCrate" count="all">
        \\  <item name="gunHandgunT1Pistol" mods="barrelAttachments" mod_chance="1"/>
        \\  <item name="gunRifleT3SniperRifle" mods="scope" mod_chance="1"/>
        \\  <item name="gunHandgunT1Pistol" mods="barrelAttachments" mod_chance="0"/>
        \\</lootgroup>
        \\</lootgroups>
    );
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const cont = g.containers.getOrCreate(.{ .x = 7, .y = 70, .z = 7 }, 8, 0).?;
    cont.player_storage = false;
    cont.loot_list = "gunCrate";
    cont.touched = false;
    g.ensureContainerLoot(cont, cl.slot);

    const ModTable = @import("../../assets/item_modifiers.zig").ModTable;
    // 1) The barrel-tag row installed a fitting barrel mod.
    try std.testing.expectEqual(pistol, cont.slots[0].item_id);
    try std.testing.expect(cont.slots[0].mod_n >= 1);
    const bar_def = g.items.byId(cont.slots[0].mods[0]).?;
    const bar_m = g.item_mods.byName(bar_def.name).?;
    try std.testing.expect(ModTable.tagListContains(bar_m.installable, "barrelAttachments") or
        ModTable.tagListContains(bar_m.modifier, "barrelAttachments"));
    // 2) The `scope` tag matches a mod's contributed tags.
    try std.testing.expectEqual(sniper, cont.slots[1].item_id);
    try std.testing.expect(cont.slots[1].mod_n >= 1);
    const sc_def = g.items.byId(cont.slots[1].mods[0]).?;
    const sc_m = g.item_mods.byName(sc_def.name).?;
    try std.testing.expect(ModTable.tagListContains(sc_m.modifier, "scope") or
        ModTable.tagListContains(sc_m.installable, "scope"));
    // 3) mod_chance 0 installs nothing.
    try std.testing.expectEqual(pistol, cont.slots[2].item_id);
    try std.testing.expectEqual(@as(u8, 0), cont.slots[2].mod_n);
}

test "loot bag fill carries the rolled quality, stackables stay quality 1" {
    // A death/airdrop bag is a stock LootContainer roll, so the rolled quality
    // (and random-durability wear) belongs on the deposited stack; a stackable
    // keeps quality 1 like every other deposit path.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .game_dir = game_dir,
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const axe = g.items.ecsIdByName("meleeToolRepairT0StoneAxe");
    const coin = g.items.ecsIdByName("casinoCoin");
    if (axe == 0 or coin == 0) return error.SkipZigTest;
    // The quality gate is HasQuality, not stack size: the axe has quality with
    // Stacknumber 500, the coin is a stackable without quality.
    if (!g.items.byId(axe).?.has_quality or g.items.byId(coin).?.has_quality) return error.SkipZigTest;
    g.loot.deinit();
    g.loot = try @import("../../assets/loot.zig").loadFromSlice(std.testing.allocator,
        \\<lootgroups>
        \\<lootgroup name="bagGroup" count="all">
        \\  <item name="meleeToolRepairT0StoneAxe" quality="6"/>
        \\  <item name="casinoCoin" count="5" quality="3"/>
        \\</lootgroup>
        \\</lootgroups>
    );
    const bag = g.sim.spawnLootBag(1, 70, 1, coin, 1).?;
    g.fillLootBagFromTable(bag, "bagGroup", 7, 1);
    const bs = g.sim.slotOfNetId(bag).?;
    var saw_axe = false;
    var saw_coin = false;
    for (g.sim.inventory[bs].slots) |sl| {
        if (sl.item_id == axe) {
            try std.testing.expectEqual(@as(u8, 6), sl.quality);
            saw_axe = true;
        }
        if (sl.item_id == coin and sl.count > 1) {
            try std.testing.expectEqual(@as(u8, 1), sl.quality);
            saw_coin = true;
        }
    }
    try std.testing.expect(saw_axe and saw_coin);
}

test "container loot starts a random-durability item worn" {
    // Stock LootContainer: when `random_durability="true"` and the item has a
    // MaxUseTimes, UseTimes = (int)(max * RandomRange(0.2, 0.8)); otherwise 0.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .game_dir = game_dir,
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const axe = g.items.ecsIdByName("meleeToolRepairT0StoneAxe");
    if (axe == 0) return error.SkipZigTest;
    const max_use = g.itemMaxUseTimes(axe, 1);
    if (max_use == 0) return error.SkipZigTest;
    g.loot.deinit();
    g.loot = try @import("../../assets/loot.zig").loadFromSlice(std.testing.allocator,
        \\<lootgroups>
        \\<lootgroup name="duraCrate" count="all">
        \\  <item name="meleeToolRepairT0StoneAxe" random_durability="true"/>
        \\  <item name="meleeToolRepairT0StoneAxe" random_durability="false"/>
        \\  <item name="meleeToolRepairT0StoneAxe" quality="6"/>
        \\</lootgroup>
        \\</lootgroups>
    );
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const cont = g.containers.getOrCreate(.{ .x = 6, .y = 70, .z = 6 }, 8, 0).?;
    cont.player_storage = false;
    cont.loot_list = "duraCrate";
    cont.touched = false;
    g.ensureContainerLoot(cont, cl.slot);
    try std.testing.expect(cont.slots[0].item_id == axe and cont.slots[1].item_id == axe);
    const lo: f32 = @as(f32, @floatFromInt(max_use)) * 0.15; // truncation margin
    const hi: f32 = @as(f32, @floatFromInt(max_use)) * 0.85;
    try std.testing.expect(cont.slots[0].use_times >= lo and cont.slots[0].use_times <= hi);
    try std.testing.expectEqual(@as(f32, 0), cont.slots[1].use_times);
    // A tool carries quality despite Stacknumber 500 (`ItemClass.HasQuality`),
    // which the old `stack == 1` heuristic dropped.
    try std.testing.expectEqual(@as(u8, 6), cont.slots[2].quality);
}

test "container loot applies entry buffs to the opener" {
    // Stock collects a spawned entry's `buffs=` during the roll and applies the
    // list to the opener after it (LootContainer.ExecuteBuffActions ->
    // Buffs.AddBuff). The fill path routes the entry's list through a sink into
    // the catalog add, which is what makes a bookworm success chime reach the
    // client. An unknown name fails closed (stock ships one typo'd row).
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .game_dir = game_dir,
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    const buff_id = g.buffs.indexOfName("buffPerkBookwormSuccess") orelse return error.SkipZigTest;
    g.loot.deinit();
    g.loot = try @import("../../assets/loot.zig").loadFromSlice(std.testing.allocator,
        \\<lootgroups>
        \\<lootgroup name="buffCrate" count="all">
        \\  <item name="foodCanBeef" buffs="buffPerkBookwormSuccess"/>
        \\  <item name="resourceWood" buffs="noSuchBuffAtAll"/>
        \\</lootgroup>
        \\</lootgroups>
    );
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot).?;
    try std.testing.expect(g.sim.buffs[ps].find(buff_id) == null);

    const cont = g.containers.getOrCreate(.{ .x = 5, .y = 70, .z = 5 }, 8, 0).?;
    cont.player_storage = false;
    cont.loot_list = "buffCrate";
    cont.touched = false;
    g.ensureContainerLoot(cont, cl.slot);
    // The known buff landed; the typo'd name resolves to no catalog row, so the
    // sink's add failed closed and nothing was added for it.
    try std.testing.expect(g.sim.buffs[ps].find(buff_id) != null);
    try std.testing.expect(g.buffs.indexOfName("noSuchBuffAtAll") == null);
}

test "progression update rows write $perkBookwormChance (stock data)" {
    // The other half of the loot RandomRoll gates: progression.xml's
    // `perkIntellectMastery` rows fire on `onSelfProgressionUpdate` and set
    // `$perkBookwormChance` to 25 at level >= 2, 0 at <= 1. The purchase and
    // add level paths both run them, so the cvar tracks the perk.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .game_dir = game_dir,
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    // Fresh character: no cvar, so the 63 loot RandomRoll rows read 0.
    try std.testing.expectEqual(@as(f32, 0), cl.cvars.get("$perkBookwormChance"));

    // Reaching Intellect Mastery 2 sets the chance to 25.
    try std.testing.expect(g.addProgressionLevel(cl.slot, "perkIntellectMastery", 2));
    try std.testing.expectEqual(@as(f32, 25), cl.cvars.get("$perkBookwormChance"));

    // The second row clears it at level <= 1. Purchases only ever go one level
    // up (skillCostOf refuses a downgrade), so prove it on a second character
    // buying level 1 from scratch: the row fires with level 1 and writes 0.
    var cap2: ln_peer.Capture = .{};
    const cl2 = try g.attachJoinedClient(&cap2);
    cl2.skill_points = 100;
    // The stock purchase gate: perk level 1 needs attIntellect >= 6 (level 3
    // needs 8, so set 8 to allow buying up for the flag assertion below).
    cl2.skill_levels[0] = .{ .name = "attIntellect", .level = 8 };
    cl2.skill_level_n = 1;
    try std.testing.expect(g.purchaseSkill(cl2.slot, "perkIntellectMastery", 1));
    try std.testing.expectEqual(@as(f32, 0), cl2.cvars.get("$perkBookwormChance"));
    // The purchase also fires `onPerkLevelChanged`: the point-chance flag
    // needs Intellect Mastery 3, so level 1 leaves it unset...
    try std.testing.expectEqual(@as(f32, 0), cl2.cvars.get("$pointChanceFlag"));
    // ...and buying up to 3 runs the one-shot latch (flag 1, chances,
    // flag +1): the flag ends at 2 and the point chance at 50.
    try std.testing.expect(g.purchaseSkill(cl2.slot, "perkIntellectMastery", 2));
    try std.testing.expect(g.purchaseSkill(cl2.slot, "perkIntellectMastery", 3));
    try std.testing.expectEqual(@as(f32, 2), cl2.cvars.get("$pointChanceFlag"));
    try std.testing.expectEqual(@as(f32, 50), cl2.cvars.get("$perkIntellectMasteryPointChance"));
}

test "loot requirement gates read the opener's progression on the fill path" {
    // Deterministic synthetic table (no game dir): a Progression-gated entry
    // must roll only when the fill path can build the opener's requirements.Ctx
    // from their ledger. `casinoCoin` resolves through the offline builtin map,
    // so the assertion is about the gate, not the catalog.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .starter_zombies = false,
        .demo_seed = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    // Swap the (empty, offline) loot table for a synthetic one.
    g.loot.deinit();
    g.loot = try @import("../../assets/loot.zig").loadFromSlice(std.testing.allocator,
        \\<lootgroups>
        \\<lootgroup name="gateGroup" count="all">
        \\  <item name="foodCanBeef"/>
        \\  <item name="casinoCoin" count="10">
        \\    <requirement class="Progression" name="perkTreasureHunter" operation="GTE" value="4"/>
        \\  </item>
        \\  <item name="resourceWood">
        \\    <requirement class="SandboxOption" option="HarvestingOutput" operation="EQ" value="0"/>
        \\  </item>
        \\</lootgroup>
        \\</lootgroups>
    );
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const coin = g.items.ecsIdByName("casinoCoin");
    try std.testing.expect(coin != 0);
    const Count = struct {
        fn of(cont: *const @TypeOf(g.containers.items[0]), id: u16) u32 {
            var n: u32 = 0;
            for (cont.slots[0..cont.slot_count]) |sl| {
                if (sl.item_id == id) n += sl.count;
            }
            return n;
        }
    };

    // Unqualified: the gated row is omitted, the ungated one still rolls, so a
    // zero result cannot pass by having rolled nothing at all.
    cl.skill_levels[0] = .{ .name = "perkTreasureHunter", .level = 3 };
    cl.skill_level_n = 1;
    const a = g.containers.getOrCreate(.{ .x = 1, .y = 70, .z = 1 }, 8, 0).?;
    a.player_storage = false;
    a.loot_list = "gateGroup";
    a.touched = false;
    g.ensureContainerLoot(a, cl.slot);
    try std.testing.expectEqual(@as(u32, 0), Count.of(a, coin));
    var saw_food = false;
    for (a.slots[0..a.slot_count]) |sl| {
        if (sl.item_id != 0) saw_food = true;
    }
    try std.testing.expect(saw_food);

    // Qualified (GTE 4 is inclusive): the gated row rolls.
    cl.skill_levels[0] = .{ .name = "perkTreasureHunter", .level = 4 };
    const b = g.containers.getOrCreate(.{ .x = 2, .y = 70, .z = 1 }, 8, 0).?;
    b.player_storage = false;
    b.loot_list = "gateGroup";
    b.touched = false;
    g.ensureContainerLoot(b, cl.slot);
    try std.testing.expect(Count.of(b, coin) > 0);

    // No opener: the gate cannot be answered, so it refuses.
    const c = g.containers.getOrCreate(.{ .x = 3, .y = 70, .z = 1 }, 8, 0).?;
    c.player_storage = false;
    c.loot_list = "gateGroup";
    c.touched = false;
    g.fillContainerFromLoot(c, "gateGroup", 7, 1, -1);
    try std.testing.expectEqual(@as(u32, 0), Count.of(c, coin));

    // A SandboxOption gate reads the server's decoded sandbox code. Default
    // code: HarvestingOutput is 1.0, so the `EQ 0` row stays out. `ADYA` sets
    // option 102 (HarvestingOutput) to value index 0 = 0.0, so it rolls.
    const wood = g.items.ecsIdByName("resourceWood");
    try std.testing.expect(wood != 0);
    const CountOne = struct {
        fn of(cont: *const @TypeOf(g.containers.items[0]), id: u16) u32 {
            var n: u32 = 0;
            for (cont.slots[0..cont.slot_count]) |sl| {
                if (sl.item_id == id) n += sl.count;
            }
            return n;
        }
    };
    try std.testing.expectEqual(@as(u32, 0), CountOne.of(a, wood));
    g.sandbox_code = "ADYA";
    const d = g.containers.getOrCreate(.{ .x = 4, .y = 70, .z = 1 }, 8, 0).?;
    d.player_storage = false;
    d.loot_list = "gateGroup";
    d.touched = false;
    g.ensureContainerLoot(d, cl.slot);
    try std.testing.expect(CountOne.of(d, wood) > 0);
}

test "equipped item mods fold their passives (layer 13, stock data)" {
    // EffectManager.GetValue layer 13 applies a modifier item's effect rows
    // alongside the item's own. Before this only the attachment tags were
    // parsed, so a modded armour piece defended no better than a bare one:
    // modArmorInsulatedLiner's `ElementalDamageResist +1 tags=heat,electrical`
    // and modRadiationReady's `+50% tags=radiation` did nothing server-side.
    const game_dir = stock_paths.dedicated_server;
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(cl.slot) orelse return error.TestUnexpectedResult;

    const helmet = g.items.byName("armorPrimitiveHelmet") orelse return error.SkipZigTest;
    try std.testing.expect(ecs.inventory.give(&g.sim, cl.slot, helmet.id, 1));
    var from: u16 = 0;
    for (g.sim.inventory[ps].slots, 0..) |s, i| {
        if (s.item_id == helmet.id) {
            from = @intCast(i);
            break;
        }
    }
    g.sim.inventory[ps].slots[from].quality = 6;
    try std.testing.expect(ecs.inventory.equip(&g.sim, cl.slot, from, 0));
    const eq: usize = ecs.components.inv_equip_start;

    const heat_before = g.elementalDamageResist(ps, "heat");
    try std.testing.expect(heat_before > 0.08); // the helmet's own 8..12.3 curve
    try std.testing.expect(g.elementalDamageResist(ps, "radiation") < 0.01);

    // The insulated liner's flat +1 heat/electrical joins the same tagged fold.
    const liner = g.items.ecsIdByName("modArmorInsulatedLiner");
    if (liner == 0) return error.SkipZigTest;
    g.sim.inventory[ps].slots[eq].mods[0] = liner;
    g.sim.inventory[ps].slots[eq].mod_n = 1;
    try std.testing.expectApproxEqAbs(heat_before + 0.01, g.elementalDamageResist(ps, "heat"), 0.005);
    try std.testing.expect(g.elementalDamageResist(ps, "cold") < 0.02); // tag-scoped

    // Radiation Ready is a percentage row, still scoped to its own tag.
    const rad = g.items.ecsIdByName("modRadiationReady");
    if (rad == 0) return error.SkipZigTest;
    g.sim.inventory[ps].slots[eq].mods[1] = rad;
    g.sim.inventory[ps].slots[eq].mod_n = 2;
    try std.testing.expect(g.elementalDamageResist(ps, "radiation") > 0.4);
    try std.testing.expect(g.elementalDamageResist(ps, "heat") < heat_before + 0.02);

    // Removing the mods drops their rows on the next read (no sticky state).
    g.sim.inventory[ps].slots[eq].mods = .{0} ** 4;
    g.sim.inventory[ps].slots[eq].mod_n = 0;
    try std.testing.expectApproxEqAbs(heat_before, g.elementalDamageResist(ps, "heat"), 0.005);

    // A plating mod's PhysicalDamageResist joins the armour rating through the
    // survival tick's column (stock GetTotalPhysicalArmorRating walks the worn
    // items' effect layers), while the same mod on the *held* item does not:
    // the holding slot is not armour.
    try g.step();
    const pdr_before = ecs.inventory.armorMitigation(&g.sim, cl.slot);
    const plate = g.items.ecsIdByName("modArmorPlatingBasic");
    if (plate == 0) return error.SkipZigTest;
    g.sim.inventory[ps].slots[eq].mods[0] = plate;
    g.sim.inventory[ps].slots[eq].mod_n = 1;
    try g.step();
    try std.testing.expectApproxEqAbs(pdr_before + 0.01, ecs.inventory.armorMitigation(&g.sim, cl.slot), 0.002);

    g.sim.inventory[ps].slots[eq].mods = .{0} ** 4;
    g.sim.inventory[ps].slots[eq].mod_n = 0;
    const held_slot = g.sim.inventory[ps].holding;
    if (held_slot < ecs.components.inv_toolbelt) {
        g.sim.inventory[ps].slots[held_slot].item_id = helmet.id;
        g.sim.inventory[ps].slots[held_slot].count = 1;
        g.sim.inventory[ps].slots[held_slot].mods[0] = plate;
        g.sim.inventory[ps].slots[held_slot].mod_n = 1;
        try g.step();
        try std.testing.expectApproxEqAbs(pdr_before, ecs.inventory.armorMitigation(&g.sim, cl.slot), 0.002);
    }
}
