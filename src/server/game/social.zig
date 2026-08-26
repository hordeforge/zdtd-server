//! Buff + party/ally helpers extracted from game.zig (verbatim bodies).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");

pub fn handleAddRemoveBuff(self: *Game, c: *Client, body: []const u8) !void {
    var name_buf: [packages.stock_buff.max_buff_name]u8 = undefined;
    const req = packages.stock_buff.parseAddRemoveBuff(body, &name_buf) catch {
        self.harness.counters.inc(.buff_rejects);
        self.harness.counters.inc(.c2s_malformed);
        return;
    };
    if (req.entity_id != c.entity_id) {
        self.harness.counters.inc(.buff_rejects);
        self.harness.counters.inc(.ownership_rejects);
        return;
    }
    const def_id = self.buffs.indexOfName(req.name) orelse {
        self.harness.counters.inc(.buff_rejects);
        const n = self.harness.counters.get(.buff_rejects);
        if (n == 1 or n % 100 == 0) {
            std.debug.print("zdtd: buff name not in catalog slot={d} n={d}\n", .{ c.slot, n });
        }
        return;
    };
    const ps = self.sim.playerByPeer(c.slot) orelse return;
    const set = self.sim.buffsMut(ps);
    if (!req.adding) {
        _ = ecs.buff.remove(set, def_id);
        return;
    }
    const def = self.buffs.byId(def_id) orelse return;
    const res = ecs.buff.add(set, .{
        .def_id = def_id,
        .duration = def.duration,
        .stack_type = def.stack_type,
        .update_rate_ticks = def.update_rate_ticks,
        .remove_on_death = def.remove_on_death,
    }, ecs.buff.duration_from_class, req.instigator_id, req.instigator_x, req.instigator_y, req.instigator_z);
    if (res == .no_slot) {
        self.harness.counters.inc(.buff_rejects);
        return;
    }
    try relayBuff(self, c.entity_id, def.name, true, req.instigator_id, c.slot);
}

pub fn sendBuffSync(self: *Game, peer: *ln_peer.Peer, c: *const Client) !void {
    var blob_buf: [1024]u8 = undefined;
    for (&self.clients) |*other| {
        if (!other.joined or other.slot == c.slot) continue;
        const blob = playerBuffBlob(self, other.slot, &blob_buf);
        if (blob.len == 0) continue;
        const body = packages.stock_buff.buildEntityStatsBuffBody(&self.body_buf, other.entity_id, blob) catch {
            self.harness.counters.inc(.encode_errors);
            continue;
        };
        try self.sendGame(peer, "NetPackageEntityStatsBuff", body);
    }
}

pub fn playerBuffBlob(self: *Game, peer_slot: usize, buf: []u8) []const u8 {
    const ps = self.sim.playerByPeer(peer_slot) orelse return &.{};
    if (!self.sim.mask[ps].buffs) return &.{};
    var values: [ecs.components.max_buffs_per_entity]packages.stock_buff.BuffValueWire = undefined;
    var n: usize = 0;
    for (self.sim.buffs[ps].slots) |b| {
        if (!b.active) continue;
        const def = self.buffs.byId(b.def_id) orelse continue;
        values[n] = .{
            .name = def.name,
            .stack_mult = b.stack_mult,
            .duration_ticks = b.duration_ticks,
            .instigator_id = b.instigator_id,
            .flags = @bitCast(b.flags),
            .update_ticks = b.update_ticks,
            .instigator_x = b.instigator_x,
            .instigator_y = b.instigator_y,
            .instigator_z = b.instigator_z,
        };
        n += 1;
    }
    if (n == 0) return &.{};
    return packages.stock_buff.writeEntityBuffs(buf, values[0..n]) catch &.{};
}

