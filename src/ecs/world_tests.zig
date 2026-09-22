//! ECS World tests: spawn, damage, loot, ticks, handles, corpses.
//!
//! Split out of ecs/world.zig (same code, moved verbatim).

const std = @import("std");
const world = @import("world.zig");
const World = world.World;
const Slot = world.Slot;
const EntityClass = world.EntityClass;
const max_entities = world.max_entities;
const c = @import("components.zig");
const quest = @import("quest.zig");
const director = @import("aidirector.zig");
const entity_warn_at = world.entity_warn_at;
const NetId = world.NetId;
const AtomicBits = world.AtomicBits;

test "spawnPlayer starter kit fails closed when name resolve returns 0" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const Ctx = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) u16 {
            if (std.mem.eql(u8, name, "foodCanBeef")) return 2;
            return 0;
        }
    };
    w.item_id_fn = &Ctx.lookup;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    try std.testing.expect(w.inventory[ps].countItem(2) >= 1);
    try std.testing.expectEqual(@as(u32, 0), w.inventory[ps].countItem(8));
    try std.testing.expectEqual(@as(u32, 0), w.inventory[ps].countItem(7));
    try std.testing.expectEqual(@as(u32, 0), w.inventory[ps].countItem(6));
}

test "ecs spawn player zombie damage" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const z = w.spawnZombie(5, 70, 0, 50).?;
    try std.testing.expect(w.slotOfNetId(p) != null);
    try std.testing.expect(w.slotOfNetId(z) != null);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    const ps = w.playerByPeer(0).?;
    try std.testing.expect(w.mask[ps].inventory);
    try std.testing.expect(w.inventory[ps].countItem(8) >= 1);
    try std.testing.expect(w.damage(z, 100).killed);
    // Corpse dwell: the body stays at hp 0 until the sweep destroys it.
    const zs = w.slotOfNetId(z) orelse return error.TestUnexpectedResult;
    try std.testing.expect(w.health[zs].hp <= 0);
    try std.testing.expect(w.health[zs].corpse_seconds > 0);
    var out: [2]NetId = undefined;
    try std.testing.expectEqual(@as(usize, 1), w.sweepCorpses(1000, &out, null));
    try std.testing.expect(w.slotOfNetId(z) == null);
}

test "damage ignores non-positive amount and already-dead players" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expect(!w.damage(p, 0).killed);
    try std.testing.expect(!w.damage(p, -10).killed);
    try std.testing.expect(w.damage(p, 9999).killed);
    // Second kill must not re-fire (DropOnDeath / quest side effects).
    try std.testing.expect(!w.damage(p, 1).killed);
    const ps = w.slotOfNetId(p).?;
    try std.testing.expectEqual(@as(f32, 0), w.health[ps].hp);
    try std.testing.expect(w.alive[ps]);
}

test "damageFrom records the attacker as the revenge target" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const p = w.spawnPlayer(5, 70, 0, 0).?;
    const zs = w.slotOfNetId(z).?;
    _ = w.damageFrom(z, 3, p);
    try std.testing.expectEqual(p, w.zombie_ai[zs].revenge_target);
    try std.testing.expectEqual(@as(f32, 20.0), w.zombie_ai[zs].revenge_time); // rules.ai default
    // Unattributed and self-inflicted damage leave the target alone.
    w.zombie_ai[zs] = .{};
    _ = w.damage(z, 3);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
    _ = w.damageFrom(z, 3, z);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
    // A zero-damage claim is not an attack.
    _ = w.damageFrom(z, 0, p);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
}

test "loot bag drops only on LootDropProb" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    // A 0-prob class never drops a bag (stock regular zombie is .04).
    w.setClassDef(1, .{ .name = "z", .kind = .zombie, .hash = 1, .drop_prob = 0 });
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const r = w.damage(z, 100);
    try std.testing.expect(r.killed);
    try std.testing.expectEqual(@as(i32, -1), r.loot_bag_id);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.loot_bag));
    // A 1.0 class always drops (offline/builtin default keeps tests stable).
    w.setClassDef(1, .{ .name = "z", .kind = .zombie, .hash = 1, .drop_prob = 1 });
    const z2 = w.spawnZombie(0, 70, 0, 40).?;
    const r2 = w.damage(z2, 100);
    try std.testing.expect(r2.killed);
    try std.testing.expect(r2.loot_bag_id > 0);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.loot_bag));
}

