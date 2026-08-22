//! Asset loading for Game.init — extracted verbatim from game.zig.
//! Takes *Game and InitOptions, mirrors the original inline sequence so the
//! wire/sim behaviour is byte-for-byte. Allocation happens here (init path only).

const std = @import("std");
const game_mod = @import("../game.zig");
const game_hooks = @import("hooks.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const biomes_mod = @import("../../world/biomes.zig");
const subbiome_noise = @import("../../world/subbiome_noise.zig");
const util_sim = @import("../../util/sim.zig");
const util_log = @import("../../util/log.zig");
const assets_quests = @import("../../assets/quests.zig");
const assets_blocks = @import("../../assets/blocks.zig");
const assets_items = @import("../../assets/items.zig");
const assets_signs = @import("../../assets/signs.zig");
const assets_entities = @import("../../assets/entities.zig");
const assets_recipes = @import("../../assets/recipes.zig");
const assets_loot = @import("../../assets/loot.zig");
const assets_entitygroups = @import("../../assets/entitygroups.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const assets_maxdamage = @import("../../assets/maxdamage.zig");
const assets_traders = @import("../../assets/traders.zig");
const assets_npc = @import("../../assets/npc.zig");
const assets_biome_layers = @import("../../assets/biome_layers.zig");
const assets_block_textures = @import("../../assets/block_textures.zig");
const assets_painting = @import("../../assets/painting.zig");
const assets_spawning = @import("../../assets/spawning.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const assets_progression = @import("../../assets/progression.zig");
const assets_vehicles = @import("../../assets/vehicles.zig");
const assets_storage_pairs = @import("../../assets/storage_pairs.zig");
const ecs = @import("../../ecs/root.zig");

/// Report a catalog load failure and fall back to the builtin table.
/// `tryLoad` returns null for "stock file absent" and an error for a real
/// parse/IO failure, so a bare `catch null` hides the second case: the server
/// then runs forever on builtin defaults while the operator believes the stock
/// XML is loaded. Mirrors the blocks/items loaders above.
fn logged(comptime what: []const u8, result: anytype) @typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| {
        util_log.err("zdtd: {s} load failed: {s}\n", .{ what, @errorName(err) });
        return null;
    };
}

pub fn loadAssets(self: *Game, allocator: std.mem.Allocator, opts: game_mod.InitOptions) !void {
    const assets_paths = @import("../../assets/paths.zig");
    assets_paths.setOverrideDirs(opts.config_overrides);
    if (opts.config_overrides.len > 0) {
        util_log.info("zdtd: config overrides dirs={d}\n", .{opts.config_overrides.len});
    }
    if (assets_quests.tryLoad(allocator, opts.game_dir, opts.map_dir, opts.config_dir, opts.quests_path, opts.quest_policy) catch |err| blk: {
        util_log.err("zdtd: quests catalog load failed: {s}\n", .{@errorName(err)});
        break :blk null;
    }) |cat| {
        self.sim.setCatalog(cat);
    }
    // AssignIds + blocks.xml properties first so later catalogs can resolve ids.
    if (assets_maxdamage.tryLoad(allocator, opts.game_dir, opts.config_dir) catch |err| blk: {
        util_log.err("zdtd: blocks/AssignIds load failed: {s}\n", .{@errorName(err)});
        break :blk null;
    }) |md| {
        self.maxdamage.deinit();
        self.maxdamage = md;
        self.maxdamage.tryMergeBundledAssignIds(allocator);
        self.maxdamage.resolveMaterialMaxDamage(allocator) catch |err| {
            util_log.err("zdtd: resolveMaterialMaxDamage failed: {s}\n", .{@errorName(err)});
        };
        if (self.world.prefabs) |*pf| {
            if (pf.prefabs_root.len > 0) {
                var nim_path: [2048]u8 = undefined;
                if (std.fmt.bufPrint(&nim_path, "{s}/POIs/abandoned_house_01.blocks.nim", .{pf.prefabs_root})) |p| {
                    self.maxdamage.mergeNim(allocator, p) catch |err| {
                        util_log.err("zdtd: mergeNim {s} failed: {s}\n", .{ p, @errorName(err) });
                    };
                } else |_| {}
            }
        }
        util_log.info("zdtd: maxdamage names={d} ids={d} assignids={d} storage={d}\n", .{
            self.maxdamage.by_name.count(),
            self.maxdamage.by_id.count(),
            self.maxdamage.id_by_name.count(),
            self.maxdamage.storage_ids.count(),
        });
    } else {
        self.maxdamage.tryMergeBundledAssignIds(allocator);
        util_log.info("zdtd: assignids-only names={d}\n", .{self.maxdamage.id_by_name.count()});
    }
    // A05: live terrain type ids from AssignIds (World.terrain_ids; pins remain offline defaults).
    {
        const TerrCtx = struct {
            t: *const assets_maxdamage.Table,
            fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                return self_t.t.idByName(name);
            }
        };
        var terr_ctx: TerrCtx = .{ .t = &self.maxdamage };
        self.world.resolveTerrainIds(TerrCtx.lookup, &terr_ctx);
    }
    // Prefab `.tts` type ids are indices into each POI's own
    // `<name>.blocks.nim`, not runtime block ids; remap them by name the way
    // stock does at Prefab::loadIdMapping (asm.il:928850). Installed before
    // the first chunk is generated so no POI is stamped with local ids.
    if (self.world.prefabs) |*pf| {
        const NimCtx = struct {
            fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                const t: *const assets_maxdamage.Table = @ptrCast(@alignCast(ctx.?));
                return t.idByName(name);
            }
            fn multiblock(ctx: ?*anyopaque, name: []const u8) assets_maxdamage.Dim {
                const t: *const assets_maxdamage.Table = @ptrCast(@alignCast(ctx.?));
                return t.multiBlockDim(name);
            }
        };
        if (self.maxdamage.id_by_name.count() > 0) {
            pf.setIdLookup(.{ .ctx = &self.maxdamage, .lookup = NimCtx.lookup, .multiblock = NimCtx.multiblock });
        } else {
            util_log.warn("zdtd: no AssignIds table, POI block ids stay prefab-local\n", .{});
        }
    }
    {
        const IdCtx = struct {
            t: *const assets_maxdamage.Table,
            fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                return self_t.t.idByName(name);
            }
        };
        var id_ctx: IdCtx = .{ .t = &self.maxdamage };
        if (assets_blocks.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, &id_ctx) catch |err| blk: {
            util_log.err("zdtd: block definitions load failed: {s}\n", .{@errorName(err)});
            break :blk null;
        }) |bt| {
            self.blocks.deinit();
            self.blocks = bt;
            util_log.info("zdtd: blocks defs={d}\n", .{self.blocks.defs.len});
        }
    }
    if (assets_items.tryLoad(allocator, opts.game_dir, opts.config_dir) catch |err| blk: {
        util_log.err("zdtd: item definitions load failed: {s}\n", .{@errorName(err)});
        break :blk null;
    }) |it| {
        self.items.deinit();
        self.items = it;
        util_log.info("zdtd: items source={s} defs={d} stock_names={d}\n", .{
            @tagName(self.items.source), self.items.defs.len, self.items.stock_names.len,
        });
        if (self.items.byStockName("foodCanChili")) |st| {
            const eid = self.items.ecsIdFromStockType(st);
            util_log.info("zdtd: foodCanChili stock={d} ecs={d} isEat={}\n", .{
                st, eid, self.items.isEat(eid),
            });
        }
    } else if (self.stock_catalogs_requested) {
        util_log.warn("zdtd: items.xml failed to load; item-dependent actions fail closed\n", .{});
    }
    if (logged("sign libraries", assets_signs.tryLoad(allocator, opts.game_dir))) |sc| {
        self.signs.deinit();
        self.signs = sc;
        util_log.info("zdtd: sign libraries entries={d}\n", .{self.signs.entries.len});
    }
    if (logged("entityclasses.xml", assets_entities.tryLoad(allocator, opts.game_dir, opts.config_dir))) |et| {
        self.entities.deinit();
        self.entities = et;
        // Push defaults into class_table for spawn helpers.
        const zdef = self.entities.defaultZombie();
        self.sim.setClassDef(1, .{
            .name = zdef.name,
            .max_hp = zdef.max_hp,
            .kind = .zombie,
            .hash = zdef.hash,
            .loot_list = zdef.loot_list,
            .drop_prob = zdef.loot_drop_prob,
            .chase_speed = zdef.chase_speed,
            .wander_speed = zdef.wander_speed,
            .attack_damage = self.handItemDamage(zdef.hand_item),
            .time_stay = zdef.time_stay,
            .sight_range = zdef.sight_range,
            .view_angle_deg = zdef.view_angle_deg,
            .explode_threshold = zdef.explode_threshold,
            .explode_delay_s = zdef.explode_delay_s,
            .ai_attack = zdef.ai_attack,
        });
        const adef = self.entities.defaultAnimal();
        self.sim.setClassDef(7, .{
            .name = adef.name,
            .max_hp = adef.max_hp,
            .kind = .animal,
            .hash = adef.hash,
            .loot_list = adef.loot_list,
            .drop_prob = adef.loot_drop_prob,
            .chase_speed = adef.chase_speed,
            .wander_speed = adef.wander_speed,
            .attack_damage = self.handItemDamage(adef.hand_item),
            .time_stay = adef.time_stay,
            .sight_range = adef.sight_range,
            .view_angle_deg = adef.view_angle_deg,
            .ai_attack = adef.ai_attack,
        });
        // (animals never explode; threshold stays 0)
        util_log.info("zdtd: entityclasses defs={d} zombie={s} hash={d}\n", .{
            self.entities.defs.len, zdef.name, zdef.hash,
        });
    }
    // Trader NPC: real class hash so the client renders EntityTrader. Runs
    // for the builtin table too (no game-dir), where the offline demo trader
    // still needs a renderable class; the XML def wins when a game-dir loads.
    if (self.entities.defaultTrader()) |tdef| {
        self.sim.setClassDef(3, .{
            .name = tdef.name,
            .max_hp = tdef.max_hp,
            .kind = .trader,
            .hash = tdef.hash,
            .loot_list = tdef.loot_list,
            .drop_prob = tdef.loot_drop_prob,
        });
    }
    if (logged("recipes.xml", assets_recipes.tryLoad(allocator, opts.game_dir, opts.config_dir))) |rt| {
        self.recipes.deinit();
        self.recipes = rt;
        util_log.info("zdtd: recipes defs={d}\n", .{self.recipes.defs.len});
    }
    if (logged("loot.xml", assets_loot.tryLoad(allocator, opts.game_dir, opts.config_dir))) |lt| {
        self.loot.deinit();
        self.loot = lt;
        util_log.info("zdtd: loot groups={d} containers={d}\n", .{ self.loot.groups.len, self.loot.containers.len });
    }
    self.loot.abundance_pct = opts.loot_abundance; // LootAbundance applies to builtin or xml table

    if (logged("entitygroups.xml", assets_entitygroups.tryLoad(allocator, opts.game_dir, opts.config_dir))) |gt| {
        self.entitygroups.deinit();
        self.entitygroups = gt;
        util_log.info("zdtd: entitygroups n={d}\n", .{self.entitygroups.groups.len});
        // Fill zombie class slots 1 + 8..11 from weighted group picks so the
        // director can rotate varied classes (not always class_table[1]).
        var zslot: usize = 1;
        var pick_seed: u32 = 1;
        while (zslot < 12) : (pick_seed += 1) {
            const cname = self.entitygroups.pick("ZombiesAll", pick_seed) orelse break;
            const def = self.entities.byName(cname) orelse continue;
            self.sim.setClassDef(@intCast(zslot), .{
                .name = def.name,
                .max_hp = def.max_hp,
                .kind = .zombie,
                .hash = def.hash,
                .loot_list = def.loot_list,
                .drop_prob = def.loot_drop_prob,
                .chase_speed = def.chase_speed,
                .wander_speed = def.wander_speed,
                .attack_damage = self.handItemDamage(def.hand_item),
                .time_stay = def.time_stay,
                .view_angle_deg = def.view_angle_deg,
                .explode_threshold = def.explode_threshold,
                .explode_delay_s = def.explode_delay_s,
            });
            zslot = if (zslot == 1) 8 else zslot + 1;
            if (pick_seed > 32) break;
        }
    }
    // After entitygroups: every <spawn group=…> must name a real entity
    // group. Stock throws XmlLoadException there (ParseSpawn, asm.il
    // ~1379646); zdtd warns and keeps the ladder so one bad row cannot
    // take the server down.
    if (logged("gamestages.xml", assets_gamestages.tryLoad(allocator, opts.game_dir, opts.config_dir))) |gst| {
        self.gamestages.deinit();
        self.gamestages = gst;
        var stage_n: usize = 0;
        var missing: usize = 0;
        for (self.gamestages.spawners) |sp| {
            stage_n += sp.stages.len;
            for (sp.stages) |st| {
                for (st.spawns) |sg| {
                    if (self.entitygroups.byName(sg.group) == null) missing += 1;
                }
            }
        }
        util_log.info(
            "zdtd: gamestages spawners={d} stages={d} groups={d} unknown_entitygroups={d}\n",
            .{ self.gamestages.spawners.len, stage_n, self.gamestages.groups.len, missing },
        );
    }
    if (try assets_traders.tryLoad(allocator, opts.game_dir, opts.config_dir)) |tt| {
        self.traders.deinit();
        self.traders = tt;
    }
    if (try assets_npc.tryLoad(allocator, opts.game_dir, opts.config_dir)) |nt| {
        self.npc.deinit();
        self.npc = nt;
    }
    // Trader POIs on a stock map: spawn each POI's trader NPC at its
    // IndexedBlockOffsets "Trader" cell so a player walking to a compound
    // finds the trader, not an empty building (needs prefabs + entities +
    // npc tables, hence after the loads above).
    self.spawnPoiTraders();
    if (logged("painting.xml", assets_painting.tryLoad(allocator, opts.game_dir, opts.config_dir))) |pt| {
        self.painting.deinit();
        self.painting = pt;
        util_log.info("zdtd: painting entries={d}\n", .{self.painting.n});
    }
    if (logged("spawning.xml", assets_spawning.tryLoad(allocator, opts.game_dir, opts.config_dir))) |st| {
        self.spawning.deinit();
        self.spawning = st;
        util_log.info("zdtd: spawning rules={d}\n", .{self.spawning.rules.len});
    }
    if (logged("buffs.xml", assets_buffs.tryLoad(allocator, opts.game_dir, opts.config_dir))) |bt| {
        self.buffs.deinit();
        self.buffs = bt;
        util_log.info("zdtd: buffs defs={d}\n", .{self.buffs.defs.len});
    }
    if (logged("progression.xml", assets_progression.tryLoadTable(allocator, opts.game_dir, opts.config_dir))) |pt| {
        self.progression_table.deinit();
        self.progression_table = pt;
        self.progression = pt.curve;
        if (pt.curve.loaded) {
            util_log.info("zdtd: progression max_level={d} exp_to_level={d} attrs={d} perks={d}\n", .{
                pt.curve.max_level,
                pt.curve.exp_to_level,
                pt.attributes.len,
                pt.perks.len,
            });
        }
    } else if (logged("progression.xml", assets_progression.tryLoad(allocator, opts.game_dir, opts.config_dir))) |pc| {
        self.progression = pc;
        if (pc.loaded) {
            util_log.info("zdtd: progression max_level={d} exp_to_level={d}\n", .{ pc.max_level, pc.exp_to_level });
        }
    }
    if (logged("vehicles.xml", assets_vehicles.tryLoad(allocator, opts.game_dir, opts.config_dir))) |vt| {
        self.vehicles.deinit();
        self.vehicles = vt;
        util_log.info("zdtd: vehicles defs={d}\n", .{self.vehicles.defs.len});
    }
    if (logged("blocks.xml storage pairs", assets_storage_pairs.tryLoad(allocator, opts.game_dir, opts.config_dir))) |sp| {
        self.storage_pairs.deinit();
        self.storage_pairs = sp;
        const IdCtx = struct {
            t: *const assets_maxdamage.Table,
            fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                const s: *const @This() = @ptrCast(@alignCast(ctx.?));
                return s.t.idByName(name);
            }
        };
        var id_ctx: IdCtx = .{ .t = &self.maxdamage };
        self.storage_pairs.resolveIds(IdCtx.lookup, &id_ctx);
        util_log.info("zdtd: storage pairs={d}\n", .{self.storage_pairs.pairs.len});
    }
    // Wire spawning.xml groups into director (first matching biome rule).
    {
        var night_g: []const u8 = "";
        var day_g: []const u8 = "";
        var animal_g: []const u8 = "";
        var buf: [16]assets_spawning.Rule = undefined;
        for ([_][]const u8{ "pine_forest", "burnt_forest", "desert", "snow", "wasteland" }) |bn| {
            const n = self.spawning.rulesForBiome(bn, &buf);
            var ri: usize = 0;
            while (ri < n) : (ri += 1) {
                const r = buf[ri];
                if (r.kind == .animal and animal_g.len == 0) animal_g = r.entitygroup;
                if (r.kind == .zombie) {
                    if (r.time == .night and night_g.len == 0) night_g = r.entitygroup;
                    if (r.time == .any or r.time == .day) {
                        if (day_g.len == 0) day_g = r.entitygroup;
                    }
                }
            }
            if (night_g.len > 0 and day_g.len > 0) break;
        }
        self.sim.director.night_group = night_g;
        self.sim.director.day_group = day_g;
        self.sim.director.animal_group = animal_g;
        // Biome-aware group override: resolve per spawn-point biome so e.g.
        // wasteland at midnight spawns wasteland walkers, not pine_forest's.
        self.sim.director.biome_group_ctx = self;
        self.sim.director.biome_group_fn = &Game.biomeGroupName;
        self.sim.director.group_pick_ctx = self;
        self.sim.director.group_pick_fn = &Game.pickEntityGroup;
        // Full class resolution: any entityclasses.xml class a spawn group
        // picks reaches the sim with its own HP/speeds/damage, even when it
        // is not preloaded into the fixed class_table (A35).
        self.sim.director.class_resolve_ctx = self;
        self.sim.director.class_resolve_fn = &Game.resolveSpawnClass;
        self.sim.director.stage_group_ctx = self;
        self.sim.director.stage_group_fn = &Game.pickStageGroup;
        self.sim.director.spawner_group_ctx = self;
        self.sim.director.spawner_group_fn = &Game.pickSpawnerGroup;
        // Plugin kill verdict (T15): routes the sim's death decision to the
        // Wasm host (on_player_death for players, on_entity_killed for the
        // rest). Unset hook = no plugins = today's behaviour.
        self.sim.kill_verdict_ctx = self;
        self.sim.kill_verdict_fn = &game_mod.killVerdict;
        // Quest-accept gate (AGENTS rule 29): on_quest_accept verdict on every
        // acceptance (plugins gate which quests a player may take).
        self.sim.quest_accept_ctx = self;
        self.sim.quest_accept_fn = &game_hooks.questAcceptAt;
        if (night_g.len > 0 or day_g.len > 0) {
            util_log.info("zdtd: director groups night={s} day={s} animal={s}\n", .{ night_g, day_g, animal_g });
        }
    }
    if (logged("biomes.xml colors", biomes_mod.tryLoadColorTable(allocator, opts.game_dir, opts.config_dir))) |ct| {
        self.biome_colors.deinit();
        self.biome_colors = ct;
        // Reload biomes.png with XML colors if map already loaded.
        if (opts.map_dir) |md| {
            const reloaded = biomes_mod.tryLoadWithColors(allocator, md, &self.biome_colors) catch |err| blk: {
                util_log.err("zdtd: biome map reload with XML colors failed: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            if (reloaded) |new_biomes| {
                if (self.world.biomes) |*old| old.deinit();
                self.world.biomes = new_biomes;
            }
        }
        util_log.info("zdtd: biome colors n={d}\n", .{self.biome_colors.colors.len});
    }
    // biomes.xml layer stacks → terrain columns (AssignIds names).
    {
        const IdCtx = struct {
            t: *const assets_maxdamage.Table,
            fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
                const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                if (self_t.t.idByName(name)) |id| return id;
                // Comptime pins only when AssignIds map empty (offline / no dump).
                if (self_t.t.id_by_name.count() > 0) return null;
                const a = @import("../../assets/assignids_comptime.zig");
                if (std.mem.eql(u8, name, "terrStone")) return a.terr_stone;
                if (std.mem.eql(u8, name, "terrBedrock")) return a.terr_bedrock;
                if (std.mem.eql(u8, name, "terrDirt")) return a.terr_dirt;
                if (std.mem.eql(u8, name, "terrForestGround")) return a.terr_forest_ground;
                if (std.mem.eql(u8, name, "terrBurntForestGround")) return a.terr_burnt_forest_ground;
                if (std.mem.eql(u8, name, "terrDesertGround")) return a.terr_desert_ground;
                if (std.mem.eql(u8, name, "terrSand")) return a.terr_sand;
                if (std.mem.eql(u8, name, "terrSandStone")) return a.terr_sand_stone;
                if (std.mem.eql(u8, name, "terrSnow")) return a.terr_snow;
                if (std.mem.eql(u8, name, "terrTopSoil")) return a.terr_topsoil;
                if (std.mem.eql(u8, name, "terrDestroyedStone")) return a.terr_destroyed_stone;
                if (std.mem.eql(u8, name, "terrDestroyedGrass")) return a.terr_destroyed_grass;
                if (std.mem.eql(u8, name, "water")) return a.water;
                return null;
            }
            /// blocks.xml IsDistantDecoration, the filter that decides which
            /// `<decoration>` rows can become DecoObjects at all.
            fn distantDeco(ctx: ?*anyopaque, name: []const u8) bool {
                const self_t: *const @This() = @ptrCast(@alignCast(ctx.?));
                return self_t.t.isDistantDeco(name);
            }
        };
        var id_ctx: IdCtx = .{ .t = &self.maxdamage };
        if (logged("biomes.xml layers", assets_biome_layers.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, IdCtx.distantDeco, &id_ctx))) |bl| {
            self.world.biome_layers_table = bl;
            // The procedural generator picks up the loaded biome stacks (W3).
            self.world.syncWorldgenBiomes();
            // Weather groups must come from the same effective biomes.xml we
            // serve, since groupIndex is a document ordinal in that file.
            // Frequency and countdown divisor read the very GameStats values
            // the client is told, so server sim and client display agree.
            const gs_defaults: packages.GameStatsValues = .{};
            self.world.weather.initFrom(&self.world.biome_layers_table, .{
                .seed = opts.worldgen_seed orelse util_sim.default_seed,
                .day_night_length = opts.day_night_length,
                // [sim] storm_frequency percent -> the 1.0x divisor the
                // scheduler divides by (0 disables storms). Mirrors the
                // GameStats wire value so client and server agree.
                .storm_frequency = @as(f32, @floatFromInt(self.storm_frequency)) / 100.0,
                .time_of_day_inc_per_sec = @intCast(@max(gs_defaults.time_of_day_inc_per_sec, 0)),
            });
            self.restoreWeather();
            const burnt = bl.stackFor(9);
            util_log.info("zdtd: biome layers default_n={d} burnt_n={d} burnt0={d} decos={s}\n", .{
                bl.default_stack.n,
                burnt.n,
                if (burnt.n > 0) burnt.layers[0].block_id else 0,
                if (bl.hasDecos()) "yes" else "no",
            });
        }
        // Clock restore is independent of the biome-layers load: a world
        // without stock biome data must still resume its saved day/time.
        self.restoreClock();
        if (logged("blocks.xml textures", assets_block_textures.tryLoad(allocator, opts.game_dir, opts.config_dir, IdCtx.lookup, &id_ctx))) |bt| {
            self.block_textures.deinit();
            self.block_textures = bt;
            util_log.info("zdtd: block textures defaults={d}\n", .{self.block_textures.by_id.count()});
        }
    }
    self.power_registry = ecs.powerblocks.Registry.build(&self.maxdamage);
    util_log.info("zdtd: power blocks registered={d}\n", .{self.power_registry.n});
    if (opts.game_dir != null or opts.config_dir != null) {
        if (self.maxdamage.power_class_by_name.count() == 0)
            util_log.warn("zdtd: blocks.xml Class map empty (power props missing)\n", .{});
        if (self.items.source != .xml)
            util_log.warn("zdtd: items table builtin despite game-dir (items.xml not loaded)\n", .{});
        if (self.recipes.source != .xml)
            util_log.warn("zdtd: recipes table builtin despite game-dir\n", .{});
        if (self.entities.source != .xml)
            util_log.warn("zdtd: entities table builtin despite game-dir\n", .{});
        if (self.loot.source != .xml)
            util_log.warn("zdtd: loot table builtin despite game-dir\n", .{});
        if (self.entitygroups.source != .xml)
            util_log.warn("zdtd: entitygroups table builtin despite game-dir\n", .{});
        if (self.blocks.source != .xml)
            util_log.warn("zdtd: blocks table builtin despite game-dir\n", .{});
        if (self.sim.catalog.source != .stock_xml)
            util_log.warn("zdtd: quests catalog builtin despite game-dir\n", .{});
        if (self.gamestages.source != .xml)
            util_log.warn("zdtd: gamestages table empty despite game-dir\n", .{});
        if (self.traders.groups.len == 0)
            util_log.warn("zdtd: traders table empty despite game-dir\n", .{});
        if (self.npc.entries.len == 0)
            util_log.warn("zdtd: npc table empty despite game-dir\n", .{});
        if (self.painting.n == 0)
            util_log.warn("zdtd: painting table empty despite game-dir\n", .{});
        if (self.spawning.rules.len == 0)
            util_log.warn("zdtd: spawning table empty despite game-dir\n", .{});
        if (self.buffs.defs.len == 0)
            util_log.warn("zdtd: buffs table empty despite game-dir\n", .{});
        if (!self.progression.loaded)
            util_log.warn("zdtd: progression table empty despite game-dir\n", .{});
        if (self.vehicles.defs.len == 0)
            util_log.warn("zdtd: vehicles table empty despite game-dir\n", .{});
        if (self.storage_pairs.pairs.len == 0)
            util_log.warn("zdtd: storage pairs table empty despite game-dir\n", .{});
    }
    if (self.maxdamage.idByName("generatorbank")) |gid| {
        if (self.power_registry.lookup(gid)) |pr| {
            util_log.info("zdtd: power generatorbank watts={d} max_fuel={d} out_per_fuel={d}\n", .{
                pr.watts, pr.max_fuel, pr.output_per_fuel,
            });
        }
    }
}
