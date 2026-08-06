//! Stock world prefabs.xml index + footprint stamping on heightmaps.
//! Block paint: stock `.tts` via `tts.zig` (Prefab.readBlockData raw types),
//! with the prefab-local type ids remapped to runtime block ids by name through
//! each POI's `<name>.blocks.nim` (Prefab::loadIdMapping).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const blocks_nim = @import("../assets/blocks_nim.zig");
const xml_util = @import("../assets/xml_util.zig");
const tts = @import("tts.zig");

/// Quest-facing data from the prefab's `<name>.xml` (stock PrefabManager keeps
/// the same per-POI index): the QuestTags activity list and the DifficultyTier
/// used to filter quest POI assignment.
pub const QuestData = struct {
    /// Stock QuestTags value ("clear, fetch, infested"), "" when absent.
    tags: []const u8 = "",
    /// Stock DifficultyTier (1..6), 0 when absent.
    tier: u8 = 0,
    /// Local cell of the prefab's trader NPC (`IndexedBlockOffsets` class
    /// "Trader"), -1/0/-1 when the POI has no trader.
    trader_x: i32 = -1,
    trader_y: i32 = 0,
    trader_z: i32 = -1,
    /// ThemeTags trader identity ("traderBob" → npcTraderBob), "" when none.
    trader_tag: []const u8 = "",
    /// Trader compound: true when the POI XML says TraderArea=True. The area's
    /// wire shape (NetPackageWorldAreas / TraderArea.Write) needs the protect
    /// padding and the teleport volumes below.
    is_trader_area: bool = false,
    /// `TraderAreaProtect` padding ("0,0,0"); the wire writes
    /// (padding - 2) in x/z (TraderArea::GetProtectPadding).
    protect_padding: [3]i8 = .{ 0, 0, 0 },
    /// `TeleportVolumeStart` / `TeleportVolumeSize` #-lists, local prefab
    /// cells (start s8, size u8 on the wire). Up to max_teleport_volumes.
    teleport_start: [max_teleport_volumes][3]i8 = .{.{ 0, 0, 0 }} ** max_teleport_volumes,
    teleport_size: [max_teleport_volumes][3]u8 = .{.{ 0, 0, 0 }} ** max_teleport_volumes,
    teleport_n: u8 = 0,
};

pub const max_teleport_volumes: usize = 8;

/// City parts (driveways, roads, sewer caps, ...) are the stock `part_*`
/// naming: never quest POIs, skipped for painting and sleeper-volume budget,
/// and given a flat pad and fallback size.
pub fn isPart(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "part_");
}

/// Local cell of the trader NPC from `IndexedBlockOffsets class="Trader"`:
/// the first nested `name="N" value="x, y, z"`. Null when the POI has none.
fn traderCellOf(content: []const u8) ?[3]i32 {
    const ci = std.mem.indexOf(u8, content, "class=\"Trader\"") orelse return null;
    const vi = std.mem.indexOfPos(u8, content, ci, "value=\"") orelse return null;
    const start = vi + 7;
    const end = std.mem.indexOfScalarPos(u8, content, start, '"') orelse return null;
    var cell: [3]i32 = .{ 0, 0, 0 };
    var it = std.mem.tokenizeScalar(u8, content[start..end], ',');
    var n: usize = 0;
    while (it.next()) |tok| : (n += 1) {
        if (n >= 3) break;
        cell[n] = std.fmt.parseInt(i32, std.mem.trim(u8, tok, " "), 10) catch return null;
    }
    if (n != 3) return null;
    return cell;
}

/// Parse "x, y, z" into a triple; null on malformed input.
fn parseVec3i(v: []const u8) ?[3]i32 {
    var out: [3]i32 = .{ 0, 0, 0 };
    var it = std.mem.tokenizeScalar(u8, v, ',');
    var n: usize = 0;
    while (it.next()) |tok| : (n += 1) {
        if (n >= 3) break;
        out[n] = std.fmt.parseInt(i32, std.mem.trim(u8, tok, " "), 10) catch return null;
    }
    if (n != 3) return null;
    return out;
}

