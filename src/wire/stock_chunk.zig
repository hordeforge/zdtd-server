//! Stock V3.0.1 `Chunk.write(PooledBinaryWriter, bNetwork=true)` encoder.
//! Used as NetPackageChunk payload so the stock client can Chunk.read without
//! client-side generation. See research/docs/save-region.md and Chunk IL dumps.

const std = @import("std");
const binary = @import("binary.zig");

/// MarchingCubes cctor values (V3.0.1).
pub const density_air: u8 = 127; // sbyte 127
pub const density_terrain: u8 = 0x80; // sbyte -128

/// Stock terrain type ids from blocks.xml registration order (air first).
pub const stock_air: u16 = 0;
pub const stock_terr_stone: u16 = 1;
pub const stock_terr_bedrock: u16 = 4;
pub const stock_terr_dirt: u16 = 5;
pub const stock_terr_forest_ground: u16 = 7;
pub const stock_terr_topsoil: u16 = 13;

const layers_n: usize = 64;
const cells_per_layer: usize = 1024; // 16*16*4

/// Block id provider: (lx, y, lz) -> stock block type id.
pub const BlockAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u16;

/// Texture provider: (lx, y, lz) -> stock int64 textureFull (0 = unpainted).
/// Only the low 48 bits (6 bytes) are wired (chunk textures channel bpv=6).
pub const TexAtFn = *const fn (ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u64;

pub const EncodeOpts = struct {
    cx: i32,
    cy: i32 = 0,
    cz: i32,
    heights: *const [256]u8,
    ticks: u64 = 1,
    /// When null, fill dirt/stone/bedrock columns from heights using stock type ids.
    block_at: ?BlockAtFn = null,
    block_ctx: ?*anyopaque = null,
    /// Per-block textureFull provider (paint). Null → texture channel all-zero.
    /// Shares block_ctx (same chunk pointer).
    tex_at: ?TexAtFn = null,
    biome: u8 = 3, // pine forest-ish placeholder
};

fn texAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u64 {
    if (opts.tex_at) |f| return f(opts.block_ctx, lx, y, lz);
    return 0;
}

fn defaultBlockAt(heights: *const [256]u8, lx: i32, y: i32, lz: i32) u16 {
    if (y < 0 or y >= 256) return stock_air;
    const h = heights[@intCast(lx + lz * 16)];
    if (y > h) return stock_air;
    if (y == 0) return stock_terr_bedrock;
    if (y + 3 < h) return stock_terr_stone;
    if (y == h) return stock_terr_topsoil;
    if (y + 1 == h) return stock_terr_dirt;
    return stock_terr_dirt;
}

fn blockAt(opts: EncodeOpts, lx: i32, y: i32, lz: i32) u16 {
    if (opts.block_at) |f| return f(opts.block_ctx, lx, y, lz);
    return defaultBlockAt(opts.heights, lx, y, lz);
}

/// Layer cell index matching stock: x + z*16 + (y&3)*256 within a 4-high band.
fn layerCell(lx: i32, y_in_layer: i32, lz: i32) usize {
    return @intCast(lx + lz * 16 + y_in_layer * 256);
}

/// Write one same-value ChunkBlockChannel (all 64 layers null, sameValue filled).
fn writeChannelSame(w: *binary.Writer, bytes_per_val: usize, fill: []const u8) !void {
    // fill length must be bytes_per_val (one value repeated into sameValue slots by read path).
    // Encoder: presence bit 1 (null layer) + sameValue bytes per layer.
    var scratch: [256]u8 = undefined;
    var pos: usize = 0;
    var layer: usize = 0;
    while (layer < layers_n) : (layer += 1) {
        if (pos >= scratch.len) {
            try w.writeBytes(scratch[0..pos]);
            pos = 0;
        }
        scratch[pos] = 1; // layer is null → sameValue path
        pos += 1;
        var j: usize = 0;
        while (j < bytes_per_val) : (j += 1) {
            if (pos >= scratch.len) {
                try w.writeBytes(scratch[0..pos]);
                pos = 0;
            }
            const b = if (j < fill.len) fill[j] else 0;
            scratch[pos] = b;
            pos += 1;
        }
    }
    if (pos > 0) try w.writeBytes(scratch[0..pos]);
}

/// Encode network-mode Chunk.write body (no NetPackageChunk envelope).
pub fn encodeNetworkChunk(buf: []u8, opts: EncodeOpts) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };

    try w.writeI32(opts.cx);
    try w.writeI32(opts.cy);
    try w.writeI32(opts.cz);
    try w.writeU64(opts.ticks);

    // 64 block layers
    var layer_i: usize = 0;
    while (layer_i < layers_n) : (layer_i += 1) {
        const y0: i32 = @intCast(layer_i * 4);
        var any = false;
        var ly: i32 = 0;
        while (ly < 4) : (ly += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    if (blockAt(opts, lx, y0 + ly, lz) != stock_air) {
                        any = true;
                        break;
                    }
                }
                if (any) break;
            }
            if (any) break;
        }
        try w.writeBool(any);
        if (!any) continue;

        // Block ids are the full 32-bit BlockValue.rawData split lower8 + upper24
        // (ChunkBlockLayer.Read: lower8 same-value byte or 1024 array, then upper24
        // null or 3072 interleaved bytes = (id>>8, id>>16, id>>24) per cell).
        // Terrain ids < 256 need no upper24; construction/POI ids (256..25029) do,
        // else they truncate to a wrong (usually terrain) block and render as smooth
        // marching-cubes clay with no texture.
        var first: u16 = stock_air;
        var uniform = true;
        var have = false;
        var need_upper = false;
        var lower: [cells_per_layer]u8 = .{0} ** cells_per_layer;
        var upper: [cells_per_layer * 3]u8 = .{0} ** (cells_per_layer * 3);
        ly = 0;
        while (ly < 4) : (ly += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    const id = blockAt(opts, lx, y0 + ly, lz);
                    const cell = layerCell(lx, ly, lz);
                    lower[cell] = @truncate(id);
                    const id32: u32 = id;
                    upper[cell * 3 + 0] = @truncate(id32 >> 8);
                    upper[cell * 3 + 1] = @truncate(id32 >> 16);
                    upper[cell * 3 + 2] = @truncate(id32 >> 24);
                    if (id >= 256) need_upper = true;
                    if (!have) {
                        first = id;
                        have = true;
                    } else if (id != first) {
                        uniform = false;
                    }
                }
            }
        }
        if (uniform) {
            try w.writeBool(false); // no lower array → same value
            try w.writeByte(@truncate(first));
        } else {
            try w.writeBool(true);
            try w.writeBytes(&lower);
        }
        if (need_upper) {
            try w.writeBool(true); // upper24 present (ids ≥ 256)
            try w.writeBytes(&upper);
        } else {
            try w.writeBool(false); // upper24 null → all ids < 256
        }
    }

    // bNetwork=true: skip stability channel

    // heightmap 256
    try w.writeBytes(opts.heights);

    // terrain height 256 (same as surface for flat columns)
    try w.writeBytes(opts.heights);

    // topsoil broken: 32 bytes (bitfield)
    var topsoil: [32]u8 = .{0} ** 32;
    try w.writeBytes(&topsoil);

    // biomes 256
    var biomes: [256]u8 = .{opts.biome} ** 256;
    try w.writeBytes(&biomes);

    // biome intensities: 1536 bytes = BiomeIntensity[256], 6 bytes each interleaved:
    // biomeId0..3, intensity0and1 (lo nibble=i0), intensity2and3
    // Default stock full single-biome: id0=biome, intensity0and1=0x0F (i0=1).
    var intensities: [1536]u8 = .{0} ** 1536;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const o = i * 6;
        intensities[o] = opts.biome;
        intensities[o + 4] = 0x0F;
    }
    try w.writeBytes(&intensities);

    try w.writeByte(opts.biome); // DominantBiome
    try w.writeByte(opts.biome); // AreaMasterDominantBiome

    // custom data count (network filter): u16
    try w.writeU16(0);

    // normals 256 each
    var normals: [256]u8 = .{0} ** 256;
    // Y-up-ish neutral
    @memset(&normals, 127);
    try w.writeBytes(&normals); // X
    try w.writeBytes(&normals); // Y
    try w.writeBytes(&normals); // Z

    // density: solid below surface, air above (per-cell via full layers is heavy;
    // use same-value air for empty sky layers is handled by block presence).
    // Emit density channel as full per-layer data for bands that have solids, else same air.
    try writeDensityChannel(&w, opts);

    // light bpv=1 same 0 (stock default; client LightChunk recomputes)
    try writeChannelSame(&w, 1, &[_]u8{0});
    // damage bpv=2 same 0
    try writeChannelSame(&w, 2, &[_]u8{ 0, 0 });
    // textures[0] bpv=6 from Chunk ctor. Paint-driven shape blocks (woodShapes,
    // concreteShapes, …) take their face material from this channel; 0 renders as
    // a grey default. Emit per-block textureFull (low 6 bytes) from the world store.
    try writeTextureChannel(&w, opts);
    // water bpv=2 same 0
    try writeChannelSame(&w, 2, &[_]u8{ 0, 0 });

    try w.writeBool(false); // NeedsLightCalculation done

    // entity count 0
    try w.writeI32(0);
    // tile entity count 0
    try w.writeI32(0);

    // bHasSleeperVolume false (always written)
    try w.writeBool(false);

    // bNetwork skips sleeper/trigger volume lists; wall volumes always written
    // wall volume count as byte 0
    try w.writeByte(0);

    // bNetwork: write false instead of building insideDevices list? IL:
    // if (!bNetwork) write sleeper...; if (!bNetwork) write trigger...
    // wall volumes always
    // then if (bNetwork) Write(false) else new List... for something at IL_042B
    // IL_042B: ldarg.2 brfalse.s IL_0435
    // IL_042E: Write(false)  -- when bNetwork, write false then fall into insideDevices path? 
    // Actually when bNetwork true: Write(false) then still builds insideDevices from list.
    // Looking again IL_042B-0435:
    //   if (bNetwork) Write(false);
    //   new List... (always)
    // insideDevices count as i16 then entries
    try w.writeBool(false); // the network branch bool before insideDevices
    try w.writeI16(0); // insideDevices count

    try w.writeBool(false); // IsInternalBlocksCulled

    // bNetwork skips BlockTrigger list

    return w.written();
}