test "spawnLootBagFrom copies a slot range into the death bag" {
    // DropOnDeath: the bag carries the victim's real inventory range (mode 1
    // toolbelt+backpack, 2 toolbelt, 3 backpack), not a placeholder unit.
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Seed the toolbelt and the backpack with distinct items.
    w.inventory[ps].slots[3] = .{ .item_id = 7, .count = 5 };
    w.inventory[ps].slots[10 + 4] = .{ .item_id = 9, .count = 2 };
    // Mode 2 (toolbelt only): the bag holds slot 3, not the backpack slot.
    const b2 = w.spawnLootBagFrom(0, 70, 2, &w.inventory[ps], 0, c.inv_toolbelt).?;
    const bs2 = w.slotOfNetId(b2).?;
    // Offsets are preserved (bag slot 3 = source slot 3).
    try std.testing.expectEqual(@as(u16, 7), w.inventory[bs2].slots[3].item_id);
    try std.testing.expectEqual(@as(u16, 5), w.inventory[bs2].slots[3].count);
    // The backpack item is outside the toolbelt range: not in the mode-2 bag.
    try std.testing.expectEqual(@as(u16, 0), w.inventory[bs2].slots[10 + 4].item_id);
    // Mode 3 (backpack only): the bag holds the backpack slot.
    const b3 = w.spawnLootBagFrom(0, 70, 3, &w.inventory[ps], c.inv_bag_start, c.inv_equip_start).?;
    const bs3 = w.slotOfNetId(b3).?;
    try std.testing.expectEqual(@as(u16, 9), w.inventory[bs3].slots[4].item_id); // 14-10
    try std.testing.expectEqual(@as(u16, 2), w.inventory[bs3].slots[4].count);
}

test "per-tick path budget stride is derived from last tick demand" {
    var w: World = .{};
    defer w.deinit();
    w.path_replans.store(4, .monotonic);
    w.beginTick();
    try std.testing.expectEqual(@as(u32, 1), w.path_stride);
    try std.testing.expectEqual(@as(u32, 0), w.path_replans.load(.monotonic));
    // Demand above the cap spreads over as many ticks as it takes, up to the
    // delay ceiling.
    w.path_replans.store(World.path_replans_per_tick, .monotonic);
    w.path_replans_denied.store(World.path_replans_per_tick, .monotonic);
    w.beginTick();
    try std.testing.expectEqual(@as(u32, 2), w.path_stride);
    // Every slot is admitted eventually: over `stride` consecutive ticks the
    // rotating phase covers all of them exactly once.
    var seen: u32 = 0;
    var k: u32 = 0;
    while (k < w.path_stride) : (k += 1) {
        if (w.pathBudgetAdmits(7)) seen += 1;
        w.path_tick +%= 1;
    }
    try std.testing.expectEqual(@as(u32, 1), seen);
}

test "net id lookup falls back to authoritative columns when index misses" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(1, 2, 3, 40).?;
    const expected = w.slotOfNetId(id).?;
    try std.testing.expect(w.net_to_slot.remove(id));
    // Healthy map: a miss is authoritative (no per-miss full scan).
    try std.testing.expectEqual(null, w.slotOfNetId(id));
    // Degraded map (failed insert): the SoA scan recovers the entry.
    w.net_map_degraded = true;
    try std.testing.expectEqual(expected, w.slotOfNetId(id).?);
}

test "player peer index follows replacement and destroy" {
    var w: World = .{};
    defer w.deinit();
    const first_id = w.spawnPlayer(0, 70, 0, 3).?;
    const first = w.slotOfNetId(first_id).?;
    try std.testing.expectEqual(first, w.playerByPeer(3).?);

    const second_id = w.spawnPlayer(1, 70, 0, 4).?;
    const second = w.slotOfNetId(second_id).?;
    try std.testing.expectEqual(second, w.playerByPeer(4).?);

    w.destroy(second);
    try std.testing.expect(w.playerByPeer(4) == null);
    try std.testing.expectEqual(first, w.playerByPeer(3).?);
}

