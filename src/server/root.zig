//! Server process layer: Game orchestration, config, admin/GSI TCP, scenarios.
//!
//! Dependency direction: top of the stack. May import all other src packages.
//! New join/tick/C2S behavior lands in `game.zig` (or extracted helpers beside
//! it: `phase_gate`, `movement`, `c2s_text`); keep stock package bodies in
//! `wire/` (via packages facade), sim rules in `ecs/`, map IO in `world/`.
//! Mono clock: `util/clock` only.

pub const game = @import("game.zig");
pub const config = @import("config.zig");
pub const zdtd_config = @import("zdtd_config.zig");
pub const mode = @import("mode.zig");
pub const admin = @import("admin.zig");
pub const admin_cmds = @import("admin_cmds.zig");
pub const admin_console = @import("admin_console.zig");
pub const webui = @import("webui.zig");
pub const serverinfo_tcp = @import("serverinfo_tcp.zig");
pub const scenarios = @import("scenarios.zig");
pub const phase_gate = @import("phase_gate.zig");
pub const movement = @import("movement.zig");
pub const c2s_text = @import("c2s_text.zig");
pub const evidence = @import("evidence.zig");
pub const guard_policy = @import("guard_policy.zig");
pub const ally = @import("ally.zig");
pub const replicate_te = @import("replicate_te.zig");
pub const persist = @import("persist.zig");
pub const game_net = @import("game/net.zig");
pub const game_tick = @import("game/tick.zig");
pub const game_world = @import("game/world.zig");
pub const game_player = @import("game/player.zig");
pub const game_join = @import("game/join.zig");
pub const game_types = @import("game/types.zig");
pub const game_quest = @import("game/quest.zig");
pub const game_social = @import("game/social.zig");
pub const game_trader = @import("game/trader.zig");
pub const game_stability = @import("game/stability.zig");
pub const game_replicate = @import("game/replicate.zig");
pub const game_sleeper = @import("game/sleeper.zig");
pub const game_hooks = @import("game/hooks.zig");
pub const game_deco = @import("game/deco.zig");
pub const game_loot = @import("game/loot.zig");
pub const game_craft = @import("game/craft.zig");
pub const game_chunk_stream = @import("game/chunk_stream.zig");
pub const game_chunk_fill = @import("game/chunk_fill.zig");
pub const game_weather = @import("game/weather.zig");
pub const game_vehicle = @import("game/vehicle.zig");
pub const game_config_files = @import("game/config_files.zig");
pub const game_movement_helpers = @import("game/movement_helpers.zig");
pub const game_net_handlers = @import("game/net_handlers.zig");
pub const game_rate_limits = @import("game/rate_limits.zig");
pub const game_blockmeta = @import("game/blockmeta.zig");
pub const game_clock_persist = @import("game/clock_persist.zig");
pub const game_locks = @import("game/locks.zig");
pub const game_bans = @import("game/bans.zig");
pub const game_trader_wire = @import("game/trader_wire.zig");
pub const game_tests = @import("game/tests.zig");
// C2S handlers (server/c2s/)
pub const c2s_inv = @import("c2s/inv.zig");
pub const c2s_blocks = @import("c2s/blocks.zig");
pub const c2s_move = @import("c2s/move.zig");
pub const c2s_quest = @import("c2s/quest.zig");
pub const c2s_misc = @import("c2s/misc.zig");
pub const c2s_join = @import("c2s/join.zig");
pub const c2s_dispatch = @import("c2s/dispatch.zig");

pub const Game = game.Game;
/// Canonical definition lives in config (serverconfig / InitOptions parse).
pub const AuthorityMode = config.AuthorityMode;

test {
    _ = game;
    _ = config;
    _ = zdtd_config;
    _ = mode;
    _ = admin;
    _ = admin_cmds;
    _ = webui;
    _ = serverinfo_tcp;
    _ = scenarios;
    _ = phase_gate;
    _ = movement;
    _ = c2s_text;
    _ = evidence;
    _ = guard_policy;
    _ = ally;
    _ = replicate_te;
    _ = persist;
    _ = game_net;
    _ = game_tick;
    _ = game_world;
    _ = game_player;
    _ = game_join;
    _ = game_types;
    _ = game_quest;
    _ = game_social;
    _ = game_trader;
    _ = game_stability;
    _ = game_replicate;
    _ = game_sleeper;
    _ = game_hooks;
    _ = game_deco;
    _ = game_loot;
    _ = game_weather;
    _ = game_vehicle;
    _ = game_config_files;
    _ = game_movement_helpers;
    _ = game_net_handlers;
    _ = game_rate_limits;
    _ = game_blockmeta;
    _ = game_clock_persist;
    _ = game_locks;
    _ = game_bans;
    _ = game_trader_wire;
    _ = game_tests;
    _ = c2s_inv;
    _ = c2s_blocks;
    _ = c2s_move;
    _ = c2s_quest;
    _ = c2s_misc;
    _ = c2s_join;
    _ = c2s_dispatch;
}