fn writeDensityChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    // ChunkBlockChannel bpv=1: per layer presence(1=null/sameValue, 0=full 1024).
    // Density must match block type or client mesh dies (repairchunkdensity / CGO=0).
    // Same-value only when entire 4-high band is uniform air or uniform terrain.
    var layer_i: usize = 0;
    while (layer_i < layers_n) : (layer_i += 1) {
        const y0: i32 = @intCast(layer_i * 4);
        var any_solid = false;
        var any_air = false;
        var dens: [cells_per_layer]u8 = undefined;
        var ly: i32 = 0;
        while (ly < 4) : (ly += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    const solid = blockAt(opts, lx, y0 + ly, lz) != stock_air;
                    if (solid) any_solid = true else any_air = true;
                    dens[layerCell(lx, ly, lz)] = if (solid) density_terrain else density_air;
                }
            }
        }
        if (any_solid and any_air) {
            try w.writeByte(0); // full layer data
            try w.writeBytes(&dens);
        } else {
            try w.writeByte(1); // null layer → sameValue
            try w.writeByte(if (any_solid) density_terrain else density_air);
        }
    }
}

/// Textures channel (ChunkBlockChannel bpv=6): per 4-high band, a presence byte
/// then either 6 same-value bytes (uniform band) or 6 byte-planes of 1024 bytes
/// (plane j = byte j of each cell's textureFull). Value = low 6 bytes of the
/// int64 textureFull, little-endian. Matches ChunkBlockChannel.Read.
fn writeTextureChannel(w: *binary.Writer, opts: EncodeOpts) !void {
    const bpv: usize = 6;
    var band: usize = 0;
    while (band < layers_n) : (band += 1) {
        const y0: i32 = @intCast(band * 4);
        var vals: [cells_per_layer]u64 = undefined;
        var uniform = true;
        var first: u64 = 0;
        var ly: i32 = 0;
        while (ly < 4) : (ly += 1) {
            var lz: i32 = 0;
            while (lz < 16) : (lz += 1) {
                var lx: i32 = 0;
                while (lx < 16) : (lx += 1) {
                    const cell = layerCell(lx, ly, lz);
                    const tf = texAt(opts, lx, y0 + ly, lz);
                    vals[cell] = tf;
                    if (cell == 0) {
                        first = tf;
                    } else if (tf != first) {
                        uniform = false;
                    }
                }
            }
        }
        if (uniform) {
            try w.writeByte(1); // presence: same-value band
            var j: usize = 0;
            while (j < bpv) : (j += 1) try w.writeByte(@truncate(first >> @intCast(j * 8)));
        } else {
            try w.writeByte(0); // presence: full byte-planes
            var j: usize = 0;
            while (j < bpv) : (j += 1) {
                var cell: usize = 0;
                while (cell < cells_per_layer) : (cell += 1) {
                    try w.writeByte(@truncate(vals[cell] >> @intCast(j * 8)));
                }
            }
        }
    }
}

