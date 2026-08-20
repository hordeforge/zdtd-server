//! P4 guard policy: what the server *does* with detector evidence.
//!
//! Pure decision layer over `evidence.zig`. No Game import, no allocator, no
//! wall clock: windows key off the caller's tick counter so scenario tests that
//! advance `Game.tick_n` by hand stay deterministic.
//!
//! Ladder (each rung must be switched on explicitly, defaults are log-only):
//!   log-only (default) -> quarantine bits (opt-in) -> kick (opt-in AND
//!   dry_run=false AND the server is in Correct authority mode).
//!
//! Structural guarantee: `.info` and `.soft` evidence returns `.none` before any
//! counter is touched, so a weak signal can never open a gate no matter how
//! often it fires. See docs/AUTHORITY.md.

const std = @import("std");
const evidence = @import("evidence.zig");

/// Distinct detector slots addressable by `strong_mask` (Detector minus `.other`,
/// plus one catch-all slot for `.other`).
pub const detector_slots: u8 = 9;

fn detectorIndex(det: evidence.Detector) u8 {
    return switch (det) {
        .other => detector_slots - 1,
        else => @intFromEnum(det) - 1,
    };
}

fn surfaceIndex(surf: evidence.Surface) u8 {
    return @intFromEnum(surf);
}

/// Per-surface denial bits. Independent because `evidence.Surface` attributes
/// each signal to the C2S surface it was observed on.
pub const Quarantine = struct {
    no_damage: bool = false,
    no_container: bool = false,
    no_setblock: bool = false,

    pub fn any(self: Quarantine) bool {
        return self.no_damage or self.no_container or self.no_setblock;
    }
};

/// Bits a trip on `surf` should set. `.none` is unattributed abuse (movement,
/// phase, reconnect flood) and therefore quarantines every surface.
pub fn bitsFor(surf: evidence.Surface) Quarantine {
    return switch (surf) {
        .none => .{ .no_damage = true, .no_container = true, .no_setblock = true },
        .damage => .{ .no_damage = true },
        .container => .{ .no_container = true },
        .block => .{ .no_setblock = true },
    };
}

/// Operator switches (zdtd.toml `[authority]`). Defaults are the safe rung:
/// nothing is denied and nothing is dropped, the policy only logs and counts.
pub const Policy = struct {
    /// Master switch for the kick rung. Without it the ladder tops out at logs.
    enforce: bool = false,
    /// Even with `enforce`, a kick is only simulated (counted + logged).
    dry_run: bool = true,
    /// Allow the quarantine rung (per-surface C2S denial).
    quarantine: bool = false,
    /// Shed weak evidence + deferrable broadcasts after a tick overrun.
    load_shed: bool = true,
    /// Length of the counting window, in ticks (1200 = 60 s at 20 TPS).
    window_ticks: u64 = 1200,
    /// Distinct Strong detectors inside one window that trip the gate.
    strong_distinct: u8 = 2,
    /// Hard events inside one window that trip the gate.
    hard_repeat: u16 = 25,
    /// Ticks a policy kick waits between the `NetPackagePlayerDenied` send and
    /// the peer drop. 10 ticks at 20 TPS = 0.5 s, matching stock
    /// `GameUtils.disconnectLater(0.5f)` (asm.il:1918548-1918583).
    kick_delay_ticks: u64 = 10,
    /// Ticks the load-shed valve stays open after a tick-budget overrun (2 s).
    shed_hold_ticks: u64 = 40,
    /// Block destroys inside one policy window that trip the weak farming
    /// signal. Heuristic, not stock-derived: nothing in the IL defines a
    /// legitimate harvest rate. Record-only by construction (`.soft`), so
    /// tuning it cannot cause a kick.
    weak_break_rate_per_window: u16 = 900,

    /// Repair operator values after config merge. Logs each repair like
    /// `zdtd_config.sanitizeInitOptions`; never panics.
    pub fn clamp(self: *Policy) void {
        if (self.window_ticks == 0) {
            std.debug.print("zdtd: guard_window_ticks=0 invalid; using 1\n", .{});
            self.window_ticks = 1;
        }
        if (self.strong_distinct == 0) {
            std.debug.print("zdtd: guard_strong_distinct=0 invalid; using 1\n", .{});
            self.strong_distinct = 1;
        }
        if (self.strong_distinct > detector_slots) {
            std.debug.print(
                "zdtd: guard_strong_distinct={d} exceeds detector count {d}; clamping\n",
                .{ self.strong_distinct, detector_slots },
            );
            self.strong_distinct = detector_slots;
        }
        if (self.hard_repeat == 0) {
            std.debug.print("zdtd: guard_hard_repeat=0 invalid; using 1\n", .{});
            self.hard_repeat = 1;
        }
        if (self.kick_delay_ticks == 0) {
            std.debug.print("zdtd: guard_kick_delay_ticks=0 invalid; using 1\n", .{});
            self.kick_delay_ticks = 1;
        }
        if (self.shed_hold_ticks == 0) {
            std.debug.print("zdtd: guard_shed_hold_ticks=0 invalid; using 1\n", .{});
            self.shed_hold_ticks = 1;
        }
        if (self.weak_break_rate_per_window == 0) {
            std.debug.print("zdtd: guard_weak_break_rate=0 invalid; using 1\n", .{});
            self.weak_break_rate_per_window = 1;
        }
    }
};

