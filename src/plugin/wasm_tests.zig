//! Wasm plugin runtime tests: guest contract, hooks, verdicts,
//! reload, claims, and the shipped core/mods fixtures.
//!
//! Split out of plugin/wasm.zig (same code, moved verbatim).

const std = @import("std");
const test_tmp = @import("../util/test_tmp.zig");
const wasm = @import("wasm.zig");
const Plugin = wasm.Plugin;
const WasmHost = wasm.WasmHost;
const HostCtx = wasm.HostCtx;
const Hook = wasm.Hook;
const Budget = wasm.Budget;
const verdict_deny = wasm.verdict_deny;
const max_wasm_plugins = wasm.max_wasm_plugins;
const no_claim = wasm.no_claim;
const host_verbs = wasm.host_verbs;
const manifest = @import("manifest.zig");
const imports_mod = @import("imports.zig");
const api = @import("api.zig");
const resolver = @import("resolver.zig");

/// Shared host-callback context for the counting/queueing test doubles: the
/// per-test `Cap` structs below all captured the same handful of counters in
/// slightly different shapes, so one reset-per-test context serves them
/// (specialized captures - shift/withdraw, evidence writers - keep local
/// structs). `filter` narrows `logged_n` for tests that assert one message.
const TestCtx = struct {
    var logged_n: usize = 0;
    var matched_n: usize = 0;
    var filter: [48]u8 = undefined;
    var filter_len: usize = 0;
    var tick: u64 = 0;
    var queued: [8][]const u8 = undefined;
    var queued_len: [8]usize = undefined;
    var queued_n: usize = 0;
    var last_src: i16 = 0;
    var last_cmd: [128]u8 = undefined;
    var last_len: usize = 0;
    var world_time: u32 = 0;
    var blood_moon: u32 = 0;
    var vy: i32 = 0;

    fn reset() void {
        logged_n = 0;
        matched_n = 0;
        filter_len = 0;
        tick = 0;
        queued_n = 0;
        last_src = 0;
        last_len = 0;
        world_time = 0;
        blood_moon = 0;
        vy = 0;
    }

    fn match(s: []const u8) void {
        filter_len = @min(s.len, filter.len);
        @memcpy(filter[0..filter_len], s[0..filter_len]);
    }

    fn logFn(_: *HostCtx, _: u8, msg: []const u8) void {
        logged_n += 1;
        if (filter_len > 0 and std.mem.eql(u8, msg, filter[0..filter_len])) matched_n += 1;
    }

    fn tickFn(_: *HostCtx) u64 {
        return tick;
    }

    fn queueFn(_: *HostCtx, src: i16, cmd: []const u8) void {
        last_src = src;
        last_len = @min(cmd.len, last_cmd.len);
        @memcpy(last_cmd[0..last_len], cmd[0..last_len]);
        if (queued_n < queued.len) {
            queued[queued_n] = cmd;
            queued_len[queued_n] = cmd.len;
            queued_n += 1;
        }
    }

    fn senseFn(_: *HostCtx, _: i16, out: []u8) usize {
        if (out.len < 24) return 0;
        out[0] = 0;
        return 0;
    }

    fn queryFn(_: *HostCtx, _: []const u8, _: []u8) usize {
        return 0;
    }

    fn ctx() HostCtx {
        return .{
            .log_fn = &logFn,
            .tick_fn = &tickFn,
            .queue_fn = &queueFn,
            .sense_fn = &senseFn,
            .query_fn = &queryFn,
        };
    }
};
const io_fs = @import("../util/io_fs.zig");

test "wasm runtime instantiates a trivial module and calls on_enable" { // Hand-built minimal wasm: (module (func (export "on_enable"))) - a no-op
    // void hook.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x0d, 0x01, 0x09, 'o', 'n', '_', 'e', 'n', 'a', 'b', 'l', 'e', 0x00, 0x00, // export on_enable -> func 0
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: locals 0, end
    };
    var ctx = HostCtx{
        .log_fn = &struct {
            fn f(_: *HostCtx, _: u8, _: []const u8) void {}
        }.f,
        .tick_fn = &struct {
            fn f(_: *HostCtx) u64 {
                return 42;
            }
        }.f,
        .queue_fn = &struct {
            fn f(_: *HostCtx, _: i16, _: []const u8) void {}
        }.f,
    };
    var p = try Plugin.load(std.testing.allocator, "trivial", &bytes, &ctx, .{});
    defer p.deinit();
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(!p.hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(p.callHook(.on_enable));
    try std.testing.expect(!p.disabled);
}

test "wasm runtime disables a looping module on fuel exhaustion" {
    // (module (func (export "on_tick") (loop (br 0)))) - an infinite loop that
    // burns fuel until the budget is exhausted.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x0b, 0x01, 0x07, 'o', 'n', '_', 't', 'i', 'c', 'k', 0x00, 0x00, // export on_tick -> func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b, // code: loop, br 0, end
    };
    var ctx = HostCtx{
        .log_fn = &struct {
            fn f(_: *HostCtx, _: u8, _: []const u8) void {}
        }.f,
        .tick_fn = &struct {
            fn f(_: *HostCtx) u64 {
                return 1;
            }
        }.f,
        .queue_fn = &struct {
            fn f(_: *HostCtx, _: i16, _: []const u8) void {}
        }.f,
    };
    var p = try Plugin.load(std.testing.allocator, "looper", &bytes, &ctx, .{ .fuel = 1_000 });
    defer p.deinit();
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(!p.callHook(.on_tick));
    try std.testing.expect(p.disabled);
    // A disabled plugin stops being called.
    try std.testing.expect(!p.callHook(.on_tick));
}

test "wasm host loads the C fixture modules: hooks fire, looper disabled" {
    TestCtx.reset();
    // Fixtures built from C (assets/fixtures/plugin_hello.c / plugin_looper.c):
    // proof the runtime is language-agnostic, not a Zig-only artifact.
    TestCtx.queued_n = 0;
    TestCtx.logged_n = 0;
    TestCtx.tick = 7;
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    const paths = [_][]const u8{
        "assets/fixtures/plugin_hello.wasm",
        "assets/fixtures/plugin_looper.wasm",
    };
    // Small fuel so the looper is cut off in microseconds, not seconds.
    host.loadAll(std.testing.allocator, &paths, &ctx, .{ .fuel = 50_000 });
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.count());

    // Hello registers every hook; the looper registers the ones it defines.
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_join)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_shutdown)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_tick)]);

    host.enable();
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());

    // Three ticks: hello observes the tick and queues three spawn commands.
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        TestCtx.tick = 7 + @as(u64, @intCast(t));
        host.onTick();
    }
    try std.testing.expectEqual(@as(usize, 3), TestCtx.queued_n);
    try std.testing.expectEqualStrings("spawn 256 70 256 40", TestCtx.queued[0]);
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
    try std.testing.expect(!host.slots[0].disabled); // hello survived
    try std.testing.expect(host.slots[1].disabled); // looper cut off by fuel
    try std.testing.expect(TestCtx.logged_n > 0); // hello logged through zdtd_log

    // The disabled looper is not called again; hello keeps running.
    TestCtx.tick = 10;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
}

test "wasm host fires the T15 event hooks with deny/adjust verdicts" {
    TestCtx.reset();
    // plugin_rules.wasm exports the four event hooks (T15): on_player_death
    // denies, on_block_damage and on_quest_complete double, on_entity_killed
    // keeps. plugin_trap.wasm traps in on_entity_killed: the host disables only
    // that module and the kill still proceeds (trap -> keep).
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    const paths = [_][]const u8{
        "assets/fixtures/plugin_trap.wasm",
        "assets/fixtures/plugin_rules.wasm",
    };
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.count());

    // plugin_rules (slot 1 after the trap reorder): deny death, double block
    // damage, double quest reward, scale kills 150%.
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_player_death)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_entity_killed)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_block_damage)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_quest_complete)]);
    try std.testing.expectEqual(verdict_deny, host.playerDeath(7));
    try std.testing.expectEqual(@as(i32, 150), host.entityKilled(8, 1));
    try std.testing.expectEqual(@as(i32, 200), host.blockDamage(0, 0, 0, 50));
    try std.testing.expectEqual(@as(i32, 200), host.questComplete(9, 2));

    // plugin_trap (slot 0): on_entity_killed traps -> that module only is
    // disabled (returns keep), then plugin_rules (slot 1) scales 150%; the
    // sim's kill is not blocked by the broken plugin.
    try std.testing.expectEqual(@as(i32, 150), host.entityKilled(10, 1));
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
    try std.testing.expect(host.slots[0].disabled);
    try std.testing.expect(!host.slots[1].disabled);
    // A disabled module keeps reporting keep for every hook.
    try std.testing.expectEqual(@as(i32, 150), host.entityKilled(11, 1));
}

