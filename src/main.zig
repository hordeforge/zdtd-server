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
const zdtd_config = @import("server/zdtd_config.zig");
const mode_mod = @import("server/mode.zig");
const webui_mod = @import("server/webui.zig");
const io_fs = @import("util/io_fs.zig");
const version = @import("version.zig");

const help_text =
    \\Usage: zdtd [options]
    \\
    \\  Zig dedicated server for the stock 7DTD client wire (EAC off).
    \\
    \\Options:
    \\  --port N              TCP info port 0..65533; LiteNet uses N+2 (default 26902)
    \\  --world DIR           zdtd save/overlay dir (default worlds/zdtd_default)
    \\  --map DIR             stock Data/Worlds/<Name> (dtm + prefabs)
    \\  --game-dir DIR        install root (Data/Worlds + Data/Config)
    \\  --world-name NAME     Navezgane | Pregen06k01 | … (needs --game-dir unless --map)
    \\  --serverconfig PATH   stock-like ServerSettings XML (file must exist; see serverconfig.example.xml)
    \\  --mode NAME           gamemode pack modes/<NAME>.toml (data-only; see docs/GAME_OPTIONS.md)
    \\  --admin-port N        TCP admin console on 127.0.0.1 (0 = off; give/tele/save/kick/say)
    \\  --webui-port N        HTTP ops UI (0 = off; requires secret; see docs/WEBUI.md)
    \\  --webui-bind ADDR     webui bind, loopback only: 127.0.0.1 or localhost (default 127.0.0.1)
    \\  --webui-secret STR    shared secret, min 8 chars (prefer env ZDTD_WEBUI_SECRET; CLI visible in ps)
    \\  --quests PATH         explicit quests.xml (file must exist)
    \\  --config-dir DIR      stock Data/Config dir (XML assets; dir must exist)
    \\  --config-overrides DIR
    \\                        dir of xpath patch XMLs (repeatable; filename order; dir must exist)
    \\  --worldgen-seed U64   procedural terrain, decimal or 0x hex (conflicts with --map)
    \\  --ticks N             run N ticks then save and exit (0 = run forever)
    \\  --once                run one tick then save and exit (conflicts with --ticks)
    \\  -q, --quiet           suppress startup banners (keeps config line, warnings, errors)
    \\  -V, -v, --version     print product and stock wire versions and exit
    \\  -h, --help            show this help
    \\  --                    end of options (no positionals follow)
    \\
    \\Value forms: --flag VALUE or --flag=VALUE
    \\Precedence: CLI > env (webui secret) > world/zdtd.toml > CWD zdtd.toml >
    \\            mode pack (if --mode or [mode] name) > --serverconfig keys > code defaults.
    \\            See docs/GAME_OPTIONS.md.
    \\
    \\Examples:
    \\  zdtd --port 27002 --world worlds/zdtd_default
    \\  zdtd --mode default --port 27002
    \\  zdtd --game-dir "$GAME" --world-name Navezgane --world worlds/nav_save
    \\  zdtd --map "$GAME/Data/Worlds/Pregen06k01" --world worlds/pregen_run
    \\  zdtd --serverconfig serverconfig.xml --admin-port 8081
    \\  ZDTD_WEBUI_SECRET=… zdtd --webui-port 8080
    \\  zdtd --worldgen-seed 42 --once
    \\  zdtd --quiet --once --port 0
    \\
    \\Exit codes: 0 success, 1 runtime error (config load, startup), 2 usage error.
    \\
;

fn usageError(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    std.debug.print("zdtd: " ++ fmt ++ "\nzdtd: try 'zdtd --help'\n", fmt_args);
    std.process.exit(2);
}

/// Runtime (non-usage) startup failure: the CLI was fine, the environment was
/// not. No "--help" hint; exit 1 so scripts can tell it from a usage error.
fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    std.debug.print("zdtd: " ++ fmt ++ "\n", fmt_args);
    std.process.exit(1);
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

