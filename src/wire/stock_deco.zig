//! Stock NetPackageDecoUpdate + DecoObject wire (derived V3.0.1, live on V3.1.0 b14).
//! Client fixed-size worlds only show grass/trees from server deco packages
//! (client decorateChunkRandom is a no-op when bFixedSize).

const std = @import("std");
const binary = @import("binary.zig");

/// Runtime Block.blockID after AssignIds (bundled dump, comptime).
/// DecoObject requires BlockShapeDistantDeco (+ Model). plantShrub is ModelEntity only.
const assignids = @import("../assets/assignids_comptime.zig");
pub const plant_shrub: u32 = assignids.plant_shrub;
pub const tree_dead_pine_leaf: u32 = assignids.tree_dead_pine_leaf;
pub const tree_dead_02: u32 = assignids.tree_dead_02;
pub const tree_oak_sml: u32 = assignids.tree_oak_sml;
pub const tree_winter_evergreen: u32 = assignids.tree_winter_evergreen;

/// Storage / loot containers (same AssignIds dump).
pub const cnt_wooden_chest_closed: u32 = assignids.cnt_wooden_chest_closed;
pub const cnt_wooden_chest_open: u32 = assignids.cnt_wooden_chest_open;
pub const cnt_wood_writable_crate: u32 = assignids.cnt_wood_writable_crate;
pub const cnt_desk_safe: u32 = assignids.cnt_desk_safe;
pub const cnt_hardened_chest_insecure: u32 = assignids.cnt_hardened_chest_insecure;

/// DecoState.GeneratedActive. Forced: RestoreGeneratedDecos (asm.il ends 1258023)
/// deletes state 2 (Dynamic) decos on the DecoResetWorldChunk path.
pub const deco_state_active: u8 = 0;

/// On-wire DecoObject size: u64 pos + f32 realY + u32 rawData + u8 state
/// (DecoObject::Write, asm.il ends 1264030). NOT the stock
/// `NetPackageDecoUpdate.decoSize = 0x10` literal (asm.il 808289): that field is
/// declared and never referenced anywhere in the assembly, so it is a stale
/// estimate, not the record size.
pub const deco_size: usize = 17;

/// BlockValue rawData rotation band (bits 16..20, block-shapes.md). Same shift
/// deco_mirror uses for its multiblock child packing, so the mirror and the
/// client read the same rotation.
pub const deco_rot_shift: u5 = 16;
/// NetPackageDecoUpdate.decosPerPackage (asm.il 808291); Setup caps each package
/// at this many objects (`ldc.i4 0x8000` at Setup IL_000b).
pub const decos_per_package: usize = 0x8000;
/// zdtd per-package cap. Body is `objects_off + n*deco_size`; 4096 keeps one
/// package at ~68 KiB so it frames inside `Game.send_buf` (256 KiB) and stays in
/// the same fragment-count band as a stock chunk.
pub const zdtd_decos_per_package: usize = 4096;

/// Body offsets: firstPackage:bool | dataLen:i32 | count:i32 | objects.
pub const header_len: usize = 5;
pub const objects_off: usize = header_len + 4;

/// GameUtils.Vector3iToUInt64
pub fn vector3iToU64(x: i32, y: i32, z: i32) u64 {
    const xu: u64 = @as(u64, @intCast(@as(u32, @bitCast(x +% 32768)) & 0xFFFF));
    const yu: u64 = @as(u64, @intCast(@as(u32, @bitCast(y +% 32768)) & 0xFFFF));
    const zu: u64 = @as(u64, @intCast(@as(u32, @bitCast(z +% 32768)) & 0xFFFF));
    return (xu << 32) | (yu << 16) | zu;
}

pub const DecoObj = struct {
    x: i32,
    y: i32,
    z: i32,
    real_y: f32,
    block_raw: u32,
    state: u8 = deco_state_active,
};

pub fn writeDecoObject(w: *binary.Writer, o: DecoObj) !void {
    try w.writeU64(vector3iToU64(o.x, o.y, o.z));
    try w.writeF32(o.real_y);
    try w.writeU32(o.block_raw);
    try w.writeByte(o.state);
}

/// Bytes a DecoUpdate body needs for `n` objects.
pub fn decoUpdateLen(n: usize) usize {
    return objects_off + n * deco_size;
}

/// Patch the header of a DecoUpdate body whose objects were written in place at
/// `objects_off`. `end` is the writer position past the last object. Single
/// framing implementation: `buildDecoUpdate` and the streaming sender share it.
pub fn finishDecoUpdate(buf: []u8, first_package: bool, count: usize, end: usize) ![]u8 {
    if (count > decos_per_package) return error.TooManyDecos;
    if (buf.len < end or end < objects_off) return error.Overflow;
    // Illegal state: header count must describe exactly the bytes written.
    if (end - objects_off != count * deco_size) return error.Overflow;
    buf[0] = @intFromBool(first_package);
    std.mem.writeInt(i32, buf[1..5], @intCast(end - header_len), .little);
    std.mem.writeInt(i32, buf[5..9], @intCast(count), .little);
    return buf[0..end];
}