test "wasm plugin admin command hook handles ping/echo and falls through" {
    TestCtx.reset();
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    const paths = [_][]const u8{"assets/fixtures/plugin_admin.wasm"};
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_admin_command)]);

    var out: [4096]u8 = undefined;
    {
        const rep = host.adminCommand("ping", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("pong\n", rep.?);
    }
    {
        const rep = host.adminCommand("echo hello world", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("hello world\n", rep.?);
    }
    {
        const rep = host.adminCommand("unknown_verb", &out);
        try std.testing.expect(rep == null);
    }
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "wasm chat filter hook deny/rewrite/keep" {
    TestCtx.reset();
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    const paths = [_][]const u8{"assets/fixtures/plugin_chat.wasm"};
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_chat)]);
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", host.chatFilter(1, "bad", &out).?);
    try std.testing.expectEqualStrings("hi", host.chatFilter(1, "hello", &out).?);
    try std.testing.expect(host.chatFilter(1, "other", &out) == null);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "wasm on_player_login join gate: deny reason, allow others" {
    TestCtx.reset();
    // T9 proof (WORK_PLAN): the join gate hook is covered with a real .wasm
    // fixture. "rejectme" is denied with the reason "nope"; any other name is
    // allowed; traps/fuel keep the gate open (allow).
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    const paths = [_][]const u8{"assets/fixtures/plugin_login.wasm"};
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_login)]);
    var out: [256]u8 = undefined;
    const reason = host.playerLoginDeny(1, "rejectme", &out).?;
    try std.testing.expectEqualStrings("nope", reason);
    try std.testing.expect(host.playerLoginDeny(1, "SurvivorBob", &out) == null);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_announce.wasm (zig-built) join/leave says + clock announcements" {
    const Cap = struct {
        var queued: [8][128]u8 = undefined;
        var queued_len: [8]usize = .{0} ** 8;
        var queued_n: usize = 0;
        var world_time: u32 = 2 * 24000; // day 2
        var blood_moon: u32 = 1;
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 7;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n < queued.len) {
                const n = @min(cmd.len, 128);
                @memcpy(queued[queued_n][0..n], cmd[0..n]);
                queued_len[queued_n] = n;
                queued_n += 1;
            }
        }
        fn senseFn(_: *HostCtx, _: i16, out_buf: []u8) usize {
            if (out_buf.len < 24) return 0;
            std.mem.writeInt(u32, out_buf[0..4], 0x3453425a, .little); // 'ZBS3'
            std.mem.writeInt(u32, out_buf[4..8], 0, .little);
            std.mem.writeInt(u32, out_buf[8..12], 1, .little);
            std.mem.writeInt(i32, out_buf[12..16], -1, .little);
            std.mem.writeInt(u32, out_buf[16..20], world_time, .little);
            std.mem.writeInt(u32, out_buf[20..24], blood_moon, .little);
            return 24;
        }
    };
    Cap.queued_n = 0;
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_announce/core_announce.wasm"}, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_tick)]);
    host.enable();
    host.playerJoin(3, 77);
    host.playerLeave(3, 77);
    // First tick: baseline only (no announcements yet).
    host.onTick();
    // Second tick with the same clock: still nothing.
    host.onTick();
    try std.testing.expectEqual(@as(usize, 2), Cap.queued_n); // join + leave says
    try std.testing.expectEqualStrings("say A new survivor has joined the wasteland.", Cap.queued[0][0..Cap.queued_len[0]]);
    try std.testing.expectEqualStrings("say A survivor has left the wasteland.", Cap.queued[1][0..Cap.queued_len[1]]);
    // Day roll + blood-moon end on the next tick.
    Cap.queued_n = 0;
    Cap.world_time = 3 * 24000; // day 3
    Cap.blood_moon = 0;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 2), Cap.queued_n);
    try std.testing.expectEqualStrings("say Day 3", Cap.queued[0][0..Cap.queued_len[0]]);
    try std.testing.expectEqualStrings("say The blood moon fades.", Cap.queued[1][0..Cap.queued_len[1]]);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_killfeed.wasm observer keeps every verdict and never disables" {
    TestCtx.reset();
    // The reference event-observer plugin (AGENTS.md rule 29, Wasm-first):
    // loaded from the committed module, its verdict hooks must always keep
    // (0) and the module must never trap/disable - a pure observer is a
    // zero-risk addition (docs/PLUGIN_DEV.md "What belongs in a plugin").
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_killfeed/core_killfeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_join)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_leave)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_death)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_entity_killed)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_quest_complete)]);
    // Observer: keep every outcome (0), never deny/adjust.
    try std.testing.expectEqual(@as(i32, 0), host.playerDeath(7));
    try std.testing.expectEqual(@as(i32, 0), host.entityKilled(8, 1));
    try std.testing.expectEqual(@as(i32, 0), host.questComplete(9, 2));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
    // Join/leave are void notifications: they never disable the module.
    host.playerJoin(0, 10);
    host.playerLeave(0, 10);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_pvp.wasm denies player-vs-player damage via kind query" {
    // The player-damage policy plugin (AGENTS rule 29): with the "kind" query
    // verb stubbed (100/200 players, 300 zombie), on_player_damage must deny
    // player-vs-player and keep everything else, never disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn queryFn(_: *HostCtx, req: []const u8, out: []u8) usize {
            var it = std.mem.tokenizeScalar(u8, req, ' ');
            _ = it.next();
            const id_s = it.next() orelse return 0;
            const id = std.fmt.parseInt(i32, id_s, 10) catch return 0;
            const k: u8 = switch (id) {
                100, 200 => 0, // players
                300 => 1, // zombie
                else => return 0,
            };
            out[0] = '0' + k;
            return 1;
        }
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn, .query_fn = &Cap.queryFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_pvp/core_pvp.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_damage)]);
    try std.testing.expectEqual(@as(i32, -1), host.playerDamage(100, 200, 50)); // both players: deny
    try std.testing.expectEqual(@as(i32, 0), host.playerDamage(300, 200, 50)); // zombie -> player: keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_questgate.wasm denies forbidden_* quests via quest query" {
    // The quest-acceptance policy plugin (AGENTS rule 29): with the "quest"
    // query verb stubbed (def 1 -> "forbidden_evil", def 2 -> "tier1_clear"),
    // on_quest_accept must deny the forbidden name and keep the rest, never
    // disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn queryFn(_: *HostCtx, req: []const u8, out: []u8) usize {
            var it = std.mem.tokenizeScalar(u8, req, ' ');
            _ = it.next();
            const id_s = it.next() orelse return 0;
            const id = std.fmt.parseInt(i32, id_s, 10) catch return 0;
            const name: []const u8 = switch (id) {
                1 => "forbidden_evil",
                2 => "tier1_clear",
                else => return 0,
            };
            const n = @min(name.len, out.len);
            @memcpy(out[0..n], name[0..n]);
            return n;
        }
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn, .query_fn = &Cap.queryFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_questgate/core_questgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_quest_accept)]);
    try std.testing.expectEqual(@as(i32, -1), host.questAccept(5, 1)); // forbidden_evil: deny
    try std.testing.expectEqual(@as(i32, 0), host.questAccept(5, 2)); // tier1_clear: keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_craftgate.wasm denies forbidden_* recipes via on_craft_request" {
    TestCtx.reset();
    // The craft-request policy plugin (AGENTS rule 29): on_craft_request must
    // deny the forbidden recipe name and keep the rest, never disabling.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_craftgate/core_craftgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_craft_request)]);
    try std.testing.expectEqual(@as(i32, -1), host.craftRequest(5, "forbidden_sword", 1)); // deny
    try std.testing.expectEqual(@as(i32, 0), host.craftRequest(5, "resourceWood", 3)); // keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_lootgate.wasm scales loot rolls to 50% via on_loot_roll" {
    TestCtx.reset();
    // The loot-roll policy plugin (AGENTS rule 29): on_loot_roll must return
    // 50 (scale percent) for every list and never disable.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_lootgate/core_lootgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_loot_roll)]);
    try std.testing.expectEqual(@as(i32, 50), host.lootRoll("EntityLootContainerRegular", 4));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_tradefeed.wasm observes trader events via on_trader_event" {
    TestCtx.reset();
    // The trader-event observer plugin (AGENTS rule 29): on_trader_event must
    // be present, fire for every kind without disabling, and stay loaded.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    host.traderEvent(107, 42, 0); // open
    host.traderEvent(107, 42, 1); // buy
    host.traderEvent(107, 42, 2); // sell
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "_zdtd_requires validates declarative dependencies at load" {
    TestCtx.reset();
    // Coeffect fail-closed (paper): a module declaring a capability it does
    // not export (typo'd hook) is rejected at load with a loud error, instead
    // of silently never firing. The valid tradefeed module passes.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.n);
    try std.testing.expect(!host.slots[0].requires_failed);

    var bad: WasmHost = .{};
    bad.loadAll(std.testing.allocator, &[_][]const u8{"assets/fixtures/plugin_requires_bad.wasm"}, &ctx, .{});
    defer bad.shutdown();
    // The module names an unknown capability: it must be rejected, not loaded.
    try std.testing.expectEqual(@as(usize, 0), bad.n);
}

test "the guest contract version is read and a newer one is refused" {
    TestCtx.reset();
    // Paper 6.6 (review F6): a name set cannot see a semantic change between
    // two versions that share the hook vocabulary, so a guest may declare the
    // version it was built against with `_zdtd_api() -> i32`. Newer than the
    // host fails closed through the `_zdtd_requires` channel; older is
    // accepted; absent keeps the permissive legacy path.
    var ctx = TestCtx.ctx();
    // (module (func (export "_zdtd_api") (result i32) i32.const N))
    const V = struct {
        fn bytes(comptime ver: u8) [42]u8 {
            return .{
                0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
                0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
                0x02, 0x01, 0x00, 0x07, 0x0d, 0x01, 0x09, '_',
                'z',  'd',  't',  'd',  '_',  'a',  'p',  'i',
                0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
                ver,  0x0b,
            };
        }
    };
    // The C fixtures and every pre-versioning module export nothing: no
    // declared version, still loaded.
    const plain = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
        0x01, 0x00, 0x07, 0x0b, 0x01, 0x07, 'o',  'n',
        '_',  't',  'i',  'c',  'k',  0x00, 0x00, 0x0a,
        0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    var p_plain = try Plugin.load(std.testing.allocator, "plain.wasm", &plain, &ctx, .{});
    defer p_plain.deinit();
    try std.testing.expectEqual(@as(?u32, null), p_plain.api_version);
    try std.testing.expect(!p_plain.requires_failed);

    const cur = V.bytes(@intCast(api.plugin_api_version));
    var p_cur = try Plugin.load(std.testing.allocator, "cur.wasm", &cur, &ctx, .{});
    defer p_cur.deinit();
    try std.testing.expectEqual(@as(?u32, api.plugin_api_version), p_cur.api_version);
    try std.testing.expect(!p_cur.requires_failed);

    const next = V.bytes(@intCast(api.plugin_api_version + 1));
    var p_next = try Plugin.load(std.testing.allocator, "next.wasm", &next, &ctx, .{});
    defer p_next.deinit();
    try std.testing.expect(p_next.requires_failed);
    try std.testing.expectEqual(@as(?u32, api.plugin_api_version + 1), p_next.api_version);
    // The reason names both versions for the operator log.
    try std.testing.expect(std.mem.find(u8, p_next.requires_err[0..p_next.requires_err_len], "plugin API v") != null);
    try std.testing.expect(std.mem.find(u8, p_next.requires_err[0..p_next.requires_err_len], "this host is v") != null);
    // loadAll is the shipping path: a newer guest is skipped, not loaded.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const cur_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ dir, "cur.wasm" });
    defer std.testing.allocator.free(cur_path);
    const next_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ dir, "next.wasm" });
    defer std.testing.allocator.free(next_path);
    try io_fs.writeFile(cur_path, &cur);
    try io_fs.writeFile(next_path, &next);
    var host: WasmHost = .{};
    defer host.shutdown();
    host.loadAll(std.testing.allocator, &[_][]const u8{ cur_path, next_path }, &ctx, .{});
    try std.testing.expectEqual(@as(usize, 1), host.n);
}