/// Resolve a value for `--flag` or `--flag=value`. Rejects empty values in
/// both forms (`--flag=` and `--flag ""`). Also rejects bare next-tokens that
/// look like another option (`--port --world`) so the real mistake is clear.
fn flagValue(it: *std.process.Args.Iterator, flag: []const u8, inline_val: ?[]const u8) []const u8 {
    const v = inline_val orelse it.next() orelse
        usageError("option '{s}' requires a value", .{flag});
    if (v.len == 0) usageError("option '{s}' requires a value", .{flag});
    // Space-separated form only: `--flag --other` is almost always a missing value.
    // Inline `--flag=--other` is allowed (paths/secrets can start with '-').
    if (inline_val == null and looksLikeOption(v)) {
        usageError("option '{s}' requires a value (got '{s}')", .{ flag, v });
    }
    return v;
}

/// True if `s` looks like a CLI option token rather than a flag value.
fn looksLikeOption(s: []const u8) bool {
    if (s.len == 0 or s[0] != '-') return false;
    // Bare "-" is unusual as a path; treat as option-like.
    if (s.len == 1) return true;
    // Negative integers are valid for signed types; none of our flags take them
    // via flagValue alone before flagInt, but keep digit forms as values.
    if (s[1] >= '0' and s[1] <= '9') return false;
    return true;
}

fn flagInt(comptime T: type, flag: []const u8, s: []const u8, base: u8) T {
    // Leading '-' on unsigned parse is Overflow; say so clearly instead of
    // dumping maxInt (u64 max is unreadable in usage text).
    if (s.len > 0 and s[0] == '-' and @typeInfo(T).int.signedness == .unsigned) {
        usageError(
            "value '{s}' for option '{s}' is out of range (expected non-negative integer)",
            .{ s, flag },
        );
    }
    return std.fmt.parseInt(T, s, base) catch |err| switch (err) {
        error.Overflow => usageError(
            "value '{s}' for option '{s}' is out of range (expected 0 to {d})",
            .{ s, flag, std.math.maxInt(T) },
        ),
        error.InvalidCharacter => usageError(
            "invalid value '{s}' for option '{s}' (expected integer)",
            .{ s, flag },
        ),
    };
}

/// ServerPort 0..65533 so LiteNet can bind port+2 without wrapping past u16.
fn flagServerPort(flag: []const u8, s: []const u8) u16 {
    // Parse as u32 so values past 65535 get the same 0..65533 message (not u16 max).
    if (s.len > 0 and s[0] == '-') {
        usageError(
            "value '{s}' for option '{s}' is out of range (expected 0 to 65533)",
            .{ s, flag },
        );
    }
    const p = std.fmt.parseInt(u32, s, 10) catch |err| switch (err) {
        error.Overflow => usageError(
            "value '{s}' for option '{s}' is out of range (expected 0 to 65533)",
            .{ s, flag },
        ),
        error.InvalidCharacter => usageError(
            "invalid value '{s}' for option '{s}' (expected integer)",
            .{ s, flag },
        ),
    };
    if (p > std.math.maxInt(u16) - 2) {
        usageError(
            "value for '{s}' must be between 0 and 65533 (LiteNet uses port+2)",
            .{flag},
        );
    }
    return @intCast(p);
}

/// Non-essential stderr (startup banners). Always print warnings via std.debug.print.
fn infoLog(quiet: bool, comptime fmt: []const u8, fmt_args: anytype) void {
    if (quiet) return;
    std.debug.print(fmt, fmt_args);
}

/// Split `--name` / `--name=value` into (name, optional value).
fn splitFlag(a: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
        return .{ .name = a[0..eq], .value = a[eq + 1 ..] };
    }
    return .{ .name = a, .value = null };
}

