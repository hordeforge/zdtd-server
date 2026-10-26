//! Product and compatibility versions reported to operators.

/// SemVer for the zdtd server. Keep build.zig.zon in sync; make check enforces it.
pub const product = "0.13.0-dev.1";

/// Exact stock client wire currently supported by this build.
pub const stock_wire = "V3.3.0 b18";

/// Version string exchanged on the wire (GSI ServerVersion, login package).
/// Stock format differs from `stock_wire`: spaced, no build number.
/// Bump together with `stock_wire` when the supported client changes.
pub const stock_wire_announce = "V 3.3.0";

/// GSI `ServerVersion` (GameInfoString key 9) must be the strict four-field
/// SerializableString `{ReleaseType}.{Major}.{Minor}.{Build}` (protocol.md:
/// `V.3.30.18` = ReleaseType V, Major 3, Minor 0x1E, Build 0x12;
/// changelog-3.3.0 §4.2: b10->b18). The client's `TryParseSerializedString`
/// requires `Split('.')` to yield exactly 4 fields, so the spaced display form
/// above trips a parse warning. The login package's versionLong stays the
/// display form (`V 3.3.0`, protocol.md VersionLongString packing).
pub const stock_wire_gsi_version = "V.3.30.18";

/// `VersionInformation.LongStringNoBuild` for the supported wire. The IL
/// reading (`String.Format("{0} {1}.{2}", ReleaseType, Major, Minor)` with
/// the raw Minor, asm.il IL_00BE) suggests "V 3.30", but the EMPIRICALLY
/// VERIFIED stock behavior on V3.1.0 b14 (network.md login-version-gate
/// section, live captures 2026-08-22/23) is the display form: the real
/// client sends "V 3.1.0" for both `version` and `compVersion` and the
/// authorizer accepts it, kicking "V 3.10" with VersionMismatch=4. The
/// 3.3.0 pin follows the same display form ("V 3.3.0", changelog-3.3.0 §4.2);
/// LIVE-VERIFIED 2026-08-29: a 7dtd-loadgen join against zdtd (PackageIds
/// numeric Minor -> the client echoes the display form) passes the gate, while
/// a mismatched Minor advertising was rejected with VersionMismatch=4.
pub const stock_wire_comp = "V 3.3.0";