test "shipped core plugins declare the host contract version" {
    TestCtx.reset();
    // The guest constant lives in `mods/plugin_common.zig` (wasm32-freestanding
    // cannot import the host's api.zig), so this test is the drift gate: bump
    // one side without the other and every shipped plugin fails to load or
    // stops matching.
    var ctx = TestCtx.ctx();
    const modules = [_][]const u8{
        "plugins/core_announce/core_announce.wasm",
        "plugins/core_killfeed/core_killfeed.wasm",
        "plugins/core_damagegate/core_damagegate.wasm",
        "plugins/core_pricegate/core_pricegate.wasm",
        "plugins/core_rewardgate/core_rewardgate.wasm",
        "plugins/core_lootgate/core_lootgate.wasm",
        "plugins/core_tradefeed/core_tradefeed.wasm",
        "plugins/core_pvp/core_pvp.wasm",
        "plugins/core_questgate/core_questgate.wasm",
        "plugins/core_craftgate/core_craftgate.wasm",
        "plugins/core_adminverbs/core_adminverbs.wasm",
        "plugins/core_perkgate/core_perkgate.wasm",
        "mods/mcp/mcp.wasm",
        "mods/parachute/parachute.wasm",
    };
    var host: WasmHost = .{};
    defer host.shutdown();
    host.loadAll(std.testing.allocator, &modules, &ctx, .{});
    // The shipped set must fit the host table, or the default composition
    // silently loses modules at the cap.
    try std.testing.expect(modules.len <= max_wasm_plugins);
    // Every module loaded: a plugin declaring a newer version than the host
    // would have been skipped by loadAll, so the count is part of the gate.
    try std.testing.expectEqual(@as(usize, modules.len), host.n);
    for (0..host.n) |i| {
        try std.testing.expectEqual(@as(?u32, api.plugin_api_version), host.slots[i].api_version);
    }
}

test "plugin reload disposes and reinstantiates the module in place" {
    TestCtx.reset();
    // HMR (paper): dispose the old fiber (on_shutdown + deinit), reload the
    // module from disk into the same slot, and re-activate (on_enable). The
    // reloaded module must be fully functional and not disabled.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    try std.testing.expect(!host.slots[0].disabled);
    host.traderEvent(107, 42, 1);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "plugin reload keeps a heap-owned display name valid" {
    TestCtx.reset();
    // Regression: reload used to free its display copy via defer on the
    // success path while the reloaded slot still pointed at it (use-after-free
    // on the next `plugin list` render, double free at shutdown). A resolved
    // mod slot (PRD 0005) owns its display string, so reload must transfer
    // that ownership, not release it under the slot.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.n);
    // Install a manifest-style display name owned by the slot.
    host.slots[0].display = try std.testing.allocator.dupe(u8, "core_tradefeed");
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    // Readable after the reload...
    try std.testing.expectEqualStrings("core_tradefeed", host.slots[0].display);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    // ...and freed exactly once at shutdown (the defer above); a double free
    // fails this test under std.testing.allocator.
}

test "plugin reload keeps the module's config bytes" {
    TestCtx.reset();
    // Regression (composability audit 2026-09-11): config.toml bytes are loaded
    // by loadResolved/loadAll, not by loadInto, so reload's "preserve tier and
    // display" left config_bytes empty. Every module with a config silently
    // reverted to its compiled defaults on `plugin reload` while on_enable
    // still logged "enabled", and the zdtd.config import then returned 0 bytes.
    // The wasm.zig reload tests all load through loadAll, where config_bytes is
    // already "", which is exactly why none of them caught it.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.n);
    // A manifest-style config owned by the slot (the shape loadResolved leaves).
    const cfg_text = "tradefeed_prefix = \"sold\"\n";
    host.slots[0].config_bytes = try std.testing.allocator.dupe(u8, cfg_text);
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    // Readable after the reload, and the old copy was freed by deinit (a leak
    // or double free fails this test under std.testing.allocator).
    try std.testing.expectEqualStrings(cfg_text, host.slots[0].config_bytes);
}

/// Minimal undeclared module (exports `on_tick`, no `_zdtd_requires`): the
/// shape the strict presence rule refuses and the raw fixture path accepts.
/// Shared by the presence test and the F8 reload-replay test.
const undeclared_test_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x03, 0x02, 0x01, 0x00, // function: one of type 0
    0x07, 0x0b, 0x01, 0x07, 'o', 'n', '_', 't', 'i', 'c', 'k', // export "on_tick"
    0x00, 0x00,
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: empty body
};

/// Minimal declaring module for the manifest-backed reload tests: exports
/// on_tick plus a valid `_zdtd_requires` ("log"), which the reviewed F8 rule
/// requires of a module loaded from a manifest.
const declaring_test_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
    0x01, 0x7e, 0x03, 0x03, 0x02, 0x00, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x1c, 0x02, 0x07,
    0x6f, 0x6e, 0x5f, 0x74, 0x69, 0x63, 0x6b, 0x00, 0x00, 0x0e, 0x5f, 0x7a, 0x64, 0x74, 0x64, 0x5f,
    0x72, 0x65, 0x71, 0x75, 0x69, 0x72, 0x65, 0x73, 0x00, 0x01, 0x0a, 0x0d, 0x02, 0x02, 0x00, 0x0b,
    0x08, 0x00, 0x42, 0x80, 0x80, 0x80, 0x80, 0x30, 0x0b, 0x0b, 0x09, 0x01, 0x00, 0x41, 0x00, 0x0b,
    0x03, 0x6c, 0x6f, 0x67,
};

test "plugin reload re-reads config.toml for a manifest-backed module" {
    TestCtx.reset();
    // F11 (plugin-composability review 2026-09-12): a manifest-backed reload
    // re-reads manifest.toml but kept the pre-reload config_bytes, so an
    // edited config.toml was never seen until a restart. The config is now
    // re-read with the declaration; a missing file fails closed to none.
    var ctx = TestCtx.ctx();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const a = std.testing.allocator;
    const wasm_path = try std.Io.Dir.path.join(a, &.{ dir, "m.wasm" });
    defer a.free(wasm_path);
    const man_path = try std.Io.Dir.path.join(a, &.{ dir, "manifest.toml" });
    defer a.free(man_path);
    const cfg_path = try std.Io.Dir.path.join(a, &.{ dir, "config.toml" });
    defer a.free(cfg_path);
    try io_fs.writeFile(wasm_path, &declaring_test_wasm);
    try io_fs.writeFile(man_path, "name = \"m\"\nwasm = \"m.wasm\"\n");
    try io_fs.writeFile(cfg_path, "announce = \"one\"\n");

    var host: WasmHost = .{};
    host.allocator = a;
    host.ctx = &ctx;
    host.budget = .{};
    defer host.shutdown();
    try host.loadInto(0, wasm_path);
    host.n = 1;
    host.slots[0].manifest_loaded = true;
    host.slots[0].display = try a.dupe(u8, "m");
    host.slots[0].config_bytes = try a.dupe(u8, "announce = \"one\"\n");

    try io_fs.writeFile(cfg_path, "announce = \"two\"\n");
    try std.testing.expect(host.reload(0, wasm_path));
    try std.testing.expectEqualStrings("announce = \"two\"\n", host.slots[0].config_bytes);

    // The file is gone: the reload fails closed to no config.
    io_fs.deleteFile(cfg_path);
    try std.testing.expect(host.reload(0, wasm_path));
    try std.testing.expectEqual(@as(usize, 0), host.slots[0].config_bytes.len);
}

test "a discovered mod must declare _zdtd_requires" {
    TestCtx.reset();
    // Composability audit 2026-09-11: probeRequires returned early when the
    // export was absent, so a mod that exported hooks but declared nothing had
    // its hook names validated by nobody - a typo'd hook was a silent
    // never-fire. The presence rule is now fail-closed for a discovered mod
    // (its manifest is a capability claim) while the raw load path stays
    // permissive, because the in-repo C fixtures export every symbol through
    // --export-all and so "exports a hook" is not evidence of intent there.
    var ctx = TestCtx.ctx();
    // Hand-built module exporting only `on_tick` and declaring nothing: type
    // ()->(), one function of that type, the export, an empty body.
    const undeclared = undeclared_test_wasm;
    // Same bytes on the raw path (no manifest claim) load: the rule is about a
    // discovered mod's declaration, not about the module shape.
    var p = try Plugin.load(std.testing.allocator, "undeclared.wasm", &undeclared, &ctx, .{});
    defer p.deinit();
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(!p.requires_failed);
    // A discovered mod (manifest = capability claim) with the same export and
    // no declaration is refused at the load boundary.
    ctx.require_declaration = true;
    try std.testing.expectError(
        error.RequiresUnmet,
        Plugin.load(std.testing.allocator, "undeclared.wasm", &undeclared, &ctx, .{}),
    );
    ctx.require_declaration = false;
}

test "plugin reload failure frees the display copy and reports false" {
    TestCtx.reset();
    // The failed-reload branch must not leave a disposed slot inside 0..n:
    // hooks/deinit would run on undefined memory on the next tick or at
    // shutdown. The dead module is dropped from the range and later modules
    // shift down (HostCtx backlinks and override-point claims follow).
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(
        std.testing.allocator,
        &[_][]const u8{ "plugins/core_tradefeed/core_tradefeed.wasm", "assets/fixtures/plugin_hello.wasm" },
        &ctx,
        .{},
    );
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.n);
    host.slots[0].display = try std.testing.allocator.dupe(u8, "core_tradefeed");
    // Claim points on both modules so claim handling is observable:
    // craft_request -> slot 1 (survivor, must follow down to 0),
    // loot_roll -> slot 0 (dropped, must release).
    host.claims[@intFromEnum(manifest.OverridePoint.craft_request)] = 1;
    host.claims[@intFromEnum(manifest.OverridePoint.loot_roll)] = 0;
    try std.testing.expect(!host.reload(0, "/no/such/plugin.wasm"));
    try std.testing.expectEqual(@as(usize, 1), host.n);
    // Slot 0 now holds the survivor; its backlink addresses its new slot.
    try std.testing.expect(std.mem.endsWith(u8, host.slots[0].name, "plugin_hello.wasm"));
    try std.testing.expect(ctx.plugin_slot[0] != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&host.slots[0])), ctx.plugin_slot[0].?);
    try std.testing.expect(ctx.plugin_slot[1] == null and ctx.rt_slot[1] == null);
    // The survivor's claim followed it down; the dropped module's released.
    try std.testing.expectEqual(@as(u8, 0), host.claims[@intFromEnum(manifest.OverridePoint.craft_request)]);
    try std.testing.expectEqual(no_claim, host.claims[@intFromEnum(manifest.OverridePoint.loot_roll)]);
}

/// Capture for the failed-reload src remap: the owner's attribution table
/// stands in for the command buffer, bots and glide flags the Game shifts.
var shift_dropped: i16 = 0;
var shift_calls: u32 = 0;