test "destroy releases every POI lock held by a player" {
    var w: World = .{};
    defer w.deinit();
    const first_id = w.spawnPlayer(0, 70, 0, 3).?;
    const second_id = w.spawnPlayer(0, 70, 0, 4).?;
    const first = w.slotOfNetId(first_id).?;
    const second = w.slotOfNetId(second_id).?;
    const now = w.director.clock.worldTimeBits();
    const shared: c.PoiRect = .{ .x = 0, .z = 0, .size_x = 10, .size_y = 10, .size_z = 10 };
    const solo: c.PoiRect = .{ .x = 100, .z = 0, .size_x = 10, .size_y = 10, .size_z = 10 };
    try std.testing.expect(w.poi_locks.lock(shared, first_id, now));
    try std.testing.expect(w.poi_locks.lock(shared, second_id, now));
    try std.testing.expect(w.poi_locks.lock(solo, first_id, now));

    w.destroy(first);
    const until = now +| w.poi_locks.grace_ticks;
    try std.testing.expectEqual(@as(?u64, 0), w.poi_locks.check(1, 1, now));
    try std.testing.expectEqual(@as(?u64, until), w.poi_locks.check(101, 1, now));
    try std.testing.expectEqual(@as(u8, 1), w.poi_locks.entries[0].quester_n);
    try std.testing.expectEqual(second_id, w.poi_locks.entries[0].questers[0]);

    w.destroy(second);
    w.destroy(second);
    try std.testing.expectEqual(@as(?u64, until), w.poi_locks.check(1, 1, until));
    try std.testing.expect(w.poi_locks.check(1, 1, until + 1) == null);
    try std.testing.expect(w.poi_locks.check(101, 1, until + 1) == null);
    try std.testing.expectEqual(@as(usize, 0), w.poi_locks.n);
}

test "entity_count tracks spawn destroy and soft warn flag" {
    var w: World = .{};
    defer w.deinit();
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    const z = w.spawnZombie(0, 70, 0, 40).?;
    try std.testing.expectEqual(@as(u16, 1), w.entity_count);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    const zs = w.slotOfNetId(z).?;
    w.destroy(zs);
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    try std.testing.expect(w.any_freed_this_tick);
    // Fill to soft threshold without allocating beyond max.
    var n: usize = 0;
    while (n < entity_warn_at) : (n += 1) {
        _ = w.spawnZombie(@floatFromInt(n), 70, 0, 40) orelse break;
    }
    try std.testing.expect(w.entity_count >= entity_warn_at);
    try std.testing.expect(w.entity_cap_warned);
    try std.testing.expectEqual(@as(u32, w.entity_count), w.countKind(.zombie));
}

test "spawnZombieFromClass fills from class_table" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    w.class_table[1].max_hp = 55;
    w.class_table[1].hash = 12345;
    w.class_table[1].loot_list = "EntityLootContainerStrong";
    const id = w.spawnZombieFromClass("zombie", 3, 70, 4).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 55), w.health[s].max_hp);
    try std.testing.expectEqual(@as(i32, 12345), w.class_id[s].hash);
    try std.testing.expectEqualStrings("EntityLootContainerStrong", w.class_id[s].loot_list);
    try std.testing.expect(w.spawnZombieFromClass("nope", 0, 0, 0) == null);
}

