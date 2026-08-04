//! zdtd.toml: operator tunables (Bucket B), not stock serverconfig.
//! Precedence (applied by caller): CLI > env (webui secret) > world/zdtd.toml >
//! CWD zdtd.toml > --serverconfig keys > code defaults.
//! Minimal TOML subset: [section] + key = int|float|bool|string. No arrays/tables-in-tables.
//! Design: docs/HARDCODE_AUDIT.md, docs/adr/0010-data-config-zig-plugins.md

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

pub const Stream = struct {
    max_streamed_chunks: ?usize = null,
    chunk_adds_per_stream_tick: ?u32 = null,
    stream_radius_min: ?i32 = null,
    stream_radius_max: ?i32 = null,
    chunk_stream_period_ticks: ?u64 = null,
    motion_replicate_period_ticks: ?u64 = null,
    spawn_area_radius_max: ?i32 = null,
};

pub const Authority = struct {
    interest_range_blocks: ?f32 = null,
    max_edit_range_blocks: ?f32 = null,
    max_claimed_damage: ?i32 = null,
    peer_stale_ms: ?u64 = null,
    mode: ?[]const u8 = null,
};

pub const Feature = struct {
    wire_chunks: ?bool = null,
};

/// Select a gamemode pack under modes/<name>.toml (ADR 0010). Not the pack body.
pub const Mode = struct {
    name: ?[]const u8 = null,
};

pub const File = struct {
    stream: Stream = .{},
    authority: Authority = .{},
    feature: Feature = .{},
    mode: Mode = .{},
    /// Arena owning any string slices from parse.
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *File) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
    }
};

/// Max size for operator zdtd.toml (keeps mispointed paths from loading multi-MB files).
const max_toml_bytes: usize = 256 * 1024;

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !File {
    const data = try io_fs.readFileAll(allocator, path);
    defer allocator.free(data);
    if (data.len > max_toml_bytes) return error.TomlTooLarge;
    return try parse(allocator, data);
}

/// Load first existing path among candidates (does not allocate path strings).
pub fn loadFirst(allocator: std.mem.Allocator, paths: []const []const u8) !?File {
    for (paths) |p| {
        if (!io_fs.fileExistsSimple(p)) continue;
        return try loadFromPath(allocator, p);
    }
    return null;
}

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !File {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var f: File = .{ .arena_ptr = arena };
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.BadToml;
            section = try a.dupe(u8, std.mem.trim(u8, line[1..end], " \t"));
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.debug.print("zdtd: zdtd.toml malformed line (no '='); ignored: '{s}'\n", .{line});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, val, '#')) |h| {
            val = std.mem.trim(u8, val[0..h], " \t");
        }
        try applyKV(&f, a, section, key, val);
    }
    return f;
}

fn applyKV(f: *File, a: std.mem.Allocator, section: []const u8, key: []const u8, val: []const u8) !void {
    if (std.mem.eql(u8, section, "stream")) {
        if (std.mem.eql(u8, key, "max_streamed_chunks")) {
            f.stream.max_streamed_chunks = try parseUsize(val);
        } else if (std.mem.eql(u8, key, "chunk_adds_per_stream_tick")) {
            f.stream.chunk_adds_per_stream_tick = try parseU32(val);
        } else if (std.mem.eql(u8, key, "stream_radius_min") or std.mem.eql(u8, key, "chunk_stream_radius_min")) {
            f.stream.stream_radius_min = try parseI32(val);
        } else if (std.mem.eql(u8, key, "stream_radius_max") or std.mem.eql(u8, key, "chunk_stream_radius_max")) {
            f.stream.stream_radius_max = try parseI32(val);
        } else if (std.mem.eql(u8, key, "chunk_stream_period_ticks")) {
            f.stream.chunk_stream_period_ticks = try parseU64(val);
        } else if (std.mem.eql(u8, key, "motion_replicate_period_ticks")) {
            f.stream.motion_replicate_period_ticks = try parseU64(val);
        } else if (std.mem.eql(u8, key, "spawn_area_radius_max")) {
            f.stream.spawn_area_radius_max = try parseI32(val);
        } else {
            warnUnknownKey(section, key);
        }
    } else if (std.mem.eql(u8, section, "authority")) {
        if (std.mem.eql(u8, key, "interest_range_blocks") or std.mem.eql(u8, key, "interest_range")) {
            f.authority.interest_range_blocks = try parseF32(val);
        } else if (std.mem.eql(u8, key, "max_edit_range_blocks") or std.mem.eql(u8, key, "max_edit_range")) {
            f.authority.max_edit_range_blocks = try parseF32(val);
        } else if (std.mem.eql(u8, key, "max_claimed_damage")) {
            f.authority.max_claimed_damage = try parseI32(val);
        } else if (std.mem.eql(u8, key, "peer_stale_ms")) {
            f.authority.peer_stale_ms = try parseU64(val);
        } else if (std.mem.eql(u8, key, "mode")) {
            f.authority.mode = try a.dupe(u8, stripQuotes(val));
        } else {
            warnUnknownKey(section, key);
        }
    } else if (std.mem.eql(u8, section, "feature")) {
        if (std.mem.eql(u8, key, "wire_chunks")) {
            f.feature.wire_chunks = try parseBool(val);
        } else {
            warnUnknownKey(section, key);
        }
    } else if (std.mem.eql(u8, section, "mode")) {
        if (std.mem.eql(u8, key, "name")) {
            f.mode.name = try a.dupe(u8, stripQuotes(val));
        } else {
            warnUnknownKey(section, key);
        }
    } else if (section.len == 0) {
        std.debug.print("zdtd: zdtd.toml key '{s}' outside any [section]; ignored\n", .{key});
    } else {
        warnUnknownKey(section, key);
    }
}

