//! Prefab sleeper volumes: parse XML + wake/spawn on player enter.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml = @import("../assets/xml_util.zig");
const tts_rot = @import("tts.zig");
const blocks_nim = @import("../assets/blocks_nim.zig");
const prefabs = @import("prefabs.zig");

pub const max_volumes: usize = 8192;
pub const max_group_classes: usize = 4;

pub const VolumeGroup = struct {
    class_name: []const u8 = "",
    min_count: u8 = 0,
    max_count: u8 = 1,
};

/// Authored sleeper spawn point (world space, after prefab rotation).
/// Position of a `Class=Sleeper` marker block cell in the prefab voxel data.
pub const SpawnPos = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Volume = struct {
    /// World-space AABB (inclusive min, exclusive max) after prefab rotation.
    x0: i32 = 0,
    y0: i32 = 0,
    z0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,
    z1: i32 = 0,
    groups: [max_group_classes]VolumeGroup = [_]VolumeGroup{.{}} ** max_group_classes,
    group_n: u8 = 0,
    /// Once players trigger, stay triggered (no re-spawn spam).
    triggered: bool = false,
    /// Prefab decoration name (debug).
    prefab: []const u8 = "",
    /// Authored spawn points from `Class=Sleeper` marker blocks inside this AABB.
    /// Empty when no `.tts`/`.blocks.nim` is available; callers fall back to a
    /// scatter across the AABB in that case.
    spawns: []const SpawnPos = &.{},
};

pub const Store = struct {
    volumes: []Volume = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    /// Count triggered this session.
    trigger_count: u32 = 0,

    pub fn deinit(self: *Store) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn empty() Store {
        return .{};
    }

    pub fn containsXZ(self: *const Store, vi: usize, x: f32, z: f32) bool {
        if (vi >= self.volumes.len) return false;
        const v = &self.volumes[vi];
        const xi: i32 = @floor(x);
        const zi: i32 = @floor(z);
        return xi >= v.x0 and xi < v.x1 and zi >= v.z0 and zi < v.z1;
    }

    pub fn contains(self: *const Store, vi: usize, x: f32, y: f32, z: f32) bool {
        if (vi >= self.volumes.len) return false;
        const v = &self.volumes[vi];
        const xi: i32 = @floor(x);
        const yi: i32 = @floor(y);
        const zi: i32 = @floor(z);
        return xi >= v.x0 and xi < v.x1 and yi >= v.y0 and yi < v.y1 and zi >= v.z0 and zi < v.z1;
    }
};

fn fileExists(path: []const u8) bool {
    return io_fs.fileExistsSimple(path);
}

fn prop(body: []const u8, name: []const u8) ?[]const u8 {
    return xml.propertyValue(body, name);
}

/// Split `a, b, c#d, e, f` on `#` into segments.
fn nextSegment(s: []const u8, start: *usize) ?[]const u8 {
    if (start.* >= s.len) return null;
    const rest = s[start.*..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| {
        const seg = std.mem.trim(u8, rest[0..h], " \t");
        start.* += h + 1;
        return seg;
    }
    const seg = std.mem.trim(u8, rest, " \t");
    start.* = s.len;
    if (seg.len == 0) return null;
    return seg;
}

const Vec3i = struct { x: i32, y: i32, z: i32 };

fn parseI32Csv3(s: []const u8) ?Vec3i {
    const t = std.mem.trim(u8, s, " \t");
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, t, ',');
    while (it.next()) |p| {
        if (n >= 3) break;
        parts[n] = std.mem.trim(u8, p, " \t");
        n += 1;
    }
    if (n < 3) return null;
    const x = std.fmt.parseInt(i32, parts[0], 10) catch return null;
    const y = std.fmt.parseInt(i32, parts[1], 10) catch return null;
    const z = std.fmt.parseInt(i32, parts[2], 10) catch return null;
    return .{ .x = x, .y = y, .z = z };
}

/// Count of '#'-separated segments (matches StringParsers::ParseList entry count).
fn segCount(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (nextSegment(s, &i)) |_| n += 1;
    return n;
}

/// Parse one spawnCountMin/Max token. Stock default before the triple branch is
/// 5,5 (asm.il ReadFromProperties IL_0210/0214); a failed/negative parse keeps
/// that default. (Runtime <0 reset to 5/6 not modeled: malformed-data only.)
fn parseCount(s: []const u8) u8 {
    const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t"), 10) catch return 5;
    if (v < 0) return 5;
    return @intCast(@min(v, 255));
}

/// Find `<prefabs_root>/<sub>/<name><ext>` across POIs/Parts/RWGTiles.
fn findPrefabFile(prefabs_root: []const u8, name: []const u8, ext: []const u8, buf: []u8) ?[]const u8 {
    const subdirs = [_][]const u8{ "POIs", "Parts", "RWGTiles" };
    for (subdirs) |sub| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}/{s}{s}", .{ prefabs_root, sub, name, ext }) catch continue;
        if (fileExists(p)) return p;
    }
    return null;
}

