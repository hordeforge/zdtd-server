//! Shared process utilities (no game domain).
//!
//! Dependency direction: leaf layer. Must not import server, ecs, wire, world,
//! assets, litenet, or apm. Callers import these for FS helpers, mono clock,
//! seeded RNG, optional range-parallel tick work, deterministic sim mode, and
//! non-blocking TCP listen.

pub const io_fs = @import("io_fs.zig");
pub const log = @import("log.zig");
pub const parallel = @import("parallel.zig");
pub const clock = @import("clock.zig");
pub const rng = @import("rng.zig");
pub const secret = @import("secret.zig");
pub const sim = @import("sim.zig");
pub const tcp_listen = @import("tcp_listen.zig");
pub const toml_bind = @import("toml_bind.zig");

test {
    _ = io_fs;
    _ = log;
    _ = parallel;
    _ = clock;
    _ = rng;
    _ = secret;
    _ = sim;
    _ = tcp_listen;
    _ = toml_bind;
}
