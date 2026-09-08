//! Stock quest journal + NPCQuestList QuestPacketEntry wire (V3.x).
//! Matches QuestJournal.Write v5, Quest.Write (FileVersion 8), and
//! NetPackageNPCQuestList FetchList entries.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

/// Stock Quest.Write FileVersion 8 (RE: stock_quest.zig header; protocol-packages.md §6.18).
pub const quest_file_version: u8 = 8;
/// Stock QuestJournal.Write v5 (RE: protocol-packages.md quest journal body).
pub const journal_version: u8 = 5;
/// Objective block version marker (0 = versionless within Quest.Write; RE: Quest.Write structure).
pub const objective_file_version: u8 = 0;
/// Quest.PositionDataTypes (asm.il 983460-983475).
pub const position_data_quest_giver: u8 = 0;
pub const position_data_location: u8 = 1;
pub const position_data_poi_position: u8 = 2;
pub const position_data_poi_size: u8 = 3;

/// Stock objective Write path. Exactly four BaseObjective subclasses override
/// Write (every `kind base=BaseObjective` / `base=Objective*` type in
/// `il/full-v3.2.0/_global` was checked); the rest inherit the base shape.
pub const ObjectiveWriteKind = enum(u8) {
    /// BaseObjective.Write: FileVersion u8 + CurrentValue u8 (BaseObjective.il.txt:542).
    base = 0,
    /// ObjectiveTreasureChest.Write: destroyCount i32 + CurrentRadius i32, no
    /// base call (ObjectiveTreasureChest.il.txt:2592).
    treasure_chest = 1,
    /// ObjectivePOIStayWithin.Write and ObjectiveStayWithin.Write are both a
    /// bare `ret` (ObjectivePOIStayWithin.il.txt:100, ObjectiveStayWithin.il.txt:136).
    empty = 2,
    /// ObjectiveTime.Write: `(UInt16)currentTime`, no base call
    /// (ObjectiveTime.il.txt:126); Read casts it back to the currentTime float
    /// and pins currentValue to 1 (:115).
    time = 3,
};

pub const QuestState = enum(u8) {
    not_started = 0,
    in_progress = 1,
    ready_turn_in = 2,
    completed = 3,
    failed = 4,
};

/// Stock reward wire kind matching BaseReward / RewardItem / RewardLootItem Write.
pub const RewardWire = struct {
    /// true: RewardItem or RewardLootItem (index byte + ItemStack.Write).
    /// false: Exp/Skill/etc. (index byte only via BaseReward.Write).
    has_item_stack: bool = false,
    /// ItemStack when has_item_stack; count 0 is valid Empty stack.
    item: stock_inv.StockSlot = .{},
};

pub const QuestPacketEntry = struct {
    quest_id: []const u8,
    loc_x: f32 = 0,
    loc_y: f32 = 70,
    loc_z: f32 = 0,
    size_x: f32 = 50,
    size_y: f32 = 20,
    size_z: f32 = 50,
    poi_name: []const u8 = "",
    trader_x: f32 = 0,
    trader_y: f32 = 70,
    trader_z: f32 = 0,
};

/// InProgress/Completed quest for PDF / journal snapshot.
/// objective_count and rewards.len must match client CreateQuest list lengths.
pub const StockQuestWrite = struct {
    id: []const u8,
    quest_version: u8 = 1,
    state: QuestState = .in_progress,
    shared_owner_id: i32 = -1,
    quest_giver_id: i32 = -1,
    tracked: bool = true,
    current_phase: u8 = 1,
    quest_code: i32 = 0,
    objective_count: u8 = 0,
    /// CurrentValue for objective index 0 (legacy).
    first_objective_value: u8 = 0,
    /// Optional per-objective CurrentValue (length objective_count). Empty = use first only.
    objective_values: []const u8 = &.{},
    /// Per-objective write kind (stock CreateQuest subclass). Empty = BaseObjective.
    objective_kinds: []const ObjectiveWriteKind = &.{},
    /// One entry per client Rewards[i]; wire kind must match Reward subclass.
    rewards: []const RewardWire = &.{},
    quest_faction: u8 = 0,
    quest_progress_day: i32 = 0,
    /// Quest.PositionData entries, written only when InProgress. Order is the
    /// stock Dictionary iteration order, which the client keys by type byte.
    position_data: []const PositionEntry = &.{},
    /// Quest.RallyMarkerActivated (asm.il 989046): false re-arms the marker
    /// block, true makes BlockRallyMarker report it as already used.
    rally_marker_activated: bool = false,
};

/// One Quest.PositionData pair: PositionDataTypes key + Vector3.
pub const PositionEntry = struct {
    kind: u8,
    x: f32 = 0,
    y: f32 = 70,
    z: f32 = 0,
};

