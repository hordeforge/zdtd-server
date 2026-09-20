//! World-position keyed loot containers (block TE storage).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const components = @import("../ecs/components.zig");

pub const max_container_slots: usize = 54; // 9x6 common chest
/// Game embeds ContainerStore on the heap (allocator.create), so the array is
/// sized for a long-lived world; the save path buffers on the heap, not the
/// stack. GAP 12: 256 silently dropped the 257th container on save (raised to
/// 512, then 2026-08-21 to 4096 + world-container eviction, because Navezgane
/// alone has thousands of loot containers and a hard cap truncates the tail  -
/// every container past it comes back empty).
pub const max_containers: usize = 4096;
const persisted_container_size: usize = 20 + max_container_slots * components.inv_slot_persist_stride + 4 + 2; // + touched_day u32 + size_x/size_y u8 (ZCT3)
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
    /// Grid size the client observed for this container (loot.xml
    /// LootContainer size_x/size_y on the stock client's TE write). 0/0 =
    /// unknown -> the wire writer synthesizes 2xN (or 9x6 above 18 slots).
    /// Persisted in ZCT3 so a restarted container keeps its real grid shape
    /// (ZCT2 still loads with the same size fields).
    size_x: u8 = 0,
    size_y: u8 = 0,
    touched: bool = false,
    /// In-game day the container's loot was generated or last taken from
    /// (LootRespawnDays re-roll base). 0 = unknown (pre-persistence saves).
    touched_day: u32 = 0,
    player_storage: bool = true,
    /// loot.xml container name whose table filled this container (set by the
    /// fill path; the destroy_on_close check reads it). Points into the loot
    /// table's arena; not persisted (a reload re-derives it at fill).
    loot_list: []const u8 = "",

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

/// Inverse of `guidFromPos`: decode a container guid back to its position.
/// Null when the tag bytes are not ours (a foreign/zero guid must not resolve
/// to a bogus position).
pub fn posFromGuid(guid: *const [16]u8) ?PosKey {
    if (guid[12] != 'Z' or guid[13] != 'T' or guid[14] != 'E' or guid[15] != 1) return null;
    return .{
        .x = std.mem.readInt(i32, guid[0..4], .little),
        .y = std.mem.readInt(i32, guid[4..8], .little),
        .z = std.mem.readInt(i32, guid[8..12], .little),
    };
}

