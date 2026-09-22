//! World bodies: time, sign-data terminator, init info, world info,
//! folder transfer, and chunk-cluster info, with their layout tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_world` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageWorldTime (RE inventories/netpackage-bodies.md, write IL=8): a
/// single `worldTime` u64, encoded as WorldClock.worldTimeBits (24000 per day,
/// 1000 per hour).
pub fn buildWorldTimeBody(buf: []u8, world_time: u64) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeU64(world_time);
    return w.written();
}

/// Empty last-batch NetPackageSignDataResponse: isLastBatch:bool + dataLen:i32(+bytes).
/// Client RequestWorldSignDataFromServer waits until isLastBatch clears downloadInProgress.
pub fn buildSignDataResponseEmptyLast(buf: []u8) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeBool(true); // isLastBatch
    try wr.writeI32(0); // data length
    return wr.written();
}

/// Empty NetPackageWorldInitInfo: eventPrefabCount:i32 + wallVolumeCount:i32.
/// Sets GameManager.worldInitInfoReceived so worldInfoCo can proceed to DoSpawn.
pub fn buildWorldInitInfoEmpty(buf: []u8) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeI32(0); // eventPrefabs
    try wr.writeI32(0); // wallVolumes
    return wr.written();
}

/// Stock NetPackageWorldInfo body (matches NetPackageWorldInfo.read/write IL):
/// gameMode, levelName, gameName, guid, hasPpList, [ppList], ticks:u64, fixedSizeCC,
/// firstTimeJoin, worldHashes raw (count:i32 + entries), worldDataSize:i64.
/// `name` is used for both levelName and gameName.
pub fn buildWorldInfoBody(buf: []u8, name: []const u8, w: i32, h: i32, sx: i32, sy: i32, sz: i32, seed: i32) ![]u8 {
    _ = w;
    _ = h;
    _ = sx;
    _ = sy;
    _ = sz;
    _ = seed;
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeString("GameModeSurvival"); // gameMode class name
    try wr.writeString(name); // levelName (e.g. Navezgane)
    try wr.writeString(name); // gameName
    try wr.writeString("00000000-0000-0000-0000-000000000001"); // guid
    try wr.writeBool(false); // no PersistentPlayerList blob
    try wr.writeU64(0); // ticks
    // fixedSizeCC MUST be false for stock maps (Navezgane): true installs
    // ChunkProviderDummy on the client (no splat maps). MicroSplat then samples
    // null _CustomControl0/1 and the whole terrain floor is grey clay.
    // false → GenerateWorldFromRaw(bClientMode) loads splat*.png from GameData.
    // Spawn overlay waits for CGO >= viewDist^2-10; keep stream ring large enough.
    // Design: docs/adr/0016-fixedsizecc-false-stream-cgo.md
    try wr.writeBool(false);
    // firstTimeJoin=false. GameManager.DoSpawn feeds this straight into
    // XUiC_SpawnSelectionWindow::Open(ui, bChooseSpawnPosition, bEnteringGame,
    // bFirstTimeSpawn) (V3.1.0 b14 IL: DoSpawn IL_0021, Open IL_0024). With
    // true the client parks on the spawn-selection window: the world renders
    // behind it, but the local player is never added to the world, so
    // EntityAlive.OnAddedToWorld never runs, IsSpawned stays false and the
    // client never sends EntityPosAndRot (server saw pos=(?,?,?) forever).
    try wr.writeBool(false); // firstTimeJoin
    // worldHashesData is raw MemoryStream of: count:i32 + (path:string, crc:u32)*count
    // PrepareWorldHashes writes count=0 when no RWG file CRC table.
    try wr.writeI32(0);
    try wr.writeI64(0); // worldDataSize
    return wr.written();
}

/// One `NetPackageWorldFolder` part (write IL=30): seqNr:i32, totalParts:i32,
/// dataLen:i32 (-1 when null), then data bytes. Channel 1. The client's
/// ProcessPackage appends each part to ReceiveStream and, on the last
/// (seqNr == totalParts - 1), runs uncompressWorld.
pub fn buildWorldFolderPartBody(buf: []u8, seq: i32, total: i32, data: []const u8) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeI32(seq);
    try wr.writeI32(total);
    try wr.writeI32(@intCast(data.len));
    try wr.writeBytes(data);
    return wr.written();
}

