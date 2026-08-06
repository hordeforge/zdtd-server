//! Stock V3.1.0 NetPackageTileEntity payload for composite storage (network modes).
//!
//! Outer package (already without PackageId):
//!   handle:u8 | worldPos Vector3i | teBlockId:i32 | payloadLen:i32 | payload
//!   (V3.0.1 was: handle | worldPos | u16 payload_len | payload)
//!
//! Network payload (StreamMode ToClient/FromServer):
//!   TileEntity: chunkPos Vector3i only
//!   Composite: size u32 (marker) | blockId i32 | owner null (u8 0) | moduleCount u8
//!     for each module: nameHash i32 | featureSize u32 | feature body
//!   TEFeatureStorage feature (network):
//!     hasLootList bool | [string] | sizeX u16 | sizeY u16 | touched bool
//!     worldTimeTouched u32 | playerStorage bool | itemCount i16 | ItemStack*n
//!     hasPrefs bool | [prefs] | PackedBoolArray locks (7bit len + bytes)

const std = @import("std");
const binary = @import("binary.zig");
const stock_inv = @import("stock_inv.zig");
const containers = @import("../world/containers.zig");
const workstations = @import("../world/workstations.zig");

// Domain caps/types owned by world/workstations (avoids world → wire cycle).
// Wire uses these names as aliases for TE encode only; world is the owner.
const max_ws_slots: usize = workstations.max_ws_slots;
const max_ws_queue: usize = workstations.max_ws_queue;
const QueueItem = workstations.QueueItem;

/// GetStableHashCode("TEFeatureStorage"): matches Extensions.GetStableHashCode.
pub const feature_hash_storage: i32 = 731446478;

const unity_hash = @import("../assets/unity_hash.zig");

fn localChunkPos(wx: i32, wy: i32, wz: i32) struct { x: i32, y: i32, z: i32 } {
    // stock chunk: 16×256×16; y is full world y in ToWorldPos (chunk Y * 256)
    const lx = @mod(wx, 16);
    const lz = @mod(wz, 16);
    return .{
        .x = if (lx < 0) lx + 16 else lx,
        .y = wy,
        .z = if (lz < 0) lz + 16 else lz,
    };
}

fn writeOuterTeHeader(w: *binary.Writer, handle: u8, world_x: i32, world_y: i32, world_z: i32, te_block_id: i32, pay_len: usize) !void {
    try w.writeByte(handle);
    try w.writeI32(world_x);
    try w.writeI32(world_y);
    try w.writeI32(world_z);
    try w.writeI32(te_block_id);
    try w.writeI32(@intCast(pay_len));
}

fn readOuterTeHeader(r: *binary.Reader, out_handle: *u8, out_x: *i32, out_y: *i32, out_z: *i32, out_block_id: *i32) binary.ReadError!usize {
    out_handle.* = try r.readByte();
    out_x.* = try r.readI32();
    out_y.* = try r.readI32();
    out_z.* = try r.readI32();
    out_block_id.* = try r.readI32();
    const pay_len_i = try r.readI32();
    if (pay_len_i < 0) return error.InvalidString;
    return @intCast(pay_len_i);
}

const Marker = struct {
    pos: usize,
};

fn reserveU32(w: *binary.Writer) !Marker {
    const m = Marker{ .pos = w.pos };
    try w.writeU32(0);
    return m;
}

fn finalizeU32(w: *binary.Writer, m: Marker) void {
    // FinalizeSizeMarker writes (end - markPos) including? Looking at IL:
    // length = currentPos - reservedPos; then seeks to reserved and writes length.
    // The reserved zeros are AT of the span, so length includes the 4 marker bytes.
    const end = w.pos;
    const len: u32 = @intCast(end - m.pos);
    std.mem.writeInt(u32, w.buf[m.pos..][0..4], len, .little);
}

/// Build NetPackageTileEntity body (handle + world pos + composite storage payload).
pub fn buildStorageTeBody(
    buf: []u8,
    handle: u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    block_id: i32,
    cont: *const containers.Container,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    var payload: [4096]u8 = undefined;
    const pay = try writeCompositeStoragePayload(&payload, world_x, world_y, world_z, block_id, cont, resolve, ctx);

    var w: binary.Writer = .{ .buf = buf };
    try writeOuterTeHeader(&w, handle, world_x, world_y, world_z, block_id, pay.len);
    try w.writeBytes(pay);
    return w.written();
}

