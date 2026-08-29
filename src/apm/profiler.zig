//! Scoped wall-clock sections for tick phases (zdtd-native; not 7dtd-server-apm).

const std = @import("std");
const metrics = @import("metrics.zig");
const tracy = @import("tracy.zig");
const clock = @import("../util/clock.zig");

pub const Section = enum(u8) {
    tick_total,
    net_poll,
    sim_entities,
    replicate,
    chunk_stream,
    save_io,
    /// Chunk serialize on the tick thread (split out of save_io: the async
    /// flush moves the write off-thread but not the encode).
    save_encode,
    /// Blocking wait on the background chunk writer (queue drain / key gate).
    save_flush_wait,
    /// Per-tick rebuild of the read-mostly terrain blocked snapshot.
    terrain_snap,
    /// Sleeper-volume player test pass (serial or job batch).
    sleeper_scan,
    /// One-time storage-TE block scan of a streamed chunk (65536 cells).
    te_scan,
    /// Resident-miss chunk materialization: disk load or procedural gen.
    chunk_gen,
    /// Per-player survival/effects pass (passive-effects VM + triggered
    /// engine + stat application; tickSurvival).
    survival,
    /// Join-phase C2S handling on the tick (login/enter/spawn handlers:
    /// spawn-area core + join bundle + respawn logic). GAP "Join-burst tick
    /// budget" attribution: the spawn-area CHUNK part is paced via
    /// drainSpawnArea (replicate, .replicate section); this section isolates
    /// the residual synchronous join work.
    join,
    /// Paced spawn-area drain pass (replicate): one pass = the shared
    /// per-tick drain budget of chunk bodies + per-chunk ACK yields.
    join_drain,
    _,
};

pub const sections_len: usize = @typeInfo(Section).@"enum".fields.len;

/// `@src()` is not legal at container scope, so the table is produced by a
/// function evaluated into a container-level const (rodata): Tracy requires a
/// source location to outlive every zone that points at it.
fn buildSectionLocs() [sections_len]tracy.SourceLocation {
    const here = @src();
    var locs: [sections_len]tracy.SourceLocation = undefined;
    for (@typeInfo(Section).@"enum".fields) |f| {
        locs[f.value] = .{
            .name = f.name.ptr,
            .function = "apm.profiler.scope",
            .file = here.file.ptr,
            .line = here.line,
        };
    }
    return locs;
}

const section_locs: [sections_len]tracy.SourceLocation = buildSectionLocs();

pub const Profiler = struct {
    hist: [sections_len]metrics.LatencyHist = [_]metrics.LatencyHist{.{}} ** sections_len,
    open: [sections_len]?u64 = [_]?u64{null} ** sections_len,

    /// Raw begin/end are not Tracy-mapped: Tracy validates strict LIFO nesting
    /// per thread, which only `scope`/`Scope.end` guarantees. Use `scope`.
    pub fn begin(self: *Profiler, s: Section) void {
        const i: usize = @intFromEnum(s);
        if (i >= sections_len) return;
        self.open[i] = clock.monoNs();
    }

    pub fn end(self: *Profiler, s: Section) void {
        const i: usize = @intFromEnum(s);
        if (i >= sections_len) return;
        const start = self.open[i] orelse return;
        self.open[i] = null;
        const now = clock.monoNs();
        const dt: u64 = if (now >= start) now - start else 0;
        self.hist[i].observe(dt);
    }

    pub fn histOf(self: *const Profiler, s: Section) *const metrics.LatencyHist {
        return &self.hist[@intFromEnum(s)];
    }

    pub fn reset(self: *Profiler) void {
        for (&self.hist) |*h| h.reset();
        @memset(&self.open, null);
    }
};

pub const Scope = struct {
    p: *Profiler,
    s: Section,
    /// Zero-sized unless `-Dtracy=true`; `Scope` layout is unchanged by default.
    z: tracy.Zone,

    pub fn end(self: Scope) void {
        self.p.end(self.s);
        self.z.end();
    }
};

pub fn scope(p: *Profiler, s: Section) Scope {
    p.begin(s);
    const i: usize = @intFromEnum(s);
    // Same out-of-range guard `begin`/`end` use: a non-exhaustive tag with no
    // name gets an inactive zone rather than a fabricated one.
    const named = i < sections_len;
    return .{ .p = p, .s = s, .z = tracy.zone(&section_locs[if (named) i else 0], named) };
}

test "profiler records" {
    var p: Profiler = .{};
    const sc = scope(&p, .tick_total);
    var x: u64 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) x +%= i;
    sc.end();
    try std.testing.expect(p.histOf(.tick_total).count == 1);
    try std.testing.expect(x > 0);
}

test "tracy section locations cover every named section" {
    inline for (@typeInfo(Section).@"enum".fields) |f| {
        const loc = section_locs[f.value];
        try std.testing.expectEqualStrings(f.name, std.mem.span(loc.name.?));
        try std.testing.expect(loc.line > 0);
        try std.testing.expect(std.mem.span(loc.file).len > 0);
    }
}

test "scope stays layout-neutral when tracy is off" {
    if (tracy.enabled) return error.SkipZigTest;
    try std.testing.expectEqual(@sizeOf(struct { p: *Profiler, s: Section }), @sizeOf(Scope));
}

test "unnamed section scope is inert" {
    var p: Profiler = .{};
    const sc = scope(&p, @enumFromInt(200));
    sc.end();
    for (&p.hist) |*h| try std.testing.expectEqual(@as(u64, 0), h.count);
}
