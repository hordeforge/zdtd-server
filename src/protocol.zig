//! Wire constants from ../../7dtd-engine-research/docs/protocol.md (V3.x loadgen golden; wire pin V3.1.0).
//! Package IDs are dynamic (PackageIds map); never hard-code across builds.
//! Decision: docs/adr/0009-dynamic-package-ids.md. Tick model: ticks_per_second / tick_ns.
//!
//! Leaf module at src root (shared by wire/frame, server tick, main CLI).
//! Import this module directly (`@import("protocol.zig")`); not via wire.

const std = @import("std");

/// Pre-auth challenge: raw [0xCA][Guid16]
pub const challenge_marker: u8 = 0xCA;
pub const challenge_size: usize = 17;

/// LiteNet reserved header: channel byte
pub const reserved_header_bytes: usize = 1;
/// Outer envelope after channel: size(4)+comp(1)+enc(1)+count(2)
pub const outer_envelope_after_channel: usize = 8;

/// Stock GameTimer target (research closed-gaps / loop)
pub const ticks_per_second: u32 = 20;
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;

/// Golden body sizes (loadgen PackageCodec; excludes pkgId)
pub const body_entity_pos_and_rot_no_q: usize = 30;
pub const body_entity_rel_pos_and_rot_no_q: usize = 20;
pub const body_entity_alive_flags: usize = 6;

/// contentLen = pkgId(2) + body for RelPos !q
pub const content_len_entity_rel_pos_and_rot_no_q: usize = 22;

/// Wire geometry profile: the chunk-format constants a server+client pair must
/// agree on (WorldConstants ChunkBlockYDim family; research
/// 7dtd-engine-research/docs/terrain-height.md). `stock` = today's exact
/// values, byte-pinned by golden tests. A non-stock profile requires a paired
/// client mod (RealEarth-style engine expand: stock clients cannot read it).
/// XZ (`ChunkAreaDim`) never expands; only the column height grows.
///
/// One source of truth: only `y_dim` is stored; `layers`, `c_max_height` and
/// `plane_cells` derive from it, so a profile cannot disagree with itself.
/// The block-plane index stride is the fixed `ChunkAreaDim` 256 in every
/// dialect (`x + z*16 + y*256`); only the cell count grows with the height.
pub const WireProfile = struct {
    /// Column height (ChunkBlockYDim). 256 stock, 16384 RealEarth-expanded.
    y_dim: u32 = 256,
    /// Layer height in blocks. Fixed 4 in stock and expanded dumps.
    layer_height: u32 = 4,

    /// ChunkBlockLayers = y_dim / layer_height (64 stock, 4096 expanded).
    pub fn layers(self: WireProfile) u32 {
        return self.y_dim / self.layer_height;
    }
    /// ChunkBlockYPow = log2(y_dim) (8 stock, 14 expanded). Validated at load.
    pub fn y_pow(self: WireProfile) u8 {
        return @intCast(@ctz(self.y_dim));
    }
    /// cMaxHeight = y_dim - 1 (255 stock, 16383 expanded).
    pub fn c_max_height(self: WireProfile) u32 {
        return self.y_dim - 1;
    }
    /// Dense block-plane cell count: ChunkAreaDim × y_dim = 256 × y_dim
    /// (65536 stock, 131072 at 512). The plane INDEX stride is the fixed
    /// ChunkAreaDim 256 (`x + z*16 + y*256`) in every dialect - only the cell
    /// count and the layer band count grow with the column height.
    pub fn plane_cells(self: WireProfile) u32 {
        return 256 * self.y_dim;
    }
    /// Stock dialect: today's byte-pinned format.
    pub fn isStock(self: WireProfile) bool {
        return self.y_dim == 256;
    }
    /// Structural sanity: power-of-two y_dim ≥ 256, layer_height divides it.
    pub fn validate(self: WireProfile) bool {
        if (self.y_dim < 256 or self.y_dim & (self.y_dim - 1) != 0) return false;
        if (self.layer_height == 0 or self.y_dim % self.layer_height != 0) return false;
        const expected_pow: u32 = @as(u32, 1) << @as(u5, @intCast(self.y_pow()));
        return expected_pow == self.y_dim and self.y_dim == self.c_max_height() + 1;
    }
};

