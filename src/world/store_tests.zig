//! World store tests: worldgen, persistence, water, SIMD, prefabs.
//!
//! Split out of world/store.zig (same code, moved verbatim).

const std = @import("std");
const test_tmp = @import("../util/test_tmp.zig");
const store = @import("store.zig");
const World = store.World;
const Chunk = store.Chunk;
const ChunkPos = store.ChunkPos;
const TerrainIds = store.TerrainIds;
const blockIndex = store.blockIndex;
const fillBlocksFromStack = store.fillBlocksFromStack;
const projectPlane = store.projectPlane;
const projectPlaneScalar = store.projectPlaneScalar;
const assignids = @import("../assets/assignids_comptime.zig");
const biome_layers = @import("../assets/biome_layers.zig");
const dtm = @import("dtm.zig");
const chunk_flush = @import("chunk_flush.zig");
const io_fs = @import("../util/io_fs.zig");
const parallel = @import("../util/parallel.zig");
const rules_mod = @import("../ecs/rules.zig");
const stock_paths = @import("../util/stock_paths.zig");
const water_mod = @import("water.zig");
const worldgen_mod = @import("worldgen.zig");
const block_air = store.block_air;
const block_stone = store.block_stone;
const block_dirt = store.block_dirt;
const block_water = store.block_water;
const body_height = store.body_height;
const max_drop = store.max_drop;
const max_step_up = store.max_step_up;
const sea_level = store.sea_level;
const y_dim = store.y_dim;
const prefabs = store.prefabs;

test "proc worldgen getOrCreate heights from seed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(0xA11CE);
    try std.testing.expect(w.terrain_source == .proc);
    const c = try w.getOrCreate(.{ .x = 2, .z = -1 });
    try std.testing.expect(c.heightAt(0, 0) >= worldgen_mod.min_surface);
    try std.testing.expect(c.heightAt(0, 0) <= worldgen_mod.max_surface);
    const h0 = c.heightAt(5, 7);
    const h_surf = c.heightAt(0, 0);
    try std.testing.expect(c.blockAt(0, h_surf, 0) != block_air);
    if (h_surf + 1 < y_dim) {
        try std.testing.expectEqual(block_air, c.blockAt(0, @intCast(h_surf + 1), 0));
    }
    // Same seed regenerates an identical heights AND block plane after a drop.
    const plane = try std.testing.allocator.dupe(u32, c.blocks.?);
    defer std.testing.allocator.free(plane);
    const heights_before = c.heights;
    if (w.chunks.fetchRemove(ChunkPos.hash(.{ .x = 2, .z = -1 }))) |kv| {
        var dead = kv.value;
        dead.deinitBlocks();
        w.allocator.destroy(dead);
    }
    const c2 = try w.getOrCreate(.{ .x = 2, .z = -1 });
    try std.testing.expectEqual(h0, c2.heightAt(5, 7));
    try std.testing.expectEqualSlices(u8, &heights_before, &c2.heights);
    try std.testing.expectEqualSlices(u32, plane, c2.blocks.?);
}

test "proc worlds persist only edited chunks" {
    // Infinite-world save growth: an untouched proc chunk regenerates from
    // the seed, so evicting/saving it must leave no file; an edit marks
    // dirty and persists.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    const pos = ChunkPos{ .x = 0, .z = 0 };
    const c = try w.getOrCreate(pos);
    try std.testing.expect(!c.dirty);
    var path_buf: [512]u8 = undefined;
    const path = try w.chunkPath(pos, &path_buf);
    try w.saveChunk(c);
    try std.testing.expect(!io_fs.fileExists(path));
    // An edit marks dirty and persists.
    try w.setBlockWorld(1, 10, 1, block_stone);
    try std.testing.expect(c.dirty);
    try w.saveChunk(c);
    try std.testing.expect(io_fs.fileExists(path));
}

test "proc worlds derive a spawn from the generated surface" {
    // No DTM spawn points on proc worlds: the spawn must sit above the
    // deterministic surface near the origin, not the hardcoded (256,70,256)
    // which can bury the player or leave them mid-air for a random seed.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(7);
    const sp = w.primarySpawn();
    try std.testing.expectEqual(@as(i32, 256), sp.x);
    try std.testing.expectEqual(@as(i32, 256), sp.z);
    const h = try w.heightWorld(sp.x, sp.z);
    try std.testing.expectEqual(@as(i32, @intCast(h)) + 2, sp.y);
    try std.testing.expect(sp.y > 3);
    // A different seed derives its own surface-relative spawn.
    w.enableProc(999);
    const sp2 = w.primarySpawn();
    const h2 = try w.heightWorld(sp2.x, sp2.z);
    try std.testing.expectEqual(@as(i32, @intCast(h2)) + 2, sp2.y);
}

test "a clean proc session writes no world files (mods leave no trace)" {
    // --preset infinite is an opt-in overlay: exploring materializes chunks but
    // nothing persists until the player edits, so removing the mod later
    // leaves the world dir exactly as it was (default behavior unchanged;
    // edits are the player's data).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    // Explore a few chunks as the stream would, then save-all like shutdown.
    _ = try w.getOrCreate(.{ .x = 0, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = -2, .z = 3 });
    try w.saveAll();
    var path_buf: [512]u8 = undefined;
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = 0, .z = 0 }, &path_buf)));
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = 1, .z = 0 }, &path_buf)));
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = -2, .z = 3 }, &path_buf)));
    // Derived decoration (the deco mirror) is re-derived on every stream and
    // reload, so it must not dirty the chunk or write files either - a clean
    // session truly leaves no trace (real edits still persist).
    try w.setBlockDecoWorld(3, 10, 3, block_stone);
    try std.testing.expect(!w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);
    try w.saveAll();
    try std.testing.expect(!io_fs.fileExists(try w.chunkPath(.{ .x = 0, .z = 0 }, &path_buf)));
    // An edit is the one thing that persists.
    try w.setBlockWorld(5, 10, 5, block_stone);
    try w.saveAll();
    try std.testing.expect(io_fs.fileExists(try w.chunkPath(.{ .x = 0, .z = 0 }, &path_buf)));
}

