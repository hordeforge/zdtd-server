//! Join state machine - extracted from game.zig handlePackage (stock SM).
//! Owns the 7 join packages that must stay coherent: PlayerLogin →
//! RequestToEnterGame → AuthConfirmation → SignDataRequest →
//! WorldInitInfoRequest → DynamicClientArrive → RequestToSpawnPlayer.
//! Bodies are verbatim copies (stock asm.il comments kept). This file is
//! imported via src/server/root.zig so `zig build test` aggregates it; game.zig
//! keeps only a one-line delegate.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const c2s_text = @import("../c2s_text.zig");
const prefabs_mod = @import("../../world/prefabs.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const ecs = @import("../../ecs/root.zig");
const clock = @import("../../util/clock.zig");
const admin_cmds = @import("../admin_cmds.zig");
const version_mod = @import("../../version.zig");
const plugin_compose = @import("../game/plugin_compose.zig");
const join_login = @import("join_login.zig");
const join_enter = @import("join_enter.zig");
const join_worldinfo = @import("join_worldinfo.zig");
const join_spawn = @import("join_spawn.zig");

const sanitizePlayerName = c2s_text.sanitizePlayerName;

const apm = @import("../../apm/root.zig");

/// True when handled (join SM package). False lets caller fall through to c2s/*.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    // Join-phase attribution (GAP "Join-burst tick budget"): the whole C2S
    // join handler is one apm section so the residual synchronous join work
    // (spawn-area core, join bundle, respawn logic) is measurable separately
    // from the paced chunk drain (.replicate) and the rest of net_poll.
    const sc = apm.profiler.scope(&self.harness.prof, .join);
    defer sc.end();
    if (try join_login.handleLogin(self, c, peer, name, body)) return true;
    if (try join_enter.handleEnter(self, c, peer, name, body)) return true;
    if (try join_worldinfo.handleWorldInfo(self, c, peer, name, body)) return true;
    if (try join_spawn.handleSpawnPlayer(self, c, peer, name, body)) return true;
    return false;
}
