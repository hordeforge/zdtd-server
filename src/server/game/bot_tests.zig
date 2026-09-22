//! Bot manager tests: names, moves, collisions.
//!
//! Split out of server/game/bot.zig (same tests, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const bot = @import("bot.zig");
const BotManager = bot.BotManager;
const stepMove = bot.stepMove;
const Bot = bot.Bot;
const bot_headshot_multiplier = bot.bot_headshot_multiplier;
const bot_shoot_damage = bot.bot_shoot_damage;
const max_sense_events = bot.max_sense_events;
const max_sense_info = bot.max_sense_info;
const sense_event_len = bot.sense_event_len;
const sense_record_len = bot.sense_record_len;

test "Bot.setName truncates on a UTF-8 codepoint boundary" {
    // name[] is 24 bytes with a trailing NUL, so the payload budget is 23.
    // Eight CJK ideographs are 24 bytes; a byte @min would keep a dangling
    // lead and put invalid UTF-8 into the player-mesh spawn body.
    var b: Bot = .{};
    b.setName("名" ** 8);
    try std.testing.expectEqual(@as(usize, 21), b.name_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(b.name[0..b.name_len]));
    try std.testing.expectEqualStrings("名" ** 7, b.name[0..b.name_len]);
}

test "BotManager find/move/look/remove/removeAll on hand-seeded bots" {
    var m: BotManager = .{};
    // Data-only: spawn needs a Game for net ids, so seed two live bots by hand.
    m.bots[0] = .{ .net_id = 100, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 101, .x = 10, .y = 70, .z = 10, .hp = 80, .alive = true };
    m.n = 2;

    try std.testing.expectEqual(@as(?usize, 0), m.find(100));
    try std.testing.expectEqual(@as(?usize, 1), m.find(101));
    try std.testing.expect(m.find(999) == null);
    try std.testing.expect(m.find(-1) == null);

    // move sets intent.
    m.move(100, 4, 71, 0, 2);
    try std.testing.expect(m.bots[0].move_active);
    try std.testing.expectApproxEqAbs(@as(f32, 4), m.bots[0].dest_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), m.bots[0].speed, 0.001);

    // look sets yaw.
    m.look(101, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 90), m.bots[1].yaw, 0.001);

    // Unknown ids are no-ops.
    m.move(999, 1, 1, 1, 1);
    m.look(999, 1);
    m.remove(999);
    try std.testing.expectEqual(@as(usize, 2), m.n);

    // remove frees the slot; removeAll clears everything.
    m.remove(101);
    try std.testing.expectEqual(@as(usize, 1), m.n);
    try std.testing.expect(m.find(101) == null);
    m.removeAll(0);
    try std.testing.expectEqual(@as(usize, 0), m.n);
    try std.testing.expect(m.find(100) == null);
}

test "BotManager move integration steps toward dest without overshooting" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 100, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 101, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true, .move_active = true, .dest_x = 10, .dest_y = 70, .dest_z = 0, .speed = 4 };
    m.n = 2;

    // stepMove is tick's per-bot integration; exercised directly so the math
    // is testable without constructing a full Game.
    stepMove(&m.bots[1], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), m.bots[1].x, 0.001);
    try std.testing.expect(m.bots[1].move_active);

    // Four more half-second steps (2 m each) land at exactly dest (no
    // overshoot). As in the old ECS tick, an exact landing via the step branch
    // snaps the position but leaves the intent set; the arrival check clears it
    // on the next call (distance now 0).
    stepMove(&m.bots[1], 0.5);
    stepMove(&m.bots[1], 0.5);
    stepMove(&m.bots[1], 0.5);
    stepMove(&m.bots[1], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 10), m.bots[1].x, 0.001);
    try std.testing.expect(m.bots[1].move_active);
    stepMove(&m.bots[1], 0.5);
    try std.testing.expect(!m.bots[1].move_active);

    // y snaps to dest_y on every step.
    try std.testing.expectApproxEqAbs(@as(f32, 70), m.bots[1].y, 0.001);
    m.bots[1].dest_y = 71;
    m.bots[1].move_active = true;
    stepMove(&m.bots[1], 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 71), m.bots[1].y, 0.001);

    // A bot without move_active never moves.
    const x0 = m.bots[0].x;
    stepMove(&m.bots[0], 1);
    try std.testing.expectApproxEqAbs(x0, m.bots[0].x, 0.001);
}