fn writeCompositeStoragePayload(
    buf: []u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    block_id: i32,
    cont: *const containers.Container,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    const lp = localChunkPos(world_x, world_y, world_z);
    // TileEntity.write network mode: chunkPos only
    try w.writeI32(lp.x);
    try w.writeI32(lp.y);
    try w.writeI32(lp.z);

    // Composite network body
    const outer = try reserveU32(&w);
    try w.writeI32(block_id);
    try w.writeByte(0); // null owner
    try w.writeByte(1); // one module: Storage

    try w.writeI32(feature_hash_storage);
    const feat_mark = try reserveU32(&w);
    try writeStorageFeature(&w, cont, resolve, ctx);
    finalizeU32(&w, feat_mark);

    finalizeU32(&w, outer);
    return w.written();
}

fn writeStorageFeature(
    w: *binary.Writer,
    cont: *const containers.Container,
    resolve: ?stock_inv.TypeResolver,
    ctx: ?*anyopaque,
) !void {
    // network mode: no version u16
    try w.writeBool(false); // no loot list name
    // container size: prefer 2×N or 9×6 for 54
    const n = cont.slot_count;
    const size_x: u16 = if (n > 18) 9 else 2;
    // Ceil: declared grid must hold every stack written below, or the stock
    // client's TEFeatureStorage.read indexes past its container and throws.
    const size_y: u16 = @max(1, (n + size_x - 1) / size_x);
    try w.writeU16(size_x);
    try w.writeU16(size_y);
    try w.writeBool(cont.touched);
    try w.writeU32(0); // worldTimeTouched
    try w.writeBool(cont.player_storage);

    const count: i16 = @intCast(@min(n, containers.max_container_slots));
    try w.writeI16(count);
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const s = cont.slots[i];
        // InvSlot has meta only; seed stays 0 (matches stock_inv.slotFromEcs / wsGroupToStock).
        const stock = if (s.count > 0 and s.item_id != 0)
            stock_inv.StockSlot{
                .type_id = if (resolve) |r| r(ctx, s.item_id) else stock_inv.typeFromBuiltinId(s.item_id),
                .count = s.count,
                .quality = s.quality,
                .meta = s.meta,
            }
        else
            stock_inv.StockSlot{};
        try stock_inv.writeItemStack(w, stock);
    }
    try w.writeBool(false); // no preferences
    // empty locks for count bits
    try w.write7BitEncodedInt(@intCast(count)); // length in bits
    if (count > 0) {
        const zeros: [32]u8 = .{0} ** 32;
        var left = (@as(usize, @intCast(count)) + 7) / 8;
        while (left > 0) {
            const chunk = @min(left, zeros.len);
            try w.writeBytes(zeros[0..chunk]);
            left -= chunk;
        }
    }
}

