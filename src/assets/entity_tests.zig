//! Entity class tests: kinds, speeds, resolvers.
//!
//! Split out of assets/entities.zig (same tests, moved verbatim).

const std = @import("std");
const test_tmp = @import("../util/test_tmp.zig");
const entities = @import("entities.zig");
const EntityDef = entities.EntityDef;
const inferKind = entities.inferKind;
const EntityTable = entities.EntityTable;
const loadFromPath = entities.loadFromPath;
const components = @import("../ecs/components.zig");
const unity_hash = @import("unity_hash.zig");
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "builtin entities" {
    const t = EntityTable.builtin();
    try std.testing.expectEqualStrings("zombieBoe", t.defaultZombie().name);
    try std.testing.expectEqual(unity_hash.class_zombie_boe, t.defaultZombie().hash);
}

test "xml catalog without zombies does not fall back to builtin HP" {
    const defs = [_]EntityDef{.{
        .name = "playerMale",
        .kind = .player,
        .spawnable = false,
        .is_enemy = false,
        .max_hp = 100,
    }};
    const t: EntityTable = .{ .defs = &defs, .source = .xml };
    try std.testing.expectEqualStrings("", t.defaultZombie().name);
    try std.testing.expectEqual(@as(f32, 0), t.defaultZombie().max_hp);
    try std.testing.expectEqualStrings("", t.defaultAnimal().name);
    try std.testing.expectEqual(@as(f32, 0), t.defaultAnimal().max_hp);
}

test "unity hash matches known playerMale" {
    try std.testing.expectEqual(unity_hash.class_player_male, unity_hash.getStableHashCode("playerMale"));
    try std.testing.expectEqual(unity_hash.class_zombie_boe, unity_hash.getStableHashCode("zombieBoe"));
}