/// The joining player's OWN active buffs. Stock carries them in the PDF
/// `buffData` section; zdtd writes that section empty (fresh-PlayerDataFile
/// form), so without this bundle the client's buff icons vanish on rejoin
/// even though the server kept the buff state. One AddRemoveBuff (adding)
/// per active buff, the same body shape as the relay.
pub fn sendOwnBuffs(self: *Game, peer: *ln_peer.Peer, c: *const Client) !void {
    const ps = self.sim.playerByPeer(c.slot) orelse return;
    if (!self.sim.mask[ps].buffs) return;
    for (self.sim.buffs[ps].slots) |b| {
        if (!b.active) continue;
        const def = self.buffs.byId(b.def_id) orelse continue;
        const body = packages.stock_buff.buildAddRemoveBuffBody(&self.body_buf, .{
            .entity_id = c.entity_id,
            .name = def.name,
            .duration = ecs.buff.duration_from_class,
            .adding = true,
            .instigator_id = b.instigator_id,
            .instigator_x = b.instigator_x,
            .instigator_y = b.instigator_y,
            .instigator_z = b.instigator_z,
        }) catch {
            self.harness.counters.inc(.encode_errors);
            continue;
        };
        try self.sendGame(peer, "NetPackageAddRemoveBuff", body);
    }
}

pub fn relayBuff(self: *Game, entity_id: i32, buff_name: []const u8, adding: bool, instigator_id: i32, except_slot: ?usize) !void {
    const b = packages.stock_buff.buildAddRemoveBuffBody(&self.body_buf, .{
        .entity_id = entity_id,
        .name = buff_name,
        .duration = ecs.buff.duration_from_class,
        .adding = adding,
        .instigator_id = instigator_id,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    }) catch {
        self.harness.counters.inc(.encode_errors);
        return;
    };
    try self.broadcastExcept("NetPackageAddRemoveBuff", b, except_slot);
}

pub fn broadcastBuffExpiries(self: *Game, r: *const ecs.TickResult) !void {
    var i: u8 = 0;
    while (i < r.buff_expired_n) : (i += 1) {
        const ex = r.buff_expired[i];
        const def = self.buffs.byId(ex.def_id) orelse continue;
        try relayBuff(self, ex.entity_id, def.name, false, -1, null);
    }
}

pub fn handlePartyActions(self: *Game, c: *Client, body: []const u8) !void {
    var voice_buf: [64]u8 = undefined;
    const a = packages.stock_party.readActions(body, &voice_buf) catch {
        self.harness.counters.inc(.c2s_malformed);
        return;
    };
    const me = c.entity_id;
    const target_ok = a.invited_entity >= 0 and self.clientByEntityId(a.invited_entity) != null;
    switch (a.action) {
        1 => {
            if (a.invited_by_entity < 0 or !target_ok) return;
            const p = self.parties.acceptInvite(a.invited_by_entity, a.invited_entity) orelse return;
            try broadcastPartySnapshot(
                self,
                p.id,
                p.leader_index,
                p.voice_lobby[0..p.voice_len],
                p.members[0..p.n],
                a.invited_entity,
                a.action,
                false,
            );
        },
        2 => {
            if (!target_ok) return;
            const p = self.parties.partyByMember(me) orelse return;
            if (p.leader() != me) return;
            if (!self.parties.setLeader(p.id, a.invited_entity)) return;
            try broadcastPartySnapshot(
                self,
                p.id,
                p.leader_index,
                p.voice_lobby[0..p.voice_len],
                p.members[0..p.n],
                a.invited_entity,
                a.action,
                false,
            );
        },
        3 => {
            if (self.parties.removePlayer(me)) |r| {
                try broadcastPartyRemoval(self, r, a.action);
            }
        },
        4 => {
            if (!target_ok) return;
            const p = self.parties.partyByMember(me) orelse return;
            if (p.leader() != me or p.find(a.invited_entity) == null) return;
            if (self.parties.removePlayer(a.invited_entity)) |r| {
                try broadcastPartyRemoval(self, r, a.action);
            }
        },
        5 => {
            if (self.parties.removePlayer(me)) |r| {
                try broadcastPartyRemoval(self, r, a.action);
            }
        },
        6 => {
            const p = self.parties.autoJoin(me) orelse return;
            try broadcastPartySnapshot(
                self,
                p.id,
                p.leader_index,
                p.voice_lobby[0..p.voice_len],
                p.members[0..p.n],
                me,
                a.action,
                false,
            );
        },
        7 => {
            const p = self.parties.partyByMember(me) orelse return;
            if (!self.parties.setVoiceLobby(p.id, a.voice_lobby)) return;
            try broadcastPartySnapshot(
                self,
                p.id,
                p.leader_index,
                p.voice_lobby[0..p.voice_len],
                p.members[0..p.n],
                me,
                a.action,
                false,
            );
        },
        else => {},
    }
}