const MarkerU16 = struct { pos: usize };

fn reserveU16(w: *binary.Writer) !MarkerU16 {
    const m = MarkerU16{ .pos = w.pos };
    try w.writeU16(0);
    return m;
}

fn finalizeU16(w: *binary.Writer, m: MarkerU16) void {
    // Stock FinalizeSizeMarker: length = end - markPos (includes marker bytes).
    const end = w.pos;
    const len: u16 = @intCast(end - m.pos);
    std.mem.writeInt(u16, w.buf[m.pos..][0..2], len, .little);
}

pub fn writeQuestPacketEntry(w: *binary.Writer, e: QuestPacketEntry) !void {
    try w.writeString(e.quest_id);
    try w.writeF32(e.loc_x);
    try w.writeF32(e.loc_y);
    try w.writeF32(e.loc_z);
    try w.writeF32(e.size_x);
    try w.writeF32(e.size_y);
    try w.writeF32(e.size_z);
    try w.writeString(e.poi_name);
    try w.writeF32(e.trader_x);
    try w.writeF32(e.trader_y);
    try w.writeF32(e.trader_z);
}

/// NetPackageNPCQuestList FetchList (RE): npc i32 | player i32 | eventType u8
/// (0 = fetch) | tier i32 | entry count i32 | count x QuestPacketEntry.
pub fn buildNpcQuestListFetch(
    buf: []u8,
    npc_entity_id: i32,
    player_entity_id: i32,
    tier_level: i32,
    entries: []const QuestPacketEntry,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(npc_entity_id);
    try w.writeI32(player_entity_id);
    try w.writeByte(0); // FetchList
    try w.writeI32(tier_level);
    try w.writeI32(@intCast(entries.len));
    for (entries) |e| try writeQuestPacketEntry(&w, e);
    return w.written();
}

pub fn writeStockQuest(w: *binary.Writer, q: StockQuestWrite) !void {
    try w.writeString(q.id);
    try w.writeByte(q.quest_version);
    try w.writeByte(quest_file_version);
    try w.writeByte(@intFromEnum(q.state));
    try w.writeI32(q.shared_owner_id);
    try w.writeI32(q.quest_giver_id);
    if (q.state == .in_progress) {
        try w.writeBool(q.tracked);
        try w.writeByte(q.current_phase);
        try w.writeI32(q.quest_code);
    }
    // Objectives size marker (UInt16) + virtual BaseObjective.Write per entry.
    // A kind mismatch desyncs the whole list: the client sizes the block from
    // the marker and Quest.Read clears every objective when ValidateSizeMarker
    // rejects it (Quest.il.txt:3454-3470).
    {
        const m = try reserveU16(w);
        var i: u8 = 0;
        while (i < q.objective_count) : (i += 1) {
            const kind: ObjectiveWriteKind = if (i < q.objective_kinds.len) q.objective_kinds[i] else .base;
            const val: u8 = if (i < q.objective_values.len)
                q.objective_values[i]
            else if (i == 0)
                q.first_objective_value
            else if (q.current_phase > 0 and i + 1 == q.current_phase)
                q.first_objective_value
            else
                0;
            switch (kind) {
                .base => {
                    try w.writeByte(objective_file_version);
                    try w.writeByte(val);
                },
                .treasure_chest => {
                    try w.writeI32(0); // destroyCount
                    try w.writeI32(0); // CurrentRadius
                },
                .empty => {},
                // currentTime seconds; the client casts it straight back to
                // its float field, so the progress value rides here, not in a
                // CurrentValue byte.
                .time => try w.writeU16(val),
            }
        }
        finalizeU16(w, m);
    }
    try w.writeByte(0); // DataVariables count
    if (q.state == .in_progress) {
        // Stock writes the dictionary count as a byte; more than 255 entries
        // cannot be expressed, so refuse rather than truncate the count.
        if (q.position_data.len > 255) return error.Overflow;
        try w.writeByte(@intCast(q.position_data.len)); // PositionData count
        for (q.position_data) |p| {
            try w.writeByte(p.kind);
            try w.writeF32(p.x);
            try w.writeF32(p.y);
            try w.writeF32(p.z);
        }
        try w.writeBool(q.rally_marker_activated);
    } else {
        try w.writeU64(0); // FinishTime
    }
    if (q.state == .in_progress or q.state == .ready_turn_in) {
        // Rewards: UInt16 size | count i32 | per reward virtual Write.
        // RewardExp: index u8. RewardItem/LootItem: index u8 + ItemStack.
        const m = try reserveU16(w);
        try w.writeI32(@intCast(q.rewards.len));
        for (q.rewards, 0..) |rw, i| {
            try w.writeByte(@intCast(i)); // RewardIndex
            if (rw.has_item_stack) {
                try stock_inv.writeItemStack(w, rw.item);
            }
        }
        finalizeU16(w, m);
    }
    try w.writeByte(q.quest_faction);
    try w.writeI32(q.quest_progress_day);
}

