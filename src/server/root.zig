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
}
