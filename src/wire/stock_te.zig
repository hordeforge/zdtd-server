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
const stock_entity = @import("stock_entity.zig");
const platform_user = @import("platform_user.zig");
const containers = @import("../world/containers.zig");
const workstations = @import("../world/workstations.zig");

// Domain caps/types owned by world/workstations (avoids world → wire cycle).
// Wire uses these names as aliases for TE encode only; world is the owner.
const max_ws_slots: usize = workstations.max_ws_slots;
const max_ws_queue: usize = workstations.max_ws_queue;
const max_ws_melt: usize = workstations.max_ws_melt;
const max_craft_complete: usize = workstations.max_craft_complete;
const last_input_blob_max: usize = workstations.last_input_blob_max;
const QueueItem = workstations.QueueItem;
const CraftComplete = workstations.CraftComplete;

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
    // container size: the observed grid (loot.xml LootContainer size_x/size_y
    // stored on the container at lock time) wins; otherwise synthesize 2xN or
    // 9x6 for 54. The declared grid must hold every stack written below, or
    // the stock client's TEFeatureStorage.read indexes past its container and
    // throws.
    const n = cont.slot_count;
    const has_real = cont.size_x > 0 and @as(usize, cont.size_x) * @as(usize, cont.size_y) >= n;
    const size_x: u16 = if (has_real) cont.size_x else if (n > 18) 9 else 2;
    // Ceil: declared grid must hold every stack written below, or the stock
    // client's TEFeatureStorage.read indexes past its container and throws.
    const size_y: u16 = if (has_real) cont.size_y else @max(1, (n + size_x - 1) / size_x);
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

    // Outer size marker: FinalizeSizeMarker writes the span from the marker to
    // the composite's end, so it can never reach past the payload. Checking it
    // is what keeps a non-composite TE body (a workstation write, whose version
    // byte lands where the marker starts) from being mistaken for storage.
    const outer_size = try pr.readU32();
    if (outer_size < 4 or outer_size - 4 > pr.remaining()) return error.InvalidString;
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
// Network body after handle|worldPos|teBlockId|payloadLen. StreamModeWrite
// ToServer (1) and ToClient (2) are byte-identical (TileEntityWorkstation::write
// asm.il ~1332990, IL_00cc and IL_018d):
//   TileEntity.write network: chunkPos Vector3i
//   version u8 (client V3.1.0 writes 50)
//   fuel | input | tools | output: u8 count + ItemStack.Write * count
//   queue: u8 count + RecipeQueueItem.Write * count
//   craftComplete: i16 count + CraftCompleteData.Write * count
//   isBurning bool | currentBurnTimeLeft f32 | meltCount u8 + f32 * count
//   isPlayerPlaced bool | (GameTimer.ticks - lastTickTime) u64
//   lastInput: u8 count + ItemStack.Write * count
//
// Every count is the peer's array *length*, never a used prefix: both
// readItemStackArray (asm.il ~1333365, IL_0012) and readRecipeStackArray
// (asm.il ~1333602, IL_0012) reallocate the target array to the received count
// before the discard gate, so a short count permanently shrinks the client's
// grid. currentMeltTimesLeft is indexed directly at the received count
// (TileEntityWorkstation::read asm.il ~1332790, IL_016e) with no bounds check.

/// Stock TileEntityWorkstation save/wire version 50 (RE: protocol-packages.md §6.12 TE payload).
pub const workstation_te_version: u8 = 50;
/// RecipeQueueItem.Version (asm.il ~272640).
const recipe_queue_item_version: u16 = 2;
/// CraftCompleteData.Version (asm.il ~272468).
const craft_complete_version: u16 = 1;
/// Recipe.ingredients is an unbounded i32 count on the wire.
const max_recipe_ingredients: i32 = 64;
/// Longest string we will pull off the wire before rejecting the write.
const wire_name_max: usize = 256;

