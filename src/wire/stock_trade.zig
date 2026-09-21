//! Player-action bodies: trader trade + ToServer header, vending
//! access, pickup-block, item reload, and set-block texture.
//!
//! Split out of the packages.zig facade (same builders, moved
//! verbatim); import via `packages.stock_trade` like the other
//! stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const stock_entity = @import("stock_entity.zig");
const platform_user = @import("platform_user.zig");
const stock_inv = @import("stock_inv.zig");
const components = @import("../ecs/components.zig");


/// Trader buy/sell, **not a stock package body**: trader_entity i32 | item u16
/// | qty u16 | side u8 (0=buy, 1=sell), exactly 9 bytes. Stock has no
/// NetPackageTraderTrade; a real client's trade shows up as its post-trade
/// TraderData copy (parseTraderDataToServer). This body rides under the
/// NetPackageTraderData name for loadgen and the sim, and c2s/quest.zig picks
/// the arm on an exact length of 9 so a stock body cannot land here.
pub fn parseTraderTrade(body: []const u8) !struct { trader_entity: i32, item: u16, qty: u16, side: u8 } {
    if (body.len < 9) return error.EndOfStream;
    return .{
        .trader_entity = std.mem.readInt(i32, body[0..4], .little),
        .item = std.mem.readInt(u16, body[4..6], .little),
        .qty = std.mem.readInt(u16, body[6..8], .little),
        .side = body[8],
    };
}

/// Stock NetPackagePlayerVendingMachine.read (asm.il 833593-833690): a
/// PlatformUserIdentifierAbs stream (FromStream(reader, false, false)), the
/// Vector3i position, and the removing flag. The client sends it when it rents
/// (removing=false) or clears (removing=true) a vending machine.
pub const VendingMachineAccess = struct {
    user: platform_user.Id,
    x: i32,
    y: i32,
    z: i32,
    removing: bool,
};

/// Read side of NetPackagePlayerVendingMachine (RE protocol-packages.md
/// residual table, write IL=28): `userId` (PlatformUserIdentifier) | x,y,z i32
/// | `removing` bool. An empty identity is an error rather than a null user:
/// the whole package exists to add or remove that user from a machine's
/// allowed list, so there is nothing to apply without one.
pub fn parseVendingMachineAccess(body: []const u8, plat_buf: []u8, id_buf: []u8) !VendingMachineAccess {
    var r: binary.Reader = .{ .data = body };
    const user = (try platform_user.read(&r, plat_buf, id_buf)) orelse return error.EndOfStream;
    const x = try r.readI32();
    const y = try r.readI32();
    const z = try r.readI32();
    const removing = try r.readBool();
    return .{ .user = user, .x = x, .y = y, .z = z, .removing = removing };
}

/// zdtd's own trade request body, **not a stock package**: traderEntity i32 |
/// item u16 | qty u16 | side u8. Stock has no single "trade" package; a buy or
/// sell rides the inventory transaction path. This feeds Game.handleTrade
/// directly and is never framed with a stock package name, so it cannot reach
/// or come from a client.
pub fn buildTraderTradeBody(buf: []u8, trader_entity: i32, item: u16, qty: u16, side: u8) ![]u8 {
    if (buf.len < 9) return error.Overflow;
    std.mem.writeInt(i32, buf[0..4], trader_entity, .little);
    std.mem.writeInt(u16, buf[4..6], item, .little);
    std.mem.writeInt(u16, buf[6..8], qty, .little);
    buf[8] = side;
    return buf[0..9];
}

/// Stock NetPackageTraderData ToServer header (asm.il 843046): the first byte
/// is isEntity; then entityId (i32) or the TE position Vector3i (3 x i32);
/// then hasTraderData; the TraderData::Write body follows when true. The real
/// client sends its post-trade cache copy back here (loot-economy.md §5). The
/// server parses it for framing but does not treat its stock or money as
/// authoritative.
pub const TraderDataToServer = struct {
    is_entity: bool,
    entity_id: i32 = -1,
    te_x: i32 = 0,
    te_y: i32 = 0,
    te_z: i32 = 0,
    has_trader_data: bool = false,
    /// TraderData::Write body (when has_trader_data).
    trader_data: []const u8 = &.{},
};

