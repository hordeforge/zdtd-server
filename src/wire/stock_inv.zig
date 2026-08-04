//! Stock V3.0.1 inventory wire (ItemValue/ItemStack/Bag/Equipment/NetPackagePlayerInventory).
//! Encodes bodies only (package id is in the channel frame, not here).
//!
//! RE source: Assembly-CSharp ItemValue.Write (save version 9), ItemStack.Write,
//! GameUtils.WriteItemStack / WriteItemValueArray, Bag.Write, NetPackagePlayerInventory.write,
//! NetPackageHoldingItem.write. Block.ItemsStartHere = 65536.

const std = @import("std");
const binary = @import("binary.zig");
const components = @import("../ecs/components.zig");

/// Matches Block.ItemsStartHere after static init (MAX_BLOCKS).
/// Single source: assets/items.zig (catalog owns the pin; wire re-exports).
pub const items_start_here: i32 = @import("../assets/items.zig").items_start_here;

/// ItemValue.CurrentSaveVersion in V3.0.1.
pub const item_value_save_version: u8 = 9;

/// Inventory.PUBLIC_SLOTS_PLAYMODE.
pub const toolbelt_slots: usize = 10;

/// EntityPlayer bag size on the wire: CarryCapacity base is 45 (Awake
/// EffectManager base f32 45 → Bag.ctor). ECS stores only
/// `components.inv_bag_count` (32); apply truncates, encode pads empties.
/// ldc.i4.s 99 in Awake is the PassiveEffects enum, not size.
pub const bag_slots: usize = 45;

/// Equipment.m_slots length in ctor.
pub const equipment_slots: usize = 12;

pub const StockSlot = struct {
    /// Absolute ItemValue.type (block id < items_start_here, or items_start_here + item index).
    /// Prefer encodeItemType() helpers for item classes.
    type_id: i32 = 0,
    count: u16 = 0,
    quality: u16 = 0,
    meta: u16 = 0,
    use_times: f32 = 0,
    seed: u16 = 0,
    activated: u8 = 0,
    ammo_index: u8 = 0,
};

/// Map relative item index (0..) to absolute type with ItemsStartHere offset.
pub fn itemTypeFromIndex(item_index: u16) i32 {
    if (item_index == 0) return 0;
    return items_start_here + @as(i32, item_index);
}

/// Encode zdtd builtin item_id as a stock-style absolute type (item flag path).
/// Icons only match when the client ItemClass list assigns the same relative index;
/// structure is always client-parseable.
pub fn typeFromBuiltinId(item_id: u16) i32 {
    return itemTypeFromIndex(item_id);
}

pub fn writeEmptyItemValue(w: *binary.Writer) !void {
    try w.writeByte(0);
}

/// Minimal non-empty ItemValue.Write (v9): no Metadata, no Stats, empty mods/cosmetics, default texture.
/// Emptiness is type_id == 0 only (equipment uses ItemValue without stack count).
pub fn writeItemValue(w: *binary.Writer, s: StockSlot) !void {
    if (s.type_id == 0) {
        try writeEmptyItemValue(w);
        return;
    }
    try w.writeByte(item_value_save_version);

    var wire_type: i32 = s.type_id;
    var flags: u8 = 0;
    if (wire_type >= items_start_here) {
        flags |= 1;
        wire_type -= items_start_here;
    }
    // no Stats → flag bit 1 clear
    try w.writeByte(flags);
    try w.writeU16(@intCast(wire_type));
    try w.writeF32(s.use_times);
    try w.writeU16(s.quality);
    try w.writeU16(s.meta);
    try w.writeByte(0); // metadata count
    // not ItemClassModifier path: write mod arrays
    try w.writeByte(0); // Modifications.Length
    try w.writeByte(0); // CosmeticMods.Length
    try w.writeByte(s.activated);
    try w.writeByte(s.ammo_index);
    try w.writeU16(s.seed);
    try w.writeBool(false); // TextureFullArray default
}

/// ItemStack.Write: count u16; if count != 0 then ItemValue.Write.
pub fn writeItemStack(w: *binary.Writer, s: StockSlot) !void {
    const c: u16 = if (s.count > 65535) 65535 else s.count;
    try w.writeU16(c);
    if (c != 0) try writeItemValue(w, s);
}

/// GameUtils.WriteItemStack: count u16 + ItemStack.Write * n (including empties).
pub fn writeItemStackList(w: *binary.Writer, slots: []const StockSlot) !void {
    try w.writeU16(@intCast(slots.len));
    for (slots) |s| try writeItemStack(w, s);
}

/// GameUtils.WriteItemValueArray: count u16 + (bool present, ItemValue?)*n
pub fn writeItemValueArray(w: *binary.Writer, slots: []const StockSlot) !void {
    try w.writeU16(@intCast(slots.len));
    for (slots) |s| {
        const present = s.type_id != 0;
        try w.writeBool(present);
        if (present) try writeItemValue(w, s);
    }
}

/// Bag.Write (version 1): byte ver, u16 slot count, stacks, locked=false, touched, prefs=false.
pub fn writeBag(w: *binary.Writer, slots: []const StockSlot, touched: bool) !void {
    try w.writeByte(1); // Bag.Version path that includes touched + prefs
    try w.writeU16(@intCast(slots.len));
    for (slots) |s| try writeItemStack(w, s);
    try w.writeBool(false); // no LockedSlots
    try w.writeBool(touched);
    try w.writeBool(false); // no PreferenceTracker
}