/// One workstation's arrays as they must appear on the wire. Every slice length
/// is emitted verbatim, so callers pass the full stock array, not a used prefix.
pub const WorkstationSlots = struct {
    fuel: []const stock_inv.StockSlot = &.{},
    input: []const stock_inv.StockSlot = &.{},
    tools: []const stock_inv.StockSlot = &.{},
    output: []const stock_inv.StockSlot = &.{},
    /// lastInput passes through untouched: the server never reads it, and the
    /// client uses it only to reset melt timers. `last_input_count` is the array
    /// length; `last_input` the ItemStack.Write bytes for exactly that many.
    last_input_count: u8 = 0,
    last_input: []const u8 = &.{},
    queue: []const QueueItem = &.{},
    craft_complete: []const CraftComplete = &.{},
    melt: []const f32 = &.{},
    is_burning: bool = false,
    burn_time_left: f32 = 0,
    is_player_placed: bool = true,
};

fn writeWsStackArray(w: *binary.Writer, slots: []const stock_inv.StockSlot) !void {
    if (slots.len > 255) return error.Overflow;
    try w.writeByte(@intCast(slots.len));
    for (slots) |s| try stock_inv.writeItemStack(w, s);
}

/// RecipeQueueItem.Write (asm.il ~272652). The recipe rides along as the blob the
/// client sent: `Read` leaves the receiver's Recipe untouched when hasRecipe is
/// false (asm.il ~272880, IL_0084), which only preserves a recipe that peer
/// already had, and `HandleRecipeQueue` dereferences it (asm.il ~1331756).
fn writeQueueItem(w: *binary.Writer, q: QueueItem) !void {
    try w.writeU16(recipe_queue_item_version);
    try w.writeI16(q.multiplier);
    try w.writeBool(q.is_crafting);
    try w.writeF32(q.craft_time_left);
    try w.writeBool(false); // RepairItem null
    try w.writeByte(q.quality);
    try w.writeI32(q.starting_entity_id);
    try w.writeF32(q.one_item_craft_time);
    const blob = q.recipeBlob();
    try w.writeBool(blob.len != 0);
    try w.writeBytes(blob);
}

/// CraftCompleteData.Write (asm.il ~272530).
fn writeCraftComplete(w: *binary.Writer, cc: CraftComplete) !void {
    try w.writeU16(craft_complete_version);
    try w.writeI32(cc.crafter_entity_id);
    try stock_inv.writeItemStack(w, .{ .type_id = cc.item_type, .count = cc.item_count });
    try w.writeString(cc.recipeName());
    try w.writeI32(cc.exp_gain);
    // GiveExp divides by (craftCount + RecipeUsedCount) (asm.il ~528534).
    try w.writeU16(@max(cc.used_count, 1));
    try w.writeString(cc.scrappedName());
}

/// Build NetPackageTileEntity body for a workstation.
pub fn buildWorkstationTeBody(
    buf: []u8,
    handle: u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    te_block_id: i32,
    ws: WorkstationSlots,
) ![]u8 {
    var payload: [6144]u8 = undefined;
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
    if (ws.queue.len > 255 or ws.craft_complete.len > std.math.maxInt(i16)) return error.Overflow;
    try pw.writeByte(@intCast(ws.queue.len));
    for (ws.queue) |q| try writeQueueItem(&pw, q);
    try pw.writeI16(@intCast(ws.craft_complete.len));
    for (ws.craft_complete) |cc| try writeCraftComplete(&pw, cc);
    try pw.writeBool(ws.is_burning);
    try pw.writeF32(ws.burn_time_left);
    if (ws.melt.len > 255) return error.Overflow;
    try pw.writeByte(@intCast(ws.melt.len));
    for (ws.melt) |m| try pw.writeF32(m);
    try pw.writeBool(ws.is_player_placed);
    // lastTickTime delta: the receiver stores GameTimer.ticks - delta, so 0 means
    // "ticked just now" and no catch-up runs on arrival.
    try pw.writeU64(0);
    try pw.writeByte(ws.last_input_count);
    try pw.writeBytes(ws.last_input);
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
    fuel_n: u8 = 0,
    input: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    input_n: u8 = 0,
    tools: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    tools_n: u8 = 0,
    output: [max_ws_slots]stock_inv.StockSlot = [_]stock_inv.StockSlot{.{}} ** max_ws_slots,
    output_n: u8 = 0,
    last_input: [last_input_blob_max]u8 = [_]u8{0} ** last_input_blob_max,
    last_input_blob_len: u16 = 0,
    last_input_n: u8 = 0,
    queue: [max_ws_queue]QueueItem = [_]QueueItem{.{}} ** max_ws_queue,
    queue_n: u8 = 0,
    craft_complete: [max_craft_complete]CraftComplete = [_]CraftComplete{.{}} ** max_craft_complete,
    craft_complete_n: u8 = 0,
    melt: [max_ws_melt]f32 = [_]f32{0} ** max_ws_melt,
    melt_n: u8 = 0,
    is_burning: bool = false,
    burn_time_left: f32 = 0,
    is_player_placed: bool = true,
};

