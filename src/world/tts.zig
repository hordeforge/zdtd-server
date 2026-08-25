//! Stock prefab `.tts` block paint (Prefab.readBlockData, V3.x file version 19).
//!
//! File layout (stream after open):
//!   magic "tts\0" | version:u32 | size.x/y/z:i16 | blockCount * raw:u32 LE
//!   density:sbyte[count] (v>=?)
//!   damage:u16 LE[count] (v>8)
//!   texture: SimpleBitStream + sparse TextureFullArray (v>=10)
//!   water: SimpleBitStream + WaterValue (v>=17)
//!   (entities only for v 4..11)
//! After loadBlockData returns, caller may readTileEntities (v>12).
//! Block loop (version > 4): flat index 0..count-1 with Prefab.offsetToCoord:
//!   dim = sx*sy; z = i/dim; y = (i%dim)/sx; x = (i%dim)%sx
//! BlockValue.type = raw & 0xFFFF; child bit = 0x40000000 (skip children).
//! File version < 18 stores the older BlockValueV3 layout: convertOldRawData.
//! Type ids are prefab-local indices into `<name>.blocks.nim`, not runtime block
//! ids; `prefabs.Index` remaps them by name (Prefab::loadIdMapping).

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const assignids = @import("../assets/assignids_comptime.zig");

/// TTS block-paint blockId bitfield: child flag (RE: tts.zig header, Prefab.readBlockData).
pub const child_bit: u32 = 0x4000_0000;
/// TTS block-paint blockId bitfield: decal flag (RE: tts.zig header).
pub const decal_bit: u32 = 0x8000_0000;
/// TTS block-paint blockId bitfield: type mask (RE: tts.zig header).
pub const type_mask: u32 = 0xFFFF;
/// First file version written with the current `BlockValue` bit layout; older
/// files carry `BlockValueV3` and go through `convertOldRawData` first.
pub const blockvalue_version: u32 = 18;

/// `BlockValueV3.rawData` → `BlockValue.rawData` (`BlockValueV3::ConvertOldRawData`,
/// asm.il:141406). `readBlockData` runs this on every cell of a pre-18 prefab
/// before anything reads the type (asm.il:920200), and 568 of Navezgane's 1559
/// decorations are pre-18, so without it the type field is off by a bit.
///   old: type 0..14, rotation 15..19, meta 20..23, meta2 24..27, meta3 28..29
///   new: type 0..15, rotation 16..20, meta3 21, meta 22..25, meta2 26..29
/// Child (bit 30) and decal (bit 31) keep their position in both layouts.
/// Stock re-encodes the parent offset for a child cell; `parseBlocks` drops
/// child cells (multi-block children are not regenerated), so only the child
/// bit has to survive here. Stock also converts through one shared static
/// BlockValue, which leaks the child bit from a child cell into the cells after
/// it; starting from zero avoids inheriting that.
pub fn convertOldRawData(old: u32) u32 {
    if (old & child_bit != 0) return child_bit;
    var new: u32 = old & 0x7FFF;
    new |= ((old >> 15) & 31) << 16;
    new |= ((old >> 20) & 15) << 22;
    new |= ((old >> 24) & 15) << 26;
    return new | (old & decal_bit);
}

/// Prefab TileEntity list entry (local coords + type + raw payload).
pub const TeEntry = struct {
    /// Local prefab cell (before rotation/origin).
    lx: i16 = 0,
    ly: i16 = 0,
    lz: i16 = 0,
    /// TileEntityType enum (Composite=0x19, Loot=0x05, …).
    te_type: u8 = 0,
    /// Opaque TE body (StreamMode Persistency path).
    payload: []const u8 = &.{},
};

