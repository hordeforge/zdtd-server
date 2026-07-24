//! Prefab sign libraries (*_signs.xml under Data/Prefabs) for NetPackageSignDataResponse.
//! Minimal SignData: guid + name + next_* ids + zero layers (stops client "Failed to
//! retrieve sign data" for missing library guids; full layer paint is later).

const std = @import("std");
const linux = std.os.linux;
const binary = @import("../wire/binary.zig");

pub const max_signs: usize = 4096;
pub const max_batch_payload: usize = 48 * 1024;

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
    const i = std.mem.indexOf(u8, open_tag, needle) orelse return null;
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
    var path_z: [2048]u8 = undefined;
    if (dir_path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..dir_path.len], dir_path);
    path_z[dir_path.len] = 0;

    const fd_rc = linux.open(path_z[0..dir_path.len :0].ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return; // missing dir is ok
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) break;
        if (n == 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const ent: *align(1) const linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
            const reclen = ent.reclen;
            if (reclen == 0) break;
            const name_ptr: [*:0]const u8 = @ptrCast(&ent.name);
            const name = std.mem.span(name_ptr);
            off += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            var child_buf: [2048]u8 = undefined;
            const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, name }) catch continue;

            if (ent.type == linux.DT.DIR) {
                try walkSigns(gpa, arena, child, list);
                continue;
            }
            if (!std.mem.endsWith(u8, name, "_signs.xml")) continue;
            const lib = name[0 .. name.len - "_signs.xml".len];
            try parseSignsFile(gpa, arena, child, lib, list);
            if (list.items.len >= max_signs) return;
        }
    }
}

fn parseSignsFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    library: []const u8,
    list: *std.ArrayList(SignEntry),
) !void {
    const raw = readFileAll(gpa, path) catch return;
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

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [2048]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(path_z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return error.SeekFailed;
    const size: usize = @intCast(end);
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var got: usize = 0;
    while (got < size) {
        const n = linux.read(fd, buf[got..].ptr, size - got);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        got += @intCast(n);
    }
    return buf[0..got];
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8) !?Catalog {
    if (game_dir) |gd| {
        var path_buf: [2048]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Prefabs", .{gd});
        return loadFromPrefabsRoot(allocator, p) catch null;
    }
    return null;
}

/// Encode minimal SignData (zero layers).
pub fn writeSignData(w: *binary.Writer, e: SignEntry) !void {
    try w.writeBytes(&e.guid);
    try w.writeString(e.name);
    try w.writeI64(e.modified_ticks);
    try w.writeI32(e.next_poly);
    try w.writeI32(e.next_text);
    try w.writeI32(e.next_noise);
    try w.writeI32(e.next_group);
    try w.writeI32(0); // layer count
}

/// One NetPackageSignDataResponse body: isLastBatch + dataLen + data.
/// `data` layout: u32 size_marker (includes 4 + payload), then (library, SignData)* .
pub fn buildSignDataResponseBatch(
    buf: []u8,
    entries: []const SignEntry,
    start: usize,
    is_last: bool,
) !struct { body: []u8, next: usize } {
    if (buf.len < 32) return error.Overflow;
    // Reserve: bool(1) + i32 dataLen(4) + u32 size(4) + payload
    const data_start: usize = 1 + 4;
    const size_off = data_start;
    const payload_off = size_off + 4;
    if (payload_off >= buf.len) return error.Overflow;

    var w: binary.Writer = .{ .buf = buf, .pos = payload_off };
    var i = start;
    while (i < entries.len) : (i += 1) {
        const before = w.pos;
        writeSignEntry(&w, entries[i]) catch {
            w.pos = before;
            break;
        };
        // keep under max_batch_payload for the data blob
        if (w.pos - data_start > max_batch_payload and i > start) {
            w.pos = before;
            break;
        }
    }
    // if nothing fit and we have entries left, force one
    if (i == start and start < entries.len) {
        w.pos = payload_off;
        try writeSignEntry(&w, entries[start]);
        i = start + 1;
    }

    const end_pos = w.pos;
    const size_incl: u32 = @intCast(end_pos - size_off); // includes the u32 size field
    std.mem.writeInt(u32, buf[size_off..][0..4], size_incl, .little);

    const data_len: i32 = @intCast(end_pos - data_start);
    buf[0] = if (is_last and i >= entries.len) 1 else 0;
    std.mem.writeInt(i32, buf[1..5], data_len, .little);
    return .{ .body = buf[0..end_pos], .next = i };
}

fn writeSignEntry(w: *binary.Writer, e: SignEntry) !void {
    try w.writeString(e.library);
    try writeSignData(w, e);
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

test "sign batch empty layers" {
    var g: [16]u8 = .{0} ** 16;
    g[0] = 1;
    const e = [_]SignEntry{.{
        .library = "house_01",
        .name = "Front",
        .guid = g,
    }};
    var buf: [4096]u8 = undefined;
    const r = try buildSignDataResponseBatch(&buf, &e, 0, true);
    try std.testing.expect(r.body[0] == 1); // last
    try std.testing.expectEqual(@as(usize, 1), r.next);
    const dlen = std.mem.readInt(i32, r.body[1..5], .little);
    try std.testing.expect(dlen > 4);
}
