//! Buff runtime rules: stacking, duration ticks, expiry. Pure over BuffSet, no
//! World and no wire. Every rule mirrors stock EntityBuffs/BuffClass/BuffValue,
//! because the client ticks its own copy of the same buff (EntityAlive::
//! OnUpdateEntity, asm.il 445737): any deviation makes the HUD icon and timer
//! disappear at a different moment than the server thinks it did.

const std = @import("std");
const c = @import("components.zig");

pub const BuffSet = c.BuffSet;
pub const BuffInstance = c.BuffInstance;
pub const StackType = c.StackType;

/// "Use the buff's own BuffClass duration". Any value >= 0 sent on the wire
/// calls BuffClass::set_DurationMax on the client, which retunes the shared
/// class for every entity for the session (asm.il 736259 IL_00cf / 732658).
pub const duration_from_class: f32 = -1;

/// The BuffClass fields a tick needs, resolved from buffs.xml by the caller.
pub const Def = struct {
    def_id: u16,
    /// BuffClass::InitialDurationMax in seconds; <= 0 never expires.
    duration: f32 = 0,
    stack_type: StackType = .ignore,
    update_rate_ticks: i32 = 20,
    remove_on_death: bool = true,
};

pub const AddResult = enum {
    /// New BuffValue appended to ActiveBuffs.
    added,
    /// Already present: the stack rule ran, no new instance.
    stacked,
    /// ActiveBuffs is full (stock's list is unbounded, ours is not).
    no_slot,
};

/// EntityBuffs::AddBuff (asm.il 736259). Immunity, editor, RequiredGameStat and
/// FriendlyFireCheck gates are client-side concerns and are deliberately absent.
pub fn add(
    set: *BuffSet,
    def: Def,
    requested_duration: f32,
    instigator_id: i32,
    ix: i32,
    iy: i32,
    iz: i32,
) AddResult {
    // NaN takes the "< 0" path in stock too (blt.un at IL_0154 / IL_0244).
    const has_requested = requested_duration >= 0;
    if (set.find(def.def_id)) |e| {
        // IL_00c6: a wire duration >= 0 overrides DurationMax before the switch.
        if (has_requested) e.duration_max = requested_duration;
        switch (def.stack_type) {
            // IL_0101: revive an instance already flagged for removal, else nothing.
            .ignore => e.flags.remove = false,
            // IL_013a: extend by whatever is left, floored at the class duration.
            .duration => {
                const remaining = requested_duration - e.durationSeconds();
                const max_secs = @max(if (has_requested) requested_duration else def.duration, remaining);
                setDurationTicks(e, 0);
                e.duration_max = max_secs;
            },
            // IL_0196: Mathf.Clamp(mult + 1, 0, 255) (asm.il 733342).
            .effect => e.stack_mult +|= 1,
            // IL_011a: restart the timer, keep everything else.
            .replace => setDurationTicks(e, 0),
        }
        return .stacked;
    }

    const free = set.findFree() orelse return .no_slot;
    free.* = .{
        .active = true,
        .def_id = def.def_id,
        .stack_mult = 1,
        .flags = .{},
        .duration_ticks = 0,
        .update_ticks = 0,
        .update_rate_ticks = def.update_rate_ticks,
        // IL_023d: requested when >= 0, else the class InitialDurationMax.
        .duration_max = if (has_requested) requested_duration else def.duration,
        .remove_on_death = def.remove_on_death,
        .instigator_id = instigator_id,
        .instigator_x = ix,
        .instigator_y = iy,
        .instigator_z = iz,
    };
    return .added;
}

/// EntityBuffs::RemoveBuff (asm.il 736646): flags for removal, the next tick
/// does the removing. Returns true when an active instance was flagged.
pub fn remove(set: *BuffSet, def_id: u16) bool {
    const e = set.find(def_id) orelse return false;
    e.flags.remove = true;
    return true;
}

/// BuffValue::set_DurationInTicks (asm.il 733385) also truncates into updateTicks.
fn setDurationTicks(e: *BuffInstance, ticks: u32) void {
    e.duration_ticks = ticks;
    e.update_ticks = @truncate(ticks);
}