/// A count wider than our array cannot be echoed back at the same length, and a
/// short echo would resize the client's grid, so it is rejected outright.
fn readWsStackArray(r: *binary.Reader, out: []stock_inv.StockSlot, out_n: *u8) binary.ReadError!void {
    const n = try r.readByte();
    if (n > out.len) return error.InvalidString;
    for (out[0..n]) |*s| s.* = try stock_inv.readItemStack(r);
    out_n.* = n;
}

/// lastInput: validate every stack parses, then keep the raw bytes for the echo.
fn readWsStackBlob(r: *binary.Reader, out: *ParsedWorkstation) binary.ReadError!void {
    const n = try r.readByte();
    if (n > max_ws_slots) return error.InvalidString;
    const start = r.pos;
    var i: u8 = 0;
    while (i < n) : (i += 1) _ = try stock_inv.readItemStack(r);
    const blob = r.data[start..r.pos];
    if (blob.len > out.last_input.len) return error.InvalidString;
    @memcpy(out.last_input[0..blob.len], blob);
    out.last_input_blob_len = @intCast(blob.len);
    out.last_input_n = n;
}

/// Recipe.Read (asm.il ~274879): ver u16 | itemValueType i32 | count i32 |
/// isScrap bool | craftingTime f32 | craftExpGain i32 | craftingArea string |
/// i32 n + ItemStack * n. Captured verbatim so the echo can re-emit it.
fn readRecipe(r: *binary.Reader, out: *QueueItem) binary.ReadError!void {
    const start = r.pos;
    _ = try r.readU16(); // version (client pops it unread)
    out.output_type = try r.readI32();
    out.output_count = try r.readI32();
    _ = try r.readBool(); // isScrap
    out.crafting_time = try r.readF32();
    out.craft_exp_gain = try r.readI32();
    try r.skipString(); // craftingArea
    const n = try r.readI32();
    if (n < 0 or n > max_recipe_ingredients) return error.InvalidString;
    var i: i32 = 0;
    while (i < n) : (i += 1) _ = try stock_inv.readItemStack(r);
    out.setRecipeBlob(r.data[start..r.pos]);
}

fn readQueueItem(r: *binary.Reader) binary.ReadError!QueueItem {
    var out: QueueItem = .{};
    const ver = try r.readU16();
    if (ver != recipe_queue_item_version) return error.InvalidString;
    out.multiplier = try r.readI16();
    out.is_crafting = try r.readBool();
    out.craft_time_left = try r.readF32();
    const has_repair = try r.readBool();
    if (has_repair) {
        _ = try stock_inv.readItemValue(r);
        _ = try r.readU16();
    }
    out.quality = try r.readByte();
    out.starting_entity_id = try r.readI32();
    out.one_item_craft_time = try r.readF32();
    const has_recipe = try r.readBool();
    if (has_recipe) try readRecipe(r, &out);
    return out;
}

/// CraftCompleteData.Read (asm.il ~272566). The client sends back the entries its
/// CheckForCraftComplete has not consumed, so this is the acknowledgement path.
fn readCraftComplete(r: *binary.Reader) binary.ReadError!CraftComplete {
    var out: CraftComplete = .{};
    var name: [wire_name_max]u8 = undefined;
    const ver = try r.readU16();
    if (ver != craft_complete_version) return error.InvalidString;
    out.crafter_entity_id = try r.readI32();
    const item = try stock_inv.readItemStack(r);
    out.item_type = item.type_id;
    out.item_count = item.count;
    out.setRecipeName(try r.readString(name[0..]));
    out.exp_gain = try r.readI32();
    out.used_count = try r.readU16();
    out.setScrappedName(try r.readString(name[0..]));
    return out;
}