test "load stock entityclasses when present" {
    const path = stock_paths.configFile("entityclasses.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 100);
    const boe = t.byName("zombieBoe") orelse return error.TestExpectedEqual;
    try std.testing.expect(boe.spawnable);
    try std.testing.expectEqual(components.Kind.zombie, boe.kind);
    // AITarget player sense (EAISetNearestEntityAsTarget targetClasses):
    // zombieBoe inherits the template's `EntityPlayer,0,0` triple: hear 0
    // reads 50 stock-side, see 0 = unset (the sense path falls back to
    // SightRange). animalDireWolf declares `EntityPlayer,28,20`.
    try std.testing.expectEqual(@as(f32, 50), boe.target_player_hear);
    try std.testing.expectEqual(@as(f32, 0), boe.target_player_see);
    const dwolf = t.byName("animalDireWolf") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 28), dwolf.target_player_hear);
    try std.testing.expectEqual(@as(f32, 20), dwolf.target_player_see);
    // SetAsTargetIfHurt class filter (EAISetAsTargetIfHurt SetData IL):
    // zombieTemplateMale names player+bandit+enemyAnimal (bits 0+1+2+3);
    // animalDireWolf inherits the template's filter through Extends.
    const tm = t.byName("zombieTemplateMale") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 15), tm.hurt_target_classes);
    try std.testing.expectEqual(@as(u8, 15), boe.hurt_target_classes);
    try std.testing.expectEqual(@as(u8, 15), dwolf.hurt_target_classes);
    // BlockIf alert gate (EAIBlockIf SetData IL): the hostile-animal template
    // ships `condition=alert e 0` on AITarget-2 (bits 0+1); the zombie template
    // has no BlockIf row, and the dire wolf inherits the hostile gate.
    const hostile = t.byName("animalTemplateHostile") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 3), hostile.block_if_alert_only);
    try std.testing.expectEqual(@as(u8, 0), tm.block_if_alert_only);
    // The dire wolf ships its own pipe AITarget blob (hurt + blocking +
    // corpse + sense, no BlockIf), which replaces the template list; the
    // plain wolf keeps numbered props and inherits the hostile gate.
    try std.testing.expectEqual(@as(u8, 0), dwolf.block_if_alert_only);
    try std.testing.expectEqual(@as(u8, 3), (t.byName("animalWolf") orelse return error.TestExpectedEqual).block_if_alert_only);
    // LootDropEntityClass "EntityLootContainerRegular" resolves one hop through
    // that class's LootList to the real loot.xml container.
    try std.testing.expectEqualStrings("zPackReg", boe.loot_list);
    try std.testing.expectEqual(@as(f32, 0.04), boe.loot_drop_prob);
    // ExperienceGain resolves the '^xpNormal01' replace_properties reference
    // (entityclasses.xml XP_ZOMBIE_TEMPLATE -> zombieTemplateMale -> zombieBoe).
    try std.testing.expectEqual(@as(f32, 500), boe.xp_gain);
    // A34: HP comes from the HealthMax passive_effect chain, not the 40 builtin
    // floor. Ground truth = the V3.1.0 b14 stock file: zombieBoe's own body
    // declares `value="^healthNormal"` = 200 (the earlier audit guess of 125
    // was wrong for this file). No perc_add on the row; rolls would be pinned
    // to base for deterministic sims either way (documented).
    try std.testing.expectEqual(@as(f32, 200), boe.max_hp);
    // Day/night speeds (V3.1.0 b14 ground truth): zombieBoe inherits
    // zombieTemplateMale's MoveSpeed 0.08 (day shamble) and MoveSpeedAggro
    // "0.2, 1.25" (day chase min / night chase max; the stock XML comment
    // "min/max (like day or night)"), with no MoveSpeedNight (night shamble
    // seeds from MoveSpeed, entity-ai.md 3312).
    try std.testing.expectEqual(@as(f32, 0.08), boe.wander_speed);
    try std.testing.expectEqual(@as(f32, 0), boe.wander_speed_night);
    try std.testing.expectEqual(@as(f32, 1.25), boe.chase_speed);
    try std.testing.expectEqual(@as(f32, 0.2), boe.chase_speed_day);
    const dog = t.byName("animalZombieDog") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0.45), dog.wander_speed);
    try std.testing.expectEqual(@as(f32, 0.3), dog.wander_speed_night);
    try std.testing.expectEqual(@as(f32, 1.3), dog.chase_speed);
    try std.testing.expectEqual(@as(f32, 1.2), dog.chase_speed_day);
    // SightLightThreshold: zombieTemplateMale pins "-2,150" (the stock XML
    // comment "how well lit you have to be for the zombie to see you at
    // min,max range") and zombieBoe inherits it; a class with no prop keeps
    // 0,0 → the Rules (30,100) cctor-default floor.
    try std.testing.expectEqual(@as(f32, -2.0), boe.sight_light_min);
    try std.testing.expectEqual(@as(f32, 150.0), boe.sight_light_max);
    // SleeperSightToWakeMin/Max (the sleeping zombie's wake-threshold ROLL
    // ranges, RE entity-ai.md D8.6 step 5): zombieBoe inherits the template's
    // "-40,5" / "340,480".
    try std.testing.expectEqual(@as(f32, -40.0), boe.sleeper_wake_near_min);
    try std.testing.expectEqual(@as(f32, 5.0), boe.sleeper_wake_near_max);
    try std.testing.expectEqual(@as(f32, 340.0), boe.sleeper_wake_far_min);
    try std.testing.expectEqual(@as(f32, 480.0), boe.sleeper_wake_far_max);
    // PhysicalDamageResist (passive 41): the armoured classes carry an
    // untagged base_set percentage (soldier 50, demolition 60, biker/utility
    // worker 20); a plain zombie has none, and demolition's own row wins over
    // the soldier it extends. The tag-gated swarm rows (ranged 99 / inverted
    // 75) are deliberately not folded into one number.
    try std.testing.expectEqual(@as(f32, 50.0), (t.byName("zombieSoldier") orelse return error.TestExpectedEqual).phys_resist);
    try std.testing.expectEqual(@as(f32, 60.0), (t.byName("zombieDemolition") orelse return error.TestExpectedEqual).phys_resist);
    try std.testing.expectEqual(@as(f32, 20.0), (t.byName("zombieBiker") orelse return error.TestExpectedEqual).phys_resist);
    try std.testing.expectEqual(@as(f32, 0.0), boe.phys_resist);
    try std.testing.expectEqual(@as(f32, 0.0), (t.byName("animalInsectSwarm") orelse return error.TestExpectedEqual).phys_resist);

    // MoveSpeedRand (entity-ai.md 3318-3320): the template's "-.2, .25".
    try std.testing.expectEqual(@as(f32, -0.2), boe.move_speed_rand_min);
    try std.testing.expectEqual(@as(f32, 0.25), boe.move_speed_rand_max);
    const stag = t.byName("animalStag") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(components.Kind.animal, stag.kind);
    try std.testing.expect(stag.spawnable);
    // A34 on animals: the stag's own HealthMax base_set=100 wins over the 30
    // builtin animal floor (the 10 row in the file is inside an XML comment).
    try std.testing.expectEqual(@as(f32, 100), stag.max_hp);
    // Kind from the stock Tags, not the name: vehicles carry `Tags="vehicle"`
    // and junk turrets `Tags="turret,..."` (the old inferKind missed both, so
    // callers had to sniff names).
    const bike = t.byName("vehicleBicycle") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(components.Kind.vehicle, bike.kind);
    const sledge = t.byName("junkTurretSledge") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(components.Kind.turret, sledge.kind);
    const fer = t.byName("zombieBoeFeral") orelse return error.TestExpectedEqual;
    // A34 on the feral ladder: zombieBoeFeral overrides zombieBoe's HealthMax
    // with ^healthNormalFeral = 550 (Extends-chain override + variable lookup).
    try std.testing.expectEqual(@as(f32, 550), fer.max_hp);
    // AITask-* attack gating (timid animals never attack): the stag's inherited
    // task list is RunawayWhenHurt/RunawayFromEntity/Look/Wander (no attack
    // task), wolves carry ApproachAndAttackTarget, and the boar keeps its
    // hostile template's attack task even though it overrides IsEnemyEntity
    // to false for safe-zone spawning.
    const stag2 = t.byName("animalStag").?;
    try std.testing.expect(!stag2.ai_attack);
    const rabbit = t.byName("animalRabbit").?;
    try std.testing.expect(!rabbit.ai_attack);
    const wolf = t.byName("animalWolf").?;
    try std.testing.expect(wolf.ai_attack);
    const boar = t.byName("animalBoar").?;
    try std.testing.expect(boar.ai_attack);
    try std.testing.expect(boe.ai_attack); // zombieTemplate has the attack task
    // Pipe `AITask` on zombieTemplateMale (BreakBlock|DestroyArea|Territorial|...):
    // the numbered-only walker used to miss it, so every zombie ran the shared table.
    const set = components.ai_task_list_set;
    try std.testing.expect(boe.ai_tasks & set != 0);
    try std.testing.expect(components.aiTaskAllowed(boe.ai_tasks, .destroy_area));
    try std.testing.expect(components.aiTaskAllowed(boe.ai_tasks, .territorial));
    try std.testing.expect(components.aiTaskAllowed(boe.ai_tasks, .approach_distraction));
    const rancher = t.byName("zombieRancher").?;
    try std.testing.expect(rancher.ai_tasks & set != 0);
    try std.testing.expect(!components.aiTaskAllowed(rancher.ai_tasks, .territorial));
    try std.testing.expect(!components.aiTaskAllowed(rancher.ai_tasks, .destroy_area));
    try std.testing.expect(components.aiTaskAllowed(rancher.ai_tasks, .approach_attack));
    try std.testing.expect(stag2.ai_tasks & set != 0);
    try std.testing.expect(components.aiTaskAllowed(stag2.ai_tasks, .runaway));
    try std.testing.expect(!components.aiTaskAllowed(stag2.ai_tasks, .approach_attack));
    try std.testing.expect(!components.aiTaskAllowed(stag2.ai_tasks, .break_block));
}