/// NetPackageChunk body: overwrite=false + dataLen + stock Chunk.write payload.
/// First delivery must use overwrite=false so client allocates+reads during package.read.
pub fn buildNetPackageChunkNew(buf: []u8, opts: EncodeOpts) ![]u8 {
    // Reserve space: 1 + 4 + payload
    if (buf.len < 16) return error.Overflow;
    const payload = try encodeNetworkChunk(buf[5..], opts);
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false); // bOverwriteExisting = false (initial stream)
    try w.writeI32(@intCast(payload.len));
    // payload already written at buf[5..]; if writer started at 0 we need copy
    // encode wrote into buf[5..], so written starts at 5.
    const total = 5 + payload.len;
    if (total > buf.len) return error.Overflow;
    // Ensure bool/len prefix is at 0..5
    buf[0] = 0;
    std.mem.writeInt(i32, buf[1..5], @intCast(payload.len), .little);
    return buf[0..total];
}

test "stock chunk encodes non-empty terrain" {
    var heights: [256]u8 = .{60} ** 256;
    var buf: [65536]u8 = undefined;
    const body = try buildNetPackageChunkNew(&buf, .{
        .cx = -18,
        .cz = 28,
        .heights = &heights,
    });
    try std.testing.expect(body.len > 100);
    try std.testing.expectEqual(@as(u8, 0), body[0]); // not overwrite
    const plen = std.mem.readInt(i32, body[1..5], .little);
    try std.testing.expectEqual(@as(i32, @intCast(body.len - 5)), plen);
    // payload starts with cx,cy,cz
    const cx = std.mem.readInt(i32, body[5..9], .little);
    try std.testing.expectEqual(@as(i32, -18), cx);
}

