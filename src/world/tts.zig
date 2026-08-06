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

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

pub const child_bit: u32 = 0x4000_0000;
pub const type_mask: u32 = 0xFFFF;

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
        const raw = std.mem.readInt(u32, data[off..][0..4], .little);
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
    var tile_entities: []TeEntry = &.{};
    // Free planes allocated mid-parse if a later step fails (OOM / TE list error).
    errdefer {
        if (density.len != 0) allocator.free(density);
        if (damage.len != 0) allocator.free(damage);
        if (textures.len != 0) allocator.free(textures);
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
                var set_bits: usize = 0;
                var bit_i: usize = 0;
                const total_bits = bits.len * 8;
                while (bit_i < total_bits and bit_i < count) : (bit_i += 1) {
                    const byte = bits[bit_i / 8];
                    const bit: u3 = @intCast(bit_i % 8);
                    if ((byte >> bit) & 1 != 0) set_bits += 1;
                }
                // WaterValue.Read = u16 mass
                const need_w = set_bits * 2;
                if (pos + need_w <= data.len) pos += need_w;
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

/// Rotate local XZ for prefab rotation 0..3 (matches common stock stamp: origin corner fixed).
pub fn rotateLocalXZ(x: i32, z: i32, sx: i32, sz: i32, rot: u8) struct { x: i32, z: i32 } {
    return switch (rot & 3) {
        0 => .{ .x = x, .z = z },
        1 => .{ .x = z, .z = sx - 1 - x },
        2 => .{ .x = sx - 1 - x, .z = sz - 1 - z },
        3 => .{ .x = sz - 1 - z, .z = x },
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
pub const SetBlockFn = *const fn (ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, raw: u32, tex: u64, dens: ?u8) void;

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
    set_block: SetBlockFn,
    ctx: ?*anyopaque,
) void {
    const assignids = @import("../assets/assignids_comptime.zig");
    const count: i32 = @intCast(tts.blockCount());
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const raw = tts.types[@intCast(i)];
        if (raw == 0) continue;
        const typ: u16 = @truncate(raw & type_mask);
        if (typ == assignids.terrain_filler or typ == assignids.terrain_filler_adaptive) continue;
        const c = tts.offsetToCoord(i);
        const r = rotateLocalXZ(c.x, c.z, tts.sx, tts.sz, rot);
        const wx = origin_x + r.x;
        const wy = origin_y + c.y;
        const wz = origin_z + r.z;
        if (wy < 0 or wy >= 256) continue;
        const tex: u64 = if (tts.textures.len > @as(usize, @intCast(i))) tts.textures[@intCast(i)] else 0;
        const dens: ?u8 = if (tts.density.len > @as(usize, @intCast(i))) tts.density[@intCast(i)] else null;
        set_block(ctx, wx, wy, wz, rotateRawY(raw, rot), tex, dens);
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
    if (!io_fs.fileExistsSimple(p)) return error.SkipZigTest;

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
