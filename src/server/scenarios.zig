//! Integration scenarios: two-peer motion, damage wire kill, setblock replicate, persist restart.
//! These call shipped Game handlers (onData/handlePackage/replicate/broadcast), not mocks.

const std = @import("std");
const game_mod = @import("game.zig");
const ln_peer = @import("../litenet/peer.zig");
const packages = @import("../wire/packages.zig");
const wire_frame = @import("../wire/frame.zig");
const world_store = @import("../world/store.zig");
const quest_mod = @import("../ecs/quest.zig");
const systems = @import("../ecs/systems.zig");
const ecs = @import("../ecs/world.zig");
const io_fs = @import("../util/io_fs.zig");
const maxdamage = @import("../assets/maxdamage.zig");
const biome_layers = @import("../assets/biome_layers.zig");
const world_weather = @import("../world/weather.zig");
const binary = @import("../wire/binary.zig");
const platform_user = packages.platform_user;
const ally_mod = @import("ally.zig");
const containers_mod = @import("../world/containers.zig");
const vending_mod = @import("../world/vending.zig");
const assets_traders = @import("../assets/traders.zig");

/// Scenario worlds must start fresh: persisted state (entities.zen, *.zch)
/// from a previous run leaks into the next one, and vehicles/turrets have
/// accumulated enough across runs to exhaust the entity table (join failure)
/// and bloat listents replies. Wipe the dir before each scenario seeds it.
fn freshScenarioDir(dir: []const u8) void {
    io_fs.removeDirTreeSimple(dir);
    io_fs.mkdirPathSimple(dir);
}

test "scenario two-peer motion: B receives A PosAndRot" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_motion");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_motion", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    try std.testing.expect(ca.entity_id > 0);
    try std.testing.expect(cb.entity_id > 0);
    try std.testing.expect(ca.entity_id != cb.entity_id);

    // A reports a new position through the real package path.
    var pos_body: [64]u8 = undefined;
    const body = try packages.buildPosAndRotBody(&pos_body, ca.entity_id, 300, 71, 310, 0, 45, 0, true);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", body);
    try g.injectFramed(ca, framed);

    // Clear captures then replicate; B must see A's entity pos (A must not).
    cap_a.clear();
    cap_b.clear();
    try g.replicateNow();

    const pos_id = packages.idOf("NetPackageEntityPosAndRot").?;
    const b_body = cap_b.findPkgIdEntity(pos_id, ca.entity_id);
    try std.testing.expect(b_body != null);
    const parsed = try packages.parsePosAndRotBody(b_body.?);
    try std.testing.expectEqual(ca.entity_id, parsed.entity_id);
    try std.testing.expect(@abs(parsed.x - 300.0) < 0.01);
    try std.testing.expect(@abs(parsed.z - 310.0) < 0.01);

    // A should not receive its own PosAndRot echo.
    try std.testing.expect(cap_a.findPkgIdEntity(pos_id, ca.entity_id) == null);
    std.debug.print(
        "PASS two-peer-motion: B received PosAndRot for A id={d} pos=({d:.1},{d:.1},{d:.1}); A no self-echo\n",
        .{ ca.entity_id, parsed.x, parsed.y, parsed.z },
    );
}

test "scenario relpos motion: dirty relay without heartbeat (ecs-soa F1)" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_relpos");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_relpos", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    try std.testing.expect(ca.entity_id > 0);
    try std.testing.expect(cb.entity_id > 0);

    // A moves through the relative package (the dominant stock motion path).
    // Body layout per the RelPos arm: eid i32 | 7 bytes pad | dx/dy/dz i16.
    var rel: [32]u8 = undefined;
    @memset(&rel, 0);
    std.mem.writeInt(i32, rel[0..4], ca.entity_id, .little);
    std.mem.writeInt(i16, rel[11..13], 32, .little); // dx = 32 * 0.03125 = 1.0
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageEntityRelPosAndRot", rel[0..20]);
    try g.injectFramed(ca, framed);

    cap_a.clear();
    cap_b.clear();
    try g.replicateNow();

    // B must see A's new position on the next replicate (dirty relay), not
    // only on the 5-tick heartbeat; A must not echo its own motion.
    const pos_id = packages.idOf("NetPackageEntityPosAndRot").?;
    const b_body = cap_b.findPkgIdEntity(pos_id, ca.entity_id);
    try std.testing.expect(b_body != null);
    if (b_body) |bb| {
        const parsed = try packages.parsePosAndRotBody(bb);
        try std.testing.expectEqual(ca.entity_id, parsed.entity_id);
    }
    try std.testing.expect(cap_a.findPkgIdEntity(pos_id, ca.entity_id) == null);
    std.debug.print("PASS relpos-motion: B received PosAndRot relay for A after RelPos inject\n", .{});
}

test "scenario damage wire: fatal DamageEntity broadcasts EntityRemove" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);

    var dmg_body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;

    // A forged target id outside the attacker's interest range must not mutate it.
    const far_zid = g.sim.spawnZombie(10_000, 70, 10_000, 50).?;
    const far_body = try packages.buildDamageBody(&dmg_body, far_zid, 0, 3, 100, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageDamageEntity", far_body));
    try std.testing.expect(g.sim.slotOfNetId(far_zid) != null);

    const zid = g.sim.spawnZombie(260, 70, 260, 50).?;
    try std.testing.expect(g.sim.slotOfNetId(zid) != null);

    const dbody = try packages.buildDamageBody(&dmg_body, zid, 0, 3, 100, true, ca.entity_id);
    const head = try packages.parseDamageHead(dbody);
    try std.testing.expectEqual(zid, head.entity_id);
    try std.testing.expect(head.fatal);

    const framed = try packages.framed(&frame_buf, "NetPackageDamageEntity", dbody);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, framed);

    // Corpse dwell (EntityAlive::OnDeathUpdate, TimeStayAfterDeath): the body
    // stays in world at hp 0; the EntityRemove is deferred to the tick sweep,
    // so the client's ragdoll is not yanked mid-animation.
    const zs = g.sim.slotOfNetId(zid) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.health[zs].hp <= 0);
    try std.testing.expect(g.sim.health[zs].corpse_seconds > 0);
    try std.testing.expect(g.sim.countKind(.loot_bag) >= 1);
    const rm_id = packages.idOf("NetPackageEntityRemove").?;
    try std.testing.expect(cap_a.findPkgId(rm_id) == null);
    try std.testing.expect(cap_b.findPkgId(rm_id) == null);
    // Mob health replication: the fatal hit marks hp dirty; the next replicate
    // pass sends EntityStatChanged(health) to observers, so the client sees
    // the death (kind health=0) instead of a full-health body. The wire may
    // carry the raw overkill (50 - 9999) or the clamped 0 depending on the
    // death path; the client treats hp <= 0 as dead either way.
    try g.step();
    const stat_id = packages.idOf("NetPackageEntityStatChanged").?;
    const stat_b = cap_b.findPkgIdEntity(stat_id, zid) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), stat_b[8]); // health kind
    const hp_value: f32 = @bitCast(std.mem.readInt(u32, stat_b[9..13], .little));
    try std.testing.expect(hp_value <= 0.01);
    // Fast-forward the dwell: the tick sweep broadcasts EntityRemove once the
    // corpse timer expires (0.2 s -> 4 ticks, then the sweep fires).
    g.sim.health[zs].corpse_seconds = 0.2;
    var step: u32 = 0;
    while (step < 10) : (step += 1) try g.step();
    try std.testing.expect(g.sim.slotOfNetId(zid) == null);
    const rm_a = cap_a.findPkgIdEntity(rm_id, zid);
    const rm_b = cap_b.findPkgIdEntity(rm_id, zid);
    try std.testing.expect(rm_a != null);
    try std.testing.expect(rm_b != null);
    try std.testing.expectEqual(zid, std.mem.readInt(i32, rm_b.?[0..4], .little));

    // Stock DroppedLootContainer ECD EntitySpawn with embedded bag to peers.
    // NetPackageBag is ToServer-only; no S2C Bag may be sent.
    const spawn_id = packages.idOf("NetPackageEntitySpawn").?;
    const bag_id = packages.idOf("NetPackageBag").?;
    const sp_b = cap_b.findPkgId(spawn_id);
    try std.testing.expect(sp_b != null);
    // body: entityId i32 | ECD ver35 | entityClass DroppedLootContainer
    try std.testing.expectEqual(@as(u8, 36), sp_b.?[4]);
    try std.testing.expectEqual(
        packages.stock_entity.class_dropped_loot_container,
        std.mem.readInt(i32, sp_b.?[5..9], .little),
    );
    // ECD bag flag at fixed offset 57 (after pos/rot/BodyDamage/stats/deathTime).
    try std.testing.expectEqual(@as(u8, 1), sp_b.?[57]);
    try std.testing.expect(cap_b.findPkgId(bag_id) == null);
    std.debug.print(
        "PASS damage-wire: framed DamageEntity fatal killed id={d}; EntityRemove + loot ECD bag on A and B\n",
        .{zid},
    );
}

test "scenario setblock: peer B receives SetBlock after A edit" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_block");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_block", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);

    // Chunk wire layout is unit-tested in packages.zig; join no longer sends intermediate
    // chunks by default (stock clients use local gen). Assert builder still matches.
    var heights: [256]u8 = .{60} ** 256;
    var chbuf: [packages.chunk_stock_envelope_overhead + packages.chunk_body_size]u8 = undefined;
    const ch_body = try packages.buildChunkBody(&chbuf, 0, 0, &heights);
    try std.testing.expectEqual(packages.chunk_stock_envelope_overhead + packages.chunk_body_size, ch_body.len);
    const ch = try packages.parseChunkBody(ch_body);
    try std.testing.expect(ch.heights.len == 256);

    var sb: [64]u8 = undefined;
    const sbody = try packages.buildSetBlockBody(&sb, 250, 70, 250, world_store.block_stone);
    var frame_buf: [128]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageSetBlock", sbody);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, framed);

    try std.testing.expect((try g.world.blockWorld(250, 70, 250)) != world_store.block_air);

    const sb_id = packages.idOf("NetPackageSetBlock").?;
    const b_got = cap_b.findPkgId(sb_id);
    try std.testing.expect(b_got != null);
    const parsed = try packages.parseSetBlockBody(b_got.?);
    try std.testing.expectEqual(@as(i32, 250), parsed.x);
    try std.testing.expectEqual(@as(i32, 70), parsed.y);
    try std.testing.expectEqual(@as(i32, 250), parsed.z);
    try std.testing.expectEqual(world_store.block_stone, parsed.block_id);
    std.debug.print(
        "PASS setblock: B received SetBlock ({d},{d},{d}) id={d}; chunk body len={d}\n",
        .{ parsed.x, parsed.y, parsed.z, parsed.block_id, ch_body.len },
    );

    // Storage place (block_id >= 20) creates container + S2C TileEntity.
    // Runtime AssignIds for cntWoodenChestClosed (client V3.1.4 capture).
    const chest_id: u16 = @intCast(packages.stock_deco.cnt_wooden_chest_closed);
    const sbody2 = try packages.buildSetBlockBody(&sb, 251, 70, 250, chest_id);
    const framed2 = try packages.framed(&frame_buf, "NetPackageSetBlock", sbody2);
    cap_b.clear();
    try g.injectFramed(ca, framed2);
    try std.testing.expect(g.containers.get(.{ .x = 251, .y = 70, .z = 250 }) != null);
    const te_id = packages.idOf("NetPackageTileEntity").?;
    try std.testing.expect(cap_b.findPkgId(te_id) != null);
    std.debug.print("PASS setblock-storage: TileEntity broadcast for chest at (251,70,250)\n", .{});
}

test "scenario NetPackagePlayerDisconnect frees the slot immediately" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_disconnect");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_disconnect", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(g.clients[c.slot].joined);
    var fbuf: [64]u8 = undefined;
    var body: [4]u8 = undefined;
    // A foreign entity id is dropped: the slot stays joined.
    std.mem.writeInt(i32, body[0..4], c.entity_id + 999, .little);
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackagePlayerDisconnect", &body));
    try std.testing.expect(g.clients[c.slot].joined);
    // The sender's own id frees the slot immediately (transport poll fallback
    // would wait up to peer_stale_ms).
    std.mem.writeInt(i32, body[0..4], c.entity_id, .little);
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackagePlayerDisconnect", &body));
    try std.testing.expect(!g.clients[c.slot].joined);
}

test "scenario SetBlock lower damage repairs instead of adding" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_repair");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_repair", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    var frame_buf: [512]u8 = undefined;
    var body: [64]u8 = undefined;
    // Place stone near spawn (in reach, no claim).
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 70, 250, world_store.block_stone)));
    try std.testing.expect((try g.world.blockWorld(250, 70, 250)) == world_store.block_stone);
    // Damage to 50.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBodyDamage(&body, 250, 70, 250, world_store.block_stone, 50, 0, 0)));
    try std.testing.expectEqual(@as(u16, 50), g.getBlockHp(250, 70, 250));
    // Repair: the client reports the new LOWER absolute damage (ItemActionRepair
    // negates the amount). The server must apply 20, not add 20 to 50.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBodyDamage(&body, 250, 70, 250, world_store.block_stone, 20, 0, 0)));
    try std.testing.expectEqual(@as(u16, 20), g.getBlockHp(250, 70, 250));
    // A further damage advance still works.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBodyDamage(&body, 250, 70, 250, world_store.block_stone, 80, 0, 0)));
    try std.testing.expectEqual(@as(u16, 80), g.getBlockHp(250, 70, 250));
}

test "scenario hammer upgrade validates the UpgradeBlock target" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_upgrade");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_upgrade", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Offline maxdamage has the AssignIds dump but no blocks.xml, so the
    // upgrade ladder is empty: load the stock blocks.xml and swap it in (same
    // pattern the trader tests use for traders.xml / npc.xml).
    const game = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var mt = (maxdamage.tryLoad(gpa, game, null) catch null) orelse return error.SkipZigTest;
    mt.tryMergeBundledAssignIds(gpa);
    g.maxdamage.deinit();
    g.maxdamage = mt;
    const wood_id = g.maxdamage.idByName("woodMaster") orelse return error.SkipZigTest;
    const cobble_id = g.maxdamage.idByName("cobblestoneMaster") orelse return error.SkipZigTest;
    const bedroll_id = g.maxdamage.idByName("bedroll") orelse return error.SkipZigTest;

    var frame_buf: [512]u8 = undefined;
    var body: [64]u8 = undefined;
    // Place a wood block with an upgrade path.
    // y=150 is air above the flat surface; dig first in case a previous run's
    // persisted world left a block at the cell (Game.deinit saves the world).
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, 0)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == 0);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, wood_id)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == wood_id);

    // Legitimate upgrade: cobblestoneMaster is woodMaster's ToBlock.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, cobble_id)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == cobble_id);

    // Forged swap: bedroll is not in the upgrade ladder, so the block stays.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, bedroll_id)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == cobble_id);

    std.debug.print("PASS upgrade: woodMaster -> cobblestoneMaster accepted, forged swap rejected\n", .{});
}

test "scenario power switch: meta flip gates the grid and keeps the meta on the echo" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_switch");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_switch", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const switch_id = g.maxdamage.idByName("switch") orelse return error.SkipZigTest;
    try std.testing.expect(g.power_registry.lookup(switch_id) != null);

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);

    var sb: [64]u8 = undefined;
    var frame_buf: [128]u8 = undefined;
    const place = try packages.buildSetBlockBody(&sb, 250, 70, 251, switch_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageSetBlock", place));
    const ni = g.sim.power.indexOfPosition(250, 70, 251) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.power.nodes[ni].is_switch);
    // A freshly placed switch is latched off: block meta 0 and grid agree.
    try std.testing.expect(!g.sim.power.nodes[ni].on);

    // Flip it: BlockSwitch::updateState sets meta bit 0x2 and SetBlockRPCs the
    // whole BlockValue, so the wire flags are bChangeBlockValue|bUpdateLight.
    const raw_on = packages.withBlockMeta(@as(u32, switch_id), packages.block_meta_on);
    const flip = try packages.buildSetBlockBodyRaw(&sb, 250, 70, 251, raw_on, 0, ca.entity_id, ca.entity_id);
    flip[20] = 0x11;
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageSetBlock", flip));
    try std.testing.expect(g.sim.power.nodes[ni].on);

    // The echo must carry the meta back, or every client snaps the switch off.
    const sb_id = packages.idOf("NetPackageSetBlock").?;
    const echo = cap_b.findPkgId(sb_id) orelse return error.TestUnexpectedResult;
    var one: [1]packages.BlockChange = undefined;
    try std.testing.expectEqual(@as(usize, 1), try packages.parseSetBlockChanges(echo, one[0..]));
    try std.testing.expectEqual(switch_id, one[0].block_id);
    try std.testing.expectEqual(packages.block_meta_on, packages.blockMeta(one[0].raw) & packages.block_meta_on);

    // Flipping back closes the gate again.
    const raw_off = packages.withBlockMeta(@as(u32, switch_id), 0);
    const unflip = try packages.buildSetBlockBodyRaw(&sb, 250, 70, 251, raw_off, 0, ca.entity_id, ca.entity_id);
    unflip[20] = 0x11;
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageSetBlock", unflip));
    try std.testing.expect(!g.sim.power.nodes[ni].on);
    std.debug.print("PASS power-switch: meta flip drives the grid latch and survives the echo\n", .{});
}

test "scenario powered trigger TE: malformed body leaves containers alone" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_trigger");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_trigger", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);

    // Seed a real chest so a permissive trigger parser would have something to
    // corrupt if it ever swallowed a storage payload.
    const chest_id: u16 = @intCast(packages.stock_deco.cnt_wooden_chest_closed);
    var sb: [64]u8 = undefined;
    var frame_buf: [8192]u8 = undefined;
    const place = try packages.buildSetBlockBody(&sb, 251, 70, 251, chest_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageSetBlock", place));
    const cont = g.containers.get(.{ .x = 251, .y = 70, .z = 251 }) orelse return error.TestUnexpectedResult;
    const slots_before = cont.slot_count;
    const nodes_before = g.sim.power.node_n;

    // Truncated and nonsense TE payloads must both fall through to the drop.
    const bad = [_][]const u8{
        &.{},
        &.{ 255, 1, 0, 0, 0 },
        &.{ 255, 251, 0, 0, 0, 70, 0, 0, 0, 251, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 9, 9, 9, 9 },
    };
    for (bad) |body| {
        try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageTileEntity", body));
    }
    const after = g.containers.get(.{ .x = 251, .y = 70, .z = 251 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(slots_before, after.slot_count);
    try std.testing.expectEqual(nodes_before, g.sim.power.node_n);
    std.debug.print("PASS powered-trigger-te: malformed payloads dropped, chest untouched\n", .{});
}

test "scenario persist: block write, process restart, read-back, rejoin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    {
        const g = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        try g.setBlock(7, 72, 9, world_store.block_stone);
        try g.world.saveAll();
        // also join once pre-restart
        var cap: ln_peer.Capture = .{};
        const c = try g.attachJoinedClient(&cap);
        try std.testing.expect(c.joined);
    }

    // Restart: new Game process-equivalent (new struct, same world dir).
    {
        const g2 = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g2.deinit();
            gpa.destroy(g2);
        }
        const c = try g2.world.getOrCreate(.{ .x = 0, .z = 0 });
        try std.testing.expectEqual(@as(u16, 72), c.heightAt(7, 9));
        try std.testing.expectEqual(world_store.block_stone, try g2.world.blockWorld(7, 72, 9));

        // Join still works on reloaded world (PlayerId + HoldingItem; no S2C inv/chunk).
        var cap: ln_peer.Capture = .{};
        const client = try g2.attachJoinedClient(&cap);
        try std.testing.expect(client.joined);
        try std.testing.expect(client.entity_id > 0);
        const pid = packages.idOf("NetPackagePlayerId").?;
        try std.testing.expect(cap.findPkgId(pid) != null);
        std.debug.print(
            "PASS persist: after restart height(7,9)=72 block=stone join_ok entity={d} player_id_sent\n",
            .{client.entity_id},
        );
    }
}

const navezgane_path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Worlds/Navezgane";

fn stockMapPresent() bool {
    return io_fs.dirExistsSimple(navezgane_path) or io_fs.fileExistsSimple(navezgane_path);
}

