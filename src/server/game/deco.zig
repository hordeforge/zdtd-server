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

pub fn decoSpeciesAt(ctx: ?*anyopaque, wx: i32, wz: i32) packages.stock_deco.SpeciesList {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return .{}));
    const bm = g.world.biomes orelse return .{};
    const biome_id = bm.atWorld(wx, wz) orelse return .{};
    const subs = g.world.biome_layers_table.subBiomes(biome_id);
    var set = g.world.biome_layers_table.decosFor(biome_id);
    if (subs.len > 0) {
        const si = subbiome_noise.subBiomeIdx(&g.sub_noise, subs, wx, wz);
        if (si >= 0) set = subs[@intCast(si)].decos;
    }
    var out: packages.stock_deco.SpeciesList = .{};
    for (set.slice()) |d| {
        if (out.n >= packages.stock_deco.max_species) break;
        out.items[out.n] = .{ .block_id = d.block_id, .prob = d.prob };
        out.n += 1;
    }
    return out;
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