test "spawnSleeperDef carries per-entity class stats" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnSleeperDef(3, 70, 4, .{
        .name = "zombieFeral",
        .max_hp = 60,
        .kind = .zombie,
        .hash = 12345,
        .loot_list = "EntityLootContainerStrong",
        .chase_speed = 1.1,
        .wander_speed = 0.3,
        .attack_damage = 25,
    }, 0).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expect(w.mask[s].sleeper);
    try std.testing.expect(w.sleeper[s].volume_r > 0);
    try std.testing.expectEqual(c.AiState.sleep, w.zombie_ai[s].state);
    // The A35 per-entity layer: speeds/damage/hash/loot survive on the entity
    // so the AI reads them even though class_table has no feral row.
    try std.testing.expectEqual(@as(f32, 1.1), w.class_id[s].chase_speed);
    try std.testing.expectEqual(@as(f32, 0.3), w.class_id[s].wander_speed);
    try std.testing.expectEqual(@as(f32, 25), w.class_id[s].attack_damage);
    try std.testing.expectEqual(@as(f32, 60), w.health[s].max_hp);
    try std.testing.expectEqual(@as(i32, 12345), w.class_id[s].hash);
    try std.testing.expectEqualStrings("EntityLootContainerStrong", w.class_id[s].loot_list);
    // The wake-threshold roll: a class without SleeperSightToWake* uses the
    // stock default ranges (-40..5 / 340..480) and the roll is deterministic
    // per spawn (same position + class → same thresholds, inside the ranges).
    const near0 = w.sleeper[s].wake_light_near;
    const far0 = w.sleeper[s].wake_light_far;
    try std.testing.expect(near0 >= -40.0 and near0 <= 5.0);
    try std.testing.expect(far0 >= 340.0 and far0 <= 480.0);
    const id2 = w.spawnSleeperDef(3, 70, 4, .{
        .name = "zombieFeral",
        .max_hp = 60,
        .kind = .zombie,
        .hash = 12345,
        .loot_list = "EntityLootContainerStrong",
    }, 0).?;
    const s2 = w.slotOfNetId(id2).?;
    try std.testing.expectEqual(near0, w.sleeper[s2].wake_light_near);
    try std.testing.expectEqual(far0, w.sleeper[s2].wake_light_far);
    // A class carrying the ranges rolls inside them.
    const id3 = w.spawnSleeperDef(9, 70, 9, .{
        .name = "custom",
        .hash = 7,
        .kind = .zombie,
        .sleeper_wake_near_min = 0.0,
        .sleeper_wake_near_max = 0.0,
        .sleeper_wake_far_min = 10.0,
        .sleeper_wake_far_max = 20.0,
    }, 0).?;
    const s3 = w.slotOfNetId(id3).?;
    try std.testing.expect(w.sleeper[s3].wake_light_near >= -40.0 and w.sleeper[s3].wake_light_near <= 5.0);
    try std.testing.expect(w.sleeper[s3].wake_light_far >= 10.0 and w.sleeper[s3].wake_light_far <= 20.0);
}

test "MoveSpeedRand rolls the day chase per entity, deterministically" {
    // RE entity-ai.md 3318-3320: moveSpeedRand adds a per-entity roll to the
    // day chase when aggro < 1 (clamp min 0.1, cap at aggro max). The roll is
    // deterministic per spawn (position + class hash) and lands in
    // [0.1, aggroMax]; a class without the prop keeps the unrolled value.
    var w: World = .{};
    defer w.deinit();
    const def = EntityClass{
        .name = "zombieBoe",
        .hash = 1,
        .kind = .zombie,
        .chase_speed_day = 0.2,
        .chase_speed = 1.25,
        .move_speed_rand_min = -0.2,
        .move_speed_rand_max = 0.25,
    };
    const z = w.spawnZombieDef(0, 70, 0, 40, def).?;
    const s = w.slotOfNetId(z).?;
    const rolled = w.class_id[s].chase_speed_day;
    try std.testing.expect(rolled >= 0.1 and rolled <= 1.25);
    // Same position + class → same roll (deterministic); a different
    // position rolls differently in general.
    const z2 = w.spawnZombieDef(0, 70, 0, 40, def).?;
    const s2 = w.slotOfNetId(z2).?;
    try std.testing.expectEqual(rolled, w.class_id[s2].chase_speed_day);
    // No MoveSpeedRand prop: unrolled.
    const plain = w.spawnZombieDef(5, 70, 5, 40, .{
        .name = "zombieBoe",
        .hash = 1,
        .kind = .zombie,
        .chase_speed_day = 0.2,
        .chase_speed = 1.25,
    }).?;
    try std.testing.expectEqual(@as(f32, 0.2), w.class_id[w.slotOfNetId(plain).?].chase_speed_day);
    // An aggro >= 1 day value is not rolled (the stock `aggro < 1` gate).
    const dog = w.spawnZombieDef(7, 70, 7, 40, .{
        .name = "dog",
        .hash = 2,
        .kind = .zombie,
        .chase_speed_day = 1.2,
        .chase_speed = 1.3,
        .move_speed_rand_min = -0.2,
        .move_speed_rand_max = 0.25,
    }).?;
    try std.testing.expectEqual(@as(f32, 1.2), w.class_id[w.slotOfNetId(dog).?].chase_speed_day);
}

