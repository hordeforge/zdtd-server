//! Chunk wire tests: encode, density, stability.
//!
//! Split out of wire/stock_chunk.zig (same tests, moved verbatim).

const std = @import("std");
const stock_chunk = @import("stock_chunk.zig");
const EncodeOpts = stock_chunk.EncodeOpts;
const blockType = stock_chunk.blockType;
const cells_per_layer = stock_chunk.cells_per_layer;
const defaultBlockAt = stock_chunk.defaultBlockAt;
const dominantOf = stock_chunk.dominantOf;
const layerCell = stock_chunk.layerCell;
const writeDensityChannel = stock_chunk.writeDensityChannel;
const binary = @import("binary.zig");
const buildNetPackageChunkNew = stock_chunk.buildNetPackageChunkNew;
const densityForBlock = stock_chunk.densityForBlock;
const density_air = stock_chunk.density_air;
const density_terrain = stock_chunk.density_terrain;
const encodeNetworkChunk = stock_chunk.encodeNetworkChunk;
const fillDefaultRawsFromHeights = stock_chunk.fillDefaultRawsFromHeights;
const fillWaterMassFromRaws = stock_chunk.fillWaterMassFromRaws;
const layerAnyNonAirU32 = stock_chunk.layerAnyNonAirU32;
const layerIsUniformU32 = stock_chunk.layerIsUniformU32;
const layerIsUniformU8 = stock_chunk.layerIsUniformU8;
const layerNeedsUpperU32 = stock_chunk.layerNeedsUpperU32;
const packDensityFromRaws = stock_chunk.packDensityFromRaws;
const packLowerU8 = stock_chunk.packLowerU8;
const packTexturePlane = stock_chunk.packTexturePlane;
const packU16Plane = stock_chunk.packU16Plane;
const packUpper24 = stock_chunk.packUpper24;
const stock_air = stock_chunk.stock_air;
const stock_dens_set_bytes = stock_chunk.stock_dens_set_bytes;
const stock_plane_cells = stock_chunk.stock_plane_cells;
const stock_terr_bedrock = stock_chunk.stock_terr_bedrock;
const stock_terr_dirt = stock_chunk.stock_terr_dirt;
const stock_terr_stone = stock_chunk.stock_terr_stone;
const water_mass_full = stock_chunk.water_mass_full;

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
    // Payload starts with cx, cy, cz. All three are read here, with distinct
    // values, because only cx was asserted before: cy and cz could swap and
    // nothing noticed, which is the one defect a positional header is prone
    // to. cy is 0 for a surface chunk (chunk Y band), cz is the caller's.
    try std.testing.expectEqual(@as(i32, -18), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[9..13], .little));
    try std.testing.expectEqual(@as(i32, 28), std.mem.readInt(i32, body[13..17], .little));
}

test "a uniform non-air layer writes the presence bool before the shared value" {
    // Wire-order audit: the uniform-layer branch writes `false` (no lower
    // array) then the shared value's low byte. The audit reported the pair as a
    // survivor because the all-air case has both bytes at 0, so no test could
    // tell them apart. A uniform SOLID layer makes them differ (0 vs the block
    // id), and swapping them tells the client a 1024-byte lower array follows,
    // which desyncs the whole layer walk. This pins the order on a uniform
    // bedrock layer where the two bytes are 0 and the bedrock id.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u32 {
            return if (y < 4) stock_terr_bedrock else stock_air;
        }
    };
    var heights: [256]u8 = .{0} ** 256;
    var raw: [524288]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
    });
    // Header is cx | cy | cz (i32 x3) | ticks (u64) = 20 bytes; layer 0 then
    // records its presence bool, the uniform flag and the shared value.
    try std.testing.expectEqual(@as(u8, 1), payload[20]); // layer has solid cells
    try std.testing.expectEqual(@as(u8, 0), payload[21]); // no lower array (uniform)
    try std.testing.expectEqual(@as(u8, stock_terr_bedrock), payload[22]); // shared value
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