test "flat world set dig persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    try w.setBlockWorld(5, 70, 5, block_dirt);
    try w.setBlockWorld(6, 71, 5, block_stone);
    try std.testing.expectEqual(block_dirt, try w.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w.blockWorld(6, 71, 5));
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);
    try w.saveAll();
    try std.testing.expect(!w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?.dirty);

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 71), c.heightAt(6, 5));
    // Full columns must reload so dig/build is authoritative after restart.
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w2.blockWorld(6, 71, 5));
}

test "standableY answers the walk surface, not the column top" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    const g: i32 = ch.heightAt(0, 0); // flat sea_level surface

    // Flat ground: feet rest one above the surface block.
    try std.testing.expectEqual(@as(?i32, g + 1), ch.standableY(0, 0, g + 1, max_step_up, max_drop));

    // One-block wall: a body steps up onto it.
    try ch.setBlock(w.allocator, 1, g + 1, 0, block_stone);
    try std.testing.expectEqual(@as(?i32, g + 2), ch.standableY(1, 0, g + 1, max_step_up, max_drop));

    // Two-block wall: too high to step, no headroom on top of the first course.
    try ch.setBlock(w.allocator, 2, g + 1, 0, block_stone);
    try ch.setBlock(w.allocator, 2, g + 2, 0, block_stone);
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(2, 0, g + 1, max_step_up, max_drop));

    // POI interior: floor at g, roof at g+3. The floor wins over the roof even
    // though heightAt now reports the roof.
    try ch.setBlock(w.allocator, 3, g + 3, 0, block_stone);
    try std.testing.expectEqual(@as(u16, @intCast(g + 3)), ch.heightAt(3, 0));
    try std.testing.expectEqual(@as(?i32, g + 1), ch.standableY(3, 0, g + 1, max_step_up, max_drop));

    // Crawlspace: roof one block above the floor leaves no headroom.
    try ch.setBlock(w.allocator, 4, g + 2, 0, block_stone);
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(4, 0, g + 1, max_step_up, max_drop));

    // Drop: dug pit deeper than max_drop is refused, within it is accepted.
    var y: i32 = g;
    while (y > g - 2) : (y -= 1) try ch.setBlock(w.allocator, 5, y, 0, block_air);
    try std.testing.expectEqual(@as(?i32, g - 1), ch.standableY(5, 0, g + 1, max_step_up, max_drop));
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(5, 0, g + 1, max_step_up, 1));
}

test "standableY clamps at world floor and ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    // Bedrock floor: the lowest feet cell is 1, so a candidate never probes
    // support at y = -1 and a zero-height band resolves to nothing.
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(0, 0, 0, 0, 0));
    try ch.setBlock(w.allocator, 0, 1, 0, block_air);
    try ch.setBlock(w.allocator, 0, 2, 0, block_air);
    try std.testing.expectEqual(@as(?i32, 1), ch.standableY(0, 0, 3, 0, 1000));
    // Ceiling: a candidate needs body_height cells below y_dim.
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(0, 0, y_dim - 1, 0, 0));
    // Band entirely in open sky reports impassable, not a crash.
    try std.testing.expectEqual(@as(?i32, null), ch.standableY(0, 0, y_dim - 1, 0, 4));
}

test "standableWorld crosses chunk borders and refuses a sealed column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const g: i32 = sea_level;
    try std.testing.expectEqual(@as(?i32, g + 1), try w.standableWorld(-1, -1, g + 1));
    var y: i32 = g + 1;
    while (y <= g + 4) : (y += 1) try w.setBlockWorld(-1, y, -1, block_stone);
    try std.testing.expectEqual(@as(?i32, null), try w.standableWorld(-1, -1, g + 1));
}

test "evictOneChunk picks the coldest chunk, min key on ties (DST)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Insert in reverse key order so HashMap walk ≠ sorted order. Chunk 1 is
    // the lowest key but is re-touched, so the untouched chunk 3 loses.
    _ = try w.getOrCreate(.{ .x = 3, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 2, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    const keep = ChunkPos.hash(.{ .x = 2, .z = 0 });
    try w.evictOneChunk(keep);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 3, .z = 0 })) == null);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 1, .z = 0 })) != null);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 2, .z = 0 })) != null);
    // Ties (equal stamps) still resolve by min key, not HashMap walk order.
    var tied = try World.init(std.testing.allocator, dir);
    defer tied.deinit();
    _ = try tied.getOrCreate(.{ .x = 7, .z = 0 });
    _ = try tied.getOrCreate(.{ .x = 6, .z = 0 });
    _ = try tied.getOrCreate(.{ .x = 5, .z = 0 });
    var it = tied.chunks.iterator();
    while (it.next()) |e| e.value_ptr.*.last_touch = 0;
    try tied.evictOneChunk(ChunkPos.hash(.{ .x = 7, .z = 0 }));
    try std.testing.expect(tied.chunks.get(ChunkPos.hash(.{ .x = 5, .z = 0 })) == null);
}

test "paint clear on setBlock and ZCH3 texture density roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    // Paint a cell, then plain dig must drop orphan texture/density.
    try c.setBlockTexDens(w.allocator, 3, 40, 4, block_dirt, 0x61, 12);
    try std.testing.expectEqual(@as(u64, 0x61), c.texAt(3, 40, 4));
    try std.testing.expectEqual(@as(?u8, 12), c.densAt(3, 40, 4));
    try c.setBlock(w.allocator, 3, 40, 4, block_air);
    try std.testing.expectEqual(@as(u64, 0), c.texAt(3, 40, 4));
    try std.testing.expectEqual(@as(?u8, null), c.densAt(3, 40, 4));
    // Repaint and persist; reload must restore channels (hdr flags 13/14).
    try c.setBlockTexDens(w.allocator, 3, 40, 4, block_stone, 0x0b0b0b0b0b0b, 7);
    try c.setBlockTexDens(w.allocator, 1, 10, 2, block_dirt, 0x22, 3);
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(block_stone, c2.blockAt(3, 40, 4));
    try std.testing.expectEqual(@as(u64, 0x0b0b0b0b0b0b), c2.texAt(3, 40, 4));
    try std.testing.expectEqual(@as(?u8, 7), c2.densAt(3, 40, 4));
    try std.testing.expectEqual(block_dirt, c2.blockAt(1, 10, 2));
    try std.testing.expectEqual(@as(u64, 0x22), c2.texAt(1, 10, 2));
    try std.testing.expectEqual(@as(?u8, 3), c2.densAt(1, 10, 2));
}

