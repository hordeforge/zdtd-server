//! zdtd: Zig dedicated server for 7 Days to Die (client wire).
//! Usage: zdtd [--port N] [--world DIR] [--map STOCK_WORLD_DIR] [--ticks N] [--once]

const std = @import("std");
const game_mod = @import("server/game.zig");
const packages = @import("wire/packages.zig");
const frame = @import("wire/frame.zig");
const protocol = @import("protocol.zig");
const apm = @import("apm/root.zig");
const world_store = @import("world/store.zig");
const server_config = @import("server/config.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var port: u16 = 26902;
    var world_dir: []const u8 = "worlds/zdtd_default";
    var map_dir: ?[]const u8 = null;
    var game_dir: ?[]const u8 = null;
    var config_dir: ?[]const u8 = null;
    var quests_path: ?[]const u8 = null;
    var world_name: ?[]const u8 = null;
    var serverconfig_path: ?[]const u8 = null;
    var admin_port: u16 = 0;
    var max_ticks: u64 = 0;
    var once = false;
    var map_path_buf: [1024]u8 = undefined;
    var cfg_owned: ?server_config.Config = null;
    defer if (cfg_owned) |*c| c.deinit();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--port")) {
            if (it.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
        } else if (std.mem.eql(u8, a, "--world")) {
            if (it.next()) |w| world_dir = w;
        } else if (std.mem.eql(u8, a, "--map")) {
            if (it.next()) |m| map_dir = m;
        } else if (std.mem.eql(u8, a, "--game-dir")) {
            if (it.next()) |gdir| game_dir = gdir;
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            if (it.next()) |cd| config_dir = cd;
        } else if (std.mem.eql(u8, a, "--quests")) {
            if (it.next()) |qp| quests_path = qp;
        } else if (std.mem.eql(u8, a, "--world-name")) {
            if (it.next()) |wn| world_name = wn;
        } else if (std.mem.eql(u8, a, "--serverconfig")) {
            if (it.next()) |sc| serverconfig_path = sc;
        } else if (std.mem.eql(u8, a, "--admin-port")) {
            if (it.next()) |ap| admin_port = try std.fmt.parseInt(u16, ap, 10);
        } else if (std.mem.eql(u8, a, "--ticks")) {
            if (it.next()) |t| max_ticks = try std.fmt.parseInt(u64, t, 10);
        } else if (std.mem.eql(u8, a, "--once")) {
            once = true;
            max_ticks = 1;
        } else if (std.mem.eql(u8, a, "--help")) {
            std.debug.print(
                \\zdtd [--port 26902] [--world SAVE_DIR] [--map STOCK_WORLD_DIR] [--ticks N] [--once]
                \\     [--game-dir DEDI_OR_CLIENT_ROOT] [--world-name Navezgane|Pregen06k01|…]
                \\     [--config-dir Data/Config] [--quests path/to/quests.xml]
                \\     [--serverconfig path/serverconfig.xml] [--admin-port N]
                \\
                \\  --port           ServerPort: TCP GameServerInfo; LiteNet uses port+2
                \\  --world          zdtd save/overlay dir (default worlds/zdtd_default)
                \\  --map            stock Data/Worlds/<Name>
                \\  --game-dir       install root (Data/Worlds + Data/Config)
                \\  --world-name     Navezgane | Pregen06k01 | …
                \\  --serverconfig   stock-like ServerSettings XML (port, GameName, …)
                \\  --admin-port     TCP admin console (give/tele/save/kick/say)
                \\  --quests         explicit quests.xml
                \\
            , .{});
            return;
        }
    }

    if (serverconfig_path) |scp| {
        cfg_owned = server_config.loadFromPath(gpa, scp) catch null;
        if (cfg_owned) |cfg| {
            port = cfg.port;
            if (cfg.admin_port != 0) admin_port = cfg.admin_port;
            if (cfg.world_name.len > 0) world_name = cfg.world_name;
            if (cfg.game_world.len > 0 and map_dir == null and game_dir != null) {
                world_name = cfg.game_world;
            }
        }
    }

    // Resolve --game-dir + --world-name → map path when --map not set.
    if (map_dir == null) {
        if (world_name) |wn| {
            // If looks like a save name only, still try as world folder under game-dir
            const root = game_dir orelse defaultGameDir();
            const candidate = try std.fmt.bufPrint(&map_path_buf, "{s}/Data/Worlds/{s}", .{ root, wn });
            // Fall back to a flat world instead of crashing when the resolved world
            // folder is absent (e.g. serverconfig GameName with no matching save).
            if (dirExists(candidate)) {
                map_dir = candidate;
                if (game_dir == null) game_dir = root;
            } else {
                std.debug.print("zdtd: world '{s}' not found under {s}/Data/Worlds; using flat world\n", .{ wn, root });
            }
        }
    }

    const resolved_world_name: ?[]const u8 = blk: {
        if (cfg_owned) |c| {
            if (c.world_name.len > 0) break :blk c.world_name;
        }
        break :blk world_name;
    };
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, port, .{
        .map_dir = map_dir,
        .game_dir = game_dir,
        .config_dir = config_dir,
        .quests_path = quests_path,
        .admin_port = admin_port,
        .world_name = resolved_world_name,
        .view_radius = if (cfg_owned) |c| c.view_radius else 4,
        .password = if (cfg_owned) |c| c.password else "",
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
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }

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
            \\zdtd 0.1.0
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2)
            \\  save={s}
            \\  map={s} dtm={d}x{d} spawn=({d},{d},{d})
            \\  prefabs={d} water_sources={d}
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d}
            \\
        ,
            .{
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
    } else {
        std.debug.print(
            \\zdtd 0.1.0
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2) world={s}
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d} (flat; --map or --world-name Navezgane)
            \\
        ,
            .{
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
        apm.report.writeText(&snap, &w) catch {};
        std.debug.print("{s}", .{w.buffered()});
        if (once) std.debug.print("zdtd --once complete\n", .{});
    }
}