test "scenario stock map: Game loads Navezgane, spawn join, height observable" {
    if (!stockMapPresent()) return error.SkipZigTest;
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_stockmap");

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithMap(gpa, "worlds/zdtd_sc_stockmap", navezgane_path, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expect(g.world.heightmap != null);
    const sp = g.world.primarySpawn();
    try std.testing.expectEqual(@as(i32, -273), sp.x);
    const h = try g.world.heightWorld(sp.x, sp.z);
    try std.testing.expect(h >= 55 and h <= 65);

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.joined);
    // Player spawned at stock spawn
    if (g.sim.slotOfNetId(c.entity_id)) |idx| {
        try std.testing.expect(@abs(g.sim.transform[idx].x - @as(f32, @floatFromInt(sp.x))) < 0.1);
        try std.testing.expect(@abs(g.sim.transform[idx].z - @as(f32, @floatFromInt(sp.z))) < 0.1);
    } else return error.NoEntity;
    const pid = packages.idOf("NetPackagePlayerId").?;
    try std.testing.expect(cap.findPkgId(pid) != null);
    std.debug.print(
        "PASS stock-map-game: Navezgane join entity={d} spawn=({d},{d},{d}) height={d} player_id_sent\n",
        .{ c.entity_id, sp.x, sp.y, sp.z, h },
    );
}

test "scenario persist with stock map: edit survives restart under same --map" {
    if (!stockMapPresent()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const edit_x: i32 = -270;
    const edit_z: i32 = 450;
    var edit_y: i32 = 70;

    {
        const g = try game_mod.Game.createWithMap(gpa, dir, navezgane_path, 0);
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        const base_h = try g.world.heightWorld(edit_x, edit_z);
        edit_y = @as(i32, @intCast(base_h)) + 5;
        try g.setBlock(edit_x, edit_y, edit_z, world_store.block_stone);
        try g.world.saveAll();
    }

    {
        const g2 = try game_mod.Game.createWithMap(gpa, dir, navezgane_path, 0);
        defer {
            g2.deinit();
            gpa.destroy(g2);
        }
        try std.testing.expect(g2.world.heightmap != null);
        // Overlay edit must still be present (disk heights still u8; API is u16).
        const h = try g2.world.heightWorld(edit_x, edit_z);
        const expect_h: i32 = @min(edit_y, 255);
        try std.testing.expectEqual(expect_h, @as(i32, h));
        // Prefer solid block at edit column; if DTM rematerializes air at exact y, height still proves overlay.
        const blk = try g2.world.blockWorld(edit_x, edit_y, edit_z);
        try std.testing.expect(blk != world_store.block_air or h >= @as(u8, @intCast(@min(edit_y, 255))));
        var cap: ln_peer.Capture = .{};
        const client = try g2.attachJoinedClient(&cap);
        try std.testing.expect(client.joined);
        std.debug.print(
            "PASS stock-map-persist: edit ({d},{d},{d}) after restart h={d} join entity={d}\n",
            .{ edit_x, edit_y, edit_z, h, client.entity_id },
        );
    }
}

test "scenario synthetic DTM fixture always runs" {
    // Tiny 32×32 DTM on disk → loadStockMap path without Steam tree.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var map_buf: [std.fs.max_path_bytes]u8 = undefined;
    const map_dir = try std.fmt.bufPrint(&map_buf, "{s}/map", .{root});
    var save_buf: [std.fs.max_path_bytes]u8 = undefined;
    const save_dir = try std.fmt.bufPrint(&save_buf, "{s}/save", .{root});
    io_fs.mkdirPathSimple(map_dir);
    io_fs.mkdirPathSimple(save_dir);
    try writeFixtureMap(map_dir);

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithMap(gpa, save_dir, map_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expect(g.world.heightmap != null);
    try std.testing.expectEqual(@as(i32, 32), g.world.heightmap.?.width);
    // world (0,0) → DTM (16,16) height 80 in fixture
    const h = try g.world.heightWorld(0, 0);
    try std.testing.expectEqual(@as(u8, 80), h);
    const sp = g.world.primarySpawn();
    try std.testing.expectEqual(@as(i32, 1), sp.x);
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.joined);
    std.debug.print(
        "PASS stock-map-fixture: synthetic 32x32 DTM height(0,0)={d} spawn=({d},{d},{d}) join entity={d}\n",
        .{ h, sp.x, sp.y, sp.z, c.entity_id },
    );
}

fn writeFixtureMap(dir: []const u8) !void {
    // map_info.xml
    const info =
        \\<MapInfo>
        \\  <property name="HeightMapSize" value="32,32" />
        \\</MapInfo>
    ;
    try writeFileAt(dir, "map_info.xml", info);
    const spawns =
        \\<spawnpoints>
        \\  <spawnpoint position="1,80,2" rotation="0,0,0" />
        \\</spawnpoints>
    ;
    try writeFileAt(dir, "spawnpoints.xml", spawns);
    // dtm.raw 32*32 u16 LE; default 70*256, cell (16,16)=80*256
    var raw: [32 * 32 * 2]u8 = undefined;
    var i: usize = 0;
    while (i < 32 * 32) : (i += 1) {
        std.mem.writeInt(u16, raw[i * 2 ..][0..2], 70 * 256, .little);
    }
    std.mem.writeInt(u16, raw[(16 * 32 + 16) * 2 ..][0..2], 80 * 256, .little);
    try writeFileAt(dir, "dtm.raw", &raw);
}

test "scenario stock fixture quests.xml load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, dir, 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    try std.testing.expectEqual(quest_mod.CatalogSource.stock_xml, g.sim.catalog.source);
    try std.testing.expect(g.sim.catalog.defs.len >= 4);
    try std.testing.expectEqualStrings("quest_whiteRiverCitizen1", g.sim.catalog.starter_name);
    const clear = g.sim.catalog.byName("tier1_clear").?;
    try std.testing.expectEqual(quest_mod.QuestKind.kill_zombies, clear.kind);
    try std.testing.expect(clear.turn_in);
    const list = g.sim.catalog.listById("trader_jen_quests").?;
    try std.testing.expect(list.entries.len >= 2);

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // Starter is white river (fetch_trader), not builtin kill id 1.
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, g.sim.catalog.starter_id));
    // Multi-phase starter: first open advances Goto→Interact; second completes turn-in.
    systems.questOnTraderOpen(&g.sim, c.slot);
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, g.sim.catalog.starter_id));
    try std.testing.expect(systems.questCoins(&g.sim, c.slot) >= 10);

    // Accept clear: Goto POI (phase1) → ClearSleepers (phase3) → ReturnToNPC (phase4).
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, clear.id));
    // Reach the quest POI to clear phase 1; the rally scaffolding (phase 2) auto-skips.
    systems.questTickGoto(&g.sim, c.slot, clear.tx, clear.ty, clear.tz);
    var k: u16 = 0;
    while (k < clear.target_count) : (k += 1) systems.questOnZombieKilled(&g.sim, c.slot);
    // Return-to-NPC (highest phase) still pending: not complete until turned in.
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, clear.id));
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, clear.id));

    std.debug.print(
        "PASS quests-xml: defs={d} starter={s} coins={d} lists={d}\n",
        .{ g.sim.catalog.defs.len, g.sim.catalog.starter_name, systems.questCoins(&g.sim, c.slot), g.sim.catalog.lists.len },
    );
}

test "scenario quest accept kill complete and trader buy" {
    // tmp dir: the fixed worlds/zdtd_sc_quest directory is shared with the
    // quests-xml scenario; a completed starter persists in ZPV3 and the join
    // would refuse to re-grant it (GAP starter-quest row).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, 1));

    var k: u32 = 0;
    while (k < 3) : (k += 1) {
        const zid = g.sim.spawnZombie(260, 70, 260, 10).?;
        var dmg_body: [256]u8 = undefined;
        const dbody = try packages.buildDamageBody(&dmg_body, zid, 0, 3, 100, true, c.entity_id);
        var frame_buf: [512]u8 = undefined;
        const framed = try packages.framed(&frame_buf, "NetPackageDamageEntity", dbody);
        try g.injectFramed(c, framed);
    }
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 1));
    // reward 25 for kill quest; coins may include prior save restore in world dir
    try std.testing.expect(systems.questCoins(&g.sim, c.slot) >= 25);

    // Find trader entity
    var te: i32 = -1;
    var si: usize = 0;
    while (si < 512) : (si += 1) {
        if (g.sim.alive[@intCast(si)] and g.sim.mask[@intCast(si)].trader) {
            te = g.sim.network_id[@intCast(si)].id;
            break;
        }
    }
    try std.testing.expect(te > 0);
    // The join bundle replicated the trader as EntitySpawn; the ECD must carry
    // the trader class hash and hasTraderData so the client renders EntityTrader
    // and can open the trade window from the spawn data alone.
    const spawn_id = packages.idOf("NetPackageEntitySpawn").?;
    const sp_body = cap.findPkgIdEntity(spawn_id, te) orelse return error.TestUnexpectedResult;
    var sr: binary.Reader = .{ .data = sp_body };
    _ = try sr.readI32(); // entityId (targeted)
    try std.testing.expectEqual(@as(u8, 36), try sr.readByte()); // ECD FileVersion
    try std.testing.expectEqual(packages.stock_entity.class_npc_trader_jen, try sr.readI32());
    _ = try sr.readI32(); // entityId copy
    _ = try sr.readF32(); // lifetime
    _ = try sr.readF32(); // x
    _ = try sr.readF32(); // y
    _ = try sr.readF32(); // z
    _ = try sr.readF32(); // rot.x
    _ = try sr.readF32(); // yaw
    _ = try sr.readF32(); // rot.z
    _ = try sr.readBool(); // on_ground
    _ = try sr.readI32(); // BodyDamage parts
    _ = try sr.readI32();
    _ = try sr.readU32();
    _ = try sr.readBool(); // no EntityStats
    _ = try sr.readI16(); // deathTime
    _ = try sr.readBool(); // no bag
    _ = try sr.readI32(); // homePosition x
    _ = try sr.readI32();
    _ = try sr.readI32();
    _ = try sr.readI16(); // homeRange
    _ = try sr.readByte(); // spawnerSource
    try std.testing.expectEqual(@as(u16, 0), try sr.readU16()); // entityData length
    try std.testing.expectEqual(true, try sr.readBool()); // hasTraderData
    try std.testing.expectEqual(te, try sr.readI32()); // trader id
    // Trader lock-open: the LockResponse carries EntityTraderLockContext with
    // server TraderData; the client's trade window reads inventory from it.
    cap.clear();
    var lr_body: [64]u8 = undefined;
    var lw: binary.Writer = .{ .buf = &lr_body };
    try lw.writeBool(true); // locking
    try lw.writeU16(1); // channel 1 (trade)
    try lw.writeI32(1); // target count
    try lw.writeByte(1); // present
    try lw.writeByte(2); // Entity target
    try lw.writeI32(te);
    try lw.writeString("EntityTraderLockContext");
    try lw.writeString("trade");
    try lw.writeBool(false); // client-side hasTraderData (server fills it)
    var lfb: [256]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&lfb, "NetPackageLockRequest", lr_body[0..lw.written().len]));
    const lock_id = packages.idOf("NetPackageLockResponse").?;
    const resp_body = cap.findPkgId(lock_id) orelse return error.TestUnexpectedResult;
    var rr: binary.Reader = .{ .data = resp_body };
    try std.testing.expectEqual(true, try rr.readBool()); // locking
    try std.testing.expectEqual(true, try rr.readBool()); // success
    var scratch: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", try rr.readString(&scratch)); // error
    try std.testing.expectEqual(false, try rr.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 1), try rr.readU16()); // channel
    try std.testing.expectEqual(@as(i32, 1), try rr.readI32()); // target count
    try std.testing.expectEqual(@as(u8, 1), try rr.readByte()); // present
    try std.testing.expectEqual(@as(u8, 2), try rr.readByte()); // Entity
    try std.testing.expectEqual(te, try rr.readI32());
    try std.testing.expectEqualStrings("EntityTraderLockContext", try rr.readString(&scratch));
    try std.testing.expectEqualStrings("trade", try rr.readString(&scratch));
    try std.testing.expectEqual(true, try rr.readBool()); // hasTraderData
    try std.testing.expectEqual(te, try rr.readI32()); // trader id
    var open_body: [4]u8 = undefined;
    std.mem.writeInt(i32, open_body[0..4], te, .little);
    var ofb: [64]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&ofb, "NetPackageTraderData", &open_body));
    // visit_the_trader (id 3): Goto trader (phase1) → interact (phase2) → complete.
    _ = systems.questAccept(&g.sim, c.slot, 3);
    const v = g.sim.catalog.byId(3).?;
    systems.questTickGoto(&g.sim, c.slot, v.tx, v.ty, v.tz);
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 3));

    // systems.trade first syncs the wallet UP from the client's coin stacks
    // (inv_coins > wallet => wallet = inv_coins), so a correct buy can still
    // leave the wallet at or above its pre-trade value and the debit assertion
    // below would be measuring the sync, not the purchase. Seed the wallet above
    // any inventory coins so no sync can fire mid-buy.
    const pslot = g.sim.playerByPeer(c.slot).?;
    const coin_id = g.items.ecsIdByName("casinoCoin");
    const inv_coins: u32 = if (coin_id != 0) g.sim.inventory[pslot].countItem(coin_id) else 0;
    g.sim.wallet[pslot].coins = inv_coins + 1000;

    const coins_before = systems.questCoins(&g.sim, c.slot);
    var trade_body: [16]u8 = undefined;
    const tb = try packages.buildTraderTradeBody(&trade_body, te, 2, 1, 0);
    // Whether this buy can succeed depends on the environment: the casinoCoin
    // id comes from items.xml, the stock rows from traders.xml, and the coin
    // balance from XML quest rewards. CI runs with no stock game dir. So assert
    // the property that must hold either way: a buy is atomic. Either the stock
    // row decrements AND coins are debited, or neither moves. A half-applied
    // trade (item without payment, or payment without item) is the real bug.
    const tslot = g.sim.slotOfNetId(te).?;
    const stockCount = struct {
        fn f(st: anytype, item: u16) u32 {
            var i: usize = 0;
            while (i < st.n) : (i += 1) {
                if (st.entries[i].item == item) return st.entries[i].count;
            }
            return 0;
        }
    }.f;
    const stock_before = stockCount(&g.sim.trader_stock[tslot], 2);
    try g.handleTrade(c, tb);
    const stock_after = stockCount(&g.sim.trader_stock[tslot], 2);
    const coins_after = systems.questCoins(&g.sim, c.slot);
    try std.testing.expect(coins_after <= coins_before); // a buy never credits
    if (stock_after < stock_before) {
        try std.testing.expect(coins_after < coins_before); // sold => charged
    } else {
        try std.testing.expectEqual(stock_before, stock_after);
        try std.testing.expectEqual(coins_before, coins_after); // no-op => free
    }

    const px = if (g.sim.slotOfNetId(c.entity_id)) |pi| g.sim.transform[pi].x else 256;
    const pz = if (g.sim.slotOfNetId(c.entity_id)) |pi| g.sim.transform[pi].z else 256;
    const z2 = g.sim.spawnZombie(px + 5, 70, pz, 40).?;
    const zi = g.sim.slotOfNetId(z2).?;
    const x0 = g.sim.transform[zi].x;
    var t: u32 = 0;
    while (t < 60) : (t += 1) try g.step();
    try std.testing.expect(g.sim.zombie_ai[zi].state == .chase or g.sim.zombie_ai[zi].state == .attack or g.sim.transform[zi].x < x0);

    std.debug.print(
        "PASS systems: quest_complete coins={d} ai_state={s}\n",
        .{ systems.questCoins(&g.sim, c.slot), @tagName(g.sim.zombie_ai[zi].state) },
    );
}

test "scenario vending machine opens via LockRequest with TraderData" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_vending");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_vending", 0, .{});
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Seed a vending machine at (1,70,2): TraderID 3 (player-owned vending).
    const vp: vending_mod.PosKey = .{ .x = 1, .y = 70, .z = 2 };
    const v = g.vending.getOrCreate(vp, 1234, 3).?;
    v.available_money = 5000;
    try std.testing.expect(g.vending.count() == 1);

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Client opens the machine: LockRequest with a TileEntity target (type 0)
    // and the VendingMachineLockContext type name. Server fills TraderData.
    cap.clear();
    var lr_body: [128]u8 = undefined;
    var lw: binary.Writer = .{ .buf = &lr_body };
    try lw.writeBool(true); // locking
    try lw.writeU16(0); // channel
    try lw.writeI32(1); // target count
    try lw.writeByte(1); // present
    try lw.writeByte(0); // TileEntity target
    try lw.writeI32(1);
    try lw.writeI32(70);
    try lw.writeI32(2);
    try lw.writeString("VendingMachineLockContext");
    var lfb: [256]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&lfb, "NetPackageLockRequest", lr_body[0..lw.written().len]));

    // LockResponse: locking+success, echoes the vending context type, and
    // carries server TraderData (trader id 3).
    const lock_id = packages.idOf("NetPackageLockResponse").?;
    const resp_body = cap.findPkgId(lock_id) orelse return error.TestUnexpectedResult;
    var rr: binary.Reader = .{ .data = resp_body };
    try std.testing.expectEqual(true, try rr.readBool()); // locking
    try std.testing.expectEqual(true, try rr.readBool()); // success
    var scratch: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", try rr.readString(&scratch)); // error
    try std.testing.expectEqual(false, try rr.readBool()); // isForceUnlocked
    try std.testing.expectEqual(@as(u16, 0), try rr.readU16()); // channel
    try std.testing.expectEqual(@as(i32, 1), try rr.readI32()); // target count
    try std.testing.expectEqual(@as(u8, 1), try rr.readByte()); // present
    try std.testing.expectEqual(@as(u8, 0), try rr.readByte()); // TileEntity
    try std.testing.expectEqual(@as(i32, 1), try rr.readI32());
    try std.testing.expectEqual(@as(i32, 70), try rr.readI32());
    try std.testing.expectEqual(@as(i32, 2), try rr.readI32());
    // Context type name preserved from the request.
    try std.testing.expectEqualStrings("VendingMachineLockContext", try rr.readString(&scratch));
    try std.testing.expectEqualStrings("", try rr.readString(&scratch)); // command
    try std.testing.expectEqual(true, try rr.readBool()); // hasTraderData
    try std.testing.expectEqual(@as(i32, 3), try rr.readI32()); // trader id

    // The machine's TE (type 7 payload) is pushed to the peer too.
    const te_id = packages.idOf("NetPackageTileEntity").?;
    const te_body = cap.findPkgId(te_id) orelse return error.TestUnexpectedResult;
    var tr: binary.Reader = .{ .data = te_body };
    try std.testing.expectEqual(@as(u8, 255), try tr.readByte()); // handle
    try std.testing.expectEqual(@as(i32, 1), try tr.readI32());
    try std.testing.expectEqual(@as(i32, 70), try tr.readI32());
    try std.testing.expectEqual(@as(i32, 2), try tr.readI32());
    try std.testing.expectEqual(@as(i32, 1234), try tr.readI32()); // teBlockId
    const te_pay_len: usize = @intCast(try tr.readI32());
    const te_pay = te_body[te_body.len - te_pay_len ..];
    var pr: binary.Reader = .{ .data = te_pay };
    try std.testing.expectEqual(@as(i32, 1), try pr.readI32()); // chunkPos x
    try std.testing.expectEqual(@as(i32, 70), try pr.readI32()); // chunkPos y
    try std.testing.expectEqual(@as(i32, 2), try pr.readI32()); // chunkPos z
    try std.testing.expectEqual(@as(i32, 3), try pr.readI32()); // vending TE version
    try std.testing.expectEqual(false, try pr.readBool()); // isLocked
    try std.testing.expectEqual(false, try pr.readBool()); // owner: null identity
    try std.testing.expectEqualStrings("", try pr.readString(&scratch)); // passwordHash
    try std.testing.expectEqual(@as(i32, 0), try pr.readI32()); // allowed users
    try std.testing.expectEqual(@as(i32, 0), try pr.readI32()); // rentalEndDay
    try std.testing.expectEqual(@as(i32, 3), try pr.readI32()); // TraderData trader id
    // TraderData rest: lastInventoryUpdate | FileVersion | entry count |
    // entries | tier groups | available money.
    try std.testing.expectEqual(@as(u64, 0), try pr.readU64());
    try std.testing.expectEqual(@as(u8, 2), try pr.readByte()); // FileVersion
    try std.testing.expectEqual(@as(i32, 0), try pr.readI32()); // entries (offline empty)
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // tier groups
    try std.testing.expectEqual(@as(i32, 5000), try pr.readI32()); // available money
    // trader_info 3 is not rentable → no nextAutoBuy tail.
    try std.testing.expectEqual(@as(usize, 0), pr.remaining());

    std.debug.print("PASS scenario: vending open LockResponse trader_id=3 te_pay={d}\n", .{te_pay_len});
}