test "ZCH3 damage plane roundtrips and stays per-cell" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try c.setDmg(w.allocator, 3, 40, 4, 250);
    try c.setDmg(w.allocator, 1, 10, 2, 7);
    try std.testing.expectEqual(@as(u16, 250), c.dmgAt(3, 40, 4));
    try std.testing.expectEqual(@as(u16, 0), c.dmgAt(5, 5, 5));
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 250), c2.dmgAt(3, 40, 4));
    try std.testing.expectEqual(@as(u16, 7), c2.dmgAt(1, 10, 2));
    try std.testing.expectEqual(@as(u16, 0), c2.dmgAt(5, 5, 5));
    // Clear persists too: a repaired block must not re-damage after reload.
    c2.clearDmg(3, 40, 4);
    try w2.saveAll();
    var w3 = try World.init(std.testing.allocator, dir);
    defer w3.deinit();
    const c3 = try w3.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 0), c3.dmgAt(3, 40, 4));
    try std.testing.expectEqual(@as(u16, 7), c3.dmgAt(1, 10, 2));
}

test "topsoil bitfield: fresh clear, dig marks, ZCH3 round-trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    const g: i32 = c.heightAt(0, 0); // flat sea_level surface
    try std.testing.expectEqual(@as(u8, 0), c.topsoil[0]); // fresh = clear

    // Dig AT the surface marks the column (stock SetTopSoilBroken trigger:
    // block change at y >= surface). Column (0,0) is bit 0 of byte 0.
    try w.setBlockWorld(0, g, 0, block_air);
    try std.testing.expectEqual(@as(u8, 0x01), c.topsoil[0]);
    // A tunnel BELOW the surface does not disturb the topsoil.
    try w.setBlockWorld(1, g - 3, 0, block_air);
    try std.testing.expectEqual(@as(u8, 0x01), c.topsoil[0]);
    // Column (1,0) is bit 1: a surface edit there sets it too.
    try w.setBlockWorld(1, g, 0, block_air);
    try std.testing.expectEqual(@as(u8, 0x03), c.topsoil[0]);

    // A border cell marks the neighbor chunk's adjacent column (only when the
    // neighbor exists; never created on demand).
    try w.setBlockWorld(15, g, 0, block_air); // lx=15, column bit 15 (byte 1 bit 7)
    try std.testing.expectEqual(@as(u8, 0x80), c.topsoil[1]);
    try std.testing.expect(w.chunks.get(ChunkPos.hash(.{ .x = 1, .z = 0 })) == null);

    // ZCH3 round-trip: the disturbed bits survive a reload; old files without
    // the tail load all-clear.
    try w.saveAll();
    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u8, 0x03), c2.topsoil[0]);
    try std.testing.expectEqual(@as(u8, 0x80), c2.topsoil[1]);

    // Pre-topsoil save (16-byte hdr + heights only): loads all-clear.
    var path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path2 = try std.fmt.bufPrint(&path_buf2, "{s}/c_0_0.zch", .{dir});
    var old: [16 + 256]u8 = .{0} ** (16 + 256);
    old[0] = 'Z';
    old[1] = 'C';
    old[2] = 'H';
    old[3] = '3';
    std.mem.writeInt(i32, old[4..8], 0, .little);
    std.mem.writeInt(i32, old[8..12], 0, .little);
    try io_fs.writeFile(path2, &old);
    var w3 = try World.init(std.testing.allocator, dir);
    defer w3.deinit();
    const c3 = try w3.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u8, 0), c3.topsoil[0]);
}

test "torn or misplaced chunk save cannot partially replace generated state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/c_0_0.zch", .{dir});

    var torn: [16 + 256]u8 = .{0} ** (16 + 256);
    @memcpy(torn[0..4], "ZCH3");
    torn[12] = 1; // Claims a block plane that is not present.
    @memset(torn[16..], 200);
    try io_fs.writeFile(path, &torn);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, sea_level), c.heightAt(0, 0));
    try std.testing.expect(c.blocks != null);

    // The filename is not identity: embedded coordinates must agree too.
    std.mem.writeInt(i32, torn[4..8], 7, .little);
    torn[12] = 0;
    try io_fs.writeFile(path, &torn);
    var direct = Chunk.generateFlat(.{ .x = 0, .z = 0 });
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&direct));
    try std.testing.expectEqual(@as(u16, sea_level), direct.heightAt(0, 0));

    // A record whose header is coherent but whose declared block plane is
    // absent must fail inside loadChunk, before anything is copied into the
    // resident chunk. The cases above reach loadChunk with no plane declared,
    // so the length check there was never the one that rejected them; the
    // standalone validateChunkBytes is not on this path at all.
    @memcpy(torn[0..4], "ZCH3");
    std.mem.writeInt(i32, torn[4..8], 0, .little);
    torn[12] = 1; // block plane declared, 262144 bytes short
    try io_fs.writeFile(path, &torn);
    var short = Chunk.generateFlat(.{ .x = 0, .z = 0 });
    const before = short.heightAt(0, 0);
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&short));
    try std.testing.expectEqual(before, short.heightAt(0, 0)); // untouched
    try std.testing.expect(short.blocks == null);

    @memcpy(torn[0..4], "NOPE");
    torn[12] = 0;
    try io_fs.writeFile(path, &torn);
    try std.testing.expectError(error.ReadFailed, w.loadChunk(&direct));
}

