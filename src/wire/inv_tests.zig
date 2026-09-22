//! Inventory wire tests: slots, bags, containers.
//!
//! Split out of wire/stock_inv.zig (same tests, moved verbatim).

const std = @import("std");
const stock_inv = @import("stock_inv.zig");
const binary = @import("binary.zig");
const components = @import("../ecs/components.zig");
const platform_user = @import("platform_user.zig");
const StockSlot = stock_inv.StockSlot;
const applyPlayerDataNetwork = stock_inv.applyPlayerDataNetwork;
const applyPlayerInventoryBody = stock_inv.applyPlayerInventoryBody;
const bag_slots = stock_inv.bag_slots;
const buildFromEcs = stock_inv.buildFromEcs;
const buildHoldingFromEcs = stock_inv.buildHoldingFromEcs;
const buildPersistentPlayerState = stock_inv.buildPersistentPlayerState;
const buildPlayerDataBodyForTest = stock_inv.buildPlayerDataBodyForTest;
const equipment_slots = stock_inv.equipment_slots;
const item_value_save_version = stock_inv.item_value_save_version;
const items_start_here = stock_inv.items_start_here;
const max_lp_blocks_on_wire = stock_inv.max_lp_blocks_on_wire;
const max_vending_positions_on_wire = stock_inv.max_vending_positions_on_wire;
const parseBagSlots = stock_inv.parseBagSlots;
const persistent_player_state_max_len = stock_inv.persistent_player_state_max_len;
const persistent_reason_login = stock_inv.persistent_reason_login;
const readDropItemsContainer = stock_inv.readDropItemsContainer;
const readHoldingItem = stock_inv.readHoldingItem;
const readItemValue = stock_inv.readItemValue;
const slotFromEcs = stock_inv.slotFromEcs;
const toEcs = stock_inv.toEcs;
const typeFromBuiltinId = stock_inv.typeFromBuiltinId;
const writeDropItemsContainer = stock_inv.writeDropItemsContainer;
const writeEmptyItemValue = stock_inv.writeEmptyItemValue;
const writeHoldingItem = stock_inv.writeHoldingItem;
const writeItemStack = stock_inv.writeItemStack;
const writeItemValue = stock_inv.writeItemValue;
const writePlayerInventory = stock_inv.writePlayerInventory;

