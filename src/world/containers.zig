//! World-position keyed loot containers (block TE storage).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");

pub const max_container_slots: usize = 54; // 9x6 common chest
/// Keep small: Game embeds ContainerStore; large arrays blow the stack on init.
pub const max_containers: usize = 256;

pub const PosKey = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn eql(a: PosKey, b: PosKey) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

pub const Container = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    /// Stock block id for composite TE (0 = generic).
    block_id: i32 = 0,
    /// Stable TransactionalInventory key (Guid bytes). Deterministic from pos.
    inv_guid: [16]u8 = .{0} ** 16,
    slots: [max_container_slots]components.InvSlot = [_]components.InvSlot{.{}} ** max_container_slots,
    slot_count: u16 = 8, // default 2x4
    touched: bool = false,
    player_storage: bool = true,

    pub fn clear(self: *Container) void {
        self.slots = [_]components.InvSlot{.{}} ** max_container_slots;
        self.touched = false;
    }

    pub fn setSlot(self: *Container, idx: usize, item: components.InvSlot) void {
        if (idx >= self.slot_count or idx >= max_container_slots) return;
        self.slots[idx] = item;
        self.touched = true;
    }
};

/// Deterministic Guid from world pos (not random NewGuid; stable across restarts).
/// Bytes: x:i32 | y:i32 | z:i32 | tag "ZTE\x01".
pub fn guidFromPos(pos: PosKey) [16]u8 {
    var g: [16]u8 = .{0} ** 16;
    std.mem.writeInt(i32, g[0..4], pos.x, .little);
    std.mem.writeInt(i32, g[4..8], pos.y, .little);
    std.mem.writeInt(i32, g[8..12], pos.z, .little);
    g[12] = 'Z';
    g[13] = 'T';
    g[14] = 'E';
    g[15] = 1;
    return g;
}