pub const TtsBlocks = struct {
    sx: i32,
    sy: i32,
    sz: i32,
    /// Full BlockValue.rawData (type 0..15 + rotation/meta); air = 0. Child cells cleared.
    types: []u32,
    /// Density channel (stock sbyte as u8 bit pattern), length types.len or empty.
    density: []u8 = &.{},
    /// Damage plane (u16 LE per cell) when present.
    damage: []u16 = &.{},
    /// Per-cell textureFull (paint); low 48 bits meaningful. 0 = unpainted.
    /// Length types.len when the sparse texture channel was decoded, else empty.
    textures: []u64 = &.{},
    /// Per-cell water mass (sparse WaterValue u16, v>=17). 0 = dry. Length
    /// types.len when the channel was decoded, else empty. Cells with mass > 0
    /// are authored water (POI pools, flooded basements, water towers).
    water: []u16 = &.{},
    /// Prefab TE list (local coords). Payloads owned by same allocator.
    tile_entities: []TeEntry = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TtsBlocks) void {
        for (self.tile_entities) |te| {
            if (te.payload.len != 0) self.allocator.free(te.payload);
        }
        if (self.tile_entities.len != 0) self.allocator.free(self.tile_entities);
        self.allocator.free(self.types);
        if (self.density.len != 0) self.allocator.free(self.density);
        if (self.damage.len != 0) self.allocator.free(self.damage);
        if (self.textures.len != 0) self.allocator.free(self.textures);
        if (self.water.len != 0) self.allocator.free(self.water);
        self.* = undefined;
    }

    pub fn blockCount(self: *const TtsBlocks) usize {
        return self.types.len;
    }

    /// Prefab.offsetToCoord
    pub fn offsetToCoord(self: *const TtsBlocks, offset: i32) struct { x: i32, y: i32, z: i32 } {
        const dim = self.sx * self.sy;
        const z = @divTrunc(offset, dim);
        const rem = @rem(offset, dim);
        const y = @divTrunc(rem, self.sx);
        const x = @rem(rem, self.sx);
        return .{ .x = x, .y = y, .z = z };
    }
};

/// SimpleBitStream.Read: i32 length + length bytes. Returns new offset after stream.
fn skipSimpleBitStream(data: []const u8, pos: usize) !usize {
    if (pos + 4 > data.len) return error.ShortTts;
    const n = std.mem.readInt(i32, data[pos..][0..4], .little);
    if (n < 0) return error.BadBitStream;
    const end = pos + 4 + @as(usize, @intCast(n));
    if (end > data.len) return error.ShortTts;
    return end;
}