/// Equipment section of NetPackagePlayerInventory when equipment is present.
pub fn writeEquipment(w: *binary.Writer, slots: []const StockSlot) !void {
    try writeItemValueArray(w, slots);
    // Cosmetic IDs: one i32 per equipment slot (item type id or 0)
    for (slots) |_| try w.writeI32(0);
    try w.writeI32(0); // unlocked cosmetics count
}

/// NetPackagePlayerInventory body (no base PackageId).
pub fn writePlayerInventory(
    w: *binary.Writer,
    toolbelt: []const StockSlot,
    bag: []const StockSlot,
    equipment: []const StockSlot,
    drag: ?StockSlot,
) !void {
    const has_tb = toolbelt.len > 0;
    try w.writeBool(has_tb);
    if (has_tb) try writeItemStackList(w, toolbelt);

    const has_bag = bag.len > 0;
    try w.writeBool(has_bag);
    if (has_bag) try writeBag(w, bag, true);

    const has_eq = equipment.len > 0;
    try w.writeBool(has_eq);
    if (has_eq) try writeEquipment(w, equipment);

    const has_drag = drag != null and drag.?.type_id != 0 and drag.?.count != 0;
    try w.writeBool(has_drag);
    if (has_drag) {
        var one = [_]StockSlot{drag.?};
        try writeItemStackList(w, one[0..]);
    }
}

/// NetPackageHoldingItem body: entityId i32, ItemStack, holding index byte.
pub fn writeHoldingItem(w: *binary.Writer, entity_id: i32, held: StockSlot, holding_index: u8) !void {
    try w.writeI32(entity_id);
    try writeItemStack(w, held);
    try w.writeByte(holding_index);
}

/// Optional absolute-type resolver (from ItemTable.stockTypeFor). null → builtin relative.
pub const TypeResolver = *const fn (ctx: ?*anyopaque, item_id: u16) i32;

pub fn buildFromEcs(buf: []u8, inv: *const components.Inventory) ![]u8 {
    return buildFromEcsResolved(buf, inv, null, null);
}

pub fn buildFromEcsResolved(
    buf: []u8,
    inv: *const components.Inventory,
    resolve: ?TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    var tb: [toolbelt_slots]StockSlot = [_]StockSlot{.{}} ** toolbelt_slots;
    var bag: [bag_slots]StockSlot = [_]StockSlot{.{}} ** bag_slots;
    var eq: [equipment_slots]StockSlot = [_]StockSlot{.{}} ** equipment_slots;

    var i: usize = 0;
    while (i < toolbelt_slots) : (i += 1) {
        const s = inv.slots[i];
        if (s.count > 0 and s.item_id != 0) {
            tb[i] = slotFromEcs(s, resolve, ctx);
        }
    }
    i = 0;
    while (i < components.inv_bag_count and i < bag_slots) : (i += 1) {
        const s = inv.slots[components.inv_bag_start + i];
        if (s.count > 0 and s.item_id != 0) {
            bag[i] = slotFromEcs(s, resolve, ctx);
        }
    }
    i = 0;
    while (i < components.inv_equip_count and i < equipment_slots) : (i += 1) {
        const s = inv.slots[components.inv_equip_start + i];
        if (s.count > 0 and s.item_id != 0) {
            eq[i] = slotFromEcs(s, resolve, ctx);
        }
    }

    var w: binary.Writer = .{ .buf = buf };
    try writePlayerInventory(&w, tb[0..], bag[0..], eq[0..], null);
    return w.written();
}

pub fn buildHoldingFromEcs(buf: []u8, entity_id: i32, inv: *const components.Inventory) ![]u8 {
    return buildHoldingFromEcsResolved(buf, entity_id, inv, null, null);
}

pub fn buildHoldingFromEcsResolved(
    buf: []u8,
    entity_id: i32,
    inv: *const components.Inventory,
    resolve: ?TypeResolver,
    ctx: ?*anyopaque,
) ![]u8 {
    const held_ecs = inv.heldItem();
    const held = if (held_ecs.count > 0 and held_ecs.item_id != 0)
        slotFromEcs(held_ecs, resolve, ctx)
    else
        StockSlot{};
    const idx: u8 = if (inv.holding < toolbelt_slots) @intCast(inv.holding) else 0;
    var w: binary.Writer = .{ .buf = buf };
    try writeHoldingItem(&w, entity_id, held, idx);
    return w.written();
}

pub fn slotFromEcs(s: components.InvSlot, resolve: ?TypeResolver, ctx: ?*anyopaque) StockSlot {
    // Empty stacks must be type 0 / count 0. Resolving item_id=0 through the
    // catalog can yield a non-zero fallback type and fill the client bag.
    if (s.count == 0 or s.item_id == 0) return .{};
    const type_id: i32 = if (resolve) |r| r(ctx, s.item_id) else typeFromBuiltinId(s.item_id);
    if (type_id == 0) return .{};
    // InvSlot stores a single meta field (durability / flags); stock seed is not
    // tracked separately, so leave seed at default 0 (do not mirror meta into seed).
    return .{
        .type_id = type_id,
        .count = s.count,
        .quality = s.quality,
        .meta = s.meta,
    };
}

