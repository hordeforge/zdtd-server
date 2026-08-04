//! Product and compatibility versions reported to operators.

/// SemVer for the zdtd server. Keep build.zig.zon in sync; make check enforces it.
pub const product = "0.1.0";

/// Exact stock client wire currently supported by this build.
pub const stock_wire = "V3.1.0 b14";
