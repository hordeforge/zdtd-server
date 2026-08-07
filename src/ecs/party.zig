//! Party engine (RE ../7dtd-research/docs/parties-factions.md §2).
//!
//! Per-session grouping of human players keyed by runtime entity id:
//! `NetPackagePartyActions` / `NetPackagePartyData` carry no platform identity
//! (parties-factions.md: both are entity-id keyed), so the group is
//! thrown away on disband, exactly like stock `PartyManager`. Pure state +
//! operations, no Game import, no clock: Game routes the C2S action here and
//! fans the resulting `NetPackagePartyData` snapshot out.
//!
//! Stock semantics ported: `Party` caps at 8 members (`Party.AddPlayer` /
//! `IsFull`), a party of one is not kept (the last member's LeaveParty /
//! removal disbands it), and `ServerHandleAutoJoinParty` joins (or creates)
//! party id 1.

const std = @import("std");

/// Party.AddPlayer / IsFull cap (parties-factions.md §2).
pub const max_party_members: usize = 8;
/// Concurrent parties (one per group; stock partyList is unbounded, but the
/// player cap bounds the meaningful set).
pub const max_parties: usize = 8;

/// Stock Party: PartyID, MemberList (entity ids), LeaderIndex, VoiceLobbyId.
pub const Party = struct {
    id: i32 = -1,
    members: [max_party_members]i32 = .{-1} ** max_party_members,
    n: u8 = 0,
    leader_index: u8 = 0,
    /// VoiceLobbyId (SetVoiceLobby). zdtd owns no voice lobby; kept for the
    /// wire round-trip (NetPackagePartyData serializes it).
    voice_lobby: [64]u8 = undefined,
    voice_len: u8 = 0,

    pub fn find(self: *const Party, entity_id: i32) ?u8 {
        var i: u8 = 0;
        while (i < self.n) : (i += 1) {
            if (self.members[i] == entity_id) return i;
        }
        return null;
    }

    pub fn isFull(self: *const Party) bool {
        return self.n >= max_party_members;
    }

    pub fn leader(self: *const Party) i32 {
        if (self.n == 0 or self.leader_index >= self.n) return -1;
        return self.members[self.leader_index];
    }
};

/// Disband / membership-change outcome of a removal, so Game can broadcast the
/// right snapshot (disbandParty flag + changedEntityID).
pub const Removal = struct {
    party_id: i32 = -1,
    /// Remaining member entity ids (already mutated), for the final snapshot.
    members: [max_party_members]i32 = .{-1} ** max_party_members,
    n: u8 = 0,
    leader_index: u8 = 0,
    changed_entity: i32 = -1,
    disband: bool = false,
};

