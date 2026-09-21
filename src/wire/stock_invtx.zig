//! Inventory-transaction bodies: the compact zdtd InvTx request/
//! response, the legacy entity-id data request, the stock
//! InventoryData request/response, and the IdMapping bodies, with the
//! request-order test.
//!
//! Split out of the packages.zig facade (same builders, same test);
//! import via `packages.stock_invtx` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");

test "inventory transaction request body is the compact zdtd order" {
    // buildInvTxRequest had no test at all. It is not the stock layout (that
    // is parseStockInvTx), but it rides the stock package name for loadgen and
    // the scenarios, so its field order still has to hold: op u8 | a u16 |
    // b u16 | qty u16 | entityId i32.
    var buf: [16]u8 = undefined;
    const body = try buildInvTxRequest(&buf, 2, 11, 22, 33, 106);
    try std.testing.expectEqual(@as(usize, 11), body.len);
    try std.testing.expectEqual(@as(u8, 2), body[0]);
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, body[1..3], .little));
    try std.testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, body[3..5], .little));
    try std.testing.expectEqual(@as(u16, 33), std.mem.readInt(u16, body[5..7], .little));
    try std.testing.expectEqual(@as(i32, 106), std.mem.readInt(i32, body[7..11], .little));
    // The parser must agree field for field, not just on the length.
    const p = try parseInvTxRequest(body);
    try std.testing.expectEqual(@as(u8, 2), p.op);
    try std.testing.expectEqual(@as(u16, 11), p.a);
    try std.testing.expectEqual(@as(u16, 22), p.b);
    try std.testing.expectEqual(@as(u16, 33), p.qty);
    try std.testing.expectEqual(@as(i32, 106), p.entity_id);
}

/// Stock-compatible player inventory body (NetPackagePlayerInventory.write fields).

/// NetPackagePlayerInventory (RE protocol-packages.md 5.4, write IL=107):
/// `toolbelt` present bool (+ ItemStack[] if set) | `bag` present bool
/// (+ Bag.Write) | `equipment` present bool (+ Equipment: ItemValue array, one
/// cosmetic i32 per slot, then the unlockedCosmetics count) | `dragAndDropItem`
/// present bool (+ ItemStack). The body-inventory table shows the cosmetics
/// list as a top-level field; the narrative places it inside the equipment
/// block, which is where stock_inv.writeEquipment puts it.

/// NetPackageIdMapping body: name string + i32 len + bytes, matching
/// `NetPackageIdMapping::write` (IL=18: `Write(String)`, `Write(Int32)`,
/// `Write(Byte[])`) and its read (IL=13: `ReadString`, `ReadInt32`,
/// `ReadBytes`).
pub fn buildIdMappingBody(buf: []u8, name: []const u8, data: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(name);
    try w.writeI32(@intCast(data.len));
    try w.writeBytes(data);
    return w.written();
}

/// One `(stock type id, name)` row of a NameIdMapping payload, in
/// `NameIdMapping::SaveToWriter` order (IL=72: per entry `Write(Int32)` the id
/// then `Write(String)` the name).
pub const IdMappingEntry = struct { id: i32, name: []const u8 };

/// NameIdMapping payload: version i32 (1) | count i32 | per entry id i32 +
/// name string. The count is written after the rows because stock backfills it
/// the same way (`SaveToWriter` seeks back to the reserved slot, IL=72).
/// Returns the payload for `buildIdMappingBody` to wrap.
pub fn buildNameIdMappingPayload(buf: []u8, entries: []const IdMappingEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(1); // version
    const count_pos = w.pos;
    try w.writeI32(0);
    var n: i32 = 0;
    for (entries) |e| {
        try w.writeI32(e.id);
        try w.writeString(e.name);
        n += 1;
    }
    std.mem.writeInt(i32, buf[count_pos..][0..4], n, .little);
    return w.written();
}

/// NetPackageHoldingItem (RE inventories/netpackage-bodies.md, write IL=16):
/// `entityId` i32 | `holdingItemStack` (ItemStack.Write) | `holdingItemIndex`
/// u8. Body written by stock_inv.writeHoldingItem.

/// zdtd's own compact transaction request: op:u8 | a:u16 | b:u16 | qty:u16 |
/// entity_id:i32. **Not the stock body.** Stock writes
/// `InventoryTransaction.Write` (RE inventories/netpackage-bodies.md, Write
/// IL=75): a nested op list (count | count | Key Vector3i | InitialHash i32 |
/// FinalHash i32 | Ops count | InventoryOperation.Write each). The C2S handler
/// tries the stock layout first and only falls back to this one
/// (`c2s/inv.zig`, parseStockInvTx), so a real client is served the stock
/// shape; this compact form exists for scenarios driving the same handler
/// without building a full stock transaction. It is never sent to a client.
pub fn buildInvTxRequest(buf: []u8, op: u8, a: u16, b: u16, qty: u16, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(op);
    try w.writeU16(a);
    try w.writeU16(b);
    try w.writeU16(qty);
    try w.writeI32(entity_id);
    return w.written();
}