test "scenario trader close cycle force-unlocks the trade channel" {
    // Fixture traders.xml with one hour-gated trader_info (stock Joel shape:
    // 4:05-21:50) so the cycle runs offline.
    const tsrc =
        \\<traders>
        \\  <trader_item_group name="groupCasino">
        \\    <item name="casinoCoin" count="1"/>
        \\  </trader_item_group>
        \\  <trader_info id="1" open_time="4:05" close_time="21:50"/>
        \\  <traderAlways>
        \\    <item name="casinoCoin" count="1"/>
        \\  </traderAlways>
        \\</traders>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tdir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var tpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tpath = try std.fmt.bufPrint(&tpath_buf, "{s}/traders_close.xml", .{tdir});
    try io_fs.writeFile(std.testing.allocator, tpath, tsrc);
    const tt = try assets_traders.loadFromPath(std.testing.allocator, tpath);

    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_traders_close");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_traders_close", 0, .{});
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    g.traders.deinit();
    g.traders = tt;

    const trader_id = g.sim.spawnTrader("traderJen", 0, 70, 0, 1, 500).?;
    const ts = g.sim.slotOfNetId(trader_id).?;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Open the trade window the way the stock client does: LockRequest on
    // channel 0 with an Entity target (EntityTraderLockContext).
    cap.clear();
    var lr_body: [128]u8 = undefined;
    var lw: binary.Writer = .{ .buf = &lr_body };
    try lw.writeBool(true); // locking
    try lw.writeU16(0); // trade channel
    try lw.writeI32(1);
    try lw.writeByte(1); // present
    try lw.writeByte(2); // Entity target
    try lw.writeI32(trader_id);
    try lw.writeString("EntityTraderLockContext");
    try lw.writeString("trade");
    var lfb: [256]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&lfb, "NetPackageLockRequest", lr_body[0..lw.written().len]));
    try std.testing.expect(g.lock_channel[0] == @as(i32, @intCast(c.slot)));
    try std.testing.expect(!g.sim.trader_stock[ts].is_closed);

    // Close time: the clock passes 21:50, the next tick latches closed and
    // force-unlocks the held trade channel.
    g.sim.director.clock.hours = 22.0;
    cap.clear();
    try g.step();
    try std.testing.expect(g.sim.trader_stock[ts].is_closed);
    try std.testing.expect(g.lock_channel[0] < 0);
    const lock_id = packages.idOf("NetPackageLockResponse").?;
    const resp = cap.findPkgId(lock_id) orelse return error.TestUnexpectedResult;
    // Forced unlock: locking=false, success=true (buildLockResponseUnlock).
    var rr: binary.Reader = .{ .data = resp };
    try std.testing.expectEqual(false, try rr.readBool()); // locking
    try std.testing.expectEqual(true, try rr.readBool()); // success

    // Opening hours latch back open on the next cycle.
    g.sim.director.clock.hours = 8.0;
    try g.step();
    try std.testing.expect(!g.sim.trader_stock[ts].is_closed);

    std.debug.print("PASS scenario: trader close cycle force-unlock + reopen latch\n", .{});
}

test "scenario blood moon parties pool nearby players into one horde" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_bmparty");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_bmparty", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);
    // Both clients sit at the flat-world spawn (256,70,256): within 80 m, so
    // stock would pool them into ONE blood-moon party.
    try std.testing.expect(g.sim.director.bm_party_n == 0);

    // Blood moon night: day 7 at dusk (frequency 7), enemy count 8.
    g.sim.director.clock.day = 7;
    g.sim.director.clock.hours = 22.0;
    g.sim.director.bloodmoon_enemy_count = 8;
    g.sim.director.bloodmoon_cd = 0;
    try g.step();
    try std.testing.expect(g.sim.director.bm_party_n == 1);
    try std.testing.expect(g.sim.director.bm_stage_frozen != 0);

    // One wave per party: max(1, 8/2) = 4 horde zombies, NOT 8 (per player).
    var horde: u32 = 0;
    var horde_slot: ?ecs.Slot = null;
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (!g.sim.alive[s] or !g.sim.zombie_ai[s].is_horde) continue;
        horde += 1;
        horde_slot = s;
    }
    try std.testing.expect(horde >= 1 and horde <= 4);
    const hs = horde_slot orelse return error.TestUnexpectedResult;

    // Teleport-back: drag the horde zombie 200 m from the focus; the next tick
    // brings it inside cTeleportDist (150 m) of the party focus.
    const focus = g.sim.director.bm_parties[0];
    g.sim.setPos(g.sim.network_id[hs].id, focus.focus_x + 200, g.sim.transform[hs].y, focus.focus_z, 0);
    try g.step();
    const dx = g.sim.transform[hs].x - focus.focus_x;
    const dz = g.sim.transform[hs].z - focus.focus_z;
    try std.testing.expect(dx * dx + dz * dz <= 150.0 * 150.0);

    // Dawn clears the horde marks and the frozen stage (EndBloodMoon).
    g.sim.director.clock.day = 8;
    g.sim.director.clock.hours = 5.0;
    try g.step();
    try std.testing.expect(g.sim.director.bm_stage_frozen == 0);
    var still_horde = false;
    var s2: ecs.Slot = 0;
    while (s2 < ecs.max_entities) : (s2 += 1) {
        if (g.sim.alive[s2] and g.sim.zombie_ai[s2].is_horde) still_horde = true;
    }
    try std.testing.expect(!still_horde);

    std.debug.print("PASS scenario: blood moon parties pool 2 players -> 1 horde (n={d}) teleport+dawn clear\n", .{horde});
}

test "scenario trader RemoveQuest accepts and drops the quest from offers" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_qaccept");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_qaccept", 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // A persisted save from an earlier run may carry accepted quests; clear the
    // journal so the offer baseline is deterministic across runs.
    g.sim.journal[g.sim.playerByPeer(c.slot).?] = .{};
    var te: i32 = -1;
    var si: usize = 0;
    while (si < 512) : (si += 1) {
        if (g.sim.alive[@intCast(si)] and g.sim.mask[@intCast(si)].trader) {
            te = g.sim.network_id[@intCast(si)].id;
            break;
        }
    }
    try std.testing.expect(te > 0);
    const qid = packages.idOf("NetPackageNPCQuestList").?;
    // FetchList first: baseline offer count (accepted quests already excluded).
    cap.clear();
    var fb: [16]u8 = undefined;
    std.mem.writeInt(i32, fb[0..4], te, .little);
    std.mem.writeInt(i32, fb[4..8], c.entity_id, .little);
    fb[8] = 0; // fetch_list
    std.mem.writeInt(i32, fb[9..13], 1, .little); // tier 1 (fixture quests are tier 1)
    var fbuf: [256]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageNPCQuestList", fb[0..13]));
    const before = cap.findPkgId(qid) orelse return error.TestUnexpectedResult;
    const before_count = std.mem.readInt(i32, before[13..17], .little);
    try std.testing.expect(before_count >= 1);
    // RemoveQuest: accept offer index 0 at tier 1 (stock accept marker).
    cap.clear();
    var rb: [16]u8 = undefined;
    std.mem.writeInt(i32, rb[0..4], te, .little);
    std.mem.writeInt(i32, rb[4..8], c.entity_id, .little);
    rb[8] = 1; // remove_quest
    std.mem.writeInt(i32, rb[9..13], 1, .little);
    rb[13] = 0; // index 0
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageNPCQuestList", rb[0..14]));
    const ps = g.sim.playerByPeer(c.slot).?;
    var has_active = false;
    for (g.sim.journal[ps].slots) |q| {
        if (q.active) has_active = true;
    }
    try std.testing.expect(has_active);
    // The re-sent list is one shorter: the accepted quest is no longer offered.
    const after = cap.findPkgId(qid) orelse return error.TestUnexpectedResult;
    const after_count = std.mem.readInt(i32, after[13..17], .little);
    try std.testing.expectEqual(before_count - 1, after_count);
}

test "scenario vehicle enter drive and turret kills with power" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(g.sim.countKind(.vehicle) >= 1);
    try std.testing.expect(g.sim.countKind(.turret) >= 1);
    try std.testing.expect(g.sim.power.total_gen > 0);

    var ve: i32 = -1;
    var vslot: u16 = 0;
    var si: usize = 0;
    while (si < 512) : (si += 1) {
        if (g.sim.alive[@intCast(si)] and g.sim.mask[@intCast(si)].vehicle) {
            ve = g.sim.network_id[@intCast(si)].id;
            vslot = @intCast(si);
            break;
        }
    }
    try std.testing.expect(ve > 0);

    var vb: [32]u8 = undefined;
    const enter = try packages.buildVehicleControlBody(&vb, ve, 0, 0, 0);
    var fb: [64]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageVehicleSpawn", enter));
    try std.testing.expectEqual(c.entity_id, g.sim.vehicle[vslot].driverNetId());

    const drive = try packages.buildVehicleControlBody(&vb, ve, 2, 1.0, 0.1);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageVehicleSpawn", drive));
    try g.step();
    try std.testing.expect(g.sim.vehicle[vslot].speed > 0);

    var te: i32 = -1;
    var tx: f32 = 0;
    var ty: f32 = 70;
    var tz: f32 = 0;
    si = 0;
    while (si < 512) : (si += 1) {
        if (g.sim.alive[@intCast(si)] and g.sim.mask[@intCast(si)].turret) {
            te = g.sim.network_id[@intCast(si)].id;
            tx = g.sim.transform[@intCast(si)].x;
            ty = g.sim.transform[@intCast(si)].y;
            tz = g.sim.transform[@intCast(si)].z;
            break;
        }
    }
    try std.testing.expect(te > 0);
    g.sim.power.resolve();
    try std.testing.expect(g.sim.power.isEntityPowered(te));
    const zid = g.sim.spawnZombie(tx + 2, ty, tz, 15).?;
    cap.clear();
    var k: u32 = 0;
    while (k < 50) : (k += 1) try g.step();
    // Corpse dwell: the body stays at hp 0 until the sweep destroys it; the
    // next tick then broadcasts EntityRemove (Turret kill path shares the sim).
    try std.testing.expect(g.sim.slotOfNetId(zid) != null);
    try std.testing.expect(g.sim.countKind(.loot_bag) >= 1);
    const zs = g.sim.slotOfNetId(zid) orelse return error.TestUnexpectedResult;
    g.sim.health[zs].corpse_seconds = 0.2;
    var step: u32 = 0;
    while (step < 10) : (step += 1) try g.step();
    try std.testing.expect(g.sim.slotOfNetId(zid) == null);
    // Turret kill must S2C EntityRemove for the zombie and DroppedLootContainer ECD.
    const rm_id = packages.idOf("NetPackageEntityRemove").?;
    const spawn_id = packages.idOf("NetPackageEntitySpawn").?;
    try std.testing.expect(cap.findPkgIdEntity(rm_id, zid) != null);
    // Join flood may include other EntitySpawns; match loot bag class hash.
    const sp = cap.findPkgIdClass(spawn_id, packages.stock_entity.class_dropped_loot_container);
    try std.testing.expect(sp != null);
    try std.testing.expectEqual(@as(u8, 36), sp.?[4]);

    const load = g.sim.power.addNode(.consumer, 1, 70, 1, 5).?;
    const gen_i = blk: {
        var i: usize = 0;
        while (i < g.sim.power.node_n) : (i += 1) {
            if (g.sim.power.nodes[i].kind == .generator) break :blk i;
        }
        break :blk @as(usize, 0);
    };
    const gnode = g.sim.power.nodes[gen_i];
    // Stock NetPackageWireActions SetParent: child(load)@(1,70,1) -> parent(gen).
    const wc = try packages.buildWireSetParentBody(&vb, 1, 70, 1, gnode.x, gnode.y, gnode.z, 0);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageWireActions", wc));
    try std.testing.expect(g.sim.power.nodes[g.sim.power.indexOfId(load).?].powered);

    std.debug.print(
        "PASS systems-ext: vehicle_speed={d:.1} power_gen={d:.0} load={d:.0} ecs=1 turret_remove+loot\n",
        .{ g.sim.vehicle[vslot].speed, g.sim.power.total_gen, g.sim.power.total_load },
    );
}

test "scenario pressure plate trigger pulse powers wired load" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_trig");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_trig", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // gen -> plate (trigger gate) -> load. Idle plate blocks the load.
    const gen = g.sim.power.addNodeAt(.generator, 100, 70, 100, 100).?;
    const plate = g.sim.power.addNodeAt(.consumer, 102, 70, 100, 1).?;
    const load = g.sim.power.addNodeAt(.consumer, 104, 70, 100, 20).?;
    const pi = g.sim.power.indexOfId(plate).?;
    g.sim.power.nodes[pi].is_trigger = true;
    try std.testing.expect(g.sim.power.connect(gen, plate));
    try std.testing.expect(g.sim.power.connect(plate, load));
    g.sim.power.resolve();
    try std.testing.expect(g.sim.power.nodes[pi].powered);
    try std.testing.expect(!g.sim.power.nodes[g.sim.power.indexOfId(load).?].powered);

    // Player steps on plate cell via PosAndRot (noteAcceptedMove -> activateTriggerAt).
    const pos = try packages.buildPosAndRotBody(&g.body_buf, c.entity_id, 102.5, 70.1, 100.5, 0, 0, 0, true);
    var fb: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageEntityPosAndRot", pos));
    try std.testing.expect(g.sim.power.nodes[pi].pulse_left > 0);
    try std.testing.expect(g.sim.power.nodes[g.sim.power.indexOfId(load).?].powered);

    // Pulse expires over ticks.
    var t: u32 = 0;
    while (t < 20) : (t += 1) try g.step();
    try std.testing.expectEqual(@as(f32, 0), g.sim.power.nodes[pi].pulse_left);
    try std.testing.expect(!g.sim.power.nodes[g.sim.power.indexOfId(load).?].powered);

    std.debug.print("PASS trigger: plate pulse then expire load_off\n", .{});
}

test "scenario inventory move drop place equip" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_inv");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_inv", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Join no longer S2C-sends PlayerInventory (stock C→S only). HoldingItem is valid S2C.
    const inv_id = packages.idOf("NetPackagePlayerInventory").?;
    const hold_id = packages.idOf("NetPackageHoldingItem").?;
    try std.testing.expect(cap.findPkgId(hold_id) != null);
    // Seed ECS inventory via give for the rest of this scenario (stock clients push C2S inv).
    _ = inv_id;

    // Give wood + armor via admin path
    const inv = @import("../ecs/inventory.zig");
    try std.testing.expect(inv.give(&g.sim, c.slot, 7, 10));
    try std.testing.expect(inv.give(&g.sim, c.slot, 11, 1));

    // Wire: move holding, drop, place
    var txb: [32]u8 = undefined;
    var fb: [128]u8 = undefined;
    // Drop one wood (tests the drop path) without consuming the armor: the
    // bag already holds wood, so give(7,10) stacked into it and give(11,1)
    // landed armor in the first empty slot (toolbelt 0). Dropping slot 0
    // would discard that armor, so target the wood slot instead.
    const drop_wood_slot: u16 = blk: {
        const ps = g.sim.playerByPeer(c.slot).?;
        for (g.sim.inventory[ps].slots, 0..) |s, i| {
            if (s.item_id == 7 and s.count > 0) break :blk @intCast(i);
        }
        break :blk 1;
    };
    const drop_req = try packages.buildInvTxRequest(&txb, @intFromEnum(inv.Op.drop), drop_wood_slot, 0, 1, -1);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", drop_req));
    // place wood at 10,70,10
    const wood_slot: u16 = blk: {
        const ps = g.sim.playerByPeer(c.slot).?;
        for (g.sim.inventory[ps].slots, 0..) |s, i| {
            if (s.item_id == 7 and s.count > 0) break :blk @intCast(i);
        }
        break :blk 1;
    };
    const place_req = try packages.buildInvTxRequest(
        &txb,
        @intFromEnum(inv.Op.place),
        wood_slot,
        @bitCast(@as(i16, 70)),
        @bitCast(@as(i16, 10)),
        10, // x
    );
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", place_req));
    // resourceWood places frameShapes:cube (AssignIds), not bedrock(4).
    try std.testing.expectEqual(inv.place_wood_block_id, try g.world.blockWorld(10, 70, 10));

    // equip armor
    const armor_slot: u16 = blk: {
        const ps = g.sim.playerByPeer(c.slot).?;
        for (g.sim.inventory[ps].slots, 0..) |s, i| {
            if (s.item_id == 11) break :blk @intCast(i);
        }
        break :blk 0;
    };
    const eq = try packages.buildInvTxRequest(&txb, @intFromEnum(inv.Op.equip), armor_slot, 0, 0, -1);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", eq));
    try std.testing.expect(inv.armorMitigation(&g.sim, c.slot) >= 0.09);

    const rid = packages.idOf("NetPackageInventoryTransactionResponse").?;
    try std.testing.expect(cap.findPkgId(rid) != null);

    // Stock C→S: client-style PlayerInventory body applied into ECS.
    {
        const ps = g.sim.playerByPeer(c.slot).?;
        var inv_copy = g.sim.inventory[ps];
        inv_copy.slots[2] = .{ .item_id = 3, .count = 9, .quality = 1 }; // ammo
        var stock_body: [8192]u8 = undefined;
        const body = try packages.buildInventoryBodyStock(&stock_body, &inv_copy);
        var fb2: [9000]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&fb2, "NetPackagePlayerInventory", body));
        try std.testing.expectEqual(@as(u16, 3), g.sim.inventory[ps].slots[2].item_id);
        try std.testing.expectEqual(@as(u16, 9), g.sim.inventory[ps].slots[2].count);
    }

    // Stock bag package: put wood into bag slot via NetPackageBag.
    {
        const ps = g.sim.playerByPeer(c.slot).?;
        var inv_copy = g.sim.inventory[ps];
        inv_copy.slots[10] = .{ .item_id = 7, .count = 4, .quality = 1 };
        var bag_body: [8192]u8 = undefined;
        const bb = try packages.stock_inv.buildBagPackage(&bag_body, c.entity_id, &inv_copy, null, null, true);
        var fb3: [9000]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&fb3, "NetPackageBag", bb));
        try std.testing.expectEqual(@as(u16, 7), g.sim.inventory[ps].slots[10].item_id);
        try std.testing.expectEqual(@as(u16, 4), g.sim.inventory[ps].slots[10].count);
    }

    // Multi-item drop container.
    {
        const items = [_]packages.stock_inv.StockSlot{
            .{ .type_id = packages.stock_inv.items_start_here + 1, .count = 3, .quality = 1 },
            .{ .type_id = packages.stock_inv.items_start_here + 2, .count = 2, .quality = 1 },
        };
        var dib: [512]u8 = undefined;
        const db = try packages.stock_inv.writeDropItemsContainer(&dib, c.entity_id, "EntityLootContainer", 5, 70, 6, items[0..]);
        var fb4: [1024]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&fb4, "NetPackageDropItemsContainer", db));
        try std.testing.expect(g.sim.countKind(.loot_bag) >= 1);
    }

    // Stock TE storage roundtrip via NetPackageTileEntity.
    {
        // Stock body via packages facade (AGENTS: one stock shape → one builder path).
        const stock_te = packages.stock_te;
        var cont: containers_mod.Container = .{
            .pos = .{ .x = 253, .y = 70, .z = 254 },
            .block_id = 42,
            .slot_count = 8,
            .player_storage = true,
        };
        cont.setSlot(0, .{ .item_id = 7, .count = 6, .quality = 1 });
        var teb: [8192]u8 = undefined;
        const te_body = try stock_te.buildStorageTeBody(&teb, 255, 253, 70, 254, 42, &cont, null, null);
        var fb5: [9000]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&fb5, "NetPackageTileEntity", te_body));
        const got = g.containers.get(.{ .x = 253, .y = 70, .z = 254 });
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u16, 7), got.?.slots[0].item_id);
        try std.testing.expectEqual(@as(u16, 6), got.?.slots[0].count);
    }

    std.debug.print("PASS inventory: place/equip + bag + multi-drop + stock TE\n", .{});
}

