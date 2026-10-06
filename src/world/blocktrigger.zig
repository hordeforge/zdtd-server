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