/// Parse stock .tts bytes (version >= 5 raw u32 path). Caller owns returned planes.
pub fn parseBlocks(allocator: std.mem.Allocator, data: []const u8) !TtsBlocks {
    if (data.len < 14) return error.ShortTts;
    if (!std.mem.eql(u8, data[0..4], "tts\x00")) return error.BadMagic;
    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version < 5) return error.UnsupportedTtsVersion;
    const sx: i32 = std.mem.readInt(i16, data[8..10], .little);
    const sy: i32 = std.mem.readInt(i16, data[10..12], .little);
    const sz: i32 = std.mem.readInt(i16, data[12..14], .little);
    if (sx <= 0 or sy <= 0 or sz <= 0) return error.BadSize;
    const count: usize = @intCast(@as(i64, sx) * @as(i64, sy) * @as(i64, sz));
    const need = 14 + count * 4;
    if (data.len < need) return error.ShortTts;
    const types = try allocator.alloc(u32, count);
    errdefer allocator.free(types);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = 14 + i * 4;
        const stored = std.mem.readInt(u32, data[off..][0..4], .little);
        const raw = if (version < blockvalue_version) convertOldRawData(stored) else stored;
        if (raw & child_bit != 0) {
            types[i] = 0;
            continue;
        }
        // Keep type + rotation + meta; drop hasdecal if any (bit 31 unused for paint).
        types[i] = raw & ~child_bit;
    }

    var pos: usize = need;
    var density: []u8 = &.{};
    var damage: []u16 = &.{};
    var textures: []u64 = &.{};
    var water: []u16 = &.{};
    var tile_entities: []TeEntry = &.{};
    // Free planes allocated mid-parse if a later step fails (OOM / TE list error).
    errdefer {
        if (density.len != 0) allocator.free(density);
        if (damage.len != 0) allocator.free(damage);
        if (textures.len != 0) allocator.free(textures);
        if (water.len != 0) allocator.free(water);
    }

    // Density: sbyte[count]: always present for our supported versions after blocks.
    // (IL sets density during block loop for air; also bulk channel in some paths.)
    // Measured stock files: density plane immediately after blocks.
    if (data.len >= pos + count) {
        density = try allocator.alloc(u8, count);
        @memcpy(density, data[pos .. pos + count]);
        pos += count;
    }

    // Damage: u16 LE[count] when version > 8.
    if (version > 8 and data.len >= pos + count * 2) {
        damage = try allocator.alloc(u16, count);
        var di: usize = 0;
        while (di < count) : (di += 1) {
            damage[di] = std.mem.readInt(u16, data[pos + di * 2 ..][0..2], .little);
        }
        pos += count * 2;
    }

    // Texture sparse (version >= 10): SimpleBitStream + one i64 textureFull per
    // set bit (bit index = cell offset). Decode into a dense per-cell array so
    // paint-driven shape blocks get their face material on the wire (else grey).
    if (version >= 10 and pos + 4 <= data.len) {
        const n = std.mem.readInt(i32, data[pos..][0..4], .little);
        if (n >= 0 and pos + 4 + @as(usize, @intCast(n)) <= data.len) {
            const bits = data[pos + 4 ..][0..@intCast(n)];
            var texpos = pos + 4 + @as(usize, @intCast(n));
            const tex = try allocator.alloc(u64, count);
            @memset(tex, 0);
            var bit_i: usize = 0;
            const total_bits = bits.len * 8;
            while (bit_i < total_bits and bit_i < count) : (bit_i += 1) {
                const byte = bits[bit_i / 8];
                const bit: u3 = @intCast(bit_i % 8);
                if ((byte >> bit) & 1 == 0) continue;
                if (texpos + 8 > data.len) break;
                tex[bit_i] = std.mem.readInt(u64, data[texpos..][0..8], .little);
                texpos += 8;
            }
            textures = tex;
            pos = texpos;
        }
    }

    // Water sparse (version >= 17): SimpleBitStream + WaterValue (u16 mass) per set bit.
    // Bit index = cell offset (same as texture channel); ignore padding bits past `count`.
    if (version >= 17 and pos + 4 <= data.len) {
        var prefer_te = false;
        if (pos + 5 <= data.len) {
            const maybe_te = std.mem.readInt(i16, data[pos..][0..2], .little);
            const plen0 = std.mem.readInt(i16, data[pos + 2 ..][0..2], .little);
            if (maybe_te >= 0 and maybe_te < 512 and plen0 > 0 and plen0 < 4096) prefer_te = true;
        }
        if (!prefer_te) {
            const bit_start_pos = pos;
            pos = skipSimpleBitStream(data, pos) catch pos;
            if (pos > bit_start_pos + 4) {
                const n = std.mem.readInt(i32, data[bit_start_pos..][0..4], .little);
                const bits = data[bit_start_pos + 4 ..][0..@intCast(n)];
                const wt = try allocator.alloc(u16, count);
                errdefer allocator.free(wt);
                @memset(wt, 0);
                var wpos = pos;
                var bit_i: usize = 0;
                const total_bits = bits.len * 8;
                while (bit_i < total_bits and bit_i < count) : (bit_i += 1) {
                    const byte = bits[bit_i / 8];
                    const bit: u3 = @intCast(bit_i % 8);
                    if ((byte >> bit) & 1 == 0) continue;
                    // WaterValue.Read = u16 mass
                    if (wpos + 2 > data.len) break;
                    wt[bit_i] = std.mem.readInt(u16, data[wpos..][0..2], .little);
                    wpos += 2;
                }
                pos = wpos;
                water = wt;
            }
        }
    }

    // Tile entities after readBlockData when version > 12:
    // i16 count | (i16 payloadLen | u8 type | payload[payloadLen])*count
    if (version > 12 and pos + 2 <= data.len) {
        const te_count_i = std.mem.readInt(i16, data[pos..][0..2], .little);
        if (te_count_i > 0 and te_count_i < 2048) {
            pos += 2;
            const te_count: usize = @intCast(te_count_i);
            var list: std.ArrayList(TeEntry) = .empty;
            errdefer {
                for (list.items) |te| {
                    if (te.payload.len != 0) allocator.free(te.payload);
                }
                list.deinit(allocator);
            }
            var ti: usize = 0;
            while (ti < te_count and pos + 3 <= data.len) : (ti += 1) {
                const plen_i = std.mem.readInt(i16, data[pos..][0..2], .little);
                pos += 2;
                const te_type = data[pos];
                pos += 1;
                if (plen_i <= 0) break;
                const plen: usize = @intCast(plen_i);
                if (pos + plen > data.len) break;
                const payload = try allocator.dupe(u8, data[pos .. pos + plen]);
                pos += plen;
                var lx: i16 = 0;
                var ly: i16 = 0;
                var lz: i16 = 0;
                // Persistency TileEntity.read: u16 version + Vector3i chunkPos (local).
                if (payload.len >= 2 + 12) {
                    const x = std.mem.readInt(i32, payload[2..6], .little);
                    const y = std.mem.readInt(i32, payload[6..10], .little);
                    const z = std.mem.readInt(i32, payload[10..14], .little);
                    if (x >= 0 and x < sx and y >= 0 and y < sy and z >= 0 and z < sz) {
                        lx = @intCast(x);
                        ly = @intCast(y);
                        lz = @intCast(z);
                    }
                }
                try list.append(allocator, .{
                    .lx = lx,
                    .ly = ly,
                    .lz = lz,
                    .te_type = te_type,
                    .payload = payload,
                });
            }
            tile_entities = try list.toOwnedSlice(allocator);
        }
    }

    return .{
        .sx = sx,
        .sy = sy,
        .sz = sz,
        .types = types,
        .density = density,
        .damage = damage,
        .textures = textures,
        .water = water,
        .tile_entities = tile_entities,
        .allocator = allocator,
    };
}

