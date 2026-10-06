//! Per-POI trigger wiring (stock `BlockTrigger`).
//!
//! Wiring metadata for one voxel inside a POI: which channels the block fires
//! when activated, which it listens on, and the latched input state. Grounded
//! in `../../7dtd-engine-research/docs/world/block-shapes.md` section 7 and
//! `BlockTrigger.il.txt:116` (the `Read` field order).
//!
//! Non-goals: the `TriggerManager` / `PrefabTriggerData` runtime registry and
//! `Block.OnTriggered` mutations. This is the record and its codec only.

const std = @import("std");

/// `BlockTrigger.TriggeredStates` (`BlockTrigger_TriggeredStates.il.txt`).
pub const TriggeredState = enum(u8) {
    not_triggered = 0,
    needs_triggered = 1,
    has_triggered = 2,
    _,
};

/// One voxel's trigger wiring (`BlockTrigger`).
pub const BlockTrigger = struct {
    /// Local position inside the chunk (`LocalChunkPos`).
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    /// Channels this block fires when activated (`TriggersIndices`).
    triggers: [max_channels]u8 = .{0} ** max_channels,
    triggers_n: u8 = 0,
    /// Channels this block listens on (`TriggeredByIndices`).
    triggered_by: [max_channels]u8 = .{0} ** max_channels,
    triggered_by_n: u8 = 0,
    /// Channels currently toggled on (`TriggeredValues`, latched inputs).
    triggered_values: [max_channels]u8 = .{0} ** max_channels,
    triggered_values_n: u8 = 0,
    /// Deferred-fire latch (`NeedsTriggered`).
    needs_triggered: TriggeredState = .not_triggered,
    /// `ExcludeIcon`: editor icon suppression (v>=3).
    exclude_icon: bool = false,
    /// `UseOrForMultipleTriggers`: OR vs AND over the listened channels (v>=4).
    use_or: bool = false,
    /// `Unlock` (v>=5).
    unlock: bool = false,

    /// `BlockTrigger.HasAnyTriggers` (IL=6): the gate in
    /// `TriggerManager.TriggerBlocks`.
    pub fn hasAnyTriggers(self: *const BlockTrigger) bool {
        return self.triggers_n > 0;
    }

    /// `UseOrForMultipleTriggers` (block-shapes.md 7.1): the AND/OR combine
    /// over the listened channels. A single listen channel is always "on"
    /// when that channel is latched, regardless of the flag.
    pub fn isOn(self: *const BlockTrigger) bool {
        if (self.triggered_by_n == 0) return true;
        var i: usize = 0;
        while (i < self.triggered_by_n) : (i += 1) {
            const latched = self.isLatched(self.triggered_by[i]);
            if (self.use_or) {
                if (latched) return true;
            } else {
                if (!latched) return false;
            }
        }
        return !self.use_or;
    }

    /// `SetTriggeredValueFlag` (`BlockTrigger.OnTriggered` IL=27): latch the
    /// fired channel. Returns false when the channel is not one this block
    /// listens on, which is an out-of-wiring claim.
    pub fn latch(self: *BlockTrigger, channel: u8) bool {
        var listens = false;
        for (self.triggered_by[0..self.triggered_by_n]) |c| {
            if (c == channel) {
                listens = true;
                break;
            }
        }
        if (!listens) return false;
        if (self.isLatched(channel)) return true;
        if (self.triggered_values_n >= max_channels) return false;
        self.triggered_values[self.triggered_values_n] = channel;
        self.triggered_values_n += 1;
        return true;
    }

    /// `Block.OnTriggerAddedFromPrefab` (`BlockActivateSwitch`, block-shapes.md
    /// 7.1): the stamp normalizer. A switch is "on" (meta bit 0) only when its
    /// trigger has no `TriggeredBy` wiring - a wired switch starts off and is
    /// flipped by a trigger, an unwired one starts on. Returns the meta bit to
    /// OR into the block word.
    pub fn switchMetaBit(self: *const BlockTrigger) u32 {
        return if (self.triggered_by_n == 0) 1 else 0;
    }

    /// `BlockHazard.SetHazardState` / `BlockLight.SetLightState`
    /// (block-shapes.md 7.3): the shared state bit. `(meta & ~3) | (isOn ? 2
    /// : 0)` writes meta bit 1 as the on/off flag for trigger, light and
    /// hazard alike. `meta` is the block word's meta bits; the return is the
    /// new meta.
    pub fn setOnState(meta: u32, is_on: bool) u32 {
        const bit: u32 = if (is_on) 2 else 0;
        return (meta & ~@as(u32, 3)) | bit;
    }

    /// `BlockHazard.IsHazardOn` / `BlockLight.IsLightOn`
    /// (block-shapes.md 7.3): meta bit 1 is the shared on/off flag.
    pub fn isOnState(meta: u32) bool {
        return (meta & 2) != 0;
    }

    /// `BlockActivateSwitch.OnTriggered` (IL=24, block-shapes.md 7.3): the
    /// switch toggle. `(meta & ~2) | 1` clears bit 1 and sets bit 0, so a
    /// trigger firing flips the switch to "on" regardless of its prior state.
    /// `meta` is the block word's meta bits; the return is the new meta.
    pub fn switchToggleMeta(meta: u32) u32 {
        return (meta & ~@as(u32, 2)) | 1;
    }

    /// `BlockTrigger.OnTriggered` clears `TriggeredValues` after the
    /// combination fires.
    pub fn clearLatched(self: *BlockTrigger) void {
        self.triggered_values_n = 0;
    }

    /// `TriggeredValues` (block-shapes.md 7.1): the channels currently
    /// toggled on (latched inputs).
    pub fn isLatched(self: *const BlockTrigger, channel: u8) bool {
        for (self.triggered_values[0..self.triggered_values_n]) |v| {
            if (v == channel) return true;
        }
        return false;
    }
};