test "stock map heights via DTM if Navezgane present" {
    const map = stock_paths.navezgane;
    if (!io_fs.dirExists(map)) return error.SkipZigTest;

    io_fs.mkdirPath("worlds");
    io_fs.mkdirPath("worlds/zdtd_navezgane_test");
    var w = try World.init(std.testing.allocator, "worlds/zdtd_navezgane_test");
    defer w.deinit();
    try w.loadStockMap(map);
    const h = try w.heightWorld(-273, 449);
    try std.testing.expect(h >= 55 and h <= 65);
    const sp = w.primarySpawn();
    try std.testing.expectEqual(@as(i32, -273), sp.x);
    const t = World.worldToChunk(-273, 449);
    const c = try w.getOrCreate(t.pos);
    try std.testing.expect(c.heightAt(t.lx, t.lz) == h);
    const n_pref = if (w.prefabs) |*p| p.items.len else 0;
    std.debug.print(
        "PASS stock-map: Navezgane dtm={d}x{d} height(-273,449)={d} spawn=({d},{d},{d}) prefabs={d}\n",
        .{ w.heightmap.?.width, w.heightmap.?.height, h, sp.x, sp.y, sp.z, n_pref },
    );
}

test "async flush round-trips a save into a fresh World" {
    if (!chunk_flush.Flusher.available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.async_flush = true;
    w.flush.arm();
    try std.testing.expect(w.asyncEnabled());
    try w.setBlockWorld(5, 70, 5, block_dirt);
    try w.setBlockWorld(6, 71, 5, block_stone);
    try w.saveAll();
    w.flushWait();
    try std.testing.expect(w.flush.written.load(.monotonic) >= 1);
    try std.testing.expectEqual(@as(u64, 0), w.flush.errors.load(.monotonic));

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    try std.testing.expectEqual(block_stone, try w2.blockWorld(6, 71, 5));
}

test "rotation raw lives in the chunk plane and survives save/reload" {
    // GAP_ANALYSIS 13: a placed block's full BlockValue (type low 16, rotation
    // / meta upper bits) must reach the chunk plane and the ZCH3 save, so a
    // second client or a relog re-renders the rotation instead of a bare id.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);

    const raw_door: u32 = block_dirt | (@as(u32, 0x0005) << 16); // arbitrary upper meta bits
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    try w.setBlockRawWorld(5, 70, 5, raw_door);
    // The plane carries the full raw; the u16 read still answers the type id.
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(raw_door, c.rawAt(5, 70, 5));
    try std.testing.expectEqual(block_dirt, c.blockAt(5, 70, 5));
    try w.saveAll();

    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try std.testing.expectEqual(block_dirt, try w2.blockWorld(5, 70, 5));
    const c2 = try w2.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(raw_door, c2.rawAt(5, 70, 5));
    // Clearing to air writes a zero raw and drops the meta with the block.
    try w2.setBlockRawWorld(5, 70, 5, 0);
    try std.testing.expectEqual(@as(u32, 0), c2.rawAt(5, 70, 5));
}

test "asyncEnabled is false under force-serial (DST keeps the sync path)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.async_flush = true;
    w.flush.arm();
    parallel.setForceSerial(true);
    defer parallel.setForceSerial(false);
    try std.testing.expect(!w.asyncEnabled());
    // Injected write failures still surface as an error return on this path.
    try w.setBlockWorld(1, 70, 1, block_stone);
    io_fs.injectWriteFailures(1);
    defer io_fs.injectWriteFailures(0);
    try std.testing.expectError(error.DiskQuota, w.saveChunk(w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?));
}

test "evict then reload of a queued key reads the newest bytes" {
    if (!chunk_flush.Flusher.available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.async_flush = true;
    w.flush.arm();

    _ = try w.getOrCreate(.{ .x = 1, .z = 0 });
    _ = try w.getOrCreate(.{ .x = 2, .z = 0 });
    try w.setBlockWorld(16 + 4, 90, 4, block_stone); // chunk (1,0)
    const key1 = ChunkPos.hash(.{ .x = 1, .z = 0 });
    // Evict (1,0): its payload goes on the queue, then the chunk is freed.
    try w.evictOneChunk(ChunkPos.hash(.{ .x = 2, .z = 0 }));
    try std.testing.expect(w.chunks.get(key1) == null);
    // Reload must wait on the queued write, never read a stale/absent file.
    try std.testing.expectEqual(block_stone, try w.blockWorld(16 + 4, 90, 4));
}

test "navezgane spawn chunk carries its POI blocks" {
    // The stock client saw only terrain where abandoned_house_07 stands, so the
    // POI must survive the whole store path, not just the prefab index.
    const map_dir = stock_paths.navezgane;
    if (!io_fs.fileExists(map_dir ++ "/prefabs.xml")) return error.SkipZigTest;

    var w = try World.init(std.testing.allocator, "worlds/zdtd_poi_test");
    defer w.deinit();
    try w.loadStockMapEx(map_dir, null);

    // prefabs.xml lists the prefab's origin CORNER, so probe inside the
    // footprint: abandoned_house_07 is 42x42 at (-262,61,450).
    const t2 = World.worldToChunk(-241, 471);
    const ch = try w.getOrCreate(t2.pos);

    var non_air: usize = 0;
    var y: i32 = 62;
    while (y < 80) : (y += 1) {
        if (ch.blockAt(t2.lx, y, t2.lz) != 0) non_air += 1;
    }
    try std.testing.expect(non_air > 0);
}

test "isSolidWorld: a closed door is solid, an open door is passable" {
    // RE TEFeatureDoor.SetOpen: the open state is a meta bit (bit 1 of the
    // 22..25 nibble). With the door-id hook wired, an open door no longer
    // blocks the AI probes; without the hook it stays solid.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const Door = struct {
        fn isDoor(_: ?*anyopaque, id: u16) bool {
            return id == 999;
        }
    };
    w.door_id_ctx = null;
    w.door_id_fn = &Door.isDoor;
    try w.setBlockWorld(5, 70, 5, 999);
    try std.testing.expect(try w.isSolidWorld(5, 70, 5)); // closed
    const open_raw: u32 = 999 | (2 << 22); // meta open bit
    try w.setBlockRawWorld(5, 70, 5, open_raw);
    try std.testing.expect(!try w.isSolidWorld(5, 70, 5)); // open
    // Without the hook the table is unknown: the open door stays solid.
    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try w2.setBlockRawWorld(5, 70, 5, open_raw);
    try std.testing.expect(try w2.isSolidWorld(5, 70, 5));
}