fn warnUnknownKey(section: []const u8, key: []const u8) void {
    std.debug.print("zdtd: zdtd.toml unknown key [{s}].{s}; ignored\n", .{ section, key });
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        return v[1 .. v.len - 1];
    }
    return v;
}

fn parseUsize(v: []const u8) !usize {
    return std.fmt.parseInt(usize, stripQuotes(v), 10);
}
fn parseU32(v: []const u8) !u32 {
    return std.fmt.parseInt(u32, stripQuotes(v), 10);
}
fn parseU64(v: []const u8) !u64 {
    return std.fmt.parseInt(u64, stripQuotes(v), 10);
}
fn parseI32(v: []const u8) !i32 {
    return std.fmt.parseInt(i32, stripQuotes(v), 10);
}
fn parseF32(v: []const u8) !f32 {
    return std.fmt.parseFloat(f32, stripQuotes(v));
}
fn parseBool(v: []const u8) !bool {
    const s = stripQuotes(v);
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "no")) return false;
    return error.BadTomlBool;
}

/// Merge File into InitOptions-like fields. Only non-null keys override.
/// Does not apply authority.mode (caller parses with AuthorityMode).
pub fn applyToInitOptions(f: *const File, opts: anytype) void {
    if (f.stream.max_streamed_chunks) |v| opts.max_streamed_chunks = v;
    if (f.stream.chunk_adds_per_stream_tick) |v| opts.chunk_adds_per_stream_tick = v;
    if (f.stream.stream_radius_min) |v| opts.chunk_stream_radius_min = v;
    if (f.stream.stream_radius_max) |v| opts.chunk_stream_radius_max = v;
    if (f.stream.chunk_stream_period_ticks) |v| opts.chunk_stream_period_ticks = v;
    if (f.stream.motion_replicate_period_ticks) |v| opts.motion_replicate_period_ticks = v;
    if (f.stream.spawn_area_radius_max) |v| opts.spawn_area_radius_max = v;
    if (f.authority.interest_range_blocks) |v| opts.interest_range = v;
    if (f.authority.max_edit_range_blocks) |v| opts.max_edit_range = v;
    if (f.authority.max_claimed_damage) |v| opts.max_claimed_damage = v;
    if (f.authority.peer_stale_ms) |v| opts.peer_stale_ms = v;
    if (f.feature.wire_chunks) |v| opts.wire_chunks = v;
}

/// Clamp / repair InitOptions after toml apply. Logs adjustments; never panics.
pub fn sanitizeInitOptions(opts: anytype) void {
    if (opts.max_streamed_chunks == 0) {
        std.debug.print("zdtd: max_streamed_chunks=0 invalid; using 1\n", .{});
        opts.max_streamed_chunks = 1;
    }
    if (opts.chunk_stream_radius_min < 1) {
        std.debug.print("zdtd: stream_radius_min={d} invalid; using 1\n", .{opts.chunk_stream_radius_min});
        opts.chunk_stream_radius_min = 1;
    }
    if (opts.chunk_stream_radius_max < opts.chunk_stream_radius_min) {
        std.debug.print(
            "zdtd: stream_radius_max={d} < min={d}; raising max to min\n",
            .{ opts.chunk_stream_radius_max, opts.chunk_stream_radius_min },
        );
        opts.chunk_stream_radius_max = opts.chunk_stream_radius_min;
    }
    if (opts.chunk_adds_per_stream_tick == 0) {
        std.debug.print("zdtd: chunk_adds_per_stream_tick=0 invalid; using 1\n", .{});
        opts.chunk_adds_per_stream_tick = 1;
    }
    if (opts.chunk_stream_period_ticks == 0) {
        std.debug.print("zdtd: chunk_stream_period_ticks=0 invalid; using 1\n", .{});
        opts.chunk_stream_period_ticks = 1;
    }
    if (opts.motion_replicate_period_ticks == 0) {
        std.debug.print("zdtd: motion_replicate_period_ticks=0 invalid; using 1\n", .{});
        opts.motion_replicate_period_ticks = 1;
    }
    if (opts.spawn_area_radius_max < 1) {
        std.debug.print("zdtd: spawn_area_radius_max={d} invalid; using 1\n", .{opts.spawn_area_radius_max});
        opts.spawn_area_radius_max = 1;
    }
    if (opts.max_claimed_damage < 1) {
        std.debug.print("zdtd: max_claimed_damage={d} invalid; using 1\n", .{opts.max_claimed_damage});
        opts.max_claimed_damage = 1;
    }
    if (!std.math.isFinite(opts.max_edit_range) or opts.max_edit_range <= 0) {
        std.debug.print("zdtd: max_edit_range={d} invalid; using 1\n", .{opts.max_edit_range});
        opts.max_edit_range = 1;
    }
    if (!std.math.isFinite(opts.interest_range) or opts.interest_range <= 0) {
        std.debug.print("zdtd: interest_range={d} invalid; using 1\n", .{opts.interest_range});
        opts.interest_range = 1;
    }
    if (opts.peer_stale_ms == 0) {
        std.debug.print("zdtd: peer_stale_ms=0 invalid; using 1\n", .{});
        opts.peer_stale_ms = 1;
    }
}

