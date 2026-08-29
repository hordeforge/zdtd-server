//! Core plugin shared support: bounded output buffer, host imports, and the
//! `_zdtd_requires` export shape (ADR 0030). Imported by each plugin's root
//! file at build time; nothing here touches the wire or allocates.
//!
//! All core plugins are Zig (freestanding wasm32); bot stays C by design
//! (ADR 0026). Build recipe per plugin:
//!   zig build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
//!     --name <name> -femit-bin=<name>.wasm <plugin>_main.zig
//! where `<plugin>_main.zig` is a two-line wrapper exporting `_start` and
//! pulling in the plugin root (zig build-exe needs an entry; zwasm runs the
//! start section only if declared, and we never declare one).

const std = @import("std");

pub extern "zdtd" fn log(level: i32, ptr: i32, len: i32) void;
pub extern "zdtd" fn tick() i64;
pub extern "zdtd" fn queue(ptr: i32, len: i32) i32;
pub extern "zdtd" fn sense(ptr: i32, len: i32, token: i32) i32;
pub extern "zdtd" fn query(req_ptr: i32, req_len: i32, out_ptr: i32, out_cap: i32) i32;
pub extern "zdtd" fn json_parse(ptr: i32, len: i32) i32;
pub extern "zdtd" fn json_str(path_ptr: i32, path_len: i32, out_ptr: i32, out_cap: i32) i32;
pub extern "zdtd" fn json_raw(path_ptr: i32, path_len: i32, out_ptr: i32, out_cap: i32) i32;
pub extern "zdtd" fn json_obj(path_ptr: i32, path_len: i32) i32;

/// Maximum bytes of one log line / queued command this module builds.
pub const out_cap = 160;

/// Bounded append buffer over a static array. Overflow drops bytes but keeps
/// counting so callers can detect truncation.
pub const Buf = struct {
    bytes: [out_cap]u8 = undefined,
    n: usize = 0,

    pub fn reset(self: *Buf) void {
        self.n = 0;
    }

    pub fn put(self: *Buf, s: []const u8) void {
        const room = out_cap - 1 - @min(self.n, out_cap - 1);
        const take = @min(s.len, room);
        // out_cap is tiny; the copy can never exceed the remaining slice.
        if (take > 0) {
            @memcpy(self.bytes[self.n..][0..take], s[0..take]);
            self.n += take;
        }
    }

    pub fn putInt(self: *Buf, v: anytype) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.put(s);
    }

    pub fn slice(self: *const Buf) []const u8 {
        return self.bytes[0..self.n];
    }

    pub fn logLine(self: *const Buf, level: i32) void {
        if (self.n == 0) return;
        log(level, @intCast(@intFromPtr(&self.bytes)), @intCast(self.n));
    }

    pub fn send(self: *const Buf) i32 {
        return queue(@intCast(@intFromPtr(&self.bytes)), @intCast(self.n));
    }
};

/// `_zdtd_requires` export (ADR 0030): low 32 bits ptr, high 32 bits len.
/// `spec` must be a comptime comma-separated capability list. Call from a
/// `comptime` block in the plugin root: `common.exportRequires("log,queue");`
pub fn exportRequires(comptime spec: []const u8) void {
    const S = struct {
        const text = spec;
        fn requires_spec() callconv(.c) i64 {
            const len: u64 = text.len;
            const ptr: u64 = @intFromPtr(text.ptr);
            return @bitCast(ptr | (len << 32));
        }
    };
    @export(&S.requires_spec, .{ .name = "_zdtd_requires" });
}

test "Buf truncates instead of overrunning" {
    var b: Buf = .{};
    const big = [_]u8{'x'} ** 200;
    b.put(&big);
    try std.testing.expectEqual(out_cap - 1, b.slice().len);
}

pub extern "zdtd" fn config(out_ptr: i32, out_cap: i32) i32;

/// Self-contained default config (the mod's config.toml, raw text served by
/// the host's zdtd.config import). The host never parses it; each plugin owns
/// its format. `get`/`getInt` handle the minimal `key = value` subset (with
/// `#` comments and quoted values) that the shipped core plugins use; a
/// plugin with a richer format can read `bytes` directly.
pub const Config = struct {
    bytes: [4096]u8 = undefined,
    n: usize = 0,

    pub fn load(self: *Config) void {
        self.n = @intCast(config(@intCast(@intFromPtr(&self.bytes)), @intCast(self.bytes.len)));
    }

    fn value(self: *const Config, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) {
            const nl = std.mem.indexOfScalarPos(u8, self.bytes[0..self.n], i, '\n') orelse self.n;
            const line = std.mem.trim(u8, self.bytes[i..nl], " \t\r");
            i = nl + 1;
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
            var v = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.indexOfScalar(u8, v, '#')) |h| v = std.mem.trim(u8, v[0..h], " \t");
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            return v;
        }
        return null;
    }

    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        return self.value(key);
    }

    pub fn getInt(self: *const Config, key: []const u8) ?i64 {
        const v = self.value(key) orelse return null;
        return std.fmt.parseInt(i64, v, 10) catch null;
    }
};

test "Config parses key = value lines" {
    var c: Config = .{};
    const src = "# a comment\nprice_percent = 150\nname = \"trader\"\n";
    @memcpy(c.bytes[0..src.len], src);
    c.n = src.len;
    try std.testing.expectEqual(@as(i64, 150), c.getInt("price_percent").?);
    try std.testing.expectEqualStrings("trader", c.get("name").?);
    try std.testing.expect(c.get("missing") == null);
}
