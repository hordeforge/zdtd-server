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

/// Quest-area bounding box sent when no POI selector answered, so there is no
/// real prefab bbox to report. zdtd-owned: the true value is the selected
/// POI's own size, which fills these fields whenever a selector hits. It only
/// shapes the client's quest-area marker; sim containment reads the POI rect
/// in `ecs/components.PoiRect`, never these, so a fallback here cannot widen
/// a StayWithin zone.
pub const default_quest_size_x: f32 = 50;
pub const default_quest_size_y: f32 = 20;
pub const default_quest_size_z: f32 = 50;

pub const QuestPacketEntry = struct {
    quest_id: []const u8,
    loc_x: f32 = 0,
    loc_y: f32 = 70,
    loc_z: f32 = 0,
    size_x: f32 = default_quest_size_x,
    size_y: f32 = default_quest_size_y,
    size_z: f32 = default_quest_size_z,
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
    size_x: f32 = default_quest_size_x,
    size_y: f32 = default_quest_size_y,
    size_z: f32 = default_quest_size_z,
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

pub const NpcQuestEventType = enum(u8) {
    fetch_list = 0,
    remove_quest = 1,
    reset_quests = 2,
    add_used_poi = 3,
    clear_used_poi = 4,
};

pub const NpcQuestListHead = struct {
    npc_entity_id: i32,
    player_entity_id: i32,
    event_type: NpcQuestEventType,
    tier_level: i32 = 0,
    remove_index: u8 = 0,
};

/// Read side of NetPackageNPCQuestList (RE protocol-packages.md, Process
/// IL=180): `npcEntityID` i32 | `playerEntityID` i32 | `eventType` u8, then a
/// type-dependent tail. Only the head and `tierLevel` are decoded here; the
/// FetchList entry list, POI vectors and the RemoveQuest index beyond
/// `remove_index` are tails the server never needs to read back, since it is
/// the side that produces them.
///
/// An `eventType` outside the five stock values is rejected: stock switches on
/// it, so a sixth selects no tail and nothing sensible to answer.
pub fn parseNpcQuestList(body: []const u8) !NpcQuestListHead {
    if (body.len < 9) return error.EndOfStream;
    const npc = std.mem.readInt(i32, body[0..4], .little);
    const player = std.mem.readInt(i32, body[4..8], .little);
    const et_raw = body[8];
    const et = std.enums.fromInt(NpcQuestEventType, et_raw) orelse return error.InvalidEvent;
    var head: NpcQuestListHead = .{
        .npc_entity_id = npc,
        .player_entity_id = player,
        .event_type = et,
    };
    if (et == .fetch_list or et == .remove_quest or et == .add_used_poi or et == .clear_used_poi) {
        if (body.len < 13) return error.EndOfStream;
        head.tier_level = std.mem.readInt(i32, body[9..13], .little);
        if (et == .remove_quest) {
            if (body.len < 14) return error.EndOfStream;
            head.remove_index = body[13];
        }
    }
    return head;
}

pub const QuestObjectiveEventType = enum(u8) {
    treasure_radius_break = 0,
    treasure_complete = 1,
    block_activated = 2,
};

pub const QuestObjectiveUpdate = struct {
    sender_entity_id: i32,
    quest_code: i32,
    event_type: QuestObjectiveEventType,
    block_x: i32 = 0,
    block_y: i32 = 0,
    block_z: i32 = 0,
};

/// Read side of NetPackageQuestObjectiveUpdate (RE
/// inventories/netpackage-bodies.md, write IL=21): `senderEntityID` i32 |
/// `questCode` i32 | `eventType` u8 | `blockPos` (StreamUtils Vector3i), the
/// order buildQuestObjectiveUpdate writes.
///
/// The trailing block position is optional here while stock always writes it:
/// a 9-byte body leaves the position zero rather than erroring, which is what
/// keeps the zdtd-native {def_id u16, op u8} fixtures in c2s/quest.zig
/// parseable. An `eventType` outside the three stock values is rejected, since
/// stock switches on it and a fourth has no objective to advance.
pub fn parseQuestObjectiveUpdate(body: []const u8) !QuestObjectiveUpdate {
    if (body.len < 9) return error.EndOfStream;
    const et_raw = body[8];
    const et = std.enums.fromInt(QuestObjectiveEventType, et_raw) orelse return error.InvalidEvent;
    var out: QuestObjectiveUpdate = .{
        .sender_entity_id = std.mem.readInt(i32, body[0..4], .little),
        .quest_code = std.mem.readInt(i32, body[4..8], .little),
        .event_type = et,
    };
    if (body.len >= 21) {
        out.block_x = std.mem.readInt(i32, body[9..13], .little);
        out.block_y = std.mem.readInt(i32, body[13..17], .little);
        out.block_z = std.mem.readInt(i32, body[17..21], .little);
    }
    return out;
}

/// NetPackageQuestObjectiveUpdate (RE inventories/netpackage-bodies.md, write
/// IL=21): `senderEntityID` i32 | `questCode` i32 | `eventType` u8 |
/// `blockPos` (StreamUtils Vector3i = three i32).
pub fn buildQuestObjectiveUpdate(buf: []u8, u: QuestObjectiveUpdate) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(u.sender_entity_id);
    try w.writeI32(u.quest_code);
    try w.writeByte(@intFromEnum(u.event_type));
    try w.writeI32(u.block_x);
    try w.writeI32(u.block_y);
    try w.writeI32(u.block_z);
    return w.written();
}

