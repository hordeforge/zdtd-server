//! ECS package root: SoA world, components, systems, resources.

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

pub const World = world.World;
pub const Slot = world.Slot;
pub const Kind = components.Kind;
pub const Mask = components.Mask;
pub const max_entities = world.max_entities;

test {
    _ = world;
    _ = systems;
    _ = quest;
    _ = electric;
    _ = powerblocks;
    _ = aidirector;
    _ = path;
    _ = interest;
    _ = inventory;
    _ = @import("../util/parallel.zig");
}