test "stock chunk per-cell biome changes wire and is deterministic" {
    var heights: [256]u8 = .{60} ** 256;
    // Separate buffers: encodeNetworkChunk returns a slice into its caller
    // buffer, so sharing one buffer would alias later writes over earlier views.
    var buf_a: [65536]u8 = undefined;
    var buf_b: [65536]u8 = undefined;
    var buf_c: [65536]u8 = undefined;
    const Ctx = struct {
        fn at(_: ?*anyopaque, wx: i32, wz: i32) u8 {
            return @intCast(@mod(wx + wz, 3));
        }
    };
    const body = try encodeNetworkChunk(&buf_a, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome_at = Ctx.at,
        .biome_ctx = null,
    });
    const uniform = try encodeNetworkChunk(&buf_b, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
    });
    // Per-cell values 0/1/2 must differ from the uniform single-biome wire.
    try std.testing.expect(!std.mem.eql(u8, body, uniform));
    // A constant per-cell provider must be byte-identical to the uniform encode
    // (same cells, same intensities, same dominant).
    const ConstCtx = struct {
        fn at(_: ?*anyopaque, _: i32, _: i32) u8 {
            return 3;
        }
    };
    const const_body = try encodeNetworkChunk(&buf_c, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome_at = ConstCtx.at,
        .biome_ctx = null,
    });
    try std.testing.expect(std.mem.eql(u8, const_body, uniform));
}

test "dominantOf picks most common biome id with first-max ties" {
    var biomes: [256]u8 = .{1} ** 256;
    @memset(biomes[240..], 5);
    try std.testing.expectEqual(@as(u8, 1), dominantOf(&biomes, 3));
    var all_zero: [256]u8 = .{0} ** 256;
    try std.testing.expectEqual(@as(u8, 0), dominantOf(&all_zero, 3));
    var tie: [256]u8 = .{0} ** 256;
    @memset(tie[128..], 9); // 128×0, 128×9: first maximum (0) wins
    try std.testing.expectEqual(@as(u8, 0), dominantOf(&tie, 3));
}

test "stock chunk emits per-block textureFull for painted blocks" {
    // A painted woodShapes block (id 259, textureFull 0x61) must appear in the
    // texture channel as bytes 0x61,0,0,0,0,0 (low 6 bytes LE), not zero.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u32 {
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

test "stock chunk water channel carries full mass for water cells" {
    // A water block at (1,66,3) (band 16) must switch that band from the
    // same-value 3 bytes to presence 0 + two u16 byte-planes, with the full
    // static mass (19500 = 0x4C2C) at the water cell.
    const Ctx = struct {
        fn at(_: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
            if (lx == 1 and y == 66 and lz == 3) return 240; // water
            if (y == 0) return stock_terr_bedrock;
            if (y <= 60) return 1; // stone
            return stock_air;
        }
    };
    var heights: [256]u8 = .{60} ** 256;
    var raw_w: [524288]u8 = undefined;
    var raw_d: [524288]u8 = undefined;
    const water = try encodeNetworkChunk(&raw_w, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = null,
        .water_block_id = 240,
    });
    const dry = try encodeNetworkChunk(&raw_d, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = null,
    });
    // One band (16) switches from 3 same-value bytes to 1 + 2*1024 full bytes
    // (a layer has cells_per_layer = 1024 cells; planes are 1024 bytes each).
    try std.testing.expectEqual(dry.len + 2046, water.len);
    // The dry water channel is 64 same-value layers of 3 bytes, preceded by the
    // identical prefix and followed by the 15-byte const tail.
    const wch = dry.len - 64 * 3 - 15;
    const band16 = wch + 16 * 3;
    try std.testing.expectEqual(@as(u8, 0), water[band16]); // presence: full
    const cell = layerCell(1, 2, 3);
    try std.testing.expectEqual(@as(u8, 0x2C), water[band16 + 1 + cell]); // lo plane
    try std.testing.expectEqual(@as(u8, 0x4C), water[band16 + 1 + 1024 + cell]); // hi plane
    // Bands 0..15 stay same-value 0.
    try std.testing.expectEqual(@as(u8, 1), water[wch + 15 * 3]);
}

