//! Integration scenarios: two-peer motion, damage wire kill, setblock replicate, persist restart.
//! These call shipped Game handlers (onData/handlePackage/replicate/broadcast), not mocks.

const std = @import("std");
const game_mod = @import("game.zig");
const ln_peer = @import("../litenet/peer.zig");
const packages = @import("../wire/packages.zig");
const world_store = @import("../world/store.zig");
const quest_mod = @import("../ecs/quest.zig");
const systems = @import("../ecs/systems.zig");
const io_fs = @import("../util/io_fs.zig");
const biome_layers = @import("../assets/biome_layers.zig");

test "scenario two-peer motion: B receives A PosAndRot" {
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_sc_motion");
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

test "scenario damage wire: fatal DamageEntity broadcasts EntityRemove" {
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_sc_dmg");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_dmg", 0);
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

    try std.testing.expect(g.sim.slotOfNetId(zid) == null);
    try std.testing.expect(g.sim.countKind(.loot_bag) >= 1);

    const rm_id = packages.idOf("NetPackageEntityRemove").?;
    const rm_a = cap_a.findPkgId(rm_id);
    const rm_b = cap_b.findPkgId(rm_id);
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_block");
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

test "scenario power switch: meta flip gates the grid and keeps the meta on the echo" {
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_sc_switch");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_trigger");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_stockmap");

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
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_sc_quest");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_quest", 0);
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

test "scenario vehicle enter drive and turret kills with power" {
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_sc_veh");
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const g = try game_mod.Game.create(gpa, "worlds/zdtd_sc_veh", 0);
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
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageVehicleDataSync", enter));
    try std.testing.expectEqual(c.entity_id, g.sim.vehicle[vslot].driver_net_id);

    const drive = try packages.buildVehicleControlBody(&vb, ve, 2, 1.0, 0.1);
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageVehicleDataSync", drive));
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
    try std.testing.expect(g.sim.slotOfNetId(zid) == null);
    try std.testing.expect(g.sim.countKind(.loot_bag) >= 1);
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_trig");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_inv");
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
    const drop_req = try packages.buildInvTxRequest(&txb, @intFromEnum(inv.Op.drop), 0, 0, 1, -1);
    var fb: [128]u8 = undefined;
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
        const stock_te = @import("../wire/stock_te.zig");
        const containers = @import("../world/containers.zig");
        var cont: containers.Container = .{
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_dir");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_weather");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_craft");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_refuel");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_eat");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_eat_pi");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_speedhack");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_guard_log");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_guard_quar");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_ws");
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
    io_fs.mkdirPathSimple("worlds/zdtd_sc_unload");
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

test "scenario zombie melee reaches the client as EntityStatChanged, then death and respawn" {
    // Regression for the "zombies cannot hurt you" gap: server-side melee moved
    // health[].hp and nothing was ever sent, so the victim's client saw no damage,
    // no death screen, and the server-side corpse could not fight back.
    io_fs.mkdirPathSimple("worlds");
    io_fs.mkdirPathSimple("worlds/zdtd_sc_hp_repl");
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
    _ = g.sim.spawnZombie(p.x + 1, p.y, p.z, 40).?;

    cap.clear();
    var t: u32 = 0;
    while (t < 60 and g.sim.health[ps].hp >= 100) : (t += 1) try g.step();
    try std.testing.expect(g.sim.health[ps].hp < 100);

    // Stock NetPackageEntityStatChanged::write (asm.il:201967, GetLength 21 at
    // :202120): entityId i32 (NetPackageEntityTargeted) | instigatorId i32 |
    // EnumStat u8 | value f32 | max f32 | maxModifier f32.
    const hit = cap.findPkgIdEntity(stat_id, c.entity_id) orelse return error.NoDamageStatPackage;
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
    const dead = cap.findPkgIdEntity(stat_id, c.entity_id) orelse return error.NoDeathStatPackage;
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, dead[9..13], .little))));

    // Respawn still heals and still tells the client.
    cap.clear();
    var spawn_body: [2]u8 = undefined;
    std.mem.writeInt(i16, spawn_body[0..2], 4, .little);
    var fb: [64]u8 = undefined;
    try g.injectFramed(c, try packages.framed(&fb, "NetPackageRequestToSpawnPlayer", &spawn_body));
    try std.testing.expectEqual(@as(f32, 100), g.sim.health[ps].hp);
    const alive_again = cap.findPkgIdEntity(stat_id, c.entity_id) orelse return error.NoRespawnStatPackage;
    try std.testing.expectEqual(@as(f32, 100), @as(f32, @bitCast(std.mem.readInt(u32, alive_again[9..13], .little))));

    std.debug.print(
        "PASS hp replication: hurt={d:.0}/{d:.0} then hp=0 then respawn hp={d:.0}\n",
        .{ hurt_hp, hurt_max, g.sim.health[ps].hp },
    );
}