pub const ParsedTe = struct {
    handle: u8 = 255,
    world_x: i32 = 0,
    world_y: i32 = 0,
    world_z: i32 = 0,
    block_id: i32 = 0,
    items: [containers.max_container_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** containers.max_container_slots,
    item_count: usize = 0,
    size_x: u16 = 0,
    size_y: u16 = 0,
};

/// Parse NetPackageTileEntity body if stock composite+storage; error if ZTE1 or unknown.
pub fn parseStorageTeBody(body: []const u8) binary.ReadError!ParsedTe {
    var r: binary.Reader = .{ .data = body };
    var out: ParsedTe = .{};
    const pay_len = try readOuterTeHeader(&r, &out.handle, &out.world_x, &out.world_y, &out.world_z, &out.block_id);
    if (r.remaining() < pay_len) return error.EndOfStream;
    var pr: binary.Reader = .{ .data = r.data[r.pos .. r.pos + pay_len] };

    // chunkPos
    _ = try pr.readI32();
    _ = try pr.readI32();
    _ = try pr.readI32();

    // outer size marker (we ignore absolute length, stream continues)
    _ = try pr.readU32();
    const payload_block_id = try pr.readI32();
    // Outer teBlockId is authoritative on V3.1.0; payload still carries blockId.
    if (out.block_id == 0) out.block_id = payload_block_id;
    const owner_tag = try pr.readByte();
    if (owner_tag != 0) {
        // skip owner: bool already 1, then another byte + 2 strings in ToStream
        _ = try pr.readByte();
        try pr.skipString();
        try pr.skipString();
    }
    const mod_n = try pr.readByte();
    var mi: u8 = 0;
    while (mi < mod_n) : (mi += 1) {
        const hash = try pr.readI32();
        const feat_size = try pr.readU32();
        // feat_size includes the 4-byte marker itself
        if (feat_size < 4) return error.InvalidString;
        const feat_payload_len = feat_size - 4;
        if (pr.remaining() < feat_payload_len) return error.EndOfStream;
        const feat_start = pr.pos;
        if (hash == feature_hash_storage or hash == unity_hash.getStableHashCode("TEFeatureStorage")) {
            try parseStorageFeature(&pr, &out);
        } else {
            pr.pos += feat_payload_len;
        }
        // ensure we advanced exactly feat_payload_len from marker end
        const consumed = pr.pos - feat_start;
        if (consumed < feat_payload_len) pr.pos = feat_start + feat_payload_len;
        if (consumed > feat_payload_len) return error.InvalidString;
    }
    return out;
}

fn parseStorageFeature(r: *binary.Reader, out: *ParsedTe) binary.ReadError!void {
    const has_list = try r.readBool();
    if (has_list) try r.skipString();
    out.size_x = try r.readU16();
    out.size_y = try r.readU16();
    _ = try r.readBool(); // touched
    _ = try r.readU32(); // worldTime
    _ = try r.readBool(); // player storage
    const count_i = try r.readI16();
    const count: usize = if (count_i > 0) @intCast(count_i) else 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const s = try stock_inv.readItemStack(r);
        if (i < out.items.len) {
            out.items[i] = s;
            out.item_count += 1;
        }
    }
    const has_prefs = try r.readBool();
    if (has_prefs) {
        // cannot fully skip PreferenceTracker without format; stop
        return;
    }
    // locks
    const bit_len = try binary.read7BitEncodedInt(r);
    if (bit_len > 0) {
        const nbytes = (@as(usize, bit_len) + 7) / 8;
        if (r.remaining() < nbytes) return error.EndOfStream;
        r.pos += nbytes;
    }
}

/// Apply parsed items into container store entry.
pub fn applyParsedToContainer(
    parsed: *const ParsedTe,
    cont: *containers.Container,
    reverse: ?stock_inv.ReverseResolver,
    ctx: ?*anyopaque,
) void {
    const n = if (parsed.size_x > 0 and parsed.size_y > 0)
        @min(@as(usize, parsed.size_x) * @as(usize, parsed.size_y), containers.max_container_slots)
    else
        @min(parsed.item_count, containers.max_container_slots);
    // Geometry only grows: a client-declared smaller grid must not make the
    // container's tail slots unaddressable (and drop them from the save).
    cont.slot_count = @intCast(@max(@as(usize, cont.slot_count), n));
    cont.block_id = parsed.block_id;
    cont.clear();
    var i: usize = 0;
    while (i < parsed.item_count and i < cont.slot_count) : (i += 1) {
        const s = parsed.items[i];
        if (s.type_id == 0 or s.count == 0) continue;
        const item_id: u16 = if (reverse) |rv| rv(ctx, s.type_id) else blk: {
            if (s.type_id > stock_inv.items_start_here) {
                const rel = s.type_id - stock_inv.items_start_here;
                if (rel > 0 and rel < 100) break :blk @as(u16, @intCast(rel));
            }
            break :blk 0;
        };
        if (item_id == 0) continue;
        cont.setSlot(i, .{
            .item_id = item_id,
            .count = s.count,
            .quality = @min(s.quality, 255),
            .meta = s.meta,
        });
    }
}

// --- TileEntityWorkstation (TileEntityType.Workstation = 12, classic TE) ---
// Network body after handle|worldPos|u16 len:
//   TileEntity.write network: chunkPos Vector3i
//   version u8 (client V3.1.4 writes 50)
//   fuel/input/tools/output: u8 count + ItemStack.Write * n
//   queue: u8 count + RecipeQueueItem.Write * n
//   craftComplete: i16 count + CraftCompleteData * n (we send 0)
//   isBurning bool | currentBurnTimeLeft f32 | meltCount u8 + f32*n
//   isPlayerPlaced bool | lastTickTime-delta u64 (network read adds GameTimer)

