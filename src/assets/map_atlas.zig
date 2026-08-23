//! Stock texture-atlas minimap colors, generated from
//! `../7dtd-engine-research/tools/sandbox/atlas/ta_*.xml` by
//! `../7dtd-engine-research/tools/sandbox/gen_atlas_zig.py` (do not hand-edit).
//! Source of truth: the `MeshDescription.MetaData` TextAssets in the
//! stock V3.1.0 b14 `meshdescriptions_assets_all.bundle` (docs/texture-atlas.md
//! in the 7dtd-engine-research repo). Colors are packed with the stock
//! Utils.ToColor5 RGB555 formula: (r*31+0.5)<<10 | (g*31+0.5)<<5 | (b*31+0.5).

pub const Entry = struct {
    /// Texture id (blocks.xml Texture property values index this).
    id: u16,
    /// RGB555 minimap color.
    color5: u16,
};

pub const Atlas = struct {
    name: []const u8,
    entries: []const Entry,
};

pub const atlases = [_]Atlas{
    .{ .name = "decalsxml", .entries = &.{ .{ .id = 500, .color5 = 15819 }, .{ .id = 501, .color5 = 0 }, .{ .id = 502, .color5 = 17901 }, .{ .id = 503, .color5 = 5284 }, .{ .id = 504, .color5 = 6308 }, .{ .id = 505, .color5 = 3138 }, .{ .id = 506, .color5 = 16647 }, .{ .id = 507, .color5 = 6341 }, .{ .id = 508, .color5 = 4227 }, .{ .id = 509, .color5 = 3138 }, .{ .id = 510, .color5 = 5285 }, .{ .id = 511, .color5 = 5120 }, .{ .id = 512, .color5 = 3137 }, .{ .id = 513, .color5 = 14697 }, .{ .id = 514, .color5 = 5284 }, .{ .id = 515, .color5 = 7332 } } },
    .{ .name = "grassxml", .entries = &.{ .{ .id = 39, .color5 = 5314 }, .{ .id = 40, .color5 = 4257 }, .{ .id = 177, .color5 = 4195 }, .{ .id = 201, .color5 = 9446 }, .{ .id = 244, .color5 = 4227 }, .{ .id = 306, .color5 = 8455 }, .{ .id = 350, .color5 = 13741 }, .{ .id = 351, .color5 = 17935 }, .{ .id = 362, .color5 = 5314 }, .{ .id = 364, .color5 = 4258 }, .{ .id = 365, .color5 = 6340 }, .{ .id = 368, .color5 = 12683 }, .{ .id = 369, .color5 = 9512 }, .{ .id = 370, .color5 = 10571 }, .{ .id = 371, .color5 = 0 }, .{ .id = 377, .color5 = 6340 }, .{ .id = 395, .color5 = 7395 }, .{ .id = 401, .color5 = 5314 }, .{ .id = 402, .color5 = 5314 }, .{ .id = 550, .color5 = 8453 }, .{ .id = 551, .color5 = 8453 }, .{ .id = 561, .color5 = 8355 }, .{ .id = 562, .color5 = 9476 }, .{ .id = 563, .color5 = 12647 }, .{ .id = 564, .color5 = 9478 }, .{ .id = 565, .color5 = 11625 }, .{ .id = 567, .color5 = 7363 }, .{ .id = 568, .color5 = 9512 }, .{ .id = 573, .color5 = 5314 } } },
    .{ .name = "opaquexml", .entries = &.{ .{ .id = 7, .color5 = 11562 }, .{ .id = 8, .color5 = 13740 }, .{ .id = 9, .color5 = 15721 }, .{ .id = 11, .color5 = 13706 }, .{ .id = 12, .color5 = 15854 }, .{ .id = 13, .color5 = 11495 }, .{ .id = 14, .color5 = 11592 }, .{ .id = 15, .color5 = 11625 }, .{ .id = 21, .color5 = 21994 }, .{ .id = 22, .color5 = 13706 }, .{ .id = 23, .color5 = 11593 }, .{ .id = 43, .color5 = 17901 }, .{ .id = 44, .color5 = 15821 }, .{ .id = 46, .color5 = 6275 }, .{ .id = 47, .color5 = 9479 }, .{ .id = 50, .color5 = 12717 }, .{ .id = 51, .color5 = 12714 }, .{ .id = 52, .color5 = 19025 }, .{ .id = 53, .color5 = 23217 }, .{ .id = 54, .color5 = 20048 }, .{ .id = 55, .color5 = 6342 }, .{ .id = 56, .color5 = 18991 }, .{ .id = 57, .color5 = 13672 }, .{ .id = 61, .color5 = 12684 }, .{ .id = 62, .color5 = 3171 }, .{ .id = 64, .color5 = 13708 }, .{ .id = 65, .color5 = 16843 }, .{ .id = 67, .color5 = 15787 }, .{ .id = 73, .color5 = 21106 }, .{ .id = 74, .color5 = 11593 }, .{ .id = 75, .color5 = 13641 }, .{ .id = 76, .color5 = 11593 }, .{ .id = 77, .color5 = 16845 }, .{ .id = 78, .color5 = 23186 }, .{ .id = 79, .color5 = 14697 }, .{ .id = 81, .color5 = 13673 }, .{ .id = 84, .color5 = 11560 }, .{ .id = 116, .color5 = 15821 }, .{ .id = 168, .color5 = 15786 }, .{ .id = 169, .color5 = 13640 }, .{ .id = 170, .color5 = 17769 }, .{ .id = 171, .color5 = 18992 }, .{ .id = 172, .color5 = 18992 }, .{ .id = 173, .color5 = 18991 }, .{ .id = 174, .color5 = 20048 }, .{ .id = 191, .color5 = 15855 }, .{ .id = 192, .color5 = 14797 }, .{ .id = 193, .color5 = 15689 }, .{ .id = 194, .color5 = 16911 }, .{ .id = 214, .color5 = 12485 }, .{ .id = 217, .color5 = 18992 }, .{ .id = 226, .color5 = 15788 }, .{ .id = 227, .color5 = 18959 }, .{ .id = 229, .color5 = 6341 }, .{ .id = 241, .color5 = 12617 }, .{ .id = 245, .color5 = 22163 }, .{ .id = 246, .color5 = 14664 }, .{ .id = 247, .color5 = 10503 }, .{ .id = 248, .color5 = 10569 }, .{ .id = 261, .color5 = 18957 }, .{ .id = 262, .color5 = 11560 }, .{ .id = 263, .color5 = 11560 }, .{ .id = 267, .color5 = 9581 }, .{ .id = 268, .color5 = 15822 }, .{ .id = 269, .color5 = 14662 }, .{ .id = 272, .color5 = 13672 }, .{ .id = 282, .color5 = 16912 }, .{ .id = 299, .color5 = 17836 }, .{ .id = 302, .color5 = 11626 }, .{ .id = 303, .color5 = 12650 }, .{ .id = 307, .color5 = 16911 }, .{ .id = 311, .color5 = 22757 }, .{ .id = 312, .color5 = 22196 }, .{ .id = 314, .color5 = 19026 }, .{ .id = 315, .color5 = 17967 }, .{ .id = 319, .color5 = 21039 }, .{ .id = 320, .color5 = 15887 }, .{ .id = 321, .color5 = 11593 }, .{ .id = 328, .color5 = 15821 }, .{ .id = 329, .color5 = 16878 }, .{ .id = 330, .color5 = 17935 }, .{ .id = 331, .color5 = 17935 }, .{ .id = 332, .color5 = 18993 }, .{ .id = 334, .color5 = 6342 }, .{ .id = 335, .color5 = 9512 }, .{ .id = 336, .color5 = 9512 }, .{ .id = 337, .color5 = 9512 }, .{ .id = 340, .color5 = 16844 }, .{ .id = 342, .color5 = 15855 }, .{ .id = 344, .color5 = 10502 }, .{ .id = 345, .color5 = 10502 }, .{ .id = 352, .color5 = 15787 }, .{ .id = 355, .color5 = 13741 }, .{ .id = 356, .color5 = 16878 }, .{ .id = 358, .color5 = 30653 }, .{ .id = 361, .color5 = 16845 }, .{ .id = 372, .color5 = 7465 }, .{ .id = 379, .color5 = 13640 }, .{ .id = 380, .color5 = 9479 }, .{ .id = 382, .color5 = 11525 }, .{ .id = 385, .color5 = 10634 }, .{ .id = 391, .color5 = 10537 }, .{ .id = 407, .color5 = 16911 }, .{ .id = 408, .color5 = 14762 }, .{ .id = 413, .color5 = 14797 }, .{ .id = 428, .color5 = 11658 }, .{ .id = 429, .color5 = 18757 }, .{ .id = 435, .color5 = 9581 }, .{ .id = 436, .color5 = 10603 }, .{ .id = 443, .color5 = 11594 }, .{ .id = 445, .color5 = 13740 }, .{ .id = 446, .color5 = 14764 }, .{ .id = 519, .color5 = 27449 }, .{ .id = 525, .color5 = 14763 }, .{ .id = 531, .color5 = 9512 }, .{ .id = 532, .color5 = 14798 }, .{ .id = 534, .color5 = 20048 }, .{ .id = 535, .color5 = 23187 }, .{ .id = 536, .color5 = 19940 }, .{ .id = 537, .color5 = 8589 }, .{ .id = 538, .color5 = 26155 }, .{ .id = 539, .color5 = 18856 }, .{ .id = 540, .color5 = 15525 }, .{ .id = 541, .color5 = 16648 }, .{ .id = 542, .color5 = 19731 }, .{ .id = 543, .color5 = 6283 }, .{ .id = 544, .color5 = 14796 }, .{ .id = 545, .color5 = 11626 }, .{ .id = 546, .color5 = 15821 }, .{ .id = 547, .color5 = 22198 }, .{ .id = 548, .color5 = 17934 }, .{ .id = 549, .color5 = 15821 }, .{ .id = 552, .color5 = 9480 }, .{ .id = 553, .color5 = 9513 }, .{ .id = 555, .color5 = 10603 }, .{ .id = 571, .color5 = 10570 }, .{ .id = 580, .color5 = 20083 }, .{ .id = 581, .color5 = 6342 }, .{ .id = 582, .color5 = 13739 }, .{ .id = 583, .color5 = 21103 }, .{ .id = 584, .color5 = 23219 }, .{ .id = 585, .color5 = 22092 }, .{ .id = 586, .color5 = 10503 }, .{ .id = 587, .color5 = 14662 }, .{ .id = 588, .color5 = 17903 }, .{ .id = 589, .color5 = 15821 }, .{ .id = 590, .color5 = 11559 }, .{ .id = 591, .color5 = 13740 }, .{ .id = 592, .color5 = 21034 }, .{ .id = 593, .color5 = 13707 }, .{ .id = 596, .color5 = 8456 }, .{ .id = 597, .color5 = 13641 }, .{ .id = 598, .color5 = 10503 }, .{ .id = 600, .color5 = 16879 }, .{ .id = 602, .color5 = 15786 }, .{ .id = 603, .color5 = 14630 }, .{ .id = 604, .color5 = 15854 }, .{ .id = 605, .color5 = 22162 }, .{ .id = 606, .color5 = 15854 }, .{ .id = 607, .color5 = 14699 } } },
    .{ .name = "terrainxml", .entries = &.{ .{ .id = 1, .color5 = 9513 }, .{ .id = 2, .color5 = 11593 }, .{ .id = 6, .color5 = 18004 }, .{ .id = 8, .color5 = 12684 }, .{ .id = 10, .color5 = 11627 }, .{ .id = 11, .color5 = 14764 }, .{ .id = 33, .color5 = 6343 }, .{ .id = 34, .color5 = 3172 }, .{ .id = 184, .color5 = 13606 }, .{ .id = 185, .color5 = 16777 }, .{ .id = 195, .color5 = 5315 }, .{ .id = 288, .color5 = 10570 }, .{ .id = 300, .color5 = 20050 }, .{ .id = 316, .color5 = 7400 }, .{ .id = 403, .color5 = 8454 }, .{ .id = 438, .color5 = 10569 }, .{ .id = 439, .color5 = 10569 }, .{ .id = 440, .color5 = 13643 }, .{ .id = 569, .color5 = 9513 }, .{ .id = 570, .color5 = 9513 } } },
    .{ .name = "transparentxml", .entries = &.{ .{ .id = 285, .color5 = 8456 }, .{ .id = 333, .color5 = 7399 }, .{ .id = 532, .color5 = 13741 }, .{ .id = 596, .color5 = 7399 }, .{ .id = 702, .color5 = 8489 } } },
    .{ .name = "waterxml", .entries = &.{.{ .id = 223, .color5 = 14794 }} },
};

