//! C2S quest/social/trade domain: shared quests, party and ally actions,
//! buff add/remove, quest events and objective updates, the NPC quest list,
//! trader data and vending-machine edits.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const rng_util = @import("../../util/rng.zig");
const c2s_text = @import("../c2s_text.zig");
const replicate_te = @import("../game/replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const quest_party = @import("quest_party.zig");
const quest_waypoint = @import("quest_waypoint.zig");
const quest_buff = @import("quest_buff.zig");
const quest_trade = @import("quest_trade.zig");

/// Fallback quest-giver marker Y. Lives in quest_party.zig with the party
/// arms; this alias keeps the name resolving for existing callers.
const quest_giver_fallback_y = quest_party.quest_giver_fallback_y;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try quest_party.handleParty(self, c, peer, name, body)) return true;
    if (try quest_waypoint.handleWaypoint(self, c, peer, name, body)) return true;
    if (try quest_buff.handleBuff(self, c, peer, name, body)) return true;
    if (try quest_trade.handleTrade(self, c, peer, name, body)) return true;
    return false;
}

