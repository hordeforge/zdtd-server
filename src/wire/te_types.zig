//! Stock TileEntityType enum values (RE: TileEntityType / network TE discriminant).
//! Named constants only; not loaded from XML (engine enum, not game data tables).

/// Classic TileEntityType (V3.x). Cite IL / research when adding.
pub const none: u8 = 0;
pub const loot: u8 = 1;
pub const trader: u8 = 2;
pub const vantage_point: u8 = 3;
pub const fortress_rubble: u8 = 4;
/// CompositeTileEntity / storage path used by zdtd stock_te (RE capture).
pub const composite: u8 = 5;
pub const secure_loot: u8 = 6;
pub const workstation: u8 = 12;
pub const sign: u8 = 0x16;
pub const light: u8 = 0x19;
pub const powered: u8 = 10;

/// Types accepted for generic storage/open TE handlers in Game.
pub fn isStorageLike(te_type: u8) bool {
    return te_type == composite or te_type == loot or te_type == secure_loot or te_type == 0;
}

pub fn isSignLike(te_type: u8) bool {
    return te_type == sign;
}

pub fn isWorkstation(te_type: u8) bool {
    return te_type == workstation;
}
