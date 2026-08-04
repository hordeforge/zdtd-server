//! zdtd: Zig dedicated server for 7 Days to Die (client wire).
//! Run `zdtd --help` for CLI options and precedence.

const std = @import("std");
const game_mod = @import("server/game.zig");
const packages = @import("wire/packages.zig");
const frame = @import("wire/frame.zig");
const protocol = @import("protocol.zig");
const apm = @import("apm/root.zig");
const world_store = @import("world/store.zig");
const server_config = @import("server/config.zig");
const io_fs = @import("util/io_fs.zig");
const version = @import("version.zig");

fn usageError(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    std.debug.print("zdtd: " ++ fmt ++ "\nzdtd: try 'zdtd --help'\n", fmt_args);
    std.process.exit(2);
}

fn flagValue(it: *std.process.Args.Iterator, flag: []const u8) [:0]const u8 {
    return it.next() orelse usageError("option '{s}' requires a value", .{flag});
}

fn flagInt(comptime T: type, flag: []const u8, s: []const u8, base: u8) T {
    return std.fmt.parseInt(T, s, base) catch
        usageError("invalid value '{s}' for option '{s}'", .{ s, flag });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var port: u16 = 26902;
    var port_cli = false;
    var world_dir: []const u8 = "worlds/zdtd_default";
    var map_dir: ?[]const u8 = null;
    var game_dir: ?[]const u8 = null;
    var config_dir: ?[]const u8 = null;
    var config_overrides: std.ArrayList([]const u8) = .empty;
    defer config_overrides.deinit(gpa);
    var quests_path: ?[]const u8 = null;
    var world_name: ?[]const u8 = null;
    var world_name_cli = false;
    var serverconfig_path: ?[]const u8 = null;
    var admin_port: u16 = 0;
    var admin_port_cli = false;
    var max_ticks: u64 = 0;
    var once = false;
    var worldgen_seed: ?u64 = null;
    var map_path_buf: [1024]u8 = undefined;
    var cfg_owned: ?server_config.Config = null;
    defer if (cfg_owned) |*c| c.deinit();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--port")) {
            port = flagInt(u16, a, flagValue(&it, a), 10);
            port_cli = true;
        } else if (std.mem.eql(u8, a, "--world")) {
            world_dir = flagValue(&it, a);
        } else if (std.mem.eql(u8, a, "--map")) {
            map_dir = flagValue(&it, a);
        } else if (std.mem.eql(u8, a, "--game-dir")) {
            game_dir = flagValue(&it, a);
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            config_dir = flagValue(&it, a);
        } else if (std.mem.eql(u8, a, "--config-overrides")) {
            try config_overrides.append(gpa, flagValue(&it, a));
        } else if (std.mem.eql(u8, a, "--quests")) {
            quests_path = flagValue(&it, a);
        } else if (std.mem.eql(u8, a, "--world-name")) {
            world_name = flagValue(&it, a);
            world_name_cli = true;
        } else if (std.mem.eql(u8, a, "--serverconfig")) {
            serverconfig_path = flagValue(&it, a);
        } else if (std.mem.eql(u8, a, "--admin-port")) {
            admin_port = flagInt(u16, a, flagValue(&it, a), 10);
            admin_port_cli = true;
        } else if (std.mem.eql(u8, a, "--worldgen-seed")) {
            worldgen_seed = flagInt(u64, a, flagValue(&it, a), 0);
        } else if (std.mem.eql(u8, a, "--ticks")) {
            max_ticks = flagInt(u64, a, flagValue(&it, a), 10);
        } else if (std.mem.eql(u8, a, "--once")) {
            once = true;
            max_ticks = 1;
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("zdtd {s}\n", .{version.product});
            return;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\zdtd [--port 26902] [--world SAVE_DIR] [--map STOCK_WORLD_DIR] [--ticks N] [--once]
                \\     [--game-dir DEDI_OR_CLIENT_ROOT] [--world-name Navezgane|Pregen06k01|…]
                \\     [--config-dir Data/Config] [--config-overrides DIR]…
                \\     [--quests path/to/quests.xml]
                \\     [--serverconfig path/serverconfig.xml] [--admin-port N]
                \\     [--worldgen-seed U64]
                \\
                \\  --port           ServerPort: TCP GameServerInfo; LiteNet uses port+2
                \\  --world          zdtd save/overlay dir (default worlds/zdtd_default)
                \\  --map            stock Data/Worlds/<Name>
                \\  --game-dir       install root (Data/Worlds + Data/Config)
                \\  --world-name     Navezgane | Pregen06k01 | …
                \\  --serverconfig   stock-like ServerSettings XML (required file; see serverconfig.example.xml)
                \\  --admin-port     TCP admin console on 127.0.0.1 (give/tele/save/kick/say)
                \\  --quests         explicit quests.xml
                \\  --config-dir     stock Data/Config dir (XML assets)
                \\  --config-overrides  dir of xpath patch XMLs (repeatable; filename order)
                \\  --worldgen-seed  procedural terrain (on-the-fly; no --map). Empty world dir ok.
                \\  --ticks          run N ticks then save and exit (0 = run forever)
                \\  --once           run a single tick then save and exit
                \\  --version        print version and exit
                \\  -h, --help       show this help
                \\
                \\  Precedence: CLI flags override matching serverconfig.xml keys.
                \\
            , .{});
            return;
        } else {
            usageError("unknown option '{s}'", .{a});
        }
    }

    if (serverconfig_path) |scp| {
        // Explicit path: fail fast (do not silently run with defaults).
        cfg_owned = server_config.loadFromPath(gpa, scp) catch |err| {
            usageError("cannot load --serverconfig '{s}': {s}", .{ scp, @errorName(err) });
        };
        if (cfg_owned) |cfg| {
            if (!port_cli) port = cfg.port;
            if (!admin_port_cli and cfg.admin_port != 0) admin_port = cfg.admin_port;
            if (!world_name_cli and cfg.world_name.len > 0) world_name = cfg.world_name;
            // GameWorld only fills map identity when CLI did not set --world-name.
            if (!world_name_cli and cfg.game_world.len > 0 and map_dir == null and game_dir != null) {
                world_name = cfg.game_world;
            }
        }
    }

    // Resolve --game-dir + --world-name → map path when --map not set.
    // Require --game-dir (or serverconfig paths); no absolute Steam default.
    if (map_dir == null) {
        if (world_name) |wn| {
            if (game_dir) |root| {
                const candidate = try std.fmt.bufPrint(&map_path_buf, "{s}/Data/Worlds/{s}", .{ root, wn });
                // Fall back to a flat world instead of crashing when the resolved world
                // folder is absent (e.g. serverconfig GameName with no matching save).
                if (io_fs.dirExistsSimple(candidate)) {
                    map_dir = candidate;
                } else {
                    std.debug.print("zdtd: world '{s}' not found under {s}/Data/Worlds; using flat world\n", .{ wn, root });
                }
            } else {
                std.debug.print("zdtd: --world-name '{s}' needs --game-dir (or --map); using flat world\n", .{wn});
            }
        }
    }

    const resolved_world_name: ?[]const u8 = blk: {
        if (cfg_owned) |c| {
            if (c.world_name.len > 0) break :blk c.world_name;
        }
        break :blk world_name;
    };
    const cfg_max_players: u16 = if (cfg_owned) |c| c.max_players else 8;
    const cfg_password: []const u8 = if (cfg_owned) |c| c.password else "";
    const cfg_view_radius: i32 = if (cfg_owned) |c| c.view_radius else 6;
    const cfg_authority = if (cfg_owned) |c| c.authority_mode else .correct;

    const g = try game_mod.Game.createWithOptions(gpa, world_dir, port, .{
        .map_dir = map_dir,
        .game_dir = game_dir,
        .config_dir = config_dir,
        .config_overrides = config_overrides.items,
        .quests_path = quests_path,
        .admin_port = admin_port,
        .world_name = resolved_world_name,
        .view_radius = cfg_view_radius,
        .max_players = cfg_max_players,
        .password = cfg_password,
        .game_difficulty = if (cfg_owned) |c| c.game_difficulty else 2,
        .blood_moon_frequency = if (cfg_owned) |c| c.blood_moon_frequency else 7,
        .blood_moon_enemy_count = if (cfg_owned) |c| c.blood_moon_enemy_count else 8,
        .blood_moon_range = if (cfg_owned) |c| c.blood_moon_range else 0,
        .player_killing_mode = if (cfg_owned) |c| c.player_killing_mode else 3,
        .day_night_length = if (cfg_owned) |c| c.day_night_length else 60,
        .day_light_length = if (cfg_owned) |c| c.day_light_length else 18,
        .max_spawned_zombies = if (cfg_owned) |c| c.max_spawned_zombies else 64,
        .zombie_move = if (cfg_owned) |c| c.zombie_move else 0,
        .zombie_move_night = if (cfg_owned) |c| c.zombie_move_night else 3,
        .zombie_feral_move = if (cfg_owned) |c| c.zombie_feral_move else 3,
        .zombie_bm_move = if (cfg_owned) |c| c.zombie_bm_move else 3,
        .enemy_difficulty = if (cfg_owned) |c| c.enemy_difficulty else 0,
        .loot_abundance = if (cfg_owned) |c| c.loot_abundance else 100,
        .xp_multiplier = if (cfg_owned) |c| c.xp_multiplier else 100,
        .block_damage_player = if (cfg_owned) |c| c.block_damage_player else 100,
        .block_damage_ai = if (cfg_owned) |c| c.block_damage_ai else 100,
        .block_damage_ai_bm = if (cfg_owned) |c| c.block_damage_ai_bm else 100,
        .max_spawned_animals = if (cfg_owned) |c| c.max_spawned_animals else 50,
        .air_drop_frequency = if (cfg_owned) |c| c.air_drop_frequency else 72,
        .drop_on_death = if (cfg_owned) |c| c.drop_on_death else 1,
        .land_claim_size = if (cfg_owned) |c| c.land_claim_size else 41,
        .land_claim_online_durability_modifier = if (cfg_owned) |c| c.land_claim_online_durability_modifier else 4,
        .land_claim_offline_durability_modifier = if (cfg_owned) |c| c.land_claim_offline_durability_modifier else 4,
        .worldgen_seed = worldgen_seed,
        .authority_mode = cfg_authority,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Effective config summary (password never printed).
    std.debug.print(
        "zdtd: config port={d} max_players={d} view_radius={d} admin_port={d} password={s} authority={s}\n",
        .{
            port,
            g.max_players,
            g.view_radius,
            admin_port,
            if (cfg_password.len > 0) "set" else "open",
            @tagName(cfg_authority),
        },
    );

    const sp = g.world.primarySpawn();
    const qcat = g.sim.catalog;
    const qsrc: []const u8 = switch (qcat.source) {
        .builtin => "builtin",
        .stock_xml => if (qcat.source_path.len > 0) qcat.source_path else "quests.xml",
    };
    if (map_dir) |md| {
        const hm = g.world.heightmap.?;
        const n_pref = if (g.world.prefabs) |*p| p.items.len else 0;
        const n_water = if (g.world.water) |*w| w.points.len else 0;
        std.debug.print(
            \\zdtd {s}
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2)
            \\  save={s}
            \\  map={s} dtm={d}x{d} spawn=({d},{d},{d})
            \\  prefabs={d} water_sources={d}
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d}
            \\
        ,
            .{
                version.product,
                g.infoPort(),
                g.bindPort(),
                world_dir,
                md,
                hm.width,
                hm.height,
                sp.x,
                sp.y,
                sp.z,
                n_pref,
                n_water,
                qsrc,
                qcat.defs.len,
                qcat.starter_name,
                qcat.starter_id,
                protocol.challenge_marker,
                protocol.ticks_per_second,
                packages.default_mappings.len,
            },
        );
    } else if (g.world.terrain_source == .proc) {
        const seed = if (g.world.worldgen) |wg| wg.seed else 0;
        std.debug.print(
            \\zdtd {s}
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2) world={s}
            \\  terrain=proc seed={d} spawn=({d},{d},{d})
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d}
            \\
        ,
            .{
                version.product,
                g.infoPort(),
                g.bindPort(),
                world_dir,
                seed,
                sp.x,
                sp.y,
                sp.z,
                qsrc,
                qcat.defs.len,
                qcat.starter_name,
                qcat.starter_id,
                protocol.challenge_marker,
                protocol.ticks_per_second,
                packages.default_mappings.len,
            },
        );
    } else {
        std.debug.print(
            \\zdtd {s}
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2) world={s}
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d} (flat; --map or --worldgen-seed)
            \\
        ,
            .{
                version.product,
                g.infoPort(),
                g.bindPort(),
                world_dir,
                qsrc,
                qcat.defs.len,
                qcat.starter_name,
                qcat.starter_id,
                protocol.challenge_marker,
                protocol.ticks_per_second,
                packages.default_mappings.len,
            },
        );
    }

    if (max_ticks == 0) {
        try g.run();
    } else {
        var i: u64 = 0;
        while (i < max_ticks) : (i += 1) {
            try g.step();
        }
        try g.world.saveAll();
        const snap = g.harness.snapshot();
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        apm.report.writeText(&snap, &w) catch |err|
            std.debug.print("zdtd: apm report truncated: {s}\n", .{@errorName(err)});
        std.debug.print("{s}", .{w.buffered()});
        if (once) std.debug.print("zdtd --once complete\n", .{});
    }
}