// --- C→S parsers (vanilla client sends these ToServer) ---

pub const ReverseResolver = *const fn (ctx: ?*anyopaque, stock_type: i32) u16;

/// Unity Mono string hash of entity class names (matches EntityClass.list / stock_entity).
const class_player_male: i32 = 2001454542;
const class_player_female: i32 = 2129337093;

fn skipStat(r: *binary.Reader) binary.ReadError!void {
    const ver = try r.readI32();
    if (ver != 6) return error.EndOfStream;
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
}

fn skipPlayerEntityStats(r: *binary.Reader) binary.ReadError!void {
    // PlayerEntityStats.Write: version 11, Health/Stamina/Water/Food Stat, CoreTemp sbyte
    const ver = try r.readI32();
    if (ver != 11) return error.EndOfStream;
    try skipStat(r);
    try skipStat(r);
    try skipStat(r);
    try skipStat(r);
    _ = try r.readByte(); // CoreTemp
}

fn skipEntityStats(r: *binary.Reader, is_player: bool) binary.ReadError!void {
    if (is_player) return skipPlayerEntityStats(r);
    // EntityStats.Write: version 11 + Health only
    const ver = try r.readI32();
    if (ver != 11) return error.EndOfStream;
    try skipStat(r);
}

fn skipBag(r: *binary.Reader) binary.ReadError!void {
    return skipBagApply(r, null, null, null);
}

fn skipPlayerProfile(r: *binary.Reader) binary.ReadError!void {
    // PlayerProfile.Write: i32 version=5, strings/bool/byte fields
    _ = try r.readI32();
    try r.skipString(); // archetype
    _ = try r.readBool(); // isMale
    try r.skipString(); // race
    _ = try r.readByte(); // variant
    try r.skipString(); // hair
    try r.skipString(); // hairColor
    try r.skipString(); // mustache
    try r.skipString(); // chops
    try r.skipString(); // beard
    try r.skipString(); // eyeColor
}

/// Skip EntityCreationData.write(networkWrite=false) for player/zombie paths.
/// Returns entity_id and position from the ECD head.
pub fn skipEcdNetworkWriteFalse(r: *binary.Reader) binary.ReadError!struct { entity_id: i32, x: f32, y: f32, z: f32 } {
    const file_ver = try r.readByte();
    // V3.0.1 wrote 35; V3.1.0 client ECD.write is 36 (+ stressAmount tail).
    if (file_ver != 35 and file_ver != 36) return error.EndOfStream;
    const entity_class = try r.readI32();
    const entity_id = try r.readI32();
    _ = try r.readF32(); // lifetime
    const x = try r.readF32();
    const y = try r.readF32();
    const z = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32(); // rot
    _ = try r.readBool(); // onGround
    // BodyDamage.Write: version, damageType, Flags
    _ = try r.readI32();
    _ = try r.readI32();
    _ = try r.readU32();
    const has_stats = try r.readBool();
    const is_player = entity_class == class_player_male or entity_class == class_player_female;
    if (has_stats) try skipEntityStats(r, is_player);
    _ = try r.readI16(); // deathTime
    const has_bag = try r.readBool();
    if (has_bag) try skipBag(r);
    _ = try r.readI32();
    _ = try r.readI32();
    _ = try r.readI32(); // home
    _ = try r.readI16(); // homeRange
    _ = try r.readByte(); // spawnerSource
    // Class specials: item / falling / player mid fields
    if (is_player) {
        _ = try readItemValue(r); // holding
        _ = try r.readByte(); // team
        try r.skipString(); // entityName
        try r.skipString(); // skinTexture
        const has_profile = try r.readBool();
        if (has_profile) try skipPlayerProfile(r);
    }
    // entityData blob + trader
    const ed_len = try r.readU16();
    if (r.remaining() < ed_len) return error.EndOfStream;
    r.pos += ed_len;
    const has_trader = try r.readBool();
    if (has_trader) return error.EndOfStream; // rare on join PDF
    // networkWrite=false: no sleeper tail; junkDrone skipped (class 0)
    if (file_ver >= 36) _ = try r.readF32(); // stressAmount
    return .{ .entity_id = entity_id, .x = x, .y = y, .z = z };
}

