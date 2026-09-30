//! Tile-entity wire tests: storage, vendors, triggers.
//!
//! Split out of wire/stock_te.zig (same tests, moved verbatim).

const std = @import("std");
const stock_te = @import("stock_te.zig");
const buildPoweredTriggerTeBodyToServer = stock_te.buildPoweredTriggerTeBodyToServer;
const testWorkstationBody = stock_te.testWorkstationBody;
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");
const platform_user = @import("platform_user.zig");
const unity_hash = @import("../assets/unity_hash.zig");
const containers = @import("../world/containers.zig");
const containers_mod = containers;
const blocks_mod = @import("../assets/blocks.zig");
const workstations = @import("../world/workstations.zig");
const PoweredTriggerTe = stock_te.PoweredTriggerTe;
const Vec3i = stock_te.Vec3i;
const buildLightTeBody = stock_te.buildLightTeBody;
const buildPoweredTriggerTeBody = stock_te.buildPoweredTriggerTeBody;
const buildStorageTeBody = stock_te.buildStorageTeBody;
const buildVendingTeBody = stock_te.buildVendingTeBody;
const buildWorkstationTeBody = stock_te.buildWorkstationTeBody;
const feature_hash_signable = stock_te.feature_hash_signable;
const feature_hash_storage = stock_te.feature_hash_storage;
const parsePoweredTriggerTeBody = stock_te.parsePoweredTriggerTeBody;
const parseSignableTeBody = stock_te.parseSignableTeBody;
const parseStorageTeBody = stock_te.parseStorageTeBody;
const parseVendingTeBody = stock_te.parseVendingTeBody;
const parseWorkstationTeBody = stock_te.parseWorkstationTeBody;
const spliceStorageEcho = stock_te.spliceStorageEcho;
const trigger_type_motion = stock_te.trigger_type_motion;
const trigger_type_switch = stock_te.trigger_type_switch;
const max_ws_slots = stock_te.max_ws_slots;
const reserveU32 = stock_te.reserveU32;
const finalizeU32 = stock_te.finalizeU32;
const writeStorageFeature = stock_te.writeStorageFeature;
const trigger_type_timer_relay = stock_te.trigger_type_timer_relay;
const trigger_type_trip_wire = stock_te.trigger_type_trip_wire;

test "workstation te body roundtrip keeps stock array lengths" {
    var buf: [8192]u8 = undefined;
    const body = try testWorkstationBody(&buf);
    const p = try parseWorkstationTeBody(body);
    try std.testing.expectEqual(@as(i32, 10), p.world_x);
    try std.testing.expectEqual(@as(i32, 1301), p.block_id);
    try std.testing.expectEqual(workstations.stock_fuel_len, p.fuel_n);
    try std.testing.expectEqual(workstations.stock_input_len, p.input_n);
    try std.testing.expectEqual(workstations.stock_tools_len, p.tools_n);
    try std.testing.expectEqual(workstations.stock_output_len, p.output_n);
    try std.testing.expectEqual(workstations.stock_last_input_len, p.last_input_n);
    try std.testing.expectEqual(workstations.stock_queue_len, p.queue_n);
    try std.testing.expectEqual(workstations.stock_melt_len, p.melt_n);
    try std.testing.expectEqual(@as(u16, 5), p.fuel[0].count);
    try std.testing.expectEqual(@as(u16, 12), p.input[0].count);
    try std.testing.expect(p.is_burning);
    try std.testing.expect(p.is_player_placed);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), p.burn_time_left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), p.melt[0], 0.01);
}

test "workstation queue slot keeps its recipe and identity fields" {
    var buf: [8192]u8 = undefined;
    const body = try testWorkstationBody(&buf);
    const p = try parseWorkstationTeBody(body);
    const active = p.queue[p.queue_n - 1];
    try std.testing.expectEqual(@as(i16, 3), active.multiplier);
    try std.testing.expect(active.is_crafting);
    try std.testing.expectEqual(@as(i32, 171), active.starting_entity_id);
    // These two sat unasserted, and their fixture values matched a neighbour,
    // so a swap on either side of them emitted identical bytes.
    try std.testing.expectEqual(@as(u8, 4), active.quality);
    try std.testing.expectApproxEqAbs(@as(f32, 2.25), active.one_item_craft_time, 0.01);
    try std.testing.expectEqual(stock_inv.items_start_here + 9, active.output_type);
    try std.testing.expectEqual(@as(i32, 2), active.output_count);
    try std.testing.expectEqual(@as(i32, 5), active.craft_exp_gain);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), active.crafting_time, 0.01);
    try std.testing.expect(active.recipeBlob().len > 0);
    // Empty slots ride the wire too, and carry no recipe.
    try std.testing.expectEqual(@as(usize, 0), p.queue[0].recipeBlob().len);
}

test "workstation craft complete list roundtrips" {
    var buf: [8192]u8 = undefined;
    const body = try testWorkstationBody(&buf);
    const p = try parseWorkstationTeBody(body);
    try std.testing.expectEqual(@as(u8, 1), p.craft_complete_n);
    try std.testing.expectEqual(@as(i32, 171), p.craft_complete[0].crafter_entity_id);
    try std.testing.expectEqual(@as(i32, 5), p.craft_complete[0].exp_gain);
    try std.testing.expectEqual(@as(u16, 1), p.craft_complete[0].used_count);
    try std.testing.expectEqual(@as(u16, 2), p.craft_complete[0].item_count);
    try std.testing.expectEqualStrings("meleeToolRepairT0StoneAxe", p.craft_complete[0].recipeName());
}