test "persistent player state body layout" {
    var buf: [512]u8 = undefined;
    const primary: platform_user.Id = .{ .platform = "EOS", .id = "0123456789abcdef" };
    const native: platform_user.Id = .{ .platform = "Steam", .id = "76561190000000000" };
    const lp = [_][3]i32{ .{ 10, 64, -20 }, .{ 300, 70, 512 } };
    const vm = [_][3]i32{.{ -44, 68, 91 }};
    const body = try buildPersistentPlayerState(&buf, 107, "Alice", primary, native, -273, 61, 449, &lp, &vm);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(persistent_reason_login, try r.readByte());
    // PrimaryId PUID
    try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // present
    // UserIdentifierVersion: stock writes 1 and pops it on read (asm.il 31206).
    try std.testing.expectEqual(platform_user.user_identifier_version, try r.readByte());
    var sbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("EOS", try r.readString(&sbuf));
    try std.testing.expectEqualStrings("0123456789abcdef", try r.readString(&sbuf));
    // NativeId PUID (same shape, native platform account)
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    _ = try r.readByte();
    try std.testing.expectEqualStrings("Steam", try r.readString(&sbuf));
    try std.testing.expectEqualStrings("76561190000000000", try r.readString(&sbuf));
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // playGroup Standard
    try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // AuthoredText present
    try std.testing.expectEqualStrings("Alice", try r.readString(&sbuf));
    // author PUID is the PrimaryId again (asm.il 1885235)
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
    _ = try r.readByte();
    try std.testing.expectEqualStrings("EOS", try r.readString(&sbuf));
    try std.testing.expectEqualStrings("0123456789abcdef", try r.readString(&sbuf));
    try std.testing.expectEqual(@as(i64, 0), try r.readI64()); // lastLogin
    try std.testing.expectEqual(@as(i32, -273), try r.readI32());
    try std.testing.expectEqual(@as(i32, 61), try r.readI32());
    try std.testing.expectEqual(@as(i32, 449), try r.readI32());
    try std.testing.expectEqual(@as(i32, 107), try r.readI32()); // entity_id
    // lpBlockCount : i32, then that many Vector3i (RE server-lifecycle.md 6.1
    // PersistentPlayerData.Write IL=205). These used to be a hardcoded 0, so a
    // player's land claims never reached the client overlay.
    try std.testing.expectEqual(@as(i32, 2), try r.readI32()); // lpBlockCount
    try std.testing.expectEqual(@as(i32, 10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 64), try r.readI32());
    try std.testing.expectEqual(@as(i32, -20), try r.readI32());
    try std.testing.expectEqual(@as(i32, 300), try r.readI32());
    try std.testing.expectEqual(@as(i32, 70), try r.readI32());
    try std.testing.expectEqual(@as(i32, 512), try r.readI32());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // backpacks count
    // Bedroll Vector3i, then the two trailing counts. Nothing read these, so
    // the y = int.max "unset" marker could swap with either zero beside it and
    // the body still parsed - which would put a real coordinate where the
    // marker belongs and hand the player a bedroll at the world edge.
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // bedroll x
    try std.testing.expectEqual(std.math.maxInt(i32), try r.readI32()); // y: unset
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // bedroll z
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // questPositions
    // OwnedVendingMachinePositions: count then Vector3i list (PPD.Write
    // fields 25-28). This was a hardcoded 0, so a player who rented a machine
    // lost its map marker on every rejoin.
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // vending count
    try std.testing.expectEqual(@as(i32, -44), try r.readI32());
    try std.testing.expectEqual(@as(i32, 68), try r.readI32());
    try std.testing.expectEqual(@as(i32, 91), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "persistent player state with no claims writes an empty lpBlocks list" {
    var buf: [512]u8 = undefined;
    const primary: platform_user.Id = .{ .platform = "EOS", .id = "abc" };
    const body = try buildPersistentPlayerState(&buf, 7, "solo", primary, primary, 0, 0, 0, &.{}, &.{});
    // Walk to the count: the empty list must still write a 0, not vanish.
    var r: binary.Reader = .{ .data = body };
    _ = try r.readByte(); // reason
    var sbuf: [64]u8 = undefined;
    for (0..2) |_| { // primary + native PUID
        _ = try r.readByte();
        _ = try r.readByte();
        _ = try r.readString(&sbuf);
        _ = try r.readString(&sbuf);
    }
    _ = try r.readByte(); // playGroup
    _ = try r.readByte(); // AuthoredText present
    _ = try r.readString(&sbuf); // name
    _ = try r.readByte(); // author present
    _ = try r.readByte(); // version
    _ = try r.readString(&sbuf);
    _ = try r.readString(&sbuf);
    _ = try r.readI64(); // lastLogin
    for (0..4) |_| _ = try r.readI32(); // x, y, z, entity_id
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // lpBlockCount
}

test "persistent player state fits a full claim list at max identity length" {
    // The caller builds into a fixed slice of body_buf and drops the package on
    // error, so an overflow here is silent: the joining player's name never
    // reaches the other clients ("Player '' joined") and no claim overlay is
    // drawn. Both identity strings and the name are at their caps, with both
    // lists full, which is the largest body the join path can produce.
    var buf: [persistent_player_state_max_len]u8 = undefined;
    const long_id = "0123456789" ** 6 ++ "0123"; // 64 = platform_user.max_id_len
    const long_platform = "0123456789abcdef"; // 16 = platform_user.max_platform_len
    const primary: platform_user.Id = .{ .platform = long_platform, .id = long_id };
    var lp: [max_lp_blocks_on_wire][3]i32 = undefined;
    for (&lp, 0..) |*b, i| b.* = .{ @intCast(i), 64, @intCast(i) };
    var vm: [max_vending_positions_on_wire][3]i32 = undefined;
    for (&vm, 0..) |*p, i| p.* = .{ @intCast(i), 68, @intCast(i) };
    const body = try buildPersistentPlayerState(
        &buf,
        107,
        "0123456789abcdef0123456789abcdef", // 32 = the join name cap
        primary,
        primary,
        -273,
        61,
        449,
        &lp,
        &vm,
    );
    try std.testing.expect(body.len <= persistent_player_state_max_len);
}

// --- NetPackageBag: entityId i32 | u16 blob_len | Bag.Write ---

// --- NetPackageDropItemsContainer ---
// droppedByID i32 | containerEntity string | Vector3 | u16 count | ItemStack*n
// (write uses WriteItemStack loop, same as GameUtils list but count is u16 of array len)

// --- golden tests ---

test "applyPlayerDataNetwork applies equipment after drag" {
    var buf: [1024]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    // ECD.write(networkWrite=false), entityClass 0 (no player mid fields)
    try w.writeByte(36);
    try w.writeI32(0);
    try w.writeI32(106);
    try w.writeF32(std.math.floatMax(f32));
    try w.writeF32(-273);
    try w.writeF32(61);
    try w.writeF32(449);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeBool(true);
    try w.writeI32(4);
    try w.writeI32(0);
    try w.writeU32(0);
    try w.writeBool(false);
    try w.writeI16(0);
    try w.writeBool(false);
    try w.writeI32(-273);
    try w.writeI32(61);
    try w.writeI32(449);
    try w.writeI16(-1);
    try w.writeByte(0);
    try w.writeU16(0);
    try w.writeBool(false);
    try w.writeF32(0); // stressAmount v36
    // toolbelt: 1 stack (item 2) then pad to empty via list count=1 (rest empty on apply)
    try w.writeU16(1);
    try writeItemStack(&w, .{ .type_id = items_start_here + 2, .count = 3, .quality = 1 });
    try w.writeByte(0); // selectedInventorySlot
    // Bag v1 empty
    try w.writeByte(1);
    try w.writeU16(0);
    try w.writeBool(false);
    try w.writeBool(false);
    try w.writeBool(false);
    // dragAndDrop: 1 empty stack
    try w.writeU16(1);
    try w.writeU16(0);
    // alreadyCrafted / spawn / meta head before equipment
    try w.writeU16(0);
    try w.writeByte(0);
    try w.writeI64(0);
    try w.writeBool(true);
    try w.writeI16(0);
    try w.writeBool(true); // bLoaded
    try w.writeI32(-273);
    try w.writeI32(61);
    try w.writeI32(449);
    try w.writeF32(0);
    try w.writeI32(106);
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0);
    try w.writeI32(0);
    // Equipment.Write v4: slot0 = item 8, rest empty
    try w.writeByte(4);
    try writeItemValue(&w, .{ .type_id = items_start_here + 8, .count = 1, .quality = 1 });
    var ei: usize = 1;
    while (ei < equipment_slots) : (ei += 1) try w.writeByte(0);
    ei = 0;
    while (ei < equipment_slots) : (ei += 1) try w.writeI32(0);
    try w.writeI32(0);

    var inv: components.Inventory = .{};
    const h = try applyPlayerDataNetwork(w.written(), &inv, null, null);
    try std.testing.expectEqual(@as(i32, 106), h.entity_id);
    try std.testing.expectEqual(@as(f32, -273), h.x);
    try std.testing.expectEqual(@as(u16, 2), inv.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 3), inv.slots[0].count);
    try std.testing.expectEqual(@as(u16, 8), inv.slots[components.inv_equip_start].item_id);
    try std.testing.expectEqual(@as(u16, 1), inv.slots[components.inv_equip_start].count);
    try std.testing.expectEqual(@as(u16, 2), h.inv_slots); // toolbelt + equip
    try std.testing.expectEqual(@as(u16, 0), inv.holding); // selected slot 0

    var unchanged: components.Inventory = .{};
    unchanged.slots[0] = .{ .item_id = 7, .count = 9, .quality = 1 };
    unchanged.holding = 0;
    const before = unchanged;
    try std.testing.expectError(error.EndOfStream, applyPlayerDataNetwork(w.written()[0 .. w.written().len - 1], &unchanged, null, null));
    try std.testing.expectEqualDeep(before, unchanged);

    // The shared test builder emits the same body this fixture writes by hand,
    // so a scenario driving the real handler exercises this exact layout.
    var hbuf: [1024]u8 = undefined;
    var hw: binary.Writer = .{ .buf = &hbuf };
    try buildPlayerDataBodyForTest(&hw, 106, 2, 8);
    try std.testing.expectEqualSlices(u8, w.written(), hw.written());
}