/// Apply PlayerDataFile.WriteNetwork body (ECD + toolbelt/bag/equip sections).
/// Stops after Equipment.Write; rest of PDF (quests, waypoints, meta) is ignored for sim.
pub fn applyPlayerDataNetwork(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!struct { entity_id: i32, x: f32, y: f32, z: f32, inv_slots: u16 } {
    var r: binary.Reader = .{ .data = body };
    const head = try skipEcdNetworkWriteFalse(&r);

    // PDF.Write remainder starts with toolbelt ItemStack list
    var tb: [toolbelt_slots]StockSlot = [_]StockSlot{.{}} ** toolbelt_slots;
    const tb_n = try readItemStackList(&r, tb[0..]);
    var i: usize = 0;
    while (i < toolbelt_slots) : (i += 1) {
        inv.slots[i] = if (i < tb_n) toEcs(tb[i], reverse, ctx) else .{};
    }
    const selected = try r.readByte(); // selectedInventorySlot
    if (selected < toolbelt_slots) {
        _ = inv.setHolding(selected);
    }

    // Bag (always written in PDF)
    try skipBagApply(&r, inv, reverse, ctx);

    // dragAndDrop as 1-element list
    var drag: [1]StockSlot = .{.{}};
    _ = try readItemStackList(&r, drag[0..]);

    // alreadyCraftedList: u16 count + strings
    const crafted_n = try r.readU16();
    var ci: u16 = 0;
    while (ci < crafted_n) : (ci += 1) try r.skipString();

    // spawnPoints: stock Write always emits byte 0 (no entries follow)
    _ = try r.readByte();
    _ = try r.readI64(); // selectedSpawnPointKey
    _ = try r.readBool(); // stock hardcodes true
    _ = try r.readI16(); // stock hardcodes 0
    _ = try r.readBool(); // bLoaded
    // lastSpawnPosition: Vector3i + heading
    _ = try r.readI32();
    _ = try r.readI32();
    _ = try r.readI32();
    _ = try r.readF32();
    _ = try r.readI32(); // pdf id
    _ = try r.readI32(); // playerKills
    _ = try r.readI32(); // zombieKills
    _ = try r.readI32(); // deaths
    _ = try r.readI32(); // score

    // Equipment.Write (v4): 12 ItemValues + 12 cosmetic i32 + unlocked list
    try applyEquipmentWrite(&r, inv, reverse, ctx);

    var filled: u16 = 0;
    i = 0;
    while (i < components.max_inv_slots) : (i += 1) {
        if (inv.slots[i].count > 0 and inv.slots[i].item_id != 0) filled += 1;
    }
    return .{ .entity_id = head.entity_id, .x = head.x, .y = head.y, .z = head.z, .inv_slots = filled };
}

/// Equipment.Write / Read: version byte 4, m_slots ItemValues, cosmetic i32s, unlocked i32 list.
fn applyEquipmentWrite(
    r: *binary.Reader,
    inv: *components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!void {
    const ver = try r.readByte();
    if (ver != 4) return error.EndOfStream;
    var i: usize = 0;
    while (i < equipment_slots) : (i += 1) {
        const s = try readItemValue(r);
        if (i < components.inv_equip_count) {
            inv.slots[components.inv_equip_start + i] = toEcs(s, reverse, ctx);
        }
    }
    i = 0;
    while (i < equipment_slots) : (i += 1) _ = try r.readI32(); // cosmetic slot ids
    const unlocked = try r.readI32();
    if (unlocked < 0) return error.EndOfStream;
    var ui: i32 = 0;
    while (ui < unlocked) : (ui += 1) _ = try r.readI32();
}

/// Parse a Bag blob; apply stacks into `inv` when non-null, skip otherwise.
fn skipBagApply(
    r: *binary.Reader,
    inv: ?*components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!void {
    const bag_ver = try r.readByte();
    const bag_n = try r.readU16();
    var i: usize = 0;
    while (i < bag_n) : (i += 1) {
        const s = try readItemStack(r);
        if (inv) |v| if (i < components.inv_bag_count) {
            v.slots[components.inv_bag_start + i] = toEcs(s, reverse, ctx);
        };
    }
    if (inv) |v| while (i < components.inv_bag_count) : (i += 1) {
        v.slots[components.inv_bag_start + i] = .{};
    };
    const has_locked = try r.readBool();
    if (has_locked) try skipPackedBoolArray(r);
    if (bag_ver >= 1) {
        _ = try r.readBool(); // touched
        const has_prefs = try r.readBool();
        if (has_prefs) return error.EndOfStream; // unsupported
    }
}

/// ItemValue.Read: empty byte 0, else version + ReadData.
pub fn readItemValue(r: *binary.Reader) binary.ReadError!StockSlot {
    const ver = try r.readByte();
    if (ver == 0) return .{};
    return readItemValueData(r, ver, false);
}

/// Nested ItemValue inside a mod/cosmetic slot: entries are ItemClassModifier
/// items, whose ReadData skips the Modifications/CosmeticMods arrays (IL).
fn readItemValueNested(r: *binary.Reader) binary.ReadError!StockSlot {
    const ver = try r.readByte();
    if (ver == 0) return .{};
    return readItemValueData(r, ver, true);
}

/// Deterministic ItemValue.ReadData per stock IL (dump_iv_readdata):
/// v>=8 flags byte | type u16 (+ItemsStartHere if flag1) | UseTimes (f32 if v>5)
/// | Quality u16 | Meta u16 | v>6 metadata | flag2 stats | mods+cosmetics unless
/// modifier | v>1 Activated | v>2 AmmoIdx | v>3 Seed | v>8 texture bool+i64.
fn readItemValueData(r: *binary.Reader, version: u8, is_modifier: bool) binary.ReadError!StockSlot {
    var flags: u8 = 0;
    if (version >= 8) flags = try r.readByte();
    var type_id: i32 = try r.readU16();
    if ((flags & 1) != 0) type_id += items_start_here;
    // legacy type remap for version < 8 skipped (we always send v9)

    const use_times: f32 = if (version > 5) try r.readF32() else @floatFromInt(try r.readU16());
    const quality = try r.readU16();
    // ItemClass quality clamp skipped (no ItemClass table)
    const meta = try r.readU16();

    if (version > 6) {
        const meta_count = try r.readByte();
        var mi: u8 = 0;
        while (mi < meta_count) : (mi += 1) {
            try r.skipString();
            try skipTypedMetadata(r);
        }
    }

    if ((flags & 2) != 0) {
        const sc = try r.readByte();
        var si: u8 = 0;
        while (si < sc) : (si += 1) {
            _ = try r.readByte(); // type
            _ = try r.readI16();
            _ = try r.readI16();
        }
    }

    // Stock: skip mods when (v<=4 and !HasQuality) or ItemClass is
    // ItemClassModifier. We always speak v9, and nested mod-slot entries are
    // the modifier case, so top-level parses arrays unconditionally.
    if (!is_modifier) {
        const mod_n = try r.readByte();
        var mi: u8 = 0;
        while (mi < mod_n) : (mi += 1) {
            const has = try r.readBool();
            if (has) _ = try readItemValueNested(r);
        }
        const cos_n = try r.readByte();
        var ci: u8 = 0;
        while (ci < cos_n) : (ci += 1) {
            const has = try r.readBool();
            if (has) _ = try readItemValueNested(r);
        }
    }

    var activated: u8 = 0;
    var ammo: u8 = 0;
    var seed: u16 = 0;
    if (version > 1) activated = try r.readByte();
    if (version > 2) ammo = try r.readByte();
    if (version > 3) seed = try r.readU16();
    if (version > 8) {
        const has_tex = try r.readBool();
        if (has_tex) _ = try r.readU64(); // TextureFullArray.Read(br,1): one i64
    }

    return .{
        .type_id = type_id,
        .count = 1, // ItemValue alone; stack count is separate
        .quality = quality,
        .meta = meta,
        .use_times = use_times,
        .seed = seed,
        .activated = activated,
        .ammo_index = ammo,
    };
}

fn skipTypedMetadata(r: *binary.Reader) binary.ReadError!void {
    // TypedMetadataValue.Read: i32 typeTag, then payload
    const tag = try r.readI32();
    switch (tag) {
        1 => _ = try r.readF32(),
        2 => _ = try r.readI32(),
        3 => try r.skipString(),
        else => {},
    }
}

pub fn readItemStack(r: *binary.Reader) binary.ReadError!StockSlot {
    const count = try r.readU16();
    if (count == 0) return .{};
    var s = try readItemValue(r);
    s.count = count;
    return s;
}

pub fn readItemStackList(r: *binary.Reader, out: []StockSlot) binary.ReadError!usize {
    const n = try r.readU16();
    const take = @min(@as(usize, n), out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = try readItemStack(r);
        if (i < take) out[i] = s;
    }
    return take;
}

/// Parse stock NetPackagePlayerInventory body and apply present sections into ECS Inventory.
/// reverse maps absolute stock type → ecs item_id (0 = empty/unknown skipped as empty).
pub fn applyPlayerInventoryBody(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
) binary.ReadError!void {
    var r: binary.Reader = .{ .data = body };

    const has_tb = try r.readBool();
    if (has_tb) {
        var slots: [toolbelt_slots]StockSlot = [_]StockSlot{.{}} ** toolbelt_slots;
        const n = try readItemStackList(&r, slots[0..]);
        var i: usize = 0;
        while (i < toolbelt_slots) : (i += 1) {
            if (i < n) {
                inv.slots[i] = toEcs(slots[i], reverse, ctx);
            } else {
                inv.slots[i] = .{};
            }
        }
    }

    const has_bag = try r.readBool();
    if (has_bag) {
        // Bag.Write: version byte, u16 count, stacks, locked?, touched?, prefs?
        const bag_ver = try r.readByte();
        const bag_n = try r.readU16();
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = try readItemStack(&r);
            if (i < components.inv_bag_count) {
                inv.slots[components.inv_bag_start + i] = toEcs(s, reverse, ctx);
            }
        }
        // clear remaining bag slots if client sent shorter bag
        while (i < components.inv_bag_count) : (i += 1) {
            inv.slots[components.inv_bag_start + i] = .{};
        }
        const has_locked = try r.readBool();
        if (has_locked) {
            // PackedBoolArray: skip best-effort (length-prefixed bits). Read count if present.
            // Stock PackedBoolArray.Read: typically length then bytes. Skip remaining carefully:
            // For empty lock array Write is only false bool; when true, Read reconstructs.
            // Minimal: if stream has u16 length then that many bits packed.
            // Use versioned bag path: after locks, version>=1 has touched + prefs.
            _ = try skipPackedBoolArray(&r);
        }
        if (bag_ver >= 1) {
            _ = try r.readBool(); // touched
            const has_prefs = try r.readBool();
            if (has_prefs) {
                // PreferenceTracker.Write: playerId:i32 + optional toolbelt/equip/bag stacks.
                // Skip fully so equipment/drag sections after bag still parse.
                try skipPreferenceTracker(&r);
            }
        }
    }

    const has_eq = try r.readBool();
    if (has_eq) {
        const eq_n = try r.readU16();
        var i: usize = 0;
        while (i < eq_n) : (i += 1) {
            const present = try r.readBool();
            var s: StockSlot = .{};
            if (present) s = try readItemValue(&r);
            if (i < components.inv_equip_count) {
                inv.slots[components.inv_equip_start + i] = toEcs(s, reverse, ctx);
            }
        }
        // cosmetic i32 per eq slot + unlocked list
        var ci: usize = 0;
        while (ci < eq_n) : (ci += 1) _ = try r.readI32();
        const unlocked = try r.readI32();
        var ui: i32 = 0;
        while (ui < unlocked) : (ui += 1) _ = try r.readI32();
    }

    const has_drag = try r.readBool();
    if (has_drag) {
        // GameUtils.ReadItemStack: count + stacks; first is drag
        var drag_slots: [1]StockSlot = .{.{}};
        _ = try readItemStackList(&r, drag_slots[0..]);
        // ECS has no drag slot; ignore contents but parse for stream correctness.
    }
}

/// PreferenceTracker.Write (IL): playerId:i32, then optional toolbelt stacks,
/// equipment ItemValue array, bag stacks (each gated by a bool).
/// Best-effort count of eatable units in a PlayerInventory body (toolbelt+bag).
pub fn countEatableInPlayerInventoryBody(
    body: []const u8,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
    is_eat: *const fn (ctx: ?*anyopaque, item_id: u16) bool,
) struct { total: u32, first_id: u16 } {
    var r: binary.Reader = .{ .data = body };
    var total: u32 = 0;
    var first_id: u16 = 0;
    const has_tb = r.readBool() catch return .{ .total = 0, .first_id = 0 };
    if (has_tb) {
        var slots: [toolbelt_slots]StockSlot = [_]StockSlot{.{}} ** toolbelt_slots;
        const n = readItemStackList(&r, slots[0..]) catch 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = slots[i];
            if (s.type_id == 0 or s.count == 0) continue;
            const eid: u16 = if (reverse) |rv| rv(ctx, s.type_id) else fallbackEcsId(s.type_id);
            if (eid == 0) continue;
            if (!is_eat(ctx, eid)) continue;
            total += s.count;
            if (first_id == 0) first_id = eid;
        }
    }
    const has_bag = r.readBool() catch return .{ .total = total, .first_id = first_id };
    if (has_bag) {
        _ = r.readByte() catch return .{ .total = total, .first_id = first_id };
        const bag_n = r.readU16() catch return .{ .total = total, .first_id = first_id };
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = readItemStack(&r) catch break;
            if (s.type_id == 0 or s.count == 0) continue;
            const eid: u16 = if (reverse) |rv| rv(ctx, s.type_id) else fallbackEcsId(s.type_id);
            if (eid == 0) continue;
            if (!is_eat(ctx, eid)) continue;
            total += s.count;
            if (first_id == 0) first_id = eid;
        }
    }
    return .{ .total = total, .first_id = first_id };
}