test "parse stream and authority" {
    const src =
        \\# comment
        \\[stream]
        \\max_streamed_chunks = 100
        \\stream_radius_min = 5
        \\[authority]
        \\interest_range_blocks = 120.5
        \\peer_stale_ms = 4000
        \\mode = "observe"
        \\[feature]
        \\wire_chunks = false
        \\[mode]
        \\name = "default"
    ;
    var f = try parse(std.testing.allocator, src);
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 100), f.stream.max_streamed_chunks.?);
    try std.testing.expectEqual(@as(i32, 5), f.stream.stream_radius_min.?);
    try std.testing.expectApproxEqAbs(@as(f32, 120.5), f.authority.interest_range_blocks.?, 0.01);
    try std.testing.expectEqual(@as(u64, 4000), f.authority.peer_stale_ms.?);
    try std.testing.expectEqualStrings("observe", f.authority.mode.?);
    try std.testing.expectEqual(false, f.feature.wire_chunks.?);
    try std.testing.expectEqualStrings("default", f.mode.name.?);
}

test "loadFromPath rejects oversized file" {
    const dir = "worlds/zdtd_toml_big";
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple(dir);
    const path = dir ++ "/zdtd.toml";
    const big = try std.testing.allocator.alloc(u8, max_toml_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, '#');
    try io_fs.writeFileSimple(path, big);
    try std.testing.expectError(error.TomlTooLarge, loadFromPath(std.testing.allocator, path));
}

test "parse ignores unknown keys" {
    const src =
        \\[stream]
        \\nope = 1
        \\max_streamed_chunks = 10
    ;
    var f = try parse(std.testing.allocator, src);
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 10), f.stream.max_streamed_chunks.?);
}

test "sanitizeInitOptions repairs bad radii" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
        chunk_stream_period_ticks: u64 = 5,
        motion_replicate_period_ticks: u64 = 2,
        spawn_area_radius_max: i32 = 8,
        max_claimed_damage: i32 = 200,
        max_edit_range: f32 = 96,
        interest_range: f32 = 160,
        peer_stale_ms: u64 = 3000,
    };
    var o: Opts = .{
        .max_streamed_chunks = 0,
        .chunk_stream_radius_min = 8,
        .chunk_stream_radius_max = 3,
        .interest_range = -1,
    };
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(usize, 1), o.max_streamed_chunks);
    try std.testing.expectEqual(@as(i32, 8), o.chunk_stream_radius_min);
    try std.testing.expectEqual(@as(i32, 8), o.chunk_stream_radius_max);
    try std.testing.expectEqual(@as(f32, 1), o.interest_range);
}

test "sanitizeInitOptions rejects non-finite ranges" {
    const Opts = struct {
        max_streamed_chunks: usize = 169,
        chunk_stream_radius_min: i32 = 7,
        chunk_stream_radius_max: i32 = 9,
        chunk_adds_per_stream_tick: u32 = 8,
        chunk_stream_period_ticks: u64 = 5,
        motion_replicate_period_ticks: u64 = 2,
        spawn_area_radius_max: i32 = 8,
        max_claimed_damage: i32 = 200,
        max_edit_range: f32 = std.math.nan(f32),
        interest_range: f32 = std.math.inf(f32),
        peer_stale_ms: u64 = 3000,
    };
    var o: Opts = .{};
    sanitizeInitOptions(&o);
    try std.testing.expectEqual(@as(f32, 1), o.max_edit_range);
    try std.testing.expectEqual(@as(f32, 1), o.interest_range);
}
