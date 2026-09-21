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

// --- Stock NetPackageInventoryTransactionRequest parse (RE protocol-packages.md
// 6.13, items.md 2060-2087, InventoryOperation.Write IL) ---
//
// Body: i32 count, then per inventory: Guid key (16 bytes, .NET little-endian)
// + i32 initialHash + i32 finalHash + i32 opCount + opCount x
// InventoryOperation.Write. Each op: i16 operation (0 SetAbsolute, 1
// SetRelative, 2 SetAll); SetAbsolute/SetRelative write ItemStack.Write + i32
// index; SetAll writes ItemStack.WriteArray. The stock client sends this for
// container/backpack transactions; zdtd's native 11-byte body is tried first.

/// SetAll stack cap per op: stock backpack size is 36; 128 bounds hostile input.
pub const stock_tx_setall_cap: usize = 128;

pub const StockInvOp = struct {
    op: u8,
    stack: stock_inv.StockSlot = .{},
    index: i32 = 0,
    /// SetAll (op 2): NewStacks array; empty when op != 2 or null array.
    new_stacks: [stock_tx_setall_cap]stock_inv.StockSlot = undefined,
    new_n: u16 = 0,
};

/// Ops per inventory (a stock backpack move is 1-2; cap bounds hostile input).
pub const stock_tx_op_cap: usize = 8;
pub const stock_tx_entry_cap: usize = 4;

pub const StockInvEntry = struct {
    guid: [16]u8,
    initial_hash: i32,
    final_hash: i32,
    ops: [stock_tx_op_cap]StockInvOp = undefined,
    op_n: u8 = 0,
};

pub const StockInvTx = struct {
    entries: [stock_tx_entry_cap]StockInvEntry = undefined,
    entry_n: u8 = 0,
};

/// Read side of the stock NetPackageInventoryTransactionRequest body, one
/// InventoryTransaction.Write (RE inventories/netpackage-bodies.md, Write
/// IL=75): a nested op list of count | count | `Key` Vector3i | `InitialHash`
/// i32 | `FinalHash` i32 | ops count | InventoryOperation.Write each.
///
/// Returns error.EndOfStream on truncation and error.InvalidArgument when the
/// layout is not stock-shaped, which is how c2s/inv.zig knows to fall back to
/// the compact zdtd body (parseInvTxRequest).
pub fn parseStockInvTx(body: []const u8) !StockInvTx {
    var r: binary.Reader = .{ .data = body };
    var out: StockInvTx = .{};
    const count = try r.readI32();
    if (count < 0 or count > stock_tx_entry_cap) return error.InvalidArgument;
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const e = &out.entries[i];
        for (&e.guid) |*b| b.* = try r.readByte();
        e.initial_hash = try r.readI32();
        e.final_hash = try r.readI32();
        const op_count = try r.readI32();
        if (op_count < 0 or op_count > stock_tx_op_cap) return error.InvalidArgument;
        var k: usize = 0;
        while (k < @as(usize, @intCast(op_count))) : (k += 1) {
            const op_raw = try r.readI16();
            if (op_raw < 0 or op_raw > 2) return error.InvalidArgument;
            const op: u8 = @intCast(op_raw);
            const oe = &e.ops[k];
            oe.op = op;
            if (op == 2) {
                // SetAll: ItemStack.WriteArray (i16 count; -1 = null array).
                const n = try r.readI16();
                if (n == -1) {
                    oe.new_n = 0; // null NewStacks
                    continue;
                }
                if (n < 0 or n > stock_tx_setall_cap) return error.InvalidArgument;
                var j: i16 = 0;
                while (j < n) : (j += 1) {
                    oe.new_stacks[@intCast(j)] = try stock_inv.readItemStack(&r);
                }
                oe.new_n = @intCast(n);
            } else {
                oe.stack = try stock_inv.readItemStack(&r);
                oe.index = try r.readI32();
            }
        }
        e.op_n = @intCast(op_count);
        out.entry_n = @intCast(count);
    }
    return out;
}

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

test "inventory data request stock layout and not-found response" {
    var key: [16]u8 = .{1} ** 16;
    var tok: [16]u8 = .{2} ** 16;
    var req_buf: [36]u8 = undefined;
    @memcpy(req_buf[0..16], &key);
    std.mem.writeInt(i32, req_buf[16..20], 42, .little);
    @memcpy(req_buf[20..36], &tok);
    const req = try parseInvDataRequestStock(&req_buf);
    try std.testing.expectEqual(@as(i32, 42), req.hash);
    try std.testing.expectEqualSlices(u8, &key, &req.inventory_key);

    var resp_buf: [128]u8 = undefined;
    const resp = try buildInvDataResponseNotFound(&resp_buf, key, tok);
    try std.testing.expectEqual(@as(u8, 0), resp[0]); // success false
    // error string 7bit-len then UTF8; then key; then i16 -1
    try std.testing.expect(resp.len > 20);

    const items = [_]stock_inv.StockSlot{
        .{ .type_id = stock_inv.items_start_here + 7, .count = 3, .quality = 1 },
        .{},
    };
    const ok = try buildInvDataResponseItems(&resp_buf, key, tok, items[0..]);
    try std.testing.expectEqual(@as(u8, 1), ok[0]);
    try std.testing.expect(ok.len > resp.len);
}