test "navezgane heights agree with the blocks in the same column" {
    // The client stood in mid air with no collider under it while the server
    // held it several blocks above the terrain top, which is what a heights
    // plane that disagrees with the painted blocks looks like.
    const map_dir = stock_paths.navezgane;
    if (!io_fs.fileExists(map_dir ++ "/prefabs.xml")) return error.SkipZigTest;

    var w = try World.init(std.testing.allocator, "worlds/zdtd_height_test");
    defer w.deinit();
    try w.loadStockMapEx(map_dir, null);

    // Sampled around the first authored spawn point, where the mismatch showed.
    const spots = [_][2]i32{
        .{ -270, 461 }, .{ -269, 459 }, .{ -273, 449 }, .{ -265, 455 }, .{ -280, 452 },
    };
    for (spots) |p2| {
        const h = try w.heightWorld(p2[0], p2[1]);
        const t2 = World.worldToChunk(p2[0], p2[1]);
        const ch = try w.getOrCreate(t2.pos);
        // Topmost non-air cell in the column: what a client collider rests on.
        var top: i32 = -1;
        var y: i32 = 255;
        while (y >= 0) : (y -= 1) {
            if (ch.blockAt(t2.lx, y, t2.lz) != 0) {
                top = y;
                break;
            }
        }
        try std.testing.expect(top >= 0);
        // heights is the surface the server stands entities on, so it must not
        // float above the highest block it actually placed.
        try std.testing.expect(@as(i32, h) <= top);
    }
}

test "water sources fill lake columns with water blocks" {
    // Chunk bed at y=60, water source surface y=70 at column (5,5): water must
    // fill 61..70; air above; far columns outside radius stay dry. A shore cell
    // with bed at 71 (above the surface) keeps terrain, no water.
    var chunk: Chunk = .{ .pos = .{ .x = 0, .z = 0 } };
    chunk.heights = .{60} ** 256;
    chunk.heights[0] = 71; // shore cell at (0,0): bed above the water surface
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try chunk.ensureBlocksWithStack(arena.allocator(), biome_layers.defaultStack());
    var pts = [_]water_mod.WaterPoint{.{ .x = 5, .y = 70, .z = 5 }};
    const sources = water_mod.Sources{ .points = pts[0..], .allocator = undefined };
    chunk.applyWaterSources(0, 0, &sources, block_water);
    try std.testing.expectEqual(@as(u32, block_water), chunk.blocks.?[blockIndex(5, 61, 5)]);
    try std.testing.expectEqual(@as(u32, block_water), chunk.blocks.?[blockIndex(5, 70, 5)]);
    try std.testing.expectEqual(@as(u32, block_air), chunk.blocks.?[blockIndex(5, 71, 5)]);
    // Shore cell (0,0): bed 71 >= surface 70, keeps its terrain block (dirt 5).
    try std.testing.expectEqual(@as(u32, block_dirt), chunk.blocks.?[blockIndex(0, 70, 0)]);
    // Column (15,15) is outside the radius-12 source ring (dx=10,dz=10 → 200 > 144).
    try std.testing.expectEqual(@as(u32, block_air), chunk.blocks.?[blockIndex(15, 65, 15)]);
}

test "procBiomeAt follows the surface fill field deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(77);
    // Two resolved biomes at sparse stock ids (biomes.xml: 3 pine_forest,
    // 5 desert) turn the field on and translate index -> real id.
    w.biome_layers_table.names[3] = "pine_forest";
    w.biome_layers_table.names[5] = "desert";
    w.syncWorldgenBiomes();
    try std.testing.expectEqual(@as(u8, 2), w.worldgen.?.biome_n);
    try std.testing.expectEqual(@as(u8, 3), w.biome_layers_table.biomeIdAt(0));
    try std.testing.expectEqual(@as(u8, 5), w.biome_layers_table.biomeIdAt(1));
    // Deterministic and translated into the real id set at any chunk.
    for ([_]i32{ -3, 0, 1, 12 }) |cx| {
        for ([_]i32{ -2, 0, 5 }) |cz| {
            const b = w.procBiomeAt(cx, cz);
            try std.testing.expect(b == 3 or b == 5);
            try std.testing.expectEqual(b, w.procBiomeAt(cx, cz));
        }
    }
    // The biome at a chunk's center is the same field the surface fill used
    // (chunk (0,0) center is world (8,8) for a 16-wide chunk), translated to
    // the real sparse id.
    try std.testing.expectEqual(
        w.biome_layers_table.biomeIdAt(w.worldgen.?.biomeAt(8, 8)),
        w.procBiomeAt(0, 0),
    );
}

test "resolveTerrainIds seeds default stack from live dump ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    const Ctx = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "air")) return 50;
            if (std.mem.eql(u8, name, "terrStone")) return 51;
            if (std.mem.eql(u8, name, "terrBedrock")) return 52;
            if (std.mem.eql(u8, name, "terrDirt")) return 53;
            if (std.mem.eql(u8, name, "water")) return 54;
            if (std.mem.eql(u8, name, "terrForestGround")) return 55;
            if (std.mem.eql(u8, name, "terrainFiller")) return 56;
            if (std.mem.eql(u8, name, "terrainFillerAdaptive")) return 57;
            return null;
        }
    };
    w.resolveTerrainIds(Ctx.lookup, null);
    try std.testing.expectEqual(@as(u16, 55), w.biome_layers_table.default_stack.layers[0].block_id);
    try std.testing.expectEqual(@as(u16, 53), w.biome_layers_table.default_stack.layers[1].block_id);
    try std.testing.expectEqual(@as(u16, 51), w.biome_layers_table.default_stack.layers[2].block_id);
    try std.testing.expectEqual(@as(u16, 52), w.biome_layers_table.default_stack.layers[3].block_id);
    const c = try w.getOrCreate(.{ .x = 0, .z = 0 });
    try std.testing.expectEqual(@as(u16, 50), c.blockAt(0, 200, 0));
    try std.testing.expectEqual(@as(u16, 52), c.blockAt(0, 0, 0));
    w.enableProc(1);
    try std.testing.expectEqual(@as(u16, 50), w.worldgen.?.air_id);
    try std.testing.expectEqual(@as(u16, 51), w.worldgen.?.stone_id);
    try std.testing.expectEqual(@as(u16, 53), w.worldgen.?.dirt_id);
    try std.testing.expectEqual(@as(u16, 52), w.worldgen.?.bedrock_id);
    try std.testing.expectEqual(@as(u16, 55), w.worldgen.?.forest_id);
}

