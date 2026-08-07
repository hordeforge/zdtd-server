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
pub const stock_deco = @import("stock_deco.zig");
pub const stock_nameid = @import("stock_nameid.zig");
pub const stock_entity = @import("stock_entity.zig");
pub const stock_quest = @import("stock_quest.zig");
pub const stock_buff = @import("stock_buff.zig");
pub const stock_te = @import("stock_te.zig");
pub const stock_sign = @import("stock_sign.zig");
pub const stock_party = @import("stock_party.zig");
pub const te_types = @import("te_types.zig");

test {
    _ = binary;
    _ = frame;
    _ = packages;
    _ = platform_user;
    _ = stock_inv;
    _ = stock_chunk;
    _ = stock_deco;
    _ = stock_nameid;
    _ = stock_entity;
    _ = stock_quest;
    _ = stock_buff;
    _ = stock_te;
    _ = stock_sign;
    _ = stock_party;
    _ = te_types;
}