test "stock chunk empty sky is smaller" {
    var heights: [256]u8 = .{0} ** 256;
    var buf: [65536]u8 = undefined;
    const body = try buildNetPackageChunkNew(&buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
    });
    // Only bedrock at y=0 so one layer present.
    try std.testing.expect(body.len < 8000);
}

test "stock chunk emits per-block textureFull for painted blocks" {
    // A painted woodShapes block (id 259, textureFull 0x61) must appear in the
    // texture channel as bytes 0x61,0,0,0,0,0 (low 6 bytes LE), not zero.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u16 {
            return if (y == 0) stock_terr_bedrock else if (y <= 60) 259 else stock_air;
        }
        fn tex(_: ?*anyopaque, _: i32, y: i32, _: i32) u64 {
            return if (y >= 1 and y <= 60) 0x61 else 0;
        }
    };
    var heights: [256]u8 = .{60} ** 256;
    var raw: [524288]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .tex_at = Ctx.tex,
        .block_ctx = null,
    });
    // The wood value 0x61 must appear in the payload (texture channel), and a
    // chunk with no paint must not contain a spurious 0x61 texture band.
    var has_paint = false;
    for (payload) |b| {
        if (b == 0x61) has_paint = true;
    }
    try std.testing.expect(has_paint);

    const unpainted = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at, // same blocks, no tex_at
        .block_ctx = null,
    });
    // Texture channel is all-zero: same-value bands write 6 zero bytes each.
    // (Can't assert 0x61 absent globally since block ids may coincide; assert the
    // painted encoding is strictly larger due to a non-uniform texture band.)
    try std.testing.expect(payload.len > unpainted.len);
}