test "syncWorldgenBiomes keeps XML stacks for a single biome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    w.biome_layers_table.names[3] = "pine_forest";
    w.syncWorldgenBiomes();
    try std.testing.expectEqual(@as(u8, 1), w.worldgen.?.biome_n);
    try std.testing.expect(w.worldgen.?.biome_table != null);
}

/// Carve one column (world x, z=0) to air from `lo`..`hi` and return the chunk
/// plane write for the water tests (the flat default world pre-fills terrain
/// up to its surface, so basins must be carved before pouring).
fn carveAirColumn(w: *World, x: i32, lo: i32, hi: i32) !void {
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = lo;
    while (y <= hi) : (y += 1) {
        try ch.setBlockRaw(w.allocator, x, y, 0, block_air);
    }
}

test "water leveling: digging beside a lake pours the connected basin to its surface" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Flat default world (terrain to its surface ~63). Carve a lake column at
    // x=0 (water 51..62, surface 62) and a basin x=1..7 (air 51..62); x=8
    // stays terrain as the wall. The carve bypasses the edit wrapper, so only
    // the dig below enqueues.
    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    for (1..8) |x| try carveAirColumn(&w, @intCast(x), 51, 62);
    // Dig the cell right beside the lake (x=1, y=51): its neighbor (0,51) is
    // water with surface 62, so the basin x=1..7, y=51..62 pours (7 x 12).
    try w.setBlockWorld(1, 51, 0, block_air);
    try std.testing.expectEqual(@as(u32, 84), w.levelWaterTick(4, 128, 8));
    try std.testing.expectEqual(block_water, try w.blockWorld(1, 51, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(3, 55, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(7, 62, 0));
    // Above the surface cell (63) the flat terrain holds; never water.
    try std.testing.expect((try w.blockWorld(7, 63, 0)) != block_water);
    try std.testing.expect((try w.blockWorld(4, 63, 0)) != block_water);
}

test "water leveling notifies every filled cell so the Game can broadcast" {
    // The chunk dirty flag only drives persistence, so without this notify a
    // pour was saved but never sent and a joined client kept seeing the dry
    // basin until the chunk was re-streamed.
    const Sink = struct {
        var n: u32 = 0;
        var last_id: u16 = 0;
        fn onFill(_: ?*anyopaque, _: i32, _: i32, _: i32, id: u16) void {
            n += 1;
            last_id = id;
        }
    };
    Sink.n = 0;
    Sink.last_id = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.water_fill_fn = &Sink.onFill;

    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    for (1..8) |x| try carveAirColumn(&w, @intCast(x), 51, 62);
    try w.setBlockWorld(1, 51, 0, block_air);
    const filled = w.levelWaterTick(4, 128, 8);
    // One notify per filled cell, carrying the water id the client renders.
    try std.testing.expectEqual(filled, Sink.n);
    try std.testing.expect(filled > 0);
    try std.testing.expectEqual(block_water, Sink.last_id);
}

test "water leveling: a deep dig not connected to water stays dry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    // One cell dug at y=45, sealed above by the flat terrain: no water
    // adjacent at the edit, so nothing pours.
    try w.setBlockWorld(1, 45, 0, block_air);
    try std.testing.expectEqual(@as(u32, 0), w.levelWaterTick(4, 128, 8));
    try std.testing.expectEqual(block_air, try w.blockWorld(1, 45, 0));
}

test "water leveling: placed water cascades down its column and puddles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // A 1-wide shaft at x=5 carved 51..62; x=4 and x=6 stay terrain walls.
    try carveAirColumn(&w, 5, 51, 62);
    // Placing water (bucket) cascades down the air column to the shaft
    // bottom (stock gravity flow, bounded: 11 cells 51..61; the puddle has
    // no air neighbors - the walls are terrain - so it adds 0).
    try w.setBlockWorld(5, 62, 0, block_water);
    try std.testing.expectEqual(@as(u32, 11), w.levelWaterTick(4, 128, 8));
    try std.testing.expectEqual(block_water, try w.blockWorld(5, 62, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(5, 61, 0));
    try std.testing.expectEqual(block_water, try w.blockWorld(5, 51, 0));
    try std.testing.expect((try w.blockWorld(5, 50, 0)) != block_water);
}

test "water leveling: the puddle cap bounds sideways spread on a flat floor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    // Flat floor at y=51 (terrain below), open air 51..60 across x=1..8.
    for (1..9) |x| try carveAirColumn(&w, @intCast(x), 51, 60);
    try w.setBlockWorld(4, 51, 0, block_water);
    // Column has no air below (floor at 51 rests on terrain 50); the pour is
    // the puddle only: at most puddle_cap 3 cells spread at the floor level,
    // never climbing (52 stays air).
    try std.testing.expectEqual(@as(u32, 3), w.levelWaterTick(4, 128, 3));
    // 3 puddle cells + the placed cell at the floor level; nothing above.
    var wet: u32 = 0;
    for (1..9) |x| {
        if ((try w.blockWorld(@intCast(x), 51, 0)) == block_water) wet += 1;
    }
    try std.testing.expectEqual(@as(u32, 4), wet);
    try std.testing.expect((try w.blockWorld(4, 52, 0)) != block_water);
}

test "water leveling: the spread cap bounds one pour" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    carveAirColumn(&w, 0, 51, 62) catch return;
    const ch = try w.getOrCreate(.{ .x = 0, .z = 0 });
    var y: i32 = 51;
    while (y <= 62) : (y += 1) {
        try ch.setBlockRaw(w.allocator, 0, y, 0, block_water);
    }
    for (1..8) |x| try carveAirColumn(&w, @intCast(x), 51, 62);
    try w.setBlockWorld(1, 51, 0, block_air);
    // Cap 2: only two cells pour this tick; the rest stay air (a further edit
    // would re-seed, but the queue is drained here).
    try std.testing.expectEqual(@as(u32, 2), w.levelWaterTick(4, 2, 8));
    try std.testing.expectEqual(block_water, try w.blockWorld(1, 51, 0));
    try std.testing.expectEqual(block_air, try w.blockWorld(1, 53, 0));
}