fn skipPreferenceTracker(r: *binary.Reader) binary.ReadError!void {
    _ = try r.readI32(); // PlayerID
    if (try r.readBool()) {
        var tmp: [64]StockSlot = [_]StockSlot{.{}} ** 64;
        _ = try readItemStackList(r, tmp[0..]);
    }
    if (try r.readBool()) {
        const n = try r.readU16();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const present = try r.readBool();
            if (present) _ = try readItemValue(r);
        }
    }
    if (try r.readBool()) {
        var tmp: [64]StockSlot = [_]StockSlot{.{}} ** 64;
        _ = try readItemStackList(r, tmp[0..]);
    }
}

fn skipPackedBoolArray(r: *binary.Reader) binary.ReadError!void {
    // PackedBoolArray.Write: 7-bit encoded length (StreamUtils.Write7BitEncodedInt
    // per IL), then packed bytes. Matches the reader in stock_te.zig.
    const len = try binary.read7BitEncodedInt(r);
    if (len == 0) return;
    const nbytes: usize = (@as(usize, len) + 7) / 8;
    if (r.remaining() < nbytes) return error.EndOfStream;
    r.pos += nbytes;
}

fn toEcs(s: StockSlot, reverse: ?ReverseResolver, ctx: ?*anyopaque) components.InvSlot {
    if (s.type_id == 0 or s.count == 0) return .{};
    const item_id: u16 = if (reverse) |rv| rv(ctx, s.type_id) else fallbackEcsId(s.type_id);
    if (item_id == 0) return .{};
    return .{
        .item_id = item_id,
        .count = s.count,
        .quality = @min(s.quality, 255),
        .meta = s.meta,
    };
}

