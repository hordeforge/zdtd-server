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
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const game_hooks = @import("../game/hooks.zig");
const clock = @import("../../util/clock.zig");
const util_sim = @import("../../util/sim.zig");
const wire_frame = @import("../../wire/frame.zig");
const assets_biome_layers = @import("../../assets/biome_layers.zig");
const sleepers_mod = @import("../../world/sleepers.zig");
const replicate_te = @import("../replicate_te.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const assets_entitygroups = @import("../../assets/entitygroups.zig");
const assets_traders = @import("../../assets/traders.zig");
const assets_npc = @import("../../assets/npc.zig");
const jobs = @import("../../ecs/jobs.zig");
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
    buf[o] = 3; // name_len "Bot"
    o += 1;
    @memcpy(buf[o..][0..3], "Bot");
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
        try std.testing.expectEqualStrings("ZPVA", data[0..4]);
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
        // Migrated hp = full: the player is alive and at the full-health mark
        // the pre-ZPV8 code granted on relog.
        try std.testing.expect(g.sim.alive[ps]);
        // Migrated hp = -1 sentinel: the restore keeps the spawn path's full
        // health (the pre-ZPV8 relog behavior), and the tail values land.
        try std.testing.expectEqual(g.sim.health[ps].max_hp, g.sim.health[ps].hp);
        try std.testing.expectEqual(@as(u16, 5), cl.level);
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
    buf[o] = 3; // name_len "Bot"
    o += 1;
    @memcpy(buf[o..][0..3], "Bot");
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
        try std.testing.expectEqualStrings("ZPVA", data[0..4]);
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
        try std.testing.expectEqual(@as(u16, 5), cl.level);
        // The v8 hp rides through the migration (0.4 > 0, applied).
        try std.testing.expectEqual(@as(f32, 0.4), g.sim.health[ps].hp);
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
    buf[o] = 3; // name_len "Bot"
    o += 1;
    @memcpy(buf[o..][0..3], "Bot");
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
    std.mem.writeInt(u32, buf[o..][0..4], @bitCast(@as(f32, 10.0)), .little); // use_times
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
        try std.testing.expectEqualStrings("ZPVA", data[0..4]);
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
        var found = false;
        for (g.sim.inventory[ps].slots) |s| {
            if (s.item_id == 7 and s.count == 3 and s.quality == 4 and s.meta == 5) found = true;
        }
        try std.testing.expect(found);
        try std.testing.expectEqual(@as(u16, 5), cl.level);
        // The v7 use_times rides through (10.0).
        var ut: f32 = 0;
        for (g.sim.inventory[ps].slots) |s| {
            if (s.item_id == 7) ut = s.use_times;
        }
        try std.testing.expectEqual(@as(f32, 10.0), ut);
        std.debug.print("PASS zpv7->zpv9: inventory + tail carried with hp/born inserted\n", .{});
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
    buf[o] = 3; // name_len "Bot"
    o += 1;
    @memcpy(buf[o..][0..3], "Bot");
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
        const cl = try g.attachJoinedClient(&capture);
        const ps = g.sim.playerByPeer(cl.slot).?;
        // Restored from the v6 record: item 7, count 3, quality 4, meta 5.
        var found = false;
        for (&g.sim.inventory[ps].slots) |*s| {
            if (s.item_id == 7 and s.count == 3 and s.quality == 4 and s.meta == 5) found = true;
        }
        try std.testing.expect(found);
        try g.savePlayers();
    }
    {
        const data = try io_fs.readFileAll(std.testing.allocator, zsv);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualStrings("ZPVA", data[0..4]);
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
        var found = false;
        for (&g.sim.inventory[ps].slots) |*s| {
            if (s.item_id == 7 and s.count == 3 and s.quality == 4 and s.meta == 5) found = true;
        }
        try std.testing.expect(found);
        std.debug.print("PASS zpv6->zpv7: legacy 7-byte inventory slots widened on save\n", .{});
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
        g.sim.inventory[ps].slots[3] = .{ .item_id = 9, .count = 7, .quality = 5, .meta = 1 };
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
        try std.testing.expectEqual(@as(u16, 9), g.sim.inventory[ps].slots[3].item_id);
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
    buf[o] = 3; // name_len "Bot"
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
        try std.testing.expectEqualStrings("ZPVA", data[0..4]);
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
    // Breaking a non-keystone block does not remove the claim.
    g.removeClaimAt(249, 70, 250);
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // Breaking the keystone removes it (claim disappears with its block).
    g.removeClaimAt(250, 70, 250);
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
    // Expiry: an offline claim past the window is released on the day roll.
    g.registerClaim(250, 70, 250, cl.entity_id);
    g.markClaimsForEntity(cl.entity_id, false);
    g.land_claims[0].owner_seen_day = g.sim.director.clock.day - 10;
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
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
    try std.testing.expectEqual(@as(u32, 1), g.dropClaimsForName(owner[0..on]));
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
        .{ .webui_port = 1, .enable_sample_plugin = false },
    ));
    try std.testing.expect(!util_sim.isEnabled());
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
            .enable_sample_plugin = false,
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
            .enable_sample_plugin = false,
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
            .enable_sample_plugin = false,
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
            .enable_sample_plugin = false,
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