/// The stock wire profile: 256-tall columns, 64 layers, byte heightmaps.
/// Byte-pinned by golden tests; never change these values.
pub const stock_profile: WireProfile = .{};

/// Named wire dialects for config/operator use (`[wire] profile` in
/// zdtd.toml). Non-stock dialects need a paired client mod; stock clients
/// cannot read them. `tall-512` is the seam-proof dialect (synthetic).
pub const known_profiles = [_]struct { name: []const u8, profile: WireProfile }{
    .{ .name = "stock", .profile = .{} },
    .{ .name = "tall-512", .profile = .{ .y_dim = 512 } },
};

/// Resolve a `[wire] profile` name; null = unknown (fail closed at startup).
pub fn profileForName(name: []const u8) ?WireProfile {
    for (known_profiles) |k| {
        if (std.mem.eql(u8, name, k.name)) return k.profile;
    }
    return null;
}

test "known wire profiles resolve and validate" {
    const p = profileForName("stock").?;
    try std.testing.expect(p.validate());
    try std.testing.expect(p.isStock());
    const t = profileForName("tall-512").?;
    try std.testing.expect(t.validate());
    try std.testing.expectEqual(@as(u32, 128), t.layers());
    try std.testing.expectEqual(@as(u32, 256 * 512), t.plane_cells());
    try std.testing.expect(profileForName("bogus") == null);
}

test "WireProfile stock derives the RE constants" {
    try std.testing.expect(stock_profile.validate());
    try std.testing.expect(stock_profile.isStock());
    try std.testing.expectEqual(@as(u32, 64), stock_profile.layers());
    try std.testing.expectEqual(@as(u8, 8), stock_profile.y_pow());
    try std.testing.expectEqual(@as(u32, 255), stock_profile.c_max_height());
    try std.testing.expectEqual(@as(u32, 65536), stock_profile.plane_cells());

    // Expanded (RealEarth-style): 16384 / 8 / 4096 layers; the plane grows
    // 256 × y_dim while the index stride stays the fixed ChunkAreaDim 256.
    const tall: WireProfile = .{ .y_dim = 16384 };
    try std.testing.expect(tall.validate());
    try std.testing.expectEqual(@as(u32, 4096), tall.layers());
    try std.testing.expectEqual(@as(u8, 14), tall.y_pow());
    try std.testing.expectEqual(@as(u32, 16383), tall.c_max_height());
    try std.testing.expectEqual(@as(u32, 256 * 16384), tall.plane_cells());
    try std.testing.expect(!tall.isStock());

    // Invalid profiles are rejected.
    const non_pow2: WireProfile = .{ .y_dim = 300 };
    try std.testing.expect(!non_pow2.validate());
    const too_short: WireProfile = .{ .y_dim = 128 };
    try std.testing.expect(!too_short.validate());
    const zero_layer: WireProfile = .{ .y_dim = 256, .layer_height = 0 };
    try std.testing.expect(!zero_layer.validate());
}

/// Validate the challenge envelope shape. The caller compares the echoed GUID;
/// this helper intentionally checks only the fixed length and marker byte.
pub fn challengeEchoValid(packet: []const u8) bool {
    return packet.len == challenge_size and packet[0] == challenge_marker;
}

test "challengeEchoValid" {
    var pkt: [17]u8 = .{0} ** 17;
    pkt[0] = challenge_marker;
    try std.testing.expect(challengeEchoValid(&pkt));
    pkt[0] = 0;
    try std.testing.expect(!challengeEchoValid(&pkt));
}