test "stock chunk emits upper24 for construction ids >= 256" {
    // A block_at that returns a construction id (1000) at the surface must produce
    // the upper24 array so the client reconstructs id 1000, not 1000 & 0xFF = 232.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u16 {
            return if (y == 0) stock_terr_bedrock else if (y <= 60) 1000 else stock_air;
        }
    };
    var heights: [256]u8 = .{60} ** 256;
    var raw: [262144]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = null,
    });
    // Reconstruct layer containing y=60 (layer 15): find lower byte 232 (=1000&0xFF)
    // paired with upper byte 3 (=1000>>8) somewhere. Simplest: the byte 0xE8 (232)
    // and 0x03 must both appear in the block-layer region.
    var has_low = false;
    var has_up = false;
    for (payload) |b| {
        if (b == 0xE8) has_low = true; // 1000 & 0xFF
        if (b == 0x03) has_up = true; //  1000 >> 8
    }
    try std.testing.expect(has_low and has_up);
}

test "stock chunk surface density mixed band has both values" {
    // Height 60 → layer 15 (y 60..63) is mixed solid/air; payload must exceed all-same path.
    var heights: [256]u8 = .{60} ** 256;
    var buf: [131072]u8 = undefined;
    const body = try buildNetPackageChunkNew(&buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
    });
    // All-same density path = 64*(1+1)=128 density bytes; mixed surface adds ~1024.
    try std.testing.expect(body.len > 1000);
    // BiomeIntensity interleaved: first column biomeId0=3, intensity0and1=0x0F
    // Find intensities after maps is brittle; spot-check encodeNetworkChunk maps instead.
    var raw: [131072]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 1,
        .cz = 2,
        .heights = &heights,
        .biome = 7,
    });
    // Scan for intensity plane: after biomes (256 of biome) comes 1536 intensities.
    // Search 6-byte pattern 07 00 00 00 0F 00 repeated near mid-payload.
    var hits: usize = 0;
    var off: usize = 0;
    while (off + 6 <= payload.len) : (off += 1) {
        if (payload[off] == 7 and payload[off + 1] == 0 and payload[off + 2] == 0 and
            payload[off + 3] == 0 and payload[off + 4] == 0x0F and payload[off + 5] == 0)
        {
            hits += 1;
            off += 5;
        }
    }
    try std.testing.expect(hits >= 200); // ~256 columns
    // Density bytes: both terrain 0x80 and air 127 must appear (mixed surface).
    var has_t = false;
    var has_a = false;
    for (payload) |b| {
        if (b == density_terrain) has_t = true;
        if (b == density_air) has_a = true;
    }
    try std.testing.expect(has_t and has_a);
}