/// Channel indices are bytes (the prefab editor's trigger layers).
pub const max_channels: usize = 8;

/// `BlockTrigger.Read` (`BlockTrigger.il.txt:116`). The record is versioned;
/// the current writer emits 5.
pub fn read(r: *std.Io.Reader) !BlockTrigger {
    var out: BlockTrigger = .{};
    const version = try r.takeInt(u16, .little);
    if (version >= 2) out.needs_triggered = @enumFromInt(try r.takeByte());
    out.triggers_n = try r.takeByte();
    if (out.triggers_n > max_channels) return error.InvalidData;
    for (out.triggers[0..out.triggers_n]) |*c| c.* = try r.takeByte();
    out.triggered_by_n = try r.takeByte();
    if (out.triggered_by_n > max_channels) return error.InvalidData;
    for (out.triggered_by[0..out.triggered_by_n]) |*c| c.* = try r.takeByte();
    out.triggered_values_n = try r.takeByte();
    if (out.triggered_values_n > max_channels) return error.InvalidData;
    for (out.triggered_values[0..out.triggered_values_n]) |*c| c.* = try r.takeByte();
    if (version >= 3) out.exclude_icon = (try r.takeByte()) != 0;
    if (version >= 4) out.use_or = (try r.takeByte()) != 0;
    if (version >= 5) out.unlock = (try r.takeByte()) != 0;
    return out;
}

/// `Prefab.readTriggerData` (`Prefab.il.txt:5210`): `i16 count`, then per
/// entry `i16 blob_len`, `Vector3i local_pos`, then `blob_len` bytes of
/// `BlockTrigger.Read`. The wrapper is the prefab's per-POI trigger table.
pub const TriggerTable = struct {
    entries: [max_triggers]BlockTrigger = [_]BlockTrigger{.{}} ** max_triggers,
    n: u16 = 0,

    /// `Chunk.GetBlockTrigger(localPos)` shape: the wiring at a local cell, or
    /// null when the POI has none there.
    pub fn at(self: *const TriggerTable, x: i32, y: i32, z: i32) ?*const BlockTrigger {
        for (self.entries[0..self.n]) |*e| {
            if (e.x == x and e.y == y and e.z == z) return e;
        }
        return null;
    }
};

/// One POI's trigger table is bounded by its voxel count; 256 is far above any
/// shipped prefab's wiring (the editor's trigger layers are sparse).
pub const max_triggers: usize = 256;

