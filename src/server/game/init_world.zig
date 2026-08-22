//! Post-asset init: sleeper volumes, network listen, seed entities, power demo.
//! World-store initialization and persisted-world restoration for `Game.init`.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const version = @import("../../version.zig");
const world_store = @import("../../world/store.zig");
const sleepers_mod = @import("../../world/sleepers.zig");
const ecs = @import("../../ecs/root.zig");
const util_sim = @import("../../util/sim.zig");
const util_log = @import("../../util/log.zig");
const clock = @import("../../util/clock.zig");
const replicate_te = @import("../replicate_te.zig");
const admin_xml = @import("../admin_xml.zig");
const io_fs = @import("../../util/io_fs.zig");

pub fn initWorld(self: *Game, allocator: std.mem.Allocator, port: u16, opts: game_mod.InitOptions, had_saved_entities: bool) !void {
    // Prefab sleeper volumes (stock map only). Prefer POIs near primary spawn first
    // so max_volumes budget covers playable area; remainder skipped (honest cap).
    if (self.world.prefabs) |*pf| {
        if (pf.prefabs_root.len > 0) {
            const sp0 = self.world.primarySpawn();
            var refs: std.ArrayList(sleepers_mod.PrefabRef) = .empty;
            defer refs.deinit(allocator);
            // Pass 1: within ~512m of spawn
            for (pf.items) |d| {
                const dx = d.x - sp0.x;
                const dz = d.z - sp0.z;
                if (dx * dx + dz * dz > 512 * 512) continue;
                try refs.append(allocator, .{
                    .name = d.name,
                    .x = d.x,
                    // Sleeper volume starts are prefab-local, so they follow
                    // the stamped body down through YOffset.
                    .y = d.stampY(),
                    .z = d.z,
                    .rot = d.rot,
                    .size_x = d.size_x,
                    .size_y = d.size_y,
                    .size_z = d.size_z,
                });
            }
            // Pass 2: fill remaining budget with farther POIs
            if (refs.items.len < 800) {
                for (pf.items) |d| {
                    const dx = d.x - sp0.x;
                    const dz = d.z - sp0.z;
                    if (dx * dx + dz * dz <= 512 * 512) continue;
                    try refs.append(allocator, .{
                        .name = d.name,
                        .x = d.x,
                        .y = d.stampY(),
                        .z = d.z,
                        .rot = d.rot,
                        .size_x = d.size_x,
                        .size_y = d.size_y,
                        .size_z = d.size_z,
                    });
                    if (refs.items.len >= 1200) break;
                }
            }
            if (sleepers_mod.loadFromPrefabs(allocator, pf.prefabs_root, refs.items, &Game.isSleeperName, self) catch |err| blk: {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} sleeper load failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
                break :blk null;
            }) |sv| {
                self.sleepers.deinit();
                self.sleepers = sv;
                // Stock POI volumes name gamestage groups, not entitygroups
                // (SleeperVolume::Spawn, asm.il ~1199169). Probe at stage 1,
                // the lowest rung any stock ladder has, so a regression back
                // to defaultZombie for most of the map is visible at boot.
                var gs_ok: usize = 0;
                for (self.sleepers.volumes) |vol| {
                    if (vol.group_n == 0) continue;
                    if (self.gamestages.sleeperEntityGroup(vol.groups[0].class_name, 1) != null) gs_ok += 1;
                }
                util_log.info("zdtd: sleeper volumes={d} (prefabs_near={d}) gamestage_resolved={d}\n", .{ self.sleepers.volumes.len, refs.items.len, gs_ok });
                // Re-apply ClearSleepers suppressions from a previous session
                // (sleepers_cleared.zsc): a cleared quest POI must not re-arm.
                self.sleepers.loadCleared(self.allocator, self.world.world_dir);
            }
        }
    }

    // Stock: ServerPort = TCP info; LiteNet UDP = ServerPort+2 (NetworkServerLiteNetLib.GetServerPorts).
    // port==0: offline DST game - never bind a socket so the seeded sim is
    // sealed from the network stack (poll sees WouldBlock; sends drop to the
    // Capture). Production always binds LiteNet at ServerPort+2.
    const lite_port: u16 = if (port == 0) 0 else port +% 2;
    if (lite_port != 0) try self.net.listen(lite_port);
    // ServerPassword is LiteNet Connect key (not Encryption* / not PlayerLogin).
    self.net.server_password = self.password;
    // Stock ConnectionRateLimitMilliseconds, enforced at ConnectRequest time
    // (litenet Server.rateLimited, reject_rate_limit Disconnect).
    self.net.join_rate_limit_ms = self.join_rate_limit_ms;
    self.info_port = port;
    // Offline harness (port 0): virtual mono clock + serial forRanges so
    // lock/stale/resend and parallel systems are seed-stable under DST.
    // Run seed is worldgen when set, else default_seed (logged via getSeed).
    // Production always passes a real ServerPort and leaves wall clock.
    if (port == 0) {
        const seed = opts.worldgen_seed orelse util_sim.default_seed;
        util_sim.enableSeeded(util_sim.default_start_ns, seed);
        // DST replay key: the single value that reproduces this run.
        util_log.info("zdtd: DST run seed={d}\n", .{seed});
    }
    // A later init error (for example invalid WebUI configuration) must not
    // leak process-wide virtual time or forced-serial scheduling into the
    // next test. Successful construction transfers cleanup to deinit().
    errdefer if (port == 0) util_sim.disable();
    if (port != 0) {
        const level = if (opts.world_name) |wn| wn else self.world_name;
        // Advertise ServerPort in GSI.Port; stock client dials LiteNet at Port+2.
        self.info_tcp.start(.{
            .game_name = "zdtd",
            .game_host = "zdtd",
            .level_name = level,
            .ip = "127.0.0.1",
            .info_port = port,
            .max_players = self.max_players,
            .current_players = 0,
            .server_version = version.stock_wire_gsi_version,
            .world_size = self.worldSize(),
            .eac_enabled = false,
            .password_protected = self.password.len > 0,
            .sandbox_preset = self.sandbox_preset,
            .sandbox_code = self.sandbox_code,
            .server_description = self.server_description,
            .server_website_url = self.server_website_url,
            .region = self.region,
            .language = self.language,
            .play_group = self.play_group,
        }) catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} warning: TCP server-info on {d} failed: {}\n", .{ clock.wallStamp(&ts), port, err });
        };
    }
    self.loadAdminLists();
    // Stock serveradmin.xml (admins/whitelist/blacklist) applies on top of
    // zdtd's own list files; see admin_xml.zig for the format and the
    // hot-reload poll in tickServerAdminReload.
    if (opts.serveradmin_path) |sa_path| {
        self.serveradmin_path = self.allocator.dupe(u8, sa_path) catch null;
        if (self.serveradmin_path != null) {
            self.serveradmin_mtime = io_fs.fileMtimeNanos(sa_path) orelse 0;
            admin_xml.load(self.allocator, sa_path, &self.admin_list, &self.whitelist, &self.ban_list) catch |err| {
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} warning: serveradmin.xml load failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
            };
        }
    }
    if (opts.admin_port != 0) {
        // Stock TelnetConsole::.ctor (asm.il ~270735): a password is what moves
        // the console off loopback, so `auth` must be set before `listen`.
        self.admin.auth = .{
            .password = opts.telnet_password,
            .fail_limit = opts.telnet_failed_login_limit,
            .fail_block_minutes = opts.telnet_failed_logins_blocktime,
        };
        self.admin.greeting = .{
            .version = version.stock_wire_announce,
            .compat_version = version.stock_wire,
            .server_ip = if (self.admin.public()) "Any" else "127.0.0.1",
            .server_port = port,
            .max_players = self.max_players,
            .game_mode = "GameModeSurvival",
            .world = opts.game_world,
            .game_name = self.world_name,
            .difficulty = opts.game_difficulty,
        };
        self.admin.listen(opts.admin_port) catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} warning: admin TCP on 127.0.0.1:{d} failed: {}\n", .{ clock.wallStamp(&ts), opts.admin_port, err });
        };
        if (self.admin.port != 0) {
            std.debug.print(
                "zdtd: admin console {s}:{d} ({s})\n",
                .{
                    if (self.admin.public()) "0.0.0.0" else "127.0.0.1",
                    self.admin.port,
                    if (self.admin.public()) "password required" else "unauthenticated; loopback only",
                },
            );
        }
    }
    if (opts.webui_port != 0) {
        // Fail closed: operator requested webui; a silent disabled UI is a misconfig incident.
        self.webui.listen(.{
            .port = opts.webui_port,
            .bind_host = opts.webui_bind,
            .secret = opts.webui_secret,
        }) catch |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} webui on {s}:{d} failed: {s}\n", .{
                clock.wallStamp(&ts),
                opts.webui_bind,
                opts.webui_port,
                @errorName(err),
            });
            return err;
        };
        self.webui.setAdminHandler(self, Game.webuiAdminThunk);
        util_log.info("zdtd: webui http://{s}:{d}/ (auth: Bearer / X-Zdtd-Secret)\n", .{
            opts.webui_bind,
            self.webui.port,
        });
    }
    if (opts.world_name) |wn| self.world_name = wn;

    const sp = self.world.primarySpawn();
    const sy: f32 = @floatFromInt(sp.y);
    const sx: f32 = @floatFromInt(sp.x);
    const sz: f32 = @floatFromInt(sp.z);

    // Keep starter zombies outside default turret range (~24) so they survive until join.
    // A35: spawn the full resolved class so the entities carry their own stats.
    const zdef = self.entities.defaultZombie();
    const z1 = self.sim.spawnZombieDef(sx + 40, sy, sz + 8, zdef.max_hp, self.entityClassOf(zdef));
    const z2 = self.sim.spawnZombieDef(sx - 35, sy, sz + 12, zdef.max_hp, self.entityClassOf(zdef));
    const z3 = self.sim.spawnSleeperDef(sx + 30, sy, sz - 40, self.entityClassOf(zdef));
    const adef = self.entities.defaultAnimal();
    _ = self.sim.spawnAnimalDef(sx - 20, sy, sz - 25, self.entityClassOf(adef));
    if (self.sim.spawnTrader("Trader Jen", sx + 12, sy, sz + 8, self.npc.traderIdForClass("Trader Jen"), self.trader_wallet_dukes)) |trader_id| {
        self.fillTraderFromXml(trader_id);
    }
    // Persistable kinds seed only on a fresh world; entities.zen owns
    // them across restarts (see had_saved_entities above).
    if (!had_saved_entities) {
        const vk: ecs.components.VehicleKind = .minibike;
        if (self.vehicles.byKind(vk)) |vd| {
            _ = self.sim.spawnVehicleEx(vk, sx + 6, sy, sz - 4, vd.max_hp, vd.velocity_max, vd.seat_count);
        } else {
            _ = self.sim.spawnVehicle(vk, sx + 6, sy, sz - 4);
        }
    }
    // Near-spawn storage TE (stock TileEntity on chunk stream).
    // Prefer runtime AssignIds id for cntWoodenChestClosed when known; else placeholder.
    {
        const cx: i32 = sp.x + 2;
        const cy: i32 = sp.y;
        const cz: i32 = sp.z + 2;
        const chest_block: u16 = replicate_te.seedChestBlockId(self);
        if (self.world.setBlockWorld(cx, cy, cz, chest_block)) |_| {
            if (self.containers.getOrCreate(.{ .x = cx, .y = cy, .z = cz }, 8, chest_block)) |cont| {
                cont.setSlot(0, .{ .item_id = 7, .count = 10, .quality = 1 }); // wood
                cont.setSlot(1, .{ .item_id = 2, .count = 3, .quality = 1 }); // food
            }
        } else |err| {
            var ts: [19]u8 = undefined;
            std.debug.print("zdtd: {s} seed chest block ({d},{d},{d}) failed: {s}\n", .{ clock.wallStamp(&ts), cx, cy, cz, @errorName(err) });
        }
    }
    util_log.info("zdtd: sim seed zombies z1={?} z2={?} sleeper={?} count={d} spawn=({d},{d},{d})\n", .{
        z1, z2, z3, self.sim.countKind(.zombie), sp.x, sp.y, sp.z,
    });

    // Demo power grid off the spawn pad (do not auto-wire a live turret onto seed zombies).
    // The turret is persistable and only seeds fresh; the generator is a
    // virtual node (no block) and re-seeds every boot so a restored turret
    // still finds a source after a restart.
    const gen = self.sim.power.addNode(.generator, @trunc(sx + 50), @trunc(sy), @trunc(sz + 50), 100);
    if (!had_saved_entities) {
        if (self.sim.spawnTurret(sx + 52, sy, sz + 52)) |tid| {
            if (gen) |gid| {
                if (self.sim.slotOfNetId(tid)) |ts| {
                    _ = self.sim.power.connect(gid, self.sim.turret[ts].power_node);
                }
            }
        }
    }
    self.sim.power.resolve();

    // Static plugins after world/assets are ready (sample_hello logs once).
    self.plugins.enableStaticDefaults();
    // Wasm plugins from config ([plugin] modules, ADR 0020): load once at
    // init (allocation allowed here), then enable. loadAll logs and skips
    // a missing or unloadable module, so one bad file does not kill boot.
    self.wasm_plugins.loadAll(self.allocator, opts.plugin_modules, &self.wasm_ctx, opts.plugin_budget);
    self.wasm_plugins.enable();
}
