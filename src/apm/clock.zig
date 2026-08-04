//! Re-export of process mono clock (implementation lives in util/clock.zig).
//! Kept so existing `apm/clock` and `apm.clock` import paths stay stable.

pub const monoNs = @import("../util/clock.zig").monoNs;
pub const sleepNs = @import("../util/clock.zig").sleepNs;

test {
    _ = @import("../util/clock.zig");
}
