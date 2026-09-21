//! Offline builtin item catalog: fallback defs + stock name map.
//!
//! Split out of assets/items.zig (same code, moved verbatim);
//! re-exported so existing `items.*` call sites keep working.

const ItemDef = @import("items.zig").ItemDef;

pub const builtin_defs = [_]ItemDef{
    .{ .id = 0, .name = "none", .stack = 0 },
    .{ .id = 1, .name = "scrap", .stack = 60000, .stock_type = 0 },
    .{ .id = 2, .name = "food", .stack = 50, .is_eat = true, .food_amount = 15, .food_health = 7 },
    .{ .id = 3, .name = "ammo", .stack = 150 },
    .{ .id = 4, .name = "medicine", .stack = 10, .food_health = 25 },
    .{ .id = 5, .name = "tool", .stack = 1 },
    .{ .id = 6, .name = "dukeCoin", .stack = 60000 },
    .{ .id = 7, .name = "wood", .stack = 60000 },
    .{ .id = 8, .name = "stoneAxe", .stack = 1 },
    .{ .id = 9, .name = "meleeClub", .stack = 1 },
    .{ .id = 10, .name = "cobblePlaceable", .stack = 50 },
    .{ .id = 11, .name = "armorScrap", .stack = 1 },
    .{ .id = 12, .name = "questToken", .stack = 20 },
};

/// Map builtin ECS id → stock items.xml name (vanilla; names stable through V3.1.0 b14).
pub fn builtinStockName(item_id: u16) ?[]const u8 {
    return switch (item_id) {
        1 => "resourceScrapIron",
        2 => "foodCanBeef",
        3 => "ammo9mmBulletBall",
        4 => "medicalFirstAidBandage",
        5 => "meleeToolRepairT0StoneAxe",
        6 => "casinoCoin",
        7 => "resourceWood",
        8 => "meleeToolRepairT0StoneAxe",
        9 => "meleeWpnClubT0WoodenClub",
        10 => "resourceCobblestones",
        11 => "armorPrimitiveHelmet",
        12 => "questItem",
        else => null,
    };
}