test "spawn*Def copies MaxViewAngle and explosion stats onto the entity" {
    // A35: class_table index stays the kind default; per-entity ClassId fields
    // must carry MaxViewAngle / ExplosionData so sense and demolition read them.
    var w: World = .{};
    defer w.deinit();
    const zdef = EntityClass{
        .name = "zombieCop",
        .hash = 7,
        .kind = .zombie,
        .view_angle_deg = 90,
        .explode_threshold = 0.75,
        .explode_delay_s = 0.5,
        .explosion_radius = 5,
        .dismember_head = 1.5,
    };
    const z = w.spawnZombieDef(0, 70, 0, 40, zdef).?;
    const zs = w.slotOfNetId(z).?;
    try std.testing.expectEqual(@as(f32, 90), w.class_id[zs].view_angle_deg);
    try std.testing.expectEqual(@as(f32, 0.75), w.class_id[zs].explode_threshold);
    try std.testing.expectEqual(@as(f32, 5), w.class_id[zs].explosion_radius);
    try std.testing.expectEqual(@as(f32, 1.5), w.class_id[zs].dismember_head);

    const adef = EntityClass{
        .name = "animalWolf",
        .hash = 9,
        .kind = .animal,
        .view_angle_deg = 120,
        .explode_threshold = 0.5,
        .dismember_legs = 2,
        .is_enemy = true,
    };
    const a = w.spawnAnimalDef(1, 70, 1, adef).?;
    const aslot = w.slotOfNetId(a).?;
    try std.testing.expectEqual(@as(f32, 120), w.class_id[aslot].view_angle_deg);
    try std.testing.expectEqual(@as(f32, 0.5), w.class_id[aslot].explode_threshold);
    try std.testing.expectEqual(@as(f32, 2), w.class_id[aslot].dismember_legs);
}

test "beginTick clears locals" {
    var w: World = .{};
    w.locals.interest_n = 9;
    w.beginTick();
    try std.testing.expectEqual(@as(u8, 0), w.locals.interest_n);
}

test "alive_bits and dirty_bits survive random spawn destroy churn" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    // Empty world: both sets start clear.
    try std.testing.expectEqual(@as(usize, 0), w.alive_bits.count());
    try std.testing.expectEqual(@as(usize, 0), w.dirty_bits.count());

    var prng = std.Random.DefaultPrng.init(0xb175e75);
    const rnd = prng.random();
    var op: usize = 0;
    while (op < 4000) : (op += 1) {
        switch (rnd.uintLessThan(u8, 4)) {
            0 => _ = w.spawnZombie(rnd.float(f32) * 100, 70, rnd.float(f32) * 100, 40),
            1 => w.destroy(rnd.uintLessThan(Slot, max_entities)),
            2 => w.markDirty(rnd.uintLessThan(Slot, max_entities), .{ .pos = true }),
            else => {
                const s = rnd.uintLessThan(Slot, max_entities);
                if (w.alive[s]) {
                    w.dirty[s] = .{};
                    w.syncDirtyBit(s);
                }
            },
        }
        // beginTick releases freed slots so allocSlot can recycle them.
        if (op % 37 == 0) w.beginTick();
    }
    // Fill to capacity so the full-table edge is covered too.
    while (w.spawnZombie(1, 70, 1, 40) != null) {}

    var s: Slot = 0;
    while (s < max_entities) : (s += 1) {
        try std.testing.expectEqual(w.alive[s], w.alive_bits.isSet(s));
        try std.testing.expectEqual(w.alive[s] and w.dirty[s].any(), w.dirty_bits.isSet(s));
    }
    try std.testing.expectEqual(@as(usize, max_entities), w.alive_bits.count());
}