/// NetPackageDecoUpdate body: firstPackage:bool | dataLen:i32 | payload(count:i32 + objects).
pub fn buildDecoUpdate(buf: []u8, first_package: bool, objs: []const DecoObj) ![]u8 {
    if (objs.len > decos_per_package) return error.TooManyDecos;
    if (buf.len < decoUpdateLen(objs.len)) return error.Overflow;
    var w: binary.Writer = .{ .buf = buf, .pos = objects_off };
    for (objs) |o| try writeDecoObject(&w, o);
    return finishDecoUpdate(buf, first_package, objs.len, w.pos);
}

/// Streams DecoObjects into a caller-owned body buffer, cutting a new package
/// every `cap` objects. Mirrors stock `NetPackageDecoUpdate.Setup`, which is
/// called back to back until the write list is drained (`SendDecosToClient`,
/// asm.il 1263272): the first package carries `firstPackage=true` (the client
/// allocates `DecoManager.loadedDecos` only then), every continuation `false`.
///
/// Contract: the body returned by `take` aliases `buf`, so it must be sent
/// before the next `push`.
pub const PackageWriter = struct {
    buf: []u8,
    cap: usize,
    count: usize = 0,
    pos: usize = objects_off,
    /// Packages already handed out by `take`.
    sent: usize = 0,

    pub fn init(buf: []u8, cap: usize) !PackageWriter {
        if (cap == 0 or cap > decos_per_package) return error.TooManyDecos;
        if (buf.len < decoUpdateLen(cap)) return error.Overflow;
        return .{ .buf = buf, .cap = cap };
    }

    /// True when the current package is at capacity: `take` before pushing again.
    pub fn full(self: *const PackageWriter) bool {
        return self.count >= self.cap;
    }

    pub fn push(self: *PackageWriter, o: DecoObj) !void {
        if (self.full()) return error.TooManyDecos;
        var w: binary.Writer = .{ .buf = self.buf, .pos = self.pos };
        try writeDecoObject(&w, o);
        self.pos = w.pos;
        self.count += 1;
    }

    /// Finish the current package (possibly empty) and start the next one.
    pub fn take(self: *PackageWriter) ![]u8 {
        const body = try finishDecoUpdate(self.buf, self.sent == 0, self.count, self.pos);
        self.sent += 1;
        self.count = 0;
        self.pos = objects_off;
        return body;
    }
};

/// World cells per terrain chunk side.
pub const chunk_side: i32 = 16;

/// DecoChunk side in world cells (`ldc.i4 0x80` at `DecoManager::decorateChunkRandom`
/// IL_0032/IL_003a, asm.il 1265917).
pub const deco_chunk_side: i32 = 128;

/// Placement attempts per deco chunk (`ldc.i4 0x3e8` at IL_0259). Fixed, not a
/// density knob: density comes from the per-biome probabilities.
pub const attempts_per_deco_chunk: u32 = 1000;

/// One `<decoration type="block">` row that survived the `IsDistantDecoration`
/// filter, with its biomes.xml `prob` unscaled.
pub const Species = struct {
    block_id: u16,
    prob: f32,
};

/// Wire-side capacity for a biome's distant-deco list. Must not be smaller than
/// `assets/biome_layers.max_deco_per_biome`, which caps the same list on the
/// load side and carries the measurement justifying 16 (pine_forest's "Dense
/// large trees" subbiome has 14 surviving rows). The two are separate constants
/// because `wire` must not import `assets`; the server-side fill asserts they
/// agree.
pub const max_species: usize = 16;

/// A biome's distant-decoration list, in XML order. The sampler walks it last to
/// first, exactly like `decorateChunkRandom` walks `m_DistantDecoBlocks`
/// (asm.il 1266052-1266179).
pub const SpeciesList = struct {
    n: u8 = 0,
    items: [max_species]Species = undefined,

    pub fn slice(self: *const SpeciesList) []const Species {
        return self.items[0..self.n];
    }
};

/// World callbacks the sampler needs. `height_at` returns the surface block Y
/// (0 or out-of-range skips the cell, so an unreadable column places nothing).
/// `species_at` returns the biome's distant-deco list for a world XZ; an empty
/// list means the cell places nothing, never a fabricated fallback species.
pub const Sampler = struct {
    height_at: *const fn (ctx: ?*anyopaque, wx: i32, wz: i32) u16,
    species_at: *const fn (ctx: ?*anyopaque, wx: i32, wz: i32) SpeciesList,
    ctx: ?*anyopaque = null,
};