test "BotManager fillSense writes the fixed 40-byte sense layout (v4)" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 100, .x = 1.5, .y = 70.25, .z = -3.5, .yaw = 45, .hp = 60, .alive = true };
    m.bots[1] = .{ .net_id = 101, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 2;

    var out: [16 + 2 * sense_record_len]u8 = [_]u8{0} ** (16 + 2 * sense_record_len);
    var n: usize = 0;
    m.fillSense(&out, 16, 2, &n);
    try std.testing.expectEqual(@as(usize, 2), n);

    const r0 = out[16 .. 16 + sense_record_len];
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, r0[0..4], .little));
    try std.testing.expectEqual(@as(u8, 2), r0[4]); // kind bot
    try std.testing.expectEqual(@as(u8, 0), r0[5]); // self
    try std.testing.expectEqual(@as(u8, 1), r0[6]); // alive
    try std.testing.expectEqual(@as(u8, 0), r0[7]); // pad
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), @as(f32, @bitCast(std.mem.readInt(u32, r0[8..12], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 70.25), @as(f32, @bitCast(std.mem.readInt(u32, r0[12..16], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -3.5), @as(f32, @bitCast(std.mem.readInt(u32, r0[16..20], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), @as(f32, @bitCast(std.mem.readInt(u32, r0[20..24], .little))), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), @as(f32, @bitCast(std.mem.readInt(u32, r0[24..28], .little))), 0.001);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, r0[28..32], .little)); // vy
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, r0[32..36], .little)); // target
    try std.testing.expectEqual(@as(u8, 0), r0[36]); // wearing

    // Dead bots are skipped.
    m.bots[1].alive = false;
    m.n = 1;
    n = 0;
    m.fillSense(&out, 16, 2, &n);
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "BotManager damageBot applies headshot multiplier and can kill" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 20, .alive = true };
    m.bots[1] = .{ .net_id = 11, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 2;

    // Plain shot: 100 - 12 = 88.
    try std.testing.expect(m.damageBot(11, bot_shoot_damage));
    try std.testing.expectApproxEqAbs(@as(f32, 88), m.bots[1].hp, 0.01);

    // Headshot (multiplier 2x): 88 - 24 = 64.
    try std.testing.expect(m.damageBot(11, bot_shoot_damage * bot_headshot_multiplier));
    try std.testing.expectApproxEqAbs(@as(f32, 64), m.bots[1].hp, 0.01);

    // Lethal headshot kills the 40 hp bot and drops the live count.
    try std.testing.expect(m.damageBot(10, bot_shoot_damage * bot_headshot_multiplier));
    try std.testing.expect(!m.bots[0].alive);
    try std.testing.expectEqual(@as(usize, 1), m.n);

    // Unknown ids are a no-op.
    try std.testing.expect(!m.damageBot(999, bot_shoot_damage));
}

test "BotManager damageFrom attributes, records events, and can kill" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 11, .x = 0, .y = 70, .z = 0, .hp = 30, .alive = true };
    m.n = 2;

    // Attributed hit: hp drops, last_attacker records the shooter, an event is queued.
    try std.testing.expect(m.damageFrom(10, 12, 555));
    try std.testing.expectApproxEqAbs(@as(f32, 88), m.bots[0].hp, 0.01);
    try std.testing.expectEqual(@as(i32, 555), m.bots[0].last_attacker);
    try std.testing.expectEqual(@as(usize, 1), m.ev_n);
    try std.testing.expectEqual(@as(i32, 555), m.events[0].attacker);
    try std.testing.expectEqual(@as(i32, 10), m.events[0].victim);
    try std.testing.expectApproxEqAbs(@as(f32, 12), m.events[0].amount, 0.01);

    // Unknown targets are no-ops (no event, no state).
    try std.testing.expect(!m.damageFrom(999, 5, 555));
    try std.testing.expectEqual(@as(usize, 1), m.ev_n);

    // Lethal attributed hit kills and still events.
    try std.testing.expect(m.damageFrom(11, 30, 555));
    try std.testing.expect(!m.bots[1].alive);
    try std.testing.expectEqual(@as(usize, 1), m.n);
    try std.testing.expectEqual(@as(usize, 2), m.ev_n);
}