/// Per-client policy state. Fixed size, cleared for free by `clients[i] = .{}`
/// on kick / disconnect (so quarantine is session-scoped by design).
pub const PeerState = struct {
    /// First tick of the current counting window.
    window_start: u64 = 0,
    /// One bit per detector that produced a Strong event this window.
    strong_mask: u16 = 0,
    /// Hard events this window.
    hard_n: u16 = 0,
    /// (detector, surface) pairs already written to the evidence ring this
    /// window. Bounds ring pressure without perturbing the gate counts.
    seen_mask: u64 = 0,
    /// Gate already fired this window (one action per window, not per event).
    tripped: bool = false,
    quarantine: Quarantine = .{},
    /// Non-zero once a policy kick is armed; the tick the peer is dropped.
    kick_at_tick: u64 = 0,
};

pub const Action = enum {
    /// Nothing to do (below the gate, or weak signal).
    none,
    /// Set the quarantine bits in `Outcome.bits`.
    quarantine,
    /// Gate tripped but the kick rung is off or dry-run: log and count only.
    would_kick,
    /// Send PlayerDenied and arm the delayed drop.
    kick,
};

pub const Outcome = struct {
    /// Write this event to the evidence ring (false = duplicate this window).
    record: bool,
    action: Action = .none,
    bits: Quarantine = .{},
};

/// Fold one detector event into `state` and decide what the server should do.
/// `corrects` is `Game.authorityCorrects()`: Observe mode records and logs but
/// never denies or drops, matching the documented mode table.
pub fn evaluate(
    state: *PeerState,
    policy: Policy,
    tick: u64,
    det: evidence.Detector,
    sev: evidence.Severity,
    surf: evidence.Surface,
    corrects: bool,
) Outcome {
    if (state.window_start == 0 or tick -% state.window_start >= policy.window_ticks) {
        state.window_start = tick;
        state.strong_mask = 0;
        state.hard_n = 0;
        state.seen_mask = 0;
        state.tripped = false;
        // Quarantine bits deliberately survive the window roll: they are
        // cleared by admin `guardclear` or by the session ending.
    }

    const pair_bit = @as(u64, 1) << @intCast(detectorIndex(det) * 4 + surfaceIndex(surf));
    const record = (state.seen_mask & pair_bit) == 0;
    state.seen_mask |= pair_bit;

    // Weak signals are excluded before any counter moves. This is the whole
    // "weak signals never kick" guarantee; it is a structural property of the
    // control flow, not a threshold.
    switch (sev) {
        .info, .soft => return .{ .record = record },
        .strong => state.strong_mask |= @as(u16, 1) << @intCast(detectorIndex(det)),
        .hard => state.hard_n +|= 1,
    }

    const tripped = @popCount(state.strong_mask) >= policy.strong_distinct or
        state.hard_n >= policy.hard_repeat;
    if (!tripped or state.tripped) return .{ .record = record };
    state.tripped = true;

    if (corrects and policy.enforce and !policy.dry_run)
        return .{ .record = record, .action = .kick, .bits = bitsFor(surf) };
    if (corrects and policy.quarantine)
        return .{ .record = record, .action = .quarantine, .bits = bitsFor(surf) };
    return .{ .record = record, .action = .would_kick, .bits = bitsFor(surf) };
}

const testing = std.testing;
const log_only: Policy = .{};

test "weak signals never trip any gate" {
    var st: PeerState = .{};
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        const out = evaluate(&st, log_only, 1 + i % 100, .farming, .soft, .block, true);
        try testing.expectEqual(Action.none, out.action);
        const out2 = evaluate(&st, log_only, 1 + i % 100, .flood, .info, .none, true);
        try testing.expectEqual(Action.none, out2.action);
    }
    try testing.expectEqual(@as(u16, 0), st.strong_mask);
    try testing.expectEqual(@as(u16, 0), st.hard_n);
    try testing.expectEqual(false, st.tripped);
}