/// One entity's expired/removed buff, reported so the net layer can tell
/// observers without ecs importing the wire.
pub const Removed = struct {
    def_id: u16 = 0,
};

/// A removal attributed to an entity, for the tick result the net layer drains.
pub const Expiry = struct {
    entity_id: i32 = 0,
    def_id: u16 = 0,
};

/// EntityBuffs::Tick (asm.il 735832) in stock order: drop Invalid, Finished
/// raises Remove, Remove fires and deletes, Paused and dead skip, first tick
/// raises Started, then BuffValue::Tick advances the duration.
/// Returns the number of instances removed, writing their def ids into `out`.
pub fn tick(set: *BuffSet, dead: bool, out: []Removed) u8 {
    var n: u8 = 0;
    for (&set.slots) |*e| {
        if (!e.active) continue;
        if (e.flags.invalid) {
            e.* = .{};
            continue;
        }
        if (e.flags.finished) e.flags.remove = true;
        if (e.flags.remove) {
            if (n < out.len) {
                out[n] = .{ .def_id = e.def_id };
                n += 1;
            }
            e.* = .{};
            continue;
        }
        if (e.flags.paused) continue;
        if (dead) continue;
        e.flags.started = true;
        durationTick(e);
        // BuffClass::Tick (asm.il 732754): DurationMax <= 0 never expires.
        if (e.duration_max > 0 and e.durationSeconds() >= e.duration_max) e.flags.finished = true;
        // The Update event fires and clears within the same tick (IL_01cc).
        // We have no triggered_effect VM, so it is only ever observed clear.
        e.flags.update = false;
    }
    return n;
}

/// BuffValue::DurationTick (asm.il 733398). Both counters wrap in stock
/// (unchecked add + conv.u2), so saturating here would diverge.
fn durationTick(e: *BuffInstance) void {
    e.duration_ticks +%= 1;
    e.update_ticks +%= 1;
    if (e.update_ticks >= e.update_rate_ticks) {
        e.flags.update = true;
        e.update_ticks = 0;
    }
}

/// BuffClass::RemoveOnDeath (asm.il 1371585): the client drops these itself when
/// the entity dies, so the server clears them silently rather than broadcasting.
pub fn clearOnDeath(set: *BuffSet) u8 {
    var n: u8 = 0;
    for (&set.slots) |*e| {
        if (!e.active or !e.remove_on_death) continue;
        e.* = .{};
        n += 1;
    }
    return n;
}

const shocked: Def = .{ .def_id = 1, .duration = 4, .stack_type = .duration, .update_rate_ticks = 20 };
const on_fire: Def = .{ .def_id = 2, .duration = 0, .stack_type = .ignore, .update_rate_ticks = 10 };
const harvest: Def = .{ .def_id = 3, .duration = 0, .stack_type = .effect, .remove_on_death = false };
const bleeding: Def = .{ .def_id = 4, .duration = 0, .stack_type = .replace };

fn addDefault(set: *BuffSet, def: Def) AddResult {
    return add(set, def, duration_from_class, -1, 0, 0, 0);
}

test "add stores the class duration when the wire duration is negative" {
    var set: BuffSet = .{};
    try std.testing.expectEqual(AddResult.added, addDefault(&set, shocked));
    const e = set.find(1).?;
    try std.testing.expectEqual(@as(f32, 4), e.duration_max);
    try std.testing.expectEqual(@as(u8, 1), e.stack_mult);
    try std.testing.expectEqual(@as(u32, 0), e.duration_ticks);
    try std.testing.expect(!e.flags.started);
    // A concrete duration overrides it (server never sends this to a client).
    var set2: BuffSet = .{};
    _ = add(&set2, shocked, 9, -1, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 9), set2.find(1).?.duration_max);
    // NaN takes the negative path, as in stock's unordered compare.
    var set3: BuffSet = .{};
    _ = add(&set3, shocked, std.math.nan(f32), -1, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 4), set3.find(1).?.duration_max);
}