/// `Prefab.readTriggerData` (`Prefab.il.txt:5210`).
pub fn readTriggerTable(r: *std.Io.Reader) !TriggerTable {
    var out: TriggerTable = .{};
    const count = try r.takeInt(i16, .little);
    if (count < 0 or count > max_triggers) return error.InvalidData;
    var i: i16 = 0;
    while (i < count) : (i += 1) {
        const blob_len = try r.takeInt(i16, .little);
        if (blob_len < 0) return error.InvalidData;
        var pos: [12]u8 = undefined;
        _ = try r.readSliceAll(&pos);
        const x = std.mem.readInt(i32, pos[0..4], .little);
        const y = std.mem.readInt(i32, pos[4..8], .little);
        const z = std.mem.readInt(i32, pos[8..12], .little);
        var blob: [256]u8 = undefined;
        const bl: usize = @intCast(blob_len);
        if (bl > blob.len) return error.InvalidData;
        _ = try r.readSliceAll(blob[0..bl]);
        var br = std.Io.Reader.fixed(blob[0..bl]);
        var bt = try read(&br);
        bt.x = x;
        bt.y = y;
        bt.z = z;
        out.entries[out.n] = bt;
        out.n += 1;
    }
    return out;
}

test "BlockTrigger.Read follows the pinned field order" {
    // v5 record: needs_triggered=1, one fire channel (3), two listen channels
    // (4,5), one latched value (4), exclude_icon=false, use_or=true, unlock=false.
    const body = [_]u8{
        5, 0, // version 5
        1, // NeedsTriggered
        1, 3, // TriggersIndices
        2, 4, 5, // TriggeredByIndices
        1, 4, // TriggeredValues
        0, // ExcludeIcon
        1, // UseOrForMultipleTriggers
        0, // Unlock
    };
    var r = std.Io.Reader.fixed(&body);
    const t = try read(&r);
    try std.testing.expectEqual(TriggeredState.needs_triggered, t.needs_triggered);
    try std.testing.expectEqual(@as(u8, 1), t.triggers_n);
    try std.testing.expectEqual(@as(u8, 3), t.triggers[0]);
    try std.testing.expectEqual(@as(u8, 2), t.triggered_by_n);
    try std.testing.expectEqual(@as(u8, 5), t.triggered_by[1]);
    try std.testing.expectEqual(@as(u8, 1), t.triggered_values_n);
    try std.testing.expect(!t.exclude_icon);
    try std.testing.expect(t.use_or);
    try std.testing.expect(!t.unlock);
    try std.testing.expect(t.hasAnyTriggers());
}

test "the shared on/off state bit is meta bit 1" {
    // `BlockHazard.SetHazardState` / `BlockLight.SetLightState`
    // (block-shapes.md 7.3): `(meta & ~3) | (isOn ? 2 : 0)`. `IsHazardOn` /
    // `IsLightOn` test `(meta & 2) != 0`. Trigger, light and hazard share the
    // bit.
    try std.testing.expectEqual(@as(u32, 2), BlockTrigger.setOnState(0, true));
    try std.testing.expectEqual(@as(u32, 0), BlockTrigger.setOnState(2, false));
    // Bits above the two low ones survive.
    try std.testing.expectEqual(@as(u32, 0xC | 2), BlockTrigger.setOnState(0xC, true));
    try std.testing.expect(BlockTrigger.isOnState(2));
    try std.testing.expect(!BlockTrigger.isOnState(1));
    try std.testing.expect(BlockTrigger.isOnState(0xC | 2));
}

test "the switch toggle sets meta bit 0 and clears bit 1" {
    // `BlockActivateSwitch.OnTriggered` (IL=24, block-shapes.md 7.3):
    // `(meta & ~2) | 1` clears bit 1 and sets bit 0, so a trigger firing flips
    // the switch to "on" regardless of its prior state.
    try std.testing.expectEqual(@as(u32, 1), BlockTrigger.switchToggleMeta(0));
    try std.testing.expectEqual(@as(u32, 1), BlockTrigger.switchToggleMeta(1));
    try std.testing.expectEqual(@as(u32, 1), BlockTrigger.switchToggleMeta(2));
    // Other meta bits survive.
    try std.testing.expectEqual(@as(u32, 5), BlockTrigger.switchToggleMeta(4));
    // Bit 1 is cleared by the toggle, so a word with it set loses it.
    try std.testing.expectEqual(@as(u32, 0b1101), BlockTrigger.switchToggleMeta(0b1111));
}