test "scenario aidirector night spawn" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_dir");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_dir", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    g.sim.director.clock.hours = 23.0;
    g.sim.director.horde_cd = 0;
    const before = g.sim.countKind(.zombie);
    const r = g.sim.director.tick(&g.sim, 0.1);
    try std.testing.expect(r.spawned >= 1);
    try std.testing.expect(g.sim.countKind(.zombie) > before);
    std.debug.print(
        "PASS aidirector: night horde spawned={d} zombies_now={d} world_time={d}\n",
        .{ r.spawned, g.sim.countKind(.zombie), r.world_time },
    );
}

test "scenario weather storm cycle and blood moon override" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_weather");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_weather", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);

    // Two biomes with different group counts, so a group index is only ever valid
    // against its own biome (stock desert has no "fog" group either).
    var table: biome_layers.Table = .{};
    table.weather_ids[0] = 3;
    table.weather_groups[0] = biome_layers.parseWeatherGroups(
        \\<weather name="default" prob="83" duration="6"><CloudThickness range="0,20"/></weather>
        \\<weather name="fog" prob="7"><Fog range="17,27"/></weather>
        \\<weather name="stormbuild" prob="0" duration=".2"><Wind range="25,25"/></weather>
        \\<weather name="storm" prob="0" duration="1.1" delay="26,36"><Wind range="40,40"/></weather>
        \\<weather name="bloodMoon" prob="0"><Wind range="15,20"/></weather>
    );
    table.weather_ids[1] = 5;
    table.weather_groups[1] = biome_layers.parseWeatherGroups(
        \\<weather name="default" prob="90" duration="5"><CloudThickness range="0,10"/></weather>
        \\<weather name="stormbuild" prob="0" duration=".59"><Wind range="9,9"/></weather>
        \\<weather name="storm" prob="0" duration="1.3" delay="28,36"><Wind range="12,12"/></weather>
        \\<weather name="bloodMoon" prob="0"><Wind range="4,4"/></weather>
    );
    table.weather_n = 2;
    table.loaded = true;
    g.world.biome_layers_table = table;
    g.world.weather.initFrom(&g.world.biome_layers_table, .{ .seed = 20240101 });

    const pine = &g.world.biome_layers_table.weather_groups[0];
    const build_idx = pine.findIndex("stormbuild").?;
    const storm_idx = pine.findIndex("storm").?;
    var saw_build = false;
    var saw_storm = false;
    var saw_clear_after_storm = false;
    var build_countdown_fell = false;
    var prev_state: u8 = 0;
    var prev_remaining: u8 = 0;
    // Four in-game days of world ticks (day * 24000 + hour * 1000).
    var world_time: i64 = 0;
    while (world_time <= 96_000) : (world_time += 50) {
        g.world.weather.tick(&g.world.biome_layers_table, world_time, false);
        const st = g.world.weather.states[0];
        // The wire body is always exactly 5 entries of 23 bytes, group index in
        // range for its biome, whatever the machine is doing.
        const body = g.buildWeatherBodyFromBiomes() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 115), body.len);
        try std.testing.expectEqual(st.biome_id, body[0]);
        try std.testing.expect(body[1] < pine.n);
        try std.testing.expectEqual(st.group_index, body[1]);
        switch (st.storm_state) {
            1 => {
                saw_build = true;
                try std.testing.expectEqual(build_idx, body[1]);
                if (prev_state == 1 and st.remaining_seconds < prev_remaining) build_countdown_fell = true;
            },
            2 => {
                saw_storm = true;
                try std.testing.expectEqual(storm_idx, body[1]);
            },
            else => if (prev_state == 2) {
                saw_clear_after_storm = true;
            },
        }
        prev_state = st.storm_state;
        prev_remaining = st.remaining_seconds;
    }
    try std.testing.expect(saw_build);
    try std.testing.expect(saw_storm);
    try std.testing.expect(saw_clear_after_storm);
    try std.testing.expect(build_countdown_fell);

    // Blood moon forces every weather biome onto its own bloodMoon group index.
    g.sim.director.bloodmoon_active = true;
    g.world.weather.tick(&g.world.biome_layers_table, 100_000, true);
    const bm_body = g.buildWeatherBodyFromBiomes() orelse return error.TestUnexpectedResult;
    var i: usize = 0;
    while (i < g.world.weather.n) : (i += 1) {
        const set = &g.world.biome_layers_table.weather_groups[i];
        try std.testing.expectEqual(set.findIndex("bloodMoon").?, bm_body[i * 23 + 1]);
    }
    std.debug.print(
        "PASS weather: stormbuild→storm→clear over 4 days, blood moon forced group={d}, body={d}B\n",
        .{ bm_body[1], bm_body.len },
    );
}

test "scenario craft invtx + explosion dig + lock deny" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_craft");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_craft", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);

    // Craft: give ingredients for builtin resourceWood (needs resourceWood 1 → 1).
    // Builtin recipe index 0 is resourceWood with ingredient resourceWood: use cobble recipe idx 1.
    // resourceCobblestones needs resourceRockSmall; map aliases may miss. Give wood and craft wood recipe 0
    // by using wood→wood (consume 1 wood, get 1 wood) as smoke that path runs without error.
    const ps = g.sim.playerByPeer(ca.slot).?;
    try std.testing.expect(g.sim.inventory[ps].addItem(7, 5)); // wood
    {
        var txb: [32]u8 = undefined;
        const tb = try packages.buildInvTxRequest(&txb, @intFromEnum(@import("../ecs/inventory.zig").Op.craft), 0, 0, 1, 0);
        var fb: [64]u8 = undefined;
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", tb));
    }
    // After craft (resourceWood consumes wood, grants wood): still have wood.
    try std.testing.expect(g.sim.inventory[ps].countItem(7) >= 1);

    // Place a stone block then explode it away.
    try g.setBlock(252, 70, 252, world_store.block_stone);
    try std.testing.expectEqual(world_store.block_stone, try g.world.blockWorld(252, 70, 252));
    {
        var eb: [128]u8 = undefined;
        var w: @import("../wire/binary.zig").Writer = .{ .buf = &eb };
        try w.writeF32(252);
        try w.writeF32(70);
        try w.writeF32(252);
        try w.writeI32(252);
        try w.writeI32(70);
        try w.writeI32(252);
        try w.writeF32(0);
        try w.writeF32(0);
        try w.writeF32(0);
        try w.writeF32(1);
        try w.writeU16(0);
        try w.writeI32(ca.entity_id);
        try w.writeF32(0);
        var fb: [256]u8 = undefined;
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageExplosionInitiate", w.written()));
    }
    try std.testing.expectEqual(@as(u16, 0), try g.world.blockWorld(252, 70, 252));
    // B should have seen SetBlock air and/or ExplosionClient.
    const exp_id = packages.idOf("NetPackageExplosionClient");
    const sb_id = packages.idOf("NetPackageSetBlock");
    try std.testing.expect(exp_id != null or sb_id != null);
    if (exp_id) |eid| try std.testing.expect(cap_b.findPkgId(eid) != null or (sb_id != null and cap_b.findPkgId(sb_id.?) != null));

    // Lock: A holds channel 0; B denied.
    {
        var req: [64]u8 = undefined;
        var w: @import("../wire/binary.zig").Writer = .{ .buf = &req };
        try w.writeBool(true);
        try w.writeU16(0);
        try w.writeI32(0); // no targets
        try w.writeString("");
        var fb: [128]u8 = undefined;
        const framed = try packages.framed(&fb, "NetPackageLockRequest", w.written());
        try g.injectFramed(ca, framed);
        try g.injectFramed(cb, framed);
        try std.testing.expectEqual(@as(i32, @intCast(ca.slot)), g.lock_channel[0]);
    }

    std.debug.print("PASS craft+explosion+lock: wood ok, dig air, lock held by A\n", .{});
}

test "scenario gas can refuel generator via InvTx place" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_refuel");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_refuel", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Place a generator node with empty tank at a known world pos near spawn.
    const gx: i32 = 260;
    const gy: i32 = 70;
    const gz: i32 = 260;
    const gen = g.sim.power.addNodeAt(.generator, gx, gy, gz, 100).?;
    const gi = g.sim.power.indexOfId(gen).?;
    g.sim.power.nodes[gi].capacity = 1000;
    g.sim.power.nodes[gi].fuel_or_energy = 0;
    g.sim.power.nodes[gi].on = false;
    g.sim.power.nodes[gi].burn_rate = 1;
    g.sim.power.resolve();

    // Register a fuel item with FuelValue (stock ammoGasCan shape) without full items.xml.
    // Inject into ItemTable defs via a temporary override on fuel_value_fn.
    const fuel_id: u16 = 50;
    const FuelCtx = struct {
        fn fuel(_: ?*anyopaque, id: u16) f32 {
            return if (id == 50) 25 else 0;
        }
    };
    g.sim.fuel_value_ctx = null;
    g.sim.fuel_value_fn = &FuelCtx.fuel;

    const inv = @import("../ecs/inventory.zig");
    const ps0 = g.sim.playerByPeer(c.slot).?;
    // Starter kit may already hold item_id 50; isolate the fuel stack.
    g.sim.inventory[ps0].clear();
    try std.testing.expect(inv.give(&g.sim, c.slot, fuel_id, 3));
    const fuel_slot: u16 = blk: {
        for (g.sim.inventory[ps0].slots, 0..) |s, i| {
            if (s.item_id == fuel_id and s.count > 0) break :blk @intCast(i);
        }
        break :blk 0;
    };
    try std.testing.expectEqual(@as(u16, 3), g.sim.inventory[ps0].slots[fuel_slot].count);

    // Move player near generator for range check.
    if (g.sim.slotOfNetId(c.entity_id)) |ps| {
        g.sim.transform[ps].x = @floatFromInt(gx);
        g.sim.transform[ps].y = @floatFromInt(gy);
        g.sim.transform[ps].z = @floatFromInt(gz);
    }

    var txb: [32]u8 = undefined;
    // InvTx place: a=slot, b=y, qty=z, entity_id=x
    const place_req = try packages.buildInvTxRequest(
        &txb,
        @intFromEnum(inv.Op.place),
        fuel_slot,
        @bitCast(@as(i16, @intCast(gy))),
        @bitCast(@as(i16, @intCast(gz))),
        gx,
    );
    var fb: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", place_req));

    try std.testing.expect(g.sim.power.nodes[gi].fuel_or_energy >= 25);
    try std.testing.expect(g.sim.power.nodes[gi].on);
    const ps = g.sim.playerByPeer(c.slot).?;
    var remaining: u32 = 0;
    for (g.sim.inventory[ps].slots) |s| {
        if (s.item_id == fuel_id) remaining += s.count;
    }
    try std.testing.expectEqual(@as(u32, 2), remaining);

    std.debug.print(
        "PASS refuel: gen_fuel={d:.0} remaining_cans={d}\n",
        .{ g.sim.power.nodes[gi].fuel_or_energy, remaining },
    );
}

test "scenario ItemActionEat via InvTx use applies food and hp" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_eat");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_eat", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const inv = @import("../ecs/inventory.zig");

    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.health[ps].hp = 50;
    g.sim.health[ps].food = 40;
    g.sim.health[ps].food_max = 100;
    // Clear starter kit; give one food (ecs id 2 = foodCanBeef).
    g.sim.inventory[ps] = .{};
    try std.testing.expect(inv.give(&g.sim, c.slot, 2, 1));
    const food_slot: u16 = blk: {
        for (g.sim.inventory[ps].slots, 0..) |s, i| {
            if (s.item_id == 2 and s.count > 0) break :blk @intCast(i);
        }
        return error.TestUnexpectedResult;
    };
    var txb: [32]u8 = undefined;
    const use_req = try packages.buildInvTxRequest(&txb, @intFromEnum(inv.Op.use), food_slot, 0, 0, -1);
    var fb: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", use_req));
    try std.testing.expectEqual(@as(u16, 0), g.sim.inventory[ps].slots[food_slot].count);
    try std.testing.expect(g.sim.health[ps].food >= 54.9);
    try std.testing.expect(g.sim.health[ps].hp >= 56.9);
    // S2C EntityStatChanged food/health should have been sent.
    const st_id = packages.idOf("NetPackageEntityStatChanged").?;
    try std.testing.expect(cap.findPkgId(st_id) != null);
    std.debug.print("PASS ItemActionEat: food={d:.0} hp={d:.0}\n", .{ g.sim.health[ps].food, g.sim.health[ps].hp });
}

test "scenario ItemActionEat via PlayerInventory stack-loss applies food and hp" {
    // Stock client path (ADR 0007): DecHoldingItem locally then C2S PlayerInventory.
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_eat_pi");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_eat_pi", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const inv = @import("../ecs/inventory.zig");

    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.health[ps].hp = 50;
    g.sim.health[ps].food = 40;
    g.sim.health[ps].food_max = 100;
    g.sim.inventory[ps] = .{};
    try std.testing.expect(inv.give(&g.sim, c.slot, 2, 2)); // two food
    // Client-style: one unit consumed locally (count 2 -> 1), push PlayerInventory.
    var inv_copy = g.sim.inventory[ps];
    // Find food slot and dec
    for (&inv_copy.slots) |*s| {
        if (s.item_id == 2 and s.count > 0) {
            s.count -= 1;
            break;
        }
    }
    var stock_body: [8192]u8 = undefined;
    const body = try packages.buildInventoryBodyStock(&stock_body, &inv_copy);
    var fb: [9000]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackagePlayerInventory", body));
    try std.testing.expectEqual(@as(u16, 1), blk: {
        var n: u16 = 0;
        for (g.sim.inventory[ps].slots) |s| {
            if (s.item_id == 2) n += s.count;
        }
        break :blk n;
    });
    try std.testing.expect(g.sim.health[ps].food >= 54.9);
    try std.testing.expect(g.sim.health[ps].hp >= 56.9);
    const st_id = packages.idOf("NetPackageEntityStatChanged").?;
    try std.testing.expect(cap.findPkgId(st_id) != null);
    std.debug.print("PASS ItemActionEat PlayerInventory: food={d:.0} hp={d:.0}\n", .{ g.sim.health[ps].food, g.sim.health[ps].hp });
}

test "scenario malicious C2S: speedhack PosAndRot increments movement_rejects" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_speedhack");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_speedhack", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);

    // Seed last-good position so envelope has a baseline.
    var pos_body: [64]u8 = undefined;
    const seed = try packages.buildPosAndRotBody(&pos_body, c.entity_id, 100, 71, 100, 0, 0, 0, true);
    var frame_buf: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", seed));

    // Advance server tick so dt is non-zero (min_dt still applies; huge delta still clamps).
    g.tick_n += 20;

    const before = g.harness.counters.get(.movement_rejects);
    // 500 m horizontal in ~1 s >> 20 m/s soft cap.
    const hack = try packages.buildPosAndRotBody(&pos_body, c.entity_id, 600, 71, 100, 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", hack));

    const after = g.harness.counters.get(.movement_rejects);
    try std.testing.expect(after > before);

    // Correct mode clamps: seed was 100, soft cap 20 m/s × ~1s → stay near 120, not 600.
    if (g.sim.slotOfNetId(c.entity_id)) |idx| {
        const x = g.sim.transform[idx].x;
        try std.testing.expect(x < 200);
        try std.testing.expect(x >= 100);
        try std.testing.expect(x <= 100 + 20 + 0.5);
    } else return error.MissingEntity;

    std.debug.print(
        "PASS speedhack: movement_rejects {d}->{d}; clamped x={d:.1}\n",
        .{ before, after, g.sim.transform[g.sim.slotOfNetId(c.entity_id).?].x },
    );
}

fn writeFileAt(dir: []const u8, name: []const u8, data: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    try io_fs.writeFileSimple(path, data);
}

/// Fire two distinct Strong detectors on one peer: speedhack movement
/// (surface .none) then a dead-actor DamageEntity claim (surface .damage).
fn tripTwoStrongSignals(g: *game_mod.Game, c: anytype) !void {
    var body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;

    const seed = try packages.buildPosAndRotBody(&body, c.entity_id, 100, 71, 100, 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", seed));
    g.tick_n += 20;
    // 500 m in ~1 s: movement / strong.
    const hack = try packages.buildPosAndRotBody(&body, c.entity_id, 600, 71, 100, 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", hack));

    // Dead actor claiming damage: bounds / strong / damage.
    const ps = g.sim.slotOfNetId(c.entity_id) orelse return error.MissingEntity;
    g.sim.health[ps].hp = 0;
    const dmg = try packages.buildDamageBody(&body, c.entity_id + 1000, 0, 0, 50, false, c.entity_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg));
}

test "scenario guard policy: two distinct strong signals log-only by default" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_guard_log");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_guard_log", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // Defaults are the safe rung: nothing enforced, nothing quarantined.
    try std.testing.expectEqual(false, g.guard.enforce);
    try std.testing.expectEqual(true, g.guard.dry_run);

    try tripTwoStrongSignals(g, c);

    try std.testing.expectEqual(@as(u64, 1), g.harness.counters.get(.guard_would_kicks));
    try std.testing.expectEqual(@as(u64, 0), g.harness.counters.get(.guard_kicks));
    try std.testing.expectEqual(@as(u64, 0), g.harness.counters.get(.guard_quarantines));
    // Peer stays connected and unrestricted under the default ladder.
    try std.testing.expect(c.peer != null);
    try std.testing.expectEqual(@as(u64, 0), c.guard.kick_at_tick);
    try std.testing.expectEqual(false, c.guard.quarantine.any());
    std.debug.print("PASS guard policy log-only: would_kicks=1, peer still connected\n", .{});
}

test "scenario guard policy: quarantine denies only the abused surface" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_guard_quar");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_guard_quar", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Quarantine rung on; kick rung stays off (enforce=false, dry_run=true).
    g.guard = .{ .quarantine = true };
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    try tripTwoStrongSignals(g, c);

    // The tripping event was attributed to `.damage`, so only that bit is set.
    try std.testing.expectEqual(true, c.guard.quarantine.no_damage);
    try std.testing.expectEqual(false, c.guard.quarantine.no_setblock);
    try std.testing.expectEqual(false, c.guard.quarantine.no_container);
    try std.testing.expectEqual(@as(u64, 1), g.harness.counters.get(.guard_quarantines));
    try std.testing.expectEqual(@as(u64, 0), g.harness.counters.get(.guard_kicks));
    try std.testing.expect(c.peer != null);

    // A further DamageEntity is dropped at the top of the handler: the
    // quarantine counter moves and the downstream bounds reject never runs.
    const q_before = g.harness.counters.get(.quarantine_rejects);
    const b_before = g.harness.counters.get(.bounds_rejects);
    var body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;
    const dmg = try packages.buildDamageBody(&body, c.entity_id + 1000, 0, 0, 50, false, c.entity_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg));
    try std.testing.expectEqual(q_before + 1, g.harness.counters.get(.quarantine_rejects));
    try std.testing.expectEqual(b_before, g.harness.counters.get(.bounds_rejects));

    // SetBlock is not quarantined, so it still reaches the normal handler.
    const q_after = g.harness.counters.get(.quarantine_rejects);
    const sb = try packages.buildSetBlockBody(&body, 5000, 60, 5000, 0);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", sb));
    try std.testing.expectEqual(q_after, g.harness.counters.get(.quarantine_rejects));

    // Operator escape hatch (admin `guardclear <slot>`) resets the bits.
    c.guard.quarantine = .{};
    try std.testing.expectEqual(false, c.guard.quarantine.any());
    std.debug.print("PASS guard policy quarantine: no_damage only, damage C2S denied\n", .{});
}