pub const workstation_te_version: u8 = 50;

pub const WorkstationSlots = struct {
    fuel: []const stock_inv.StockSlot = &.{},
    input: []const stock_inv.StockSlot = &.{},
    tools: []const stock_inv.StockSlot = &.{},
    output: []const stock_inv.StockSlot = &.{},
    queue: []const QueueItem = &.{},
    is_burning: bool = false,
    burn_time_left: f32 = 0,
    is_player_placed: bool = true,
};

fn writeWsStackArray(w: *binary.Writer, slots: []const stock_inv.StockSlot) !void {
    const n = @min(slots.len, 255);
    try w.writeByte(@intCast(n));
    for (slots[0..n]) |s| try stock_inv.writeItemStack(w, s);
}

/// RecipeQueueItem.Write without a Recipe blob (server-side queue echo keeps
/// timing fields; client resolves recipe locally from its own queue UI).
fn writeQueueItem(w: *binary.Writer, q: QueueItem) !void {
    try w.writeU16(2);
    try w.writeI16(q.multiplier);
    try w.writeBool(q.is_crafting);
    try w.writeF32(q.craft_time_left);
    try w.writeBool(false); // no repair item
    try w.writeByte(0); // quality
    try w.writeI32(-1); // startingEntityId
    try w.writeF32(q.one_item_craft_time);
    try w.writeBool(false); // recipe omitted on echo
}

/// Build NetPackageTileEntity body for a workstation (queue emitted from live state,
/// capped at 255 items).
pub fn buildWorkstationTeBody(
    buf: []u8,
    handle: u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    te_block_id: i32,
    ws: WorkstationSlots,
) ![]u8 {
    var payload: [4096]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &payload };
    const lp = localChunkPos(world_x, world_y, world_z);
    try pw.writeI32(lp.x);
    try pw.writeI32(lp.y);
    try pw.writeI32(lp.z);
    try pw.writeByte(workstation_te_version);
    try writeWsStackArray(&pw, ws.fuel);
    try writeWsStackArray(&pw, ws.input);
    try writeWsStackArray(&pw, ws.tools);
    try writeWsStackArray(&pw, ws.output);
    try pw.writeByte(@intCast(@min(ws.queue.len, 255)));
    for (ws.queue) |q| try writeQueueItem(&pw, q);
    try pw.writeI16(0); // craftComplete count
    try pw.writeBool(ws.is_burning);
    try pw.writeF32(ws.burn_time_left);
    try pw.writeByte(0); // meltTimes count
    try pw.writeBool(ws.is_player_placed);
    try pw.writeU64(0); // lastTickTime delta
    const pay = pw.written();

    var w: binary.Writer = .{ .buf = buf };
    try writeOuterTeHeader(&w, handle, world_x, world_y, world_z, te_block_id, pay.len);
    try w.writeBytes(pay);
    return w.written();
}

pub const ParsedWorkstation = struct {
    handle: u8 = 255,
    world_x: i32 = 0,
    world_y: i32 = 0,
    world_z: i32 = 0,
    block_id: i32 = 0,
    fuel: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    fuel_n: usize = 0,
    input: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    input_n: usize = 0,
    tools: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    tools_n: usize = 0,
    output: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    output_n: usize = 0,
    queue: [max_ws_queue]QueueItem = [_]QueueItem{.{}} ** max_ws_queue,
    queue_n: usize = 0,
    is_burning: bool = false,
    burn_time_left: f32 = 0,
};

fn readWsStackArray(r: *binary.Reader, out: []stock_inv.StockSlot, out_n: *usize) binary.ReadError!void {
    const n = try r.readByte();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = try stock_inv.readItemStack(r);
        if (i < out.len) {
            out[i] = s;
            out_n.* = i + 1;
        }
    }
}

