//! C2S inventory and block editing: player inventory snapshots, holding/item
//! drop/bag, tile-entity edits, inventory transactions, block trigger/setblock
//! and explosions.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const inv_reload = @import("inv_reload.zig");
const inv_holding = @import("inv_holding.zig");
const inv_te = @import("inv_te.zig");
const inv_txn = @import("inv_txn.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const replicate_te = @import("../game/replicate_te.zig");
const stock_te = packages.stock_te;
const stabilityAfterSetBlock = game_mod.stabilityAfterSetBlock;
const reverseItemType = game_mod.Game.reverseItemType;
const resolveItemType = game_mod.Game.resolveItemType;
const eatProps = game_mod.Game.eatProps;

/// Server-authoritative mod attachment scrub. Lives in inv_reload.zig;
/// this alias keeps the name resolving for existing callers.
pub const scrubIllegalMods = inv_reload.scrubIllegalMods;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try inv_reload.handleReload(self, c, peer, name, body)) return true;
    if (try inv_holding.handleHolding(self, c, peer, name, body)) return true;
    if (try inv_te.handleTe(self, c, peer, name, body)) return true;
    if (try inv_txn.handleTxn(self, c, peer, name, body)) return true;
    return false;
}
