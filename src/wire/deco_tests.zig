//! Deco wire tests: sampling, windows, keys.
//!
//! Split out of wire/stock_deco.zig (same tests, moved verbatim).

const std = @import("std");
const stock_deco = @import("stock_deco.zig");
const SpeciesList = stock_deco.SpeciesList;
const Sampler = stock_deco.Sampler;
const Window = stock_deco.Window;
const makeChunkKey = stock_deco.makeChunkKey;
const buildDecoResetWorldChunk = stock_deco.buildDecoResetWorldChunk;
const DecoObj = stock_deco.DecoObj;
const PackageWriter = stock_deco.PackageWriter;
const attempts_per_deco_chunk = stock_deco.attempts_per_deco_chunk;
const buildDecoUpdate = stock_deco.buildDecoUpdate;
const decoUpdateLen = stock_deco.decoUpdateLen;
const deco_rot_shift = stock_deco.deco_rot_shift;
const deco_size = stock_deco.deco_size;
const deco_state_active = stock_deco.deco_state_active;
const decos_per_package = stock_deco.decos_per_package;
const finishDecoUpdate = stock_deco.finishDecoUpdate;
const generateForDecoChunk = stock_deco.generateForDecoChunk;
const objects_off = stock_deco.objects_off;
const tree_dead_02 = stock_deco.tree_dead_02;
const tree_oak_sml = stock_deco.tree_oak_sml;
const tree_winter_evergreen = stock_deco.tree_winter_evergreen;
const vector3iToU64 = stock_deco.vector3iToU64;
const worldToDecoChunk = stock_deco.worldToDecoChunk;
const zdtd_decos_per_package = stock_deco.zdtd_decos_per_package;

test "vector3i pack roundtrip bits" {
    const p = vector3iToU64(-273, 61, 449);
    const x: i32 = @as(i32, @intCast(@as(u16, @truncate(p >> 32)))) -% 32768;
    const y: i32 = @as(i32, @intCast(@as(u16, @truncate(p >> 16)))) -% 32768;
    const z: i32 = @as(i32, @intCast(@as(u16, @truncate(p)))) -% 32768;
    try std.testing.expectEqual(@as(i32, -273), x);
    try std.testing.expectEqual(@as(i32, 61), y);
    try std.testing.expectEqual(@as(i32, 449), z);
}

test "deco update empty first" {
    var buf: [64]u8 = undefined;
    const body = try buildDecoUpdate(&buf, true, &.{});
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[5..9], .little));
}