test "two distinct strong detectors trip, one repeated does not" {
    var repeated: PeerState = .{};
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const out = evaluate(&repeated, log_only, 10, .bounds, .strong, .block, true);
        try testing.expectEqual(Action.none, out.action);
    }

    var distinct: PeerState = .{};
    const first = evaluate(&distinct, log_only, 10, .bounds, .strong, .block, true);
    try testing.expectEqual(Action.none, first.action);
    const second = evaluate(&distinct, log_only, 10, .movement, .strong, .none, true);
    try testing.expectEqual(Action.would_kick, second.action);
    // One action per window, even as more strong events arrive.
    const third = evaluate(&distinct, log_only, 10, .ownership, .strong, .block, true);
    try testing.expectEqual(Action.none, third.action);
}

test "hard repeat trips exactly at the threshold" {
    var st: PeerState = .{};
    const p: Policy = .{ .hard_repeat = 3 };
    try testing.expectEqual(Action.none, evaluate(&st, p, 5, .phase, .hard, .none, true).action);
    try testing.expectEqual(Action.none, evaluate(&st, p, 5, .phase, .hard, .none, true).action);
    try testing.expectEqual(Action.would_kick, evaluate(&st, p, 5, .phase, .hard, .none, true).action);
}

test "window roll clears mask and trip latch" {
    var st: PeerState = .{};
    const p: Policy = .{ .window_ticks = 100 };
    _ = evaluate(&st, p, 10, .bounds, .strong, .block, true);
    _ = evaluate(&st, p, 20, .movement, .strong, .none, true);
    try testing.expect(st.tripped);
    // Same detector pair again after the roll must be recordable and countable.
    const rolled = evaluate(&st, p, 200, .bounds, .strong, .block, true);
    try testing.expectEqual(true, rolled.record);
    try testing.expectEqual(Action.none, rolled.action);
    try testing.expectEqual(false, st.tripped);
    try testing.expectEqual(@as(u32, 1), @popCount(st.strong_mask));
}

test "ring dedupe: identical pair recorded once per window" {
    var st: PeerState = .{};
    try testing.expectEqual(true, evaluate(&st, log_only, 1, .bounds, .strong, .block, true).record);
    try testing.expectEqual(false, evaluate(&st, log_only, 2, .bounds, .strong, .block, true).record);
    // Same detector, different surface is a different pair.
    try testing.expectEqual(true, evaluate(&st, log_only, 3, .bounds, .strong, .damage, true).record);
}

test "kick rung requires enforce, no dry_run, and correct mode" {
    const trip = struct {
        fn run(p: Policy, corrects: bool) Outcome {
            var st: PeerState = .{};
            _ = evaluate(&st, p, 1, .bounds, .strong, .damage, corrects);
            return evaluate(&st, p, 1, .movement, .strong, .damage, corrects);
        }
    }.run;

    try testing.expectEqual(Action.would_kick, trip(.{ .enforce = true }, true).action);
    try testing.expectEqual(
        Action.kick,
        trip(.{ .enforce = true, .dry_run = false }, true).action,
    );
    // Observe mode never denies or drops.
    try testing.expectEqual(
        Action.would_kick,
        trip(.{ .enforce = true, .dry_run = false, .quarantine = true }, false).action,
    );
    // Quarantine rung without enforce.
    const q = trip(.{ .quarantine = true }, true);
    try testing.expectEqual(Action.quarantine, q.action);
    try testing.expectEqual(true, q.bits.no_damage);
    try testing.expectEqual(false, q.bits.no_setblock);
}

test "surface maps to independent bits and none sets all" {
    try testing.expectEqual(Quarantine{ .no_damage = true }, bitsFor(.damage));
    try testing.expectEqual(Quarantine{ .no_container = true }, bitsFor(.container));
    try testing.expectEqual(Quarantine{ .no_setblock = true }, bitsFor(.block));
    try testing.expectEqual(
        Quarantine{ .no_damage = true, .no_container = true, .no_setblock = true },
        bitsFor(.none),
    );
    try testing.expectEqual(false, (Quarantine{}).any());
    try testing.expectEqual(true, bitsFor(.block).any());
}

test "clamp repairs zeros and over-wide thresholds" {
    var p: Policy = .{ .window_ticks = 0, .strong_distinct = 0, .hard_repeat = 0 };
    p.clamp();
    try testing.expectEqual(@as(u64, 1), p.window_ticks);
    try testing.expectEqual(@as(u8, 1), p.strong_distinct);
    try testing.expectEqual(@as(u16, 1), p.hard_repeat);

    var wide: Policy = .{ .strong_distinct = 200 };
    wide.clamp();
    try testing.expectEqual(detector_slots, wide.strong_distinct);
}

test "detector and surface indices stay inside the mask widths" {
    for (std.enums.values(evidence.Detector)) |det| {
        try testing.expect(detectorIndex(det) < detector_slots);
        for (std.enums.values(evidence.Surface)) |surf| {
            try testing.expect(detectorIndex(det) * 4 + surfaceIndex(surf) < 64);
        }
    }
}