test "empty item value is single zero byte" {
    var buf: [8]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try writeEmptyItemValue(&w);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, w.written());
}

test "item stack empty is count zero only" {
    var buf: [16]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try writeItemStack(&w, .{});
    try std.testing.expectEqual(@as(usize, 2), w.written().len);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, w.written()[0..2], .little));
}

test "item value v9 minimal shape" {
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    // absolute type items_start_here + 8 (stoneAxe builtin)
    // flags and ammo_index carry distinct non-zero values: both defaulted to
    // 0 here, which made the CosmeticMods length byte, flags and ammo_index
    // three interchangeable zeros on the wire, so a swap among them emitted
    // identical bytes and the assertions below could not tell them apart.
    try writeItemValue(&w, .{
        .type_id = items_start_here + 8,
        .count = 1,
        .quality = 1,
        .meta = 0,
        .seed = 42,
        .flags = 3,
        .ammo_index = 2,
    });
    const b = w.written();
    try std.testing.expectEqual(@as(u8, 9), b[0]); // save version
    try std.testing.expectEqual(@as(u8, 1), b[1]); // flags: is item
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, b[2..4], .little));
    // UseTimes f32 @4, Quality u16 @8, Meta u16 @10, meta_count @12
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b[8..10], .little));
    try std.testing.expectEqual(@as(u8, 0), b[12]); // metadata count
    try std.testing.expectEqual(@as(u8, 0), b[13]); // mods
    try std.testing.expectEqual(@as(u8, 0), b[14]); // cosmetics length
    try std.testing.expectEqual(@as(u8, 3), b[15]); // Flags (V3.2.0 bitfield)
    try std.testing.expectEqual(@as(u8, 2), b[16]); // SelectedAmmoIndex
    try std.testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, b[17..19], .little));
    try std.testing.expectEqual(@as(u8, 0), b[19]); // texture default
}