test {
    _ = @import("wire/binary.zig");
    _ = @import("wire/frame.zig");
    _ = @import("wire/packages.zig");
    _ = @import("wire/stock_inv.zig");
    _ = @import("wire/stock_te.zig");
    _ = @import("litenet/packet.zig");
    _ = @import("world/store.zig");
    _ = @import("world/containers.zig");
    _ = @import("world/dtm.zig");
    _ = @import("world/dem.zig");
    _ = @import("world/workstations.zig");
    _ = @import("world/prefabs.zig");
    _ = @import("world/water.zig");
    _ = @import("ecs/root.zig");
    _ = @import("ecs/world.zig");
    _ = @import("ecs/systems.zig");
    _ = @import("ecs/quest.zig");
    _ = @import("ecs/electric.zig");
    _ = @import("ecs/aidirector.zig");
    _ = @import("util/parallel.zig");
    _ = @import("assets/root.zig");
    _ = @import("assets/quests.zig");
    _ = @import("assets/blocks.zig");
    _ = @import("assets/items.zig");
    _ = @import("assets/entities.zig");
    _ = @import("assets/recipes.zig");
    _ = @import("assets/loot.zig");
    _ = @import("assets/entitygroups.zig");
    _ = @import("assets/maxdamage.zig");
    _ = @import("ecs/path.zig");
    _ = @import("ecs/interest.zig");
    _ = @import("ecs/inventory.zig");
    _ = @import("server/admin.zig");
    _ = @import("server/config.zig");
    _ = @import("server/serverinfo_tcp.zig");
    _ = @import("apm/root.zig");
    _ = @import("apm/metrics.zig");
    _ = @import("apm/profiler.zig");
    _ = @import("apm/report.zig");
    _ = @import("apm/clock.zig");
    _ = @import("server/scenarios.zig");
    _ = @import("world/sleepers.zig");
    _ = @import("world/tts.zig");
    _ = @import("world/blocks_nim.zig");
    _ = @import("world/biomes.zig");
}

test "integration world persist + damage + packages" {
    const dir = "worlds/zdtd_itest";
    mkdirP("worlds");
    mkdirP(dir);

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
    try std.testing.expectEqual(@as(u8, 70), c.heightAt(10, 10));

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

fn defaultGameDir() []const u8 {
    // Common dedicated install path on this machine / Steam defaults.
    return "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
}

/// True when `path` can be opened as a directory (avoids a fatal map load on a
/// missing world folder). Best-effort: any open failure reports absent.
fn dirExists(path: []const u8) bool {
    const linux = std.os.linux;
    if (path.len >= 1024) return false;
    var z: [1024]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

fn mkdirP(path: []const u8) void {
    const linux = std.os.linux;
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (buf[i] != '/') continue;
        buf[i] = 0;
        _ = linux.mkdir(buf[0..i :0].ptr, 0o755);
        buf[i] = '/';
    }
    var zbuf: [513]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = linux.mkdir(zbuf[0..path.len :0].ptr, 0o755);
}