test "a failed reload asks the owner to remap the compacted srcs" {
    // Slot 0 dies and slot 1 becomes slot 0, so every effect the owner still
    // attributes to src 2 belongs to src 1 now (paper 3.1: an effect stays
    // attributable to the module that made it). The remap used to live in the
    // admin verb, which left any other caller of reload with a table pointing
    // at the wrong module.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn shiftFn(_: *HostCtx, dropped: i16) void {
            shift_dropped = dropped;
            shift_calls += 1;
        }
    };
    shift_dropped = 0;
    shift_calls = 0;
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .shift_srcs_fn = &Cap.shiftFn,
    };
    var host: WasmHost = .{};
    host.loadAll(
        std.testing.allocator,
        &[_][]const u8{ "plugins/core_tradefeed/core_tradefeed.wasm", "assets/fixtures/plugin_hello.wasm" },
        &ctx,
        .{},
    );
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.n);
    try std.testing.expect(!host.reload(0, "/no/such/plugin.wasm"));
    try std.testing.expectEqual(@as(u32, 1), shift_calls);
    try std.testing.expectEqual(@as(i16, 1), shift_dropped);
    // A reload that succeeds keeps every slot where it was: no remap.
    try std.testing.expect(host.reload(0, "assets/fixtures/plugin_hello.wasm"));
    try std.testing.expectEqual(@as(u32, 1), shift_calls);
}

test "takeWithdrawn never reports more srcs than the caller's buffer holds" {
    TestCtx.reset();
    // The caller slices `out[0..n]`, so a count past `out.len` is an
    // out-of-bounds read; marking the overflow withdrawn anyway would also
    // burn the one withdrawal those modules get. A src that does not fit stays
    // pending for the next pass instead.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(
        std.testing.allocator,
        &[_][]const u8{ "plugins/core_tradefeed/core_tradefeed.wasm", "assets/fixtures/plugin_hello.wasm" },
        &ctx,
        .{},
    );
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.n);
    host.slots[0].disabled = true;
    host.slots[1].disabled = true;
    var one: [1]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 1), host.takeWithdrawn(&one));
    try std.testing.expectEqual(@as(i16, 1), one[0]);
    // The src that did not fit is still pending, not silently consumed.
    try std.testing.expectEqual(@as(usize, 1), host.takeWithdrawn(&one));
    try std.testing.expectEqual(@as(i16, 2), one[0]);
    try std.testing.expectEqual(@as(usize, 0), host.takeWithdrawn(&one));
}

test "reload reconciles the module's manifest point claims" {
    TestCtx.reset();
    // Paper 5.2.1/5.2.2: a reload reconciles the declarative configuration, not
    // just the code. The claim table is built once by loadResolved, so before
    // this a module replaced on disk kept exclusivity its new manifest had
    // dropped (its hook was still exported, so nothing else caught it) and one
    // that added a claim never got it.
    var ctx = TestCtx.ctx();
    // Hand-built modules: one exports the loot.roll hook, one exports only
    // on_tick, so the hook-present refusal is observable.
    const with_hook = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
        0x01, 0x7e, 0x03, 0x03, 0x02, 0x00, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x21, 0x02, 0x0c,
        0x6f, 0x6e, 0x5f, 0x6c, 0x6f, 0x6f, 0x74, 0x5f, 0x72, 0x6f, 0x6c, 0x6c, 0x00, 0x00, 0x0e, 0x5f,
        0x7a, 0x64, 0x74, 0x64, 0x5f, 0x72, 0x65, 0x71, 0x75, 0x69, 0x72, 0x65, 0x73, 0x00, 0x01, 0x0a,
        0x0d, 0x02, 0x02, 0x00, 0x0b, 0x08, 0x00, 0x42, 0x80, 0x80, 0x80, 0x80, 0x30, 0x0b, 0x0b, 0x09,
        0x01, 0x00, 0x41, 0x00, 0x0b, 0x03, 0x6c, 0x6f, 0x67,
    };
    const without_hook = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
        0x01, 0x7e, 0x03, 0x03, 0x02, 0x00, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x1c, 0x02, 0x07,
        0x6f, 0x6e, 0x5f, 0x74, 0x69, 0x63, 0x6b, 0x00, 0x00, 0x0e, 0x5f, 0x7a, 0x64, 0x74, 0x64, 0x5f,
        0x72, 0x65, 0x71, 0x75, 0x69, 0x72, 0x65, 0x73, 0x00, 0x01, 0x0a, 0x0d, 0x02, 0x02, 0x00, 0x0b,
        0x08, 0x00, 0x42, 0x80, 0x80, 0x80, 0x80, 0x30, 0x0b, 0x0b, 0x09, 0x01, 0x00, 0x41, 0x00, 0x0b,
        0x03, 0x6c, 0x6f, 0x67,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const a = std.testing.allocator;

    // m0 and m1 both export loot.roll; m2 does not.
    const wasm0 = try std.Io.Dir.path.join(a, &.{ dir, "m0", "m.wasm" });
    defer a.free(wasm0);
    const wasm1 = try std.Io.Dir.path.join(a, &.{ dir, "m1", "m.wasm" });
    defer a.free(wasm1);
    const wasm2 = try std.Io.Dir.path.join(a, &.{ dir, "m2", "m.wasm" });
    defer a.free(wasm2);
    const man0 = try std.Io.Dir.path.join(a, &.{ dir, "m0", "manifest.toml" });
    defer a.free(man0);
    const man1 = try std.Io.Dir.path.join(a, &.{ dir, "m1", "manifest.toml" });
    defer a.free(man1);
    const man2 = try std.Io.Dir.path.join(a, &.{ dir, "m2", "manifest.toml" });
    defer a.free(man2);
    try io_fs.writeFile(wasm0, &with_hook);
    try io_fs.writeFile(wasm1, &with_hook);
    try io_fs.writeFile(wasm2, &without_hook);
    try io_fs.writeFile(man0, "name = \"m0\"\nwasm = \"m.wasm\"\npoints = \"loot.roll\"\n");
    try io_fs.writeFile(man1, "name = \"m1\"\nwasm = \"m.wasm\"\npoints = \"loot.roll\"\n");
    try io_fs.writeFile(man2, "name = \"m2\"\nwasm = \"m.wasm\"\npoints = \"craft.request\"\n");

    var host: WasmHost = .{};
    host.allocator = a;
    host.ctx = &ctx;
    host.budget = .{};
    defer host.shutdown();
    try host.loadInto(0, wasm0);
    try host.loadInto(1, wasm1);
    try host.loadInto(2, wasm2);
    host.n = 3;
    for (0..3) |i| {
        host.slots[i].manifest_loaded = true;
        host.slots[i].display = try a.dupe(u8, if (i == 0) "m0" else if (i == 1) "m1" else "m2");
    }

    const loot = @intFromEnum(manifest.OverridePoint.loot_roll);
    const craft = @intFromEnum(manifest.OverridePoint.craft_request);

    // The declaration installs the claim (boot did this via the resolver).
    host.reconcileClaims(0, wasm0);
    try std.testing.expectEqual(@as(u8, 0), host.claims[loot]);

    // A second claimant with the hook exported is refused: the point is
    // exclusive, and a reload must not steal it from a live module.
    host.reconcileClaims(1, wasm1);
    try std.testing.expectEqual(@as(u8, 0), host.claims[loot]);

    // The replaced module drops its claim on disk: reload re-reads the
    // manifest and releases it instead of holding exclusivity forever.
    try io_fs.writeFile(man0, "name = \"m0\"\nwasm = \"m.wasm\"\n");
    try std.testing.expect(host.reload(0, wasm0));
    try std.testing.expectEqual(no_claim, host.claims[loot]);
    // ... and the freed point goes to the other module's declaration.
    host.reconcileClaims(1, wasm1);
    try std.testing.expectEqual(@as(u8, 1), host.claims[loot]);

    // A claim whose hook the module does not export is refused (fail closed,
    // like the boot install), and the point stays free.
    host.reconcileClaims(2, wasm2);
    try std.testing.expectEqual(no_claim, host.claims[craft]);

    // A legacy `[plugin] modules` path has no manifest to reconcile, so a
    // manifest.toml that happens to sit beside it must not mint or drop claims.
    host.claims[craft] = 2;
    host.slots[2].manifest_loaded = false;
    try std.testing.expect(host.reload(2, wasm2));
    try std.testing.expectEqual(@as(u8, 2), host.claims[craft]);
}

test "point claims bind to the loaded slot, not the plan index" {
    TestCtx.reset();
    // F7 (plugin-composability review 2026-09-12): a module the loader skips
    // (missing file, cap) shifts every later module down, while point_claims
    // stays keyed by the resolver's plan slot. Binding by plan slot named
    // whichever module landed there (whose hook_present may pass), or a slot
    // >= self.n that claimSlot voids forever.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const gone_dir = try std.Io.Dir.path.join(a, &.{ dir, "gone" });
    defer a.free(gone_dir);
    io_fs.mkdirPath(gone_dir);

    // The second module is the shipped override fixture: it exports
    // on_loot_roll and a valid _zdtd_requires, so loadResolved accepts it.
    var modules = [_]resolver.ResolvedModule{
        .{ .manifest = .{ .name = "gone", .dir = gone_dir, .wasm = "absent.wasm" }, .tier = .user, .slot = 0 },
        .{ .manifest = .{ .name = "gate", .dir = "assets/fixtures", .wasm = "plugin_override.wasm" }, .tier = .user, .slot = 1 },
    };
    var plan: resolver.ResolvedResult = .{ .modules = &modules, .point_claims = .{}, .name_to_slot = .{}, .synthetic = &.{} };
    defer plan.point_claims.deinit(a);
    defer plan.name_to_slot.deinit(a);
    try plan.point_claims.put(a, "loot.roll", 1);

    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    defer host.shutdown();
    host.loadResolved(a, &plan, &ctx, .{});
    // The first module is skipped, so the claimant lands in slot 0 and its
    // claim must follow it there.
    try std.testing.expectEqual(@as(usize, 1), host.n);
    try std.testing.expectEqualStrings("gate", host.slots[0].display);
    try std.testing.expectEqual(@as(u8, 0), host.claims[@intFromEnum(manifest.OverridePoint.loot_roll)]);
}