/// QuestJournal.Write v5 with zero TraderPOIs / TradersByFaction / TraderData.
pub fn writeQuestJournal(w: *binary.Writer, quests: []const StockQuestWrite) !void {
    try w.writeByte(journal_version);
    try w.writeByte(0); // TraderPOIs
    try w.writeByte(0); // TradersByFaction
    try w.writeU16(@intCast(quests.len));
    for (quests) |q| {
        const m = try reserveU16(w);
        try writeStockQuest(w, q);
        finalizeU16(w, m);
    }
    try w.writeByte(0); // TraderData
}

test "npc quest list fetch with one entry" {
    var buf: [256]u8 = undefined;
    // Distinct values throughout: the entry is positional, and six f32 in a
    // row is exactly where a swapped pair hides. size_* used to be left at 0,
    // which made every swap among loc_z, size_x, size_y and size_z invisible.
    const entries = [_]QuestPacketEntry{.{
        .quest_id = "tier1_clear",
        .loc_x = 10,
        .loc_y = 70,
        .loc_z = 20,
        .size_x = 31,
        .size_y = 32,
        .size_z = 33,
        .poi_name = "test_poi",
        .trader_x = 1,
        .trader_y = 71,
        .trader_z = 2,
    }};
    const body = try buildNpcQuestListFetch(&buf, 50, 106, 1, entries[0..]);
    try std.testing.expect(body.len > 17);
    try std.testing.expectEqual(@as(i32, 50), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), body[8]);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[9..13], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[13..17], .little));
    // quest id string 7bit-len
    try std.testing.expectEqual(@as(u8, 11), body[17]); // "tier1_clear".len

    // The entry continues with loc x/y/z then size x/y/z as f32, and nothing
    // read them back: a swap anywhere in that run rode out silently.
    const loc = 18 + "tier1_clear".len;
    const f32At = struct {
        fn get(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.get;
    try std.testing.expectEqual(@as(f32, 10), f32At(body, loc));
    try std.testing.expectEqual(@as(f32, 70), f32At(body, loc + 4));
    try std.testing.expectEqual(@as(f32, 20), f32At(body, loc + 8));
    try std.testing.expectEqual(@as(f32, 31), f32At(body, loc + 12));
    try std.testing.expectEqual(@as(f32, 32), f32At(body, loc + 16));
    try std.testing.expectEqual(@as(f32, 33), f32At(body, loc + 20));
    // poiName string, then the trader position triple.
    const trader = loc + 24 + 1 + "test_poi".len;
    try std.testing.expectEqual(@as(f32, 1), f32At(body, trader));
    try std.testing.expectEqual(@as(f32, 71), f32At(body, trader + 4));
    try std.testing.expectEqual(@as(f32, 2), f32At(body, trader + 8));
}

// --- NetPackageSharedQuest (party share / force-add journal on client) ---

pub const SharedQuestEvent = enum(u8) {
    share_quest = 0,
    remove_quest = 1,
    add_shared_member = 2,
    remove_shared_member = 3,
};

pub const SharedQuestShare = struct {
    shared_by_entity_id: i32,
    quest_code: i32,
    quest_id: []const u8,
    poi_name: []const u8 = "",
    pos_x: f32 = 0,
    pos_y: f32 = 70,
    pos_z: f32 = 0,
    size_x: f32 = 50,
    size_y: f32 = 20,
    size_z: f32 = 50,
    return_x: f32 = 0,
    return_y: f32 = 70,
    return_z: f32 = 0,
    quest_giver_id: i32 = -1,
    shared_with_entity_id: i32 = -1,
};

/// NetPackageSharedQuest, ShareQuest (event 0) body for S2C / echo. RE
/// inventories/netpackage-bodies.md write IL=8: one `sharedQuestData` blob,
/// laid out by the SharedQuestData.write fields written below.
pub fn buildSharedQuestShare(buf: []u8, q: SharedQuestShare) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(q.shared_by_entity_id);
    try w.writeByte(@intFromEnum(SharedQuestEvent.share_quest));
    try w.writeI32(q.quest_code);
    try w.writeString(q.quest_id);
    try w.writeString(q.poi_name);
    try w.writeF32(q.pos_x);
    try w.writeF32(q.pos_y);
    try w.writeF32(q.pos_z);
    try w.writeF32(q.size_x);
    try w.writeF32(q.size_y);
    try w.writeF32(q.size_z);
    try w.writeF32(q.return_x);
    try w.writeF32(q.return_y);
    try w.writeF32(q.return_z);
    try w.writeI32(q.quest_giver_id);
    try w.writeI32(q.shared_with_entity_id);
    return w.written();
}