test "slot recycle does not inherit the previous tenant's dirty bit" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(id).?;
    w.markDirty(s, .{ .hp = true });
    w.destroy(s);
    try std.testing.expect(!w.alive_bits.isSet(s));
    try std.testing.expect(!w.dirty_bits.isSet(s));
    // markDirty on a dead slot is a no-op, so a stale caller cannot resurrect it.
    w.markDirty(s, .{ .pos = true });
    try std.testing.expect(!w.dirty_bits.isSet(s));
    // Recycled slot starts from spawnBase's spawn|pos, nothing carried over.
    w.beginTick();
    const id2 = w.spawnZombie(1, 70, 1, 40).?;
    const s2 = w.slotOfNetId(id2).?;
    try std.testing.expectEqual(s, s2);
    try std.testing.expect(w.dirty_bits.isSet(s2));
    try std.testing.expect(!w.dirty[s2].hp);
}

test "generation-counted handle invalidates after destroy" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(id).?;
    const h = w.handleOfSlot(s);
    try std.testing.expect(w.handleAlive(h));
    w.destroy(s);
    try std.testing.expect(!w.handleAlive(h));
    // Reuse slot: new gen must not match old handle.
    _ = w.spawnZombie(1, 70, 1, 40);
    try std.testing.expect(!w.handleAlive(h));
}

test "death during a blood moon sets IsBloodMoonDead, daytime death does not" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.playerByPeer(0).?;
    const nid = w.network_id[ps].id;
    // Blood-moon night: day 7, freq 7, after dusk.
    w.director.clock.day = 7;
    w.director.clock.hours = 22.0;
    w.director.clock.dawn = 6;
    w.director.clock.dusk = 18;
    w.director.clock.bloodmoon_frequency = 7;
    _ = w.damage(nid, 9999);
    try std.testing.expect(w.player[ps].is_blood_moon_dead);
    // Daytime death leaves the flag clear.
    w.player[ps].is_blood_moon_dead = false;
    w.director.clock.hours = 12.0;
    _ = w.damage(nid, 9999);
    try std.testing.expect(!w.player[ps].is_blood_moon_dead);
}

test "corpse dwell keeps the body at hp 0, then the sweep removes it" {
    var w: World = .{};
    defer w.deinit();
    const id = w.spawnZombie(0, 70, 0, 50).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 0), w.health[s].corpse_seconds);
    const killed = w.damage(id, 9999);
    try std.testing.expect(killed.killed);
    // The corpse stays in world (builtin class has no TimeStayAfterDeath, so
    // the stock EntityAlive default of 5 s applies) with its AI stopped.
    try std.testing.expect(w.alive[s]);
    try std.testing.expect(w.health[s].hp <= 0);
    try std.testing.expectEqual(@as(f32, 5), w.health[s].corpse_seconds);
    try std.testing.expect(w.zombie_ai[s].state == .idle);
    // A second hit must not re-fire kill side effects.
    const again = w.damage(id, 9999);
    try std.testing.expect(!again.killed);
    try std.testing.expect(w.alive[s]);
    // The sweep leaves the body until the dwell elapses, then destroys it.
    var out: [4]NetId = undefined;
    try std.testing.expectEqual(@as(usize, 0), w.sweepCorpses(2, &out, null));
    try std.testing.expect(w.alive[s]);
    try std.testing.expectEqual(@as(usize, 1), w.sweepCorpses(10, &out, null));
    try std.testing.expectEqual(id, out[0]);
    try std.testing.expect(!w.alive[s]);
}

test "sweepCorpses never destroys more than it reports" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const id = w.spawnZombie(@floatFromInt(i), 70, 0, 10).?;
        try std.testing.expect(w.damage(id, 9999).killed);
    }
    // Buffer smaller than the expiring set: the overflow keeps its slot so the
    // caller never has to broadcast an EntityRemove it was not handed.
    var out: [2]NetId = undefined;
    try std.testing.expectEqual(@as(usize, 2), w.sweepCorpses(1000, &out, null));
    try std.testing.expectEqual(@as(u32, 3), w.countKind(.zombie));
    try std.testing.expectEqual(@as(usize, 2), w.sweepCorpses(1000, &out, null));
    try std.testing.expectEqual(@as(usize, 1), w.sweepCorpses(1000, &out, null));
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
}