test "queued-verb policy: module deny, operator right-bias, reload" {
    TestCtx.reset();
    // Paper 3.2.3 interception (ADR 0039): a module declares verbs it will not
    // queue, the operator context is merged last (denies add, allows clear),
    // and a reload re-reads the declaration while keeping the operator's masks.
    var ctx = TestCtx.ctx();
    const plain = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00,
        0x01, 0x7e, 0x03, 0x03, 0x02, 0x00, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x1c, 0x02, 0x07,
        0x6f, 0x6e, 0x5f, 0x74, 0x69, 0x63, 0x6b, 0x00, 0x00, 0x0e, 0x5f, 0x7a, 0x64, 0x74, 0x64, 0x5f,
        0x72, 0x65, 0x71, 0x75, 0x69, 0x72, 0x65, 0x73, 0x00, 0x01, 0x0a, 0x0d, 0x02, 0x02, 0x00, 0x0b,
        0x08, 0x00, 0x42, 0x80, 0x80, 0x80, 0x80, 0x30, 0x0b, 0x0b, 0x09, 0x01, 0x00, 0x41, 0x00, 0x0b,
        0x03, 0x6c, 0x6f, 0x67,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const a = std.testing.allocator;
    const wasm_path = try std.Io.Dir.path.join(a, &.{ dir, "m.wasm" });
    defer a.free(wasm_path);
    const man_path = try std.Io.Dir.path.join(a, &.{ dir, "manifest.toml" });
    defer a.free(man_path);
    try io_fs.writeFile(wasm_path, &plain);
    try io_fs.writeFile(man_path, "name = \"m\"\nwasm = \"m.wasm\"\ndeny = \"say\"\n");

    var host: WasmHost = .{};
    host.allocator = a;
    host.ctx = &ctx;
    host.budget = .{};
    defer host.shutdown();
    try host.loadInto(0, wasm_path);
    host.n = 1;
    host.slots[0].manifest_loaded = true;
    host.slots[0].display = try a.dupe(u8, "m");
    host.reconcileClaims(0, wasm_path);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].module_deny);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].denied);

    io_fs.deleteFile(man_path);
    try std.testing.expect(host.reload(0, wasm_path));
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].module_deny);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].denied);

    // Operator right-bias: a deny adds damage, an allow clears the module's say.
    host.slots[0].op_deny = manifest.QueueVerb.damage.bit();
    host.slots[0].op_allow = manifest.QueueVerb.say.bit();
    host.slots[0].refreshDenied();
    try std.testing.expectEqual(manifest.QueueVerb.damage.bit(), host.slots[0].denied);

    // Reload re-reads the declaration (say dropped) and keeps the operator
    // masks, so only the operator's damage deny remains.
    try io_fs.writeFile(man_path, "name = \"m\"\nwasm = \"m.wasm\"\n");
    try std.testing.expect(host.reload(0, wasm_path));
    try std.testing.expectEqual(@as(manifest.QueueVerbMask, 0), host.slots[0].module_deny);
    try std.testing.expectEqual(manifest.QueueVerb.damage.bit(), host.slots[0].denied);
    try std.testing.expectEqual(manifest.QueueVerb.damage.bit(), host.slots[0].op_deny);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].op_allow);

    // A legacy path (no manifest) keeps the operator policy across a reload.
    host.slots[0].manifest_loaded = false;
    try std.testing.expect(host.reload(0, wasm_path));
    try std.testing.expectEqual(@as(manifest.QueueVerbMask, 0), host.slots[0].module_deny);
    try std.testing.expectEqual(manifest.QueueVerb.damage.bit(), host.slots[0].denied);
}

test "findByName matches display name and wasm stem suffix" {
    TestCtx.reset();
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(
        std.testing.allocator,
        &[_][]const u8{ "plugins/core_tradefeed/core_tradefeed.wasm", "assets/fixtures/plugin_hello.wasm" },
        &ctx,
        .{},
    );
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.n);
    host.slots[0].display = try std.testing.allocator.dupe(u8, "core_tradefeed");
    // Display name is what `plugin list` prints.
    try std.testing.expectEqual(@as(?usize, 0), host.findByName("core_tradefeed"));
    // Stem suffix: `plugin reload hello` matches plugin_hello.wasm.
    try std.testing.expectEqual(@as(?usize, 1), host.findByName("hello"));
    try std.testing.expectEqual(@as(?usize, 1), host.findByName("plugin_hello.wasm"));
    try std.testing.expectEqual(@as(?usize, null), host.findByName(""));
    try std.testing.expectEqual(@as(?usize, null), host.findByName("no_such_mod"));
    host.shutdown();
    try std.testing.expectEqual(@as(usize, 0), host.n);
    try std.testing.expect(ctx.rt_slot[0] == null and ctx.plugin_slot[0] == null);
    try std.testing.expect(ctx.rt_slot[1] == null and ctx.plugin_slot[1] == null);
}

test "host_verbs is the _zdtd_requires vocabulary for host imports" {
    try std.testing.expectEqual(@as(usize, 10), host_verbs.len);
    var ctx = HostCtx{ .log_fn = undefined, .tick_fn = undefined, .queue_fn = undefined };
    try std.testing.expect(Plugin.isHostVerb("log", &ctx));
    try std.testing.expect(Plugin.isHostVerb("json_obj", &ctx));
    try std.testing.expect(Plugin.isHostVerb("config", &ctx));
    try std.testing.expect(!Plugin.isHostVerb("on_tick", &ctx));
    try std.testing.expect(!Plugin.isHostVerb("bot", &ctx));
    // sense/query are optional callbacks: declaring one against an owner that
    // never wired it would validate and then silently read 0 bytes, so the
    // capability is only accepted when the callback exists.
    try std.testing.expect(!Plugin.isHostVerb("sense", &ctx));
    try std.testing.expect(!Plugin.isHostVerb("query", &ctx));
    try std.testing.expect(!Plugin.isHostVerb("sense", null));
    ctx.sense_fn = &TestSense.sense;
    ctx.query_fn = &TestSense.query;
    try std.testing.expect(Plugin.isHostVerb("sense", &ctx));
    try std.testing.expect(Plugin.isHostVerb("query", &ctx));
}

test "the linker defines exactly the verbs the requires vocabulary accepts" {
    // The two lists are hand-written on purpose (per-import types in
    // imports.zig, validation names in wasm.zig): pin them as sets so an
    // import added to the linker without a declare name, or a declare name
    // without an import, goes red here instead of surfacing as a module
    // rejected with "unknown capability" or a missing import at instantiate
    // (composability review: requires vocabulary matches the host verbs).
    const defined = imports_mod.defined_verb_names;
    try std.testing.expectEqual(host_verbs.len, defined.len);
    inline for (host_verbs) |v| {
        var found = false;
        inline for (defined) |d| {
            if (std.mem.eql(u8, v, d)) found = true;
        }
        try std.testing.expect(found);
    }
}

const TestSense = struct {
    fn sense(_: *HostCtx, _: i16, _: []u8) usize {
        return 0;
    }
    fn query(_: *HostCtx, _: []const u8, _: []u8) usize {
        return 0;
    }
};

test "Hook.names is the _zdtd_requires vocabulary for hooks" {
    try std.testing.expectEqual(@typeInfo(Hook).@"enum".fields.len, Hook.names.len);
    inline for (@typeInfo(Hook).@"enum".fields, 0..) |f, i| {
        try std.testing.expectEqualStrings(f.name, Hook.names[i]);
    }
}

test "plugin reload withdraws after on_shutdown before deinit" {
    // HMR: on_shutdown may queue; the owner must withdraw that src after
    // shutdown and before deinit so the replacement (or a compacted neighbor
    // on failed reload) does not inherit the dying fiber's effects.
    const Cap = struct {
        var srcs: [4]i16 = undefined;
        var n: usize = 0;
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn withdrawFn(_: *HostCtx, src: i16) void {
            if (n < srcs.len) {
                srcs[n] = src;
                n += 1;
            }
        }
    };
    Cap.n = 0;
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .withdraw_fn = &Cap.withdrawFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    try std.testing.expectEqual(@as(usize, 1), Cap.n);
    try std.testing.expectEqual(@as(i16, 1), Cap.srcs[0]);
    Cap.n = 0;
    try std.testing.expect(!host.reload(0, "/no/such/plugin.wasm"));
    try std.testing.expectEqual(@as(usize, 1), Cap.n);
    try std.testing.expectEqual(@as(i16, 1), Cap.srcs[0]);
}

test "queue import attributes commands to the calling plugin slot" {
    TestCtx.reset();
    // Temporal composability plumbing: plugin_hello queues a spawn each of the
    // first ticks; the queue import must hand the owner the 1-based slot so a
    // disabled plugin's pending effects can be withdrawn by src.
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"assets/fixtures/plugin_hello.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    host.onTick();
    try std.testing.expectEqual(@as(i16, 1), TestCtx.last_src);
    try std.testing.expect(std.mem.startsWith(u8, TestCtx.last_cmd[0..TestCtx.last_len], "spawn"));
}