/// Parse the `TeleportVolumeStart` / `TeleportVolumeSize` #-lists into the
/// bounded arrays (stock trader POIs carry up to 6 volumes).
fn parseVolumeLists(
    starts: []const u8,
    sizes: []const u8,
    out_start: *[max_teleport_volumes][3]i8,
    out_size: *[max_teleport_volumes][3]u8,
    out_n: *u8,
) void {
    var s_it = std.mem.tokenizeScalar(u8, starts, '#');
    var z_it = std.mem.tokenizeScalar(u8, sizes, '#');
    var n: usize = 0;
    while (s_it.next()) |s| : (n += 1) {
        if (n >= max_teleport_volumes) break;
        const z = z_it.next() orelse break;
        const sp = parseVec3i(s) orelse continue;
        const zp = parseVec3i(z) orelse continue;
        out_start[n] = .{ @intCast(sp[0]), @intCast(sp[1]), @intCast(sp[2]) };
        out_size[n] = .{ @intCast(zp[0]), @intCast(zp[1]), @intCast(zp[2]) };
    }
    out_n.* = @intCast(n);
}

/// Runtime block id for a stock block name (AssignIds space), null when the
/// install has no such block. Supplied by the server from its AssignIds table.
pub const IdLookup = struct {
    ctx: ?*anyopaque = null,
    lookup: *const fn (ctx: ?*anyopaque, name: []const u8) ?u16,
};

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
    /// `YOffset` from the prefab .xml. Only meaningful once the prefab files
    /// have been probed (parseXml with a prefabs data dir), 0 otherwise.
    y_offset: i32 = 0,

    /// World Y the prefab's local y=0 plane lands on. Stock adds `Prefab.yOffset`
    /// to the decoration position, but only when `y_is_groundlevel` is set
    /// (DynamicPrefabDecorator.Load, asm.il:902414-902420); a decoration that
    /// pins an absolute Y keeps it. 679 of Navezgane's 1487 full POIs carry a
    /// nonzero offset, and caves/mines/bunkers are 25 to 55 blocks below ground.
    pub fn stampY(self: Decoration) i32 {
        return if (self.y_is_ground) self.y + self.y_offset else self.y;
    }
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
    /// Lazy QuestTags/DifficultyTier cache keyed by decoration name (tags owned
    /// by self.allocator; absent prefabs are cached with empty tags).
    quest_cache: std.StringHashMap(QuestData),
    /// Runtime AssignIds resolver for the `.blocks.nim` remap; without it the
    /// prefab-local ids are stamped raw (offline / no id table).
    id_lookup: ?IdLookup = null,

    pub fn deinit(self: *Index) void {
        var it = self.tts_cache.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.tts_cache.deinit();
        var qit = self.quest_cache.iterator();
        while (qit.next()) |e| {
            if (e.value_ptr.tags.len != 0) self.allocator.free(e.value_ptr.tags);
            if (e.value_ptr.trader_tag.len != 0) self.allocator.free(e.value_ptr.trader_tag);
        }
        self.quest_cache.deinit();
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
            // Declared position, NOT stampY(): this is the terrain pad the POI
            // sits on, which stays at ground level even when the prefab body is
            // stamped 30+ blocks below it (caves, mines, bunkers).
            const ground: u8 = @intCast(@min(255, @max(0, d.y)));
            const is_part = isPart(d.name);
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

    /// Resolve path to `name<ext>` under prefabs_root (POIs/Parts/RWGTiles).
    pub fn findPrefabPath(self: *const Index, name: []const u8, ext: []const u8, path_buf: []u8) ?[]const u8 {
        if (self.prefabs_root.len == 0) return null;
        const subdirs = [_][]const u8{ "POIs", "Parts", "RWGTiles" };
        for (subdirs) |sub| {
            const need = self.prefabs_root.len + 1 + sub.len + 1 + name.len + ext.len;
            if (need >= path_buf.len) continue;
            const p = std.fmt.bufPrint(path_buf, "{s}/{s}/{s}{s}", .{ self.prefabs_root, sub, name, ext }) catch continue;
            if (fileExists(p)) return p;
        }
        return null;
    }

    /// Resolve path to name.tts under prefabs_root (POIs/Parts/RWGTiles).
    pub fn findTtsPath(self: *const Index, name: []const u8, path_buf: []u8) ?[]const u8 {
        return self.findPrefabPath(name, ".tts", path_buf);
    }

    /// Install the runtime AssignIds resolver used by the `.blocks.nim` remap.
    /// Drops cached prefabs so anything loaded before this point is re-read and
    /// remapped rather than left in prefab-local ids.
    pub fn setIdLookup(self: *Index, l: IdLookup) void {
        self.id_lookup = l;
        var it = self.tts_cache.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.tts_cache.clearRetainingCapacity();
    }

    /// Translate prefab-local `.tts` type ids into runtime block ids by NAME,
    /// through the prefab's own `<name>.blocks.nim` (`Prefab::loadIdMapping`,
    /// asm.il:928850, applied per cell in `readBlockData`, asm.il:920216).
    /// The two id spaces have drifted: over Navezgane's 750 distinct prefabs
    /// 1126764 of 11097182 authored cells (10.2%) carry a local id whose
    /// runtime block is a different block, so stamping the raw id builds the
    /// wrong POI.
    fn remapToRuntimeIds(self: *Index, name: []const u8, tb: *tts.TtsBlocks) void {
        const resolver = self.id_lookup orelse return;
        var path_buf: [2048]u8 = undefined;
        // Stock refuses to load a prefab whose name map is missing; keeping the
        // raw ids at least yields a building on a nonstandard install. Loaded
        // prefabs are cached, so each of these prints at most once per prefab.
        const nim_path = self.findPrefabPath(name, ".blocks.nim", &path_buf) orelse {
            std.debug.print("zdtd: prefab {s}: no .blocks.nim, block ids stay prefab-local\n", .{name});
            return;
        };
        var map = blocks_nim.loadFromPath(self.allocator, nim_path) catch |err| {
            std.debug.print("zdtd: blocks.nim load failed {s}: {s}\n", .{ nim_path, @errorName(err) });
            return;
        };
        defer map.deinit();

        // Stock's translation table: one entry per local id, -1 where the name
        // is unknown to this install (asm.il:1177941 createIdTranslationTable).
        const table = self.allocator.alloc(i32, map.names.len) catch {
            std.debug.print("zdtd: prefab {s}: id table alloc failed, ids stay prefab-local\n", .{name});
            return;
        };
        defer self.allocator.free(table);
        for (map.names, 0..) |bname, local| {
            table[local] = if (bname.len == 0)
                -1
            else if (resolver.lookup(resolver.ctx, bname)) |rid| @intCast(rid) else -1;
        }

        var unknown: u32 = 0;
        for (tb.types) |*raw| {
            const typ: u16 = @truncate(raw.* & tts.type_mask);
            if (typ == 0) continue;
            const mapped: i32 = if (typ < table.len) table[typ] else -1;
            if (mapped < 0) {
                // Stock substitutes "missingBlock" or fails the whole prefab;
                // leaving the cell air is the honest middle: no wrong block.
                raw.* = 0;
                unknown += 1;
                continue;
            }
            // BlockValue::set_type: low 16 bits only, rotation/meta survive.
            raw.* = (raw.* & ~tts.type_mask) | @as(u32, @intCast(mapped));
        }
        if (unknown != 0) {
            std.debug.print("zdtd: prefab {s}: {d} cells have no block in this install\n", .{ name, unknown });
        }
    }

    /// Load (or cache) TTS block types for a prefab name, in runtime block ids.
    pub fn getTtsBlocks(self: *Index, name: []const u8) ?*const tts.TtsBlocks {
        if (self.tts_cache.getPtr(name)) |p| return p;
        var path_buf: [2048]u8 = undefined;
        const path = self.findTtsPath(name, &path_buf) orelse return null;
        // Path exists (findTtsPath); load failure is corrupt TTS / OOM, not "no prefab".
        var loaded = tts.loadBlocks(self.allocator, path) catch |err| {
            std.debug.print("zdtd: tts load failed {s}: {s}\n", .{ path, @errorName(err) });
            return null;
        };
        self.remapToRuntimeIds(name, &loaded);
        self.tts_cache.put(name, loaded) catch {
            var tmp = loaded;
            tmp.deinit();
            std.debug.print("zdtd: tts cache put failed for {s}\n", .{name});
            return null;
        };
        return self.tts_cache.getPtr(name);
    }

    /// QuestTags + DifficultyTier from the prefab's `<name>.xml`, cached (lazy
    /// like the tts cache; a missing XML or missing attrs caches empty data).
    pub fn questData(self: *Index, name: []const u8) ?QuestData {
        if (self.quest_cache.get(name)) |qd| return qd;
        var qd: QuestData = .{};
        var path_buf: [2048]u8 = undefined;
        if (self.findPrefabPath(name, ".xml", &path_buf)) |path| {
            const raw = io_fs.readFileAll(self.allocator, path) catch null;
            if (raw) |content| {
                defer self.allocator.free(content);
                if (xml_util.propertyValue(content, "QuestTags")) |v| {
                    qd.tags = self.allocator.dupe(u8, v) catch "";
                }
                if (xml_util.propertyValue(content, "DifficultyTier")) |v| {
                    qd.tier = std.fmt.parseInt(u8, v, 10) catch 0;
                }
                // Trader POIs: the NPC's local cell lives in the
                // IndexedBlockOffsets class "Trader" entry, the class identity
                // in ThemeTags ("traderBob" → npcTraderBob).
                if (traderCellOf(content)) |cell| {
                    qd.trader_x = cell[0];
                    qd.trader_y = cell[1];
                    qd.trader_z = cell[2];
                }
                if (xml_util.propertyValue(content, "ThemeTags")) |v| {
                    if (std.mem.startsWith(u8, v, "trader") and v.len > 6) {
                        qd.trader_tag = self.allocator.dupe(u8, v) catch "";
                    }
                }
                // Trader compound area (NetPackageWorldAreas): the protect
                // padding and the teleport volumes the client needs to build
                // the safe zone and the closing-time teleport.
                if (xml_util.propertyValue(content, "TraderArea")) |v| {
                    qd.is_trader_area = std.mem.eql(u8, v, "True");
                }
                if (xml_util.propertyValue(content, "TraderAreaProtect")) |v| {
                    if (parseVec3i(v)) |p| {
                        qd.protect_padding = .{ @intCast(p[0]), @intCast(p[1]), @intCast(p[2]) };
                    }
                }
                parseVolumeLists(
                    xml_util.propertyValue(content, "TeleportVolumeStart") orelse "",
                    xml_util.propertyValue(content, "TeleportVolumeSize") orelse "",
                    &qd.teleport_start,
                    &qd.teleport_size,
                    &qd.teleport_n,
                );
            }
        }
        self.quest_cache.put(name, qd) catch {
            if (qd.tags.len != 0) self.allocator.free(qd.tags);
            if (qd.trader_tag.len != 0) self.allocator.free(qd.trader_tag);
            return null;
        };
        return self.quest_cache.get(name);
    }

    /// Paint stock .tts blocks into world for decorations overlapping this chunk.
    /// Policy: paint full POIs always; paint `part_*` only when volume <= 24^3
    /// (skip huge RWG clutter parts). Ids come out of `getTtsBlocks` already
    /// remapped from prefab-local to runtime AssignIds (see remapToRuntimeIds).
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
            if (isPart(d.name)) continue;
            const tb = self.getTtsBlocks(d.name) orelse continue;
            tts.paintDecoration(tb, d.x, d.stampY(), d.z, d.rot, set_block, ctx);
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
            if (isPart(d.name)) continue;
            const tb = self.getTtsBlocks(d.name) orelse continue;
            const origin_y = d.stampY();
            for (tb.tile_entities) |te| {
                const r = tts.rotateLocalXZ(te.lx, te.lz, tb.sx, tb.sz, d.rot);
                const wx = d.x + r.x;
                const wy = origin_y + te.ly;
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
        // Malformed XML must not crash the loader: reject instead of overflowing.
        v = std.math.mul(i32, v, 10) catch return null;
        v = std.math.add(i32, v, s[i] - '0') catch return null;
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
            .quest_cache = std.StringHashMap(QuestData).init(allocator),
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
        .quest_cache = std.StringHashMap(QuestData).init(allocator),
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

/// Pull `<property name="YOffset" value="N" />` out of a stock prefab .xml.
/// Stock reads it as `properties.GetInt("YOffset")` at the end of `Prefab::Load`
/// (asm.il:917079-917081); `DynamicProperties::GetInt` yields 0 both for a
/// missing key and for a value `Int32.TryParse` rejects (asm.il:2082831), so
/// every failure path here returns 0 rather than an error.
fn parseYOffset(xml: []const u8) i32 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, xml, search, "<property")) |tag_start| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, tag_start, '>') orelse return 0;
        const tag = xml[tag_start..tag_end];
        search = tag_end + 1;
        // Exact name compare: the same file also carries "DistantPOIYOffset".
        const name = attrValue(tag, "name") orelse continue;
        if (!std.mem.eql(u8, name, "YOffset")) continue;
        const value = attrValue(tag, "value") orelse return 0;
        return parseI32Prefix(value) orelse 0;
    }
    return 0;
}