/// Recipe.Read (IL): ver u16 | itemValueType i32 | count i32 | isScrap bool |
/// craftingTime f32 | craftExpGain i32 | craftingArea string | i32 n + ItemStack*n.
fn readRecipe(r: *binary.Reader, out: *QueueItem) binary.ReadError!void {
    _ = try r.readU16(); // version (client pops it unread)
    out.output_type = try r.readI32();
    out.output_count = try r.readI32();
    _ = try r.readBool(); // isScrap
    out.crafting_time = try r.readF32();
    _ = try r.readI32(); // craftExpGain
    try r.skipString(); // craftingArea
    const n = try r.readI32();
    if (n < 0 or n > 64) return error.InvalidString;
    var i: i32 = 0;
    while (i < n) : (i += 1) _ = try stock_inv.readItemStack(r);
}

fn readQueueItem(r: *binary.Reader) binary.ReadError!QueueItem {
    var out: QueueItem = .{};
    const ver = try r.readU16();
    if (ver != 2) return error.InvalidString;
    out.multiplier = try r.readI16();
    out.is_crafting = try r.readBool();
    out.craft_time_left = try r.readF32();
    const has_repair = try r.readBool();
    if (has_repair) {
        _ = try stock_inv.readItemValue(r);
        _ = try r.readU16();
    }
    _ = try r.readByte(); // quality
    _ = try r.readI32(); // startingEntityId
    out.one_item_craft_time = try r.readF32();
    const has_recipe = try r.readBool();
    if (has_recipe) try readRecipe(r, &out);
    return out;
}

/// Parse C2S workstation TE write (network mode), including queue entries with
/// Recipe blobs (output type/count/time captured; ingredients skipped).
pub fn parseWorkstationTeBody(body: []const u8) binary.ReadError!ParsedWorkstation {
    var r: binary.Reader = .{ .data = body };
    var out: ParsedWorkstation = .{};
    const pay_len = try readOuterTeHeader(&r, &out.handle, &out.world_x, &out.world_y, &out.world_z, &out.block_id);
    if (r.remaining() < pay_len) return error.EndOfStream;
    var pr: binary.Reader = .{ .data = r.data[r.pos .. r.pos + pay_len] };
    _ = try pr.readI32();
    _ = try pr.readI32();
    _ = try pr.readI32(); // chunkPos
    const ver = try pr.readByte();
    if (ver != workstation_te_version) return error.InvalidString;
    try readWsStackArray(&pr, out.fuel[0..], &out.fuel_n);
    try readWsStackArray(&pr, out.input[0..], &out.input_n);
    try readWsStackArray(&pr, out.tools[0..], &out.tools_n);
    try readWsStackArray(&pr, out.output[0..], &out.output_n);
    const qn = try pr.readByte();
    var qi: u8 = 0;
    while (qi < qn) : (qi += 1) {
        const item = try readQueueItem(&pr);
        if (qi < out.queue.len) {
            out.queue[qi] = item;
            out.queue_n = qi + 1;
        }
    }
    const ccn = try pr.readI16();
    if (ccn != 0) return error.InvalidString; // CraftCompleteData unparsed
    out.is_burning = try pr.readBool();
    out.burn_time_left = try pr.readF32();
    const mn = try pr.readByte();
    var mi2: u8 = 0;
    while (mi2 < mn) : (mi2 += 1) _ = try pr.readF32();
    return out;
}