test "a switch is on only when its trigger has no TriggeredBy wiring" {
    // `Block.OnTriggerAddedFromPrefab` (`BlockActivateSwitch`, block-shapes.md
    // 7.1): meta bit 0 is "on" only when the trigger has no `TriggeredBy`
    // wiring. An unwired switch starts on; a wired one starts off and is
    // flipped by a trigger.
    var bt: BlockTrigger = .{};
    try std.testing.expectEqual(@as(u32, 1), bt.switchMetaBit());
    bt.triggered_by = .{4} ++ .{0} ** 7;
    bt.triggered_by_n = 1;
    try std.testing.expectEqual(@as(u32, 0), bt.switchMetaBit());
}

test "latch records a fired channel and rejects an out-of-wiring claim" {
    // `BlockTrigger.OnTriggered` (IL=27): latch the fired channel, combine,
    // and clear `TriggeredValues` after the combination fires. A channel the
    // block does not listen on is an out-of-wiring claim and is refused.
    var bt: BlockTrigger = .{};
    bt.triggered_by = .{ 4, 5, 0, 0, 0, 0, 0, 0 };
    bt.triggered_by_n = 2;
    try std.testing.expect(bt.latch(4));
    try std.testing.expect(bt.isLatched(4));
    // Two listen channels, AND mode: one latched is not enough.
    try std.testing.expect(!bt.isOn());
    // Latching twice is idempotent.
    try std.testing.expect(bt.latch(4));
    try std.testing.expectEqual(@as(u8, 1), bt.triggered_values_n);
    // A channel this block does not listen on is refused.
    try std.testing.expect(!bt.latch(9));
    try std.testing.expectEqual(@as(u8, 1), bt.triggered_values_n);
    // Latch the second channel: now the AND fires.
    try std.testing.expect(bt.latch(5));
    try std.testing.expect(bt.isOn());
    // After the combination fires the latches clear.
    bt.clearLatched();
    try std.testing.expectEqual(@as(u8, 0), bt.triggered_values_n);
    try std.testing.expect(!bt.isOn());
}

test "the AND/OR combine over the listened channels (UseOrForMultipleTriggers)" {
    // `UseOrForMultipleTriggers` (block-shapes.md 7.1): OR fires when any
    // listened channel is latched, AND when all are. A single channel is
    // always "on" when it is latched.
    var bt: BlockTrigger = .{};
    bt.triggered_by = .{ 4, 5, 0, 0, 0, 0, 0, 0 };
    bt.triggered_by_n = 2;
    // No latched inputs: AND is off, OR is off.
    try std.testing.expect(!bt.isOn());
    bt.use_or = true;
    try std.testing.expect(!bt.isOn());
    // One latched: OR fires, AND does not.
    bt.triggered_values = .{4} ++ .{0} ** 7;
    bt.triggered_values_n = 1;
    try std.testing.expect(bt.isOn());
    bt.use_or = false;
    try std.testing.expect(!bt.isOn());
    // Both latched: both fire.
    bt.triggered_values = .{ 4, 5, 0, 0, 0, 0, 0, 0 };
    bt.triggered_values_n = 2;
    try std.testing.expect(bt.isOn());
    bt.use_or = true;
    try std.testing.expect(bt.isOn());
    // A single listen channel is "on" when it is latched, flag or no flag.
    bt.triggered_by_n = 1;
    bt.triggered_values = .{4} ++ .{0} ** 7;
    bt.triggered_values_n = 1;
    bt.use_or = false;
    try std.testing.expect(bt.isOn());
    // No listen channels: always on (the block is a pure source).
    bt.triggered_by_n = 0;
    try std.testing.expect(bt.isOn());
}

test "readTriggerTable follows the pinned wrapper format" {
    // One entry: blob_len=10, pos=(1,2,3), then the v5 BlockTrigger body.
    const body = [_]u8{
        1, 0, // i16 count
        10, 0, // i16 blob_len
        1, 0, 0, 0, // x
        2, 0, 0, 0, // y
        3, 0, 0, 0, // z
        // BlockTrigger v5: version, needs, triggers_n, trigger,
        // triggered_by_n, triggered_values_n, exclude, use_or, unlock
        5, 0, 0, 1, 7, 0, 0, 0, 0, 0,
    };
    var r = std.Io.Reader.fixed(&body);
    const tbl = try readTriggerTable(&r);
    try std.testing.expectEqual(@as(u16, 1), tbl.n);
    const e = tbl.at(1, 2, 3).?;
    try std.testing.expectEqual(@as(u8, 1), e.triggers_n);
    try std.testing.expectEqual(@as(u8, 7), e.triggers[0]);
    try std.testing.expect(tbl.at(9, 9, 9) == null);
}