/// World XZ half-open rectangle the caller is willing to have decorated.
pub const Window = struct {
    x0: i32,
    z0: i32,
    x1: i32,
    z1: i32,

    pub fn contains(self: Window, wx: i32, wz: i32) bool {
        return wx >= self.x0 and wx < self.x1 and wz >= self.z0 and wz < self.z1;
    }
};

/// Per-deco-chunk occupancy, one bit per cell. Stands in for the stock
/// `DecoOccupiedMap`: `decorateChunkRandom` rejects a draw when `Get(x,z) > 2` or
/// when `CheckArea(x-2, z-2, 6, 5, 5)` finds anything (asm.il 1265997-1266006),
/// i.e. a 5x5 keep-out square anchored two cells back. zdtd tracks placement, not
/// the stock EnumDecoOccupied grades (they come from BigDecorationRadius, which
/// no server-side data carries), so the spacing is reproduced and the grading is
/// not. Deliberate: too-close trees look worse than slightly-too-sparse ones.
const Occupancy = struct {
    const side: usize = @intCast(deco_chunk_side);
    bits: [side * side / 8]u8 = @splat(0),

    fn idx(lx: i32, lz: i32) usize {
        return @as(usize, @intCast(lz)) * side + @as(usize, @intCast(lx));
    }

    fn get(self: *const Occupancy, lx: i32, lz: i32) bool {
        if (lx < 0 or lz < 0 or lx >= deco_chunk_side or lz >= deco_chunk_side) return false;
        const i = idx(lx, lz);
        return self.bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
    }

    fn set(self: *Occupancy, lx: i32, lz: i32) void {
        const i = idx(lx, lz);
        self.bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
    }

    /// Stock's `CheckArea(x - 2, z - 2, _, 5, 5)`.
    fn areaBusy(self: *const Occupancy, lx: i32, lz: i32) bool {
        var dz: i32 = 0;
        while (dz < 5) : (dz += 1) {
            var dx: i32 = 0;
            while (dx < 5) : (dx += 1) {
                if (self.get(lx - 2 + dx, lz - 2 + dz)) return true;
            }
        }
        return false;
    }
};

