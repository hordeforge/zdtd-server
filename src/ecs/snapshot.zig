//! Deterministic sim snapshot bytes for tests/debug (not a full save format).
//! Fixed buffer, no heap. Covers live entity census + director clock.

const std = @import("std");
const World = @import("world.zig").World;
const max_entities = @import("world.zig").max_entities;
const Kind = @import("components.zig").Kind;

pub const magic: u32 = 0x5a445453; // "ZDTS"
/// zdtd snapshot format version (debug/test format, not a stock save).
pub const version: u16 = 1;

fn putU32(b: []u8, p: *usize, v: u32) void {
    std.mem.writeInt(u32, b[p.*..][0..4], v, .little);
    p.* += 4;
}
fn putU16(b: []u8, p: *usize, v: u16) void {
    std.mem.writeInt(u16, b[p.*..][0..2], v, .little);
    p.* += 2;
}
fn putU64(b: []u8, p: *usize, v: u64) void {
    std.mem.writeInt(u64, b[p.*..][0..8], v, .little);
    p.* += 8;
}

/// Write a compact census into `buf`. Returns written slice.
pub fn writeCensus(w: *const World, buf: []u8) ![]const u8 {
    if (buf.len < 64) return error.Overflow;
    var pos: usize = 0;
    putU32(buf, &pos, magic);
    putU16(buf, &pos, version);
    putU16(buf, &pos, w.entity_count);
    putU32(buf, &pos, @intCast(w.next_net_id));
    putU64(buf, &pos, w.director.clock.worldTimeBits());
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        const k: Kind = @enumFromInt(f.value);
        putU16(buf, &pos, @intCast(w.countKind(k)));
    }
    var listed: u16 = 0;
    const max_list: u16 = 32;
    putU16(buf, &pos, 0);
    const count_at = pos - 2;
    var i: u16 = 0;
    while (i < max_entities and listed < max_list) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].network_id) continue;
        if (pos + 10 > buf.len) break;
        putU32(buf, &pos, @bitCast(w.network_id[i].id));
        putU32(buf, &pos, w.network_id[i].gen);
        putU16(buf, &pos, @intFromEnum(w.kind[i]));
        listed += 1;
    }
    std.mem.writeInt(u16, buf[count_at..][0..2], listed, .little);
    return buf[0..pos];
}

test "census roundtrip size" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    _ = w.spawnZombie(0, 70, 0, 40);
    _ = w.spawnPlayer(1, 70, 1, 0);
    var buf: [256]u8 = undefined;
    const out = try writeCensus(&w, &buf);
    try std.testing.expect(out.len >= 16);
    try std.testing.expectEqual(magic, std.mem.readInt(u32, out[0..4], .little));
    try std.testing.expectEqual(@as(u16, version), std.mem.readInt(u16, out[4..6], .little));
}