test "ban expiry under virtual wall is seed-stable" {
    // Offline Game enables the virtual clock: wallSeconds must not sample host
    // REALTIME or ban add/expire cannot replay from a seed.
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/dst_ban_wall", 0, .{
        .enable_sample_plugin = false,
    });
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
        const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
            .enable_sample_plugin = false,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        // Day 5, 12:30 — deinit saves clock.zcl.
        g.sim.director.clock.day = 5;
        g.sim.director.clock.hours = 12.5;
    }
    {
        const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
            .enable_sample_plugin = false,
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expectEqual(@as(u32, 5), g.sim.director.clock.day);
        try std.testing.expectApproxEqAbs(@as(f32, 12.5), g.sim.director.clock.hours, 0.001);
    }
}

test "setgamepref applies runtime GameStats prefs and broadcasts" {
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const dir = ".zdtd_cfg_cache/pref_set_test";
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{
        .enable_sample_plugin = false,
    });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const gs_id = packages.idOf("NetPackageGameStats").?;
    try std.testing.expectEqual(@as(u8, 2), g.sim.director.difficulty);

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
    jobs.forSlotRange(vols.len, par, Game.SleeperScanCtx.work);

    try std.testing.expectEqualSlices(u8, serial[0..], batched[0..]);
    try std.testing.expectEqual(@as(u8, 1), serial[0]);
    // Already triggered: never re-tested, never re-spawned.
    try std.testing.expectEqual(@as(u8, 0), serial[3]);
    try std.testing.expectEqual(@as(u8, 1), serial[10]);
}

test "path step hook sees walls and terrain, and the snapshot agrees" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/terrain_snap", 0, .{
        .enable_sample_plugin = false,
    });
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

test "deco burst is biome driven and mirrors into the block store" {
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/deco_biome", 0, .{
        .enable_sample_plugin = false,
    });
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
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/path_terrain", 0, .{
        .enable_sample_plugin = false,
    });
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
        .enable_sample_plugin = false,
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
    const g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/power_visuals", 0, .{
        .enable_sample_plugin = false,
    });
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
    try std.testing.expectEqual(world_store.block_stone, @as(u16, @truncate(raw & 0xffff)));
    try std.testing.expectEqual(
        packages.block_meta_on | packages.block_meta_powered,
        packages.blockMeta(raw),
    );

    // Nothing flipped: the second pass must not touch the block or emit a packet.
    g.clearBlockRaw(8, 70, 8);
    replicate_te.broadcastPowerVisuals(g);
    try std.testing.expectEqual(@as(u32, 0), g.blockRawAt(8, 70, 8));

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
    // Pin the game-hour length so one tickSurvival(30.0) call is exactly one
    // in-game hour regardless of the default day-length config.
    g.sim.director.clock.seconds_per_hour = 30;
    g.sim.health[ps].food = 100;
    g.sim.health[ps].water = 100;
    g.sim.health[ps].hp = 100;
    const st_id = packages.idOf("NetPackageEntityStatChanged").?;

    // One in-game hour (default seconds_per_hour = 30): food -2, water -2.5.
    cap.clear();
    g.tickSurvival(30.0);
    try std.testing.expect(g.sim.health[ps].food < 100);
    try std.testing.expect(g.sim.health[ps].water < 100);
    try std.testing.expect(cap.findPkgId(st_id) != null); // S2C sync fired

    // Starvation: exhausted food drains hp (12/game-hour).
    g.sim.health[ps].food = 0;
    g.sim.health[ps].water = 100;
    const hp_before = g.sim.health[ps].hp;
    g.tickSurvival(30.0);
    try std.testing.expect(g.sim.health[ps].hp < hp_before);

    // Well-fed regen: fed + hydrated restores hp (10/game-hour), capped.
    g.sim.health[ps].hp = 50;
    g.sim.health[ps].food = 90;
    g.sim.health[ps].water = 90;
    g.tickSurvival(30.0);
    try std.testing.expect(g.sim.health[ps].hp > 50);
    try std.testing.expect(g.sim.health[ps].hp <= g.sim.health[ps].max_hp);

    // Clamp at zero: depletion never goes negative.
    g.sim.health[ps].food = 0.5;
    g.sim.health[ps].water = 0.5;
    g.tickSurvival(30.0);
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
    try std.testing.expect(g.sim.power.indexOfPosition(8, 70, 8) != null);
    try std.testing.expect(g.sim.power.indexOfPosition(10, 70, 8) != null);
}