pub const SharedQuestHead = struct {
    shared_by_entity_id: i32,
    event: SharedQuestEvent,
    quest_code: i32 = 0,
    quest_id_storage: [96]u8 = undefined,
    /// Length of the id in quest_id_storage. A length, not a slice: a slice
    /// into the struct's own storage dangles when returned by value.
    quest_id_len: usize = 0,
    shared_with_entity_id: i32 = -1,

    pub fn questId(self: *const SharedQuestHead) []const u8 {
        return self.quest_id_storage[0..self.quest_id_len];
    }
};

/// Read side of NetPackageSharedQuest, whose body is one SharedQuestData (RE
/// inventories/netpackage-bodies.md, write IL=63): `sharedByEntityID` i32 |
/// `questEvent` u8 | `questCode` i32 | `questID` string | `poiName` string |
/// `position`, `size`, `returnPos` (three Vector3 = 36 bytes) | `questGiverID`
/// i32 | `sharedWithEntityID` i32. The three trailing fields the RE table lists
/// after that are the conditional branch of the same write, not a fixed tail.
///
/// Only the fields the server acts on come back: the POI name and the three
/// vectors are skipped by width, since the shared quest is resolved from
/// `questID` against the server's own catalog rather than from the client's
/// description of it.
pub fn parseSharedQuestHead(body: []const u8) !SharedQuestHead {
    if (body.len < 5) return error.EndOfStream;
    const by = std.mem.readInt(i32, body[0..4], .little);
    const et_raw = body[4];
    const et = std.enums.fromInt(SharedQuestEvent, et_raw) orelse return error.InvalidEvent;
    var head: SharedQuestHead = .{ .shared_by_entity_id = by, .event = et };
    if (et == .share_quest) {
        if (body.len < 9) return error.EndOfStream;
        head.quest_code = std.mem.readInt(i32, body[5..9], .little);
        var r: binary.Reader = .{ .data = body, .pos = 9 };
        const id = try r.readString(head.quest_id_storage[0..]);
        head.quest_id_len = id.len;
        try r.skipString();
        // 9 f32 + questGiver i32 + sharedWith i32
        if (r.remaining() < 36 + 8) return error.EndOfStream;
        r.pos += 36;
        _ = try r.readI32();
        head.shared_with_entity_id = try r.readI32();
    } else if (et == .remove_quest) {
        if (body.len < 9) return error.EndOfStream;
        head.quest_code = std.mem.readInt(i32, body[5..9], .little);
    } else {
        if (body.len >= 13) {
            head.quest_code = std.mem.readInt(i32, body[5..9], .little);
            head.shared_with_entity_id = std.mem.readInt(i32, body[9..13], .little);
        }
    }
    return head;
}

// --- NetPackageQuestEvent (rally marker activation / POI quest lock) ---

/// NetPackageQuestEvent.QuestEventTypes (asm.il 834734-834751).
pub const QuestEventType = enum(u8) {
    try_rally_marker = 0,
    confirm_rally_marker = 1,
    rally_marker_activated = 2,
    rally_marker_locked = 3,
    rally_marker_player_locked = 4,
    rally_marker_bedroll_locked = 5,
    rally_marker_land_claim_locked = 6,
    lock_poi = 7,
    unlock_poi = 8,
    clear_sleeper = 9,
    show_sleeper_volume = 10,
    hide_sleeper_volume = 11,
    setup_fetch = 12,
    setup_restore_power = 13,
    finish_managed_quest = 14,
    poi_locked = 15,
    reset_trader_quests = 16,
};

/// Fixed head of every NetPackageQuestEvent plus the tails the server acts on.
/// Head order from NetPackageQuestEvent.read (asm.il 835089-835124):
/// entityID i32 | prefabPos Vector3 | eventType u8 | questTags string | questCode i32.
pub const QuestEventHead = struct {
    entity_id: i32,
    px: f32 = 0,
    py: f32 = 0,
    pz: f32 = 0,
    event: QuestEventType,
    quest_code: i32 = 0,
    /// RallyMarkerLocked tail (asm.il 835089 IL_0161): QuestLockInstance.LockedOutUntil.
    extra_data: u64 = 0,
    /// ResetTraderQuests tail (asm.il 835089 IL_01bd).
    faction_point_override: i32 = 0,
    /// ClearSleeper tail (asm.il 835089 IL_007c).
    subscribe_to: bool = false,
};