pub fn broadcastPartySnapshot(
    self: *Game,
    party_id: i32,
    leader_index: u8,
    voice: []const u8,
    members: []const i32,
    changed: i32,
    action: u8,
    disband: bool,
) !void {
    var pbuf: [256]u8 = undefined;
    const body = try packages.stock_party.buildDataBody(&pbuf, .{
        .party_id = party_id,
        .leader_index = leader_index,
        .voice_lobby = voice,
        .members = members,
        .changed_entity = changed,
        .party_action = action,
        .disband = disband,
    });
    for (&self.clients) |*cl| {
        if (!cl.joined or cl.peer == null) continue;
        const is_member = !disband and blk: {
            for (members) |m| {
                if (m == cl.entity_id) break :blk true;
            }
            break :blk false;
        };
        if (!is_member and cl.entity_id != changed) continue;
        const peer = cl.peer.?;
        self.sendGame(peer, "NetPackagePartyData", body) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            std.debug.print("zdtd: send PartyData failed: {s}\n", .{@errorName(err)});
        };
    }
}

pub fn broadcastPartyRemoval(self: *Game, r: ecs.party.Removal, action: u8) !void {
    try broadcastPartySnapshot(
        self,
        r.party_id,
        r.leader_index,
        "",
        r.members[0..r.n],
        r.changed_entity,
        action,
        r.disband,
    );
}

pub fn clientByEntityId(self: *Game, entity_id: i32) ?*Client {
    for (&self.clients) |*cl| {
        if (cl.joined and cl.entity_id == entity_id) return cl;
    }
    return null;
}

pub fn acceptQuestFor(self: *Game, c: *Client, def_id: u16) bool {
    if (!systems.questAccept(&self.sim, c.slot, def_id)) return false;
    shareQuestWithParty(self, c, def_id);
    return true;
}

pub fn shareQuestWithParty(self: *Game, c: *Client, def_id: u16) void {
    const p = self.parties.partyByMember(c.entity_id) orelse return;
    const d = self.sim.catalog.byId(def_id) orelse return;
    var qp: ?*ecs.components.QuestProgress = null;
    if (self.sim.playerByPeer(c.slot)) |ps| {
        if (self.sim.mask[ps].journal) {
            for (&self.sim.journal[ps].slots) |*s| {
                if (s.active and s.def_id == def_id) qp = s;
            }
        }
    }
    const q = qp orelse return;
    if (q.is_shared) return;
    q.is_shared = true;
    for (p.members[0..p.n]) |m| {
        if (m == c.entity_id) continue;
        if (clientByEntityId(self, m)) |member| {
            if (member.peer) |mp| {
                var qb: [256]u8 = undefined;
                const body = packages.stock_quest.buildSharedQuestShare(&qb, .{
                    .shared_by_entity_id = c.entity_id,
                    .quest_code = q.quest_code,
                    .quest_id = d.name,
                    .shared_with_entity_id = m,
                }) catch continue;
                self.sendGame(mp, "NetPackageSharedQuest", body) catch |err| {
                    self.harness.counters.inc(.net_send_errors);
                    std.debug.print("zdtd: send SharedQuest failed: {s}\n", .{@errorName(err)});
                };
            }
        }
    }
}

pub fn handleAllyRequest(self: *Game, c: *Client, body: []const u8) !void {
    const req = packages.parseAllyRequest(body) catch {
        self.harness.counters.inc(.c2s_malformed);
        return;
    };
    const source = req.source.get() orelse return;
    const target = req.target.get() orelse return;
    const own = c.puid_primary.get() orelse return;
    if (!own.eql(source)) {
        self.harness.counters.inc(.ownership_rejects);
        return;
    }
    const t = self.allies.processRequest(source, target, req.add_ally) catch {
        self.harness.counters.inc(.c2s_throttle);
        return;
    };
    if (t.isNoop()) return;
    const resp = try packages.buildAllyResponseBody(
        self.body_buf[9216..9728],
        source,
        target,
        @intFromEnum(t.new_status),
        @intFromEnum(t.event_source),
        @intFromEnum(t.event_target),
    );
    try self.broadcast("NetPackageAllyResponse", resp);
}