test "day/night speeds parse from entityclasses XML" {
    // Offline parse: MoveSpeedAggro "min, max" splits into day (min) / night
    // (max) chase (the stock XML comment "min/max (like day or night)");
    // MoveSpeedNight is the night shamble; a single aggro value applies to
    // both, and a class without MoveSpeedNight keeps 0 (falls to day at night
    // per entity-ai.md 3312 moveSpeedNight seeds from moveSpeed).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec2.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="ZombieBase">
        \\    <property name="MoveSpeed" value="0.08"/>
        \\    <property name="MoveSpeedAggro" value="0.2, 1.25"/>
        \\    <property name="MoveSpeedRand" value="-.2, .25"/>
        \\    <property name="SightLightThreshold" value="-2,150"/>
        \\    <property name="SleeperSightToWakeMin" value="-40,5"/>
        \\    <property name="SleeperSightToWakeMax" value="340,480"/>
        \\  </entity_class>
        \\  <entity_class name="zombieBoe" extends="ZombieBase">
        \\  </entity_class>
        \\  <entity_class name="animalZombieDog" extends="ZombieBase">
        \\    <property name="MoveSpeed" value=".45"/>
        \\    <property name="MoveSpeedNight" value=".3"/>
        \\    <property name="MoveSpeedAggro" value="1.2, 1.3"/>
        \\    <property name="SightLightThreshold" value="0,200"/>
        \\  </entity_class>
        \\  <entity_class name="zombieFlat">
        \\    <property name="MoveSpeed" value="0.1"/>
        \\    <property name="MoveSpeedAggro" value="0.5"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const boe = t.byName("zombieBoe").?;
    try std.testing.expectEqual(@as(f32, 0.08), boe.wander_speed);
    try std.testing.expectEqual(@as(f32, 0), boe.wander_speed_night); // seeded from MoveSpeed at night
    try std.testing.expectEqual(@as(f32, 1.25), boe.chase_speed); // aggro max = night chase
    try std.testing.expectEqual(@as(f32, 0.2), boe.chase_speed_day); // aggro min = day chase
    // SightLightThreshold inherits through extends (stock "-2,150").
    try std.testing.expectEqual(@as(f32, -2.0), boe.sight_light_min);
    try std.testing.expectEqual(@as(f32, 150.0), boe.sight_light_max);
    // SleeperSightToWakeMin/Max roll ranges (stock "-40,5" / "340,480").
    try std.testing.expectEqual(@as(f32, -40.0), boe.sleeper_wake_near_min);
    try std.testing.expectEqual(@as(f32, 5.0), boe.sleeper_wake_near_max);
    try std.testing.expectEqual(@as(f32, 340.0), boe.sleeper_wake_far_min);
    try std.testing.expectEqual(@as(f32, 480.0), boe.sleeper_wake_far_max);
    // MoveSpeedRand roll range (stock "-.2, .25", entity-ai.md 3318-3320).
    try std.testing.expectEqual(@as(f32, -0.2), boe.move_speed_rand_min);
    try std.testing.expectEqual(@as(f32, 0.25), boe.move_speed_rand_max);
    const dog = t.byName("animalZombieDog").?;
    try std.testing.expectEqual(@as(f32, 0.45), dog.wander_speed);
    try std.testing.expectEqual(@as(f32, 0.3), dog.wander_speed_night);
    try std.testing.expectEqual(@as(f32, 1.3), dog.chase_speed);
    try std.testing.expectEqual(@as(f32, 1.2), dog.chase_speed_day);
    try std.testing.expectEqual(@as(f32, 0.0), dog.sight_light_min);
    try std.testing.expectEqual(@as(f32, 200.0), dog.sight_light_max);
    const flat = t.byName("zombieFlat").?;
    try std.testing.expectEqual(@as(f32, 0.5), flat.chase_speed); // single value -> both
    try std.testing.expectEqual(@as(f32, 0.5), flat.chase_speed_day);
    try std.testing.expectEqual(@as(f32, 0.0), flat.move_speed_rand_min); // no prop -> no roll
    try std.testing.expectEqual(@as(f32, 0.0), flat.move_speed_rand_max);
    try std.testing.expectEqual(@as(f32, 0.0), flat.sight_light_min); // no prop -> 0,0 -> Rules floor
    try std.testing.expectEqual(@as(f32, 0.0), flat.sight_light_max);
}