/// Read side of the stock NetPackageTraderData ToServer header documented
/// above (asm.il 843046; RE protocol-packages.md, Process IL=50). The
/// discriminant picks the length: an entity target is 1 + 4 + 1 bytes, a tile
/// entity 1 + 12 + 1, and the TraderData::Write body follows only when
/// `hasTraderData` is set. That body is returned as an unparsed slice; the
/// caller decides what of it, if anything, it trusts.
pub fn parseTraderDataToServer(body: []const u8) !TraderDataToServer {
    if (body.len < 6) return error.EndOfStream;
    const is_entity = body[0] != 0;
    var t: TraderDataToServer = .{ .is_entity = is_entity };
    if (is_entity) {
        if (body.len < 6) return error.EndOfStream;
        t.entity_id = std.mem.readInt(i32, body[1..5], .little);
        t.has_trader_data = body[5] != 0;
        t.trader_data = if (t.has_trader_data) body[6..] else &.{};
    } else {
        if (body.len < 14) return error.EndOfStream;
        t.te_x = std.mem.readInt(i32, body[1..5], .little);
        t.te_y = std.mem.readInt(i32, body[5..9], .little);
        t.te_z = std.mem.readInt(i32, body[9..13], .little);
        t.has_trader_data = body[13] != 0;
        t.trader_data = if (t.has_trader_data) body[14..] else &.{};
    }
    return t;
}

/// Stock NetPackagePickupBlock (RE inventories/netpackage-bodies.md "NetPackagePickupBlock",
/// read asm.il 20: StreamUtils.ReadVector3i | ReadUInt32 rawData | ReadInt32
/// playerId | PlatformUserIdentifierAbs.FromStream(errorOnEmpty=false,
/// inclCustomData=false)). The S2C echo of a pickup carries the same layout
/// with a null identity (Setup(pos, bv, playerId, null), ToStream(null) is a
/// lone 0 byte).
pub const PickupBlock = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// Full BlockValue.rawData the client snapped; type = low 16 bits
    /// (BlockValue.get_type, asm.il BlockValue.rawData layout).
    raw: u32 = 0,
    player_id: i32 = 0,
};

/// Read side of NetPackagePickupBlock (RE inventories/netpackage-bodies.md,
/// read asm.il 20 / write IL=22): `blockPos` (StreamUtils Vector3i) | `rawData`
/// u32 | `playerId` i32 | `persistentPlayerId` (PlatformUserIdentifier, null =
/// one 0 byte). Same order buildPickupBlockBody writes.
///
/// The platform identity is handed back through `sent` rather than dropped
/// because the C2S handler needs it: stock runs both ValidEntityIdForSender on
/// `playerId` and ValidUserIdForSender on the identity, and a parser that
/// consumed the identity silently would leave the second check with nothing to
/// compare (c2s/blocks.zig).
pub fn parsePickupBlockBody(body: []const u8, plat_buf: []u8, id_buf: []u8, sent: *?platform_user.Id) !PickupBlock {
    if (body.len < 16) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    const p: PickupBlock = .{
        .x = try r.readI32(),
        .y = try r.readI32(),
        .z = try r.readI32(),
        .raw = try r.readU32(),
        .player_id = try r.readI32(),
    };
    sent.* = try platform_user.read(&r, plat_buf, id_buf);
    return p;
}

/// NetPackagePickupBlock (RE inventories/netpackage-bodies.md, write IL=22):
/// `blockPos` (StreamUtils Vector3i) | `rawData` u32 | `playerId` i32 |
/// `persistentPlayerId` (PlatformUserIdentifier ToStream; null = one 0 byte,
/// which is what a dedi with no platform identity writes).
pub fn buildPickupBlockBody(buf: []u8, x: i32, y: i32, z: i32, raw: u32, player_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeU32(raw);
    try w.writeI32(player_id);
    try platform_user.write(&w, null);
    return w.written();
}

/// Stock NetPackageItemReload (RE inventories/netpackage-bodies.md "NetPackageItemReload"):
/// a single i32 entityId. Same layout both directions; the dedi relays it to
/// every peer but the sender (GameManager.ItemReloadServer IL=32, flags 192).
pub fn parseItemReload(body: []const u8) !i32 {
    if (body.len < 4) return error.EndOfStream;
    return std.mem.readInt(i32, body[0..4], .little);
}