/// Load block type plane from a stock .tts path (version >= 5 raw u32 path).
pub fn loadBlocks(allocator: std.mem.Allocator, path: []const u8) !TtsBlocks {
    const data = try io_fs.readFileAll(allocator, path);
    defer allocator.free(data);
    return parseBlocks(allocator, data);
}

/// Rotate local XZ for prefab rotation 0..3, origin corner fixed.
///
/// Stock turns clockwise: Prefab::RotatePointOnY takes the AngleAxis(-90, up)
/// path (asm.il ~915424), so r=1 maps (x,z) to (sz-1-z, x) and r=3 maps it to
/// (z, sx-1-x). Turning the other way leaves r=0 and r=2 right but swaps r=1
/// with r=3, which is 709 of Navezgane's 1559 decorations. The observable cost
/// is that front doors, garages and driveways face away from their road: for
/// the 130 decorations carrying POIMarkerType=RoadExit, the stock map lands the
/// marker within 4 blocks of a road pixel in splat3_processed.png for 129, the
/// mirrored map for only 94 (and just 6 of 24 at r=1, 6 of 23 at r=3).
pub fn rotateLocalXZ(x: i32, z: i32, sx: i32, sz: i32, rot: u8) struct { x: i32, z: i32 } {
    return switch (rot & 3) {
        0 => .{ .x = x, .z = z },
        1 => .{ .x = sz - 1 - z, .z = x },
        2 => .{ .x = sx - 1 - x, .z = sz - 1 - z },
        3 => .{ .x = z, .z = sx - 1 - x },
        else => .{ .x = x, .z = z },
    };
}

/// BlockValue.rotation is bits 16..20 (`(rawData >> 16) & 31`, asm.il
/// BlockValue::get_rotation ~140513).
const rotation_shift: u5 = 16;
const rotation_mask: u32 = 31;

/// One 90 degree step about world Y for the 24 cube orientations. Stock does
/// this in BlockShapeNew::CalcRotation (asm.il ~181959) by running the
/// orientation through ConvertRotationFree; this table is that same permutation,
/// derived from the BlockShapeNew::rotationsToQuats construction (asm.il
/// ~181879) where entry i is AngleAxis(a, right|forward) * AngleAxis(b, up).
/// It is a bijection of order 4, which the tests below assert.
const rot_y_step = [24]u8{
    1,  2,  3,  0,
    7,  4,  5,  6,
    23, 20, 21, 22,
    11, 8,  9,  10,
    13, 14, 15, 12,
    17, 18, 19, 16,
};

/// Rotate a block's own facing to match a prefab stamped at `steps` * 90
/// degrees. Rotating only the footprint leaves every wall, roof and sign inside
/// a rotated POI facing its unrotated direction, which is most of Navezgane:
/// its prefabs.xml uses rotations 0..3 in roughly equal numbers.
/// Entries 24..27 are the 45 degree band and cycle among themselves, matching
/// CalcRotation's separate loop for `_rotation >= 24`. Anything above that is
/// left alone rather than guessed at.
pub fn rotateRawY(raw: u32, steps: u8) u32 {
    const n: u8 = steps & 3;
    if (n == 0) return raw;
    const rot: u8 = @truncate((raw >> rotation_shift) & rotation_mask);
    var out: u8 = rot;
    if (rot < 24) {
        var i: u8 = 0;
        while (i < n) : (i += 1) out = rot_y_step[out];
    } else if (rot < 28) {
        out = 24 + ((rot - 24 + n) & 3);
    } else {
        return raw;
    }
    return (raw & ~(rotation_mask << rotation_shift)) |
        (@as(u32, out) << rotation_shift);
}