test "workstation encoder drains the payload exactly" {
    // The check that would have caught the missing trailing lastInput array:
    // re-encoding the parsed body must reproduce it byte for byte.
    var buf: [8192]u8 = undefined;
    const body = try testWorkstationBody(&buf);
    const p = try parseWorkstationTeBody(body);
    var again: [8192]u8 = undefined;
    const re = try buildWorkstationTeBody(&again, p.handle, p.world_x, p.world_y, p.world_z, p.block_id, .{
        .fuel = p.fuel[0..p.fuel_n],
        .input = p.input[0..p.input_n],
        .tools = p.tools[0..p.tools_n],
        .output = p.output[0..p.output_n],
        .last_input_count = p.last_input_n,
        .last_input = p.last_input[0..p.last_input_blob_len],
        .queue = p.queue[0..p.queue_n],
        .craft_complete = p.craft_complete[0..p.craft_complete_n],
        .melt = p.melt[0..p.melt_n],
        .is_burning = p.is_burning,
        .burn_time_left = p.burn_time_left,
        .is_player_placed = p.is_player_placed,
    });
    try std.testing.expectEqualSlices(u8, body, re);
}

test "workstation body truncated before lastInput is rejected" {
    var buf: [8192]u8 = undefined;
    const body = try testWorkstationBody(&buf);
    // Drop the trailing lastInput array (u8 count + 3 empty stacks) and shrink
    // the declared payload length to match: a stock peer never sends this.
    const cut = 1 + @as(usize, workstations.stock_last_input_len) * 2;
    const short = body[0 .. body.len - cut];
    std.mem.writeInt(i32, short[17..][0..4], @intCast(short.len - 21), .little);
    try std.testing.expectError(error.EndOfStream, parseWorkstationTeBody(short));
}

test "workstation array count wider than our store is rejected" {
    var buf: [8192]u8 = undefined;
    const body = try testWorkstationBody(&buf);
    // Byte 21 is the payload's chunkPos start; the fuel count sits after
    // chunkPos (12) and the version byte (1).
    body[21 + 13] = @intCast(max_ws_slots + 1);
    try std.testing.expectError(error.InvalidString, parseWorkstationTeBody(body));
}

test "signable te parse reads the authored text and flags storage siblings" {
    // Stock carries a sign's text in the composite TE stream
    // (NetPackageTileEntity, TEComposite Feature TEFeatureSignable::Write),
    // not in its own package. The parser walks the module table by hash and by
    // the inclusive per-feature marker, so an unknown sibling is skipped
    // without being parsed.
    const TestBody = struct {
        fn build(
            buf: []u8,
            handle: u8,
            block_id: i32,
            text: ?[]const u8,
            modules: []const i32,
        ) ![]u8 {
            var pay: [1024]u8 = undefined;
            var pw: binary.Writer = .{ .buf = &pay };
            try pw.writeI32(3);
            try pw.writeI32(70);
            try pw.writeI32(5);
            const om = try reserveU32(&pw);
            try pw.writeI32(block_id);
            try pw.writeByte(0); // no owner
            try pw.writeByte(@intCast(modules.len));
            for (modules) |hash| {
                try pw.writeI32(hash);
                const fm = try reserveU32(&pw);
                if (hash == feature_hash_signable) {
                    try pw.writeBool(text != null);
                    if (text) |t| try pw.writeString(t);
                    try pw.writeBool(false); // no author identity
                } else {
                    try pw.writeU32(0); // opaque sibling body
                }
                finalizeU32(&pw, fm);
            }
            finalizeU32(&pw, om);
            var w: binary.Writer = .{ .buf = buf };
            try w.writeByte(handle);
            try w.writeI32(3);
            try w.writeI32(70);
            try w.writeI32(5);
            try w.writeI32(block_id);
            try w.writeI32(@intCast(pw.pos));
            try w.writeBytes(pay[0..pw.pos]);
            return w.written();
        }
    }.build;

    var body_buf: [1024]u8 = undefined;
    var text_buf: [64]u8 = undefined;
    const sign_only = try TestBody(&body_buf, 7, 742, "hello base", &.{feature_hash_signable});
    const sign = try parseSignableTeBody(sign_only, &text_buf);
    try std.testing.expectEqual(@as(u8, 7), sign.handle);
    try std.testing.expectEqual(@as(i32, 742), sign.block_id);
    try std.testing.expect(sign.has_text);
    try std.testing.expectEqualStrings("hello base", text_buf[0..sign.text_len]);
    try std.testing.expect(!sign.has_storage);

    // A clearing write (AuthoredText present = 0) yields no text.
    var body_buf2: [1024]u8 = undefined;
    const cleared = try TestBody(&body_buf2, 9, 742, null, &.{feature_hash_signable});
    const cl = try parseSignableTeBody(cleared, &text_buf);
    try std.testing.expect(!cl.has_text);
    try std.testing.expectEqual(@as(usize, 0), cl.text_len);

    // A writable crate's composite carries storage and signable: the sign leg
    // reports the storage sibling so the storage branch keeps the item list.
    var body_buf3: [1024]u8 = undefined;
    const mixed = try TestBody(&body_buf3, 11, 900, "crate label", &.{ feature_hash_storage, feature_hash_signable });
    const mx = try parseSignableTeBody(mixed, &text_buf);
    try std.testing.expect(mx.has_storage);
    try std.testing.expectEqualStrings("crate label", text_buf[0..mx.text_len]);

    // No signable module at all is not a sign body, and the storage parser
    // refuses the sign body (it used to create a phantom container there).
    var body_buf4: [1024]u8 = undefined;
    const storage_only = try TestBody(&body_buf4, 12, 900, null, &.{feature_hash_storage});
    try std.testing.expectError(error.NotSignableTe, parseSignableTeBody(storage_only, &text_buf));
    try std.testing.expectError(error.NotStorageTe, parseStorageTeBody(sign_only));

    // A text longer than the buffer fails closed instead of truncating
    // mid-string (stock has no wire limit; the XUI input caps the typed text).
    var big: [400]u8 = undefined;
    @memset(big[0..300], 'x');
    var body_buf5: [1024]u8 = undefined;
    const long = try TestBody(&body_buf5, 13, 742, big[0..300], &.{feature_hash_signable});
    try std.testing.expectError(error.Overflow, parseSignableTeBody(long, &text_buf));
}

