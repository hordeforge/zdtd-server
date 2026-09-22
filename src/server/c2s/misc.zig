//! C2S misc domain: chat, player data / disconnect, dropped packages, game
//! events, quest entity spawns, console commands, damage, lock requests,
//! vehicles, attach, wire actions and turret spawns.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the join-SM arms otherwise.

const std = @import("std");
const misc_chat = @import("misc_chat.zig");
const misc_relay = @import("misc_relay.zig");
const misc_session = @import("misc_session.zig");
const misc_av = @import("misc_av.zig");
const misc_questequip = @import("misc_questequip.zig");
const misc_progress = @import("misc_progress.zig");
const misc_gameevent = @import("misc_gameevent.zig");
const misc_spawn = @import("misc_spawn.zig");
const misc_admin = @import("misc_admin.zig");
const misc_damage = @import("misc_damage.zig");
const misc_lock = @import("misc_lock.zig");
const misc_vehicle = @import("misc_vehicle.zig");
const misc_wire = @import("misc_wire.zig");
const misc_turret = @import("misc_turret.zig");
const misc_drop = @import("misc_drop.zig");
const protocol = @import("../../protocol.zig");
const replicate_te = @import("../game/replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const clock = @import("../../util/clock.zig");
const invsys = @import("../../ecs/inventory.zig");
const inv_apply = @import("../inv_apply.zig");
const components = @import("../../ecs/components.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const c2s_text = @import("../c2s_text.zig");
const packLockPos = game_mod.Game.packLockPos;
const firstLockTargetPos = game_mod.Game.firstLockTargetPos;
const logPersistErr = game_mod.logPersistErr;
const reverseItemType = game_mod.Game.reverseItemType;
const max_chat_msg_len = c2s_text.max_chat_msg_len;
const chatMsgOk = c2s_text.chatMsgOk;
const plugin_compose = @import("../game/plugin_compose.zig");

/// Honored-`fatal` kill amount vs NPC kinds. Lives in misc_damage.zig;
/// this alias keeps the name resolving for any out-of-tree caller.
const fatal_kill_amount = misc_damage.fatal_kill_amount;

/// Highest `WireActions` value. Lives in misc_wire.zig with the wire arms;
/// this alias keeps the name resolving for any out-of-tree caller.
const wire_tool_max_op = misc_wire.wire_tool_max_op;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try misc_chat.handleChat(self, c, peer, name, body)) return true;
    if (try misc_relay.handleRelay(self, c, peer, name, body)) return true;
    if (try misc_drop.handleDrop(self, c, peer, name, body)) return true;
    if (try misc_relay.handleAvatar(self, c, peer, name, body)) return true;
    if (try misc_session.handleSession(self, c, peer, name, body)) return true;
    if (try misc_av.handleAv(self, c, peer, name, body)) return true;
    if (try misc_questequip.handleQuestEquip(self, c, peer, name, body)) return true;
    if (try misc_progress.handleProgress(self, c, peer, name, body)) return true;
    if (try misc_gameevent.handleGameEvent(self, c, peer, name, body)) return true;
    if (try misc_spawn.handleSpawn(self, c, peer, name, body)) return true;
    if (try misc_admin.handleAdmin(self, c, peer, name, body)) return true;
    if (try misc_damage.handleDamage(self, c, peer, name, body)) return true;
    if (try misc_lock.handleLock(self, c, peer, name, body)) return true;
    if (try misc_vehicle.handleVehicle(self, c, peer, name, body)) return true;
    if (try misc_wire.handleWire(self, c, peer, name, body)) return true;
    if (try misc_turret.handleTurret(self, c, peer, name, body)) return true;
    if (try misc_drop.handleDrops2(self, c, peer, name, body)) return true;
    return false;
}



/// Relay `body` verbatim to every joined client, including the sender
/// (stock GameMessageServer re-broadcasts to all peers, sender included).
fn relayBodyAll(self: *Game, pkg: []const u8, body: []const u8, label: []const u8) void {
    misc_relay.relayBodyAll(self, pkg, body, label);
}

/// Relay `body` verbatim to every joined client except `except_entity_id`'s
/// client (stock allButAttachedToEntityId fan-out); null relays to all.
fn relayBodyExcept(self: *Game, pkg: []const u8, body: []const u8, except_entity_id: ?i32, label: []const u8) void {
    misc_relay.relayBodyExcept(self, pkg, body, except_entity_id, label);
}

/// Native then Wasm chat filter chain. Lives in misc_chat.zig; this alias
/// keeps the name resolving for any out-of-tree caller.
const filteredChatText = misc_chat.filteredChatText;

/// Push the killer's AddScoreClient. Lives in misc_damage.zig; this alias
/// keeps the name resolving for any out-of-tree caller.
const sendScoreUpdate = misc_damage.sendScoreUpdate;