/// dens: TTS density sbyte as u8 when plane present; null when unknown.
pub const SetBlockFn = *const fn (ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8, dmg: u16) void;

/// Stamp non-air TTS cells into the world at decoration origin.
/// `origin_y` is ground (y_is_ground) or prefab base Y.
/// Skips air and terrainFiller / terrainFillerAdaptive: those are stock "keep
/// world terrain" placeholders. Stamping filler paints grey marching-cubes clay.
/// Full BlockValue.rawData (type + rotation + meta) is stamped so shape meshes
/// face the correct way and take TTS paint textures.
pub fn paintDecoration(
    tts: *const TtsBlocks,
    origin_x: i32,
    origin_y: i32,
    origin_z: i32,
    rot: u8,
    water_id: u16,
    /// Resolved filler type ids (A37): TTS stamps these as "keep world terrain"
    /// placeholders; skipping them via live ids keeps modded dumps correct.
    filler_id: u16,
    filler_adaptive_id: u16,
    /// Resolves the replacement block for a filler cell (stock
    /// InitTerrainFillers/CopyIntoLocal: the cell takes the surrounding
    /// terrain). Null = skip the filler cells (offline tests).
    terrain_id: ?*const fn (?*anyopaque, i32, i32, i32) u16,
    terrain_ctx: ?*anyopaque,
    set_block: SetBlockFn,
    ctx: ?*anyopaque,
) void {
    const count: i32 = @intCast(tts.blockCount());
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const c = tts.offsetToCoord(i);
        const r = rotateLocalXZ(c.x, c.z, tts.sx, tts.sz, rot);
        const wx = origin_x + r.x;
        const wy = origin_y + c.y;
        const wz = origin_z + r.z;
        if (wy < 0 or wy >= 256) continue;
        // Authored POI water (v>=17 sparse channel): the cell's block plane is
        // air but the water channel marks mass. Paint the resolved water block
        // so the chunk wire's water-mass channel derives the cell (stock pools,
        // flooded basements, water towers) at full static mass.
        if (water_id != 0 and tts.water.len > @as(usize, @intCast(i)) and tts.water[@intCast(i)] > 0) {
            set_block(ctx, wx, wy, wz, water_id, 0, null, 0);
            continue;
        }
        const raw = tts.types[@intCast(i)];
        if (raw == 0) continue;
        const typ: u16 = @truncate(raw & type_mask);
        if (typ == filler_id or typ == filler_adaptive_id) {
            // Stock resolves fillers through InitTerrainFillers / CopyIntoLocal:
            // the cell takes the surrounding terrain instead of staying a
            // placeholder (adaptive fillers use the same surrounding material).
            if (terrain_id) |tf| {
                const tid = tf(terrain_ctx, wx, wy, wz);
                if (tid != 0) {
                    // Terrain cell: no paint, density or damage.
                    set_block(ctx, wx, wy, wz, tid, 0, null, 0);
                    continue;
                }
            }
            continue;
        }
        const tex: u64 = if (tts.textures.len > @as(usize, @intCast(i))) tts.textures[@intCast(i)] else 0;
        const dens: ?u8 = if (tts.density.len > @as(usize, @intCast(i))) tts.density[@intCast(i)] else null;
        // Authored block damage (u16 absolute HP, v>8 plane): POIs that stock
        // ships pre-damaged arrive with their cracks and weak spots. 0 when
        // the plane is absent.
        const dmg: u16 = if (tts.damage.len > @as(usize, @intCast(i))) tts.damage[@intCast(i)] else 0;
        // Stock rotates a block by CalcRotation(rot, 4 - r): BlockShapeNew::RotateY
        // replaces _rotCount with 4 - _rotCount on the left-turn path
        // (asm.il ~181926). Using r directly leaves the building internally
        // coherent but 180 degrees off stock at r=1 and r=3.
        set_block(ctx, wx, wy, wz, rotateRawY(raw, 4 -% (rot & 3)), tex, dens, dmg);
    }
}