test "AtomicBits concurrent set loses no bits" {
    const builtin = @import("builtin");
    if (builtin.single_threaded) return;
    // Ranges deliberately misaligned to the 64-slot word grid (the 3/5/6/7
    // worker splits in the parallel AI pass straddle words the same way), so
    // two threads write the same u64 word. A plain `|=` tears; the atomic
    // fetchOr must keep every bit.
    const ranges = [_][2]usize{ .{ 0, 70 }, .{ 70, 150 }, .{ 150, 300 }, .{ 300, 512 } };
    var bits = AtomicBits.initEmpty();
    const ThreadCtx = struct {
        bits: *AtomicBits,
        begin: usize,
        end: usize,
        fn run(ctx: *const @This()) void {
            var i = ctx.begin;
            while (i < ctx.end) : (i += 1) ctx.bits.set(i);
        }
    };
    var ctxs: [ranges.len]ThreadCtx = undefined;
    var threads: [ranges.len]std.Thread = undefined;
    var spawned: usize = 0;
    var spawn_err: ?anyerror = null;
    for (&threads, 0..) |*t, ti| {
        ctxs[ti] = .{ .bits = &bits, .begin = ranges[ti][0], .end = ranges[ti][1] };
        t.* = std.Thread.spawn(.{}, ThreadCtx.run, .{&ctxs[ti]}) catch |err| {
            spawn_err = err;
            break;
        };
        spawned += 1;
    }
    // ThreadCtx lives on this stack frame, so every thread that did start has
    // to be joined before returning, including on the spawn-failure path.
    for (threads[0..spawned]) |*t| t.join();
    if (spawn_err) |err| {
        std.debug.print("zdtd test: AtomicBits thread spawn failed: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    }
    var i: usize = 0;
    while (i < max_entities) : (i += 1) try std.testing.expect(bits.isSet(i));
    try std.testing.expectEqual(@as(usize, max_entities), bits.count());
}

test "spawnTurret applies the block-data combat stats through the hook" {
    // Rule 15: the placed turret's range/damage/fire interval come from the
    // autoTurret block data via the Game hook; zero fields keep the
    // component defaults.
    var w: World = .{};
    defer w.deinit();
    var stats: c.TurretBlockStats = .{ .max_distance = 30, .entity_damage = 32, .burst_fire_rate = 0.15, .burst_rounds = 15 };
    w.turret_stats_fn = struct {
        fn f(ctx: ?*anyopaque) ?c.TurretBlockStats {
            const s: *c.TurretBlockStats = @ptrCast(@alignCast(ctx.?));
            return s.*;
        }
    }.f;
    w.turret_stats_ctx = &stats;
    const id = w.spawnTurret(5, 70, 5).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 30), w.turret[s].range);
    try std.testing.expectEqual(@as(f32, 32), w.turret[s].damage);
    try std.testing.expectEqual(@as(f32, 0.15), w.turret[s].fire_interval);
    // BurstRoundCount is the magazine: it was parsed off blocks.xml and then
    // dropped, so every turret held the 200-round component fallback.
    try std.testing.expectEqual(@as(u16, 15), w.turret[s].ammo);
    // Without the hook the component defaults hold.
    var w2: World = .{};
    defer w2.deinit();
    const id2 = w2.spawnTurret(5, 70, 5).?;
    const s2 = w2.slotOfNetId(id2).?;
    try std.testing.expectEqual(@as(f32, 24), w2.turret[s2].range);
    try std.testing.expectEqual(@as(f32, 12), w2.turret[s2].damage);
    try std.testing.expectEqual(@as(u16, 200), w2.turret[s2].ammo);
}

test "spawnTurret honors a fail-closed turret_watts hook" {
    var w: World = .{};
    defer w.deinit();
    w.turret_watts_fn = struct {
        fn f(_: ?*anyopaque) f32 {
            return 0;
        }
    }.f;
    const id = w.spawnTurret(5, 70, 5).?;
    const s = w.slotOfNetId(id).?;
    const ni = w.power.indexOfId(w.turret[s].power_node).?;
    try std.testing.expectEqual(@as(f32, 0), w.power.nodes[ni].watts);
}

