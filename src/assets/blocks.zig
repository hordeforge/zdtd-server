//! blocks.xml solid/name table. Wire ids come only from AssignIds (idByName),
//! never sequential XML declaration order.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const assignids = @import("assignids_comptime.zig");

pub const max_blocks: usize = 8192;

pub const BlockDef = struct {
    id: u16 = 0,
    name: []const u8 = "",
    solid: bool = true,
};

pub const IdByNameFn = *const fn (?*anyopaque, []const u8) ?u16;

pub const BlockTable = struct {
    defs: []const BlockDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *BlockTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() BlockTable {
        return .{ .defs = builtin_defs[0..], .source = .builtin };
    }

    pub fn byId(self: *const BlockTable, id: u16) ?BlockDef {
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const BlockTable, name: []const u8) ?BlockDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn isSolid(self: *const BlockTable, id: u16) bool {
        if (id == 0) return false;
        if (self.byId(id)) |d| return d.solid;
        return true;
    }
};

// Offline / no-dump slice: dump-validated pins only (assignids_comptime).
pub const builtin_defs = [_]BlockDef{
    .{ .id = assignids.air, .name = "air", .solid = false },
    .{ .id = assignids.terr_stone, .name = "terrStone", .solid = true },
    .{ .id = assignids.terrain_filler, .name = "terrainFiller", .solid = true },
    .{ .id = assignids.terrain_filler_adaptive, .name = "terrainFillerAdaptive", .solid = true },
    .{ .id = assignids.terr_bedrock, .name = "terrBedrock", .solid = true },
    .{ .id = assignids.terr_dirt, .name = "terrDirt", .solid = true },
    .{ .id = assignids.terr_forest_ground, .name = "terrForestGround", .solid = true },
    .{ .id = assignids.terr_sand, .name = "terrSand", .solid = true },
    .{ .id = assignids.terr_topsoil, .name = "terrTopSoil", .solid = true },
    .{ .id = assignids.water, .name = "water", .solid = false },
};

fn isSolidName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "air")) return false;
    if (std.mem.eql(u8, name, "water")) return false;
    if (std.mem.startsWith(u8, name, "water")) return false;
    if (std.mem.startsWith(u8, name, "terrWater")) return false;
    return true;
}

/// Load blocks.xml names; resolve ids only via AssignIds (`id_by_name`).
/// Names missing from the dump are omitted (fail closed).
pub fn loadFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !BlockTable {
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

    var list: std.ArrayList(BlockDef) = .empty;
    defer list.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and list.items.len < max_blocks) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<block ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        if (seen.contains(name)) {
            i = bi + 7;
            continue;
        }
        const id = id_by_name(ctx, name) orelse {
            i = bi + 7;
            continue;
        };
        const kn = try arena.dupe(u8, name);
        try seen.put(allocator, kn, {});
        try list.append(allocator, .{
            .id = id,
            .name = kn,
            .solid = isSolidName(name),
        });
        i = bi + 7;
    }

    if (list.items.len == 0) {
        // No dump match: fall back to builtin pins (offline).
        arena_holder.deinit();
        allocator.destroy(arena_holder);
        return BlockTable.builtin();
    }

    const defs = try arena.alloc(BlockDef, list.items.len);
    @memcpy(defs, list.items);
    return .{ .defs = defs, .arena_ptr = arena_holder, .source = .xml };
}

pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !?BlockTable {
    const paths = @import("paths.zig");
    var path_buf: [2048]u8 = undefined;
    const base = paths.resolveConfigXml(&path_buf, "blocks.xml", game_dir, config_dir) orelse return null;
    if (paths.override_dirs.len == 0) {
        return loadFromPath(allocator, base, id_by_name, ctx) catch null;
    }
    const merged = try paths.readConfigXml(allocator, "blocks.xml", game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
    const cp = ".zdtd_cfg_cache/blocks.xml";
    {
        io_fs.writeFile(allocator, cp, merged) catch return loadFromPath(allocator, base, id_by_name, ctx) catch null;
    }
    return loadFromPath(allocator, cp, id_by_name, ctx) catch null;
}

test "builtin block table" {
    const t = BlockTable.builtin();
    try std.testing.expect(t.isSolid(1)); // terrStone
    try std.testing.expect(!t.isSolid(0));
    try std.testing.expectEqualStrings("terrainFiller", t.byId(2).?.name);
    try std.testing.expectEqualStrings("terrDirt", t.byId(5).?.name);
    try std.testing.expect(!t.isSolid(240)); // water
}