test "stack ignore revives a pending removal and leaves the timer alone" {
    var set: BuffSet = .{};
    _ = addDefault(&set, on_fire);
    var removed: [4]Removed = undefined;
    _ = tick(&set, false, &removed);
    _ = tick(&set, false, &removed);
    try std.testing.expect(remove(&set, on_fire.def_id));
    try std.testing.expect(set.find(2).?.flags.remove);

    try std.testing.expectEqual(AddResult.stacked, addDefault(&set, on_fire));
    const e = set.find(2).?;
    try std.testing.expect(!e.flags.remove);
    // Ignore must not restart the timer: 73 stock buffs have no stack_type.
    try std.testing.expectEqual(@as(u32, 2), e.duration_ticks);
    try std.testing.expectEqual(@as(u8, 1), e.stack_mult);
}

test "stack replace restarts the timer without duplicating" {
    var set: BuffSet = .{};
    _ = addDefault(&set, bleeding);
    var removed: [4]Removed = undefined;
    var i: usize = 0;
    while (i < 30) : (i += 1) _ = tick(&set, false, &removed);
    try std.testing.expectEqual(@as(u32, 30), set.find(4).?.duration_ticks);

    try std.testing.expectEqual(AddResult.stacked, addDefault(&set, bleeding));
    try std.testing.expectEqual(@as(u8, 1), set.count());
    try std.testing.expectEqual(@as(u32, 0), set.find(4).?.duration_ticks);
    try std.testing.expectEqual(@as(u16, 0), set.find(4).?.update_ticks);
}

test "stack effect increments the multiplier and saturates at 255" {
    var set: BuffSet = .{};
    _ = addDefault(&set, harvest);
    _ = addDefault(&set, harvest);
    try std.testing.expectEqual(@as(u8, 2), set.find(3).?.stack_mult);
    set.find(3).?.stack_mult = 255;
    _ = addDefault(&set, harvest);
    // Mathf.Clamp(256, 0, 255) in stock (asm.il 733342): saturate, never wrap.
    try std.testing.expectEqual(@as(u8, 255), set.find(3).?.stack_mult);
}

test "stack duration extends by the remainder and resets the tick counter" {
    var set: BuffSet = .{};
    _ = addDefault(&set, shocked); // DurationMax 4 s
    var removed: [4]Removed = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) _ = tick(&set, false, &removed); // 1 s elapsed
    try std.testing.expectEqual(@as(f32, 1), set.find(1).?.durationSeconds());

    // Requested 10 s: remaining = 10 - 1 = 9 > requested 10? No, so max = 10.
    _ = add(&set, shocked, 10, -1, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 10), set.find(1).?.duration_max);
    try std.testing.expectEqual(@as(u32, 0), set.find(1).?.duration_ticks);

    // Negative request: base is InitialDurationMax (4) and remaining is
    // -1 - 0 = -1, so the class duration wins.
    var set2: BuffSet = .{};
    _ = addDefault(&set2, shocked);
    _ = addDefault(&set2, shocked);
    try std.testing.expectEqual(@as(f32, 4), set2.find(1).?.duration_max);
}

test "tick expires a buff exactly at DurationMax and reports it once" {
    var set: BuffSet = .{};
    _ = addDefault(&set, shocked); // 4 s = 80 ticks
    var removed: [4]Removed = undefined;

    var i: usize = 0;
    while (i < 79) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 0), tick(&set, false, &removed));
    }
    // Tick 80 reaches 4.0 s and flags Finished; the removal lands next tick,
    // matching stock's Finished → Remove → RemoveAt ordering.
    try std.testing.expectEqual(@as(u8, 0), tick(&set, false, &removed));
    try std.testing.expect(set.find(1).?.flags.finished);
    try std.testing.expectEqual(@as(u8, 1), tick(&set, false, &removed));
    try std.testing.expectEqual(@as(u16, 1), removed[0].def_id);
    try std.testing.expectEqual(@as(u8, 0), set.count());
    try std.testing.expectEqual(@as(u8, 0), tick(&set, false, &removed));
}