test "player inventory flags and toolbelt length" {
    var buf: [4096]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[0] = .{ .item_id = 8, .count = 1, .quality = 1 };
    inv.slots[1] = .{ .item_id = 2, .count = 5, .quality = 1 };
    inv.slots[10] = .{ .item_id = 7, .count = 20, .quality = 1 }; // bag
    inv.holding = 0;
    const body = try buildFromEcs(&buf, &inv);
    try std.testing.expect(body.len > 20);
    try std.testing.expectEqual(@as(u8, 1), body[0]); // has toolbelt
    // toolbelt list count u16 == 10
    try std.testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, body[1..3], .little));
    // first stack count == 1
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, body[3..5], .little));
}

test "holding item body layout" {
    var buf: [128]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[0] = .{ .item_id = 8, .count = 1, .quality = 1 };
    inv.holding = 0;
    const body = try buildHoldingFromEcs(&buf, 42, &inv);
    try std.testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, body[4..6], .little));
    try std.testing.expectEqual(@as(u8, 0), body[body.len - 1]); // holding index

    // The empty-stack form the join path sends before the inventory lands. It
    // was open-coded in game/join.zig, out of reach of the wire audits, and a
    // swapped entityId/count there went unnoticed by the whole suite. Layout
    // is `NetPackageHoldingItem::write` (IL=16): Write(Int32) entityId,
    // ItemStack::Write (count u16, no ItemValue when zero), Write(Byte) index.
    var eb: [16]u8 = undefined;
    var ew: binary.Writer = .{ .buf = &eb };
    try writeHoldingItem(&ew, 42, .{}, 3);
    const empty = ew.written();
    try std.testing.expectEqual(@as(usize, 7), empty.len);
    try std.testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, empty[0..4], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, empty[4..6], .little));
    try std.testing.expectEqual(@as(u8, 3), empty[6]);
}