/// Stock NetPackageSetBlockTexture (RE inventories/netpackage-bodies.md "NetPackageSetBlockTexture",
/// read asm.il 24: StreamUtils.ReadVector3i | u8 face | u8 idx | i32
/// playerIdThatChanged | u8 channel). The dedi rebroadcast sets
/// playerIdThatChanged=-1 (GameManager.SetBlockTextureServer IL=41
/// IL_0018-0027); the face byte stores the BlockTextureData catalog idx raw
/// (Chunk.SetBlockFaceTexture IL=48 masks `_texture & 255` into face*8 bits).
/// chnTextures is a 1-element array (Chunk IL_01F8-01FE: `ldc.i4.1;
/// newarr`), so channel 0 is the only valid one.
pub const SetBlockTexture = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    face: u8 = 0,
    idx: u8 = 0,
    player_id: i32 = 0,
    channel: u8 = 0,
};

/// Read side of NetPackageSetBlockTexture (RE
/// inventories/netpackage-bodies.md, write IL=24): `blockPos` (StreamUtils
/// Vector3i) | `blockFace` u8 | `idx` u8 | `playerIdThatChanged` i32 |
/// `channel` u8, which is the 19-byte minimum checked here.
pub fn parseSetBlockTexture(body: []const u8) !SetBlockTexture {
    if (body.len < 19) return error.EndOfStream;
    var r: binary.Reader = .{ .data = body };
    return .{
        .x = try r.readI32(),
        .y = try r.readI32(),
        .z = try r.readI32(),
        .face = try r.readByte(),
        .idx = try r.readByte(),
        .player_id = try r.readI32(),
        .channel = try r.readByte(),
    };
}

/// NetPackageSetBlockTexture (RE inventories/netpackage-bodies.md, write
/// IL=24): `blockPos` (StreamUtils Vector3i = three i32) | `blockFace` u8 |
/// `idx` u8 | `playerIdThatChanged` i32 | `channel` u8.
pub fn buildSetBlockTextureBody(buf: []u8, t: SetBlockTexture) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(t.x);
    try w.writeI32(t.y);
    try w.writeI32(t.z);
    try w.writeByte(t.face);
    try w.writeByte(t.idx);
    try w.writeI32(t.player_id);
    try w.writeByte(t.channel);
    return w.written();
}


pub const TraderStockEntry = stock_entity.TraderStockEntry;

/// Stock NetPackageTraderData.write (asm.il 839492-839540): the entity id and
/// tePosition are mutually exclusive. Write(bool = entityId != -1); when true it
/// writes ONLY the i32 entityId and branches past the position write. Our near-spawn
/// trader is an EntityTrader, so we always take the entity-id branch. Emitting a
/// tePosition here would desync the client's read and corrupt the TraderData body.
pub fn buildTraderDataStock(
    buf: []u8,
    entity_id: i32,
    trader_id: i32,
    available_money: i32,
    entries: []const TraderStockEntry,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(true); // entityId != -1
    try w.writeI32(entity_id);
    try w.writeBool(true); // has TraderData
    try stock_entity.writeTraderDataBody(&w, .{
        .trader_id = trader_id,
        .available_money = available_money,
        .entries = entries,
    });
    return w.written();
}

test "parsePickupBlockBody reads the stock wrench-pickup layout" {
    // 3x i32 pos | u32 rawData | i32 playerId | null platform identity (1 byte).
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(10);
    try w.writeI32(64);
    try w.writeI32(-3);
    try w.writeU32(0x0004_0023); // type 0x23, meta nibble in bits 22..25
    try w.writeI32(501);
    try platform_user.write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    const body = w.written();
    var plat: [platform_user.max_platform_len]u8 = undefined;
    var id: [platform_user.max_id_len]u8 = undefined;
    var sent: ?platform_user.Id = null;
    const p = try parsePickupBlockBody(body, &plat, &id, &sent);
    try std.testing.expect(sent != null);
    try std.testing.expectEqual(@as(i32, 10), p.x);
    try std.testing.expectEqual(@as(i32, 64), p.y);
    try std.testing.expectEqual(@as(i32, -3), p.z);
    try std.testing.expectEqual(@as(u32, 0x0004_0023), p.raw);
    try std.testing.expectEqual(@as(i32, 501), p.player_id);
    // Truncated before the identity is EndOfStream, never a partial read.
    var cut: usize = 0;
    while (cut < 16) : (cut += 1) {
        var pb: [platform_user.max_platform_len]u8 = undefined;
        var ib: [platform_user.max_id_len]u8 = undefined;
        var sent3: ?platform_user.Id = null;
        try std.testing.expectError(error.EndOfStream, parsePickupBlockBody(body[0..cut], &pb, &ib, &sent3));
    }
}