test "workstation queue item with recipe parses" {
    var qb: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &qb };
    try w.writeU16(2);
    try w.writeI16(3); // multiplier
    try w.writeBool(true);
    try w.writeF32(4.5);
    try w.writeBool(false); // no repair
    try w.writeByte(0);
    try w.writeI32(107);
    try w.writeF32(1.5);
    try w.writeBool(true); // recipe
    try w.writeU16(1); // recipe version
    try w.writeI32(stock_inv.items_start_here + 9); // output type
    try w.writeI32(2); // output count
    try w.writeBool(false); // isScrap
    try w.writeF32(1.5); // craftingTime
    try w.writeI32(5); // exp
    try w.writeString("forge");
    try w.writeI32(1); // one ingredient
    try stock_inv.writeItemStack(&w, .{ .type_id = stock_inv.items_start_here + 4, .count = 6 });
    var r: binary.Reader = .{ .data = w.written() };
    const q = try readQueueItem(&r);
    try std.testing.expectEqual(@as(i16, 3), q.multiplier);
    try std.testing.expect(q.is_crafting);
    try std.testing.expectEqual(stock_inv.items_start_here + 9, q.output_type);
    try std.testing.expectEqual(@as(i32, 2), q.output_count);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), q.crafting_time, 0.01);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "workstation te body roundtrip" {
    var buf: [1024]u8 = undefined;
    const fuel = [_]stock_inv.StockSlot{
        .{ .type_id = stock_inv.items_start_here + 3, .count = 5, .quality = 0 },
    };
    const input = [_]stock_inv.StockSlot{
        .{ .type_id = stock_inv.items_start_here + 7, .count = 12, .quality = 0 },
    };
    const body = try buildWorkstationTeBody(&buf, 255, 10, 70, 20, 0, .{
        .fuel = fuel[0..],
        .input = input[0..],
        .is_burning = true,
        .burn_time_left = 12.5,
    });
    const p = try parseWorkstationTeBody(body);
    try std.testing.expectEqual(@as(i32, 10), p.world_x);
    try std.testing.expectEqual(@as(usize, 1), p.fuel_n);
    try std.testing.expectEqual(@as(u16, 5), p.fuel[0].count);
    try std.testing.expectEqual(@as(usize, 1), p.input_n);
    try std.testing.expectEqual(@as(u16, 12), p.input[0].count);
    try std.testing.expect(p.is_burning);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), p.burn_time_left, 0.01);
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
    const body = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null);
    const parsed = try parseStorageTeBody(body);
    try std.testing.expectEqual(@as(i32, 10), parsed.world_x);
    try std.testing.expectEqual(@as(i32, 500), parsed.block_id);
    try std.testing.expect(parsed.item_count >= 3);
    try std.testing.expectEqual(@as(u16, 12), parsed.items[0].count);
    try std.testing.expectEqual(@as(i32, stock_inv.items_start_here + 7), parsed.items[0].type_id);
}

/// TileEntityPoweredTrigger network payload (TileEntityType.Trigger = 19).
///
/// TileEntity::write network modes emit chunkPos only; the u16 version and
/// heapMapUpdateTime are Persistency-only (asm.il:1312529). TileEntityPowered
/// then writes i32 const 1 | bool isPlayerPlaced | u8 PowerItemType | u8 wireCount
/// | wireCount x Vector3i | Vector3i parentPos | [ToClient] bool IsPowered |
/// f32 CenteredPitch | f32 CenteredYaw (asm.il:1322177). TileEntityPoweredTrigger
/// appends u8 TriggerType, then PlatformUserIdentifierAbs ownerID when the type is
/// Motion, then the per-direction tail (asm.il:1326015 write / 1325813 read):
///
///   ToServer  (client -> server, read as FromClient): non-Switch types write
///     Property1 u8, Property2 u8, ResetTrigger bool; Motion appends i32 TargetType.
///   ToClient  (server -> client, read as FromServer): TripWire writes a bool
///     "parent is a TripWireRelay" first; TimerRelay writes StartTime/EndTime,
///     any other non-Switch type writes TriggerPowerDelay/TriggerPowerDuration;
///     Motion appends i32 TargetType.
///
/// Property1/Property2 are TimerRelay StartTime/EndTime for TriggerType 2 and
/// TriggerPowerDelay/TriggerPowerDuration otherwise (asm.il:1326249, 1326317).
/// Stock reads only two bytes for a TimerRelay where the client wrote three, so a
/// trailing byte is normal and must not fail the parse.
pub const trigger_type_switch: u8 = 0;
pub const trigger_type_timer_relay: u8 = 2;
pub const trigger_type_motion: u8 = 3;
pub const trigger_type_trip_wire: u8 = 4;
pub const max_te_wires: usize = 8;

pub const Vec3i = struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };

pub const PoweredTriggerTe = struct {
    handle: u8 = 255,
    world_x: i32 = 0,
    world_y: i32 = 0,
    world_z: i32 = 0,
    block_id: i32 = 0,
    is_player_placed: bool = false,
    power_item_type: u8 = 0,
    /// Wires kept up to max_te_wires; wire_total is what the sender declared.
    wires: [max_te_wires]Vec3i = [_]Vec3i{.{}} ** max_te_wires,
    wire_n: usize = 0,
    wire_total: u8 = 0,
    parent: Vec3i = .{},
    pitch: f32 = 0,
    yaw: f32 = 0,
    trigger_type: u8 = trigger_type_switch,
    /// TimerRelay StartTime, else TriggerPowerDelay index.
    property1: u8 = 0,
    /// TimerRelay EndTime, else TriggerPowerDuration index.
    property2: u8 = 0,
    reset_trigger: bool = false,
    target_type: i32 = 0,
};