test "chunk pointers stay valid across map resizes (pointer-stable store)" {
    // GAP "Chunk pointer stability" (PARTIAL 2026-08-29): the store maps keys
    // to per-chunk allocations instead of inline Chunk values, so a *Chunk
    // held across a re-entrant getOrCreate survives the map resize that a
    // value-map would dangle (bait-soak segfault 5/5, Debug abort at
    // chunk_fill.zig:327). Regression: same identity + same data after many
    // resizes, and the mid-scan create pattern stays readable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();

    const held = try w.getOrCreate(.{ .x = 0, .z = 0 });
    const h0 = held.heightAt(0, 0);
    // Force several map resizes while the pointer is held.
    var x: i32 = 1;
    while (x < 40) : (x += 1) {
        _ = try w.getOrCreate(.{ .x = x, .z = 0 });
    }
    // Same identity, same data: the held pointer is still the resident chunk.
    try std.testing.expectEqual(held, w.chunks.get(ChunkPos.hash(.{ .x = 0, .z = 0 })).?);
    try std.testing.expectEqual(h0, held.heightAt(0, 0));
    // Re-entrant mid-scan pattern (chunk_fill.zig te_scan): a pointer held
    // while another chunk is created must stay readable.
    const mid = try w.getOrCreate(.{ .x = 41, .z = 0 });
    const mid_h = mid.heightAt(0, 0);
    _ = try w.getOrCreate(.{ .x = 42, .z = 0 });
    try std.testing.expectEqual(mid_h, mid.heightAt(0, 0));
}

test "Collide verbs decide movement and sight" {
    // Stock `Block.IsCollideMovement` (movement bit) gates movement and
    // `Block.IsSeeThrough` (sight bit) gates sight; water always blocks sight.
    // 66 of the 418 stock Collide rows clear the movement bit (grass, plants,
    // cobwebs, campfires, spikes, barbed wire) and 365 clear the sight bit
    // (containers, most glass), so both predicates matter.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();

    const Ids = struct {
        const plant: u16 = 501; // Collide "melee,bullet,arrow,rocket": no movement, no sight
        const glass: u16 = 502; // "movement,melee,bullet,arrow,rocket": movement, no sight
        const wall: u16 = 503; // all six bits
        const unknown: u16 = 504; // not in the table
    };
    const Table = struct {
        fn movement(_: ?*anyopaque, id: u16) bool {
            return switch (id) {
                Ids.plant => false,
                Ids.glass, Ids.wall => true,
                else => true, // unknown id keeps the pre-parse behaviour
            };
        }
        fn sight(_: ?*anyopaque, id: u16) bool {
            return switch (id) {
                Ids.plant, Ids.glass => false,
                Ids.wall => true,
                else => true,
            };
        }
    };
    w.movement_solid_ctx = null;
    w.movement_solid_fn = &Table.movement;
    w.sight_block_ctx = null;
    w.sight_block_fn = &Table.sight;

    try w.setBlockWorld(3, 70, 3, Ids.plant);
    try w.setBlockWorld(4, 70, 3, Ids.glass);
    try w.setBlockWorld(5, 70, 3, Ids.wall);
    try w.setBlockWorld(6, 70, 3, Ids.unknown);

    // Movement: the plant stops blocking, glass and the wall do.
    try std.testing.expect(!try w.isSolidWorld(3, 70, 3));
    try std.testing.expect(try w.isSolidWorld(4, 70, 3));
    try std.testing.expect(try w.isSolidWorld(5, 70, 3));
    try std.testing.expect(try w.isSolidWorld(6, 70, 3));

    // Sight: only the wall blocks (glass and the plant are see-through).
    try std.testing.expect(!w.sightBlockedWorld(3, 70, 3));
    try std.testing.expect(!w.sightBlockedWorld(4, 70, 3));
    try std.testing.expect(w.sightBlockedWorld(5, 70, 3));
    try std.testing.expect(w.sightBlockedWorld(6, 70, 3));
    // Air never blocks sight, and water always does (IsSeeThrough returns true
    // only when the sight bit is clear AND the cell is not water).
    try std.testing.expect(!w.sightBlockedWorld(3, 71, 3));
    try w.setBlockWorld(3, 71, 3, w.terrain_ids.water);
    try std.testing.expect(w.sightBlockedWorld(3, 71, 3));

    // With no oracle the pre-parse behaviour stands: every non-air, non-water
    // block blocks both verbs.
    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    try w2.setBlockWorld(3, 70, 3, Ids.plant);
    try std.testing.expect(try w2.isSolidWorld(3, 70, 3));
    try std.testing.expect(w2.sightBlockedWorld(3, 70, 3));
}

test "projectPlane SIMD matches scalar Geometry.project" {
    var prng = std.Random.DefaultPrng.init(0x51_11);
    const rnd = prng.random();
    const geos = [_]rules_mod.Geometry{
        .{ .height_scale = 0.5 },
        .{ .height_offset = 20 },
        .{ .height_scale = 0.75, .height_offset = -10, .height_ceiling = 200 },
        .{ .height_scale = 1.5, .height_ceiling = 180 },
    };
    for (geos) |geo| {
        var simd_h: [256]u8 = undefined;
        var scalar_h: [256]u8 = undefined;
        for (&simd_h, &scalar_h) |*a, *b| {
            const v = rnd.int(u8);
            a.* = v;
            b.* = v;
        }
        projectPlane(&simd_h, geo, 255);
        projectPlaneScalar(&scalar_h, geo, 255);
        try std.testing.expectEqualSlices(u8, &scalar_h, &simd_h);
    }
}