test "AITask attack gating parses from entityclasses XML" {
    // Offline parse: attack-task presence is inherited through extends, and a
    // class with no AITask-* at all keeps the zombie-brain default (true).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="TimidBase">
        \\    <property name="AITask-1" value="RunawayWhenHurt"/>
        \\    <property name="AITask-2" value="Look"/>
        \\  </entity_class>
        \\  <entity_class name="animalDeer" extends="TimidBase">
        \\    <property name="AITask-3" value="Wander"/>
        \\  </entity_class>
        \\  <entity_class name="animalTemplateHostile">
        \\    <property name="AITask-1" value="BreakBlock"/>
        \\    <property name="AITask-2" value="ApproachAndAttackTarget"/>
        \\  </entity_class>
        \\  <entity_class name="animalWolf" extends="animalTemplateHostile">
        \\    <property name="MaxHealth" value="200"/>
        \\  </entity_class>
        \\  <entity_class name="mysteryNoTasks">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expect(!t.byName("animalDeer").?.ai_attack); // inherited timid list
    try std.testing.expect(t.byName("animalWolf").?.ai_attack); // hostile template
    try std.testing.expect(t.byName("mysteryNoTasks").?.ai_attack); // no list -> default
    try std.testing.expectEqual(@as(u16, 0), t.byName("mysteryNoTasks").?.ai_tasks);
    const deer = t.byName("animalDeer").?;
    try std.testing.expect(deer.ai_tasks & components.ai_task_list_set != 0);
    try std.testing.expect(components.aiTaskAllowed(deer.ai_tasks, .runaway));
    try std.testing.expect(components.aiTaskAllowed(deer.ai_tasks, .look));
    try std.testing.expect(components.aiTaskAllowed(deer.ai_tasks, .wander));
    try std.testing.expect(!components.aiTaskAllowed(deer.ai_tasks, .approach_attack));
}