pub const ContainerStore = struct {
    items: [max_containers]Container = undefined,
    /// Lookup key mirror of `items[i].pos`, written by getOrCreate. Only valid
    /// where `used[i]`; the AoS `pos` stays authoritative for save/encode.
    keys: [max_containers]PosKey = .{PosKey{ .x = 0, .y = 0, .z = 0 }} ** max_containers,
    used: [max_containers]bool = .{false} ** max_containers,
    n: usize = 0,
    /// Once: warn when getOrCreate drops a container because the table is full.
    cap_warned: bool = false,

    pub fn deinit(self: *ContainerStore) void {
        self.* = .{};
    }

    pub fn get(self: *ContainerStore, pos: PosKey) ?*Container {
        // Scan the 6 KiB key mirror, not the AoS: Container is ~500 B, so
        // probing `items[i].pos` strided a quarter megabyte per lookup.
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_containers and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            if (PosKey.eql(self.keys[i], pos)) return &self.items[i];
        }
        return null;
    }

    pub fn getOrCreate(self: *ContainerStore, pos: PosKey, slot_count: u16, block_id: i32) ?*Container {
        if (self.get(pos)) |c| return c;
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (self.used[i]) continue;
            self.used[i] = true;
            self.keys[i] = pos;
            self.items[i] = .{
                .pos = pos,
                .block_id = block_id,
                .inv_guid = guidFromPos(pos),
                .slot_count = @min(slot_count, @as(u16, max_container_slots)),
            };
            self.n += 1;
            return &self.items[i];
        }
        // Table full: evict a WORLD container (player_storage=false). World
        // containers regenerate deterministically from the prefab TE / block
        // scan when its chunk is next streamed, so eviction is safe; a
        // player-placed chest must never be evicted.
        i = 0;
        while (i < max_containers) : (i += 1) {
            if (!self.used[i] or self.items[i].player_storage) continue;
            const evicted = self.items[i].pos;
            self.used[i] = true;
            self.keys[i] = pos;
            self.items[i] = .{
                .pos = pos,
                .block_id = block_id,
                .inv_guid = guidFromPos(pos),
                .slot_count = @min(slot_count, @as(u16, max_container_slots)),
            };
            if (!self.cap_warned) {
                self.cap_warned = true;
                std.debug.print(
                    "zdtd: container table full ({d}); evicting world container ({d},{d},{d}) for ({d},{d},{d})\n",
                    .{ max_containers, evicted.x, evicted.y, evicted.z, pos.x, pos.y, pos.z },
                );
            }
            return &self.items[i];
        }
        if (!self.cap_warned) {
            self.cap_warned = true;
            std.debug.print(
                "zdtd: container table full and every slot is player storage; dropping new container at ({d},{d},{d}) (max_containers={d})\n",
                .{ pos.x, pos.y, pos.z, max_containers },
            );
        }
        return null;
    }

    pub fn getByGuid(self: *ContainerStore, guid: *const [16]u8) ?*Container {
        // inv_guid is only ever guidFromPos(pos), so decode the position and
        // reuse get()'s key-mirror scan instead of striding the ~500 B AoS.
        return self.get(posFromGuid(guid) orelse return null);
    }

    pub fn remove(self: *ContainerStore, pos: PosKey) void {
        var i: usize = 0;
        while (i < max_containers) : (i += 1) {
            if (self.used[i] and PosKey.eql(self.keys[i], pos)) {
                self.used[i] = false;
                self.items[i] = .{};
                if (self.n > 0) self.n -= 1;
                return;
            }
        }
    }

    /// Persist file: magic "ZCT3" | u16 count | per container:
    /// pos xyz i32*3 | block_id i32 | slot_count u16 | touched u8 | player u8 |
    /// slot_count * InvSlot persist stride (same shape as ZPV17/ZEN2) |
    /// touched_day u32 | size_x u8 | size_y u8. ZCT1 (7-byte slots, no
    /// touched_day/sizes) and ZCT2 (7-byte slots + day + sizes) still load;
    /// ZCT3 keeps mods, stats, flags, and durability across restarts.
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
        @memcpy(buf[0..4], "ZCT3");
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
        const slot_stride = components.inv_slot_persist_stride;
        for (idxs[0..n_idx]) |ii| {
            const c = &self.items[ii];
            // Must cover everything the body below writes: header, slots,
            // touched_day u32 AND the size_x/size_y pair. save_capacity
            // budgets the full record, so this never trips today, but
            // a guard that under-counts what it guards is a latent overrun.
            if (o + 20 + @as(usize, c.slot_count) * slot_stride + 4 + 2 > buf.len) break;
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
                c.slots[s].writePersist(buf[o..][0..slot_stride]);
                o += slot_stride;
            }
            // touched_day u32 appended after the slots; older saves omit it and
            // load as 0 (no immediate respawn).
            std.mem.writeInt(u32, buf[o..][0..4], c.touched_day, .little);
            o += 4;
            // size_x/size_y u8 each: the observed grid shape.
            buf[o] = c.size_x;
            buf[o + 1] = c.size_y;
            o += 2;
            count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], count, .little);
        try io_fs.writeFile(p, buf[0..o]);
    }

    /// Decode a ZCT1/ZCT2/ZCT3 buffer (magic | count | records). Used by load and
    /// fuzz. ZCT3 slots use the shared InvSlot persist stride; ZCT1/ZCT2 keep
    /// the legacy 7-byte head. ZCT2/ZCT3 carry size_x/size_y after touched_day;
    /// ZCT1 records end after the slots and load sizes as 0
    /// (the wire writer synthesizes the grid).
    pub fn loadFromSlice(self: *ContainerStore, buf: []const u8) !void {
        const len = buf.len;
        if (len < 6) return error.ReadFailed;
        const full_slots = std.mem.eql(u8, buf[0..4], "ZCT3");
        const with_size = full_slots or std.mem.eql(u8, buf[0..4], "ZCT2");
        if (!full_slots and !with_size and !std.mem.eql(u8, buf[0..4], "ZCT1")) return error.ReadFailed;
        const slot_stride: usize = if (full_slots) components.inv_slot_persist_stride else 7;
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
            if (o + @as(usize, slot_count) * slot_stride > len) return error.ReadFailed;
            if (with_size and o + @as(usize, slot_count) * slot_stride + 6 > len) return error.ReadFailed;
            // A record can be dropped (table full of player storage), but it
            // still has to be consumed whole: the slots AND the touched_day +
            // size tail below. Skipping only the slots would leave the cursor
            // on the tail and shift every following record.
            const maybe_c = self.getOrCreate(pos, slot_count, block_id);
            if (maybe_c) |c| {
                c.touched = touched;
                c.player_storage = player;
            }
            var s: usize = 0;
            while (s < slot_count) : (s += 1) {
                if (maybe_c) |c| {
                    if (s < max_container_slots) {
                        c.slots[s] = components.InvSlot.readPersist(buf[o..][0..slot_stride]);
                    }
                }
                o += slot_stride;
            }
            // touched_day appended after the slots in ZCT2; a ZCT1 record ends
            // at the last slot and loads touched_day as 0.
            //
            // The magic decides this, not the remaining length. Keying it on
            // `o + 4 <= len` only worked for a single-record ZCT1 file: with
            // two or more, the bytes after the first record are the next
            // record's position, so they were consumed as its touched_day and
            // every later record shifted out of alignment and was lost.
            //
            // The same shape was checked elsewhere and is sound there: the
            // player-save tails in `server/persist.zig` gate on the record's
            // version and only use the length as a guard, and where that guard
            // can fail the remaining bytes are too few for another record to
            // follow. A new format version here must keep the version test.
            // ZCT2's touched_day + size pair are required fields (the writer
            // always emits them), so their extent is validated above, before
            // any store mutation: a truncated tail previously slipped past the
            // length guards here, loaded partial state as a success, and the
            // next save persisted the partial values over the good ones.
            if (with_size) {
                if (maybe_c) |c| c.touched_day = std.mem.readInt(u32, buf[o..][0..4], .little);
                o += 4;
            }
            // ZCT2: size_x/size_y u8 each follow touched_day.
            if (with_size) {
                if (maybe_c) |c| {
                    c.size_x = buf[o];
                    c.size_y = buf[o + 1];
                }
                o += 2;
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
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const c = s.getOrCreate(.{ .x = @intCast(i), .y = 70, .z = @intCast(i * 3) }, 8, 42).?;
        c.setSlot(0, .{ .item_id = 7, .count = 1, .quality = 1, .meta = 0 });
    }
    try s.save(dir, std.testing.allocator);
    const s2_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s2_box);
    s2_box.* = .{};
    const s2 = s2_box;
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
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    const c = s.getOrCreate(.{ .x = 5, .y = 70, .z = 6 }, 8, 42).?;
    c.setSlot(0, .{ .item_id = 7, .count = 12, .quality = 2, .meta = 3 });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try s.save(dir, std.testing.allocator);
    const s2_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s2_box);
    s2_box.* = .{};
    const s2 = s2_box;
    try s2.load(dir);
    const c2 = s2.get(.{ .x = 5, .y = 70, .z = 6 }).?;
    try std.testing.expectEqual(@as(u16, 7), c2.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 12), c2.slots[0].count);
    try std.testing.expectEqual(@as(u8, 2), c2.slots[0].quality);
    try std.testing.expect(c2.touched);
}