test {
    // Package roots pull leaf module tests; add new modules to the matching root.
    _ = @import("util/root.zig");
    _ = @import("apm/root.zig");
    _ = @import("litenet/root.zig");
    _ = @import("wire/root.zig");
    _ = @import("assets/root.zig");
    _ = @import("ecs/root.zig");
    _ = @import("world/root.zig");
    _ = @import("server/root.zig");
}

test "integration world persist + damage + packages" {
    const dir = "worlds/zdtd_itest";
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple(dir);

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expect(g.bindPort() != 0);

    try g.setBlock(10, 70, 10, world_store.block_stone);
    try g.world.saveAll();

    const g2 = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g2.deinit();
        gpa.destroy(g2);
    }
    const c = try g2.world.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 70), c.heightAt(10, 10));

    const zid = g2.sim.spawnZombie(0, 70, 0, 10).?;
    try std.testing.expect(g2.applyDamage(zid, 50));

    var body: [64]u8 = undefined;
    const pos = try packages.buildPosAndRotBody(&body, 1, 0, 70, 0, 0, 0, 0, true);
    try std.testing.expectEqual(@as(usize, 30), pos.len);
    const rel = try packages.buildRelPosBody(&body, 1, 0, 0, 0, 0, 0, 0, true, 1);
    try std.testing.expectEqual(@as(usize, 20), rel.len);

    var frame_buf: [128]u8 = undefined;
    const fr = try packages.framed(&frame_buf, "NetPackageEntityRelPosAndRot", rel);
    try std.testing.expectEqual(@as(i32, 22), std.mem.readInt(i32, fr[9..][0..4], .little));

    var ch: [17]u8 = undefined;
    frame.buildChallenge(&ch, .{1} ** 16);
    try std.testing.expect(frame.isChallenge(&ch));
}
