//! zdtd: Zig dedicated server for 7 Days to Die (client wire).
//! Run `zdtd --help` for CLI options and precedence.

const std = @import("std");
const game_mod = @import("server/game.zig");
const packages = @import("wire/packages.zig");
const frame = @import("wire/frame.zig");
const protocol = @import("protocol.zig");
const apm = @import("apm/root.zig");
const world_store = @import("world/store.zig");
const ecs_mod = @import("ecs/root.zig");
const server_config = @import("server/config.zig");
const zdtd_config = @import("server/zdtd_config.zig");
const mode_mod = @import("server/mode.zig");
const webui_mod = @import("server/webui.zig");
const io_fs = @import("util/io_fs.zig");
const log = @import("util/log.zig");
const clock = @import("util/clock.zig");
const version = @import("version.zig");

const help_text =
    \\Usage: zdtd [options]
    \\
    \\  Zig dedicated server for the stock 7DTD client wire (EAC off).
    \\
    \\Options:
    \\  --port N              TCP info port 0..65533; LiteNet uses N+2 (default 26902;
    \\                        0 = offline deterministic mode, pair with --once/--ticks)
    \\  --world DIR           zdtd save/overlay dir (default worlds/zdtd_default)
    \\  --map DIR             stock Data/Worlds/<Name> (dtm + prefabs)
    \\  --game-dir DIR        install root (Data/Worlds + Data/Config)
    \\  --world-name NAME     Navezgane | Pregen06k01 | … (needs --game-dir unless --map)
    \\  --serverconfig PATH   stock-like ServerSettings XML (file must exist; see serverconfig.example.xml)
    \\  --mode NAME           gamemode pack modes/<NAME>.toml (data-only; see docs/GAME_OPTIONS.md)
    \\  --admin-port N        stock telnet console (0 = off; loopback unless TelnetPassword is set)
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

/// Split the zdtd.toml `[plugin] modules` list (comma/space separated) into a
/// slice owned by the caller (free with gpa.free when len > 0). The path
/// strings point into the toml arena, which outlives the create call.
fn splitPluginModules(allocator: std.mem.Allocator, raw: []const u8) []const []const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, " ,");
    while (it.next() != null) count += 1;
    if (count == 0) return &.{};
    const list = allocator.alloc([]const u8, count) catch {
        // Never let a configured plugin set vanish silently: log the drop so
        // the operator sees why their zdtd.toml [plugin] modules did not load.
        std.debug.print("zdtd: cannot allocate plugin module list ({d} modules); plugins disabled\n", .{count});
        return &.{};
    };
    var i: usize = 0;
    it = std.mem.tokenizeAny(u8, raw, " ,");
    while (it.next()) |tok| {
        list[i] = tok;
        i += 1;
    }
    return list;
}