test "pipe AITask blob replaces parent list and numbered keys merge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec_pipe.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="zombieTemplateMale">
        \\    <property name="AITask" value="
        \\    BreakBlock|
        \\    DestroyArea|
        \\    Territorial|
        \\    ApproachAndAttackTarget class=EntityPlayer,0|
        \\    Wander|
        \\    "/>
        \\  </entity_class>
        \\  <entity_class name="zombieBoe" extends="zombieTemplateMale">
        \\    <property name="MaxHealth" value="150"/>
        \\  </entity_class>
        \\  <entity_class name="zombieRancher" extends="zombieTemplateMale">
        \\    <property name="AITask" value="
        \\    BreakBlock|
        \\    ApproachAndAttackTarget class=EntityPlayer,0|
        \\    Wander|
        \\    "/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const boe = t.byName("zombieBoe").?;
    try std.testing.expect(boe.ai_attack);
    try std.testing.expect(components.aiTaskAllowed(boe.ai_tasks, .destroy_area));
    try std.testing.expect(components.aiTaskAllowed(boe.ai_tasks, .territorial));
    const rancher = t.byName("zombieRancher").?;
    try std.testing.expect(rancher.ai_attack);
    try std.testing.expect(!components.aiTaskAllowed(rancher.ai_tasks, .territorial));
    try std.testing.expect(!components.aiTaskAllowed(rancher.ai_tasks, .destroy_area));
    try std.testing.expect(components.aiTaskAllowed(rancher.ai_tasks, .break_block));
}

test "stock Demolition Explosion class parses (zombieFatCop tiers)" {
    // Ground truth = the V3.1.0 b14 stock file: the cop's <property
    // class="Explosion"> ships RadiusBlocks 5 / RadiusEntities 6 / BlockDamage
    // 500 / EntityDamage 150 with DamageBonus earth -> 0; the feral and
    // radiated tiers override only the damages.
    const path = stock_paths.configFile("entityclasses.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const cop = t.byName("zombieFatCop") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 5), cop.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 6), cop.explosion.radius_entities);
    try std.testing.expectEqual(@as(f32, 500), cop.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 150), cop.explosion.entity_damage);
    try std.testing.expect(cop.explosion.bonus_n >= 1);
    var earth_mult: f32 = 1;
    var bi: u8 = 0;
    while (bi < cop.explosion.bonus_n) : (bi += 1) {
        if (std.mem.eql(u8, cop.explosion.bonus_cat[bi], "earth")) earth_mult = cop.explosion.bonus_mult[bi];
    }
    try std.testing.expectEqual(@as(f32, 0), earth_mult);
    const feral = t.byName("zombieFatCopFeral") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 5), feral.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 650), feral.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 200), feral.explosion.entity_damage);
}