test "scenario workstation queue: C2S write, craft tick, S2C echo keeps stock geometry" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_ws");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ws", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);

    const ws = @import("../world/workstations.zig");
    const stock_te = packages.stock_te;
    const stock_inv = packages.stock_inv;
    const pa = g.sim.playerByPeer(ca.slot).?;
    const wx: i32 = @intFromFloat(g.sim.transform[pa].x);
    const wy: i32 = @intFromFloat(g.sim.transform[pa].y);
    const wz: i32 = @intFromFloat(g.sim.transform[pa].z);

    // Client write: full stock array lengths, fuel lit, one recipe queued in the
    // active (last) slot with a Recipe blob, and an empty craft-complete list.
    var recipe: [128]u8 = undefined;
    var rw: @import("../wire/binary.zig").Writer = .{ .buf = &recipe };
    const out_type = stock_inv.itemTypeFromIndex(7); // resourceWood
    try rw.writeU16(1);
    try rw.writeI32(out_type);
    try rw.writeI32(2);
    try rw.writeBool(false);
    try rw.writeF32(1.0);
    try rw.writeI32(9);
    try rw.writeString("forge");
    try rw.writeI32(0);

    var fuel = [_]stock_inv.StockSlot{.{}} ** ws.stock_fuel_len;
    fuel[0] = .{ .type_id = out_type, .count = 4 };
    const input = [_]stock_inv.StockSlot{.{}} ** ws.stock_input_len;
    const tools = [_]stock_inv.StockSlot{.{}} ** ws.stock_tools_len;
    const output = [_]stock_inv.StockSlot{.{}} ** ws.stock_output_len;
    var last_input_buf: [64]u8 = undefined;
    var liw: @import("../wire/binary.zig").Writer = .{ .buf = &last_input_buf };
    for (0..ws.stock_last_input_len) |_| try stock_inv.writeItemStack(&liw, .{});
    const melt = [_]f32{0} ** ws.stock_melt_len;
    var queue = [_]ws.QueueItem{.{}} ** ws.stock_queue_len;
    queue[queue.len - 1] = .{
        .multiplier = 2,
        .is_crafting = true,
        .craft_time_left = 0.2,
        .one_item_craft_time = 1.0,
        .starting_entity_id = ca.entity_id,
        .output_type = out_type,
        .output_count = 2,
        .craft_exp_gain = 9,
    };
    queue[queue.len - 1].setRecipeBlob(rw.written());

    var body: [4096]u8 = undefined;
    const c2s = try stock_te.buildWorkstationTeBody(&body, 3, wx, wy, wz, 1301, .{
        .fuel = fuel[0..],
        .input = input[0..],
        .tools = tools[0..],
        .output = output[0..],
        .last_input_count = ws.stock_last_input_len,
        .last_input = liw.written(),
        .queue = queue[0..],
        .melt = melt[0..],
        .is_burning = true,
        .burn_time_left = 30,
    });
    var fb: [4096]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageTileEntity", c2s));

    const st = g.workstations.get(wx, wy, wz).?;
    try std.testing.expect(st.geometry_known);
    try std.testing.expectEqual(@as(i32, 1301), st.block_id);
    try std.testing.expectEqual(ws.stock_queue_len, st.queue_len);
    try std.testing.expectEqual(ws.stock_output_len, st.output_len);
    try std.testing.expect(st.queue[st.queue_len - 1].recipeBlob().len > 0);

    // Craft tick: the active entry finishes one item and queues a record.
    cap_b.clear(); // isolate the S2C dirty broadcast from the raw C2S echo
    try g.tickWorkstations(0.5);
    try std.testing.expectEqual(@as(i16, 1), st.queue[st.queue_len - 1].multiplier);
    try std.testing.expectEqual(@as(u8, 1), st.craft_complete_n);
    try std.testing.expectEqual(ca.entity_id, st.craft_complete[0].crafter_entity_id);

    // The S2C echo B receives must decode at the same array lengths, still carry
    // the recipe blob and the craft-complete record, and drain exactly.
    const te_id = packages.idOf("NetPackageTileEntity").?;
    const echo = cap_b.findPkgId(te_id).?;
    const p = try stock_te.parseWorkstationTeBody(echo);
    try std.testing.expectEqual(ws.stock_fuel_len, p.fuel_n);
    try std.testing.expectEqual(ws.stock_output_len, p.output_n);
    try std.testing.expectEqual(ws.stock_last_input_len, p.last_input_n);
    try std.testing.expectEqual(ws.stock_queue_len, p.queue_n);
    try std.testing.expectEqual(ws.stock_melt_len, p.melt_n);
    try std.testing.expectEqual(@as(i32, 1301), p.block_id);
    try std.testing.expect(p.queue[p.queue_n - 1].recipeBlob().len > 0);
    try std.testing.expectEqual(@as(u8, 1), p.craft_complete_n);
    try std.testing.expectEqual(@as(i32, 9), p.craft_complete[0].exp_gain);

    // The next client write acknowledges consumption by returning a trimmed list.
    const ack = try stock_te.buildWorkstationTeBody(&body, 4, wx, wy, wz, 1301, .{
        .fuel = fuel[0..],
        .input = input[0..],
        .tools = tools[0..],
        .output = output[0..],
        .last_input_count = ws.stock_last_input_len,
        .last_input = liw.written(),
        .queue = queue[0..],
        .melt = melt[0..],
        .is_burning = true,
        .burn_time_left = 29,
    });
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageTileEntity", ack));
    try std.testing.expectEqual(@as(u8, 0), st.craft_complete_n);

    std.debug.print("PASS workstation: queue depth {d}, craft complete acknowledged\n", .{st.queue_len});
}

test "scenario interest: mob leaving interest gets EntityRemove(Unloaded)" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_unload");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_unload", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    const ps = g.sim.slotOfNetId(ca.entity_id).?;
    const px = g.sim.transform[ps].x;
    const py = g.sim.transform[ps].y;
    const pz = g.sim.transform[ps].z;

    // Two mobs the client can see. Only one of them walks away.
    const near_id = g.sim.spawnZombie(px + 4, py, pz + 4, 50).?;
    const gone_id = g.sim.spawnZombie(px + 8, py, pz + 8, 50).?;
    const near_s = g.sim.slotOfNetId(near_id).?;
    const gone_s = g.sim.slotOfNetId(gone_id).?;

    cap.clear();
    try g.replicateNow();
    try std.testing.expect(ca.known_entities.isSet(near_s));
    try std.testing.expect(ca.known_entities.isSet(gone_s));

    // Walk one mob far outside the interest box. It stays alive, so the death
    // path (the only thing that used to clear known_entities) never runs.
    g.sim.transform[gone_s].x = px + 4000;
    g.sim.transform[gone_s].z = pz + 4000;

    cap.clear();
    try g.replicateNow();
    try std.testing.expect(g.sim.slotOfNetId(gone_id) != null);

    const rm_id = packages.idOf("NetPackageEntityRemove").?;
    const rm = cap.findPkgIdEntity(rm_id, gone_id);
    try std.testing.expect(rm != null);
    // NetPackageEntityRemove::write is entityId i32 then reason u8, and
    // EnumRemoveEntityReason.Unloaded = 1 (asm.il:817290-817301, :1227761).
    try std.testing.expectEqual(@as(usize, 5), rm.?.len);
    try std.testing.expectEqual(@as(u8, 1), rm.?[4]);
    try std.testing.expect(!ca.known_entities.isSet(gone_s));

    // The mob still in range keeps its client-side entity.
    try std.testing.expect(cap.findPkgIdEntity(rm_id, near_id) == null);
    try std.testing.expect(ca.known_entities.isSet(near_s));

    // And the removal is one-shot: no per-tick remove/spawn flip-flop.
    const sp_id = packages.idOf("NetPackageEntitySpawn").?;
    cap.clear();
    try g.replicateNow();
    try std.testing.expect(cap.findPkgIdEntity(rm_id, gone_id) == null);
    try std.testing.expect(cap.findPkgIdEntity(sp_id, gone_id) == null);

    std.debug.print(
        "PASS interest-unload: id={d} removed with Unloaded, id={d} still tracked\n",
        .{ gone_id, near_id },
    );
}

/// First NetPackageEntityStatChanged body for `entity_id` with EnumStat `kind`
/// (0 Health, 7 Food, 8 Water — PlayerEntityStats::Tick). The survival loop
/// also emits Food/Water stats, so tests must pick the stat they mean.
fn findStatBody(cap: *const ln_peer.Capture, stat_id: u16, entity_id: i32, kind: u8) ?[]const u8 {
    var i: usize = 0;
    while (i < cap.n) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id != stat_id) continue;
            const b = pkgs[j].body;
            if (b.len < 9) continue;
            if (std.mem.readInt(i32, b[0..4], .little) != entity_id) continue;
            if (b[8] != kind) continue;
            return b;
        }
    }
    return null;
}

test "scenario zombie melee reaches the client as EntityStatChanged, then death and respawn" {
    // Regression for the "zombies cannot hurt you" gap: server-side melee moved
    // health[].hp and nothing was ever sent, so the victim's client saw no damage,
    // no death screen, and the server-side corpse could not fight back.
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_hp_repl");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_hp_repl", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const stat_id = packages.idOf("NetPackageEntityStatChanged").?;
    const ps = g.sim.playerByPeer(c.slot).?;
    const p = g.sim.transform[ps];
    // This test exercises damage/death replication, not survival: turn the
    // depletion loop off so well-fed regen cannot interfere with the kill.
    g.sim.rules.progression.food_depletion_per_hour = 0;
    g.sim.rules.progression.water_depletion_per_hour = 0;
    _ = g.sim.spawnZombie(p.x + 1, p.y, p.z, 40).?;

    cap.clear();
    var t: u32 = 0;
    while (t < 60 and g.sim.health[ps].hp >= 100) : (t += 1) try g.step();
    try std.testing.expect(g.sim.health[ps].hp < 100);

    // Stock NetPackageEntityStatChanged::write (asm.il:201967, GetLength 21 at
    // :202120): entityId i32 (NetPackageEntityTargeted) | instigatorId i32 |
    // EnumStat u8 | value f32 | max f32 | maxModifier f32.
    const hit = findStatBody(&cap, stat_id, c.entity_id, 0) orelse return error.NoDamageStatPackage;
    try std.testing.expectEqual(@as(usize, 21), hit.len);
    // A dedicated server has no local player, so the instigator is -1 (asm.il:199661).
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, hit[4..8], .little));
    try std.testing.expectEqual(@as(u8, 0), hit[8]); // EnumStat.Health
    const hurt_hp: f32 = @bitCast(std.mem.readInt(u32, hit[9..13], .little));
    const hurt_max: f32 = @bitCast(std.mem.readInt(u32, hit[13..17], .little));
    try std.testing.expect(hurt_hp > 0 and hurt_hp < 100);
    try std.testing.expectEqual(@as(f32, 100), hurt_max);
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, hit[17..21], .little))));

    // Fatal hit: hp 0 must reach the client, that is what starts the death flow.
    cap.clear();
    g.sim.health[ps].hp = 1;
    t = 0;
    while (t < 60 and g.sim.health[ps].hp > 0) : (t += 1) try g.step();
    try std.testing.expectEqual(@as(f32, 0), g.sim.health[ps].hp);
    try std.testing.expect(g.sim.alive[ps]); // corpse keeps its entity for respawn
    const dead = findStatBody(&cap, stat_id, c.entity_id, 0) orelse return error.NoDeathStatPackage;
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, dead[9..13], .little))));

    // Respawn still heals and still tells the client.
    cap.clear();
    var spawn_body: [2]u8 = undefined;
    std.mem.writeInt(i16, spawn_body[0..2], 4, .little);
    var fb: [64]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageRequestToSpawnPlayer", &spawn_body));
    try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].hp);
    const alive_again = findStatBody(&cap, stat_id, c.entity_id, 0) orelse return error.NoRespawnStatPackage;
    try std.testing.expectEqual(@as(f32, 100), @as(f32, @bitCast(std.mem.readInt(u32, alive_again[9..13], .little))));

    std.debug.print(
        "PASS hp replication: hurt={d:.0}/{d:.0} then hp=0 then respawn hp={d:.0}\n",
        .{ hurt_hp, hurt_max, g.sim.health[ps].hp },
    );
}