test "container store ZCT2 persists the observed grid size" {
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    const c = s.getOrCreate(.{ .x = 5, .y = 70, .z = 6 }, 12, 42).?;
    c.size_x = 6;
    c.size_y = 2; // stock 6x2 wooden chest
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try s.save(dir, std.testing.allocator);
    const s2_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s2_box);
    s2_box.* = .{};
    const s2 = s2_box;
    try s2.load(dir);
    const c2 = s2.get(.{ .x = 5, .y = 70, .z = 6 }).?;
    try std.testing.expectEqual(@as(u8, 6), c2.size_x);
    try std.testing.expectEqual(@as(u8, 2), c2.size_y);
}

test "a legacy ZCT1 file loads without the touched_day and size tail" {
    // ZCT1 records end after the slots; ZCT2 appends touched_day u32 plus
    // size_x/size_y. Nothing loaded a ZCT1 buffer, so reading one as ZCT2 -
    // six bytes past the record taken as its tail - left the suite green while
    // every later record shifted.
    // Two records, so the first one's missing tail is followed by real bytes:
    // with a single record the length guard hides the difference.
    var buf: [6 + 2 * (20 + 2 * 7)]u8 = @splat(0);
    @memcpy(buf[0..4], "ZCT1");
    std.mem.writeInt(u16, buf[4..6], 2, .little); // two records
    std.mem.writeInt(i32, buf[6..10], 5, .little); // x
    std.mem.writeInt(i32, buf[10..14], 70, .little); // y
    std.mem.writeInt(i32, buf[14..18], 6, .little); // z
    std.mem.writeInt(i32, buf[18..22], 42, .little); // block_id
    std.mem.writeInt(u16, buf[22..24], 2, .little); // slot_count
    buf[24] = 1; // touched
    buf[25] = 0; // player_storage
    // Two 7-byte slots: item u16 | count u16 | quality u8 | meta u16.
    std.mem.writeInt(u16, buf[26..28], 7, .little);
    std.mem.writeInt(u16, buf[28..30], 3, .little);
    buf[30] = 4;
    std.mem.writeInt(u16, buf[31..33], 5, .little);

    // Second record at a distinct position; reading a 6-byte tail for the
    // first would consume its header and lose it.
    const r2 = 6 + 20 + 2 * 7;
    std.mem.writeInt(i32, buf[r2 .. r2 + 4][0..4], 9, .little); // x
    std.mem.writeInt(i32, buf[r2 + 4 .. r2 + 8][0..4], 71, .little); // y
    std.mem.writeInt(i32, buf[r2 + 8 .. r2 + 12][0..4], 10, .little); // z
    std.mem.writeInt(i32, buf[r2 + 12 .. r2 + 16][0..4], 43, .little); // block_id
    std.mem.writeInt(u16, buf[r2 + 16 .. r2 + 18][0..2], 2, .little); // slot_count

    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    try s.loadFromSlice(&buf);
    const c = s.get(.{ .x = 5, .y = 70, .z = 6 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 42), c.block_id);
    try std.testing.expectEqual(@as(u16, 2), c.slot_count);
    try std.testing.expect(c.touched);
    try std.testing.expectEqual(@as(u16, 7), c.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 3), c.slots[0].count);
    // The grid is absent in v1 and loads as 0; the wire writer synthesizes it.
    try std.testing.expectEqual(@as(u8, 0), c.size_x);
    try std.testing.expectEqual(@as(u8, 0), c.size_y);

    // The record after it is still found: a misread tail would have eaten its
    // header and shifted everything that follows.
    const c2 = s.get(.{ .x = 9, .y = 71, .z = 10 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 43), c2.block_id);
}

