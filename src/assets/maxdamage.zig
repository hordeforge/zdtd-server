//! MaxDamage lookup: blocks.xml name→hp + optional AssignIds map from .blocks.nim
//! or a version-matched id\tname dump. Without a full id map, callers fall back to
//! band defaults. Storage names (LootList / CompositeTileEntity) ride the same table.

const std = @import("std");
const xml = @import("xml_util.zig");
const linux = std.os.linux;
const blocks_nim = @import("../world/blocks_nim.zig");

/// Bundled V3.1.4 full client AssignIds dump (ZDTD_DUMP_BLOCK_IDS Postfix).
/// Pins verified: treeDeadTree02=24626, cntWoodenChestClosed=18671. No stale saves.
pub const bundled_assignids_path = "assets/fixtures/assignids_v314.txt";

pub const Table = struct {
    /// name → MaxDamage
    by_name: std.StringHashMapUnmanaged(u16) = .{},
    /// AssignIds → MaxDamage (filled when .blocks.nim / dump loaded)
    by_id: std.AutoHashMapUnmanaged(u16, u16) = .{},
    /// AssignIds → true for blocks with LootList or CompositeTileEntity class
    storage_ids: std.AutoHashMapUnmanaged(u16, void) = .{},
    /// name → true (storage from blocks.xml); keys live in arena
    storage_names: std.StringHashMapUnmanaged(void) = .{},
    /// block name → AssignIds runtime id (every dump row, not just MaxDamage hits).
    id_by_name: std.StringHashMapUnmanaged(u16) = .{},
    /// block name → power watts (MaxPower for sources, else RequiredPower for
    /// consumers). From blocks.xml DynamicProperties, keyed by name like by_name.
    power_watts_by_name: std.StringHashMapUnmanaged(f32) = .{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            // hashmaps use arena for keys; just free arena
            self.by_name = .{};
            self.by_id = .{};
            self.storage_ids = .{};
            self.storage_names = .{};
            self.id_by_name = .{};
            self.power_watts_by_name = .{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn empty() Table {
        return .{};
    }

    pub fn maxDamage(self: *const Table, block_id: u16) ?u16 {
        return self.by_id.get(block_id);
    }

    pub fn maxDamageByName(self: *const Table, name: []const u8) ?u16 {
        return self.by_name.get(name);
    }

    pub fn isStorageId(self: *const Table, block_id: u16) bool {
        return self.storage_ids.contains(block_id);
    }

    /// Runtime AssignIds id for a stock block name (from dump / .nim), else null.
    pub fn idByName(self: *const Table, name: []const u8) ?u16 {
        return self.id_by_name.get(name);
    }

    /// Power watts for a stock block name (MaxPower/RequiredPower), else null.
    pub fn wattsByName(self: *const Table, name: []const u8) ?f32 {
        return self.power_watts_by_name.get(name);
    }

    fn arenaAlloc(self: *Table, allocator: std.mem.Allocator) std.mem.Allocator {
        if (self.arena_ptr) |ap| return ap.allocator();
        return allocator;
    }

    fn markStorageIfKnown(self: *Table, arena: std.mem.Allocator, id: u16, name: []const u8) !void {
        if (self.storage_names.contains(name)) {
            try self.storage_ids.put(arena, id, {});
        }
    }

    /// Merge AssignIds→name from a .blocks.nim into by_id using by_name MaxDamage.
    /// Prefab nim local ids may not match runtime AssignIds; still useful when they do.
    pub fn mergeNim(self: *Table, allocator: std.mem.Allocator, nim_path: []const u8) !void {
        var nim = blocks_nim.loadFromPath(allocator, nim_path) catch return;
        defer nim.deinit();
        const arena = self.arenaAlloc(allocator);
        for (nim.names, 0..) |name, id| {
            if (name.len == 0) continue;
            // Prefab nim ids are local; only fill MaxDamage when they happen to match.
            // Do not mark storage from nim (wrong AssignIds pollution).
            if (self.by_name.get(name)) |hp| {
                try self.by_id.put(arena, @intCast(id), hp);
            }
        }
    }

    /// Merge AssignIds dump: lines `id\tname` or `id name` (client ZDTD_DUMP_BLOCK_IDS).
    pub fn mergeAssignIdsDump(self: *Table, allocator: std.mem.Allocator, path: []const u8) !void {
        const raw = readFileAll(allocator, path) catch return;
        defer allocator.free(raw);
        const arena = self.arenaAlloc(allocator);
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line_raw| {
            var line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            // Accept "id\tname", "id name", "name=id"
            var id: u16 = 0;
            var name: []const u8 = "";
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                name = std.mem.trim(u8, line[0..eq], " \t");
                const id_s = std.mem.trim(u8, line[eq + 1 ..], " \t");
                id = std.fmt.parseInt(u16, id_s, 10) catch continue;
            } else {
                var sp = std.mem.tokenizeAny(u8, line, " \t");
                const id_s = sp.next() orelse continue;
                id = std.fmt.parseInt(u16, id_s, 10) catch continue;
                name = std.mem.trim(u8, sp.rest(), " \t");
            }
            if (name.len == 0) continue;
            if (self.by_name.get(name)) |hp| {
                try self.by_id.put(arena, id, hp);
            }
            try self.markStorageIfKnown(arena, id, name);
            const name_dup = try arena.dupe(u8, name);
            try self.id_by_name.put(arena, name_dup, id);
        }
    }

    /// Try bundled fixture then optional external path. Silent no-op if missing.
    pub fn tryMergeBundledAssignIds(self: *Table, allocator: std.mem.Allocator) void {
        self.mergeAssignIdsDump(allocator, bundled_assignids_path) catch {};
    }
};

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
    var off: usize = 0;
    while (off < size) {
        const n = linux.read(fd, buf[off..].ptr, size - off);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        off += @intCast(n);
    }
    return buf[0..off];
}

