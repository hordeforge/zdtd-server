//! Shutdown ordering for Game: flush every store, then tear down subsystems.
//! Player persistence lives in server/persist.zig; callers go there directly.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const apm = @import("../../apm/root.zig");
const util_sim = @import("../../util/sim.zig");

pub fn deinit(self: *Game) void {
    const leave_sim = self.info_port == 0;
    self.savePlayers() catch |e| game_mod.logPersistErr(self, "save players", e);
    self.world.saveAll() catch |e| game_mod.logPersistErr(self, "save world", e);
    {
        const fs = apm.profiler.scope(&self.harness.prof, .save_flush_wait);
        defer fs.end();
        self.world.flushWait();
    }
    self.sampleFlushCounters();
    self.containers.save(self.world.world_dir, self.allocator) catch |e| game_mod.logPersistErr(self, "save containers", e);
    self.workstations.save(self.world.world_dir, self.allocator) catch |e| game_mod.logPersistErr(self, "save workstations", e);
    self.vending.save(self.world.world_dir) catch |e| game_mod.logPersistErr(self, "save vending", e);
    self.saveClaims() catch |e| game_mod.logPersistErr(self, "save claims", e);
    self.saveEntities() catch |e| game_mod.logPersistErr(self, "save entities", e);
    self.allies.save(self.world.world_dir, self.allocator) catch |e| game_mod.logPersistErr(self, "save allies", e);
    self.saveBlockMeta() catch |e| game_mod.logPersistErr(self, "save block meta", e);
    self.saveWeather() catch |e| game_mod.logPersistErr(self, "save weather", e);
    self.saveClock() catch |e| game_mod.logPersistErr(self, "save clock", e);
    self.land_claims_n = 0;
    self.plugins.shutdown();
    self.wasm_plugins.shutdown();
    deinitStores(self);
    self.admin.deinit();
    self.webui.deinit();
    self.info_tcp.stop();
    self.world.deinit();
    self.net.deinit();
    if (leave_sim) util_sim.disable();
}

/// Sim plus every asset store, in construction-reverse order. Shared by `deinit`
/// and the `createWithOptions` errdefer so a newly added store cannot be freed
/// on one path and leaked on the other.
pub fn deinitStores(self: *Game) void {
    self.sim.deinit();
    self.blocks.deinit();
    self.items.deinit();
    self.signs.deinit();
    self.entities.deinit();
    self.recipes.deinit();
    self.loot.deinit();
    self.entitygroups.deinit();
    self.gamestages.deinit();
    self.maxdamage.deinit();
    self.block_textures.deinit();
    self.painting.deinit();
    self.spawning.deinit();
    self.buffs.deinit();
    self.progression_table.deinit();
    self.vehicles.deinit();
    self.storage_pairs.deinit();
    self.biome_colors.deinit();
    self.traders.deinit();
    self.npc.deinit();
    self.sleepers.deinit();
}

pub fn refreshInfoPlayers(self: *Game) void {
    self.info_tcp.setPlayers(@intCast(self.countJoined()));
}