test "storage echo keeps the client's other composite modules" {
    // A writable crate's composite is storage + signable (+ lockable). Stock
    // reserializes the whole TE it just read, so the echo carries every module;
    // zdtd replaces only the storage module with the server's clamped state and
    // leaves the rest of the client's body byte-identical.
    var server: containers.Container = .{ .pos = .{ .x = 4, .y = 70, .z = 4 }, .block_id = 500, .slot_count = 8 };
    server.setSlot(0, .{ .item_id = 7, .count = 12, .quality = 1 });
    const client: containers.Container = blk: {
        var c: containers.Container = .{ .pos = .{ .x = 4, .y = 70, .z = 4 }, .block_id = 500, .slot_count = 8 };
        c.setSlot(0, .{ .item_id = 7, .count = 999, .quality = 1 }); // over-stack claim
        break :blk c;
    };

    var pay: [8192]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &pay };
    try pw.writeI32(4);
    try pw.writeI32(70);
    try pw.writeI32(4);
    const om = try reserveU32(&pw);
    try pw.writeI32(500);
    try pw.writeByte(0); // no owner
    try pw.writeByte(2); // storage + signable
    try pw.writeI32(feature_hash_storage);
    const sm = try reserveU32(&pw);
    try writeStorageFeature(&pw, &client, null, null);
    finalizeU32(&pw, sm);
    try pw.writeI32(feature_hash_signable);
    const gm = try reserveU32(&pw);
    try pw.writeBool(true);
    try pw.writeString("crate label");
    try pw.writeBool(false);
    finalizeU32(&pw, gm);
    finalizeU32(&pw, om);

    var body_buf: [8192]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body_buf };
    try w.writeByte(4);
    try w.writeI32(4);
    try w.writeI32(70);
    try w.writeI32(4);
    try w.writeI32(500);
    try w.writeI32(@intCast(pw.pos));
    try w.writeBytes(pay[0..pw.pos]);
    const body = w.written();

    const parsed = try parseStorageTeBody(body);
    try std.testing.expect(parsed.found_storage);
    try std.testing.expect(parsed.storage_blob_len > 0);
    try std.testing.expectEqual(@as(u16, 999), parsed.items[0].count);

    var echo_buf: [8192]u8 = undefined;
    const echo = spliceStorageEcho(&echo_buf, body, &parsed, &server, null, null) orelse return error.TestUnexpectedResult;
    // Same length (the module encodes to a fixed span for the same grid), so
    // everything after the storage module - the sign text and its markers - is
    // byte-identical to what the client sent.
    try std.testing.expectEqual(body.len, echo.len);
    const after = parsed.storage_blob_off + parsed.storage_blob_len;
    try std.testing.expectEqualSlices(u8, body[after..], echo[after..]);
    const echoed = try parseStorageTeBody(echo);
    try std.testing.expectEqual(@as(u16, 12), echoed.items[0].count); // clamped

    // A body whose module would change length cannot be spliced in place: the
    // caller falls back to the storage-only echo, which the client's modern
    // reader accepts (it reads the declared modules and warns about the rest).
    var empty: containers.Container = .{ .pos = .{ .x = 4, .y = 70, .z = 4 }, .block_id = 500, .slot_count = 8 };
    try std.testing.expect(spliceStorageEcho(&echo_buf, body, &parsed, &empty, null, null) == null);
}

test "stable hash TEFeatureStorage" {
    try std.testing.expectEqual(@as(i32, 731446478), unity_hash.getStableHashCode("TEFeatureStorage"));
    try std.testing.expectEqual(feature_hash_storage, unity_hash.getStableHashCode("TEFeatureStorage"));
}

test "storage te encode decode roundtrip" {
    var cont: containers.Container = .{
        .pos = .{ .x = 10, .y = 70, .z = -3 },
        .block_id = 500,
        .slot_count = 8,
        .touched = true,
        .player_storage = true,
    };
    cont.setSlot(0, .{ .item_id = 7, .count = 12, .quality = 1 });
    cont.setSlot(2, .{ .item_id = 2, .count = 3, .quality = 1 });

    var buf: [8192]u8 = undefined;
    const body = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null, &.{});

    // The payload opens with chunkPos through StreamUtils.Write(Vector3i),
    // which emits x, y, z (`il/full-v3.2.0/_global/StreamUtils.il.txt` IL=13).
    // parseStorageTeBody skips those three, so nothing else here would notice
    // them coming out reordered - the swap-mutation audit found exactly that
    // gap. World (10, 70, -3) is local x 10, y 70 (full world y), z 13.
    const payload_start: usize = 1 + 12 + 4 + 4; // handle | worldPos | blockId | payLen
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, body[payload_start..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 70), std.mem.readInt(i32, body[payload_start + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 13), std.mem.readInt(i32, body[payload_start + 8 ..][0..4], .little));

    const parsed = try parseStorageTeBody(body);
    try std.testing.expectEqual(@as(i32, 10), parsed.world_x);
    try std.testing.expectEqual(@as(i32, 500), parsed.block_id);
    try std.testing.expect(parsed.item_count >= 3);
    try std.testing.expectEqual(@as(u16, 12), parsed.items[0].count);
    try std.testing.expectEqual(@as(i32, stock_inv.items_start_here + 7), parsed.items[0].type_id);
    // Unknown grid (0/0) synthesizes 2xN; a stored 6x2 grid rides the wire.
    try std.testing.expectEqual(@as(u16, 2), parsed.size_x);
    try std.testing.expectEqual(@as(u16, 4), parsed.size_y);
    cont.size_x = 6;
    cont.size_y = 2;
    const body2 = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null, &.{});
    const parsed2 = try parseStorageTeBody(body2);
    try std.testing.expectEqual(@as(u16, 6), parsed2.size_x);
    try std.testing.expectEqual(@as(u16, 2), parsed2.size_y);
}