/// Test reverse mapper: stock type 65536+id → id (matches typeFromBuiltinId).
fn testRevItemId(_: ?*anyopaque, st: i32) u16 {
    if (st >= items_start_here) {
        const rel = st - items_start_here;
        if (rel > 0 and rel < 100) return @intCast(rel);
    }
    return 0;
}

test "ecs starter kit encodes without overflow" {
    var buf: [8192]u8 = undefined;
    var inv: components.Inventory = .{};
    _ = inv.addItem(8, 1);
    _ = inv.addItem(2, 5);
    _ = inv.addItem(7, 20);
    inv.holding = 0;
    const body = try buildFromEcs(&buf, &inv);
    try std.testing.expect(body.len < buf.len);
    try std.testing.expect(body.len > 100); // padded bag + equipment
    // Header: has toolbelt + 10-slot toolbelt list (stock shape), not just non-empty.
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, body[1..3], .little));
    // Round-trip apply so overflow-free encode still carries the three stacks.
    var inv2: components.Inventory = .{};
    const rev = testRevItemId;
    try applyPlayerInventoryBody(body, &inv2, rev, null);
    var n8: u16 = 0;
    var n2: u16 = 0;
    var n7: u16 = 0;
    for (inv2.slots[0..components.inv_equip_start]) |s| {
        if (s.item_id == 8) n8 += s.count;
        if (s.item_id == 2) n2 += s.count;
        if (s.item_id == 7) n7 += s.count;
    }
    try std.testing.expectEqual(@as(u16, 1), n8);
    try std.testing.expectEqual(@as(u16, 5), n2);
    try std.testing.expectEqual(@as(u16, 20), n7);
}

test "player inventory encode then apply roundtrip" {
    var buf: [8192]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[0] = .{ .item_id = 8, .count = 1, .quality = 1 };
    inv.slots[1] = .{ .item_id = 2, .count = 5, .quality = 1 };
    inv.slots[10] = .{ .item_id = 7, .count = 20, .quality = 1 };
    inv.holding = 0;
    const body = try buildFromEcs(&buf, &inv);

    var inv2: components.Inventory = .{};
    const rev = testRevItemId;
    try applyPlayerInventoryBody(body, &inv2, rev, null);
    try std.testing.expectEqual(@as(u16, 8), inv2.slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 1), inv2.slots[0].count);
    try std.testing.expectEqual(@as(u16, 2), inv2.slots[1].item_id);
    try std.testing.expectEqual(@as(u16, 5), inv2.slots[1].count);
    try std.testing.expectEqual(@as(u16, 7), inv2.slots[10].item_id);
    try std.testing.expectEqual(@as(u16, 20), inv2.slots[10].count);
}

test "holding encode decode" {
    var buf: [128]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[0] = .{ .item_id = 8, .count = 1, .quality = 1 };
    inv.holding = 0;
    const body = try buildHoldingFromEcs(&buf, 99, &inv);
    const p = try readHoldingItem(body);
    try std.testing.expectEqual(@as(i32, 99), p.entity_id);
    try std.testing.expectEqual(@as(u8, 0), p.holding_index);
    try std.testing.expectEqual(@as(u16, 1), p.stack.count);
    try std.testing.expectEqual(@as(i32, items_start_here + 8), p.stack.type_id);
}

