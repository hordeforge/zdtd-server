//! Product and compatibility versions reported to operators.

/// SemVer for the zdtd server. Keep build.zig.zon in sync; make check enforces it.
pub const product = "0.1.0";

/// Exact stock client wire currently supported by this build.
pub const stock_wire = "V3.1.0 b14";

/// Version string exchanged on the wire (GSI ServerVersion, login package).
/// Stock format differs from `stock_wire`: spaced, no build number.
/// Bump together with `stock_wire` when the supported client changes.
pub const stock_wire_announce = "V 3.1.0";

/// GSI `ServerVersion` (GameInfoString key 9) must be the strict four-field
/// SerializableString `{ReleaseType}.{Major}.{Minor}.{Build}` (network.md:
/// `V.3.10.14` = ReleaseType V, Major 3, Minor 0xA, Build 0xE; asm.il 2009306
/// and 795818-795822). The client's `TryParseSerializedString` requires
/// `Split('.')` to yield exactly 4 fields, so the spaced display form above
/// trips a parse warning. The login package's versionLong stays the display
/// form (`V 3.1.0`, protocol.md VersionLongString packing).
pub const stock_wire_gsi_version = "V.3.10.14";
