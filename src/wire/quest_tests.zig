//! Quest wire tests: shares, events, objectives.
//!
//! Split out of wire/stock_quest.zig (same tests, moved verbatim).

const std = @import("std");
const stock_quest = @import("stock_quest.zig");
const binary = @import("binary.zig");
const NpcQuestEventType = stock_quest.NpcQuestEventType;
const ObjectiveWriteKind = stock_quest.ObjectiveWriteKind;
const PositionEntry = stock_quest.PositionEntry;
const QuestEventType = stock_quest.QuestEventType;
const QuestObjectiveEventType = stock_quest.QuestObjectiveEventType;
const QuestPacketEntry = stock_quest.QuestPacketEntry;
const QuestState = stock_quest.QuestState;
const RewardWire = stock_quest.RewardWire;
const SharedQuestEvent = stock_quest.SharedQuestEvent;
const StockQuestWrite = stock_quest.StockQuestWrite;
const buildNpcQuestListFetch = stock_quest.buildNpcQuestListFetch;
const buildQuestEvent = stock_quest.buildQuestEvent;
const buildQuestObjectiveUpdate = stock_quest.buildQuestObjectiveUpdate;
const buildQuestTreasurePointReply = stock_quest.buildQuestTreasurePointReply;
const buildSharedQuestShare = stock_quest.buildSharedQuestShare;
const objective_file_version = stock_quest.objective_file_version;
const parseNpcQuestList = stock_quest.parseNpcQuestList;
const parseQuestEventHead = stock_quest.parseQuestEventHead;
const parseQuestObjectiveUpdate = stock_quest.parseQuestObjectiveUpdate;
const parseQuestTreasurePoint = stock_quest.parseQuestTreasurePoint;
const parseSharedQuestHead = stock_quest.parseSharedQuestHead;
const position_data_location = stock_quest.position_data_location;
const position_data_poi_position = stock_quest.position_data_poi_position;
const position_data_poi_size = stock_quest.position_data_poi_size;
const quest_file_version = stock_quest.quest_file_version;
const quest_point_get_treasure = stock_quest.quest_point_get_treasure;
const quest_point_update_treasure = stock_quest.quest_point_update_treasure;
const writeQuestJournal = stock_quest.writeQuestJournal;
const writeStockQuest = stock_quest.writeStockQuest;

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

// --- NetPackageQuestEvent (rally marker activation / POI quest lock) ---

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
// --- Stock NetPackageNPCQuestList (V3.x) ---
// eventType: 0 FetchList, 1 RemoveQuest, 2 ResetQuests, 3 AddUsedPOI, 4 ClearUsedPOI

// --- Stock NetPackageQuestObjectiveUpdate (V3.x) ---
// senderEntityID i32 | questCode i32 | eventType u8 | blockPos Vector3i

test "stock npc quest list empty fetch layout" {
    var buf: [32]u8 = undefined;
    const body = try buildNpcQuestListFetch(&buf, 50, 106, 0, &.{});
    try std.testing.expectEqual(@as(usize, 17), body.len);
    const head = try parseNpcQuestList(body);
    try std.testing.expectEqual(@as(i32, 50), head.npc_entity_id);
    try std.testing.expectEqual(@as(i32, 106), head.player_entity_id);
    try std.testing.expectEqual(NpcQuestEventType.fetch_list, head.event_type);
    try std.testing.expectEqual(@as(i32, 0), head.tier_level);
    // entry count follows tier
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[13..17], .little));
}

test "stock quest objective update layout" {
    var buf: [32]u8 = undefined;
    const body = try buildQuestObjectiveUpdate(&buf, .{
        .sender_entity_id = 106,
        .quest_code = 1,
        .event_type = .block_activated,
        .block_x = 10,
        .block_y = 70,
        .block_z = 20,
    });
    try std.testing.expectEqual(@as(usize, 21), body.len);
    const u = try parseQuestObjectiveUpdate(body);
    try std.testing.expectEqual(@as(i32, 106), u.sender_entity_id);
    try std.testing.expectEqual(@as(i32, 1), u.quest_code);
    try std.testing.expectEqual(QuestObjectiveEventType.block_activated, u.event_type);
    // Whole block position: y and z were unread, so a swap would advance the
    // objective against a different block than the one the client activated.
    try std.testing.expectEqual(@as(i32, 10), u.block_x);
    try std.testing.expectEqual(@as(i32, 70), u.block_y);
    try std.testing.expectEqual(@as(i32, 20), u.block_z);
}