test "parseSetBlockTexture reads the stock paint body" {
    var buf: [32]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeI32(5);
    try w.writeI32(60);
    try w.writeI32(-8);
    try w.writeByte(3); // face
    try w.writeByte(17); // catalog idx
    try w.writeI32(-1); // dedi rebroadcast playerIdThatChanged
    try w.writeByte(0); // channel
    const t = try parseSetBlockTexture(w.written());
    // Whole position: only x was read back, so y and z could swap unnoticed
    // and paint would land on a different block.
    try std.testing.expectEqual(@as(i32, 5), t.x);
    try std.testing.expectEqual(@as(i32, 60), t.y);
    try std.testing.expectEqual(@as(i32, -8), t.z);
    try std.testing.expectEqual(@as(u8, 3), t.face);
    try std.testing.expectEqual(@as(u8, 17), t.idx);
    try std.testing.expectEqual(@as(i32, -1), t.player_id);
    try std.testing.expectEqual(@as(u8, 0), t.channel);
    // Round-trip: build is the same 19-byte layout.
    var out: [32]u8 = undefined;
    const built = try buildSetBlockTextureBody(&out, t);
    try std.testing.expectEqual(@as(usize, 19), built.len);
    const t2 = try parseSetBlockTexture(built);
    try std.testing.expectEqual(@as(i32, -8), t2.z);
    try std.testing.expectEqual(@as(u8, 17), t2.idx);
    // Raw bytes, not only the round-trip: build and parse can move a field
    // together and still agree with each other, which is what the swap audit
    // reported here after the parse-side assertions were added.
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, built[0..4], .little));
    try std.testing.expectEqual(@as(i32, 60), std.mem.readInt(i32, built[4..8], .little));
    try std.testing.expectEqual(@as(i32, -8), std.mem.readInt(i32, built[8..12], .little));
    try std.testing.expectEqual(@as(u8, 3), built[12]); // face
    try std.testing.expectEqual(@as(u8, 17), built[13]); // idx
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, built[14..18], .little));
    try std.testing.expectEqual(@as(u8, 0), built[18]); // channel
    // Truncated at every boundary is EndOfStream.
    var cut: usize = 0;
    while (cut < 19) : (cut += 1) {
        try std.testing.expectError(error.EndOfStream, parseSetBlockTexture(built[0..cut]));
    }
}

test "parseItemReload reads the single entityId" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i32, buf[0..4], 12345, .little);
    try std.testing.expectEqual(@as(i32, 12345), try parseItemReload(buf[0..4]));
    // Negative ids are legal wire values (the sender's own entity id is
    // always positive; a negative one fails the entity-exists gate).
    std.mem.writeInt(i32, buf[0..4], -1, .little);
    try std.testing.expectEqual(@as(i32, -1), try parseItemReload(buf[0..4]));
    try std.testing.expectError(error.EndOfStream, parseItemReload(buf[0..3]));
    try std.testing.expectError(error.EndOfStream, parseItemReload(&.{}));
}

test "buildPickupBlockBody echoes the S2C pickup with a null identity" {
    var buf: [64]u8 = undefined;
    const out = try buildPickupBlockBody(&buf, 7, 8, 9, 0x1234, 42);
    // Body is 3x4 + 4 + 4 + 1 null-identity byte.
    try std.testing.expectEqual(@as(usize, 21), out.len);
    var plat: [platform_user.max_platform_len]u8 = undefined;
    var id: [platform_user.max_id_len]u8 = undefined;
    var sent2: ?platform_user.Id = null;
    const p = try parsePickupBlockBody(out, &plat, &id, &sent2);
    try std.testing.expect(sent2 == null);
    // Whole position: y and z had nothing reading them back, so a swap in the
    // triple would pick up a different block than the client asked for.
    try std.testing.expectEqual(@as(i32, 7), p.x);
    try std.testing.expectEqual(@as(i32, 8), p.y);
    try std.testing.expectEqual(@as(i32, 9), p.z);
    try std.testing.expectEqual(@as(u32, 0x1234), p.raw);
    try std.testing.expectEqual(@as(i32, 42), p.player_id);
}

