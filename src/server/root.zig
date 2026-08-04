//! Server process layer: Game orchestration, config, admin/GSI TCP, scenarios.
//!
//! Dependency direction: top of the stack. May import all other src packages.
//! New join/tick/C2S behavior lands in `game.zig` (or extracted helpers beside
//! it); keep stock package bodies in `wire/`, sim rules in `ecs/`, map IO in
//! `world/`.

pub const game = @import("game.zig");
pub const config = @import("config.zig");
pub const admin = @import("admin.zig");
pub const webui = @import("webui.zig");
pub const serverinfo_tcp = @import("serverinfo_tcp.zig");
pub const scenarios = @import("scenarios.zig");

pub const Game = game.Game;
pub const AuthorityMode = game.AuthorityMode;

test {
    _ = game;
    _ = config;
    _ = admin;
    _ = webui;
    _ = serverinfo_tcp;
    _ = scenarios;
}