test "zero duration never expires and keeps ticking past the wrap point" {
    var set: BuffSet = .{};
    _ = addDefault(&set, on_fire); // duration 0
    var removed: [4]Removed = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) _ = tick(&set, false, &removed);
    try std.testing.expectEqual(@as(u8, 1), set.count());
    try std.testing.expect(!set.find(2).?.flags.finished);

    // durationTicks wraps in stock (unchecked add); so must ours.
    set.find(2).?.duration_ticks = std.math.maxInt(u32);
    _ = tick(&set, false, &removed);
    try std.testing.expectEqual(@as(u32, 0), set.find(2).?.duration_ticks);
}

test "update flag cycles on the class update rate" {
    var set: BuffSet = .{};
    _ = addDefault(&set, on_fire); // update_rate_ticks 10
    var removed: [4]Removed = undefined;
    var i: usize = 0;
    while (i < 9) : (i += 1) _ = tick(&set, false, &removed);
    try std.testing.expectEqual(@as(u16, 9), set.find(2).?.update_ticks);
    _ = tick(&set, false, &removed);
    // Fired and reset within the tick (asm.il 733398 IL_0034).
    try std.testing.expectEqual(@as(u16, 0), set.find(2).?.update_ticks);
    try std.testing.expect(!set.find(2).?.flags.update);
}

test "paused and dead entities do not advance the duration" {
    var set: BuffSet = .{};
    _ = addDefault(&set, shocked);
    var removed: [4]Removed = undefined;
    set.find(1).?.flags.paused = true;
    _ = tick(&set, false, &removed);
    try std.testing.expectEqual(@as(u32, 0), set.find(1).?.duration_ticks);
    try std.testing.expect(!set.find(1).?.flags.started);

    set.find(1).?.flags.paused = false;
    _ = tick(&set, true, &removed);
    try std.testing.expectEqual(@as(u32, 0), set.find(1).?.duration_ticks);
    // A dead entity still processes a pending removal.
    try std.testing.expect(remove(&set, 1));
    try std.testing.expectEqual(@as(u8, 1), tick(&set, true, &removed));
}

test "invalid instances vanish without a removal report" {
    var set: BuffSet = .{};
    _ = addDefault(&set, shocked);
    set.find(1).?.flags.invalid = true;
    var removed: [4]Removed = undefined;
    try std.testing.expectEqual(@as(u8, 0), tick(&set, false, &removed));
    try std.testing.expectEqual(@as(u8, 0), set.count());
}

test "a full buff set rejects new buffs but still stacks known ones" {
    var set: BuffSet = .{};
    var i: u16 = 0;
    while (i < c.max_buffs_per_entity) : (i += 1) {
        try std.testing.expectEqual(AddResult.added, addDefault(&set, .{ .def_id = i, .stack_type = .replace }));
    }
    try std.testing.expectEqual(AddResult.no_slot, addDefault(&set, .{ .def_id = 999 }));
    try std.testing.expectEqual(AddResult.stacked, addDefault(&set, .{ .def_id = 0, .stack_type = .replace }));
}

test "removal reports saturate at the caller's buffer" {
    var set: BuffSet = .{};
    var i: u16 = 0;
    while (i < c.max_buffs_per_entity) : (i += 1) {
        _ = addDefault(&set, .{ .def_id = i });
        _ = remove(&set, i);
    }
    var removed: [2]Removed = undefined;
    // All instances still go away; only the first two are reported.
    try std.testing.expectEqual(@as(u8, 2), tick(&set, false, &removed));
    try std.testing.expectEqual(@as(u8, 0), set.count());
}

test "clearOnDeath keeps buffs the client keeps" {
    var set: BuffSet = .{};
    _ = addDefault(&set, shocked); // remove_on_death default true
    _ = addDefault(&set, harvest); // remove_on_death false
    try std.testing.expectEqual(@as(u8, 1), clearOnDeath(&set));
    try std.testing.expectEqual(@as(u8, 1), set.count());
    try std.testing.expect(set.find(harvest.def_id) != null);
}

test "remove on an absent buff is a no-op" {
    var set: BuffSet = .{};
    try std.testing.expect(!remove(&set, 7));
    _ = addDefault(&set, shocked);
    try std.testing.expect(!remove(&set, 7));
    try std.testing.expectEqual(@as(u8, 1), set.count());
}