test "parseStockInvTx reads the stock InventoryTransaction layout" {
    // Golden bytes per RE (items.md 2060-2087, InventoryOperation Write IL):
    // count 1; one inventory: 16-byte Guid, initialHash, finalHash, opCount 1,
    // then one SetAbsolute op (i16 0, ItemStack.Write, i32 index).
    var buf: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(1); // inventoryCount
    // Guid: 16 bytes (0x00..0x0F).
    for (0..16) |i| try w.writeByte(@intCast(i));
    try w.writeI32(111); // initialHash
    try w.writeI32(222); // finalHash
    try w.writeI32(1); // opCount
    try w.writeI16(0); // SetAbsolute
    try stock_inv.writeItemStack(&w, .{ .type_id = 800, .count = 1, .quality = 1 });
    try w.writeI32(3); // index slot 3
    const tx = try parseStockInvTx(w.written());
    try std.testing.expectEqual(@as(u8, 1), tx.entry_n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &tx.entries[0].guid);
    try std.testing.expectEqual(@as(i32, 111), tx.entries[0].initial_hash);
    try std.testing.expectEqual(@as(i32, 222), tx.entries[0].final_hash);
    try std.testing.expectEqual(@as(u8, 1), tx.entries[0].op_n);
    try std.testing.expectEqual(@as(u8, 0), tx.entries[0].ops[0].op);
    try std.testing.expectEqual(@as(i32, 3), tx.entries[0].ops[0].index);
    try std.testing.expectEqual(@as(u16, 1), tx.entries[0].ops[0].stack.count);
    try std.testing.expectEqual(@as(i32, 800), tx.entries[0].ops[0].stack.type_id);

    // SetAll op: i16 2 + ItemStack.WriteArray (i16 count, -1 = null).
    var buf2: [256]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &buf2 };
    try w2.writeI32(1);
    for (0..16) |i| try w2.writeByte(@intCast(i));
    try w2.writeI32(1);
    try w2.writeI32(2);
    try w2.writeI32(1); // opCount
    try w2.writeI16(2); // SetAll
    try w2.writeI16(2); // array count
    try stock_inv.writeItemStack(&w2, .{ .type_id = 800, .count = 5, .quality = 1 });
    try stock_inv.writeItemStack(&w2, .{ .type_id = 801, .count = 2, .quality = 1 });
    const tx2 = try parseStockInvTx(w2.written());
    try std.testing.expectEqual(@as(u8, 1), tx2.entries[0].op_n);
    try std.testing.expectEqual(@as(u8, 2), tx2.entries[0].ops[0].op);
    try std.testing.expectEqual(@as(u16, 2), tx2.entries[0].ops[0].new_n);
    try std.testing.expectEqual(@as(i32, 800), tx2.entries[0].ops[0].new_stacks[0].type_id);
    try std.testing.expectEqual(@as(i32, 801), tx2.entries[0].ops[0].new_stacks[1].type_id);

    // Null WriteArray: i16 -1 decodes to an empty stack list.
    var buf3: [256]u8 = undefined;
    var w3: binary.Writer = .{ .buf = &buf3 };
    try w3.writeI32(1);
    for (0..16) |i| try w3.writeByte(@intCast(i));
    try w3.writeI32(1);
    try w3.writeI32(2);
    try w3.writeI32(1);
    try w3.writeI16(2);
    try w3.writeI16(-1);
    const tx3 = try parseStockInvTx(w3.written());
    try std.testing.expectEqual(@as(u8, 2), tx3.entries[0].ops[0].op);
    try std.testing.expectEqual(@as(u16, 0), tx3.entries[0].ops[0].new_n);

    // A native 11-byte body must NOT parse as a stock transaction.
    var native: [11]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 };
    try std.testing.expectError(error.EndOfStream, parseStockInvTx(&native));
}

test "id mapping body is name, then length, then bytes" {
    // The join path builds this for the item NameIdMapping and nothing read it
    // back: swapping the name string with the i32 length left the whole suite
    // green while the body no longer matched `NetPackageIdMapping::read`
    // (IL=13: ReadString, ReadInt32, ReadBytes).
    var buf: [64]u8 = undefined;
    const body = try buildIdMappingBody(&buf, "items", &.{ 7, 8, 9 });

    var r: binary.Reader = .{ .data = body };
    var name_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("items", try r.readString(&name_buf));
    try std.testing.expectEqual(@as(i32, 3), try r.readI32());
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, body[r.pos..]);
}
test "name id mapping payload is version, count, then id before name" {
    // The join path built this inline in game/join.zig, where neither the
    // mutant tool nor the coverage counts reach: swapping the id with the name
    // left the whole suite green while the payload stopped matching
    // `NameIdMapping::SaveToWriter` (IL=72: per entry Write(Int32) the id then
    // Write(String) the name).
    var buf: [128]u8 = undefined;
    const payload = try buildNameIdMappingPayload(&buf, &.{
        .{ .id = 65543, .name = "meleeToolStoneAxe" },
        .{ .id = 65545, .name = "gunHandgunT1Pistol" },
    });

    var r: binary.Reader = .{ .data = payload };
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // version
    try std.testing.expectEqual(@as(i32, 2), try r.readI32()); // backfilled count
    var name_buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 65543), try r.readI32());
    try std.testing.expectEqualStrings("meleeToolStoneAxe", try r.readString(&name_buf));
    try std.testing.expectEqual(@as(i32, 65545), try r.readI32());
    try std.testing.expectEqualStrings("gunHandgunT1Pistol", try r.readString(&name_buf));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());

    // An empty map still carries a well-formed header.
    const none = try buildNameIdMappingPayload(&buf, &.{});
    try std.testing.expectEqual(@as(usize, 8), none.len);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, none[4..8], .little));
}
