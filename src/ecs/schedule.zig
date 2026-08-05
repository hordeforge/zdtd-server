//! Explicit sim pipeline phases. Ordered only; parallel stays inside a phase
//! (systemZombieAi / systemTurrets via util/parallel). No access-set scheduler.

const World = @import("world.zig").World;
const systems = @import("systems.zig");

/// Named tick phases (document order = run order).
pub const Phase = enum(u8) {
    begin,
    director,
    ai,
    vehicles,
    turrets,
    despawn,
    commands,
};

pub const TickResult = struct {
    ai_hits: u32 = 0,
    director_spawned: u32 = 0,
    world_time: u64 = 0,
    turret_kills: u32 = 0,
    killed_ids: [16]i32 = .{0} ** 16,
    killed_n: u8 = 0,
    loot_bag_ids: [16]i32 = .{0} ** 16,
    loot_n: u8 = 0,
    despawned_ids: [8]i32 = .{0} ** 8,
    despawned_n: u8 = 0,
    commands_applied: u32 = 0,
    /// A* replans this tick. Evidence for the deferred path-solve phase gap
    /// (docs/SCALE_ARCHITECTURE.md); not used by the sim itself.
    path_replans: u32 = 0,
};

/// Run full sim tick: beginTick → director → ai → vehicles → turrets →
/// despawn → drain commands. Power resolve stays in Game.step (daylight).
pub fn run(w: *World, dt: f32) TickResult {
    w.beginTick();

    const dr = systems.systemDirector(w, dt);
    const hits = systems.systemZombieAi(w, dt);
    systems.systemVehicles(w, dt);
    // Power resolves once per tick in Game.step (power.tick with real daylight);
    // an extra resolve here doubled the grid BFS and forced daylight=true, so
    // turrets read solar as powered at night. Turrets use last tick's resolve.
    const tk = systems.systemTurrets(w, dt);

    var de_ids: [8]i32 = .{0} ** 8;
    const de_n = systems.systemDespawnFar(w, de_ids[0..]);

    // Deferred ops from systems/plugins: apply after sim mutations settle.
    // Drain clears the buffer (frame leftover). apm: commands_applied counter
    // on TickResult is enough without importing apm from ecs (cycle).
    const cmd = w.drainCommands();

    var out: TickResult = .{
        .ai_hits = hits,
        .director_spawned = dr.spawned,
        .world_time = dr.world_time,
        .turret_kills = tk.kills,
        .killed_n = tk.killed_n,
        .loot_n = tk.loot_n,
        .despawned_n = de_n,
        .commands_applied = cmd.applied,
        .path_replans = w.path_replans.load(.monotonic),
    };
    @memcpy(out.killed_ids[0..tk.killed_n], tk.killed_ids[0..tk.killed_n]);
    @memcpy(out.loot_bag_ids[0..tk.loot_n], tk.loot_bag_ids[0..tk.loot_n]);
    @memcpy(out.despawned_ids[0..de_n], de_ids[0..de_n]);
    return out;
}

const std = @import("std");

test "schedule.run drains commands and clears locals" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    w.locals.interest_n = 5;
    try std.testing.expect(w.pushCommand(.{ .spawn_zombie = .{ .x = 0, .y = 70, .z = 0, .hp = 40 } }));
    const r = run(&w, 0.05);
    try std.testing.expectEqual(@as(u32, 1), r.commands_applied);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    try std.testing.expectEqual(@as(u8, 0), w.locals.interest_n);
    try std.testing.expectEqual(@as(usize, 0), w.commands.len());
}
