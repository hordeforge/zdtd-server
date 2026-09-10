//! World-position keyed light tile entities (TileEntityLight, type 18).
//!
//! Prefab `.tts` files carry authored Light TE markers (269 across Navezgane)
//! with their persistency payload: version u16, chunkPos Vector3i, base-TE
//! tail, then LightIntensity / LightRange / Color32 / LightType / LightAngle /
//! LightShadows (RE tile-entities-power.md 3.x + TileEntityLight.il). The
//! domain model keeps the parsed fields wire-neutrally; the wire layer builds
//! the stock TileEntityLight network body at send time.
//!
//! Persistence: light TEs are authored world data (they regenerate from the
//! prefab scan on chunk fill), so no save file - like prefab containers, they
//! are deterministic per position.

const std = @import("std");

pub const max_lights: usize = 2048;

pub const PosKey = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Light = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    intensity: f32 = 1.0,
    range: f32 = 10.0,
    /// RGBA (Color32).
    color: u32 = 0xffffffff,
    light_type: u8 = 1,
    angle: f32 = 0,
    shadows: u8 = 1,
    /// LightStateType: the blink/flicker mode. Authored payloads below v6 omit
    /// it, so the default is the steady state stock initializes the field to.
    state: u8 = 0,
    /// Blink rate and start delay in seconds (payload v>6 / v>7).
    rate: f32 = 0,
    delay: f32 = 0,
};

/// Parse a prefab `.tts` Light TE persistency payload (RE TileEntityLight.il
/// read IL=68 + TileEntity.il read): u16 version, Vector3i chunkPos (local),
/// base-TE tail (i32 when v<=18, u64 when v>1), LightIntensity f32,
/// LightRange f32, Color32 RGBA, then v>4: u8 type + f32 angle + u8 shadows,
/// v>5: u8 state, v>6: f32 rate, v>7: f32 delay. Bounds-checked; a truncated
/// payload yields the default light (fail closed, never a desync).
pub fn parsePayload(payload: []const u8, out: *Light) bool {
    var o: usize = 0;
    if (payload.len < 2 + 12) return false;
    const ver: u16 = std.mem.readInt(u16, payload[o..][0..2], .little);
    o += 2 + 12; // version + chunkPos Vector3i
    if (ver <= 18) {
        if (o + 4 > payload.len) return false;
        o += 4;
    }
    if (ver > 1) {
        if (o + 8 > payload.len) return false;
        o += 8;
    }
    if (o + 8 > payload.len) return false;
    out.intensity = @bitCast(std.mem.readInt(u32, payload[o..][0..4], .little));
    o += 4;
    out.range = @bitCast(std.mem.readInt(u32, payload[o..][0..4], .little));
    o += 4;
    if (o + 4 > payload.len) return false;
    out.color = std.mem.readInt(u32, payload[o..][0..4], .little);
    o += 4;
    if (ver > 4) {
        if (o + 6 > payload.len) return false;
        out.light_type = payload[o];
        o += 1;
        out.angle = @bitCast(std.mem.readInt(u32, payload[o..][0..4], .little));
        o += 4;
        out.shadows = payload[o];
        o += 1;
    }
    if (ver > 5) {
        if (o + 1 > payload.len) return false;
        out.state = payload[o];
        o += 1;
    }
    if (ver > 6) {
        if (o + 4 > payload.len) return false;
        out.rate = @bitCast(std.mem.readInt(u32, payload[o..][0..4], .little));
        o += 4;
    }
    if (ver > 7) {
        if (o + 4 > payload.len) return false;
        out.delay = @bitCast(std.mem.readInt(u32, payload[o..][0..4], .little));
        o += 4;
    }
    return true;
}