test "drop items container encode decode" {
    var buf: [512]u8 = undefined;
    const items = [_]StockSlot{
        .{ .type_id = items_start_here + 7, .count = 5, .quality = 1 },
        .{ .type_id = items_start_here + 1, .count = 2, .quality = 1 },
    };
    const body = try writeDropItemsContainer(&buf, 10, "EntityLootContainer", 1.5, 70, -2.5, items[0..]);
    const p = try readDropItemsContainer(body);
    try std.testing.expectEqual(@as(i32, 10), p.dropped_by);
    // All three coordinates, not just x: y and z had no assertion, so they
    // could swap and the round-trip still passed.
    try std.testing.expectEqual(@as(f32, 1.5), p.x);
    try std.testing.expectEqual(@as(f32, 70), p.y);
    try std.testing.expectEqual(@as(f32, -2.5), p.z);
    try std.testing.expectEqual(@as(usize, 2), p.item_count);
    try std.testing.expectEqual(@as(u16, 5), p.items[0].count);
}

test "use_times round-trips through the wire slot conversion" {
    const ecs_slot = components.InvSlot{
        .item_id = 7,
        .count = 1,
        .quality = 1,
        .meta = 0,
        .use_times = 42.5,
    };
    const stock = slotFromEcs(ecs_slot, null, null);
    try std.testing.expectEqual(@as(f32, 42.5), stock.use_times);
    const back = toEcs(stock, null, null);
    try std.testing.expectEqual(@as(f32, 42.5), back.use_times);
    // An empty slot resets use_times to 0 (no phantom durability).
    const empty = slotFromEcs(components.InvSlot{ .item_id = 0, .count = 0 }, null, null);
    try std.testing.expectEqual(@as(f32, 0), empty.use_times);
}

test "C2S apply keeps bag slots past the old 32-slot subset" {
    // The ECS bag is the full stock 45 (was 32): a client bag item at index
    // 40 (slots[50]) must survive the apply, not be dropped (ADR 0007
    // resolved 2026-08-22).
    var buf: [8192]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[components.inv_bag_start + 40] = .{ .item_id = 7, .count = 20, .quality = 1 };
    const body = try buildFromEcs(&buf, &inv);
    var applied: components.Inventory = .{};
    try applyPlayerInventoryBody(body, &applied, null, null);
    try std.testing.expectEqual(@as(u16, 7), applied.slots[components.inv_bag_start + 40].item_id);
    try std.testing.expectEqual(@as(u16, 20), applied.slots[components.inv_bag_start + 40].count);
    // The stock bag width is 45 and the ECS bag matches it now.
    try std.testing.expectEqual(bag_slots, components.inv_bag_count);
    // Equip is the stock 12-wide too.
    try std.testing.expectEqual(@as(usize, 12), components.inv_equip_count);
}

test "a bag count wider than the ECS bag does not spill into other slots" {
    // The apply path's bag loop runs to the client's declared u16 count, not
    // to the ECS bag width: the index guard inside the loop is what keeps bag
    // index 45 and beyond from writing into equipment. Nothing pinned that,
    // and the loop reads a stack per iteration, so a forged count is bounded
    // by the body running out rather than by a cap.
    var buf: [8192]u8 = undefined;
    var slots: [bag_slots + 1]StockSlot = @splat(.{});
    slots[bag_slots - 1] = .{ .type_id = items_start_here + 7, .count = 20 };
    slots[bag_slots] = .{ .type_id = items_start_here + 8, .count = 3 };
    var w: binary.Writer = .{ .buf = &buf };
    try writePlayerInventory(&w, &.{}, &slots, &.{}, null);

    var applied: components.Inventory = .{};
    applied.slots[0] = .{ .item_id = 2, .count = 5 };
    for (applied.slots[components.inv_equip_start..]) |*slot| {
        slot.* = .{ .item_id = 99, .count = 1, .quality = 1 };
    }
    const before = applied;
    try applyPlayerInventoryBody(w.written(), &applied, null, null);
    try std.testing.expectEqual(@as(u16, 7), applied.slots[components.inv_equip_start - 1].item_id);
    try std.testing.expectEqual(@as(u16, 20), applied.slots[components.inv_equip_start - 1].count);
    try std.testing.expectEqualDeep(before.slots[0..components.inv_bag_start].*, applied.slots[0..components.inv_bag_start].*);
    try std.testing.expectEqualDeep(before.slots[components.inv_equip_start..].*, applied.slots[components.inv_equip_start..].*);

    var truncated: components.Inventory = .{};
    try std.testing.expectError(error.EndOfStream, applyPlayerInventoryBody(w.written()[0 .. w.pos - 1], &truncated, null, null));
}