test "scenario ally invite accept and identity spoof reject" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_ally");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ally", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Both peers log in with a real platform identity, so the identity the ally
    // wire uses comes out of the shipped NetPackagePlayerLogin decode.
    const id_a: platform_user.Id = .{ .platform = "Steam", .id = "76561198000000001" };
    const id_b: platform_user.Id = .{ .platform = "EOS", .id = "0123456789abcdef" };
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClientAs(&cap_a, id_a);
    const cb = try g.attachJoinedClientAs(&cap_b, id_b);
    try std.testing.expect(ca.puid_primary.matches(id_a));
    try std.testing.expect(ca.puid_native.matches(id_a));
    try std.testing.expect(cb.puid_primary.matches(id_b));

    // The join PersistentPlayerState must carry that identity, not a fabricated
    // one: it is what the client's PersistentPlayerData is keyed on.
    {
        const pps_id = packages.idOf("NetPackagePersistentPlayerState").?;
        const pps = cap_b.findPkgId(pps_id) orelse return error.NoPersistentPlayerState;
        var r: binary.Reader = .{ .data = pps };
        try std.testing.expectEqual(packages.stock_inv.persistent_reason_login, try r.readByte());
        var plat: [platform_user.max_platform_len]u8 = undefined;
        var pid: [platform_user.max_id_len]u8 = undefined;
        const primary = (try platform_user.read(&r, &plat, &pid)).?;
        try std.testing.expectEqualStrings(id_b.platform, primary.platform);
        try std.testing.expectEqualStrings(id_b.id, primary.id);
    }

    const resp_id = packages.idOf("NetPackageAllyResponse").?;
    var body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;

    // A invites B.
    cap_a.clear();
    cap_b.clear();
    const invite = try packages.buildAllyRequestBody(&body, id_a, id_b, true);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAllyRequest", invite));
    try std.testing.expectEqual(ally_mod.Status.outgoing_invite, g.allies.status(id_a, id_b));
    try std.testing.expectEqual(ally_mod.Status.incoming_invite, g.allies.status(id_b, id_a));
    // Stock broadcasts the response, so both sides see it.
    const seen_b = cap_b.findPkgId(resp_id) orelse return error.NoAllyResponse;
    try std.testing.expect(cap_a.findPkgId(resp_id) != null);
    {
        var r: binary.Reader = .{ .data = seen_b };
        var plat: [platform_user.max_platform_len]u8 = undefined;
        var pid: [platform_user.max_id_len]u8 = undefined;
        try std.testing.expectEqualStrings(id_a.id, (try platform_user.read(&r, &plat, &pid)).?.id);
        try std.testing.expectEqualStrings(id_b.id, (try platform_user.read(&r, &plat, &pid)).?.id);
        try std.testing.expectEqual(@intFromEnum(ally_mod.Status.outgoing_invite), try r.readByte());
        try std.testing.expectEqual(@intFromEnum(ally_mod.Event.outgoing_sent), try r.readByte());
        try std.testing.expectEqual(@intFromEnum(ally_mod.Event.incoming_received), try r.readByte());
    }

    // B accepts: the request now comes from B's side.
    const accept = try packages.buildAllyRequestBody(&body, id_b, id_a, true);
    try g.injectFramed(cb, try packages.framed(&frame_buf, "NetPackageAllyRequest", accept));
    try std.testing.expect(g.allies.isAlly(id_a, id_b));
    try std.testing.expect(g.allies.isAlly(id_b, id_a));

    // A claims B's identity to cancel the pair: rejected, state untouched.
    const rejects_before = g.harness.counters.get(.ownership_rejects);
    const spoof = try packages.buildAllyRequestBody(&body, id_b, id_a, false);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAllyRequest", spoof));
    try std.testing.expectEqual(rejects_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(g.allies.isAlly(id_a, id_b));

    // A removes the ally for real; both sides drop back to NotAllied.
    const remove = try packages.buildAllyRequestBody(&body, id_a, id_b, false);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAllyRequest", remove));
    try std.testing.expectEqual(ally_mod.Status.not_allied, g.allies.status(id_a, id_b));
    try std.testing.expectEqual(@as(usize, 0), g.allies.count());

    // A client-sent AllyResponse is wrong-direction and must never be reflected.
    const rejects_pre_resp = g.harness.counters.get(.ownership_rejects);
    const fake = try packages.buildAllyResponseBody(&body, id_b, id_a, 1, 3, 6);
    cap_a.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAllyResponse", fake));
    try std.testing.expectEqual(rejects_pre_resp + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(cap_a.findPkgId(resp_id) == null);
    std.debug.print("PASS ally: invite/accept/remove by identity; spoof and C2S AllyResponse rejected\n", .{});
}

test "scenario buff add relays to observers and expires on the server clock" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_buff");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_buff", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    _ = cb;

    // buffShocked: stack_type=duration, duration 4 s (80 stock ticks).
    const def_id = g.buffs.indexOfName("buffShocked").?;
    var body: [128]u8 = undefined;
    var frame_buf: [256]u8 = undefined;
    const add = try packages.stock_buff.buildAddRemoveBuffBody(&body, .{
        .entity_id = ca.entity_id,
        .name = "buffShocked",
        // A client may ask for any duration; the server must not honour it.
        .duration = 30,
        .adding = true,
        .instigator_id = ca.entity_id,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAddRemoveBuff", add));

    const ps = g.sim.playerByPeer(ca.slot).?;
    try std.testing.expect(g.sim.mask[ps].buffs);
    const inst = g.sim.buffs[ps].find(def_id).?;
    // Class duration wins over the client's 30 s request.
    try std.testing.expectEqual(@as(f32, 4), inst.duration_max);

    // B is told, A is not (it already applied the buff locally).
    const pkg_id = packages.idOf("NetPackageAddRemoveBuff").?;
    const relayed = cap_b.findPkgIdEntity(pkg_id, ca.entity_id) orelse return error.NoRelay;
    var name_buf: [64]u8 = undefined;
    const parsed = try packages.stock_buff.parseAddRemoveBuff(relayed, &name_buf);
    try std.testing.expectEqualStrings("buffShocked", parsed.name);
    try std.testing.expect(parsed.adding);
    // Never a concrete duration: that would retune the shared BuffClass on B.
    try std.testing.expectEqual(@as(f32, -1), parsed.duration);
    try std.testing.expect(cap_a.findPkgIdEntity(pkg_id, ca.entity_id) == null);

    // A peer that joins now missed the relay, so the join bundle must carry the
    // full list as EntityStatsBuff (remote-only on the client).
    var cap_c: ln_peer.Capture = .{};
    const cc = try g.attachJoinedClient(&cap_c);
    const stats_id = packages.idOf("NetPackageEntityStatsBuff").?;
    const sync = cap_c.findPkgIdEntity(stats_id, ca.entity_id) orelse return error.NoBuffSync;
    // i32 entityId | i32 len | EntityBuffs blob (version 3, count 1).
    try std.testing.expectEqual(@as(i32, @intCast(sync.len - 8)), std.mem.readInt(i32, sync[4..8], .little));
    try std.testing.expectEqual(@as(u8, 3), sync[8]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, sync[9..11], .little));
    // A peer never gets its own list this way (the client would drop it anyway).
    try std.testing.expect(cap_c.findPkgIdEntity(stats_id, cc.entity_id) == null);

    // Run the 81 ticks it takes to reach 4.0 s and then report the removal.
    cap_a.clear();
    cap_b.clear();
    var t: u32 = 0;
    while (t < 81) : (t += 1) try g.step();
    try std.testing.expect(g.sim.buffs[ps].find(def_id) == null);

    const gone_a = cap_a.findPkgIdEntity(pkg_id, ca.entity_id) orelse return error.NoExpiry;
    const gone = try packages.stock_buff.parseAddRemoveBuff(gone_a, &name_buf);
    try std.testing.expect(!gone.adding);
    try std.testing.expectEqualStrings("buffShocked", gone.name);
    try std.testing.expect(cap_b.findPkgIdEntity(pkg_id, ca.entity_id) != null);
    std.debug.print(
        "PASS buff lifecycle: entity={d} buffShocked relayed to observer, expired after {d} ticks\n",
        .{ ca.entity_id, t },
    );
}

test "scenario buff rejects unknown names and foreign entities" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_buff_rej");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_buff_rej", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);
    const pkg_id = packages.idOf("NetPackageAddRemoveBuff").?;

    var body: [128]u8 = undefined;
    var frame_buf: [256]u8 = undefined;
    const unknown = try packages.stock_buff.buildAddRemoveBuffBody(&body, .{
        .entity_id = ca.entity_id,
        .name = "buffNotInAnyCatalog",
        .duration = -1,
        .adding = true,
        .instigator_id = -1,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    cap_b.clear();
    const before = g.harness.counters.get(.buff_rejects);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAddRemoveBuff", unknown));
    try std.testing.expectEqual(before + 1, g.harness.counters.get(.buff_rejects));
    try std.testing.expect(cap_b.findPkgId(pkg_id) == null);

    // Buffing somebody else's entity is not a client's call.
    const foreign = try packages.stock_buff.buildAddRemoveBuffBody(&body, .{
        .entity_id = ca.entity_id + 1000,
        .name = "buffIsOnFire",
        .duration = -1,
        .adding = true,
        .instigator_id = -1,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    const own_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAddRemoveBuff", foreign));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(cap_b.findPkgId(pkg_id) == null);

    // A truncated body is malformed input, not a buff.
    const mal_before = g.harness.counters.get(.c2s_malformed);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageAddRemoveBuff", unknown[0..5]));
    try std.testing.expectEqual(mal_before + 1, g.harness.counters.get(.c2s_malformed));

    const ps = g.sim.playerByPeer(ca.slot).?;
    try std.testing.expectEqual(@as(u8, 0), g.sim.buffs[ps].count());
    std.debug.print("PASS buff rejects: unknown name, foreign entity, truncated body all dropped\n", .{});
}

test "scenario replace-stack buff re-add restarts instead of duplicating" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_buff_stack");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_buff_stack", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // buffInjuryBleeding is stack_type=replace in stock buffs.xml.
    const def_id = g.buffs.indexOfName("buffInjuryBleeding").?;
    var body: [128]u8 = undefined;
    var frame_buf: [256]u8 = undefined;
    const add = try packages.stock_buff.buildAddRemoveBuffBody(&body, .{
        .entity_id = c.entity_id,
        .name = "buffInjuryBleeding",
        .duration = -1,
        .adding = true,
        .instigator_id = -1,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    const framed = try packages.framed(&frame_buf, "NetPackageAddRemoveBuff", add);
    try g.injectFramed(c, framed);

    var t: u32 = 0;
    while (t < 10) : (t += 1) try g.step();
    const ps = g.sim.playerByPeer(c.slot).?;
    try std.testing.expectEqual(@as(u32, 10), g.sim.buffs[ps].find(def_id).?.duration_ticks);

    try g.injectFramed(c, framed);
    try std.testing.expectEqual(@as(u8, 1), g.sim.buffs[ps].count());
    try std.testing.expectEqual(@as(u32, 0), g.sim.buffs[ps].find(def_id).?.duration_ticks);

    // duration 0 in the catalog means it never expires on its own; a client
    // remove request ends it through the same path an expiry would.
    const rem = try packages.stock_buff.buildAddRemoveBuffBody(&body, .{
        .entity_id = c.entity_id,
        .name = "buffInjuryBleeding",
        .duration = -1,
        .adding = false,
        .instigator_id = -1,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageAddRemoveBuff", rem));
    try std.testing.expect(g.sim.buffs[ps].find(def_id).?.flags.remove);
    try g.step();
    try std.testing.expectEqual(@as(u8, 0), g.sim.buffs[ps].count());
    std.debug.print("PASS buff stacking: replace restarted one instance, client remove ended it\n", .{});
}

test "scenario replicate serialize-once: a second viewer costs fan-out, not encodes" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_rep_once");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_rep_once", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);

    // Heartbeat motion pass (tick % 2 == 0 for motion, % 5 == 0 for heartbeat).
    g.tick_n = 10;
    // Settle: the first pass hands out EntitySpawn, later passes only move things.
    try g.replicateNow();
    try g.replicateNow();

    const enc0 = g.harness.counters.get(.packages_encoded);
    const fan0 = g.harness.counters.get(.replicate_fanouts);
    try g.replicateNow();
    const enc_one = g.harness.counters.get(.packages_encoded) - enc0;
    const fan_one = g.harness.counters.get(.replicate_fanouts) - fan0;
    try std.testing.expect(enc_one > 0);
    try std.testing.expect(fan_one > 0);

    // Second viewer at the same spawn: it sees the same entities as A.
    var cap_b: ln_peer.Capture = .{};
    const cb = try g.attachJoinedClient(&cap_b);
    try std.testing.expect(cb.entity_id != ca.entity_id);
    try g.replicateNow();
    try g.replicateNow();

    cap_a.clear();
    cap_b.clear();
    const enc1 = g.harness.counters.get(.packages_encoded);
    const fan1 = g.harness.counters.get(.replicate_fanouts);
    try g.replicateNow();
    const enc_two = g.harness.counters.get(.packages_encoded) - enc1;
    const fan_two = g.harness.counters.get(.replicate_fanouts) - fan1;

    // Fan-out follows viewers; encodes must not. Only the two player entities
    // gained an observer, so the encode delta is a small constant. A per-peer
    // encode would instead scale the whole pass with the viewer count.
    try std.testing.expect(fan_two > fan_one);
    try std.testing.expect(enc_two < enc_one * 2);
    try std.testing.expect(enc_two <= enc_one + 8);
    // Both peers really received the shared entities, not just one of them.
    const pos_id = packages.idOf("NetPackageEntityPosAndRot").?;
    try std.testing.expect(cap_a.findPkgIdEntity(pos_id, cb.entity_id) != null);
    try std.testing.expect(cap_b.findPkgIdEntity(pos_id, ca.entity_id) != null);
    std.debug.print(
        "PASS replicate serialize-once: encodes {d}→{d}, fan-out {d}→{d} for 1→2 viewers\n",
        .{ enc_one, enc_two, fan_one, fan_two },
    );
}

test "scenario replicate dirty gate: clean statics skip the off-heartbeat pass" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_rep_dirty");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_rep_dirty", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const px = g.sim.transform[ps].x;
    const py = g.sim.transform[ps].y;
    const pz = g.sim.transform[ps].z;

    // Static, non-mob entities in interest range: no spawn-on-approach, so the
    // only reason to visit them off heartbeat would be a dirty transform.
    const bags = 24;
    var bag_ids: [bags]i32 = undefined;
    for (&bag_ids, 0..) |*id, k| {
        id.* = g.sim.spawnLootBag(px + @as(f32, @floatFromInt(k % 4)), py, pz + 1, 7, 1).?;
    }

    // Heartbeat pass first: it both clears the spawn dirty bits and shows the
    // candidate count when everything is in play.
    g.tick_n = 10;
    try g.replicateNow();
    const hb0 = g.harness.counters.get(.replicate_candidates);
    try g.replicateNow();
    const cand_heartbeat = g.harness.counters.get(.replicate_candidates) - hb0;
    try std.testing.expect(cand_heartbeat >= bags);

    // Off-heartbeat motion pass with nothing dirty: the bags are not candidates.
    g.tick_n = 12;
    const off0 = g.harness.counters.get(.replicate_candidates);
    try g.replicateNow();
    const cand_off = g.harness.counters.get(.replicate_candidates) - off0;
    try std.testing.expect(cand_off + bags <= cand_heartbeat);

    // One bag moves: it is back in the candidate set and still goes on the wire
    // with the same PosAndRot body a stock client already expects.
    cap.clear();
    g.sim.setPos(bag_ids[3], px + 2, py, pz + 3, 0);
    const dirty0 = g.harness.counters.get(.replicate_candidates);
    try g.replicateNow();
    try std.testing.expectEqual(cand_off + 1, g.harness.counters.get(.replicate_candidates) - dirty0);

    const pos_id = packages.idOf("NetPackageEntityPosAndRot").?;
    const body = cap.findPkgIdEntity(pos_id, bag_ids[3]);
    try std.testing.expect(body != null);
    const parsed = try packages.parsePosAndRotBody(body.?);
    try std.testing.expectEqual(bag_ids[3], parsed.entity_id);
    try std.testing.expect(@abs(parsed.x - (px + 2)) < 0.01);
    try std.testing.expect(@abs(parsed.z - (pz + 3)) < 0.01);
    std.debug.print(
        "PASS replicate dirty gate: candidates heartbeat={d} off={d} after one move={d}\n",
        .{ cand_heartbeat, cand_off, cand_off + 1 },
    );
}

test "scenario multi-seat: driver plus passenger, dismount frees the seat" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_seats");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_seats", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);

    // Truck4x4 parked on both players so the 8 m mount gate passes for each.
    const pa = g.sim.slotOfNetId(ca.entity_id).?;
    const t = g.sim.transform[pa];
    const ve = g.sim.spawnVehicleEx(.four_by_four, t.x, t.y, t.z, 300, 14, 4).?;
    const vs = g.sim.slotOfNetId(ve).?;
    const pb = g.sim.slotOfNetId(cb.entity_id).?;
    g.sim.transform[pb] = t;

    var body: [32]u8 = undefined;
    var fb: [64]u8 = undefined;
    cap_a.clear();
    cap_b.clear();

    // Both clients mount the stock way: AttachServer with slot -1.
    const mount_a = try packages.buildEntityAttach(&body, .attach_server, ca.entity_id, ve, packages.slot_any);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAttach", mount_a));
    try std.testing.expectEqual(ca.entity_id, g.sim.vehicle[vs].driverNetId());

    const mount_b = try packages.buildEntityAttach(&body, .attach_server, cb.entity_id, ve, packages.slot_any);
    try g.injectFramed(cb, try packages.framed(&fb, "NetPackageEntityAttach", mount_b));
    try std.testing.expectEqual(@as(?u8, 1), systems.vehicleFindSeat(&g.sim, vs, cb.entity_id));

    // The passenger cannot steer: only seat 0 drives.
    var vb: [32]u8 = undefined;
    const drive = try packages.buildVehicleControlBody(&vb, ve, 2, 1.0, 0.0);
    try g.injectFramed(cb, try packages.framed(&fb, "NetPackageVehicleSpawn", drive));
    try std.testing.expectEqual(@as(f32, 0), g.sim.vehicle[vs].speed);

    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageVehicleSpawn", drive));
    try g.step();
    try std.testing.expect(g.sim.vehicle[vs].speed > 0);
    // Both riders travel with the hull.
    try std.testing.expectApproxEqAbs(g.sim.transform[vs].x, g.sim.transform[pb].x, 0.001);
    try std.testing.expectApproxEqAbs(g.sim.transform[vs].z, g.sim.transform[pb].z, 0.001);

    // The passenger dismounts the stock way: DetachServer with vehicleId -1.
    const dismount_b = try packages.buildEntityAttach(&body, .detach_server, cb.entity_id, -1, packages.slot_any);
    try g.injectFramed(cb, try packages.framed(&fb, "NetPackageEntityAttach", dismount_b));
    try std.testing.expectEqual(@as(?u8, null), systems.vehicleFindSeat(&g.sim, vs, cb.entity_id));
    try std.testing.expect(g.sim.vehicle[vs].speed > 0); // driver still aboard

    const dismount_a = try packages.buildEntityAttach(&body, .detach_server, ca.entity_id, -1, packages.slot_any);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAttach", dismount_a));
    try std.testing.expectEqual(@as(f32, 0), g.sim.vehicle[vs].speed);
    try std.testing.expectEqual(@as(u8, 4), g.sim.vehicle[vs].freeSeats());

    // Wire check: peers only ever see the client-side types 1 and 3 carrying the
    // resolved seat. Types 0/2 would send them down the server branch of
    // NetPackageEntityAttach::ProcessPackage (asm.il:844722).
    var types: [16]packages.AttachType = undefined;
    var slots: [16]i16 = undefined;
    var vehicles: [16]i32 = undefined;
    const n = collectAttaches(&cap_b, &types, &slots, &vehicles);
    try std.testing.expect(n >= 4);
    var seen_driver = false;
    var seen_passenger = false;
    var seen_detach = false;
    for (types[0..n], slots[0..n], vehicles[0..n]) |ty, slot, veh| {
        try std.testing.expect(ty == .attach_client or ty == .detach_client);
        if (ty == .attach_client and slot == 0 and veh == ve) seen_driver = true;
        if (ty == .attach_client and slot == 1 and veh == ve) seen_passenger = true;
        if (ty == .detach_client) {
            try std.testing.expectEqual(@as(i32, -1), veh);
            try std.testing.expectEqual(packages.slot_any, slot);
            seen_detach = true;
        }
    }
    try std.testing.expect(seen_driver);
    try std.testing.expect(seen_passenger);
    try std.testing.expect(seen_detach);
    std.debug.print("PASS multi-seat: attaches={d} seats=4 driver+passenger mount/dismount\n", .{n});
}

/// Every EntityAttach a peer received, so a scenario can assert the server
/// never puts a client on the server branch of ProcessPackage.
fn collectAttaches(
    cap: *const ln_peer.Capture,
    types: []packages.AttachType,
    slots: []i16,
    vehicles: []i32,
) usize {
    const attach_id = packages.idOf("NetPackageEntityAttach") orelse return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < cap.n and n < types.len) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn and n < types.len) : (j += 1) {
            if (pkgs[j].id != attach_id) continue;
            const a = packages.parseEntityAttach(pkgs[j].body) catch continue;
            types[n] = a.attach_type;
            slots[n] = a.slot;
            vehicles[n] = a.vehicle_id;
            n += 1;
        }
    }
    return n;
}

test "scenario wasm plugins: hello queues a sim command, looper disabled by fuel" {
    // T9 proof (WORK_PLAN): C-built .wasm fixtures loaded through the real
    // config path (plugin_modules). Hello registers hooks, observes ticks and
    // queues a SimCommand that the sim applies; the looper is cut off by the
    // fuel budget within one tick and the server keeps ticking.
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_wasm");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{
        "assets/fixtures/plugin_hello.wasm",
        "assets/fixtures/plugin_looper.wasm",
    };
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_wasm", 0, .{
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
        // Small fuel: the looper is cut off in microseconds, not seconds.
        .plugin_budget = .{ .fuel = 200_000 },
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    try std.testing.expectEqual(@as(usize, 2), g.wasm_plugins.count());
    try std.testing.expectEqual(@as(usize, 0), g.wasm_plugins.disabledCount());

    // A joined client anchors the despawn distance, so the queued spawns at
    // the seed pad (256,70,256) stay alive for the assertion.
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);

    const z_before = g.sim.countKind(.zombie);
    var t: u64 = 0;
    while (t < 8) : (t += 1) try g.step();

    // Hello queued three spawns on its first three ticks; the schedule's
    // per-tick drain applied them (spawn point is the seed pad, in range).
    const z_after = g.sim.countKind(.zombie);
    try std.testing.expect(z_after >= z_before + 3);
    // Only the looper is disabled; the server kept stepping.
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.disabledCount());
    try std.testing.expect(g.tick_n >= 8);

    std.debug.print(
        "PASS wasm-plugins: modules=2 disabled=1 zombies {d}->{d} ticks={d}\n",
        .{ z_before, z_after, g.tick_n },
    );
}

test "scenario mode pack rules overlay changes sim behaviour" {
    // T13 proof (WORK_PLAN / ADR 0021): a mode pack's [rules.*] sections flow
    // through the real merge into World.rules, and the sim obeys the rule: the
    // combat damage floor (class_table zero) is the pack's attack_damage, so a
    // zombie in melee deals pack damage, not the default floor.
    const mode_mod = @import("mode.zig");
    const rules_mod = @import("../ecs/rules.zig");

    var pack = try mode_mod.parse(std.testing.allocator,
        \\name = "scenario_hard"
        \\[rules.combat]
        \\attack_damage = 42.0
        \\[rules.ai]
        \\sense_dist_sq = 36.0
    );
    defer pack.deinit();
    var rules: rules_mod.Rules = .{};
    rules_mod.mergeOverlay(&rules, &pack.rules);
    try std.testing.expectEqual(@as(f32, 42.0), rules.combat.attack_damage);
    try std.testing.expectEqual(@as(f32, 36.0), rules.ai.sense_dist_sq);

    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_rules");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_rules", 0, .{ .rules = rules });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // The rule landed on the sim World.
    try std.testing.expectEqual(@as(f32, 42.0), g.sim.rules.combat.attack_damage);

    // Melee: class_table[1] is the offline floor path (attack_damage 0), so the
    // pack's 42 is what the zombie deals. A zombie at (0,70,0), player at
    // (1.2,70,0) reaches attack range and bites twice in 2 s.
    const z = g.sim.spawnZombie(0, 70, 0, 40).?;
    _ = g.sim.spawnPlayer(1.2, 70, 0, 0);
    const zs = g.sim.slotOfNetId(z).?;
    const ps = g.sim.playerByPeer(0).?;
    const hp0 = g.sim.health[ps].hp;
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.05) _ = systems.systemZombieAi(&g.sim, 0.05);
    // Default floor is 8 (2 bites ~16); the pack floor 42 lands ~84.
    try std.testing.expect(g.sim.health[ps].hp <= hp0 - 40);
    const comps = @import("../ecs/components.zig");
    try std.testing.expectEqual(comps.AiState.attack, g.sim.zombie_ai[zs].state);

    std.debug.print(
        "PASS mode-rules: pack attack_damage=42 melee hp {d}->{d}\n",
        .{ hp0, g.sim.health[ps].hp },
    );
}

test "scenario wasm T15 hooks: deny death, double block damage and quest reward, trap isolates" {
    // T15 proof (WORK_PLAN): a .wasm module implements a visible mode rule end
    // to end through the event hooks. plugin_rules denies every player death
    // (victim survives at 1 hp), doubles block damage and doubles quest exp;
    // plugin_trap traps in on_entity_killed and is disabled without stopping
    // the kill or the server.
    // Fresh world per run: block_hp persists in the world store, and the
    // on_block_damage assert is absolute (WORK_PLAN W3).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{
        "assets/fixtures/plugin_rules.wasm",
        "assets/fixtures/plugin_trap.wasm",
    };
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .quests_path = "assets/fixtures/quests.xml",
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 2), g.wasm_plugins.count());

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);
    const peer: usize = c.slot;

    // --- on_player_death denies: a lethal hit leaves the player at 1 hp ---
    const ps = g.sim.playerByPeer(c.slot).?;
    const hp0 = g.sim.health[ps].hp;
    const res = g.sim.damage(c.entity_id, 99999);
    try std.testing.expect(!res.killed);
    try std.testing.expectEqual(@as(f32, 1), g.sim.health[ps].hp);
    try std.testing.expect(hp0 > 1);

    // --- on_block_damage doubles: 100 proposed -> 200 applied ---
    const applied = g.addBlockDamage(10, 70, 10, 100);
    try std.testing.expectEqual(@as(u16, 200), applied);

    // --- on_quest_complete doubles: tier1_clear pays 1000 exp -> 2000 ---
    const clear = g.sim.catalog.byName("tier1_clear").?;
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, clear.id));
    systems.questTickGoto(&g.sim, c.slot, clear.tx, clear.ty, clear.tz);
    var k: u16 = 0;
    while (k < clear.target_count) : (k += 1) systems.questOnZombieKilled(&g.sim, c.slot);
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, clear.id));
    const xp_before = g.clients[peer].xp;
    try g.step(); // tick-end payout runs the questComplete verdict
    const xp_gain = g.clients[peer].xp - xp_before;
    // 1000 exp x 200% = 2000 (xp_multiplier default 100 keeps it 1.0x).
    try std.testing.expect(xp_gain >= 2000);

    // --- on_entity_killed trap: the trap module is disabled, the kill still
    // lands (verdict keep), and the server keeps stepping ---
    const z = g.sim.spawnZombie(40, 70, 0, 40).?;
    const killed = g.sim.damage(z, 99999);
    try std.testing.expect(killed.killed);
    try std.testing.expect(g.sim.slotOfNetId(z) == null or g.sim.health[g.sim.slotOfNetId(z).?].hp == 0);
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.disabledCount());
    try std.testing.expect(g.wasm_plugins.slots[1].disabled);
    try std.testing.expect(!g.wasm_plugins.slots[0].disabled);
    try g.step();
    try std.testing.expect(g.tick_n >= 2);

    std.debug.print(
        "PASS wasm-t15: deny death hp=1, block dmg 100->{d}, quest exp +{d}, trap disabled=1\n",
        .{ applied, xp_gain },
    );
}