pub const Manager = struct {
    parties: [max_parties]Party = undefined,
    used: [max_parties]bool = .{false} ** max_parties,
    /// PartyManager.nextPartyID (parties-factions.md §2): starts at 1,
    /// increments per CreateParty.
    next_party_id: i32 = 1,

    pub fn init(self: *Manager) void {
        self.* = .{};
        self.parties = [_]Party{.{}} ** max_parties;
    }

    pub fn deinit(self: *Manager) void {
        _ = self;
    }

    fn allocParty(self: *Manager, id: i32) ?*Party {
        for (&self.parties, &self.used) |*p, *u| {
            if (!u.*) {
                u.* = true;
                p.* = .{ .id = id };
                return p;
            }
        }
        return null;
    }

    fn freeParty(self: *Manager, id: i32) void {
        for (&self.parties, &self.used) |*p, *u| {
            if (u.* and p.id == id) {
                u.* = false;
                p.* = .{};
            }
        }
    }

    /// Linear scan like stock `PartyManager.GetParty(id)`.
    pub fn partyById(self: *Manager, id: i32) ?*Party {
        for (&self.parties, &self.used) |*p, *u| {
            if (u.* and p.id == id) return p;
        }
        return null;
    }

    /// The party `entity_id` currently belongs to (stock EntityPlayer.Party).
    pub fn partyByMember(self: *Manager, entity_id: i32) ?*Party {
        for (&self.parties, &self.used) |*p, *u| {
            if (u.* and p.find(entity_id) != null) return p;
        }
        return null;
    }

    /// `Party.AddPlayer` (parties-factions.md §2): refuse duplicate / full,
    /// append, and default the leader index to the first member when the party
    /// was empty (stock CreateParty sets LeaderIndex 0 after AddPlayer of the
    /// inviter).
    pub fn addPlayer(self: *Manager, party_id: i32, entity_id: i32) bool {
        if (entity_id < 0) return false;
        const p = self.partyById(party_id) orelse return false;
        if (p.isFull() or p.find(entity_id) != null) return false;
        p.members[p.n] = entity_id;
        p.n += 1;
        return true;
    }

    /// `PartyManager.CreateParty` + both AddPlayer calls
    /// (`ServerHandleAcceptInvite`, parties-factions.md §2.2): when the inviter
    /// already has a party the accepted player joins it instead.
    pub fn acceptInvite(self: *Manager, inviter: i32, accepted: i32) ?*Party {
        if (inviter < 0 or accepted < 0 or inviter == accepted) return null;
        if (self.partyByMember(accepted) != null) return null; // already grouped
        const p = self.partyByMember(inviter) orelse (self.allocParty(self.next_party_id) orelse return null);
        // A fresh party's first AddPlayer is the inviter (leader index 0).
        if (p.n == 0) {
            self.next_party_id += 1;
            if (!self.addPlayer(p.id, inviter)) return null;
        }
        if (!self.addPlayer(p.id, accepted)) return null;
        return p;
    }

    /// `Party.ServerHandleChangeLead` -> `SetLeader` (parties-factions.md §2.2).
    /// The new host must already be a member; the leader index follows the
    /// stock `MemberList.IndexOf(newHost)`.
    pub fn setLeader(self: *Manager, party_id: i32, new_leader: i32) bool {
        const p = self.partyById(party_id) orelse return false;
        const idx = p.find(new_leader) orelse return false;
        p.leader_index = idx;
        return true;
    }

    /// `Party.ServerHandleLeaveParty` / `ServerHandleKickParty` /
    /// `ServerHandleDisconnectParty` -> `RemovePlayer` / `KickPlayer`
    /// (parties-factions.md §2.2). A removal that leaves exactly one member
    /// disbands the party (stock: the last member auto-leaves; a party of one
    /// is not kept). The leader leaving resets LeaderIndex to 0.
    pub fn removePlayer(self: *Manager, entity_id: i32) ?Removal {
        if (entity_id < 0) return null;
        const p = self.partyByMember(entity_id) orelse return null;
        var out = Removal{
            .party_id = p.id,
            .changed_entity = entity_id,
        };
        const idx = p.find(entity_id).?;
        var i: u8 = idx;
        while (i + 1 < p.n) : (i += 1) p.members[i] = p.members[i + 1];
        p.n -= 1;
        p.members[p.n] = -1;
        if (p.leader_index >= p.n and p.n > 0) p.leader_index = 0;
        if (p.n <= 1) {
            // Disband: the last survivor also leaves (party of one not kept).
            if (p.n == 1) out.changed_entity = p.members[0];
            out.disband = true;
            out.n = 0;
            out.leader_index = 0;
            self.freeParty(p.id);
            return out;
        }
        out.members = p.members;
        out.n = p.n;
        out.leader_index = p.leader_index;
        return out;
    }

    /// `Party.ServerHandleAutoJoinParty` (parties-factions.md §2.2): join (or
    /// create) party id 1; the AutoParty world stat is read by Game.
    pub fn autoJoin(self: *Manager, entity_id: i32) ?*Party {
        if (entity_id < 0) return null;
        if (self.partyByMember(entity_id)) |p| return p;
        const p = self.partyById(1) orelse (self.allocParty(1) orelse return null);
        if (!self.addPlayer(p.id, entity_id)) return null;
        return p;
    }

    /// `Party.SetVoiceLobby` (`ServerHandleSetVoiceLoby`): zdtd keeps the id for
    /// the wire round-trip; there is no voice lobby integration.
    pub fn setVoiceLobby(self: *Manager, party_id: i32, voice: []const u8) bool {
        const p = self.partyById(party_id) orelse return false;
        const n = @min(voice.len, p.voice_lobby.len);
        @memcpy(p.voice_lobby[0..n], voice[0..n]);
        p.voice_len = @intCast(n);
        return true;
    }
};