test "a storage slot count reaching past its feature is rejected" {
    // The stack loop is bounded by the payload, not by the feature length the
    // body itself declared, so a forged count reads through the end of its own
    // feature and into whatever follows. It still fails closed: the reader runs
    // out (`EndOfStream`) before the post-loop overrun check is reached, and a
    // body that disagrees with itself is refused whole rather than yielding a
    // truncated container. Only the slots the container can hold are kept, so
    // the extra iterations cost reads, not memory.
    var cont: containers.Container = .{
        .pos = .{ .x = 10, .y = 70, .z = -3 },
        .block_id = 500,
        .slot_count = 4,
    };
    var buf: [8192]u8 = undefined;
    const body = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null, &.{});

    // handle 1 | worldPos 12 | blockId 4 | payLen 4 = 21, then chunkPos 12 |
    // outer marker 4 | blockId 4 | ownerTag 1 | moduleCount 1 | hash 4 |
    // feature marker 4 = 30, then the feature's hasList 1 | size_x 2 |
    // size_y 2 | touched 1 | worldTimeTouched 4 | playerStorage 1 = 11.
    const count_off: usize = 21 + 30 + 11;
    try std.testing.expectEqual(@as(i16, 4), std.mem.readInt(i16, body[count_off..][0..2], .little));
    std.mem.writeInt(i16, body[count_off..][0..2], 1000, .little);
    try std.testing.expectError(error.EndOfStream, parseStorageTeBody(body));
}

test "storage te carries the touch time the container was looted at" {
    // TEFeatureStorage.UpdateTick computes LootRespawnDays from
    // worldTimeTouched (RE loot-economy.md: daysElapsed =
    // (WorldTimeToTotalHours(now) - WorldTimeToTotalHours(worldTimeTouched))
    // / 24). Sending a constant 0 for a container the server knows was looted
    // on day 5 tells the client the loot is ancient.
    var cont: containers.Container = .{
        .pos = .{ .x = 4, .y = 70, .z = 4 },
        .block_id = 500,
        .slot_count = 4,
        .touched = true,
        .touched_day = 5,
        .player_storage = false,
    };
    var buf: [8192]u8 = undefined;
    const body = try buildStorageTeBody(&buf, 255, 4, 70, 4, 500, &cont, null, null, &.{});
    const parsed = try parseStorageTeBody(body);
    try std.testing.expect(parsed.touched);
    // Day 5 in stock world-time bits: (day - 1) * 24000, matching
    // WorldClock.worldTimeBits so both sides agree on the epoch.
    try std.testing.expectEqual(@as(u32, 4 * 24000), parsed.world_time_touched);

    // An untouched container has no touch time to report.
    cont.touched = false;
    cont.touched_day = 0;
    const body2 = try buildStorageTeBody(&buf, 255, 4, 70, 4, 500, &cont, null, null, &.{});
    const parsed2 = try parseStorageTeBody(body2);
    try std.testing.expectEqual(@as(u32, 0), parsed2.world_time_touched);

    // touched_day comes off disk as a u32, so a corrupt or absurd value must
    // saturate rather than wrap into a plausible-looking recent time.
    cont.touched = true;
    cont.touched_day = std.math.maxInt(u32);
    const body3 = try buildStorageTeBody(&buf, 255, 4, 70, 4, 500, &cont, null, null, &.{});
    const parsed3 = try parseStorageTeBody(body3);
    try std.testing.expectEqual(std.math.maxInt(u32), parsed3.world_time_touched);
}

// --- TileEntityVendingMachine (TileEntityType.VendingMachine = 7) ---
//
// Network payload (TileEntityVendingMachine::write asm.il ~440486):
//   TileEntity::write network: chunkPos Vector3i
//   i32 3                       // version constant
//   bool isLocked
//   PlatformUserIdentifierAbs.ToStream(ownerID, false)  // null = unowned
//   string passwordHash
//   i32 n | n x ToStream(allowedUserIds[i], false)
//   i32 rentalEndDay
//   TraderData.Write (writeTraderDataBody)
//   if TraderInfo.Rentable: u64 nextAutoBuy