/// Rotate local volume corner for prefab rot 0..3 (same as TTS stamp).
fn rotLocal(x: i32, z: i32, sx: i32, sz: i32, rot: u8) struct { x: i32, z: i32 } {
    const r = tts_rot.rotateLocalXZ(x, z, sx, sz, rot);
    return .{ .x = r.x, .z = r.z };
}

pub const PrefabRef = struct {
    name: []const u8,
    x: i32,
    y: i32,
    z: i32,
    rot: u8,
    size_x: i32,
    size_y: i32,
    size_z: i32,
};

/// Load sleeper volumes for decorations under prefabs_root (POIs/Parts/RWGTiles).
pub fn loadFromPrefabs(
    allocator: std.mem.Allocator,
    prefabs_root: []const u8,
    decorations: []const PrefabRef,
) !Store {
    if (prefabs_root.len == 0 or decorations.len == 0) return Store.empty();

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(Volume) = .empty;
    defer list.deinit(allocator);

    // Cache xml body by prefab name.
    var xml_cache: std.StringHashMapUnmanaged([]const u8) = .{};
    defer xml_cache.deinit(allocator);

    // Cache prefab voxel data (`.tts`) and local-id name map (`.blocks.nim`) by
    // prefab name for authored spawn-point extraction. Null = tried and absent.
    var tts_cache: std.StringHashMapUnmanaged(?*tts_rot.TtsBlocks) = .{};
    var nim_cache: std.StringHashMapUnmanaged(?*blocks_nim.Map) = .{};
    defer {
        var tit = tts_cache.valueIterator();
        while (tit.next()) |v| if (v.*) |p| {
            p.deinit();
            allocator.destroy(p);
        };
        tts_cache.deinit(allocator);
        var nit = nim_cache.valueIterator();
        while (nit.next()) |v| if (v.*) |p| {
            p.deinit();
            allocator.destroy(p);
        };
        nim_cache.deinit(allocator);
    }

    const subdirs = [_][]const u8{ "POIs", "Parts", "RWGTiles" };
    var path_buf: [2048]u8 = undefined;

    for (decorations) |d| {
        // Skip tiny parts: volumes mostly on full POIs.
        if (prefabs.isPart(d.name)) continue;

        const body = blk: {
            if (xml_cache.get(d.name)) |b| break :blk b;
            var found: ?[]const u8 = null;
            for (subdirs) |sub| {
                const need = prefabs_root.len + 1 + sub.len + 1 + d.name.len + 4;
                if (need >= path_buf.len) continue;
                const p = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.xml", .{ prefabs_root, sub, d.name }) catch continue;
                if (!fileExists(p)) continue;
                const raw = io_fs.readFileAll(allocator, p) catch continue;
                defer allocator.free(raw);
                // Stock prefab XML often has UTF-8 BOM.
                const raw_nb = if (raw.len >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF)
                    raw[3..]
                else
                    raw;
                const clean = xml.stripComments(allocator, raw_nb) catch continue;
                defer allocator.free(clean);
                found = try arena.dupe(u8, clean);
                break;
            }
            const b = found orelse continue;
            // key must outlive; d.name from caller may be stable (prefab index names)
            const key = try arena.dupe(u8, d.name);
            try xml_cache.put(allocator, key, b);
            break :blk b;
        };

        const size_s = prop(body, "SleeperVolumeSize") orelse continue;
        const start_s = prop(body, "SleeperVolumeStart") orelse continue;
        const group_s = prop(body, "SleeperVolumeGroup") orelse continue;

        // Prefab size for rotation (from decoration or PrefabSize prop).
        var psx = d.size_x;
        var psy = d.size_y;
        var psz = d.size_z;
        if (prop(body, "PrefabSize")) |ps| {
            if (parseI32Csv3(ps)) |sz| {
                psx = sz.x;
                psy = sz.y;
                psz = sz.z;
            }
        }

        // SleeperVolumeGroup: comma-split flat token list (asm.il ReadFromProperties
        // IL_022d..02a0). vol_count == start-segment count decides the form:
        //   tokens == vol_count      → name-only, spawnCountMin/Max default 5,5
        //   tokens == vol_count*3    → triple (name, min, max) per volume
        //   otherwise                → groupName "???", 5,5
        const vol_count = segCount(start_s);
        var g_toks: std.ArrayList([]const u8) = .empty;
        defer g_toks.deinit(allocator);
        {
            var it = std.mem.splitScalar(u8, group_s, ',');
            while (it.next()) |t| try g_toks.append(allocator, std.mem.trim(u8, t, " \t"));
        }
        const name_only = g_toks.items.len == vol_count;
        const triple = g_toks.items.len == vol_count * 3;

        // Authored spawn points come from Class=Sleeper marker blocks in the
        // voxel data, not XML (asm.il Prefab block-scan ~919380: Block.IsSleeperBlock
        // → SleeperVolume::AddSpawnPoint). Collect their LOCAL cells once per prefab.
        const tblocks: ?*tts_rot.TtsBlocks = blk: {
            if (tts_cache.get(d.name)) |v| break :blk v;
            var loaded: ?*tts_rot.TtsBlocks = null;
            if (findPrefabFile(prefabs_root, d.name, ".tts", &path_buf)) |p| {
                if (tts_rot.loadBlocks(allocator, p)) |t| {
                    const ptr = allocator.create(tts_rot.TtsBlocks) catch break :blk null;
                    ptr.* = t;
                    loaded = ptr;
                } else |_| {}
            }
            try tts_cache.put(allocator, try arena.dupe(u8, d.name), loaded);
            break :blk loaded;
        };
        const nmap: ?*blocks_nim.Map = blk: {
            if (nim_cache.get(d.name)) |v| break :blk v;
            var loaded: ?*blocks_nim.Map = null;
            if (findPrefabFile(prefabs_root, d.name, ".blocks.nim", &path_buf)) |p| {
                if (blocks_nim.loadFromPath(allocator, p)) |m| {
                    const ptr = allocator.create(blocks_nim.Map) catch break :blk null;
                    ptr.* = m;
                    loaded = ptr;
                } else |_| {}
            }
            try nim_cache.put(allocator, try arena.dupe(u8, d.name), loaded);
            break :blk loaded;
        };
        var sleeper_local: std.ArrayList(SpawnPos) = .empty;
        defer sleeper_local.deinit(allocator);
        if (tblocks) |tb| if (nmap) |nm| {
            const cnt: i32 = @intCast(tb.blockCount());
            var bi: i32 = 0;
            while (bi < cnt) : (bi += 1) {
                const tid: u16 = @truncate(tb.types[@intCast(bi)] & 0xffff);
                const name = nm.nameOf(tid) orelse continue;
                if (!std.mem.startsWith(u8, name, "sleeper")) continue;
                const c = tb.offsetToCoord(bi);
                try sleeper_local.append(allocator, .{ .x = c.x, .y = c.y, .z = c.z });
            }
        };

        var si: usize = 0;
        var ti: usize = 0;
        var vol_i: usize = 0;
        while (list.items.len < max_volumes) {
            const start_seg = nextSegment(start_s, &si) orelse break;
            // Missing Size for a Start index → Vector3i.one (stock ParseList fallback).
            const size_seg = nextSegment(size_s, &ti);
            const cur_vol = vol_i;
            vol_i += 1;

            const st = parseI32Csv3(start_seg) orelse continue;
            const sz: Vec3i = if (size_seg) |ss| (parseI32Csv3(ss) orelse Vec3i{ .x = 1, .y = 1, .z = 1 }) else Vec3i{ .x = 1, .y = 1, .z = 1 };
            if (sz.x <= 0 or sz.y <= 0 or sz.z <= 0) continue;

            // Local corners → rotate XZ → world.
            // Stock volumes: start is min corner in prefab local space.
            const c0 = rotLocal(st.x, st.z, psx, psz, d.rot);
            const c1 = rotLocal(st.x + sz.x - 1, st.z + sz.z - 1, psx, psz, d.rot);
            const lx0 = @min(c0.x, c1.x);
            const lz0 = @min(c0.z, c1.z);
            const lx1 = @max(c0.x, c1.x) + 1;
            const lz1 = @max(c0.z, c1.z) + 1;

            var vol: Volume = .{
                .x0 = d.x + lx0,
                .y0 = d.y + st.y,
                .z0 = d.z + lz0,
                .x1 = d.x + lx1,
                .y1 = d.y + st.y + sz.y,
                .z1 = d.z + lz1,
                .prefab = d.name,
            };
            // Resolve this volume's group by form (one group per volume).
            vol.groups[0] = if (name_only and cur_vol < g_toks.items.len) VolumeGroup{
                .class_name = g_toks.items[cur_vol],
                .min_count = 5,
                .max_count = 5,
            } else if (triple and cur_vol * 3 + 2 < g_toks.items.len) blk: {
                const mn = parseCount(g_toks.items[cur_vol * 3 + 1]);
                const mx = parseCount(g_toks.items[cur_vol * 3 + 2]);
                break :blk VolumeGroup{
                    .class_name = g_toks.items[cur_vol * 3],
                    .min_count = mn,
                    .max_count = @max(mn, mx),
                };
            } else VolumeGroup{ .class_name = "???", .min_count = 5, .max_count = 5 };
            vol.group_n = 1;

            // Filter authored spawn cells to this volume's local box, rotate to world.
            var vspawns: std.ArrayList(SpawnPos) = .empty;
            defer vspawns.deinit(allocator);
            for (sleeper_local.items) |lp| {
                if (lp.x < st.x or lp.x >= st.x + sz.x) continue;
                if (lp.y < st.y or lp.y >= st.y + sz.y) continue;
                if (lp.z < st.z or lp.z >= st.z + sz.z) continue;
                const r = rotLocal(lp.x, lp.z, psx, psz, d.rot);
                try vspawns.append(allocator, .{ .x = d.x + r.x, .y = d.y + lp.y, .z = d.z + r.z });
            }
            if (vspawns.items.len > 0) vol.spawns = try arena.dupe(SpawnPos, vspawns.items);

            try list.append(allocator, vol);
        }
    }

    const vols = try arena.alloc(Volume, list.items.len);
    @memcpy(vols, list.items);
    return .{
        .volumes = vols,
        .arena_ptr = arena_holder,
    };
}