/// YOffset from the prefab .xml next to its .tts; 0 when the file is missing.
fn readPrefabYOffset(allocator: std.mem.Allocator, tts_path: []const u8) i32 {
    if (!std.mem.endsWith(u8, tts_path, ".tts")) return 0;
    var path_buf: [2048]u8 = undefined;
    const p = std.fmt.bufPrint(&path_buf, "{s}.xml", .{tts_path[0 .. tts_path.len - 4]}) catch return 0;
    const xml = io_fs.readFileAll(allocator, p) catch return 0;
    defer allocator.free(xml);
    return parseYOffset(xml);
}

fn fillSizesFromTts(idx: *Index) !void {
    var path_buf: [2048]u8 = undefined;
    // Cache by name (keys are d.name slices into stable name_storage).
    var cache = std.StringHashMap(struct { x: i32, y: i32, z: i32, yoff: i32 }).init(idx.allocator);
    defer cache.deinit();

    const subdirs = [_][]const u8{ "POIs", "Parts", "RWGTiles" };
    const root = idx.prefabs_root;
    if (root.len == 0) return;

    for (idx.items) |*d| {
        if (cache.get(d.name)) |sz| {
            d.size_x = sz.x;
            d.size_y = sz.y;
            d.size_z = sz.z;
            d.y_offset = sz.yoff;
            continue;
        }
        var found = false;
        var sx: i32 = 8;
        var sy: i32 = 4;
        var sz: i32 = 8;
        var yoff: i32 = 0;
        for (subdirs) |sub| {
            // Avoid bufPrint overflow on long Steam paths: check lengths first.
            const need = root.len + 1 + sub.len + 1 + d.name.len + 4;
            if (need >= path_buf.len) continue;
            const p = std.fmt.bufPrint(path_buf[0..], "{s}/{s}/{s}.tts", .{ root, sub, d.name }) catch continue;
            if (readTtsSize(p, &sx, &sy, &sz)) {
                found = true;
                yoff = readPrefabYOffset(idx.allocator, p);
                break;
            }
        }
        if (!found and isPart(d.name)) {
            sx = 4;
            sy = 2;
            sz = 4;
        } else if (!found) {
            sx = 16;
            sy = 8;
            sz = 16;
        }
        try cache.put(d.name, .{ .x = sx, .y = sy, .z = sz, .yoff = yoff });
        d.size_x = sx;
        d.size_y = sy;
        d.size_z = sz;
        d.y_offset = yoff;
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

test "parse YOffset property from prefab xml" {
    // Stock property blocks put DistantPOIYOffset before YOffset, so a loose
    // substring match on "YOffset" would read the wrong property.
    const xml =
        \\<prefab>
        \\  <property name="DistantPOIYOffset" value="7" />
        \\  <property name="YOffset" value="-33" />
        \\  <property class="Stats">
        \\    <property name="TotalVertices" value="280910" />
        \\  </property>
        \\</prefab>
    ;
    try std.testing.expectEqual(@as(i32, -33), parseYOffset(xml));
    // Absent, malformed and overflowing values all read 0, like GetInt does.
    try std.testing.expectEqual(@as(i32, 0), parseYOffset("<prefab><property name=\"Zoning\" value=\"City\" /></prefab>"));
    try std.testing.expectEqual(@as(i32, 0), parseYOffset("<prefab><property name=\"YOffset\" value=\"abc\" /></prefab>"));
    try std.testing.expectEqual(@as(i32, 0), parseYOffset("<prefab><property name=\"YOffset\" value=\"99999999999\" /></prefab>"));
    try std.testing.expectEqual(@as(i32, 0), parseYOffset(""));
    // Every truncation of a well formed file must return, not run off the end.
    const full = "<prefab>\n  <property name=\"YOffset\" value=\"-2\" />\n</prefab>";
    var cut: usize = 0;
    while (cut <= full.len) : (cut += 1) _ = parseYOffset(full[0..cut]);
}

test "YOffset applies to the stamp origin but not to the terrain pad" {
    const root = "worlds/zdtd_yoffset_test/Prefabs";
    var hdr: [14]u8 = @splat(0);
    @memcpy(hdr[0..4], "tts\x00");
    std.mem.writeInt(u32, hdr[4..8], 19, .little);
    std.mem.writeInt(u16, hdr[8..10], 12, .little);
    std.mem.writeInt(u16, hdr[10..12], 6, .little);
    std.mem.writeInt(u16, hdr[12..14], 12, .little);
    try io_fs.writeFileSimple(root ++ "/POIs/zdtd_yoffset_poi.tts", &hdr);
    try io_fs.writeFileSimple(root ++ "/POIs/zdtd_yoffset_poi.xml",
        \\<prefab>
        \\  <property name="DistantPOIYOffset" value="0" />
        \\  <property name="YOffset" value="-7" />
        \\</prefab>
    );

    const world_dir = "worlds/zdtd_yoffset_test";
    try io_fs.writeFileSimple(world_dir ++ "/prefabs.xml",
        \\<prefabs>
        \\  <decoration type="model" name="zdtd_yoffset_poi" position="4,60,4" rotation="0" y_is_groundlevel="true" />
        \\  <decoration type="model" name="zdtd_yoffset_poi" position="4,60,4" rotation="0" y_is_groundlevel="false" />
        \\</prefabs>
    );

    var idx = try loadFromWorldDir(std.testing.allocator, world_dir, root);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 2), idx.items.len);
    try std.testing.expectEqual(@as(i32, -7), idx.items[0].y_offset);
    try std.testing.expectEqual(@as(i32, 53), idx.items[0].stampY());
    // Stock only adds yOffset when y_is_groundlevel is set (asm.il:902414).
    try std.testing.expectEqual(@as(i32, -7), idx.items[1].y_offset);
    try std.testing.expectEqual(@as(i32, 60), idx.items[1].stampY());

    // The pad stays at the declared ground level: the height plane must not
    // follow a cave 30 blocks down and punch a pit through the terrain.
    var h: [256]u8 = @splat(50);
    idx.applyToChunkHeights(0, 0, &h);
    try std.testing.expectEqual(@as(u8, 61), h[4 + 4 * 16]);
}

