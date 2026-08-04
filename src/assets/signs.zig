//! Prefab sign libraries (*_signs.xml under Data/Prefabs) for NetPackageSignDataResponse.
//! Catalog data only; the wire encode lives in wire/stock_sign.zig.
//! Minimal SignData: guid + name + next_* ids + zero layers (stops client "Failed to
//! retrieve sign data" for missing library guids; full layer paint is later).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

pub const max_signs: usize = 4096;

pub const SignEntry = struct {
    /// Prefab library id (filename without `_signs.xml`).
    library: []const u8,
    name: []const u8,
    guid: [16]u8,
    next_poly: i32 = 0,
    next_text: i32 = 0,
    next_noise: i32 = 0,
    next_group: i32 = 0,
    /// .NET DateTime ticks (UTC); 0 is fine for wire.
    modified_ticks: i64 = 0,
};

pub const Catalog = struct {
    entries: []SignEntry = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Catalog) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn empty() Catalog {
        return .{};
    }
};

/// Parse UUID "aabbccdd-eeff-0011-2233-445566778899" to .NET Guid.TryWriteBytes order.
pub fn guidFromHyphenString(s: []const u8, out: *[16]u8) !void {
    // Expected 8-4-4-4-12 hex with hyphens → 36 chars.
    var hex: [32]u8 = undefined;
    var hi: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (hi >= 32) return error.BadGuid;
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.BadGuid,
        };
        if (hi % 2 == 0) {
            hex[hi / 2] = v << 4;
        } else {
            hex[hi / 2] |= v;
        }
        hi += 1;
    }
    if (hi != 32) return error.BadGuid;
    // .NET Guid layout: Data1 LE, Data2 LE, Data3 LE, Data4[8] as-is.
    // String groups: tttttttt-tttt-tttt-cccc-nnnnnnnnnnnn
    // bytes raw big-endian groups → rearrange:
    const raw = hex;
    out[0] = raw[3];
    out[1] = raw[2];
    out[2] = raw[1];
    out[3] = raw[0];
    out[4] = raw[5];
    out[5] = raw[4];
    out[6] = raw[7];
    out[7] = raw[6];
    @memcpy(out[8..16], raw[8..16]);
}

fn attrValue(open_tag: []const u8, key: []const u8) ?[]const u8 {
    // key="value"
    var needle_buf: [64]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    @memcpy(needle_buf[0..key.len], key);
    needle_buf[key.len] = '=';
    needle_buf[key.len + 1] = '"';
    const needle = needle_buf[0 .. key.len + 2];
    // Anchor on a preceding delimiter: `prob=` must not match `force_prob=`.
    var from: usize = 0;
    const i = while (std.mem.indexOfPos(u8, open_tag, from, needle)) |k| {
        if (k > 0 and (open_tag[k - 1] == ' ' or open_tag[k - 1] == '\t' or
            open_tag[k - 1] == '\n' or open_tag[k - 1] == '\r')) break k;
        from = k + 1;
    } else return null;
    const start = i + needle.len;
    const end = std.mem.indexOfPos(u8, open_tag, start, "\"") orelse return null;
    return open_tag[start..end];
}

fn parseI32Attr(open_tag: []const u8, key: []const u8, default: i32) i32 {
    const v = attrValue(open_tag, key) orelse return default;
    return std.fmt.parseInt(i32, v, 10) catch default;
}

/// Load all `*_signs.xml` under prefabs_root (e.g. Data/Prefabs).
pub fn loadFromPrefabsRoot(allocator: std.mem.Allocator, prefabs_root: []const u8) !Catalog {
    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(SignEntry) = .empty;
    defer list.deinit(allocator);

    try walkSigns(allocator, arena, prefabs_root, &list);

    // readdir order is OS/filesystem dependent; wire batches iterate this
    // slice, so sort for seed-stable SignDataResponse across machines (DST).
    std.mem.sort(SignEntry, list.items, {}, struct {
        fn less(_: void, a: SignEntry, b: SignEntry) bool {
            const o = std.mem.order(u8, a.library, b.library);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    const entries = try arena.alloc(SignEntry, list.items.len);
    @memcpy(entries, list.items);
    return .{ .entries = entries, .arena_ptr = arena_holder };
}

fn walkSigns(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    list: *std.ArrayList(SignEntry),
) !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        var child_buf: [2048]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        if (entry.kind == .directory) {
            try walkSigns(gpa, arena, child, list);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "_signs.xml")) continue;
        const lib = entry.name[0 .. entry.name.len - "_signs.xml".len];
        try parseSignsFile(gpa, arena, child, lib, list);
        if (list.items.len >= max_signs) return;
    }
}

fn parseSignsFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    library: []const u8,
    list: *std.ArrayList(SignEntry),
) !void {
    const raw = io_fs.readFileAll(gpa, path) catch return;
    defer gpa.free(raw);

    const lib_owned = try arena.dupe(u8, library);
    var i: usize = 0;
    while (i < raw.len and list.items.len < max_signs) {
        const si = std.mem.indexOfPos(u8, raw, i, "<sign ") orelse break;
        const gt = std.mem.indexOfPos(u8, raw, si, ">") orelse break;
        const tag = raw[si .. gt + 1];
        i = gt + 1;

        const guid_s = attrValue(tag, "guid") orelse continue;
        var guid: [16]u8 = undefined;
        guidFromHyphenString(guid_s, &guid) catch continue;
        const name_s = attrValue(tag, "name") orelse "";
        try list.append(gpa, .{
            .library = lib_owned,
            .name = try arena.dupe(u8, name_s),
            .guid = guid,
            .next_poly = parseI32Attr(tag, "next_poly_id", 0),
            .next_text = parseI32Attr(tag, "next_text_id", 0),
            .next_noise = parseI32Attr(tag, "next_noise_id", 0),
            .next_group = parseI32Attr(tag, "next_group_id", 0),
        });
    }
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8) !?Catalog {
    if (game_dir) |gd| {
        var path_buf: [2048]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Prefabs", .{gd});
        return loadFromPrefabsRoot(allocator, p) catch null;
    }
    return null;
}

test "guid net order" {
    var g: [16]u8 = undefined;
    try guidFromHyphenString("00112233-4455-6677-8899-aabbccddeeff", &g);
    try std.testing.expectEqual(@as(u8, 0x33), g[0]);
    try std.testing.expectEqual(@as(u8, 0x22), g[1]);
    try std.testing.expectEqual(@as(u8, 0x11), g[2]);
    try std.testing.expectEqual(@as(u8, 0x00), g[3]);
    try std.testing.expectEqual(@as(u8, 0x55), g[4]);
    try std.testing.expectEqual(@as(u8, 0x44), g[5]);
    try std.testing.expectEqual(@as(u8, 0x77), g[6]);
    try std.testing.expectEqual(@as(u8, 0x66), g[7]);
    try std.testing.expectEqual(@as(u8, 0x88), g[8]);
    try std.testing.expectEqual(@as(u8, 0xaa), g[10]);
}
