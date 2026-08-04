//! Default Block.Texture → textureFull (i64) from stock blocks.xml.
//! Face paint is 6×u8 packed little-endian (matches TTS paint samples like
//! 0x0b0b0b0b0b0b for six faces of texture 11). Shape blocks with textureFull=0
//! render grey; emit packed defaults on the wire for unpainted cells.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");

/// Pack 6 face indices with 8 bits each (TTS paint samples for ids ≤255).
pub fn packFaces8(faces: [6]u8) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        v |= @as(u64, faces[i]) << @intCast(i * 8);
    }
    return v;
}

/// Pack 6 face indices with 10 bits each (blocks.xml Texture ids up to ~702).
pub fn packFaces10(faces: [6]u16) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        v |= @as(u64, faces[i] & 0x3ff) << @intCast(i * 10);
    }
    return v;
}

/// Parse blocks.xml `Texture` for chunk-channel paint (6×u8 only).
/// Returns 0 if any face id > 255: those atlas ids live on Block.textureInfos
/// on the client, not in the chunk channel (SetBlockFaceTexture masks to 255).
pub fn parseTextureValue(s: []const u8) u64 {
    var faces: [6]u16 = .{0} ** 6;
    var fi: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (fi >= 6) break;
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        const n = std.fmt.parseInt(u16, t, 10) catch continue;
        faces[fi] = n;
        fi += 1;
    }
    if (fi == 0) return 0;
    if (fi == 1) {
        const v = faces[0];
        faces = .{ v, v, v, v, v, v };
    }
    for (faces) |f| {
        if (f > 255) return 0;
    }
    var f8: [6]u8 = undefined;
    for (faces, 0..) |f, i| f8[i] = @truncate(f);
    return packFaces8(f8);
}

pub const Table = struct {
    by_id: std.AutoHashMapUnmanaged(u16, u64) = .{},
    name_tex: std.StringHashMapUnmanaged(u64) = .{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.by_id = .{};
            self.name_tex = .{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn get(self: *const Table, type_id: u16) u64 {
        return self.by_id.get(type_id) orelse 0;
    }

    fn ensureArena(self: *Table, allocator: std.mem.Allocator) !std.mem.Allocator {
        if (self.arena_ptr) |ap| return ap.allocator();
        const ap = try allocator.create(std.heap.ArenaAllocator);
        ap.* = std.heap.ArenaAllocator.init(allocator);
        self.arena_ptr = ap;
        return ap.allocator();
    }

    fn putNameTex(self: *Table, allocator: std.mem.Allocator, name: []const u8, tex: u64) !void {
        const arena = try self.ensureArena(allocator);
        const kn = try arena.dupe(u8, name);
        try self.name_tex.put(arena, kn, tex);
    }

    pub fn mergeBlocksXml(self: *Table, allocator: std.mem.Allocator, path: []const u8) !void {
        const raw = try io_fs.readFileAll(allocator, path);
        defer allocator.free(raw);
        const clean = try xml.stripComments(allocator, raw);
        defer allocator.free(clean);
        var i: usize = 0;
        while (i < clean.len) {
            const bi = std.mem.indexOfPos(u8, clean, i, "<block ") orelse break;
            const name = xml.attr(clean, bi, "name") orelse {
                i = bi + 7;
                continue;
            };
            const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
            var body_end = gt + 1;
            if (!(gt > bi and clean[gt - 1] == '/')) {
                const close = std.mem.indexOfPos(u8, clean, gt, "</block>") orelse break;
                body_end = close;
            }
            const body = clean[gt + 1 .. body_end];
            if (xml.propertyValue(body, "Texture")) |tv| {
                const packed_t = parseTextureValue(tv);
                if (packed_t != 0) try self.putNameTex(allocator, name, packed_t);
            }
            i = body_end + 1;
        }
    }

    pub fn resolveIds(self: *Table, allocator: std.mem.Allocator, id_by_name: *const fn (?*anyopaque, []const u8) ?u16, ctx: ?*anyopaque) !void {
        const arena = try self.ensureArena(allocator);
        var it = self.name_tex.iterator();
        while (it.next()) |e| {
            const id = id_by_name(ctx, e.key_ptr.*) orelse continue;
            try self.by_id.put(arena, id, e.value_ptr.*);
        }
    }
};

pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    id_by_name: *const fn (?*anyopaque, []const u8) ?u16,
    ctx: ?*anyopaque,
) !?Table {
    const paths = @import("paths.zig");
    var path_buf: [2048]u8 = undefined;
    var t: Table = .{};
    errdefer t.deinit();
    const path: ?[]const u8 = blk: {
        if (paths.override_dirs.len > 0) {
            if (try paths.readConfigXml(allocator, "blocks.xml", game_dir, config_dir)) |merged| {
                defer allocator.free(merged);
                io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
                const cp = ".zdtd_cfg_cache/blocks.xml";
                if (io_fs.writeFile(allocator, cp, merged)) |_| {
                    break :blk cp;
                } else |_| {}
            }
        }
        break :blk paths.resolveConfigXml(&path_buf, "blocks.xml", game_dir, config_dir);
    };
    if (path) |p| {
        try t.mergeBlocksXml(allocator, p);
        try t.resolveIds(allocator, id_by_name, ctx);
        if (t.by_id.count() == 0) {
            t.deinit();
            return null;
        }
        return t;
    }
    return null;
}

test "packFaces and parseTextureValue" {
    try std.testing.expectEqual(@as(u64, 0x0b0b0b0b0b0b), packFaces8(.{ 11, 11, 11, 11, 11, 11 }));
    try std.testing.expectEqual(@as(u64, 0x020202020202), parseTextureValue("2"));
    const multi = parseTextureValue("11,12,13,14,15,16");
    try std.testing.expectEqual(@as(u64, 11), multi & 0xff);
    try std.testing.expectEqual(@as(u64, 16), (multi >> 40) & 0xff);
    // Terrain atlas ids >255 cannot go on the chunk channel (client uses Block.list).
    try std.testing.expectEqual(@as(u64, 0), parseTextureValue("288,570,570,570,570,570"));
    try std.testing.expectEqual(@as(u64, 0), parseTextureValue("570"));
}