test "deco update one object golden layout" {
    var buf: [64]u8 = undefined;
    const o: DecoObj = .{ .x = -273, .y = 62, .z = 449, .real_y = 62.0, .block_raw = 24629 };
    const body = try buildDecoUpdate(&buf, true, &.{o});
    // 5 header + 4 count + 17 object (8 pos + 4 realY + 4 rawData + 1 state).
    try std.testing.expectEqual(@as(usize, 26), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    // dataLen counts count:i32 + objects only, not the firstPackage byte or itself.
    try std.testing.expectEqual(@as(i32, 21), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(vector3iToU64(-273, 62, 449), std.mem.readInt(u64, body[9..17], .little));
    try std.testing.expectEqual(@as(f32, 62.0), @as(f32, @bitCast(std.mem.readInt(u32, body[17..21], .little))));
    try std.testing.expectEqual(@as(u32, 24629), std.mem.readInt(u32, body[21..25], .little));
    try std.testing.expectEqual(deco_state_active, body[25]);
}

test "deco update continuation header is 0" {
    var buf: [64]u8 = undefined;
    const o: DecoObj = .{ .x = 1, .y = 2, .z = 3, .real_y = 2.0, .block_raw = 7 };
    const body = try buildDecoUpdate(&buf, false, &.{ o, o });
    try std.testing.expectEqual(@as(u8, 0), body[0]);
    try std.testing.expectEqual(@as(i32, 4 + 2 * deco_size), std.mem.readInt(i32, body[1..5], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(decoUpdateLen(2), body.len);
}

test "deco update rejects short buffer and over-cap counts" {
    var small: [24]u8 = undefined;
    const o: DecoObj = .{ .x = 0, .y = 1, .z = 0, .real_y = 1.0, .block_raw = 1 };
    try std.testing.expectError(error.Overflow, buildDecoUpdate(&small, true, &.{o}));
    var buf: [64]u8 = undefined;
    // finishDecoUpdate is the shared guard: count must match the bytes written.
    try std.testing.expectError(error.Overflow, finishDecoUpdate(&buf, true, 2, objects_off + deco_size));
    try std.testing.expectError(error.TooManyDecos, finishDecoUpdate(&buf, true, decos_per_package + 1, objects_off));
    try std.testing.expect(zdtd_decos_per_package <= decos_per_package);
}

test "PackageWriter splits into first + continuation packages" {
    var buf: [decoUpdateLen(3)]u8 = undefined;
    var pw = try PackageWriter.init(&buf, 3);
    const o: DecoObj = .{ .x = 4, .y = 5, .z = 6, .real_y = 5.0, .block_raw = 42 };
    var counts: [3]i32 = undefined;
    var firsts: [3]u8 = undefined;
    var pushed: usize = 0;
    // 7 objects at cap 3 => packages of 3, 3, 1.
    while (pushed < 7) : (pushed += 1) {
        if (pw.full()) {
            const body = try pw.take();
            firsts[pw.sent - 1] = body[0];
            counts[pw.sent - 1] = std.mem.readInt(i32, body[5..9], .little);
        }
        try pw.push(o);
    }
    const last = try pw.take();
    firsts[pw.sent - 1] = last[0];
    counts[pw.sent - 1] = std.mem.readInt(i32, last[5..9], .little);
    try std.testing.expectEqual(@as(usize, 3), pw.sent);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, &firsts);
    try std.testing.expectEqualSlices(i32, &.{ 3, 3, 1 }, &counts);
    try std.testing.expectEqual(decoUpdateLen(1), last.len);
}

test "PackageWriter empty take is a valid first package" {
    var buf: [64]u8 = undefined;
    var pw = try PackageWriter.init(&buf, 2);
    const body = try pw.take();
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, body[5..9], .little));
    try std.testing.expectEqual(decoUpdateLen(0), body.len);
}

test "PackageWriter rejects undersized buffer and bad cap" {
    var buf: [decoUpdateLen(2)]u8 = undefined;
    try std.testing.expectError(error.Overflow, PackageWriter.init(&buf, 3));
    try std.testing.expectError(error.TooManyDecos, PackageWriter.init(&buf, 0));
    var pw = try PackageWriter.init(&buf, 2);
    const o: DecoObj = .{ .x = 0, .y = 1, .z = 0, .real_y = 1.0, .block_raw = 1 };
    try pw.push(o);
    try pw.push(o);
    try std.testing.expectError(error.TooManyDecos, pw.push(o));
}

/// Test world: one flat height everywhere and one species list everywhere.
const TestWorld = struct {
    height: u16 = 40,
    list: SpeciesList = .{},

    fn heightAt(ctx: ?*anyopaque, _: i32, _: i32) u16 {
        const self: *const TestWorld = @ptrCast(@alignCast(ctx.?));
        return self.height;
    }

    fn speciesAt(ctx: ?*anyopaque, _: i32, _: i32) SpeciesList {
        const self: *const TestWorld = @ptrCast(@alignCast(ctx.?));
        return self.list;
    }

    fn sampler(self: *TestWorld) Sampler {
        return .{ .height_at = heightAt, .species_at = speciesAt, .ctx = self };
    }
};

fn twoSpecies() SpeciesList {
    var l: SpeciesList = .{};
    l.items[0] = .{ .block_id = 100, .prob = 0.06 };
    l.items[1] = .{ .block_id = 200, .prob = 0.07 };
    l.n = 2;
    return l;
}

const full_window: Window = .{ .x0 = -1_000_000, .z0 = -1_000_000, .x1 = 1_000_000, .z1 = 1_000_000 };

test "deco chunk sampling is deterministic and only emits supplied ids" {
    var w: TestWorld = .{ .list = twoSpecies() };
    var a: [attempts_per_deco_chunk]DecoObj = undefined;
    var b: [attempts_per_deco_chunk]DecoObj = undefined;
    const na = generateForDecoChunk(&a, -2, 3, 12345, full_window, w.sampler());
    const nb = generateForDecoChunk(&b, -2, 3, 12345, full_window, w.sampler());
    try std.testing.expectEqual(na, nb);
    try std.testing.expect(na > 0);
    try std.testing.expectEqualSlices(DecoObj, a[0..na], b[0..nb]);
    // A different seed must place differently, or a restart replays one layout.
    var c: [attempts_per_deco_chunk]DecoObj = undefined;
    const nc = generateForDecoChunk(&c, -2, 3, 999, full_window, w.sampler());
    try std.testing.expect(nc != na or !std.mem.eql(u8, std.mem.asBytes(&a[0]), std.mem.asBytes(&c[0])));

    var saw_a = false;
    var saw_b = false;
    for (a[0..na]) |o| {
        // Low 16 bits are the supplied species id; bits 16..20 carry the stock
        // 0..3 rotation roll (deco_rot_shift), so the raw is never just the id.
        try std.testing.expect(o.block_raw & 0xFFFF == 100 or o.block_raw & 0xFFFF == 200);
        try std.testing.expect((o.block_raw >> deco_rot_shift) & 0x1F <= 3);
        saw_a = saw_a or o.block_raw & 0xFFFF == 100;
        saw_b = saw_b or o.block_raw & 0xFFFF == 200;
        try std.testing.expectEqual(deco_state_active, o.state);
        // One above the surface, realYPos == block Y (stock: (int)(y + 1 + 0.5)).
        try std.testing.expectEqual(@as(i32, w.height + 1), o.y);
        try std.testing.expectEqual(@as(f32, @floatFromInt(o.y)), o.real_y);
        // Inside the deco chunk it was asked to decorate.
        try std.testing.expect(o.x >= -256 and o.x < -128);
        try std.testing.expect(o.z >= 384 and o.z < 512);
    }
    try std.testing.expect(saw_a and saw_b);
}

test "deco density tracks the biome probabilities" {
    var w: TestWorld = .{ .list = twoSpecies() };
    var out: [attempts_per_deco_chunk]DecoObj = undefined;
    const n = generateForDecoChunk(&out, 0, 0, 7, full_window, w.sampler());
    // p(accept) per attempt = 1 - (1 - .07*2)(1 - .06*2) ~= .243, minus the
    // keep-out rejections. Wide band: this asserts the probabilities drive the
    // count at all, not a tuned constant.
    try std.testing.expect(n > 80 and n < 243);

    // Ten times the probability must place materially more.
    var dense: SpeciesList = .{};
    dense.items[0] = .{ .block_id = 100, .prob = 0.6 };
    dense.items[1] = .{ .block_id = 200, .prob = 0.7 };
    dense.n = 2;
    w.list = dense;
    const nd = generateForDecoChunk(&out, 0, 0, 7, full_window, w.sampler());
    try std.testing.expect(nd > n);

    // Zero probability places nothing, and neither does an empty list.
    var zero: SpeciesList = .{};
    zero.items[0] = .{ .block_id = 100, .prob = 0 };
    zero.n = 1;
    w.list = zero;
    try std.testing.expectEqual(@as(usize, 0), generateForDecoChunk(&out, 0, 0, 7, full_window, w.sampler()));
    w.list = .{};
    try std.testing.expectEqual(@as(usize, 0), generateForDecoChunk(&out, 0, 0, 7, full_window, w.sampler()));
}

test "deco sampling skips unusable surface heights" {
    var w: TestWorld = .{ .height = 0, .list = twoSpecies() };
    var out: [attempts_per_deco_chunk]DecoObj = undefined;
    try std.testing.expectEqual(@as(usize, 0), generateForDecoChunk(&out, 0, 0, 1, full_window, w.sampler()));
    w.height = 251;
    try std.testing.expectEqual(@as(usize, 0), generateForDecoChunk(&out, 0, 0, 1, full_window, w.sampler()));
}

test "window clipping drops outside cells without moving the kept ones" {
    var w: TestWorld = .{ .list = twoSpecies() };
    var all: [attempts_per_deco_chunk]DecoObj = undefined;
    var half: [attempts_per_deco_chunk]DecoObj = undefined;
    const n_all = generateForDecoChunk(&all, 0, 0, 42, full_window, w.sampler());
    const clip: Window = .{ .x0 = 0, .z0 = 0, .x1 = 64, .z1 = 128 };
    const n_half = generateForDecoChunk(&half, 0, 0, 42, clip, w.sampler());
    try std.testing.expect(n_half > 0 and n_half < n_all);
    for (half[0..n_half]) |o| try std.testing.expect(clip.contains(o.x, o.z));
    // Every clipped object is also in the unclipped run, at the same spot.
    for (half[0..n_half]) |o| {
        var found = false;
        for (all[0..n_all]) |o2| {
            if (std.meta.eql(o, o2)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "keep-out spacing holds and the attempt cap bounds the output" {
    var dense: SpeciesList = .{};
    dense.items[0] = .{ .block_id = 100, .prob = 1.0 };
    dense.n = 1;
    var w: TestWorld = .{ .list = dense };
    var out: [attempts_per_deco_chunk]DecoObj = undefined;
    const n = generateForDecoChunk(&out, 0, 0, 3, full_window, w.sampler());
    try std.testing.expect(n > 0);
    try std.testing.expect(n <= attempts_per_deco_chunk);
    // 5x5 keep-out: no two objects may sit within 2 cells on both axes.
    for (out[0..n], 0..) |a, i| {
        for (out[0..n], 0..) |b, j| {
            if (i == j) continue;
            const dx = if (a.x > b.x) a.x - b.x else b.x - a.x;
            const dz = if (a.z > b.z) a.z - b.z else b.z - a.z;
            try std.testing.expect(dx > 2 or dz > 2);
        }
    }
}

test "output buffer overflow does not change what fits" {
    var w: TestWorld = .{ .list = twoSpecies() };
    var big: [attempts_per_deco_chunk]DecoObj = undefined;
    var small: [8]DecoObj = undefined;
    const n_big = generateForDecoChunk(&big, 5, -7, 11, full_window, w.sampler());
    const n_small = generateForDecoChunk(&small, 5, -7, 11, full_window, w.sampler());
    try std.testing.expectEqual(small.len, n_small);
    try std.testing.expect(n_big > n_small);
    try std.testing.expectEqualSlices(DecoObj, big[0..n_small], small[0..n_small]);
}

test "deco chunk mapping is floor division" {
    try std.testing.expectEqual(@as(i32, 0), worldToDecoChunk(0));
    try std.testing.expectEqual(@as(i32, 0), worldToDecoChunk(127));
    try std.testing.expectEqual(@as(i32, 1), worldToDecoChunk(128));
    try std.testing.expectEqual(@as(i32, -1), worldToDecoChunk(-1));
    try std.testing.expectEqual(@as(i32, -2), worldToDecoChunk(-129));
}

test "deco plant/tree runtime block ids" {
    // AssignIds: non-terrain IDs are >> XML index; 6xxx values hit shipping/shapes.
    try std.testing.expect(tree_dead_02 > 1000);
    try std.testing.expect(tree_oak_sml > 1000);
    try std.testing.expectEqual(@as(u32, 24626), tree_dead_02);
    try std.testing.expectEqual(@as(u32, 24629), tree_oak_sml);
    try std.testing.expectEqual(@as(u32, 24651), tree_winter_evergreen);
}

test "deco reset body size" {
    var buf: [16]u8 = undefined;
    const body = try buildDecoResetWorldChunk(&buf, -18, 28);
    try std.testing.expectEqual(@as(usize, 12), body.len);
    try std.testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, body[0..4], .little));
}