/// Deterministic replacement for stock's `GameRandom`. Stock reseeds per deco
/// chunk from the world seed; zdtd needs the same property (a chunk decorates the
/// same way on every join and on every restart) but not the same stream, since
/// GameRandom's algorithm is not reproduced anywhere in zdtd.
const Rng = struct {
    s: u64,

    fn init(seed: u64, dcx: i32, dcz: i32) Rng {
        var s = seed;
        s ^= @as(u64, @bitCast(@as(i64, dcx))) *% 0x9e3779b97f4a7c15;
        s ^= @as(u64, @bitCast(@as(i64, dcz))) *% 0xc2b2ae3d27d4eb4f;
        // A zero state would emit zeros forever.
        return .{ .s = if (s == 0) 0x853c49e6748fea9b else s };
    }

    fn next(self: *Rng) u64 {
        self.s +%= 0x9e3779b97f4a7c15;
        var z = self.s;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    /// Uniform in [lo, hi], matching `GameRandom::RandomRange(int, int)` bounds
    /// as `decorateChunkRandom` uses it: `RandomRange(x0, x1 - 1)`.
    fn range(self: *Rng, lo: i32, hi: i32) i32 {
        if (hi <= lo) return lo;
        const span: u64 = @intCast(hi - lo + 1);
        return lo + @as(i32, @intCast(self.next() % span));
    }

    /// Uniform in [0, 1), matching `GameRandom::RandomFloat`.
    fn float(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / 16777216.0;
    }
};

/// Deco chunk covering a world cell.
pub fn worldToDecoChunk(w: i32) i32 {
    return @divFloor(w, deco_chunk_side);
}

/// Decorate one 128x128 deco chunk, clipped to `window`.
///
/// Shape follows `DecoManager::decorateChunkRandom` (asm.il 1265917-1266235):
/// 1000 attempts, each drawing x in [cx*128, cx*128+127] and z likewise, rejected
/// by the occupancy keep-out, then walking the cell's biome species list last to
/// first and accepting the first whose roll satisfies
/// `RandomFloat <= prob * 0.125f * 16f` (IL_00f4-IL_010d). The accepted block
/// lands at `y = terrainHeight + 1` with `realY` equal to it (IL_0211-IL_021a).
///
/// Deviations, deliberate: no `GameUtils::CheckOreNoiseAt` gate (zdtd has no
/// server-side resource Perlin, and every `checkresource` row in stock biomes.xml
/// is a `type="prefab"` row we do not send anyway). Rotation follows stock
/// (`BiomeBlockDecoration::GetRandomRotation`, 0..3 in rawData bits 16..20), keyed
/// to the placement cell so every clipping window and the world mirror agree on
/// the rawData for a given cell.
pub fn generateForDecoChunk(
    out: []DecoObj,
    dcx: i32,
    dcz: i32,
    seed: u64,
    window: Window,
    sampler: Sampler,
) usize {
    var occ: Occupancy = .{};
    var rng: Rng = .init(seed, dcx, dcz);
    const wx0 = dcx * deco_chunk_side;
    const wz0 = dcz * deco_chunk_side;
    var n: usize = 0;
    var attempt: u32 = 0;
    while (attempt < attempts_per_deco_chunk) : (attempt += 1) {
        // Draw every attempt even when the output is full or the cell is out of
        // window, so clipping cannot change the placement of the cells we keep.
        const wx = rng.range(wx0, wx0 + deco_chunk_side - 1);
        const wz = rng.range(wz0, wz0 + deco_chunk_side - 1);
        const lx = wx - wx0;
        const lz = wz - wz0;
        // One roll per species slot, always drawn: stock rolls once per species it
        // walks, and drawing a fixed count keeps the stream (and therefore the
        // placement) independent of how long a given biome's list happens to be.
        var rolls: [max_species]f32 = undefined;
        for (&rolls) |*r| r.* = rng.float();
        if (occ.get(lx, lz) or occ.areaBusy(lx, lz)) continue;

        // Species resolution reads the static biome map, so it is safe outside the
        // window; the height lookup is not (it would generate chunks the join
        // never streams). Doing the roll and the occupancy mark first keeps the
        // layout independent of how big a window the caller asked for: the same
        // cell decorates the same way for a near and a far view radius.
        const list = sampler.species_at(sampler.ctx, wx, wz);
        var picked: ?Species = null;
        var i: usize = list.n;
        while (i > 0) {
            i -= 1;
            if (rolls[i] <= list.items[i].prob * 0.125 * 16.0) {
                picked = list.items[i];
                break;
            }
        }
        const sp = picked orelse continue;
        // Stock marks the occupied map before resolving terrain height too
        // (TryAddToOccupiedMap at IL_01ea, GetTerrainHeightAt at IL_01fa).
        occ.set(lx, lz);
        if (!window.contains(wx, wz)) continue;

        const h: i32 = sampler.height_at(sampler.ctx, wx, wz);
        if (h < 2 or h >= 250) continue;
        const by = h + 1;
        // Full output buffer must not change what the earlier objects were: a
        // later join with a bigger buffer decorates the chunk identically.
        if (n >= out.len) continue;
        // Stock rolls BiomeBlockDecoration::GetRandomRotation (0..3, 90 degree
        // steps) and packs it into BlockValue rawData bits 16..20
        // (block-shapes.md). The roll is keyed to the placement cell, not the
        // shared placement stream: a stream draw would shift with the number of
        // previously accepted cells, giving the same placement different
        // rotations in different clipping windows (the window-clipping test).
        // Position-keyed keeps every window and the world mirror in agreement on
        // the rawData for a given cell; the mirror reads the same bits, so a
        // rotated multiblock keeps its child-cell offsets consistent.
        var rot_rng: Rng = .init(seed, wx, wz);
        out[n] = .{
            .x = wx,
            .y = by,
            .z = wz,
            .real_y = @floatFromInt(by),
            .block_raw = sp.block_id | (@as(u32, @intCast(rot_rng.range(0, 3))) << deco_rot_shift),
        };
        n += 1;
    }
    return n;
}

/// WorldChunkCache.MakeChunkKey(x, z); packages.makeChunkKey aliases this.
/// Empirical, not IL-cited: the method is called from the dumps but its body
/// is in none of them, so this shift/mask is what a stock client accepts on
/// Chunk / ChunkRemove / DecoResetWorldChunk rather than a read layout.
/// docs/wire/WIRE_CHUNK.md "ChunkRemove" records what that evidence is worth.
pub fn makeChunkKey(cx: i32, cz: i32) i64 {
    const x = @as(i64, cx) & 0xFFFFFF;
    const z = @as(i64, cz) & 0xFFFFFF;
    return (z << 24) | x;
}

/// NetPackageDecoResetWorldChunk body: dataLen:i32 | chunkKey:i64 (WorldChunkCache key).
pub fn buildDecoResetWorldChunk(buf: []u8, cx: i32, cz: i32) ![]u8 {
    const key = makeChunkKey(cx, cz);
    if (buf.len < 12) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], 8, .little);
    std.mem.writeInt(i64, buf[4..12], key, .little);
    return buf[0..12];
}