/// Parse a workstation TE write (network mode) in full. The whole payload must be
/// consumed: a stock peer always writes exactly this layout, and stopping short
/// is how a missing trailing field goes unnoticed until a real client throws.
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
    if (qn > out.queue.len) return error.InvalidString;
    for (out.queue[0..qn]) |*q| q.* = try readQueueItem(&pr);
    out.queue_n = qn;
    const ccn = try pr.readI16();
    if (ccn < 0 or ccn > out.craft_complete.len) return error.InvalidString;
    const ccu: usize = @intCast(ccn);
    for (out.craft_complete[0..ccu]) |*cc| cc.* = try readCraftComplete(&pr);
    out.craft_complete_n = @intCast(ccu);
    out.is_burning = try pr.readBool();
    out.burn_time_left = try pr.readF32();
    const mn = try pr.readByte();
    if (mn > out.melt.len) return error.InvalidString;
    for (out.melt[0..mn]) |*m| m.* = try pr.readF32();
    out.melt_n = mn;
    out.is_player_placed = try pr.readBool();
    _ = try pr.readU64(); // lastTickTime delta (we re-time every echo)
    try readWsStackBlob(&pr, &out);
    if (pr.remaining() != 0) return error.InvalidString;
    return out;
}

/// A stock-shaped body: ctor array lengths, one fuel and one input stack, a
/// recipe in the active (last) queue slot and one craft-complete record.
fn testWorkstationBody(buf: []u8) ![]u8 {
    var fuel = [_]stock_inv.StockSlot{.{}} ** workstations.stock_fuel_len;
    fuel[0] = .{ .type_id = stock_inv.items_start_here + 3, .count = 5 };
    var input = [_]stock_inv.StockSlot{.{}} ** workstations.stock_input_len;
    input[0] = .{ .type_id = stock_inv.items_start_here + 7, .count = 12 };
    const tools = [_]stock_inv.StockSlot{.{}} ** workstations.stock_tools_len;
    const output = [_]stock_inv.StockSlot{.{}} ** workstations.stock_output_len;
    var last_input_buf: [64]u8 = undefined;
    var liw: binary.Writer = .{ .buf = &last_input_buf };
    for (0..workstations.stock_last_input_len) |_| try stock_inv.writeItemStack(&liw, .{});
    const melt = [_]f32{ 1.5, 0, 0 };

    var blob: [128]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &blob };
    try bw.writeU16(1); // Recipe.Version
    try bw.writeI32(stock_inv.items_start_here + 9); // itemValueType
    try bw.writeI32(2); // count
    try bw.writeBool(false); // isScrap
    try bw.writeF32(1.5); // craftingTime
    try bw.writeI32(5); // craftExpGain
    try bw.writeString("forge");
    try bw.writeI32(1); // one ingredient
    try stock_inv.writeItemStack(&bw, .{ .type_id = stock_inv.items_start_here + 4, .count = 6 });

    var queue = [_]QueueItem{.{}} ** workstations.stock_queue_len;
    queue[queue.len - 1] = .{
        .multiplier = 3,
        .is_crafting = true,
        .craft_time_left = 1.5,
        .one_item_craft_time = 1.5,
        .starting_entity_id = 171,
        .output_type = stock_inv.items_start_here + 9,
        .output_count = 2,
        .craft_exp_gain = 5,
    };
    queue[queue.len - 1].setRecipeBlob(bw.written());

    var cc: CraftComplete = .{
        .crafter_entity_id = 171,
        .item_type = stock_inv.items_start_here + 9,
        .item_count = 2,
        .exp_gain = 5,
        .used_count = 1,
    };
    cc.setRecipeName("meleeToolRepairT0StoneAxe");
    const ccs = [_]CraftComplete{cc};

    return buildWorkstationTeBody(buf, 255, 10, 70, 20, 1301, .{
        .fuel = fuel[0..],
        .input = input[0..],
        .tools = tools[0..],
        .output = output[0..],
        .last_input_count = workstations.stock_last_input_len,
        .last_input = liw.written(),
        .queue = queue[0..],
        .craft_complete = ccs[0..],
        .melt = melt[0..],
        .is_burning = true,
        .burn_time_left = 12.5,
    });
}

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
    // Unknown grid (0/0) synthesizes 2xN; a stored 6x2 grid rides the wire.
    try std.testing.expectEqual(@as(u16, 2), parsed.size_x);
    try std.testing.expectEqual(@as(u16, 4), parsed.size_y);
    cont.size_x = 6;
    cont.size_y = 2;
    const body2 = try buildStorageTeBody(&buf, 255, 10, 70, -3, 500, &cont, null, null);
    const parsed2 = try parseStorageTeBody(body2);
    try std.testing.expectEqual(@as(u16, 6), parsed2.size_x);
    try std.testing.expectEqual(@as(u16, 2), parsed2.size_y);
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