/// Consume the per-event tail so a malformed body is rejected instead of being
/// silently accepted on its head alone. Mirrors the read switch at asm.il
/// 835089 IL_0049/IL_0052: only 3, 7, 9, 12, 13 and 16 carry a tail.
fn readQuestEventTail(r: *binary.Reader, head: *QuestEventHead) !void {
    switch (head.event) {
        .rally_marker_locked => head.extra_data = try r.readU64(),
        .lock_poi => {
            try r.skipString(); // questID
            try skipI32List(r);
        },
        .clear_sleeper => head.subscribe_to = try r.readBool(),
        .setup_fetch => {
            _ = try r.readByte(); // FetchModeType
            try skipI32List(r);
        },
        .setup_restore_power => {
            try r.skipString(); // blockIndex
            try r.skipString(); // eventName
            try skipI32List(r);
            const n = try r.readByte();
            // activateList: Vector3i triples.
            if (r.remaining() < @as(usize, n) * 12) return error.EndOfStream;
            r.pos += @as(usize, n) * 12;
        },
        .reset_trader_quests => head.faction_point_override = try r.readI32(),
        else => {},
    }
}

/// SharedWithList: byte count followed by that many i32 entity ids.
fn skipI32List(r: *binary.Reader) !void {
    const n = try r.readByte();
    if (r.remaining() < @as(usize, n) * 4) return error.EndOfStream;
    r.pos += @as(usize, n) * 4;
}

/// Parse a C2S NetPackageQuestEvent. Rejects unknown event bytes and any body
/// whose declared tail runs past the end (trust boundary: this is off the wire).
pub fn parseQuestEventHead(body: []const u8) !QuestEventHead {
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const px = try r.readF32();
    const py = try r.readF32();
    const pz = try r.readF32();
    const et_raw = try r.readByte();
    const et = std.enums.fromInt(QuestEventType, et_raw) orelse return error.InvalidEvent;
    try r.skipString(); // questTags (FastTags.ToString; empty set is "")
    const quest_code = try r.readI32();
    var head: QuestEventHead = .{
        .entity_id = entity_id,
        .px = px,
        .py = py,
        .pz = pz,
        .event = et,
        .quest_code = quest_code,
    };
    try readQuestEventTail(&r, &head);
    return head;
}

/// Build a server-side NetPackageQuestEvent. questTags is always the empty tag
/// set, which FastTags.ToString serializes as "" (asm.il 772366-772404), i.e. a
/// single zero length byte. Only the tails the server emits are written.
pub fn buildQuestEvent(buf: []u8, head: QuestEventHead) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(head.entity_id);
    try w.writeF32(head.px);
    try w.writeF32(head.py);
    try w.writeF32(head.pz);
    try w.writeByte(@intFromEnum(head.event));
    try w.writeString("");
    try w.writeI32(head.quest_code);
    switch (head.event) {
        .rally_marker_locked => try w.writeU64(head.extra_data),
        .clear_sleeper => try w.writeBool(head.subscribe_to),
        .reset_trader_quests => try w.writeI32(head.faction_point_override),
        // lock_poi / setup_fetch / setup_restore_power carry list tails the
        // server never originates; refuse rather than emit a headless body.
        .lock_poi, .setup_fetch, .setup_restore_power => return error.Unsupported,
        else => {},
    }
    return w.written();
}

test "quest event rally round trip" {
    var buf: [64]u8 = undefined;
    const body = try buildQuestEvent(&buf, .{
        .entity_id = 171,
        .px = 128,
        .py = 70,
        .pz = -64,
        .event = .rally_marker_activated,
        .quest_code = 10007,
    });
    // head = i32 + 3×f32 + u8 + empty string (1 byte) + i32, no tail
    try std.testing.expectEqual(@as(usize, 4 + 12 + 1 + 1 + 4), body.len);
    const head = try parseQuestEventHead(body);
    try std.testing.expectEqual(@as(i32, 171), head.entity_id);
    try std.testing.expectEqual(QuestEventType.rally_marker_activated, head.event);
    try std.testing.expectEqual(@as(i32, 10007), head.quest_code);
    try std.testing.expectEqual(@as(f32, 128), head.px);
    try std.testing.expectEqual(@as(f32, -64), head.pz);
}

test "quest event locked tail carries extra data" {
    var buf: [64]u8 = undefined;
    const body = try buildQuestEvent(&buf, .{
        .entity_id = 171,
        .event = .rally_marker_locked,
        .quest_code = 3,
        .extra_data = 0x0102030405060708,
    });
    try std.testing.expectEqual(@as(usize, 4 + 12 + 1 + 1 + 4 + 8), body.len);
    const head = try parseQuestEventHead(body);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), head.extra_data);
}