test "stock trader data snapshot layout" {
    var buf: [512]u8 = undefined;
    const items = [_]TraderStockEntry{
        .{ .item = .{ .type_id = stock_inv.items_start_here + 2, .count = 5, .quality = 1 }, .markup = 0 },
    };
    const body = try buildTraderDataStock(&buf, 50, 50, 1000, items[0..]);
    // Envelope: entity-id branch only, no tePosition (asm.il 839492-839540).
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(true, try r.readBool()); // entityId != -1
    try std.testing.expectEqual(@as(i32, 50), try r.readI32()); // entityId
    try std.testing.expectEqual(true, try r.readBool()); // hasTraderData
    // TraderData.Write (asm.il 857508-857528)
    try std.testing.expectEqual(@as(i32, 50), try r.readI32()); // TraderID
    try std.testing.expectEqual(@as(u64, 0), try r.readU64()); // lastInventoryUpdate
    try std.testing.expectEqual(@as(u8, 2), try r.readByte()); // FileVersion
    // WriteInventoryData (asm.il 857530-857594)
    try std.testing.expectEqual(@as(i32, 1), try r.readI32()); // PrimaryInventory count
    // Entry.Write (asm.il 856889-856907): ItemStack + i8 markup + bool addedByPlayer.
    const slot = try stock_inv.readItemStack(&r);
    try std.testing.expectEqual(@as(u16, 5), slot.count);
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @bitCast(try r.readByte()))); // Markup
    try std.testing.expectEqual(false, try r.readBool()); // AddedByPlayer
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // TierItemGroups count
    try std.testing.expectEqual(@as(i32, 1000), try r.readI32()); // AvailableMoney
    try std.testing.expectEqual(body.len, r.pos);
}

test "trader data snapshot holds the stock 50-entry window (MaxItems)" {
    var buf: [4096]u8 = undefined;
    var items: [components.max_stock]TraderStockEntry = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .item = .{ .type_id = stock_inv.items_start_here + 2, .count = 5, .quality = 1 } };
        _ = i;
    }
    const body = try buildTraderDataStock(&buf, 50, 50, 1000, items[0..]);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(true, try r.readBool());
    _ = try r.readI32();
    try std.testing.expectEqual(true, try r.readBool());
    _ = try r.readI32();
    _ = try r.readU64();
    _ = try r.readByte();
    try std.testing.expectEqual(@as(i32, components.max_stock), try r.readI32());
    var i: usize = 0;
    while (i < components.max_stock) : (i += 1) {
        const slot = try stock_inv.readItemStack(&r);
        try std.testing.expectEqual(@as(u16, 5), slot.count);
        _ = try r.readByte();
        try std.testing.expectEqual(false, try r.readBool());
    }
    try std.testing.expectEqual(@as(u8, 0), try r.readByte());
    try std.testing.expectEqual(@as(i32, 1000), try r.readI32());
    try std.testing.expectEqual(body.len, r.pos);
}

test "parseTraderDataToServer reads the stock ToServer body" {
    // RE protocol-packages.md 6.23: isEntity bool | entityId i32 (or
    // tePosition 3xi32) | hasTraderData bool | TraderData.Write.
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try w.writeBool(true); // isEntity
    try w.writeI32(1001); // entityId
    try w.writeBool(true); // hasTraderData
    try w.writeI32(3); // TraderData.TraderID
    try w.writeU64(7); // lastInventoryUpdate
    try w.writeByte(0); // trailing u8
    const td = try parseTraderDataToServer(w.written());
    try std.testing.expect(td.is_entity);
    try std.testing.expectEqual(@as(i32, 1001), td.entity_id);
    try std.testing.expect(td.has_trader_data);
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, td.trader_data[0..4], .little));
    // Vending machine branch: isEntity false + tePosition.
    var buf2: [64]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &buf2 };
    try w2.writeBool(false);
    try w2.writeI32(10);
    try w2.writeI32(70);
    try w2.writeI32(20);
    try w2.writeBool(false); // no trader data
    const td2 = try parseTraderDataToServer(w2.written());
    try std.testing.expect(!td2.is_entity);
    try std.testing.expectEqual(@as(i32, 10), td2.te_x);
    try std.testing.expect(!td2.has_trader_data);
}