test "fps_bot.wasm integration: sense drives brain; aim/look, gating, memory-pursue" {
    // Loads the real committed bot brain and drives it through the host sense
    // import with a canned snapshot, proving the end-to-end sense→brain→queue
    // pipe (RFC 0001 §3 / ADR 0026). The brain must NOT be modified; this is
    // the host-side regression the uncommitted work dropped.
    const Cap = struct {
        // queueFn COPIES each command into owned bytes - the guest reuses one
        // `out` buffer per queue call, so storing a slice would alias.
        var queued: [8][64]u8 = undefined;
        var queued_n: usize = 0;
        var queued_len: [8]usize = undefined;
        var hide_player: bool = false;
        var show_zombie: bool = false;
        var show_flanker: bool = false;
        var with_trailer: bool = false;
        var bot_hp: f32 = 100;

        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn writeRec(b: []u8, base: usize, net: i32, kind: u8, is_self: u8, alive: u8, x: f32, y: f32, z: f32, hp: f32, yaw: f32, target: i32) void {
            // v4 (ADR 0037): 40-byte records (vy i32@28, target i32@32, wearing u8@36).
            const r = b[base .. base + 40];
            std.mem.writeInt(i32, r[0..4], net, .little);
            r[4] = kind;
            r[5] = is_self;
            r[6] = alive;
            r[7] = 0; // pad
            std.mem.writeInt(u32, r[8..12], @bitCast(x), .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(y), .little);
            std.mem.writeInt(u32, r[16..20], @bitCast(z), .little);
            std.mem.writeInt(u32, r[20..24], @bitCast(hp), .little);
            std.mem.writeInt(u32, r[24..28], @bitCast(yaw), .little);
            std.mem.writeInt(i32, r[28..32], 0, .little); // vy
            std.mem.writeInt(i32, r[32..36], target, .little);
            r[36] = 0; // wearing
        }
        // One 16-byte trailer record (RFC 0001 §3 event layout).
        fn writeEv(b: []u8, base: usize, kind: u8, a: i32, c: i32, amount: f32) void {
            const r = b[base .. base + 16];
            @memset(r, 0);
            r[0] = kind;
            std.mem.writeInt(i32, r[4..8], a, .little);
            std.mem.writeInt(i32, r[8..12], c, .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(amount), .little);
        }
        fn queryFn(_: *HostCtx, _: []const u8, _: []u8) usize {
            return 0;
        }

        fn senseFn(_: *HostCtx, _: i16, out: []u8) usize {
            // header: magic 'ZBS4' (24 bytes: magic, count, tick, self,
            // world_time, blood_moon), records at base 24.
            std.mem.writeInt(u32, out[0..4], 0x3453425a, .little);
            const count: u32 = if (hide_player)
                1
            else
                (if (show_zombie) @as(u32, 3) else @as(u32, 2)) + @as(u32, @intFromBool(show_flanker));
            std.mem.writeInt(u32, out[4..8], count, .little);
            std.mem.writeInt(u32, out[8..12], 1, .little);
            std.mem.writeInt(i32, out[12..16], 0, .little);
            std.mem.writeInt(u32, out[16..20], 1 * 24000 + 12 * 1000, .little); // world_time: day 1, noon
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon off
            var n: u32 = 0;
            // one bot at the origin (self), facing +45deg toward the visible
            // player (yaw = atan2(10,10)+90deg); hp is mutable so the dodge
            // phase can simulate the bot taking damage (100 -> 60).
            writeRec(out, 24, 1000, 2, 1, 1, 0.0, 0.0, 0.0, bot_hp, 2.356, -1);
            n += 1;
            if (!hide_player) {
                // a player at (10, 0, 10) unless hidden (LOS pull-down)
                writeRec(out, 24 + 40, 2000, 0, 0, 1, 10.0, 0.0, 10.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (show_zombie) {
                // a zombie CLOSER to the bot (9,10) than the player (10,10);
                // player-preference targeting must still pick the player.
                writeRec(out, 24 + 80, 3000, 1, 0, 1, 9.0, 0.0, 10.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (show_flanker) {
                // a player BEHIND the bot (facing +X, yaw 0) and closer than the
                // visible player: the FOV cone must exclude it.
                writeRec(out, 24 + @as(usize, n) * 40, 4000, 0, 0, 1, -12.0, 0.0, 0.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (with_trailer) {
                // v2 event trailer: a kind-4 bot-info record (bot 1000 carries a
                // sniper, weapon_id 3) followed by a kind-3 damage event (player
                // 2000 hit bot 1000 for 42). The guest must keep parsing records
                // at the 32-byte stride and derive the trailer from the length.
                const eb = 24 + @as(usize, n) * 40;
                writeEv(out, eb, 4, 1000, 0, 0);
                out[eb + 1] = 3; // weapon_id sniper (loadout-pool index 3)
                writeEv(out, eb + 16, 3, 2000, 1000, 42.0);
                return 24 + @as(usize, n) * 40 + 40;
            }
            return 24 + @as(usize, n) * 40;
        }
    };
    Cap.queued_n = 0;
    Cap.hide_player = false;

    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
        // The bot declares `sense,query,...` in its _zdtd_requires, and a
        // declared optional capability is only accepted when the owner wired
        // it (otherwise the guest would read 0 bytes forever). This test drives
        // the sense path, so query answers nothing but must exist.
        .query_fn = &Cap.queryFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/fps_bot/fps_bot.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    // The bot module exports the lifecycle hooks we rely on.
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_admin_command)]);

    // Admin command round-trip: bot help is handled by the brain, not the core.
    var out: [4096]u8 = undefined;
    const rep = host.adminCommand("bot help", &out);
    try std.testing.expect(rep != null);
    try std.testing.expect(std.mem.find(u8, rep.?, "bot help") != null);

    // Tick 1 (player visible): the brain aims and moves on the player.
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expect(Cap.queued_n >= 2);
    var saw_move = false;
    var saw_look = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        const s = c[0..Cap.queued_len[qi]];
        if (std.mem.startsWith(u8, s, "bot move 1000")) saw_move = true;
        if (std.mem.startsWith(u8, s, "bot look 1000")) saw_look = true;
    }
    try std.testing.expect(saw_move);
    try std.testing.expect(saw_look);

    // Per-bot skill override: after tick 1 the roster knows bot 1000, so
    // `bot skill 4 1000` must reply with the id it targeted.
    var skill_out: [256]u8 = undefined;
    const srep = host.adminCommand("bot skill 4 1000", &skill_out);
    try std.testing.expect(srep != null);
    try std.testing.expect(std.mem.find(u8, srep.?, "id=1000") != null);

    // Roster integrity: the brain locked the player (2000) as its target, so
    // `bot list` must show a valid, non-garbage target for bot 1000.
    var list_out: [512]u8 = undefined;
    const lrep = host.adminCommand("bot list", &list_out);
    try std.testing.expect(lrep != null);
    try std.testing.expect(std.mem.find(u8, lrep.?, "id=1000") != null);
    try std.testing.expect(std.mem.find(u8, lrep.?, "target=2000") != null);

    // Per-bot `bot cfg` overrides parse and reply; unknown keys are rejected.
    // vision/reaction are reset to the skill default (0) right after so the
    // later phases still engage the player at range 14.
    var cfg_out: [256]u8 = undefined;
    const c1 = host.adminCommand("bot cfg 1000 vision 5", &cfg_out);
    try std.testing.expect(c1 != null and std.mem.find(u8, c1.?, "cfg set") != null);
    const c2 = host.adminCommand("bot cfg 1000 reaction 1", &cfg_out);
    try std.testing.expect(c2 != null and std.mem.find(u8, c2.?, "cfg set") != null);
    const c3 = host.adminCommand("bot cfg 1000 bogus 1", &cfg_out);
    try std.testing.expect(c3 != null and std.mem.find(u8, c3.?, "unknown key") != null);
    const c4 = host.adminCommand("bot cfg 1000 vision 0", &cfg_out);
    try std.testing.expect(c4 != null and std.mem.find(u8, c4.?, "cfg set") != null);
    const c5 = host.adminCommand("bot cfg 1000 reaction 0", &cfg_out);
    try std.testing.expect(c5 != null and std.mem.find(u8, c5.?, "cfg set") != null);

    // Tick 2 (identical scene): command gating suppresses redundant move/look.
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 0), Cap.queued_n);

    // Tick 3 (player hidden): the brain keeps hunting the last-known position.
    Cap.hide_player = true;
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expect(Cap.queued_n >= 1);
    var found_pursue = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        if (std.mem.find(u8, c[0..Cap.queued_len[qi]], "10.00 0.00 10.00") != null) found_pursue = true;
    }
    try std.testing.expect(found_pursue);

    // Tick 4 (dodge-on-hit): player visible again and the bot took damage
    // (hp 100 -> 60). The brain must enter an evasive dodge and FORCE a move at
    // the dodge speed (4.00 - no other branch uses it), bypassing command
    // gating even though the scene is otherwise unchanged.
    Cap.hide_player = false;
    Cap.bot_hp = 60;
    Cap.queued_n = 0;
    host.onTick();
    var found_dodge = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        const s = c[0..Cap.queued_len[qi]];
        if (std.mem.startsWith(u8, s, "bot move ") and std.mem.endsWith(u8, s, " 4.00")) found_dodge = true;
    }
    try std.testing.expect(found_dodge);

    // Tick 5+ (fire phase): the static scene stays (bot hp 60, no further
    // damage), so the dodge expires and the reaction gate runs down. A zombie
    // appears CLOSER to the bot than the player, so player-preference targeting
    // must still make the brain fire at the player (2000). The brain must queue
    // `bot shoot 1000 2000` (optionally flagged `head`), proving both the fire
    // path and the target preference work end-to-end.
    Cap.show_zombie = true;
    Cap.show_flanker = true; // closer player behind the bot: FOV must exclude it
    var found_shoot = false;
    var burst_count: usize = 0;
    var fire_ticks: usize = 0;
    while (fire_ticks < 16 and !found_shoot) : (fire_ticks += 1) {
        Cap.queued_n = 0;
        host.onTick();
        var tick_shoots: usize = 0;
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot shoot 1000 2000")) {
                found_shoot = true;
                tick_shoots += 1;
            }
        }
        burst_count = tick_shoots;
    }
    try std.testing.expect(found_shoot);
    // Burst volley: at least two shots queued in the firing tick (skill 2 => 2).
    try std.testing.expect(burst_count >= 2);

    // Tick (flee phase): a nearly-dead bot (hp 15, 0.15 < HP_FLEE_FRAC) of ANY
    // skill (skill 4 was set earlier) must retreat and HOLD fire - no shoot is
    // queued across several ticks, while it still moves (backpedal).
    Cap.bot_hp = 15;
    var flee_ticks: usize = 0;
    var saw_flee_move = false;
    var saw_flee_shoot = false;
    while (flee_ticks < 4) : (flee_ticks += 1) {
        Cap.queued_n = 0;
        host.onTick();
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot move ")) saw_flee_move = true;
            if (std.mem.startsWith(u8, s, "bot shoot ")) saw_flee_shoot = true;
        }
    }
    try std.testing.expect(saw_flee_move);
    try std.testing.expect(!saw_flee_shoot);

    // Stuck juke: with the player hidden and the bot unable to move (the canned
    // host never integrates, so its position is static), the memory-pursue dest
    // is juked perpendicularly after STUCK_TICKS and a NEW move (not the plain
    // 10,10) is queued, instead of grinding forever.
    Cap.hide_player = true;
    var juked = false;
    var k: usize = 0;
    while (k < 26) : (k += 1) {
        Cap.queued_n = 0;
        host.onTick();
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot move ") and std.mem.find(u8, s, "10.00 0.00 10.00") == null) juked = true;
        }
    }
    try std.testing.expect(juked);

    // Trailer phase: a sense pass that ALSO carries kind-4 bot-info (sniper)
    // and kind-3 damage-event records (player 2000 hit bot 1000 for 42) must
    // not desync the brain's record offsets - it still tracks and drives on
    // the player (the grudge keeps it locked), proving the v2 event trailer
    // parses end-to-end (RFC 0001 §3).
    Cap.with_trailer = true;
    Cap.hide_player = false;
    Cap.bot_hp = 58;
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expect(Cap.queued_n >= 1);
    var trailer_drove = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        const s = c[0..Cap.queued_len[qi]];
        if (std.mem.startsWith(u8, s, "bot look 1000") or std.mem.startsWith(u8, s, "bot move 1000")) trailer_drove = true;
    }
    try std.testing.expect(trailer_drove);
    var list2_out: [512]u8 = undefined;
    const l2 = host.adminCommand("bot list", &list2_out);
    try std.testing.expect(l2 != null);
    try std.testing.expect(std.mem.find(u8, l2.?, "target=2000") != null); // grudge holds the player

    // Ammo/reload phase: the trailer gives bot 1000 a SNIPER (weapon_id 3,
    // mag 5, burst 1, ~0.6 s between shots). Firing must run the mag dry and
    // then hold fire through a reload gap (weapon_reload 2.5 s = 50 ticks)
    // before resuming - proving ammo pacing end-to-end (RFC 0001 §5.1).
    var shoot_ticks: [64]usize = undefined;
    var shoot_n: usize = 0;
    var t: usize = 0;
    while (t < 200 and shoot_n < shoot_ticks.len) : (t += 1) {
        Cap.queued_n = 0;
        host.onTick();
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot shoot ")) {
                if (shoot_n < shoot_ticks.len) shoot_ticks[shoot_n] = t;
                shoot_n += 1;
            }
        }
    }
    // At least two shots (before AND after the reload).
    try std.testing.expect(shoot_n >= 2);
    // The reload window: a gap of at least ~2 s between shots (throttle alone
    // is ~0.6 s; the 2.5 s reload is the only way to see a 45+ tick gap).
    var max_gap: usize = 0;
    var gi: usize = 1;
    while (gi < shoot_n) : (gi += 1) {
        const gap = shoot_ticks[gi] - shoot_ticks[gi - 1];
        if (gap > max_gap) max_gap = gap;
    }
    try std.testing.expect(max_gap >= 45);

    // No module exhausted fuel or trapped through the whole sequence.
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "mcp.wasm: MCP protocol core (session, ping, tools, errors)" {
    // The MCP addon guest (ADR 0031, docs/rfc/0002-mcp-server-design.md M1): the host feeds a
    // client JSON-RPC frame through the on_mcp_frame hook and gets the guest's
    // response back. The guest owns protocol logic; JSON parsing is the host
    // std.json capability; the sense/query surfaces here stand in for the real
    // transport bridge.
    const Cap = struct {
        var sense_enabled: bool = false;
        var queued: [4][64]u8 = undefined;
        var queued_len: [4]usize = undefined;
        var queued_n: usize = 0;

        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        fn writeRec(b: []u8, base: usize, net: i32, kind: u8, x: f32, y: f32, z: f32, hp: f32) void {
            // v4 (ADR 0037): 40-byte records (vy i32@28, target i32@32, wearing u8@36).
            const r = b[base .. base + 40];
            std.mem.writeInt(i32, r[0..4], net, .little);
            r[4] = kind;
            r[5] = 0; // is_self
            r[6] = 1; // alive
            r[7] = 0; // pad
            std.mem.writeInt(u32, r[8..12], @bitCast(x), .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(y), .little);
            std.mem.writeInt(u32, r[16..20], @bitCast(z), .little);
            std.mem.writeInt(u32, r[20..24], @bitCast(hp), .little);
            std.mem.writeInt(u32, r[24..28], @bitCast(@as(f32, 0.0)), .little);
            std.mem.writeInt(i32, r[28..32], 0, .little); // vy
            std.mem.writeInt(i32, r[32..36], -1, .little); // target
            r[36] = 0; // wearing
        }
        fn senseFn(_: *HostCtx, _: i16, out: []u8) usize {
            if (!sense_enabled) return 0;
            // header: magic 'ZBS4' (24 bytes), 2 records, tick 42, self -1
            std.mem.writeInt(u32, out[0..4], 0x3453425a, .little);
            std.mem.writeInt(u32, out[4..8], 2, .little);
            std.mem.writeInt(u32, out[8..12], 42, .little);
            std.mem.writeInt(i32, out[12..16], -1, .little);
            std.mem.writeInt(u32, out[16..20], 0, .little); // world_time
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon
            writeRec(out, 24, 2000, 0, 10.0, 0.0, 10.0, 100.0); // player
            writeRec(out, 64, 3000, 1, 9.0, 0.0, 10.0, 100.0); // zombie
            return 24 + 80;
        }
        fn queryFn(_: *HostCtx, req: []const u8, out: []u8) usize {
            if (!std.mem.eql(u8, req, "mcp.allowlist")) return 0;
            const allow = "bot count\nsay";
            const n = @min(out.len, allow.len);
            @memcpy(out[0..n], allow[0..n]);
            return n;
        }
    };
    Cap.queued_n = 0;
    Cap.sense_enabled = false;

    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
        .query_fn = &Cap.queryFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/mcp/mcp.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    const p = &host.slots[0];
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_mcp_frame)]);
    try std.testing.expect(!p.requires_failed);

    var out: [8192]u8 = undefined;

    // Malformed JSON is a parse error, not a crash.
    {
        const rep = p.callMcpFrame("{nope", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32700") != null);
    }
    // Batches are refused with Invalid Request.
    {
        const rep = p.callMcpFrame("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32600") != null);
    }
    // tools/list before initialize is not allowed (spec -32002).
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32002") != null);
    }
    // ping is allowed pre-initialize and echoes the id.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", rep.?);
    }
    // initialize negotiates the pinned spec version and capabilities.
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":" ++
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"id\":7") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"protocolVersion\":\"2025-06-18\"") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"serverInfo\"") != null);
    }
    // Re-initialize is refused.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"initialize\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32600") != null);
    }
    // The initialized notification gets no response and unlocks the tools.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}", &out);
        try std.testing.expect(rep == null);
    }
    // tools/list now lists the registry.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"tools\":[") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"name\":\"server_status\"") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"name\":\"admin_command\"") != null);
    }
    // Unknown tool and missing name are Invalid Params.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32602") != null);
    }
    // Read tool without a sense surface fails closed (isError, not fake data).
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"server_status\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "no world data available") != null);
    }
    // With a snapshot the same tool reports real host data.
    Cap.sense_enabled = true;
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"server_status\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "ticks=42") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "players=1") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "zombies=1") != null);
    }
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"player_list\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "id=2000") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "x=10.0") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "hp=100.0") != null);
    }
    // admin_command: allowlisted verb queues through the plugin boundary...
    Cap.queued_n = 0;
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{\"verb\":\"bot count 6\"}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"result\"") != null);
        try std.testing.expectEqual(@as(usize, 1), Cap.queued_n);
        try std.testing.expect(std.mem.eql(u8, Cap.queued[0][0..Cap.queued_len[0]], "bot count 6"));
    }
    // ...an unlisted verb is denied by the allowlist policy.
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{\"verb\":\"kick Bob\"}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "verb not in allowlist") != null);
    }
    // admin_command without a verb is Invalid Params.
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32602") != null);
    }
    // No module trapped or exhausted fuel through the whole sequence.
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_perkgate.wasm denies forbidden_* perk spends via on_perk_spend" {
    TestCtx.reset();
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_perkgate/core_perkgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_perk_spend)]);
    // Deny a forbidden-named perk spend; keep everything else.
    try std.testing.expectEqual(@as(i32, -1), host.perkSpend(100, "forbidden_evil", 1, 1));
    try std.testing.expectEqual(@as(i32, 0), host.perkSpend(100, "perkLightEater", 1, 1));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "parachute.wasm deploys glide on a falling worn player and clears on landing (ADR 0037)" {
    const Cap = struct {
        var queued: [8][48]u8 = undefined;
        var queued_len: [8]usize = undefined;
        var queued_n: usize = 0;
        var vy: f32 = 0;

        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        // One player record (net 2000, kind 0) at the v4 40-byte stride with a
        // mutable vy and wearing_glider=1 (the armor-slot tag was resolved
        // server-side).
        fn writePlayer(b: []u8) void {
            const base: usize = 24;
            const r = b[base .. base + 40];
            @memset(r, 0);
            std.mem.writeInt(i32, r[0..4], 2000, .little);
            r[4] = 0; // kind player
            r[6] = 1; // alive
            std.mem.writeInt(u32, r[28..32], @bitCast(vy), .little); // f32 bit pattern
            r[36] = 1; // wearing_glider
        }
        fn senseFn(_: *HostCtx, _: i16, out: []u8) usize {
            if (out.len < 24 + 40) return 0;
            std.mem.writeInt(u32, out[0..4], 0x3453425a, .little); // 'ZBS4'
            std.mem.writeInt(u32, out[4..8], 1, .little); // count
            std.mem.writeInt(u32, out[8..12], 1, .little); // tick
            std.mem.writeInt(i32, out[12..16], -1, .little); // self
            std.mem.writeInt(u32, out[16..20], 0, .little); // world_time
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon
            writePlayer(out);
            return 24 + 40;
        }
    };
    Cap.queued_n = 0;
    Cap.vy = 0;

    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/parachute/parachute.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(!host.slots[0].requires_failed);

    // Not falling: no deploy, no queue.
    Cap.vy = -2.0;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 0), Cap.queued_n);

    // Falling fast: deploy after the debounce window (default delay 10 ticks).
    Cap.vy = -12.0;
    var t: usize = 0;
    while (t < 12) : (t += 1) host.onTick();
    var saw_arm = false;
    for (Cap.queued[0..Cap.queued_n]) |*c| {
        if (std.mem.eql(u8, c[0..Cap.queued_len[0]], "glide 2000 1")) saw_arm = true;
    }
    try std.testing.expect(saw_arm);

    // Landed (vy near zero): clear the glide.
    Cap.vy = 0.0;
    host.onTick();
    var saw_clear = false;
    for (Cap.queued[0..Cap.queued_n]) |*c| {
        if (std.mem.eql(u8, c[0..Cap.queued_len[0]], "glide 2000 0")) saw_clear = true;
    }
    try std.testing.expect(saw_clear);
}