fn fallbackEcsId(stock_type: i32) u16 {
    if (stock_type >= items_start_here) {
        const rel = stock_type - items_start_here;
        if (rel > 0 and rel <= 65535) return @intCast(rel);
    }
    return 0;
}

pub const HoldingParsed = struct {
    entity_id: i32,
    stack: StockSlot,
    holding_index: u8,
};

pub fn readHoldingItem(body: []const u8) binary.ReadError!HoldingParsed {
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const stack = try readItemStack(&r);
    const idx = try r.readByte();
    return .{ .entity_id = entity_id, .stack = stack, .holding_index = idx };
}

pub const ItemDropParsed = struct {
    stack: StockSlot,
    x: f32,
    y: f32,
    z: f32,
    entity_id: i32,
    client_instance_id: i32,
    relative_to_head: bool,
};

pub fn readItemDrop(body: []const u8) binary.ReadError!ItemDropParsed {
    var r: binary.Reader = .{ .data = body };
    const stack = try readItemStack(&r);
    const x = try r.readF32();
    const y = try r.readF32();
    const z = try r.readF32();
    _ = try r.readF32(); // initialMotion x
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32(); // randomPosAdd
    _ = try r.readF32();
    _ = try r.readF32();
    _ = try r.readF32(); // lifetime
    const entity_id = try r.readI32();
    const client_instance_id = try r.readI32();
    const relative = try r.readBool();
    return .{
        .stack = stack,
        .x = x,
        .y = y,
        .z = z,
        .entity_id = entity_id,
        .client_instance_id = client_instance_id,
        .relative_to_head = relative,
    };
}