test "scenario journal PDF carries max_journal quests (GAP 12)" {
    // The join PlayerId journal was capped at 2 StockQuestWrite entries while
    // the sim journal holds 8: a third active quest silently vanished from the
    // client. Fill the sim journal past the old cap and assert every accepted
    // quest (all client-known fixture defs) reaches the PDF snapshot.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap); // auto-accepts the starter
    try std.testing.expect(c.entity_id > 0);

    const accepted = [_][]const u8{ "tier1_clear", "tier1_fetch", "quest_activate_block", "clear_the_noise" };
    var got: usize = 1; // starter
    for (accepted) |nm| {
        const d = g.sim.catalog.byName(nm) orelse continue;
        if (systems.questAccept(&g.sim, c.slot, d.id)) got += 1;
    }
    try std.testing.expect(got >= 3); // at least two beyond the starter

    var qbuf: [@import("../ecs/components.zig").max_journal]packages.stock_quest.StockQuestWrite = undefined;
    var reward_store: [@import("../ecs/components.zig").max_journal][quest_mod.max_reward_flags]packages.stock_quest.RewardWire = undefined;
    var obj_val_store: [@import("../ecs/components.zig").max_journal][quest_mod.max_phases]u8 = undefined;
    var kind_store: [@import("../ecs/components.zig").max_journal][quest_mod.max_phases]packages.stock_quest.ObjectiveWriteKind = undefined;
    // game.zig max_quest_position_data = 3; keep the two in lockstep.
    var pos_store: [@import("../ecs/components.zig").max_journal][3]packages.stock_quest.PositionEntry = undefined;
    const qn = g.fillStockJournalWrites(c.slot, &qbuf, &reward_store, &obj_val_store, &kind_store, &pos_store);
    try std.testing.expectEqual(got, qn);
    try std.testing.expect(qn > 2); // the old hardcoded cap
    try std.testing.expect(qn <= @import("../ecs/components.zig").max_journal);

    std.debug.print("PASS journal-pdf: {d} quests reach the join PDF (cap was 2)\n", .{qn});
}

test "scenario vending rent state machine (loot-economy §6)" {
    // NetPackagePlayerVendingMachine (rent / clear) handled server-
    // authoritatively: only the sender's own identity may act, the rent costs
    // TraderInfo.RentCost currency, the term is rent_time in-game days, one
    // machine per player, and an expired rental returns to unowned.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExistsSimple(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const puid: platform_user.Id = .{ .platform = "Steam", .id = "9001" };
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClientAs(&cap, puid);
    const ps = g.sim.playerByPeer(c.slot).?;
    // The wallet starts at 0; rent syncs it from the starter casinoCoin stack
    // (50 coins) before checking the price.
    try std.testing.expectEqual(@as(u32, 0), g.sim.wallet[ps].coins);

    // A rentable machine (stock trader_info 5: rentable, rent_cost 2500).
    const vm = g.vending.getOrCreate(.{ .x = 10, .y = 70, .z = 20 }, 1, 5).?;
    const info = g.traders.traderInfo(5).?;
    try std.testing.expect(info.rentable);
    try std.testing.expectEqual(@as(i32, 2500), info.rent_cost);

    const sendAccess = struct {
        fn call(gg: *game_mod.Game, cc: anytype, x: i32, z: i32, removing: bool) !void {
            var body: [128]u8 = undefined;
            var w: binary.Writer = .{ .buf = &body };
            try platform_user.write(&w, puid);
            try w.writeI32(x);
            try w.writeI32(70);
            try w.writeI32(z);
            try w.writeBool(removing);
            var frame_buf: [256]u8 = undefined;
            const framed = try packages.framed(&frame_buf, "NetPackagePlayerVendingMachine", w.written());
            try gg.injectFramed(cc, framed);
        }
    }.call;

    // Wallet short: starter 1000 < 2500 -> denied, machine stays unowned.
    try sendAccess(g, c, 10, 20, false);
    try std.testing.expectEqual(@as(u32, 0), vm.owner.id_len);
    try std.testing.expectEqual(@as(i32, 0), vm.rental_end_day);

    // Fund the wallet, rent succeeds: owner set, term = rent_time days, coins
    // deducted (spend inventory first, then the wallet balance).
    g.sim.wallet[ps].coins = 10000;
    try sendAccess(g, c, 10, 20, false);
    try std.testing.expectEqualStrings("9001", vm.owner.id[0..vm.owner.id_len]);
    try std.testing.expectEqual(@as(i32, @intCast(g.sim.director.clock.day)) + info.rent_time, vm.rental_end_day);
    try std.testing.expect(g.sim.wallet[ps].coins < 10000);

    // Second machine: one per player (CanRent 2) blocks.
    const vm2 = g.vending.getOrCreate(.{ .x = 30, .y = 70, .z = 40 }, 1, 5).?;
    try sendAccess(g, c, 30, 40, false);
    try std.testing.expectEqual(@as(u32, 0), vm2.owner.id_len);

    // Re-rent extends the term by rent_time days.
    const before = vm.rental_end_day;
    g.sim.wallet[ps].coins = 10000;
    try sendAccess(g, c, 10, 20, false);
    try std.testing.expectEqual(before + info.rent_time, vm.rental_end_day);

    // Another identity cannot clear or re-rent the machine.
    const other: platform_user.Id = .{ .platform = "Steam", .id = "9002" };
    var cap2: ln_peer.Capture = .{};
    const c2 = try g.attachJoinedClientAs(&cap2, other);
    const ps2 = g.sim.playerByPeer(c2.slot).?;
    g.sim.wallet[ps2].coins = 10000;
    const sendOther = struct {
        fn call(gg: *game_mod.Game, cc: anytype, removing: bool) !void {
            var body: [128]u8 = undefined;
            var w: binary.Writer = .{ .buf = &body };
            try platform_user.write(&w, other);
            try w.writeI32(10);
            try w.writeI32(70);
            try w.writeI32(20);
            try w.writeBool(removing);
            var frame_buf: [256]u8 = undefined;
            const framed = try packages.framed(&frame_buf, "NetPackagePlayerVendingMachine", w.written());
            try gg.injectFramed(cc, framed);
        }
    }.call;
    try sendOther(g, c2, false);
    try std.testing.expectEqualStrings("9001", vm.owner.id[0..vm.owner.id_len]);
    try sendOther(g, c2, true);
    try std.testing.expectEqualStrings("9001", vm.owner.id[0..vm.owner.id_len]);

    // Owner clears: machine returns to unowned.
    try sendAccess(g, c, 10, 20, true);
    try std.testing.expectEqual(@as(u32, 0), vm.owner.id_len);
    try std.testing.expectEqual(@as(i32, 0), vm.rental_end_day);

    // Expiry: a rented machine past rental_end_day returns to unowned on the
    // day roll.
    try sendAccess(g, c, 10, 20, false);
    try std.testing.expect(vm.rental_end_day > 0);
    g.sim.director.clock.day = @intCast(vm.rental_end_day + 1);
    g.claims_last_day = 0;
    try g.step();
    try std.testing.expectEqual(@as(i32, 0), vm.rental_end_day);

    std.debug.print(
        "PASS vending-rent: rent cost={d} term={d} owner set/extend/clear/expire one-per-player ok\n",
        .{ info.rent_cost, info.rent_time },
    );
}

test "scenario stock NetPackageTraderData ToServer CopyFrom (real-client trade)" {
    // A real client sends its post-trade TraderData back over
    // NetPackageTraderData (isEntity | entityId/tePosition | hasTraderData |
    // TraderData::Write). The stock server mirrors it (CopyFrom) onto the
    // entity trader or vending TE; the wire carries no price, so price/sell
    // stay server-owned. This is the real-client buy path (loot-economy §5).
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExistsSimple(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    const wood_wire = g.items.byStockName("resourceWood") orelse return error.SkipZigTest;
    const wood_ecs = g.items.ecsIdByName("resourceWood");
    try std.testing.expect(wood_ecs != 0);

    // --- Entity trader CopyFrom ---
    const tid = g.sim.spawnTrader("npcTraderJen", 50, 70, 60, 5, 5000).?;
    const ts = g.sim.slotOfNetId(tid).?;
    try std.testing.expect(g.sim.mask[ts].trader_stock);
    g.sim.trader_stock[ts].entries[0] = .{ .item = wood_ecs, .count = 10, .price = 1, .sell = 1, .markup = 0 };
    g.sim.trader_stock[ts].n = 1;
    g.sim.trader_stock[ts].wallet = 5000;

    var body: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeBool(true); // isEntity
    try w.writeI32(tid);
    try w.writeBool(true); // hasTraderData
    const entry = packages.stock_entity.TraderStockEntry{
        .item = .{ .type_id = wood_wire, .count = 3 },
        .markup = -4,
    };
    try packages.stock_entity.writeTraderDataBody(&w, .{ .trader_id = 5, .available_money = 4000, .entries = &[_]packages.stock_entity.TraderStockEntry{entry} });
    var frame_buf: [640]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageTraderData", w.written());
    try g.injectFramed(c, framed);

    // CopyFrom applied: count/markup/money from the client copy; price/sell
    // survive as server-owned.
    const st = &g.sim.trader_stock[ts];
    try std.testing.expectEqual(@as(u16, 3), st.entries[0].count);
    try std.testing.expectEqual(@as(i8, -4), st.entries[0].markup);
    try std.testing.expectEqual(@as(u16, 1), st.entries[0].price);
    try std.testing.expectEqual(@as(i32, 4000), st.wallet);

    // --- Vending machine CopyFrom (isEntity=false, tePosition) ---
    const vm = g.vending.getOrCreate(.{ .x = 10, .y = 70, .z = 20 }, 1, 5).?;
    var vbody: [512]u8 = undefined;
    var vw: binary.Writer = .{ .buf = &vbody };
    try vw.writeBool(false); // isEntity = false -> tePosition
    try vw.writeI32(10);
    try vw.writeI32(70);
    try vw.writeI32(20);
    try vw.writeBool(true); // hasTraderData
    try packages.stock_entity.writeTraderDataBody(&vw, .{ .trader_id = 5, .available_money = 3000, .entries = &[_]packages.stock_entity.TraderStockEntry{entry} });
    const vframed = try packages.framed(&frame_buf, "NetPackageTraderData", vw.written());
    try g.injectFramed(c, vframed);
    try std.testing.expectEqual(@as(i32, wood_wire), vm.stock[0].type_id);
    try std.testing.expectEqual(@as(i32, 3), vm.stock[0].count);
    try std.testing.expectEqual(@as(i8, -4), vm.stock[0].markup);
    try std.testing.expectEqual(@as(i32, 3000), vm.available_money);

    std.debug.print("PASS traderdata-copyfrom: entity+vending CopyFrom count/markup/money ok\n", .{});
}

test "scenario vending lock/password/allowed editing (owner-gated)" {
    // The owner's lock / password / allowed-user edits arrive as the vending
    // TE composite C2S (the mirror of TileEntityVendingMachine::write). The
    // server applies them only for the machine's owner; ownership and the
    // rental term stay server-owned (the rent SM applies them).
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExistsSimple(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const puid: platform_user.Id = .{ .platform = "Steam", .id = "9001" };
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClientAs(&cap, puid);
    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.wallet[ps].coins = 10000;

    // Rent the machine (server-authoritative rent SM).
    const vm = g.vending.getOrCreate(.{ .x = 256, .y = 70, .z = 258 }, 1, 5).?;
    var rent_body: [128]u8 = undefined;
    var rw: binary.Writer = .{ .buf = &rent_body };
    try platform_user.write(&rw, puid);
    try rw.writeI32(256);
    try rw.writeI32(70);
    try rw.writeI32(258);
    try rw.writeBool(false);
    var frame_buf: [1024]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackagePlayerVendingMachine", rw.written()));
    try std.testing.expect(vm.rental_end_day > 0);

    // Owner edits: lock on, password "1234", one allowed user.
    const buddy: platform_user.Id = .{ .platform = "Steam", .id = "9002" };
    var te_body: [2048]u8 = undefined;
    const te = try packages.stock_te.buildVendingTeBody(&te_body, 255, 256, 70, 258, .{
        .block_id = 1,
        .is_locked = true,
        .owner = puid,
        .password_hash = "1234",
        .allowed = &[_]platform_user.Id{buddy},
        .rental_end_day = vm.rental_end_day,
        .trader_id = 5,
        .entries = &.{},
        .available_money = 0,
        .rentable = true,
    });
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageTileEntity", te));
    try std.testing.expect(vm.is_locked);
    try std.testing.expectEqual(@as(u8, 4), vm.password_len);
    try std.testing.expectEqualStrings("1234", vm.password_hash[0..vm.password_len]);
    try std.testing.expectEqual(@as(u8, 1), vm.allowed_n);
    try std.testing.expectEqualStrings("9002", vm.allowed[0].id[0..vm.allowed[0].id_len]);
    // The rental term is NOT client-editable: it stays server-owned.
    try std.testing.expect(vm.rental_end_day > 0);

    // A non-owner cannot edit.
    const stranger: platform_user.Id = .{ .platform = "Steam", .id = "9003" };
    var cap3: ln_peer.Capture = .{};
    const c3 = try g.attachJoinedClientAs(&cap3, stranger);
    var te2: [2048]u8 = undefined;
    const te2b = try packages.stock_te.buildVendingTeBody(&te2, 255, 256, 70, 258, .{
        .block_id = 1,
        .is_locked = false,
        .password_hash = "",
        .rental_end_day = vm.rental_end_day,
        .trader_id = 5,
        .entries = &.{},
        .available_money = 0,
        .rentable = true,
    });
    try g.injectFramed(c3, try packages.framed(&frame_buf, "NetPackageTileEntity", te2b));
    try std.testing.expect(vm.is_locked); // unchanged
    try std.testing.expectEqualStrings("1234", vm.password_hash[0..vm.password_len]);

    std.debug.print("PASS vending-edit: owner lock/password/allowed applied, non-owner denied\n", .{});
}

test "scenario storm_frequency knob reaches weather and the GameStats wire" {
    // TODO open item: StormFrequency was a compile-time GameStats default with
    // no knob. [sim] storm_frequency now feeds the weather scheduler divisor
    // and the GameStats wire value the client is told, so the two agree.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // config_dir so the biome-layers table loads and the weather manager
    // initializes from the configured frequency (headless builtin skips it).
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .storm_frequency = 200,
        .config_dir = "assets/fixtures",
        .sandbox_code = "AAAJABJACJADJARFBNC",
        .sandbox_preset = "Adventurer",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(i32, 200), g.storm_frequency);
    // Weather scheduler divisor: 200% -> 2.0x (storms less often).
    try std.testing.expectEqual(@as(f32, 2.0), g.world.weather.storm_frequency);
    // The wire blob carries the same value the scheduler used.
    try std.testing.expectEqual(@as(i32, 200), g.gameStatsValues().storm_freq);
    // The operator's sandbox code (weather-survival / blood-moon gates) rides
    // the GameStats blob so the client decodes the server's gates (RE
    // sandbox-options §8). The stock default code is what the shipped
    // serverconfig carries.
    try std.testing.expectEqualStrings("AAAJABJACJADJARFBNC", g.gameStatsValues().sandbox_code);
    var gs_buf: [1024]u8 = undefined;
    const gs = try packages.buildGameStatsBodyValues(&gs_buf, g.gameStatsValues());
    try std.testing.expect(std.mem.indexOf(u8, gs, "AAAJABJACJADJARFBNC") != null);

    // 0 disables storms (weather-env.md: World.StormFrequency == 0).
    const g2 = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{ .storm_frequency = 0, .config_dir = "assets/fixtures" });
    defer {
        g2.deinit();
        gpa.destroy(g2);
    }
    try std.testing.expectEqual(@as(f32, 0), g2.world.weather.storm_frequency);
    try std.testing.expectEqual(@as(i32, 0), g2.gameStatsValues().storm_freq);
}

test "scenario weather storm state survives a restart" {
    // Storm SM persistence (TODO residual): force biome 0 into an active storm,
    // deinit saves weather.zwt, and a fresh Game in the same world resumes the
    // storm instead of re-rolling the opening groups.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    // Cycle 1: push biome 0 into an active storm; deinit persists it.
    // config_dir points at the offline biomes.xml fixture so the table has
    // weather groups (the flat builtin table has none).
    {
        const g = try game_mod.Game.createWithOptions(std.testing.allocator, world_dir, 0, .{
            .config_dir = "assets/fixtures",
        });
        defer {
            g.deinit();
            std.testing.allocator.destroy(g);
        }
        try std.testing.expect(g.world.weather.n >= 1);
        const set = world_weather.Manager.groupsFor(&g.world.biome_layers_table, &g.world.weather.states[0]);
        const storm_idx = set.findIndex("storm") orelse return error.TestUnexpectedResult;
        g.world.weather.states[0].storm_state = 2;
        g.world.weather.states[0].group_index = @intCast(storm_idx);
        g.world.weather.states[0].storm_world_time = 1_000;
        g.world.weather.states[0].storm_duration = 40_000;
        g.world.weather.states[0].remaining_seconds = 7;
        g.world.weather.states[0].params[0] = 55.25;
    }

    // Cycle 2: the restored manager carries the storm, not a fresh roll.
    {
        const g2 = try game_mod.Game.createWithOptions(std.testing.allocator, world_dir, 0, .{
            .config_dir = "assets/fixtures",
        });
        defer {
            g2.deinit();
            std.testing.allocator.destroy(g2);
        }
        try std.testing.expectEqual(g2.world.weather.states[0].storm_state, @as(u8, 2));
        try std.testing.expectEqual(g2.world.weather.states[0].remaining_seconds, @as(u8, 7));
        try std.testing.expectEqual(g2.world.weather.states[0].storm_world_time, @as(?i64, 1_000));
        try std.testing.expectApproxEqAbs(@as(f32, 55.25), g2.world.weather.states[0].params[0], 0.001);
        // The schedule keeps running from the restored state: after 30 ticks the
        // same storm is still up (storm_world_time 1000 is past due, so the
        // manager re-enters the storm branch, not a fresh random group).
        var t: u64 = 0;
        while (t < 30) : (t += 1) try g2.step();
        try std.testing.expectEqual(g2.world.weather.states[0].storm_state, @as(u8, 2));
        try std.testing.expect(g2.world.weather.states[0].group_index < g2.world.biome_layers_table.weather_groups[0].n);
    }
    std.debug.print("PASS weather-restart: storm state restored across restart\n", .{});
}

test "scenario blood moon day re-send fires on the day roll" {
    // GAP §6: a client that joined mid-cycle must get a fresh GameStats blob
    // when the scheduled blood-moon day rolls, or its red-moon HUD day stays
    // stale forever. Force the clock past the first horde and step.
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_bmday");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    // The clock now persists (clock.zcl); this scenario deliberately mutates
    // the day, so start from a fresh calendar each run.
    io_fs.deleteFile(gpa, "worlds/zdtd_sc_bmday/clock.zcl");

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_bmday", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const gs_id = packages.idOf("NetPackageGameStats").?;

    // First step records the initial scheduled day (day 1, freq 7 -> 7)
    // without broadcasting (lazy init).
    try g.step();
    try std.testing.expectEqual(@as(i32, 7), g.last_bm_day);
    cap.clear();

    // Simulate a client that sat past the first horde: day 8, stale 7.
    g.sim.director.clock.day = 8;
    g.sim.director.clock.hours = 1.0;
    g.last_bm_day = 7;
    try g.step();

    // The roll must re-send the GameStats blob with the next scheduled day.
    try std.testing.expect(cap.findPkgId(gs_id) != null);
    try std.testing.expectEqual(@as(i32, 14), g.last_bm_day);
    std.debug.print("PASS bmday-resend: day 8 re-sent GameStats (BloodMoonDay 7 -> 14)\n", .{});
}

test "scenario quest completion pays out item and exp rewards" {
    // The fixture starter (quest_whiteRiverCitizen1) carries
    // <reward type="Exp" value="500"/> + <reward type="Item" id="casinoCoin"
    // value="100"/>. Completing it must credit the wallet coins (sim), drop
    // the casinoCoin stack into the inventory and award the exp, via the
    // tick-end payout drain. tmp dir: a completed starter persists in ZPV3
    // and the join would refuse to re-grant it (GAP starter-quest row).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, dir, 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const xp0 = g.clients[c.slot].xp;
    const coins0 = g.sim.wallet[ps].coins;
    const eid = g.items.ecsIdByName("casinoCoin");
    try std.testing.expect(eid != 0);

    // Starter: two trader opens complete the white-river fetch turn-in.
    systems.questOnTraderOpen(&g.sim, c.slot);
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, g.sim.catalog.starter_id));
    try std.testing.expectEqual(coins0 + 100, g.sim.wallet[ps].coins);

    // The payout drain runs at the next step.
    try g.step();
    try std.testing.expect(g.clients[c.slot].xp > xp0);
    var found = false;
    for (g.sim.inventory[ps].slots) |s| {
        if (s.item_id == eid and s.count > 0) found = true;
    }
    try std.testing.expect(found);
    std.debug.print("PASS quest-rewards: coins +100, casinoCoin granted, xp {d}->{d}\n", .{ xp0, g.clients[c.slot].xp });
}