test "accept invite creates a party with both players and a leader" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    const p = m.acceptInvite(10, 20).?;
    try std.testing.expectEqual(@as(i32, 1), p.id);
    try std.testing.expectEqual(@as(u8, 2), p.n);
    try std.testing.expectEqual(@as(i32, 10), p.leader());
    try std.testing.expectEqual(p, m.partyByMember(20));
    // A second invite from the same inviter joins the existing party.
    const p2 = m.acceptInvite(10, 30).?;
    try std.testing.expectEqual(p.id, p2.id);
    try std.testing.expectEqual(@as(u8, 3), p2.n);
}

test "accept invite refuses a duplicate, a full party and same-entity" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    const p = m.acceptInvite(10, 20).?;
    try std.testing.expect(!m.addPlayer(p.id, 20)); // duplicate
    try std.testing.expect(m.acceptInvite(10, 10) == null); // same entity
    try std.testing.expect(m.acceptInvite(20, 20) == null); // accepted already grouped
}

test "party caps at 8 members" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    const p = m.acceptInvite(10, 20).?;
    // 2 members already; add until the 8-cap refuses.
    var id: i32 = 21;
    while (id < 21 + @as(i32, max_party_members)) : (id += 1) {
        _ = m.addPlayer(p.id, id);
    }
    try std.testing.expect(p.isFull());
    try std.testing.expect(!m.addPlayer(p.id, id));
    try std.testing.expectEqual(@as(u8, max_party_members), p.n);
}

test "leave disbands a party of two; the last survivor also leaves" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    _ = m.acceptInvite(10, 20).?;
    const r = m.removePlayer(10).?;
    try std.testing.expect(r.disband);
    try std.testing.expectEqual(@as(i32, 20), r.changed_entity);
    try std.testing.expect(m.partyByMember(20) == null);
    try std.testing.expect(m.removePlayer(20) == null);
}

test "leader leaving promotes index 0; setLeader re-targets" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    const p = m.acceptInvite(10, 20).?;
    _ = m.addPlayer(p.id, 30);
    try std.testing.expect(m.setLeader(p.id, 30));
    try std.testing.expectEqual(@as(i32, 30), p.leader());
    const r = m.removePlayer(30).?;
    try std.testing.expect(!r.disband);
    try std.testing.expectEqual(@as(i32, 10), p.leader()); // reset to index 0
    try std.testing.expectEqual(@as(u8, 2), r.n);
}

test "auto join creates or reuses party id 1" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    const p = m.autoJoin(10).?;
    try std.testing.expectEqual(@as(i32, 1), p.id);
    _ = m.autoJoin(20).?;
    try std.testing.expectEqual(@as(u8, 2), p.n);
    try std.testing.expect(m.partyByMember(10).?.id == 1);
}

test "voice lobby id round-trips through the party" {
    var m: Manager = .{};
    m.init();
    defer m.deinit();
    const p = m.acceptInvite(10, 20).?;
    try std.testing.expect(m.setVoiceLobby(p.id, "voice-abc"));
    try std.testing.expectEqualStrings("voice-abc", p.voice_lobby[0..p.voice_len]);
}
