//! Re-export of process mono clock (implementation lives in util/clock.zig).
//! Kept so existing `apm/clock` and `apm.clock` import paths stay stable.
//! Prefer `util/clock` from server/litenet (metrics package is not a time source).
//! Virtual-clock APIs are re-exported so sim harnesses can inject time via either path.

const impl = @import("../util/clock.zig");

pub const monoNs = impl.monoNs;
pub const sleepNs = impl.sleepNs;
pub const isVirtual = impl.isVirtual;
pub const enableVirtual = impl.enableVirtual;
pub const disableVirtual = impl.disableVirtual;
pub const setVirtualNs = impl.setVirtualNs;
pub const advanceNs = impl.advanceNs;

test {
    _ = impl;
}