test "stock chunk emits upper24 for construction ids >= 256" {
    // A block_at that returns a construction id (1000) at the surface must produce
    // the upper24 array so the client reconstructs id 1000, not 1000 & 0xFF = 232.
    const Ctx = struct {
        fn at(_: ?*anyopaque, _: i32, y: i32, _: i32) u32 {
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

    // A uniform density layer is a presence marker of 1 followed by the shared
    // value, and only the payload length was ever asserted: swapping those two
    // bytes went unnoticed. Drive the channel directly rather than scanning the
    // body for the pair - other channels emit the same two bytes for their own
    // reasons, so a scan finds a hit either way and proves nothing.
    {
        var chan_buf: [4096]u8 = undefined;
        var cw: binary.Writer = .{ .buf = &chan_buf };
        // heights 60 puts terrain in the lower layers, so walk the channel and
        // check the uniform ones: layer 16 and up are entirely above the
        // surface, hence uniform air.
        try writeDensityChannel(&cw, .{ .cx = 0, .cz = 0, .heights = &heights });
        const chan = cw.written();
        var off: usize = 0;
        var layer: usize = 0;
        var air_layers: usize = 0;
        while (layer < 64) : (layer += 1) {
            const presence = chan[off];
            off += 1;
            if (presence == 1) {
                // Uniform: one shared value follows. Above the surface that
                // value is air, and it differs from the marker, so a swap of
                // the two moves 127 into the presence slot.
                if (layer >= 16) {
                    try std.testing.expectEqual(density_air, chan[off]);
                    air_layers += 1;
                }
                off += 1;
            } else {
                try std.testing.expectEqual(@as(u8, 0), presence);
                off += cells_per_layer;
            }
        }
        try std.testing.expectEqual(off, chan.len);
        try std.testing.expect(air_layers >= 48);
    }
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
    // One intensity run per column: a 16x16 chunk has exactly 256, and the
    // encoder writes every one. Measured 2026-09-04. The bound used to be
    // ">= 200 // ~256 columns", which would have passed with 56 columns
    // missing from the biome-intensity plane.
    try std.testing.expectEqual(@as(usize, 256), hits);
    // Density bytes: both terrain 0x80 and air 127 must appear (mixed surface).
    var has_t = false;
    var has_a = false;
    for (payload) |b| {
        if (b == density_terrain) has_t = true;
        if (b == density_air) has_a = true;
    }
    try std.testing.expect(has_t and has_a);
}

test "topsoil bitfield rides the chunk wire (stock m_bTopSoilBroken)" {
    // The maps region (heightmap 256, terrain heights 256, then the 32
    // topsoil bytes) follows the variable-length block layers. With every
    // column at height 60, the maps region is a 512-byte run of 0x3C (60)
    // followed by the topsoil: locate that run (block lower8 ids are small,
    // never 60) and verify the 32 bytes after it match the chunk state while
    // the rest of the payload is byte-identical.
    const find512 = struct {
        fn f(payload: []const u8) ?usize {
            if (payload.len < 544) return null;
            var i: usize = 0;
            while (i + 544 <= payload.len) : (i += 1) {
                var j: usize = 0;
                while (j < 512 and payload[i + j] == 60) : (j += 1) {}
                if (j == 512) return i;
            }
            return null;
        }
    }.f;
    var heights: [256]u8 = .{60} ** 256;
    var buf: [131072]u8 = undefined;
    // Fresh world: the topsoil bytes after the maps run are clear
    // (splat-rendered).
    const fresh = try encodeNetworkChunk(&buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
    });
    const fresh_off = find512(fresh) orelse return error.TestUnexpectedResult;
    const fresh_top = fresh[fresh_off + 512 ..][0..32];
    for (fresh_top) |b| try std.testing.expectEqual(@as(u8, 0), b);
    // Disturbed columns (dig at (0,0) + columns 56..63): the same window now
    // carries the bitfield; everything else stays identical.
    var ts: [32]u8 = [_]u8{0} ** 32;
    ts[0] = 0x01;
    ts[7] = 0xFF;
    const dist = try encodeNetworkChunk(&buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
        .topsoil = &ts,
    });
    try std.testing.expectEqual(fresh.len, dist.len);
    const dist_off = find512(dist) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh_off, dist_off);
    try std.testing.expectEqualSlices(u8, fresh[0..fresh_off], dist[0..dist_off]);
    try std.testing.expectEqualSlices(u8, ts[0..], dist[dist_off + 512 ..][0..32]);
    try std.testing.expectEqualSlices(u8, fresh[fresh_off + 544 ..], dist[dist_off + 544 ..]);
}