test "rotateRawY is identity for zero steps and preserves non-rotation bits" {
    const raw: u32 = 0x0AB3_0042; // type 0x42, rotation 3, high meta bits set
    try std.testing.expectEqual(raw, rotateRawY(raw, 0));
    const r1 = rotateRawY(raw, 1);
    try std.testing.expectEqual(raw & ~(rotation_mask << rotation_shift), r1 & ~(rotation_mask << rotation_shift));
}

test "rotateRawY cube orientations form a bijection of order four" {
    var seen = [_]bool{false} ** 24;
    var rot: u8 = 0;
    while (rot < 24) : (rot += 1) {
        const raw = @as(u32, rot) << rotation_shift;
        const once: u8 = @truncate((rotateRawY(raw, 1) >> rotation_shift) & rotation_mask);
        try std.testing.expect(once < 24);
        try std.testing.expect(!seen[once]);
        seen[once] = true;
        // Four quarter turns must land back on the original facing.
        try std.testing.expectEqual(raw, rotateRawY(raw, 4));
        // Stepping twice equals one half turn.
        try std.testing.expectEqual(rotateRawY(raw, 2), rotateRawY(rotateRawY(raw, 1), 1));
    }
    for (seen) |s| try std.testing.expect(s);
}

test "rotateRawY cycles the 45 degree band and leaves unknown rotations alone" {
    const band_base: u32 = 24 << rotation_shift;
    try std.testing.expectEqual(@as(u32, 25) << rotation_shift, rotateRawY(band_base, 1));
    try std.testing.expectEqual(@as(u32, 24) << rotation_shift, rotateRawY(@as(u32, 27) << rotation_shift, 1));
    try std.testing.expectEqual(band_base, rotateRawY(band_base, 4));
    const unknown: u32 = 30 << rotation_shift;
    try std.testing.expectEqual(unknown, rotateRawY(unknown, 1));
}

test "tts load abandoned_house block types if present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs/POIs/abandoned_house_01.tts";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;

    var t = try loadBlocks(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expectEqual(@as(i32, 42), t.sx);
    try std.testing.expectEqual(@as(i32, 21), t.sy);
    try std.testing.expectEqual(@as(i32, 42), t.sz);
    try std.testing.expectEqual(@as(usize, 42 * 21 * 42), t.types.len);
    var non_air: usize = 0;
    for (t.types) |ty| {
        if (ty != 0) non_air += 1;
    }
    try std.testing.expect(non_air > 100);
    const c0 = t.offsetToCoord(0);
    try std.testing.expectEqual(@as(i32, 0), c0.x);
    try std.testing.expectEqual(@as(i32, 0), c0.y);
    try std.testing.expectEqual(@as(i32, 0), c0.z);
    // Density + damage planes on stock v19.
    try std.testing.expectEqual(t.types.len, t.density.len);
    try std.testing.expectEqual(t.types.len, t.damage.len);
    try std.testing.expectEqual(@as(u8, 0x80), t.density[0]);
    // Prefab TE list after density/damage/texture (abandoned_house has sleepers/loot).
    try std.testing.expect(t.tile_entities.len >= 1);
}

test "rotate local xz quarter turns" {
    const a = rotateLocalXZ(0, 0, 3, 2, 0);
    try std.testing.expectEqual(@as(i32, 0), a.x);
    try std.testing.expectEqual(@as(i32, 0), a.z);
    const b = rotateLocalXZ(0, 0, 3, 2, 2);
    try std.testing.expectEqual(@as(i32, 2), b.x);
    try std.testing.expectEqual(@as(i32, 1), b.z);
}