pub const ContainerStore = struct {
    items: [max_containers]Container = undefined,
    used: [max_containers]bool = .{false} ** max_containers,
    n: usize = 0,

    pub fn deinit(self: *ContainerStore) void {
        self.* = .{};
    }

    pub fn get(self: *ContainerStore, pos: PosKey) ?*Container {
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (self.used[i] and PosKey.eql(self.items[i].pos, pos)) return &self.items[i];
        }
        return null;
    }

    pub fn getOrCreate(self: *ContainerStore, pos: PosKey, slot_count: u16, block_id: i32) ?*Container {
        if (self.get(pos)) |c| return c;
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (self.used[i]) continue;
            self.used[i] = true;
            self.items[i] = .{
                .pos = pos,
                .block_id = block_id,
                .inv_guid = guidFromPos(pos),
                .slot_count = @min(slot_count, @as(u16, max_container_slots)),
            };
            self.n += 1;
            return &self.items[i];
        }
        return null;
    }

    pub fn getByGuid(self: *ContainerStore, guid: *const [16]u8) ?*Container {
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (self.used[i] and std.mem.eql(u8, &self.items[i].inv_guid, guid)) return &self.items[i];
        }
        return null;
    }

    pub fn remove(self: *ContainerStore, pos: PosKey) void {
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (self.used[i] and PosKey.eql(self.items[i].pos, pos)) {
                self.used[i] = false;
                self.items[i] = .{};
                if (self.n > 0) self.n -= 1;
                return;
            }
        }
    }

    /// Persist file: magic "ZCT1" | u16 count | per container:
    /// pos xyz i32*3 | block_id i32 | slot_count u16 | touched u8 | player u8 |
    /// slot_count * (item_id u16 | count u16 | quality u8 | meta u16).
    pub fn save(self: *const ContainerStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/containers.zct", .{dir});
        var buf: [64 * 1024]u8 = undefined;
        var o: usize = 0;
        @memcpy(buf[0..4], "ZCT1");
        o = 6; // count patched below
        var count: u16 = 0;
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (!self.used[i]) continue;
            const c = &self.items[i];
            if (o + 20 + @as(usize, c.slot_count) * 7 > buf.len) break;
            std.mem.writeInt(i32, buf[o..][0..4], c.pos.x, .little);
            std.mem.writeInt(i32, buf[o + 4 ..][0..4], c.pos.y, .little);
            std.mem.writeInt(i32, buf[o + 8 ..][0..4], c.pos.z, .little);
            std.mem.writeInt(i32, buf[o + 12 ..][0..4], c.block_id, .little);
            std.mem.writeInt(u16, buf[o + 16 ..][0..2], c.slot_count, .little);
            buf[o + 18] = @intFromBool(c.touched);
            buf[o + 19] = @intFromBool(c.player_storage);
            o += 20;
            var s: usize = 0;
            while (s < c.slot_count) : (s += 1) {
                const sl = c.slots[s];
                std.mem.writeInt(u16, buf[o..][0..2], sl.item_id, .little);
                std.mem.writeInt(u16, buf[o + 2 ..][0..2], sl.count, .little);
                buf[o + 4] = sl.quality;
                std.mem.writeInt(u16, buf[o + 5 ..][0..2], sl.meta, .little);
                o += 7;
            }
            count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], count, .little);
        try io_fs.writeFileSimple(p, buf[0..o]);
    }

    pub fn load(self: *ContainerStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/containers.zct", .{dir});
        const data = io_fs.readFileAll(std.heap.page_allocator, p) catch return error.OpenFailed;
        defer std.heap.page_allocator.free(data);
        const buf = data;
        const len = data.len;
        if (len < 6 or !std.mem.eql(u8, buf[0..4], "ZCT1")) return error.ReadFailed;
        const count = std.mem.readInt(u16, buf[4..6], .little);
        var o: usize = 6;
        var ci: u16 = 0;
        while (ci < count) : (ci += 1) {
            if (o + 20 > len) return error.ReadFailed;
            const pos: PosKey = .{
                .x = std.mem.readInt(i32, buf[o..][0..4], .little),
                .y = std.mem.readInt(i32, buf[o + 4 ..][0..4], .little),
                .z = std.mem.readInt(i32, buf[o + 8 ..][0..4], .little),
            };
            const block_id = std.mem.readInt(i32, buf[o + 12 ..][0..4], .little);
            const slot_count = std.mem.readInt(u16, buf[o + 16 ..][0..2], .little);
            const touched = buf[o + 18] != 0;
            const player = buf[o + 19] != 0;
            o += 20;
            if (o + @as(usize, slot_count) * 7 > len) return error.ReadFailed;
            const c = self.getOrCreate(pos, slot_count, block_id) orelse {
                o += @as(usize, slot_count) * 7;
                continue;
            };
            c.touched = touched;
            c.player_storage = player;
            var s: usize = 0;
            while (s < slot_count) : (s += 1) {
                if (s < max_container_slots) {
                    c.slots[s] = .{
                        .item_id = std.mem.readInt(u16, buf[o..][0..2], .little),
                        .count = std.mem.readInt(u16, buf[o + 2 ..][0..2], .little),
                        .quality = buf[o + 4],
                        .meta = std.mem.readInt(u16, buf[o + 5 ..][0..2], .little),
                    };
                }
                o += 7;
            }
        }
    }
};

test "container store save load roundtrip" {
    var s: ContainerStore = .{};
    const c = s.getOrCreate(.{ .x = 5, .y = 70, .z = 6 }, 8, 42).?;
    c.setSlot(0, .{ .item_id = 7, .count = 12, .quality = 2, .meta = 3 });
    try s.save(".");
    var s2: ContainerStore = .{};
    try s2.load(".");
    const c2 = s2.get(.{ .x = 5, .y = 70, .z = 6 }).?;
    try std.testing.expectEqual(@as(u16, 7), c2.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 12), c2.slots[0].count);
    try std.testing.expectEqual(@as(u8, 2), c2.slots[0].quality);
    try std.testing.expect(c2.touched);
    io_fs.deleteFileSimple("./containers.zct");
}

test "container get or create" {
    var s: ContainerStore = .{};
    const c = s.getOrCreate(.{ .x = 1, .y = 70, .z = 2 }, 8, 100).?;
    c.setSlot(0, .{ .item_id = 7, .count = 3, .quality = 1 });
    try std.testing.expectEqual(@as(u16, 7), s.get(.{ .x = 1, .y = 70, .z = 2 }).?.slots[0].item_id);
    const g = guidFromPos(.{ .x = 1, .y = 70, .z = 2 });
    try std.testing.expectEqualSlices(u8, &g, &c.inv_guid);
    try std.testing.expect(s.getByGuid(&g) == c);
}