const std = @import("std");

/// Minimap water color (BlockLiquidv2.Color = Color32(0,105,148))
/// packed RGB555 (RE texture-atlas.md CalcChunkColors).
pub const water_color5: u16 = 434;
/// Fallback when a block has no atlas color nor MapColor: stock
/// Color.get_gray() = (0.5,0.5,0.5) -> RGB555 16,16,16.
pub const gray_color5: u16 = 16816;

/// blocks.xml Mesh property name -> atlas table name. Empty (no
/// Mesh property) = default mesh 0 = "opaque" (RE texture-atlas.md).
pub fn atlasForMesh(mesh: []const u8) []const u8 {
    if (std.mem.eql(u8, mesh, "terrain")) return "terrainxml";
    if (std.mem.eql(u8, mesh, "grass")) return "grassxml";
    if (std.mem.eql(u8, mesh, "water")) return "waterxml";
    if (std.mem.eql(u8, mesh, "transparent")) return "transparentxml";
    if (std.mem.eql(u8, mesh, "decals")) return "decalsxml";
    return "opaquexml";
}

/// A block's minimap color: the MapColor property wins (stock
/// Block.GetMapColor bMapColorSet path); else the top-face
/// texture's atlas color; else null (caller picks gray).
pub fn blockColor5(mesh: []const u8, texture_top: u16, map_color: u16) ?u16 {
    if (map_color != 0) return map_color;
    if (texture_top == 0) return null;
    return color5(atlasForMesh(mesh), texture_top);
}