test "rotateLocalXZ turns clockwise like stock" {
    // Corners of a 4 x 6 prefab under each rotation. Stock's forward map is
    // r=1 -> (sz-1-z, x) and r=3 -> (z, sx-1-x); mirroring those two is the
    // defect that pointed 709 of Navezgane's 1559 POIs away from their road.
    const sx: i32 = 4;
    const sz: i32 = 6;
    try std.testing.expectEqual(@as(i32, 0), rotateLocalXZ(0, 0, sx, sz, 0).x);
    try std.testing.expectEqual(@as(i32, 0), rotateLocalXZ(0, 0, sx, sz, 0).z);

    const r1 = rotateLocalXZ(0, 0, sx, sz, 1);
    try std.testing.expectEqual(@as(i32, sz - 1), r1.x);
    try std.testing.expectEqual(@as(i32, 0), r1.z);

    const r2 = rotateLocalXZ(0, 0, sx, sz, 2);
    try std.testing.expectEqual(@as(i32, sx - 1), r2.x);
    try std.testing.expectEqual(@as(i32, sz - 1), r2.z);

    const r3 = rotateLocalXZ(0, 0, sx, sz, 3);
    try std.testing.expectEqual(@as(i32, 0), r3.x);
    try std.testing.expectEqual(@as(i32, sx - 1), r3.z);

    // Four quarter turns return every cell to itself.
    var x: i32 = 0;
    while (x < sx) : (x += 1) {
        var z: i32 = 0;
        while (z < sz) : (z += 1) {
            const a = rotateLocalXZ(x, z, sx, sz, 1);
            const b = rotateLocalXZ(a.x, a.z, sz, sx, 1);
            const c = rotateLocalXZ(b.x, b.z, sx, sz, 1);
            const d = rotateLocalXZ(c.x, c.z, sz, sx, 1);
            try std.testing.expectEqual(x, d.x);
            try std.testing.expectEqual(z, d.z);
        }
    }
}

test "convert BlockValueV3 raw data to the current layout" {
    // type 0x1234, rotation 5, meta 9, meta2 3, decal set, in the old layout.
    const old: u32 = 0x1234 | (5 << 15) | (9 << 20) | (3 << 24) | decal_bit;
    const new = convertOldRawData(old);
    try std.testing.expectEqual(@as(u32, 0x1234), new & type_mask);
    try std.testing.expectEqual(@as(u32, 5), (new >> 16) & 31);
    try std.testing.expectEqual(@as(u32, 9), (new >> 22) & 15);
    try std.testing.expectEqual(@as(u32, 3), (new >> 26) & 15);
    try std.testing.expect(new & decal_bit != 0);
    try std.testing.expect(new & child_bit == 0);
    // Old type is 15 bits, so bit 15 belongs to rotation, not the type. Reading
    // it as a 16-bit type is what made pre-18 prefabs miss their name map.
    try std.testing.expectEqual(@as(u32, 0x0001), convertOldRawData(0x0001 | (1 << 15)) & type_mask);
    // Child cells keep only the child bit; parseBlocks drops them.
    try std.testing.expectEqual(child_bit, convertOldRawData(0x2222 | child_bit));
    try std.testing.expectEqual(@as(u32, 0), convertOldRawData(0));
}

