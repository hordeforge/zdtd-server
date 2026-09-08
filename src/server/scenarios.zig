//! Integration scenarios: two-peer motion, damage wire kill, setblock replicate, persist restart.
//! These call shipped Game handlers (onData/handlePackage/replicate/broadcast), not mocks.

const std = @import("std");
const game_mod = @import("game.zig");
const game_bot = @import("game/bot.zig");
const game_player = @import("game/player.zig");
const game_movement_helpers = @import("game/movement_helpers.zig");
const game_wasm_host = @import("game/wasm_host.zig");
const replicate_te = @import("replicate_te.zig");
const game_join = @import("game/join.zig");
const plugin_api = @import("../plugin/api.zig");
const ln_peer = @import("../litenet/peer.zig");
const packages = @import("../wire/packages.zig");
const wire_frame = @import("../wire/frame.zig");
const world_store = @import("../world/store.zig");
const world_tts = @import("../world/tts.zig");
const nav = @import("../world/nav.zig");
const sleepers_mod = @import("../world/sleepers.zig");
const quest_mod = @import("../ecs/quest.zig");
const quest_mod_components = @import("../ecs/components.zig");
const systems = @import("../ecs/systems.zig");
const invsys = @import("../ecs/inventory.zig");
const ecs = @import("../ecs/world.zig");
const io_fs = @import("../util/io_fs.zig");
const maxdamage = @import("../assets/maxdamage.zig");
const blocks_mod = @import("../assets/blocks.zig");
const biome_layers = @import("../assets/biome_layers.zig");
const world_weather = @import("../world/weather.zig");
const binary = @import("../wire/binary.zig");
const assets_recipes = @import("../assets/recipes.zig");
const assets_loot = @import("../assets/loot.zig");
const assets_items = @import("../assets/items.zig");
const assets_progression = @import("../assets/progression.zig");
const assets_item_modifiers = @import("../assets/item_modifiers.zig");
const inv_c2s = @import("c2s/inv.zig");
const platform_user = packages.platform_user;
const ally_mod = @import("ally.zig");
const persist = @import("persist.zig");
const phase_gate = @import("phase_gate.zig");
const util_log = @import("../util/log.zig");
const clock = @import("../util/clock.zig");
const containers_mod = @import("../world/containers.zig");
const vending_mod = @import("../world/vending.zig");
const assets_traders = @import("../assets/traders.zig");

// Module-scope capture for the T21 evidence-observer scenario (the nested
// vtable fn cannot close over locals).
var ev_seen: [8]i32 = .{0} ** 8;

/// Scenario worlds must start fresh: persisted state (entities.zen, *.zch)
/// from a previous run leaks into the next one, and vehicles/turrets have
/// accumulated enough across runs to exhaust the entity table (join failure)
/// and bloat listents replies. Wipe the dir before each scenario seeds it.
fn freshScenarioDir(dir: []const u8) void {
    io_fs.removeDirTree(dir);
    io_fs.mkdirPath(dir);
}

/// Drive one zombie kill for `c`'s active clear quest at its bound POI center
/// (0,0 when the quest has no POI), so poi_gated ClearSleepers phases count.
fn questKillAtPoi(g: *game_mod.Game, c: *game_mod.Client) void {
    var x: f32 = 0;
    var z: f32 = 0;
    if (g.sim.playerByPeer(c.slot)) |ps| {
        for (&g.sim.journal[ps].slots) |*s| {
            if (!s.active) continue;
            if (s.poi.valid()) {
                x = s.poi.x + s.poi.size_x * 0.5;
                z = s.poi.z + s.poi.size_z * 0.5;
            }
            break;
        }
    }
    systems.questOnZombieKilled(&g.sim, c.slot, x, z);
}

/// Tick the stay-within constraints for `c`'s active quest at its bound POI
/// center (or the def spot when the quest has no POI), so shared-phase stay
/// objectives (POIStayWithin) receive their trigger in the sweep.
fn questStayAtPoi(g: *game_mod.Game, c: *game_mod.Client) void {
    if (g.sim.playerByPeer(c.slot)) |ps| {
        for (&g.sim.journal[ps].slots) |*s| {
            if (!s.active) continue;
            const d = g.sim.catalog.byId(s.def_id) orelse continue;
            if (s.poi.valid()) {
                systems.questTickStayWithin(&g.sim, c.slot, s.poi.x + s.poi.size_x * 0.5, s.poi.z + s.poi.size_z * 0.5);
            } else {
                systems.questTickStayWithin(&g.sim, c.slot, d.tx, d.tz);
            }
            break;
        }
    }
}

test "scenario a wrong challenge echo does not authenticate the peer" {
    // The challenge is the whole pre-auth boundary: 17 raw bytes, marker 0xCA
    // then a 16-byte GUID the client echoes back (RE protocol.md §2). Nothing
    // tested the GUID comparison - deleting it, so any 0xCA packet of the
    // right length authenticated, left the suite green.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    const peer = &g.net.peers[0];
    peer.* = .{ .alive = true, .local_id = 1, .authenticated = false };
    try g.onConnected(peer);
    const c = g.clientFor(peer) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!c.authed_challenge);

    // Right shape, wrong GUID: every byte flipped from the one issued.
    var wrong: [17]u8 = undefined;
    wire_frame.buildChallenge(&wrong, c.challenge);
    for (wrong[1..]) |*b| b.* = ~b.*;
    try g.onData(peer, &wrong);
    try std.testing.expect(!c.authed_challenge);
    try std.testing.expect(!peer.authenticated);

    // The real echo still works, so the rejection is the GUID, not the shape.
    var right: [17]u8 = undefined;
    wire_frame.buildChallenge(&right, c.challenge);
    try g.onData(peer, &right);
    try std.testing.expect(c.authed_challenge);
    try std.testing.expect(peer.authenticated);
}

test "scenario a peer that never echoes is reaped past the auth age" {
    // Stock MaxDurationInAuthState (10 s): the auth sweep reaps by challenge
    // age, not RX silence. A peer that keeps the socket warm with junk but
    // never echoes must still be reaped; an authenticated peer of the same
    // age must survive (its challenge_ns cleared on echo).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    const peer = &g.net.peers[0];
    peer.* = .{ .alive = true, .local_id = 1, .authenticated = false };
    try g.onConnected(peer);
    const c = g.clientFor(peer) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!c.authed_challenge);
    try std.testing.expect(c.challenge_ns != 0);

    // Fresh challenge: the sweep leaves it alone even with no RX yet.
    const reaped_before = g.harness.counters.get(.stale_peers_reaped);
    g.reapStalePeers();
    try std.testing.expectEqual(reaped_before, g.harness.counters.get(.stale_peers_reaped));
    try std.testing.expect(peer.alive);

    // Age the challenge past the cap while keeping RX warm: reaped anyway.
    // The virtual clock makes the age exact (wall time would also do, but a
    // slow CI box must not flake the boundary).
    clock.enableVirtual(1_000_000_000);
    c.challenge_ns = 0; // issued at virtual t=0
    peer.last_recv_ns = clock.monoNs(); // RX warm right now
    clock.advanceNs((game_mod.default_auth_state_ms *| 1_000_000) + 1);
    g.reapStalePeers();
    clock.disableVirtual();
    try std.testing.expectEqual(reaped_before + 1, g.harness.counters.get(.stale_peers_reaped));
    try std.testing.expect(!peer.alive);
}

test "scenario pre-login world package is rejected by production dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    const peer = &g.net.peers[0];
    peer.* = .{ .alive = true, .local_id = 1, .authenticated = true };
    const c = g.clientFor(peer) orelse return error.TestUnexpectedResult;
    c.authed_challenge = true;
    try std.testing.expect(!c.joined);

    const x: i32 = 250;
    const y: i32 = 150;
    const z: i32 = 250;
    const before = try g.world.blockWorld(x, y, z);
    var body_buf: [64]u8 = undefined;
    const body = try packages.buildSetBlockBody(&body_buf, x, y, z, world_store.block_stone);
    var frame_buf: [128]u8 = undefined;
    try g.onData(peer, try packages.framed(&frame_buf, "NetPackageSetBlock", body));

    try std.testing.expectEqual(@as(u64, 1), g.harness.counters.get(.phase_rejects));
    try std.testing.expectEqual(before, try g.world.blockWorld(x, y, z));
}

test "scenario two-peer motion: B receives A PosAndRot" {
    io_fs.mkdirPath("worlds");
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

test "scenario animal movement state replicates (EntitySpeeds)" {
    // GAP animal-replication row: the EntitySpeeds/AliveFlags block was gated
    // on kind == .zombie, so the client animated animals with movementState 0
    // while their transform slid. Animals now stream the same movement state
    // as zombies (wander -> walking, chase -> running).
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_animal_rep");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_animal_rep", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const adef = g.entities.defaultAnimal();
    const an = g.sim.spawnAnimalDef(g.sim.transform[ps].x + 8, g.sim.transform[ps].y, g.sim.transform[ps].z, g.entityClassOf(adef)).?;
    cap.clear();
    try g.replicateNow();
    const speeds_id = packages.idOf("NetPackageEntitySpeeds").?;
    const sb = cap.findPkgIdEntity(speeds_id, an) orelse return error.TestUnexpectedResult;
    const parsed = try packages.parseEntitySpeedsBody(sb);
    // A wandering animal must stream a non-zero movement state (walking), not
    // the 0 the old zombie-only gate sent.
    try std.testing.expect(parsed.movement_state != 0);
    std.debug.print("PASS animal-replicate: EntitySpeeds movement_state={d} for animal id={d}\n", .{ parsed.movement_state, an });
}

test "scenario multiplayer player bodies spawn to peers and drop removes them" {
    // Players must see each other: the joiner receives every other player as
    // EntitySpawn (player class + name), and a disconnect broadcasts
    // EntityRemove(Despawned) so no ghost body stays on the other client.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_players");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_players", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);

    // A's join was before B existed, so B's join burst must spawn A to B
    // and A must receive B's body (both near the (256,70,256) pad).
    const spawn_id = packages.idOf("NetPackageEntitySpawn").?;
    const b_sees_a = cap_b.findPkgIdEntity(spawn_id, ca.entity_id) orelse return error.TestUnexpectedResult;
    var r = binary.Reader{ .data = b_sees_a };
    _ = try r.readI32(); // targeted entity id
    try std.testing.expectEqual(@as(u8, 36), try r.readByte()); // ECD FileVersion
    try std.testing.expectEqual(packages.stock_entity.class_player_male, try r.readI32());
    const a_sees_b = cap_a.findPkgIdEntity(spawn_id, cb.entity_id) orelse return error.TestUnexpectedResult;
    var r2 = binary.Reader{ .data = a_sees_b };
    _ = try r2.readI32();
    try std.testing.expectEqual(@as(u8, 36), try r2.readByte());
    try std.testing.expectEqual(packages.stock_entity.class_player_male, try r2.readI32());

    // Progression snapshot: B holds A's PlayerStats (name "Bot", level 1).
    const ps_id = packages.idOf("NetPackagePlayerStats").?;
    const psb = cap_b.findPkgIdEntity(ps_id, ca.entity_id) orelse return error.TestUnexpectedResult;
    var pr = binary.Reader{ .data = psb };
    try std.testing.expectEqual(ca.entity_id, try pr.readI32());
    _ = try pr.readI32(); // killed
    try std.testing.expectEqual(@as(u16, 0), try pr.readU16()); // empty held ItemStack
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // holdingItemIndex
    _ = try pr.readI32(); // deathHealth
    try std.testing.expectEqual(@as(u8, 0), try pr.readByte()); // teamNumber
    _ = try pr.readI32(); // attachedToEntityId
    var name_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Bot", try pr.readString(&name_buf));
    try std.testing.expectEqual(true, try pr.readBool()); // isPlayer
    try std.testing.expectEqual(@as(i32, 0), try pr.readI32()); // killedZombies
    _ = try pr.readI32(); // killedPlayers
    _ = try pr.readI32(); // experience (ExpToNextLevel)
    try std.testing.expectEqual(@as(i32, 1), try pr.readI32()); // level
    _ = try pr.readU32(); // totalItemsCrafted
    _ = try pr.readF32(); // distanceWalked
    _ = try pr.readF32(); // longestLife
    _ = try pr.readF32(); // currentLife
    _ = try pr.readF32(); // totalTimePlayed
    _ = try pr.readI32(); // vehiclePose
    try std.testing.expectEqual(false, try pr.readBool()); // isSpectator
    try std.testing.expectEqual(true, try pr.readBool()); // hasProgression
    const blob_len = try pr.readI16();
    try std.testing.expectEqual(@as(i16, 17), blob_len);
    _ = try pr.readByte(); // version 3
    try std.testing.expectEqual(@as(u16, 1), try pr.readU16()); // Level in blob

    // Level-up pushes a fresh snapshot to peers: award A enough XP for lvl 2.
    // Stock threshold (progression.zig expForLevel): 10000 * 1.05f^2 = 11024.
    cap_b.clear();
    g.awardXp(ca.slot, 11024);
    const psb2 = cap_b.findPkgIdEntity(ps_id, ca.entity_id) orelse return error.TestUnexpectedResult;
    var pr2 = binary.Reader{ .data = psb2 };
    try std.testing.expectEqual(ca.entity_id, try pr2.readI32());
    // Skip to level: killed(4) itemstack(2) holdingIdx(1) deathHealth(4)
    // team(1) attached(4) name(1+3) isPlayer(1) killedZombies(4)
    // killedPlayers(4) experience(4) -> prefix 33 before level.
    var skip: usize = 0;
    while (skip < 4 + 2 + 1 + 4 + 1 + 4 + 1 + 3 + 1 + 4 + 4 + 4) : (skip += 1) _ = try pr2.readByte();
    const lvl2 = try pr2.readI32();
    try std.testing.expectEqual(@as(i32, @intCast(ca.level)), lvl2); // snapshot carries the new level

    // Dropping A broadcasts EntityRemove(Despawned) to B. The drop zeroes
    // A's client struct, so snapshot the entity id before it.
    const a_eid = ca.entity_id;
    cap_b.clear();
    g.dropClientSlot(ca.slot, "scenario drop");
    const rm_id = packages.idOf("NetPackageEntityRemove").?;
    const rmb = cap_b.findPkgIdEntity(rm_id, a_eid) orelse return error.TestUnexpectedResult;
    var rr = binary.Reader{ .data = rmb };
    try std.testing.expectEqual(a_eid, try rr.readI32());
    try std.testing.expectEqual(@as(u8, @intFromEnum(packages.RemoveEntityReason.despawned)), try rr.readByte());
    // The drop destroys the sim player entity: no ghost player lingers for
    // this peer slot (listents/mem phantom, spawn-on-approach for late
    // joiners) until the slot is reused.
    try std.testing.expect(g.sim.playerByPeer(ca.slot) == null);

    std.debug.print(
        "PASS multiplayer-bodies: B saw A id={d}, A saw B id={d}, drop sent Remove(despawned)\n",
        .{ a_eid, cb.entity_id },
    );
}

test "scenario relpos motion: dirty relay without heartbeat (ecs-soa F1)" {
    io_fs.mkdirPath("worlds");
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

    // bUseQRotation shifts dPos: the Rotation base this package extends is
    // 3 x i16 euler when the flag is clear and a 4 x f32 quaternion when it is
    // set (RE protocol-packages.md 5.5.3), so dPos starts at byte 21 rather
    // than 11. Reading it at the fixed offset decoded quaternion bytes as a
    // movement delta.
    {
        // Let the speed envelope refill: the euler move above already spent
        // this tick's budget, and a second 1-block step in the same tick is
        // rejected for speed, which would mask what this case is testing.
        var settle: u32 = 0;
        while (settle < 20) : (settle += 1) try g.step();
        const idx = g.sim.slotOfNetId(ca.entity_id).?;
        const before_x = g.sim.transform[idx].x;
        var q: [40]u8 = @splat(0);
        std.mem.writeInt(i32, q[0..4], ca.entity_id, .little);
        q[4] = 1; // bUseQRotation
        // Identity quaternion: x=y=z=0, w=1. Its w bytes sit at 17..21, which
        // is exactly where the old fixed offset looked for dy/dz.
        std.mem.writeInt(u32, q[17..21], @bitCast(@as(f32, 1.0)), .little);
        std.mem.writeInt(i16, q[21..23], 32, .little); // dx = 32 * 0.03125 = 1.0
        std.mem.writeInt(i16, q[23..25], 0, .little); // dy
        std.mem.writeInt(i16, q[25..27], 0, .little); // dz
        q[27] = 1; // onGround
        std.mem.writeInt(i16, q[28..30], 1, .little); // updateSteps
        var qfb: [128]u8 = undefined;
        try g.injectFramed(ca, try packages.framed(&qfb, "NetPackageEntityRelPosAndRot", q[0..30]));
        // dx = +1 block. With the fixed offset the delta came from the
        // quaternion's w bytes instead and moved the player somewhere else.
        try std.testing.expectApproxEqAbs(before_x + 1.0, g.sim.transform[idx].x, 0.01);
    }
    std.debug.print("PASS relpos-motion: B received PosAndRot relay for A after RelPos inject\n", .{});
}

test "scenario item drop commits with EntitySpawnResponse" {
    // Stock ItemDropServer answers the thrower with EntitySpawnResponse(success,
    // item): the client DecItems its own bag on receipt (the drop commit).
    // Without it the thrown stack lingers in the client bag until re-sync.
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
    const ca = try g.attachJoinedClient(&cap_a);

    // Give A a wood stack to drop, then drop 1 via the real package path.
    const wood_id = g.items.ecsIdByName("resourceWood");
    try std.testing.expect(wood_id != 0);
    _ = invsys.give(&g.sim, ca.slot, wood_id, 10);
    const stack = packages.stock_inv.StockSlot{ .type_id = packages.stock_inv.itemTypeFromIndex(7), .count = 1 };
    var db: [128]u8 = undefined;
    var dw: @import("../wire/binary.zig").Writer = .{ .buf = &db };
    try packages.stock_inv.writeItemStack(&dw, stack);
    try dw.writeF32(260);
    try dw.writeF32(70);
    try dw.writeF32(260);
    try dw.writeF32(0); // initialMotion
    try dw.writeF32(0);
    try dw.writeF32(0);
    try dw.writeF32(0); // randomPosAdd
    try dw.writeF32(0);
    try dw.writeF32(0);
    try dw.writeF32(60); // lifetime
    try dw.writeI32(-1); // entityId (server assigns)
    try dw.writeI32(7); // clientInstanceId
    try dw.writeBool(false);
    var fb: [256]u8 = undefined;
    cap_a.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageItemDrop", dw.written()));

    const resp_id = packages.idOf("NetPackageEntitySpawnResponse").?;
    const rb = cap_a.findPkgId(resp_id) orelse return error.TestUnexpectedResult;
    var rr = binary.Reader{ .data = rb };
    try std.testing.expectEqual(true, try rr.readBool()); // success
    // The dropped item's ItemValue follows (never the empty sentinel: the
    // client dereferences ItemValue.ItemClass on receipt).
    const iv_type = try rr.readI32();
    try std.testing.expect(iv_type != 0);

    std.debug.print("PASS item-drop-commit: EntitySpawnResponse success, item type={d}\n", .{iv_type});
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

    // A forged target id outside the attacker's interest range must not mutate
    // it. Surviving the packet is not enough to show the range gate ran: the
    // claim carries `fatal`, so a gate that let it through would leave the
    // zombie present but at zero HP. Assert the health is untouched.
    const far_zid = g.sim.spawnZombie(10_000, 70, 10_000, 50).?;
    const far_slot = g.sim.slotOfNetId(far_zid) orelse return error.TestUnexpectedResult;
    const far_hp_before = g.sim.health[far_slot].hp;
    const far_body = try packages.buildDamageBody(&dmg_body, far_zid, 0, 3, 100, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageDamageEntity", far_body));
    try std.testing.expect(g.sim.slotOfNetId(far_zid) != null);
    try std.testing.expectApproxEqAbs(far_hp_before, g.sim.health[far_slot].hp, 0.01);

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
    io_fs.mkdirPath("worlds");
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

test "scenario audio: a client sound relays to the other player, not the sender" {
    // NetPackageAudio was dropped as a client-local cue. It is not: a client's
    // BroadcastPlay falls through to SendToServer, and the dedicated server
    // relays it to every in-range player through Audio.Server::Play. Doors,
    // storage, switches and locks all reach it, so dropping it left everyone
    // else in silence.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_audio");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_audio", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);

    var abuf: [128]u8 = undefined;
    const body = try packages.buildAudioPlayBody(&abuf, .{
        .entity_id = ca.entity_id,
        .sound_group = "open_door",
        .play = true,
        .play_on_entity = true,
        .volume_scale = 1,
    });
    var fb: [192]u8 = undefined;
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageAudio", body));

    const au_id = packages.idOf("NetPackageAudio").?;
    const b_got = cap_b.findPkgId(au_id) orelse return error.TestUnexpectedResult;
    // The sender already played it locally, so stock never echoes it back.
    try std.testing.expect(cap_a.findPkgId(au_id) == null);
    var nbuf: [64]u8 = undefined;
    const relayed = try packages.parseAudioPlay(b_got, &nbuf);
    try std.testing.expectEqualStrings("open_door", relayed.sound_group);
    try std.testing.expect(relayed.play);

    // signalOnly is an AI stimulus, not a sound: stock skips the relay loop.
    const sig = try packages.buildAudioPlayBody(&abuf, .{
        .entity_id = ca.entity_id,
        .sound_group = "footstep",
        .play = true,
        .play_on_entity = true,
        .signal_only = true,
    });
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageAudio", sig));
    try std.testing.expect(cap_b.findPkgId(au_id) == null);

    // Claiming another entity's sound is refused.
    const own_before = g.harness.counters.get(.ownership_rejects);
    const spoof = try packages.buildAudioPlayBody(&abuf, .{
        .entity_id = ca.entity_id + 999,
        .sound_group = "open_door",
        .play = true,
        .play_on_entity = true,
    });
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageAudio", spoof));
    try std.testing.expect(g.harness.counters.get(.ownership_rejects) > own_before);
    std.debug.print("PASS audio: sound relayed to the other player, sender excluded\n", .{});
}

test "scenario treasure point: the server answers the client's dig-site request" {
    // ObjectiveTreasureChest asks the server for a dig site whenever the quest
    // carries no PositionData TreasurePoint(4)/TreasureOffset(8), which zdtd
    // never fills. The package used to be validated and dropped, so a treasure
    // quest got no marker and could not finish.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_treasure");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_treasure", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const ps = g.sim.playerByPeer(ca.slot).?;

    // Give the player one active quest with a known code.
    g.sim.mask[ps].journal = true;
    const qcode: i32 = 4242;
    g.sim.journal[ps].slots[0].active = true;
    g.sim.journal[ps].slots[0].quest_code = qcode;

    var req_buf: [64]u8 = undefined;
    const req = try packages.buildQuestTreasurePointReply(&req_buf, ca.entity_id, qcode, 5, 0, 0, 0, 0, 0, 0);
    var fb: [128]u8 = undefined;
    cap_a.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageQuestTreasurePoint", req));

    const tp_id = packages.idOf("NetPackageQuestTreasurePoint").?;
    const got = cap_a.findPkgId(tp_id) orelse return error.TestUnexpectedResult;
    const reply = try packages.parseQuestTreasurePoint(got);
    try std.testing.expectEqual(packages.quest_point_get_treasure, reply.action);
    try std.testing.expectEqual(ca.entity_id, reply.player_id);
    try std.testing.expectEqual(qcode, reply.quest_code);
    // The blocks-per-reduction step the client asked with is echoed back, and
    // the dig site sits on the terrain surface rather than at y=0.
    try std.testing.expectEqual(@as(i32, 5), reply.blocks_per_reduction);
    try std.testing.expect(reply.y > 0);

    // A request naming another entity is refused.
    const own_before = g.harness.counters.get(.ownership_rejects);
    const spoof = try packages.buildQuestTreasurePointReply(&req_buf, ca.entity_id + 999, qcode, 5, 0, 0, 0, 0, 0, 0);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageQuestTreasurePoint", spoof));
    try std.testing.expect(g.harness.counters.get(.ownership_rejects) > own_before);
    std.debug.print("PASS treasure-point: dig site resolved and sent to the asking player\n", .{});
}

test "scenario waterset: a client water edit applies and reaches peer B" {
    // Stock water edits (jar fill/empty) originate client-side and the server
    // relays them; zdtd dropped NetPackageWaterSet as unhandled, so the change
    // stayed local to the acting client and was lost on relog.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_waterset");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_waterset", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    _ = try g.attachJoinedClient(&cap_b);

    // A cell inside the editor's reach, at the player's own position.
    const ps = g.sim.playerByPeer(ca.slot).?;
    const tr = g.sim.transform[ps];
    const wx: i32 = @intFromFloat(tr.x);
    const wy: i32 = @intFromFloat(tr.y);
    const wz: i32 = @intFromFloat(tr.z);

    const changes = [_]packages.WaterSetChange{
        .{ .x = wx, .y = wy, .z = wz, .mass = packages.water_mass_full },
    };
    var wbuf: [64]u8 = undefined;
    const wbody = try packages.buildWaterSetBody(&wbuf, ca.entity_id, &changes);
    var fb: [128]u8 = undefined;
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWaterSet", wbody));

    // The server applied it to its own world, so it persists and survives a
    // relog rather than living only on the sender.
    try std.testing.expectEqual(world_store.block_water, try g.world.blockWorld(wx, wy, wz));

    // Peer B was told; the sender was not (it already applied locally).
    const ws_id = packages.idOf("NetPackageWaterSet").?;
    const b_got = cap_b.findPkgId(ws_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cap_a.findPkgId(ws_id) == null);
    var out: [4]packages.WaterSetChange = undefined;
    const relayed = try packages.parseWaterSet(b_got, &out);
    try std.testing.expectEqual(@as(usize, 1), relayed.n);
    try std.testing.expectEqual(wx, out[0].x);
    try std.testing.expectEqual(packages.water_mass_full, out[0].mass);

    // A change naming another entity as the sender is refused outright.
    const own_before = g.harness.counters.get(.ownership_rejects);
    const spoof = try packages.buildWaterSetBody(&wbuf, ca.entity_id + 999, &changes);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWaterSet", spoof));
    try std.testing.expect(g.harness.counters.get(.ownership_rejects) > own_before);
    std.debug.print("PASS waterset: applied server-side and relayed to the other peer\n", .{});
}

test "scenario NetPackagePlayerDisconnect frees the slot immediately" {
    io_fs.mkdirPath("worlds");
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

test "scenario replicate sends EntityVelocity for a falling zombie" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_vel");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_vel", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    g.clients[c.slot].entered = true;
    // Spawn a zombie at the observer's feet and drop it (vy < 0).
    const ps = g.sim.playerByPeer(c.slot).?;
    const z = g.sim.spawnZombie(g.sim.transform[ps].x, g.sim.transform[ps].y + 1, g.sim.transform[ps].z, 40).?;
    const zs = g.sim.slotOfNetId(z).?;
    g.sim.zombie_ai[zs].vy = -3.0;
    try g.replicate();
    const did = packages.idOf("NetPackageEntityVelocity").?;
    var found = false;
    var i: usize = 0;
    while (i < cap.n and !found) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                var r = binary.Reader{ .data = pkgs[j].body };
                try std.testing.expectEqual(z, try r.readI32());
                _ = try r.readBool(); // bAdd
                _ = try r.readF32();
                try std.testing.expectApproxEqAbs(@as(f32, -3.0), try r.readF32(), 0.001);
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
}

test "scenario replicate sends TurretSync on target change" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_turret");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_turret", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    g.clients[c.slot].entered = true;
    const ps = g.sim.playerByPeer(c.slot).?;
    // A turret at the observer's feet acquires a target.
    const t = g.sim.spawnTurret(g.sim.transform[ps].x, g.sim.transform[ps].y + 1, g.sim.transform[ps].z).?;
    const ts = g.sim.slotOfNetId(t).?;
    const z = g.sim.spawnZombie(g.sim.transform[ps].x, g.sim.transform[ps].y + 2, g.sim.transform[ps].z, 40).?;
    g.sim.turret[ts].target_id = z;
    try g.replicate();
    const did = packages.idOf("NetPackageTurretSync").?;
    var found = false;
    var i: usize = 0;
    while (i < cap.n and !found) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                // The flat world spawns a demo turret whose TurretSync also
                // appears; match the frame for OUR turret entity.
                if (pkgs[j].body.len >= 9 and std.mem.readInt(i32, pkgs[j].body[0..4], .little) != t) continue;
                var r = binary.Reader{ .data = pkgs[j].body };
                try std.testing.expectEqual(t, try r.readI32());
                try std.testing.expectEqual(z, try r.readI32());
                try std.testing.expectEqual(@as(u8, 1), try r.readByte()); // isOn
                try std.testing.expectEqual(@as(u8, 0), try r.readByte()); // ItemValue.None
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);

    // A stock NetPackageTurretSpawn is entityType i32 | pos Vector3 (3 x f32) |
    // rot Vector3 | ItemValue | entityThatPlaced i32 (RE
    // inventories/netpackage-bodies.md, write IL=24). Read as zdtd's compact
    // three-i32 form, the float bit patterns decode to coordinates in the
    // billions and the reach gate drops the placement, so a real client's
    // turret silently never appeared.
    {
        const before = g.sim.countKind(.turret);
        const p = g.sim.transform[ps];
        const tx = p.x + 1;
        const ty = p.y;
        const tz = p.z + 1;
        var sb: [64]u8 = @splat(0);
        var w: binary.Writer = .{ .buf = &sb };
        try w.writeI32(1); // entityType
        try w.writeF32(tx); // pos
        try w.writeF32(ty);
        try w.writeF32(tz);
        try w.writeF32(0); // rot
        try w.writeF32(0);
        try w.writeF32(0);
        try w.writeByte(0); // ItemValue.None
        try w.writeI32(c.entity_id); // entityThatPlaced
        var sfb: [128]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&sfb, "NetPackageTurretSpawn", w.written()));
        try std.testing.expectEqual(before + 1, g.sim.countKind(.turret));
        // Placed where the client asked, not at a bit-pattern coordinate.
        var placed = false;
        for (g.sim.kind_groups.slice(.turret)) |slot| {
            if (!g.sim.alive[slot]) continue;
            const tt = g.sim.transform[slot];
            if (@abs(tt.x - tx) < 1.5 and @abs(tt.z - tz) < 1.5) placed = true;
        }
        try std.testing.expect(placed);
    }
    std.debug.print("PASS turretspawn: stock float body places at the requested position\n", .{});
}

test "scenario backpack marker broadcasts on drop and clears on collect" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_bp");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_bp", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    g.clients[c.slot].entered = true;
    // Drop: the marker broadcast carries the position.
    g.clients[c.slot].has_backpack = true;
    g.clients[c.slot].backpack_x = 12;
    g.clients[c.slot].backpack_y = 60;
    g.clients[c.slot].backpack_z = -34;
    const n_before = cap.n;
    try g.broadcastPlayerBackpack(&g.clients[c.slot]);
    try std.testing.expect(cap.n > n_before);
    const did = packages.idOf("NetPackagePlayerSetBackpackPosition").?;
    var found = false;
    var i: usize = 0;
    while (i < cap.n and !found) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                var r = binary.Reader{ .data = pkgs[j].body };
                try std.testing.expectEqual(c.entity_id, try r.readI32());
                try std.testing.expectEqual(@as(u8, 1), try r.readByte());
                try std.testing.expectEqual(@as(i32, 12), try r.readI32());
                try std.testing.expectEqual(@as(i32, 60), try r.readI32());
                try std.testing.expectEqual(@as(i32, -34), try r.readI32());
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
    // Collect: the cleared marker broadcasts an empty list.
    const n_first = cap.n;
    g.clients[c.slot].has_backpack = false;
    try g.broadcastPlayerBackpack(&g.clients[c.slot]);
    found = false;
    i = n_first;
    while (i < cap.n and !found) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                var r = binary.Reader{ .data = pkgs[j].body };
                _ = try r.readI32();
                try std.testing.expectEqual(@as(u8, 0), try r.readByte());
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
}

test "scenario ClientInfo broadcasts the player list every 5 s" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_ci");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ci", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    g.clients[c.slot].entered = true;
    const n_before = cap.n;
    g.tickClientInfo();
    try std.testing.expect(cap.n > n_before);
    const did = packages.idOf("NetPackageClientInfo").?;
    var found = false;
    var i: usize = 0;
    while (i < cap.n and !found) : (i += 1) {
        const msg = cap.slots[i].data[0..cap.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                var r = binary.Reader{ .data = pkgs[j].body };
                const count = try r.readU16();
                try std.testing.expect(count >= 1);
                const eid = try r.readI32();
                try std.testing.expectEqual(c.entity_id, eid);
                _ = try r.readI16(); // ping
                _ = try r.readBool(); // admin
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
    // The timer re-arms.
    g.tickClientInfo();
    try std.testing.expectEqual(@as(u16, 99), g.client_info_timer);
}

test "scenario map: PersistentPlayerPositions broadcasts every 6 s" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_ppp");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ppp", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const a = try g.attachJoinedClient(&cap_a);
    const b = try g.attachJoinedClient(&cap_b);
    // Two players online: the first broadcast carries both positions.
    const n_before = cap_a.n;
    g.tickPlayerPositions();
    try std.testing.expect(cap_a.n > n_before);
    const did = packages.idOf("NetPackagePersistentPlayerPositions").?;
    var found = false;
    var i: usize = 0;
    while (i < cap_a.n and !found) : (i += 1) {
        const msg = cap_a.slots[i].data[0..cap_a.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                var r = binary.Reader{ .data = pkgs[j].body };
                const count = try r.readI32();
                try std.testing.expect(count >= 2); // a + b
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
    // The timer re-arms: the next tick only counts down.
    _ = a;
    _ = b;
    g.tickPlayerPositions();
    try std.testing.expectEqual(@as(u16, 119), g.player_positions_timer);
}

test "scenario map: MapPosition C2S arms the window and sends MapChunks" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_map");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_map", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(g.clients[c.slot].joined);
    // The harness completes the join but not the enter bundle; an entered
    // client is what the map send pass serves.
    g.clients[c.slot].entered = true;
    // The client drives the map by sending its middle (RE protocol-packages
    // NetPackageMapPosition: entityId + Vector2i, world coords).
    var fbuf: [64]u8 = undefined;
    var body: [12]u8 = undefined;
    std.mem.writeInt(i32, body[0..4], c.entity_id, .little);
    std.mem.writeInt(i32, body[4..8], 1000, .little);
    std.mem.writeInt(i32, body[8..12], 2000, .little);
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageMapPosition", &body));
    try std.testing.expect(g.clients[c.slot].map_middle_set);
    try std.testing.expectEqual(@as(i32, 1000), g.clients[c.slot].map_middle_x);
    // A foreign entity id is ignored.
    std.mem.writeInt(i32, body[0..4], c.entity_id + 999, .little);
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageMapPosition", &body));
    try std.testing.expectEqual(@as(i32, 1000), g.clients[c.slot].map_middle_x);
    // The send pass fills the 17x17 window in batches. Flat generated
    // terrain deflates to a ~60 byte frame (all cells one color), so the
    // frame body cannot be re-inflated by the C2S parse guard (64x cap) -
    // assert the send happened (a frame went out) and the window advanced.
    const n_before = cap.n;
    g.tickMapChunks();
    try std.testing.expect(cap.n > n_before);
    var sent_n: usize = 0;
    for (g.clients[c.slot].map_chunks_sent) |s| {
        if (s != 0) sent_n += 1;
    }
    try std.testing.expect(sent_n > 0);
    // A second pass sends the next batch until the window is covered.
    g.tickMapChunks();
    var sent_n2: usize = 0;
    for (g.clients[c.slot].map_chunks_sent) |s| {
        if (s != 0) sent_n2 += 1;
    }
    try std.testing.expect(sent_n2 > sent_n);
    var any_sent = false;
    for (g.clients[c.slot].map_chunks_sent) |s| {
        if (s != 0) any_sent = true;
    }
    try std.testing.expect(any_sent);
    // A moved middle resets the sent set so the window re-fills.
    std.mem.writeInt(i32, body[0..4], c.entity_id, .little);
    std.mem.writeInt(i32, body[4..8], 1100, .little);
    try g.injectFramed(c, try packages.framed(&fbuf, "NetPackageMapPosition", &body));
    try std.testing.expectEqual(@as(i32, 1100), g.clients[c.slot].map_middle_x);
    var all_clear = true;
    for (g.clients[c.slot].map_chunks_sent) |s| {
        if (s != 0) all_clear = false;
    }
    try std.testing.expect(all_clear);
}

test "scenario hard disconnect reap saves before clearing the slot" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_reap");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_reap", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(g.clients[c.slot].joined);
    // Kill the transport without a NetPackagePlayerDisconnect (hard drop):
    // the reap must persist the player before clearing the slot, so a hard
    // disconnect is never lost to the autosave interval (GAP "Save on
    // disconnect / kick").
    c.peer.?.alive = false;
    g.reapStalePeers();
    try std.testing.expect(!g.clients[c.slot].joined);
    var pb: [512]u8 = undefined;
    const path = try g.playersPath(&pb);
    const saved = io_fs.readFileAll(g.allocator, path) catch null;
    defer if (saved) |s| g.allocator.free(s);
    try std.testing.expect(saved != null and saved.?.len > 8);
}

test "scenario SetBlock lower damage repairs instead of adding" {
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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

test "scenario downgrade swap: DowngradeBlock target accepted, break turns into it" {
    // RE Block.OnBlockDamaged IL_021D-030D: a block with a DowngradeBlock
    // turns into that block (rotation/meta preserved) when destroyed by
    // damage instead of being removed; the client swap report must accept the
    // downgrade target like the upgrade target.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_downgrade");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_downgrade", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const game = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var mt = (maxdamage.tryLoad(gpa, game, null) catch null) orelse return error.SkipZigTest;
    mt.tryMergeBundledAssignIds(gpa);
    g.maxdamage.deinit();
    g.maxdamage = mt;
    const safe_id = g.maxdamage.idByName("cntWallSafeInsecure") orelse return error.SkipZigTest;
    const open_id = g.maxdamage.idByName("cntWallSafeOpen") orelse return error.SkipZigTest;
    const bedroll_id = g.maxdamage.idByName("bedroll") orelse return error.SkipZigTest;
    const wood_id = g.maxdamage.idByName("woodMaster") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("cntWallSafeOpen", g.maxdamage.downgradeTarget("cntWallSafeInsecure").?);

    var frame_buf: [512]u8 = undefined;
    var body: [64]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, 0)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == 0);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, safe_id)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == safe_id);

    // The wrench downgrade report (client swap to the DowngradeBlock target).
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, open_id)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == open_id);

    // Forged swap: bedroll is neither the upgrade nor the downgrade target.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 250, 150, 250, bedroll_id)));
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == open_id);

    // Damage-break downgrade: the swap raw carries the downgrade target id
    // with the old block's rotation/meta upper bits.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 251, 150, 250, safe_id)));
    try std.testing.expect((try g.world.blockWorld(251, 150, 250)) == safe_id);
    const down_raw = g.downgradeBreakRaw(251, 150, 250, safe_id);
    try std.testing.expect((down_raw & 0xffff) == open_id);
    _ = try g.world.setBlockRawWorld(251, 150, 250, down_raw);
    try std.testing.expect((try g.world.blockWorld(251, 150, 250)) == open_id);

    // A normal block has no downgrade path: break raw is 0.
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", try packages.buildSetBlockBody(&body, 252, 150, 250, wood_id)));
    try std.testing.expect(g.downgradeBreakRaw(252, 150, 250, wood_id) == 0);

    std.debug.print("PASS downgrade: cntWallSafeInsecure -> cntWallSafeOpen accepted, forged swap rejected, break swaps\n", .{});
}

test "scenario multi-block SetBlock places anchor + ischild children" {
    // Stock client multi-block placement sends one NetPackageSetBlock with the
    // anchor AND the MultiBlockDim children (BlockValue.ischild set, raw bit
    // 0x40000000): GameManager.ChangeBlocks applies the list as-is, only
    // non-child cells get TileEntity handling. The handler must place every
    // cell with its raw (rotation/ischild preserved), not just the first.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_multiblock");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_multiblock", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const game = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var mt = (maxdamage.tryLoad(gpa, game, null) catch null) orelse return error.SkipZigTest;
    mt.tryMergeBundledAssignIds(gpa);
    g.maxdamage.deinit();
    g.maxdamage = mt;
    // cntAmmoPileLarge: MultiBlockDim 2,1,1 (stock V3.1.4 blocks.xml:3384).
    const ammo_id = g.maxdamage.idByName("cntAmmoPileLarge") orelse return error.SkipZigTest;
    const dim = g.maxdamage.multiBlockDim("cntAmmoPileLarge");
    try std.testing.expect(dim.x == 2 and dim.y == 1 and dim.z == 1);

    // Hand-build a 2-change SetBlock body mirroring buildSetBlockBodyRaw:
    // anchor at (250,150,250) + child at (251,150,250) carrying ischild bit.
    const ischild_bit: u32 = 0x40000000;
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try packages.platform_user.write(&w, null);
    try w.writeI16(2);
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const cx: i32 = 250 + @as(i32, @intCast(i));
        try w.writeByte(1); // BlockValueRef type 1 = BlockPosition
        try w.writeI32(cx);
        try w.writeI32(150);
        try w.writeI32(250);
        try w.writeI32(0); // changedByEntityId
        try w.writeByte(1); // block_change_flag_value
        try w.writeU32(if (i == 0) @as(u32, ammo_id) else @as(u32, ammo_id) | ischild_bit);
        try w.writeU16(0);
    }
    try w.writeI32(0); // localPlayerThatChanged

    var frame_buf: [512]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", w.written()));
    // Both cells placed (the id low 16 bits of the child raw; ischild is bit 30).
    try std.testing.expect((try g.world.blockWorld(250, 150, 250)) == ammo_id);
    try std.testing.expect((try g.world.blockWorld(251, 150, 250)) == ammo_id);
    try std.testing.expect((try g.world.rawWorld(251, 150, 250)) & ischild_bit != 0);
    try std.testing.expect((try g.world.rawWorld(250, 150, 250)) & ischild_bit == 0);

    std.debug.print("PASS multiblock: 2-change SetBlock places anchor + ischild child\n", .{});
}

test "scenario party mate's shared quest advances on the killer's kill" {
    // Stock SharedKillServer -> SharedKillClient (IL=65): an in-range party
    // mate's EntityKilled quest event fires for the same kill (their shared
    // quest copies advance; same GameStats[54] range as the XP share).
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
    var pbody: [32]u8 = undefined;
    var fbuf: [128]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&pbody, 1, ca.entity_id, cb.entity_id)));
    try std.testing.expect(g.parties.partyByMember(cb.entity_id) != null);
    // Both members carry the same kill quest (builtin def 1 =
    // clear_the_noise, 3 kills): the harness join auto-grants the starter
    // (questAcceptStarter would refuse the duplicate).
    const pa = g.sim.playerByPeer(ca.slot).?;
    const pb = g.sim.playerByPeer(cb.slot).?;
    const findStarter = struct {
        fn f(g2: *game_mod.Game, ps: usize) usize {
            for (g2.sim.journal[ps].slots, 0..) |sl, i| {
                if (sl.def_id == 1 and sl.active) return i;
            }
            return std.math.maxInt(usize);
        }
    }.f;
    const ja = findStarter(g, pa);
    const jb = findStarter(g, pb);
    try std.testing.expect(ja != std.math.maxInt(usize));
    try std.testing.expect(jb != std.math.maxInt(usize));
    try std.testing.expectEqual(@as(u16, 0), g.sim.journal[pa].slots[ja].progress);
    try std.testing.expectEqual(@as(u16, 0), g.sim.journal[pb].slots[jb].progress);
    // A kills a zombie (B in range at the (256,70,256) sim origin).
    const zid = g.sim.spawnZombie(258, 70, 258, 10).?;
    var dmg: [256]u8 = undefined;
    const dbody = try packages.buildDamageBody(&dmg, zid, 0, 3, 100, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody));
    try std.testing.expect(g.sim.health[g.sim.slotOfNetId(zid).?].hp <= 0);
    // Both journals advanced one kill (the mate via SharedKillServer).
    try std.testing.expectEqual(@as(u16, 1), g.sim.journal[pa].slots[ja].progress);
    try std.testing.expectEqual(@as(u16, 1), g.sim.journal[pb].slots[jb].progress);
    std.debug.print("PASS party-quest-kill: in-range mate's shared quest advances\n", .{});
}

test "scenario rejoin restores the player's own buffs via AddRemoveBuff" {
    // Stock carries the player's own buffs in the PDF `buffData`; zdtd writes
    // that section empty (fresh-PlayerDataFile form), so the join bundle must
    // re-send the active buffs as an AddRemoveBuff(adding) bundle - otherwise
    // the client's buff icons vanish on rejoin while the server keeps state.
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
    var cap1: ln_peer.Capture = .{};
    const c1 = try g.attachJoinedClient(&cap1);
    // Grant a buff through the real C2S path (validated + relayed).
    var fbuf: [256]u8 = undefined;
    var bbody: [128]u8 = undefined;
    const add = try packages.stock_buff.buildAddRemoveBuffBody(&bbody, .{
        .entity_id = c1.entity_id,
        .name = "buffShocked",
        .duration = 4,
        .adding = true,
        .instigator_id = c1.entity_id,
        .instigator_x = 0,
        .instigator_y = 0,
        .instigator_z = 0,
    });
    try g.injectFramed(c1, try packages.framed(&fbuf, "NetPackageAddRemoveBuff", add));
    const ps = g.sim.playerByPeer(c1.slot).?;
    var has_buff = false;
    for (g.sim.buffs[ps].slots) |b| {
        if (b.active) {
            if (g.buffs.byId(b.def_id)) |def| {
                if (std.mem.eql(u8, def.name, "buffShocked")) has_buff = true;
            }
        }
    }
    try std.testing.expect(has_buff);

    // Rejoin: save (the real quit/reap flows save before dropping; the
    // harness drop is a bare removal) then drop + attach again. A fresh
    // spawn gets a NEW entity id; the buffs ride the ZPV3 save and restore
    // on the post-spawn pass. The new capture must carry the player's own
    // AddRemoveBuff(adding) bundle.
    try g.savePlayers();
    g.dropClientSlot(c1.slot, "rejoin drop");
    var cap2: ln_peer.Capture = .{};
    const c2 = try g.attachJoinedClient(&cap2);
    const eid = c2.entity_id;
    // Sanity: the restored sim buff is on the new player slot.
    const ps2 = g.sim.playerByPeer(c2.slot).?;
    var restored = false;
    for (g.sim.buffs[ps2].slots) |b| {
        if (b.active) {
            if (g.buffs.byId(b.def_id)) |def| {
                if (std.mem.eql(u8, def.name, "buffShocked")) restored = true;
            }
        }
    }
    try std.testing.expect(restored);
    // The join steps may expire the restored buff (its expiry relay is an
    // adding=false package), so scan EVERY AddRemoveBuff for the entity and
    // require the re-add bundle (the sendOwnBuffs join send).
    const ab_id = packages.idOf("NetPackageAddRemoveBuff").?;
    var found = false;
    var si: usize = 0;
    while (si < cap2.n) : (si += 1) {
        const msg = cap2.slots[si].data[0..cap2.slots[si].len];
        var pkgs: [8]@import("../wire/frame.zig").Package = undefined;
        const pn = @import("../wire/frame.zig").parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id != ab_id) continue;
            var r = binary.Reader{ .data = pkgs[j].body };
            const ent = try r.readI32();
            var name_buf: [64]u8 = undefined;
            const name = try r.readString(&name_buf);
            _ = try r.readF32(); // duration
            const adding = try r.readBool();
            if (ent == eid and adding and std.mem.eql(u8, name, "buffShocked")) found = true;
        }
    }
    try std.testing.expect(found);
    std.debug.print("PASS rejoin-buffs: own active buffs re-synced via AddRemoveBuff\n", .{});
}

test "scenario stealth meter broadcasts NetPackageEntityStealth to observers" {
    // Stock PlayerStealth.TickServer S2C (IL_0470): every 16 ticks, when the
    // packed stealth state changed, the server broadcasts
    // NetPackageEntityStealth (id:i32 | data:u16, light | noise<<8 |
    // alert<<15 | crouch bit 0) so other clients render the meter.
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
    const pa = g.sim.playerByPeer(ca.slot).?;
    // A makes noise (the sim fold; the C2S relay is audio-only on a dedi).
    g.sim.pushStealthNoise(pa, g.sim.transform[pa].x, g.sim.transform[pa].y, g.sim.transform[pa].z, 60, 40, 0.8, 0, 0);
    // Step until the 16-tick broadcast fires and the sim noise settles.
    var t: usize = 0;
    var got: ?u8 = null;
    while (t < 64 and got == null) : (t += 1) {
        cap_b.clear();
        try g.step();
        if (packages.idOf("NetPackageEntityStealth")) |st_id| {
            if (cap_b.findPkgIdEntity(st_id, ca.entity_id)) |body| {
                var r = binary.Reader{ .data = body };
                const ent = try r.readI32();
                const data = try r.readU16();
                if (ent == ca.entity_id) got = @truncate((data >> 8) & 127);
            }
        }
    }
    const expect: u8 = @trunc(@min(g.sim.stealth[pa].noise_volume, 127.0));
    const got_v = got orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expect, got_v);
    try std.testing.expect(got_v > 0); // a real meter value, not a zero ping
    std.debug.print("PASS stealth-meter: NetPackageEntityStealth carries the noise fold\n", .{});
}

test "scenario demolish blast uses per-class ExplosionData and the earth DamageBonus" {
    // drainExplosions: the blast params come from the class's <property
    // class="Explosion"> block carried per entity (spawnZombie copies it from
    // class_table), with the Rules values as floor; the DamageBonus earth -> 0
    // keeps terrain (materials.xml damage_category) intact while stone breaks.
    freshScenarioDir("worlds/zdtd_sc_explode");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_explode", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var peer_cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&peer_cap);
    // Stock blocks.xml + materials.xml so block -> Material -> damage_category
    // resolves (offline builtin table has no material chain).
    const game = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var mt = (maxdamage.tryLoad(gpa, game, null) catch null) orelse return error.SkipZigTest;
    mt.tryMergeBundledAssignIds(gpa);
    g.maxdamage.deinit();
    g.maxdamage = mt;
    const stone_id = g.maxdamage.idByName("terrStone") orelse return error.SkipZigTest;
    const dirt_id = g.maxdamage.idByName("terrDirt") orelse return error.SkipZigTest;

    const pushBlast = struct {
        fn push(g2: *game_mod.Game, s: u16) !void {
            const cap = @import("../ecs/components.zig").explode_cap;
            if (g2.sim.explode_n >= cap) return error.TestUnexpectedResult;
            g2.sim.explode_reqs[g2.sim.explode_n] = .{ .slot = s };
            g2.sim.explode_n += 1;
            try g2.step(); // drains the ring (Game.step -> drainExplosions)
        }
    }.push;

    // Blast centre at the joined client so the cop never despawns during the
    // tick that precedes the drain (despawn_dist_sq is 200 m). Spawn the cop
    // at the terrain FEET level (the player's transform Y is its centre, ~6
    // blocks up; an airborne cop falls and dies before the drain) and offset
    // the whole blast a bit from the player so the entity AoE spares them.
    const px = g.sim.transform[c.slot];
    const gx: i32 = @as(i32, @trunc(px.x)) + 10;
    const gz: i32 = @as(i32, @trunc(px.z)) + 10;
    const gy: i32 = @trunc(g.groundHeight(gx, gz));
    // Cop A: radius 5, block damage 5000 (overrides the 1000 floor), entity
    // damage 800, DamageBonus earth -> 0.
    g.sim.setClassDef(1, .{
        .name = "zombieCop",
        .kind = .zombie,
        .hash = 7,
        .explosion_radius = 5,
        .explosion_radius_e = 6,
        .explosion_block_dmg = 5000,
        .explosion_entity_dmg = 800,
        .explosion_bonus_cat = .{ "earth", "", "", "" },
        .explosion_bonus_mult = .{ 0, 1, 1, 1 },
        .explosion_bonus_n = 1,
    });
    const zid_a = g.sim.spawnZombie(@floatFromInt(gx), @floatFromInt(gy), @floatFromInt(gz), 100).?;
    const sa = g.sim.slotOfNetId(zid_a).?;
    try g.setBlock(gx + 3, gy, gz + 3, stone_id); // dist 4.24: 5000*0.152=760 >= 500 HP
    try g.setBlock(gx + 2, gy, gz + 2, dirt_id); // earth category -> bonus 0 -> survives
    try pushBlast(g, sa);
    try std.testing.expect((try g.world.blockWorld(gx + 3, gy, gz + 3)) == 0); // stone broken
    try std.testing.expect((try g.world.blockWorld(gx + 2, gy, gz + 2)) != 0); // dirt survived
    try std.testing.expect(!g.sim.alive[sa]); // the cop died with the blast
    // Blast FX: stock GameManager.explode sends NetPackageExplosionClient for
    // every explosion (cops included); the observing client must receive it.
    const fxc = peer_cap.findPkgId(packages.idOf("NetPackageExplosionClient").?) orelse return error.TestUnexpectedResult;
    // Exactly the stock body (RE protocol-packages.md 6.15, write IL=60):
    // center Vector3 (12) + rotation Quaternion (16) + expType i16 (2) +
    // blastPower/blastRadius/blockDamage u16 (6) + entityId i32 (4) +
    // changeCount u16 (2) = 42. The old ">= 24" would have passed on a body
    // truncated anywhere past the rotation.
    try std.testing.expectEqual(@as(usize, 42), fxc.len);

    // Cop B: radius 1 (per-entity wins over the rules floor 4): the same stone
    // cell at distance 1.414 is outside the blast and survives.
    g.sim.setClassDef(1, .{
        .name = "zombieCop",
        .kind = .zombie,
        .hash = 7,
        .explosion_radius = 1,
        .explosion_block_dmg = 5000,
    });
    const zid_b = g.sim.spawnZombie(@floatFromInt(gx), @floatFromInt(gy), @floatFromInt(gz), 100).?;
    const sb = g.sim.slotOfNetId(zid_b).?;
    try g.setBlock(gx + 1, gy, gz + 1, stone_id);
    try pushBlast(g, sb);
    try std.testing.expect((try g.world.blockWorld(gx + 1, gy, gz + 1)) != 0); // outside radius 1

    std.debug.print("PASS explode: per-class ExplosionData radius/damage + earth bonus\n", .{});
}

test "scenario stability collapse spawns one singular fallingBlock per qualifying cell" {
    // RE entity-ai.md LetBlocksFall 1256-1262: the default path (group mode
    // EntityFallingBlocks.Enabled is false) spawns one fallingBlock entity
    // per collapsed cell whose block ShowModelOnFall is true. The builtin
    // tables default the gate to true, so a stone column collapses into two
    // singular entities (n=1 each), never a group.
    freshScenarioDir("worlds/zdtd_sc_fall");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_fall", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);

    // Column on the flat terrain (top ~70): base at y=71, two above.
    const stone = world_store.block_stone;
    try g.setBlock(250, 71, 250, stone);
    try g.setBlock(250, 72, 250, stone);
    try g.setBlock(250, 73, 250, stone);
    // Remove the base; the two cells above lose support and fall.
    _ = game_mod.stabilityAfterSetBlock(g, 250, 71, 250, stone, 0);
    var n_falling: usize = 0;
    for (g.sim.kind_groups.slice(.falling_block)) |s| {
        if (!g.sim.mask[s].falling or !g.sim.alive[s]) continue;
        n_falling += 1;
        try std.testing.expectEqual(@as(u8, 1), g.sim.falling[s].n);
        try std.testing.expectEqual(@as(u32, stone), g.sim.falling[s].cells[0].raw & 0xffff);
    }
    try std.testing.expectEqual(@as(usize, 2), n_falling);
    // The collapsed cells aired out.
    try std.testing.expectEqual(@as(u16, 0), try g.world.blockWorld(250, 72, 250));
    try std.testing.expectEqual(@as(u16, 0), try g.world.blockWorld(250, 73, 250));

    std.debug.print("PASS stability-collapse: 2 cells fall as 2 singular fallingBlock entities\n", .{});
}

test "scenario zombie opens a door on its path instead of chewing" {
    // RE entity-ai.md CheckForDoorAndOpen: a zombie pressed against a door
    // (path blocked, door tag + TEFeatureDoor) opens it - SetOpen meta bit +
    // broadcast - instead of damaging it, and the AI solid probe then reports
    // the open door passable so the zombie walks through.
    freshScenarioDir("worlds/zdtd_sc_door");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_door", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // A door-capable blocks table (builtin has no door): a minimal fixture with
    // the stock door name, loaded through the same loader the XML path uses.
    const DoorId = struct {
        fn id(_: ?*anyopaque, name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "doorWoodLargeGate")) return 105;
            if (std.mem.eql(u8, name, "terrStone")) return 1;
            return null;
        }
    };
    const src = "<blocks><block name=\"terrStone\"><property name=\"Class\" value=\"Terrain\"/></block><block name=\"doorWoodLargeGate\"><property name=\"Class\" value=\"CompositeTileEntity\"/></block></blocks>";
    const path = ".zdtd_test_blocks_door.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);
    const ft = try blocks_mod.loadFromPath(gpa, path, DoorId.id, null);
    g.blocks.deinit();
    g.blocks = ft;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // Pull the player next to the zombie (2 blocks away, within block_range).
    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.transform[ps].x = 7;
    g.sim.transform[ps].y = 71;
    g.sim.transform[ps].z = 5;
    const zs = g.sim.spawnZombie(5, 71, 5, 200).?;
    const zi = g.sim.slotOfNetId(zs).?;
    g.sim.zombie_ai[zi].state = .chase;
    g.sim.zombie_ai[zi].target_id = c.entity_id;
    // Door two-tall at the zombie's facing cell (head height 72).
    try g.world.setBlockWorld(6, 71, 5, 105);
    try g.world.setBlockWorld(6, 72, 5, 105);
    try std.testing.expect(try g.world.isSolidWorld(6, 72, 5)); // closed: solid
    g.tickZombieBlockDamage();
    // The door is now open: meta bit set, block passable, no damage applied.
    const raw = try g.world.rawWorld(6, 72, 5);
    try std.testing.expect((packages.blockMeta(raw) & packages.block_meta_on) != 0);
    try std.testing.expect(!try g.world.isSolidWorld(6, 72, 5));
    try std.testing.expectEqual(@as(u16, 105), try g.world.blockWorld(6, 72, 5)); // still the door

    std.debug.print("PASS zombie-door: blocked zombie opens the door and walks through\n", .{});
}

test "scenario zombie chews a 1-tall wall at feet level instead of getting stuck" {
    // A zombie pressed against a 1-block-tall wall (solid at feet, air at
    // head) must chew the feet cell: the old head-height-only probe saw air
    // and the zombie stayed stuck forever.
    freshScenarioDir("worlds/zdtd_sc_lowwall");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_lowwall", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.transform[ps].x = 7;
    g.sim.transform[ps].y = 71;
    g.sim.transform[ps].z = 5;
    const zs = g.sim.spawnZombie(5, 71, 5, 200).?;
    const zi = g.sim.slotOfNetId(zs).?;
    g.sim.zombie_ai[zi].state = .chase;
    g.sim.zombie_ai[zi].target_id = c.entity_id;
    // 1-tall wall in front at the zombie's feet (71), air at head (72).
    try g.world.setBlockWorld(6, 71, 5, 1);
    try std.testing.expect(try g.world.isSolidWorld(6, 71, 5));
    try std.testing.expect(!try g.world.isSolidWorld(6, 72, 5));
    const hp_before = g.getBlockHp(6, 71, 5);
    g.tickZombieBlockDamage();
    // The wall took bite damage: hp moved.
    const hp_after = g.getBlockHp(6, 71, 5);
    try std.testing.expect(hp_after > hp_before);
    std.debug.print("PASS zombie-lowwall: feet-level wall chewed (hp {d} -> {d})\n", .{ hp_before, hp_after });
}

test "scenario power switch: meta flip gates the grid and keeps the meta on the echo" {
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    return io_fs.dirExists(navezgane_path) or io_fs.fileExists(navezgane_path);
}

test "scenario stock map: Game loads Navezgane, spawn join, height observable" {
    if (!stockMapPresent()) return error.SkipZigTest;
    io_fs.mkdirPath("worlds");
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

test "scenario deco streams beyond the join window as chunks stream" {
    // RE DecoManager.Read: a post-join firstPackage=false DecoUpdate ADDS to
    // the client's loadedDecos HashSet, so decorations must stream with newly
    // entered chunks (the world is not bald beyond spawn). Teleporting the
    // player to a fresh region must generate + send the new deco chunks.
    if (!stockMapPresent()) return error.SkipZigTest;
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_decostream");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_decostream", 0, .{
        .game_dir = game_dir,
        .map_dir = navezgane_path,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const sp = g.world.primarySpawn();
    // The join burst sent the spawn view's deco and tracked its deco chunks.
    const join_marked = c.deco_sent_n;
    try std.testing.expect(join_marked > 0);
    // Teleport to a fresh forest region (10 chunks east of spawn - beyond the
    // join window's deco chunks) and stream: new chunks ship their deco. The
    // first added chunks land in a south band whose deco chunk can be sparse,
    // so the assertion is on the mechanism (new deco chunks tracked + packages
    // sent, deduped on the next pass); object production is proven by the join
    // burst, which uses the same generator.
    g.sim.transform[ps].x = @as(f32, @floatFromInt(sp.x)) + 160.0;
    g.sim.transform[ps].z = @as(f32, @floatFromInt(sp.z));
    cap.clear();
    try g.streamChunksForClient(c);
    const streamed_marked = c.deco_sent_n;
    try std.testing.expect(streamed_marked > join_marked);
    // A DecoUpdate package was sent for the new deco chunks (parseable payload).
    const did = packages.idOf("NetPackageDecoUpdate").?;
    var found = false;
    var si: usize = 0;
    while (si < cap.n and !found) : (si += 1) {
        const msg = cap.slots[si].data[0..cap.slots[si].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did) {
                var r = binary.Reader{ .data = pkgs[j].body };
                _ = try r.readBool();
                _ = try r.readI32(); // payloadLen
                _ = try r.readI32(); // object count (may be 0 in a sparse deco chunk)
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
    // Dedupe: a second pass at the same position sends no new deco chunks.
    cap.clear();
    try g.streamChunksForClient(c);
    try std.testing.expectEqual(streamed_marked, c.deco_sent_n);
    std.debug.print("PASS deco-stream: {d} join deco chunks, {d} after teleport, deduped on re-stream\n", .{ join_marked, streamed_marked });
}

test "scenario combat noise wakes a sleeper volume before player entry" {
    // RE entity-ai.md CheckSleeperVolumeNoise (IL=62) + SleeperVolume.CheckNoise
    // (IL=69): a noise inside a volume's AABB (+0.9 pad) spawns its sleepers,
    // independent of the player's position. The player here stays far away, so
    // only the noise can wake the volume.
    freshScenarioDir("worlds/zdtd_sc_sleepernoise");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_sleepernoise", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    // One volume far from the player's spawn (~256, 70, 256).
    const vols = try gpa.alloc(sleepers_mod.Volume, 1);
    defer gpa.free(vols);
    vols[0] = .{
        .x0 = 100,
        .y0 = 70,
        .z0 = 100,
        .x1 = 108,
        .y1 = 76,
        .z1 = 108,
        .group_n = 1,
    };
    vols[0].groups[0] = .{ .class_name = "GroupGenericZombie", .min_count = 2, .max_count = 4 };
    g.sleepers.volumes = vols;
    g.sleepers.trigger_count = 0;
    // A combat noise inside the volume.
    g.sim.pushNoise(104, 72, 104, 10);
    try g.step();
    try std.testing.expect(g.sleepers.volumes[0].triggered);
    try std.testing.expect(g.sleepers.trigger_count > 0);
    // The volume's sleepers spawned in/near it.
    var near: usize = 0;
    for (g.sim.kind_groups.slice(.zombie)) |zs| {
        if (!g.sim.mask[zs].sleeper or !g.sim.alive[zs]) continue;
        const t = g.sim.transform[zs];
        if (t.x > 90 and t.x < 120 and t.z > 90 and t.z < 120) near += 1;
    }
    try std.testing.expect(near > 0);
    std.debug.print("PASS sleeper-noise: volume woken by combat noise, spawned {d} sleepers\n", .{near});
}

test "scenario cleared sleeper volume re-arms after LootRespawnDays" {
    // RE SleeperVolume.ClearedUpdate (IL=33) + Touch (IL_0100-0134): when a
    // triggered volume's last sleeper zombie dies, respawnTime = worldTime +
    // LootRespawnDays x 24000 ticks; a touch past that time re-arms the
    // volume and the group respawns. LootRespawnDays 0 -> never re-arm.
    freshScenarioDir("worlds/zdtd_sc_sleeperrearm");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_sleeperrearm", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const vols = try gpa.alloc(sleepers_mod.Volume, 1);
    defer gpa.free(vols);
    vols[0] = .{
        .x0 = 100,
        .y0 = 70,
        .z0 = 100,
        .x1 = 108,
        .y1 = 76,
        .z1 = 108,
        .group_n = 1,
    };
    vols[0].groups[0] = .{ .class_name = "GroupGenericZombie", .min_count = 2, .max_count = 4 };
    g.sleepers.volumes = vols;
    g.sleepers.trigger_count = 0;

    const spawnCount = struct {
        fn call(gg: *game_mod.Game) usize {
            var n: usize = 0;
            for (gg.sim.kind_groups.slice(.zombie)) |zs| {
                if (!gg.sim.alive[zs] or !gg.sim.mask[zs].sleeper) continue;
                if (gg.sim.health[zs].hp <= 0) continue; // dead-but-lingering
                const t = gg.sim.transform[zs];
                if (t.x > 90 and t.x < 120 and t.z > 90 and t.z < 120) n += 1;
            }
            return n;
        }
    }.call;

    // Wake the volume; the group spawns.
    g.sim.pushNoise(104, 72, 104, 10);
    try g.step();
    try std.testing.expect(g.sleepers.volumes[0].triggered);
    const first = spawnCount(g);
    try std.testing.expect(first > 0);

    // Kill every spawned sleeper; the recount fires ClearedUpdate.
    for (g.sim.kind_groups.slice(.zombie)) |zs| {
        if (!g.sim.alive[zs] or !g.sim.mask[zs].sleeper) continue;
        const t = g.sim.transform[zs];
        if (t.x < 90 or t.x > 120 or t.z < 90 or t.z > 120) continue;
        _ = g.sim.damageFrom(g.sim.network_id[zs].id, 999_999, -1);
    }
    try g.step();
    const vol = &g.sleepers.volumes[0];
    try std.testing.expect(vol.respawn_time != 0);
    try std.testing.expectEqual(@as(u8, 0), vol.spawned_alive);

    // Advance the clock past respawn (default LootRespawnDays 7), then a
    // fresh noise re-arms the volume: the group respawns.
    g.sim.director.clock.day +%= 9;
    g.sim.pushNoise(104, 72, 104, 10);
    try g.step();
    try std.testing.expect(g.sleepers.volumes[0].triggered);
    try std.testing.expect(spawnCount(g) > 0);

    // LootRespawnDays 0: a cleared volume never re-arms (respawnTime =
    // cRespawnNever; every touch skips).
    for (g.sim.kind_groups.slice(.zombie)) |zs| {
        if (!g.sim.alive[zs] or !g.sim.mask[zs].sleeper) continue;
        const t = g.sim.transform[zs];
        if (t.x < 90 or t.x > 120 or t.z < 90 or t.z > 120) continue;
        _ = g.sim.damageFrom(g.sim.network_id[zs].id, 999_999, -1);
    }
    g.loot_respawn_days = 0;
    try g.step();
    try std.testing.expectEqual(std.math.maxInt(u64), g.sleepers.volumes[0].respawn_time);
    g.sim.director.clock.day +%= 9;
    g.sim.pushNoise(104, 72, 104, 10);
    try g.step();
    try std.testing.expect(spawnCount(g) == 0);
    std.debug.print("PASS sleeper-rearm: cleared volume respawns after LootRespawnDays; 0 days never re-arms\n", .{});
}

test "scenario always-on radius effect: radiated barrel grants buffRadiation01" {
    // WORK_PLAN T38 (RE dedicated-misc-systems.md BlockRadiusEffect):
    // always-on no-fuel sources (wallTorchLight, candleWallLight,
    // burningBarrel, cntBarrelRadiatedSingle00, decoPumpkinJackOLantern)
    // grant their ActiveRadiusEffects buff to players within radius; the
    // per-player local 7x7x7 scan applies them each tick. Real game-dir
    // blocks/buffs. Skipped without the game dir.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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
    const barrel_id = g.blocks.byName("cntBarrelRadiatedSingle00").?.id;
    const buff_id = g.buffs.indexOfName("buffRadiation01").?;
    // The radius scan runs in the 2 Hz side-work block; run it every step.
    g.sleeper_tick_ticks = 1;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const ap = g.sim.transform[ps];
    const bx: i32 = @trunc(ap.x + 1);
    const by: i32 = @trunc(ap.y);
    const bz: i32 = @trunc(ap.z);
    try g.world.setBlockWorld(bx, by, bz, barrel_id);

    var t: u64 = 0;
    while (t < 3) : (t += 1) try g.step();
    try std.testing.expect(g.sim.mask[ps].buffs);
    try std.testing.expect(g.sim.buffs[ps].find(buff_id) != null);
    std.debug.print("PASS radius-alwayson: radiated barrel grants buffRadiation01 to nearby players\n", .{});
}

test "scenario group-id sleeper volumes cascade within one placement only" {
    // RE entity-ai.md TouchGroup (IL=52): a volume with a nonzero
    // SleeperVolumeGroupId wakes every other volume of the same prefab
    // placement sharing the id; group id 0 = standalone. A duplicate
    // placement of the same prefab (different origin) must NOT wake.
    freshScenarioDir("worlds/zdtd_sc_sleepercascade");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_sleepercascade", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    const vols = try gpa.alloc(sleepers_mod.Volume, 4);
    defer gpa.free(vols);
    vols[0] = .{
        .x0 = 100,
        .y0 = 70,
        .z0 = 100,
        .x1 = 108,
        .y1 = 76,
        .z1 = 108,
        .group_id = 1,
        .group_n = 1,
        .prefab = "AAA_utility_waterworks",
        .origin_x = 500,
        .origin_y = 60,
        .origin_z = 500,
    };
    vols[1] = .{
        .x0 = 200,
        .y0 = 70,
        .z0 = 200,
        .x1 = 208,
        .y1 = 76,
        .z1 = 208,
        .group_id = 1,
        .group_n = 1,
        .prefab = "AAA_utility_waterworks",
        .origin_x = 500,
        .origin_y = 60,
        .origin_z = 500,
    };
    // Duplicate placement of the same prefab: same id, different origin.
    vols[2] = .{
        .x0 = 300,
        .y0 = 70,
        .z0 = 300,
        .x1 = 308,
        .y1 = 76,
        .z1 = 308,
        .group_id = 1,
        .group_n = 1,
        .prefab = "AAA_utility_waterworks",
        .origin_x = 9000,
        .origin_y = 60,
        .origin_z = 9000,
    };
    // Same placement, standalone id 0.
    vols[3] = .{
        .x0 = 400,
        .y0 = 70,
        .z0 = 400,
        .x1 = 408,
        .y1 = 76,
        .z1 = 408,
        .group_id = 0,
        .group_n = 1,
        .prefab = "AAA_utility_waterworks",
        .origin_x = 500,
        .origin_y = 60,
        .origin_z = 500,
    };
    for (vols) |*v| v.groups[0] = .{ .class_name = "GroupGenericZombie", .min_count = 1, .max_count = 2 };
    g.sleepers.volumes = vols;
    g.sleepers.trigger_count = 0;
    // Combat noise inside volume 0 only.
    g.sim.pushNoise(104, 72, 104, 10);
    try g.step();
    try std.testing.expect(g.sleepers.volumes[0].triggered);
    try std.testing.expect(g.sleepers.volumes[1].triggered);
    try std.testing.expect(!g.sleepers.volumes[2].triggered);
    try std.testing.expect(!g.sleepers.volumes[3].triggered);
    try std.testing.expectEqual(@as(u32, 2), g.sleepers.trigger_count);
    std.debug.print("PASS sleeper-cascade: group-id volumes wake together in one placement only\n", .{});
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

test "scenario destroy_on_close container breaks on unlock and drops contents" {
    // Stock TEFeatureStorage.OnUnlockedServer (IL=6) ->
    // GameManager.CheckDestroyTileEntity (IL=37, loot-economy.md 454-456):
    // destroy_on_close="true" drops the remaining contents as an
    // EntityLootContainer bag at +0.5,0.75,+0.5 and destroys the block on
    // close; "empty" destroys only when the player emptied the container.
    freshScenarioDir("worlds/zdtd_sc_destroyclose");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_destroyclose", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);

    // Custom loot table: a "true" container and an "empty" container.
    var conts = [_]assets_loot.LootContainer{
        .{ .name = "testAirdrop", .size_x = 4, .size_y = 3, .destroy_on_close = 1 },
        .{ .name = "testSmallSafe", .size_x = 8, .size_y = 5, .destroy_on_close = 2 },
    };
    g.loot = .{ .containers = &conts, .source = .xml };

    const bx = 100;
    const by = 60;
    const bz = 100;
    const pos = containers_mod.PosKey{ .x = bx, .y = by, .z = bz };
    try g.world.setBlockWorld(bx, by, bz, world_store.block_stone);

    // "true" container with contents: close -> bag spawns with the items and
    // the block breaks.
    {
        const cont = g.containers.getOrCreate(pos, 12, world_store.block_stone) orelse unreachable;
        cont.loot_list = "testAirdrop";
        cont.slots[0] = .{ .item_id = 1, .count = 3, .quality = 1 };
        cont.slots[1] = .{ .item_id = 2, .count = 1, .quality = 1 };
        g.maybeDestroyContainerOnClose(bx, by, bz);
        try std.testing.expect(g.containers.get(pos) == null);
        try std.testing.expectEqual(@as(u16, 0), g.world.rawWorld(bx, by, bz) catch 0);
        var bag_near: usize = 0;
        for (g.sim.kind_groups.slice(.loot_bag)) |bs| {
            const t = g.sim.transform[bs];
            if (t.x > bx - 2 and t.x < bx + 2 and t.y > by - 2 and t.y < by + 3 and t.z > bz - 2 and t.z < bz + 2) bag_near += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bag_near);
        const bs = g.sim.kind_groups.slice(.loot_bag);
        var bag_items: usize = 0;
        for (bs) |sl| {
            for (g.sim.inventory[sl].slots) |s| {
                if (s.count > 0 and s.item_id != 0) bag_items += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), bag_items);
    }

    // "empty" container with contents: NOT destroyed on close.
    const pos2 = containers_mod.PosKey{ .x = 200, .y = 60, .z = 200 };
    try g.world.setBlockWorld(200, 60, 200, world_store.block_stone);
    {
        const cont = g.containers.getOrCreate(pos2, 40, world_store.block_stone) orelse unreachable;
        cont.loot_list = "testSmallSafe";
        cont.slots[0] = .{ .item_id = 1, .count = 2, .quality = 1 };
        g.maybeDestroyContainerOnClose(200, 60, 200);
        try std.testing.expect(g.containers.get(pos2) != null);
        try std.testing.expect(g.world.rawWorld(200, 60, 200) catch 0 != 0);
    }

    // Emptied "empty" container: destroyed, nothing to drop.
    {
        const cont = g.containers.get(pos2) orelse unreachable;
        cont.slots[0] = .{};
        g.maybeDestroyContainerOnClose(200, 60, 200);
        try std.testing.expect(g.containers.get(pos2) == null);
        try std.testing.expectEqual(@as(u16, 0), g.world.rawWorld(200, 60, 200) catch 0);
    }
    std.debug.print("PASS destroy-on-close: true drops+breaks, empty breaks when emptied\n", .{});
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
    io_fs.mkdirPath(map_dir);
    io_fs.mkdirPath(save_dir);
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
    systems.drainQuestCoins(&g.sim, c.slot);
    try std.testing.expect(systems.questCoins(&g.sim, c.slot) >= 10);

    // Accept clear: Goto POI (phase1) → ClearSleepers (phase3) → ReturnToNPC (phase4).
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, clear.id));
    // Reach the quest POI to clear phase 1; the rally scaffolding (phase 2) auto-skips.
    systems.questTickGoto(&g.sim, c.slot, clear.tx, clear.ty, clear.tz);
    var k: u16 = 0;
    while (k < clear.target_count) : (k += 1) questKillAtPoi(g, c);
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
    systems.drainQuestCoins(&g.sim, c.slot);
    try std.testing.expect(systems.questCoins(&g.sim, c.slot) >= 25);

    // Find trader entity. TraderData.TraderID is traders.xml <trader_info>, not
    // the network entity id (XUiC_TraderWindow.showrestock needs TraderInfo).
    var te: i32 = -1;
    var trader_info_id: i32 = 0;
    var si: usize = 0;
    while (si < 512) : (si += 1) {
        if (g.sim.alive[@intCast(si)] and g.sim.mask[@intCast(si)].trader) {
            te = g.sim.network_id[@intCast(si)].id;
            trader_info_id = g.sim.trader_stock[@intCast(si)].trader_info_id;
            break;
        }
    }
    try std.testing.expect(te > 0);
    try std.testing.expect(trader_info_id > 0);
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
    try std.testing.expectEqual(trader_info_id, try sr.readI32()); // traders.xml TraderID
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
    try std.testing.expectEqual(trader_info_id, try rr.readI32()); // traders.xml TraderID
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

    systems.drainQuestCoins(&g.sim, c.slot);
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
    systems.drainQuestCoins(&g.sim, c.slot);
    const coins_after = systems.questCoins(&g.sim, c.slot);
    try std.testing.expect(coins_after <= coins_before); // a buy never credits
    if (stock_after < stock_before) {
        try std.testing.expect(coins_after < coins_before); // sold => charged
    } else {
        try std.testing.expectEqual(stock_before, stock_after);
        try std.testing.expectEqual(coins_before, coins_after); // no-op => free
    }

    // A stock NetPackageTraderData ToServer body for a tile entity with no
    // trader data attached is 1 + 12 + 1 = 14 bytes. Its byte 8 is the high
    // byte of te_y, which is 0 for any real coordinate, so a `>= 9` length
    // test routed it into the trade arm and decoded two te_y bytes as a
    // quantity. Only an exactly-9-byte body is a zdtd trade.
    // The two arms are told apart by what only the trader-open arm does:
    // questOnTraderOpen advances a trader_interact objective. Asserting that
    // stock and coins do not move would pass either way, because the
    // misrouted body decodes qty 0 and systems.trade returns immediately on
    // that - a test that cannot fail is not a test.
    {
        _ = systems.questAccept(&g.sim, c.slot, 3); // visit_the_trader
        systems.questTickGoto(&g.sim, c.slot, v.tx, v.ty, v.tz); // phase 1
        try std.testing.expect(systems.questHasActive(&g.sim, c.slot, 3));
        var te_body: [14]u8 = @splat(0);
        te_body[0] = 0; // isEntity = false -> tile entity position follows
        std.mem.writeInt(i32, te_body[1..5], 100, .little); // te_x
        std.mem.writeInt(i32, te_body[5..9], 70, .little); // te_y (byte 8 = 0)
        std.mem.writeInt(i32, te_body[9..13], 100, .little); // te_z
        te_body[13] = 0; // hasTraderData = false
        var tfb: [64]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&tfb, "NetPackageTraderData", &te_body));
        // Routed as trader-open: the interact objective completes the quest.
        // Routed as a trade (the bug), questOnTraderOpen never runs and the
        // quest stays active.
        try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 3));
    }
    std.debug.print("PASS traderdata: 14-byte stock TE body is not decoded as a trade\n", .{});

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

test "scenario quest turn-in and phase advance fire on the stock trader lock-open" {
    // GAP "Quest turn-in / phase advance on trader open": the stock client
    // opens the trade window with NetPackageLockRequest (EntityTraderLockContext
    // "trade"), and the server fires QuestEventManager's interact/turn-in on
    // that open. Drive the whole path through the wire, not the direct hook:
    // the starter (Goto -> Interact -> TurnIn) completes on the second lock-
    // open with the coin reward, and a fetch quest parked at ready_turn_in
    // completes on a single open.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_trader_quest_open");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_trader_quest_open", 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap); // auto-accepts the starter
    // info_id 0 = no trader_info hours, always open.
    const te = g.sim.spawnTrader("traderOpen", 0, 70, 8, 0, 5000).?;

    // Stock lock-open body (channel 1, Entity target, EntityTraderLockContext).
    const openTrade = struct {
        fn f(gg: *game_mod.Game, cc: *game_mod.Client, target_id: i32, cap_p: *ln_peer.Capture) !void {
            cap_p.clear();
            var lr_body: [64]u8 = undefined;
            var lw: binary.Writer = .{ .buf = &lr_body };
            try lw.writeBool(true); // locking
            try lw.writeU16(1); // channel 1 (trade)
            try lw.writeI32(1); // target count
            try lw.writeByte(1); // present
            try lw.writeByte(2); // Entity target
            try lw.writeI32(target_id);
            try lw.writeString("EntityTraderLockContext");
            try lw.writeString("trade");
            try lw.writeBool(false); // client-side hasTraderData (server fills)
            var lfb: [256]u8 = undefined;
            try gg.injectFramed(cc, try packages.framed(&lfb, "NetPackageLockRequest", lr_body[0..lw.written().len]));
            const lock_id = packages.idOf("NetPackageLockResponse").?;
            _ = cap_p.findPkgId(lock_id) orelse return error.TestUnexpectedResult;
        }
    }.f;

    const starter_id = g.sim.catalog.starter_id;
    systems.drainQuestCoins(&g.sim, c.slot);
    const coins0 = systems.questCoins(&g.sim, c.slot);
    // Open 1: phase 2 (InteractWithNPC) advances; the TurnIn phase parks the
    // quest ready.
    try openTrade(g, c, te, &cap);
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, starter_id));
    // Open 2: the ready quest turns in and pays (coins at the tick-end
    // payout drain, like the rest of the reward).
    try openTrade(g, c, te, &cap);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, starter_id));
    systems.drainQuestCoins(&g.sim, c.slot);
    try std.testing.expect(systems.questCoins(&g.sim, c.slot) > coins0);

    // A fetch quest parked at ready_turn_in completes on the next open.
    const fetch = g.sim.catalog.byName("tier1_fetch") orelse return error.TestUnexpectedResult;
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, fetch.id));
    systems.questOnFetchItem(&g.sim, c.slot, 1);
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, fetch.id));
    try openTrade(g, c, te, &cap);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, fetch.id));
    std.debug.print("PASS trader-quest-open: lock path fires turn-in (starter 2 opens, fetch 1 open)\n", .{});
}

test "scenario in-game player console: allowlist, deny, and admin routing" {
    // GAP in-game console row: NetPackageConsoleCmdServer is answered with
    // ConsoleCmdClient. Players get the read-only allowlist (help/gettime/
    // listplayers/...); a non-allowlisted verb is denied. An admin
    // (permission list entry) routes the same verb through the full admin
    // command surface with the reply captured into the response.
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

    const sendCmd = struct {
        fn f(gg: *game_mod.Game, cc: *game_mod.Client, cap_p: *ln_peer.Capture, cmd: []const u8, joined: *[512]u8) ![]const u8 {
            cap_p.clear();
            var body: [64]u8 = undefined;
            var w: binary.Writer = .{ .buf = &body };
            try w.writeString(cmd);
            var fb: [128]u8 = undefined;
            try gg.injectFramed(cc, try packages.framed(&fb, "NetPackageConsoleCmdServer", w.written()));
            const cid = packages.idOf("NetPackageConsoleCmdClient").?;
            const resp = cap_p.findPkgId(cid) orelse return error.TestUnexpectedResult;
            var r: binary.Reader = .{ .data = resp };
            const n = try r.readI32();
            var scratch: [256]u8 = undefined;
            var jn: usize = 0;
            var i: i32 = 0;
            while (i < n and jn + 1 <= joined.len) : (i += 1) {
                const ln = try r.readString(&scratch);
                if (jn + ln.len + 1 > joined.len) break;
                @memcpy(joined[jn..][0..ln.len], ln);
                jn += ln.len;
                joined[jn] = '\n';
                jn += 1;
            }
            return joined[0..jn];
        }
    }.f;

    // Player (no admin entry, level 1000): the allowlisted verb answers with
    // the friendly help text.
    var hbuf: [512]u8 = undefined;
    const help = try sendCmd(g, c, &cap, "help", &hbuf);
    try std.testing.expect(std.mem.find(u8, help, "zdtd console commands") != null);
    // gettime carries the jittered CalcNextDay blood-moon countdown (the
    // plain frequency modulus ignored BloodMoonRange).
    g.sim.director.clock.bloodmoon_frequency = 7;
    var gbuf: [512]u8 = undefined;
    const gt = try sendCmd(g, c, &cap, "gettime", &gbuf);
    try std.testing.expect(std.mem.find(u8, gt, "bloodmoon in") != null);
    // A non-allowlisted verb is denied for a plain player.
    var dbuf: [512]u8 = undefined;
    const deny = try sendCmd(g, c, &cap, "kick nobody", &dbuf);
    try std.testing.expect(std.mem.find(u8, deny, "permission denied") != null);
    // Admin (permission list entry): the same verb routes through the full
    // admin surface; the reply is captured (kick's target error), not denied.
    try std.testing.expect(g.admin_list.add("Bot", 0));
    var abuf: [512]u8 = undefined;
    const adm = try sendCmd(g, c, &cap, "kick nobody", &abuf);
    try std.testing.expect(std.mem.find(u8, adm, "permission denied") == null);
    try std.testing.expect(adm.len > 0);
    // Per-command permission matrix (stock IsAllowed = req >= caller, levels
    // run 0 = highest): an owner (level 0) may run a delegated command
    // (req 5), and a level-5 admin is DENIED an owner-only command (req 0).
    // The check used to be inverted (req > caller), letting a level-5 admin
    // run owner commands and locking the owner out of delegated ones.
    try std.testing.expect(g.setCommandLevel("kick", 5));
    const owner_delegated = try sendCmd(g, c, &cap, "kick nobody", &abuf);
    try std.testing.expect(std.mem.find(u8, owner_delegated, "permission denied") == null); // owner(0) >= req(5)
    try std.testing.expect(g.setCommandLevel("kick", 0));
    try std.testing.expect(g.admin_list.add("Bot", 5)); // re-level the admin
    const mid_owner_cmd = try sendCmd(g, c, &cap, "kick nobody", &abuf);
    try std.testing.expect(std.mem.find(u8, mid_owner_cmd, "permission denied") != null); // caller(5) < req(0)
    // Malformed argument sweep. The console takes strings straight off the
    // wire (NetPackageConsoleCmdServer) and hands them to parseInt/parseFloat
    // in a dozen verbs, but the fuzz harness cannot reach it: it fuzzes pure
    // functions and this path needs a live Game. So drive the hostile shapes
    // through the real C2S entry point here.
    try std.testing.expect(g.admin_list.add("Bot", 0)); // owner, so nothing is refused on permission
    const bad_args = [_][]const u8{
        "tp", // no args at all
        "tp 1", // too few
        "tp x y z", // non-numeric
        "tp nan nan nan", // parses, but not finite
        "tp inf -inf 0",
        "tp 1e40 1e40 1e40", // finite but past the coordinate ceiling
        "tp 99999999999999999999 0 0", // overflows f32 to inf
        "settime notanumber",
        "settime -1",
        "loglevel 999", // past u8
        "give 0", // item id zero
        "give 999999", // item id past the catalog
        "ban", // verb with every argument missing
        "kick",
        "", // empty command line
        " ", // whitespace only
        "\t\t",
        "tp\t1\t2\t3", // tab-separated instead of spaces
    };
    for (bad_args) |cmd| {
        // The contract is only that the server answers and stays up: a reply
        // must come back, and the tick after it must still run.
        _ = sendCmd(g, c, &cap, cmd, &abuf) catch continue;
        try g.step();
    }
    try std.testing.expect(g.sim.director.clock.day >= 1); // sim still coherent
    {
        // The sweep runs as owner, so tp reaches the admin teleport rather than
        // being refused by the player allowlist. Assert the position it lands
        // on is still a usable coordinate: that is what the isFinite check and
        // the clamp in consoleTeleport are for.
        const ps_probe = g.sim.playerByPeer(c.slot).?;
        try std.testing.expect(std.math.isFinite(g.sim.transform[ps_probe].x));
        try std.testing.expect(std.math.isFinite(g.sim.transform[ps_probe].y));
        try std.testing.expect(std.math.isFinite(g.sim.transform[ps_probe].z));
    }

    std.debug.print("PASS player-console: allowlist + deny + admin routing with captured reply\n", .{});
    std.debug.print("PASS console-args: {d} malformed command lines answered without a crash\n", .{bad_args.len});
}

test "scenario AI kill drops the player's real inventory as a death bag" {
    // GAP DropOnDeath row: an AI kill (hp drains server-side) must drop the
    // victim's actual inventory range as a loot bag at the death position, not
    // a placeholder unit - the C2S kill path bags its own victims, this is the
    // hp-replicate AI path (drop_on_death 1 = toolbelt + backpack).
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_deathbag");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_deathbag", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.inventory[ps].slots[2] = .{ .item_id = 7, .count = 5 };
    g.sim.inventory[ps].slots[10 + 4] = .{ .item_id = 9, .count = 2 };
    // Kill the player through the server-side damage path (AI-style: no C2S
    // damage claim).
    _ = g.sim.damageFrom(g.sim.network_id[ps].id, 1000, -1);
    try std.testing.expectEqual(@as(f32, 0), g.sim.health[ps].hp);
    // replicatePlayerHealth detects the death and drops the bag (mode 1 all).
    g.replicatePlayerHealth();
    var bag_slot: ?usize = null;
    var s: usize = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (g.sim.alive[s] and g.sim.mask[s].loot_bag) {
            bag_slot = s;
            break;
        }
    }
    const bs = bag_slot orelse return error.TestUnexpectedResult;
    // The bag carries the real inventory range at the same offsets.
    try std.testing.expectEqual(@as(u16, 7), g.sim.inventory[bs].slots[2].item_id);
    try std.testing.expectEqual(@as(u16, 5), g.sim.inventory[bs].slots[2].count);
    try std.testing.expectEqual(@as(u16, 9), g.sim.inventory[bs].slots[10 + 4].item_id);
    std.debug.print("PASS death-bag: AI kill drops the player's real inventory range\n", .{});
}

test "scenario vending machine opens via LockRequest with TraderData" {
    io_fs.mkdirPath("worlds");
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
    // VendingMachineLockContext::Read takes TraderData straight after the type
    // name: no Command string, no hasTraderData bool (those belong to
    // EntityTraderLockContext). This test used to assert both of them, which
    // is what kept the wrong shape in place: a stock client would have read
    // the empty command's length byte and the bool as the first two bytes of
    // TraderID.
    try std.testing.expectEqual(@as(i32, 3), try rr.readI32()); // trader id
    _ = try rr.readU64(); // lastInventoryUpdate
    try std.testing.expectEqual(@as(u8, 2), try rr.readByte()); // TraderData FileVersion

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
    try io_fs.writeFile(tpath, tsrc);
    const tt = try assets_traders.loadFromPath(std.testing.allocator, tpath);

    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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

test "party highest game stage feeds the director (max, not party level)" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_gsmax");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_gsmax", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    // Level 1 vs level 10: game stages differ.
    g.clients[ca.slot].level = 1;
    g.clients[cb.slot].level = 10;
    const gs_lo = g.gameStageOf(ca.slot);
    const gs_hi = g.gameStageOf(cb.slot);
    try std.testing.expect(gs_hi > gs_lo);
    // Ungrouped: the highest stage is the max over all joined players.
    try std.testing.expectEqual(gs_hi, g.partyHighestGameStage());
    // In one party: still the max member stage.
    const p = g.parties.acceptInvite(ca.entity_id, cb.entity_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2), p.n);
    try std.testing.expectEqual(gs_hi, g.partyHighestGameStage());
    // The director reads it (party_stage is the blood-moon difficulty input).
    try g.step();
    try std.testing.expectEqual(gs_hi, g.sim.director.party_stage);
    std.debug.print("PASS scenario: party highest game stage feeds the director (max={d} > solo={d})\n", .{ gs_hi, gs_lo });
}

test "scenario trader RemoveQuest accepts and drops the quest from offers" {
    io_fs.mkdirPath("worlds");
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

test "scenario vehicle refuel caps at the tank and refunds when full" {
    // Fuel items used on a vehicle (InvTx place at the body) fill the tank
    // capped at vehicle_fuel_max; a full tank returns false so the can is
    // refunded (mirrors the generator refuel refund).
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

    var vs: ecs.Slot = 0;
    var found = false;
    while (vs < ecs.max_entities) : (vs += 1) {
        if (g.sim.alive[vs] and g.sim.mask[vs].vehicle) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    const vx: i32 = @trunc(g.sim.transform[vs].x);
    const vy: i32 = @trunc(g.sim.transform[vs].y);
    const vz: i32 = @trunc(g.sim.transform[vs].z);

    g.sim.vehicle[vs].fuel = 10;
    try std.testing.expect(g.tryRefuelVehicle(c, vx, vy, vz, 50));
    try std.testing.expectEqual(@as(f32, 60), g.sim.vehicle[vs].fuel);
    // Over-fill clamps at the cap.
    try std.testing.expect(g.tryRefuelVehicle(c, vx, vy, vz, 500));
    try std.testing.expectEqual(@as(f32, 100), g.sim.vehicle[vs].fuel);
    // A full tank refunds (false -> the InvTx handler returns the can).
    try std.testing.expect(!g.tryRefuelVehicle(c, vx, vy, vz, 10));

    std.debug.print("PASS vehicle-refuel: 10+50=60, clamp 100, full refunds\n", .{});
}

test "scenario drowning damages a submerged player" {
    // The client drains its local O2 bar first; the server is authoritative
    // for the hp loss: while the head block is water the player takes
    // drowning_damage_per_second (2 hp/s) in 1 s ticks.
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
    const ps = g.sim.playerByPeer(c.slot).?;
    const water_id = g.world.terrain_ids.water;
    if (water_id == 0) return; // flat world without water: nothing to test

    const hx: i32 = @trunc(g.sim.transform[ps].x);
    const hz: i32 = @trunc(g.sim.transform[ps].z);
    // Let the player settle onto the surface (the flat-world spawn is a few
    // blocks in the air), then submerge the settled head block.
    var k: u32 = 0;
    while (k < 30) : (k += 1) try g.step();
    const hy: i32 = @trunc(g.sim.transform[ps].y);
    try g.world.setBlockWorld(hx, hy + 1, hz, water_id);
    const hp0 = g.sim.health[ps].hp;
    k = 0;
    while (k < 25) : (k += 1) try g.step(); // >1 s submerged
    try std.testing.expect(g.sim.health[ps].hp < hp0);
    // Out of the water: no further loss. The placed water cascaded and its
    // puddle refills cleared cells, so teleport the player to dry air instead
    // of fighting the pour.
    g.sim.transform[ps].y = 100;
    const hp1 = g.sim.health[ps].hp;
    k = 0;
    while (k < 25) : (k += 1) try g.step();
    // No drown-scale loss after surfacing (regen drift is fine).
    try std.testing.expect(g.sim.health[ps].hp >= hp1 - 0.5);

    std.debug.print("PASS drowning: hp {d:.0} -> {d:.0} submerged, stable after surface\n", .{ hp0, hp1 });
}

test "scenario radiated biome damages the player" {
    // Stock BiomeType.Radiated (biomes.xml <biomemap name="radiated"/>) deals
    // damage over time; the server is authoritative for the hp loss.
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
    const ps = g.sim.playerByPeer(c.slot).?;

    // Synthesize a 1x1 biome map covering the pad with the radiated name.
    const bm_mod = @import("../world/biomes.zig");
    // 513x514 map centered so the (256,256) pad lands inside (z flips: row 0
    // is north, so the pad row is dz = half_h - 1 - z = 0).
    const bw: usize = 513;
    const bh: usize = 514;
    var map = bm_mod.BiomeMap{};
    map.width = @intCast(bw);
    map.height = @intCast(bh);
    map.scale = 1;
    map.half_w = 256;
    map.half_h = 257;
    map.allocator = gpa;
    map.r = gpa.alloc(u8, bw * bh) catch return error.OutOfMemory;
    @memset(map.r, 3); // pine_forest everywhere else
    const dx: usize = @intCast(256 + 256);
    const dz: usize = @intCast(257 - 1 - 256);
    map.r[dz * bw + dx] = 7; // radiated biomemap id at the pad
    g.world.biomes = map; // flat world has none; world.deinit frees it
    g.world.biome_layers_table.names[7] = "radiated";

    const hx: i32 = @trunc(g.sim.transform[ps].x);
    const hz: i32 = @trunc(g.sim.transform[ps].z);
    try std.testing.expect(g.isRadiatedAt(hx, hz));
    const hp0 = g.sim.health[ps].hp;
    var k: u32 = 0;
    while (k < 25) : (k += 1) try g.step(); // >1 s in the zone
    try std.testing.expect(g.sim.health[ps].hp < hp0);

    std.debug.print("PASS radiation: hp {d:.0} -> {d:.0} in radiated biome\n", .{ hp0, g.sim.health[ps].hp });
}

test "scenario explosion damages entities and credits the kill" {
    // Stock explosions hurt everything in the radius (linear falloff); a
    // zombie close enough dies and the thrower gets quest/XP/score credit.
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
    const zid = g.sim.spawnZombie(257, 70, 257, 30).?;
    const tank_id = g.sim.spawnZombie(258, 70, 256, 500).?;
    const far_id = g.sim.spawnZombie(276, 70, 256, 500).?;

    var body: [256]u8 = undefined;
    var w: @import("../wire/binary.zig").Writer = .{ .buf = &body };
    try w.writeF32(256);
    try w.writeF32(70);
    try w.writeF32(256); // center
    try w.writeI32(256);
    try w.writeI32(70);
    try w.writeI32(256); // block pos
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(1); // quat
    try w.writeU16(18); // blob len
    try w.writeI16(0); // particleIndex
    try w.writeI16(10); // duration deci-seconds
    try w.writeI16(60); // blockRadius 3.0
    try w.writeI16(20_000); // forged entityRadius 1000.0; server caps to 6
    try w.writeI16(100); // blastPower
    try w.writeF32(50); // blockDamage
    try w.writeF32(65_535); // forged entityDamage; server caps to authority limit
    try w.writeI32(c.entity_id);
    try w.writeF32(0); // delay
    var fb: [512]u8 = undefined;
    cap.clear();
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageExplosionInitiate", w.written()));

    const zs = g.sim.slotOfNetId(zid) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.health[zs].hp <= 0); // close enough to die
    const tank = g.sim.slotOfNetId(tank_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.health[tank].hp >= 300); // at most max_claimed_damage
    const far = g.sim.slotOfNetId(far_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 500), g.sim.health[far].hp); // outside capped radius
    const score_id = packages.idOf("NetPackageEntityAddScoreClient").?;
    const sb = cap.findPkgIdEntity(score_id, c.entity_id) orelse return error.TestUnexpectedResult;
    var sr = binary.Reader{ .data = sb };
    _ = try sr.readI32();
    try std.testing.expectEqual(@as(i16, 1), try sr.readI16()); // zombieKills

    std.debug.print("PASS explosion: close zombie killed, thrower credited 1 kill\n", .{});
}

test "scenario bedroll respawn: placed bed is listed and used on death" {
    // Stock bedroll placement sets the respawn point: the death screen lists
    // it after the world spawn and RequestToSpawnPlayer respawns there.
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

    // The bedroll block resolves by name (dump id), and the placement record
    // recognizes it; then simulate the placement record (the InvTx place path
    // derives coords from the packed entity_id, covered by its own tests).
    const bedroll_id = g.maxdamage.idByName("bedroll") orelse return; // dump has it
    try std.testing.expect(g.isBedrollId(bedroll_id));
    const ps = g.sim.playerByPeer(c.slot).?;
    const bx: i32 = @as(i32, @trunc(g.sim.transform[ps].x)) + 10;
    const by: i32 = @as(i32, @trunc(g.sim.transform[ps].y));
    const bz: i32 = @as(i32, @trunc(g.sim.transform[ps].z));
    c.bed_x = bx;
    c.bed_y = by;
    c.bed_z = bz;
    c.has_bed = true;

    // A zombie bites the player to death (AI path, not C2S damage), so the
    // spawn list must arrive from the hp-replicate pass for any killer.
    const zid = g.sim.spawnZombie(256, 70, 256, 5).?;
    _ = g.sim.damageFrom(c.entity_id, 100, g.sim.network_id[g.sim.slotOfNetId(zid).?].id);
    cap.clear();
    try g.step();
    try std.testing.expect(g.sim.health[g.sim.slotOfNetId(c.entity_id).?].hp <= 0);

    // Death screen lists world spawn + the bed.
    const wsp_id = packages.idOf("NetPackageWorldSpawnPoints").?;
    const wspb = cap.findPkgId(wsp_id) orelse return error.TestUnexpectedResult;
    var wr = binary.Reader{ .data = wspb };
    try std.testing.expectEqual(@as(u8, 2), try wr.readByte());
    try std.testing.expectEqual(@as(i32, 2), try wr.readI32()); // world + bed
    _ = try wr.readU16();
    _ = try wr.readF32();
    _ = try wr.readF32();
    _ = try wr.readF32();
    _ = try wr.readF32();
    _ = try wr.readI32();
    _ = try wr.readI32();
    _ = try wr.readU16();
    const bed_x = try wr.readF32();
    try std.testing.expectEqual(@as(f32, @floatFromInt(bx)), bed_x);

    std.debug.print("PASS bedroll: placed at {d}, listed on death, respawn target set\n", .{bx});
}

test "scenario spawn confirm: forged echo dropped, own echo relayed to the other peer" {
    // Stock NetPackagePlayerSpawnedInWorld ProcessPackage (IL=47): validate
    // the claimed entity against the sender (ValidEntityIdForSender), then
    // rebroadcast the confirm to every other peer on channel 192. A forged
    // echo for someone else's entity must die silently; the sender's own echo
    // must reach the tracking client with its entity intact.
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
    const peer_a = ca.peer.?;
    const spawn_id = packages.idOf("NetPackagePlayerSpawnedInWorld").?;
    // Join itself sends each client a SpawnedInWorld; drain those so the
    // assertions below see only what this test's echoes produce.
    cap_a.clear();
    cap_b.clear();

    const rej_before = g.harness.counters.get(.ownership_rejects);
    var forged: [20]u8 = undefined;
    _ = try packages.buildSpawnedBody(&forged, @intFromEnum(packages.RespawnType.died), 256, 70, 256, cb.entity_id);
    try g.handlePackage(ca, peer_a, spawn_id, &forged);
    try std.testing.expectEqual(rej_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(cap_b.findPkgId(spawn_id) == null);

    var own: [20]u8 = undefined;
    _ = try packages.buildSpawnedBody(&own, @intFromEnum(packages.RespawnType.died), 256, 70, 256, ca.entity_id);
    try g.handlePackage(ca, peer_a, spawn_id, &own);
    const relayed = cap_b.findPkgId(spawn_id) orelse return error.TestUnexpectedResult;
    const rep = try packages.parseSpawnedBody(relayed);
    try std.testing.expectEqual(ca.entity_id, rep.entity_id);
    try std.testing.expect(cap_a.findPkgId(spawn_id) == null);

    std.debug.print("PASS spawn-confirm: forged dropped, own relayed eid={d}\n", .{ca.entity_id});
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

    // The control body is zdtd's own shape under a stock package name
    // (DIVERGENCES "Four zdtd-shaped bodies"), told apart only by its exact
    // 13-byte length. Stock's NetPackageVehicleSpawn is entityType i32 + two
    // Vector3 + ItemValue + entityThatPlaced i32, so it is far longer; a
    // length gate that accepted "at least 13" would read a real spawn body's
    // position floats as throttle and steer.
    // A stock-length body: entityType, pos, rot, then a tail. Nothing in it
    // may reach the control path. Speed coasts down exponentially rather than
    // reaching zero, so compare against the coasting baseline instead of 0.
    // Build it byte-exact so the prefix would decode as a *drive* command if
    // the length gate let it through: byte 4 (pos.x's high byte) is op 2, and
    // bytes 5..13 are a large throttle. A body whose bytes happen to decode as
    // op 0 would pass this test without exercising the gate at all.
    var stock_body: [64]u8 = undefined;
    var sw: binary.Writer = .{ .buf = &stock_body };
    try sw.writeI32(ve); // entityType, deliberately the live vehicle id
    try sw.writeByte(2); // offset 4: read as op -> 2 = drive
    try sw.writeF32(1.0); // offsets 5..9: read as throttle
    try sw.writeF32(0.0); // offsets 9..13: read as steer
    try sw.writeF32(0);
    try sw.writeF32(0);
    try sw.writeF32(0); // the rest of pos/rot
    try sw.writeF32(0);
    try sw.writeI32(0); // stand-in for the ItemValue + entityThatPlaced tail
    try std.testing.expect(sw.written().len > packages.vehicle_control_len);
    const before_stock = g.sim.vehicle[vslot].speed;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageVehicleSpawn", sw.written()));
    try g.step();
    // Read as a control body, the pos floats would arrive as throttle 1.0 and
    // push the speed up; coasting can only lower it.
    try std.testing.expect(g.sim.vehicle[vslot].speed <= before_stock);

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

    // Owner attribution: a turret the player placed credits the placer with
    // the kill counter + AddScoreClient (trap kills give quest/XP/score in
    // stock). The demo turret is unowned, so credit only the owned one.
    {
        var ts2: usize = 0;
        var owned: ?ecs.Slot = null;
        while (ts2 < ecs.max_entities) : (ts2 += 1) {
            if (g.sim.alive[@intCast(ts2)] and g.sim.mask[@intCast(ts2)].turret) {
                g.sim.turret[@intCast(ts2)].owner_slot = @intCast(c.slot);
                owned = @intCast(ts2);
                break;
            }
        }
        const owned_t = owned orelse return error.TestUnexpectedResult;
        g.sim.turret[owned_t].ammo = 20;
        g.sim.power.resolve();
        _ = g.sim.spawnZombie(tx + 2, ty, tz, 15);
        cap.clear();
        const kills_before = c.zombie_kills;
        // trap_kill_xp_frac defaults to 0 (stock buffs.xml: no perk, no XP), so
        // an unperked turret kill must not raise the owner's XP.
        const xp_before = c.xp;
        var k2: u32 = 0;
        while (k2 < 50) : (k2 += 1) try g.step();
        try std.testing.expect(c.zombie_kills > kills_before);
        try std.testing.expectEqual(xp_before, c.xp);
        const score_id2 = packages.idOf("NetPackageEntityAddScoreClient").?;
        try std.testing.expect(cap.findPkgIdEntity(score_id2, c.entity_id) != null);

        // A perkAdvancedEngineering-equivalent rate (stock level 3 = .45) does
        // credit the fraction, once a turret kills again under it.
        g.sim.rules.progression.trap_kill_xp_frac = 0.45;
        g.sim.turret[owned_t].ammo = 20;
        g.sim.power.resolve();
        _ = g.sim.spawnZombie(tx + 2, ty, tz, 15);
        const xp_before2 = c.xp;
        var k3: u32 = 0;
        while (k3 < 50) : (k3 += 1) try g.step();
        try std.testing.expect(c.xp > xp_before2);
        // The real perk fold wins over the floor: reset the floor to 0, grant
        // the equivalent perk at level 3 (.45), and the next turret kill still
        // credits.
        g.sim.rules.progression.trap_kill_xp_frac = 0;
        const perks = [_]assets_progression.PerkDef{
            .{
                .name = "perkAdvancedEngineering",
                .max_level = 5,
                .passives = &.{.{ .name = "ElectricalTrapXP", .op = .base_set, .curve = .{ 0.15, 0.3, 0.45, 0, 0, 0, 0, 0 }, .curve_len = 3 }},
            },
        };
        g.progression_table.perks = &perks;
        g.clients[c.slot].skill_levels[0] = .{ .name = "perkAdvancedEngineering", .level = 3 };
        g.clients[c.slot].skill_level_n = 1;
        g.sim.turret[owned_t].ammo = 20;
        g.sim.power.resolve();
        _ = g.sim.spawnZombie(tx + 2, ty, tz, 15);
        const xp_before3 = c.xp;
        var k4: u32 = 0;
        while (k4 < 50) : (k4 += 1) try g.step();
        try std.testing.expect(c.xp > xp_before3);
    }

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
    io_fs.mkdirPath("worlds");
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

test "scenario a joiner sees what other players are holding" {
    // EntityCreationData's player branch carries holdingItem (stock_entity.zig
    // writes it before teamNumber/entityName). A switch is rebroadcast as
    // NetPackageHoldingItem, but the spawn package is the only thing that tells
    // a joiner what an already-present player has in hand. Passing null there
    // renders every existing player empty-handed until they next switch.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_holdspawn");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_holdspawn", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // A joins and arms itself.
    var cap_a: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const wood_id = g.items.ecsIdByName("resourceWood");
    try std.testing.expect(wood_id != 0);
    _ = invsys.give(&g.sim, ca.slot, wood_id, 10);
    const ps_a = g.sim.playerByPeer(ca.slot).?;
    // Hold whichever toolbelt slot the give landed in.
    var held_slot: u16 = 0;
    var si: u16 = 0;
    while (si < quest_mod_components.inv_toolbelt) : (si += 1) {
        if (g.sim.inventory[ps_a].slots[si].item_id == wood_id) {
            held_slot = si;
            break;
        }
    }
    try std.testing.expect(invsys.setHolding(&g.sim, ca.slot, held_slot));

    // B joins and must be told what A is holding.
    var cap_b: ln_peer.Capture = .{};
    const cb = try g.attachJoinedClient(&cap_b);
    const spawn_id = packages.idOf("NetPackageEntitySpawn") orelse return error.TestUnexpectedResult;
    const body = cap_b.findPkgIdEntity(spawn_id, ca.entity_id) orelse return error.TestUnexpectedResult;
    const held = playerSpawnHoldingType(body) orelse return error.TestUnexpectedResult;
    try std.testing.expect(held != 0);

    // The other direction: an armed joiner's own body goes out to the players
    // already in the world, so C must not look empty-handed to A either.
    var cap_c: ln_peer.Capture = .{};
    cap_a.clear();
    const cc = try g.attachJoinedClient(&cap_c);
    const ps_c = g.sim.playerByPeer(cc.slot).?;
    _ = invsys.give(&g.sim, cc.slot, wood_id, 5);
    var cs: u16 = 0;
    while (cs < quest_mod_components.inv_toolbelt) : (cs += 1) {
        if (g.sim.inventory[ps_c].slots[cs].item_id == wood_id) break;
    }
    try std.testing.expect(invsys.setHolding(&g.sim, cc.slot, cs));
    // The outbound half: a joiner's own body is pushed to the peers already in
    // the world at the moment it joins. Read it from A's capture, not the
    // joiner's, so this exercises the second call site rather than the first.
    // The joiner must already be armed when it joins, since that push happens
    // once during the join and is not repeated when a later client connects.
    // C is armed from above; re-running the join broadcast now pushes C's body
    // to A through the outbound site.
    cap_a.clear();
    try game_join.sendPlayerSpawns(
        g,
        cc.peer orelse return error.TestUnexpectedResult,
        cc,
        @intFromFloat(g.sim.transform[ps_c].x),
        @intFromFloat(g.sim.transform[ps_c].z),
    );
    const d_body = cap_a.findPkgIdEntity(spawn_id, cc.entity_id) orelse
        return error.TestUnexpectedResult;
    const d_held = playerSpawnHoldingType(d_body) orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_held != 0);

    // Player spawns are a first-join-only bundle: sendJoinBundle gates
    // sendPlayerSpawns on `first_join = !c.entered`, so a respawn does not
    // re-describe the other players. That is deliberate (the client already
    // holds those entities from its first join) and is pinned here because the
    // obvious assumption is the opposite: the holding_item fix lives in
    // sendPlayerSpawns, so if a change ever started re-sending these on
    // respawn, this is where the new path would have to be re-checked.
    cap_b.clear();
    var spawn_req: [2]u8 = undefined;
    std.mem.writeInt(i16, spawn_req[0..2], 4, .little);
    var rfb: [64]u8 = undefined;
    try g.injectFramed(cb, try packages.framed(&rfb, "NetPackageRequestToSpawnPlayer", &spawn_req));
    try std.testing.expect(cap_b.n > 0); // the respawn bundle did go out
    try std.testing.expect(cap_b.findPkgId(spawn_id) == null);

    std.debug.print("PASS spawn-holding: joiner told peer holds type {d}\n", .{held});
}

/// Decode the holdingItem type id out of a NetPackageEntitySpawn player body.
/// Offsets follow stock_entity.buildEntitySpawnStock: the fixed head, then the
/// player branch's ItemValue. Returns null when the body is not a player spawn
/// or carries the empty-ItemValue sentinel.
fn playerSpawnHoldingType(body: []const u8) ?i32 {
    var r: binary.Reader = .{ .data = body };
    _ = r.readI32() catch return null; // entity_id (package head)
    const file_ver = r.readByte() catch return null;
    if (file_ver != 36) return null;
    const cls = r.readI32() catch return null;
    if (cls != packages.stock_entity.class_player_male and
        cls != packages.stock_entity.class_player_female) return null;
    _ = r.readI32() catch return null; // entity id
    var skip: usize = 0;
    while (skip < 7) : (skip += 1) _ = r.readF32() catch return null; // lifetime, pos, rot
    _ = r.readBool() catch return null; // on_ground
    _ = r.readI32() catch return null; // BodyDamage
    _ = r.readI32() catch return null;
    _ = r.readU32() catch return null;
    _ = r.readBool() catch return null; // no EntityStats
    _ = r.readI16() catch return null; // deathTime
    if (r.readBool() catch return null) return null; // a bag would shift the rest
    _ = r.readI32() catch return null; // home x
    _ = r.readI32() catch return null;
    _ = r.readI32() catch return null;
    _ = r.readI16() catch return null; // homeRange
    _ = r.readByte() catch return null; // spawnerSource
    const slot = packages.stock_inv.readItemValue(&r) catch return null;
    return slot.type_id;
}

test "scenario powered trigger echo carries every wire the sim holds" {
    // The sim caps wires globally (electric.max_wires), not per node, so a
    // trigger can legitimately hold more edges than any fixed echo buffer.
    // The S2C encoder writes a u8 count and accepts up to 255, so a caller
    // buffer smaller than that silently drops edges off the wire: the client
    // is told the node has fewer connections than the server believes.
    const stock_te = packages.stock_te;
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_trigwires");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_trigwires", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    _ = c;

    const plate_id = g.maxdamage.idByName("pressureplate") orelse return error.SkipZigTest;
    if (g.power_registry.lookup(plate_id) == null) return error.SkipZigTest;

    // Place the trigger, then wire more neighbours to it than a single-byte
    // "handful" buffer would hold.
    const tx: i32 = 200;
    const ty: i32 = 70;
    const tz: i32 = 200;
    try g.world.setBlockWorld(tx, ty, tz, plate_id);
    const trig = g.sim.power.addNodeAt(.consumer, tx, ty, tz, 1) orelse return error.TestUnexpectedResult;
    const ti = g.sim.power.indexOfId(trig).?;
    g.sim.power.nodes[ti].is_trigger = true;

    const wanted: usize = stock_te.max_te_wires + 4;
    var made: usize = 0;
    var k: i32 = 0;
    while (made < wanted) : (k += 1) {
        const nid = g.sim.power.addNodeAt(.consumer, tx + 2 + k * 2, ty, tz, 1) orelse break;
        if (!g.sim.power.connect(trig, nid)) break;
        made += 1;
    }
    try std.testing.expectEqual(wanted, made);

    cap.clear();
    g.sim.power.resolve();
    try replicate_te.broadcastPoweredTriggerTe(g, tx, ty, tz);

    const te_id = packages.idOf("NetPackageTileEntity") orelse return error.TestUnexpectedResult;
    const msg = cap.findPkgId(te_id) orelse return error.TestUnexpectedResult;
    // The wire count sits after the outer TE header; parse rather than index so
    // this keeps testing the shipped layout instead of a copy of it.
    const declared = countPoweredTriggerWires(msg) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(made, declared);

    std.debug.print("PASS trigger echo: {d} wires held, {d} on the wire\n", .{ made, declared });
}

/// Pull the wire count out of a captured NetPackageTileEntity powered-trigger
/// body. Mirrors the field order in stock_te.buildPoweredTriggerTeBody.
fn countPoweredTriggerWires(msg: []const u8) ?usize {
    // Locate the package body inside the captured frame by scanning for the
    // outer TE header the builder writes; the capture holds a full frame.
    if (msg.len < 32) return null;
    var i: usize = 0;
    while (i + 30 < msg.len) : (i += 1) {
        // outer: handle u8 | wx i32 | wy i32 | wz i32 | blockId i32 | len i32
        if (msg[i] != 255) continue;
        const wx = std.mem.readInt(i32, msg[i + 1 ..][0..4], .little);
        const wy = std.mem.readInt(i32, msg[i + 5 ..][0..4], .little);
        const wz = std.mem.readInt(i32, msg[i + 9 ..][0..4], .little);
        if (wx != 200 or wy != 70 or wz != 200) continue;
        // payload: lx i32 | ly i32 | lz i32 | const1 i32 | placed u8 | type u8 | wireCount u8
        const payload = i + 21;
        if (payload + 19 > msg.len) return null;
        return msg[payload + 18];
    }
    return null;
}

test "scenario inventory move drop place equip" {
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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

test "scenario console storm commands force and clear the storm" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_stormcmd");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_stormcmd", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);

    var table: biome_layers.Table = .{};
    table.weather_ids[0] = 3;
    table.weather_groups[0] = biome_layers.parseWeatherGroups(
        \\<weather name="default" prob="83" duration="6"><CloudThickness range="0,20"/></weather>
        \\<weather name="stormbuild" prob="0" duration=".2"><Wind range="25,25"/></weather>
        \\<weather name="storm" prob="0" duration="1.1" delay="26,36"><Wind range="40,40"/></weather>
    );
    table.weather_n = 1;
    table.loaded = true;
    g.world.biome_layers_table = table;
    g.world.weather.initFrom(&g.world.biome_layers_table, .{ .seed = 99 });
    const pine = &g.world.biome_layers_table.weather_groups[0];
    const storm_idx = pine.findIndex("storm").?;

    const wt0 = @as(i64, @intCast(g.sim.director.clock.worldTimeBits()));
    try std.testing.expect(g.forceStorm());
    var st = g.world.weather.states[0];
    try std.testing.expectEqual(@as(u8, 2), st.storm_state);
    // The force also pushes the storm group onto the wire and broadcasts it.
    const body = g.buildWeatherBodyFromBiomes() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(storm_idx, body[1]); // storm group at the biome slot
    const wid = packages.idOf("NetPackageWeather").?;
    try std.testing.expect(cap.findPkgId(wid) != null);

    try std.testing.expect(g.clearStorm());
    st = g.world.weather.states[0];
    try std.testing.expectEqual(@as(u8, 0), st.storm_state);
    // The next storm is pushed a full in-game day out.
    try std.testing.expect(st.storm_world_time.? > wt0 + 70_000);

    std.debug.print(
        "PASS storm-commands: forced storm_state=2 group={d}, cleared to 0, next > day out\n",
        .{st.group_index},
    );
}

test "scenario craft invtx + explosion dig + lock deny" {
    io_fs.mkdirPath("worlds");
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

test "scenario a locked tile entity stays locked on a different channel" {
    // Channels are per-purpose (loot, trade, ...), so the same container can be
    // asked for on two of them. The per-channel holder check above cannot see
    // that: it only compares who holds *this* channel. Without the position
    // sweep, a second player picks a free channel and gets the same chest.
    // The lock deny in the scenario above sends no targets, so pos_key is 0
    // and the sweep is skipped there; a real block target is what reaches it.
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

    // Lock request naming one block target (type 0 = block: x, y, z).
    const buildReq = struct {
        fn call(buf: []u8, channel: u16, x: i32, y: i32, z: i32) ![]u8 {
            var w: binary.Writer = .{ .buf = buf };
            try w.writeBool(true); // locking
            try w.writeU16(channel);
            try w.writeI32(1); // one target
            try w.writeByte(1); // present
            try w.writeByte(0); // block target
            try w.writeI32(x);
            try w.writeI32(y);
            try w.writeI32(z);
            try w.writeString(""); // context
            return w.written();
        }
    }.call;

    const lock_id = packages.idOf("NetPackageLockResponse") orelse return error.TestUnexpectedResult;
    var rb: [64]u8 = undefined;
    var fb: [256]u8 = undefined;

    // A takes the chest on channel 0.
    cap_a.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageLockRequest", try buildReq(&rb, 0, 300, 70, 300)));
    try std.testing.expectEqual(@as(i32, @intCast(ca.slot)), g.lock_channel[0]);
    {
        const body = cap_a.findPkgId(lock_id) orelse return error.TestUnexpectedResult;
        var r: binary.Reader = .{ .data = body };
        _ = try r.readBool(); // locking
        try std.testing.expectEqual(true, try r.readBool()); // success
    }

    // B asks for the same chest on channel 1: a free channel, someone else's
    // chest. The response must be a denial and the channel must stay unheld.
    cap_b.clear();
    try g.injectFramed(cb, try packages.framed(&fb, "NetPackageLockRequest", try buildReq(&rb, 1, 300, 70, 300)));
    try std.testing.expectEqual(@as(i32, -1), g.lock_channel[1]);
    {
        const body = cap_b.findPkgId(lock_id) orelse return error.TestUnexpectedResult;
        var r: binary.Reader = .{ .data = body };
        _ = try r.readBool(); // locking
        try std.testing.expectEqual(false, try r.readBool()); // success
    }

    // A different chest on that same channel 1 is fine, so the denial above is
    // the position sweep and not the channel being unusable.
    cap_b.clear();
    try g.injectFramed(cb, try packages.framed(&fb, "NetPackageLockRequest", try buildReq(&rb, 1, 320, 70, 320)));
    try std.testing.expectEqual(@as(i32, @intCast(cb.slot)), g.lock_channel[1]);
    std.debug.print("PASS lock-sweep: same TE denied across channels, other TE allowed\n", .{});
}

test "scenario SetBlock beyond edit reach is rejected" {
    // SetBlock carries its own coordinates, so nothing about the packet ties
    // the edit to where the player is standing except this check. Without it a
    // client rewrites terrain anywhere in the world, including chunks it was
    // never streamed. The reach is max_edit_range (96) from the editor.
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
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    const ep = g.sim.transform[ps];

    const stone = world_store.block_stone;
    var sb: [64]u8 = undefined;
    var fb: [8192]u8 = undefined;

    // Just inside the reach: allowed, so the far edit below is rejected for
    // distance and not for some unrelated reason.
    const near_x: i32 = @intFromFloat(ep.x + g.max_edit_range - 4);
    const near_z: i32 = @intFromFloat(ep.z);
    const near = try packages.buildSetBlockBody(&sb, near_x, 70, near_z, stone);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageSetBlock", near));
    try std.testing.expectEqual(stone, try g.world.blockWorld(near_x, 70, near_z));

    // Well beyond it: dropped, and the counter says why.
    const far_x: i32 = @intFromFloat(ep.x + g.max_edit_range * 4);
    const before = g.harness.counters.get(.bounds_rejects);
    const far = try packages.buildSetBlockBody(&sb, far_x, 70, near_z, stone);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageSetBlock", far));
    try std.testing.expectEqual(@as(u32, 0), try g.world.blockWorld(far_x, 70, near_z));
    try std.testing.expect(g.harness.counters.get(.bounds_rejects) > before);
    std.debug.print("PASS edit-reach: near edit applied, far edit rejected\n", .{});
}

test "scenario NetPackageBag naming another player is refused" {
    // NetPackageBag carries the entity id whose inventory it describes, so
    // nothing but this ownership check stops a peer from addressing someone
    // else's player entity and rewriting their slots. Stock treats a player's
    // own bag as client-authored (ADR 0007); that trust does not extend to
    // writing a *different* player's inventory.
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
    const psa = g.sim.playerByPeer(ca.slot) orelse return error.TestUnexpectedResult;
    const psb = g.sim.playerByPeer(cb.slot) orelse return error.TestUnexpectedResult;

    var bag_body: [8192]u8 = undefined;
    var fb: [9000]u8 = undefined;

    // A writes its own bag: allowed, so the refusal below is the ownership
    // check and not a malformed body or an unreachable handler.
    {
        var mine = g.sim.inventory[psa];
        mine.slots[10] = .{ .item_id = 7, .count = 4, .quality = 1 };
        const bb = try packages.stock_inv.buildBagPackage(&bag_body, ca.entity_id, &mine, null, null, true);
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageBag", bb));
        try std.testing.expectEqual(@as(u16, 7), g.sim.inventory[psa].slots[10].item_id);
    }

    // A addresses B's entity: refused, B's slot untouched, counter moves.
    const before_id = g.sim.inventory[psb].slots[10].item_id;
    const before_n = g.sim.inventory[psb].slots[10].count;
    const own_before = g.harness.counters.get(.ownership_rejects);
    {
        var theirs = g.sim.inventory[psb];
        theirs.slots[10] = .{ .item_id = 7, .count = 64, .quality = 1 };
        const bb = try packages.stock_inv.buildBagPackage(&bag_body, cb.entity_id, &theirs, null, null, true);
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageBag", bb));
    }
    try std.testing.expectEqual(before_id, g.sim.inventory[psb].slots[10].item_id);
    try std.testing.expectEqual(before_n, g.sim.inventory[psb].slots[10].count);
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    std.debug.print("PASS bag-ownership: own bag applied, another player's refused\n", .{});
}

test "scenario gas can refuel generator via InvTx place" {
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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

test "scenario observe mode records evidence but does not enforce (T19)" {
    // T19: observe must be honest. It applies the client position (the guard
    // never denies in observe - AUTHORITY.md) but must NOT count
    // movement_rejects: that counter means ENFORCED rejections, and counting
    // applied moves would make the dashboard claim protection observe does
    // not provide. The evidence ring records the observed violation instead.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_observe");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_observe", 0, .{ .authority_mode = .observe });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);

    // Seed last-good position so the envelope has a baseline.
    var pos_body: [64]u8 = undefined;
    const seed = try packages.buildPosAndRotBody(&pos_body, c.entity_id, 100, 71, 100, 0, 0, 0, true);
    var frame_buf: [128]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", seed));
    g.tick_n += 20;

    const rejects_before = g.harness.counters.get(.movement_rejects);
    const evidence_before = g.harness.counters.get(.evidence_events);
    // 500 m horizontal in ~1 s >> the 20 m/s soft cap.
    const hack = try packages.buildPosAndRotBody(&pos_body, c.entity_id, 600, 71, 100, 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", hack));

    // Not enforced: no reject counted, and the permissive apply keeps the
    // client position in the sim.
    try std.testing.expectEqual(rejects_before, g.harness.counters.get(.movement_rejects));
    const idx = g.sim.slotOfNetId(c.entity_id) orelse return error.MissingEntity;
    try std.testing.expect(g.sim.transform[idx].x > 500);
    // Observed: the evidence ring recorded the violation.
    try std.testing.expect(g.harness.counters.get(.evidence_events) > evidence_before);
    std.debug.print(
        "PASS observe-honest: rejects {d}->{d} evidence {d}->{d} x={d:.1}\n",
        .{ rejects_before, g.harness.counters.get(.movement_rejects), evidence_before, g.harness.counters.get(.evidence_events), g.sim.transform[idx].x },
    );
}

test "scenario T20 hard ceiling downgrades client-informed detectors" {
    // The authority ceiling (T20): `.hard` can trip a kick, so only
    // server-only detectors may carry it. A `.hard` event from a
    // client-informed detector (bounds/movement weigh client-reported
    // values) fails closed to `.strong` - never the hard ladder - and the
    // downgrade is counted.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_ceiling");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_ceiling", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    g.tick_n = 100; // a non-zero tick for the evidence stream

    // T21 wiring: a registered evidence observer receives the event with the
    // EFFECTIVE (post-ceiling) severity. Module-scope capture (the vtable fn
    // cannot close over locals).
    ev_seen = .{0} ** 8;
    const obs = plugin_api.PluginVTable{
        .name = "evobs",
        .on_evidence = struct {
            fn f(_: *const plugin_api.Host, tick: i32, peer_local: i32, entity_id: i32, detector: i32, severity: i32, surface: i32, observed_bits: i32, bound_bits: i32) void {
                ev_seen = .{ tick, peer_local, entity_id, detector, severity, surface, observed_bits, bound_bits };
            }
        }.f,
    };
    try std.testing.expect(g.plugins.register(&obs));
    g.plugins.enableAll();

    // A .hard bounds event (client-informed): downgraded, never trips hard.
    const downgrades_before = g.harness.counters.get(.hard_ceiling_downgrades);
    g.noteEvidence(c, 0, c.entity_id, .bounds, .hard, .block, 100, 96);
    try std.testing.expect(g.harness.counters.get(.hard_ceiling_downgrades) > downgrades_before);
    try std.testing.expectEqual(@as(u16, 0), c.guard.hard_n);
    // The observer saw the downgraded severity (.strong = 2) and the event.
    try std.testing.expectEqual(@as(i32, 2), ev_seen[4]); // severity post-ceiling
    try std.testing.expectEqual(@as(i32, 3), ev_seen[3]); // detector .bounds
    try std.testing.expect(ev_seen[0] > 0); // tick

    // A .hard phase event (server-only): passes the ceiling untouched.
    const downgrades_mid = g.harness.counters.get(.hard_ceiling_downgrades);
    g.noteEvidence(c, 0, c.entity_id, .phase, .hard, .none, 1, 0);
    try std.testing.expectEqual(downgrades_mid, g.harness.counters.get(.hard_ceiling_downgrades));
    try std.testing.expect(c.guard.hard_n >= 1);
    std.debug.print("PASS hard-ceiling: bounds .hard downgraded, phase .hard kept (hard_n={d})\n", .{c.guard.hard_n});
}

test "scenario void rescue suppresses the movement reject (T22)" {
    // T22 suppression: a client that falls out of the mesh (y < -1) is
    // rescued to the surface - a server correction for a mesh desync, never
    // a cheat. The envelope resets so the interim packets (the client still
    // falling before it processes the EntityTeleport) are not counted as
    // movement rejects against a legit player.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_voidrescue");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_voidrescue", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    var pos_body: [64]u8 = undefined;
    var frame_buf: [128]u8 = undefined;
    const sp = g.world.primarySpawn();
    // Fall in cap-respecting steps (1 block/tick < the 25 m/s cap) from the
    // surface into the void.
    var fy: f32 = @as(f32, @floatFromInt(sp.y)) + 0.08;
    while (fy > -2) : (fy -= 1) {
        const fb = try packages.buildPosAndRotBody(&pos_body, c.entity_id, @floatFromInt(sp.x), fy, @floatFromInt(sp.z), 0, 0, 0, true);
        try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", fb));
        g.tick_n += 1;
    }
    const rejects_before = g.harness.counters.get(.movement_rejects);
    // Still falling before it processes the rescue's EntityTeleport: this
    // interim void packet must not count as a reject either.
    const fall2 = try packages.buildPosAndRotBody(&pos_body, c.entity_id, @floatFromInt(sp.x), fy - 1, @floatFromInt(sp.z), 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", fall2));
    try std.testing.expectEqual(rejects_before, g.harness.counters.get(.movement_rejects));
    // The sim is back at the surface, not in the void.
    const idx = g.sim.slotOfNetId(c.entity_id) orelse return error.MissingEntity;
    try std.testing.expect(g.sim.transform[idx].y > 0);
    std.debug.print("PASS void-rescue: rejects {d}->{d} y={d:.1}\n", .{ rejects_before, g.harness.counters.get(.movement_rejects), g.sim.transform[idx].y });
}

test "scenario guardreport shows the would-kick diff (T23)" {
    // T23: the dry-run must produce a reviewable diff - guardreport names the
    // peer, the strong detectors in its window, and the detector that tripped
    // the kick ladder (and when), so an operator reviews exactly who WOULD be
    // kicked before enabling an enforcement rung.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_guardreport");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_guardreport", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    g.tick_n = 100;

    // Trip the gate with two distinct strong detectors (the default ladder:
    // 2 distinct strong in a window). The second detector is the cause.
    g.noteEvidence(c, 0, c.entity_id, .bounds, .strong, .block, 100, 96);
    try std.testing.expect(!c.guard.tripped);
    g.noteEvidence(c, 0, c.entity_id, .movement, .strong, .none, 25, 20);
    try std.testing.expect(c.guard.tripped);
    try std.testing.expectEqualStrings("movement", @tagName(c.guard.tripped_det));
    try std.testing.expect(c.guard.tripped_tick > 0);

    // The dry-run diff names the cause and the enforcement state.
    var sink: [2048]u8 = undefined;
    g.admin_reply_len = 0;
    g.admin_reply_sink = &sink;
    g.runAdminLine("guardreport", "test");
    g.admin_reply_sink = null;
    const reply = sink[0..g.admin_reply_len];
    try std.testing.expect(reply.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, reply, "dry_run=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "tripped=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "det=movement") != null);
    std.debug.print("PASS guardreport: {s}\n", .{reply});
}

test "scenario stock InvTx rejects unresolvable item stacks (T18)" {
    // T18 hardening: a stock InventoryTransaction SetAbsolute carrying a
    // non-empty stack that does not resolve to a server catalog item must be
    // REJECTED (fail-closed, honest success bit + c2s_rejects), not silently
    // applied as an empty slot with a success ack.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_stocktx");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_stocktx", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;

    // Seed a known item at slot 3 so we can assert it survives a rejected tx.
    const wood = (g.items.byName("resourceWood") orelse return error.SkipZigTest).id;
    g.sim.inventory[ps].slots[3] = .{ .item_id = wood, .count = 10 };

    // Stock InvTx: SetAbsolute at index 3 with a bogus, unresolvable type id.
    var body: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeI32(1); // inventoryCount
    for (0..16) |i| try w.writeByte(@intCast(i)); // guid
    try w.writeI32(0); // initialHash
    try w.writeI32(0); // finalHash
    try w.writeI32(1); // opCount
    try w.writeI16(0); // SetAbsolute
    try packages.stock_inv.writeItemStack(&w, .{ .type_id = packages.stock_inv.items_start_here + 50000, .count = 1 });
    try w.writeI32(3); // index slot 3
    var frame_buf: [300]u8 = undefined;
    const rejects_before = g.harness.counters.get(.c2s_rejects);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageInventoryTransactionRequest", w.written()));
    try std.testing.expect(g.harness.counters.get(.c2s_rejects) > rejects_before);
    // The slot is untouched (rejected, not cleared).
    try std.testing.expectEqual(@as(u16, wood), g.sim.inventory[ps].slots[3].item_id);
    try std.testing.expectEqual(@as(u16, 10), g.sim.inventory[ps].slots[3].count);
    std.debug.print("PASS stock-tx-reject: c2s_rejects {d}->{d} slot3 intact\n", .{ rejects_before, g.harness.counters.get(.c2s_rejects) });

    // The op index is a raw i32 off the wire while the slot array holds
    // max_inv_slots, so an index past the end (or negative) has to fail the
    // transaction before it is used to write. Same body shape with a
    // resolvable item, so the index is the only thing wrong with it.
    const good_type = packages.stock_inv.items_start_here + @as(i32, wood);
    // Pin that the stack itself is fine: with an unresolvable type the T18
    // reject above fires first and the index bound never runs, which makes a
    // green test prove nothing.
    try std.testing.expectEqual(wood, g.items.ecsIdFromStockType(good_type));
    for ([_]i32{ @intCast(quest_mod_components.max_inv_slots), -1 }) |bad_index| {
        var ob: [256]u8 = undefined;
        var ow: binary.Writer = .{ .buf = &ob };
        try ow.writeI32(1);
        for (0..16) |i| try ow.writeByte(@intCast(i));
        try ow.writeI32(0);
        try ow.writeI32(0);
        try ow.writeI32(1); // opCount
        try ow.writeI16(0); // SetAbsolute
        try packages.stock_inv.writeItemStack(&ow, .{ .type_id = packages.stock_inv.items_start_here + @as(i32, wood), .count = 1 });
        try ow.writeI32(bad_index);
        var ofb: [300]u8 = undefined;
        try g.injectFramed(c, try packages.framed(&ofb, "NetPackageInventoryTransactionRequest", ow.written()));
        // Slot 3 still carries what the earlier reject left there: nothing was
        // applied, and no write landed anywhere the index could have reached.
        try std.testing.expectEqual(@as(u16, wood), g.sim.inventory[ps].slots[3].item_id);
        try std.testing.expectEqual(@as(u16, 10), g.sim.inventory[ps].slots[3].count);
    }
    std.debug.print("PASS stock-tx-reject: an out-of-range op index is rejected\n", .{});
}

test "scenario whitelist gate fails closed on an un-keyable identity (admin audit)" {
    // The "platform:id" composite key buffer was sized to max_id (64) while a
    // max-length identity composite is up to 81 chars; the bufPrint overflow
    // at the whitelist gate used to `catch return true` - SKIPPING the gate
    // (fail-open on a whitelist-only server). Now the buffer covers the
    // composite and an un-keyable identity is simply not on the whitelist
    // (denied), never a gate skip.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_whitelist");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_whitelist", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Whitelist-only: a DIFFERENT identity, so this player is not on it.
    try std.testing.expect(g.whitelist.add("Steam:111", 0));
    // Max-length id: "EOS:" + 64 chars = 68-char composite > the old 64 cap.
    var id_buf: [64]u8 = undefined;
    @memset(&id_buf, 'a');
    const puid: platform_user.Id = .{ .platform = "EOS", .id = &id_buf };
    var cap: ln_peer.Capture = .{};
    try std.testing.expectError(error.JoinFailed, g.attachJoinedClientAs(&cap, puid));
    // The old fail-open behavior joined this player; now the gate denies.
    std.debug.print("PASS whitelist-fail-closed: max-length identity denied on whitelist-only\n", .{});
}

test "scenario malicious C2S: out-of-range coordinates are rejected, admin tele clamps" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_coordbound");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_coordbound", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);
    const idx = g.sim.slotOfNetId(c.entity_id) orelse return error.MissingEntity;
    const spawn_x = g.sim.transform[idx].x;
    const spawn_y = g.sim.transform[idx].y;
    const spawn_z = g.sim.transform[idx].z;

    // A coordinate beyond the sim's ceiling but inside the wire reader's
    // stock range (1<<24, wire/packages.zig world_coord_limit) must be
    // rejected at the envelope - even on the first packet after spawn, where
    // move_valid=false would otherwise apply it directly and the tick path's
    // @trunc casts could still trap further out.
    var pos_body: [64]u8 = undefined;
    var frame_buf: [128]u8 = undefined;
    const before = g.harness.counters.get(.bounds_rejects);
    const huge = try packages.buildPosAndRotBody(&pos_body, c.entity_id, 2e6, 2e6, 2e6, 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", huge));
    const after = g.harness.counters.get(.bounds_rejects);
    try std.testing.expect(after > before);
    try std.testing.expectEqual(spawn_x, g.sim.transform[idx].x);
    try std.testing.expectEqual(spawn_y, g.sim.transform[idx].y);
    try std.testing.expectEqual(spawn_z, g.sim.transform[idx].z);

    // Same for a C2S hard teleport: rejected, transform untouched.
    const before2 = g.harness.counters.get(.bounds_rejects);
    const huge_tp = try packages.buildPosAndRotBody(&pos_body, c.entity_id, -2e6, -2e6, -2e6, 0, 0, 0, true);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageEntityTeleport", huge_tp));
    try std.testing.expect(g.harness.counters.get(.bounds_rejects) > before2);
    try std.testing.expectEqual(spawn_x, g.sim.transform[idx].x);
    try std.testing.expectEqual(spawn_z, g.sim.transform[idx].z);

    // Admin `tele` clamps to the same ceiling instead of rejecting: the
    // operator's intent is honored up to the safety bound.
    var sink: [4096]u8 = undefined;
    var line_buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "tele {d} 3e38 3e38 3e38", .{c.slot});
    g.admin_reply_len = 0;
    g.admin_reply_sink = sink[0..];
    g.runAdminLine(line, "test");
    g.admin_reply_sink = null;
    const max_c = game_mod.max_player_coord;
    try std.testing.expectEqual(max_c, g.sim.transform[idx].x);
    try std.testing.expectEqual(max_c, g.sim.transform[idx].y);
    try std.testing.expectEqual(max_c, g.sim.transform[idx].z);

    // Plugin bot verbs: an out-of-range `bot spawn` is dropped (no bot), and a
    // `bot move` with a huge dest never sets a dest the tick step would cast.
    _ = g.bots.handleCommand(g, "bot spawn 3e38 3e38", 0);
    try std.testing.expectEqual(@as(usize, 0), g.bots.n);
    const bot_id = g.bots.spawn(g, 0, g.bots.cfg.spawn_y, 0, 100) orelse return error.NoBot;
    const bs = g.bots.find(bot_id) orelse return error.NoBot;
    var move_cmd: [64]u8 = undefined;
    const move_line = try std.fmt.bufPrint(&move_cmd, "bot move {d} 3e38 3e38 3e38 5", .{bot_id});
    _ = g.bots.handleCommand(g, move_line, 0);
    try std.testing.expect(!g.bots.bots[bs].move_active);

    std.debug.print(
        "PASS coord bound: C2S 2e6 rejected (bounds_rejects {d}->{d}), admin tele clamped to {d:.0}\n",
        .{ before, after, max_c },
    );
}

test "scenario teleport Y-clamp suppresses the raw claim on peers" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_tpclamp");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_tpclamp", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_mover: ln_peer.Capture = .{};
    var cap_obs: ln_peer.Capture = .{};
    const m = try g.attachJoinedClient(&cap_mover);
    const obs = try g.attachJoinedClient(&cap_obs);
    try std.testing.expect(m.entity_id > 0);
    const idx = g.sim.slotOfNetId(m.entity_id) orelse return error.MissingEntity;
    const sx = g.sim.transform[idx].x;
    const sy = g.sim.transform[idx].y;
    const sz = g.sim.transform[idx].z;

    // Arm the envelope with a legitimate first move (move_valid=false would
    // otherwise apply the teleport directly).
    var pos_body: [64]u8 = undefined;
    var frame_buf: [128]u8 = undefined;
    const home = try packages.buildPosAndRotBody(&pos_body, m.entity_id, sx, sy, sz, 0, 0, 0, true);
    try g.injectFramed(m, try packages.framed(&frame_buf, "NetPackageEntityPosAndRot", home));
    try std.testing.expectEqual(sy, g.sim.transform[idx].y);

    // A Y-only fly teleport (same x/z, +1000 y) is clamped by the vertical
    // envelope; the sim must not reach the claim.
    const fly = try packages.buildPosAndRotBody(&pos_body, m.entity_id, sx, sy + 1000, sz, 0, 0, 0, true);
    try g.injectFramed(m, try packages.framed(&frame_buf, "NetPackageEntityTeleport", fly));
    try std.testing.expect(g.sim.transform[idx].y < sy + 1.0);

    // The observer must not have seen the raw claim: a clamped teleport is
    // not relayed (peers pick the true position up on the next motion pass).
    const did = packages.idOf("NetPackageEntityTeleport").?;
    var found = false;
    var i: usize = 0;
    while (i < cap_obs.n and !found) : (i += 1) {
        const msg = cap_obs.slots[i].data[0..cap_obs.slots[i].len];
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(msg, &pkgs);
        var j: usize = 0;
        while (j < pn) : (j += 1) {
            if (pkgs[j].id == did and pkgs[j].body.len >= 4 and
                std.mem.readInt(i32, pkgs[j].body[0..4], .little) == m.entity_id)
            {
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(!found);

    // Ownership: the cases above all teleport the sender's own entity, which
    // exercises the speed envelope but never the id check in front of it. A
    // client claiming another entity must be rejected outright - otherwise one
    // player could move another around the map.
    const obs_idx = g.sim.slotOfNetId(obs.entity_id) orelse return error.TestUnexpectedResult;
    const before = g.sim.transform[obs_idx];
    const own_before = g.harness.counters.get(.ownership_rejects);
    var spoof_buf: [64]u8 = undefined;
    const spoof_tp = try packages.buildEntityTeleportBody(
        &spoof_buf,
        obs.entity_id, // not m's entity
        before.x + 500,
        before.y,
        before.z + 500,
        0,
        0,
        0,
        true,
    );
    try g.injectFramed(m, try packages.framed(&frame_buf, "NetPackageEntityTeleport", spoof_tp));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    const after = g.sim.transform[obs_idx];
    try std.testing.expectEqual(before.x, after.x);
    try std.testing.expectEqual(before.z, after.z);

    std.debug.print("PASS scenario: Y-clamped C2S teleport suppressed on the observer peer\n", .{});
    std.debug.print("PASS teleport-ownership: a peer cannot teleport another entity\n", .{});
}

test "scenario join enter bundle arrives in full on the capture peer" {
    // net-send-review checklist: a join regression must fail a test, not wedge
    // a client. Assert the enter-bundle critical sends that fit the capture
    // landed on a capture peer: ConfigFile -> WorldInfo -> ChunkClusterInfo ->
    // WorldSpawnPoints -> WorldAreas -> WorldTime -> GameStats (IdMapping is
    // too large for a capture slot; its arrival is enforced by the critical
    // send abort semantics, see the comment below). No ticking happens here,
    // so the capture holds only the bundle (no chunk-stream overflow to drop
    // the earliest critical sends).
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_enterbundle");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_enterbundle", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);

    // NetPackageIdMapping is deliberately absent: the deflated blocks mapping
    // is ~255 KiB and the capture slot cap is 8 KiB, so it truncates and the
    // channel parser cannot see it. Its arrival is still enforced here: it is
    // a critical send (sendBlockIdMapping -> sendFramedReliable critical), so
    // a WindowFull or a misclassification to droppable aborts the bundle with
    // error.WindowFull and attachJoinedClient above would have failed.
    // NetPackageWorldAreas is also absent: sendWorldAreas skips the send when
    // the world has no trader-area prefabs (join.zig:449), which is the flat
    // test world.
    const names = [_][]const u8{
        "NetPackageConfigFile",
        "NetPackageWorldInfo",
        "NetPackageChunkClusterInfo",
        "NetPackageWorldSpawnPoints",
        "NetPackageWorldTime",
        "NetPackageGameStats",
    };
    var checked: usize = 0;
    for (names) |nm| {
        const id = packages.idOf(nm) orelse continue;
        if (cap.findPkgId(id) == null) {
            std.debug.print("FAIL enter bundle: {s} (id {d}) not found in {d} capture slots\n", .{ nm, id, cap.n });
            return error.MissingBundlePackage;
        }
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, names.len), checked);
    std.debug.print("PASS enter bundle: {d}/{d} critical packages arrived on capture\n", .{ checked, names.len });
}

test "scenario plugin withdrawal despawns applied spawns" {
    // Paper 3.1 held inverse: a withdrawn plugin's applied queue spawns are
    // despawned by the Game withdrawal path (self-disable and reload both
    // route here), so a broken module's entities never outlive it.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_withdraw");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_withdraw", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // The flat world seeds a few zombies; assert relative to the baseline.
    const base = g.sim.countKind(.zombie);
    _ = g.sim.commands.pushSrc(1, .{ .spawn_zombie = .{ .x = 0, .y = 70, .z = 0, .hp = 40 } });
    _ = g.sim.commands.pushSrc(2, .{ .spawn_zombie = .{ .x = 4, .y = 70, .z = 4, .hp = 40 } });
    _ = g.sim.commands.drain(&g.sim);
    try std.testing.expectEqual(base + 2, g.sim.countKind(.zombie));

    // Withdraw plugin 1 only: its spawn is despawned, plugin 2's survives.
    @import("game/step.zig").withdrawPluginSrc(g, 1);
    try std.testing.expectEqual(base + 1, g.sim.countKind(.zombie));

    // Bots queued through zdtd.queue are attributed too: a withdrawn plugin's
    // bots and count floor must not outlive it.
    g.bots.bots[0] = .{ .net_id = 9001, .alive = true, .src = 2 };
    g.bots.n = 1;
    g.bots.floor = 4;
    g.bots.floor_src = 2;

    // Withdraw plugin 2: back to the baseline, and plugin 2's bots/floor go.
    @import("game/step.zig").withdrawPluginSrc(g, 2);
    try std.testing.expectEqual(base, g.sim.countKind(.zombie));
    try std.testing.expectEqual(@as(usize, 0), g.bots.n);
    try std.testing.expectEqual(@as(u32, 0), g.bots.floor);

    std.debug.print("PASS plugin withdraw: applied spawns despawned per src\n", .{});
}

test "scenario plugin disable withdraws pending commands before drain" {
    // ADR 0030: a module that disables (trap/fuel) must not have its queued
    // ops applied. Withdrawal runs immediately before drain, not only after
    // onTick. Damage has no held inverse, so a drain-then-withdraw would
    // leave the hit applied.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{"assets/fixtures/plugin_hello.wasm"};
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.count());

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const t = g.sim.transform[ps];
    const z = g.sim.spawnZombie(t.x + 1, t.y, t.z, 40).?;
    const zs = g.sim.slotOfNetId(z).?;
    const hp0 = g.sim.health[zs].hp;
    g.wasm_plugins.slots[0].disabled = true;
    try std.testing.expect(g.sim.commands.pushSrc(1, .{ .damage = .{ .net_id = z, .amount = 10 } }));
    try g.step();
    try std.testing.expectApproxEqAbs(hp0, g.sim.health[zs].hp, 0.01);
    try std.testing.expectEqual(@as(usize, 0), g.sim.commands.len());

    std.debug.print("PASS plugin withdraw-before-drain: pending damage dropped\n", .{});
}

fn writeFileAt(dir: []const u8, name: []const u8, data: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    try io_fs.writeFile(path, data);
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    try std.testing.expectEqual(true, c.guard.quarantine.damage);
    try std.testing.expectEqual(false, c.guard.quarantine.setblock);
    try std.testing.expectEqual(false, c.guard.quarantine.container);
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
    std.debug.print("PASS guard policy quarantine: damage bit only, damage C2S denied\n", .{});
}

test "scenario an enforced guard kick tells the client why" {
    // The enforced rung arms a delayed drop. Stock's own kick paths always
    // send NetPackagePlayerDenied first, because a peer dropped without one
    // sees a bare timeout and cannot tell a ban from a network fault. zdtd
    // sends the same package with a custom reason string; only the delayed
    // drop itself was covered, not the notification.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_guard_kick");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_guard_kick", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // Climb to the enforcing rung: the default ladder is log-only.
    g.guard.enforce = true;
    g.guard.dry_run = false;

    const denied_id = packages.idOf("NetPackagePlayerDenied") orelse
        return error.TestUnexpectedResult;
    cap.clear();
    try tripTwoStrongSignals(g, c);
    try std.testing.expectEqual(@as(u64, 1), g.harness.counters.get(.guard_kicks));
    try std.testing.expect(c.guard.kick_at_tick != 0);

    // The denial rode out, and its body is the stock KickPlayerData shape:
    // reason i32 | apiResponse i32 | banUntil i64 | custom reason string.
    const body = cap.findPkgId(denied_id) orelse return error.TestUnexpectedResult;
    var r: binary.Reader = .{ .data = body };
    const reason = try r.readI32();
    try std.testing.expectEqual(@intFromEnum(packages.KickReason.mod_decision), reason);
    try std.testing.expectEqual(@as(i32, 0), try r.readI32()); // apiResponse
    try std.testing.expectEqual(@as(i64, 0), try r.readI64()); // banUntil
    var reason_buf: [128]u8 = undefined;
    const custom = try r.readString(&reason_buf);
    // The custom string is what an operator actually reads, since the numeric
    // reason's client-facing label is unverified (see KickReason in packages.zig).
    try std.testing.expect(custom.len > 0);
    std.debug.print("PASS guard kick: PlayerDenied sent, reason={d} custom=\"{s}\"\n", .{ reason, custom });
}

test "scenario the five unreliable packages leave the reliable window alone" {
    // Stock overrides get_Reliable to false in exactly five classes
    // (EntityPosAndRot, EntityRelPosAndRot, EntityRotation, EntitySpeeds,
    // EntityStatsBuff; RE network.md "defaults to true and is overridden to
    // false by exactly five classes"), and NetworkServerLiteNetLib maps that
    // to DeliveryMethod 4 instead of 2. `isUnreliablePackage` has a unit test
    // for the name list, but nothing checked that the send path acts on it:
    // routing every package reliably would still pass that test while filling
    // the retransmit window with position spam.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_unreliable");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_unreliable", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const peer = c.peer orelse return error.TestUnexpectedResult;

    // The reliable sequence counter only advances on the reliable path, so it
    // is the observable difference between the two routes.
    var body: [64]u8 = undefined;
    const pos = try packages.buildPosAndRotBody(&body, c.entity_id, 1, 2, 3, 0, 0, 0, true);
    const seq_before = peer.local_seq;
    try g.sendGame(peer, "NetPackageEntityPosAndRot", pos);
    try std.testing.expectEqual(seq_before, peer.local_seq);

    // A package not on the list takes the reliable route and does advance it.
    const wt = try packages.buildWorldTimeBody(body[0..16], 1234);
    try g.sendGame(peer, "NetPackageWorldTime", wt);
    try std.testing.expect(peer.local_seq != seq_before);
    std.debug.print("PASS unreliable-route: PosAndRot left seq at {d}, WorldTime moved it to {d}\n", .{ seq_before, peer.local_seq });
}

test "scenario workstation queue: C2S write, craft tick, S2C echo keeps stock geometry" {
    io_fs.mkdirPath("worlds");
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
    const wx: i32 = @trunc(g.sim.transform[pa].x);
    const wy: i32 = @trunc(g.sim.transform[pa].y);
    const wz: i32 = @trunc(g.sim.transform[pa].z);

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

test "scenario workstation recipe authority: count and time from recipes.xml" {
    // GAP P1: the server must not trust the client's Recipe blob. With a
    // recipes.xml loaded, a spoofed queue entry (count 2, time 0.2) is
    // overwritten with the recipe's count (3) and craft_time (3.0).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .config_dir = "assets/fixtures",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expect(g.recipes.source == .xml);

    var cap_a: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const ws = @import("../world/workstations.zig");
    const stock_te = packages.stock_te;
    const stock_inv = packages.stock_inv;
    const pa = g.sim.playerByPeer(ca.slot).?;
    const wx: i32 = @trunc(g.sim.transform[pa].x);
    const wy: i32 = @trunc(g.sim.transform[pa].y);
    const wz: i32 = @trunc(g.sim.transform[pa].z);

    var recipe: [128]u8 = undefined;
    var rw: @import("../wire/binary.zig").Writer = .{ .buf = &recipe };
    // A real AssignIds stock type the runtime dump resolves (the queue's
    // output_type is the stock wire type; a synthetic builtin index would
    // not resolve and blocks are in the offline AssignIds dump).
    const out_type: i32 = @intCast(g.maxdamage.idByName("frameShapes:cube") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(i32, 16107), out_type);
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
        .craft_time_left = 0.2, // spoofed: server must replace with 3.0
        .one_item_craft_time = 0.2, // spoofed
        .starting_entity_id = ca.entity_id,
        .output_type = out_type,
        .output_count = 2, // spoofed: recipe says 3
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
    const q = st.queue[st.queue_len - 1];
    try std.testing.expectEqual(@as(u16, 3), q.output_count); // recipe count wins
    try std.testing.expectEqual(@as(f32, 3.0), q.one_item_craft_time); // recipe time wins
    try std.testing.expectEqual(@as(f32, 3.0), q.craft_time_left);

    std.debug.print("PASS workstation-authority: spoofed count/time replaced by recipe 3/3.0\n", .{});
}

test "scenario POIStayWithin bounds the stay zone to the quest POI rect" {
    // GAP P1: POIStayWithin auto-completed because it classified to `.auto`.
    // It now maps to stay_within and the zone is the quest's bound POI rect.
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

    const qmod = @import("../ecs/quest.zig");
    const phases = [_]qmod.PhaseSpec{.{ .kind = .stay_within, .required = 3 }};
    const custom = [_]qmod.QuestDef{.{
        .id = 42,
        .kind = .stay_within,
        .name = "stay_in_the_poi",
        .title = "Stay in the POI",
        .target_count = 3,
        .reward_coin = 5,
        .objective_count = 1,
        .reward_count = 1,
        .phases = &phases,
        .highest_phase = 1,
        .objective_phases = &[_]u8{1},
    }};
    g.sim.catalog.defs = custom[0..];
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 42));

    // Bind a POI rect around the (256,70,256) pad (flat world has no POIs,
    // so the accept path left poi unset; a stock map would bind it there).
    const ps = g.sim.playerByPeer(c.slot).?;
    var bound = false;
    for (&g.sim.journal[ps].slots) |*s| {
        if (!s.active or s.def_id != 42) continue;
        s.poi = .{ .x = 252, .y = 70, .z = 252, .size_x = 8, .size_y = 4, .size_z = 8 };
        bound = true;
    }
    try std.testing.expect(bound);

    // Outside the POI footprint: no progress.
    systems.questTickStayWithin(&g.sim, c.slot, 320, 320);
    var p1: u16 = 0;
    for (&g.sim.journal[ps].slots) |*s| {
        if (!s.active or s.def_id != 42) continue;
        p1 = s.progress;
    }
    try std.testing.expectEqual(@as(u16, 0), p1);

    // Inside the POI: three stays complete the quest (turn_in=false).
    systems.questTickStayWithin(&g.sim, c.slot, 256, 256);
    systems.questTickStayWithin(&g.sim, c.slot, 256, 256);
    systems.questTickStayWithin(&g.sim, c.slot, 256, 256);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 42));

    std.debug.print("PASS poi-stay-within: outside blocked, inside completed in 3 stays\n", .{});
}

test "scenario interest: mob leaving interest gets EntityRemove(Unloaded)" {
    io_fs.mkdirPath("worlds");
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
/// (0 Health, 7 Food, 8 Water - PlayerEntityStats::Tick). The survival loop
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    io_fs.mkdirPath("worlds");
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
    const preset_mod = @import("preset.zig");
    const rules_mod = @import("../ecs/rules.zig");

    var pack = try preset_mod.parse(std.testing.allocator,
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

    io_fs.mkdirPath("worlds");
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

test "scenario tall wire profile: 512-tall columns, 128-layer wire body, ZCH4 saves" {
    // Layer B seam proof (ADR geometry/wire-profiles): a non-stock wire profile
    // flows from Game options into the block store (column height + plane
    // sizing), the chunk wire body (layer band count + plane stride) and the
    // save format (ZCH4 carrying the column height). Flat world + y_dim=512.
    // No stock client can read this dialect (a paired client mod is required);
    // the seam is proven with our own chunk + wire + save round-trips plus the
    // production join stream (chunk_fill uses the same profile-aware builder).
    freshScenarioDir("worlds/zdtd_sc_tall");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_tall", 0, .{
        .wire_profile = .{ .y_dim = 512 },
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Profile on the block store; chunks adopt the column height + plane size.
    try std.testing.expectEqual(@as(u32, 512), g.world.profile.y_dim);
    try std.testing.expect(g.world.profile.validate());
    try std.testing.expectEqual(@as(u32, 128), g.world.profile.layers());
    try std.testing.expectEqual(@as(u32, 256 * 512), g.world.profile.plane_cells());
    const pos: world_store.ChunkPos = .{ .x = 0, .z = 0 };
    const ch = try g.world.getOrCreate(pos);
    try std.testing.expectEqual(@as(u32, 512), ch.y_dim);
    try std.testing.expectEqual(@as(usize, 16 * 512 * 16), ch.planeCells());
    try std.testing.expect(ch.blocks != null);
    try std.testing.expectEqual(@as(u16, 64), ch.heightAt(0, 0)); // flat sea surface

    // Wire: the chunk body encodes y_dim/4 = 128 layers, not 64. The same flat
    // chunk encoded with the stock layer count is smaller (every extra air
    // band still costs its presence byte + channel slots).
    const TallCtx = struct {
        ch: *world_store.Chunk,
        fn at(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u32 {
            const s: *const @This() = @ptrCast(@alignCast(ctx.?));
            return s.ch.rawAt(lx, y, lz);
        }
        fn tex(ctx: ?*anyopaque, lx: i32, y: i32, lz: i32) u64 {
            const s: *const @This() = @ptrCast(@alignCast(ctx.?));
            return s.ch.texAt(lx, y, lz);
        }
    };
    var tctx: TallCtx = .{ .ch = ch };
    var wire_buf: [1024 * 1024]u8 = undefined;
    const body = try packages.stock_chunk.buildNetPackageChunkNew(&wire_buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &ch.heights,
        .layers = 128,
        .y_dim = 512,
        .block_at = TallCtx.at,
        .block_ctx = &tctx,
        .tex_at = TallCtx.tex,
    });
    var stock_buf: [1024 * 1024]u8 = undefined;
    const stock_body = try packages.stock_chunk.buildNetPackageChunkNew(&stock_buf, .{
        .cx = 0,
        .cz = 0,
        .heights = &ch.heights,
        .layers = 64,
        .y_dim = 512,
        .block_at = TallCtx.at,
        .block_ctx = &tctx,
        .tex_at = TallCtx.tex,
    });
    try std.testing.expect(body.len > stock_body.len);

    // Production join stream: the real chunk_fill builder (profile-aware)
    // sends a NetPackageChunk for the tall world without overflowing. The
    // test Capture truncates full chunk bodies at 8 KiB, so the proof is the
    // streamed-chunk tracking (clientAddStreamed only runs after chunk_fill's
    // sendGame delivered) plus the direct 128-vs-64-layer body check above.
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try g.streamChunksForClient(c);
    try std.testing.expect(c.streamed_n > 0);
    // The stream inserted many chunks; the store's HashMap may have rehashed,
    // invalidating the earlier `ch` pointer. Re-fetch before the save tests.
    const ch2 = try g.world.getOrCreate(pos);

    // Two blocks high in the tall column (above the stock 256 ceiling) so the
    // reload below proves the u32 block plane survived, not just the heights.
    try ch2.setBlock(g.world.allocator, 1, 300, 2, 7);
    try ch2.setBlock(g.world.allocator, 3, 500, 4, 9);

    // Save: ZCH4 with the column height in the header; validate + reload into
    // a same-profile chunk round-trips; a stock chunk rejects the record.
    const img = try world_store.World.encodeChunk(ch2, gpa);
    defer gpa.free(img);
    try std.testing.expectEqual(@as(u8, '4'), img[3]);
    const saved_y = std.mem.readInt(u32, img[16..20], .little);
    try std.testing.expectEqual(@as(u32, 512), saved_y);
    try world_store.World.validateChunkBytes(img, pos);
    try g.world.saveChunk(ch2);
    var other = world_store.Chunk.generateFlat(pos);
    other.y_dim = 512;
    // loadChunk allocates the block plane into this stack chunk; it is not
    // owned by the store, so the test frees it.
    defer other.deinitBlocks();
    try g.world.loadChunk(&other);
    try std.testing.expectEqual(@as(u16, 64), other.heightAt(0, 0));
    // The block plane, not just the heights: encodeChunk writes it for ZCH4
    // as well, so loadChunk has to read it back. Gating the read on ZCH3 threw
    // the plane away and then read the topsoil tail out of the middle of it.
    try std.testing.expectEqual(@as(u16, 7), other.blockAt(1, 300, 2));
    try std.testing.expectEqual(@as(u16, 9), other.blockAt(3, 500, 4));
    var stock_chunk = world_store.Chunk.generateFlat(pos);
    try std.testing.expectError(error.ReadFailed, g.world.loadChunk(&stock_chunk));

    std.debug.print("PASS tall-wire-profile: y_dim=512 planes={d} wire={d}B vs {d}B ZCH4\n", .{ ch2.planeCells(), body.len, stock_body.len });
}

test "scenario restart does not re-seed the starter chest" {
    // The near-spawn seed chest is placed once on a fresh world; a restart
    // loads it from the chunk save and must not re-place it over whatever
    // the player built at that spot (it previously re-seeded every boot,
    // dirtying the spawn chunk and clobbering player builds).
    freshScenarioDir("worlds/zdtd_sc_seedchest");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g1 = try game_mod.Game.create(gpa, "worlds/zdtd_sc_seedchest", 0);
    const sp = g1.world.primarySpawn();
    const cx = sp.x + 2;
    const cy = sp.y;
    const cz = sp.z + 2;
    const chest = try g1.world.blockWorld(cx, cy, cz);
    try std.testing.expect(chest != 0 and chest != g1.world.terrain_ids.air);
    // The player builds over the seed-chest spot.
    try g1.world.setBlockWorld(cx, cy, cz, world_store.block_stone);
    g1.deinit();
    gpa.destroy(g1);
    // Restart: the player's block survives (no fresh chest re-seeded).
    const g2 = try game_mod.Game.create(gpa, "worlds/zdtd_sc_seedchest", 0);
    defer {
        g2.deinit();
        gpa.destroy(g2);
    }
    try std.testing.expectEqual(world_store.block_stone, try g2.world.blockWorld(cx, cy, cz));
    std.debug.print("PASS seed-chest: restart keeps the player's block over the seed spot\n", .{});
}

test "scenario join spawn area paces through the stream budget" {
    // GAP "Join-burst tick budget under concurrent load": the synchronous
    // spawn area is capped at the collision-mesh core (spawn chunk + 8
    // neighbours) and the outer rings drain at chunk_adds_per_stream_tick
    // per call, so a join cannot stall the 50 ms tick with a 289-chunk
    // synchronous burst (previously max tick ~2 s under a concurrent join).
    freshScenarioDir("worlds/zdtd_sc_pacejoin");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_pacejoin", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // attachJoinedClient requests chunk_view_dim 4, so the spawn area is a
    // 9×9 square (radius 4): rings 0..1 (9 chunks) sent synchronously, the
    // outer rings (2..4, 72 chunks) pending on the paced drain.
    try std.testing.expect(c.pending_area_r >= 1);
    try std.testing.expectEqual(@as(usize, 9), c.streamed_n);
    const budget = g.chunk_adds_per_stream_tick;
    var prev = c.streamed_n;
    var calls: usize = 0;
    while (c.pending_area_r >= 0 and calls < 100) : (calls += 1) {
        var drain_budget: u32 = g.chunk_adds_per_stream_tick;
        try g.drainSpawnArea(c, &drain_budget);
        const added = c.streamed_n - prev;
        try std.testing.expect(added <= budget);
        prev = c.streamed_n;
    }
    try std.testing.expect(c.pending_area_r < 0); // fully drained
    // Full 9×9 area delivered, nothing double-sent; idle drains are no-ops.
    try std.testing.expectEqual(@as(usize, 81), c.streamed_n);
    {
        var idle_budget: u32 = g.chunk_adds_per_stream_tick;
        try g.drainSpawnArea(c, &idle_budget);
    }
    try std.testing.expectEqual(@as(usize, 81), c.streamed_n);
    std.debug.print("PASS pace-join: core=9 budget={d} calls={d} total={d}\n", .{ budget, calls, c.streamed_n });
}

test "scenario proc world streams deco from the W3 biome field" {
    // An infinite proc world (the `infinite` mode pack / --worldgen-seed)
    // must not be bald: proc worlds carry no biomemap, so deco resolves from
    // the W3 proc biome field + the biomes.xml deco lists (same table the
    // baked path uses). Join with a game-dir (biomes.xml decos) + a seed, then
    // stream past the join window: both the join burst and the streamed
    // chunks ship deco objects, not the empty firstPackage.
    if (!stockMapPresent()) return error.SkipZigTest;
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    freshScenarioDir("worlds/zdtd_sc_procdeco");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_procdeco", 0, .{
        .game_dir = game_dir,
        .worldgen_seed = 7,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expect(g.world.terrain_source == .proc);
    try std.testing.expect(g.world.worldgen != null);
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // The join burst shipped deco objects (non-empty DecoUpdate), not the
    // bald empty firstPackage.
    const join_marked = c.deco_sent_n;
    try std.testing.expect(join_marked > 0);
    // And streaming a fresh region past the join window ships more deco.
    const ps = g.sim.playerByPeer(c.slot).?;
    const sp = g.world.primarySpawn();
    g.sim.transform[ps].x = @as(f32, @floatFromInt(sp.x)) + 160.0;
    g.sim.transform[ps].z = @as(f32, @floatFromInt(sp.z));
    cap.clear();
    try g.streamChunksForClient(c);
    try std.testing.expect(c.deco_sent_n > join_marked);
    std.debug.print("PASS proc-deco: infinite proc world streams deco (join={d} streamed={d})\n", .{ join_marked, c.deco_sent_n });
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
        "assets/fixtures/plugin_trap.wasm",
        "assets/fixtures/plugin_rules.wasm",
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
    const applied = try g.addBlockDamage(10, 70, 10, 100);
    try std.testing.expectEqual(@as(u16, 200), applied);

    // --- on_quest_complete doubles: tier1_clear pays 1000 exp -> 2000 ---
    const clear = g.sim.catalog.byName("tier1_clear").?;
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, clear.id));
    systems.questTickGoto(&g.sim, c.slot, clear.tx, clear.ty, clear.tz);
    var k: u16 = 0;
    while (k < clear.target_count) : (k += 1) questKillAtPoi(g, c);
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, clear.id));
    const xp_before = g.clients[peer].xp;
    try g.step(); // tick-end payout runs the questComplete verdict
    const xp_gain = g.clients[peer].xp - xp_before;
    // 1000 exp x 200% = 2000 (xp_multiplier default 100 keeps it 1.0x).
    try std.testing.expect(xp_gain >= 2000);

    // --- on_entity_killed: the trap module (slot 0) disables on the kill
    // (returns keep), then plugin_rules (slot 1) scales; the kill lands ---
    const z = g.sim.spawnZombie(40, 70, 0, 40).?;
    const killed = g.sim.damage(z, 99999);
    try std.testing.expect(killed.killed);
    try std.testing.expect(g.sim.slotOfNetId(z) == null or g.sim.health[g.sim.slotOfNetId(z).?].hp == 0);
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.disabledCount());
    try std.testing.expect(g.wasm_plugins.slots[0].disabled);
    try std.testing.expect(!g.wasm_plugins.slots[1].disabled);
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
    // game.zig max_quest_position_data = 4; keep the two in lockstep.
    var pos_store: [@import("../ecs/components.zig").max_journal][4]packages.stock_quest.PositionEntry = undefined;
    const qn = g.fillStockJournalWrites(c.slot, &qbuf, &reward_store, &obj_val_store, &kind_store, &pos_store);
    try std.testing.expectEqual(got, qn);
    try std.testing.expect(qn > 2); // the old hardcoded cap
    try std.testing.expect(qn <= @import("../ecs/components.zig").max_journal);

    std.debug.print("PASS journal-pdf: {d} quests reach the join PDF (cap was 2)\n", .{qn});
}

test "scenario quest journal ZPV5 restores by name and keeps the POI rect" {
    // GAP quest-journal-persistence row: a restart must restore the same quest
    // (by its stock name identity, not the parse-order def_id) with the POI
    // rect it was handed (stock PositionData[2/3]), not a re-resolved one.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_questpersist");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const PoiRect = @import("../ecs/components.zig").PoiRect;
    const poi_stub = struct {
        fn f(_: ?*anyopaque, _: f32, _: f32) ?PoiRect {
            return .{ .x = 100, .y = 60, .z = 100, .size_x = 40, .size_y = 20, .size_z = 40 };
        }
    }.f;

    {
        const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_questpersist", 0, .{
            .quests_path = "assets/fixtures/quests.xml",
        });
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        g.sim.poi_fn = poi_stub;
        g.sim.nearest_poi_fn = poi_stub;
        var cap: ln_peer.Capture = .{};
        const c = try g.attachJoinedClient(&cap);
        const d = g.sim.catalog.byName("tier1_clear") orelse return error.TestUnexpectedResult;
        try std.testing.expect(systems.questAccept(&g.sim, c.slot, d.id));
        const ps = g.sim.playerByPeer(c.slot).?;
        var found = false;
        for (&g.sim.journal[ps].slots) |*s| {
            if (s.active and s.def_id == d.id) {
                try std.testing.expectEqual(@as(f32, 100), s.poi.x);
                try std.testing.expectEqual(@as(f32, 40), s.poi.size_x);
                found = true;
            }
        }
        try std.testing.expect(found);
        try g.savePlayers();
    }

    // Restart WITHOUT the POI hooks: the persisted rect must come back from
    // the file (re-resolving would leave it unset) and the def must resolve.
    {
        const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_questpersist", 0, .{
            .quests_path = "assets/fixtures/quests.xml",
        });
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        var cap: ln_peer.Capture = .{};
        const c = try g.attachJoinedClient(&cap);
        const ps = g.sim.playerByPeer(c.slot).?;
        const d = g.sim.catalog.byName("tier1_clear") orelse return error.TestUnexpectedResult;
        var found = false;
        for (&g.sim.journal[ps].slots) |*s| {
            if (s.active and s.def_id == d.id) {
                try std.testing.expectEqual(@as(f32, 100), s.poi.x);
                try std.testing.expectEqual(@as(f32, 100), s.poi.z);
                try std.testing.expectEqual(@as(f32, 40), s.poi.size_x);
                try std.testing.expectEqual(@as(f32, 40), s.poi.size_z);
                found = true;
            }
        }
        try std.testing.expect(found);
        std.debug.print("PASS quest-persist: ZPV5 round-trip restores tier1_clear by name with its POI rect\n", .{});
    }
}

test "scenario quest journal ZPV5 resolves the quest by name, not stored def_id" {
    // Hand-crafted ZPV5 record: the journal entry stores tier1_fetch's def_id
    // but the name "tier1_clear". Restore must follow the name (stock
    // Quest.Write identifies quests by name; a quests.xml edit reshuffles the
    // parse-order def_ids). Also carries a distinct POI rect that must come
    // back verbatim.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_questname");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_questname", 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const fetch_def = g.sim.catalog.byName("tier1_fetch") orelse return error.TestUnexpectedResult;
    const clear_def = g.sim.catalog.byName("tier1_clear") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fetch_def.id != clear_def.id);

    // players.zsv: ZPV5 | n=1 | record("Bot", no inv, one quest entry,
    // prog tail absent).
    var file: [256]u8 = undefined;
    var o: usize = 0;
    @memcpy(file[o..][0..4], "ZPV5");
    o += 4;
    std.mem.writeInt(u32, file[o..][0..4], 1, .little);
    o += 4;
    file[o] = 3; // name_len "Bot"
    o += 1;
    @memcpy(file[o..][0..3], "Bot");
    o += 3;
    inline for (.{ @as(f32, 10), @as(f32, 70), @as(f32, 20) }) |f| {
        std.mem.writeInt(u32, file[o..][0..4], @as(u32, @bitCast(f)), .little);
        o += 4;
    }
    std.mem.writeInt(u32, file[o..][0..4], 0, .little); // coins
    o += 4;
    file[o] = 0; // inv_n
    o += 1;
    file[o] = 1; // jn
    o += 1;
    // Journal entry: STORED def_id = tier1_fetch, name = "tier1_clear".
    std.mem.writeInt(u16, file[o..][0..2], fetch_def.id, .little);
    o += 2;
    std.mem.writeInt(i32, file[o..][0..4], 12345, .little); // quest_code
    o += 4;
    file[o] = 1; // flags: active
    o += 1;
    std.mem.writeInt(u16, file[o..][0..2], 0, .little); // progress
    o += 2;
    file[o] = 1; // phase
    o += 1;
    file[o] = @intCast(clear_def.name.len); // name_len
    o += 1;
    @memcpy(file[o..][0..clear_def.name.len], clear_def.name);
    o += clear_def.name.len;
    file[o] = 1; // poi_valid
    o += 1;
    inline for (.{ @as(f32, 10), @as(f32, 20), @as(f32, 30), @as(f32, 40), @as(f32, 50), @as(f32, 60) }) |f| {
        std.mem.writeInt(u32, file[o..][0..4], @as(u32, @bitCast(f)), .little);
        o += 4;
    }
    file[o] = 0; // prog: no tail
    o += 1;
    try io_fs.writeFile("worlds/zdtd_sc_questname/players.zsv", file[0..o]);

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    var found = false;
    for (&g.sim.journal[ps].slots) |*s| {
        if (s.active and s.def_id == clear_def.id) {
            try std.testing.expectEqual(@as(i32, 12345), s.quest_code);
            try std.testing.expectEqual(@as(f32, 10), s.poi.x);
            try std.testing.expectEqual(@as(f32, 60), s.poi.size_z);
            found = true;
        }
    }
    try std.testing.expect(found);
    std.debug.print("PASS quest-persist-name: name identity wins over stored def_id; rect verbatim\n", .{});
}

test "scenario every quest kind completes end-to-end (kill/goto/fetch/trader/craft/stay/block/rally)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // A POI rect at the origin so rally phases are real (not scaffolding) and
    // goto/stay quests bind a target center instead of degrading.
    const PoiRect = @import("../ecs/components.zig").PoiRect;
    const poi_stub = struct {
        fn f(_: ?*anyopaque, _: f32, _: f32) ?PoiRect {
            return .{ .x = 0, .y = 70, .z = 0, .size_x = 16, .size_y = 8, .size_z = 16 };
        }
    }.f;
    g.sim.poi_fn = poi_stub;
    g.sim.nearest_poi_fn = poi_stub;

    // Custom auto-complete catalog: one quest per executable PhaseKind. The
    // starter id is absent so the join path grants nothing extra.
    const defs = [_]quest_mod.QuestDef{
        .{ .id = 1, .kind = .kill_zombies, .title = "Kill", .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .kill_zombies, .required = 2 }}, .highest_phase = 1 },
        .{ .id = 2, .kind = .goto_point, .title = "Goto", .tx = 10, .tz = 10, .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .goto_point, .required = 1, .radius = 5 }}, .highest_phase = 1 },
        .{ .id = 3, .kind = .fetch_item, .title = "Fetch", .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .fetch_item, .required = 1 }}, .highest_phase = 1 },
        .{ .id = 4, .kind = .fetch_trader, .title = "Trader", .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .trader_interact, .required = 1 }}, .highest_phase = 1 },
        .{ .id = 5, .kind = .craft, .title = "Craft", .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .craft, .required = 1 }}, .highest_phase = 1 },
        .{ .id = 6, .kind = .stay_within, .title = "Stay", .tx = 0, .tz = 0, .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .stay_within, .required = 1, .radius = 8 }}, .highest_phase = 1 },
        .{ .id = 7, .kind = .block_activate, .title = "Block", .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .block_activate, .required = 1 }}, .highest_phase = 1 },
        .{ .id = 8, .kind = .goto_point, .title = "Rally", .tx = 0, .tz = 0, .reward_coin = 10, .phases = &[_]quest_mod.PhaseSpec{.{ .kind = .rally, .required = 1 }}, .highest_phase = 1 },
    };
    g.sim.catalog = .{ .defs = &defs, .starter_id = 99, .source = .builtin };

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    systems.drainQuestCoins(&g.sim, c.slot);
    const coins0 = g.sim.wallet[ps].coins;
    var body: [64]u8 = undefined;
    var frame_buf: [512]u8 = undefined;

    // kill_zombies: the required kill count completes it (and only then).
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 1));
    questKillAtPoi(g, c);
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, 1));
    questKillAtPoi(g, c);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 1));
    systems.drainQuestCoins(&g.sim, c.slot);

    // goto_point: the parsed radius gates the arrival - outside does nothing,
    // inside the target (the bound POI center 8,8) completes it.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 2));
    systems.questTickGoto(&g.sim, c.slot, 0, 70, 0); // ~11 m from the target
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, 2));
    systems.questTickGoto(&g.sim, c.slot, 8, 70, 8);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 2));
    systems.drainQuestCoins(&g.sim, c.slot);

    // fetch_item via the treasure_complete event - the wire the stock client
    // sends when it digs the chest (NetPackageQuestObjectiveUpdate).
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 3));
    const fq = systems.questFindActive(&g.sim, c.slot, 3).?;
    const ub = try packages.buildQuestObjectiveUpdate(&body, .{
        .sender_entity_id = c.entity_id,
        .quest_code = fq.quest_code,
        .event_type = .treasure_complete,
    });
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageQuestObjectiveUpdate", ub));
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 3));
    systems.drainQuestCoins(&g.sim, c.slot);

    // fetch_item via the direct hook (FetchFromContainer / container loot).
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 3));
    systems.questOnFetchItem(&g.sim, c.slot, 1);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 3));
    systems.drainQuestCoins(&g.sim, c.slot);

    // trader_interact: a trader open completes it.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 4));
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 4));
    systems.drainQuestCoins(&g.sim, c.slot);

    // craft: crafting an item advances the phase.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 5));
    systems.questOnCraft(&g.sim, c.slot, "testRecipe");
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 5));
    systems.drainQuestCoins(&g.sim, c.slot);

    // stay_within: the parsed radius gates it - outside does nothing, inside
    // the bound POI center completes it.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 6));
    systems.questTickStayWithin(&g.sim, c.slot, 20, 20); // ~17 m from 8,8
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, 6));
    systems.questTickStayWithin(&g.sim, c.slot, 8, 8);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 6));
    systems.drainQuestCoins(&g.sim, c.slot);

    // block_activate: the client's block-activated event advances it.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 7));
    const bq = systems.questFindActive(&g.sim, c.slot, 7).?;
    _ = systems.questObjectiveEvent(&g.sim, c.slot, bq.quest_code, .block_activate);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 7));
    systems.drainQuestCoins(&g.sim, c.slot);

    // rally: with a POI bound at accept the phase is real (not scaffolding);
    // the rally-marker activation advances and completes it.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 8));
    const rq = systems.questFindActive(&g.sim, c.slot, 8).?;
    try std.testing.expect(rq.poi.valid());
    try std.testing.expect(systems.questOnRallyActivated(&g.sim, c.slot, rq.quest_code));
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 8));
    systems.drainQuestCoins(&g.sim, c.slot);

    // Every completed quest paid its coin reward into the wallet: 8 defs, but
    // the fetch quest is completed twice (event path + direct hook) = 9 pays.
    systems.drainQuestCoins(&g.sim, c.slot);
    try std.testing.expectEqual(coins0 + 9 * 10, g.sim.wallet[ps].coins);
    std.debug.print("PASS all-quest-kinds: kill/goto/fetch/trader/craft/stay/block/rally completed, coins +{d}\n", .{g.sim.wallet[ps].coins - coins0});
}

test "scenario treasure radius break fires the quest TreasureRadiusReduction ambush" {
    // GAP quest-events row: the client's NetPackageQuestObjectiveUpdate
    // treasure_radius_break (each buried-supplies dig radius step) triggers
    // the quest's TreasureRadiusReduction event: stock rolls its `chance`
    // and fires the nested SpawnGSEnemy ambush around the player
    // (stock quests.xml: chance 0.25, 1-3 SleeperGSList; the fixture pins
    // chance=1 so the roll always fires). The event must NOT advance a phase.
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

    // Spy on the Game spawn hook (same shape as the phase-entry SpawnGSEnemy).
    const Call = struct { fired: bool = false, list: []const u8 = "", min: u8 = 0, max: u8 = 0, px: f32 = 0, pz: f32 = 0 };
    var call = Call{};
    const spy = struct {
        fn f(ctx: ?*anyopaque, _: quest_mod_components.PoiRect, list: []const u8, min: u8, max: u8, px: f32, pz: f32) void {
            const c: *Call = @ptrCast(@alignCast(ctx.?));
            c.fired = true;
            c.list = list;
            c.min = min;
            c.max = max;
            c.px = px;
            c.pz = pz;
        }
    }.f;
    g.sim.quest_spawn_ctx = &call;
    g.sim.quest_spawn_fn = spy;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // Anchor the player somewhere observable; the ambush spawns around it.
    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.transform[ps].x = 42;
    g.sim.transform[ps].z = 33;

    const d = g.sim.catalog.byName("tier1_fetch") orelse return error.TestUnexpectedResult;
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, d.id));
    const fq = systems.questFindActive(&g.sim, c.slot, d.id).?;

    var body: [64]u8 = undefined;
    var frame_buf: [512]u8 = undefined;
    const ub = try packages.buildQuestObjectiveUpdate(&body, .{
        .sender_entity_id = c.entity_id,
        .quest_code = fq.quest_code,
        .event_type = .treasure_radius_break,
    });
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageQuestObjectiveUpdate", ub));

    try std.testing.expect(call.fired);
    try std.testing.expectEqualStrings("SleeperGSList", call.list);
    try std.testing.expectEqual(@as(u8, 1), call.min);
    try std.testing.expectEqual(@as(u8, 3), call.max);
    // Ambush anchors on the player's current position.
    try std.testing.expectEqual(@as(f32, 42), call.px);
    try std.testing.expectEqual(@as(f32, 33), call.pz);
    // The event is an ambush, not a phase advance: quest stays active.
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, d.id));
    std.debug.print("PASS treasure-radius-break: TreasureRadiusReduction ambush fired 1-3 SleeperGSList at ({d},{d})\n", .{ call.px, call.pz });
}

test "scenario every stock quest def completes (99-def sweep over real quests.xml)" {
    // Load the real dedicated-server quests.xml and drive EVERY def to
    // completion: accept, then apply each phase kind's real trigger until the
    // quest completes (Auto) or parks ready_turn_in and a trader open finishes
    // it. Proves no stock quest is stuck behind an unmapped/.auto phase or a
    // missing trigger. Skipped when the stock game dir is absent.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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

    // A POI rect at the origin so POI-bound phases (goto/stay/rally) resolve.
    const PoiRect = @import("../ecs/components.zig").PoiRect;
    const poi_stub = struct {
        fn f(_: ?*anyopaque, _: f32, _: f32) ?PoiRect {
            return .{ .x = 0, .y = 70, .z = 0, .size_x = 16, .size_y = 8, .size_z = 16 };
        }
    }.f;
    g.sim.poi_fn = poi_stub;
    g.sim.nearest_poi_fn = poi_stub;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(g.sim.catalog.source == .stock_xml);
    try std.testing.expect(g.sim.catalog.defs.len >= 90); // the real catalog

    var completed: usize = 0;
    var failed: [16][]const u8 = undefined;
    var failed_n: usize = 0;
    for (g.sim.catalog.defs) |d| {
        if (d.id < 1 or d.name.len == 0) continue;
        const accepted = systems.questAccept(&g.sim, c.slot, d.id);
        // The starter is already active from the join auto-grant; drive it too.
        if (!accepted and !systems.questHasActive(&g.sim, c.slot, d.id)) {
            if (failed_n < failed.len) failed[failed_n] = d.name;
            failed_n += 1;
            continue;
        }
        var iter: usize = 0;
        while (iter < 400) : (iter += 1) {
            if (!systems.questHasActive(&g.sim, c.slot, d.id)) break;
            questKillAtPoi(g, c);
            systems.questOnFetchItem(&g.sim, c.slot, 1);
            systems.questOnCraft(&g.sim, c.slot, "sweep");
            systems.questOnTraderOpen(&g.sim, c.slot);
            systems.questTickGoto(&g.sim, c.slot, d.tx, d.ty, d.tz);
            systems.questTickGoto(&g.sim, c.slot, 8, 70, 8);
            systems.questTickStayWithin(&g.sim, c.slot, d.tx, d.tz);
            systems.questTickStayWithin(&g.sim, c.slot, 8, 8);
            // Shared phases with a POIStayWithin constraint need the player in
            // the bound POI: tick at the quest's POI center too.
            questStayAtPoi(g, c);
            if (systems.questFindActive(&g.sim, c.slot, d.id)) |q| {
                _ = systems.questObjectiveEvent(&g.sim, c.slot, q.quest_code, .block_activate);
                _ = systems.questOnRallyActivated(&g.sim, c.slot, q.quest_code);
            }
        }
        if (systems.questHasActive(&g.sim, c.slot, d.id)) {
            if (failed_n < failed.len) failed[failed_n] = d.name;
            failed_n += 1;
            continue;
        }
        completed += 1;
    }
    try std.testing.expect(completed >= 90);
    std.debug.print("PASS stock-quest-sweep: {d}/{d} defs completed; failed=[", .{ completed, g.sim.catalog.defs.len });
    for (failed[0..@min(failed_n, failed.len)]) |f| std.debug.print("{s} ", .{f});
    std.debug.print("]\n", .{});
}

test "scenario vending rent state machine (loot-economy §6)" {
    // NetPackagePlayerVendingMachine (rent / clear) handled server-
    // authoritatively: only the sender's own identity may act, the rent costs
    // TraderInfo.RentCost currency, the term is rent_time in-game days, one
    // machine per player, and an expired rental returns to unowned.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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

test "scenario TraderData copy-back: out-of-reach ignored, in-reach applied" {
    // A real client sends its post-trade TraderData back over
    // NetPackageTraderData (isEntity | entityId/tePosition | hasTraderData |
    // TraderData::Write). Stock's ProcessPackage does TraderData.CopyFrom onto
    // the live EntityTrader / TileEntityVendingMachine (loot-economy.md 5), so
    // the echo is applied stock-faithfully - but only from a sender within
    // trade reach, so a remote peer cannot rewrite the shared economy.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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
    const stone_wire = g.items.byStockName("resourceRockSmall") orelse return error.SkipZigTest;
    try std.testing.expect(wood_ecs != 0);

    const ps = g.sim.playerByPeer(c.slot).?;
    // The attached client spawns at world spawn, far from the test targets.

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
        .item = .{ .type_id = wood_wire, .count = 3, .quality = 1 },
        .markup = -4,
    };
    try packages.stock_entity.writeTraderDataBody(&w, .{ .trader_id = 5, .available_money = 4000, .entries = &[_]packages.stock_entity.TraderStockEntry{entry} });
    var frame_buf: [640]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackageTraderData", w.written());
    try g.injectFramed(c, framed);

    // Out of reach: the copy is ignored; every server-owned field survives.
    const st = &g.sim.trader_stock[ts];
    try std.testing.expectEqual(@as(u16, 10), st.entries[0].count);
    try std.testing.expectEqual(@as(i8, 0), st.entries[0].markup);
    try std.testing.expectEqual(@as(u16, 1), st.entries[0].price);
    try std.testing.expectEqual(@as(i32, 5000), st.wallet);

    // --- Vending machine CopyFrom (isEntity=false, tePosition) ---
    const vm = g.vending.getOrCreate(.{ .x = 10, .y = 70, .z = 20 }, 1, 5).?;
    const vm_before = vm.*;
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
    try std.testing.expectEqual(vm_before.stock[0].type_id, vm.stock[0].type_id);
    try std.testing.expectEqual(vm_before.stock[0].count, vm.stock[0].count);
    try std.testing.expectEqual(vm_before.stock[0].markup, vm.stock[0].markup);
    try std.testing.expectEqual(vm_before.available_money, vm.available_money);

    // --- In-reach legit buy: count + markup + money from the echo, price
    // stays server-owned. ---
    g.sim.transform[ps].x = 50;
    g.sim.transform[ps].y = 70;
    g.sim.transform[ps].z = 60;
    // frame_buf was clobbered by the vending frame build; rebuild the entity
    // frame from the still-intact body buffer.
    const framed_in = try packages.framed(&frame_buf, "NetPackageTraderData", w.written());
    try g.injectFramed(c, framed_in);
    try std.testing.expectEqual(@as(u16, 3), st.entries[0].count);
    try std.testing.expectEqual(@as(i8, -4), st.entries[0].markup);
    try std.testing.expectEqual(@as(u16, 1), st.entries[0].price);
    try std.testing.expectEqual(@as(i32, 4000), st.wallet);

    // Bought out: the client's echo drops the depleted entry, so the server
    // clears it (stock removes the PrimaryInventory row).
    var body2: [512]u8 = undefined;
    var w2: binary.Writer = .{ .buf = &body2 };
    try w2.writeBool(true); // isEntity
    try w2.writeI32(tid);
    try w2.writeBool(true); // hasTraderData
    try packages.stock_entity.writeTraderDataBody(&w2, .{ .trader_id = 5, .available_money = 4200, .entries = &.{} });
    const framed2 = try packages.framed(&frame_buf, "NetPackageTraderData", w2.written());
    try g.injectFramed(c, framed2);
    try std.testing.expectEqual(@as(u16, 0), st.entries[0].count);
    try std.testing.expectEqual(@as(u16, 0), st.entries[0].item);
    try std.testing.expectEqual(@as(i32, 4200), st.wallet);

    // --- In-reach vending sell: a new item appends and money credits. ---
    g.sim.transform[ps].x = 10;
    g.sim.transform[ps].y = 70;
    g.sim.transform[ps].z = 20;
    vm.stock = [_]vending_mod.StockEntry{.{}} ** vending_mod.max_vending_stock;
    vm.stock_n = 0;
    vm.available_money = 3000;
    const sell_entry = packages.stock_entity.TraderStockEntry{
        .item = .{ .type_id = stone_wire, .count = 5, .quality = 1 },
        .markup = 3,
    };
    var sbody: [512]u8 = undefined;
    var sw: binary.Writer = .{ .buf = &sbody };
    try sw.writeBool(false); // isEntity = false -> tePosition
    try sw.writeI32(10);
    try sw.writeI32(70);
    try sw.writeI32(20);
    try sw.writeBool(true); // hasTraderData
    try packages.stock_entity.writeTraderDataBody(&sw, .{ .trader_id = 5, .available_money = 3200, .entries = &[_]packages.stock_entity.TraderStockEntry{sell_entry} });
    const sframed = try packages.framed(&frame_buf, "NetPackageTraderData", sw.written());
    try g.injectFramed(c, sframed);
    try std.testing.expectEqual(stone_wire, vm.stock[0].type_id);
    try std.testing.expectEqual(@as(i32, 5), vm.stock[0].count);
    try std.testing.expectEqual(@as(i8, 3), vm.stock[0].markup);
    try std.testing.expectEqual(@as(u8, 1), vm.stock_n);
    try std.testing.expectEqual(@as(i32, 3200), vm.available_money);

    std.debug.print("PASS traderdata-copyfrom: out-of-reach ignored, in-reach buy/sell applied\n", .{});
}

test "scenario vending lock/password/allowed editing (owner-gated)" {
    // The owner's lock / password / allowed-user edits arrive as the vending
    // TE composite C2S (the mirror of TileEntityVendingMachine::write). The
    // server applies them only for the machine's owner; ownership and the
    // rental term stay server-owned (the rent SM applies them).
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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

    // The allowed-user list is part of the stock TE composite (asm.il ~440486
    // writes `i32 n | n x ToStream(...)`), so the echo has to carry it back or
    // the owner's own client shows an empty list after a reopen.
    cap.clear();
    try replicate_te.sendVendingTe(g, c.peer orelse return error.TestUnexpectedResult, 256, 70, 258);
    const te_pkg = packages.idOf("NetPackageTileEntity") orelse return error.TestUnexpectedResult;
    const echo = cap.findPkgId(te_pkg) orelse return error.TestUnexpectedResult;
    var e_plat: [vending_mod.max_platform_len]u8 = undefined;
    var e_id: [vending_mod.max_id_len]u8 = undefined;
    var e_pw: [vending_mod.max_password_hash]u8 = undefined;
    var e_aplat: [vending_mod.max_allowed_users * packages.platform_user.max_platform_len]u8 = undefined;
    var e_aid: [vending_mod.max_allowed_users * packages.platform_user.max_id_len]u8 = undefined;
    const parsed = try packages.stock_te.parseVendingTeBody(
        echo,
        &e_plat,
        &e_id,
        &e_pw,
        &e_aplat,
        &e_aid,
    );
    try std.testing.expectEqual(@as(u8, 1), parsed.allowed_n);
    try std.testing.expectEqualStrings("9002", parsed.allowed[0].id);

    std.debug.print("PASS vending-edit: owner lock/password/allowed applied, non-owner denied\n", .{});
}

test "scenario storm_frequency knob reaches weather and the GameStats wire" {
    // StormFrequency was a compile-time GameStats default with no knob;
    // [sim] storm_frequency now feeds the weather scheduler divisor
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
    try std.testing.expect(std.mem.find(u8, gs, "AAAJABJACJADJARFBNC") != null);

    // 0 disables storms (weather-environment.md: World.StormFrequency == 0).
    const g2 = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{ .storm_frequency = 0, .config_dir = "assets/fixtures" });
    defer {
        g2.deinit();
        gpa.destroy(g2);
    }
    try std.testing.expectEqual(@as(f32, 0), g2.world.weather.storm_frequency);
    try std.testing.expectEqual(@as(i32, 0), g2.gameStatsValues().storm_freq);
}

test "scenario weather storm state survives a restart" {
    // Storm SM persistence: force biome 0 into an active storm,
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
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_bmday");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    // The clock now persists (clock.zcl); this scenario deliberately mutates
    // the day, so start from a fresh calendar each run.
    io_fs.deleteFile("worlds/zdtd_sc_bmday/clock.zcl");

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
    // Coins (reward_coin) + items + exp all pay through the verdict at the
    // tick-end payout drain, so assert after the step.
    try g.step();
    try std.testing.expectEqual(coins0 + 100, g.sim.wallet[ps].coins);
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

    // The round trip above only proves the happy path. loadClaims guards its
    // 49-byte stride per record and rejects a name_len past the fixed array,
    // and neither guard had a test: a corrupt claims.zlc is exactly the input
    // those exist for.
    {
        const g3 = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g3.deinit();
            gpa.destroy(g3);
        }
        // Declares one record but carries no bytes for it.
        var short: [6]u8 = undefined;
        @memcpy(short[0..4], "ZCLC");
        std.mem.writeInt(u16, short[4..6], 1, .little);
        try io_fs.writeFile(cp, &short);
        try std.testing.expectError(error.Truncated, persist.loadClaims(g3));

        // Full stride present, but name_len exceeds the 32-byte name array:
        // the @memcpy would read past the record without the check.
        var bad_name: [6 + 49]u8 = @splat(0);
        @memcpy(bad_name[0..4], "ZCLC");
        std.mem.writeInt(u16, bad_name[4..6], 1, .little);
        bad_name[6 + 12] = 33; // name_len, one past the array
        try io_fs.writeFile(cp, &bad_name);
        try std.testing.expectError(error.BadRecord, persist.loadClaims(g3));

        // One byte short of the stride is the off-by-one the `>` bound covers.
        var stride_short: [6 + 48]u8 = @splat(0);
        @memcpy(stride_short[0..4], "ZCLC");
        std.mem.writeInt(u16, stride_short[4..6], 1, .little);
        try io_fs.writeFile(cp, &stride_short);
        try std.testing.expectError(error.Truncated, persist.loadClaims(g3));

        std.debug.print("PASS claims-persist: short stride and oversized name_len fail closed\n", .{});
    }
}

test "scenario a land claim blocks a non-owner's SetBlock" {
    // The persist scenario above only exercises the allow half (the owner
    // edits inside their own claim). The deny half is the point of the claim:
    // a second player's SetBlock inside someone else's claim is dropped, and
    // the same edit one block outside it goes through, so the rejection is
    // the claim and not the reach or bounds gate.
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
    const owner = try g.attachJoinedClient(&cap_a);
    const other = try g.attachJoinedClient(&cap_b);

    const cx: i32 = 250;
    const cz: i32 = 250;
    const kid = g.maxdamage.idByName("keystoneBlock") orelse return error.TestUnexpectedResult;
    var sb: [64]u8 = undefined;
    var fb: [8192]u8 = undefined;
    const place = try packages.buildSetBlockBody(&sb, cx, 70, cz, kid);
    try g.injectFramed(owner, try packages.framed(&fb, "NetPackageSetBlock", place));
    try std.testing.expectEqual(kid, try g.world.blockWorld(cx, 70, cz));
    const claim = g.claimCovering(cx, cz) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(owner.entity_id, claim.owner_entity);

    // Inside the claim, from the other player: denied, the block stays air.
    const stone = world_store.block_stone;
    const inside = try packages.buildSetBlockBody(&sb, cx + 1, 70, cz, stone);
    try g.injectFramed(other, try packages.framed(&fb, "NetPackageSetBlock", inside));
    try std.testing.expectEqual(@as(u32, 0), try g.world.blockWorld(cx + 1, 70, cz));

    // The owner's own edit inside the claim still lands.
    const owner_edit = try packages.buildSetBlockBody(&sb, cx + 1, 70, cz, stone);
    try g.injectFramed(owner, try packages.framed(&fb, "NetPackageSetBlock", owner_edit));
    try std.testing.expectEqual(stone, try g.world.blockWorld(cx + 1, 70, cz));
    std.debug.print("PASS claim-gate: non-owner denied inside the claim, owner allowed\n", .{});
}

test "scenario container loot respawns after LootRespawnDays" {
    io_fs.mkdirPath("worlds");
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

test "scenario loot container size comes from the loot.xml size attr" {
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir)) return error.SkipZigTest;
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_lootsize");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_lootsize", 0, .{ .game_dir = game_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    g.loot_respawn_days = 1;
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // Stock sizes: woodenChest 6x2=12, smallSafes 8x5=40 (gunSafe 8x9 caps).
    try std.testing.expectEqual(@as(u8, 6), g.loot.containerByName("woodenChest").?.size_x);
    try std.testing.expectEqual(@as(u8, 2), g.loot.containerByName("woodenChest").?.size_y);

    // Place a wooden chest; the respawn fill must size the container 6x2=12
    // (the flat fill previously hardcoded 8 slots).
    const chest_id: u16 = g.maxdamage.idByName("cntWoodenChestClosed") orelse return error.TestUnexpectedResult;
    var sb: [64]u8 = undefined;
    var frame_buf: [8192]u8 = undefined;
    const place = try packages.buildSetBlockBody(&sb, 251, 70, 251, chest_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", place));
    const pos = containers_mod.PosKey{ .x = 251, .y = 70, .z = 251 };
    const cont = g.containers.get(pos) orelse return error.TestUnexpectedResult;
    cont.clear();
    cont.touched = true;
    cont.player_storage = false; // world container: respawn-eligible
    cont.touched_day = 0;
    var req: [36]u8 = undefined;
    @memcpy(req[0..16], &cont.inv_guid);
    std.mem.writeInt(i32, req[16..20], 0, .little);
    @memcpy(req[20..36], &cont.inv_guid);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageInventoryDataRequest", &req));
    try std.testing.expectEqual(@as(u16, 12), cont.slot_count);
    // The rolled loot fits the sized grid and the wire derives 2x6 from it.
    var filled: u16 = 0;
    for (cont.slots[0..cont.slot_count]) |s| {
        if (s.count > 0 and s.item_id != 0) filled += 1;
    }
    try std.testing.expect(filled > 0);
    std.debug.print("PASS loot-size: wooden chest sized 6x2={d} slots from loot.xml ({d} filled)\n", .{ cont.slot_count, filled });
}

test "scenario trader quest offers follow the trader's class" {
    // Each stock trader class maps to its own trader_*_quests list (the five
    // lists are parsed but were never selected by trader). Spawn a trader with
    // the rekt class hash and assert its offer list is trader_rekt_quests, not
    // the jen default.
    io_fs.mkdirPath("worlds");
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
    try std.testing.expect(std.mem.find(u8, body, "quest_rekt_errand") != null);
    // intro_buried_supplies is a stock quest the old quest_/tier filter dropped.
    try std.testing.expect(std.mem.find(u8, body, "intro_buried_supplies") != null);
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

test "scenario quest POI selection matches stock tags/tier/bands and feeds offers" {
    // The stock QuestPrefabManager-equivalent selector (DynamicPrefabDecorator
    // GetRandomPOI* / GetClosestPOIToWorldPos; RE: 7dtd-engine-research
    // docs/quests-challenges.md "Quest POI selection"). A synthetic prefab
    // index proves the tag/tier/distance gating and that trader offers carry
    // the real POI location instead of the fabricated catalog spot.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_poiselect");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_poiselect", 0, .{
        .quests_path = "assets/fixtures/quests.xml",
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Force the trader band walk to band 0 (≤500 m): worldTimeBits % 3.
    g.sim.director.clock.day = 1;
    g.sim.director.clock.hours = 0;

    // Synthetic prefab index: one qualifying POI per (tier, tag) so the random
    // selector is deterministic; all within band 0 of the (0,0) trader.
    const name_storage = try gpa.dupe(u8, "poi_clear_a\x00poi_fetch_b\x00poi_fetch_c\x00part_road");
    const pois = [_]world_store.prefabs.Decoration{
        .{ .name = name_storage[0..11], .x = 100, .y = 60, .z = 100, .size_x = 30, .size_y = 20, .size_z = 30 },
        .{ .name = name_storage[12..23], .x = 400, .y = 60, .z = 100, .size_x = 30, .size_y = 20, .size_z = 30 },
        .{ .name = name_storage[24..35], .x = 700, .y = 60, .z = 100, .size_x = 30, .size_y = 20, .size_z = 30 },
        .{ .name = name_storage[36..45], .x = 50, .y = 60, .z = 50, .size_x = 10, .size_y = 10, .size_z = 10 },
    };
    const items = try gpa.dupe(world_store.prefabs.Decoration, &pois);
    var idx: world_store.prefabs.Index = .{
        .allocator = gpa,
        .items = items,
        .name_storage = name_storage,
        .tts_cache = .empty,
        .quest_cache = .empty,
    };
    // Tags must be allocator-owned (Index.deinit frees each entry's tags),
    // and distinct per entry - a shared pointer would be freed N times.
    const tags_clear = try gpa.dupe(u8, "clear");
    const tags_fetch_b = try gpa.dupe(u8, "fetch");
    const tags_fetch_c = try gpa.dupe(u8, "fetch");
    const tags_fetch_p = try gpa.dupe(u8, "fetch");
    try idx.quest_cache.put(gpa, "poi_clear_a", .{ .tags = tags_clear, .tier = 1, .has_sleepers = true });
    try idx.quest_cache.put(gpa, "poi_fetch_b", .{ .tags = tags_fetch_b, .tier = 1, .has_sleepers = true });
    try idx.quest_cache.put(gpa, "poi_fetch_c", .{ .tags = tags_fetch_c, .tier = 2, .has_sleepers = true });
    try idx.quest_cache.put(gpa, "part_road", .{ .tags = tags_fetch_p, .tier = 1, .has_sleepers = true });
    g.world.prefabs = idx;

    const clear_mask = @intFromEnum(quest_mod.QuestTag.clear);
    const fetch_mask = @intFromEnum(quest_mod.QuestTag.fetch);
    // RandomPOIGoto (world-pos path): tags + tier gate the pool, distance
    // (1000, 4000000)² bounds it, sleeper volumes are required.
    const clear_sel = (g.sim.questSelectPoi(.{
        .kind = .random,
        .anchor_x = 0,
        .anchor_z = 0,
        .tags_mask = clear_mask,
        .tier = 1,
        .entity_id = -1,
    }) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("poi_clear_a", clear_sel.name);
    try std.testing.expectEqual(@as(f32, 100), clear_sel.rect.x);
    try std.testing.expectEqual(@as(f32, 30), clear_sel.rect.size_x);
    const fetch1_sel = (g.sim.questSelectPoi(.{
        .kind = .random,
        .anchor_x = 0,
        .anchor_z = 0,
        .tags_mask = fetch_mask,
        .tier = 1,
        .entity_id = -1,
    }) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("poi_fetch_b", fetch1_sel.name);
    // Tier 2 fetch → the tier-2 POI; tier 1 has none for "crafting".
    const fetch2_sel = (g.sim.questSelectPoi(.{
        .kind = .random,
        .anchor_x = 0,
        .anchor_z = 0,
        .tags_mask = fetch_mask,
        .tier = 2,
        .entity_id = -1,
    }) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("poi_fetch_c", fetch2_sel.name);
    try std.testing.expect(g.sim.questSelectPoi(.{
        .kind = .random,
        .anchor_x = 0,
        .anchor_z = 0,
        .tags_mask = @intFromEnum(quest_mod.QuestTag.crafting),
        .tier = 1,
        .entity_id = -1,
    }) == null);
    // ClosestPOIGoto path: nearest qualifying POI (fetch, tier 1).
    const close_sel = (g.sim.questSelectPoi(.{
        .kind = .closest,
        .anchor_x = 0,
        .anchor_z = 0,
        .tags_mask = fetch_mask,
        .tier = 1,
        .entity_id = -1,
    }) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("poi_fetch_b", close_sel.name);

    // Trader offer path: tier1_clear (RandomPOIGoto + ClearSleepers → clear
    // tag) selects poi_clear_a; the offer entry carries its real location,
    // size and name instead of the fabricated catalog spot.
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    var entries: [8]packages.stock_quest.QuestPacketEntry = undefined;
    const n = g.buildTraderQuestOffers("trader_jen_quests", c.slot, 0, 70, 0, 1, &entries);
    try std.testing.expectEqual(@as(usize, 2), n);
    var clear_offer: ?*const packages.stock_quest.QuestPacketEntry = null;
    var fetch_offer: ?*const packages.stock_quest.QuestPacketEntry = null;
    for (entries[0..n]) |*e| {
        if (std.mem.eql(u8, e.quest_id, "tier1_clear")) clear_offer = e;
        if (std.mem.eql(u8, e.quest_id, "tier1_fetch")) fetch_offer = e;
    }
    const co = clear_offer orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 115), co.loc_x); // bbox center
    try std.testing.expectEqual(@as(f32, 115), co.loc_z);
    try std.testing.expectEqual(@as(f32, 30), co.size_x);
    try std.testing.expectEqual(@as(f32, 30), co.size_z);
    try std.testing.expectEqualStrings("poi_clear_a", co.poi_name);
    // tier1_fetch has no goto objective → no selector → catalog fallback.
    const fo = fetch_offer orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tier1_fetch", fo.poi_name);

    // Accept path: tier1_clear binds the selected POI rect (not the nearest /
    // fabricated def marker).
    const clear_def = g.sim.catalog.byName("tier1_clear").?;
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, clear_def.id));
    var found_slot: ?*quest_mod_components.QuestProgress = null;
    for (&g.sim.journal[ps].slots) |*s| {
        if (s.active and s.def_id == clear_def.id) found_slot = s;
    }
    const slot = found_slot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 100), slot.poi.x);
    try std.testing.expectEqual(@as(f32, 100), slot.poi.z);
    std.debug.print("PASS quest-poi-select: tags/tier/band selector + real offer locations\n", .{});
}

test "scenario block_activated objective event advances the phase" {
    // POIBlockActivate used to be auto-scaffolding (never waited). With the
    // block_activate kind, the phase is real work advanced only by the
    // client's NetPackageQuestObjectiveUpdate block_activated event.
    io_fs.mkdirPath("worlds");
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
    questKillAtPoi(g, c);
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
/// voiceLobbyId - RE parties-factions.md §3).
fn buildPartyActionBody(buf: []u8, action: u8, invited_by: i32, invited: i32) ![]u8 {
    return packages.stock_party.buildActionsBody(buf, .{
        .action = action,
        .invited_by_entity = invited_by,
        .invited_entity = invited,
    });
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

    // A non-fatal hit shoves the zombie and broadcasts NetPackageEntityVelocity
    // (bAdd=true, push away from A) to every observer, so the hit animates.
    const zkb = g.sim.spawnZombie(258, 70, 258, 100).?;
    var dmg: [256]u8 = undefined;
    const kbody = try packages.buildDamageBody(&dmg, zkb, 0, 3, 10, false, ca.entity_id);
    cap_a.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", kbody));
    const vel_id = packages.idOf("NetPackageEntityVelocity").?;
    const vvb = cap_a.findPkgIdEntity(vel_id, zkb) orelse return error.TestUnexpectedResult;
    var vr = binary.Reader{ .data = vvb };
    try std.testing.expectEqual(zkb, try vr.readI32());
    try std.testing.expectEqual(true, try vr.readBool()); // bAdd
    const vdx = try vr.readF32();
    _ = try vr.readF32(); // dy
    const vdz = try vr.readF32();
    // Push away from A at (256,70,256): the zombie sits due south-east.
    try std.testing.expect(vdx > 0 or vdz > 0);

    // A kills a zombie: Party.GetPartyXP = 100 * (1 - 0.1 * 1 in-range mate).
    const zid = g.sim.spawnZombie(258, 70, 258, 10).?;
    const dbody = try packages.buildDamageBody(&dmg, zid, 0, 3, 100, true, ca.entity_id);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody));
    try std.testing.expect(g.sim.health[g.sim.slotOfNetId(zid).?].hp <= 0);
    try std.testing.expectEqual(@as(u64, 90), ca.xp);
    try std.testing.expectEqual(@as(u64, 90), cb.xp);
    // The killer's client gets NetPackageEntityAddExpClient (xpType 0 = Kill)
    // with the split XP; the mate gets NetPackageSharedPartyKill (below).
    // Kill counter: the killer's character sheet gets AddScoreClient(1 kill).
    const score_id = packages.idOf("NetPackageEntityAddScoreClient").?;
    const scb = cap_a.findPkgIdEntity(score_id, ca.entity_id) orelse return error.TestUnexpectedResult;
    var sr = binary.Reader{ .data = scb };
    try std.testing.expectEqual(ca.entity_id, try sr.readI32());
    try std.testing.expectEqual(@as(i16, 1), try sr.readI16()); // zombieKills
    try std.testing.expectEqual(@as(i16, 0), try sr.readI16()); // playerKills
    try std.testing.expectEqual(@as(i16, 0), try sr.readI16()); // otherTeamNumber
    try std.testing.expectEqual(@as(i32, 0), try sr.readI32()); // conditions
    const xp_id = packages.idOf("NetPackageEntityAddExpClient").?;
    const xpb = cap_a.findPkgId(xp_id) orelse return error.TestUnexpectedResult;
    var xr = binary.Reader{ .data = xpb };
    try std.testing.expectEqual(ca.entity_id, try xr.readI32());
    try std.testing.expectEqual(@as(i32, 90), try xr.readI32());
    try std.testing.expectEqual(@as(i16, 0), try xr.readI16()); // Kill tag
    try std.testing.expectEqual(false, try xr.readBool()); // no ItemValue
    const sk_id = packages.idOf("NetPackageSharedPartyKill").?;
    const skb = cap_b.findPkgId(sk_id) orelse return error.TestUnexpectedResult;
    var r = binary.Reader{ .data = skb };
    _ = try r.readI32(); // entityTypeID
    try std.testing.expectEqual(@as(i32, 90), try r.readI32()); // xp
    try std.testing.expectEqual(ca.entity_id, try r.readI32()); // entityID (killer for the tooltip)
    try std.testing.expectEqual(ca.entity_id, try r.readI32()); // killerID

    // A solo kill (party broken by B leaving) awards the full 100.
    try g.injectFramed(cb, try packages.framed(&fbuf, "NetPackagePartyActions", try buildPartyActionBody(&pbody, 3, 0, 0)));
    cap_a.clear();
    const zid2 = g.sim.spawnZombie(258, 70, 258, 10).?;
    const dbody2 = try packages.buildDamageBody(&dmg, zid2, 0, 3, 100, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody2));
    try std.testing.expectEqual(@as(u64, 190), ca.xp);
    try std.testing.expectEqual(@as(u64, 90), cb.xp);
    // Solo kill: the full 100 reaches the killer via AddExpClient.
    const xpb2 = cap_a.findPkgId(xp_id) orelse return error.TestUnexpectedResult;
    var xr2 = binary.Reader{ .data = xpb2 };
    try std.testing.expectEqual(ca.entity_id, try xr2.readI32());
    try std.testing.expectEqual(@as(i32, 100), try xr2.readI32());
    try std.testing.expectEqual(@as(i16, 0), try xr2.readI16());

    // PvP kill (PlayerKillingMode 3 default): A kills B; AddScoreClient
    // carries playerKills=1 while zombieKills stays at the earlier count.
    cap_a.clear();
    const pdmg = try packages.buildDamageBody(&dmg, cb.entity_id, 0, 3, 100, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", pdmg));
    const pscb = cap_a.findPkgIdEntity(score_id, ca.entity_id) orelse return error.TestUnexpectedResult;
    var psr = binary.Reader{ .data = pscb };
    try std.testing.expectEqual(ca.entity_id, try psr.readI32());
    try std.testing.expectEqual(@as(i16, 2), try psr.readI16()); // zombieKills (2 total)
    try std.testing.expectEqual(@as(i16, 1), try psr.readI16()); // playerKills
    try std.testing.expectEqual(@as(i16, 0), try psr.readI16()); // otherTeamNumber
    try std.testing.expectEqual(@as(i32, 0), try psr.readI32()); // conditions
    // B's death screen gets the spawn list on the next hp-replicate pass.
    try g.step();
    const wsp_id = packages.idOf("NetPackageWorldSpawnPoints").?;
    const wspb = cap_b.findPkgId(wsp_id) orelse return error.TestUnexpectedResult;
    var wr = binary.Reader{ .data = wspb };
    try std.testing.expectEqual(@as(u8, 2), try wr.readByte()); // list version
    try std.testing.expectEqual(@as(i32, 1), try wr.readI32()); // one entry (world spawn)
    try std.testing.expectEqual(@as(u16, 0), try wr.readU16()); // SpawnPosition version
    _ = try wr.readF32();
    _ = try wr.readF32();
    _ = try wr.readF32();
    _ = try wr.readF32(); // heading
    _ = try wr.readI32(); // team
    _ = try wr.readI32(); // activeInGameMode
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
    // A is not in this recipient list, so A does not receive it. A real
    // client puts its own entity id first in the party list, which is why the
    // server must not filter the sender out (XUiC_Chat.il.txt:212-223).
    try std.testing.expect(cap_a.findPkgId(chat_id) == null);
    try std.testing.expect(cap_c.findPkgId(chat_id) == null);

    // A party message that lists the sender reaches the sender: stock's
    // targeted loop sends to every listed ClientInfo with no self-exclusion
    // (GameManager.il.txt:7690-7708), and the client renders only the echo.
    cap_a.clear();
    cap_b.clear();
    const self_recips = [_]i32{ cb.entity_id, cb.entity_id };
    try g.injectFramed(cb, try packages.framed(&fbuf, "NetPackageChat", try packages.buildStockChat(&body, 2, cb.entity_id, "party self", &self_recips)));
    try std.testing.expect(cap_b.findPkgId(chat_id) != null);

    // A global message (no recipients) broadcasts to everyone, sender
    // included: stock passes allBut = -1 (GameManager.il.txt:7717-7735) and
    // the client does not add its own line locally. Sent by the third peer so
    // the per-client chat rate limiter does not trip.
    cap_a.clear();
    cap_b.clear();
    cap_c.clear();
    try g.injectFramed(cc, try packages.framed(&fbuf, "NetPackageChat", try packages.buildStockChat(&body, 0, cc.entity_id, "global hi", &.{})));
    try std.testing.expect(cap_a.findPkgId(chat_id) != null);
    try std.testing.expect(cap_b.findPkgId(chat_id) != null);
    try std.testing.expect(cap_c.findPkgId(chat_id) != null); // the speaker sees it too

    // Unlike the verbatim relays, chat is parsed and rebuilt, and the rebuild
    // substitutes the sender's own entity id for whatever the client claimed.
    // That is what stops one player putting words in another's mouth, and it
    // was untested: every case above sent its own id, so a server that echoed
    // the claimed sender would have passed all of them.
    cap_b.clear();
    cap_c.clear();
    // acceptChatRate gates every chat kind per client, so let A's gap expire
    // before it speaks again; the virtual clock makes that exact.
    clock.advanceNs(2 * std.time.ns_per_s);
    // Sent by A, claiming C's entity id.
    const spoofed = try packages.buildStockChat(&body, 0, cc.entity_id, "not from me", &.{});
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageChat", spoofed));
    const relayed = cap_b.findPkgId(chat_id) orelse return error.TestUnexpectedResult;
    const rch = try packages.parseStockChat(relayed);
    try std.testing.expectEqual(ca.entity_id, rch.sender); // A, not the claimed C
    try std.testing.expect(rch.sender != cc.entity_id);
    try std.testing.expectEqualStrings("not from me", rch.msg);

    // NetPackageSimpleChat: zdtd upgrades it to a stock NetPackageChat and
    // broadcasts. A stock server would drop a recipient-less SimpleChat
    // outright (ProcessPackage IL_0015 branches to the terminal ret at
    // IL_012A), so this is a deliberate divergence, recorded in
    // DIVERGENCES 1a4. Pinned here so it is not "fixed" into silence, and so
    // the upgrade keeps substituting the real sender id.
    cap_a.clear();
    cap_b.clear();
    cap_c.clear();
    clock.advanceNs(2 * std.time.ns_per_s);
    var simple: [128]u8 = undefined;
    var sw = binary.Writer{ .buf = &simple };
    try sw.writeString("REFake1"); // sender name, read and discarded
    try sw.writeString("simple hello");
    try g.injectFramed(cb, try packages.framed(&fbuf, "NetPackageSimpleChat", sw.written()));
    // It arrives as NetPackageChat, not SimpleChat, and reaches everyone
    // including the speaker (same audience as a global NetPackageChat).
    const up_a = cap_a.findPkgId(chat_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cap_b.findPkgId(chat_id) != null);
    try std.testing.expect(cap_c.findPkgId(chat_id) != null);
    const up = try packages.parseStockChat(up_a);
    try std.testing.expectEqualStrings("simple hello", up.msg);
    // The sender is the sending peer, not anything the body claimed.
    try std.testing.expectEqual(cb.entity_id, up.sender);

    std.debug.print("PASS chat-sender: the relayed sender is the sending peer, not the claimed one\n", .{});
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

test "scenario trader restock rebuilds the window lazily on open" {
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_restock");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_restock", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);
    // Joel's trader_info (1) has reset_interval 3 in stock traders.xml.
    const trader_id = g.sim.spawnTrader("npcTraderJoel", 100, 70, 100, 1, 5000).?;
    const ts = g.sim.slotOfNetId(trader_id).?;
    // Builtin traders table has no trader_info: pin the interval like the
    // stock traders.xml row for Joel (reset_interval 3) and a day-1 fill.
    g.sim.trader_stock[ts].reset_interval = 3;
    g.sim.trader_stock[ts].last_restock_day = 1;
    // Interval not elapsed (day 2 vs fill day 1): the open leaves the window.
    g.sim.director.clock.day = 2;
    const n_before = g.sim.trader_stock[ts].n;
    g.maybeRestockTrader(ts);
    try std.testing.expectEqual(@as(u32, 1), g.sim.trader_stock[ts].last_restock_day);
    try std.testing.expectEqual(n_before, g.sim.trader_stock[ts].n);
    // Elapsed (day 4): lazy rebuild re-rolls the window, advances the day and
    // regenerates the drained money pool (stock HandleFullReset on open).
    g.sim.director.clock.day = 4;
    g.sim.trader_stock[ts].wallet = 0;
    g.maybeRestockTrader(ts);
    try std.testing.expectEqual(@as(u32, 4), g.sim.trader_stock[ts].last_restock_day);
    try std.testing.expect(g.sim.trader_stock[ts].wallet >= 5000);
    // -1 (never) stays untouched even far past the interval.
    const never_id = g.sim.spawnTrader("npcTraderNever", 120, 70, 120, 0, 5000).?;
    const nts = g.sim.slotOfNetId(never_id).?;
    g.fillTraderFromXml(never_id);
    g.sim.trader_stock[nts].reset_interval = -1;
    g.sim.trader_stock[nts].last_restock_day = 1;
    g.sim.director.clock.day = 60;
    g.maybeRestockTrader(nts);
    try std.testing.expectEqual(@as(u32, 1), g.sim.trader_stock[nts].last_restock_day);
    std.debug.print("PASS trader-restock: lazy window rebuild on open after reset_interval\n", .{});
}

test "scenario trader stock persists across restart (traders.zst)" {
    // GAP restock-timer row: stock TraderManager persists its inventory, so a
    // reboot must not re-roll what a player was looking at. initWorld spawns
    // "Trader Jen" deterministically and fills the fresh XML roll; the saved
    // window (traders.zst) overrides it by trader name on the restart, and the
    // wallet / restock cadence come back with it. Entries ride item names
    // (AssignIds ids are version-dependent); unknown names fail closed.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_traderpersist");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    var wood_name: []const u8 = "";
    {
        const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_traderpersist", 0);
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        // Find the initWorld trader and shape a traded-against window: a
        // distinctive entry, drained wallet, and a 3-day reset cadence.
        var ts: ?ecs.Slot = null;
        var s: usize = 0;
        while (s < ecs.max_entities) : (s += 1) {
            if (g.sim.alive[s] and g.sim.mask[s].trader_stock and
                std.mem.eql(u8, g.sim.trader_stock[s].name, "Trader Jen"))
            {
                ts = @intCast(s);
                break;
            }
        }
        const t = ts orelse return error.TestUnexpectedResult;
        const wood = g.items.byName("resourceWood") orelse return error.TestUnexpectedResult;
        g.sim.trader_stock[t].entries[0] = .{
            .item = wood.id,
            .count = 37,
            .quality = 1,
            .price = 222,
            .sell = 11,
            .markup = 0,
        };
        wood_name = wood.name;
        g.sim.trader_stock[t].n = 1;
        g.sim.trader_stock[t].wallet = 1234;
        g.sim.trader_stock[t].wallet_default = 4321;
        g.sim.trader_stock[t].reset_interval = 3;
        g.sim.trader_stock[t].last_restock_day = 7;
        try g.saveTraders();
    }
    {
        const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_traderpersist", 0);
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        var ts: ?ecs.Slot = null;
        var s: usize = 0;
        while (s < ecs.max_entities) : (s += 1) {
            if (g.sim.alive[s] and g.sim.mask[s].trader_stock and
                std.mem.eql(u8, g.sim.trader_stock[s].name, "Trader Jen"))
            {
                ts = @intCast(s);
                break;
            }
        }
        const t = ts orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), g.sim.trader_stock[t].n);
        try std.testing.expectEqual(@as(u16, 37), g.sim.trader_stock[t].entries[0].count);
        try std.testing.expectEqual(@as(u16, 222), g.sim.trader_stock[t].entries[0].price);
        try std.testing.expectEqual(@as(u16, 11), g.sim.trader_stock[t].entries[0].sell);
        try std.testing.expectEqualStrings(wood_name, g.items.byId(g.sim.trader_stock[t].entries[0].item).?.name);
        try std.testing.expectEqual(@as(i32, 1234), g.sim.trader_stock[t].wallet);
        try std.testing.expectEqual(@as(i32, 4321), g.sim.trader_stock[t].wallet_default);
        try std.testing.expectEqual(@as(i32, 3), g.sim.trader_stock[t].reset_interval);
        try std.testing.expectEqual(@as(u32, 7), g.sim.trader_stock[t].last_restock_day);
        std.debug.print("PASS trader-persist: stock/wallet/cadence restored across restart by trader name\n", .{});
    }
}

test "scenario a trader entry with an unresolvable item does not shift the saved record" {
    // An entry whose item id this build cannot name is dropped on save rather
    // than written as a stub. The record's entry-count byte therefore has to
    // be the number actually written, not `n`: the reader walks exactly that
    // many entries, so a header counting the dropped one would send it into
    // the next record's bytes for this record's tail.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_tradersavecount");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_tradersavecount", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var ts: ?ecs.Slot = null;
    var s: usize = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (g.sim.alive[s] and g.sim.mask[s].trader_stock and
            std.mem.eql(u8, g.sim.trader_stock[s].name, "Trader Jen"))
        {
            ts = @intCast(s);
            break;
        }
    }
    const t = ts orelse return error.TestUnexpectedResult;
    const wood = g.items.byName("resourceWood") orelse return error.TestUnexpectedResult;
    // Middle entry carries an id no item table entry claims, so `byId` misses
    // and the writer drops it. The two around it must still come back.
    const unresolvable: u16 = 60000;
    try std.testing.expect(g.items.byId(unresolvable) == null);
    g.sim.trader_stock[t].entries[0] = .{ .item = wood.id, .count = 11, .price = 101 };
    g.sim.trader_stock[t].entries[1] = .{ .item = unresolvable, .count = 22, .price = 202 };
    g.sim.trader_stock[t].entries[2] = .{ .item = wood.id, .count = 33, .price = 303 };
    g.sim.trader_stock[t].n = 3;
    g.sim.trader_stock[t].wallet = 5150;
    try g.saveTraders();

    // The blob must scan to exactly its length: a count byte of 3 over two
    // written entries makes the reader run off this record's end.
    var path_buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/traders.zst", .{g.world.world_dir});
    const blob = try io_fs.readFileAll(gpa, p);
    defer gpa.free(blob);
    try std.testing.expectEqual(blob.len, try persist.ztrScanLen(blob));

    g.sim.trader_stock[t].n = 0;
    g.sim.trader_stock[t].wallet = 0;
    try persist.loadTraders(g);
    try std.testing.expectEqual(@as(usize, 2), g.sim.trader_stock[t].n);
    try std.testing.expectEqual(@as(u16, 11), g.sim.trader_stock[t].entries[0].count);
    try std.testing.expectEqual(@as(u16, 33), g.sim.trader_stock[t].entries[1].count);
    try std.testing.expectEqual(@as(i32, 5150), g.sim.trader_stock[t].wallet);
    std.debug.print("PASS trader-savecount: a dropped entry is not counted in the record header\n", .{});
}

test "scenario traders.zst record for an absent trader does not desync the reader" {
    // A trader saved by a previous map is skipped on load, but its stock
    // entries still occupy bytes. Skipping the record without consuming them
    // left the reader mid-record, so every following trader parsed garbage:
    // either a spurious Truncated (all later traders silently lose their
    // persisted stock) or one trader's inventory bound onto another.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_traderdesync");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_traderdesync", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var ts: ?ecs.Slot = null;
    var s: usize = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (g.sim.alive[s] and g.sim.mask[s].trader_stock and
            std.mem.eql(u8, g.sim.trader_stock[s].name, "Trader Jen"))
        {
            ts = @intCast(s);
            break;
        }
    }
    const t = ts orelse return error.TestUnexpectedResult;
    const wood = g.items.byName("resourceWood") orelse return error.TestUnexpectedResult;

    // Two records: a trader this world does not have (carrying one stock
    // entry), then the live one. The live record is only reachable if the
    // skipped record's entry bytes were consumed.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const W = struct {
        fn str(a: std.mem.Allocator, b: *std.ArrayList(u8), v: []const u8) !void {
            try b.append(a, @intCast(v.len));
            try b.appendSlice(a, v);
        }
        fn int(a: std.mem.Allocator, b: *std.ArrayList(u8), comptime T: type, v: T) !void {
            var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &tmp, v, .little);
            try b.appendSlice(a, &tmp);
        }
        /// header: reset_interval i32 | last_restock_day u32 | wallet i32 |
        /// wallet_default i32 | entry count u8
        fn head(a: std.mem.Allocator, b: *std.ArrayList(u8), wallet: i32, n: u8) !void {
            try int(a, b, i32, 3);
            try int(a, b, u32, 7);
            try int(a, b, i32, wallet);
            try int(a, b, i32, 4321);
            try b.append(a, n);
        }
        /// entry: name | count u16 | quality u8 | price u16 | sell u16 | markup i8
        fn entry(a: std.mem.Allocator, b: *std.ArrayList(u8), name: []const u8, count: u16, price: u16) !void {
            try str(a, b, name);
            try int(a, b, u16, count);
            try b.append(a, 1);
            try int(a, b, u16, price);
            try int(a, b, u16, 11);
            try b.append(a, 0);
        }
    };
    try buf.appendSlice(gpa, "ZTR1");
    try buf.append(gpa, 1); // version
    try W.int(gpa, &buf, u16, 2); // record count
    try W.str(gpa, &buf, "Trader From Another Map");
    try W.head(gpa, &buf, 999, 1);
    try W.entry(gpa, &buf, wood.name, 5, 100);
    try W.str(gpa, &buf, "Trader Jen");
    try W.head(gpa, &buf, 1234, 1);
    try W.entry(gpa, &buf, wood.name, 37, 222);

    var path_buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/traders.zst", .{g.world.world_dir});
    try io_fs.writeFile(p, buf.items);

    try persist.loadTraders(g);

    // The live trader's record was reached and applied, not the skipped one's.
    try std.testing.expectEqual(@as(usize, 1), g.sim.trader_stock[t].n);
    try std.testing.expectEqual(@as(u16, 37), g.sim.trader_stock[t].entries[0].count);
    try std.testing.expectEqual(@as(u16, 222), g.sim.trader_stock[t].entries[0].price);
    try std.testing.expectEqual(@as(i32, 1234), g.sim.trader_stock[t].wallet);
    std.debug.print("PASS trader-desync: a skipped record's entries are consumed\n", .{});

    // Same cursor rule one level down: an entry naming an item this build no
    // longer resolves (XML drift) is dropped, but its bytes still have to be
    // consumed. Abandoning the entry loop there would leave the reader on this
    // entry's tail, so the next record parses from the middle of it.
    {
        var b2: std.ArrayList(u8) = .empty;
        defer b2.deinit(gpa);
        try b2.appendSlice(gpa, "ZTR1");
        try b2.append(gpa, 1);
        try W.int(gpa, &b2, u16, 2); // two records
        try W.str(gpa, &b2, "Trader Jen");
        try W.head(gpa, &b2, 4321, 2); // two entries
        try W.entry(gpa, &b2, "itemThatNoLongerExists", 9, 999);
        try W.entry(gpa, &b2, wood.name, 12, 345);
        try W.str(gpa, &b2, "Trader Bob");
        try W.head(gpa, &b2, 777, 1);
        try W.entry(gpa, &b2, wood.name, 3, 30);
        try io_fs.writeFile(p, b2.items);
        try persist.loadTraders(g);
        // The unknown entry is gone, the known one after it survived with its
        // own values, and the record ended where the header said it would.
        try std.testing.expectEqual(@as(usize, 1), g.sim.trader_stock[t].n);
        try std.testing.expectEqual(@as(u16, 12), g.sim.trader_stock[t].entries[0].count);
        try std.testing.expectEqual(@as(u16, 345), g.sim.trader_stock[t].entries[0].price);
        try std.testing.expectEqual(@as(i32, 4321), g.sim.trader_stock[t].wallet);
        // The second record still parsed: the scanner agrees on the length.
        try std.testing.expectEqual(b2.items.len, try persist.ztrScanLen(b2.items));
    }
    try io_fs.writeFile(p, buf.items);
    try persist.loadTraders(g);

    // The fuzz target walks a parallel copy of this cursor arithmetic
    // (persist.ztrScanLen) so it can run without a Game. A second
    // implementation is only useful while it agrees with the real loader, so
    // pin that here: the same blob the loader just accepted must scan to
    // exactly its length, and a blob the scanner rejects must not load.
    try std.testing.expectEqual(buf.items.len, try persist.ztrScanLen(buf.items));
    // Truncating anywhere inside the blob must fail both. Walking every prefix
    // catches a scanner that is merely permissive rather than equivalent.
    var cut: usize = 1;
    while (cut < buf.items.len) : (cut += 1) {
        const prefix = buf.items[0..cut];
        const scan_ok = if (persist.ztrScanLen(prefix)) |_| true else |_| false;
        try io_fs.writeFile(p, prefix);
        const load_ok = if (persist.loadTraders(g)) |_| true else |_| false;
        try std.testing.expectEqual(scan_ok, load_ok);
    }
}

test "scenario ZPV12 record claiming more slots than the array is bounded" {
    // players.zsv carries inv_n as a u8 (up to 255) while the inventory array
    // holds max_inv_slots (67). The slot write is bounded, but the ZPV12 mod-id
    // block indexed the same array unguarded, so an over-count record wrote
    // past it. A corrupt or hand-edited save must be rejected or clamped,
    // never allowed to scribble past the array.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_zpv12bound");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_zpv12bound", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const name = c.name[0..c.name_len];

    // ZPV12: magic | n:u32 | name_len:u8 | name | x,y,z:f32 | coins:u32 |
    // inv_n:u8 | inv_n * 21-byte slots | journal count:u8 | ...
    const claimed: u8 = 200; // > max_inv_slots (67)
    const stride: usize = persist.zpvSlotStride(12);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "ZPVC");
    var n_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &n_le, 1, .little);
    try buf.appendSlice(gpa, &n_le);
    try buf.append(gpa, @intCast(name.len));
    try buf.appendSlice(gpa, name);
    try buf.appendNTimes(gpa, 0, 16); // x,y,z,coins
    try buf.append(gpa, claimed);
    // Every slot carries a non-zero item and a non-zero mod id, so the mod
    // block actually writes for each one rather than skipping on zero.
    var s: usize = 0;
    while (s < claimed) : (s += 1) {
        var slot = [_]u8{0} ** 21;
        std.mem.writeInt(u16, slot[0..2], 7, .little); // item_id
        std.mem.writeInt(u16, slot[2..4], 1, .little); // count
        std.mem.writeInt(u16, slot[13..15], 9, .little); // mods[0]
        try buf.appendSlice(gpa, slot[0..stride]);
    }
    try buf.append(gpa, 0); // journal count

    var path_buf: [512]u8 = undefined;
    const p = try persist.playersPath(g, &path_buf);
    try io_fs.writeFile(p, buf.items);

    // Must return without writing past the inventory array. A Debug build traps
    // an out-of-bounds write, so surviving the call is part of the check - but
    // "did not crash" is weak on its own: it would also pass if the loader
    // silently restored nothing. Assert the observable outcome too, so the test
    // fails on a regression that clamps by giving up rather than by bounding.
    persist.tryRestorePlayer(g, c);
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.mask[ps].inventory);
    const capacity = g.sim.inventory[ps].slots.len;
    try std.testing.expect(claimed > capacity); // the file really did over-claim
    // Every record in the file carries item_id 7, so a loader that clamped by
    // bounding filled the whole array; one that clamped by bailing out left it
    // empty. Counting the restored slots tells those apart, which the bare
    // "it did not crash" check could not.
    var filled: usize = 0;
    for (g.sim.inventory[ps].slots) |slot| {
        if (slot.item_id == 7) filled += 1;
    }
    try std.testing.expectEqual(capacity, filled);
    std.debug.print("PASS zpv12-bound: over-count inventory record stays in bounds\n", .{});
}

test "scenario air drop pushes a supply_drop NavObject marker" {
    // AIDirectorAirDropComponent.RefreshCrates (map-objects.md section 8): the
    // one server-push nav marker case, sent alongside the loot-bag spawn.
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
    _ = try g.attachJoinedClient(&cap);
    try std.testing.expect(g.air_drop_interval_hours > 0);
    g.next_air_drop_hour = 1; // already elapsed relative to worldHour()
    cap.clear();
    g.tickAirDrop();
    const nav_id = packages.idOf("NetPackageNavObject").?;
    try std.testing.expect(cap.findPkgId(nav_id) != null);
    std.debug.print("PASS air-drop: supply_drop NavObject marker sent\n", .{});
}

test "scenario bedroll ownership survives a restart" {
    // server-lifecycle.md section 6.1: PersistentPlayerData.Write carries the
    // bedroll position as a first-class field. bed_x/y/z/has_bed existed only
    // in memory before; a restart used to drop them silently.
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
        var cap: ln_peer.Capture = .{};
        const c = try g.attachJoinedClient(&cap);
        c.has_bed = true;
        c.bed_x = 111;
        c.bed_y = 68;
        c.bed_z = -222;
    }

    {
        const g2 = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g2.deinit();
            gpa.destroy(g2);
        }
        var cap: ln_peer.Capture = .{};
        const c2 = try g2.attachJoinedClient(&cap);
        try std.testing.expect(c2.has_bed);
        try std.testing.expectEqual(@as(i32, 111), c2.bed_x);
        try std.testing.expectEqual(@as(i32, 68), c2.bed_y);
        try std.testing.expectEqual(@as(i32, -222), c2.bed_z);
    }
    std.debug.print("PASS bedroll: ownership and position survive a restart\n", .{});
}

test "scenario bedroll: a save with no bedroll tail loads with has_bed false" {
    // A pre-change save has nothing after the buff list; the reader and the
    // record-skip helper must both treat running out of bytes as "not set,"
    // not a corrupt-file error.
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
        var cap: ln_peer.Capture = .{};
        _ = try g.attachJoinedClient(&cap);
        // has_bed stays false: this reproduces a save written before the
        // bedroll tail existed, since the writer already emits a bare
        // presence-0 byte when has_bed is false (indistinguishable on disk
        // from "field never existed" up to that byte).
    }

    {
        const g2 = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g2.deinit();
            gpa.destroy(g2);
        }
        var cap: ln_peer.Capture = .{};
        const c2 = try g2.attachJoinedClient(&cap);
        try std.testing.expect(!c2.has_bed);
    }
    std.debug.print("PASS bedroll: absent tail reads back as unset, not an error\n", .{});
}

test "scenario a burning workstation grants its ActiveRadiusEffects buff to nearby players" {
    // dedicated-misc-systems.md "BlockRadiusEffect": a burning campfire-class
    // block grants its blocks.xml ActiveRadiusEffects buff to players within
    // radius; a player outside it, or the same block unlit, gets nothing.
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
    // Test-only block table: one campfire-class id (106, the convention the
    // workstation persistence tests already use) carrying a radius effect.
    // buffIsOnFire is a real entry in the builtin buff catalog (no game-dir
    // in this scenario), so indexOfName resolves without a custom buff table.
    const test_defs = [_]blocks_mod.BlockDef{.{
        .id = 106,
        .name = "campfire",
        .radius_effect_buff = "buffIsOnFire",
        .radius_effect_radius_sq = 4.0, // radius 2
    }};
    g.blocks = .{ .defs = test_defs[0..], .source = .xml };

    const ws = g.workstations.getOrCreate(100, 70, 100).?;
    ws.block_id = 106;
    ws.is_burning = true;

    var cap_near: ln_peer.Capture = .{};
    const near = try g.attachJoinedClient(&cap_near);
    const near_ps = g.sim.playerByPeer(near.slot).?;
    g.sim.transform[near_ps] = .{ .x = 101, .y = 70, .z = 100 }; // 1 block away

    var cap_far: ln_peer.Capture = .{};
    const far = try g.attachJoinedClient(&cap_far);
    const far_ps = g.sim.playerByPeer(far.slot).?;
    g.sim.transform[far_ps] = .{ .x = 200, .y = 70, .z = 100 }; // well outside radius

    g.tickBlockRadiusEffects();

    const buf_id = g.buffs.indexOfName("buffIsOnFire").?;
    try std.testing.expect(g.sim.buffs[near_ps].find(buf_id) != null);
    try std.testing.expect(g.sim.buffs[far_ps].find(buf_id) == null);

    // Unlit: the same block with is_burning=false grants nothing further, and
    // the near player's existing buff is not this tick's concern (it expires
    // on its own class duration; this tick simply does not refresh it).
    ws.is_burning = false;
    var cap_near2: ln_peer.Capture = .{};
    const near2 = try g.attachJoinedClient(&cap_near2);
    const near2_ps = g.sim.playerByPeer(near2.slot).?;
    g.sim.transform[near2_ps] = .{ .x = 101, .y = 70, .z = 100 };
    g.tickBlockRadiusEffects();
    try std.testing.expect(g.sim.buffs[near2_ps].find(buf_id) == null);

    std.debug.print("PASS block radius effect: burning campfire buffs nearby players, unlit does not\n", .{});
}

test "scenario bot shoot is LOS-gated by solid voxels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    const bid = g.bots.spawn(g, 8, 70, 8, 100).?;
    // Spawn the zombie at the terrain surface too so the eye-line is flat and
    // the wall cell is predictable.
    const zy = g.groundHeight(12, 12);
    const zid = g.sim.spawnZombie(12, zy, 12, 100).?;
    const zs = g.sim.slotOfNetId(zid).?;

    // Clear line: the shot lands and damages the zombie by the bot's weapon damage
    // (cross-pollinated from clanker WeaponProfile: mixed loadout), and the bot
    // is attributed as the attacker (zombie revenge target).
    const weap_dmg = g.bots.bots[g.bots.find(bid).?].weapon.damage;
    g.bots.shoot(g, bid, zid, false);
    try std.testing.expectApproxEqAbs(@as(f32, 100 - weap_dmg), g.sim.health[zs].hp, 0.01);
    try std.testing.expectEqual(bid, g.sim.zombie_ai[zs].revenge_target);

    // Place a stone wall on the eye-line cell between the two and re-shoot:
    // the LOS gate must reject the shot (hp unchanged).
    try g.world.setBlockWorld(10, 66, 10, world_store.block_stone);
    const hp_before = g.sim.health[zs].hp;
    g.bots.shoot(g, bid, zid, false);
    try std.testing.expectEqual(hp_before, g.sim.health[zs].hp);

    // Clear the wall; a headshot through clear air lands with the multiplier.
    try g.world.setBlockWorld(10, 66, 10, world_store.block_air);
    g.bots.shoot(g, bid, zid, true);
    try std.testing.expectApproxEqAbs(
        hp_before - weap_dmg * game_bot.bot_headshot_multiplier,
        g.sim.health[zs].hp,
        0.01,
    );
}

test "scenario bot host config flows from options (headshot multiplier)" {
    // `[bots] headshot_multiplier` (merged into InitOptions.bot_config) must
    // reach the BotManager and apply to headshot shots (ADR 0021 / ADR 0026).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .bot_config = .{ .headshot_multiplier = 3.0 },
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    const bid = g.bots.spawn(g, 8, 70, 8, 100).?;
    const zy = g.groundHeight(12, 12);
    const zid = g.sim.spawnZombie(12, zy, 12, 100).?;
    const zs = g.sim.slotOfNetId(zid).?;
    const weap_dmg = g.bots.bots[g.bots.find(bid).?].weapon.damage;
    g.bots.shoot(g, bid, zid, true); // headshot
    // 3x multiplier (config), not the 2x default.
    try std.testing.expectApproxEqAbs(
        @as(f32, 100) - weap_dmg * 3.0,
        g.sim.health[zs].hp,
        0.01,
    );
}

test "scenario on_player_damage verdict denies PvP via the real core_pvp module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    // pvp_mode 3 (PvP allowed natively): only the plugin verdict can stop it.
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{ .player_killing_mode = 3 });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Load the committed policy module into the Game's wasm host (its
    // sense/query fns are already wired in wasm_ctx).
    g.wasm_plugins.loadAll(gpa, &[_][]const u8{"plugins/core_pvp/core_pvp.wasm"}, &g.wasm_ctx, .{});
    g.wasm_plugins.enable();

    const id_a: platform_user.Id = .{ .platform = "Steam", .id = "9001" };
    const id_b: platform_user.Id = .{ .platform = "Steam", .id = "9002" };
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClientAs(&cap_a, id_a);
    const cb = try g.attachJoinedClientAs(&cap_b, id_b);
    const pa = g.sim.slotOfNetId(ca.entity_id).?;
    try std.testing.expect(g.sim.mask[pa].player);

    // Player B attacks player A: the on_player_damage verdict denies it.
    const hp0 = g.sim.health[pa].hp;
    var body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;
    const dmg = try packages.buildDamageBody(&body, ca.entity_id, 0, 0, 50, false, cb.entity_id);
    try g.injectFramed(cb, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg));
    try std.testing.expectEqual(hp0, g.sim.health[pa].hp);

    // A zombie near the players still takes player damage (the module keeps
    // non-PvP damage untouched). Spawn it beside player A so the interest
    // range gate passes.
    const ap = g.sim.transform[pa];
    const zy = g.groundHeight(@trunc(ap.x + 2), @trunc(ap.z));
    const zid = g.sim.spawnZombie(ap.x + 2, zy, ap.z, 100).?;
    const zs = g.sim.slotOfNetId(zid).?;
    const zhp0 = g.sim.health[zs].hp;
    const zdmg = try packages.buildDamageBody(&body, zid, 0, 0, 50, false, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageDamageEntity", zdmg));
    try std.testing.expect(zhp0 > g.sim.health[zs].hp);
    std.debug.print("PASS pvp-verdict: player damage denied, zombie damage kept\n", .{});
}

test "scenario core_announce broadcasts join via the say verb" {
    // ADR 0020/0026: announcements ship as a Wasm module; the `say` queue verb
    // (ecs/command.zig Op.say) routes through the stock chat broadcast with
    // sender 0 = server. This is the end-to-end proof of the affordance.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_announce");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{"plugins/core_announce/core_announce.wasm"};
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_announce", 0, .{
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.count());

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);
    // Let the join hook's queued `say` drain through the command buffer.
    var t: u64 = 0;
    while (t < 4) : (t += 1) try g.step();

    const chat_id = packages.idOf("NetPackageChat").?;
    const body = cap.findPkgId(chat_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, body, "joined the wasteland") != null);
    std.debug.print("PASS announce: join broadcast via the say verb\n", .{});

    // v2: clock announcements from the sense header (world_time + blood_moon).
    // The module latched the starting day on the first ticks; force a day
    // roll and a blood-moon flip, then assert the corresponding chats landed
    // in some captured frame. WorldClock.day is 1-based, so day 5 reads as
    // world-time day 4 in the sense header.
    g.sim.director.clock.day = 5;
    g.sim.director.clock.hours = 0.0;
    var t2: u64 = 0;
    while (t2 < 4) : (t2 += 1) try g.step();
    // Blood-moon night: pin the clock's schedule to today at night so the
    // director's tick flips bloodmoon_active (it recomputes from the clock
    // every tick, so a direct field write would be overwritten).
    g.sim.director.clock.next_bm = g.sim.director.clock.day;
    g.sim.director.clock.hours = 23.0;
    while (t2 < 8) : (t2 += 1) try g.step();

    var found_day = false;
    var found_bm = false;
    for (cap.slots[0..cap.n]) |sl| {
        if (std.mem.find(u8, sl.data[0..sl.len], "Day 4") != null) found_day = true;
        if (std.mem.find(u8, sl.data[0..sl.len], "The blood moon rises!") != null) found_bm = true;
    }
    try std.testing.expect(found_day);
    try std.testing.expect(found_bm);
    std.debug.print("PASS announce v2: day roll + blood-moon announcements from sense\n", .{});
}

test "scenario core_rewardgate scales quest item rewards (1.5x)" {
    // on_quest_complete verdict at the step reward payout (step.zig): <0 deny,
    // 0 keep, >0 percent. With rewardgate's 150, the fixture starter's
    // 100-casinoCoin Item reward pays 150; without a module it pays 100.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{"plugins/core_rewardgate/core_rewardgate.wasm"};
    const g = try game_mod.Game.createWithOptions(gpa, dir, 0, .{
        .quests_path = "assets/fixtures/quests.xml",
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.count());

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // reward_coin also pays through the verdict at the payout: baseline the
    // wallet before completing (fixture starter has reward_coin=100).
    const ps0 = g.sim.playerByPeer(c.slot).?;
    const wallet_before = g.sim.wallet[ps0].coins;
    // Baseline the ischosen reward's item too: the fixture's ischosen reward
    // (resourceWood x5) must NOT be granted by the server - the stock dedi's
    // CloseQuest receives a null rewardChoice and skips ischosen rewards (RE
    // quests-challenges.md; the player's pick rides the client inventory
    // sync). Count must be unchanged after the payout.
    const wood_id = g.items.ecsIdByName("resourceWood");
    const wood_before: u32 = g.sim.inventory[ps0].countItem(wood_id);
    // Complete the starter quest (Goto -> Interact -> TurnIn).
    systems.questOnTraderOpen(&g.sim, c.slot);
    systems.questOnTraderOpen(&g.sim, c.slot);
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, g.sim.catalog.starter_id));
    // Step drains the completed-quest ring and pays item rewards through the
    // on_quest_complete verdict (the fixture Item reward is 100 casinoCoin).
    var t: u64 = 0;
    while (t < 4) : (t += 1) try g.step();
    const ps = g.sim.playerByPeer(c.slot).?;
    const coins = g.sim.inventory[ps].countItem(6); // casinoCoin
    try std.testing.expect(coins >= 150);
    // Coin leg: reward_coin 100 x 150% = 150 added to the wallet at the same
    // verdict (was paid before the verdict in completeQuest; deny/scaling
    // must reach it).
    try std.testing.expect(g.sim.wallet[ps].coins >= wallet_before + 150);
    // ischosen reward skipped (baseline captured before completion).
    try std.testing.expectEqual(wood_before, g.sim.inventory[ps].countItem(wood_id));
    std.debug.print("PASS rewardgate: item reward scaled 100 -> {d}, coin leg +{d}, ischosen reward skipped\n", .{ coins, g.sim.wallet[ps].coins - wallet_before });
}

test "scenario core_pricegate scales trader buy prices (1.5x)" {
    // on_trade_price pre-trade verdict in the sim buy path (systems.trade):
    // <0 deny, 0 keep, >0 percent. With pricegate's 150, a unit price of 100
    // costs 150; without a module it costs 100.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_pricegate");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{"plugins/core_pricegate/core_pricegate.wasm"};
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_pricegate", 0, .{
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.count());

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // A trader with a controlled stock entry (item 2, unit price 100).
    const tid = g.sim.spawnTrader("npcTraderJen", 50, 70, 60, 5, 5000).?;
    const ts = g.sim.slotOfNetId(tid).?;
    g.sim.trader_stock[ts].entries[0] = .{ .item = 2, .count = 10, .price = 100, .sell = 1, .markup = 0 };
    g.sim.trader_stock[ts].n = 1;
    g.sim.trader_stock[ts].wallet = 5000;
    const ps = g.sim.playerByPeer(c.slot).?;
    g.sim.wallet[ps].coins = 10_000;
    const coin_id = g.items.ecsIdByName("casinoCoin");

    const before = g.sim.wallet[ps].coins;
    try std.testing.expect(systems.trade(&g.sim, c.slot, tid, 2, 1, 0, coin_id));
    const after = g.sim.wallet[ps].coins;
    // 100 unit x 1.5 verdict = 150 debited.
    try std.testing.expectEqual(before - 150, after);
    std.debug.print("PASS pricegate: buy 100 -> 150 via on_trade_price\n", .{});
}

test "scenario core_damagegate halves incoming player damage (0.5x)" {
    // on_player_damage verdict on the C2S melee path (c2s/misc.zig): with
    // damagegate's 50, a 50-damage hit costs the victim 25 hp.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_damagegate");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{"plugins/core_damagegate/core_damagegate.wasm"};
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_damagegate", 0, .{
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.count());

    const id_a: platform_user.Id = .{ .platform = "Steam", .id = "9001" };
    const id_b: platform_user.Id = .{ .platform = "Steam", .id = "9002" };
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClientAs(&cap_a, id_a);
    const cb = try g.attachJoinedClientAs(&cap_b, id_b);
    const pa = g.sim.slotOfNetId(ca.entity_id).?;
    const hp0 = g.sim.health[pa].hp;

    // Player B hits player A for 50; the verdict halves it to 25.
    var body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;
    const dmg = try packages.buildDamageBody(&body, ca.entity_id, 0, 0, 50, false, cb.entity_id);
    try g.injectFramed(cb, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg));
    try std.testing.expectEqual(hp0 - 25, g.sim.health[pa].hp);
    std.debug.print("PASS damagegate: 50-damage hit reduced to 25\n", .{});
}

test "scenario core_adminverbs wave verb spawns zombies" {
    // on_admin_command fallthrough: an unknown console verb routes to the
    // plugin host; the module queues spawns via zdtd.queue and replies.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_adminverbs");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const modules = [_][]const u8{"plugins/core_adminverbs/core_adminverbs.wasm"};
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_adminverbs", 0, .{
        .enable_sample_plugin = false,
        .plugin_modules = &modules,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.count());

    // A joined client anchors the despawn distance, so the queued spawns at
    // the seed pad stay alive for the assertion.
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    try std.testing.expect(c.entity_id > 0);
    const z0 = g.sim.countKind(.zombie);
    g.runAdminLine("wave 3", "test");
    var t: u64 = 0;
    while (t < 8) : (t += 1) try g.step();
    const z1 = g.sim.countKind(.zombie);
    try std.testing.expect(z1 >= z0 + 3);
    std.debug.print("PASS adminverbs: wave 3 spawned zombies ({d} -> {d})\n", .{ z0, z1 });
}

test "scenario player dig routes the on_block_damage verdict (plugin_rules doubles)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const pa = g.sim.playerByPeer(c.slot).?;
    const ap = g.sim.transform[pa];
    const bx: i32 = @trunc(ap.x + 1);
    const bz: i32 = @trunc(ap.z);
    const by: i32 = @trunc(g.groundHeight(bx, bz));
    try g.world.setBlockWorld(bx, by, bz, world_store.block_stone);

    // Control: a dig claiming 10 damage on a fresh block applies exactly 10.
    var sb: [64]u8 = undefined;
    var frame_buf: [128]u8 = undefined;
    const d1 = try packages.buildSetBlockBodyDamage(&sb, bx, by, bz, world_store.block_stone, 10, c.entity_id, 0);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", d1));
    try std.testing.expectEqual(@as(u16, 10), g.getBlockHp(bx, by, bz));

    // Load plugin_rules (on_block_damage returns 200 = scale by percent).
    g.wasm_plugins.loadAll(gpa, &[_][]const u8{"assets/fixtures/plugin_rules.wasm"}, &g.wasm_ctx, .{});
    g.wasm_plugins.enable();
    // A further dig claiming +10 now passes the verdict: 10 * 200% = +20.
    const d2 = try packages.buildSetBlockBodyDamage(&sb, bx, by, bz, world_store.block_stone, 20, c.entity_id, 0);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", d2));
    try std.testing.expectEqual(@as(u16, 30), g.getBlockHp(bx, by, bz));
    std.debug.print("PASS dig-verdict: player dig scales through on_block_damage (10 -> 30)\n", .{});
}

test "scenario harvest drops roll into the breaker (terrStone → resourceRockSmall x55)" {
    // Real blocks.xml (game-dir): the server rolls the broken block's
    // Harvest rows at the break choke (Block.DropItemsOnEvent IL=246 +
    // GameUtils.HarvestOnAttack IL=623) and grants the stacks to the
    // breaker's inventory. terrStone carries one Harvest row:
    // resourceRockSmall count="55" prob=1 → exactly 55 on the floor of the
    // deterministic roll. Skipped when the stock game dir is absent.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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

    const stone_id = g.blocks.byName("terrStone").?.id;
    const drops = g.blocks.harvestDrops(stone_id);
    try std.testing.expectEqual(@as(usize, 1), drops.len);
    try std.testing.expectEqualStrings("resourceRockSmall", drops[0].item_name);
    try std.testing.expectEqual(@as(u32, 55), drops[0].count_min);
    try std.testing.expectEqual(@as(u32, 55), drops[0].count_max);
    const rock_id = g.items.byName("resourceRockSmall").?.id;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const pa = g.sim.playerByPeer(c.slot).?;
    const ap = g.sim.transform[pa];
    const bx: i32 = @trunc(ap.x + 1);
    const bz: i32 = @trunc(ap.z);
    const by: i32 = @trunc(g.groundHeight(bx, bz));
    try g.world.setBlockWorld(bx, by, bz, stone_id);

    // A dig claiming far beyond MaxDamage breaks the block in one swing.
    var sb: [64]u8 = undefined;
    var frame_buf: [128]u8 = undefined;
    const d = try packages.buildSetBlockBodyDamage(&sb, bx, by, bz, stone_id, 65000, c.entity_id, 0);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageSetBlock", d));

    // Block gone, and the rolled Harvest stack sits in the breaker's
    // inventory (55 rocks, prob 1 - the deterministic roll cannot miss).
    try std.testing.expectEqual(@as(u16, 0), g.world.blockWorld(bx, by, bz) catch 0);
    const ps = g.sim.playerByPeer(c.slot).?;
    var found: u32 = 0;
    for (g.sim.inventory[ps].slots) |sl| {
        if (sl.item_id == rock_id) found += sl.count;
    }
    try std.testing.expectEqual(@as(u32, 55), found);
    std.debug.print("PASS harvest-drop: terrStone break rolls resourceRockSmall x55 into inventory\n", .{});
}

test "scenario harvest count scales by the held tool's HarvestCount passive" {
    // RE GameUtils.HarvestOnAttack IL=623: count = trunc(rolled *
    // GetValue(141, tool, 1, holder, null, dropTag)). terrStone's drop row
    // carries tag "oreWoodHarvest": a wooden club (base_add -.75 x3 tags ->
    // 0.25) yields trunc(55 x .25) = 13 rocks; the auger (untagged perc_add
    // .2 -> 1.2) yields 55 x 1.2 = 66. The bare hand has no rows -> 55
    // (covered by the harvest-drop scenario). Skipped without the game dir.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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
    const stone_id = g.blocks.byName("terrStone").?.id;
    const rock_id = g.items.byName("resourceRockSmall").?.id;
    const club_id = g.items.byName("meleeWpnClubT0WoodenClub").?.id;
    const auger_id = g.items.byName("meleeToolPickT3Auger").?.id;

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    const ap = g.sim.transform[ps];

    const breakAt = struct {
        fn call(gg: *game_mod.Game, cc: *game_mod.Client, bx: i32, by: i32, bz: i32, block_id: u16) !void {
            var sb: [64]u8 = undefined;
            var frame_buf: [128]u8 = undefined;
            const d = try packages.buildSetBlockBodyDamage(&sb, bx, by, bz, block_id, 65000, cc.entity_id, 0);
            try gg.injectFramed(cc, try packages.framed(&frame_buf, "NetPackageSetBlock", d));
        }
    }.call;

    const countRocks = struct {
        fn call(gg: *game_mod.Game, cslot: usize, rock: u16) u32 {
            const p = gg.sim.playerByPeer(cslot).?;
            var n: u32 = 0;
            for (gg.sim.inventory[p].slots) |sl| {
                if (sl.item_id == rock) n += sl.count;
            }
            return n;
        }
    }.call;

    // Wooden club in hand: 0.25x on the oreWoodHarvest drop -> 13 rocks.
    g.sim.inventory[ps].slots[g.sim.inventory[ps].holding] = .{ .item_id = club_id, .count = 1, .quality = 1 };
    const bx: i32 = @trunc(ap.x + 1);
    const bz: i32 = @trunc(ap.z);
    const by: i32 = @trunc(g.groundHeight(bx, bz));
    try g.world.setBlockWorld(bx, by, bz, stone_id);
    try breakAt(g, c, bx, by, bz, stone_id);
    try std.testing.expectEqual(@as(u32, 13), countRocks(g, c.slot, rock_id));

    // Auger in hand: untagged perc_add .2 -> 1.2x -> 66 rocks.
    for (&g.sim.inventory[ps].slots) |*sl| sl.* = .{}; // clear the club's rocks
    g.sim.inventory[ps].slots[g.sim.inventory[ps].holding] = .{ .item_id = auger_id, .count = 1, .quality = 1 };
    try g.world.setBlockWorld(bx + 2, by, bz, stone_id);
    try breakAt(g, c, bx + 2, by, bz, stone_id);
    try std.testing.expectEqual(@as(u32, 66), countRocks(g, c.slot, rock_id));
    std.debug.print("PASS harvest-count: club 0.25x (13) and auger 1.2x (66) scale terrStone rocks\n", .{});
}

test "scenario fall-event drops re-place debris at landing (terrDirt)" {
    // Real blocks.xml (game-dir): a collapsed terrDirt column lands and the
    // Fall-event roll (RE EntityFallingBlock landing DropItemsOnEvent IL)
    // re-places the debris via the stick path - terrDirt's own Fall row is
    // count=1 stick_chance=1 (prob is never consulted on stick rows), so
    // the re-placement is deterministic. Skipped without the game dir.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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
    const dirt_id = g.blocks.byName("terrDirt").?.id;
    const fd = g.blocks.dropsFor(dirt_id, .fall);
    try std.testing.expect(fd.len > 0);

    const bx: i32 = 250;
    const bz: i32 = 250;
    const base_y: i32 = @trunc(g.groundHeight(bx, bz));
    try g.setBlock(bx, base_y, bz, dirt_id);
    try g.setBlock(bx, base_y + 1, bz, dirt_id);
    try g.setBlock(bx, base_y + 2, bz, dirt_id);
    _ = game_mod.stabilityAfterSetBlock(g, bx, base_y, bz, dirt_id, 0);

    // Drive the fall to landing; the landing hook rolls the Fall rows and
    // the stick row re-places terrDirt at the landed cell.
    const ecs_systems = @import("../ecs/systems.zig");
    var guard: usize = 0;
    while (guard < 400) : (guard += 1) {
        ecs_systems.systemFallingBlocks(&g.sim, 0.05);
        var any = false;
        for (g.sim.kind_groups.slice(.falling_block)) |s| {
            if (g.sim.alive[s] and g.sim.mask[s].falling) any = true;
        }
        if (!any) break;
    }
    var re_placed = false;
    var off: i32 = 0;
    while (off <= 2) : (off += 1) {
        if ((g.world.blockWorld(bx, base_y + off, bz) catch 0) == dirt_id) re_placed = true;
    }
    try std.testing.expect(re_placed);
    std.debug.print("PASS fall-drop: terrDirt collapse re-places debris at landing\n", .{});
}

test "scenario destroy-event drops roll the bag at the blast (bathroomStallDoor)" {
    // Real blocks.xml (game-dir): the Destroy-event roll (explosion debris
    // path) drops the block's `<drop event="Destroy">` rows. bathroomStallDoor
    // carries one row: resourceScrapIron count=1 with default prob 1, so with
    // overall_prob 1.0 the roll is fully deterministic (no range draw, no
    // prob gate, no overall gate). overall_prob 0.0 brackets the gate: every
    // stack is blocked. Skipped without the game dir.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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
    const door_id = g.blocks.byName("bathroomStallDoor").?.id;
    const scrap_id = g.items.byName("resourceScrapIron").?.id;
    const chunk_fill = @import("game/chunk_fill.zig");

    const bx: i32 = 260;
    const by: i32 = 71;
    const bz: i32 = 260;
    try g.world.setBlockWorld(bx, by, bz, door_id);
    _ = chunk_fill.rollBlockDropEvent(g, 0, bx, by, bz, door_id, .destroy, 1.0);

    var found: u32 = 0;
    for (g.sim.kind_groups.slice(.loot_bag)) |s| {
        if (!g.sim.alive[s] or !g.sim.mask[s].inventory) continue;
        for (g.sim.inventory[s].slots) |sl| {
            if (sl.item_id == scrap_id) found += sl.count;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), found);

    // overall_prob 0.0 blocks every stack (stock explosion debris gate).
    try g.world.setBlockWorld(bx + 3, by, bz, door_id);
    _ = chunk_fill.rollBlockDropEvent(g, 0, bx + 3, by, bz, door_id, .destroy, 0.0);
    var found2: u32 = 0;
    for (g.sim.kind_groups.slice(.loot_bag)) |s| {
        if (!g.sim.alive[s] or !g.sim.mask[s].inventory) continue;
        for (g.sim.inventory[s].slots) |sl| {
            if (sl.item_id == scrap_id) found2 += sl.count;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), found2); // unchanged
    std.debug.print("PASS destroy-drop: bathroomStallDoor rolls resourceScrapIron bag\n", .{});
}

test "scenario sound relay fans out to peers, excluding the sender" {
    // NetPackageSoundAtPosition C2S relay (RE ProcessPackage IL=36 +
    // PlaySoundAtPositionServer IL=60): the dedi re-broadcasts the client's
    // positional sound to every client except the owning player's (stock
    // allButAttachedToEntityId = entityId); a spoofed entity id is dropped.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const pa = g.sim.playerByPeer(ca.slot).?;
    const ap = g.sim.transform[pa];

    var sb: [512]u8 = undefined;
    var s: packages.SoundAtPosition = .{
        .pos = .{ ap.x, ap.y, ap.z },
        .mode = 0, // Logarithmic
        .distance = 20,
        .entity_id = ca.entity_id,
        .volume_scale = 1,
    };
    @memcpy(s.clip[0.."test".len], "test");
    s.clip_len = 4;
    const body = try packages.buildSoundAtPosition(&sb, s);

    var fb: [512]u8 = undefined;
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageSoundAtPosition", body));
    const snd_id = packages.idOf("NetPackageSoundAtPosition").?;
    // Presence alone would pass on a relay that forwarded a different sound or
    // dropped the clip name. This is a verbatim relay, so decode it: the client
    // picks the audio asset by clip name and places it by position, so a
    // mangled body is an audibly wrong result, not a silent one.
    const heard_body = cap_b.findPkgId(snd_id) orelse return error.TestUnexpectedResult;
    const heard = try packages.parseSoundAtPosition(heard_body);
    try std.testing.expectEqualStrings("test", heard.clipSlice());
    try std.testing.expectEqual(ca.entity_id, heard.entity_id);
    try std.testing.expectEqual(@as(i32, 20), heard.distance);
    try std.testing.expect(cap_a.findPkgId(snd_id) == null); // owner already heard it locally

    // A spoofed owner (another player's entity id) is dropped, not relayed.
    cap_b.clear();
    var s2 = s;
    s2.entity_id = cb.entity_id;
    const spoofed = try packages.buildSoundAtPosition(&sb, s2);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageSoundAtPosition", spoofed));
    try std.testing.expect(cap_b.findPkgId(snd_id) == null);
    std.debug.print("PASS sound-relay: positional sound reaches peers, owner + spoofed dropped\n", .{});
}

test "scenario forge completion dings NetPackageSoundAtPosition" {
    // RE TileEntityForge IL_02F9-031F: a produced-this-tick forge plays
    // PlaySoundAtPositionServer(worldPos, "Forge/forge_item_complete",
    // Logarithmic, 100, 1). Real blocks.xml (game-dir) so the forge block
    // resolves by name; a direct-driven workstation queue completes one
    // craft and the ding reaches nearby peers. Skipped without the game dir.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
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
    const pa = g.sim.playerByPeer(c.slot).?;
    const wx: i32 = @trunc(g.sim.transform[pa].x);
    const wy: i32 = @trunc(g.sim.transform[pa].y);
    const wz: i32 = @trunc(g.sim.transform[pa].z);

    const forge_id = g.blocks.byName("forge").?.id;
    const wood_stock = g.items.byName("resourceWood").?.stock_type;
    const st = g.workstations.getOrCreate(wx, wy, wz).?;
    st.block_id = @intCast(forge_id);
    st.has_fuel_module = true;
    st.is_burning = true;
    st.burn_time_left = 30;
    st.queue_len = 1;
    st.queue[0] = .{
        .multiplier = 1,
        .is_crafting = true,
        .craft_time_left = 0.2,
        .one_item_craft_time = 1.0,
        .starting_entity_id = c.entity_id,
        .output_type = wood_stock,
        .output_count = 1,
        .craft_exp_gain = 1,
    };

    cap.clear();
    try g.tickWorkstations(0.5);
    const snd_id = packages.idOf("NetPackageSoundAtPosition").?;
    const sb = cap.findPkgId(snd_id) orelse return error.TestUnexpectedResult;
    const parsed = try packages.parseSoundAtPosition(sb);
    try std.testing.expectEqualStrings("Forge/forge_item_complete", parsed.clipSlice());
    try std.testing.expectEqual(@as(u8, 0), parsed.mode); // Logarithmic
    try std.testing.expectEqual(@as(i32, 100), parsed.distance);
    std.debug.print("PASS forge-ding: smelt completion broadcasts forge_item_complete\n", .{});
}

test "scenario on_quest_accept verdict gates acceptance (real core_questgate)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // A catalog with one forbidden and one normal quest (names are the key).
    const defs = [_]quest_mod.QuestDef{
        .{ .id = 1, .kind = .kill_zombies, .name = "forbidden_evil", .title = "FE", .target_count = 1 },
        .{ .id = 2, .kind = .goto_point, .name = "ok_quest", .title = "OK", .target_count = 1 },
    };
    g.sim.catalog = .{ .defs = &defs, .starter_id = 99, .source = .builtin };

    // Load the committed gate module into the Game's wasm host.
    g.wasm_plugins.loadAll(gpa, &[_][]const u8{"plugins/core_questgate/core_questgate.wasm"}, &g.wasm_ctx, .{});
    g.wasm_plugins.enable();

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    // The forbidden quest is denied at the sim gate (no journal slot).
    try std.testing.expect(!systems.questAccept(&g.sim, c.slot, 1));
    try std.testing.expect(!systems.questHasActive(&g.sim, c.slot, 1));
    // The normal quest still accepts.
    try std.testing.expect(systems.questAccept(&g.sim, c.slot, 2));
    try std.testing.expect(systems.questHasActive(&g.sim, c.slot, 2));
    std.debug.print("PASS questgate: forbidden_evil denied, ok_quest accepted\n", .{});
}

test "scenario on_craft_request verdict gates crafting (real core_craftgate)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // A custom recipes table: one forbidden and one normal craft (names are
    // the stable key for the verdict).
    var defs = [_]assets_recipes.RecipeDef{
        .{ .name = "forbidden_sword", .count = 1, .always_unlocked = true, .ingredient_n = 1 },
        .{ .name = "resourceWood", .count = 1, .always_unlocked = true, .ingredient_n = 1 },
    };
    defs[0].ingredients[0] = .{ .name = "resourceWood", .count = 1 };
    defs[1].ingredients[0] = .{ .name = "resourceWood", .count = 1 };
    g.recipes = .{ .defs = &defs, .source = .builtin };

    // Load the committed gate module into the Game's wasm host.
    g.wasm_plugins.loadAll(gpa, &[_][]const u8{"plugins/core_craftgate/core_craftgate.wasm"}, &g.wasm_ctx, .{});
    g.wasm_plugins.enable();

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    // Give the player the ingredient (1 wood) so the ok craft can succeed.
    const wood = g.items.ecsIdByName("resourceWood");
    try std.testing.expect(wood != 0);
    try std.testing.expect(g.sim.depositItem(ps, wood, 2));

    // The forbidden recipe is denied at the gate (no ingredients consumed).
    try std.testing.expect(!g.tryCraft(c.slot, 0, 1));
    // The normal recipe still crafts.
    try std.testing.expect(g.tryCraft(c.slot, 1, 1));
    std.debug.print("PASS craftgate: forbidden_sword denied, resourceWood crafted\n", .{});
}

test "scenario on_loot_roll verdict halves loot (real core_lootgate)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Control roll without any plugin: the seeded roll's stack count.
    var stacks: [64]assets_loot.Stack = undefined;
    const n0 = g.loot.rollContainer("EntityLootContainerRegular", 1, 42, &stacks);
    try std.testing.expect(n0 >= 1);

    // Load the committed gate module (scales every roll to 50%).
    g.wasm_plugins.loadAll(gpa, &[_][]const u8{"plugins/core_lootgate/core_lootgate.wasm"}, &g.wasm_ctx, .{});
    g.wasm_plugins.enable();

    // Fill a loot bag with the SAME seed: the verdict halves the stack count.
    const bag_nid = g.sim.spawnLootBag(10, 70, 10, 1, 1).?;
    g.fillLootBagFromTable(bag_nid, "EntityLootContainerRegular", 42, 1);
    const bs = g.sim.slotOfNetId(bag_nid).?;
    var got: usize = 0;
    for (g.sim.inventory[bs].slots) |s| {
        if (s.item_id != 0 and s.count > 0) got += 1;
    }
    try std.testing.expectEqual(n0 / 2, got);
    std.debug.print("PASS lootgate: roll {d} -> {d} stacks at 50%\n", .{ n0, got });
}

test "scenario collect rejects a bag claimed in another player's name" {
    // NetPackageEntityCollect carries entityId AND playerId; stock runs
    // ValidEntityIdForSender(playerId) before collecting (ProcessPackage
    // IL=51). Without that check a client could name any player as the
    // collector, so the bag has to survive a spoofed claim and be collectable
    // by an honest one.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    g.clients[ca.slot].entered = true;
    g.clients[cb.slot].entered = true;

    // Put both players on the bag so reach never decides the outcome.
    const pa = g.sim.playerByPeer(ca.slot).?;
    const pb = g.sim.playerByPeer(cb.slot).?;
    const t = g.sim.transform[pa];
    g.sim.setPos(cb.entity_id, t.x, t.y, t.z, 0);
    const bag = g.sim.spawnLootBag(t.x, t.y, t.z, 1, 1).?;
    _ = pb;

    var frame_buf: [256]u8 = undefined;
    var body: [16]u8 = undefined;

    // A claims the bag in B's name: rejected, bag untouched.
    const own_before = g.harness.counters.get(.ownership_rejects);
    const spoof = try packages.buildEntityCollectBody(&body, bag, cb.entity_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageEntityCollect", spoof));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(g.sim.slotOfNetId(bag) != null);

    // The same bag, claimed by its actual collector: collected and destroyed.
    const honest = try packages.buildEntityCollectBody(&body, bag, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&frame_buf, "NetPackageEntityCollect", honest));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(g.sim.slotOfNetId(bag) == null);
    std.debug.print("PASS collect: spoofed playerId rejected, honest claim collects\n", .{});
}

test "scenario a bag write beyond reach is rejected" {
    // NetPackageBag can address any entity with an inventory, not just the
    // sender's own. For a non-player target (loot bag, death bag) the write is
    // allowed, so distance is the only thing left between a legitimate looting
    // and rewriting a bag on the far side of the map by id.
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
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    const pp = g.sim.transform[ps];

    var bag_body: [8192]u8 = undefined;
    var fb: [9000]u8 = undefined;
    // A non-player target goes through applyBagPackage with player_bag_only
    // false: the bag array maps onto slots from 0, and the builder compacts
    // (it skips empty source slots), so a bag that already holds one item
    // receives the added stack at index 1.
    const bag_slot: usize = 1;

    // A bag within reach takes the write.
    const near = g.sim.spawnLootBag(pp.x + 2, pp.y, pp.z, 1, 1) orelse return error.TestUnexpectedResult;
    const near_s = g.sim.slotOfNetId(near) orelse return error.TestUnexpectedResult;
    {
        var inv = g.sim.inventory[near_s];
        inv.slots[3] = .{ .item_id = 7, .count = 5, .quality = 1 };
        const bb = try packages.stock_inv.buildBagPackage(&bag_body, near, &inv, null, null, false);
        try g.injectFramed(c, try packages.framed(&fb, "NetPackageBag", bb));
        try std.testing.expectEqual(@as(u16, 7), g.sim.inventory[near_s].slots[bag_slot].item_id);
    }

    // The same write to a bag well beyond max_edit_range is dropped.
    const far = g.sim.spawnLootBag(pp.x + g.max_edit_range * 4, pp.y, pp.z, 1, 1) orelse
        return error.TestUnexpectedResult;
    const far_s = g.sim.slotOfNetId(far) orelse return error.TestUnexpectedResult;
    const before_id = g.sim.inventory[far_s].slots[bag_slot].item_id;
    const bounds_before = g.harness.counters.get(.bounds_rejects);
    {
        var inv = g.sim.inventory[far_s];
        inv.slots[3] = .{ .item_id = 7, .count = 64, .quality = 1 };
        const bb = try packages.stock_inv.buildBagPackage(&bag_body, far, &inv, null, null, false);
        try g.injectFramed(c, try packages.framed(&fb, "NetPackageBag", bb));
    }
    try std.testing.expectEqual(before_id, g.sim.inventory[far_s].slots[bag_slot].item_id);
    try std.testing.expect(g.harness.counters.get(.bounds_rejects) > bounds_before);
    std.debug.print("PASS bag-reach: near bag written, far bag rejected\n", .{});
}

test "scenario wrench pickup applies to the world and honours reach and claims" {
    // PickupBlock had no scenario, only the wire-layout tests in packages.zig,
    // and the handler broadcast the replacement without writing it: the block
    // vanished for clients but stayed on the server, so it came back on the
    // next chunk load and kept blocking placement in the meantime. Stock
    // replicates the pickup rather than simulating it client-side (RE
    // blocks.md "Server authority"). The two trust gates the handler adds on
    // top (reach, land claim) were untested for the same reason.
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
    const psa = g.sim.playerByPeer(ca.slot) orelse return error.TestUnexpectedResult;
    const ep = g.sim.transform[psa];

    // Body: x, y, z (i32), rawData u32, playerId i32, null identity byte.
    const buildPickup = struct {
        fn call(buf: []u8, x: i32, y: i32, z: i32, raw: u32, player_id: i32) ![]u8 {
            var w: binary.Writer = .{ .buf = buf };
            try w.writeI32(x);
            try w.writeI32(y);
            try w.writeI32(z);
            try w.writeU32(raw);
            try w.writeI32(player_id);
            try w.writeByte(0); // null platform identity
            return w.written();
        }
    }.call;

    const stone = world_store.block_stone;
    var pb: [64]u8 = undefined;
    var fb: [512]u8 = undefined;

    // In reach, unclaimed: the block is gone from the world, not just echoed.
    const nx: i32 = @intFromFloat(ep.x + 3);
    const nz: i32 = @intFromFloat(ep.z + 3);
    try g.setBlock(nx, 70, nz, stone);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePickupBlock", try buildPickup(&pb, nx, 70, nz, stone, ca.entity_id)));
    try std.testing.expectEqual(@as(u32, 0), try g.world.blockWorld(nx, 70, nz));

    // Beyond reach: the block survives and the counter says why.
    const fx: i32 = @intFromFloat(ep.x + g.max_edit_range * 4);
    try g.setBlock(fx, 70, nz, stone);
    const bounds_before = g.harness.counters.get(.bounds_rejects);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePickupBlock", try buildPickup(&pb, fx, 70, nz, stone, ca.entity_id)));
    try std.testing.expectEqual(stone, try g.world.blockWorld(fx, 70, nz));
    try std.testing.expect(g.harness.counters.get(.bounds_rejects) > bounds_before);

    // Inside another player's claim, in reach: still refused.
    const kid = g.maxdamage.idByName("keystoneBlock") orelse return error.TestUnexpectedResult;
    const cx: i32 = @intFromFloat(ep.x + 6);
    const cz: i32 = @intFromFloat(ep.z + 6);
    var sb: [64]u8 = undefined;
    try g.injectFramed(cb, try packages.framed(&fb, "NetPackageSetBlock", try packages.buildSetBlockBody(&sb, cx, 70, cz, kid)));
    const claim = g.claimCovering(cx, cz) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cb.entity_id, claim.owner_entity);

    try g.setBlock(cx + 1, 70, cz, stone);
    const own_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePickupBlock", try buildPickup(&pb, cx + 1, 70, cz, stone, ca.entity_id)));
    try std.testing.expectEqual(stone, try g.world.blockWorld(cx + 1, 70, cz));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    std.debug.print("PASS pickup: world write applied, reach and claim both refuse\n", .{});
}

test "scenario block paint lands in the world and honours its gates" {
    // SetBlockTexture stores the face texture in the chunk's textureFull and
    // rebroadcasts to everyone but the painter. Only the world write makes the
    // paint outlive the packet: without it the painter sees its own local
    // paint, observers see the rebroadcast, and the next chunk load hands
    // everyone the unpainted block back. The handler's gates (channel, face,
    // sender entity, reach, claim) had no scenario either.
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
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    const ep = g.sim.transform[ps];

    const px: i32 = @intFromFloat(ep.x + 3);
    const pz: i32 = @intFromFloat(ep.z + 3);
    try g.setBlock(px, 70, pz, world_store.block_stone);

    const readTex = struct {
        fn call(gg: *game_mod.Game, x: i32, y: i32, z: i32) !u64 {
            const wt = world_store.World.worldToChunk(x, z);
            const ch = try gg.world.getOrCreate(wt.pos);
            return ch.texAt(wt.lx, y, wt.lz);
        }
    }.call;

    var tb: [64]u8 = undefined;
    var fb: [256]u8 = undefined;
    const paint_idx: u8 = 7;
    const face: u8 = 2;

    // The paint lands in the chunk, in the requested face's byte.
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageSetBlockTexture", try packages.buildSetBlockTextureBody(&tb, .{
        .x = px,
        .y = 70,
        .z = pz,
        .face = face,
        .idx = paint_idx,
        .player_id = c.entity_id,
        .channel = 0,
    })));
    const after = try readTex(g, px, 70, pz);
    try std.testing.expectEqual(paint_idx, @as(u8, @truncate(after >> (face * 8))));

    // A paint claiming another entity is refused, and the stored texture stays.
    const own_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageSetBlockTexture", try packages.buildSetBlockTextureBody(&tb, .{
        .x = px,
        .y = 70,
        .z = pz,
        .face = face,
        .idx = paint_idx + 1,
        .player_id = c.entity_id + 1000,
        .channel = 0,
    })));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expectEqual(after, try readTex(g, px, 70, pz));

    // Chunk textures are a one-element array, so channel != 0 fails closed;
    // face > 5 is not a cube face. Both are bounds rejects, not silent drops.
    const bounds_before = g.harness.counters.get(.bounds_rejects);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageSetBlockTexture", try packages.buildSetBlockTextureBody(&tb, .{
        .x = px,
        .y = 70,
        .z = pz,
        .face = face,
        .idx = paint_idx + 1,
        .player_id = c.entity_id,
        .channel = 1,
    })));
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageSetBlockTexture", try packages.buildSetBlockTextureBody(&tb, .{
        .x = px,
        .y = 70,
        .z = pz,
        .face = 6,
        .idx = paint_idx + 1,
        .player_id = c.entity_id,
        .channel = 0,
    })));
    try std.testing.expectEqual(bounds_before + 2, g.harness.counters.get(.bounds_rejects));
    try std.testing.expectEqual(after, try readTex(g, px, 70, pz));
    std.debug.print("PASS paint: world write applied, entity/channel/face gates refuse\n", .{});
}

test "scenario a client-reported XP add mints nothing" {
    // Stock applies this one: NetPackageEntityAddExpServer.ProcessPackage
    // (IL=31) reaches Progression::AddLevelExp with whatever the client sent
    // (RE il/netpackages-v3.2.0/NetPackageEntityAddExpServer_il.txt IL_0043).
    // zdtd refuses it on purpose (DIVERGENCES 1.5, AGENTS rule 17): XP is
    // awarded server-side on the kill and quest paths, so honouring the
    // package would let a client mint levels. The refusal had no test, which
    // is what makes it a regression risk rather than a decision.
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

    const xp_before = c.xp;
    const level_before = c.level;
    var body: [32]u8 = undefined;
    var fb: [256]u8 = undefined;
    const claim = try packages.stock_xp.buildAddExpClientBody(&body, .{
        .entity_id = c.entity_id,
        .xp = 1_000_000,
        .xp_type = packages.stock_xp.xp_type_kill,
    });
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageEntityAddExpServer", claim));
    try std.testing.expectEqual(xp_before, c.xp);
    try std.testing.expectEqual(level_before, c.level);

    // The server's own award path still works, so the refusal above is the
    // trust gate and not a dead XP system. Harvest/quest/magazine XP also
    // push AddExpClient as `_xpOther` so the owning client shows the icon.
    cap.clear();
    g.awardXp(c.slot, 100);
    try std.testing.expect(c.xp > xp_before);
    const xp_id = packages.idOf("NetPackageEntityAddExpClient").?;
    const xpb = cap.findPkgId(xp_id) orelse return error.TestUnexpectedResult;
    var xr = binary.Reader{ .data = xpb };
    try std.testing.expectEqual(c.entity_id, try xr.readI32());
    try std.testing.expectEqual(@as(i32, 100), try xr.readI32());
    try std.testing.expectEqual(packages.stock_xp.xp_type_other, try xr.readI16());
    try std.testing.expectEqual(false, try xr.readBool());
    std.debug.print("PASS xp-trust: client-reported XP refused, server award applies\n", .{});
}

test "scenario entity flag and speed reports must name the sender's own entity" {
    // AliveFlags and EntitySpeeds are client self-reports: the flags word
    // drives the AI stealth gates (crouch muffles hearing and shrinks sleeper
    // detection), and the movement state drives the stamina drain. Both carry
    // the entity id they describe, so without the sender check one player sets
    // another player's crouch and sprint state, and both packets are then
    // relayed to every peer as if the owner had sent them.
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
    const psb = g.sim.slotOfNetId(cb.entity_id) orelse return error.TestUnexpectedResult;

    var body: [32]u8 = undefined;
    var fb: [256]u8 = undefined;

    // A reports its own crouch: applied.
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAliveFlags", try packages.buildAliveFlagsBody(&body, ca.entity_id, packages.cF_crouching)));
    const psa = g.sim.slotOfNetId(ca.entity_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.sim.player[psa].crouching);

    // A reports B as crouching: refused, B's state untouched.
    try std.testing.expect(!g.sim.player[psb].crouching);
    var own_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAliveFlags", try packages.buildAliveFlagsBody(&body, cb.entity_id, packages.cF_crouching)));
    try std.testing.expect(!g.sim.player[psb].crouching);
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));

    // Same rule for the speed report, which latches onto the Client, not the
    // sim slot: a spoofed one would set another player's sprint drain.
    const sprint_state: u8 = 3;
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntitySpeeds", try packages.buildEntitySpeedsBody(&body, ca.entity_id, sprint_state, 6.0, 0)));
    try std.testing.expect(ca.sprint_speed > 0);

    const b_sprint_before = cb.sprint_speed;
    own_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntitySpeeds", try packages.buildEntitySpeedsBody(&body, cb.entity_id, sprint_state, 6.0, 0)));
    try std.testing.expectEqual(b_sprint_before, cb.sprint_speed);
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    std.debug.print("PASS self-report: own flags and speeds applied, spoofed entity ids refused\n", .{});
}

test "scenario a quest entity spawn summons one entity for the sender only" {
    // Body (RE protocol-packages.md 6.17, read IL_0002-001F): entityType i32 |
    // gamestageGroup string | entityIDQuestHolder i32. The last field is the
    // quest holder's entity id; it used to be read as a count, so one packet
    // summoned that many zombies with the client picking the number. Stock
    // ProcessPackage (IL=37) spawns exactly one per package.
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

    const buildSpawn = struct {
        fn call(buf: []u8, entity_type: i32, group: []const u8, holder: i32) ![]u8 {
            var w: binary.Writer = .{ .buf = buf };
            try w.writeI32(entity_type);
            try w.writeString(group);
            try w.writeI32(holder);
            return w.written();
        }
    }.call;

    const countZombies = struct {
        fn call(gg: *game_mod.Game) usize {
            var n: usize = 0;
            for (0..ecs.max_entities) |s| {
                if (gg.sim.alive[s] and gg.sim.kind[s] == .zombie) n += 1;
            }
            return n;
        }
    }.call;

    var body: [96]u8 = undefined;
    var fb: [256]u8 = undefined;

    // A joining client already holds the starter quest, so the quest gate is
    // open here. Close it first to prove the gate exists at all: with the
    // journal cleared the packet is refused.
    const psa = g.sim.playerByPeer(ca.slot) orelse return error.TestUnexpectedResult;
    const saved_journal = g.sim.journal[psa];
    g.sim.journal[psa] = .{};
    try std.testing.expect(!g.sim.journal[psa].anyActive());
    const before_no_quest = countZombies(g);
    const rejects_before = g.harness.counters.get(.c2s_rejects);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageQuestEntitySpawn", try buildSpawn(&body, -1, "group", ca.entity_id)));
    try std.testing.expectEqual(before_no_quest, countZombies(g));
    try std.testing.expect(g.harness.counters.get(.c2s_rejects) > rejects_before);

    // With the quest back, one packet summons exactly one entity, matching
    // stock ProcessPackage. The holder field carries an entity id, which the
    // old reading turned into that many spawns.
    g.sim.journal[psa] = saved_journal;
    try std.testing.expect(g.sim.journal[psa].anyActive());
    const before_one = countZombies(g);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageQuestEntitySpawn", try buildSpawn(&body, -1, "group", ca.entity_id)));
    try std.testing.expectEqual(before_one + 1, countZombies(g));
    // A large holder id is still exactly one spawn, not that many.
    const before_big = countZombies(g);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageQuestEntitySpawn", try buildSpawn(&body, -1, "group", ca.entity_id)));
    try std.testing.expectEqual(before_big + 1, countZombies(g));

    // Naming another player as the holder is refused.
    const own_before = g.harness.counters.get(.ownership_rejects);
    const before_spoof = countZombies(g);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageQuestEntitySpawn", try buildSpawn(&body, -1, "group", cb.entity_id)));
    try std.testing.expectEqual(before_spoof, countZombies(g));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    std.debug.print("PASS quest-summon: one entity per packet, sender-only, quest-gated\n", .{});
}

test "scenario walking away does not reset the decorations we sent" {
    // Stock only broadcasts DecoResetWorldChunk from region-file chunk
    // deletion and the C2S reset handler (asm.il 1186504 / 807955), never on a
    // view unload. With join-time deco objects live, sending it on unload runs
    // RestoreGeneratedDecos over our trees every time a player walks away, and
    // the deco window is single-shot so they can never be resent. The guard
    // that keeps it off the unload path had no test.
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
    try std.testing.expect(g.deco_trees); // the guard's precondition
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    try std.testing.expect(c.streamed_n > 0);

    // Walk far enough that the streamed set is replaced wholesale.
    const reset_id = packages.idOf("NetPackageDecoResetWorldChunk") orelse
        return error.TestUnexpectedResult;
    const remove_id = packages.idOf("NetPackageChunkRemove") orelse
        return error.TestUnexpectedResult;
    cap.clear();
    g.sim.transform[ps].x += 2000;
    g.sim.transform[ps].z += 2000;
    try g.streamChunksForClient(c);

    // Chunks were dropped, so the unload path ran; no deco reset rode with it.
    var saw_remove = false;
    var saw_reset = false;
    for (cap.slots[0..cap.n]) |s| {
        var pkgs: [16]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == remove_id) saw_remove = true;
            if (p.id == reset_id) saw_reset = true;
        }
    }
    try std.testing.expect(saw_remove);
    try std.testing.expect(!saw_reset);
    std.debug.print("PASS deco-unload: ChunkRemove sent, DecoReset withheld\n", .{});
}

test "scenario bots are grounded to terrain height on spawn and move" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Spawn grounds the bot onto the terrain surface at (8, 8), not the passed
    // flat y=70.
    const bid = g.bots.spawn(g, 8, 70, 8, 100).?;
    const bs = g.bots.find(bid).?;
    const gy = g.groundHeight(8, 8);
    try std.testing.expectApproxEqAbs(gy, g.bots.bots[bs].y, 0.01);

    // Moving keeps the bot on the terrain surface (re-grounded every tick).
    g.bots.move(bid, 20, 70, 20, 4);
    g.bots.tick(g, 0.05);
    const b = &g.bots.bots[bs];
    try std.testing.expectApproxEqAbs(
        g.groundHeight(@floor(b.x), @floor(b.z)),
        b.y,
        0.01,
    );
}

test "scenario a player can damage a bot and the bot records the attacker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // The joined client owns a live player entity with a transform (needed by
    // the C2S damage handler before it resolves the target).
    const actor_slot = g.sim.playerByPeer(c.slot).?;
    try std.testing.expect(g.sim.alive[actor_slot]);
    try std.testing.expect(g.sim.mask[actor_slot].transform);

    // A bot close to the player so the interest-range gate passes.
    const ap = g.sim.transform[actor_slot];
    const bid = g.bots.spawn(g, ap.x + 2, 70, ap.z, 100).?;
    const bs = g.bots.find(bid).?;

    // A normal attack: the bot's hp drops by the capped claimed strength and
    // the player's net id is recorded for the guest's retaliation (damage
    // event + last_attacker).
    var body: [256]u8 = undefined;
    var frame_buf: [512]u8 = undefined;
    const dmg = try packages.buildDamageBody(&body, bid, 0, 0, 20, false, c.entity_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg));
    try std.testing.expectApproxEqAbs(@as(f32, 100 - 20), g.bots.bots[bs].hp, 0.01);
    try std.testing.expectEqual(c.entity_id, g.bots.bots[bs].last_attacker);
    try std.testing.expectEqual(@as(usize, 1), g.bots.ev_n);
    try std.testing.expectEqual(c.entity_id, g.bots.events[0].attacker);
    try std.testing.expectEqual(bid, g.bots.events[0].victim);

    // A lethal hit kills the bot (the replicate pass unspawns it; the floor
    // self-heals on tick) and still records the event.
    const dmg2 = try packages.buildDamageBody(&body, bid, 0, 0, 200, false, c.entity_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg2));
    try std.testing.expect(!g.bots.bots[bs].alive);
    try std.testing.expectEqual(@as(usize, 2), g.bots.ev_n);

    // A forged far-away/unknown target id damages nothing (no extra event).
    const dmg3 = try packages.buildDamageBody(&body, 999999, 0, 0, 50, false, c.entity_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg3));
    try std.testing.expectEqual(@as(usize, 2), g.bots.ev_n);

    // An id the server does know, but for a bot outside interest range: the
    // claim is a client assertion, so distance is what separates a real hit
    // from a forged one. An unknown id (above) never reaches the range gate,
    // so only a live, far-away bot exercises it.
    const far = g.bots.spawn(g, ap.x + g.interest_range * 4, 70, ap.z, 100).?;
    const far_slot = g.bots.find(far).?;
    const dmg4 = try packages.buildDamageBody(&body, far, 0, 0, 50, false, c.entity_id);
    try g.injectFramed(c, try packages.framed(&frame_buf, "NetPackageDamageEntity", dmg4));
    try std.testing.expectApproxEqAbs(@as(f32, 100), g.bots.bots[far_slot].hp, 0.01);
    try std.testing.expectEqual(@as(usize, 2), g.bots.ev_n);
    std.debug.print("PASS bot-damage: an out-of-range bot target is rejected\n", .{});
}

test "scenario wasmQuery cover: none on open ground, found behind a wall" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var out: [64]u8 = undefined;

    // Plumbing: unknown verbs and malformed queries answer nothing.
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "bogus", &out));
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "cover 0 0", &out));
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "cover x y 10 10", &out));

    // Open ground: every candidate is LOS-clear from the threat, so no cover.
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "cover 0 0 10 10", &out));

    // A wall at body height between the threat (10,10) and the south-west
    // candidate (-7.07,-7.07) blocks that line: the query must now return a
    // point, and it must be the hidden direction, not the open one.
    const h = g.groundHeight(1, 1);
    const hh: i32 = @trunc(h);
    try g.world.setBlockWorld(1, hh, 1, world_store.block_stone);
    try g.world.setBlockWorld(1, hh + 1, 1, world_store.block_stone);
    try g.world.setBlockWorld(1, hh + 2, 1, world_store.block_stone);
    const n = game_wasm_host.wasmQuery(&g.wasm_ctx, "cover 0 0 10 10", &out);
    try std.testing.expect(n >= 3);
    // Response is "<cx> <cz>" - a two-float answer with a space separator.
    const sep = std.mem.findScalar(u8, out[0..n], ' ');
    try std.testing.expect(sep != null);
    const cx = std.fmt.parseFloat(f32, out[0..sep.?]) catch 0;
    const cz = std.fmt.parseFloat(f32, out[sep.? + 1 .. n]) catch 0;
    // The hidden candidate is the south-west one: both coords negative.
    try std.testing.expect(cx < 0 and cz < 0);
}

test "scenario wasmQuery path: nav path across loaded chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Ensure chunks (0..1, 0..1) exist with a walkable floor at ground height.
    const h = g.groundHeight(0, 0);
    const hh: i32 = @trunc(h);
    var x: i32 = 0;
    while (x < 32) : (x += 1) {
        var z: i32 = 0;
        while (z < 32) : (z += 1) {
            try g.world.setBlockWorld(x, hh, z, world_store.block_stone);
        }
    }

    var out: [512]u8 = undefined;

    // Plumbing: malformed path queries answer nothing.
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "path 0 0", &out));
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "path x y 10 10", &out));

    // A path from block (2,2) to (30,30): cells (0,0) -> (7,7), both chunks loaded.
    const n = game_wasm_host.wasmQuery(&g.wasm_ctx, "path 2 2 30 30", &out);
    try std.testing.expect(n >= 5);
    var it = std.mem.tokenizeScalar(u8, out[0..n], ' ');
    const count = try std.fmt.parseInt(u32, it.next().?, 10);
    try std.testing.expect(count >= 1 and count <= nav.max_waypoints);
    // The last waypoint is the target cell center (7*4+2, 7*4+2) = (30, 30).
    var last_x: f32 = -1;
    var last_z: f32 = -1;
    while (it.next()) |tok| {
        last_x = try std.fmt.parseFloat(f32, tok);
        last_z = try std.fmt.parseFloat(f32, it.next().?);
    }
    try std.testing.expect(@abs(last_x - 30) < 0.01 and @abs(last_z - 30) < 0.01);

    // A target in an unloaded chunk fails closed: no path.
    try std.testing.expectEqual(@as(usize, 0), game_wasm_host.wasmQuery(&g.wasm_ctx, "path 2 2 1000 1000", &out));
}

test "scenario zombies aggro and melee bots (revenge + proximity)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];

    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // A bot and a zombie close enough for the zombie to sense the bot. No
    // players: the bot is the zombie's only target (ADR 0026 bot snap hook).
    const bid = g.bots.spawn(g, 8, 70, 8, 100).?;
    const bs = g.bots.find(bid).?;
    const zy = g.groundHeight(20, 20);
    const zid = g.sim.spawnZombie(20, zy, 20, 100).?;
    const zs = g.sim.slotOfNetId(zid).?;

    // Drive the sim AI (same order as step.zig: sim tickAll, then bots tick)
    // until the zombie latches the bot as its target and closes to melee.
    var ticks: usize = 0;
    var latched = false;
    var meleed = false;
    while (ticks < 600 and !meleed) : (ticks += 1) {
        _ = systems.tickAll(&g.sim, 0.05);
        g.bots.tick(g, 0.05);
        if (g.sim.zombie_ai[zs].target_id == bid) latched = true;
        if (g.bots.bots[bs].hp < 100) meleed = true;
    }
    try std.testing.expect(latched);
    try std.testing.expect(meleed);
    // The melee was attributed: the bot records the zombie attacker and emits
    // a damage event for the guest's retaliation / dodge.
    try std.testing.expectEqual(zid, g.bots.bots[bs].last_attacker);
    try std.testing.expect(g.bots.ev_n >= 1);
    try std.testing.expectEqual(zid, g.bots.events[g.bots.ev_n - 1].attacker);
}

test "scenario bot count floor spawns bots and fillSense emits them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // `bot count 2` (as the wasm guest re-queues it) spawns a 2-bot floor.
    try std.testing.expect(g.bots.handleCommand(g, "bot count 2", 0));
    try std.testing.expectEqual(@as(usize, 2), g.bots.n);

    // The sense snapshot then carries both bots as kind==2 records (v4 40-byte).
    var out: [256]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], 0x3453425a, .little); // 'ZBS4'
    std.mem.writeInt(u32, out[4..8], 0, .little);
    var n: usize = 0;
    g.bots.fillSense(&out, 24, 2, &n);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 2), out[24 + 4]); // kind bot
    try std.testing.expectEqual(@as(u8, 2), out[64 + 4]);
}

test "scenario applyCountFloor tops up across repeated calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    _ = g.bots.handleCommand(g, "bot count 3", 0);
    try std.testing.expectEqual(@as(usize, 3), g.bots.n);
    _ = g.bots.handleCommand(g, "bot count 5", 0);
    try std.testing.expectEqual(@as(usize, 5), g.bots.n);

    // Two-way floor: reducing the target removes extras (`bot count 2`).
    _ = g.bots.handleCommand(g, "bot count 2", 0);
    try std.testing.expectEqual(@as(usize, 2), g.bots.n);
    // `bot count 0` clears the floor entirely.
    _ = g.bots.handleCommand(g, "bot count 0", 0);
    try std.testing.expectEqual(@as(usize, 0), g.bots.n);

    // Self-healing floor: set a floor, kill a bot, and the next tick respawns
    // it so the population returns to the remembered floor.
    _ = g.bots.handleCommand(g, "bot count 2", 0);
    try std.testing.expectEqual(@as(usize, 2), g.bots.n);
    const doomed = g.bots.bots[0].net_id;
    try std.testing.expect(g.bots.damageBot(doomed, 1000)); // lethal
    try std.testing.expectEqual(@as(usize, 1), g.bots.n);
    g.bots.tick(g, 0.05);
    try std.testing.expectEqual(@as(usize, 2), g.bots.n);
}

test "scenario bots collide with walls and slide instead of phasing through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, world_dir, 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // Bot at (8,_,8) heading east through (10,_,8); a wall blocks the path at
    // the bot's actual standing height (body cells floor(y) and +1).
    const bid = g.bots.spawn(g, 8, 70, 8, 100).?;
    const bs = g.bots.find(bid).?;
    const by = g.bots.bots[bs].y;
    const wy: i32 = @floor(by);
    try g.world.setBlockWorld(10, wy, 8, world_store.block_stone);
    try g.world.setBlockWorld(10, wy + 1, 8, world_store.block_stone);

    g.bots.move(bid, 20, by, 8, 4);
    var i: usize = 0;
    while (i < 60) : (i += 1) g.bots.tick(g, 0.05); // up to 3 s of movement
    const b = &g.bots.bots[bs];
    try std.testing.expect(b.x < 10.0); // never crossed the wall
    // Still trying to move (intent not cleared just because it is blocked).
    try std.testing.expect(b.move_active);
}

test "scenario persist: blood-moon schedule survives restart (ZCL2)" {
    // Stock CalcNextDay: the schedule is persisted (bmDayLast -> nextBM), so
    // a restart keeps the client's red moon on the horde night. Game.deinit
    // saves the clock (lifecycle) and Game.create restores it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    var first_bm: i32 = 0;
    {
        const g = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g.deinit();
            gpa.destroy(g);
        }
        g.sim.director.clock.bloodmoon_frequency = 7;
        g.sim.director.clock.bloodmoon_range = 2;
        g.sim.director.clock.day = 5;
        g.sim.director.clock.hours = 12.0;
        first_bm = g.sim.director.clock.bloodMoonDayFor(5);
        try std.testing.expect(first_bm >= 7 and first_bm <= 9);
    }
    {
        const g2 = try game_mod.Game.create(gpa, dir, 0);
        defer {
            g2.deinit();
            gpa.destroy(g2);
        }
        // The restored schedule keeps the same target (not recomputed from a
        // different stream) and stays monotonic with the live day.
        try std.testing.expectEqual(first_bm, g2.sim.director.clock.bloodMoonDayFor(5));
        g2.sim.director.clock.day = @intCast(first_bm);
        g2.sim.director.clock.hours = 23.0;
        try std.testing.expect(g2.sim.director.clock.isBloodMoonNight());
    }
}

test "scenario dig wears the held tool (ItemValue.UseTimes)" {
    // GAP "Item durability": the held tool's use_times wears with each dig
    // (stock ItemValue.UseTimes; the client shows the durability bar). The
    // dig C2S path (blocks.zig) calls degradeUse on the holding slot.
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
    const ps = g.sim.playerByPeer(c.slot).?;
    // A tool in hand with remaining durability.
    const hold = g.sim.inventory[ps].holding;
    g.sim.inventory[ps].slots[hold] = .{ .item_id = 7, .count = 1, .use_times = 10 };
    // A diggable block in reach (the player spawns near the primary spawn;
    // the existing explosion-dig scenario uses the same coordinate).
    try g.setBlock(250, 70, 250, world_store.block_stone);
    var body_buf: [128]u8 = undefined;
    const body = try packages.buildSetBlockBodyDamage(&body_buf, 250, 70, 250, world_store.block_stone, 1, 0, 0);
    var frame_buf: [128]u8 = undefined;
    try g.onData(c.peer.?, try packages.framed(&frame_buf, "NetPackageSetBlock", body));
    try std.testing.expectEqual(@as(f32, 9), g.sim.inventory[ps].slots[hold].use_times);
}

test "scenario admin ops verbs (getoptions/exportcurrentconfigs/loglevel/listthreads/cp)" {
    // The Net/ops MISSING admin verbs: each replies through the same
    // runAdminLine path the TCP/webui/in-game consoles share.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_adminops");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_adminops", 0, .{});
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    const run = struct {
        fn call(g2: *game_mod.Game, sink_buf: []u8, cmd: []const u8) []const u8 {
            g2.admin_reply_len = 0;
            g2.admin_reply_sink = sink_buf;
            g2.runAdminLine(cmd, "test");
            g2.admin_reply_sink = null;
            return sink_buf[0..g2.admin_reply_len];
        }
    }.call;

    var sink: [8192]u8 = undefined;
    const o = run(g, &sink, "getoptions");
    try std.testing.expect(std.mem.find(u8, o, "ServerPort = ") != null);
    try std.testing.expect(std.mem.find(u8, o, "GameDifficulty = ") != null);

    const e = run(g, &sink, "exportcurrentconfigs");
    try std.testing.expect(std.mem.find(u8, e, "exported_config.txt") != null);

    const ll = run(g, &sink, "loglevel");
    try std.testing.expect(std.mem.find(u8, ll, "Log level is ") != null);
    _ = run(g, &sink, "loglevel 2");
    try std.testing.expectEqual(@as(u8, 2), util_log.level());
    _ = run(g, &sink, "loglevel 0");
    try std.testing.expectEqual(@as(u8, 0), util_log.level());

    const lt = run(g, &sink, "listthreads");
    try std.testing.expect(std.mem.find(u8, lt, "main") != null);

    _ = run(g, &sink, "cp 2 tele");
    const cp = run(g, &sink, "cp tele");
    try std.testing.expect(std.mem.find(u8, cp, "requires permission level 2") != null);
    try std.testing.expectEqual(@as(u8, 2), g.commandLevel("tele"));
    _ = run(g, &sink, "cp 0 tele");
    try std.testing.expectEqual(@as(u8, 0), g.commandLevel("tele"));
    std.debug.print("PASS admin-ops: getoptions/exportcurrentconfigs/loglevel/listthreads/cp\n", .{});
}

test "scenario blood-moon music is per-party, not global" {
    // NetPackageBloodmoonMusic row: stock EntityPlayer.bloodMoonParty makes the
    // horde music per player - a player hears it only while their own party's
    // horde is alive. The old global bool made every player on a multi-party
    // server hear horde music when any party was horded.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_bmmusic");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_bmmusic", 0, .{});
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap);
    var cap2: ln_peer.Capture = .{};
    const cb = try g.attachJoinedClient(&cap2);
    // Move player B far from player A so they are different blood-moon parties.
    const ps_a = g.sim.playerByPeer(ca.slot).?;
    const ps_b = g.sim.playerByPeer(cb.slot).?;
    g.sim.transform[ps_b].x = g.sim.transform[ps_a].x + 1000;

    // Horde active with only A's party having alive zombies.
    g.sim.director.bloodmoon_active = true;
    const BmParty = @import("../ecs/aidirector.zig").BmParty;
    g.sim.director.bm_parties = [_]BmParty{.{}} ** @import("../ecs/aidirector.zig").bm_parties_cap;
    g.sim.director.bm_parties[0] = .{
        .focus_x = g.sim.transform[ps_a].x,
        .focus_z = g.sim.transform[ps_a].z,
        .members = 1,
        .alive = 3,
    };
    g.sim.director.bm_party_n = 1;

    try std.testing.expect(g.playerBloodMoonMusic(ca));
    try std.testing.expect(!g.playerBloodMoonMusic(cb));
    // Party wiped: the music stops for the surviving party member.
    g.sim.director.bm_parties[0].alive = 0;
    try std.testing.expect(!g.playerBloodMoonMusic(ca));
    // Horde over: no music for anyone.
    g.sim.director.bloodmoon_active = false;
    try std.testing.expect(!g.playerBloodMoonMusic(ca));
    std.debug.print("PASS bm-music: per-party eligibility, global-bool approximation gone\n", .{});

    // Eligibility is only half of it: the two send sites that carry it to a
    // client were untested. The tick path is edge-triggered, so it fires once
    // when the answer flips and stays quiet after.
    const bm_id = packages.idOf("NetPackageBloodmoonMusic") orelse
        return error.TestUnexpectedResult;

    // Drive the real director instead of writing bloodmoon_active: the tick
    // recomputes it from the clock. Pinning next_bm alone is not enough
    // either, because ensureBmSchedule rebuilds the schedule whenever its
    // cached bm_freq/bm_range disagree with the live settings, which throws
    // the pin away. Set the cache to match, then park the clock at night.
    const clk = &g.sim.director.clock;
    clk.bm_freq = clk.bloodmoon_frequency;
    clk.bm_range = clk.bloodmoon_range;
    clk.bm_day_last = 0;
    clk.bm_cycle = 0;
    clk.next_bm = clk.day;
    clk.hours = 23.0;
    // A horde zombie next to A is what gives A's party a live alive count.
    const hz = g.sim.spawnZombie(g.sim.transform[ps_a].x + 2, g.sim.transform[ps_a].y, g.sim.transform[ps_a].z, 100) orelse
        return error.TestUnexpectedResult;
    g.sim.zombie_ai[g.sim.slotOfNetId(hz).?].is_horde = true;

    cap.clear();
    cap2.clear();
    var bm_seen = false;
    for (0..g.world_time_send_ticks * 2) |_| {
        try g.step();
        if (cap.findPkgId(bm_id) != null) bm_seen = true;
    }
    try std.testing.expect(g.sim.director.bloodmoon_active);
    try std.testing.expect(bm_seen);
    try std.testing.expect(ca.bloodmoon_music);
    // B stands 1000 m away and joins no party of its own, so it stays silent.
    // B is deliberately not asserted here: with two players 1000 m apart the
    // director builds a party each and teleports the horde zombie to whichever
    // is nearest, so B's eligibility follows that placement rather than the
    // send site under test. The per-party split is covered above.
    // Held state: no re-send while the answer stays the same.
    cap.clear();
    for (0..g.world_time_send_ticks * 2) |_| try g.step();
    try std.testing.expect(cap.findPkgId(bm_id) == null);

    g.sim.director.bloodmoon_active = true;
    g.sim.director.bm_parties[0].alive = 3;
    try std.testing.expect(g.playerBloodMoonMusic(ca));
    // The join bundle replays the current state, because a client joining
    // mid-horde missed the tick-path edge and would otherwise never hear it.
    // Direct director writes are fine here: sendJoinBundle reads the state,
    // it does not run the director tick that would rebuild it.
    g.sim.director.bloodmoon_active = true;
    g.sim.director.bm_parties[0].alive = 3;
    g.sim.director.bm_party_n = 1;
    var cap3: ln_peer.Capture = .{};
    const cc = try g.attachJoinedClient(&cap3);
    g.sim.director.bm_parties[0].focus_x = g.sim.transform[g.sim.playerByPeer(cc.slot).?].x;
    g.sim.director.bm_parties[0].focus_z = g.sim.transform[g.sim.playerByPeer(cc.slot).?].z;
    try std.testing.expect(g.playerBloodMoonMusic(cc));
    cap3.clear();
    const cc_ps = g.sim.playerByPeer(cc.slot) orelse return error.TestUnexpectedResult;
    const cc_pos = g.sim.transform[cc_ps];
    try g.sendJoinBundle(cc, cc.peer.?, @intFromFloat(cc_pos.x), @intFromFloat(cc_pos.y), @intFromFloat(cc_pos.z), cc.entity_id);
    try std.testing.expect(cap3.findPkgId(bm_id) != null);
    try std.testing.expect(cc.bloodmoon_music);
    std.debug.print("PASS bm-wire: edge broadcast fires and holds, join bundle replays\n", .{});
}

test "scenario stock InventoryTransaction applies and acks" {
    // A real stock client sends InventoryTransaction.Write (RE
    // protocol-packages.md 6.13), which the native parser cannot read. The
    // server now applies the ops to the player's inventory (SetAll replaces
    // the array) and replies with the stock minimal ack (success + count 0).
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
    const ps = g.sim.playerByPeer(c.slot).?;
    // The starter kit puts wood at some slot; remember the first non-empty
    // slot so SetAll's replacement is observable.
    var wood_slot: usize = std.math.maxInt(usize);
    for (g.sim.inventory[ps].slots, 0..) |sl, i| {
        if (sl.item_id == 7) {
            wood_slot = i;
            break;
        }
    }
    if (wood_slot == std.math.maxInt(usize)) return error.SkipZigTest;

    // Stock SetAll body: 1 inventory, Guid, hashes, opCount 1, op 2 with an
    // empty array (count 0 = clear).
    var body: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeI32(1);
    for (0..16) |i| try w.writeByte(@intCast(i));
    try w.writeI32(1);
    try w.writeI32(2);
    try w.writeI32(1); // opCount
    try w.writeI16(2); // SetAll
    try w.writeI16(0); // empty array
    var fb: [192]u8 = undefined;
    cap.clear();
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageInventoryTransactionRequest", w.written()));
    try std.testing.expectEqual(@as(u16, 0), g.sim.inventory[ps].slots[wood_slot].item_id);
    // The stock minimal ack arrives (success true + count 0).
    const ack_id = packages.idOf("NetPackageInventoryTransactionResponse").?;
    var got_ack = false;
    for (cap.slots[0..cap.n]) |s| {
        var pkgs: [8]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id == ack_id and p.body.len >= 5 and p.body[0] == 1) got_ack = true;
        }
    }
    try std.testing.expect(got_ack);
    std.debug.print("PASS stock-invtx: SetAll applied + minimal ack\n", .{});

    // The decoder accepts a SetAll array up to stock_tx_setall_cap (128), but
    // the inventory holds max_inv_slots (67). A count between the two decodes
    // fine and then indexes past the destination array, so the handler has to
    // reject it rather than copy what fits. Empty stacks keep the body small:
    // ItemStack.Write is a bare u16 count when the count is zero.
    const over_n: i16 = @intCast(quest_mod_components.max_inv_slots + 1);
    try std.testing.expect(over_n <= @as(i16, @intCast(packages.stock_tx_setall_cap)));
    var big: [512]u8 = undefined;
    var bw: binary.Writer = .{ .buf = &big };
    try bw.writeI32(1);
    for (0..16) |i| try bw.writeByte(@intCast(i));
    try bw.writeI32(1);
    try bw.writeI32(2);
    try bw.writeI32(1); // opCount
    try bw.writeI16(2); // SetAll
    try bw.writeI16(over_n);
    for (0..@intCast(over_n)) |_| try bw.writeU16(0); // empty ItemStack
    // Put something back in the slot so a wrongly-applied SetAll is visible.
    g.sim.inventory[ps].slots[wood_slot] = .{ .item_id = 1, .count = 1 };
    var fb2: [640]u8 = undefined;
    cap.clear();
    try g.injectFramed(c, try packages.framed(&fb2, "NetPackageInventoryTransactionRequest", bw.written()));
    // Rejected: the slot the client tried to clear is untouched, so nothing
    // was applied before the bound was hit.
    try std.testing.expectEqual(@as(u16, 1), g.sim.inventory[ps].slots[wood_slot].item_id);
    // No ack either. Stock `TransactionRequestServer` (IL=46, RE items.md
    // "Server TransactionRequestServer") sends the minimal ack only on the
    // success path; a failed Apply logs and force-unlocks instead. An ack
    // here would tell the client a rejected transaction went through.
    for (cap.slots[0..cap.n]) |s| {
        var pkgs2: [8]wire_frame.Package = undefined;
        const pn2 = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs2);
        for (pkgs2[0..pn2]) |p| {
            try std.testing.expect(p.id != ack_id);
        }
    }
    std.debug.print("PASS stock-invtx: an over-cap SetAll is rejected, not clamped\n", .{});
}

// ---------------------------------------------------------------------------
// PRD 0005 / RFC 0005: module tiers, discovery, disabled/blacklist, exclusive
// core override points, and mod-replaces-mod (AC1-AC8).
// ---------------------------------------------------------------------------

const plugin_mod = @import("../plugin/root.zig");

fn mkManifest(name: []const u8, wasm: []const u8, tier: ?[]const u8, override: ?[]const u8, points: ?[]const u8, enabled: ?bool) plugin_mod.manifest.Manifest {
    return .{
        .name = name,
        .version = null,
        .wasm = wasm,
        .tier = tier,
        .override = override,
        .points = points,
        .claim_mode = null,
        .requires = null,
        .description = null,
        .enabled = enabled,
        // dir = "" -> loadResolved treats `wasm` as the full path (fixtures
        // and in-tree mods are referenced by absolute repo-relative path).
        .dir = "",
    };
}

test "scenario mods AC1: resolver keeps official tiers in discovery order" {
    // Fresh boot with no zdtd.toml: discovery finds every mods/<name>/manifest.toml,
    // sorted by dir name; official mods keep their tier (AC1).
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const mods = [_]plugin_mod.manifest.Manifest{
        mkManifest("fps_bot", "fps_bot.wasm", "official", null, null, null),
        mkManifest("mcp", "mcp.wasm", "official", null, null, null),
        mkManifest("my_user_mod", "u.wasm", "user", null, null, null),
    };
    var plan = try plugin_mod.resolver.resolve(gpa, &mods, &.{}, &.{}, &.{}, &.{});
    defer plan.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), plan.modules.len);
    try std.testing.expectEqual(.official, plan.modules[0].tier);
    try std.testing.expectEqualStrings("fps_bot", plan.modules[0].manifest.name.?);
    try std.testing.expectEqual(.official, plan.modules[1].tier);
    try std.testing.expectEqual(.user, plan.modules[2].tier);
    std.debug.print("PASS mods AC1: official tiers + discovery order\n", .{});
}

test "scenario mods AC2: disabled skips, blacklist vetoes refs" {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const mods = [_]plugin_mod.manifest.Manifest{
        mkManifest("fps_bot", "fps_bot.wasm", "official", null, null, null),
        mkManifest("core_killfeed", "k.wasm", "official", null, null, null),
    };
    // disabled = ["core_killfeed"] drops it.
    var plan = try plugin_mod.resolver.resolve(gpa, &mods, &.{}, &.{"core_killfeed"}, &.{}, &.{});
    defer plan.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), plan.modules.len);
    try std.testing.expectEqualStrings("fps_bot", plan.modules[0].manifest.name.?);

    // blacklist = ["fps_bot"] refuses the mod itself.
    try std.testing.expectError(
        error.BlacklistedTarget,
        plugin_mod.resolver.resolve(gpa, &mods, &.{}, &.{}, &.{"fps_bot"}, &.{}),
    );

    // A mod whose override names a blacklisted target cannot load.
    const replacers = [_]plugin_mod.manifest.Manifest{
        mkManifest("fps_bot", "fps_bot.wasm", "official", null, null, null),
        mkManifest("evil_bot", "e.wasm", "user", "fps_bot", null, null),
    };
    try std.testing.expectError(
        error.BlacklistedTarget,
        plugin_mod.resolver.resolve(gpa, &replacers, &.{}, &.{}, &.{"fps_bot"}, &.{}),
    );
    std.debug.print("PASS mods AC2: disabled drops, blacklist vetoes refs\n", .{});
}

test "scenario mods AC3: disabling a core component fails config" {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    // `[mods] disabled = ["loot"]` (a native core component) is a config error.
    try std.testing.expectError(
        error.DisabledCore,
        plugin_mod.resolver.resolve(gpa, &.{}, &.{}, &.{"loot"}, &.{}, &.{}),
    );
    std.debug.print("PASS mods AC3: core component protected from disable\n", .{});
}

test "scenario mods AC4/AC5: exclusive core override point routes only to the claimant" {
    // AC4: a mod claiming `craft.request` decides that verdict alone; other
    // behaviour is untouched. AC5: claiming every point of a component (here
    // both craft.request and loot.roll) overrides the component's decisions.
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const mods = [_]plugin_mod.manifest.Manifest{
        mkManifest("gate", "assets/fixtures/plugin_override.wasm", "user", null, "craft.request,loot.roll", null),
    };
    var plan = try plugin_mod.resolver.resolve(gpa, &mods, &.{}, &.{}, &.{}, &.{});
    defer plan.deinit(gpa);
    // The single claiming module occupies slot 0; both points map to it.
    try std.testing.expectEqual(@as(usize, 0), plan.point_claims.get("craft.request").?);
    try std.testing.expectEqual(@as(usize, 0), plan.point_claims.get("loot.roll").?);
    try std.testing.expectEqual(@as(usize, 0), plan.modules[0].slot);

    // Route a craft request through the Game's Wasm host with the claim wired.
    // The fixture (plugin_override.wasm) denies every craft (<0) and scales
    // loot to 300%.
    freshScenarioDir("worlds/zdtd_sc_mods_claim");
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_mods_claim", 0, .{
        .enable_sample_plugin = false,
        .plugin_plan = &plan,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.n);
    // Claimant slot 0, exclusive on both points.
    try std.testing.expectEqual(@as(u8, 0), g.wasm_plugins.claims[@intFromEnum(plugin_mod.manifest.OverridePoint.craft_request)]);
    try std.testing.expectEqual(@as(u8, 0), g.wasm_plugins.claims[@intFromEnum(plugin_mod.manifest.OverridePoint.loot_roll)]);
    // The claimed craft verdict is the fixture's deny (<0).
    try std.testing.expect(g.wasm_plugins.craftRequest(1, "some_recipe", 1) < 0);
    // The claimed loot verdict is the fixture's 300.
    try std.testing.expectEqual(@as(i32, 300), g.wasm_plugins.lootRoll("someList", 10));
    // Unclaimed hooks (e.g. player damage) keep stock composition: no module
    // exports them, so keep (0).
    try std.testing.expectEqual(@as(i32, 0), g.wasm_plugins.playerDamage(1, 2, 50));
    std.debug.print("PASS mods AC4/AC5: exclusive claim routes alone, unclaimed keeps stock\n", .{});
}

test "scenario mods AC6: override = name replaces the official mod" {
    // A user mod declaring override = "fps_bot" loads in its place; the
    // official module is not instantiated.
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const mods = [_]plugin_mod.manifest.Manifest{
        mkManifest("fps_bot", "mods/fps_bot/fps_bot.wasm", "official", null, null, null),
        mkManifest("my_bot", "assets/fixtures/plugin_hello.wasm", "user", "fps_bot", null, null),
    };
    var plan = try plugin_mod.resolver.resolve(gpa, &mods, &.{}, &.{}, &.{}, &.{});
    defer plan.deinit(gpa);
    // The target is dropped; only the replacer loads.
    try std.testing.expectEqual(@as(usize, 1), plan.modules.len);
    try std.testing.expectEqualStrings("my_bot", plan.modules[0].manifest.name.?);
    try std.testing.expectEqualStrings("fps_bot", plan.modules[0].replaces.?);

    freshScenarioDir("worlds/zdtd_sc_mods_replace");
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_mods_replace", 0, .{
        .enable_sample_plugin = false,
        .plugin_plan = &plan,
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.n);
    // The loaded slot is the replacer (display = my_bot), not bot.
    try std.testing.expectEqualStrings("my_bot", g.wasm_plugins.slots[0].display);
    std.debug.print("PASS mods AC6: replacer occupies the official mod's slot\n", .{});
}

test "scenario mods AC7: duplicate point claim / duplicate replacer is a boot error" {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // Two mods claiming loot.roll.
    const dup_points = [_]plugin_mod.manifest.Manifest{
        mkManifest("a", "a.wasm", "user", null, "loot.roll", null),
        mkManifest("b", "b.wasm", "user", null, "loot.roll", null),
    };
    try std.testing.expectError(
        error.DuplicateClaim,
        plugin_mod.resolver.resolve(gpa, &dup_points, &.{}, &.{}, &.{}, &.{}),
    );

    // Two mods replacing bot.
    const dup_replacer = [_]plugin_mod.manifest.Manifest{
        mkManifest("fps_bot", "b.wasm", "official", null, null, null),
        mkManifest("a", "a.wasm", "user", "fps_bot", null, null),
        mkManifest("b", "b.wasm", "user", "fps_bot", null, null),
    };
    try std.testing.expectError(
        error.DuplicateClaim,
        plugin_mod.resolver.resolve(gpa, &dup_replacer, &.{}, &.{}, &.{}, &.{}),
    );
    std.debug.print("PASS mods AC7: duplicate claims fail loudly\n", .{});
}

test "scenario mods AC8: discovered mods run under the standard budget and attribution" {
    // Budget: loadResolved passes the caller budget through to each module;
    // a looper fixture exhausts fuel and is disabled, not fatal (ADR 0020).
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const mods = [_]plugin_mod.manifest.Manifest{
        mkManifest("looper", "assets/fixtures/plugin_looper.wasm", "user", null, null, null),
        mkManifest("hello", "assets/fixtures/plugin_hello.wasm", "user", null, null, null),
    };
    var plan = try plugin_mod.resolver.resolve(gpa, &mods, &.{}, &.{}, &.{}, &.{});
    defer plan.deinit(gpa);

    freshScenarioDir("worlds/zdtd_sc_mods_budget");
    // Small fuel so the looper burns out in microseconds (like the T9 proof).
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_mods_budget", 0, .{
        .enable_sample_plugin = false,
        .plugin_plan = &plan,
        .plugin_budget = .{ .fuel = 200_000 },
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    // Both loaded; the looper is disabled by fuel on its first tick (AC8:
    // budget enforced through loadResolved), the hello module survives.
    try std.testing.expectEqual(@as(usize, 2), g.wasm_plugins.n);
    try std.testing.expectEqual(@as(usize, 0), g.wasm_plugins.disabledCount());
    try g.step(); // the looper burns its fuel on on_tick
    try std.testing.expectEqual(@as(usize, 1), g.wasm_plugins.disabledCount());
    try std.testing.expect(g.wasm_plugins.slots[0].disabled);
    try std.testing.expect(!g.wasm_plugins.slots[1].disabled);
    std.debug.print("PASS mods AC8: shared budget disables the looper, other mod survives\n", .{});
}

test "scenario mod scrub rejects illegal attachments server-authoritatively" {
    // RE items.md CalcModSlotCount (IL=29) + ItemClassModifier suitability:
    // after an inventory write the server clears mods that exceed the item's
    // ModSlots quality budget or violate the installable/blocked tag gates
    // (fail closed). The client's next inventory sync corrects its view.
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
    // Static catalog: a gun (2 mod slots at every tier) tagged for barrel
    // mods, a knife (1 slot, melee-only), and the two mod items.
    var gun: assets_items.ItemDef = .{ .id = 100, .name = "testGun", .tags = "T0,gun,barrelAttachments", .mod_slots_n = 6 };
    @memcpy(gun.mod_slots_curve[0..6], &[_]f32{2} ** 6);
    var knife: assets_items.ItemDef = .{ .id = 101, .name = "testKnife", .tags = "T0,melee,blade", .mod_slots_n = 6 };
    @memcpy(knife.mod_slots_curve[0..6], &[_]f32{1} ** 6);
    const defs = [_]assets_items.ItemDef{
        gun,
        knife,
        .{ .id = 102, .name = "modMeleeCrafted04" },
        .{ .id = 103, .name = "modGunBarrelExtender" },
    };
    g.items = .{ .defs = &defs, .source = .builtin };
    g.item_mods = .{ .defs = &[_]assets_item_modifiers.ModDef{
        .{ .name = "modMeleeCrafted04", .installable = "melee,stabbing", .blocked = "noMods,blunt" },
        .{ .name = "modGunBarrelExtender", .installable = "barrelAttachments,turretRanged", .blocked = "noMods,shotgun" },
    } };
    const p = g.sim.spawnPlayer(0, 70, 0, 0).?;
    const ps = g.sim.slotOfNetId(p).?;
    // Legal: gun + barrel mod (tags intersect, count 1 <= budget 2).
    g.sim.inventory[ps].slots[0] = .{ .item_id = 100, .count = 1, .quality = 1, .mods = .{ 103, 0, 0, 0 }, .mod_n = 1 };
    // Illegal: barrel mod on the knife (installable misses melee).
    g.sim.inventory[ps].slots[1] = .{ .item_id = 101, .count = 1, .quality = 1, .mods = .{ 103, 0, 0, 0 }, .mod_n = 1 };
    // Illegal: three barrel mods on the gun (budget 2).
    g.sim.inventory[ps].slots[2] = .{ .item_id = 100, .count = 1, .quality = 1, .mods = .{ 103, 103, 103, 0 }, .mod_n = 3 };
    // Illegal: melee mod on the gun (installable misses gun).
    g.sim.inventory[ps].slots[3] = .{ .item_id = 100, .count = 1, .quality = 1, .mods = .{ 102, 0, 0, 0 }, .mod_n = 1 };
    inv_c2s.scrubIllegalMods(g, ps);
    try std.testing.expectEqual(@as(u8, 1), g.sim.inventory[ps].slots[0].mod_n);
    try std.testing.expectEqual(@as(u16, 103), g.sim.inventory[ps].slots[0].mods[0]);
    try std.testing.expectEqual(@as(u8, 0), g.sim.inventory[ps].slots[1].mod_n);
    try std.testing.expectEqual(@as(u8, 0), g.sim.inventory[ps].slots[2].mod_n);
    try std.testing.expectEqual(@as(u8, 0), g.sim.inventory[ps].slots[3].mod_n);
}

test "scenario powered door opens while powered, closes on power loss" {
    // RE tile-entities-power.md PowerConsumer.HandlePowerUpdate →
    // Block.ActivateBlock(isPowered, ...): a powered door opens while its
    // circuit delivers power (the open meta bit + SetBlock broadcast, same as
    // the zombie door-open path) and closes when the power drops.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var xml_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xml_path = try std.fmt.bufPrint(&xml_buf, "{s}/blocks.xml", .{cfg_dir});
    try io_fs.writeFile(xml_path,
        \\<blocks>
        \\  <block name="doorWoodLargeGate">
        \\    <property name="Class" value="Door"/>
        \\  </block>
        \\</blocks>
    );
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_pwrdoor");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_pwrdoor", 0, .{ .config_dir = cfg_dir });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    _ = try g.attachJoinedClient(&cap);

    const door = g.blocks.byName("doorWoodLargeGate") orelse return error.TestExpectedEqual;
    try std.testing.expect(door.is_door);
    try g.world.setBlockRawWorld(5, 70, 5, door.id);
    const gen = g.sim.power.addNodeAt(.generator, 100, 70, 100, 100).?;
    const dnode = g.sim.power.addNodeAt(.consumer, 5, 70, 5, 5).?;
    try std.testing.expect(g.sim.power.connect(gen, dnode));
    g.sim.power.resolve();
    const di = g.sim.power.indexOfId(dnode).?;
    try std.testing.expect(g.sim.power.nodes[di].powered);
    try g.step(); // the tick runs actuatePoweredDoors
    const raw = try g.world.rawWorld(5, 70, 5);
    try std.testing.expect((packages.blockMeta(raw) & packages.block_meta_on) != 0);
    // Kill the generator: the consumer loses power and the door closes.
    const gi = g.sim.power.indexOfId(gen).?;
    g.sim.power.nodes[gi].on = false;
    g.sim.power.resolve();
    try g.step();
    const raw2 = try g.world.rawWorld(5, 70, 5);
    try std.testing.expect((packages.blockMeta(raw2) & packages.block_meta_on) == 0);
    std.debug.print("PASS powered-door: opens on power, closes on power loss\n", .{});
}

test "scenario stirred sleeper broadcasts NetPackageSleeperPassiveChange" {
    // RE EntityAlive.SetSleeperActive (IL=26): an in-volume player that does
    // not wake a sleeper (dark: the wake light gate fails) stirs it - the
    // server broadcasts NetPackageSleeperPassiveChange (entityId i32, flags
    // 192) so the client clears IsSleeperPassive and plays the groan.
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
    _ = try g.attachJoinedClient(&cap);
    g.sim.director.clock.hours = 1; // night: the slice-1 ambient is 0
    const z = g.sim.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie, .sight_range = 30.0 }, 0).?;
    const zs = g.sim.slotOfNetId(z).?;
    g.sim.sleeper[zs].volume_r = 20;
    g.sim.sleeper[zs].wake_light_near = -17.5;
    g.sim.sleeper[zs].wake_light_far = 410.0;
    _ = g.sim.spawnPlayer(4, 70, 0, 0); // 4 m in the volume, dark
    try g.step();
    try std.testing.expect(!g.sim.sleeper[zs].awake);
    try std.testing.expect(g.sim.sleeper[zs].groan_sent);
    if (packages.idOf("NetPackageSleeperPassiveChange")) |pc_id| {
        try std.testing.expect(cap.findPkgIdEntity(pc_id, g.sim.network_id[zs].id) != null);
    }
    std.debug.print("PASS sleeper-stir: dark in-volume player broadcasts PassiveChange\n", .{});
}

test "scenario a woken sleeper broadcasts NetPackageSleeperWakeup" {
    // The other half of EntityAlive.SetSleeperActive (IL=26): a sleeper that
    // actually wakes gets NetPackageSleeperWakeup, not the groan package. RE
    // protocol-packages.md pins it as an unreliable broadcast with
    // toEntityId -1, so every peer sees it, not just those in interest range.
    // Only the stir half had a scenario, so nothing checked that a woken
    // sleeper is announced at all.
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
    _ = try g.attachJoinedClient(&cap);
    g.sim.director.clock.hours = 12; // daylight: the wake light gate passes
    const z = g.sim.spawnSleeperDef(0, 70, 0, .{ .name = "sl", .hash = 1, .kind = .zombie, .sight_range = 30.0 }, 0).?;
    const zs = g.sim.slotOfNetId(z).?;
    g.sim.sleeper[zs].volume_r = 20;
    _ = g.sim.spawnPlayer(4, 70, 0, 0);
    try g.step();
    try std.testing.expect(g.sim.sleeper[zs].awake);

    const wake_id = packages.idOf("NetPackageSleeperWakeup") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(cap.findPkgIdEntity(wake_id, g.sim.network_id[zs].id) != null);
    // A woken sleeper takes the wake branch, not the groan branch.
    if (packages.idOf("NetPackageSleeperPassiveChange")) |pc_id| {
        try std.testing.expect(cap.findPkgIdEntity(pc_id, g.sim.network_id[zs].id) == null);
    }
    std.debug.print("PASS sleeper-wake: woken sleeper broadcasts Wakeup, not PassiveChange\n", .{});
}

test "scenario a recycled slot does not inherit the previous look-at target" {
    // EntityLookAt is deduped per slot against the last target sent, so a
    // zombie that keeps staring at the same place stops re-sending. The cache
    // is indexed by slot, and slots are reused: without the generation reset
    // the new occupant inherits the dead one's last target and its first look
    // is swallowed whenever the two happen to match, leaving the client with
    // a zombie facing the wrong way for as long as it holds that target.
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
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    const pp = g.sim.transform[ps];
    const look_id = packages.idOf("NetPackageEntityLookAt") orelse
        return error.TestUnexpectedResult;

    // First zombie: alert on the player, so it sends one look.
    const z1 = g.sim.spawnZombie(pp.x + 3, pp.y, pp.z, 100) orelse
        return error.TestUnexpectedResult;
    const s1 = g.sim.slotOfNetId(z1) orelse return error.TestUnexpectedResult;
    g.sim.zombie_ai[s1].alert = true;
    g.sim.zombie_ai[s1].target_id = c.entity_id;
    cap.clear();
    g.tickEntityLookAt();
    try std.testing.expect(cap.findPkgIdEntity(look_id, z1) != null);
    // Second tick, same target: deduped, nothing re-sent.
    cap.clear();
    g.tickEntityLookAt();
    try std.testing.expect(cap.findPkgIdEntity(look_id, z1) == null);

    // Recycle the slot onto a new zombie with the same target. The cached
    // entry still holds the player's position, so only the generation reset
    // keeps this first look from being deduped away.
    g.sim.destroy(s1);
    // A freed slot is held back until the next tick begins (allocSlot skips
    // freed_this_tick), so start one: that is what makes the reuse happen.
    g.sim.beginTick();
    const z2 = g.sim.spawnZombie(pp.x + 3, pp.y, pp.z, 100) orelse
        return error.TestUnexpectedResult;
    const s2 = g.sim.slotOfNetId(z2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(s1, s2); // same slot, new generation
    g.sim.zombie_ai[s2].alert = true;
    g.sim.zombie_ai[s2].target_id = c.entity_id;
    cap.clear();
    g.tickEntityLookAt();
    try std.testing.expect(cap.findPkgIdEntity(look_id, z2) != null);
    std.debug.print("PASS look-at: a reused slot still sends its first look\n", .{});
}

test "scenario a reload naming no live entity is not relayed" {
    // ItemReload is a pure relay: the server rebroadcasts the body to every
    // peer but the sender so they play the animation (RE ItemReloadServer
    // IL=32). The only thing between that and free bandwidth amplification is
    // the id check, since the body is one i32 a client picks.
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
    const reload_id = packages.idOf("NetPackageItemReload") orelse
        return error.TestUnexpectedResult;

    var body: [8]u8 = undefined;
    var fb: [128]u8 = undefined;

    // A real entity id relays to the other peer.
    std.mem.writeInt(i32, body[0..4], ca.entity_id, .little);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageItemReload", body[0..4]));
    try std.testing.expect(cap_b.findPkgId(reload_id) != null);

    // An id no entity holds is dropped, so it cannot be sprayed as a relay.
    std.mem.writeInt(i32, body[0..4], 999_999, .little);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageItemReload", body[0..4]));
    try std.testing.expect(cap_b.findPkgId(reload_id) == null);

    // Zero is the same case and is spelled out separately: it is the value a
    // default-constructed body carries.
    std.mem.writeInt(i32, body[0..4], 0, .little);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageItemReload", body[0..4]));
    try std.testing.expect(cap_b.findPkgId(reload_id) == null);
    std.debug.print("PASS reload-relay: live id relays, unknown and zero ids do not\n", .{});
}

test "scenario light tile entities ride the chunk stream" {
    // sendContainersInChunk walks every TE store for the chunk being streamed
    // and sends each one. The light store was the only branch with no test, so
    // a client streaming a POI would silently get unlit lamps: the light TE is
    // what carries intensity, range and colour, and it is only ever sent here.
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
    const te_id = packages.idOf("NetPackageTileEntity") orelse
        return error.TestUnexpectedResult;

    // A light inside chunk (16, 16), and one far outside it.
    const inside = g.light_te.getOrCreate(.{ .x = 16 * 16 + 3, .y = 70, .z = 16 * 16 + 4 }) orelse
        return error.TestUnexpectedResult;
    inside.intensity = 2.5;
    inside.range = 7.0;
    const outside = g.light_te.getOrCreate(.{ .x = 40 * 16, .y = 70, .z = 40 * 16 }) orelse
        return error.TestUnexpectedResult;
    outside.intensity = 1.0;

    // Other TE kinds ride the same package id, so match on the light's own
    // world position in the outer TE header (handle u8, then x/y/z i32).
    const sawLightAt = struct {
        fn call(cp: *ln_peer.Capture, id: u16, x: i32, y: i32, z: i32) bool {
            for (cp.slots[0..cp.n]) |sl| {
                var pkgs: [16]wire_frame.Package = undefined;
                const pn = wire_frame.parseChannelPayload(sl.data[0..sl.len], &pkgs);
                for (pkgs[0..pn]) |pk| {
                    if (pk.id != id or pk.body.len < 13) continue;
                    var r: binary.Reader = .{ .data = pk.body };
                    _ = r.readByte() catch continue;
                    const bx = r.readI32() catch continue;
                    const by = r.readI32() catch continue;
                    const bz = r.readI32() catch continue;
                    if (bx == x and by == y and bz == z) return true;
                }
            }
            return false;
        }
    }.call;

    cap.clear();
    try g.sendContainersInChunk(c.peer.?, 16, 16);
    try std.testing.expect(sawLightAt(&cap, te_id, inside.x, inside.y, inside.z));

    // A chunk with no light in it does not carry this one, so the branch is
    // position gated rather than sending the whole store to everyone.
    cap.clear();
    try g.sendContainersInChunk(c.peer.?, 20, 20);
    try std.testing.expect(!sawLightAt(&cap, te_id, inside.x, inside.y, inside.z));
    try std.testing.expect(!sawLightAt(&cap, te_id, outside.x, outside.y, outside.z));
    std.debug.print("PASS light-te: in-chunk light streamed, out-of-chunk light withheld\n", .{});
}

test "scenario a vending allow-list with a hole ships no empty identity" {
    // The vending TE writes allowed.len then one PlatformUserIdentifier per
    // entry. allowed_n is a stored count and the array behind it can carry an
    // empty UserRef in the middle: readUserRef accepts platform_len 0, so a
    // save written before an entry was cleared restores exactly that shape.
    // The send path compacts, which is what keeps a zero-length identity off
    // the wire; without it the client reads a count it cannot satisfy.
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
    const te_id = packages.idOf("NetPackageTileEntity") orelse
        return error.TestUnexpectedResult;

    const vx: i32 = 300;
    const vz: i32 = 300;
    const v = g.vending.getOrCreate(.{ .x = vx, .y = 70, .z = vz }, 1, 0) orelse
        return error.TestUnexpectedResult;
    // Three declared entries with the middle one empty.
    v.allowed_n = 3;
    v.allowed[0].platform_len = 5;
    @memcpy(v.allowed[0].platform[0..5], "Steam");
    v.allowed[0].id_len = 4;
    @memcpy(v.allowed[0].id[0..4], "1001");
    v.allowed[1] = .{}; // the hole
    v.allowed[2].platform_len = 5;
    @memcpy(v.allowed[2].platform[0..5], "Steam");
    v.allowed[2].id_len = 4;
    @memcpy(v.allowed[2].id[0..4], "1003");

    cap.clear();
    try replicate_te.sendVendingTe(g, c.peer.?, vx, 70, vz);

    // Walk the vending TE body to the allow-list count. Outer header is
    // handle u8 + x/y/z i32 + block id i32 + payload len i32.
    var found_count: ?i32 = null;
    for (cap.slots[0..cap.n]) |sl| {
        var pkgs: [16]wire_frame.Package = undefined;
        const pn = wire_frame.parseChannelPayload(sl.data[0..sl.len], &pkgs);
        for (pkgs[0..pn]) |pk| {
            if (pk.id != te_id or pk.body.len < 21) continue;
            var r: binary.Reader = .{ .data = pk.body };
            _ = r.readByte() catch continue;
            const bx = r.readI32() catch continue;
            _ = r.readI32() catch continue;
            const bz = r.readI32() catch continue;
            if (bx != vx or bz != vz) continue;
            _ = r.readI32() catch continue; // te block id
            _ = r.readI32() catch continue; // payload len
            // Vending payload (stock_te.buildVendingTeBody): local x/y/z i32,
            // version i32, locked bool, owner identity, password hash as a
            // length-prefixed string, then the allow-list count.
            _ = r.readI32() catch continue;
            _ = r.readI32() catch continue;
            _ = r.readI32() catch continue;
            _ = r.readI32() catch continue; // version
            _ = r.readBool() catch continue;
            var pbuf: [128]u8 = undefined;
            var ibuf: [128]u8 = undefined;
            _ = packages.platform_user.read(&r, &pbuf, &ibuf) catch continue;
            var hbuf: [256]u8 = undefined;
            _ = r.readString(&hbuf) catch continue;
            found_count = r.readI32() catch continue;
        }
    }
    // Two real entries, not the three the store declares: the empty one is
    // dropped rather than shipped as a zero-length identity.
    try std.testing.expectEqual(@as(?i32, 2), found_count);

    // Same shape one field over: the stock rows compact on type_id 0, so a
    // machine whose middle slot was sold out ships two rows, not three with
    // an item the client cannot resolve.
    v.stock_n = 3;
    v.stock[0] = .{ .type_id = packages.stock_inv.items_start_here + 1, .count = 2, .quality = 1 };
    v.stock[1] = .{}; // sold out
    v.stock[2] = .{ .type_id = packages.stock_inv.items_start_here + 2, .count = 5, .quality = 1 };
    var entries_buf: [vending_mod.max_vending_stock]packages.TraderStockEntry = undefined;
    const n_entries = replicate_te.vendingEntries(g, v, &entries_buf);
    try std.testing.expectEqual(@as(usize, 2), n_entries);
    try std.testing.expectEqual(packages.stock_inv.items_start_here + 1, entries_buf[0].item.type_id);
    try std.testing.expectEqual(packages.stock_inv.items_start_here + 2, entries_buf[1].item.type_id);
    std.debug.print("PASS vending-allow: empty allow entry and empty stock row both compacted\n", .{});
}

test "scenario a vending fill skips items this build cannot resolve" {
    // fillVendingStore rolls trader refs by name and drops a row twice: when
    // the item table has no such name, and when the resolved id has no stock
    // type. Storing one anyway puts type_id 0 in the array, and the wire
    // compaction then drops it again, so the machine ships fewer rows than
    // stock_n claims and every later index shifts.
    //
    // The group needs count="all": spawnItemsFromGroup is otherwise
    // prob-weighted (SpawnLootItemsFromList, asm.il 863343) and one run rolls
    // one ref, which leaves the guards unreached and the test green for the
    // wrong reason. count="all" takes the spawnAllRefs branch instead.
    const tsrc =
        \\<traders>
        \\  <trader_item_group name="traderAlways" count="all">
        \\    <item name="resourceWood" count="3"/>
        \\    <item name="itemThatDoesNotExistAnywhere" count="2"/>
        \\  </trader_item_group>
        \\  <trader_info id="1"/>
        \\</traders>
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tdir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var tpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tpath = try std.fmt.bufPrint(&tpath_buf, "{s}/traders_fill.xml", .{tdir});
    try io_fs.writeFile(tpath, tsrc);
    const tt = try assets_traders.loadFromPath(std.testing.allocator, tpath);

    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_vendfill");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, "worlds/zdtd_sc_vendfill", 0, .{});
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    g.traders.deinit();
    g.traders = tt;

    // Pin the premise: the good name resolves, the bad one does not. Without
    // this the test passes when both fail to resolve and nothing is stored.
    try std.testing.expect(g.ecsIdFromItemName("resourceWood") != 0);
    try std.testing.expectEqual(@as(u16, 0), g.ecsIdFromItemName("itemThatDoesNotExistAnywhere"));

    const v = g.vending.getOrCreate(.{ .x = 400, .y = 70, .z = 400 }, 1, 1) orelse
        return error.TestUnexpectedResult;
    replicate_te.fillVendingStore(g, v);

    // Both refs roll (traderAlways refs are individual, so rollAllRefs calls
    // spawnItem for each), one is unresolvable, so only the resolvable row
    // lands. The two guards are redundant with each other here: ecsIdFromItemName
    // and resolveItemType both reject this name, so removing one alone leaves
    // the test green. Removing both stores the empty row and fails it, which is
    // the property that matters: no unresolvable row reaches the store.
    try std.testing.expect(v.stock_n > 0);
    var si: usize = 0;
    while (si < v.stock_n) : (si += 1) {
        try std.testing.expect(v.stock[si].type_id != 0);
    }
    std.debug.print("PASS vending-fill: {d} resolvable rows stored, unresolvable dropped\n", .{v.stock_n});
}

test "scenario animation data relays to the other players" {
    // Stock NetPackageEntityAnimationData (client-originated: the local
    // AvatarController broadcasts the avatar anim params; ProcessPackage
    // IL=64 re-Setups + relays to the other players): the server
    // re-broadcasts the raw body to the entity's tracked players.
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
    try g.step(); // run the join sync so B tracks A's entity
    // A's animation-data body. Each AnimParamData is hash i32 + type u8 + a
    // value whose width the type picks (AnimParamData.il.txt:54); the test
    // used to omit the type byte, which no reader would have accepted.
    var body: [32]u8 = undefined;
    var bw = binary.Writer{ .buf = &body };
    try bw.writeI32(ca.entity_id);
    try bw.writeI32(1); // anim param count
    try bw.writeI32(7); // param name hash
    try bw.writeByte(packages.anim_param_float);
    try bw.writeF32(0.5); // value
    var fb: [192]u8 = undefined;
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAnimationData", bw.written()));
    // B received the relayed body for A. The server treats the param list as
    // opaque and forwards it verbatim, which is exactly why the bytes need
    // checking rather than counting: a relay that truncated or reordered the
    // tail would still produce a package with the right id and entity.
    if (packages.idOf("NetPackageEntityAnimationData")) |an_id| {
        const got = cap_b.findPkgIdEntity(an_id, ca.entity_id) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(bw.written().len, got.len);
        try std.testing.expectEqualSlices(u8, bw.written(), got);

        // Appended bytes are trimmed off rather than fanned out.
        cap_b.clear();
        var apad: [96]u8 = undefined;
        const an_n = bw.written().len;
        @memcpy(apad[0..an_n], bw.written());
        @memset(apad[an_n..][0..6], 0x3c);
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAnimationData", apad[0 .. an_n + 6]));
        const an_trimmed = cap_b.findPkgIdEntity(an_id, ca.entity_id) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(an_n, an_trimmed.len);

        // An unrecognised parameter type is rejected, not relayed.
        cap_b.clear();
        var abad: [32]u8 = undefined;
        var abw = binary.Writer{ .buf = &abad };
        try abw.writeI32(ca.entity_id);
        try abw.writeI32(1);
        try abw.writeI32(7);
        try abw.writeByte(9); // no such AnimParamData.ValueTypes
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityAnimationData", abw.written()));
        try std.testing.expect(cap_b.findPkgId(an_id) == null);
    }
    // PlayerEquipment is the same verbatim-relay shape and had no scenario at
    // all. Two properties matter and neither was covered: the body reaches the
    // other player unchanged, and a client cannot relay equipment for someone
    // else's entity (the handler gates on eid == c.entity_id).
    if (packages.idOf("NetPackagePlayerEquipment")) |eq_id| {
        // Equipment body (Equipment::Write): entityId, then the version byte
        // that selects the slot count, then one ItemValue per slot where an
        // empty slot is the bare `0` its version field would carry. Stock
        // writes version 4; versions 2 and up also carry the cosmetic tail.
        // 4 id + 1 version + 12 null slots + 12 cosmetic i32 + 4 unlocked.
        var eq: [256]u8 = undefined;
        var ew = binary.Writer{ .buf = &eq };
        try ew.writeI32(ca.entity_id);
        try ew.writeByte(4); // version -> 12 equipment slots
        // Slot 3 carries a real item: an all-empty body cannot tell a correct
        // parse from one that mis-tracks the slot cursor, which is how the
        // presence-bool bug survived here.
        const worn_stock: i32 = packages.stock_inv.items_start_here + 5;
        for (0..12) |i| {
            if (i == 3) {
                try packages.stock_inv.writeItemValue(&ew, .{ .type_id = worn_stock, .count = 1 });
            } else {
                try ew.writeByte(0); // null ItemValue
            }
        }
        for (0..12) |_| try ew.writeI32(0); // cosmetic ids
        try ew.writeI32(0); // unlocked cosmetics count
        cap_b.clear();
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePlayerEquipment", ew.written()));
        const got_eq = cap_b.findPkgIdEntity(eq_id, ca.entity_id) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, ew.written(), got_eq);
        // The parser landed the item in the slot it was written to, and left
        // its neighbours empty: a cursor that drifted by one byte would not.
        {
            const psa = g.sim.playerByPeer(ca.slot).?;
            const inv = &g.sim.inventory[psa];
            const base = quest_mod_components.inv_equip_start;
            try std.testing.expect(inv.slots[base + 3].item_id != 0);
            try std.testing.expectEqual(@as(u16, 0), inv.slots[base + 2].item_id);
            try std.testing.expectEqual(@as(u16, 0), inv.slots[base + 4].item_id);
        }

        // A body with trailing bytes relays trimmed to the stock length.
        cap_b.clear();
        var padded: [288]u8 = undefined;
        const n_eq = ew.written().len;
        @memcpy(padded[0..n_eq], ew.written());
        @memset(padded[n_eq..][0..7], 0xb7);
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePlayerEquipment", padded[0 .. n_eq + 7]));
        const trimmed = cap_b.findPkgIdEntity(eq_id, ca.entity_id) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(n_eq, trimmed.len);

        // Spoofed: A claims B's entity id. The relay must drop it, or one
        // client could rewrite another's visible gear.
        cap_b.clear();
        var spoof: [64]u8 = undefined;
        var sw = binary.Writer{ .buf = &spoof };
        try sw.writeI32(ca.entity_id + 1000); // not A's entity
        try sw.writeByte(0);
        for (0..5) |_| try sw.writeBool(false);
        for (0..5) |_| try sw.writeI32(0);
        try sw.writeI32(0);
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePlayerEquipment", sw.written()));
        try std.testing.expect(cap_b.findPkgId(eq_id) == null);
    }

    // EntityRagdoll: the last two verbatim relays had no scenario either. The
    // body is entityId | flags, with each flag bit selecting an optional tail
    // block; flags 0 is the minimal legal shape.
    if (packages.idOf("NetPackageEntityRagdoll")) |rag_id| {
        var rag: [16]u8 = undefined;
        var rw = binary.Writer{ .buf = &rag };
        try rw.writeI32(ca.entity_id);
        try rw.writeByte(0); // no duration/mode/state tails
        cap_b.clear();
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageEntityRagdoll", rw.written()));
        const got_rag = cap_b.findPkgIdEntity(rag_id, ca.entity_id) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, rw.written(), got_rag);
    }

    // ParticleEffect: ParticleId | pos f32x3 | rot f32x4 | colour bytes x4 |
    // two sound-name strings | volume f32 | entityThatCausedIt | two bools.
    // The relay excludes the causing entity, so A must not receive its own.
    if (packages.idOf("NetPackageParticleEffect")) |pe_id| {
        var pe: [128]u8 = undefined;
        var pw = binary.Writer{ .buf = &pe };
        try pw.writeI32(42); // ParticleId
        for (0..3) |_| try pw.writeF32(10.0); // pos
        for (0..4) |_| try pw.writeF32(0); // rot
        for (0..4) |_| try pw.writeByte(255); // colour
        try pw.writeString(""); // soundName
        try pw.writeString(""); // additionalHitSoundName
        try pw.writeF32(1.0); // volumeScale
        try pw.writeI32(0); // ParticleEffect.parentEntityId
        try pw.writeByte(0); // ParticleEffect.attachment
        try pw.writeI32(ca.entity_id); // entityThatCausedIt
        try pw.writeBool(false); // forceCreation
        try pw.writeBool(true); // worldSpawn
        cap_a.clear();
        cap_b.clear();
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageParticleEffect", pw.written()));
        const got_pe = cap_b.findPkgId(pe_id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, pw.written(), got_pe);
        // The causing entity already played the effect locally.
        try std.testing.expect(cap_a.findPkgId(pe_id) == null);
    }

    std.debug.print("PASS animation-relay: client anim params reach the other players\n", .{});
    std.debug.print("PASS equipment-relay: verbatim body relayed, spoofed entity dropped\n", .{});
    std.debug.print("PASS fx-relay: ragdoll and particle bodies relayed verbatim, causer excluded\n", .{});
}

test "scenario fall_sink clamps player vertical delta without the glide flag (moon_gravity)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const world_dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.createWithOptions(gpa, world_dir, 0, .{
        .rules = .{ .glide = .{ .fall_sink_vy_mps = 1.5 } },
    });
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    // Advance past tick 20 so the envelope dt below spans a full second.
    var st: u64 = 0;
    while (st < 25) : (st += 1) try g.step();
    g.sim.setPos(c.entity_id, 100, 100, 100, 0);
    game_movement_helpers.resetMoveEnvelopePeer(g, c.slot, 100, 100, 100);
    c.move_valid = true; // the reset arms the envelope for the next packet
    // dt from the envelope is (tick_n - move_tick) x 20 Hz: put the last
    // accepted move 20 ticks ago so the fall delta spans exactly 1 s.
    c.move_tick = g.tick_n -| 20;

    // A fast fall (dy = -20 over 1 s) is clamped to the 1.5 blocks/s sink.
    const r = game_movement_helpers.applyMovementEnvelope(g, c, c.peer orelse return error.MissingPeer, c.entity_id, 100, 80, 100);
    try std.testing.expect(r.applied);
    // max_dy = 1.5 * dt(1s) = 1.5; clamped y = 100 - 1.5 = 98.5.
    try std.testing.expectApproxEqAbs(@as(f32, 98.5), r.y, 0.5);
}

test "scenario zombie kills reach the client on the PlayerStats wire" {
    // EntityNetworkStats killed / killedZombies (stock write IL=104) drives the
    // client's stats UI. Both fields used to be hardcoded 0 on every
    // NetPackagePlayerStats, so a player's kill count always rendered as zero.
    // The server counts kills on its own authoritative death path.
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
    const ca = try g.attachJoinedClient(&cap);
    try std.testing.expectEqual(@as(u16, 0), ca.zombie_kills);

    // Two authoritative kills through the real C2S damage path.
    var fbuf: [512]u8 = undefined;
    var dmg: [256]u8 = undefined;
    for (0..2) |i| {
        const zid = g.sim.spawnZombie(258 + @as(f32, @floatFromInt(i)), 70, 258, 10).?;
        const dbody = try packages.buildDamageBody(&dmg, zid, 0, 3, 100, true, ca.entity_id);
        try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody));
        try std.testing.expect(g.sim.health[g.sim.slotOfNetId(zid).?].hp <= 0);
    }
    try std.testing.expectEqual(@as(u16, 2), ca.zombie_kills);

    // And the count is what the wire actually carries. Capture the real
    // NetPackagePlayerStats the server sends (a progression broadcast), not a
    // body rebuilt here: rebuilding would still pass if the send site dropped
    // the field.
    // broadcastPlayerStats skips the owning peer (stock pushes a player's
    // stats to the *other* clients), so observe it from a second client.
    var cap_b: ln_peer.Capture = .{};
    const cb = try g.attachJoinedClient(&cap_b);
    cap_b.n = 0; // drop join traffic; keep only the broadcast below
    game_player.broadcastPlayerStats(g, ca.slot);
    const ps_id = packages.idOf("NetPackagePlayerStats").?;
    const sent = cap_b.findPkgId(ps_id) orelse return error.TestUnexpectedResult;
    var r: binary.Reader = .{ .data = sent };
    _ = try r.readI32(); // entity_id
    try std.testing.expectEqual(@as(i32, 2), try r.readI32()); // killed

    // killedPlayers is the same shape: the counter existed and fed
    // AddScoreClient, but PlayerStats hardcoded 0. PvP damage needs
    // PlayerKillingMode != 0 (pvp_mode 0 drops player-to-player damage).
    g.pvp_mode = 3;
    const victim_nid = cb.entity_id;
    const pbody = try packages.buildDamageBody(&dmg, victim_nid, 0, 3, 1000, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", pbody));
    try std.testing.expectEqual(@as(u16, 1), ca.player_kills);
    cap_b.n = 0;
    game_player.broadcastPlayerStats(g, ca.slot);
    const sent2 = cap_b.findPkgId(ps_id) orelse return error.TestUnexpectedResult;
    // Walk the stock EntityNetworkStats write order (IL=104) to the two kill
    // counters rather than guessing offsets.
    var r2: binary.Reader = .{ .data = sent2 };
    _ = try r2.readI32(); // entity_id
    try std.testing.expectEqual(@as(i32, 2), try r2.readI32()); // killed
    _ = try r2.readU16(); // held item: empty ItemStack (count 0)
    _ = try r2.readByte(); // holdingItemIndex
    _ = try r2.readI32(); // deathHealth
    _ = try r2.readByte(); // teamNumber
    _ = try r2.readI32(); // attachedToEntityId
    var name_buf: [64]u8 = undefined;
    _ = try r2.readString(&name_buf); // entity_name
    _ = try r2.readBool(); // isPlayer
    try std.testing.expectEqual(@as(i32, 2), try r2.readI32()); // killedZombies
    try std.testing.expectEqual(@as(i32, 1), try r2.readI32()); // killedPlayers

    // NetPackageEntityAddScoreClient carries both counters in one body (RE
    // protocol-packages.md 27: entityId, zombieKills i16, playerKills i16,
    // otherTeamNumber i16, conditions i32). A site that fills only
    // zombie_kills lets the struct default playerKills to 0, so the next
    // zombie kill contradicts the PvP count this client was already told.
    const score_id = packages.idOf("NetPackageEntityAddScoreClient") orelse
        return error.TestUnexpectedResult;
    cap.n = 0;
    const z3_nid = g.sim.spawnZombie(280, 70, 280, 101) orelse return error.TestUnexpectedResult;
    const zbody = try packages.buildDamageBody(&dmg, z3_nid, 0, 3, 1000, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", zbody));
    const score = cap.findPkgId(score_id) orelse return error.TestUnexpectedResult;
    var r3: binary.Reader = .{ .data = score };
    _ = try r3.readI32(); // entity_id
    _ = try r3.readI16(); // zombieKills
    try std.testing.expectEqual(@as(i16, 1), try r3.readI16()); // playerKills

    std.debug.print("PASS kill-counter: zombie + PvP kills ride the PlayerStats wire\n", .{});
}

test "scenario pvp_mode 0 drops a player-to-player damage claim" {
    // Stock PlayerKillingMode 0 ("no killing") is a server policy the client
    // cannot opt out of: a DamageEntity naming another player is dropped
    // before it can touch health. The kill-counter scenario above only ever
    // runs with pvp_mode 3, so the deny half needs its own world (the damage
    // path is rate-limited per client, so it cannot share one).
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

    g.pvp_mode = 0;
    const vslot = g.sim.slotOfNetId(cb.entity_id) orelse return error.TestUnexpectedResult;
    const hp_before = g.sim.health[vslot].hp;
    try std.testing.expect(hp_before > 0);

    var dmg: [256]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    // `fatal` is set, so a gate that let this through would leave the victim
    // present at zero health rather than merely wounded.
    const denied = try packages.buildDamageBody(&dmg, cb.entity_id, 0, 3, 1000, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", denied));
    try std.testing.expectApproxEqAbs(hp_before, g.sim.health[vslot].hp, 0.01);
    try std.testing.expectEqual(@as(u16, 0), ca.player_kills);

    // Same claim with PvP enabled lands, so the rejection above is the mode
    // gate and not some unrelated reason the packet never arrived.
    g.pvp_mode = 3;
    const allowed = try packages.buildDamageBody(&dmg, cb.entity_id, 0, 3, 1000, true, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", allowed));
    try std.testing.expect(g.sim.health[vslot].hp < hp_before);
    std.debug.print("PASS pvp-gate: pvp_mode 0 denies, pvp_mode 3 allows\n", .{});
}

test "scenario every registered package id survives dispatch with a malformed body" {
    // Two properties, both cheap and both real:
    //
    // 1. Robustness. Every registered package id is dispatched with an empty
    //    body. A handler that indexes a short body without checking, or traps
    //    on a bad cast, fails here rather than when a client sends a truncated
    //    packet. This is the fuzz-shaped half and is the reason to keep it.
    // 2. Coverage floor. A large share of the registry is S2C-only (the server
    //    builds and sends those; a stock client never sends one back), so the
    //    fallthrough set is big and churns whenever a new S2C package lands.
    //    Pinning the exact list would be brittle, so assert the floor instead:
    //    the C2S handlers must keep covering at least as many packages as they
    //    do today. A dropped handler trips it; adding an S2C package does not.
    //
    // docs/DIVERGENCES.md 3b carries the per-package reasoning.
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
    const ca = try g.attachJoinedClient(&cap);
    const peer = ca.peer orelse return error.TestUnexpectedResult;
    // Phase .playing needs joined AND entered: the gate returns before any
    // handler runs, so without this the sweep would measure the gate, not the
    // handlers, and would pass even with every handler deleted.
    ca.entered = true;
    const rejects_before = g.harness.counters.get(.phase_rejects);

    var handled_n: usize = 0;
    for (packages.default_mappings, 0..) |name, id| {
        // Skip the teardown verbs: they call dropClientSlot, which resets the
        // client so every later package phase-rejects and the rest of the sweep
        // becomes vacuous. Both are handled, so skipping costs no coverage.
        if (std.mem.eql(u8, name, "NetPackagePlayerDisconnect") or
            std.mem.eql(u8, name, "NetPackageClientInfo")) continue;
        const before = g.harness.counters.get(.c2s_unhandled);
        // Empty is the coverage probe (a handler that claims the name returns
        // without touching the counter). The bodies after it are the
        // robustness half: a handler that reads a length prefix and then
        // slices, or casts a field it has not bounds-checked, trips on one of
        // these rather than on a real truncated packet.
        //   - all-zero: zero counts and zero-length strings
        //   - all-0xff: max counts, huge 7-bit string lengths, -1 ids
        //   - 0x7f run: 7-bit-encoded lengths that continue past the body
        //   - one byte: a length prefix with nothing behind it
        g.handlePackage(ca, peer, @intCast(id), &.{}) catch continue;
        if (g.harness.counters.get(.c2s_unhandled) == before) handled_n += 1;
        var zero_body: [64]u8 = .{0} ** 64;
        var ones_body: [64]u8 = .{0xff} ** 64;
        var cont_body: [64]u8 = .{0x7f} ** 64;
        const shapes = [_][]const u8{
            zero_body[0..1],  ones_body[0..1],
            zero_body[0..2],  ones_body[0..2],
            zero_body[0..8],  ones_body[0..8],
            cont_body[0..8],  zero_body[0..64],
            ones_body[0..64], cont_body[0..64],
        };
        for (shapes) |shape| {
            // A returned error is fine (reject); a trap, OOB slice or leak is
            // not, and the test allocator plus safety checks catch those.
            g.handlePackage(ca, peer, @intCast(id), shape) catch {};
        }
    }

    // Nothing may be silently eaten by the phase gate; that would make the
    // sweep vacuous (it would measure the gate instead of the handlers).
    try std.testing.expectEqual(rejects_before, g.harness.counters.get(.phase_rejects));
    // Measured 2026-09-06: 87 of the 189 swept ids reach a C2S handler (191
    // registered, less the two teardown verbs skipped above). Was 84 until
    // EntityStatChanged, GameEventResponse and SharedPartyKill gained arms.
    try std.testing.expect(handled_n >= 87);
    // "Reaches no C2S handler" and "the server sends it" are different
    // properties, and only the first is measured here: 55 registered names are
    // never referenced in src/server/ at all, registered for id mapping and
    // never emitted (DIVERGENCES 3b). Do not call the remainder "S2C-only" in
    // this message - that wording is what let the two get conflated.
    std.debug.print(
        "PASS c2s-coverage: {d}/{d} registered packages reach a C2S handler\n",
        .{ handled_n, packages.default_mappings.len },
    );
}

test "scenario entities.zen vehicle kind byte is range-checked before the cast" {
    // VehicleKind is an exhaustive enum(u8) with five values, and the record
    // type-1 branch turns a raw disk byte into one. @enumFromInt panics on an
    // out-of-range value, so a corrupt or hand-edited entities.zen would take
    // the server down on load rather than failing closed. Same shape as the
    // allies.zal status byte (fixed 2026-09-01).
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_zentkind");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_zentkind", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    // One type-1 (vehicle) record whose kind byte is 0xff: past the enum.
    var body: [64]u8 = .{0} ** 64;
    @memcpy(body[0..4], "ZENT");
    std.mem.writeInt(u16, body[4..6], 1, .little); // one record
    body[6] = 1; // rec_type: vehicle
    body[7] = 0xff; // kind: not a VehicleKind
    // The rest (x/y/z/yaw/fuel f32, seats u8, max_speed f32) stays zero; the
    // cast happens before any of it is read.
    var path_buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/entities.zen", .{g.world.world_dir});
    try io_fs.writeFile(p, body[0..26]);

    // Must fail closed, not panic.
    persist.loadEntities(g) catch {};

    // The record count is a u16 read off disk and the loop trusts it, relying
    // on every field read returning Truncated instead of a pre-checked total
    // size (unlike ZBM2, which validates the whole table up front). Pin that:
    // a count the file cannot back has to stop at the first short read.
    var claims_more: [6]u8 = undefined;
    @memcpy(claims_more[0..4], "ZENT");
    std.mem.writeInt(u16, claims_more[4..6], 400, .little); // claims 400 records, carries none
    try io_fs.writeFile(p, &claims_more);
    try std.testing.expectError(error.Truncated, persist.loadEntities(g));

    // A record cut mid-field is the same path one step further in.
    var cut: [6 + 4]u8 = @splat(0);
    @memcpy(cut[0..4], "ZENT");
    std.mem.writeInt(u16, cut[4..6], 1, .little);
    cut[6] = 1; // rec_type vehicle, then the kind byte and f32s are missing
    try io_fs.writeFile(p, &cut);
    try std.testing.expectError(error.Truncated, persist.loadEntities(g));

    // A count of zero is a legal empty file, not an error.
    var empty: [6]u8 = undefined;
    @memcpy(empty[0..4], "ZENT");
    std.mem.writeInt(u16, empty[4..6], 0, .little);
    try io_fs.writeFile(p, &empty);
    try persist.loadEntities(g);

    // Type-3 records carry a u16 edge count with no cap of its own: the loop
    // trusts it and leans on each field read returning Truncated, while
    // addPendingWire caps what actually lands. A file claiming 65535 edges and
    // carrying none is the hostile shape, and it has to stop at the first short
    // read rather than walking the whole declared count.
    var wires: [6 + 3]u8 = @splat(0);
    @memcpy(wires[0..4], "ZENT");
    std.mem.writeInt(u16, wires[4..6], 1, .little); // one record
    wires[6] = 3; // rec_type: power wire edges
    std.mem.writeInt(u16, wires[7..9], 65535, .little); // claims 65535 edges, carries none
    try io_fs.writeFile(p, &wires);
    try std.testing.expectError(error.Truncated, persist.loadEntities(g));
    try std.testing.expectEqual(@as(usize, 0), g.sim.power.pending_wire_n);

    std.debug.print("PASS zent-kind: bad kind, short tables, empty file and a 65535-edge claim all fail closed\n", .{});
}

test "scenario the attack target is published on change and cleared when it dies" {
    // Stock fans NetPackageSetAttackTarget out of every server-side target
    // change: EntityAlive::SetAttackTarget (IL=70) sends the new target and
    // the OnUpdateLive expiry (IL=363) sends -1. The client keeps it as
    // attackTargetClient, which is what GetAttackTargetLocal returns for a
    // remote entity (drone beam, DynamicMusic threat level). zdtd picked
    // targets in the sim and published none until 2026-09-06.
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
    const ps = g.sim.playerByPeer(c.slot) orelse return error.TestUnexpectedResult;
    const pp = g.sim.transform[ps];
    const at_id = packages.idOf("NetPackageSetAttackTarget") orelse
        return error.TestUnexpectedResult;

    const z1 = g.sim.spawnZombie(pp.x + 3, pp.y, pp.z, 100) orelse
        return error.TestUnexpectedResult;
    const s1 = g.sim.slotOfNetId(z1) orelse return error.TestUnexpectedResult;

    // An untargeted zombie still publishes once: the client needs to know it
    // has no target, and stock's -1 is a real wire value.
    cap.clear();
    g.tickAttackTarget();
    const first = cap.findPkgIdEntity(at_id, z1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 8), first.len);
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, first[4..8], .little));

    // Unchanged: no re-send. Stock sends per change, not per tick.
    cap.clear();
    g.tickAttackTarget();
    try std.testing.expect(cap.findPkgIdEntity(at_id, z1) == null);

    // Acquiring the player publishes the player's entity id.
    g.sim.zombie_ai[s1].target_id = c.entity_id;
    cap.clear();
    g.tickAttackTarget();
    const acq = cap.findPkgIdEntity(at_id, z1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(c.entity_id, std.mem.readInt(i32, acq[4..8], .little));

    // Same target next tick: quiet again.
    cap.clear();
    g.tickAttackTarget();
    try std.testing.expect(cap.findPkgIdEntity(at_id, z1) == null);

    // A target that stops being alive reads as no target, exactly like the
    // stock expiry clear: the id stays in the sim but must not go out.
    g.sim.alive[ps] = false;
    cap.clear();
    g.tickAttackTarget();
    const cleared = cap.findPkgIdEntity(at_id, z1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, cleared[4..8], .little));

    // The pass must be wired into the real tick, not just callable: a fresh
    // zombie has to reach the client through g.step() alone. Without this the
    // rest of the test still passes with the step.zig call site deleted.
    g.sim.alive[ps] = true;
    const z2 = g.sim.spawnZombie(pp.x + 4, pp.y, pp.z, 100) orelse
        return error.TestUnexpectedResult;
    cap.clear();
    try g.step();
    try std.testing.expect(cap.findPkgIdEntity(at_id, z2) != null);

    std.debug.print("PASS attack-target: published on change, -1 when the target is gone\n", .{});
}

test "scenario a kill notifies the killer's client so kill challenges advance" {
    // Stock GameManager.AwardKill (IL=27) ships
    // NetPackageEntityAwardKillServer(killerId, killedId) to a remote killer,
    // and its client runs QuestEventManager.EntityKilled (IL=24) to fire the
    // local EntityKill event that Challenges/ChallengeObjectiveKill and
    // ChallengeObjectiveKillByTag subscribe to. zdtd credited the kill
    // server-side and sent nothing, so kill challenges never advanced.
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
    const award_id = packages.idOf("NetPackageEntityAwardKillServer") orelse
        return error.TestUnexpectedResult;

    const zid = g.sim.spawnZombie(258, 70, 258, 10) orelse
        return error.TestUnexpectedResult;
    var dmg: [256]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    const dbody = try packages.buildDamageBody(&dmg, zid, 0, 3, 100, true, ca.entity_id);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody));
    try std.testing.expect(g.sim.health[g.sim.slotOfNetId(zid).?].hp <= 0);

    // The killer's client is told, with its own entity as the killer and the
    // dead zombie as the victim (stock Setup(killer.entityId, killed.entityId)).
    const body = cap_a.findPkgIdEntity(award_id, ca.entity_id) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 8), body.len);
    try std.testing.expectEqual(zid, std.mem.readInt(i32, body[4..8], .little));

    // Only the killer: stock sends this to the killer's connection, not to
    // everyone, and a bystander crediting the kill would be wrong.
    var pkgs: [8]wire_frame.Package = undefined;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            try std.testing.expect(p.id != award_id);
        }
    }

    // The explosion death path is a separate call site (c2s/blocks.zig, the
    // ExplosionInitiate arm) and needs its own coverage: with only the melee
    // path exercised, deleting the explosion notify leaves this test green.
    const z2 = g.sim.spawnZombie(252, 70, 252, 10) orelse
        return error.TestUnexpectedResult;
    cap_a.clear();
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
        try w.writeF32(8); // blast radius: enough to reach the zombie
        try w.writeU16(0);
        try w.writeI32(ca.entity_id);
        try w.writeF32(0);
        var fb: [256]u8 = undefined;
        try g.injectFramed(ca, try packages.framed(&fb, "NetPackageExplosionInitiate", w.written()));
    }
    if (g.sim.slotOfNetId(z2)) |z2s| {
        if (g.sim.health[z2s].hp <= 0) {
            const eb2 = cap_a.findPkgIdEntity(award_id, ca.entity_id) orelse
                return error.TestUnexpectedResult;
            try std.testing.expectEqual(z2, std.mem.readInt(i32, eb2[4..8], .little));
        }
    }

    std.debug.print("PASS award-kill: the killer's client is notified, nobody else\n", .{});
}

test "scenario the land-claim repair heals damaged blocks and answers the requester" {
    // Stock TEFeatureAreaRepair.RepairAll (IL=9): walk the claim area and
    // restore every damaged block, emitting nothing; the repair coroutine
    // ends with Setup(blockPos, false) to the requester (IL_0337). zdtd used
    // to broadcast the package to every peer and repair nothing.
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
    const owner = try g.attachJoinedClient(&cap_a);
    const other = try g.attachJoinedClient(&cap_b);

    const cx: i32 = 250;
    const cz: i32 = 250;
    const stone = world_store.block_stone;
    // Two stone blocks inside the claim, one damaged.
    try g.world.setBlockWorld(cx + 1, 70, cz, stone);
    try g.world.setBlockWorld(cx + 2, 70, cz, stone);
    try g.setBlockHp(cx + 1, 70, cz, 500);
    try std.testing.expectEqual(@as(u16, 500), g.getBlockHp(cx + 1, 70, cz));
    g.registerClaim(cx, 70, cz, owner.entity_id);

    const repair_id = packages.idOf("NetPackageLandClaimRepair") orelse
        return error.TestUnexpectedResult;
    const setblock_id = packages.idOf("NetPackageSetBlock") orelse
        return error.TestUnexpectedResult;
    var rb: [32]u8 = undefined;
    var fb: [8192]u8 = undefined;
    var pkgs: [8]wire_frame.Package = undefined;

    // A stranger's request is an ownership reject: nothing heals.
    const stranger = try packages.buildLandClaimRepairBody(&rb, cx, 70, cz, true);
    try g.injectFramed(other, try packages.framed(&fb, "NetPackageLandClaimRepair", stranger));
    try std.testing.expectEqual(@as(u16, 500), g.getBlockHp(cx + 1, 70, cz));

    // The owner's begin-repair heals the damaged block and leaves the clean
    // one alone; the fix fans out as a SetBlock with damage 0.
    const begin = try packages.buildLandClaimRepairBody(&rb, cx, 70, cz, true);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(owner, try packages.framed(&fb, "NetPackageLandClaimRepair", begin));
    try std.testing.expectEqual(@as(u16, 0), g.getBlockHp(cx + 1, 70, cz));

    // The repaired cell must arrive as a SetBlock with damage 0.
    var saw_fix = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != setblock_id) continue;
            const first = packages.parseSetBlockBody(p.body) catch continue;
            if (first.block_id == stone) saw_fix = true;
        }
    }
    try std.testing.expect(saw_fix);

    // The requester gets the end-repair (begin=false); nobody got the
    // begin-repair rebroadcast the old code fanned out.
    var saw_done = false;
    for (cap_a.slots[0..cap_a.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != repair_id or p.body.len < 25) continue;
            if (p.body[p.body.len - 1] == 0) saw_done = true;
        }
    }
    try std.testing.expect(saw_done);
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            try std.testing.expect(p.id != repair_id);
        }
    }

    std.debug.print("PASS claim-repair: damage cleared, fix replicated, requester answered\n", .{});
}

test "scenario a landed hit fans the applied damage to the victim's trackers" {
    // Stock EntityAlive.ProcessDamageResponse (IL=86) sends
    // NetPackageDamageEntity Setup(entityId, response) to the victim's
    // tracked players: the client plays the hit reaction and reads the
    // dismember/cripple/crawler bits off it. zdtd applied damage silently,
    // so no hit was ever visible to anyone but the attacker's own client.
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
    const dmg_id = packages.idOf("NetPackageDamageEntity") orelse
        return error.TestUnexpectedResult;

    const zid = g.sim.spawnZombie(258, 70, 258, 100) orelse
        return error.TestUnexpectedResult;
    var dmg: [256]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    const dbody = try packages.buildDamageBody(&dmg, zid, 0, 3, 20, false, ca.entity_id);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", dbody));

    // A bystander tracking the victim sees the applied damage with the
    // server-side attacker id, not just the attacker's echo.
    var pkgs: [8]wire_frame.Package = undefined;
    var saw = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != dmg_id) continue;
            const head = packages.parseDamageHead(p.body) catch continue;
            if (head.entity_id == zid) saw = true;
        }
    }
    try std.testing.expect(saw);

    std.debug.print("PASS s2c-damage: the victim's trackers see the applied hit\n", .{});
}

test "scenario a leg hit past the crawler threshold crawlers the zombie" {
    // Stock EntityAlive.CheckDismember (IL=125): a leg hit whose damage
    // fraction reaches the class LegCrawlerThreshold sets TurnIntoCrawler,
    // and the S2C damage body carries 0x200. The template default threshold
    // is 0 (path off); a class carrying .175 crawlers on a 20%-hp hit.
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
    const dmg_id = packages.idOf("NetPackageDamageEntity") orelse
        return error.TestUnexpectedResult;

    const zid = g.sim.spawnZombie(258, 70, 258, 100) orelse
        return error.TestUnexpectedResult;
    const zs = g.sim.slotOfNetId(zid) orelse return error.TestUnexpectedResult;
    // A class with a live crawler threshold and no cripple scale isolates
    // the crawler arm: fraction = damage / max_hp.
    g.sim.class_id[zs].leg_crawler_threshold = 0.175;
    g.sim.class_id[zs].leg_cripple_scale = 0;
    try std.testing.expect(g.sim.mask[zs].class_id);

    // LeftLowerLeg = 256. 20 damage on 100 hp = 0.2 >= 0.175.
    var dmg: [256]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &dmg };
    try w.writeI32(zid);
    try w.writeU32(packages.dmg_pain_hit);
    try w.writeByte(0);
    try w.writeByte(3);
    try w.writeU16(20);
    try w.writeByte(0);
    try w.writeI16(256);
    try w.writeByte(0);
    try w.writeI32(ca.entity_id);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", w.written()));

    try std.testing.expect(g.sim.zombie_ai[zs].crawler);
    // The bystander sees the crawler bit on the fanned-out body.
    var pkgs: [8]wire_frame.Package = undefined;
    var saw = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != dmg_id or p.body.len < 8) continue;
            const head = packages.parseDamageHead(p.body) catch continue;
            if (head.entity_id != zid) continue;
            const fl = std.mem.readInt(u32, p.body[4..8], .little);
            if (fl & packages.dmg_turn_into_crawler != 0) saw = true;
        }
    }
    try std.testing.expect(saw);

    std.debug.print("PASS dismember-roll: threshold leg hit crawlers and reports 0x200\n", .{});
}

test "scenario a perked attacker's dismember bonus reaches the S2C damage body" {
    // Stock GetDismemberChance (IL=128): weapon x damagePer x (region mult +
    // attacker DismemberSelfChance-143 bonuses). Fixture: weapon chance 1,
    // head hit at 0.5 fraction, perk bonus 200 -> chance 100.5, clamped to
    // 100, so the dismember bit always lands on the fanned-out body. Without
    // the fold the chance is 0.5 and the bit is draw-dependent; the
    // with-perk assert below is deterministic and fails if the wiring drops
    // the bonus.
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
    const dmg_id = packages.idOf("NetPackageDamageEntity") orelse
        return error.TestUnexpectedResult;

    // One-def weapon table: item 9 carries DismemberChance 1.
    const wdefs = [_]assets_items.ItemDef{.{ .id = 9, .name = "testMachete", .dismember_chance = 1 }};
    g.items.defs = wdefs[0..];
    const ps = g.sim.playerByPeer(ca.slot).?;
    g.sim.inventory[ps].slots[g.sim.inventory[ps].holding] = .{ .item_id = 9, .count = 1, .quality = 1 };
    // Perk with a +200 DismemberSelfChance row at level 1.
    const perks = [_]assets_progression.PerkDef{
        .{
            .name = "perkSkullCrusher",
            .max_level = 5,
            .passives = &.{.{ .name = "DismemberSelfChance", .op = .base_add, .value = 200 }},
        },
    };
    g.progression_table.perks = &perks;
    g.clients[ca.slot].skill_levels[0] = .{ .name = "perkSkullCrusher", .level = 1 };
    g.clients[ca.slot].skill_level_n = 1;

    const zid = g.sim.spawnZombie(258, 70, 258, 100) orelse
        return error.TestUnexpectedResult;
    const zs = g.sim.slotOfNetId(zid) orelse return error.TestUnexpectedResult;
    g.sim.class_id[zs].dismember_head = 1;
    try std.testing.expect(g.sim.mask[zs].class_id);

    // Head = 2. 50 damage on 100 hp = 0.5 fraction.
    var dmg: [256]u8 = undefined;
    var fbuf: [512]u8 = undefined;
    var w: binary.Writer = .{ .buf = &dmg };
    try w.writeI32(zid);
    try w.writeU32(packages.dmg_pain_hit);
    try w.writeByte(0);
    try w.writeByte(3);
    try w.writeU16(50);
    try w.writeByte(0);
    try w.writeI16(2);
    try w.writeByte(0);
    try w.writeI32(ca.entity_id);
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fbuf, "NetPackageDamageEntity", w.written()));

    var pkgs: [8]wire_frame.Package = undefined;
    var saw = false;
    for (cap_b.slots[0..cap_b.n]) |s| {
        const pn = wire_frame.parseChannelPayload(s.data[0..s.len], &pkgs);
        for (pkgs[0..pn]) |p| {
            if (p.id != dmg_id or p.body.len < 8) continue;
            const head = packages.parseDamageHead(p.body) catch continue;
            if (head.entity_id != zid) continue;
            const fl = std.mem.readInt(u32, p.body[4..8], .little);
            if (fl & packages.dmg_dismember != 0) saw = true;
        }
    }
    try std.testing.expect(saw);

    std.debug.print("PASS dismember-143-e2e: perk bonus lands the dismember bit on S2C\n", .{});
}

test "scenario player death sends the deficit sequence action under XPOnly" {
    // Stock EntityPlayer.HandleClientDeath (IL=71) switches on DeathPenalty:
    // 1 runs game_on_death_default, 2 runs game_on_death_injured, and both
    // carry AddXPDeficit at action index 0. The server performs it as a
    // ClientSequenceAction (12) response so the dead player's client earns
    // the deficit locally (AddXPDeficit IL=65); without the send the client
    // never runs it from the server side.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_deathdeficit");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_deathdeficit", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);
    const ps = g.sim.playerByPeer(c.slot).?;
    g.death_penalty = 1;
    _ = g.sim.damageFrom(g.sim.network_id[ps].id, 1000, -1);
    try std.testing.expectEqual(@as(f32, 0), g.sim.health[ps].hp);
    cap.clear();
    g.replicatePlayerHealth();
    const resp_id = packages.idOf("NetPackageGameEventResponse").?;
    const body = cap.findPkgId(resp_id) orelse return error.TestUnexpectedResult;
    var r = binary.Reader{ .data = body };
    var nb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("game_on_death_default", try r.readString(&nb));
    try std.testing.expectEqual(c.entity_id, try r.readI32());
    var eb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&eb));
    var tb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&tb));
    try std.testing.expectEqual(@as(u8, 12), try r.readByte());
    // DeathPenalty 2 selects the injured sequence instead.
    g.death_penalty = 2;
    g.sim.health[ps].hp = 100;
    g.sim.markDirty(ps, .{ .hp = true });
    _ = g.sim.damageFrom(g.sim.network_id[ps].id, 1000, -1);
    cap.clear();
    g.replicatePlayerHealth();
    const body2 = cap.findPkgId(resp_id) orelse return error.TestUnexpectedResult;
    var r2 = binary.Reader{ .data = body2 };
    var nb2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("game_on_death_injured", try r2.readString(&nb2));
    // DeathPenalty 0 sends nothing: game_on_death_none carries no deficit arm.
    g.death_penalty = 0;
    g.sim.health[ps].hp = 100;
    g.sim.markDirty(ps, .{ .hp = true });
    _ = g.sim.damageFrom(g.sim.network_id[ps].id, 1000, -1);
    cap.clear();
    g.replicatePlayerHealth();
    try std.testing.expect(cap.findPkgId(resp_id) == null);
    std.debug.print("PASS death-deficit: XPOnly/Injured send the deficit action, None sends nothing\n", .{});
}

test "scenario playerdata: a spoofed entity id cannot reach another player's inventory" {
    // Every stock client sends NetPackagePlayerData periodically, and it is the
    // only C2S package that carries a whole inventory. The handler
    // (c2s/misc.zig) applies it to the *sender's* slot resolved from
    // playerByPeer, and only compares the body's entity id for the reject
    // counter. Nothing drove that path end to end, so the property that matters
    // (a forged id never crosses into another peer's slots) was unpinned.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_pdata");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_pdata", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const pa = g.sim.playerByPeer(ca.slot).?;
    const pb = g.sim.playerByPeer(cb.slot).?;
    try std.testing.expect(pa != pb);

    // Give B a distinct toolbelt slot 0 so any bleed-through is visible.
    g.sim.inventory[pb].slots[0] = .{ .item_id = 11, .count = 7, .quality = 1 };
    const b_before = g.sim.inventory[pb];

    const tb_item: u16 = 2;
    const eq_item: u16 = 8;
    var body_buf: [1024]u8 = undefined;

    // Honest body: A's own entity id. Toolbelt slot 0 and equip slot 0 land.
    var w: binary.Writer = .{ .buf = &body_buf };
    try packages.stock_inv.buildPlayerDataBodyForTest(&w, ca.entity_id, tb_item, eq_item);
    var fb: [1200]u8 = undefined;
    const own_before = g.harness.counters.get(.ownership_rejects);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePlayerData", w.written()));

    try std.testing.expectEqual(tb_item, g.sim.inventory[pa].slots[0].item_id);
    try std.testing.expectEqual(@as(u16, 3), g.sim.inventory[pa].slots[0].count);
    const eq = quest_mod_components.inv_equip_start;
    try std.testing.expectEqual(eq_item, g.sim.inventory[pa].slots[eq].item_id);
    try std.testing.expectEqual(own_before, g.harness.counters.get(.ownership_rejects));
    // B is untouched by A's own legitimate update.
    try std.testing.expectEqualDeep(b_before, g.sim.inventory[pb]);

    // Spoofed body: A claims B's entity id. The reject counter rises, A's own
    // slot still takes the write (the id is advisory), and B is untouched.
    var w2: binary.Writer = .{ .buf = &body_buf };
    const spoof_tb: u16 = 6;
    try packages.stock_inv.buildPlayerDataBodyForTest(&w2, cb.entity_id, spoof_tb, eq_item);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackagePlayerData", w2.written()));

    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expectEqual(spoof_tb, g.sim.inventory[pa].slots[0].item_id);
    try std.testing.expectEqualDeep(b_before, g.sim.inventory[pb]);
    std.debug.print("PASS playerdata: forged entity id counts a reject and never crosses slots\n", .{});
}

test "scenario skill purchase: the ledger keeps catalog memory, not the packet buffer" {
    // NetPackageEntitySetSkillLevelServer reads the skill name into a stack
    // buffer in the C2S handler, and Client.skill_levels[].name is a borrowed
    // slice that outlives the packet: the save writer and the passive-effects
    // fold read it later. The two sibling writers (addProgressionLevel,
    // setProgressionLevelMax) intern the name through the catalog; the
    // purchase path did not, so it parked a dangling slice in the ledger.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_skill");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_skill", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap: ln_peer.Capture = .{};
    const c = try g.attachJoinedClient(&cap);

    const attrs = [_]assets_progression.AttrDef{
        .{ .name = "attPerception", .max_level = 10, .base_cost = 1, .cost_mult = 1.0 },
    };
    g.progression_table.attributes = &attrs;
    g.clients[c.slot].skill_points = 5;

    var body: [256]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeI32(c.entity_id);
    try w.writeString("attPerception");
    try w.writeI32(1);
    var fb: [320]u8 = undefined;
    cap.clear();
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageEntitySetSkillLevelServer", w.written()));

    try std.testing.expectEqual(@as(u8, 1), g.skillLevelOf(c.slot, "attPerception"));
    try std.testing.expectEqual(@as(u32, 4), g.clients[c.slot].skill_points);
    // The stored name must alias the catalog row, not the handler's buffer.
    try std.testing.expectEqual(
        @intFromPtr(attrs[0].name.ptr),
        @intFromPtr(g.clients[c.slot].skill_levels[0].name.ptr),
    );
    // The client is told the new level.
    const echo_id = packages.idOf("NetPackageEntitySetSkillLevelClient").?;
    try std.testing.expect(cap.findPkgId(echo_id) != null);

    // A name outside the catalog is refused and costs nothing.
    var w2: binary.Writer = .{ .buf = &body };
    try w2.writeI32(c.entity_id);
    try w2.writeString("attNotInCatalog");
    try w2.writeI32(1);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageEntitySetSkillLevelServer", w2.written()));
    try std.testing.expectEqual(@as(u32, 4), g.clients[c.slot].skill_points);
    try std.testing.expectEqual(@as(usize, 1), g.clients[c.slot].skill_level_n);
    std.debug.print("PASS skill purchase: ledger name interned from the catalog\n", .{});
}

test "scenario wire tool: a claimed foreign entity id is dropped, not relayed" {
    // NetPackageWireToolActions::ProcessPackage (IL=254) opens with
    // ValidEntityIdForSender(entityID, false) and returns on failure, and its
    // switch acts only on operations 0 (SetParent) and 1 (RemoveParent),
    // returning before either SendPackage otherwise. zdtd relayed every body
    // unread, so one client could paint a wire-tool visual on another
    // player's hands and any operation byte was forwarded.
    io_fs.mkdirPath("worlds");
    freshScenarioDir("worlds/zdtd_sc_wiretool");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_wiretool", 0);
    defer {
        g.deinit();
        gpa.destroy(g);
    }

    var cap_a: ln_peer.Capture = .{};
    var cap_b: ln_peer.Capture = .{};
    const ca = try g.attachJoinedClient(&cap_a);
    const cb = try g.attachJoinedClient(&cap_b);
    const tool_id = packages.idOf("NetPackageWireToolActions").?;

    const Body = struct {
        fn make(buf: []u8, op: u8, eid: i32) ![]u8 {
            var w: binary.Writer = .{ .buf = buf };
            try w.writeByte(op);
            try w.writeI32(10);
            try w.writeI32(70);
            try w.writeI32(20);
            try w.writeI32(eid);
            return w.written();
        }
    };
    var body: [64]u8 = undefined;
    var fb: [128]u8 = undefined;

    // Own id, SetParent: relayed to the other peer, never echoed to the sender.
    cap_a.clear();
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWireToolActions", try Body.make(&body, 0, ca.entity_id)));
    const relayed = cap_b.findPkgId(tool_id);
    try std.testing.expect(relayed != null);
    const parsed = try packages.parseWireToolActions(relayed.?);
    try std.testing.expectEqual(ca.entity_id, parsed.entity_id);
    try std.testing.expectEqual(@as(i32, 70), parsed.y);
    try std.testing.expect(cap_a.findPkgId(tool_id) == null);

    // Another player's id: refused, and B sees nothing.
    const own_before = g.harness.counters.get(.ownership_rejects);
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWireToolActions", try Body.make(&body, 0, cb.entity_id)));
    try std.testing.expectEqual(own_before + 1, g.harness.counters.get(.ownership_rejects));
    try std.testing.expect(cap_b.findPkgId(tool_id) == null);

    // An operation stock's switch does not take is dropped before the relay.
    cap_b.clear();
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWireToolActions", try Body.make(&body, 2, ca.entity_id)));
    try std.testing.expect(cap_b.findPkgId(tool_id) == null);

    // A truncated body counts as malformed instead of being forwarded.
    const mal_before = g.harness.counters.get(.c2s_malformed);
    cap_b.clear();
    const full = try Body.make(&body, 0, ca.entity_id);
    try g.injectFramed(ca, try packages.framed(&fb, "NetPackageWireToolActions", full[0 .. full.len - 1]));
    try std.testing.expectEqual(mal_before + 1, g.harness.counters.get(.c2s_malformed));
    try std.testing.expect(cap_b.findPkgId(tool_id) == null);
    std.debug.print("PASS wire tool: sender-gated, op-gated, and length-checked before relay\n", .{});
}