test "simd layerIsUniform and anyNonAir" {
    var u8s: [1024]u8 = .{7} ** 1024;
    try std.testing.expect(layerIsUniformU8(&u8s));
    u8s[1000] = 8;
    try std.testing.expect(!layerIsUniformU8(&u8s));

    var raws: [1024]u32 = .{stock_air} ** 1024;
    try std.testing.expect(!layerAnyNonAirU32(&raws));
    try std.testing.expect(layerIsUniformU32(&raws));
    raws[17] = stock_terr_dirt;
    try std.testing.expect(layerAnyNonAirU32(&raws));
    try std.testing.expect(!layerIsUniformU32(&raws));
    try std.testing.expect(!layerNeedsUpperU32(&raws));
    raws[17] = 1000;
    try std.testing.expect(layerNeedsUpperU32(&raws));
}

test "fillDefaultRawsFromHeights SIMD matches defaultBlockAt" {
    var prng = std.Random.DefaultPrng.init(0xD3F4);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 32) : (trial += 1) {
        var heights: [256]u8 = undefined;
        for (&heights, 0..) |*h, i| {
            h.* = switch (i % 7) {
                0 => 0,
                1 => 1,
                2 => 3,
                3 => 60,
                4 => 255,
                else => rnd.int(u8),
            };
        }
        var plane: [stock_plane_cells]u32 = undefined;
        fillDefaultRawsFromHeights(&heights, &plane);
        var i: usize = 0;
        while (i < plane.len) : (i += 1) {
            const lx: i32 = @intCast(i % 16);
            const lz: i32 = @intCast((i / 16) % 16);
            const y: i32 = @intCast(i / 256);
            try std.testing.expectEqual(defaultBlockAt(&heights, lx, y, lz), plane[i]);
        }
    }
}

test "simd packLower and packTexturePlane match scalar" {
    var raws: [32]u32 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) raws[i] = @as(u32, @intCast(i * 17 + 0x01020300));
    var lower: [32]u8 = undefined;
    packLowerU8(&raws, &lower);
    i = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(raws[i])), lower[i]);
    }
    var vals: [32]u64 = undefined;
    i = 0;
    while (i < 32) : (i += 1) vals[i] = @as(u64, i) * 0x010203040506 + 0x99;
    var plane: [32]u8 = undefined;
    packTexturePlane(&vals, 2, &plane);
    i = 0;
    while (i < 32) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(vals[i] >> 16)), plane[i]);
    }
}