const known_flags = [_][]const u8{
    "--port",       "--world",            "--map",           "--game-dir",
    "--world-name", "--serverconfig",     "--mode",          "--admin-port",
    "--webui-port", "--webui-bind",       "--webui-secret",  "--quests",
    "--config-dir", "--config-overrides", "--worldgen-seed", "--ticks",
    "--once",       "--quiet",            "--version",       "--help",
    "-V",           "-v",                 "-q",              "-h",
};

/// Levenshtein distance, capped by buffer size (flags are short).
fn editDistance(a: []const u8, b: []const u8) usize {
    var prev: [40]usize = undefined;
    var cur: [40]usize = undefined;
    if (a.len >= prev.len or b.len >= prev.len) return a.len + b.len;
    for (0..b.len + 1) |j| prev[j] = j;
    for (0..a.len) |i| {
        cur[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            cur[j + 1] = @min(prev[j] + cost, @min(cur[j] + 1, prev[j + 1] + 1));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Nearest known flag within edit distance 2, for typo hints.
fn suggestFlag(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (known_flags) |f| {
        const d = editDistance(name, f);
        if (d < best_d) {
            best_d = d;
            best = f;
        }
    }
    return best;
}

fn resolveWorldName(cli_name: ?[]const u8, config_name: []const u8) ?[]const u8 {
    if (cli_name) |name| return name;
    return if (config_name.len > 0) config_name else null;
}

fn isLoopbackBind(host: []const u8) bool {
    // IPv4 only (webui parseIpv4 / tcp_listen listen are IPv4).
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "localhost");
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
    var webui_port: u16 = 0;
    var webui_bind: []const u8 = "127.0.0.1";
    var webui_secret: []const u8 = "";
    var webui_secret_cli = false;
    var max_ticks: u64 = 0;
    var once = false;
    var ticks_cli = false;
    var quiet = false;
    var worldgen_seed: ?u64 = null;
    var mode_name_cli: ?[]const u8 = null;
    var map_path_buf: [1024]u8 = undefined;
    var cfg_owned: ?server_config.Config = null;
    defer if (cfg_owned) |*c| c.deinit();

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv0
    while (it.next()) |a| {
        const parts = splitFlag(a);
        const name = parts.name;
        const inline_val = parts.value;

        // POSIX end-of-options: no positionals are accepted after this either.
        if (std.mem.eql(u8, name, "--") and inline_val == null) {
            while (it.next()) |rest| {
                usageError("unexpected argument '{s}' (zdtd takes options only, not positionals)", .{rest});
            }
            break;
        }

        if (std.mem.eql(u8, name, "--port")) {
            port = flagServerPort(name, flagValue(&it, name, inline_val));
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
        } else if (std.mem.eql(u8, name, "--mode")) {
            mode_name_cli = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--admin-port")) {
            admin_port = flagInt(u16, name, flagValue(&it, name, inline_val), 10);
            admin_port_cli = true;
        } else if (std.mem.eql(u8, name, "--webui-port")) {
            webui_port = flagInt(u16, name, flagValue(&it, name, inline_val), 10);
        } else if (std.mem.eql(u8, name, "--webui-bind")) {
            webui_bind = flagValue(&it, name, inline_val);
        } else if (std.mem.eql(u8, name, "--webui-secret")) {
            webui_secret = flagValue(&it, name, inline_val);
            webui_secret_cli = true;
        } else if (std.mem.eql(u8, name, "--worldgen-seed")) {
            worldgen_seed = flagInt(u64, name, flagValue(&it, name, inline_val), 0);
        } else if (std.mem.eql(u8, name, "--ticks")) {
            if (once) usageError("options '--ticks' and '--once' cannot be used together", .{});
            max_ticks = flagInt(u64, name, flagValue(&it, name, inline_val), 10);
            ticks_cli = true;
        } else if (std.mem.eql(u8, name, "--once")) {
            if (inline_val != null) usageError("option '--once' does not take a value", .{});
            if (ticks_cli) usageError("options '--ticks' and '--once' cannot be used together", .{});
            once = true;
            max_ticks = 1;
        } else if (std.mem.eql(u8, name, "--quiet") or std.mem.eql(u8, name, "-q")) {
            if (inline_val != null) usageError("option '{s}' does not take a value", .{name});
            quiet = true;
        } else if (std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V") or std.mem.eql(u8, name, "-v")) {
            if (inline_val != null) usageError("option '{s}' does not take a value", .{name});
            printStdout("zdtd {s} (stock wire {s})\n", .{ version.product, version.stock_wire });
            return;
        } else if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (inline_val != null) usageError("option '{s}' does not take a value", .{name});
            printStdout("{s}", .{help_text});
            return;
        } else if (std.mem.startsWith(u8, a, "-")) {
            if (suggestFlag(name)) |s| {
                usageError("unknown option '{s}' (did you mean '{s}'?)", .{ name, s });
            }
            usageError("unknown option '{s}'", .{name});
        } else {
            usageError("unexpected argument '{s}' (zdtd takes options only, not positionals)", .{a});
        }
    }

    if (map_dir != null and worldgen_seed != null) {
        usageError("options '--map' and '--worldgen-seed' select different terrain sources", .{});
    }
    if (world_name_cli and map_dir == null and game_dir == null) {
        usageError("option '--world-name' requires '--game-dir' (or use '--map' directly)", .{});
    }

    // Fail closed on operator-supplied paths before Game.create (clearer than
    // a late FileNotFound from deep inside asset/map load).
    if (game_dir) |gd| {
        if (!io_fs.dirExistsSimple(gd)) {
            fatal("game install not found: '{s}' (check --game-dir)", .{gd});
        }
    }
    if (map_dir) |md| {
        if (!io_fs.dirExistsSimple(md)) {
            fatal("map directory not found: '{s}' (check --map)", .{md});
        }
    }
    if (config_dir) |cd| {
        if (!io_fs.dirExistsSimple(cd)) {
            fatal("config directory not found: '{s}' (check --config-dir)", .{cd});
        }
    }
    if (quests_path) |qp| {
        if (!io_fs.fileExistsSimple(qp)) {
            fatal("quests file not found: '{s}' (check --quests)", .{qp});
        }
    }
    for (config_overrides.items) |od| {
        if (!io_fs.dirExistsSimple(od)) {
            fatal("config-overrides directory not found: '{s}'", .{od});
        }
    }

    if (serverconfig_path) |scp| {
        // Explicit path: fail fast (do not silently run with defaults).
        if (!io_fs.fileExistsSimple(scp)) {
            fatal("serverconfig file not found: '{s}' (check --serverconfig)", .{scp});
        }
        cfg_owned = server_config.loadFromPath(gpa, scp) catch |err| {
            fatal("cannot load --serverconfig '{s}': {s}", .{ scp, @errorName(err) });
        };
        if (cfg_owned) |c| {
            if (!port_cli) port = c.port;
            if (!admin_port_cli and c.admin_port != 0) admin_port = c.admin_port;
            // GameName is only the save display name (resolveWorldName reads it
            // from cfg directly); GameWorld alone selects map identity.
            // GameWorld only fills map identity when CLI did not set --world-name.
            if (!world_name_cli and c.game_world.len > 0 and map_dir == null and game_dir != null) {
                world_name = c.game_world;
            }
        }
    }

    // ServerPort may also come from serverconfig.xml, so validate the effective
    // value after applying precedence as well as at CLI parse time.
    if (port > std.math.maxInt(u16) - 2) {
        // File-sourced value: runtime config error (exit 1), not a CLI usage typo.
        if (port_cli) {
            usageError("value for '--port' must be between 0 and 65533 (LiteNet uses port+2)", .{});
        }
        fatal("effective ServerPort {d} out of range 0..65533 (LiteNet uses port+2)", .{port});
    }

    // Resolve --game-dir + --world-name → map path when --map not set.
    // Require --game-dir (or serverconfig paths); no absolute Steam default.
    if (map_dir == null) {
        if (world_name) |wn| {
            if (game_dir) |root| {
                const candidate = try std.fmt.bufPrint(&map_path_buf, "{s}/Data/Worlds/{s}", .{ root, wn });
                if (io_fs.dirExistsSimple(candidate)) {
                    map_dir = candidate;
                } else if (world_name_cli) {
                    usageError("world '{s}' not found under --game-dir '{s}/Data/Worlds'", .{ wn, root });
                } else {
                    fatal("configured world '{s}' not found under '{s}/Data/Worlds'", .{ wn, root });
                }
            } else {
                fatal("configured world '{s}' requires --game-dir or --map", .{wn});
            }
        }
    }

    const resolved_world_name = resolveWorldName(
        if (world_name_cli) world_name else null,
        if (cfg_owned) |c| c.world_name else if (world_name) |name| name else "",
    );
    // Effective config: loaded file or struct defaults (single source in config.zig).
    const cfg: server_config.Config = cfg_owned orelse .{};

    // CLI > env ZDTD_WEBUI_SECRET (prefer env: not visible in process listings).
    if (webui_secret.len == 0) {
        if (std.process.Environ.getPosix(init.environ, "ZDTD_WEBUI_SECRET")) |env_secret| {
            if (env_secret.len > 0) webui_secret = env_secret;
        }
    } else if (webui_secret_cli) {
        // Always warn: secrets in argv are a real ops footgun.
        std.debug.print(
            "zdtd: warning: --webui-secret is visible in process listings; prefer env ZDTD_WEBUI_SECRET\n",
            .{},
        );
    }

    if (webui_port == 0 and (webui_secret_cli or !std.mem.eql(u8, webui_bind, "127.0.0.1"))) {
        std.debug.print(
            "zdtd: warning: --webui-bind/--webui-secret have no effect without --webui-port\n",
            .{},
        );
    }
    if (webui_port != 0 and webui_secret.len == 0) {
        usageError("--webui-port requires --webui-secret or non-empty env ZDTD_WEBUI_SECRET", .{});
    }
    // Fail fast with a clear message (game.webui also enforces; keep operator UX here).
    if (webui_port != 0 and webui_secret.len < webui_mod.min_secret) {
        usageError(
            "webui secret must be at least {d} characters (got {d}); use a longer ZDTD_WEBUI_SECRET",
            .{ webui_mod.min_secret, webui_secret.len },
        );
    }
    if (webui_port != 0 and !isLoopbackBind(webui_bind)) {
        usageError("--webui-bind must be loopback (127.0.0.1 or localhost); use a TLS reverse proxy for remote access", .{});
    }

    // InitOptions: serverconfig → optional mode pack → zdtd.toml stream/authority.
    // CLI-resolved fields (paths, ports, seed) are already set on the struct.
    var init_opts: game_mod.InitOptions = .{
        .map_dir = map_dir,
        .game_dir = game_dir,
        .config_dir = config_dir,
        .config_overrides = config_overrides.items,
        .quests_path = quests_path,
        .admin_port = admin_port,
        .webui_port = webui_port,
        .webui_bind = webui_bind,
        .webui_secret = webui_secret,
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
    };

    var toml_path_buf: [1024]u8 = undefined;
    const world_toml = std.fmt.bufPrint(&toml_path_buf, "{s}/zdtd.toml", .{world_dir}) catch null;
    const toml_path: ?[]const u8 = blk: {
        if (world_toml) |wt| {
            if (io_fs.fileExistsSimple(wt)) break :blk wt;
        }
        if (io_fs.fileExistsSimple("zdtd.toml")) break :blk "zdtd.toml";
        break :blk null;
    };
    var toml_owned: ?zdtd_config.File = null;
    defer if (toml_owned) |*tf| tf.deinit();
    if (toml_path) |tp| {
        toml_owned = zdtd_config.loadFromPath(gpa, tp) catch |err| {
            fatal("cannot load zdtd.toml '{s}': {s}", .{ tp, @errorName(err) });
        };
        infoLog(quiet, "zdtd: loaded {s}\n", .{tp});
    }

    // Mode pack: --mode NAME wins over zdtd.toml [mode] name. Optional.
    const mode_name: ?[]const u8 = blk: {
        if (mode_name_cli) |m| break :blk m;
        if (toml_owned) |*tf| {
            if (tf.mode.name) |n| break :blk n;
        }
        break :blk null;
    };
    var mode_owned: ?mode_mod.Pack = null;
    defer if (mode_owned) |*mp| mp.deinit();
    if (mode_name) |mn| {
        if (!mode_mod.isValidModeName(mn)) {
            // Bad token shape is a usage error (exit 2), not a missing file.
            usageError("invalid --mode name '{s}' (use [A-Za-z0-9_] only)", .{mn});
        }
        mode_owned = mode_mod.loadByName(gpa, mn) catch |err| {
            fatal("cannot load mode '{s}' (modes/{s}.toml): {s}", .{ mn, mn, @errorName(err) });
        };
        if (mode_owned) |*mp| {
            if (!std.mem.eql(u8, mp.name, mn)) {
                fatal("mode file modes/{s}.toml declares name '{s}'", .{ mn, mp.name });
            }
            mode_mod.applyToInitOptions(mp, &init_opts);
            infoLog(quiet, "zdtd: mode={s}\n", .{mp.name});
        }
    }

    if (toml_owned) |*tf| {
        zdtd_config.applyToInitOptions(tf, &init_opts);
        if (tf.authority.mode) |mode_s| {
            if (server_config.AuthorityMode.parse(mode_s)) |am| {
                init_opts.authority_mode = am;
            } else {
                // Keep as warning so misconfigured authority is still visible under --quiet.
                std.debug.print(
                    "zdtd: zdtd.toml authority.mode '{s}' unknown (use observe|permissive|correct); keeping {s}\n",
                    .{ mode_s, @tagName(init_opts.authority_mode) },
                );
            }
        }
    }
    // Always sanitize after merge (mode pack and/or toml may set stream/authority knobs).
    zdtd_config.sanitizeInitOptions(&init_opts);

    if (init_opts.authority_mode == .observe) {
        std.debug.print(
            "zdtd: warning: authority mode is observe (illegal C2S logged only; prefer correct for play)\n",
            .{},
        );
    }
    if (admin_port != 0) {
        std.debug.print(
            "zdtd: warning: AdminPort {d} opens unauthenticated console on 127.0.0.1 (not for shared hosts)\n",
            .{admin_port},
        );
    }

    const g = game_mod.Game.createWithOptions(gpa, world_dir, port, init_opts) catch |err| {
        fatal("cannot start server: {s} (world '{s}', port {d})", .{ @errorName(err), world_dir, port });
    };
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Always print the one-line config summary: scripts (e.g. auto_join) wait on
    // "zdtd: config port=" as the ready signal. Password / webui secret never printed.
    std.debug.print(
        "zdtd: config port={d} max_players={d} view_radius={d} admin_port={d} webui_port={d} password={s} authority={s} wire_chunks={s}\n",
        .{
            port,
            g.max_players,
            g.view_radius,
            admin_port,
            webui_port,
            if (init_opts.password.len > 0) "set" else "open",
            @tagName(init_opts.authority_mode),
            if (g.wire_chunks) "on" else "off",
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
        infoLog(quiet,
            \\zdtd {s}
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2)
            \\  save={s}
            \\  map={s} dtm={d}x{d} spawn=({d},{d},{d})
            \\  prefabs={d} water_sources={d}
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d}
            \\
        , .{
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
        });
    } else if (g.world.terrain_source == .proc) {
        const seed = if (g.world.worldgen) |wg| wg.seed else 0;
        infoLog(quiet,
            \\zdtd {s}
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2) world={s}
            \\  terrain=proc seed={d} spawn=({d},{d},{d})
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d}
            \\
        , .{
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
        });
    } else {
        infoLog(quiet,
            \\zdtd {s}
            \\  connect (client): {d}  (TCP info; client then UDP {d} = port+2) world={s}
            \\  quests={s} defs={d} starter={s} (id={d})
            \\  challenge=0x{X:0>2} tick={d}Hz mappings={d} (flat; --map or --worldgen-seed)
            \\
        , .{
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
        });
    }

    if (max_ticks == 0) {
        try g.run();
    } else {
        var i: u64 = 0;
        while (i < max_ticks) : (i += 1) {
            try g.step();
            g.fillWebuiSnap();
        }
        try g.world.saveAll();
        const snap = g.harness.snapshot();
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        apm.report.writeText(&snap, &w) catch |err|
            std.debug.print("zdtd: apm report truncated: {s}\n", .{@errorName(err)});
        printStdout("{s}", .{w.buffered()});
        if (once) infoLog(quiet, "zdtd --once complete\n", .{});
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
    _ = @import("plugin/root.zig");
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

test "typo suggestion finds nearest flag" {
    try std.testing.expectEqualStrings("--port", suggestFlag("--prot").?);
    try std.testing.expectEqualStrings("--ticks", suggestFlag("--tick").?);
    try std.testing.expectEqualStrings("--world", suggestFlag("-world").?);
    try std.testing.expectEqualStrings("-v", suggestFlag("-v").?);
    try std.testing.expect(suggestFlag("--zzzzzzzz") == null);
    try std.testing.expectEqual(@as(usize, 0), editDistance("--map", "--map"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("ab", "ba"));
}

test "looksLikeOption rejects next-flag tokens as values" {
    try std.testing.expect(looksLikeOption("--world"));
    try std.testing.expect(looksLikeOption("-h"));
    try std.testing.expect(looksLikeOption("--")); // end-of-options token
    try std.testing.expect(looksLikeOption("-")); // bare dash is not a path value
    try std.testing.expect(!looksLikeOption("27002"));
    try std.testing.expect(!looksLikeOption("-1")); // numeric, not an option form we treat specially
    try std.testing.expect(!looksLikeOption("worlds/zdtd_default"));
    try std.testing.expect(!looksLikeOption(""));
}

test "flagServerPort accepts LiteNet-safe range" {
    try std.testing.expectEqual(@as(u16, 0), flagServerPort("--port", "0"));
    try std.testing.expectEqual(@as(u16, 26902), flagServerPort("--port", "26902"));
    try std.testing.expectEqual(@as(u16, 65533), flagServerPort("--port", "65533"));
}

const cli_flag_corpus = [_][]const u8{
    "",
    "--port",
    "--port=27002",
    "--world=",
    "--world=worlds/zdtd_default",
    "--prot",
    "-h",
    "-1",
    "27002",
    "--",
    "----",
    "--port=" ++ ("9" ** 40),
    "\x00--help",
    "--webui-secret=s3cr3t",
};

test "fuzz CLI flag helpers" {
    try std.testing.fuzz({}, fuzzCliFlags, .{ .corpus = &cli_flag_corpus });
}

fn fuzzCliFlags(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var storage: [512]u8 = undefined;
    const len: usize = smith.slice(&storage);
    const s = storage[0..len];
    const split = splitFlag(s);
    try std.testing.expect(split.name.len <= s.len);
    if (split.value) |v| try std.testing.expect(v.len <= s.len);
    _ = looksLikeOption(s);
    _ = suggestFlag(s);
    _ = editDistance(s, "--port");
    _ = resolveWorldName(if (len == 0) null else s, "cfg");
    _ = isLoopbackBind(s);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

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