/// Empty world-folder transfer: one part carrying a zlib-deflated
/// `fileCount:i32 = 0` blob. RE: `NetPackageWorldFolder.write` IL=30,
/// `ProcessPackage` IL=93, `sendPacketsToClient` IL=84 and
/// `uncompressWorld` coroutine IL=321
/// (`../7dtd-engine-research/docs/network/protocol-packages.md` "World-folder").
/// Stock's prepareWorldFolderData streams real world files; zdtd's
/// flat/default worlds have nothing to ship (WorldInfo already advertised
/// hashCount=0), but worldInfoCo still calls RequestWorld when no local world
/// matches, and that coroutine waits on WorldReceivedAndUncompressed. An
/// empty last-part clears the wait the same way a zero-file zip would
/// (uncompressWorld: count=0 loop, write completed marker, set the flag).
pub fn buildEmptyWorldFolderTransfer(buf: []u8) ![]u8 {
    const flate = std.compress.flate;
    var plain: [4]u8 = undefined;
    std.mem.writeInt(i32, &plain, 0, .little);
    var window: [flate.max_window_len]u8 = undefined;
    var out_scratch: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&out_scratch);
    // Stock DeflateOutputStream (prepareWorldFolderData) is zlib-wrapped;
    // the client DeflateInputStream expects the same container.
    var comp = flate.Compress.init(&sink, &window, .zlib, .default) catch return error.Overflow;
    comp.writer.writeAll(&plain) catch return error.Overflow;
    comp.finish() catch return error.Overflow;
    return buildWorldFolderPartBody(buf, 0, 1, out_scratch[0..sink.end]);
}

/// Stock NetPackageChunkClusterInfo body (NetPackageChunkClusterInfo.write
/// IL=36): name:string, cMinPos:2xi32, cMaxPos:2xi32, bInfinite:bool,
/// pos:Vector3 (3xf32). Server fills from `Setup(ChunkCluster)`: name =
/// GamePrefs.GameWorld, cMin/cMax = WorldChunkCache.ChunkMinPos/MaxPos,
/// bInfinite = !IsFixedSize, pos = ChunkCluster.Position. The client
/// (GameManager.ChunkClusterInfo -> chunkClusterInfoCo, V3.1.0 b14) stores
/// pos/min/max on its ChunkCache, and only when bInfinite=false sets
/// IsFixedSize and calls the (no-op in b14) border-box methods; `name` is
/// never read client-side. Fixed maps send the ChunkProviderDisc bounds
/// formula; infinite worlds keep the WorldChunkCache ctor defaults (0,0).
pub fn buildChunkClusterInfoBody(buf: []u8, name: []const u8, cmin: [2]i32, cmax: [2]i32, b_infinite: bool, pos: [3]f32) ![]u8 {
    var wr: binary.Writer = .{ .buf = buf };
    try wr.writeString(name);
    try wr.writeI32(cmin[0]);
    try wr.writeI32(cmin[1]);
    try wr.writeI32(cmax[0]);
    try wr.writeI32(cmax[1]);
    try wr.writeBool(b_infinite);
    try wr.writeF32(pos[0]);
    try wr.writeF32(pos[1]);
    try wr.writeF32(pos[2]);
    return wr.written();
}

test "chunk cluster info body layout" {
    var buf: [64]u8 = undefined;
    const body = try buildChunkClusterInfoBody(&buf, "Navezgane", .{ -195, -198 }, .{ 195, 195 }, false, .{ 0, 0, 0 });
    var rd: binary.Reader = .{ .data = body };
    var name_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Navezgane", try rd.readString(&name_buf));
    try std.testing.expectEqual(@as(i32, -195), try rd.readI32());
    try std.testing.expectEqual(@as(i32, -198), try rd.readI32());
    try std.testing.expectEqual(@as(i32, 195), try rd.readI32());
    try std.testing.expectEqual(@as(i32, 195), try rd.readI32());
    try std.testing.expectEqual(false, try rd.readBool());
    try std.testing.expectEqual(@as(f32, 0), try rd.readF32());
    try std.testing.expectEqual(@as(f32, 0), try rd.readF32());
    try std.testing.expectEqual(@as(f32, 0), try rd.readF32());
    try std.testing.expectEqual(@as(usize, body.len), rd.pos);
}

test "world info body layout ends with hashCount0 and worldDataSize" {
    var buf: [256]u8 = undefined;
    const body = try buildWorldInfoBody(&buf, "Navezgane", 6144, 6144, 0, 0, 0, 0);
    // last 12 bytes: i32 0 + i64 0
    try std.testing.expect(body.len >= 12);
    const tail = body[body.len - 12 ..];
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, tail[0..4], .little));
    try std.testing.expectEqual(@as(i64, 0), std.mem.readInt(i64, tail[4..12], .little));
}

test "empty world folder transfer is one last part with zlib payload" {
    var buf: [128]u8 = undefined;
    const body = try buildEmptyWorldFolderTransfer(&buf);
    var rd: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 0), try rd.readI32()); // seqNr
    try std.testing.expectEqual(@as(i32, 1), try rd.readI32()); // totalParts (last = seq 0)
    const len = try rd.readI32();
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(usize, @intCast(len)), body.len - rd.pos);
    // zlib header: CMF=0x78
    try std.testing.expectEqual(@as(u8, 0x78), body[rd.pos]);
}

test "sign data empty last batch is bool true + len0" {
    var buf: [16]u8 = undefined;
    const body = try buildSignDataResponseEmptyLast(&buf);
    try std.testing.expectEqual(@as(usize, 5), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[1..5], .little));
}

test "world init info empty is two zero counts" {
    var buf: [16]u8 = undefined;
    const body = try buildWorldInitInfoEmpty(&buf);
    try std.testing.expectEqual(@as(usize, 8), body.len);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[0..4], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[4..8], .little));
}
