//! Shared process utilities (no game domain).
//!
//! Dependency direction: leaf layer. Must not import server, ecs, wire, world,
//! assets, litenet, or apm. Callers import these for FS helpers, mono clock,
//! seeded RNG, optional range-parallel tick work, deterministic sim mode, and
//! non-blocking TCP listen.

pub const io_fs = @import("io_fs.zig");
pub const parallel = @import("parallel.zig");
pub const clock = @import("clock.zig");
pub const rng = @import("rng.zig");
pub const sim = @import("sim.zig");
pub const tcp_listen = @import("tcp_listen.zig");

test {
    _ = io_fs;
    _ = parallel;
    _ = clock;
    _ = rng;
    _ = sim;
    _ = tcp_listen;
}