pub const Store = struct {
    items: [max_lights]Light = [_]Light{.{}} ** max_lights,
    used: [max_lights]bool = [_]bool{false} ** max_lights,
    n: u32 = 0,

    pub fn get(self: *const Store, pos: PosKey) ?*const Light {
        var i: usize = 0;
        while (i < max_lights) : (i += 1) {
            if (!self.used[i]) continue;
            const l = &self.items[i];
            if (l.x == pos.x and l.y == pos.y and l.z == pos.z) return l;
        }
        return null;
    }

    pub fn getOrCreate(self: *Store, pos: PosKey) ?*Light {
        var free: ?usize = null;
        var i: usize = 0;
        while (i < max_lights) : (i += 1) {
            if (!self.used[i]) {
                if (free == null) free = i;
                continue;
            }
            const l = &self.items[i];
            if (l.x == pos.x and l.y == pos.y and l.z == pos.z) return l;
        }
        const f = free orelse return null;
        self.used[f] = true;
        self.n +|= 1;
        const l = &self.items[f];
        l.* = .{ .x = pos.x, .y = pos.y, .z = pos.z };
        return l;
    }

    /// Drop the light at a position. Without this a light outlived the block
    /// that carried it: the chunk stream walks the live entries and ships one
    /// per joining player, so a destroyed lamp kept lighting the room for
    /// everyone who arrived afterwards.
    pub fn removeAt(self: *Store, pos: PosKey) void {
        var i: usize = 0;
        while (i < max_lights) : (i += 1) {
            if (!self.used[i]) continue;
            const l = &self.items[i];
            if (l.x != pos.x or l.y != pos.y or l.z != pos.z) continue;
            self.used[i] = false;
            self.n -|= 1;
            return;
        }
    }
};

test "parsePayload decodes a stock-format light payload" {
    // Synthetic payload mirroring the abandoned_house_07 marker (v16):
    // ver u16 16 | pos 3xi32 | i32 -1 (v<=18) | u64 0 (v>1) | f32 1.3 |
    // f32 3.0 | Color32 ff2993ff | u8 type 2 | f32 angle | u8 shadows |
    // u8 state | f32 rate | f32 delay. A v16 payload carries all nine fields;
    // the version gates only matter for the older authored markers.
    var p: [64]u8 = undefined;
    var o: usize = 0;
    const w = struct {
        fn put16(b: []u8, pos: *usize, v: u16) void {
            std.mem.writeInt(u16, b[pos.*..][0..2], v, .little);
            pos.* += 2;
        }
        fn put32(b: []u8, pos: *usize, v: i32) void {
            std.mem.writeInt(i32, b[pos.*..][0..4], v, .little);
            pos.* += 4;
        }
        fn putu32(b: []u8, pos: *usize, v: u32) void {
            std.mem.writeInt(u32, b[pos.*..][0..4], v, .little);
            pos.* += 4;
        }
        fn putf32(b: []u8, pos: *usize, v: f32) void {
            std.mem.writeInt(u32, b[pos.*..][0..4], @bitCast(v), .little);
            pos.* += 4;
        }
    };
    w.put16(&p, &o, 16);
    w.put32(&p, &o, 24);
    w.put32(&p, &o, 4);
    w.put32(&p, &o, 23);
    w.put32(&p, &o, -1);
    w.putu32(&p, &o, 0);
    w.putu32(&p, &o, 0);
    w.putf32(&p, &o, 1.3);
    w.putf32(&p, &o, 3.0);
    w.putu32(&p, &o, 0xff2993ff);
    p[o] = 2;
    o += 1;
    w.putf32(&p, &o, 0.5);
    p[o] = 1;
    o += 1;
    p[o] = 3;
    o += 1;
    w.putf32(&p, &o, 0.25);
    w.putf32(&p, &o, 1.5);

    var lt: Light = .{};
    try std.testing.expect(parsePayload(p[0..o], &lt));
    try std.testing.expectApproxEqAbs(@as(f32, 1.3), lt.intensity, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), lt.range, 0.001);
    try std.testing.expectEqual(@as(u32, 0xff2993ff), lt.color);
    try std.testing.expectEqual(@as(u8, 2), lt.light_type);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lt.angle, 0.001);
    try std.testing.expectEqual(@as(u8, 1), lt.shadows);
    try std.testing.expectEqual(@as(u8, 3), lt.state);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), lt.rate, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), lt.delay, 0.001);

    // Truncated payload fails closed (default light).
    var lt2: Light = .{};
    try std.testing.expect(!parsePayload(p[0..8], &lt2));

    // A v5 marker stops after shadows; the three tail fields keep their
    // defaults rather than reading past the authored payload.
    var p5: [64]u8 = undefined;
    @memcpy(p5[0..o], p[0..o]);
    var o5: usize = 0;
    w.put16(&p5, &o5, 5);
    var lt3: Light = .{};
    try std.testing.expect(parsePayload(p5[0 .. o - 9], &lt3));
    try std.testing.expectEqual(@as(u8, 0), lt3.state);
    try std.testing.expectApproxEqAbs(@as(f32, 0), lt3.rate, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), lt3.delay, 0.001);
}
