//! ECS package root: SoA world, components, systems, resources.
//!
//! Dependency direction: may import util only. Must not import wire, server,
//! world, assets, litenet, or apm. Wire/world/assets may import pure types from
//! here (components, QuestKind, InvSlot) for catalog → sim mapping; that
//! assets→ecs edge is intentional and one-way for pure shapes only. Offline
//! inv fixtures live in inventory.zig (no assets import) so the graph stays
//! acyclic.

pub const entity = @import("entity.zig");
pub const components = @import("components.zig");
pub const world = @import("world.zig");
pub const systems = @import("systems.zig");
pub const quest = @import("quest.zig");
pub const poi_lock = @import("poi_lock.zig");
pub const buff = @import("buff.zig");
pub const electric = @import("electric.zig");
pub const powerblocks = @import("powerblocks.zig");
pub const aidirector = @import("aidirector.zig");
pub const party = @import("party.zig");
pub const rules = @import("rules.zig");
pub const path = @import("path.zig");
pub const interest = @import("interest.zig");
pub const inventory = @import("inventory.zig");
pub const inv_ledger = @import("inv_ledger.zig");
pub const query = @import("query.zig");
pub const group = @import("group.zig");
pub const command = @import("command.zig");
pub const res = @import("res.zig");
pub const snapshot = @import("snapshot.zig");
pub const locals = @import("locals.zig");
pub const schedule = @import("schedule.zig");
pub const jobs = @import("jobs.zig");
pub const observers = @import("observers.zig");
pub const sim_view = @import("sim_view.zig");

pub const World = world.World;
pub const Slot = world.Slot;
pub const Kind = components.Kind;
pub const max_entities = world.max_entities;
pub const TickResult = schedule.TickResult;

pub const groupSlice = query.groupSlice;

test {
    _ = entity;
    _ = components;
    _ = world;
    _ = systems;
    _ = quest;
    _ = poi_lock;
    _ = buff;
    _ = electric;
    _ = powerblocks;
    _ = aidirector;
    _ = party;
    _ = rules;
    _ = path;
    _ = interest;
    _ = inventory;
    _ = inv_ledger;
    _ = query;
    _ = group;
    _ = command;
    _ = res;
    _ = locals;
    _ = schedule;
    _ = jobs;
    _ = observers;
    _ = sim_view;
    _ = snapshot;
}
