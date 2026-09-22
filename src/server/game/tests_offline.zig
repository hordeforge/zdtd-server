//! Game integration tests: offline determinism, evidence, clock.
//!
//! Split out of server/game/tests.zig (same tests, moved verbatim).

const std = @import("std");
const Game = @import("../game.zig").Game;
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
const replicate_te = @import("replicate_te.zig");
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

    // DropOnDeath mode 4 (delete all) is stock-valid; the runtime clamp must
    // match serverconfig's 0..4, not stop at 3.
    g.runAdminLine("setgamepref DropOnDeath 4", "test");
    try std.testing.expectEqual(@as(u8, 4), g.drop_on_death);
    g.runAdminLine("setgamepref DropOnDeath 9", "test");
    try std.testing.expectEqual(@as(u8, 4), g.drop_on_death);

    // Unknown / startup-only prefs keep the read-only reply and touch nothing.
    const info_port_before = g.info_port;
    g.runAdminLine("setgamepref ServerPort 9999", "test");
    try std.testing.expectEqual(info_port_before, g.info_port);
}