test "prefab water channel decodes and paints water blocks" {
    // Synthetic v19 .tts: 3x2x2 all-air prefab with one water cell (bit 7)
    // carrying full mass. Layout: magic, version, dims, blocks, density,
    // damage, texture bitstream (empty), water bitstream + WaterValue u16s.
    var buf: [160]u8 = undefined;
    var pos: usize = 0;
    @memcpy(buf[0..4], "tts\x00");
    pos = 4;
    std.mem.writeInt(u32, buf[pos..][0..4], 19, .little);
    pos += 4;
    std.mem.writeInt(i16, buf[pos..][0..2], 3, .little);
    std.mem.writeInt(i16, buf[pos + 2 ..][0..2], 2, .little);
    std.mem.writeInt(i16, buf[pos + 4 ..][0..2], 2, .little);
    pos += 6;
    const count: usize = 12;
    @memset(buf[pos .. pos + count * 4], 0); // blocks: all air
    pos += count * 4;
    @memset(buf[pos .. pos + count], 0); // density plane
    pos += count;
    @memset(buf[pos .. pos + count * 2], 0); // damage plane
    pos += count * 2;
    std.mem.writeInt(i32, buf[pos..][0..4], 0, .little); // texture bitstream: empty
    pos += 4;
    std.mem.writeInt(i32, buf[pos..][0..4], 1, .little); // water bitstream: 1 byte
    pos += 4;
    buf[pos] = 0x80; // bit 7 set -> cell 7 has water
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], 19500, .little); // WaterValue mass
    pos += 2;

    var t = try parseBlocks(std.testing.allocator, buf[0..pos]);
    defer t.deinit();
    try std.testing.expectEqual(t.types.len, t.water.len);
    try std.testing.expectEqual(@as(u16, 19500), t.water[7]);
    try std.testing.expectEqual(@as(u16, 0), t.water[0]);
    const c7 = t.offsetToCoord(7);
    try std.testing.expectEqual(@as(i32, 1), c7.x);
    try std.testing.expectEqual(@as(i32, 0), c7.y);
    try std.testing.expectEqual(@as(i32, 1), c7.z);

    // Paint: the water cell becomes a water block, air cells stay unpainted.
    const Paint = struct {
        water: ?struct { wx: i32, wy: i32, wz: i32 } = null,
        blocks: usize = 0,
        dmg_seen: u16 = 0,
        fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8, dmg: u16) void {
            _ = tex;
            _ = dens;
            const p: *@This() = @ptrCast(@alignCast(ctx.?));
            p.dmg_seen = dmg;
            if (raw == 0) return;
            p.blocks += 1;
            if (raw == 240) p.water = .{ .wx = wx, .wy = wy, .wz = wz };
        }
    };
    var p: Paint = .{};
    paintDecoration(&t, 100, 60, 100, 0, 240, assignids.terrain_filler, assignids.terrain_filler_adaptive, null, null, Paint.put, &p);
    try std.testing.expectEqual(@as(usize, 1), p.blocks);
    const wcell = p.water.?;
    try std.testing.expectEqual(@as(i32, 101), wcell.wx);
    try std.testing.expectEqual(@as(i32, 60), wcell.wy);
    try std.testing.expectEqual(@as(i32, 101), wcell.wz);

    // water_id 0 fails closed: no water painted.
    var p0: Paint = .{};
    paintDecoration(&t, 100, 60, 100, 0, 0, assignids.terrain_filler, assignids.terrain_filler_adaptive, null, null, Paint.put, &p0);
    try std.testing.expectEqual(@as(usize, 0), p0.blocks);
}

test "paintDecoration carries authored damage to the set callback" {
    // GAP "Prefab authored block damage plane": the TTS damage plane (u16
    // absolute HP per cell) must reach the set callback so POIs arrive with
    // their ruined/weak-spot cells. Air cells never reach the callback.
    const allocator = std.testing.allocator;
    const count: usize = 4; // 2 x 1 x 2
    const types = try allocator.alloc(u32, count);
    const damages = try allocator.alloc(u16, count);
    types[0] = 0x1001; // type 1, rotation 1
    damages[0] = 250;
    types[1] = 0x1002;
    damages[1] = 0;
    types[2] = 0; // air
    damages[2] = 99; // skipped: raw == 0
    types[3] = 0x1003;
    damages[3] = 7;
    var t: TtsBlocks = .{
        .sx = 2,
        .sy = 1,
        .sz = 2,
        .types = types,
        .damage = damages,
        .allocator = allocator,
    };
    defer t.deinit();

    const Capture = struct {
        hits: [4]struct { wx: i32, wy: i32, wz: i32, dmg: u16 } = undefined,
        n: usize = 0,
        fn put(ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, _: u32, _: u64, _: ?u8, dmg: u16) void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.hits[c.n] = .{ .wx = wx, .wy = wy, .wz = wz, .dmg = dmg };
            c.n += 1;
        }
    };
    var cap = Capture{};
    paintDecoration(&t, 10, 50, 20, 0, 0, 0, 0, null, null, Capture.put, &cap);
    try std.testing.expectEqual(@as(usize, 3), cap.n); // air cell skipped
    try std.testing.expectEqual(@as(i32, 10), cap.hits[0].wx);
    try std.testing.expectEqual(@as(i32, 50), cap.hits[0].wy);
    try std.testing.expectEqual(@as(i32, 20), cap.hits[0].wz);
    try std.testing.expectEqual(@as(u16, 250), cap.hits[0].dmg);
    try std.testing.expectEqual(@as(u16, 0), cap.hits[1].dmg);
    try std.testing.expectEqual(@as(u16, 7), cap.hits[2].dmg);
    try std.testing.expectEqual(@as(i32, 11), cap.hits[2].wx); // cell 3 at (1,0,1)
    try std.testing.expectEqual(@as(i32, 50), cap.hits[2].wy);
    try std.testing.expectEqual(@as(i32, 21), cap.hits[2].wz);
}