/// `NetPackageQuestTreasurePoint/QuestPointActions`
/// (NetPackageQuestTreasurePoint_QuestPointActions.il.txt:3).
pub const quest_point_get_goto: u8 = 0;
pub const quest_point_get_treasure: u8 = 1;
pub const quest_point_update_treasure: u8 = 2;
pub const quest_point_update_blocks: u8 = 3;

/// `NetPackageQuestTreasurePoint` body. The layout branches on the leading
/// `ActionType` byte (read IL=54, NetPackageQuestTreasurePoint.il.txt:125):
/// action 2 carries only `questCode` i32 + `position` Vector3i; every other
/// action carries the full request/response form.
pub const QuestTreasurePoint = struct {
    action: u8 = 0,
    player_id: i32 = 0,
    distance: f32 = 0,
    offset: i32 = 0,
    treasure_radius: f32 = 0,
    blocks_per_reduction: i32 = 0,
    quest_code: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    off_x: f32 = 0,
    off_y: f32 = 0,
    off_z: f32 = 0,
    use_nearby: bool = false,
};

/// Read side of the branch above (stock `NetPackageQuestTreasurePoint::read`
/// IL=54, NetPackageQuestTreasurePoint.il.txt:125): `ActionType` u8, then for
/// action 2 only `questCode` i32 + `position` Vector3i, else `playerId` i32,
/// `distance` f32, `offset` i32, `treasureRadius` f32, `blocksPerReduction`
/// i32, `questCode` i32, `position` Vector3i, `treasureOffset` Vector3 and
/// `useNearby` bool.
pub fn parseQuestTreasurePoint(body: []const u8) binary.ReadError!QuestTreasurePoint {
    var r: binary.Reader = .{ .data = body };
    var out: QuestTreasurePoint = .{ .action = try r.readByte() };
    if (out.action == quest_point_update_treasure) {
        out.quest_code = try r.readI32();
        out.x = try r.readI32();
        out.y = try r.readI32();
        out.z = try r.readI32();
        return out;
    }
    out.player_id = try r.readI32();
    out.distance = try r.readF32();
    out.offset = try r.readI32();
    out.treasure_radius = try r.readF32();
    out.blocks_per_reduction = try r.readI32();
    out.quest_code = try r.readI32();
    out.x = try r.readI32();
    out.y = try r.readI32();
    out.z = try r.readI32();
    out.off_x = try r.readF32();
    out.off_y = try r.readF32();
    out.off_z = try r.readF32();
    out.use_nearby = try r.readBool();
    return out;
}

/// The server's answer to a GetTreasurePoint request: stock re-Setups the
/// package with the resolved dig position and sends it back to the asking
/// player (`Setup` IL=26 at :36 pins ActionType 1 and zeroes distance/offset;
/// `write` IL=59 at :182 emits the same branch the reader expects).
pub fn buildQuestTreasurePointReply(
    buf: []u8,
    player_id: i32,
    quest_code: i32,
    blocks_per_reduction: i32,
    x: i32,
    y: i32,
    z: i32,
    off_x: f32,
    off_y: f32,
    off_z: f32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(quest_point_get_treasure);
    try w.writeI32(player_id);
    try w.writeF32(0); // distance: Setup zeroes it
    try w.writeI32(0); // offset: Setup zeroes it
    try w.writeF32(0); // treasureRadius: not re-set by Setup
    try w.writeI32(blocks_per_reduction);
    try w.writeI32(quest_code);
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeF32(off_x);
    try w.writeF32(off_y);
    try w.writeF32(off_z);
    try w.writeBool(false); // useNearby: not re-set by Setup
    return w.written();
}

/// zdtd-native quest accept/progress, **not a stock client wire body**:
/// def_id u16, op u8 (0=list, 1=accept, 2=abandon). Kept for unit and loadgen
/// fixtures. The stock quest C2S shapes are NetPackageNPCQuestList
/// (parseNpcQuestList) and NetPackageQuestObjectiveUpdate, both tried before
/// this one in c2s/quest.zig.
pub fn parseQuestOp(body: []const u8) !struct { def_id: u16, op: u8 } {
    if (body.len < 3) return error.EndOfStream;
    return .{
        .def_id = std.mem.readInt(u16, body[0..2], .little),
        .op = body[2],
    };
}