test "BotManager drainSenseEvents writes the 16-byte trailer layout and clears" {
    var m: BotManager = .{};
    m.events[0] = .{ .attacker = 7, .victim = 10, .amount = 12.5 };
    m.events[1] = .{ .attacker = -1, .victim = 11, .amount = 42 };
    m.ev_n = 2;

    var out: [128]u8 = [_]u8{0xAA} ** 128;
    const written = m.drainSenseEvents(&out, 16, max_sense_events);
    try std.testing.expectEqual(@as(usize, 2), written);

    const e0 = out[16..32];
    try std.testing.expectEqual(@as(u8, 3), e0[0]); // kind damage
    try std.testing.expectEqual(@as(u8, 0), e0[1]); // pad
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, e0[4..8], .little));
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, e0[8..12], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), @as(f32, @bitCast(std.mem.readInt(u32, e0[12..16], .little))), 0.001);

    const e1 = out[32..48];
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, e1[4..8], .little));
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, e1[8..12], .little));

    // The buffer is cleared: a second drain writes nothing.
    try std.testing.expectEqual(@as(usize, 0), m.drainSenseEvents(&out, 16, max_sense_events));

    // Cap: at most `cap` events are written and the tail is untouched. Fill
    // the buffer through damageFrom (which itself caps at max_sense_events).
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 1;
    for (0..max_sense_events) |i| {
        try std.testing.expect(m.damageFrom(10, 1, @intCast(i)));
    }
    try std.testing.expectEqual(@as(usize, max_sense_events), m.ev_n);
    // Overflow events are dropped (the array is full, not grown).
    try std.testing.expect(m.damageFrom(10, 1, 99));
    try std.testing.expectEqual(@as(usize, max_sense_events), m.ev_n);
    var out2: [512]u8 = [_]u8{0xBB} ** 512;
    const capped = m.drainSenseEvents(&out2, 16, max_sense_events);
    try std.testing.expectEqual(@as(usize, max_sense_events), capped);
    try std.testing.expectEqual(@as(u8, 0xBB), out2[16 + max_sense_events * sense_event_len]);
}

test "BotManager fillSenseBotInfo writes one kind-4 record per live bot" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 100, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true, .weapon_id = 3 };
    m.bots[1] = .{ .net_id = 101, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true, .weapon_id = 1 };
    m.bots[2] = .{ .net_id = 102, .x = 0, .y = 70, .z = 0, .hp = 0, .alive = false }; // skipped
    m.n = 2;

    var out: [128]u8 = [_]u8{0xAA} ** 128;
    const written = m.fillSenseBotInfo(&out, 16, max_sense_info);
    try std.testing.expectEqual(@as(usize, 2), written);

    const rec0 = out[16..32];
    try std.testing.expectEqual(@as(u8, 4), rec0[0]); // kind bot-info
    try std.testing.expectEqual(@as(u8, 3), rec0[1]); // weapon_id sniper
    try std.testing.expectEqual(@as(i32, 100), std.mem.readInt(i32, rec0[4..8], .little));
    const rec1 = out[32..48];
    try std.testing.expectEqual(@as(u8, 1), rec1[1]); // weapon_id shotgun
    try std.testing.expectEqual(@as(i32, 101), std.mem.readInt(i32, rec1[4..8], .little));

    // Cap respected; tail untouched.
    var out2: [128]u8 = [_]u8{0xBB} ** 128;
    try std.testing.expectEqual(@as(usize, 1), m.fillSenseBotInfo(&out2, 16, 1));
    try std.testing.expectEqual(@as(u8, 0xBB), out2[32]);
}

test "BotManager worker melee accumulates atomically and drains attributed" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.bots[1] = .{ .net_id = 11, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 2;

    // Two zombies hit bot 10 in the same parallel pass: atomic fixed-point
    // accumulation, no hp/event mutation on the "worker".
    try std.testing.expect(m.damageFromWorker(10, 500, 12.5));
    try std.testing.expect(m.damageFromWorker(10, 501, 7.25));
    try std.testing.expect(m.damageFromWorker(11, 502, 200.0));
    try std.testing.expect(!m.damageFromWorker(999, 1, 5)); // gone: whiff
    try std.testing.expectEqual(@as(f32, 100), m.bots[0].hp); // not yet applied
    try std.testing.expectEqual(@as(usize, 0), m.ev_n);

    // Main-thread drain: summed damage attributed to the last attacker.
    m.drainWorkerDamage();
    try std.testing.expectApproxEqAbs(@as(f32, 100 - 19.75), m.bots[0].hp, 0.01);
    try std.testing.expectEqual(@as(i32, 501), m.bots[0].last_attacker); // last writer wins
    try std.testing.expectEqual(@as(usize, 2), m.ev_n); // one event per drained bot
    try std.testing.expectEqual(@as(i32, 501), m.events[0].attacker);
    try std.testing.expectEqual(@as(i32, 502), m.events[1].attacker);
    // Bot 11 took the 200 hit too (lethal: hp goes <= 0, alive false).
    try std.testing.expect(m.bots[1].hp <= 0);
    try std.testing.expect(!m.bots[1].alive);

    // Idempotent: a second drain applies nothing.
    const hp = m.bots[0].hp;
    m.drainWorkerDamage();
    try std.testing.expectEqual(hp, m.bots[0].hp);
    try std.testing.expectEqual(@as(usize, 2), m.ev_n);
}

