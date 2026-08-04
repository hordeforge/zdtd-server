//! Wire package layer: binary LE helpers, frames, stock body builders.
//!
//! Dependency direction: wire may import util, assets (id pins, unity hash),
//! ecs component shapes, and world container/workstation domain types for TE
//! apply. It must not import server or litenet.
//!
//! Prefer `packages.zig` as the facade for stock body modules.
//! Protocol constants live in `src/protocol.zig` (re-exported here).

pub const binary = @import("binary.zig");
pub const frame = @import("frame.zig");
pub const packages = @import("packages.zig");
pub const stock_inv = @import("stock_inv.zig");
pub const stock_chunk = @import("stock_chunk.zig");
pub const stock_deco = @import("stock_deco.zig");
pub const stock_entity = @import("stock_entity.zig");
pub const stock_quest = @import("stock_quest.zig");
pub const stock_te = @import("stock_te.zig");
pub const te_types = @import("te_types.zig");
/// Wire constants (challenge, tick rate, golden sizes). Single source: src/protocol.zig.
pub const protocol = @import("../protocol.zig");

test {
    _ = binary;
    _ = frame;
    _ = packages;
    _ = stock_inv;
    _ = stock_chunk;
    _ = stock_deco;
    _ = stock_entity;
    _ = stock_quest;
    _ = stock_te;
    _ = te_types;
    _ = protocol;
}