test "trader POIs spawn their NPC classes on a stock map" {
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
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
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    const map = game_dir ++ "/Data/Worlds/Navezgane";
    if (!io_fs.dirExists(map)) return error.SkipZigTest;
    io_fs.mkdirPath(".zdtd_cfg_cache");
    var g = try Game.createWithOptions(std.testing.allocator, ".zdtd_cfg_cache/poi_reset", 0, .{
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
}

test "biome spawn groups resolve per-biome spawning.xml rules on a stock map" {
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
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
    const traders_path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    const npc_path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/npc.xml";
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
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    try w.writeF32(1);
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);

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
}

test "platform-id ban rejects a rejoin with the same identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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

test "admin target key uses the platform id for an online session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
        .enable_sample_plugin = false,
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
        .enable_sample_plugin = false,
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
    // Ensure the mtime advances past the initial load's snapshot.
    clock.sleepNs(10 * std.time.ns_per_ms);
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    try w.writeF32(1);
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

    // EntityStealth: handled without falling to the unhandled counter.
    var sb: [24]u8 = undefined;
    std.mem.writeInt(i32, sb[0..4], ca.entity_id, .little);
    var framed2: [128]u8 = undefined;
    const f2 = try packages.framed(&framed2, "NetPackageEntityStealth", &sb);
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    try g.injectFramed(ca, f2);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));
}

test "quest goto/treasure point reports are handled without double-completion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    var frame_buf: [256]u8 = undefined;
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    // GotoPoint report (traderId + playerId + questCode + padding).
    var gb: [48]u8 = undefined;
    std.mem.writeInt(i32, gb[0..4], 1, .little);
    std.mem.writeInt(i32, gb[4..8], ca.entity_id, .little);
    const f1 = try packages.framed(&frame_buf, "NetPackageQuestGotoPoint", &gb);
    try g.injectFramed(ca, f1);
    // TreasurePoint report (playerId + padding).
    var tb: [48]u8 = undefined;
    std.mem.writeInt(i32, tb[0..4], ca.entity_id, .little);
    const f2 = try packages.framed(&frame_buf, "NetPackageQuestTreasurePoint", &tb);
    try g.injectFramed(ca, f2);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));
}

test "entity physics report is handled without touching the sim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    var body: [80]u8 = undefined;
    std.mem.writeInt(i32, body[8..12], ca.entity_id, .little);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityPhysics", &body);
    const unhandled_before = g.harness.counters.get(.c2s_unhandled);
    try g.injectFramed(ca, framed);
    try std.testing.expectEqual(unhandled_before, g.harness.counters.get(.c2s_unhandled));
}

test "entity ragdoll relays to other clients, not the owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    try std.testing.expect(g.parties.acceptInvite(ca.entity_id, cb.entity_id) != null);

    // A reports treasure_complete for quest 42; the server mirrors it to the
    // party member B (stock ProcessPackage party fan-out).
    var body: [64]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &body };
    try w.writeI32(ca.entity_id);
    try w.writeI32(42);
    try w.writeByte(1); // TreasureComplete
    try w.writeI32(10);
    try w.writeI32(70);
    try w.writeI32(20);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageQuestObjectiveUpdate", w.written());
    cap_b.clear();
    try g.injectFramed(ca, framed);

    const ou_id = packages.idOf("NetPackageQuestObjectiveUpdate").?;
    var pkgs: [8]wire_frame.Package = undefined;
    var b_got = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == ou_id) b_got = true;
        }
    }
    try std.testing.expect(b_got);
}

test "poi lockout reports bedroll and land claim homes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const g = try Game.createWithOptions(std.testing.allocator, dir, 0, .{ .enable_sample_plugin = false });
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
