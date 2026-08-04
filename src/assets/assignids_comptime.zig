//! Named AssignIds pins for V3.1.x (bundled dump). Values are the stock client
//! Block.blockID after AssignIds Postfix, not XML declaration order.
//! Validated at test time against `assignids_v314.embed.txt` so a dump refresh
//! that moves a pin fails CI. Prefer runtime `maxdamage.idByName` for open sets.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

// Pins from assets/fixtures/assignids_v314.txt (ZDTD_DUMP_BLOCK_IDS, 2026-07-22).
pub const air: u16 = 0;
pub const terr_stone: u16 = 1;
pub const terrain_filler: u16 = 2;
pub const terrain_filler_adaptive: u16 = 3;
pub const terr_bedrock: u16 = 4;
pub const terr_dirt: u16 = 5;
pub const terr_forest_ground: u16 = 7;
pub const terr_burnt_forest_ground: u16 = 8;
pub const terr_desert_ground: u16 = 9;
pub const terr_sand: u16 = 10;
pub const terr_sand_stone: u16 = 11;
pub const terr_snow: u16 = 12;
pub const terr_topsoil: u16 = 13;
pub const terr_destroyed_stone: u16 = 14;
pub const terr_destroyed_grass: u16 = 30; // not 15 (that is terrDestroyedWoodDebris)
pub const water: u16 = 240;

pub const tree_dead_pine_leaf: u16 = 24612;
pub const plant_shrub: u16 = 24619;
pub const tree_dead_02: u16 = 24626;
pub const tree_oak_sml: u16 = 24629;
pub const tree_winter_evergreen: u16 = 24651;

pub const cnt_desk_safe: u16 = 18515;
pub const cnt_hardened_chest_insecure: u16 = 18650;
pub const cnt_wooden_chest_closed: u16 = 18671;
pub const cnt_wooden_chest_open: u16 = 18672;
pub const cnt_wood_writable_crate: u16 = 18683;
pub const frame_shapes_cube: u16 = 16107;
pub const cobblestone_shapes_cube: u16 = 4787;

const dump_path = "src/assets/assignids_v314.embed.txt";

const Pin = struct { id: u16, name: []const u8 };

const pins = [_]Pin{
    .{ .id = terr_stone, .name = "terrStone" },
    .{ .id = terrain_filler, .name = "terrainFiller" },
    .{ .id = terr_bedrock, .name = "terrBedrock" },
    .{ .id = terr_dirt, .name = "terrDirt" },
    .{ .id = terr_forest_ground, .name = "terrForestGround" },
    .{ .id = terr_burnt_forest_ground, .name = "terrBurntForestGround" },
    .{ .id = terr_desert_ground, .name = "terrDesertGround" },
    .{ .id = terr_sand, .name = "terrSand" },
    .{ .id = terr_sand_stone, .name = "terrSandStone" },
    .{ .id = terr_snow, .name = "terrSnow" },
    .{ .id = terr_topsoil, .name = "terrTopSoil" },
    .{ .id = terr_destroyed_stone, .name = "terrDestroyedStone" },
    .{ .id = terr_destroyed_grass, .name = "terrDestroyedGrass" },
    .{ .id = water, .name = "water" },
    .{ .id = tree_dead_02, .name = "treeDeadTree02" },
    .{ .id = tree_oak_sml, .name = "treeOakSml01" },
    .{ .id = tree_winter_evergreen, .name = "treeWinterEverGreen" },
    .{ .id = tree_dead_pine_leaf, .name = "treeDeadPineLeaf" },
    .{ .id = plant_shrub, .name = "plantShrub" },
    .{ .id = cnt_wooden_chest_closed, .name = "cntWoodenChestClosed" },
    .{ .id = cnt_wooden_chest_open, .name = "cntWoodenChestOpen" },
    .{ .id = cnt_wood_writable_crate, .name = "cntWoodWritableCrate" },
    .{ .id = cnt_desk_safe, .name = "cntDeskSafe" },
    .{ .id = cnt_hardened_chest_insecure, .name = "cntHardenedChestInsecure" },
    .{ .id = frame_shapes_cube, .name = "frameShapes:cube" },
    .{ .id = cobblestone_shapes_cube, .name = "cobblestoneShapes:cube" },
};

fn readDump(allocator: std.mem.Allocator) ![]u8 {
    return io_fs.readFileAll(allocator, dump_path);
}

test "assignids pins match bundled dump" {
    const raw = readDump(std.testing.allocator) catch return error.SkipZigTest;
    defer std.testing.allocator.free(raw);
    for (pins) |p| {
        var found = false;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var sp = std.mem.tokenizeAny(u8, line, " \t");
            const id_s = sp.next() orelse continue;
            const nm = std.mem.trim(u8, sp.rest(), " \t");
            if (!std.mem.eql(u8, nm, p.name)) continue;
            const id = try std.fmt.parseInt(u16, id_s, 10);
            try std.testing.expectEqual(p.id, id);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

// ecs/inventory keeps offline place pins without importing assets (one-way deps).
// Keep those fixture constants equal to this pin table.
test "ecs offline place pins match assignids" {
    const inv = @import("../ecs/inventory.zig");
    try std.testing.expectEqual(frame_shapes_cube, inv.place_wood_block_id);
    try std.testing.expectEqual(cobblestone_shapes_cube, inv.place_cobble_block_id);
}