test "every declared npc quest and objective event variant parses" {
    // Both parsers derive their bound from the enum via std.enums.fromInt, so
    // a new variant stays legal on the wire instead of becoming InvalidEvent.
    for (std.enums.values(NpcQuestEventType)) |ev| {
        // 14 bytes covers the longest tail (remove_quest adds remove_index).
        var body: [14]u8 = @splat(0);
        std.mem.writeInt(i32, body[0..4], 50, .little);
        std.mem.writeInt(i32, body[4..8], 106, .little);
        body[8] = @intFromEnum(ev);
        const head = try parseNpcQuestList(&body);
        try std.testing.expectEqual(ev, head.event_type);
    }
    for (std.enums.values(QuestObjectiveEventType)) |ev| {
        var body: [21]u8 = @splat(0);
        std.mem.writeInt(i32, body[0..4], 106, .little);
        std.mem.writeInt(i32, body[4..8], 1, .little);
        body[8] = @intFromEnum(ev);
        const u = try parseQuestObjectiveUpdate(&body);
        try std.testing.expectEqual(ev, u.event_type);
    }
}

test "quest treasure point body branches on the action byte" {
    // Action 2 is the short form: questCode + Vector3i and nothing else.
    var short_buf: [32]u8 = undefined;
    var sw: binary.Writer = .{ .buf = &short_buf };
    try sw.writeByte(quest_point_update_treasure);
    try sw.writeI32(77);
    try sw.writeI32(10);
    try sw.writeI32(70);
    try sw.writeI32(-4);
    const short = try parseQuestTreasurePoint(sw.written());
    try std.testing.expectEqual(@as(usize, 17), sw.written().len);
    try std.testing.expectEqual(@as(i32, 77), short.quest_code);
    try std.testing.expectEqual(@as(i32, -4), short.z);

    // The reply form round-trips through the long branch.
    // The reply: check the bytes at fixed offsets rather than round-tripping.
    // A round trip through zdtd's own writer and reader proves they agree with
    // each other, not with stock, and Setup pins distance/offset/treasureRadius
    // to zero - three consecutive fields (f32, i32, f32) that no round-trip
    // assertion can tell apart from each other or from a width swap.
    // Order per NetPackageQuestTreasurePoint::read (IL=54, :125): action u8 |
    // playerId i32 | distance f32 | offset i32 | treasureRadius f32 |
    // blocksPerReduction i32 | questCode i32 | position Vector3i |
    // treasureOffset Vector3 | useNearby bool.
    var buf: [64]u8 = undefined;
    const reply = try buildQuestTreasurePointReply(&buf, 107, 77, 3, 100, 60, -200, 0.5, 0.25, 1.5);
    try std.testing.expectEqual(@as(usize, 1 + 4 + 4 + 4 + 4 + 4 + 4 + 12 + 12 + 1), reply.len);
    try std.testing.expectEqual(quest_point_get_treasure, reply[0]);
    const i32At = struct {
        fn f(b: []const u8, off: usize) i32 {
            return std.mem.readInt(i32, b[off..][0..4], .little);
        }
    }.f;
    const f32At = struct {
        fn f(b: []const u8, off: usize) f32 {
            return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
        }
    }.f;
    try std.testing.expectEqual(@as(i32, 107), i32At(reply, 1)); // playerId
    try std.testing.expectEqual(@as(f32, 0), f32At(reply, 5)); // distance
    try std.testing.expectEqual(@as(i32, 0), i32At(reply, 9)); // offset
    try std.testing.expectEqual(@as(f32, 0), f32At(reply, 13)); // treasureRadius
    try std.testing.expectEqual(@as(i32, 3), i32At(reply, 17)); // blocksPerReduction
    try std.testing.expectEqual(@as(i32, 77), i32At(reply, 21)); // questCode
    try std.testing.expectEqual(@as(i32, 100), i32At(reply, 25)); // position.x
    try std.testing.expectEqual(@as(i32, 60), i32At(reply, 29)); // position.y
    try std.testing.expectEqual(@as(i32, -200), i32At(reply, 33)); // position.z
    // Distinct offsets: equal ones could not catch a swap among the three.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f32At(reply, 37), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), f32At(reply, 41), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), f32At(reply, 45), 0.001);
    try std.testing.expectEqual(@as(u8, 0), reply[49]); // useNearby

    // The parser agrees with those bytes.
    const got = try parseQuestTreasurePoint(reply);
    try std.testing.expectEqual(@as(i32, 107), got.player_id);
    try std.testing.expectEqual(@as(i32, 3), got.blocks_per_reduction);
    try std.testing.expectEqual(@as(i32, -200), got.z);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), got.off_y, 0.001);

    try std.testing.expectError(error.EndOfStream, parseQuestTreasurePoint(reply[0 .. reply.len - 1]));
}