test "simd packUpper24 matches scalar interleave" {
    // Mix: terrain ids (no upper), construction ids >= 256, meta/rot bits.
    var raws: [40]u32 = undefined;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const t: u32 = switch (i % 4) {
            0 => @as(u32, stock_terr_dirt),
            1 => @as(u32, 259) | (@as(u32, 3) << 16),
            2 => @as(u32, 1000) | (@as(u32, 1) << 24),
            else => @as(u32, stock_terr_stone) | (@as(u32, 7) << 8),
        };
        raws[i] = t;
    }
    var upper: [40 * 3]u8 = undefined;
    packUpper24(&raws, &upper);
    i = 0;
    while (i < 40) : (i += 1) {
        const raw = raws[i];
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 8)), upper[i * 3 + 0]);
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 16)), upper[i * 3 + 1]);
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 24)), upper[i * 3 + 2]);
    }
    // Vector width 8 with a full band (cells_per_layer, multiple of 8).
    var band: [1024]u32 = undefined;
    var bi: usize = 0;
    while (bi < 1024) : (bi += 1) band[bi] = @as(u32, @intCast(bi * 7 + 1000)) | (@as(u32, 5) << 16);
    var band_upper: [1024 * 3]u8 = undefined;
    packUpper24(&band, &band_upper);
    bi = 0;
    while (bi < 1024) : (bi += 1) {
        const raw = band[bi];
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 8)), band_upper[bi * 3 + 0]);
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 16)), band_upper[bi * 3 + 1]);
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 24)), band_upper[bi * 3 + 2]);
    }
    // Odd tail length (not a multiple of 8): covers the scalar tail.
    var short: [13]u32 = undefined;
    var si: usize = 0;
    while (si < 13) : (si += 1) short[si] = @as(u32, @intCast(si * 31 + 300)) | (@as(u32, 2) << 24);
    var short_upper: [13 * 3]u8 = undefined;
    packUpper24(&short, &short_upper);
    si = 0;
    while (si < 13) : (si += 1) {
        const raw = short[si];
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 8)), short_upper[si * 3 + 0]);
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 16)), short_upper[si * 3 + 1]);
        try std.testing.expectEqual(@as(u8, @truncate(raw >> 24)), short_upper[si * 3 + 2]);
    }
}

test "dens_at always-null callback matches dens_at null encode (SIMD path)" {
    // chunk_fill.zig passes dens_at = null when the chunk has no densities
    // plane. This pins that the always-null-callback scalar density loop and
    // the SIMD packDensityFromRaws path produce identical wire bytes.
    var heights: [256]u8 = .{60} ** 256;
    var plane: [stock_plane_cells]u32 = undefined;
    var i: usize = 0;
    while (i < plane.len) : (i += 1) {
        const lx: i32 = @intCast(i % 16);
        const lz: i32 = @intCast((i / 16) % 16);
        const y: i32 = @intCast(i / 256);
        plane[i] = defaultBlockAt(&heights, lx, y, lz);
        if (y == 30 and lx == 2 and lz == 3) plane[i] = 259; // non-terrain solid
    }
    var buf_a: [131072]u8 = undefined;
    var buf_b: [131072]u8 = undefined;
    const via_null = try encodeNetworkChunk(&buf_a, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .raws = &plane,
        .dens_at = null,
    });
    const AlwaysNull = struct {
        fn dens(_: ?*anyopaque, _: i32, _: i32, _: i32) ?u8 {
            return null;
        }
    };
    const via_cb = try encodeNetworkChunk(&buf_b, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .raws = &plane,
        .dens_at = AlwaysNull.dens,
    });
    try std.testing.expectEqualSlices(u8, via_null, via_cb);
}

test "simd packDensityFromRaws matches densityForBlock" {
    // Mix: air, terrain band (1..239), construction id, high raw with rot bits.
    var raws: [1024]u32 = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        raws[i] = switch (i % 7) {
            0 => @as(u32, stock_air),
            1 => @as(u32, stock_terr_dirt),
            2 => @as(u32, stock_terr_stone),
            3 => 259, // non-terrain shape
            4 => 1000, // construction
            5 => @as(u32, stock_terr_bedrock) | (@as(u32, 3) << 16), // terrain + meta
            else => @as(u32, 500) | (@as(u32, 1) << 24),
        };
    }
    var dens: [1024]u8 = undefined;
    packDensityFromRaws(&raws, &dens);
    i = 0;
    while (i < 1024) : (i += 1) {
        try std.testing.expectEqual(densityForBlock(blockType(raws[i])), dens[i]);
    }
    // Tail length not a multiple of vector width.
    var short_raws: [11]u32 = .{ 0, 1, 100, 239, 240, 259, 1000, 0, 5, 300, 42 };
    var short_dens: [11]u8 = undefined;
    packDensityFromRaws(&short_raws, &short_dens);
    i = 0;
    while (i < 11) : (i += 1) {
        try std.testing.expectEqual(densityForBlock(blockType(short_raws[i])), short_dens[i]);
    }
}