test "item mods round-trip through the wire ItemValue" {
    // Stock ItemValue.Write (IL=323) carries the Modifications array; zdtd
    // now captures the mod ids on read and emits them on write, so a modded
    // weapon keeps its attachments through the wire.
    var src: StockSlot = .{
        .type_id = items_start_here + 40,
        .count = 1,
        .quality = 5,
    };
    src.mods = .{ 10, 20, 0, 0 };
    src.mod_qualities = .{ 3, 5, 0, 0 };
    src.mod_n = 2;
    var buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try writeItemValue(&w, src);
    var r: binary.Reader = .{ .data = w.written() };
    const out = try readItemValue(&r);
    try std.testing.expectEqual(@as(u8, 2), out.mod_n);
    try std.testing.expectEqual(@as(u16, 10), out.mods[0]);
    try std.testing.expectEqual(@as(u16, 20), out.mods[1]);
    try std.testing.expectEqual(@as(u8, 3), out.mod_qualities[0]);
    try std.testing.expectEqual(@as(u8, 5), out.mod_qualities[1]);
    try std.testing.expectEqual(@as(u16, 5), out.quality);

    // Nested mod ItemValue carries Quality (then meta 0). Byte-check the
    // first mod body so a write/read swap of quality vs meta stays visible.
    // Layout: outer version u8 | flags u8 | type u16 | useTimes f32 | quality
    // u16 | meta u16 | metaCount u8 | Modifications.Length u8 | present bool,
    // then the nested value starts.
    const body = w.written();
    const nested = 1 + 1 + 2 + 4 + 2 + 2 + 1 + 1 + 1;
    try std.testing.expectEqual(@as(u8, 9), body[nested]); // nested version
    try std.testing.expectEqual(@as(u8, 1), body[nested + 1]); // item flag
    try std.testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, body[nested + 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, body[nested + 8 ..][0..2], .little)); // quality
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[nested + 10 ..][0..2], .little)); // meta
}

test "item mods survive the ECS conversion both ways" {
    var inv: components.InvSlot = .{
        .item_id = 30,
        .count = 1,
        .quality = 3,
    };
    inv.mods = .{ 12, 13, 0, 0 };
    inv.mod_qualities = .{ 4, 6, 0, 0 };
    inv.mod_n = 2;
    const wire = slotFromEcs(inv, null, null);
    try std.testing.expectEqual(@as(u8, 2), wire.mod_n);
    try std.testing.expectEqual(@as(u8, 4), wire.mod_qualities[0]);
    try std.testing.expectEqual(@as(u8, 6), wire.mod_qualities[1]);
    const back = toEcs(wire, null, null);
    try std.testing.expectEqual(@as(u8, 2), back.mod_n);
    try std.testing.expectEqual(@as(u16, 12), back.mods[0]);
    try std.testing.expectEqual(@as(u16, 13), back.mods[1]);
    try std.testing.expectEqual(@as(u8, 4), back.mod_qualities[0]);
    try std.testing.expectEqual(@as(u8, 6), back.mod_qualities[1]);
}