test "BotManager fillSense appends after existing ECS actor records" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .x = 0, .y = 70, .z = 0, .hp = 100, .alive = true };
    m.n = 1;
    var out: [256]u8 = undefined;
    @memset(&out, 0xAA); // host_buf-style unwritten tail (would leak as garbage)

    // Two ECS actor records already occupy offsets 16 and 56 (v4 40-byte);
    // base is the header end (16) and `n` is the running record count.
    // Regression: the bot must land at record index 2 (offset 96), NOT at a
    // doubled offset, which would leave a garbage gap and push it past the
    // copied region.
    var n: usize = 2;
    m.fillSense(&out, 16, 8, &n);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u8, 2), out[96 + 4]); // kind bot at the right slot
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, out[96..100], .little));
    // The gap record (offset 56+4, the pre-existing actor slot) is untouched.
    try std.testing.expectEqual(@as(u8, 0xAA), out[56 + 4]);
}

test "dropFrom withdraws a plugin's bots and its count floor" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .alive = true, .src = 1 };
    m.bots[1] = .{ .net_id = 11, .alive = true, .src = 2 };
    m.n = 2;
    m.floor = 4;
    m.floor_src = 1;
    m.dropFrom(1);
    try std.testing.expectEqual(@as(usize, 1), m.n);
    try std.testing.expect(!m.bots[0].alive);
    try std.testing.expect(m.bots[1].alive);
    try std.testing.expectEqual(@as(u32, 0), m.floor);
    try std.testing.expectEqual(@as(i16, 0), m.floor_src);
    // Native src 0 is never withdrawn.
    m.bots[0] = .{ .net_id = 12, .alive = true, .src = 0 };
    m.n = 2;
    m.dropFrom(0);
    try std.testing.expectEqual(@as(usize, 2), m.n);
    m.dropFrom(2);
    try std.testing.expectEqual(@as(usize, 1), m.n);
    try std.testing.expect(m.bots[0].alive);
}

test "bot remove all is scoped to the issuing src" {
    // Composability audit 2026-09-11: `bot remove all` blanked every slot and
    // `applyCountFloor` trimmed to a global count, so one plugin could delete
    // another plugin's or the console's bots with no attribution and no way
    // back. Both verbs are now scoped to the issuing src, which also makes
    // `dropFrom` restore the pre-command state exactly.
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .alive = true, .src = 0 };
    m.bots[1] = .{ .net_id = 11, .alive = true, .src = 1 };
    m.bots[2] = .{ .net_id = 12, .alive = true, .src = 1 };
    m.bots[3] = .{ .net_id = 13, .alive = true, .src = 2 };
    m.n = 4;

    // remove all from plugin 1 leaves the console's and plugin 2's bots.
    m.removeAll(1);
    try std.testing.expectEqual(@as(usize, 2), m.n);
    try std.testing.expect(m.bots[0].alive);
    try std.testing.expect(!m.bots[1].alive);
    try std.testing.expect(!m.bots[2].alive);
    try std.testing.expect(m.bots[3].alive);

    // countFor is what the floor reads, so it must count per owner.
    try std.testing.expectEqual(@as(u32, 1), m.countFor(0));
    try std.testing.expectEqual(@as(u32, 0), m.countFor(1));
    try std.testing.expectEqual(@as(u32, 1), m.countFor(2));

    // The native console clears its own bots without touching a plugin's.
    var m3: BotManager = .{};
    m3.bots[0] = .{ .net_id = 30, .alive = true, .src = 0 };
    m3.bots[1] = .{ .net_id = 31, .alive = true, .src = 1 };
    m3.n = 2;
    m3.removeAll(0);
    try std.testing.expectEqual(@as(usize, 1), m3.n);
    try std.testing.expect(m3.bots[1].alive);
}

test "shiftSrcsAfter remaps remaining bot srcs after a slot drop" {
    var m: BotManager = .{};
    m.bots[0] = .{ .net_id = 10, .alive = true, .src = 1 };
    m.bots[1] = .{ .net_id = 11, .alive = true, .src = 3 };
    m.n = 2;
    m.floor = 2;
    m.floor_src = 3;
    m.shiftSrcsAfter(2);
    try std.testing.expectEqual(@as(i16, 1), m.bots[0].src);
    try std.testing.expectEqual(@as(i16, 2), m.bots[1].src);
    try std.testing.expectEqual(@as(i16, 2), m.floor_src);
}
