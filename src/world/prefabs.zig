//! Stock world prefabs.xml index + footprint stamping on heightmaps.
//! Block paint: stock `.tts` via `tts.zig` (Prefab.readBlockData raw types).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const tts = @import("tts.zig");

pub const Decoration = struct {
    name: []const u8,
    x: i32,
    y: i32,
    z: i32,
    rot: u8 = 0,
    y_is_ground: bool = true,
    size_x: i32 = 8,
    size_y: i32 = 4,
    size_z: i32 = 8,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    /// Owned name strings and decoration list.
    items: []Decoration,
    name_storage: []u8,
    /// Prefab content root (Data/Prefabs) for size lookup; may be empty.
    prefabs_root: []const u8 = "",
    /// Lazy .tts block cache keyed by decoration name (stable name_storage slices).
    tts_cache: std.StringHashMap(tts.TtsBlocks),

    pub fn deinit(self: *Index) void {
        var it = self.tts_cache.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.tts_cache.deinit();
        self.allocator.free(self.items);
        self.allocator.free(self.name_storage);
        if (self.prefabs_root.len != 0) self.allocator.free(self.prefabs_root);
        self.* = undefined;
    }

    /// AABB in world XZ (inclusive min, exclusive max) after rotation 0/2 vs 1/3 swap.
    pub fn boundsXZ(self: *const Index, i: usize) struct { x0: i32, z0: i32, x1: i32, z1: i32 } {
        const d = self.items[i];
        var sx = d.size_x;
        var sz = d.size_z;
        if (d.rot == 1 or d.rot == 3) {
            const t = sx;
            sx = sz;
            sz = t;
        }
        return .{ .x0 = d.x, .z0 = d.z, .x1 = d.x + sx, .z1 = d.z + sz };
    }

    /// Apply footprint flattening into a 16×16 height plane for chunk (cx,cz).
    pub fn applyToChunkHeights(self: *const Index, cx: i32, cz: i32, heights: *[256]u8) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        // Brute force is fine for ~1.5k prefabs per chunk gen (once per chunk).
        for (self.items, 0..) |_, i| {
            const b = self.boundsXZ(i);
            // Reject if AABB misses chunk
            if (b.x1 <= base_x or b.x0 >= base_x + 16 or b.z1 <= base_z or b.z0 >= base_z + 16) continue;
            const d = self.items[i];
            const ground: u8 = @intCast(@min(255, @max(0, d.y)));
            const is_part = std.mem.startsWith(u8, d.name, "part_");
            // Full POIs get a 1-block pad above listed ground; parts only flatten to ground.
            const target: u8 = if (is_part) ground else @intCast(@min(255, @as(u16, ground) + 1));
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    const wx = base_x + lx;
                    const wz = base_z + lz;
                    if (wx < b.x0 or wx >= b.x1 or wz < b.z0 or wz >= b.z1) continue;
                    const idx: usize = @intCast(lx + lz * 16);
                    if (d.y_is_ground) {
                        // Flatten under POI so buildings sit level.
                        heights[idx] = target;
                    } else if (target > heights[idx]) {
                        heights[idx] = target;
                    }
                }
            }
        }
    }

    /// Resolve path to name.tts under prefabs_root (POIs/Parts/RWGTiles).
    pub fn findTtsPath(self: *const Index, name: []const u8, path_buf: []u8) ?[]const u8 {
        if (self.prefabs_root.len == 0) return null;
        const subdirs = [_][]const u8{ "POIs", "Parts", "RWGTiles" };
        for (subdirs) |sub| {
            const need = self.prefabs_root.len + 1 + sub.len + 1 + name.len + 4;
            if (need >= path_buf.len) continue;
            const p = std.fmt.bufPrint(path_buf, "{s}/{s}/{s}.tts", .{ self.prefabs_root, sub, name }) catch continue;
            if (fileExists(p)) return p;
        }
        return null;
    }

    /// Load (or cache) TTS block types for a prefab name.
    pub fn getTtsBlocks(self: *Index, name: []const u8) ?*const tts.TtsBlocks {
        if (self.tts_cache.getPtr(name)) |p| return p;
        var path_buf: [2048]u8 = undefined;
        const path = self.findTtsPath(name, &path_buf) orelse return null;
        // Path exists (findTtsPath); load failure is corrupt TTS / OOM, not "no prefab".
        const loaded = tts.loadBlocks(self.allocator, path) catch |err| {
            std.debug.print("zdtd: tts load failed {s}: {s}\n", .{ path, @errorName(err) });
            return null;
        };
        self.tts_cache.put(name, loaded) catch {
            var tmp = loaded;
            tmp.deinit();
            std.debug.print("zdtd: tts cache put failed for {s}\n", .{name});
            return null;
        };
        return self.tts_cache.getPtr(name);
    }

    /// Paint stock .tts blocks into world for decorations overlapping this chunk.
    /// Policy: paint full POIs always; paint `part_*` only when volume <= 24^3
    /// (skip huge RWG clutter parts). TTS type ids are AssignIds-range on stock
    /// installs; name remap deferred until client/server id tables diverge.
    pub fn applyTtsPaintToChunk(
        self: *Index,
        cx: i32,
        cz: i32,
        set_block: tts.SetBlockFn,
        ctx: ?*anyopaque,
    ) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        for (self.items, 0..) |_, i| {
            const b = self.boundsXZ(i);
            if (b.x1 <= base_x or b.x0 >= base_x + 16 or b.z1 <= base_z or b.z0 >= base_z + 16) continue;
            const d = self.items[i];
            // Skip driveway/road parts: huge and low value for play; full POIs first.
            if (std.mem.startsWith(u8, d.name, "part_")) continue;
            const tb = self.getTtsBlocks(d.name) orelse continue;
            tts.paintDecoration(tb, d.x, d.y, d.z, d.rot, set_block, ctx);
        }
    }

    /// Emit world positions of prefab TEs overlapping chunk (local TE coords rotated).
    pub fn foreachTeInChunk(
        self: *Index,
        cx: i32,
        cz: i32,
        cb: *const fn (ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, te_type: u8) void,
        ctx: ?*anyopaque,
    ) void {
        const base_x = cx * 16;
        const base_z = cz * 16;
        for (self.items, 0..) |_, i| {
            const b = self.boundsXZ(i);
            if (b.x1 <= base_x or b.x0 >= base_x + 16 or b.z1 <= base_z or b.z0 >= base_z + 16) continue;
            const d = self.items[i];
            if (std.mem.startsWith(u8, d.name, "part_")) continue;
            const tb = self.getTtsBlocks(d.name) orelse continue;
            for (tb.tile_entities) |te| {
                const r = tts.rotateLocalXZ(te.lx, te.lz, tb.sx, tb.sz, d.rot);
                const wx = d.x + r.x;
                const wy = d.y + te.ly;
                const wz = d.z + r.z;
                if (wx < base_x or wx >= base_x + 16 or wz < base_z or wz >= base_z + 16) continue;
                cb(ctx, wx, wy, wz, te.te_type);
            }
        }
    }
};