test "powered trigger C2S body roundtrips every stock trigger type" {
    const types = [_]u8{ 0, 1, 2, 3, 4 };
    for (types) |t| {
        var buf: [512]u8 = undefined;
        var src: PoweredTriggerTe = .{
            .handle = 3,
            .is_player_placed = true,
            .power_item_type = 3,
            .parent = .{ .x = 1, .y = 70, .z = 2 },
            .pitch = 0.25,
            .yaw = -1.5,
            .trigger_type = t,
            .property1 = 2,
            .property2 = 5,
            .reset_trigger = true,
            .target_type = 9,
        };
        // Two wires with distinct coordinates: with a single entry an
        // off-by-one in the wire loop shifts parentPos but reads back the same
        // way a correct parse of a different count would, so the test could
        // not tell the two apart.
        src.wires[0] = .{ .x = 4, .y = 71, .z = 5 };
        src.wires[1] = .{ .x = -6, .y = 72, .z = 7 };
        src.wire_n = 2;
        const body = try buildPoweredTriggerTeBodyToServer(&buf, 10, 70, -3, 19300, src);
        const p = try parsePoweredTriggerTeBody(body);
        try std.testing.expectEqual(@as(u8, 3), p.handle);
        try std.testing.expectEqual(@as(i32, 10), p.world_x);
        try std.testing.expectEqual(@as(i32, 19300), p.block_id);
        try std.testing.expect(p.is_player_placed);
        try std.testing.expectEqual(@as(u8, 3), p.power_item_type);
        try std.testing.expectEqual(@as(usize, 2), p.wire_n);
        try std.testing.expectEqual(@as(i32, 4), p.wires[0].x);
        try std.testing.expectEqual(@as(i32, 71), p.wires[0].y);
        try std.testing.expectEqual(@as(i32, 5), p.wires[0].z);
        try std.testing.expectEqual(@as(i32, -6), p.wires[1].x);
        try std.testing.expectEqual(@as(i32, 72), p.wires[1].y);
        try std.testing.expectEqual(@as(i32, 7), p.wires[1].z);
        // parentPos sits right after the wire list, so a miscounted loop
        // lands here.
        try std.testing.expectEqual(@as(i32, 1), p.parent.x);
        try std.testing.expectEqual(@as(i32, 70), p.parent.y);
        try std.testing.expectEqual(@as(i32, 2), p.parent.z);
        try std.testing.expectApproxEqAbs(@as(f32, -1.5), p.yaw, 0.001);
        try std.testing.expectEqual(t, p.trigger_type);
        if (t == trigger_type_switch) {
            // A Switch carries no delay/duration/reset tail at all.
            try std.testing.expectEqual(@as(u8, 0), p.property1);
            try std.testing.expect(!p.reset_trigger);
        } else {
            try std.testing.expectEqual(@as(u8, 2), p.property1);
            try std.testing.expectEqual(@as(u8, 5), p.property2);
            // TimerRelay reads StartTime/EndTime and stops: stock never reads its
            // ResetTrigger byte back, so the trailing byte is simply left over.
            try std.testing.expectEqual(t != trigger_type_timer_relay, p.reset_trigger);
        }
        const want_target: i32 = if (t == trigger_type_motion) 9 else 0;
        try std.testing.expectEqual(want_target, p.target_type);
    }
}

test "powered trigger S2C body carries IsPowered and the type tail" {
    var buf: [512]u8 = undefined;
    const wires = [_]Vec3i{.{ .x = 1, .y = 2, .z = 3 }};
    const body = try buildPoweredTriggerTeBody(&buf, 255, 10, 70, -3, 19300, .{
        .power_item_type = 3,
        .wires = wires[0..],
        .is_powered = true,
        .trigger_type = trigger_type_trip_wire,
        .property1 = 1,
        .property2 = 4,
        .tripwire_parent = true,
        .target_type = 7,
    });
    // Outer header: handle u8 + Vector3i + blockId i32 + payloadLen i32 = 21 bytes.
    try std.testing.expectEqual(@as(u8, 255), body[0]);
    const pay_len = std.mem.readInt(i32, body[17..21], .little);
    try std.testing.expectEqual(@as(usize, @intCast(pay_len)), body.len - 21);

    // Each wire is a Vector3i written x, y, z. Nothing read these back, so a
    // swapped component rode out silently; the fixture uses 1, 2, 3 so the
    // three positions cannot be confused. Payload: chunkPos (12) + the
    // TileEntityPowered constant i32 (4) + isPlayerPlaced (1) + powerItemType
    // (1) + wire count (1) = 19 bytes before the first wire.
    const first_wire = 21 + 19;
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[first_wire..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, body[first_wire + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, body[first_wire + 8 ..][0..4], .little));
    // ToClient adds IsPowered before pitch/yaw and drops ResetTrigger, so it is
    // one byte longer than the same trigger going the other way.
    var c2s_buf: [512]u8 = undefined;
    var src: PoweredTriggerTe = .{ .trigger_type = trigger_type_trip_wire, .property1 = 1, .property2 = 4 };
    src.wires[0] = .{ .x = 1, .y = 2, .z = 3 };
    src.wire_n = 1;
    const c2s = try buildPoweredTriggerTeBodyToServer(&c2s_buf, 10, 70, -3, 19300, src);
    try std.testing.expectEqual(c2s.len + 1, body.len);
}

test "powered trigger body rejects truncation and oversized wire counts" {
    var buf: [512]u8 = undefined;
    var src: PoweredTriggerTe = .{ .trigger_type = trigger_type_motion, .property1 = 1, .property2 = 2 };
    src.wires[0] = .{ .x = 1, .y = 2, .z = 3 };
    src.wire_n = 1;
    const body = try buildPoweredTriggerTeBodyToServer(&buf, 0, 70, 0, 19300, src);
    // Every prefix short of the full body must fail rather than parse garbage.
    var cut: usize = 0;
    while (cut < body.len) : (cut += 1) {
        try std.testing.expectError(error.EndOfStream, parsePoweredTriggerTeBody(body[0..cut]));
    }
    // A wire count that cannot fit the remaining payload is rejected up front.
    var oversized: [512]u8 = undefined;
    @memcpy(oversized[0..body.len], body);
    oversized[21 + 12 + 4 + 1 + 1] = 0xff; // wireCount byte
    try std.testing.expectError(error.EndOfStream, parsePoweredTriggerTeBody(oversized[0..body.len]));
}