test "container save order is pos-sorted not slot-order" {
    // Reverse-insert so sparse slot indices disagree with world-pos order.
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    _ = s.getOrCreate(.{ .x = 9, .y = 70, .z = 0 }, 8, 1).?;
    _ = s.getOrCreate(.{ .x = 1, .y = 70, .z = 0 }, 8, 2).?;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try s.save(dir, std.testing.allocator);
    var zct_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zct = try std.fmt.bufPrint(&zct_buf, "{s}/containers.zct", .{dir});
    const data = try io_fs.readFileAll(std.testing.allocator, zct);
    defer std.testing.allocator.free(data);
    try std.testing.expect(data.len >= 6 + 40);
    // First record pos.x must be 1 (sorted), not 9 (slot-0 insert).
    const first_x = std.mem.readInt(i32, data[6..10], .little);
    try std.testing.expectEqual(@as(i32, 1), first_x);
}

test "container get or create" {
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    const c = s.getOrCreate(.{ .x = 1, .y = 70, .z = 2 }, 8, 100).?;
    c.setSlot(0, .{ .item_id = 7, .count = 3, .quality = 1 });
    try std.testing.expectEqual(@as(u16, 7), s.get(.{ .x = 1, .y = 70, .z = 2 }).?.slots[0].item_id);
    const g = guidFromPos(.{ .x = 1, .y = 70, .z = 2 });
    try std.testing.expectEqualSlices(u8, &g, &c.inv_guid);
    try std.testing.expect(s.getByGuid(&g) == c);
}

test "container guid decode rejects a foreign tag and round-trips" {
    const pos = PosKey{ .x = -7, .y = 70, .z = 12345 };
    const g = guidFromPos(pos);
    const back = posFromGuid(&g).?;
    try std.testing.expect(PosKey.eql(pos, back));
    var foreign = g;
    foreign[15] = 2; // wrong tag byte; must not decode to a position
    try std.testing.expect(posFromGuid(&foreign) == null);
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    _ = s.getOrCreate(pos, 8, 100).?;
    try std.testing.expect(s.getByGuid(&g) != null);
    try std.testing.expect(s.getByGuid(&foreign) == null);
}

test "container persistence retains every full-capacity container" {
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    var i: usize = 0;
    while (i < max_containers) : (i += 1) {
        const c = s.getOrCreate(.{ .x = @intCast(i), .y = 70, .z = 0 }, max_container_slots, 42).?;
        c.setSlot(max_container_slots - 1, .{ .item_id = 7, .count = @intCast(i + 1) });
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try s.save(dir, std.testing.allocator);
    const s2_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s2_box);
    s2_box.* = .{};
    const s2 = s2_box;
    try s2.load(dir);
    try std.testing.expectEqual(max_containers, s2.n);
    const last = s2.get(.{ .x = max_containers - 1, .y = 70, .z = 0 }).?;
    try std.testing.expectEqual(@as(u16, max_containers), last.slots[max_container_slots - 1].count);
    io_fs.deleteFile("./containers.zct");
}