fn fileExists(path: []const u8) bool {
    return io_fs.fileExistsSimple(path);
}

fn parseI32Prefix(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
    var v: i32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
    }
    return if (neg) -v else v;
}

fn attrValue(tag: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "{s}=\"", .{key}) catch return null;
    const i = std.mem.indexOf(u8, tag, needle) orelse return null;
    const start = i + needle.len;
    const end = std.mem.indexOfScalar(u8, tag[start..], '"') orelse return null;
    return tag[start .. start + end];
}

/// Parse prefabs.xml bytes into an Index (names interned into one buffer).
/// When `prefabs_data_dir` is set, resolves POI sizes from `.tts` under that root.
pub fn parseXml(allocator: std.mem.Allocator, xml: []const u8, prefabs_data_dir: ?[]const u8) !Index {
    // First pass: count
    var count: usize = 0;
    var search: usize = 0;
    while (search < xml.len) {
        const rest = xml[search..];
        const di = std.mem.indexOf(u8, rest, "<decoration") orelse break;
        count += 1;
        search += di + 11;
    }
    if (count == 0) {
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(Decoration, 0),
            .name_storage = try allocator.alloc(u8, 0),
            .tts_cache = std.StringHashMap(tts.TtsBlocks).init(allocator),
        };
    }

    // Name storage: over-allocate xml size (names subset).
    var names = try allocator.alloc(u8, xml.len);
    errdefer allocator.free(names);
    var name_off: usize = 0;

    var items = try allocator.alloc(Decoration, count);
    errdefer allocator.free(items);
    var n: usize = 0;
    search = 0;
    while (n < count) {
        const rest = xml[search..];
        const di = std.mem.indexOf(u8, rest, "<decoration") orelse break;
        const tag_start = search + di;
        const tag_rel = std.mem.indexOfScalar(u8, xml[tag_start..], '>') orelse break;
        const tag = xml[tag_start .. tag_start + tag_rel];
        search = tag_start + tag_rel + 1;

        const name_v = attrValue(tag, "name") orelse continue;
        const pos_v = attrValue(tag, "position") orelse continue;
        const x = parseI32Prefix(pos_v) orelse continue;
        const c1 = std.mem.indexOfScalar(u8, pos_v, ',') orelse continue;
        const y = parseI32Prefix(pos_v[c1 + 1 ..]) orelse continue;
        const c2 = std.mem.indexOfScalar(u8, pos_v[c1 + 1 ..], ',') orelse continue;
        const z = parseI32Prefix(pos_v[c1 + 1 + c2 + 1 ..]) orelse continue;

        var rot: u8 = 0;
        if (attrValue(tag, "rotation")) |rv| {
            if (parseI32Prefix(rv)) |r| rot = @intCast(@mod(r, 4));
        }
        const y_gl = if (attrValue(tag, "y_is_groundlevel")) |v|
            !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "False"))
        else
            true;

        if (name_off + name_v.len > names.len) return error.NameOverflow;
        @memcpy(names[name_off..][0..name_v.len], name_v);
        const name_slice = names[name_off .. name_off + name_v.len];
        name_off += name_v.len;

        items[n] = .{
            .name = name_slice,
            .x = x,
            .y = y,
            .z = z,
            .rot = rot,
            .y_is_ground = y_gl,
            .size_x = 8,
            .size_y = 4,
            .size_z = 8,
        };
        n += 1;
    }
    // Shrink items only; keep name_storage capacity so name slices stay valid.
    items = try allocator.realloc(items, n);
    // Do NOT realloc `names`: Decoration.name points into it.

    var idx: Index = .{
        .allocator = allocator,
        .items = items,
        .name_storage = names,
        .tts_cache = std.StringHashMap(tts.TtsBlocks).init(allocator),
    };
    if (prefabs_data_dir) |root| {
        idx.prefabs_root = try allocator.dupe(u8, root);
        try fillSizesFromTts(&idx);
    }
    return idx;
}