test "rollDismember sets the wire bits stock sets" {
    // RE EntityAlive.CheckDismember (IL=125) / GetDismemberChance (IL=128):
    // weapon >= 100 skips the roll at flat 100; a leg hit past the class
    // threshold crawlers; a scaled leg hit cripples. Bits: 1 dismember,
    // 2 crawler, 4 cripple.
    var w: World = .{};
    defer w.deinit();
    const z = w.spawnZombie(0, 70, 0, 100).?;
    const s = w.slotOfNetId(z).?;
    w.class_id[s].leg_crawler_threshold = 0.175;
    w.class_id[s].leg_cripple_scale = 2;
    w.class_id[s].dismember_head = 1;
    w.class_id[s].dismember_arms = 1;
    w.class_id[s].dismember_legs = 1;

    // Flat-100 weapon on a head hit: dismember, no leg path.
    try std.testing.expectEqual(@as(u8, 1), w.rollDismember(s, 2, 10, 100, 100, 0, false));
    try std.testing.expect(!w.zombie_ai[s].crawler);

    // Leg hit at 0.2 fraction past the 0.175 threshold: crawler.
    const z2 = w.spawnZombie(10, 70, 0, 100).?;
    const s2 = w.slotOfNetId(z2).?;
    w.class_id[s2].leg_crawler_threshold = 0.175;
    w.class_id[s2].leg_cripple_scale = 0;
    w.class_id[s2].dismember_legs = 1;
    const bits = w.rollDismember(s2, 256, 20, 100, 0, 0, false);
    try std.testing.expect(bits & 2 != 0);
    try std.testing.expect(w.zombie_ai[s2].crawler);

    // Below the threshold with a live scale: cripple arm is reachable
    // (scaled = fraction * scale >= 0.05 rolls the second draw).
    const z3 = w.spawnZombie(20, 70, 0, 100).?;
    const s3 = w.slotOfNetId(z3).?;
    w.class_id[s3].leg_crawler_threshold = 0.9;
    w.class_id[s3].leg_cripple_scale = 2;
    w.class_id[s3].dismember_legs = 1;
    const b3 = w.rollDismember(s3, 256, 20, 100, 0, 0, false);
    // Either crippled or not (draw-dependent), but never crawler, and the
    // bit agrees with the state.
    try std.testing.expect(b3 & 2 == 0);
    try std.testing.expect(!w.zombie_ai[s3].crawler);
    try std.testing.expect((b3 & 4 != 0) == w.zombie_ai[s3].crippled);

    // Non-leg, no-threshold, zero weapon: nothing.
    const z4 = w.spawnZombie(30, 70, 0, 100).?;
    const s4 = w.slotOfNetId(z4).?;
    try std.testing.expectEqual(@as(u8, 0), w.rollDismember(s4, 1, 10, 100, 0, 0, false));

    // The product term decides with damagePer pinned at 1.0: weapon 1 on a
    // mult-1 head is chance 1.0, so every draw dismembers. Glancing (50 <
    // 100 hp, non-fatal) so the killing-blow prescale stays out of it. Zero
    // the multiplier term and this fails - the flat-100 arm above cannot
    // cover it.
    const z5 = w.spawnZombie(40, 70, 0, 100).?;
    const s5 = w.slotOfNetId(z5).?;
    w.class_id[s5].dismember_head = 1;
    try std.testing.expectEqual(@as(u8, 1), w.rollDismember(s5, 2, 50, 100, 1, 0, false));
}

test "dismemberPrescale matches the stock killing-blow floor table" {
    // ProcessDamageResponse IL_0118-0171: head bit + fraction >= 0.2 gets
    // max(c*0.5, 0.3), everything else max(c*0.5, 0.5).
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), World.dismemberPrescale(1.0, 2, 0.5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), World.dismemberPrescale(0.1, 2, 0.5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), World.dismemberPrescale(0.1, 1, 0.5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), World.dismemberPrescale(0.4, 2, 0.1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), World.dismemberPrescale(5.0, 2, 0.9), 0.0001);
}
