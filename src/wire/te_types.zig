//! Stock TileEntityType enum values (RE: TileEntityType / network TE discriminant,
//! IL 1311761-1311788, tabulated in 7dtd-research world-generation.md).
//! Named constants only; not loaded from XML (engine enum, not game data tables).

const std = @import("std");

pub const none: u8 = 0; // RE IL 1311761-1311788: None
pub const collector: u8 = 3; // RE: Collector
pub const land_claim: u8 = 4; // RE: LandClaim
pub const loot: u8 = 5; // RE: Loot (the .tts TE list uses stock values)
pub const trader: u8 = 6; // RE: Trader
pub const vending: u8 = 7; // RE: VendingMachine
pub const forge: u8 = 8; // RE: Forge
pub const campfire: u8 = 9; // RE: Campfire
pub const secure_loot: u8 = 0x0A; // RE: SecureLoot
pub const secure_door: u8 = 0x0B; // RE: SecureDoor
pub const workstation: u8 = 0x0C; // RE: Workstation
pub const sign: u8 = 0x0D; // RE: Sign
pub const gore_block: u8 = 0x0E; // RE: GoreBlock
pub const powered: u8 = 0x0F; // RE: Powered
pub const power_source: u8 = 0x10; // RE: PowerSource
pub const power_range_trap: u8 = 0x11; // RE: PowerRangeTrap
pub const light: u8 = 0x12; // RE: Light
pub const trigger: u8 = 0x13; // RE: Trigger
pub const sleeper: u8 = 0x14; // RE: Sleeper
pub const power_melee_trap: u8 = 0x15; // RE: PowerMeleeTrap
pub const secure_loot_signed: u8 = 0x16; // RE: SecureLootSigned
/// CompositeTileEntity / storage path used by zdtd stock_te (RE capture).
pub const composite: u8 = 0x19; // RE: Composite
pub const taskboard: u8 = 0x1B; // RE: Taskboard

/// Types accepted for generic storage/open TE handlers in Game.
pub fn isStorageLike(te_type: u8) bool {
    return te_type == composite or te_type == loot or te_type == secure_loot or te_type == none;
}

pub fn isSignLike(te_type: u8) bool {
    return te_type == sign or te_type == secure_loot_signed;
}