test "bag blob parses the stock Bag.Write layout" {
    // Bag.Write IL=71: version 1 | u16 count | N x ItemStack | client
    // cosmetics tail (locked/touched/preferences, not validated).
    var body: [256]u8 = undefined;
    var w = binary.Writer{ .buf = &body };
    try w.writeByte(1); // version
    try w.writeU16(2); // slot count
    try writeItemStack(&w, .{ .type_id = items_start_here + 5, .count = 3 });
    try writeItemStack(&w, .{ .type_id = 0, .count = 0 }); // empty slot
    var out: [8]StockSlot = undefined;
    const n = try parseBagSlots(w.written(), out[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(i32, items_start_here + 5), out[0].type_id);
    try std.testing.expectEqual(@as(u16, 3), out[0].count);
    try std.testing.expectEqual(@as(i32, 0), out[1].type_id);

    // Bounds: an over-long count is rejected, not truncated.
    var b2: [16]u8 = undefined;
    var w2 = binary.Writer{ .buf = &b2 };
    try w2.writeByte(1);
    try w2.writeU16(99);
    try std.testing.expectError(error.Overflow, parseBagSlots(w2.written(), out[0..]));
    // Unknown Bag version fails closed.
    var b3: [8]u8 = undefined;
    var w3 = binary.Writer{ .buf = &b3 };
    try w3.writeByte(7);
    try w3.writeU16(0);
    try std.testing.expectError(error.Overflow, parseBagSlots(w3.written(), out[0..]));
}

test "ItemValue stats survive a parse and a re-write" {
    // Stock ItemValue.Write (IL=323): flag bit 2, a u8 count, then one
    // `type u8 | slotA i16 | slotB i16` per entry, ahead of the mod arrays.
    // The server used to skip the block on read and never write it, so an
    // echo stripped the passive deltas a client-created item carries.
    var buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    var slot: StockSlot = .{
        .type_id = items_start_here + 7,
        .count = 1,
        .quality = 6,
        .stats_n = 2,
    };
    // `EntityDamage` base 20 (no boost) and `DegradationMax` boosted by 5.
    slot.stats[0] = .{ .effect = 1, .slot_a = 20, .slot_b = 0 };
    slot.stats[1] = .{ .effect = 8, .slot_a = 0, .slot_b = 5 };
    try writeItemValue(&w, slot);
    const body = w.written();

    var r: binary.Reader = .{ .data = body };
    const parsed = try readItemValue(&r);
    try std.testing.expectEqual(@as(u8, 2), parsed.stats_n);
    try std.testing.expectEqual(@as(u8, 1), parsed.stats[0].effect);
    try std.testing.expectEqual(@as(i16, 20), parsed.stats[0].slot_a);
    try std.testing.expectEqual(@as(i16, 0), parsed.stats[0].slot_b);
    try std.testing.expectEqual(@as(u8, 8), parsed.stats[1].effect);
    try std.testing.expectEqual(@as(i16, 5), parsed.stats[1].slot_b);

    // Byte-for-byte round-trip: the writer reproduces what the reader took.
    var buf2: [128]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &buf2 };
    try writeItemValue(&w2, parsed);
    try std.testing.expectEqualSlices(u8, body, w2.written());

    // An item without stats keeps the old shape: no bit 2, no count block.
    const plain: StockSlot = .{ .type_id = items_start_here + 7, .count = 1 };
    var buf3: [64]u8 = undefined;
    var w3: binary.Writer = .{ .buf = &buf3 };
    try writeItemValue(&w3, plain);
    var r3: binary.Reader = .{ .data = w3.written() };
    try std.testing.expectEqual(@as(u8, item_value_save_version), try r3.readByte());
    try std.testing.expectEqual(@as(u8, 0), (try r3.readByte()) & 2);
    r3.pos = 0;
    const parsed3 = try readItemValue(&r3);
    try std.testing.expectEqualDeep(plain, parsed3);
    try std.testing.expectEqual(@as(usize, 0), r3.remaining());
}