test "quest event rejects unknown event and truncation" {
    var buf: [64]u8 = undefined;
    const body = try buildQuestEvent(&buf, .{
        .entity_id = 1,
        .event = .try_rally_marker,
        .quest_code = 5,
    });
    try std.testing.expectError(error.EndOfStream, parseQuestEventHead(body[0 .. body.len - 1]));
    try std.testing.expectError(error.EndOfStream, parseQuestEventHead(body[0..4]));
    var bad = buf;
    // eventType byte, one past the highest declared variant. Derived, not a
    // literal: a new variant must not silently turn this into a legal value.
    const past_last = std.enums.values(QuestEventType).len;
    bad[16] = @intCast(past_last);
    try std.testing.expectError(error.InvalidEvent, parseQuestEventHead(bad[0..body.len]));
}

test "every declared quest event variant parses" {
    // The eventType guards derive their bound from the enum, so adding a
    // variant must not make a legal stock ordinal parse as InvalidEvent.
    // This is the regression the old hand-synced numeric guards invited.
    // Built by hand, not via buildQuestEvent: that builder refuses the three
    // list-tail variants the server never originates, which would leave the
    // ordinals they occupy untested on the parse side.
    for (std.enums.values(QuestEventType)) |ev| {
        var buf: [64]u8 = undefined;
        var w: binary.Writer = .{ .buf = &buf };
        try w.writeI32(1);
        try w.writeF32(0);
        try w.writeF32(0);
        try w.writeF32(0);
        try w.writeByte(@intFromEnum(ev));
        try w.writeString("");
        try w.writeI32(5);
        try w.writeU64(0); // widest fixed tail; ignored by variants without one
        const head = parseQuestEventHead(w.written()) catch |e| switch (e) {
            // Variants with a list tail need their own payload. The ordinal was
            // already accepted by the time the tail is read, which is what this
            // test is about; a rejected ordinal surfaces as InvalidEvent.
            error.EndOfStream => continue,
            else => return e,
        };
        try std.testing.expectEqual(ev, head.event);
    }
}

test "every declared shared quest event variant parses" {
    for (std.enums.values(SharedQuestEvent)) |ev| {
        var body: [9]u8 = @splat(0);
        std.mem.writeInt(i32, body[0..4], 7, .little);
        body[4] = @intFromEnum(ev);
        const head = parseSharedQuestHead(&body) catch |e| switch (e) {
            error.EndOfStream => continue,
            else => return e,
        };
        try std.testing.expectEqual(ev, head.event);
    }
}

test "quest event list tails are bounds checked" {
    // LockPOI: questID string + SharedWithList (u8 count + count×i32).
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(9);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeByte(@intFromEnum(QuestEventType.lock_poi));
    try w.writeString("");
    try w.writeI32(4);
    try w.writeString("tier1_clear");
    try w.writeByte(2);
    try w.writeI32(101);
    try w.writeI32(102);
    const body = w.written();
    const head = try parseQuestEventHead(body);
    try std.testing.expectEqual(QuestEventType.lock_poi, head.event);
    // A count that overruns the buffer must be refused, not read past the end.
    var short = buf;
    short[body.len - 9] = 200; // SharedWithList count byte
    try std.testing.expectError(error.EndOfStream, parseQuestEventHead(short[0..body.len]));
    try std.testing.expectError(error.Unsupported, buildQuestEvent(&buf, .{
        .entity_id = 9,
        .event = .lock_poi,
    }));
}

test "shared quest share layout" {
    var buf: [256]u8 = undefined;
    // The nine position floats used to be left at their 0 default, so any
    // swap among them emitted identical bytes. Distinct values make the run
    // of pos / size / return triples observable.
    const body = try buildSharedQuestShare(&buf, .{
        .shared_by_entity_id = 106,
        .quest_code = 7,
        .quest_id = "tier1_clear",
        .poi_name = "poi",
        .pos_x = 11,
        .pos_y = 12,
        .pos_z = 13,
        .size_x = 21,
        .size_y = 22,
        .size_z = 23,
        .return_x = 31,
        .return_y = 32,
        .return_z = 33,
        .shared_with_entity_id = 106,
    });
    try std.testing.expect(body.len > 20);
    const head = try parseSharedQuestHead(body);
    try std.testing.expectEqual(@as(i32, 106), head.shared_by_entity_id);
    try std.testing.expectEqual(SharedQuestEvent.share_quest, head.event);
    try std.testing.expectEqual(@as(i32, 7), head.quest_code);
    try std.testing.expectEqualStrings("tier1_clear", head.questId());
    try std.testing.expectEqual(@as(i32, 106), head.shared_with_entity_id);

    // parseSharedQuestHead skips the three triples by width, so read them
    // here: sharedBy i32 | event u8 | questCode i32 | questID | poiName, then
    // pos, size and return as Vector3 each.
    var r: binary.Reader = .{ .data = body[9..] }; // past sharedBy, event, code
    var s_buf: [64]u8 = undefined;
    _ = try r.readString(&s_buf); // questID
    _ = try r.readString(&s_buf); // poiName
    const want = [_]f32{ 11, 12, 13, 21, 22, 23, 31, 32, 33 };
    for (want) |v| try std.testing.expectEqual(v, try r.readF32());
}