/// Command output (help, version, APM report) goes to stdout, not stderr, so
/// operators can pipe it. Callers pass an already-built slice: no intermediate
/// buffer, so a report longer than any fixed size still prints in full.
fn writeStdout(msg: []const u8) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    std.Io.File.stdout().writeStreamingAll(threaded.io(), msg) catch |err| {
        fatal("cannot write stdout: {s}", .{@errorName(err)});
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

/// Split `--name` / `--name=value` into (name, optional value).
fn splitFlag(a: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (std.mem.findScalar(u8, a, '=')) |eq| {
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

/// `--mode NAME` (or `[mode] name`) with no matching pack. Modes resolve as
/// `modes/<name>.toml` relative to the working directory, so list what is
/// actually there: a wrong CWD and a typo look identical without it.
fn fatalUnknownMode(allocator: std.mem.Allocator, name: []const u8) noreturn {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (io_fs.listFileNames(allocator, "modes")) |files| {
        for (files) |f| {
            const stem = if (std.mem.endsWith(u8, f, ".toml")) f[0 .. f.len - 5] else continue;
            w.print("{s}{s}", .{ if (w.buffered().len == 0) "" else ", ", stem }) catch break;
        }
    } else |_| {}
    const available = w.buffered();
    if (available.len == 0) {
        fatal("mode '{s}' not found (expected modes/{s}.toml under the working directory)", .{ name, name });
    }
    fatal(
        "mode '{s}' not found (expected modes/{s}.toml under the working directory); available: {s}",
        .{ name, name, available },
    );
}

fn resolveWorldName(cli_name: ?[]const u8, config_name: []const u8) ?[]const u8 {
    if (cli_name) |name| return name;
    return if (config_name.len > 0) config_name else null;
}

/// True when `name` is a single path segment safe to join under Data/Worlds/.
/// Rejects empty, absolute, parent, and multi-segment names so CLI/serverconfig
/// cannot escape `game-dir` via `../` or absolute paths.
fn isSafeWorldDirName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.findScalar(u8, name, 0) != null) return false;
    for (name) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
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
            var ver_buf: [128]u8 = undefined;
            writeStdout(std.fmt.bufPrint(
                &ver_buf,
                "zdtd {s} (stock wire {s})\n",
                .{ version.product, version.stock_wire },
            ) catch "zdtd\n");
            return;
        } else if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (inline_val != null) usageError("option '{s}' does not take a value", .{name});
            writeStdout(help_text);
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

    // Boot banners are emitted from inside Game.init too, so the flag has to be
    // visible process-wide before any of them run.
    log.setQuiet(quiet);

    if (map_dir != null and worldgen_seed != null) {
        usageError("options '--map' and '--worldgen-seed' select different terrain sources", .{});
    }
    if (world_name_cli and map_dir == null and game_dir == null) {
        usageError("option '--world-name' requires '--game-dir' (or use '--map' directly)", .{});
    }

    // Fail closed on operator-supplied paths before Game.create (clearer than
    // a late FileNotFound from deep inside asset/map load).
    if (game_dir) |gd| {
        if (!io_fs.dirExists(gd)) {
            fatal("game install not found: '{s}' (check --game-dir)", .{gd});
        }
    }
    if (map_dir) |md| {
        if (!io_fs.dirExists(md)) {
            fatal("map directory not found: '{s}' (check --map)", .{md});
        }
    }
    if (config_dir) |cd| {
        if (!io_fs.dirExists(cd)) {
            fatal("config directory not found: '{s}' (check --config-dir)", .{cd});
        }
    }
    if (quests_path) |qp| {
        if (!io_fs.fileExists(qp)) {
            fatal("quests file not found: '{s}' (check --quests)", .{qp});
        }
    }
    for (config_overrides.items) |od| {
        if (!io_fs.dirExists(od)) {
            fatal("config-overrides directory not found: '{s}'", .{od});
        }
    }

    // Stock serveradmin.xml sits next to serverconfig.xml (save root); fall
    // back to the config dir or game dir so an operator drop-in applies.
    var serveradmin_path: ?[]const u8 = null;
    if (serverconfig_path) |scp| {
        if (std.fs.path.dirname(scp)) |dir| {
            var p: [std.fs.max_path_bytes]u8 = undefined;
            const cand = std.fmt.bufPrint(&p, "{s}/serveradmin.xml", .{dir}) catch null;
            if (cand) |c| {
                if (io_fs.fileExists(c)) serveradmin_path = try gpa.dupe(u8, c);
            }
        }
    }
    if (serveradmin_path == null) {
        if (config_dir) |cd| {
            var p: [std.fs.max_path_bytes]u8 = undefined;
            const cand = std.fmt.bufPrint(&p, "{s}/serveradmin.xml", .{cd}) catch null;
            if (cand) |c| {
                if (io_fs.fileExists(c)) serveradmin_path = try gpa.dupe(u8, c);
            }
        }
    }
    if (serveradmin_path == null) {
        if (game_dir) |gd| {
            var p: [std.fs.max_path_bytes]u8 = undefined;
            const cand = std.fmt.bufPrint(&p, "{s}/serveradmin.xml", .{gd}) catch null;
            if (cand) |c| {
                if (io_fs.fileExists(c)) serveradmin_path = try gpa.dupe(u8, c);
            }
        }
    }

    if (serverconfig_path) |scp| {
        // Explicit path: fail fast (do not silently run with defaults).
        if (!io_fs.fileExists(scp)) {
            fatal("serverconfig file not found: '{s}' (check --serverconfig)", .{scp});
        }
        cfg_owned = server_config.loadFromPath(gpa, scp) catch |err| {
            fatal("cannot load --serverconfig '{s}': {s}", .{ scp, @errorName(err) });
        };
        if (cfg_owned) |c| {
            if (!port_cli) port = c.port;
            // Stock TelnetPort wins over the zdtd AdminPort alias when telnet is
            // enabled; AdminPort stays the fallback for existing zdtd configs.
            if (!admin_port_cli) {
                if (c.telnet_enabled and c.telnet_port != 0) {
                    admin_port = c.telnet_port;
                } else if (c.admin_port != 0) {
                    admin_port = c.admin_port;
                }
            }
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
            if (!isSafeWorldDirName(wn)) {
                if (world_name_cli) {
                    usageError("invalid --world-name '{s}' (single folder name under Data/Worlds only)", .{wn});
                }
                fatal("configured world name '{s}' is not a safe path segment under Data/Worlds", .{wn});
            }
            if (game_dir) |root| {
                const candidate = try std.fmt.bufPrint(&map_path_buf, "{s}/Data/Worlds/{s}", .{ root, wn });
                if (io_fs.dirExists(candidate)) {
                    map_dir = candidate;
                } else if (world_name_cli) {
                    // Missing directory, not a malformed option: exit 1 like the
                    // sibling '--map'/'--game-dir' checks above (exit 2 is for
                    // usage typos only).
                    fatal("world '{s}' not found under --game-dir '{s}/Data/Worlds' (check --world-name)", .{ wn, root });
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

    // Fail fast on TCP listen collisions (UDP LiteNet is port+2; it can share a
    // number with a TCP listener, so only TCP↔TCP overlaps are fatal here).
    if (admin_port != 0 and admin_port == port) {
        fatal("AdminPort/TelnetPort {d} collides with ServerPort (TCP GameServerInfo)", .{admin_port});
    }
    if (webui_port != 0 and webui_port == port) {
        fatal("webui port {d} collides with ServerPort (TCP GameServerInfo)", .{webui_port});
    }
    if (webui_port != 0 and admin_port != 0 and webui_port == admin_port) {
        fatal("webui port {d} collides with AdminPort/TelnetPort", .{webui_port});
    }

    // InitOptions: serverconfig → optional mode pack → zdtd.toml stream/authority.
    // CLI-resolved fields (paths, ports, seed) are already set on the struct.
    var init_opts: game_mod.InitOptions = .{
        .map_dir = map_dir,
        .game_dir = game_dir,
        .config_dir = config_dir,
        .config_overrides = config_overrides.items,
        .quests_path = quests_path,
        .serveradmin_path = serveradmin_path,
        .admin_port = admin_port,
        .webui_port = webui_port,
        .webui_bind = webui_bind,
        .webui_secret = webui_secret,
        .world_name = resolved_world_name,
        .server_description = cfg.server_description,
        .server_website_url = cfg.server_website_url,
        .region = cfg.region,
        .language = cfg.language,
        .play_group = cfg.play_group,
        .view_radius = cfg.view_radius,
        .max_players = cfg.max_players,
        .reserved_slots = cfg.reserved_slots,
        .reserved_slots_permission = cfg.reserved_slots_permission,
        .admin_slots = cfg.admin_slots,
        .admin_slots_permission = cfg.admin_slots_permission,
        .password = cfg.password,
        .telnet_password = cfg.telnet_password,
        .telnet_failed_login_limit = cfg.telnet_failed_login_limit,
        .telnet_failed_logins_blocktime = cfg.telnet_failed_logins_blocktime,
        .game_world = if (cfg.game_world.len > 0) cfg.game_world else "Navezgane",
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
        .land_claim_expiry_days = cfg.land_claim_expiry_days,
        .loot_respawn_days = cfg.loot_respawn_days,
        .worldgen_seed = worldgen_seed,
        .authority_mode = cfg.authority_mode,
        .sandbox_code = cfg.sandbox_code,
        .sandbox_preset = cfg.sandbox_preset,
    };

    var toml_path_buf: [1024]u8 = undefined;
    const world_toml = std.fmt.bufPrint(&toml_path_buf, "{s}/zdtd.toml", .{world_dir}) catch blk: {
        // World dir too long for the fixed buffer: do not silently run without
        // the operator's per-world config.
        std.debug.print("zdtd: world dir '{s}' too long; skipping world zdtd.toml\n", .{world_dir});
        break :blk null;
    };
    const toml_path: ?[]const u8 = blk: {
        if (world_toml) |wt| {
            if (io_fs.fileExists(wt)) break :blk wt;
        }
        if (io_fs.fileExists("zdtd.toml")) break :blk "zdtd.toml";
        break :blk null;
    };
    var toml_owned: ?zdtd_config.File = null;
    defer if (toml_owned) |*tf| tf.deinit();
    if (toml_path) |tp| {
        toml_owned = zdtd_config.loadFromPath(gpa, tp) catch |err| {
            fatal("cannot load zdtd.toml '{s}': {s}", .{ tp, @errorName(err) });
        };
        log.info("zdtd: loaded {s}\n", .{tp});
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
            if (mode_name_cli != null) {
                usageError("invalid --mode name '{s}' (use [A-Za-z0-9_] only)", .{mn});
            }
            fatal("invalid [mode] name '{s}' in zdtd.toml (use [A-Za-z0-9_] only)", .{mn});
        }
        mode_owned = mode_mod.loadByName(gpa, mn) catch |err| switch (err) {
            // Missing pack is the common operator mistake (typo, or running from
            // the wrong CWD): name the path and what is actually there instead
            // of leaking "FileNotFound".
            error.FileNotFound => fatalUnknownMode(gpa, mn),
            else => fatal("cannot load mode '{s}' (modes/{s}.toml): {s}", .{ mn, mn, @errorName(err) }),
        };
        if (mode_owned) |*mp| {
            if (!std.mem.eql(u8, mp.name, mn)) {
                fatal("mode file modes/{s}.toml declares name '{s}'", .{ mn, mp.name });
            }
            mode_mod.applyToInitOptions(mp, &init_opts);
            log.info("zdtd: mode={s}\n", .{mp.name});
        }
    }

    if (toml_owned) |*tf| {
        zdtd_config.applyToInitOptions(tf, &init_opts);
        // [plugin] modules is a comma-separated list; applyToInitOptions cannot
        // allocate, so split it here and free the list after the Game is created
        // (paths point into the toml arena; Game dupes the names it keeps).
        if (tf.plugin.modules) |m| init_opts.plugin_modules = splitPluginModules(gpa, m);
        if (tf.plugin.fuel) |fuel| init_opts.plugin_budget.fuel = fuel;
        if (tf.plugin.max_pages) |pages| init_opts.plugin_budget.max_memory_pages = pages;
        // authority.mode is validated + canonicalised at parse (binder
        // enum_by_name), so this is a straight apply.
        if (tf.authority.mode) |mode_s| {
            if (server_config.AuthorityMode.parse(mode_s)) |am| init_opts.authority_mode = am;
        }
    }
    // Effective sim rules: defaults < mode pack < zdtd.toml (ADR 0021). The
    // pack is the lower-precedence overlay; the operator's zdtd.toml wins.
    var rules_eff: ecs_mod.rules.Rules = .{};
    if (mode_owned) |*mp| ecs_mod.rules.mergeOverlay(&rules_eff, &mp.rules);
    if (toml_owned) |*tf| ecs_mod.rules.mergeOverlay(&rules_eff, &tf.rules);
    init_opts.rules = rules_eff;
    // Effective quest policy: mode pack < zdtd.toml (same precedence as
    // rules); defaults = builtin stock values (QuestPolicy{}).
    var qpol: ecs_mod.quest.QuestPolicy = .{};
    if (mode_owned) |*mp| {
        if (mp.quests.objective_kinds.len > 0) qpol.objective_kinds = mp.quests.objective_kinds;
        if (mp.quests.default_kill_count) |v| qpol.default_kill_count = v;
        if (mp.quests.kill_per_tier) |v| qpol.kill_per_tier = v;
        if (mp.quests.goto_radius) |v| qpol.goto_radius = v;
        if (mp.quests.stay_radius) |v| qpol.stay_radius = v;
    }
    if (toml_owned) |*tf| {
        if (tf.quests.objective_kinds.len > 0) qpol.objective_kinds = tf.quests.objective_kinds;
        if (tf.quests.default_kill_count) |v| qpol.default_kill_count = v;
        if (tf.quests.kill_per_tier) |v| qpol.kill_per_tier = v;
        if (tf.quests.goto_radius) |v| qpol.goto_radius = v;
        if (tf.quests.stay_radius) |v| qpol.stay_radius = v;
    }
    init_opts.quest_policy = qpol;
    // Effective bot host policy: mode pack < zdtd.toml (same precedence).
    var bcfg: @import("server/game/bot.zig").BotHostConfig = .{};
    if (mode_owned) |*mp| {
        if (mp.bots.shoot_damage) |v| bcfg.shoot_damage = v;
        if (mp.bots.headshot_multiplier) |v| bcfg.headshot_multiplier = v;
        if (mp.bots.spawn_spread) |v| bcfg.spawn_spread = v;
        if (mp.bots.spawn_y) |v| bcfg.spawn_y = v;
        if (mp.bots.max_step_up) |v| bcfg.max_step_up = v;
    }
    if (toml_owned) |*tf| {
        if (tf.bots.shoot_damage) |v| bcfg.shoot_damage = v;
        if (tf.bots.headshot_multiplier) |v| bcfg.headshot_multiplier = v;
        if (tf.bots.spawn_spread) |v| bcfg.spawn_spread = v;
        if (tf.bots.spawn_y) |v| bcfg.spawn_y = v;
        if (tf.bots.max_step_up) |v| bcfg.max_step_up = v;
    }
    init_opts.bot_config = bcfg;
    // Always sanitize after merge (mode pack and/or toml may set stream/authority knobs).
    zdtd_config.sanitizeInitOptions(&init_opts);

    if (init_opts.authority_mode == .observe) {
        std.debug.print(
            "zdtd: warning: authority mode is observe (illegal C2S logged only; prefer correct for play)\n",
            .{},
        );
    }
    if (admin_port != 0 and init_opts.telnet_password.len == 0) {
        std.debug.print(
            "zdtd: warning: AdminPort {d} opens unauthenticated console on 127.0.0.1 (not for shared hosts)\n",
            .{admin_port},
        );
    }

    const g = game_mod.Game.createWithOptions(gpa, world_dir, port, init_opts) catch |err| {
        fatal("cannot start server: {s} (world '{s}', port {d})", .{ @errorName(err), world_dir, port });
    };
    // The module path list is owned by main (split below); Game does not retain it.
    if (init_opts.plugin_modules.len > 0) gpa.free(init_opts.plugin_modules);
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
        log.info(
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
        log.info(
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
        log.info(
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
        // Only reached on a clean exit (admin "shutdown" / running=false).
        // The absence of this line after a stop is how an operator tells a
        // killed/crashed process from a graceful one.
        var ts: [19]u8 = undefined;
        std.debug.print(
            "zdtd: {s} shutdown complete tick={d} (saved; exited cleanly)\n",
            .{ clock.wallStamp(&ts), g.tick_n },
        );
    } else {
        var i: u64 = 0;
        while (i < max_ticks) : (i += 1) {
            try g.step();
            g.fillWebuiSnap();
        }
        try g.world.saveAll();
        const snap = g.harness.snapshot();
        var buf: [apm.report.max_text_bytes]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        apm.report.writeText(&snap, &w) catch |err|
            std.debug.print("zdtd: apm report truncated: {s}\n", .{@errorName(err)});
        writeStdout(w.buffered());
        if (once) log.info("zdtd --once complete\n", .{});
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

test "isSafeWorldDirName rejects path escape forms" {
    try std.testing.expect(isSafeWorldDirName("Navezgane"));
    try std.testing.expect(isSafeWorldDirName("Pregen06k01"));
    try std.testing.expect(!isSafeWorldDirName(""));
    try std.testing.expect(!isSafeWorldDirName("."));
    try std.testing.expect(!isSafeWorldDirName(".."));
    try std.testing.expect(!isSafeWorldDirName("../etc"));
    try std.testing.expect(!isSafeWorldDirName("foo/bar"));
    try std.testing.expect(!isSafeWorldDirName("foo\\bar"));
    try std.testing.expect(!isSafeWorldDirName("/absolute"));
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
    // Offline (port 0) games never bind a socket: the DST sim is sealed from
    // the network stack, so the LiteNet port must stay 0.
    try std.testing.expectEqual(@as(u16, 0), g.bindPort());

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