test "a dropped ZCT2 record does not desync the records after it" {
    // getOrCreate returns null when the table is full of player storage. The
    // loader has to consume that record whole: its slots AND the touched_day +
    // size tail. Skipping only the slots left the cursor on the tail bytes, so
    // every following container parsed garbage.
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    var i: usize = 0;
    while (i < max_containers) : (i += 1) {
        const c = s.getOrCreate(.{ .x = @intCast(i), .y = 0, .z = 0 }, 8, 1).?;
        c.player_storage = true; // nothing is evictable, so the next insert drops
    }
    try std.testing.expect(s.getOrCreate(.{ .x = 77_001, .y = 0, .z = 0 }, 8, 1) == null);

    // Two ZCT2 records: one that will be dropped, then one whose position is
    // already in the table (so it resolves) carrying a distinctive slot.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    const W = struct {
        fn int(al: std.mem.Allocator, b: *std.ArrayList(u8), comptime T: type, v: T) !void {
            var t: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &t, v, .little);
            try b.appendSlice(al, &t);
        }
        /// pos xyz i32 | block i32 | slot_count u16 | touched u8 | player u8 |
        /// slots | touched_day u32 | size_x u8 | size_y u8
        fn rec(al: std.mem.Allocator, b: *std.ArrayList(u8), x: i32, item: u16, day: u32) !void {
            try int(al, b, i32, x);
            try int(al, b, i32, 0);
            try int(al, b, i32, 0);
            try int(al, b, i32, 42);
            try int(al, b, u16, 1); // one slot
            try b.append(al, 1); // touched
            try b.append(al, 1); // player_storage
            try int(al, b, u16, item);
            try int(al, b, u16, 3); // count
            try b.append(al, 1); // quality
            try int(al, b, u16, 0); // meta
            try int(al, b, u32, day);
            try b.append(al, 6); // size_x
            try b.append(al, 2); // size_y
        }
    };
    try buf.appendSlice(a, "ZCT2");
    try W.int(a, &buf, u16, 2);
    try W.rec(a, &buf, 77_002, 111, 9); // no free slot -> dropped
    try W.rec(a, &buf, 0, 222, 5); // existing pos -> must resolve

    try s.loadFromSlice(buf.items);
    // The second record was read at the right offset, not shifted by the
    // dropped record's 6-byte tail.
    const c = s.get(.{ .x = 0, .y = 0, .z = 0 }).?;
    try std.testing.expectEqual(@as(u16, 222), c.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 3), c.slots[0].count);
    try std.testing.expectEqual(@as(u32, 5), c.touched_day);
    try std.testing.expectEqual(@as(u8, 6), c.size_x);
}

test "container store evicts world containers before dropping (cap 4096)" {
    // Navezgane-scale maps have thousands of loot containers; a hard cap
    // truncates the tail (every container past it comes back empty). When the
    // table is full, getOrCreate reuses a WORLD container (player_storage =
    // false, regenerated deterministically on the next chunk scan) and never
    // evicts a player-placed chest.
    // Heap, not stack: ContainerStore is ~10 MB (4096 x 54-slot
    // containers) and overflows the 8 MB test thread stack.
    const s_box = try std.testing.allocator.create(ContainerStore);
    defer std.testing.allocator.destroy(s_box);
    s_box.* = .{};
    const s = s_box;
    var i: usize = 0;
    while (i < max_containers) : (i += 1) {
        const c = s.getOrCreate(.{ .x = @intCast(i), .y = 0, .z = 0 }, 8, 1).?;
        c.player_storage = (i % 2 == 0); // half world, half player-placed
    }
    try std.testing.expectEqual(max_containers, s.n);
    const c = s.getOrCreate(.{ .x = 9999, .y = 0, .z = 0 }, 8, 1).?;
    try std.testing.expectEqual(@as(i32, 9999), c.pos.x);
    // The evicted slot was the first WORLD container (1,0,0, odd i): it is
    // gone, while the player-placed (0,0,0, even i) one survives untouched.
    try std.testing.expect(s.get(.{ .x = 9999, .y = 0, .z = 0 }) != null);
    try std.testing.expect(s.get(.{ .x = 1, .y = 0, .z = 0 }) == null);
    const kept = s.get(.{ .x = 0, .y = 0, .z = 0 }).?;
    try std.testing.expect(kept.player_storage);
}