test "vending TE parse round-trips the owner-editable fields" {
    var buf: [2048]u8 = undefined;
    const body = try buildVendingTeBody(&buf, 0xAB, 10, 70, -3, .{
        .block_id = 300,
        .is_locked = true,
        .owner = .{ .platform = "Steam", .id = "76561198000000001" },
        .password_hash = "pw123",
        .allowed = &.{.{ .platform = "EOS", .id = "abc" }},
        .rental_end_day = 42,
        .trader_id = 4,
        .entries = &.{},
        .available_money = 1234,
        .rentable = true,
        .next_auto_buy = 999,
    });
    var plat_buf: [platform_user.max_platform_len]u8 = undefined;
    var id_buf: [platform_user.max_id_len]u8 = undefined;
    var pw_buf: [64]u8 = undefined;
    var allowed_plat: [8 * platform_user.max_platform_len]u8 = undefined;
    var allowed_id: [8 * platform_user.max_id_len]u8 = undefined;
    const v = try parseVendingTeBody(body, &plat_buf, &id_buf, &pw_buf, &allowed_plat, &allowed_id);
    try std.testing.expectEqual(@as(u8, 0xAB), v.handle);
    try std.testing.expectEqual(@as(i32, 10), v.world_x);
    try std.testing.expect(v.is_locked);
    try std.testing.expectEqualStrings("76561198000000001", v.owner.id);
    try std.testing.expectEqualStrings("pw123", v.password);
    try std.testing.expectEqual(@as(u8, 1), v.allowed_n);
    try std.testing.expectEqualStrings("abc", v.allowed[0].id);
    try std.testing.expectEqual(@as(i32, 42), v.rental_end_day);
}

test "vending TE body matches TileEntityVendingMachine::write layout" {
    // Outer header: handle | worldPos | teBlockId | payloadLen | payload.
    var buf: [2048]u8 = undefined;
    const body = try buildVendingTeBody(&buf, 0xAB, 10, 70, -3, .{
        .block_id = 300,
        .is_locked = true,
        .owner = .{ .platform = "Steam", .id = "76561198000000001" },
        .password_hash = "pw123",
        .allowed = &.{.{ .platform = "EOS", .id = "abc" }},
        .rental_end_day = 42,
        .trader_id = 4,
        .entries = &.{.{
            .item = .{ .type_id = 700, .count = 2, .quality = 1 },
            .markup = 0,
        }},
        .available_money = 1234,
        .rentable = true,
        .next_auto_buy = 999,
    });

    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(u8, 0xAB), try r.readByte());
    try std.testing.expectEqual(@as(i32, 10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 70), try r.readI32());
    try std.testing.expectEqual(@as(i32, -3), try r.readI32());
    try std.testing.expectEqual(@as(i32, 300), try r.readI32());
    const pay_len: usize = @intCast(try r.readI32());
    try std.testing.expectEqual(@as(usize, body.len - 21), pay_len);
    const pay = body[21..];

    var pr: binary.Reader = .{ .data = pay };
    // TileEntity::write network: chunkPos only (x/z mod 16, y raw).
    try std.testing.expectEqual(@as(i32, 10), try pr.readI32());
    try std.testing.expectEqual(@as(i32, 70), try pr.readI32());
    try std.testing.expectEqual(@as(i32, 13), try pr.readI32());
    // version constant 3
    try std.testing.expectEqual(@as(i32, 3), try pr.readI32());
    try std.testing.expect(pr.readBool() catch false);
    // owner platform id
    var pb: [16]u8 = undefined;
    var ib: [64]u8 = undefined;
    const owner = (try platform_user.read(&pr, &pb, &ib)).?;
    try std.testing.expectEqualStrings("Steam", owner.platform);
    try std.testing.expectEqualStrings("76561198000000001", owner.id);
    // passwordHash
    try std.testing.expectEqualStrings("pw123", try pr.readString(&pb));
    // allowed users
    try std.testing.expectEqual(@as(i32, 1), try pr.readI32());
    const allowed = (try platform_user.read(&pr, &pb, &ib)).?;
    try std.testing.expectEqualStrings("EOS", allowed.platform);
    try std.testing.expectEqualStrings("abc", allowed.id);
    // rentalEndDay
    try std.testing.expectEqual(@as(i32, 42), try pr.readI32());
    // TraderData.Write: trader id, lastInventoryUpdate u64, FileVersion 2,
    // entry count, ItemStack + markup + AddedByPlayer, tier count, money.
    try std.testing.expectEqual(@as(i32, 4), try pr.readI32());
    try std.testing.expectEqual(@as(u64, 0), try pr.readU64());
    try std.testing.expectEqual(@as(u8, 2), try pr.readByte());
    try std.testing.expectEqual(@as(i32, 1), try pr.readI32());
    try std.testing.expectEqual(@as(u16, 2), try pr.readU16()); // ItemStack count
    // ItemValue.Write (v9): version | flags | wire_type u16 | use_times f32 |
    // quality u16 | meta u16 | metadata count | mods | cosmetics | activated |
    // ammo_index | seed u16 | TextureFullArray.
    try std.testing.expectEqual(@as(u8, stock_inv.item_value_save_version), try pr.readByte());
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // flags
    try std.testing.expectEqual(@as(u16, 700), try pr.readU16()); // type id
    try std.testing.expectEqual(@as(f32, 0), try pr.readF32()); // use_times
    try std.testing.expectEqual(@as(u16, 1), try pr.readU16()); // quality
    try std.testing.expectEqual(@as(u16, 0), try pr.readU16()); // meta
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // metadata count
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // Modifications
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // CosmeticMods
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // activated
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // ammo_index
    try std.testing.expectEqual(@as(u16, 0), try pr.readU16()); // seed
    try std.testing.expect(!(pr.readBool() catch true)); // TextureFullArray
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // markup
    try std.testing.expect(pr.readBool() catch false == false); // AddedByPlayer
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // tier groups
    try std.testing.expectEqual(@as(i32, 1234), try pr.readI32()); // money
    // rentable: nextAutoBuy u64
    try std.testing.expectEqual(@as(u64, 999), try pr.readU64());
    try std.testing.expectEqual(@as(usize, 0), pr.remaining());
}

