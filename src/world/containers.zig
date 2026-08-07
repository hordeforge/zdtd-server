//! World-position keyed loot containers (block TE storage).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");

pub const max_container_slots: usize = 54; // 9x6 common chest
/// Game embeds ContainerStore on the heap (allocator.create), so the array is
/// sized for a long-lived world; the save path buffers on the heap, not the
/// stack (GAP 12: 256 silently dropped the 257th container on save).
pub const max_containers: usize = 512;
const persisted_container_size: usize = 20 + max_container_slots * 7 + 4; // + touched_day u32
const save_capacity: usize = 6 + max_containers * persisted_container_size;

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
    /// In-game day the container's loot was generated or last taken from
    /// (LootRespawnDays re-roll base). 0 = unknown (pre-persistence saves).
    touched_day: u32 = 0,
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
        // Stop after visiting every used slot: Container is ~1.5 KiB, so a
        // full 256-slot sweep strides ~390 KiB of cache per lookup.
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_containers and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            if (PosKey.eql(self.items[i].pos, pos)) return &self.items[i];
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
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_containers and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            if (std.mem.eql(u8, &self.items[i].inv_guid, guid)) return &self.items[i];
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
    ///
    /// Records are sorted by world pos so bytes are independent of sparse slot
    /// assignment order (needed for DST fault injection / mid-save replay).
    /// `allocator` owns the encode buffer (max_containers x 400+ bytes is too
    /// large for a stack frame; the GAP 12 save path used to truncate the
    /// tail once the fixed buffer filled).
    pub fn save(self: *const ContainerStore, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/containers.zct", .{dir});
        const buf = try allocator.alloc(u8, save_capacity);
        defer allocator.free(buf);
        var o: usize = 0;
        @memcpy(buf[0..4], "ZCT1");
        o = 6; // count patched below

        // Collect used indices, sort by (x,y,z). max_containers is fixed.
        var idxs: [max_containers]u16 = undefined;
        var n_idx: usize = 0;
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (!self.used[i]) continue;
            idxs[n_idx] = @intCast(i);
            n_idx += 1;
        }
        std.mem.sort(u16, idxs[0..n_idx], self, struct {
            fn less(store: *const ContainerStore, a: u16, b: u16) bool {
                const pa = store.items[a].pos;
                const pb = store.items[b].pos;
                if (pa.x != pb.x) return pa.x < pb.x;
                if (pa.y != pb.y) return pa.y < pb.y;
                return pa.z < pb.z;
            }
        }.less);

        var count: u16 = 0;
        for (idxs[0..n_idx]) |ii| {
            const c = &self.items[ii];
            if (o + 20 + @as(usize, c.slot_count) * 7 + 4 > buf.len) break;
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
            // touched_day u32 appended after the slots; older saves omit it and
            // load as 0 (no immediate respawn).
            std.mem.writeInt(u32, buf[o..][0..4], c.touched_day, .little);
            o += 4;
            count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], count, .little);
        try io_fs.writeFileSimple(p, buf[0..o]);
    }

    /// Decode a ZCT1 buffer (magic | count | records). Used by load and fuzz.
    pub fn loadFromSlice(self: *ContainerStore, buf: []const u8) !void {
        const len = buf.len;
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
            // touched_day appended after the slots in newer saves; older files
            // end at the last slot and load touched_day as 0.
            if (o + 4 <= len) {
                c.touched_day = std.mem.readInt(u32, buf[o..][0..4], .little);
                o += 4;
            }
        }
    }

    pub fn load(self: *ContainerStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/containers.zct", .{dir});
        // Only a missing file means "fresh world"; any other read failure must
        // surface so the caller can log it before the next save clobbers data.
        const data = io_fs.readFileAll(std.heap.page_allocator, p) catch |err| switch (err) {
            error.FileNotFound => return error.OpenFailed,
            else => return error.ReadFailed,
        };
        defer std.heap.page_allocator.free(data);
        return self.loadFromSlice(data);
    }
};

test "container store saves past the old 256 cap (GAP 12)" {
    // The fixed save buffer used to truncate the tail once it filled (256
    // containers); the encode now buffers on the heap sized for max_containers.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var s: ContainerStore = .{};
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const c = s.getOrCreate(.{ .x = @intCast(i), .y = 70, .z = @intCast(i * 3) }, 8, 42).?;
        c.setSlot(0, .{ .item_id = 7, .count = 1, .quality = 1, .meta = 0 });
    }
    try s.save(dir, std.testing.allocator);
    var s2: ContainerStore = .{};
    try s2.load(dir);
    var found: usize = 0;
    for (s2.used) |u| {
        if (u) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 300), found);
    const tail = s2.get(.{ .x = 299, .y = 70, .z = 897 }).?;
    try std.testing.expectEqual(@as(u16, 7), tail.slots[0].item_id);
    std.debug.print("PASS containers-cap: 300 containers round-trip (cap was 256)\n", .{});
}

test "container store save load roundtrip" {
    var s: ContainerStore = .{};
    const c = s.getOrCreate(.{ .x = 5, .y = 70, .z = 6 }, 8, 42).?;
    c.setSlot(0, .{ .item_id = 7, .count = 12, .quality = 2, .meta = 3 });
    try s.save(".", std.testing.allocator);
    var s2: ContainerStore = .{};
    try s2.load(".");
    const c2 = s2.get(.{ .x = 5, .y = 70, .z = 6 }).?;
    try std.testing.expectEqual(@as(u16, 7), c2.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 12), c2.slots[0].count);
    try std.testing.expectEqual(@as(u8, 2), c2.slots[0].quality);
    try std.testing.expect(c2.touched);
    io_fs.deleteFileSimple("./containers.zct");
}

test "container save order is pos-sorted not slot-order" {
    io_fs.mkdirPathSimple(".zdtd_cfg_cache");
    // Reverse-insert so sparse slot indices disagree with world-pos order.
    var s: ContainerStore = .{};
    _ = s.getOrCreate(.{ .x = 9, .y = 70, .z = 0 }, 8, 1).?;
    _ = s.getOrCreate(.{ .x = 1, .y = 70, .z = 0 }, 8, 2).?;
    try s.save(".zdtd_cfg_cache", std.testing.allocator);
    const data = try io_fs.readFileAll(std.testing.allocator, ".zdtd_cfg_cache/containers.zct");
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len >= 6 + 40);
    // First record pos.x must be 1 (sorted), not 9 (slot-0 insert).
    const first_x = std.mem.readInt(i32, data[6..10], .little);
    try std.testing.expectEqual(@as(i32, 1), first_x);
    io_fs.deleteFileSimple(".zdtd_cfg_cache/containers.zct");
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

test "container persistence retains every full-capacity container" {
    var s: ContainerStore = .{};
    var i: usize = 0;
    while (i < max_containers) : (i += 1) {
        const c = s.getOrCreate(.{ .x = @intCast(i), .y = 70, .z = 0 }, max_container_slots, 42).?;
        c.setSlot(max_container_slots - 1, .{ .item_id = 7, .count = @intCast(i + 1) });
    }
    try s.save(".", std.testing.allocator);
    var s2: ContainerStore = .{};
    try s2.load(".");
    try std.testing.expectEqual(max_containers, s2.n);
    const last = s2.get(.{ .x = max_containers - 1, .y = 70, .z = 0 }).?;
    try std.testing.expectEqual(@as(u16, max_containers), last.slots[max_container_slots - 1].count);
    io_fs.deleteFileSimple("./containers.zct");
}
