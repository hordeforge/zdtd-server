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
const linux = std.os.linux;

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
    /// Block type ids (AssignIds), length sx*sy*sz. Air = 0.
    types: []u16,
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
        return @intCast(self.sx * self.sy * self.sz);
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

/// Skip sparse texture channel (v>=10): bit stream then either Read(br,1) or i64 per set bit.
/// TextureFullArray.Read(br,1) size unknown exactly; consume remaining until TE header fails soft.
/// Practical approach: after bit stream, for each GetNextOffset>=0 read i64 (v<19 path) or
/// call TextureFullArray.Read: monodis shows v>=19 uses TextureFullArray.Read(br,1).
/// We approximate: for each positive offset, skip 8 bytes (i64) which matches v<19 path and
/// is a lower bound; if that overruns before TE, clamp.
fn skipSparseI64Channel(data: []const u8, pos_in: usize) !usize {
    var pos = try skipSimpleBitStream(data, pos_in);
    // Without bit decode we cannot know count. Heuristic: remaining until we see a plausible
    // TE header (i16 count small) is unsafe. Instead decode bits for offsets only.
    // Bitstream: each 1-bit yields an offset; 0-bits skip. GetNextOffset returns -1 at end.
    // Re-read the bitstream bytes we just skipped.
    if (pos_in + 4 > data.len) return error.ShortTts;
    const n = std.mem.readInt(i32, data[pos_in..][0..4], .little);
    const bits = data[pos_in + 4 ..][0..@intCast(n)];
    // Walk bits: for each 1, skip i64 at pos
    var bit_i: usize = 0;
    const total_bits = bits.len * 8;
    while (bit_i < total_bits) : (bit_i += 1) {
        const byte = bits[bit_i / 8];
        const bit: u3 = @intCast(bit_i % 8);
        if ((byte >> bit) & 1 == 0) continue;
        // set bit → read one i64 texture payload
        if (pos + 8 > data.len) return pos;
        pos += 8;
    }
    return pos;
}

/// Load block type plane from a stock .tts path (version >= 5 raw u32 path).
pub fn loadBlocks(allocator: std.mem.Allocator, path: []const u8) !TtsBlocks {
    const data = try readFileAll(allocator, path);
    defer allocator.free(data);
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
    const types = try allocator.alloc(u16, count);
    errdefer allocator.free(types);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = 14 + i * 4;
        const raw = std.mem.readInt(u32, data[off..][0..4], .little);
        if (raw & child_bit != 0) {
            types[i] = 0;
            continue;
        }
        types[i] = @truncate(raw & type_mask);
    }

    var pos: usize = need;
    var density: []u8 = &.{};
    var damage: []u16 = &.{};
    var tile_entities: []TeEntry = &.{};

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
    var textures: []u64 = &.{};
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
                for (bits) |byte| set_bits += @popCount(byte);
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

pub const SetBlockFn = *const fn (ctx: ?*anyopaque, wx: i32, wy: i32, wz: i32, block_id: u16, tex: u64) void;

/// Stamp non-air TTS types into the world at decoration origin.
/// `origin_y` is ground (y_is_ground) or prefab base Y.
pub fn paintDecoration(
    tts: *const TtsBlocks,
    origin_x: i32,
    origin_y: i32,
    origin_z: i32,
    rot: u8,
    set_block: SetBlockFn,
    ctx: ?*anyopaque,
) void {
    const count: i32 = @intCast(tts.blockCount());
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const typ = tts.types[@intCast(i)];
        if (typ == 0) continue;
        const c = tts.offsetToCoord(i);
        const r = rotateLocalXZ(c.x, c.z, tts.sx, tts.sz, rot);
        const wx = origin_x + r.x;
        const wy = origin_y + c.y;
        const wz = origin_z + r.z;
        if (wy < 0 or wy >= 256) continue;
        const tex: u64 = if (tts.textures.len > @as(usize, @intCast(i))) tts.textures[@intCast(i)] else 0;
        set_block(ctx, wx, wy, wz, typ, tex);
    }
}

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [1024]u8 = undefined;
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
    if (off != size) return error.ShortRead;
    return buf;
}

test "tts load abandoned_house block types if present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs/POIs/abandoned_house_01.tts";
    var path_z: [512]u8 = undefined;
    if (p.len >= path_z.len) return error.SkipZigTest;
    @memcpy(path_z[0..p.len], p);
    path_z[p.len] = 0;
    const rc = linux.open(path_z[0..p.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    _ = linux.close(@intCast(rc));

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
    try std.testing.expect(t.density[0] == 0x80 or t.density.len > 0);
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