/// Look up the minimap color for a texture id in an atlas (init-time only).
pub fn color5(atlas_name: []const u8, texture_id: u16) ?u16 {
    for (&atlases) |*a| {
        if (!std.mem.eql(u8, a.name, atlas_name)) continue;
        for (a.entries) |e| {
            if (e.id == texture_id) return e.color5;
        }
        return null;
    }
    return null;
}

test "terrain atlas colors match the extracted XML" {
    // terrDirt texture id 2 (blocks.xml Texture=2): stock color
    // 0.3529412,0.3176471,0.2784314 -> RGB555 r=11 g=10 b=9.
    const c = color5("terrainxml", 2).?;
    const r = (c >> 10) & 0x1f;
    const g = (c >> 5) & 0x1f;
    const b = c & 0x1f;
    try std.testing.expectEqual(@as(u16, 11), r);
    try std.testing.expectEqual(@as(u16, 10), g);
    try std.testing.expectEqual(@as(u16, 9), b);
    // terrForestGround top face id 195.
    try std.testing.expect(color5("terrainxml", 195) != null);
    // Unknown id in a known atlas: null.
    try std.testing.expect(color5("terrainxml", 9999) == null);
    // Unknown atlas: null.
    try std.testing.expect(color5("nope", 1) == null);
    // Resolver: MapColor property wins; else the mesh atlas.
    try std.testing.expectEqual(@as(?u16, 2243), blockColor5("terrain", 2, 2243));
    try std.testing.expect(blockColor5("terrain", 195, 0) != null); // terrForestGround top face
    try std.testing.expect(blockColor5("opaque", 52, 0) != null); // wood in the opaque atlas
    try std.testing.expect(blockColor5("terrain", 9999, 0) == null); // no atlas color
    try std.testing.expectEqualStrings("opaquexml", atlasForMesh(""));
    try std.testing.expectEqual(@as(u16, 434), water_color5);
}