test "parse abandoned_house sleeper volumes if present" {
    const root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(root ++ "/POIs/abandoned_house_01.xml")) return error.SkipZigTest;
    const decos = [_]PrefabRef{.{
        .name = "abandoned_house_01",
        .x = 100,
        .y = 60,
        .z = 200,
        .rot = 0,
        .size_x = 42,
        .size_y = 21,
        .size_z = 42,
    }};
    var store = try loadFromPrefabs(std.testing.allocator, root, &decos);
    defer store.deinit();
    try std.testing.expect(store.volumes.len >= 3);
    // first volume start 15,0,14 size 5,13,13 → world 115..120, 60..73, 214..227
    const v0 = store.volumes[0];
    try std.testing.expectEqual(@as(i32, 115), v0.x0);
    try std.testing.expectEqual(@as(i32, 214), v0.z0);
    try std.testing.expect(v0.group_n >= 1);
    try std.testing.expectEqualStrings("zombieLumberjack", v0.groups[0].class_name);
    // Triple form (name,0,1) → min 0, max 1 (not the name-only 5,5 default).
    try std.testing.expectEqual(@as(u8, 0), v0.groups[0].min_count);
    try std.testing.expectEqual(@as(u8, 1), v0.groups[0].max_count);
}

test "abandoned_house authored sleeper spawn points inside volumes if present" {
    const root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(root ++ "/POIs/abandoned_house_01.tts")) return error.SkipZigTest;
    if (!fileExists(root ++ "/POIs/abandoned_house_01.blocks.nim")) return error.SkipZigTest;
    const decos = [_]PrefabRef{.{
        .name = "abandoned_house_01",
        .x = 100,
        .y = 60,
        .z = 200,
        .rot = 0,
        .size_x = 42,
        .size_y = 21,
        .size_z = 42,
    }};
    var store = try loadFromPrefabs(std.testing.allocator, root, &decos);
    defer store.deinit();
    // At least one volume carries authored spawn points from Class=Sleeper blocks.
    var total: usize = 0;
    for (store.volumes, 0..) |v, vi| {
        total += v.spawns.len;
        for (v.spawns) |sp| {
            // Every spawn point sits inside its own volume AABB.
            try std.testing.expect(store.contains(vi, @floatFromInt(sp.x), @floatFromInt(sp.y), @floatFromInt(sp.z)));
        }
    }
    try std.testing.expect(total >= 1);
}

test "sleeper volume group forms: name-only vs triple" {
    // Name-only form: tokens == vol_count → spawnCountMin/Max default 5,5.
    // Triple form: tokens == vol_count*3 → parsed (name,min,max).
    // Grounded in asm.il PrefabSleeperVolumeList::ReadFromProperties IL_022d..02a0.
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(std.testing.allocator);
    try toks.append(std.testing.allocator, "zombieA");
    try toks.append(std.testing.allocator, "zombieB");
    // vol_count 2, tokens 2 → name-only.
    try std.testing.expect(toks.items.len == 2);
    try std.testing.expectEqual(@as(u8, 5), parseCount("bad"));
    try std.testing.expectEqual(@as(u8, 5), parseCount("-3"));
    try std.testing.expectEqual(@as(u8, 0), parseCount("0"));
    try std.testing.expectEqual(@as(u8, 7), parseCount("7"));
    try std.testing.expectEqual(@as(u8, 255), parseCount("9000"));
    try std.testing.expectEqual(@as(usize, 3), segCount("15, 0, 14#11, 0, 22#10, 0, 16"));
    try std.testing.expectEqual(@as(usize, 1), segCount("15, 0, 14"));
}