test "parachute.wasm announce text survives on_enable's stack frame" {
    // The guest parses config out of a stack buffer in on_enable; keeping the
    // value as a slice into that buffer meant a later tick's announcement read
    // a dead frame. The text must still be intact when the deploy fires, which
    // is several hook calls after on_enable returned.
    const announce = "rode the silk down";
    const Cap = struct {
        var queued: [8][64]u8 = undefined;
        var queued_len: [8]usize = undefined;
        var queued_n: usize = 0;
        var vy: f32 = 0;

        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        fn senseFn(_: *HostCtx, _: i16, out: []u8) usize {
            if (out.len < 24 + 40) return 0;
            std.mem.writeInt(u32, out[0..4], 0x3453425a, .little); // 'ZBS4'
            std.mem.writeInt(u32, out[4..8], 1, .little); // count
            std.mem.writeInt(u32, out[8..12], 1, .little); // tick
            std.mem.writeInt(i32, out[12..16], -1, .little); // self
            std.mem.writeInt(u32, out[16..20], 0, .little); // world_time
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon
            const r = out[24..64];
            @memset(r, 0);
            std.mem.writeInt(i32, r[0..4], 2000, .little);
            r[6] = 1; // alive
            std.mem.writeInt(u32, r[28..32], @bitCast(vy), .little);
            r[36] = 1; // wearing_glider
            return 24 + 40;
        }
    };
    Cap.queued_n = 0;
    Cap.vy = 0;

    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/parachute/parachute.wasm"}, &ctx, .{});
    defer host.shutdown();
    // Config must be in place before on_enable: that is the call whose stack
    // frame used to back the stored slice. The value is quoted and carries a
    // trailing comment, exactly as plugin_common.Config handles it, so the
    // guest's hand-rolled parser must strip both.
    host.slots[0].config_bytes = "announce_text = \"" ++ announce ++ "\"  # trailing comment\n";
    defer host.slots[0].config_bytes = "";
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());

    Cap.vy = -12.0;
    var t: usize = 0;
    while (t < 12) : (t += 1) host.onTick();

    var saw_announce = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, i| {
        if (std.mem.eql(u8, c[0..Cap.queued_len[i]], announce)) saw_announce = true;
    }
    try std.testing.expect(saw_announce);

    // Now the real shipped config.toml, not a synthetic string: its values are
    // quoted, and a parser that does not strip the quotes broadcasts them.
    const shipped = try io_fs.readFileAll(std.testing.allocator, "mods/parachute/config.toml");
    defer std.testing.allocator.free(shipped);
    host.slots[0].config_bytes = shipped;
    _ = host.slots[0].callHook(.on_enable);
    // Land first: the roster still has this player gliding from the phase
    // above, and the deploy announcement only fires on the 0 -> 1 edge.
    Cap.vy = 0.0;
    host.onTick();
    Cap.queued_n = 0;
    Cap.vy = -12.0;
    t = 0;
    while (t < 12) : (t += 1) host.onTick();
    var saw_shipped = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, i| {
        if (std.mem.eql(u8, c[0..Cap.queued_len[i]], "deployed their parachute")) saw_shipped = true;
    }
    try std.testing.expect(saw_shipped);
}