test "stock cave_07 stamps its body below the declared ground" {
    const root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(root ++ "/POIs/cave_07.tts")) return error.SkipZigTest;

    const world_dir = "worlds/zdtd_yoffset_cave_test";
    try io_fs.writeFileSimple(world_dir ++ "/prefabs.xml",
        \\<prefabs>
        \\  <decoration type="model" name="cave_07" position="0,60,0" rotation="0" y_is_groundlevel="true" />
        \\</prefabs>
    );
    var idx = try loadFromWorldDir(std.testing.allocator, world_dir, root);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 1), idx.items.len);
    // cave_07.xml declares YOffset -33; without it the cave sits at the surface.
    try std.testing.expectEqual(@as(i32, -33), idx.items[0].y_offset);
    try std.testing.expectEqual(@as(i32, 27), idx.items[0].stampY());

    const Rec = struct {
        min_wy: i32 = std.math.maxInt(i32),
        fn onBlock(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8) void {
            _ = .{ wx, wz, raw, tex, dens };
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            if (wy < r.min_wy) r.min_wy = wy;
        }
    };
    var with_offset: Rec = .{};
    idx.applyTtsPaintToChunk(0, 0, Rec.onBlock, &with_offset);
    try std.testing.expect(with_offset.min_wy < 60);

    // Same POI with the offset dropped: the delta is exactly the YOffset.
    var without: Rec = .{};
    idx.items[0].y_offset = 0;
    idx.applyTtsPaintToChunk(0, 0, Rec.onBlock, &without);
    try std.testing.expectEqual(without.min_wy - 33, with_offset.min_wy);
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

