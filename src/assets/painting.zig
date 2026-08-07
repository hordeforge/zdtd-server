//! painting.xml: paint id (0–255) ↔ TextureId for chunk face paint.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_paints: usize = 256;

pub const Entry = struct {
    paint_id: u8 = 0,
    texture_id: u16 = 0,
    name: []const u8 = "",
};

pub const Table = struct {
    /// paint_id → texture_id (0xFFFF = unset)
    paint_to_tex: [max_paints]u16 = .{0xFFFF} ** max_paints,
    entries: []const Entry = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    n: usize = 0,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.entries = &.{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn textureOf(self: *const Table, paint_id: u8) ?u16 {
        const t = self.paint_to_tex[paint_id];
        if (t == 0xFFFF) return null;
        return t;
    }
};

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var t: Table = .{};
    t.arena_ptr = arena_holder;
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len) {
        const pi = std.mem.indexOfPos(u8, clean, i, "<paint ") orelse break;
        const id_s = xml.attr(clean, pi, "id") orelse {
            i = pi + 7;
            continue;
        };
        const name = xml.attr(clean, pi, "name") orelse "";
        const pid = std.fmt.parseInt(u8, id_s, 10) catch {
            i = pi + 7;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, pi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > pi and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</paint>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        const tid: u16 = if (xml.propertyValue(body, "TextureId")) |tv|
            xml.parseU16(tv) orelse 0
        else
            0;
        t.paint_to_tex[pid] = tid;
        const kn = try arena.dupe(u8, name);
        try list.append(allocator, .{ .paint_id = pid, .texture_id = tid, .name = kn });
        i = body_end + 1;
    }

    const entries = try arena.alloc(Entry, list.items.len);
    @memcpy(entries, list.items);
    t.entries = entries;
    t.n = entries.len;
    return t;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("painting.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "load painting.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/painting.xml";
    const t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer {
        var tt = t;
        tt.deinit();
    }
    try std.testing.expect(t.n > 10);
    try std.testing.expectEqual(@as(u16, 0), t.textureOf(0).?);
    try std.testing.expectEqual(@as(u16, 7), t.textureOf(1).?); // brick
}