test "simd packU16Plane and fillWaterMassFromRaws match scalar" {
    var vals: [1024]u16 = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) vals[i] = @as(u16, @intCast((i * 37 + 0x4C2C) & 0xffff));
    var lo: [1024]u8 = undefined;
    var hi: [1024]u8 = undefined;
    packU16Plane(&vals, 0, &lo);
    packU16Plane(&vals, 1, &hi);
    i = 0;
    while (i < 1024) : (i += 1) {
        try std.testing.expectEqual(@as(u8, @truncate(vals[i])), lo[i]);
        try std.testing.expectEqual(@as(u8, @truncate(vals[i] >> 8)), hi[i]);
    }

    const water_id: u16 = 240;
    var raws: [1024]u32 = .{0} ** 1024;
    raws[0] = water_id;
    raws[17] = @as(u32, water_id) | (@as(u32, 2) << 16);
    raws[1000] = 1; // stone
    var mass: [1024]u16 = undefined;
    const has = fillWaterMassFromRaws(&raws, water_id, &mass);
    try std.testing.expect(has);
    try std.testing.expectEqual(water_mass_full, mass[0]);
    try std.testing.expectEqual(water_mass_full, mass[17]);
    try std.testing.expectEqual(@as(u16, 0), mass[1000]);
    try std.testing.expectEqual(@as(u16, 0), mass[1]);
    // No water cells.
    @memset(&raws, 1);
    try std.testing.expect(!fillWaterMassFromRaws(&raws, water_id, &mass));
    try std.testing.expectEqual(@as(u16, 0), mass[0]);
}

test "simd density channel with dens_plane overlay matches dens_at scalar" {
    // POI path: raws + TTS dens_plane/dens_set must match dens_at callback bytes.
    var heights: [256]u8 = .{60} ** 256;
    var plane: [stock_plane_cells]u32 = undefined;
    var dens_plane: [stock_plane_cells]u8 = .{0} ** stock_plane_cells;
    var dens_set: [stock_dens_set_bytes]u8 = .{0} ** stock_dens_set_bytes;
    var i: usize = 0;
    while (i < plane.len) : (i += 1) {
        const lx: i32 = @intCast(i % 16);
        const lz: i32 = @intCast((i / 16) % 16);
        const y: i32 = @intCast(i / 256);
        plane[i] = defaultBlockAt(&heights, lx, y, lz);
        if (y == 30 and lx == 2 and lz == 3) plane[i] = 259;
    }
    // Paint a handful of cells with TTS densities that differ from raw defaults.
    const paints = [_]struct { lx: i32, y: i32, lz: i32, d: u8 }{
        .{ .lx = 1, .y = 40, .lz = 2, .d = 12 },
        .{ .lx = 5, .y = 41, .lz = 7, .d = 200 },
        .{ .lx = 0, .y = 0, .lz = 0, .d = 1 },
        .{ .lx = 15, .y = 255, .lz = 15, .d = 127 },
    };
    for (paints) |p| {
        const idx: usize = @intCast(p.lx + p.lz * 16 + p.y * 256);
        dens_plane[idx] = p.d;
        dens_set[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }
    const DensCtx = struct {
        dens: *const [stock_plane_cells]u8,
        set: *const [stock_dens_set_bytes]u8,
        fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) ?u8 {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            const idx: usize = @intCast(lx + lz * 16 + y * 256);
            const bit: u8 = @as(u8, 1) << @intCast(idx % 8);
            if (self.set[idx / 8] & bit == 0) return null;
            return self.dens[idx];
        }
    };
    var dctx: DensCtx = .{ .dens = &dens_plane, .set = &dens_set };
    var buf_a: [131072]u8 = undefined;
    var buf_b: [131072]u8 = undefined;
    const via_plane = try encodeNetworkChunk(&buf_a, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .raws = &plane,
        .dens_plane = &dens_plane,
        .dens_set = &dens_set,
        // dens_at also set: the SIMD+overlay path must still win and match.
        .dens_at = DensCtx.at,
        .block_ctx = &dctx,
    });
    const via_cb = try encodeNetworkChunk(&buf_b, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .raws = &plane,
        .dens_at = DensCtx.at,
        .block_ctx = &dctx,
    });
    try std.testing.expectEqualSlices(u8, via_cb, via_plane);
}