test "Explosion class resolves per field through Extends with DamageBonus" {
    // RE entity-ai.md §9.x: the Demolition blast comes from the nested
    // <property class="Explosion"> block; feral/radiated tiers override only
    // the damages and inherit radius + DamageBonus from the base class.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="zombieFatCop">
        \\    <property name="ExplodeHealthThreshold" value=".5"/>
        \\    <property class="Explosion">
        \\      <property name="RadiusBlocks" value="5"/>
        \\      <property name="RadiusEntities" value="6"/>
        \\      <property name="BlockDamage" value="500"/>
        \\      <property name="EntityDamage" value="150"/>
        \\      <property class="DamageBonus">
        \\        <property name="earth" value="0"/>
        \\        <property name="stone" value=".5"/>
        \\      </property>
        \\    </property>
        \\  </entity_class>
        \\  <entity_class name="zombieFatCopFeral" extends="zombieFatCop">
        \\    <property class="Explosion">
        \\      <property name="BlockDamage" value="650"/>
        \\      <property name="EntityDamage" value="200"/>
        \\    </property>
        \\  </entity_class>
        \\  <entity_class name="plainWalker">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();

    const base = t.byName("zombieFatCop").?;
    try std.testing.expectEqual(@as(f32, 0.5), base.explode_threshold);
    try std.testing.expectEqual(@as(f32, 5), base.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 6), base.explosion.radius_entities);
    try std.testing.expectEqual(@as(f32, 500), base.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 150), base.explosion.entity_damage);
    try std.testing.expectEqual(@as(u8, 2), base.explosion.bonus_n);
    try std.testing.expectEqualStrings("earth", base.explosion.bonus_cat[0]);
    try std.testing.expectEqual(@as(f32, 0), base.explosion.bonus_mult[0]);
    try std.testing.expectEqualStrings("stone", base.explosion.bonus_cat[1]);
    try std.testing.expectEqual(@as(f32, 0.5), base.explosion.bonus_mult[1]);

    // Feral overrides the damages; radius and bonuses inherit from the base.
    const feral = t.byName("zombieFatCopFeral").?;
    try std.testing.expectEqual(@as(f32, 5), feral.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 650), feral.explosion.block_damage);
    try std.testing.expectEqual(@as(f32, 200), feral.explosion.entity_damage);
    try std.testing.expectEqual(@as(u8, 2), feral.explosion.bonus_n);
    try std.testing.expectEqualStrings("earth", feral.explosion.bonus_cat[0]);

    // A class without the Explosion block never explodes (threshold stays 0)
    // and its blast params stay unset (Rules floor applies).
    const plain = t.byName("plainWalker").?;
    try std.testing.expectEqual(@as(f32, 0), plain.explode_threshold);
    try std.testing.expectEqual(@as(f32, 0), plain.explosion.radius_blocks);
    try std.testing.expectEqual(@as(f32, 0), plain.explosion.block_damage);
}

test "stock dismember and leg tuning parses (template, feral, radiated)" {
    // Ground truth = the live stock file: zombieTemplateMale ships
    // DismemberMultiplier 1/1/1, LegCrippleScale 2, LegCrawlerThreshold 0;
    // the feral tier overrides the multipliers to .7 and the radiated tier
    // to .4, inheriting the leg pair through Extends.
    const path = stock_paths.configFile("entityclasses.xml");
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const template = t.byName("zombieTemplateMale") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 1), template.dismember_head);
    try std.testing.expectEqual(@as(f32, 1), template.dismember_arms);
    try std.testing.expectEqual(@as(f32, 1), template.dismember_legs);
    try std.testing.expectEqual(@as(f32, 2), template.leg_cripple_scale);
    try std.testing.expectEqual(@as(f32, 0), template.leg_crawler_threshold);
    const feral = t.byName("zombieBoeFeral") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0.7), feral.dismember_head);
    try std.testing.expectEqual(@as(f32, 0.7), feral.dismember_arms);
    try std.testing.expectEqual(@as(f32, 0.7), feral.dismember_legs);
    try std.testing.expectEqual(@as(f32, 2), feral.leg_cripple_scale);
    const radiated = t.byName("zombieBoeRadiated") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 0.4), radiated.dismember_head);
    try std.testing.expectEqual(@as(f32, 0.4), radiated.dismember_arms);
    try std.testing.expectEqual(@as(f32, 0.4), radiated.dismember_legs);
}