test "light TE body round-trips the stock network layout" {
    var buf: [128]u8 = undefined;
    const body = try buildLightTeBody(&buf, 255, 10, 70, 20, 1234, .{
        .intensity = 1.3,
        .range = 3.0,
        .color = 0xff2993ff,
        .light_type = 2,
        .angle = 0.5,
        .shadows = 1,
        .state = 3,
        .rate = 0.25,
        .delay = 1.5,
    });
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(u8, 255), try r.readByte()); // handle
    try std.testing.expectEqual(@as(i32, 10), try r.readI32()); // world pos
    try std.testing.expectEqual(@as(i32, 70), try r.readI32());
    try std.testing.expectEqual(@as(i32, 20), try r.readI32());
    // ProcessPackage drops the package when this disagrees with the client's
    // block at the position, so it carries the real world block.
    try std.testing.expectEqual(@as(i32, 1234), try r.readI32());
    const pay_len = try r.readI32();
    // chunkPos + version + the nine fields; the client reads every one of
    // them on the network path, so a short body is a stream desync.
    try std.testing.expect(pay_len == 3 * 4 + 2 + 4 + 4 + 4 + 1 + 4 + 1 + 1 + 4 + 4);
    // payload: local chunkPos + version 18 + fields
    try std.testing.expectEqual(@as(i32, 10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 70), try r.readI32());
    try std.testing.expectEqual(@as(i32, 4), try r.readI32()); // local z = mod(20,16)
    try std.testing.expectEqual(@as(u16, 18), try r.readU16());
    try std.testing.expectApproxEqAbs(@as(f32, 1.3), try r.readF32(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), try r.readF32(), 0.001);
    try std.testing.expectEqual(@as(u32, 0xff2993ff), try r.readU32());
    try std.testing.expectEqual(@as(u8, 2), try r.readByte());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try r.readF32(), 0.001);
    try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // shadows
    try std.testing.expectEqual(@as(u8, 3), try r.readByte()); // state
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), try r.readF32(), 0.001); // rate
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), try r.readF32(), 0.001); // delay
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "a locked container writes the lockable module and reads it back" {
    // TEFeatureLockable::Write IL=42 in network mode: `locked` bool | i32
    // allowed-user count | count x PlatformUserIdentifierAbs | password hash
    // string. zdtd keeps the module body verbatim so the padlock survives the
    // chunk stream, a rejoin and a restart instead of only riding one echo.
    var cont: containers.Container = .{
        .pos = .{ .x = 4, .y = 70, .z = 4 },
        .block_id = 500,
        .slot_count = 8,
    };
    var lb: [containers.max_lock_feature_bytes]u8 = undefined;
    var lw: binary.Writer = .{ .buf = &lb };
    try lw.writeBool(true);
    try lw.writeI32(0); // no allowed users
    try lw.writeString(""); // empty password hash
    const lock = lw.written();
    cont.lock_len = @intCast(lock.len);
    @memcpy(cont.lock_blob[0..lock.len], lock);
    try std.testing.expectEqual(stock_te.feature_hash_lockable, unity_hash.getStableHashCode("TEFeatureLockable"));

    var buf: [8192]u8 = undefined;
    const body = try buildStorageTeBody(&buf, 255, 4, 70, 4, 500, &cont, null, null, &.{});
    const parsed = try parseStorageTeBody(body);
    try std.testing.expect(parsed.found_storage);
    try std.testing.expect(parsed.found_lock);
    try std.testing.expectEqual(lock.len, parsed.lock_blob_len);
    try std.testing.expectEqualSlices(u8, lock, body[parsed.lock_blob_off..][0..parsed.lock_blob_len]);
    // Unlocked: the composite declares the storage module alone.
    cont.lock_len = 0;
    const plain = try buildStorageTeBody(&buf, 255, 4, 70, 4, 500, &cont, null, null, &.{});
    const parsed_plain = try parseStorageTeBody(plain);
    try std.testing.expect(parsed_plain.found_storage);
    try std.testing.expect(!parsed_plain.found_lock);
    // A module whose declared body is not a lockable field walk is refused, so
    // a forged blob never becomes the server's lock state.
    var bad: [64]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &bad };
    try bw.writeBool(true);
    try bw.writeI32(stock_te.max_lock_users + 1);
    const bad_lock = bw.written();
    var short_lock: [16]u8 = undefined;
    @memcpy(short_lock[0..bad_lock.len], bad_lock);
    try std.testing.expectError(error.InvalidString, stock_te.validateLockFeatureForTest(short_lock[0..bad_lock.len]));
}

