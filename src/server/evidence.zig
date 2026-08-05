//! P4 observe evidence: fixed ring of detector events (no secrets, no IP, no packets).
//! Optional later: JSONL flush from admin `evidence dump` via io_fs.writeFile.

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
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"det\":\"throttle\"") != null);
}
