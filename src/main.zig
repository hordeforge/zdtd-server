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

const help_text =
    \\Usage: zdtd [options]
    \\
    \\  Zig dedicated server for the stock 7DTD client wire (EAC off).
    \\
    \\Options:
    \\  --port N              ServerPort: TCP GameServerInfo; LiteNet uses N+2 (default 26902)
    \\  --world DIR           zdtd save/overlay dir (default worlds/zdtd_default)
    \\  --map DIR             stock Data/Worlds/<Name> (dtm + prefabs)
    \\  --game-dir DIR        install root (Data/Worlds + Data/Config)
    \\  --world-name NAME     Navezgane | Pregen06k01 | … (needs --game-dir unless --map)
    \\  --serverconfig PATH   stock-like ServerSettings XML (file must exist; see serverconfig.example.xml)
    \\  --admin-port N        TCP admin console on 127.0.0.1 (0 = off; give/tele/save/kick/say)
    \\  --quests PATH         explicit quests.xml
    \\  --config-dir DIR      stock Data/Config dir (XML assets)
    \\  --config-overrides DIR  dir of xpath patch XMLs (repeatable; filename order)
    \\  --worldgen-seed U64   procedural terrain (on-the-fly; no --map). Empty world dir ok.
    \\  --ticks N             run N ticks then save and exit (0 = run forever)
    \\  --once                run a single tick then save and exit
    \\  -V, --version         print product and stock wire versions and exit
    \\  -h, --help            show this help
    \\
    \\Value forms: --flag VALUE or --flag=VALUE
    \\Precedence: CLI flags override matching serverconfig.xml keys.
    \\
    \\Examples:
    \\  zdtd --port 27002 --world worlds/zdtd_default
    \\  zdtd --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
    \\  zdtd --map "$GAME/Data/Worlds/Pregen06k01" --world worlds/pregen_run
    \\  zdtd --serverconfig serverconfig.xml --admin-port 8081
    \\  zdtd --worldgen-seed 42 --once
    \\
;

fn usageError(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    std.debug.print("zdtd: " ++ fmt ++ "\nzdtd: try 'zdtd --help'\n", fmt_args);
    std.process.exit(2);
}

/// Help and version go to stdout (not stderr) so operators can pipe them.
fn printStdout(comptime fmt: []const u8, fmt_args: anytype) void {
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, fmt_args) catch {
        std.debug.print(fmt, fmt_args);
        return;
    };
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    std.Io.File.stdout().writeStreamingAll(threaded.io(), msg) catch {
        std.debug.print(fmt, fmt_args);
    };
}

/// Resolve a value for `--flag` or `--flag=value`. Rejects empty `--flag=`.
fn flagValue(it: *std.process.Args.Iterator, flag: []const u8, inline_val: ?[]const u8) []const u8 {
    if (inline_val) |v| {
        if (v.len == 0) usageError("option '{s}' requires a value", .{flag});
        return v;
    }
    return it.next() orelse usageError("option '{s}' requires a value", .{flag});
}

fn flagInt(comptime T: type, flag: []const u8, s: []const u8, base: u8) T {
    return std.fmt.parseInt(T, s, base) catch
        usageError("invalid value '{s}' for option '{s}' (expected integer)", .{ s, flag });
}

/// Split `--name` / `--name=value` into (name, optional value).
fn splitFlag(a: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
        return .{ .name = a[0..eq], .value = a[eq + 1 ..] };
    }
    return .{ .name = a, .value = null };
}

