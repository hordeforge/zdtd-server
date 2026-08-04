//! ECS package root: SoA world, components, systems, resources.
//!
//! Dependency direction: may import util and assets (catalog lookups). Must not
//! import wire, server, world, or litenet. Wire/world may use pure component
//! types from here.

pub const entity = @import("entity.zig");
pub const components = @import("components.zig");
pub const world = @import("world.zig");
pub const systems = @import("systems.zig");
pub const quest = @import("quest.zig");
pub const electric = @import("electric.zig");
pub const powerblocks = @import("powerblocks.zig");
pub const aidirector = @import("aidirector.zig");
pub const path = @import("path.zig");
pub const interest = @import("interest.zig");
pub const inventory = @import("inventory.zig");
pub const inv_ledger = @import("inv_ledger.zig");
pub const query = @import("query.zig");
pub const command = @import("command.zig");

pub const World = world.World;
pub const Slot = world.Slot;
pub const Kind = components.Kind;
pub const Mask = components.Mask;
pub const max_entities = world.max_entities;
pub const InvLedger = inv_ledger.Ledger;
pub const InvCause = inv_ledger.Cause;
pub const CommandBuffer = command.Buffer;
pub const CommandOp = command.Op;

pub const forEachAlive = query.forEachAlive;
pub const forEachWith = query.forEachWith;
pub const forEachKind = query.forEachKind;
pub const maskMatches = query.maskMatches;

test {
    _ = entity;
    _ = components;
    _ = world;
    _ = systems;
    _ = quest;
    _ = electric;
    _ = powerblocks;
    _ = aidirector;
    _ = path;
    _ = interest;
    _ = inventory;
    _ = inv_ledger;
    _ = query;
    _ = command;
}