// --- NetPackagePersistentPlayerState: reason u8 | PersistentPlayerData.Write ---
// PPD.Write (IL dump_ppl): PrimaryId ToStream | NativeId ToStream | playGroup u8 |
// AuthoredText(name) ToStream | lastLogin i64 | pos xyz i32*3 | entityId i32 |
// lpCount i32 | backpackCount i32 | lpBlocks | backpacks | bedroll xyz |
// questPosCount i32 | ... | vendingCount i32 | ...
// PUID.ToStream: bool present | u8 platform-tag-len-ish (client pops) | platform string | id string.
// AuthoredText.ToStream: bool present | text string | author PUID.

pub const persistent_reason_login: u8 = 0;

fn writePuid(w: *binary.Writer, platform: []const u8, id: []const u8) !void {
    try w.writeBool(true);
    try w.writeByte(0); // popped unread by FromStream
    try w.writeString(platform);
    try w.writeString(id);
}

/// Build NetPackagePersistentPlayerState body (reason=Login) so clients can map
/// entityId → player name (GameMessage shows '' otherwise).
pub fn buildPersistentPlayerState(
    buf: []u8,
    entity_id: i32,
    name: []const u8,
    steam_id: []const u8,
    x: i32,
    y: i32,
    z: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(persistent_reason_login);
    try writePuid(&w, "Steam", steam_id); // PrimaryId
    try writePuid(&w, "Steam", steam_id); // NativeId
    try w.writeByte(0); // playGroup Standard
    // AuthoredText: present | text | author PUID
    try w.writeBool(true);
    try w.writeString(name);
    try writePuid(&w, "Steam", steam_id);
    try w.writeI64(0); // lastLogin ticks
    try w.writeI32(x);
    try w.writeI32(y);
    try w.writeI32(z);
    try w.writeI32(entity_id);
    try w.writeI32(0); // lpBlocks count
    try w.writeI32(0); // backpacks count
    // bedroll: y=int.max marks unset
    try w.writeI32(0);
    try w.writeI32(std.math.maxInt(i32));
    try w.writeI32(0);
    try w.writeI32(0); // questPositions count
    try w.writeI32(0); // vending count
    return w.written();
}

test "persistent player state body layout" {
    var buf: [512]u8 = undefined;
    const body = try buildPersistentPlayerState(&buf, 107, "maci", "76561190000000000", -273, 61, 449);
    try std.testing.expectEqual(persistent_reason_login, body[0]);
    // First PUID: present bool at [1]
    try std.testing.expectEqual(@as(u8, 1), body[1]);
    try std.testing.expect(body.len > 60);
}

// --- NetPackageBag: entityId i32 | u16 blob_len | Bag.Write ---

/// Build NetPackageBag body from ECS inventory bag slots (player bag padded to bag_slots).
pub fn buildBagPackage(
    buf: []u8,
    entity_id: i32,
    inv: *const components.Inventory,
    resolve: ?TypeResolver,
    ctx: ?*anyopaque,
    /// If true, map inv bag range only; if false, map all slots as bag (loot container).
    player_bag_only: bool,
) ![]u8 {
    var bag: [bag_slots]StockSlot = [_]StockSlot{.{}} ** bag_slots;
    if (player_bag_only) {
        var i: usize = 0;
        while (i < components.inv_bag_count and i < bag_slots) : (i += 1) {
            const s = inv.slots[components.inv_bag_start + i];
            if (s.count > 0 and s.item_id != 0) bag[i] = slotFromEcs(s, resolve, ctx);
        }
    } else {
        var i: usize = 0;
        var o: usize = 0;
        while (i < components.max_inv_slots and o < bag_slots) : (i += 1) {
            const s = inv.slots[i];
            if (s.count > 0 and s.item_id != 0) {
                bag[o] = slotFromEcs(s, resolve, ctx);
                o += 1;
            }
        }
    }

    var inner: [4096]u8 = undefined;
    var iw: binary.Writer = .{ .buf = &inner };
    try writeBag(&iw, bag[0..], true);
    const blob = iw.written();
    if (blob.len > 65535) return error.Overflow;

    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    try w.writeU16(@intCast(blob.len));
    try w.writeBytes(blob);
    return w.written();
}

pub fn peekBagEntityId(body: []const u8) binary.ReadError!i32 {
    if (body.len < 4) return error.EndOfStream;
    return std.mem.readInt(i32, body[0..4], .little);
}