fn resolveWorldName(cli_name: ?[]const u8, config_name: []const u8) ?[]const u8 {
    if (cli_name) |name| return name;
    return if (config_name.len > 0) config_name else null;
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
        const parts = splitFlag(a);
        const name = parts.name;
        const inline_val = parts.value;

        if (std.mem.eql(u8, name, "--port")) {
            port = flagInt(u16, name, flagValue(&it, name, inline_val), 10);
            port_cli = true;
        } else if (std.mem.eql(u8, name, "--world")) {
            world_dir = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--map")) {
            map_dir = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--game-dir")) {
            game_dir = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--config-dir")) {
            config_dir = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--config-overrides")) {
            try config_overrides.append(gpa, flagValue(&it, name, inline_val));
        } else if (std.mem.eql(u8, name, "--quests")) {
            quests_path = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--world-name")) {
            world_name = flagValue(&it, name, inline_val);
            world_name_cli = true;
        } else if (std.mem.eql(u8, name, "--serverconfig")) {
            serverconfig_path = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--admin-port")) {
            admin_port = flagInt(u16, name, flagValue(&it, name, inline_val), 10);
            admin_port_cli = true;
        } else if (std.mem.eql(u8, name, "--worldgen-seed")) {
            worldgen_seed = flagInt(u64, name, flagValue(&it, name, inline_val), 0);
        } else if (std.mem.eql(u8, name, "--ticks")) {
            max_ticks = flagInt(u64, name, flagValue(&it, name, inline_val), 10);
        } else if (std.mem.eql(u8, name, "--once")) {
            if (inline_val != null) usageError("option '--once' does not take a value", .{});
            once = true;
            max_ticks = 1;
        } else if (std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V")) {
            if (inline_val != null) usageError("option '{s}' does not take a value", .{name});
            printStdout("zdtd {s} (stock wire {s})\n", .{ version.product, version.stock_wire });
            return;
        } else if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (inline_val != null) usageError("option '{s}' does not take a value", .{name});
            printStdout("{s}", .{help_text});
            return;
        } else if (std.mem.startsWith(u8, a, "-")) {
            usageError("unknown option '{s}'", .{name});
        } else {
            usageError("unexpected argument '{s}' (zdtd takes options only, not positionals)", .{a});
        }
    }

    if (serverconfig_path) |scp| {
        // Explicit path: fail fast (do not silently run with defaults).
        cfg_owned = server_config.loadFromPath(gpa, scp) catch |err| {
            usageError("cannot load --serverconfig '{s}': {s}", .{ scp, @errorName(err) });
        };
        if (cfg_owned) |c| {
            if (!port_cli) port = c.port;
            if (!admin_port_cli and c.admin_port != 0) admin_port = c.admin_port;
            if (!world_name_cli and c.world_name.len > 0) world_name = c.world_name;
            // GameWorld only fills map identity when CLI did not set --world-name.
            if (!world_name_cli and c.game_world.len > 0 and map_dir == null and game_dir != null) {
                world_name = c.game_world;
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

    const resolved_world_name = resolveWorldName(
        if (world_name_cli) world_name else null,
        if (cfg_owned) |c| c.world_name else if (world_name) |name| name else "",
    );
    // Effective config: loaded file or struct defaults (single source in config.zig).
    const cfg: server_config.Config = cfg_owned orelse .{};

    const g = try game_mod.Game.createWithOptions(gpa, world_dir, port, .{
        .map_dir = map_dir,
        .game_dir = game_dir,
        .config_dir = config_dir,
        .config_overrides = config_overrides.items,
        .quests_path = quests_path,
        .admin_port = admin_port,
        .world_name = resolved_world_name,
        .view_radius = cfg.view_radius,
        .max_players = cfg.max_players,
        .password = cfg.password,
        .game_difficulty = cfg.game_difficulty,
        .blood_moon_frequency = cfg.blood_moon_frequency,
        .blood_moon_enemy_count = cfg.blood_moon_enemy_count,
        .blood_moon_range = cfg.blood_moon_range,
        .player_killing_mode = cfg.player_killing_mode,
        .day_night_length = cfg.day_night_length,
        .day_light_length = cfg.day_light_length,
        .max_spawned_zombies = cfg.max_spawned_zombies,
        .zombie_move = cfg.zombie_move,
        .zombie_move_night = cfg.zombie_move_night,
        .zombie_feral_move = cfg.zombie_feral_move,
        .zombie_bm_move = cfg.zombie_bm_move,
        .enemy_difficulty = cfg.enemy_difficulty,
        .loot_abundance = cfg.loot_abundance,
        .xp_multiplier = cfg.xp_multiplier,
        .block_damage_player = cfg.block_damage_player,
        .block_damage_ai = cfg.block_damage_ai,
        .block_damage_ai_bm = cfg.block_damage_ai_bm,
        .max_spawned_animals = cfg.max_spawned_animals,
        .air_drop_frequency = cfg.air_drop_frequency,
        .drop_on_death = cfg.drop_on_death,
        .land_claim_size = cfg.land_claim_size,
        .land_claim_online_durability_modifier = cfg.land_claim_online_durability_modifier,
        .land_claim_offline_durability_modifier = cfg.land_claim_offline_durability_modifier,
        .worldgen_seed = worldgen_seed,
        .authority_mode = cfg.authority_mode,
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
            if (cfg.password.len > 0) "set" else "open",
            @tagName(cfg.authority_mode),
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

test "splitFlag bare and equals forms" {
    const bare = splitFlag("--port");
    try std.testing.expectEqualStrings("--port", bare.name);
    try std.testing.expect(bare.value == null);

    const eq = splitFlag("--port=27002");
    try std.testing.expectEqualStrings("--port", eq.name);
    try std.testing.expectEqualStrings("27002", eq.value.?);

    const empty = splitFlag("--world=");
    try std.testing.expectEqualStrings("--world", empty.name);
    try std.testing.expectEqualStrings("", empty.value.?);
}

test "explicit world name overrides serverconfig game name" {
    try std.testing.expectEqualStrings("CliWorld", resolveWorldName("CliWorld", "ConfigWorld").?);
    try std.testing.expectEqualStrings("ConfigWorld", resolveWorldName(null, "ConfigWorld").?);
    try std.testing.expect(resolveWorldName(null, "") == null);
}

test "server port must leave room for LiteNet offset" {
    try std.testing.expectError(
        error.InvalidPort,
        game_mod.Game.create(std.testing.allocator, "worlds/unused_invalid_port", 65534),
    );
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