test "dismember tuning resolves through Extends in an offline file" {
    // A base template ships the leg pair; the tier overrides only the
    // multipliers, so the leg values must inherit, not reset to 0.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec3.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="ZombieBase">
        \\    <property name="MaxHealth" value="100"/>
        \\    <property name="DismemberMultiplierHead" value="1"/>
        \\    <property name="DismemberMultiplierArms" value="1"/>
        \\    <property name="DismemberMultiplierLegs" value="1"/>
        \\    <property name="LegCrippleScale" value="2"/>
        \\    <property name="LegCrawlerThreshold" value="0.175"/>
        \\  </entity_class>
        \\  <entity_class name="bareWalker">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\  <entity_class name="zombieTier" extends="ZombieBase">
        \\    <property name="DismemberMultiplierHead" value=".7"/>
        \\    <property name="DismemberMultiplierArms" value=".7"/>
        \\    <property name="DismemberMultiplierLegs" value=".7"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const base = t.byName("ZombieBase").?;
    try std.testing.expectEqual(@as(f32, 1), base.dismember_head);
    try std.testing.expectEqual(@as(f32, 2), base.leg_cripple_scale);
    try std.testing.expectEqual(@as(f32, 0.175), base.leg_crawler_threshold);
    const tier = t.byName("zombieTier").?;
    try std.testing.expectEqual(@as(f32, 0.7), tier.dismember_head);
    try std.testing.expectEqual(@as(f32, 0.7), tier.dismember_arms);
    try std.testing.expectEqual(@as(f32, 0.7), tier.dismember_legs);
    try std.testing.expectEqual(@as(f32, 2), tier.leg_cripple_scale);
    try std.testing.expectEqual(@as(f32, 0.175), tier.leg_crawler_threshold);
    // A class with no dismember props at all reads 0 on every field: the
    // parse must not supply a value the stock file did not carry.
    const bare = t.byName("bareWalker").?;
    try std.testing.expectEqual(@as(f32, 0), bare.dismember_head);
    try std.testing.expectEqual(@as(f32, 0), bare.dismember_arms);
    try std.testing.expectEqual(@as(f32, 0), bare.dismember_legs);
    try std.testing.expectEqual(@as(f32, 0), bare.leg_cripple_scale);
    try std.testing.expectEqual(@as(f32, 0), bare.leg_crawler_threshold);
}

test "Leap maps to a native task and JumpMaxDistance parses" {
    // EAILeap needs both halves from entityclasses.xml: the task name in the
    // AITask list (so the class gains the leap bit) and the JumpMaxDistance
    // range bound that opens its distance window (stock zombieSpider "7, 9";
    // a class without the prop keeps the EntityClass cctor default 1.9/2.1,
    // under EAILeap's 2.8 m floor).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec_leap.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="pouncer">
        \\    <property name="JumpMaxDistance" value="7, 9"/>
        \\    <property name="AITask" value="Leap| BreakBlock| ApproachAndAttackTarget"/>
        \\  </entity_class>
        \\  <entity_class name="plainWalker">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const pouncer = t.byName("pouncer").?;
    try std.testing.expectEqual(@as(f32, 7), pouncer.jump_max_min);
    try std.testing.expectEqual(@as(f32, 9), pouncer.jump_max_max);
    try std.testing.expect(pouncer.ai_tasks & components.ai_task_list_set != 0);
    try std.testing.expect(components.aiTaskAllowed(pouncer.ai_tasks, .leap));
    try std.testing.expect(components.aiTaskAllowed(pouncer.ai_tasks, .break_block));
    try std.testing.expect(!components.aiTaskAllowed(pouncer.ai_tasks, .territorial));
    const plain = t.byName("plainWalker").?;
    try std.testing.expectEqual(@as(f32, 1.9), plain.jump_max_min);
    try std.testing.expectEqual(@as(f32, 2.1), plain.jump_max_max);
    try std.testing.expectEqual(@as(u16, 0), plain.ai_tasks);
}