test "prefab type ids remap through blocks.nim into runtime ids" {
    const maxdamage = @import("../assets/maxdamage.zig");
    const root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(root ++ "/POIs/abandoned_house_01.tts")) return error.SkipZigTest;
    var table = maxdamage.Table.empty();
    defer table.deinit();
    table.tryMergeBundledAssignIds(std.testing.allocator);
    if (table.id_by_name.count() == 0) return error.SkipZigTest;

    const xml =
        \\<prefabs>
        \\  <decoration type="model" name="abandoned_house_01" position="-872,61,612" rotation="0" />
        \\  <decoration type="model" name="cave_05" position="-100,40,100" rotation="0" />
        \\  <decoration type="model" name="abandoned_house_07" position="-262,61,450" rotation="3" />
        \\</prefabs>
    ;
    var idx = try parseXml(std.testing.allocator, xml, root);
    defer idx.deinit();
    const Look = struct {
        fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
            const t: *const maxdamage.Table = @ptrCast(@alignCast(ctx.?));
            return t.idByName(name);
        }
    };
    idx.setIdLookup(.{ .ctx = &table, .lookup = Look.lookup });

    // abandoned_house_01/_07 are file version 19, cave_05 is version 17: the
    // pre-18 one only lands in its own name map once BlockValueV3 is converted.
    for ([_][]const u8{ "abandoned_house_01", "cave_05", "abandoned_house_07" }) |name| {
        var tts_buf: [2048]u8 = undefined;
        const tts_path = idx.findTtsPath(name, &tts_buf) orelse return error.SkipZigTest;
        var raw = try tts.loadBlocks(std.testing.allocator, tts_path);
        defer raw.deinit();
        var nim_buf: [2048]u8 = undefined;
        const nim_path = idx.findPrefabPath(name, ".blocks.nim", &nim_buf) orelse return error.SkipZigTest;
        var map = try blocks_nim.loadFromPath(std.testing.allocator, nim_path);
        defer map.deinit();

        const remapped = idx.getTtsBlocks(name) orelse return error.SkipZigTest;
        try std.testing.expectEqual(raw.types.len, remapped.types.len);

        // Live client evidence for this defect: abandoned_house_07 stands at
        // world (-241,471) and its y63 cell arrived as id 2505, which the client
        // renders as woodShapes:signLetter_period. 2505 is a prefab-local id and
        // this POI's name map calls it brickShapes:cube, a different runtime id.
        if (std.mem.eql(u8, name, "abandoned_house_07")) {
            try std.testing.expectEqualStrings("brickShapes:cube", map.nameOf(2505).?);
            try std.testing.expect(table.idByName("brickShapes:cube").? != 2505);
        }

        var checked: usize = 0;
        var changed: usize = 0;
        for (raw.types, remapped.types) |r, m| {
            const local: u16 = @truncate(r & tts.type_mask);
            if (local == 0) continue;
            // Every authored id must name a block this install still has, or
            // the prefab would be stamped with something else entirely.
            const bname = map.nameOf(local) orelse return error.PrefabIdMissingFromNameMap;
            const runtime = table.idByName(bname) orelse return error.BlockNameMissingFromAssignIds;
            try std.testing.expectEqual(runtime, @as(u16, @truncate(m & tts.type_mask)));
            // BlockValue::set_type replaces the low 16 bits only.
            try std.testing.expectEqual(r & ~tts.type_mask, m & ~tts.type_mask);
            checked += 1;
            if (runtime != local) changed += 1;
        }
        try std.testing.expect(checked > 1000);
        // The defect: those cells used to be stamped with the local id.
        try std.testing.expect(changed > 0);
    }
}