/// Server-side view of a powered trigger, for the ToClient echo.
pub const PoweredTriggerState = struct {
    is_player_placed: bool = true,
    power_item_type: u8 = 0,
    wires: []const Vec3i = &.{},
    parent: Vec3i = .{},
    pitch: f32 = 0,
    yaw: f32 = 0,
    is_powered: bool = false,
    trigger_type: u8 = trigger_type_switch,
    property1: u8 = 0,
    property2: u8 = 0,
    /// TripWire only: whether the parent PowerItem is another TripWireRelay.
    tripwire_parent: bool = false,
    target_type: i32 = 0,
};

fn readVec3i(r: *binary.Reader) binary.ReadError!Vec3i {
    return .{ .x = try r.readI32(), .y = try r.readI32(), .z = try r.readI32() };
}

fn writeVec3i(w: *binary.Writer, v: Vec3i) !void {
    try w.writeI32(v.x);
    try w.writeI32(v.y);
    try w.writeI32(v.z);
}

/// PlatformUserIdentifierAbs::FromStream (asm.il:30604): a false bool is the whole
/// value; otherwise a platform byte and two length-prefixed strings follow.
fn skipPlatformUser(r: *binary.Reader) binary.ReadError!void {
    if (!try r.readBool()) return;
    _ = try r.readByte();
    try r.skipString();
    try r.skipString();
}

/// Parse a C2S NetPackageTileEntity body as TileEntityPoweredTrigger, i.e.
/// TileEntity/StreamModeRead.FromClient (2). Untrusted input: every field is
/// bounded by the declared payload length and a short body is an error.
pub fn parsePoweredTriggerTeBody(body: []const u8) binary.ReadError!PoweredTriggerTe {
    var r: binary.Reader = .{ .data = body };
    var out: PoweredTriggerTe = .{};
    const pay_len = try readOuterTeHeader(&r, &out.handle, &out.world_x, &out.world_y, &out.world_z, &out.block_id);
    if (r.remaining() < pay_len) return error.EndOfStream;
    var pr: binary.Reader = .{ .data = r.data[r.pos .. r.pos + pay_len] };

    // TileEntity::write network mode: chunkPos only.
    _ = try pr.readI32();
    _ = try pr.readI32();
    _ = try pr.readI32();
    // TileEntityPowered: the leading i32 is a constant 1 on the wire, and the
    // reader only uses it as "pitch/yaw follow" (asm.il:1322032 IL_0089).
    const has_orientation = try pr.readI32();
    out.is_player_placed = try pr.readBool();
    out.power_item_type = try pr.readByte();
    out.wire_total = try pr.readByte();
    // A wire list must fit the payload: 12 bytes each, and the trailing
    // parentPos still has to be there.
    if (pr.remaining() < @as(usize, out.wire_total) * 12 + 12) return error.EndOfStream;
    var i: usize = 0;
    while (i < out.wire_total) : (i += 1) {
        const v = try readVec3i(&pr);
        if (i < out.wires.len) {
            out.wires[i] = v;
            out.wire_n = i + 1;
        }
    }
    out.parent = try readVec3i(&pr);
    // IsPowered is ToClient-only; FromClient goes straight to pitch/yaw.
    if (has_orientation > 0) {
        out.pitch = try pr.readF32();
        out.yaw = try pr.readF32();
    }
    out.trigger_type = try pr.readByte();
    if (out.trigger_type == trigger_type_motion) try skipPlatformUser(&pr);
    if (out.trigger_type == trigger_type_timer_relay) {
        out.property1 = try pr.readByte(); // StartTime
        out.property2 = try pr.readByte(); // EndTime
    } else if (out.trigger_type != trigger_type_switch) {
        out.property1 = try pr.readByte(); // TriggerPowerDelay
        out.property2 = try pr.readByte(); // TriggerPowerDuration
        out.reset_trigger = try pr.readBool();
    }
    if (out.trigger_type == trigger_type_motion) out.target_type = try pr.readI32();
    return out;
}