/// Apply NetPackageBag body into inventory bag (player_bag_only) or full slots.
pub fn applyBagPackage(
    body: []const u8,
    inv: *components.Inventory,
    reverse: ?ReverseResolver,
    ctx: ?*anyopaque,
    player_bag_only: bool,
) binary.ReadError!i32 {
    var r: binary.Reader = .{ .data = body };
    const entity_id = try r.readI32();
    const blob_len = try r.readU16();
    if (r.remaining() < blob_len) return error.EndOfStream;
    const blob = r.data[r.pos .. r.pos + blob_len];
    r.pos += blob_len;

    var br: binary.Reader = .{ .data = blob };
    const bag_ver = try br.readByte();
    const bag_n = try br.readU16();

    if (player_bag_only) {
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = try readItemStack(&br);
            if (i < components.inv_bag_count) {
                inv.slots[components.inv_bag_start + i] = toEcs(s, reverse, ctx);
            }
        }
        while (i < components.inv_bag_count) : (i += 1) {
            inv.slots[components.inv_bag_start + i] = .{};
        }
    } else {
        // Loot: clear all, fill from start
        inv.clear();
        var i: usize = 0;
        while (i < bag_n) : (i += 1) {
            const s = try readItemStack(&br);
            if (i < components.max_inv_slots) {
                inv.slots[i] = toEcs(s, reverse, ctx);
            }
        }
    }

    const has_locked = try br.readBool();
    if (has_locked) try skipPackedBoolArray(&br);
    if (bag_ver >= 1 and br.remaining() >= 1) {
        _ = try br.readBool(); // touched
        if (br.remaining() >= 1) {
            const has_prefs = try br.readBool();
            _ = has_prefs;
        }
    }
    return entity_id;
}

// --- NetPackageDropItemsContainer ---
// droppedByID i32 | containerEntity string | Vector3 | u16 count | ItemStack*n
// (write uses WriteItemStack loop, same as GameUtils list but count is u16 of array len)

pub const DropItemsParsed = struct {
    dropped_by: i32,
    x: f32,
    y: f32,
    z: f32,
    items: [32]StockSlot = [_]StockSlot{.{}} ** 32,
    item_count: usize = 0,
};

pub fn writeDropItemsContainer(
    buf: []u8,
    dropped_by: i32,
    container_entity: []const u8,
    x: f32,
    y: f32,
    z: f32,
    items: []const StockSlot,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(dropped_by);
    try w.writeString(container_entity);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeU16(@intCast(items.len));
    for (items) |s| try writeItemStack(&w, s);
    return w.written();
}

pub fn readDropItemsContainer(body: []const u8) binary.ReadError!DropItemsParsed {
    var r: binary.Reader = .{ .data = body };
    var out: DropItemsParsed = .{
        .dropped_by = try r.readI32(),
        .x = 0,
        .y = 0,
        .z = 0,
    };
    try r.skipString(); // container entity class name
    out.x = try r.readF32();
    out.y = try r.readF32();
    out.z = try r.readF32();
    const n = try r.readU16();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = try readItemStack(&r);
        if (i < out.items.len) {
            out.items[i] = s;
            out.item_count += 1;
        }
    }
    return out;
}

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
    try writeItemValue(&w, .{
        .type_id = items_start_here + 8,
        .count = 1,
        .quality = 1,
        .meta = 0,
        .seed = 42,
    });
    const b = w.written();
    try std.testing.expectEqual(@as(u8, 9), b[0]); // save version
    try std.testing.expectEqual(@as(u8, 1), b[1]); // flags: is item
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, b[2..4], .little));
    // UseTimes f32 @4, Quality u16 @8, Meta u16 @10, meta_count @12
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b[8..10], .little));
    try std.testing.expectEqual(@as(u8, 0), b[12]); // metadata count
    try std.testing.expectEqual(@as(u8, 0), b[13]); // mods
    try std.testing.expectEqual(@as(u8, 0), b[14]); // cosmetics
    try std.testing.expectEqual(@as(u8, 0), b[15]); // activated
    try std.testing.expectEqual(@as(u8, 0), b[16]); // ammo
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
    // reverse: stock type 65536+id → id (matches typeFromBuiltinId)
    const rev = struct {
        fn f(_: ?*anyopaque, st: i32) u16 {
            if (st >= items_start_here) {
                const rel = st - items_start_here;
                if (rel > 0 and rel < 100) return @intCast(rel);
            }
            return 0;
        }
    }.f;
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

test "bag package roundtrip player bag slots" {
    var buf: [8192]u8 = undefined;
    var inv: components.Inventory = .{};
    inv.slots[10] = .{ .item_id = 7, .count = 15, .quality = 1 };
    inv.slots[11] = .{ .item_id = 3, .count = 30, .quality = 1 };
    const body = try buildBagPackage(&buf, 42, &inv, null, null, true);
    var inv2: components.Inventory = .{};
    const rev = struct {
        fn f(_: ?*anyopaque, st: i32) u16 {
            if (st >= items_start_here) {
                const rel = st - items_start_here;
                if (rel > 0 and rel < 100) return @intCast(rel);
            }
            return 0;
        }
    }.f;
    const eid = try applyBagPackage(body, &inv2, rev, null, true);
    try std.testing.expectEqual(@as(i32, 42), eid);
    try std.testing.expectEqual(@as(u16, 7), inv2.slots[10].item_id);
    try std.testing.expectEqual(@as(u16, 15), inv2.slots[10].count);
    try std.testing.expectEqual(@as(u16, 3), inv2.slots[11].item_id);
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
    try std.testing.expectEqual(@as(f32, 1.5), p.x);
    try std.testing.expectEqual(@as(usize, 2), p.item_count);
    try std.testing.expectEqual(@as(u16, 5), p.items[0].count);
}