/// Parse world prefabs.xml into an Index (names interned into one buffer).
pub fn loadFromWorldDir(allocator: std.mem.Allocator, world_dir: []const u8, prefabs_data_dir: ?[]const u8) !Index {
    var path_buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/prefabs.xml", .{world_dir});
    const xml = try io_fs.readFileAll(allocator, path);
    defer allocator.free(xml);
    return parseXml(allocator, xml, prefabs_data_dir);
}

/// Read size_x/y/z from tts header: magic "tts\0", ver u32 LE, sx/sy/sz u16 LE.
fn readTtsSize(path: []const u8, sx: *i32, sy: *i32, sz: *i32) bool {
    // Header-only read: a .tts can be multi-MB, and startup probes every prefab.
    var hdr: [14]u8 = undefined;
    const data = io_fs.readFileInto(std.heap.page_allocator, path, &hdr) catch return false;
    if (data.len < 14) return false;
    if (!std.mem.eql(u8, data[0..4], "tts\x00")) return false;
    sx.* = std.mem.readInt(u16, data[8..10], .little);
    sy.* = std.mem.readInt(u16, data[10..12], .little);
    sz.* = std.mem.readInt(u16, data[12..14], .little);
    return sx.* > 0 and sz.* > 0;
}

fn fillSizesFromTts(idx: *Index) !void {
    var path_buf: [2048]u8 = undefined;
    // Cache by name (keys are d.name slices into stable name_storage).
    var cache = std.StringHashMap(struct { x: i32, y: i32, z: i32 }).init(idx.allocator);
    defer cache.deinit();

    const subdirs = [_][]const u8{ "POIs", "Parts", "RWGTiles" };
    const root = idx.prefabs_root;
    if (root.len == 0) return;

    for (idx.items) |*d| {
        if (cache.get(d.name)) |sz| {
            d.size_x = sz.x;
            d.size_y = sz.y;
            d.size_z = sz.z;
            continue;
        }
        var found = false;
        var sx: i32 = 8;
        var sy: i32 = 4;
        var sz: i32 = 8;
        for (subdirs) |sub| {
            // Avoid bufPrint overflow on long Steam paths: check lengths first.
            const need = root.len + 1 + sub.len + 1 + d.name.len + 4;
            if (need >= path_buf.len) continue;
            const p = std.fmt.bufPrint(path_buf[0..], "{s}/{s}/{s}.tts", .{ root, sub, d.name }) catch continue;
            if (readTtsSize(p, &sx, &sy, &sz)) {
                found = true;
                break;
            }
        }
        if (!found and std.mem.startsWith(u8, d.name, "part_")) {
            sx = 4;
            sy = 2;
            sz = 4;
        } else if (!found) {
            sx = 16;
            sy = 8;
            sz = 16;
        }
        try cache.put(d.name, .{ .x = sx, .y = sy, .z = sz });
        d.size_x = sx;
        d.size_y = sy;
        d.size_z = sz;
    }
}