test "shared quest rejects truncated share body" {
    var buf: [256]u8 = undefined;
    const body = try buildSharedQuestShare(&buf, .{
        .shared_by_entity_id = 106,
        .quest_code = 7,
        .quest_id = "tier1_clear",
        .shared_with_entity_id = 106,
    });
    try std.testing.expectError(error.EndOfStream, parseSharedQuestHead(body[0 .. body.len - 1]));
    try std.testing.expectError(error.EndOfStream, parseSharedQuestHead(body[0..10]));
}

test "stock quest journal one in-progress" {
    var buf: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    const rewards = [_]RewardWire{
        .{}, // Exp: index only
        .{ .has_item_stack = true, .item = .{ .type_id = 0, .count = 0 } }, // Item: empty stack ok
    };
    // Distinct values per field. The defaults leave quest_version at 1 next to
    // quest_file_version 8, and shared_owner_id and quest_giver_id both at -1,
    // so a swap between neighbours emitted identical bytes and no test could
    // see it.
    const q = StockQuestWrite{
        .id = "quest_whiteRiverCitizen1",
        .quest_version = 3,
        .shared_owner_id = 41,
        .quest_giver_id = 42,
        .tracked = true,
        .current_phase = 2,
        .quest_code = 1,
        .objective_count = 2,
        .first_objective_value = 6,
        .rewards = rewards[0..],
    };
    try writeQuestJournal(&w, &[_]StockQuestWrite{q});
    const out = w.written();
    try std.testing.expectEqual(@as(u8, 5), out[0]);
    try std.testing.expectEqual(@as(u8, 0), out[1]);
    try std.testing.expectEqual(@as(u8, 0), out[2]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[3..5], .little));
    // outer size marker non-zero; total = header(5) + outer + TraderData(1)
    const outer = std.mem.readInt(u16, out[5..7], .little);
    try std.testing.expect(outer > 10);
    try std.testing.expectEqual(@as(usize, 5 + outer + 1), out.len);

    // Quest.Write body after the outer marker: the id string, then the header
    // bytes. Nothing read these back, so five adjacent pairs among them could
    // swap unnoticed (the mutation audit reported exactly that run).
    var qr: binary.Reader = .{ .data = out[7..] };
    var id_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("quest_whiteRiverCitizen1", try qr.readString(&id_buf));
    try std.testing.expectEqual(@as(u8, 3), try qr.readByte()); // quest_version
    try std.testing.expectEqual(quest_file_version, try qr.readByte()); // file version
    try std.testing.expectEqual(@intFromEnum(QuestState.in_progress), try qr.readByte());
    try std.testing.expectEqual(@as(i32, 41), try qr.readI32()); // sharedOwnerID
    try std.testing.expectEqual(@as(i32, 42), try qr.readI32()); // questGiverID
    // InProgress tail: tracked bool, currentPhase byte, questCode i32.
    try std.testing.expectEqual(true, try qr.readBool());
    try std.testing.expectEqual(@as(u8, 2), try qr.readByte());
    try std.testing.expectEqual(@as(i32, 1), try qr.readI32());
    // Objectives: u16 size marker, then FileVersion + CurrentValue per entry.
    _ = try qr.readU16();
    try std.testing.expectEqual(objective_file_version, try qr.readByte());
    try std.testing.expectEqual(@as(u8, 6), try qr.readByte()); // first_objective_value
}