test "quest data and part filter from the stock install" {
    const root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(root ++ "/POIs/AAA_utility_waterworks.xml")) return error.SkipZigTest;
    var idx = try parseXml(std.testing.allocator,
        \\<prefabs><decoration type="model" name="AAA_utility_waterworks" position="0,0,0" rotation="0" /></prefabs>
    , root);
    defer idx.deinit();
    const qd = idx.questData("AAA_utility_waterworks").?;
    try std.testing.expect(qd.tier == 1);
    try std.testing.expect(std.mem.indexOf(u8, qd.tags, "fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, qd.tags, "infested") != null);
    // Cached negative: a name with no POI XML returns empty data, not an error.
    const none = idx.questData("part_5m_water_tower").?;
    try std.testing.expect(none.tags.len == 0 and none.tier == 0);
    // City parts are never quest POIs; real POIs are.
    try std.testing.expect(isPart("part_5m_water_tower"));
    try std.testing.expect(isPart("part_driveway_01"));
    try std.testing.expect(!isPart("AAA_utility_waterworks"));
    try std.testing.expect(!isPart("house_old_01"));
}

test "trader POI data: cell and class tag from the stock install" {
    const root = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs";
    if (!fileExists(root ++ "/POIs/trader_bob.xml")) return error.SkipZigTest;
    var idx = try parseXml(std.testing.allocator,
        \\<prefabs><decoration type="model" name="trader_bob" position="0,0,0" rotation="2" /></prefabs>
    , root);
    defer idx.deinit();
    const qd = idx.questData("trader_bob").?;
    try std.testing.expectEqual(@as(i32, 37), qd.trader_x);
    try std.testing.expectEqual(@as(i32, 2), qd.trader_y);
    try std.testing.expectEqual(@as(i32, 24), qd.trader_z);
    try std.testing.expectEqualStrings("traderBob", qd.trader_tag);
    // Rotation maps the local cell to the world offset used at spawn.
    const r = tts.rotateLocalXZ(qd.trader_x, qd.trader_z, 60, 60, 2);
    try std.testing.expectEqual(@as(i32, 60 - 1 - 37), r.x);
    // Trader compound area: TraderArea=True, protect padding and the six
    // teleport volumes from the XML #-lists.
    try std.testing.expect(qd.is_trader_area);
    try std.testing.expectEqual(@as(i8, 0), qd.protect_padding[0]);
    try std.testing.expectEqual(@as(u8, 6), qd.teleport_n);
    try std.testing.expectEqual(@as(i8, 7), qd.teleport_start[0][0]);
    try std.testing.expectEqual(@as(u8, 52), qd.teleport_size[0][0]);
    try std.testing.expectEqual(@as(i8, 54), qd.teleport_start[5][0]);
    // A non-trader POI has no trader cell.
    const plain = idx.questData("part_5m_water_tower").?;
    try std.testing.expectEqual(@as(i32, -1), plain.trader_x);
    try std.testing.expect(plain.trader_tag.len == 0);
    try std.testing.expect(!plain.is_trader_area);
}