test "parse decoration line" {
    const xml =
        \\<prefabs>
        \\  <decoration type="model" name="abandoned_house_01" position="-872,61,612" rotation="0" y_is_groundlevel="true" />
        \\  <decoration type="model" name="part_driveway_industrial_08" position="-549,61,-530" rotation="1" y_is_groundlevel="true" />
        \\</prefabs>
    ;
    // write temp file
    const dir = "worlds/zdtd_prefab_test";
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple(dir);
    try io_fs.writeFileSimple(dir ++ "/prefabs.xml", xml);

    var idx = try loadFromWorldDir(std.testing.allocator, dir, null);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 2), idx.items.len);
    try std.testing.expectEqualStrings("abandoned_house_01", idx.items[0].name);
    try std.testing.expectEqual(@as(i32, -872), idx.items[0].x);
    try std.testing.expectEqual(@as(i32, 61), idx.items[0].y);
    try std.testing.expectEqual(@as(i32, 612), idx.items[0].z);

    var h: [256]u8 = .{50} ** 256;
    // chunk containing -872,612
    const cx = @divFloor(@as(i32, -872), 16);
    const cz = @divFloor(@as(i32, 612), 16);
    idx.applyToChunkHeights(cx, cz, &h);
    // some cell should be raised toward 61/62
    var max_h: u8 = 0;
    for (h) |v| {
        if (v > max_h) max_h = v;
    }
    try std.testing.expect(max_h >= 61);
}

test "tts size read abandoned_house if present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs/POIs/abandoned_house_01.tts";
    if (!fileExists(p)) return error.SkipZigTest;
    var sx: i32 = 0;
    var sy: i32 = 0;
    var sz: i32 = 0;
    try std.testing.expect(readTtsSize(p, &sx, &sy, &sz));
    try std.testing.expectEqual(@as(i32, 42), sx);
    try std.testing.expectEqual(@as(i32, 21), sy);
    try std.testing.expectEqual(@as(i32, 42), sz);
}

test "navezgane paints a real POI into its chunk" {
    // Regression: the client saw only terrain where abandoned_house_07 stands,
    // so a POI that the index lists must actually reach the paint callback.
    const world_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";
    const prefab_root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(world_dir ++ "/prefabs.xml")) return error.SkipZigTest;
    if (!fileExists(prefab_root ++ "/POIs/abandoned_house_07.tts")) return error.SkipZigTest;

    var idx = try loadFromWorldDir(std.testing.allocator, world_dir, prefab_root);
    defer idx.deinit();

    const Count = struct {
        n: usize = 0,
        fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8) void {
            _ = wx;
            _ = wy;
            _ = wz;
            _ = tex;
            _ = dens;
            if (raw == 0) return;
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.n += 1;
        }
    };
    var c: Count = .{};
    // abandoned_house_07 is at (-262,61,450): chunk (-17, 28).
    idx.applyTtsPaintToChunk(-17, 28, Count.put, &c);
    try std.testing.expect(c.n > 0);
}
