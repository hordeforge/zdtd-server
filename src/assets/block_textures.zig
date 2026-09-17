//! Default Block.Texture → textureFull (i64) from stock blocks.xml.
//! Face paint is 6×u8 packed little-endian (matches TTS paint samples like
//! 0x0b0b0b0b0b0b for six faces of texture 11). Shape blocks with textureFull=0
//! render grey; emit packed defaults on the wire for unpainted cells.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const arena_util = @import("../util/arena.zig");

/// Pack 6 face indices with 8 bits each (TTS paint samples for ids ≤255).
pub fn packFaces8(faces: [6]u8) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        v |= @as(u64, faces[i]) << @intCast(i * 8);
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
    for (faces, 0..) |f, i| f8[i] = @intCast(f);
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
        return arena_util.ensureLazyArena(&self.arena_ptr, allocator);
    }

    fn putNameTex(self: *Table, allocator: std.mem.Allocator, name: []const u8, tex: u64) !void {
        const arena = try self.ensureArena(allocator);
        const kn = try arena.dupe(u8, name);
        try self.name_tex.put(arena, kn, tex);
    }

    /// Full `Texture` property value of a block, own body first, then the
    /// Extends chain (stock `CreateProperties` copies the parent's *resolved*
    /// dictionary, so a block sees its grandparent's row). The starting
    /// block's Extends `param1` excludes that property from the whole chain
    /// (own body included) exactly like the blocks.zig walk; depth-capped so a
    /// corrupt cycle cannot spin.
    fn textureValue(clean: []const u8, start: usize, name_idx: *const NameIndex) ?[]const u8 {
        const max_depth: usize = 8;
        const own = ownTextureValue(clean, start);
        if (own != null) return own;
        var p1: []const u8 = "";
        var ext = extendsValue(clean, start);
        if (ext) |_| {
            // The starting block's own param1 excludes the property from the
            // whole chain (stock CreateProperties).
            p1 = param1Value(clean, start);
        } else return null;
        if (xml.tagListContains(p1, "Texture")) return null;
        var depth: usize = 0;
        while (ext) |e| : (depth += 1) {
            if (depth >= max_depth) return null;
            const base = name_idx.map.get(e) orelse return null;
            if (ownTextureValue(clean, base)) |tv| return tv;
            ext = extendsValue(clean, base);
        }
        return null;
    }

    const NameIndex = struct {
        map: std.StringHashMapUnmanaged(usize) = .{},
    };

    fn blockAt(clean: []const u8, pos: usize) bool {
        return std.mem.startsWith(u8, clean[pos..], "<block ");
    }

    /// `<property name="Extends" value=...>` of the block starting at `bi`,
    /// or null when it declares none.
    fn extendsValue(clean: []const u8, bi: usize) ?[]const u8 {
        var i = bi;
        while (i < clean.len) {
            const pi = std.mem.findPos(u8, clean, i, "<property") orelse return null;
            if (pi >= blockEnd(clean, bi)) return null;
            if (std.mem.eql(u8, xml.attr(clean, pi, "name") orelse "", "Extends"))
                return xml.attr(clean, pi, "value");
            i = pi + 9;
        }
        return null;
    }

    fn param1Value(clean: []const u8, bi: usize) []const u8 {
        var i = bi;
        while (i < clean.len) {
            const pi = std.mem.findPos(u8, clean, i, "<property") orelse return "";
            if (pi >= blockEnd(clean, bi)) return "";
            if (std.mem.eql(u8, xml.attr(clean, pi, "name") orelse "", "Extends"))
                return xml.attr(clean, pi, "param1") orelse "";
            i = pi + 9;
        }
        return "";
    }

    fn blockEnd(clean: []const u8, bi: usize) usize {
        const gt = std.mem.findPos(u8, clean, bi, ">") orelse return clean.len;
        if (gt > bi and clean[gt - 1] == '/') return gt + 1;
        return std.mem.findPos(u8, clean, gt, "</block>") orelse clean.len;
    }

    fn ownTextureValue(clean: []const u8, bi: usize) ?[]const u8 {
        const end = blockEnd(clean, bi);
        var i = bi;
        while (i < end) {
            const pi = std.mem.findPos(u8, clean, i, "<property") orelse return null;
            if (pi >= end) return null;
            if (std.mem.eql(u8, xml.attr(clean, pi, "name") orelse "", "Texture"))
                return xml.attr(clean, pi, "value");
            i = pi + 9;
        }
        return null;
    }

    pub fn mergeBlocksXml(self: *Table, allocator: std.mem.Allocator, path: []const u8) !void {
        const clean = try xml.readCleanFile(allocator, path);
        defer allocator.free(clean);
        // Name -> block offset, so the Extends walk below resolves chains
        // without rescanning the file.
        var name_idx = NameIndex{};
        defer name_idx.map.deinit(allocator);
        var i: usize = 0;
        while (i < clean.len) {
            const bi = std.mem.findPos(u8, clean, i, "<block ") orelse break;
            const name = xml.attr(clean, bi, "name") orelse {
                i = bi + 7;
                continue;
            };
            try name_idx.map.put(allocator, name, bi);
            const gt = std.mem.findPos(u8, clean, bi, ">") orelse break;
            i = blockEnd(clean, bi) + 1;
            _ = gt;
        }
        var it = name_idx.map.iterator();
        while (it.next()) |e| {
            if (textureValue(clean, e.value_ptr.*, &name_idx)) |tv| {
                if (parseTextureValue(tv) != 0) try self.putNameTex(allocator, e.key_ptr.*, parseTextureValue(tv));
            }
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
        if (paths.hasPatches()) {
            if (try paths.readConfigXml(allocator, "blocks.xml", game_dir, config_dir)) |merged| {
                defer allocator.free(merged);
                io_fs.mkdirPath(".zdtd_cfg_cache");
                const cp = ".zdtd_cfg_cache/blocks.xml";
                if (io_fs.writeFile(cp, merged)) |_| {
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

test "Texture resolves through the Extends chain" {
    // Fixture mirrors the stock shape: masters declare the row, children
    // carry only Extends; one child opts out through param1, one chain has a
    // >255 atlas id the channel cannot carry.
    const src =
        \\<blocks>
        \\<block name="woodNoUpgradeMaster">
        \\  <property name="Texture" value="241" />
        \\</block>
        \\<block name="woodMaster">
        \\  <property name="Extends" value="woodNoUpgradeMaster" />
        \\</block>
        \\<block name="oddMulti">
        \\  <property name="Extends" value="multiBase" />
        \\</block>
        \\<block name="multiBase">
        \\  <property name="Texture" value="78,84,79,84,84,84" />
        \\</block>
        \\<block name="atlasOnly">
        \\  <property name="Extends" value="atlasBase" />
        \\</block>
        \\<block name="atlasBase">
        \\  <property name="Texture" value="288,570,570,570,570,570" />
        \\</block>
        \\<block name="signYardSign01">
        \\  <property name="Extends" value="signBase" param1="Mesh,Texture,MultiBlockDim" />
        \\</block>
        \\<block name="signBase">
        \\  <property name="Texture" value="42" />
        \\</block>
        \\</blocks>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/blocks.xml", .{dir});
    try io_fs.writeFile(path, src);
    var t: Table = .{};
    defer t.deinit();
    try t.mergeBlocksXml(std.testing.allocator, path);
    try std.testing.expectEqual(@as(u64, 0xF1F1F1F1F1F1), t.name_tex.get("woodMaster").?);
    const multi = t.name_tex.get("oddMulti").?;
    try std.testing.expectEqual(@as(u64, 78), multi & 0xff);
    try std.testing.expectEqual(@as(u64, 79), (multi >> 16) & 0xff);
    // >255 atlas ids cannot ride the 6xu8 channel: nothing stored.
    try std.testing.expect(t.name_tex.get("atlasOnly") == null);
    // param1="...,Texture,..." excludes the property from the whole chain.
    try std.testing.expect(t.name_tex.get("signYardSign01") == null);
    // Base rows still resolve on their own.
    try std.testing.expectEqual(@as(u64, 0x2A2A2A2A2A2A), t.name_tex.get("signBase").?);
}
