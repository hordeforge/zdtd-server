//! Gamemode = config pack (+ optional static plugin flag). ADR 0010 step 3.
//! Data-only TOML under modes/<name>.toml. No script VM.
//! Apply onto InitOptions after serverconfig, before/with zdtd.toml stream keys.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

/// Max size for a mode pack file.
const max_mode_bytes: usize = 64 * 1024;

/// Optional InitOptions overrides from a mode pack.
pub const Pack = struct {
    name: []const u8 = "default",
    max_spawned_zombies: ?u16 = null,
    blood_moon_frequency: ?u8 = null,
    enable_sample_plugin: ?bool = null,
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Pack) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
    }
};

/// Builtin default pack source (matches modes/default.toml). Tests use this.
pub const default_pack_toml =
    \\name = "default"
    \\max_spawned_zombies = 64
    \\blood_moon_frequency = 7
    \\enable_sample_plugin = true
;

/// True when name is a single path segment: [A-Za-z0-9_]{1,64}, no dots/slashes.
pub fn isValidModeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Write `modes/<name>.toml` into buf. Caller ensures name is valid.
pub fn pathForName(name: []const u8, buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "modes/{s}.toml", .{name});
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Pack {
    const data = try io_fs.readFileAll(allocator, path);
    defer allocator.free(data);
    if (data.len > max_mode_bytes) return error.ModeTooLarge;
    return try parse(allocator, data);
}

/// Load modes/<name>.toml from CWD (or relative path). Invalid name → error.BadModeName.
pub fn loadByName(allocator: std.mem.Allocator, name: []const u8) !Pack {
    if (!isValidModeName(name)) return error.BadModeName;
    var path_buf: [96]u8 = undefined;
    const path = try pathForName(name, &path_buf);
    return try loadFromPath(allocator, path);
}

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !Pack {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var p: Pack = .{ .arena_ptr = arena };
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
            std.debug.print("zdtd: mode pack malformed line (no '='); ignored: '{s}'\n", .{line});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, val, '#')) |h| {
            val = std.mem.trim(u8, val[0..h], " \t");
        }
        try applyKV(&p, a, section, key, val);
    }
    return p;
}

fn applyKV(p: *Pack, a: std.mem.Allocator, section: []const u8, key: []const u8, val: []const u8) !void {
    // Flat root keys and optional [gameplay] / [plugin] sections.
    const root = section.len == 0 or
        std.mem.eql(u8, section, "gameplay") or
        std.mem.eql(u8, section, "plugin");
    if (!root) {
        warnUnknownKey(section, key);
        return;
    }
    if (std.mem.eql(u8, key, "name")) {
        p.name = try a.dupe(u8, stripQuotes(val));
    } else if (std.mem.eql(u8, key, "max_spawned_zombies")) {
        p.max_spawned_zombies = try parseU16(val);
    } else if (std.mem.eql(u8, key, "blood_moon_frequency") or std.mem.eql(u8, key, "bloodmoon_frequency")) {
        p.blood_moon_frequency = try parseU8(val);
    } else if (std.mem.eql(u8, key, "enable_sample_plugin")) {
        p.enable_sample_plugin = try parseBool(val);
    } else {
        warnUnknownKey(if (section.len == 0) "(root)" else section, key);
    }
}

fn warnUnknownKey(section: []const u8, key: []const u8) void {
    std.debug.print("zdtd: mode pack unknown key [{s}].{s}; ignored\n", .{ section, key });
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        return v[1 .. v.len - 1];
    }
    return v;
}

fn parseU16(v: []const u8) !u16 {
    return std.fmt.parseInt(u16, stripQuotes(v), 10);
}
fn parseU8(v: []const u8) !u8 {
    return std.fmt.parseInt(u8, stripQuotes(v), 10);
}
fn parseBool(v: []const u8) !bool {
    const s = stripQuotes(v);
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "no")) return false;
    return error.BadTomlBool;
}

/// Merge Pack into InitOptions-like fields. Only non-null keys override.
pub fn applyToInitOptions(p: *const Pack, opts: anytype) void {
    if (p.max_spawned_zombies) |v| opts.max_spawned_zombies = v;
    if (p.blood_moon_frequency) |v| opts.blood_moon_frequency = v;
    if (p.enable_sample_plugin) |v| opts.enable_sample_plugin = v;
}

test "parse default pack" {
    var p = try parse(std.testing.allocator, default_pack_toml);
    defer p.deinit();
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqual(@as(u16, 64), p.max_spawned_zombies.?);
    try std.testing.expectEqual(@as(u8, 7), p.blood_moon_frequency.?);
    try std.testing.expectEqual(true, p.enable_sample_plugin.?);
}

test "applyToInitOptions overrides only set fields" {
    const Opts = struct {
        max_spawned_zombies: u16 = 100,
        blood_moon_frequency: u8 = 3,
        enable_sample_plugin: bool = false,
        wire_chunks: bool = true,
    };
    var o: Opts = .{};
    var p = try parse(std.testing.allocator,
        \\max_spawned_zombies = 32
        \\enable_sample_plugin = true
    );
    defer p.deinit();
    applyToInitOptions(&p, &o);
    try std.testing.expectEqual(@as(u16, 32), o.max_spawned_zombies);
    try std.testing.expectEqual(@as(u8, 3), o.blood_moon_frequency);
    try std.testing.expectEqual(true, o.enable_sample_plugin);
    try std.testing.expectEqual(true, o.wire_chunks);
}

test "isValidModeName rejects path traversal" {
    try std.testing.expect(isValidModeName("default"));
    try std.testing.expect(isValidModeName("pve_hard"));
    try std.testing.expect(!isValidModeName(""));
    try std.testing.expect(!isValidModeName("../etc"));
    try std.testing.expect(!isValidModeName("a/b"));
    try std.testing.expect(!isValidModeName("a.b"));
}

test "loadByName default file when present" {
    if (!io_fs.fileExistsSimple("modes/default.toml")) return;
    var p = try loadByName(std.testing.allocator, "default");
    defer p.deinit();
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expect(p.max_spawned_zombies != null);
}

test "loadByName rejects bad name" {
    try std.testing.expectError(error.BadModeName, loadByName(std.testing.allocator, "../x"));
}

test "parse bloodmoon_frequency alias and sections" {
    var p = try parse(std.testing.allocator,
        \\[gameplay]
        \\bloodmoon_frequency = 5
        \\[plugin]
        \\enable_sample_plugin = false
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u8, 5), p.blood_moon_frequency.?);
    try std.testing.expectEqual(false, p.enable_sample_plugin.?);
}