test "a canvas composite body parses and a malformed canvas module is refused" {
    // TEFeatureCanvas::Write (network) emits one CanvasState: the GlobalSignId
    // (`libraryId` string + 16-byte Guid, GlobalSignId::ToStream IL=124) then
    // BlendMode u8, CanvasRotation u8 and ShowOnImposter bool (CanvasState
    // Write IL=18). zdtd keeps the body verbatim, so the walk is what keeps a
    // forged module out of the sign store.
    var cbuf: [64]u8 = undefined;
    var cw: binary.Writer = .{ .buf = &cbuf };
    try cw.writeString("prefab");
    try cw.writeBytes(&([_]u8{7} ** 16));
    try cw.writeByte(2); // BlendMode
    try cw.writeByte(1); // CanvasRotation
    try cw.writeBool(true); // ShowOnImposter
    const canvas = cw.written();
    try stock_te.validateCanvasFeatureForTest(canvas);

    // Compose the full NetPackageTileEntity body the client sends.
    var pay_buf: [256]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &pay_buf };
    try pw.writeI32(3); // chunkPos
    try pw.writeI32(70);
    try pw.writeI32(4);
    const outer = pw.pos;
    try pw.writeU32(0); // marker patched below
    try pw.writeI32(2000); // blockId
    try pw.writeByte(0); // null owner
    try pw.writeByte(1); // one module
    try pw.writeI32(stock_te.feature_hash_canvas);
    try pw.writeU32(@intCast(4 + canvas.len));
    try pw.writeBytes(canvas);
    const marker = pw.pos - outer;
    std.mem.writeInt(u32, pay_buf[outer..][0..4], @intCast(marker), .little);
    const payload = pw.written();

    var body_buf: [512]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &body_buf };
    try bw.writeByte(7); // handle
    try bw.writeI32(3);
    try bw.writeI32(70);
    try bw.writeI32(4);
    try bw.writeI32(2000);
    try bw.writeI32(@intCast(payload.len));
    try bw.writeBytes(payload);
    const body = bw.written();

    var text: [64]u8 = undefined;
    const parsed = try parseSignableTeBody(body, &text);
    try std.testing.expect(parsed.has_canvas);
    try std.testing.expect(!parsed.has_text);
    try std.testing.expectEqual(@as(i32, 2000), parsed.block_id);
    try std.testing.expectEqual(@as(i32, 3), parsed.world_x);

    // A module whose declared body cannot be walked as a canvas state fails
    // closed instead of being stored.
    try std.testing.expectError(error.EndOfStream, stock_te.validateCanvasFeatureForTest(&[_]u8{ 0, 2 }));
    // A body with neither signable nor canvas is still not a sign TE.
    var none_buf: [256]u8 = undefined;
    @memcpy(none_buf[0..body.len], body);
    // Module count to zero: the payload then carries no module at all.
    const count_off = 21 + 12 + 4 + 4 + 1;
    none_buf[count_off] = 0;
    try std.testing.expectError(error.NotSignableTe, parseSignableTeBody(none_buf[0..body.len], &text));
}

test "composite payload carries the block's declared modules in order" {
    // `TileEntityComposite.read` walks its own `modulesInternalOrder` and reads
    // one hash per entry, so the stream must carry exactly the declared
    // features in declaration order: a count that disagrees makes the client
    // drop the whole TE payload (TileEntityComposite.il IL_0105-0167). A
    // LockPickable module has no state on the network stream, and a block that
    // declares Lockable but holds no padlock writes the unlocked default body
    // (TEFeatureLockable::Read IL_002D-0076).
    var cont: containers_mod.Container = .{
        .pos = .{ .x = 10, .y = 70, .z = 13 },
        .block_id = 500,
        .size_x = 8,
        .size_y = 4,
    };
    cont.setSlot(0, .{ .item_id = 7, .count = 12, .quality = 1 });

    var buf: [8192]u8 = undefined;
    const declared = [_]blocks_mod.FeatureKind{ .storage, .lockable, .lock_pickable };
    const body = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null, &declared);
    const payload_start: usize = 1 + 12 + 4 + 4; // handle | worldPos | blockId | payLen
    const modules = payload_start + 12 + 4 + 4 + 1; // chunkPos | outer | blockId | owner
    try std.testing.expectEqual(@as(u8, 3), body[modules]);
    var r: binary.Reader = .{ .data = body, .pos = modules + 1 };
    const hashes = [_]i32{
        stock_te.feature_hash_storage,
        stock_te.feature_hash_lockable,
        stock_te.feature_hash_lock_pickable,
    };
    for (hashes, 0..) |want, i| {
        try std.testing.expectEqual(want, try r.readI32());
        // The size marker counts itself (`parseStorageTeBody`: feat_size - 4).
        const feat_size = try r.readU32();
        try std.testing.expect(feat_size >= 4);
        const len = feat_size - 4;
        if (i == 0) {
            try std.testing.expect(len > 0); // storage state
        } else if (i == 1) {
            // Unlocked: bool + i32 users + empty hash string.
            try std.testing.expectEqual(@as(u32, stock_te.unlocked_lock_body.len), len);
            try std.testing.expectEqualSlices(u8, &stock_te.unlocked_lock_body, body[r.pos..][0..len]);
        } else {
            // Version-only feature: no body on the network stream.
            try std.testing.expectEqual(@as(u32, 0), len);
        }
        r.pos += len;
    }

    // A declared module zdtd has no body for must not be claimed: the payload
    // falls back to the historical shape instead of desyncing the client.
    const bad = [_]blocks_mod.FeatureKind{ .storage, .door };
    const fallback = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null, &bad);
    try std.testing.expectEqual(@as(u8, 1), fallback[modules]);
}