pub const VendingTeInfo = struct {
    block_id: i32,
    is_locked: bool = false,
    owner: ?platform_user.Id = null,
    password_hash: []const u8 = "",
    allowed: []const platform_user.Id = &.{},
    rental_end_day: i32 = 0,
    trader_id: i32 = 0,
    entries: []const stock_entity.TraderStockEntry = &.{},
    available_money: i32 = 0,
    rentable: bool = false,
    next_auto_buy: u64 = 0,
};

/// Build NetPackageTileEntity body for a vending machine. Outer header carries
/// the vending block id; the payload is the TE write above (byte-identical for
/// both network directions, like the workstation).
pub fn buildVendingTeBody(
    buf: []u8,
    handle: u8,
    world_x: i32,
    world_y: i32,
    world_z: i32,
    info: VendingTeInfo,
) ![]u8 {
    var payload: [8192]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &payload };
    const lp = localChunkPos(world_x, world_y, world_z);
    try pw.writeI32(lp.x);
    try pw.writeI32(lp.y);
    try pw.writeI32(lp.z);
    try pw.writeI32(3); // version constant (IL_0008-IL_000A)
    try pw.writeBool(info.is_locked);
    try platform_user.write(&pw, info.owner);
    try pw.writeString(info.password_hash);
    try pw.writeI32(@intCast(info.allowed.len));
    for (info.allowed) |uid| try platform_user.write(&pw, uid);
    try pw.writeI32(info.rental_end_day);
    try stock_entity.writeTraderDataBody(&pw, .{
        .trader_id = info.trader_id,
        .available_money = info.available_money,
        .entries = info.entries,
    });
    if (info.rentable) try pw.writeU64(info.next_auto_buy);
    const pay = pw.written();

    var w: binary.Writer = .{ .buf = buf };
    try writeOuterTeHeader(&w, handle, world_x, world_y, world_z, info.block_id, pay.len);
    try w.writeBytes(pay);
    return w.written();
}

/// C2S vending TE (TileEntityVendingMachine, type 7): the owner's edits to the
/// lock / password / allowed-user list, sent back as the full TE composite
/// (the mirror of buildVendingTeBody; stock TileEntityVendingMachine::read).
/// Ownership and the rental term stay server-owned (the rent SM applies them);
/// this parse captures the owner-editable fields and skips the rest.
pub const ParsedVending = struct {
    handle: u8 = 255,
    world_x: i32 = 0,
    world_y: i32 = 0,
    world_z: i32 = 0,
    block_id: i32 = 0,
    is_locked: bool = false,
    /// Slices into the caller-provided owner buffers.
    owner: platform_user.Id = .{ .platform = "", .id = "" },
    has_owner: bool = false,
    /// Slices into the caller-provided password buffer.
    password: []const u8 = "",
    allowed_n: u8 = 0,
    allowed: [max_vending_allowed]platform_user.Id = undefined,
    rental_end_day: i32 = 0,
    rentable: bool = false,
    next_auto_buy: u64 = 0,
};

pub const max_vending_allowed: usize = 8;

