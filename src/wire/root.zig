//! Wire package layer: binary LE helpers, frames, stock body builders.
//!
//! Dependency direction: wire may import util, assets (id pins, unity hash),
//! ecs component shapes, and world container/workstation domain types for TE
//! apply. It must not import server or litenet.
//!
//! Stock body modules: import via `packages.zig` (one facade).
//! Protocol constants: `src/protocol.zig` only (not re-exported here).

pub const binary = @import("binary.zig");
pub const frame = @import("frame.zig");
pub const packages = @import("packages.zig");
pub const platform_user = @import("platform_user.zig");
pub const stock_inv = @import("stock_inv.zig");
pub const stock_chunk = @import("stock_chunk.zig");
pub const chunk_tests = @import("chunk_tests.zig");
pub const stock_deco = @import("stock_deco.zig");
pub const stock_nameid = @import("stock_nameid.zig");
pub const stock_entity = @import("stock_entity.zig");
pub const stock_quest = @import("stock_quest.zig");
pub const stock_buff = @import("stock_buff.zig");
pub const stock_damage = @import("stock_damage.zig");
pub const stock_map = @import("stock_map.zig");
pub const stock_motion = @import("stock_motion.zig");
pub const stock_block = @import("stock_block.zig");
pub const stock_world = @import("stock_world.zig");
pub const stock_estats = @import("stock_estats.zig");
pub const stock_invtx = @import("stock_invtx.zig");
pub const stock_lock = @import("stock_lock.zig");
pub const stock_playerid = @import("stock_playerid.zig");
pub const stock_trade = @import("stock_trade.zig");
pub const stock_denied = @import("stock_denied.zig");
pub const stock_login = @import("stock_login.zig");
pub const stock_gameevent = @import("stock_gameevent.zig");
pub const stock_console = @import("stock_console.zig");
pub const stock_chat = @import("stock_chat.zig");
pub const stock_attach = @import("stock_attach.zig");
pub const stock_areas = @import("stock_areas.zig");
pub const stock_velocity = @import("stock_velocity.zig");
pub const stock_weather = @import("stock_weather.zig");
pub const stock_anim = @import("stock_anim.zig");
pub const stock_poi = @import("stock_poi.zig");
pub const stock_clientinfo = @import("stock_clientinfo.zig");
pub const stock_turret = @import("stock_turret.zig");
pub const stock_positions = @import("stock_positions.zig");
pub const stock_claim = @import("stock_claim.zig");
pub const stock_nav = @import("stock_nav.zig");
pub const stock_explosion = @import("stock_explosion.zig");
pub const stock_sleeper = @import("stock_sleeper.zig");
pub const stock_lookat = @import("stock_lookat.zig");
pub const stock_horde = @import("stock_horde.zig");
pub const stock_remove = @import("stock_remove.zig");
pub const stock_bloodmoon = @import("stock_bloodmoon.zig");
pub const stock_chunkremove = @import("stock_chunkremove.zig");
pub const stock_collect = @import("stock_collect.zig");
pub const stock_gamestats = @import("stock_gamestats.zig");
pub const stock_loginanswer = @import("stock_loginanswer.zig");
pub const stock_localization = @import("stock_localization.zig");
pub const stock_configfile = @import("stock_configfile.zig");
pub const stock_ids = @import("stock_ids.zig");
pub const stock_frame = @import("stock_frame.zig");
pub const stock_vehicle = @import("stock_vehicle.zig");
pub const stock_te = @import("stock_te.zig");
pub const stock_sign = @import("stock_sign.zig");
pub const stock_party = @import("stock_party.zig");
pub const stock_xp = @import("stock_xp.zig");
pub const te_types = @import("te_types.zig");

test {
    _ = binary;
    _ = frame;
    _ = packages;
    _ = platform_user;
    _ = stock_inv;
    _ = stock_chunk;
    _ = chunk_tests;
    _ = stock_deco;
    _ = stock_nameid;
    _ = stock_entity;
    _ = stock_quest;
    _ = stock_buff;
    _ = stock_damage;
    _ = stock_map;
    _ = stock_motion;
    _ = stock_block;
    _ = stock_world;
    _ = stock_estats;
    _ = stock_invtx;
    _ = stock_lock;
    _ = stock_playerid;
    _ = stock_trade;
    _ = stock_denied;
    _ = stock_login;
    _ = stock_gameevent;
    _ = stock_console;
    _ = stock_chat;
    _ = stock_attach;
    _ = stock_areas;
    _ = stock_velocity;
    _ = stock_weather;
    _ = stock_anim;
    _ = stock_poi;
    _ = stock_clientinfo;
    _ = stock_turret;
    _ = stock_positions;
    _ = stock_claim;
    _ = stock_nav;
    _ = stock_explosion;
    _ = stock_sleeper;
    _ = stock_lookat;
    _ = stock_horde;
    _ = stock_remove;
    _ = stock_bloodmoon;
    _ = stock_chunkremove;
    _ = stock_collect;
    _ = stock_gamestats;
    _ = stock_loginanswer;
    _ = stock_localization;
    _ = stock_configfile;
    _ = stock_ids;
    _ = stock_frame;
    _ = stock_vehicle;
    _ = stock_te;
    _ = stock_sign;
    _ = stock_party;
    _ = stock_xp;
    _ = te_types;
}
