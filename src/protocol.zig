//! Wire constants from ../../7dtd-engine-research/docs/network/protocol.md (V3.2.0 pin; V3.1.0/V3.0.1-era goldens still cited).
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
/// 7dtd-engine-research/docs/world/terrain-height.md). zdtd emits only the
/// stock dialect; the struct survives for persistence (save stores `y_dim`)
/// and wire code that reads a height from a save. Stock = today's exact
/// values, byte-pinned by golden tests. XZ (`ChunkAreaDim`) never expands.
///
/// One source of truth: only `y_dim` is stored; `layers`, `cMaxHeight` and
/// `planeCells` derive from it, so a profile cannot disagree with itself.
/// The block-plane index stride is the fixed `ChunkAreaDim` 256
/// (`x + z*16 + y*256`).
pub const WireProfile = struct {
    /// Column height (ChunkBlockYDim). 256 stock.
    y_dim: u32 = 256,
    /// Layer height in blocks. Fixed 4.
    layer_height: u32 = 4,

    /// ChunkBlockLayers = y_dim / layer_height (64 stock).
    pub fn layers(self: WireProfile) u32 {
        return self.y_dim / self.layer_height;
    }
    /// ChunkBlockYPow = log2(y_dim) (8 stock).
    pub fn yPow(self: WireProfile) u8 {
        return @intCast(@ctz(self.y_dim));
    }
    /// cMaxHeight = y_dim - 1 (255 stock).
    pub fn cMaxHeight(self: WireProfile) u32 {
        return self.y_dim - 1;
    }
    /// Dense block-plane cell count: ChunkAreaDim × y_dim = 256 × 256 (65536
    /// stock). The plane INDEX stride is the fixed ChunkAreaDim 256
    /// (`x + z*16 + y*256`).
    pub fn planeCells(self: WireProfile) u32 {
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
        const expected_pow: u32 = @as(u32, 1) << @as(u5, @intCast(self.yPow()));
        return expected_pow == self.y_dim and self.y_dim == self.cMaxHeight() + 1;
    }
};

/// The stock wire profile: 256-tall columns, 64 layers, byte heightmaps.
/// Byte-pinned by golden tests; never change these values.
pub const stock_profile: WireProfile = .{};

test "WireProfile stock derives the RE constants" {
    try std.testing.expect(stock_profile.validate());
    try std.testing.expect(stock_profile.isStock());
    try std.testing.expectEqual(@as(u32, 64), stock_profile.layers());
    try std.testing.expectEqual(@as(u8, 8), stock_profile.yPow());
    try std.testing.expectEqual(@as(u32, 255), stock_profile.cMaxHeight());
    try std.testing.expectEqual(@as(u32, 65536), stock_profile.planeCells());

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

/// `EnumDamageTypes` (V3.2.0 b9, `il/full-v3.2.0/_global/EnumDamageTypes.il.txt`
/// field order; the wire byte in `NetPackageDamageEntity` is this ordinal:
/// protocol.md §6.5 "3 Bashing, 16 Suffocation (drown), 26 Suicide").
pub const damage_type_names = [_][]const u8{
    "none",      "piercing",   "slashing",    "bashing",       "crushing",    "corrosive",
    "heat",      "cold",       "radiation",   "toxic",         "electrical",  "disease",
    "infection", "starvation", "dehydration", "falling",       "suffocation", "bloodloss",
    "sprain",    "break",      "stun",        "concuss",       "knockout",    "blackout",
    "knockdown", "barbedwire", "suicide",     "vehicleinside", "weather",     "special",
};

/// Stock `Equipment.physicalDamageTypes`
/// (`Equipment::.cctor` IL=11: `Parse("piercing,bashing,slashing,crushing,none,corrosive")`).
/// Those are ordinals 0 (none) and 1..5, so the test is `dtype <= 5`; every
/// other `EnumDamageTypes` member is non-physical and takes
/// `ElementalDamageResist` in `Equipment.CalcDamage` (IL=83) instead of the
/// physical armor rating.
pub const max_physical_damage_type: u8 = 5;

/// True when `dtype` is in stock's `physicalDamageTypes` set (the armor-rating
/// branch of `Equipment.CalcDamage`). An out-of-range byte is treated as
/// non-physical: the enum's upper bound is the fallback, never a silent
/// physical classification.
pub fn damageTypeIsPhysical(dtype: u8) bool {
    return dtype <= max_physical_damage_type;
}

/// `DamageSource::AffectedByArmor()` (IL=5) is `damageSource ==
/// EnumDamageSource.External` (0): armour - the physical rating *and* passive
/// 43 ElementalDamageResist - applies only to External hits. Internal (1)
/// damage (starvation, dehydration, blood loss, the vehicle-inside hazard the
/// RE records as `DamageSource(Internal, VehicleInside)`) bypasses armour
/// entirely; `EntityAlive::DamageEntity`'s passive-40 GeneralDamageResist step
/// runs before this and still applies.
pub fn damageSourceAffectedByArmor(source: u8) bool {
    return source == 0;
}

/// The FastTags name for a wire damage type, used as the query tag set for
/// passive 43 and for logs. Out-of-range bytes return "" (no tag match).
pub fn damageTypeName(dtype: u8) []const u8 {
    if (dtype >= damage_type_names.len) return "";
    return damage_type_names[dtype];
}

test "damage types: stock physical set and wire names" {
    // Equipment::.cctor: piercing, bashing, slashing, crushing, none, corrosive.
    try std.testing.expect(damageTypeIsPhysical(0)); // none
    try std.testing.expect(damageTypeIsPhysical(3)); // bashing
    try std.testing.expect(damageTypeIsPhysical(5)); // corrosive
    try std.testing.expect(!damageTypeIsPhysical(6)); // heat
    try std.testing.expect(!damageTypeIsPhysical(16)); // suffocation (drown)
    try std.testing.expect(!damageTypeIsPhysical(26)); // suicide
    try std.testing.expect(!damageTypeIsPhysical(255)); // out of range -> elemental
    try std.testing.expectEqualStrings("bashing", damageTypeName(3));
    try std.testing.expectEqualStrings("suffocation", damageTypeName(16));
    try std.testing.expectEqualStrings("heat", damageTypeName(6));
    try std.testing.expectEqualStrings("", damageTypeName(200));
    // DamageSource::AffectedByArmor IL=5: External (0) only.
    try std.testing.expect(damageSourceAffectedByArmor(0));
    try std.testing.expect(!damageSourceAffectedByArmor(1));
    try std.testing.expect(!damageSourceAffectedByArmor(2));
}