test "position data entries cost 13 bytes each" {
    // Quest.Write PositionData: count u8 then per entry key u8 + Vector3.
    // A slip here desyncs the whole journal read inside PlayerId, so pin it.
    var buf_none: [256]u8 = undefined;
    var buf_poi: [256]u8 = undefined;
    var w_none: binary.Writer = .{ .buf = &buf_none };
    var w_poi: binary.Writer = .{ .buf = &buf_poi };
    const pos = [_]PositionEntry{
        .{ .kind = position_data_location, .x = 1, .y = 70, .z = 2 },
        .{ .kind = position_data_poi_position, .x = 10, .y = 60, .z = 20 },
        .{ .kind = position_data_poi_size, .x = 40, .y = 20, .z = 50 },
    };
    const q_none = StockQuestWrite{
        .id = "tier1_rally",
        .quest_code = 4,
        .objective_count = 1,
    };
    var q_poi = q_none;
    q_poi.position_data = pos[0..];
    q_poi.rally_marker_activated = true;
    try writeStockQuest(&w_none, q_none);
    try writeStockQuest(&w_poi, q_poi);
    try std.testing.expectEqual(w_none.written().len + 3 * 13, w_poi.written().len);
    // RallyMarkerActivated sits right after the entries, ahead of the tail:
    // rewards (u16 marker + i32 count, no rewards) | faction u8 | day i32.
    const out = w_poi.written();
    const tail_after_rally: usize = 2 + 4 + 1 + 4;
    try std.testing.expectEqual(@as(u8, 1), out[out.len - tail_after_rally - 1]);

    // Each entry is a kind byte plus a Vector3, and only the total size was
    // asserted: x, y and z could rotate among themselves and 13 bytes still
    // held. The entries sit directly before rallyActivated and its tail.
    const entries_len = 3 * 13;
    const first = out.len - tail_after_rally - 1 - entries_len;
    var pr: binary.Reader = .{ .data = out[first..] };
    for (pos) |want| {
        try std.testing.expectEqual(want.kind, try pr.readByte());
        try std.testing.expectEqual(want.x, try pr.readF32());
        try std.testing.expectEqual(want.y, try pr.readF32());
        try std.testing.expectEqual(want.z, try pr.readF32());
    }
}

test "treasure chest objective write is 8 bytes not base" {
    // TreasureChest.Write = 2×i32 (8 B); BaseObjective.Write = version+value (2 B).
    // Same quest head → treasure body is exactly 6 bytes longer.
    var buf_base: [128]u8 = undefined;
    var buf_tc: [128]u8 = undefined;
    var w_base: binary.Writer = .{ .buf = &buf_base };
    var w_tc: binary.Writer = .{ .buf = &buf_tc };
    const kinds_base = [_]ObjectiveWriteKind{.base};
    const kinds_tc = [_]ObjectiveWriteKind{.treasure_chest};
    const q_base = StockQuestWrite{
        .id = "tier1_treasure",
        .state = .in_progress,
        .tracked = true,
        .current_phase = 1,
        .quest_code = 9,
        .objective_count = 1,
        .objective_kinds = kinds_base[0..],
    };
    var q_tc = q_base;
    q_tc.objective_kinds = kinds_tc[0..];
    try writeStockQuest(&w_base, q_base);
    try writeStockQuest(&w_tc, q_tc);
    const base = w_base.written();
    const tc = w_tc.written();
    try std.testing.expectEqual(base.len + 6, tc.len);
    // Objectives size marker (FinalizeSizeMarker includes the u16): base=4, treasure=10.
    // Layout after shared head (id/version/state/owners/tracked/phase/code).
    const id_prefix: usize = 1 + "tier1_treasure".len; // 7-bit len + bytes
    const head: usize = id_prefix + 1 + 1 + 1 + 4 + 4 + 1 + 1 + 4; // ver,fv,state,owners×2,tracked,phase,code
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, base[head..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, tc[head..][0..2], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, tc[head + 2 ..][0..4], .little)); // destroyCount
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, tc[head + 6 ..][0..4], .little)); // CurrentRadius
}

test "empty and time objective writes carry their own body size" {
    // ObjectiveStayWithin / ObjectivePOIStayWithin Write nothing; ObjectiveTime
    // writes a bare UInt16. Neither calls base, so neither emits FileVersion.
    var buf_empty: [128]u8 = undefined;
    var buf_time: [128]u8 = undefined;
    var w_empty: binary.Writer = .{ .buf = &buf_empty };
    var w_time: binary.Writer = .{ .buf = &buf_time };
    const kinds_empty = [_]ObjectiveWriteKind{.empty};
    const kinds_time = [_]ObjectiveWriteKind{.time};
    const values = [_]u8{47};
    const q_empty = StockQuestWrite{
        .id = "intro_buried_supplies",
        .state = .in_progress,
        .tracked = true,
        .current_phase = 1,
        .quest_code = 9,
        .objective_count = 1,
        .objective_values = values[0..],
        .objective_kinds = kinds_empty[0..],
    };
    var q_time = q_empty;
    q_time.objective_kinds = kinds_time[0..];
    try writeStockQuest(&w_empty, q_empty);
    try writeStockQuest(&w_time, q_time);
    const e = w_empty.written();
    const t = w_time.written();
    const id_prefix: usize = 1 + "intro_buried_supplies".len;
    const head: usize = id_prefix + 1 + 1 + 1 + 4 + 4 + 1 + 1 + 4;
    // FinalizeSizeMarker counts the u16 itself: empty body = 2, time body = 4.
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, e[head..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, t[head..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 47), std.mem.readInt(u16, t[head + 2 ..][0..2], .little));
}