fn bodyHasStorage(body: []const u8) bool {
    // LootList property or CompositeTileEntity class → storage TE candidate.
    if (xml.propertyValue(body, "LootList") != null) return true;
    if (xml.propertyValue(body, "Class")) |cls| {
        if (std.mem.eql(u8, cls, "CompositeTileEntity")) return true;
    }
    return false;
}

pub fn loadFromBlocksXml(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try readFileAll(allocator, path);
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

    var by_name: std.StringHashMapUnmanaged(u16) = .{};
    var storage_names: std.StringHashMapUnmanaged(void) = .{};
    var power_watts_by_name: std.StringHashMapUnmanaged(f32) = .{};
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
        const kn = try arena.dupe(u8, name);
        if (xml.propertyValue(body, "MaxDamage")) |md| {
            if (xml.parseU16(md)) |hp| {
                try by_name.put(arena, kn, hp);
            }
        }
        if (bodyHasStorage(body)) {
            try storage_names.put(arena, kn, {});
        }
        // Power watts: prefer MaxPower (sources) over RequiredPower (consumers).
        // PowerConsumer::SetValuesFromBlock parses RequiredPower (asm.il:892090);
        // source MaxPower comes from the block property (generatorbank etc.).
        const watts: ?f32 = if (xml.propertyValue(body, "MaxPower")) |mp|
            xml.parseF32(mp)
        else if (xml.propertyValue(body, "RequiredPower")) |rp|
            xml.parseF32(rp)
        else
            null;
        if (watts) |w| {
            try power_watts_by_name.put(arena, kn, w);
        }
        i = body_end + 1;
    }

    return .{
        .by_name = by_name,
        .by_id = .{},
        .storage_ids = .{},
        .storage_names = storage_names,
        .power_watts_by_name = power_watts_by_name,
        .arena_ptr = arena_holder,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    var path_buf: [2048]u8 = undefined;
    if (config_dir) |cd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/blocks.xml", .{cd});
        return loadFromBlocksXml(allocator, p) catch null;
    }
    if (game_dir) |gd| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Config/blocks.xml", .{gd});
        return loadFromBlocksXml(allocator, p) catch null;
    }
    return null;
}

test "load blocks.xml MaxDamage when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/blocks.xml";
    var t = loadFromBlocksXml(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.by_name.count() > 50);
    try std.testing.expectEqual(@as(u16, 7500), t.maxDamageByName("cntHardenedChestInsecure").?);
    try std.testing.expect(t.storage_names.contains("cntWoodenChestClosed"));
    // Power watts: source MaxPower and consumer RequiredPower from blocks.xml.
    try std.testing.expect(t.wattsByName("generatorbank").? >= 12250);
    try std.testing.expectEqual(@as(f32, 15), t.wattsByName("autoTurret").?);
    // Merge nim map
    const nim = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs/POIs/abandoned_house_01.blocks.nim";
    try t.mergeNim(std.testing.allocator, nim);
    try std.testing.expect(t.by_id.count() > 0);
}

test "bundled assignids dump matches stock_deco pins" {
    var t = Table.empty();
    defer t.deinit();
    // Minimal name table so merge keeps hp rows; storage names for isStorageId.
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    t.arena_ptr = arena_holder;
    const arena = arena_holder.allocator();
    const names = [_]struct { []const u8, u16 }{
        .{ "cntWoodenChestClosed", 300 },
        .{ "cntWoodenChestOpen", 300 },
        .{ "cntHardenedChestInsecure", 7500 },
        .{ "cntDeskSafe", 2000 },
        .{ "cntWoodWritableCrate", 500 },
        .{ "treeDeadTree02", 100 },
        .{ "air", 1 },
        .{ "water", 100 },
    };
    for (names) |pair| {
        const kn = try arena.dupe(u8, pair[0]);
        try t.by_name.put(arena, kn, pair[1]);
        if (std.mem.startsWith(u8, pair[0], "cnt")) {
            try t.storage_names.put(arena, kn, {});
        }
    }
    t.mergeAssignIdsDump(std.testing.allocator, bundled_assignids_path) catch return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 300), t.maxDamage(18671).?);
    try std.testing.expectEqual(@as(u16, 7500), t.maxDamage(18650).?);
    try std.testing.expectEqual(@as(u16, 2000), t.maxDamage(18515).?);
    try std.testing.expectEqual(@as(u16, 100), t.maxDamage(24626).?); // treeDeadTree02
    try std.testing.expect(t.isStorageId(18671));
    try std.testing.expect(t.isStorageId(18650));
    try std.testing.expect(!t.isStorageId(24626)); // tree, not storage
    try std.testing.expect(t.by_id.count() >= 8);
}