test "simd density channel with raws plane matches dens_at-less scalar encode" {
    // Full memoized raw plane: SIMD density path must match callback-only encode.
    var heights: [256]u8 = .{60} ** 256;
    var plane: [stock_plane_cells]u32 = undefined;
    var i: usize = 0;
    while (i < plane.len) : (i += 1) {
        const lx: i32 = @intCast(i % 16);
        const lz: i32 = @intCast((i / 16) % 16);
        const y: i32 = @intCast(i / 256);
        plane[i] = defaultBlockAt(&heights, lx, y, lz);
        // One non-terrain solid so density mix is not only terrain/air.
        if (y == 30 and lx == 2 and lz == 3) plane[i] = 259;
    }
    var buf_a: [131072]u8 = undefined;
    var buf_b: [131072]u8 = undefined;
    const with_plane = try encodeNetworkChunk(&buf_a, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .raws = &plane,
    });
    const Ctx = struct {
        plane: *const [stock_plane_cells]u32,
        fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            return self.plane[@intCast(lx + lz * 16 + y * 256)];
        }
    };
    var ctx: Ctx = .{ .plane = &plane };
    const via_cb = try encodeNetworkChunk(&buf_b, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .block_at = Ctx.at,
        .block_ctx = &ctx,
    });
    try std.testing.expectEqualSlices(u8, via_cb, with_plane);
}

test "raws_scratch memo reaches density channel (SIMD path)" {
    // raws_scratch alone must fill opts_memo.raws so density/water see the plane.
    var heights: [256]u8 = .{55} ** 256;
    var scratch: [stock_plane_cells]u32 = undefined;
    var buf_scratch: [131072]u8 = undefined;
    var buf_raws: [131072]u8 = undefined;
    const via_scratch = try encodeNetworkChunk(&buf_scratch, .{
        .cx = 1,
        .cz = -2,
        .heights = &heights,
        .raws_scratch = &scratch,
    });
    // Same content as an explicit plane fill with defaultBlockAt.
    var plane: [stock_plane_cells]u32 = undefined;
    var i: usize = 0;
    while (i < plane.len) : (i += 1) {
        const lx: i32 = @intCast(i % 16);
        const lz: i32 = @intCast((i / 16) % 16);
        const y: i32 = @intCast(i / 256);
        plane[i] = defaultBlockAt(&heights, lx, y, lz);
    }
    const via_raws = try encodeNetworkChunk(&buf_raws, .{
        .cx = 1,
        .cz = -2,
        .heights = &heights,
        .raws = &plane,
    });
    try std.testing.expectEqualSlices(u8, via_raws, via_scratch);
    // Scratch must have been filled (not left untouched).
    try std.testing.expect(scratch[0] == stock_terr_bedrock);
    try std.testing.expect(scratch[55 * 256] != stock_air);
}

test "simd encode matches mixed height chunk length class" {
    // Regression: SIMD pack path still produces valid mixed density payload.
    var heights: [256]u8 = .{60} ** 256;
    var raw: [131072]u8 = undefined;
    const payload = try encodeNetworkChunk(&raw, .{
        .cx = 0,
        .cz = 0,
        .heights = &heights,
        .biome = 3,
    });
    try std.testing.expect(payload.len > 1000);
    var has_t = false;
    var has_a = false;
    for (payload) |b| {
        if (b == density_terrain) has_t = true;
        if (b == density_air) has_a = true;
    }
    try std.testing.expect(has_t and has_a);
}