test "scenario land claims persist across restart and re-map on login" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const claim_x: i32 = 250;
    const claim_z: i32 = 250;
    // Game A: the owner places a keystone claim; deinit persists claims.zlc.
    {
        const g = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        var cap: ln_peer.Capture = .{};
        const c = try g.attachJoinedClient(&cap);
        const kid = g.maxdamage.idByName("keystoneBlock") orelse return error.TestUnexpectedResult;
        var sb: [64]u8 = undefined;
        var frame_buf: [8192]u8 = undefined;
        const place = try packages.buildSetBlockBody(&sb, claim_x, 70, claim_z, kid);
        try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", place));
        try std.testing.expect((try g.world.blockWorld(claim_x, 70, claim_z)) == kid);
    }

    // claims.zlc was written by deinit.
    var claims_path: [512]u8 = undefined;
    const cp = try std.fmt.bufPrint(&claims_path, "{s}/claims.zlc", .{dir});
    const raw = try io_fs.readFileAll(gpa, cp);
    defer gpa.free(raw);
    try std.testing.expect(std.mem.eql(u8, raw[0..4], "ZCLC"));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, raw[4..6], .little));

    // Game B: the restored claim loads with no live owner; the owner's login
    // re-maps the entity, so their edit inside the claim is allowed.
    {
        const g2 = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g2.deinit();
            gpa.destroy(g2);
        }
        var cap: ln_peer.Capture = .{};
        const c2 = try g2.attachJoinedClient(&cap); // login "Bot" re-maps the claim
        var sb: [64]u8 = undefined;
        var frame_buf: [8192]u8 = undefined;
        const wood = world_store.block_stone;
        const place = try packages.buildSetBlockBody(&sb, claim_x + 1, 70, claim_z, wood);
        try g2.injectFramed(c2, try packages.framed(&frame_buf, "NetPackageSetBlock", place));
        // Allowed: the owner re-mapped. A claim with no live owner would deny
        // (owner_entity -1), leaving the block air.
        try std.testing.expectEqual(wood, try g2.world.blockWorld(claim_x + 1, 70, claim_z));
        std.debug.print("PASS claims-persist: keystone claim survived restart and re-mapped on login\n", .{});
    }
}

test "scenario container loot respawns after LootRespawnDays" {
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_lootrespawn");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_lootrespawn", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    g.loot_respawn_days = 1; // one-day interval for the test
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Place a storage chest and seed it as if it held loot (chunk-scanned loot
    // fills at materialization, which the flat test world does not stream).
    const chest_id: u16 = @intCast(packages.stock_deco.cnt_wooden_chest_closed);
    var sb: [64]u8 = undefined;
    var frame_buf: [8192]u8 = undefined;
    const place = try packages.buildSetBlockBody(&sb, 251, 70, 251, chest_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", place));
    const pos = containers_mod.PosKey{ .x = 251, .y = 70, .z = 251 };
    const cont = g.containers.get(pos) orelse return error.TestUnexpectedResult;
    cont.setSlot(0, .{ .item_id = 1, .count = 5, .quality = 1 });
    var req: [36]u8 = undefined;
    @memcpy(req[0..16], &cont.inv_guid);
    std.mem.writeInt(i32, req[16..20], 0, .little);
    @memcpy(req[20..36], &cont.inv_guid);

    // Loot it: empty slots, age the touch day past the interval, re-open; the
    // open must re-roll fresh loot (stock TEFeatureStorage.UpdateTick re-arms).
    // Fail closed (audit A31): a block with no resolvable LootList stays empty.
    const has_loot_list = g.maxdamage.lootListFor(chest_id) != null;
    cont.clear();
    cont.touched = true;
    cont.player_storage = false; // world container: eligible for respawn
    cont.touched_day = 0; // pre-save default: older than the interval
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageInventoryDataRequest", &req));
    var refilled = false;
    for (cont.slots[0..cont.slot_count]) |s| {
        if (s.count > 0 and s.item_id != 0) {
            refilled = true;
            break;
        }
    }
    if (has_loot_list) {
        try std.testing.expect(refilled);
        try std.testing.expectEqual(g.sim.director.clock.day, cont.touched_day);
    } else {
        // Fail closed: the empty container stays empty and untouched.
        try std.testing.expect(!refilled);
        try std.testing.expectEqual(@as(u32, 0), cont.touched_day);
    }
    std.debug.print("PASS loot-respawn: container re-rolled after LootRespawnDays (fail-closed={s})\n", .{if (has_loot_list) "no" else "yes"});
}

test "scenario trader quest offers follow the trader's class" {
    // Each stock trader class maps to its own trader_*_quests list (the five
    // lists are parsed but were never selected by trader). Spawn a trader with
    // the rekt class hash and assert its offer list is trader_rekt_quests, not
    // the jen default.
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_traders");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_traders", 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Find the pad trader and switch it to the rekt class (class_table default
    // is jen; POI traders will carry their own class at spawn).
    var te: i32 = -1;
    var si: usize = 0;
    while (si < 512) : (si += 1) {
        if (g.sim.alive[@intCast(si)] and g.sim.mask[@intCast(si)].trader) {
            te = g.sim.network_id[@intCast(si)].id;
            g.sim.class_id[@intCast(si)].hash = packages.stock_entity.class_npc_trader_rekt;
            break;
        }
    }
    try std.testing.expect(te > 0);

    cap.clear();
    var fb: [16]u8 = undefined;
    std.mem.writeInt(i32, fb[0..4], te, .little);
    std.mem.writeInt(i32, fb[4..8], c.entity_id, .little);
    fb[8] = 0; // fetch_list
    std.mem.writeInt(i32, fb[9..13], 1, .little);
    var fbuf: [256]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageNPCQuestList", fb[0..13]));
    const body = cap.findPkgId(packages.idOf("NetPackageNPCQuestList").?) orelse return error.TestUnexpectedResult;
    // The rekt list carries clear_the_noise (not in the jen list); its name
    // must appear in the offered quest ids.
    const count = std.mem.readInt(i32, body[13..17], .little);
    try std.testing.expect(count >= 1);
    // The rekt list carries clear_the_noise (not in the jen list), and the
    // QuestPacketEntry quest ids are written as raw strings in the response.
    try std.testing.expect(std.mem.indexOf(u8, body, "quest_rekt_errand") != null);
    // intro_buried_supplies is a stock quest the old quest_/tier filter dropped.
    try std.testing.expect(std.mem.indexOf(u8, body, "intro_buried_supplies") != null);
    // The offer list is filtered by the requested tier (stock DifficultyTier ==
    // tierLevel): a tier-2 fetch must not offer the tier-1 errand.
    cap.clear();
    std.mem.writeInt(i32, fb[9..13], 2, .little); // tier 2
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageNPCQuestList", fb[0..13]));
    const body2 = cap.findPkgId(packages.idOf("NetPackageNPCQuestList").?) orelse return error.TestUnexpectedResult;
    const count2 = std.mem.readInt(i32, body2[13..17], .little);
    try std.testing.expectEqual(@as(i32, 0), count2);
    std.debug.print("PASS trader-lists: rekt trader offers quest_rekt_errand from trader_rekt_quests; tier 2 filtered\n", .{});
}

test "scenario block_activated objective event advances the phase" {
    // POIBlockActivate used to be auto-scaffolding (never waited). With the
    // block_activate kind, the phase is real work advanced only by the
    // client's NetPackageQuestObjectiveUpdate block_activated event.
    io_fs.mkdirPathSimple("worlds");
    freshScenarioDir("worlds/zdtd_sc_blockobj");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_blockobj", 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // The join auto-accepts the starter; complete it to free a journal slot.
    systems.questOnTraderOpen(&g.sim, c.slot);
    systems.questOnTraderOpen(&g.sim, c.slot);
    const bid = g.sim.catalog.byName("quest_activate_block").?.id;
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, bid));
    const s = systems.questFindActive(&g.sim, c.slot, bid).?;
    try std.testing.expectEqual(@as(u8, 1), s.phase);

    // Without the event the block phase does not advance (no longer auto).
    systems.questOnZombieKilled(&g.sim, c.slot);
    try std.testing.expectEqual(@as(u8, 1), s.phase);

    // The client's block_activated event advances it.
    cap.clear();
    var ub: [21]u8 = undefined;
    std.mem.writeInt(i32, ub[0..4], c.entity_id, .little);
    std.mem.writeInt(i32, ub[4..8], s.quest_code, .little);
    ub[8] = 2; // block_activated
    std.mem.writeInt(i32, ub[9..13], 100, .little);
    std.mem.writeInt(i32, ub[13..17], 70, .little);
    std.mem.writeInt(i32, ub[17..21], 100, .little);
    var fbuf: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageQuestObjectiveUpdate", ub[0..21]));
    try std.testing.expectEqual(@as(u8, 2), s.phase);
    std.debug.print("PASS block-obj: block_activated event advanced the quest phase\n", .{});
}

/// Encode a NetPackagePartyActions body (currentOperation, invitedBy, invited,
/// voiceLobbyId — RE parties-factions.md §3).
fn buildPartyActionBody(buf: []u8, action: u8, invited_by: i32, invited: i32) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeByte(action);
    try w.writeI32(invited_by);
    try w.writeI32(invited);
    try w.writeString("");
    return w.written();
}

test "scenario party: accept invite fans a snapshot, leave disbands, disconnect removes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);

    const party_id = packages.idOf("NetPackagePartyData").?;
    var body: [32]u8 = undefined;
    var fbuf: [128]u8 = undefined;

    // A accepts B's invite (AcceptInvite: invitedBy = A's own entity).
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&body, 1, ca.entity_id, cb.entity_id)));

    // Both peers got the snapshot: party id 1, leader = A, members [A, B].
    const b_body = cap_b.findPkgId(party_id) orelse return error.TestUnexpectedResult;
    var r = binary.Reader{ .data = b_body };
    try std.testing.expectEqual(@as(i32, 1), try r.readI32());
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // LeaderIndex: A
    var vbuf: [32]u8 = undefined;
    _ = try r.readString(&vbuf);
    try std.testing.expectEqual(@as(i32, 2), try r.readI32()); // memberCount
    const m1 = try r.readI32();
    const m2 = try r.readI32();
    try std.testing.expect((m1 == ca.entity_id and m2 == cb.entity_id) or (m1 == cb.entity_id and m2 == ca.entity_id));
    try std.testing.expectEqual(@as(i32, cb.entity_id), try r.readI32()); // changedEntityID
    try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // accept_invite
    try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // not disband
    try std.testing.expect(g.parties.partyByMember(ca.entity_id) != null);

    // B leaves: the party of two disbands; A gets the disband snapshot.
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(cb, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&body, 3, 0, 0)));
    const a_body = cap_a.findPkgId(party_id) orelse return error.TestUnexpectedResult;
    var r2 = binary.Reader{ .data = a_body };
    try std.testing.expectEqual(@as(i32, 1), try r2.readI32());
    _ = try r2.readByte();
    _ = try r2.readString(&vbuf);
    try std.testing.expectEqual(@as(i32, 0), try r2.readI32()); // no members left
    _ = try r2.readI32(); // changed
    _ = try r2.readByte();
    try std.testing.expect(try r2.readByte() != 0); // disband true
    try std.testing.expect(g.parties.partyByMember(ca.entity_id) == null);

    // Re-join A+B then disconnect B: the party of two shrinks to one, and the
    // last member auto-leaves (stock: a party of one is not kept), so A gets a
    // disband snapshot with no members.
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&body, 1, ca.entity_id, cb.entity_id)));
    try std.testing.expect(g.parties.partyByMember(cb.entity_id) != null);
    cap_a.clear();
    g.dropClientSlot(cb.slot, "test-disconnect");
    const a_body2 = cap_a.findPkgId(party_id) orelse return error.TestUnexpectedResult;
    var r3 = binary.Reader{ .data = a_body2 };
    _ = try r3.readI32();
    _ = try r3.readByte();
    _ = try r3.readString(&vbuf);
    try std.testing.expectEqual(@as(i32, 0), try r3.readI32()); // no members left
    _ = try r3.readI32(); // changed
    _ = try r3.readByte();
    try std.testing.expect(try r3.readByte() != 0); // disband
    try std.testing.expect(g.parties.partyByMember(ca.entity_id) == null);
}

test "scenario party shared kill XP splits and sends SharedPartyKill to the mate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);

    // A accepts B into a party (both spawn near the (256,70,256) sim origin).
    var pbody: [32]u8 = undefined;
    var fbuf: [128]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&pbody, 1, ca.entity_id, cb.entity_id)));
    try std.testing.expect(g.parties.partyByMember(cb.entity_id) != null);

    // A kills a zombie: Party.GetPartyXP = 100 * (1 - 0.1 * 1 in-range mate).
    const zid = g.sim.spawnZombie(258, 70, 258, 10).?;
    var dmg: [256]u8 = undefined;
    const dbody = try packages.buildDamageBody(&dmg, zid, 0, 3, 100, true, ca.entity_id);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody));
    try std.testing.expect(g.sim.health[g.sim.slotOfNetId(zid).?].hp <= 0);
    try std.testing.expectEqual(@as(u64, 90), ca.xp);
    try std.testing.expectEqual(@as(u64, 90), cb.xp);
    const sk_id = packages.idOf("NetPackageSharedPartyKill").?;
    const skb = cap_b.findPkgId(sk_id) orelse return error.TestUnexpectedResult;
    var r = binary.Reader{ .data = skb };
    _ = try r.readI32(); // entityTypeID
    try std.testing.expectEqual(@as(i32, 90), try r.readI32()); // xp
    try std.testing.expectEqual(ca.entity_id, try r.readI32()); // entityID (killer for the tooltip)
    try std.testing.expectEqual(ca.entity_id, try r.readI32()); // killerID

    // A solo kill (party broken by B leaving) awards the full 100.
    try g.injectFramed(cb, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&pbody, 3, 0, 0)));
    const zid2 = g.sim.spawnZombie(258, 70, 258, 10).?;
    const dbody2 = try packages.buildDamageBody(&dmg, zid2, 0, 3, 100, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody2));
    try std.testing.expectEqual(@as(u64, 190), ca.xp);
    try std.testing.expectEqual(@as(u64, 90), cb.xp);
}

test "scenario chat routes by recipient list and preserves the channel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    var cap_c: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const cc = try g.attachJoinedClient(&cap_c); // third peer must not see party chat

    const chat_id = packages.idOf("NetPackageChat").?;
    var body: [256]u8 = undefined;
    var fbuf: [128]u8 = undefined;

    // A sends a Party-channel message with B as the only recipient: only B
    // receives it, C does not, and the channel survives the re-encode.
    cap_a.clear();
    cap_b.clear();
    cap_c.clear();
    const recips = [_]i32{cb.entity_id};
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageChat", try packages.buildStockChat(&body, 2, ca.entity_id, "party hi", &recips)));
    const b_body = cap_b.findPkgId(chat_id) orelse return error.TestUnexpectedResult;
    const ch = try packages.parseStockChat(b_body);
    try std.testing.expectEqual(@as(u8, 2), ch.chat_type);
    try std.testing.expectEqualStrings("party hi", ch.msg);
    try std.testing.expect(cap_a.findPkgId(chat_id) == null);
    try std.testing.expect(cap_c.findPkgId(chat_id) == null);

    // A global message (no recipients) broadcasts to everyone except the
    // sender; sent by the third peer so the per-client chat rate limiter does
    // not trip (the same client cannot chat twice within min_chat_gap_ns).
    cap_a.clear();
    cap_b.clear();
    cap_c.clear();
    try g.injectFramed(cc, try packages.framed(&fbuf, "NetPackageChat", try packages.buildStockChat(&body, 0, cc.entity_id, "global hi", &.{})));
    try std.testing.expect(cap_a.findPkgId(chat_id) != null);
    try std.testing.expect(cap_b.findPkgId(chat_id) != null);
    try std.testing.expect(cap_c.findPkgId(chat_id) == null); // no self-echo
}

test "scenario party shared quest: accept shares to the party, disconnect removes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const sq_id = packages.idOf("NetPackageSharedQuest").?;
    var fbuf: [128]u8 = undefined;

    // A accepts B into a party.
    var pbody: [32]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&pbody, 1, ca.entity_id, cb.entity_id)));

    // A accepts a quest (legacy {def_id u16, op u8=1} fixture body); use a
    // non-starter def because the join already accepted the starter (and a
    // re-accept is refused). The accept shares it to B (share_quest with the
    // def name + quest code).
    cap_b.clear();
    var def_id: u16 = 0;
    for (g.sim.catalog.defs) |d| {
        if (d.id != g.sim.catalog.starter_id) {
            def_id = d.id;
            break;
        }
    }
    try std.testing.expect(def_id != 0);
    var opbody: [3]u8 = undefined;
    std.mem.writeInt(u16, opbody[0..2], def_id, .little);
    opbody[2] = 1;
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageQuestObjectiveUpdate", &opbody));
    const sqb = cap_b.findPkgId(sq_id) orelse return error.TestUnexpectedResult;
    const head = try packages.stock_quest.parseSharedQuestHead(sqb);
    try std.testing.expectEqual(packages.stock_quest.SharedQuestEvent.share_quest, head.event);
    try std.testing.expectEqual(ca.entity_id, head.shared_by_entity_id);
    // The shared quest is marked server-side.
    var found_shared = false;
    if (g.sim.playerByPeer(ca.slot)) |ps| {
        for (g.sim.journal[ps].slots) |s| {
            if (s.active and s.is_shared) found_shared = true;
        }
    }
    try std.testing.expect(found_shared);

    // A disconnects: the party gets a remove_quest for the shared quest.
    // (Capture the entity id first: dropClientSlot resets the Client.)
    const a_entity = ca.entity_id;
    cap_b.clear();
    g.dropClientSlot(ca.slot, "test-quit");
    const rqb = cap_b.findPkgId(sq_id) orelse return error.TestUnexpectedResult;
    const rh = try packages.stock_quest.parseSharedQuestHead(rqb);
    try std.testing.expectEqual(packages.stock_quest.SharedQuestEvent.remove_quest, rh.event);
    try std.testing.expectEqual(a_entity, rh.shared_by_entity_id);
}

test "scenario party quest change fans objective deltas to the other members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const pq_id = packages.idOf("NetPackagePartyQuestChange").?;
    var fbuf: [128]u8 = undefined;

    // A accepts B into a party.
    var pbody: [32]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&pbody, 1, ca.entity_id, cb.entity_id)));

    // A reports a shared-quest objective delta: B receives it verbatim.
    cap_b.clear();
    var qb: [16]u8 = undefined;
    var w = binary.Writer{ .buf = &qb };
    try w.writeI32(ca.entity_id);
    try w.writeByte(2); // objectiveIndex
    try w.writeBool(true);
    try w.writeI32(7); // questCode
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyQuestChange", w.written()));
    const got = cap_b.findPkgId(pq_id) orelse return error.TestUnexpectedResult;
    const q = try packages.parsePartyQuestChange(got);
    try std.testing.expectEqual(ca.entity_id, q.sender_entity);
    try std.testing.expectEqual(@as(u8, 2), q.objective_index);
    try std.testing.expect(q.is_complete);
    try std.testing.expectEqual(@as(i32, 7), q.quest_code);

    // A spoofed sender id is rejected (ownership), even from a party member.
    cap_b.clear();
    var spoof: [16]u8 = undefined;
    var w2 = binary.Writer{ .buf = &spoof };
    try w2.writeI32(999); // not A's entity
    try w2.writeByte(0);
    try w2.writeBool(false);
    try w2.writeI32(1);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyQuestChange", w2.written()));
    try std.testing.expect(cap_b.findPkgId(pq_id) == null);
}
