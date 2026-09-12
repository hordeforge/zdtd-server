//! Deco helpers extracted verbatim from game.zig (purest game.zig shard).
//! Species resolution, multiblock dim cache, mirror into block store.
//! Delegated from Game via thin forwarders in game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const subbiome_noise = @import("../../world/subbiome_noise.zig");
const deco_mirror = @import("../../world/deco_mirror.zig");
const world_store = @import("../../world/store.zig");
const biome_layers = @import("../../assets/biome_layers.zig");
const prefabs = @import("../../world/prefabs.zig");

/// `stock_deco` height callback over the live chunk store. Unreadable columns
/// return 0, which the sampler skips (fail closed, no fabricated deco).
pub fn decoHeightAt(ctx: ?*anyopaque, wx: i32, wz: i32) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return 0));
    return g.world.heightWorld(wx, wz) catch 0;
}

/// Deco species source is available: biome deco lists from biomes.xml, plus
/// either the biomemap (baked worlds) or the W3 proc biome field (proc worlds
/// carry no biomemap). Both are game-dir data; fail closed (a bare proc world
/// without biomes.xml stays bald rather than sending block ids the client
/// cannot resolve).
pub fn decoAvailable(g: *const Game) bool {
    if (!g.deco_trees or !g.world.biome_layers_table.hasDecos()) return false;
    if (g.world.terrain_source == .proc) return g.world.worldgen != null;
    return g.world.biomes != null;
}

/// `stock_deco` species callback: the biome under (wx,wz), then that biome's
/// distant-decoration list from biomes.xml, with the V3.2.0 `AllowDecorations`
/// gate on top (a cell inside a POI footprint that did not opt in samples
/// nothing). Fail closed at every step, since a block id the client cannot
/// resolve does not degrade, it throws inside the client world-load coroutine:
/// `DecoManager.addLoadedDecoration` → `TryAddToOccupiedMap` derefs
/// `Block::isMultiBlock` with no null check (asm.il 1262497), and
/// `DecoChunk.UpdateModels` looks the model up by name, which is null for a
/// null Block. Both leave the player stuck loading, which is worse than no
/// trees.
pub fn decoSpeciesAt(ctx: ?*anyopaque, wx: i32, wz: i32) packages.stock_deco.SpeciesList {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return .{}));
    if (decoSuppressedAt(g, wx, wz)) return .{};
    // Proc worlds carry no biomemap: resolve the biome from the W3 proc biome
    // field (the same field that drives the surface fill and the chunk wire
    // biome), mapped through the biome_layers_table exactly like procBiomeAt.
    const biome_id: u8 = if (g.world.terrain_source == .proc) blk: {
        if (g.world.worldgen) |*wg| {
            break :blk g.world.biome_layers_table.biomeIdAt(wg.biomeAt(@floatFromInt(wx), @floatFromInt(wz)));
        }
        break :blk 0;
    } else if (g.world.biomes) |*bm| (bm.atWorld(wx, wz) orelse return .{}) else return .{};
    // GAP 18: resolve the subbiome per cell (stock decorateChunkRandom ->
    // GetBiomeOrSubAt). A subbiome hit samples its own list, where the tree
    // probability mass lives; otherwise the biome's own list applies.
    const subs = g.world.biome_layers_table.subBiomes(biome_id);
    var set = g.world.biome_layers_table.decosFor(biome_id);
    if (subs.len > 0) {
        const si = subbiome_noise.subBiomeIdx(&g.sub_noise, subs, wx, wz);
        if (si >= 0) set = subs[@intCast(si)].decos;
    }
    // The load-side cap and the wire-side capacity are independent constants in
    // layers that cannot import each other. If the wire side were the smaller
    // of the two, this loop would silently drop deco the loader had accepted.
    comptime std.debug.assert(packages.stock_deco.max_species >=
        biome_layers.max_deco_per_biome);
    var out: packages.stock_deco.SpeciesList = .{};
    for (set.slice()) |d| {
        if (out.n >= packages.stock_deco.max_species) break;
        out.items[out.n] = .{ .block_id = d.block_id, .prob = d.prob };
        out.n += 1;
    }
    return out;
}

/// How many suppressing POI footprints one deco chunk's list holds, and how
/// many deco chunks are cached at once. The sampler walks one 128-block deco
/// chunk at a time (join burst and streamed chunk), so a small direct-mapped
/// set never thrashes; a dense city could exceed the rect cap, which is
/// counted (`saturated`) rather than silently truncating.
pub const max_suppress_rects: usize = 16;
pub const suppress_cache_slots: usize = 8;

