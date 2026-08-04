//! Fixed on_spawn / on_death listener table. Cap 4. No heap.
//! World fires via fireSpawn / fireDeath; listeners must not spawn/destroy
//! unbounded or re-enter tick (keep side effects light).

const World = @import("world.zig").World;
const Slot = @import("entity.zig").Slot;
const NetId = @import("entity.zig").NetId;

pub const max_listeners: usize = 4;

pub const SpawnFn = *const fn (*World, Slot, NetId) void;
pub const DeathFn = *const fn (*World, Slot, NetId) void;

pub const Registry = struct {
    on_spawn: [max_listeners]?SpawnFn = .{null} ** max_listeners,
    on_death: [max_listeners]?DeathFn = .{null} ** max_listeners,

    pub fn addSpawn(self: *Registry, f: SpawnFn) bool {
        for (&self.on_spawn) |*slot| {
            if (slot.* == null) {
                slot.* = f;
                return true;
            }
        }
        return false;
    }

    pub fn addDeath(self: *Registry, f: DeathFn) bool {
        for (&self.on_death) |*slot| {
            if (slot.* == null) {
                slot.* = f;
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *Registry) void {
        self.on_spawn = .{null} ** max_listeners;
        self.on_death = .{null} ** max_listeners;
    }

    pub fn fireSpawn(self: *const Registry, w: *World, slot: Slot, id: NetId) void {
        for (self.on_spawn) |opt| {
            if (opt) |f| f(w, slot, id);
        }
    }

    pub fn fireDeath(self: *const Registry, w: *World, slot: Slot, id: NetId) void {
        for (self.on_death) |opt| {
            if (opt) |f| f(w, slot, id);
        }
    }
};

const std = @import("std");

test "observers spawn death cap" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);

    var spawn_n: u32 = 0;
    var death_n: u32 = 0;
    const H = struct {
        sn: *u32,
        dn: *u32,
        fn onSpawn(_: *World, _: Slot, _: NetId) void {}
        fn onDeath(_: *World, _: Slot, _: NetId) void {}
    };
    _ = H;

    const sn = &spawn_n;
    const dn = &death_n;
    const Spawn = struct {
        var c: *u32 = undefined;
        fn f(_: *World, _: Slot, _: NetId) void {
            c.* += 1;
        }
    };
    const Death = struct {
        var c: *u32 = undefined;
        fn f(_: *World, _: Slot, _: NetId) void {
            c.* += 1;
        }
    };
    Spawn.c = sn;
    Death.c = dn;

    try std.testing.expect(w.observers.addSpawn(Spawn.f));
    try std.testing.expect(w.observers.addDeath(Death.f));
    try std.testing.expect(w.observers.addSpawn(Spawn.f));
    try std.testing.expect(w.observers.addSpawn(Spawn.f));
    try std.testing.expect(w.observers.addSpawn(Spawn.f));
    try std.testing.expect(!w.observers.addSpawn(Spawn.f));

    const z = w.spawnZombie(0, 70, 0, 40).?;
    try std.testing.expectEqual(@as(u32, 4), spawn_n);
    const s = w.slotOfNetId(z).?;
    w.destroy(s);
    try std.testing.expectEqual(@as(u32, 1), death_n);
}