/// Read the vending TE composite. `plat_buf` / `id_buf` / `pw_buf` are the
/// caller's scratch for the owner identity, allowed-user identities and the
/// password string; `allowed` storage lives in the returned struct.
pub fn parseVendingTeBody(
    body: []const u8,
    plat_buf: []u8,
    id_buf: []u8,
    pw_buf: []u8,
    allowed_plat: []u8,
    allowed_id: []u8,
) binary.ReadError!ParsedVending {
    var r: binary.Reader = .{ .data = body };
    var out: ParsedVending = .{};
    const pay_len = try readOuterTeHeader(&r, &out.handle, &out.world_x, &out.world_y, &out.world_z, &out.block_id);
    if (r.remaining() < pay_len) return error.EndOfStream;
    var pr: binary.Reader = .{ .data = r.data[r.pos .. r.pos + pay_len] };
    _ = try pr.readI32(); // chunkPos x
    _ = try pr.readI32(); // chunkPos y
    _ = try pr.readI32(); // chunkPos z
    const ver = try pr.readI32();
    if (ver != 3) return error.InvalidString;
    out.is_locked = try pr.readBool();
    if (try platform_user.read(&pr, plat_buf, id_buf)) |uid| {
        out.owner = uid;
        out.has_owner = true;
    }
    out.password = try pr.readString(pw_buf);
    const allowed_count = try pr.readI32();
    if (allowed_count < 0 or allowed_count > 64) return error.InvalidString;
    var i: i32 = 0;
    while (i < allowed_count) : (i += 1) {
        if (out.allowed_n < max_vending_allowed) {
            const bp = allowed_plat[out.allowed_n * platform_user.max_platform_len ..][0..platform_user.max_platform_len];
            const bi = allowed_id[out.allowed_n * platform_user.max_id_len ..][0..platform_user.max_id_len];
            if (try platform_user.read(&pr, bp, bi)) |uid| {
                out.allowed[out.allowed_n] = uid;
                out.allowed_n += 1;
            }
        } else {
            var tmp_p: [platform_user.max_platform_len]u8 = undefined;
            var tmp_i: [platform_user.max_id_len]u8 = undefined;
            _ = try platform_user.read(&pr, &tmp_p, &tmp_i);
        }
    }
    out.rental_end_day = try pr.readI32();
    // TraderData follows; the store's rentable flag decides whether the u64
    // nextAutoBuy tail exists, so it cannot be parsed from the body alone.
    return out;
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
    if (out.trigger_type == trigger_type_motion) try platform_user.skip(&pr);
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

/// TileEntityLight network body (RE tile-entities-power.md 3.x
/// TileEntityLight.write IL=48): TileEntity.write network (chunkPos local
/// Vector3i + version u16 18) then LightIntensity f32, LightRange f32,
/// Color32, LightType u8, LightAngle f32, LightShadows u8.
pub const LightTeInfo = struct {
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    /// RGBA (Color32).
    color: u32 = 0xffffffff,
    light_type: u8 = 1,
    angle: f32 = 0,
    shadows: u8 = 1,
};

pub fn buildLightTeBody(buf: []u8, handle: u8, world_x: i32, world_y: i32, world_z: i32, info: LightTeInfo) ![]u8 {
    var payload: [64]u8 = undefined;
    var pw: binary.Writer = .{ .buf = &payload };
    const lp = localChunkPos(world_x, world_y, world_z);
    try pw.writeI32(lp.x);
    try pw.writeI32(lp.y);
    try pw.writeI32(lp.z);
    try pw.writeU16(18); // network write version constant (IL_000B)
    try pw.writeF32(info.intensity);
    try pw.writeF32(info.range);
    try pw.writeU32(info.color);
    try pw.writeByte(info.light_type);
    try pw.writeF32(info.angle);
    try pw.writeByte(info.shadows);

    var w: binary.Writer = .{ .buf = buf };
    try writeOuterTeHeader(&w, handle, world_x, world_y, world_z, 0, pw.written().len);
    try w.writeBytes(pw.written());
    return w.written();
}

test "light TE body round-trips the stock network layout" {
    var buf: [128]u8 = undefined;
    const body = try buildLightTeBody(&buf, 255, 10, 70, 20, .{
        .intensity = 1.3,
        .range = 3.0,
        .color = 0xff2993ff,
        .light_type = 2,
        .angle = 0.5,
        .shadows = 1,
    });
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(u8, 255), try r.readByte()); // handle
    try std.testing.expectEqual(@as(i32, 10), try r.readI32()); // world pos
    try std.testing.expectEqual(@as(i32, 70), try r.readI32());
    try std.testing.expectEqual(@as(i32, 20), try r.readI32());
    _ = try r.readI32(); // block id (0)
    const pay_len = try r.readI32();
    try std.testing.expect(pay_len == 3 * 4 + 2 + 4 + 4 + 4 + 1 + 4 + 1);
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
    try std.testing.expectEqual(@as(u8, 1), try r.readByte());
}
