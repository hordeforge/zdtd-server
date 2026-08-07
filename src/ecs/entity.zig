//! Entity handles for the sim ECS.

pub const max_entities: usize = 512;

/// Dense slot index 0..max_entities-1 when alive; never 0 as a live id (ids start at 100 historically).
/// We keep public network entity ids as i32 (spawned monotically) separate from ECS slots.
pub const Slot = u16;

pub const invalid_slot: Slot = std.math.maxInt(Slot);

const std = @import("std");

/// Network-facing entity id (stable for wire packages).
pub const NetId = i32;

/// Slot + generation for internal handles that must not alias after recycle.
pub const EntityHandle = struct {
    slot: Slot = invalid_slot,
    gen: u32 = 0,

    pub fn invalid() EntityHandle {
        return .{};
    }
};
