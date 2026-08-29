//! P4 observe evidence: fixed ring of detector events (no secrets, no IP, no packets).
//! Admin `evidence dump [path]` flushes the ring as JSONL via
//! Game.dumpEvidenceFile (io_fs.writeFile); the ring itself stays fixed-size.

const std = @import("std");

pub const max_ring: usize = 64;

pub const Severity = enum(u8) {
    info = 0,
    soft = 1,
    strong = 2,
    hard = 3,
};

pub const Detector = enum(u8) {
    phase = 1,
    ownership = 2,
    bounds = 3,
    movement = 4,
    decode = 5,
    throttle = 6,
    flood = 7,
    /// Weak (record-only) block-destroy rate. Never actionable by construction.
    farming = 8,
    other = 255,
};

/// Input authority of a detector's DECISION (T20 ceiling): a detector may be
/// elevated to `.hard` severity (which can trip a kick) only when every input
/// that decides the event is server-derived. Detectors that weigh
/// client-reported values are still server-DECIDED (the client value is only
/// ever compared against server caps/ranges) but must fail closed to `.strong`.
pub const DecisionInput = enum(u8) {
    /// Every decision input is server state (SM phase, parse result, rate
    /// counters, entity-id ownership, server caps). `.hard` is legal.
    server_only,
    /// The observed value is client-reported; the decision is the server's
    /// comparison against its own caps/ranges. `.hard` is not legal (the
    /// ceiling downgrades it to `.strong`).
    client_informed,
};

/// Authority table, one row per detector (T20 classification). The ceiling
/// assert (guard.zig noteEvidence) and the coverage test keep this honest.
pub fn decisionInputs(det: Detector) DecisionInput {
    return switch (det) {
        // Client-reported positions/coords/deltas weighed against server caps.
        .bounds, .movement => .client_informed,
        // Everything else decides purely on server state.
        .phase, .ownership, .decode, .throttle, .flood, .farming, .other => .server_only,
    };
}

/// Which C2S surface produced the event. Maps 1:1 to the guard quarantine bits,
/// so a signal can deny only the surface it was observed on. `.none` is an
/// unattributed signal (movement, phase, flood) and quarantines every surface.
pub const Surface = enum(u8) {
    none = 0,
    damage = 1,
    container = 2,
    block = 3,
};

pub const Event = struct {
    tick: u64 = 0,
    peer_local: i32 = -1,
    entity_id: i32 = -1,
    detector: Detector = .other,
    severity: Severity = .info,
    surface: Surface = .none,
    observed: f32 = 0,
    bound: f32 = 0,
};

pub const Ring = struct {
    events: [max_ring]Event = [_]Event{.{}} ** max_ring,
    head: usize = 0,
    n: usize = 0,
    total: u64 = 0,

    pub fn record(self: *Ring, ev: Event) void {
        self.events[self.head % max_ring] = ev;
        self.head +%= 1;
        if (self.n < max_ring) self.n += 1;
        self.total +%= 1;
    }

    /// Format one event as JSONL into buf (no trailing newline).
    pub fn formatEvent(ev: Event, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{{\"v\":1,\"tick\":{d},\"peer\":{d},\"ent\":{d},\"det\":\"{s}\",\"sev\":\"{s}\",\"surf\":\"{s}\",\"obs\":{d:.3},\"bound\":{d:.3}}}", .{
            ev.tick,
            ev.peer_local,
            ev.entity_id,
            @tagName(ev.detector),
            @tagName(ev.severity),
            @tagName(ev.surface),
            ev.observed,
            ev.bound,
        });
    }

    /// Dump ring newest-last into out (newline separated). Returns written len.
    pub fn dumpText(self: *const Ring, out: []u8) usize {
        var pos: usize = 0;
        const n = self.n;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (self.head -% n + k) % max_ring;
            var line: [200]u8 = undefined;
            const s = formatEvent(self.events[idx], &line) catch continue;
            if (pos + s.len + 1 > out.len) break;
            @memcpy(out[pos..][0..s.len], s);
            pos += s.len;
            out[pos] = '\n';
            pos += 1;
        }
        return pos;
    }
};

test "ring wraps and dump" {
    var r: Ring = .{};
    var i: u32 = 0;
    while (i < max_ring + 3) : (i += 1) {
        r.record(.{ .tick = i, .detector = .throttle, .severity = .soft, .observed = @floatFromInt(i) });
    }
    try std.testing.expectEqual(@as(usize, max_ring), r.n);
    try std.testing.expectEqual(@as(u64, max_ring + 3), r.total);
    var buf: [4096]u8 = undefined;
    const n = r.dumpText(&buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.find(u8, buf[0..n], "\"det\":\"throttle\"") != null);
}

test "T20 authority classification covers every detector" {
    // The decision-input table is exhaustive (compile-time) and the mapping
    // is pinned: only bounds/movement weigh client-reported values; every
    // other detector decides purely on server state. If a new detector is
    // added, this test forces a classification decision.
    inline for (@typeInfo(Detector).@"enum".fields) |f| {
        const det: Detector = @enumFromInt(f.value);
        const want: DecisionInput = switch (det) {
            .bounds, .movement => .client_informed,
            .phase, .ownership, .decode, .throttle, .flood, .farming, .other => .server_only,
        };
        try std.testing.expectEqual(want, decisionInputs(det));
    }
}