test "RangedAttackTarget SetData params parse with stock ctor defaults" {
    // The spitter classes carry their window/cooldown/anim as attributes on
    // the AITask list entry (EAIRangedAttackTarget.SetData IL=64); a class
    // without the entry keeps the stock ctor defaults (startAnimType -1,
    // releaseDelay 0.5, minRange 4, maxRange 25, cooldown 3, attackDuration
    // 20 - EAIRangedAttackTarget::.ctor / Init).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/ec_ranged.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="spitterCop">
        \\    <property name="HandItem" value="meleeHandZombieCop"/>
        \\    <property name="AITask" value="BreakBlock| ApproachDistraction| RangedAttackTarget itemType=1;cooldown=6;duration=5;minRange=4;maxRange=27;startAnimType=2| ApproachAndAttackTarget"/>
        \\  </entity_class>
        \\  <entity_class name="spitterDefault">
        \\    <property name="AITask" value="BreakBlock| RangedAttackTarget| ApproachAndAttackTarget"/>
        \\  </entity_class>
        \\  <entity_class name="plainWalker">
        \\    <property name="MaxHealth" value="50"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const sp = t.byName("spitterCop").?;
    try std.testing.expectEqual(@as(f32, 6), sp.ranged_cooldown_s);
    try std.testing.expectEqual(@as(f32, 5), sp.ranged_duration_s);
    try std.testing.expectEqual(@as(f32, 4), sp.ranged_min_dist);
    try std.testing.expectEqual(@as(f32, 27), sp.ranged_max_dist);
    try std.testing.expectEqual(@as(i32, 2), sp.ranged_start_anim);
    try std.testing.expectEqual(@as(f32, 0.5), sp.ranged_release_delay_s);
    try std.testing.expect(sp.ai_tasks & components.ai_task_list_set != 0);
    try std.testing.expect(components.aiTaskAllowed(sp.ai_tasks, .ranged_attack_target));
    const dflt = t.byName("spitterDefault").?;
    try std.testing.expectEqual(@as(f32, 3), dflt.ranged_cooldown_s);
    try std.testing.expectEqual(@as(f32, 20), dflt.ranged_duration_s);
    try std.testing.expectEqual(@as(f32, 25), dflt.ranged_max_dist);
    try std.testing.expectEqual(@as(i32, -1), dflt.ranged_start_anim);
    const plain = t.byName("plainWalker").?;
    try std.testing.expectEqual(@as(u16, 0), plain.ai_tasks);
    // A mask without the list bit is the native table (aiTaskAllowed allows
    // every name); what refuses the task for such a class is the
    // `ai_tasks == 0` gate in rangedAttackCanExecute, so here the plain class
    // just keeps the stock ctor window.
    try std.testing.expectEqual(@as(f32, 4), plain.ranged_min_dist);
    try std.testing.expectEqual(@as(f32, 25), plain.ranged_max_dist);
}

test "AttackTimeoutDay/Night parse per class and through Extends" {
    // GetAttackTimeoutTicks IL=10 reads exactly these two floats, in seconds
    // (EntityClass cctor default 1); stock zombieTemplateMale ships 1.5 / 1.1.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/at.xml", .{dir});
    try io_fs.writeFile(path,
        \\<entity_classes>
        \\  <entity_class name="Base">
        \\    <property name="AttackTimeoutDay" value="1.5"/>
        \\    <property name="AttackTimeoutNight" value="1.1"/>
        \\  </entity_class>
        \\  <entity_class name="Child" extends="Base">
        \\    <property name="AttackTimeoutNight" value="0.8"/>
        \\  </entity_class>
        \\  <entity_class name="Junk">
        \\    <property name="AttackTimeoutDay" value="900"/>
        \\  </entity_class>
        \\</entity_classes>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    const base = t.byName("Base") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), base.attack_timeout_day, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), base.attack_timeout_night, 0.001);
    // Extends inherits the day arm and overrides the night one.
    const child = t.byName("Child") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), child.attack_timeout_day, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), child.attack_timeout_night, 0.001);
    // Out-of-range values are refused, not clamped into a blender.
    const junk = t.byName("Junk") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f32, 0), junk.attack_timeout_day, 0.001);
}