/// Per-deco-chunk cache of the POI footprints that suppress world deco
/// (RFC 0007 Option B, realized lazily per deco chunk instead of an eager
/// per-chunk bitmap: an eager map would read every prefab XML at boot, while
/// this pays one decoration-list scan per sampled deco chunk and a few rect
/// tests per sample cell). Prefabs are load-fixed, so an entry never needs
/// invalidation.
pub const SuppressCache = struct {
    keys: [suppress_cache_slots]i64 = @splat(0),
    filled: [suppress_cache_slots]bool = @splat(false),
    n: [suppress_cache_slots]u8 = @splat(0),
    rects: [suppress_cache_slots][max_suppress_rects]prefabs.Rect = undefined,
    /// Deco chunks whose suppressing-POI count hit `max_suppress_rects`:
    /// suppression there is partial (the overflow is not suppressed), visible
    /// to the operator instead of assumed complete.
    saturated: u32 = 0,

    fn entry(self: *SuppressCache, g: *Game, dcx: i32, dcz: i32) []const prefabs.Rect {
        const key = packages.makeChunkKey(dcx, dcz);
        const slot: usize = @intCast(@mod(key, @as(i64, suppress_cache_slots)));
        if (self.filled[slot] and self.keys[slot] == key) {
            return self.rects[slot][0..self.n[slot]];
        }
        var count: usize = 0;
        if (g.world.prefabs) |*pf| {
            const side: i32 = packages.stock_deco.deco_chunk_side;
            count = pf.collectDecoSuppressors(
                dcx * side,
                dcz * side,
                (dcx + 1) * side,
                (dcz + 1) * side,
                self.rects[slot][0..],
            );
            if (count == max_suppress_rects) {
                self.saturated +%= 1;
                g.harness.counters.add(.deco_suppress_saturated, 1);
            }
        }
        self.keys[slot] = key;
        self.filled[slot] = true;
        self.n[slot] = @intCast(count);
        return self.rects[slot][0..self.n[slot]];
    }
};

/// True when (wx,wz) sits inside a POI footprint whose `AllowDecorations` is
/// not true, i.e. stock's world-deco suppression area (V3.2.0
/// changelog-3.2.0 §4.5). False when the world carries no prefab index: a flat
/// or proc test world has no POIs to suppress inside.
pub fn decoSuppressedAt(g: *Game, wx: i32, wz: i32) bool {
    if (g.world.prefabs == null) return false;
    const dcx = packages.stock_deco.worldToDecoChunk(wx);
    const dcz = packages.stock_deco.worldToDecoChunk(wz);
    const rects = g.deco_suppress.entry(g, dcx, dcz);
    for (rects) |r| {
        if (wx >= r.x0 and wx < r.x1 and wz >= r.z0 and wz < r.z1) return true;
    }
    return false;
}

pub const DecoDimCache = struct {
    const cap: usize = 32;
    ids: [cap]u16 = @splat(0),
    offsets: [cap]deco_mirror.Offsets = undefined,
    n: usize = 0,

    pub fn offsetsFor(self: *DecoDimCache, g: *const Game, id: u16) deco_mirror.Offsets {
        for (self.ids[0..self.n], self.offsets[0..self.n]) |cached_id, offs| {
            if (cached_id == id) return offs;
        }
        const offs = decoOffsetsFor(g, id);
        if (self.n < cap) {
            self.ids[self.n] = id;
            self.offsets[self.n] = offs;
            self.n += 1;
        }
        return offs;
    }
};

/// Cell offsets a decoration block occupies, from its blocks.xml `MultiBlockDim`.
pub fn decoOffsetsFor(self: *const Game, id: u16) deco_mirror.Offsets {
    var it = self.maxdamage.idNameIterator();
    while (it.next()) |e| {
        if (e.id != id) continue;
        const dim = self.maxdamage.multiBlockDim(e.name);
        return deco_mirror.offsetsFor(dim.x, dim.y, dim.z);
    }
    return .{};
}

/// Write one placed decoration into the block store so collision, harvest and
/// the streamed chunk payload agree with what the client renders.
pub fn mirrorDeco(self: *Game, cache: *DecoDimCache, o: packages.stock_deco.DecoObj) bool {
    const offsets = cache.offsetsFor(self, world_store.typeId(o.block_raw));
    if (offsets.n == 0) return false;
    const written = deco_mirror.apply(&self.world, .{
        .x = o.x,
        .y = o.y,
        .z = o.z,
        .raw = o.block_raw,
        .offsets = offsets,
    }) catch |err| {
        self.harness.counters.inc(.encode_errors);
        std.debug.print("zdtd: deco mirror failed at {d},{d},{d}: {s}\n", .{ o.x, o.y, o.z, @errorName(err) });
        return false;
    };
    return written > 0;
}