test "fillBlocksFromStack SIMD matches per-column fillColumn write" {
    var heights: [256]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xb10c);
    const rnd = prng.random();
    for (&heights) |*h| h.* = rnd.intRangeAtMost(u8, 8, 120);

    const stack = biome_layers.defaultStack();
    const air: u32 = assignids.air;
    var simd_plane: [65536]u32 = undefined;
    @memset(&simd_plane, air);
    fillBlocksFromStack(&heights, 256, stack, air, &simd_plane);

    // Scalar reference: same fillColumn + per-cell write as the old path.
    var scalar_plane: [65536]u32 = undefined;
    @memset(&scalar_plane, air);
    var col: [256]u16 = undefined;
    var lz: i32 = 0;
    while (lz < 16) : (lz += 1) {
        var lx: i32 = 0;
        while (lx < 16) : (lx += 1) {
            const h = heights[@intCast(lx + lz * 16)];
            biome_layers.Table.fillColumn(stack, h, &col);
            var y: i32 = 0;
            while (y <= h) : (y += 1) {
                scalar_plane[blockIndex(lx, y, lz)] = col[@intCast(y)];
            }
        }
    }
    try std.testing.expectEqualSlices(u32, &scalar_plane, &simd_plane);
}

test "nextNonAir matches a scalar walk" {
    // Random planes with heavy air bias: the vector scan must yield exactly the
    // non-air indices, in order, for aligned and unaligned starts alike.
    var rng = std.Random.DefaultPrng.init(0xA17);
    const r = rng.random();
    var plane: [259]u32 = undefined;
    for (0..32) |_| {
        for (&plane) |*cell| {
            // Type in the low 16 bits; upper bits carry flags that must not
            // make an air cell look occupied.
            const ty: u32 = if (r.uintLessThan(u8, 8) == 0) r.intRangeAtMost(u32, 1, 0xFFFF) else 0;
            cell.* = ty | (@as(u32, r.int(u16)) << 16);
        }
        for ([_]usize{ 0, 1, 7, 16, 17, 250, 259 }) |from| {
            var i = from;
            var want = from;
            while (true) {
                while (want < plane.len and store.typeId(plane[want]) == 0) want += 1;
                const got = store.nextNonAir(&plane, i);
                if (want >= plane.len) {
                    try std.testing.expectEqual(@as(?usize, null), got);
                    break;
                }
                try std.testing.expectEqual(@as(?usize, want), got);
                i = want + 1;
                want = i;
            }
        }
    }
    // All-air and empty inputs terminate without a hit.
    var air: [256]u32 = .{0} ** 256;
    try std.testing.expectEqual(@as(?usize, null), store.nextNonAir(&air, 0));
    air[255] = 9;
    try std.testing.expectEqual(@as(?usize, 255), store.nextNonAir(&air, 0));
    try std.testing.expectEqual(@as(?usize, null), store.nextNonAir(&.{}, 0));
}

test "a budgeted save drains across calls and loses nothing" {
    // The periodic tick save is budgeted so a join burst (hundreds of dirty
    // chunks) cannot stall one tick: `saveAllBudget` returns true while work
    // remains and the caller comes back next tick. The unbounded `saveAll`
    // stays the shutdown/admin form, and every edit must still reach disk.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);
    // Four edited chunks, all dirty.
    for ([_]ChunkPos{ .{ .x = 0, .z = 0 }, .{ .x = 1, .z = 0 }, .{ .x = 0, .z = 1 }, .{ .x = 2, .z = 2 } }) |p| {
        _ = try w.getOrCreate(p);
        try w.setBlockWorld(p.x * 16 + 5, 10, p.z * 16 + 5, block_stone);
    }
    var calls: usize = 0;
    while (try w.saveAllBudget(1)) : (calls += 1) {
        try std.testing.expect(calls < 64);
    }
    calls += 1; // the final call that reported no work left
    try std.testing.expect(calls >= 4);
    // Every edited chunk is on disk and loads back with the edit intact.
    var path_buf: [512]u8 = undefined;
    for ([_]ChunkPos{ .{ .x = 0, .z = 0 }, .{ .x = 1, .z = 0 }, .{ .x = 0, .z = 1 }, .{ .x = 2, .z = 2 } }) |p| {
        try std.testing.expect(io_fs.fileExists(try w.chunkPath(p, &path_buf)));
    }
    var w2 = try World.init(std.testing.allocator, dir);
    defer w2.deinit();
    w2.enableProc(1);
    const c = try w2.getOrCreate(.{ .x = 2, .z = 2 });
    try std.testing.expectEqual(block_stone, c.blockAt(5, 10, 5));
    // A budgeted call on a clean world reports no work.
    try std.testing.expect(!try w2.saveAllBudget(1));
}

test "a deco chunk mirrors once per world and a loaded chunk suppresses it" {
    // The deco mirror derives decorations into the block plane. Re-deriving on
    // a later stream resurrects a decoration the player removed (the chopped
    // tree that came back), so each deco chunk is marked once, and a chunk that
    // came from disk is marked too: its plane already carries what the mirror
    // wrote plus every player edit since.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var w = try World.init(std.testing.allocator, dir);
    defer w.deinit();
    w.enableProc(1);

    try std.testing.expect(!w.decoChunkMirrored(0, 0));
    w.markDecoChunkMirrored(0, 0);
    try std.testing.expect(w.decoChunkMirrored(0, 0));
    // Neighbours and out-of-grid coordinates stay clear (the mirror then runs,
    // which is the pre-existing behaviour rather than a silent skip).
    try std.testing.expect(!w.decoChunkMirrored(1, 0));
    try std.testing.expect(!w.decoChunkMirrored(-1, 0));
    try std.testing.expect(!w.decoChunkMirrored(0, store.max_deco_grid));

    // A saved-then-reloaded chunk marks its own deco chunk (regular chunk
    // 24,40 lives in deco chunk 3,5), which starts clear.
    try std.testing.expect(!w.decoChunkMirrored(3, 5));
    const c = try w.getOrCreate(.{ .x = 24, .z = 40 });
    try w.setBlockWorld(24 * 16 + 1, 10, 40 * 16 + 1, block_stone);
    try w.saveChunk(c);
    const after = try w.getOrCreate(.{ .x = 24, .z = 40 });
    try w.loadChunk(after);
    try std.testing.expect(w.decoChunkMirrored(3, 5));
}