/// Build the authoritative S2C body for a powered trigger, i.e.
/// TileEntity/StreamModeWrite.ToClient (2).
pub fn buildPoweredTriggerTeBody(
    buf: []u8,
    handle: u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    te_block_id: i32,
    st: PoweredTriggerState,
) ![]u8 {
    var payload: [1024]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &payload };
    const lp = localChunkPos(world_x, world_y, world_z);
    try pw.writeI32(lp.x);
    try pw.writeI32(lp.y);
    try pw.writeI32(lp.z);
    try pw.writeI32(1); // TileEntityPowered writes this constant
    try pw.writeBool(st.is_player_placed);
    try pw.writeByte(st.power_item_type);
    const wire_n = @min(st.wires.len, 255);
    try pw.writeByte(@intCast(wire_n));
    for (st.wires[0..wire_n]) |v| try writeVec3i(&pw, v);
    try writeVec3i(&pw, st.parent);
    try pw.writeBool(st.is_powered);
    try pw.writeF32(st.pitch);
    try pw.writeF32(st.yaw);
    try pw.writeByte(st.trigger_type);
    // Motion carries an ownerID; a null PlatformUserIdentifierAbs is one 0 byte.
    if (st.trigger_type == trigger_type_motion) try pw.writeBool(false);
    if (st.trigger_type == trigger_type_trip_wire) try pw.writeBool(st.tripwire_parent);
    if (st.trigger_type != trigger_type_switch) {
        try pw.writeByte(st.property1);
        try pw.writeByte(st.property2);
    }
    if (st.trigger_type == trigger_type_motion) try pw.writeI32(st.target_type);
    const pay = pw.written();

    var w: binary.Writer = .{ .buf = buf };
    try writeOuterTeHeader(&w, handle, world_x, world_y, world_z, te_block_id, pay.len);
    try w.writeBytes(pay);
    return w.written();
}

/// Encode a C2S powered-trigger body (StreamModeWrite.ToServer = 1). Tests and the
/// fuzz corpus need the client half of the exchange; the server never sends it.
fn buildPoweredTriggerTeBodyToServer(
    buf: []u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    te_block_id: i32,
    te: PoweredTriggerTe,
) ![]u8 {
    var payload: [1024]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &payload };
    const lp = localChunkPos(world_x, world_y, world_z);
    try pw.writeI32(lp.x);
    try pw.writeI32(lp.y);
    try pw.writeI32(lp.z);
    try pw.writeI32(1);
    try pw.writeBool(te.is_player_placed);
    try pw.writeByte(te.power_item_type);
    try pw.writeByte(@intCast(te.wire_n));
    for (te.wires[0..te.wire_n]) |v| try writeVec3i(&pw, v);
    try writeVec3i(&pw, te.parent);
    try pw.writeF32(te.pitch);
    try pw.writeF32(te.yaw);
    try pw.writeByte(te.trigger_type);
    if (te.trigger_type == trigger_type_motion) try pw.writeBool(false);
    if (te.trigger_type != trigger_type_switch) {
        try pw.writeByte(te.property1);
        try pw.writeByte(te.property2);
        try pw.writeBool(te.reset_trigger);
    }
    if (te.trigger_type == trigger_type_motion) try pw.writeI32(te.target_type);
    const pay = pw.written();

    var w: binary.Writer = .{ .buf = buf };
    try writeOuterTeHeader(&w, te.handle, world_x, world_y, world_z, te_block_id, pay.len);
    try w.writeBytes(pay);
    return w.written();
}

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
        src.wires[0] = .{ .x = 4, .y = 71, .z = 5 };
        src.wire_n = 1;
        const body = try buildPoweredTriggerTeBodyToServer(&buf, 10, 70, -3, 19300, src);
        const p = try parsePoweredTriggerTeBody(body);
        try std.testing.expectEqual(@as(u8, 3), p.handle);
        try std.testing.expectEqual(@as(i32, 10), p.world_x);
        try std.testing.expectEqual(@as(i32, 19300), p.block_id);
        try std.testing.expect(p.is_player_placed);
        try std.testing.expectEqual(@as(u8, 3), p.power_item_type);
        try std.testing.expectEqual(@as(usize, 1), p.wire_n);
        try std.testing.expectEqual(@as(i32, 71), p.wires[0].y);
        try std.testing.expectEqual(@as(i32, 70), p.parent.y);
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