/// Read side of buildInvTxRequest and likewise **not the stock body**: op u8 |
/// a u16 | b u16 | qty u16 | entityId i32. The stock layout is
/// InventoryTransaction.Write (RE inventories/netpackage-bodies.md, Write
/// IL=75), decoded by parseStockInvTx. The C2S handler tries the stock form
/// first and only falls back here (c2s/inv.zig), so a real client never
/// reaches this parser; it exists for the zdtd tools and fixtures that write
/// the compact form.
pub fn parseInvTxRequest(body: []const u8) !struct { op: u8, a: u16, b: u16, qty: u16, entity_id: i32 } {
    if (body.len < 11) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .op = try r.readByte(),
        .a = try r.readU16(),
        .b = try r.readU16(),
        .qty = try r.readU16(),
        .entity_id = try r.readI32(),
    };
}

/// zdtd's compact transaction response head, the counterpart to
/// buildInvTxRequest and likewise **not the stock body**: ok u8 |
/// dropped_entity i32, then an optional inventory snapshot the caller appends.
/// Stock's NetPackageInventoryTransactionResponse (RE write IL=66) is
/// inventories bool | i32 | success bool | keys count | Vector3i | bool.
pub fn buildInvTxResponseHead(buf: []u8, ok: bool, dropped_entity: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(@intFromBool(ok));
    try w.writeI32(dropped_entity);
    return w.written();
}

/// Legacy container data request: entity_id i32. **Not the stock body**, which
/// is `KeyHashPair` + `managerToken` Guid (RE inventories/netpackage-bodies.md
/// NetPackageInventoryDataRequest, write IL=12) and is decoded by
/// parseInvDataRequestStock. The C2S handler tries the stock form first
/// (c2s/inv.zig), so this serves loadgen and the older zdtd path only.
pub fn parseInvDataRequest(body: []const u8) !i32 {
    if (body.len < 4) return error.EndOfStream;
    return std.mem.readInt(i32, body[0..4], .little);
}

/// Stock NetPackageInventoryDataRequest: Guid inventoryKey | i32 hash | Guid managerToken.
pub const InvDataRequestStock = struct {
    inventory_key: [16]u8,
    hash: i32,
    manager_token: [16]u8,
};

/// Read side of the stock NetPackageInventoryDataRequest (RE
/// inventories/netpackage-bodies.md, write IL=12): `keyHash`
/// (KeyHashPair.Write, itself Guid `Key` + i32 `Hash`, Write IL=9) |
/// `managerToken` Guid. Both Guids are carried opaquely: the server matches the
/// key and echoes the token back on the response, so their internal layout is
/// never interpreted here.
pub fn parseInvDataRequestStock(body: []const u8) !InvDataRequestStock {
    // 16 + 4 + 16 = 36
    if (body.len < 36) return error.EndOfStream;
    var key: [16]u8 = undefined;
    var tok: [16]u8 = undefined;
    @memcpy(&key, body[0..16]);
    const hash = std.mem.readInt(i32, body[16..20], .little);
    @memcpy(&tok, body[20..36]);
    return .{ .inventory_key = key, .hash = hash, .manager_token = tok };
}

/// Stock NetPackageInventoryDataResponse for unknown key:
/// success=false | error string | inventoryKey | ItemStack[] null (i16 -1) | managerToken
pub fn buildInvDataResponseNotFound(buf: []u8, inventory_key: [16]u8, manager_token: [16]u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(false);
    try w.writeString("inventory not found");
    try w.writeBytes(&inventory_key);
    // ItemStack.WriteArray(null) → i16 -1
    try w.writeI16(-1);
    try w.writeBytes(&manager_token);
    return w.written();
}

/// NetPackageInventoryDataResponse (RE protocol-packages.md, write IL=24 /
/// Process IL=30): `success` bool | `errorMsg` string | `inventoryKey` Guid |
/// `ItemStack[]` (i16 count + ItemStack.Write each) | `managerToken` Guid.
/// The body-inventory table omits the stack array; the narrative row and the
/// client's UpdateInventory(items, managerToken) both have it, so the array
/// sits between key and token. This is the hash-miss / full-sync path; the
/// hash-hit path writes count -1 for a null list (Request Process IL=92 step 3).
pub fn buildInvDataResponseItems(
    buf: []u8,
    inventory_key: [16]u8,
    manager_token: [16]u8,
    slots: []const stock_inv.StockSlot,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true);
    try w.writeString(""); // empty error
    try w.writeBytes(&inventory_key);
    // ItemStack.WriteArray: i16 count + ItemStack.Write * n
    const n: i16 = @intCast(@min(slots.len, 32767));
    try w.writeI16(n);
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        try stock_inv.writeItemStack(&w, slots[i]);
    }
    try w.writeBytes(&manager_token);
    return w.written();
}