test "a legacy [plugin] modules slot is not manifest-backed" {
    TestCtx.reset();
    // Composability review: loadResolved marked every plan entry
    // manifest_loaded, including the synthetic manifests the resolver
    // fabricates for `[plugin] modules` paths (dir ""). Those never had a
    // manifest.toml read for them, so a reload re-read whatever
    // `manifest.toml` happened to sit beside the .wasm (adopting point claims
    // and a deny list the boot path never applied), and when none sat there
    // the config.toml bytes loaded at boot were dropped instead of preserved.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    // A .wasm with a config.toml beside it and NO manifest.toml: the shape an
    // operator gets from `modules = ["<path>.wasm"]`.
    const wasm_path = try std.Io.Dir.path.join(a, &.{ dir, "legacy.wasm" });
    defer a.free(wasm_path);
    const cfg_path = try std.Io.Dir.path.join(a, &.{ dir, "config.toml" });
    defer a.free(cfg_path);
    try io_fs.writeFile(wasm_path, &declaring_test_wasm);
    try io_fs.writeFile(cfg_path, "greeting = \"hi\"\n");

    var modules = [_]resolver.ResolvedModule{
        .{ .manifest = .{ .name = wasm_path, .dir = "", .wasm = wasm_path }, .tier = .user, .slot = 0 },
    };
    var plan: resolver.ResolvedResult = .{ .modules = &modules, .point_claims = .{}, .name_to_slot = .{}, .synthetic = &.{} };
    defer plan.point_claims.deinit(a);
    defer plan.name_to_slot.deinit(a);

    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    defer host.shutdown();
    host.loadResolved(a, &plan, &ctx, .{});
    try std.testing.expectEqual(@as(usize, 1), host.n);
    try std.testing.expect(!host.slots[0].manifest_loaded);
    try std.testing.expectEqualStrings("greeting = \"hi\"\n", host.slots[0].config_bytes);

    // HMR keeps the boot-time config instead of failing closed to none on a
    // manifest.toml that was never part of this module's load.
    try std.testing.expect(host.reload(0, host.slots[0].name));
    try std.testing.expectEqualStrings("greeting = \"hi\"\n", host.slots[0].config_bytes);
}

test "enable activates each instance once and a reload reactivates its replacement" {
    TestCtx.reset();
    // Paper inverse/double: `on_enable` is an initializer, so re-running it
    // is additive (each run queues/logs again). The activation latch makes
    // enable() idempotent per instance, and a reload's fresh instance gets
    // exactly one activation beside its on_enable. plugin_hello's on_enable
    // logs "hello enabled" (the shutdown log and tick logs are filtered out).
    TestCtx.match("hello enabled");
    var ctx = TestCtx.ctx();
    var host: WasmHost = .{};
    const path = "assets/fixtures/plugin_hello.wasm";
    host.loadAll(std.testing.allocator, &[_][]const u8{path}, &ctx, .{ .fuel = 1_000_000 });
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());

    host.enable();
    try std.testing.expectEqual(@as(usize, 1), TestCtx.matched_n);
    // Second enable: the latch skips the already-activated instance.
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), TestCtx.matched_n);

    // Reload disposes the old instance and activates its replacement once.
    try std.testing.expect(host.reload(0, path));
    try std.testing.expect(host.slots[0].activated);
    try std.testing.expectEqual(@as(usize, 2), TestCtx.matched_n);
    host.enable();
    try std.testing.expectEqual(@as(usize, 2), TestCtx.matched_n);
}

test "plugin reload replays the boot declaration rule (review F8)" {
    TestCtx.reset();
    // A manifest-backed slot booted through the strict path must not reload a
    // replacement that dropped `_zdtd_requires`: HMR holds the same fail-closed
    // rule as the restart it stands in for. The slot records which rule it
    // booted under, `reload` replays it, and the refused replacement leaves the
    // active range. The raw fixture path (in-repo C modules, `--export-all`)
    // keeps its permissive rule, proven by the same swap loading there.
    var ctx = TestCtx.ctx();
    const a = std.testing.allocator;

    // Strict boot (the discovered-mod rule), then the swap to undeclared.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
        const wasm_path = try std.Io.Dir.path.join(a, &.{ dir, "m.wasm" });
        defer a.free(wasm_path);
        const man_path = try std.Io.Dir.path.join(a, &.{ dir, "manifest.toml" });
        defer a.free(man_path);
        try io_fs.writeFile(wasm_path, &declaring_test_wasm);
        try io_fs.writeFile(man_path, "name = \"m\"\nwasm = \"m.wasm\"\n");
        var host: WasmHost = .{};
        host.allocator = a;
        host.ctx = &ctx;
        host.budget = .{};
        defer host.shutdown();
        ctx.require_declaration = true;
        try host.loadInto(0, wasm_path);
        host.n = 1;
        host.slots[0].manifest_loaded = true;
        host.slots[0].display = try a.dupe(u8, "m");
        // The boot rule the slot ran under is recorded for the reload...
        try std.testing.expect(host.slots[0].require_declaration);
        // ...and boot restores the host flag, like loadResolved's save/restore.
        ctx.require_declaration = false;

        try io_fs.writeFile(wasm_path, &undeclared_test_wasm);
        try std.testing.expect(!host.reload(0, wasm_path));
        // The refused replacement leaves the active range (same as a restart
        // that would refuse it: the composition keeps only loadable modules).
        try std.testing.expectEqual(@as(usize, 0), host.n);
    }

    // The same swap on a raw-path slot (in-repo fixture rule) loads: the flag
    // is what the replay honors, not a global switch.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
        const wasm_path = try std.Io.Dir.path.join(a, &.{ dir, "m.wasm" });
        defer a.free(wasm_path);
        const man_path = try std.Io.Dir.path.join(a, &.{ dir, "manifest.toml" });
        defer a.free(man_path);
        try io_fs.writeFile(wasm_path, &declaring_test_wasm);
        try io_fs.writeFile(man_path, "name = \"m\"\nwasm = \"m.wasm\"\n");
        var host: WasmHost = .{};
        host.allocator = a;
        host.ctx = &ctx;
        host.budget = .{};
        defer host.shutdown();
        try host.loadInto(0, wasm_path); // ctx flag still false: raw rule
        host.n = 1;
        host.slots[0].manifest_loaded = true;
        host.slots[0].display = try a.dupe(u8, "m");
        try std.testing.expect(!host.slots[0].require_declaration);

        try io_fs.writeFile(wasm_path, &undeclared_test_wasm);
        try std.testing.expect(host.reload(0, wasm_path));
        try std.testing.expectEqual(@as(usize, 1), host.n);
    }
}

test "reconcileClaims keeps claims and module deny when the manifest is invalid (review F9)" {
    TestCtx.reset();
    // The on-disk declaration is read first and state changes only on
    // success: an unreadable or invalid manifest must not release an
    // installed point claim or lift the module's queued-verb deny (the boot
    // path would refuse that manifest outright; the reload keeps the
    // declaration it booted with until a restart re-reads it).
    var ctx = TestCtx.ctx();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    const wasm_path = try std.Io.Dir.path.join(a, &.{ dir, "m.wasm" });
    defer a.free(wasm_path);
    const man_path = try std.Io.Dir.path.join(a, &.{ dir, "manifest.toml" });
    defer a.free(man_path);

    // The claimant exports on_loot_roll and declares its spec, so a strict
    // boot accepts it (discovered-mod rule).
    const trap = try io_fs.readFileAll(a, "assets/fixtures/plugin_claim_trap.wasm");
    defer a.free(trap);
    try io_fs.writeFile(wasm_path, trap);
    try io_fs.writeFile(man_path, "name = \"m\"\nwasm = \"m.wasm\"\npoints = \"loot.roll\"\ndeny = \"say\"\n");
    var host: WasmHost = .{};
    host.allocator = a;
    host.ctx = &ctx;
    host.budget = .{};
    defer host.shutdown();
    ctx.require_declaration = true;
    try host.loadInto(0, wasm_path);
    ctx.require_declaration = false;
    host.n = 1;
    host.slots[0].manifest_loaded = true;
    host.slots[0].display = try a.dupe(u8, "m");

    const loot = @intFromEnum(manifest.OverridePoint.loot_roll);
    host.reconcileClaims(0, wasm_path);
    try std.testing.expectEqual(@as(u8, 0), host.claims[loot]);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].module_deny);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].denied);

    // Corrupt the manifest: bind now fails, and the failure must leave both
    // the claim and the deny exactly as they were.
    try io_fs.writeFile(man_path, "name = \"m\"\npoints = [ broken\n");
    host.reconcileClaims(0, wasm_path);
    try std.testing.expectEqual(@as(u8, 0), host.claims[loot]);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].module_deny);
    try std.testing.expectEqual(manifest.QueueVerb.say.bit(), host.slots[0].denied);
}
