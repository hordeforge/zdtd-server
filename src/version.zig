//! Product and compatibility versions reported to operators.

/// SemVer for the zdtd server. Keep build.zig.zon in sync; make check enforces it.
pub const product = "0.1.0";

/// Exact stock client wire currently supported by this build.
pub const stock_wire = "V3.1.0 b14";

/// Version string exchanged on the wire (GSI ServerVersion, login package).
/// Stock format differs from `stock_wire`: spaced, no build number.
/// Bump together with `stock_wire` when the supported client changes.
pub const stock_wire_announce = "V 3.1.0";
