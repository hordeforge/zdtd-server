//! Product and compatibility versions reported to operators.

/// SemVer for the zdtd server. Keep build.zig.zon in sync; make check enforces it.
pub const product = "0.2.0";

/// Exact stock client wire currently supported by this build.
pub const stock_wire = "V3.2.0 b9";

/// Version string exchanged on the wire (GSI ServerVersion, login package).
/// Stock format differs from `stock_wire`: spaced, no build number.
/// Bump together with `stock_wire` when the supported client changes.
pub const stock_wire_announce = "V 3.2.0";

/// GSI `ServerVersion` (GameInfoString key 9) must be the strict four-field
/// SerializableString `{ReleaseType}.{Major}.{Minor}.{Build}` (network.md:
/// `V.3.20.9` = ReleaseType V, Major 3, Minor 0x14, Build 0x9; changelog-3.2.0
/// §1: minor 10->20, build 14->9). The client's `TryParseSerializedString`
/// requires `Split('.')` to yield exactly 4 fields, so the spaced display
/// form above trips a parse warning. The login package's versionLong stays
/// the display form (`V 3.2.0`, protocol.md VersionLongString packing).
pub const stock_wire_gsi_version = "V.3.20.9";

/// `VersionInformation.LongStringNoBuild` for the supported wire. The IL
/// reading (`String.Format("{0} {1}.{2}", ReleaseType, Major, Minor)` with
/// the raw Minor, asm.il IL_00BE) suggests "V 3.20", but the EMPIRICALLY
/// VERIFIED stock behavior on V3.1.0 b14 (network.md login-version-gate
/// section, live captures 2026-08-22/23) is the display form: the real
/// client sends "V 3.1.0" for both `version` and `compVersion` and the
/// authorizer accepts it, kicking "V 3.10" with VersionMismatch=4. The
/// 3.2.0 pin follows the same display form ("V 3.2.0", changelog-3.2.0 §1);
/// a live 3.2.0 capture has not re-probed the gate, so this is inferred,
/// not yet live-verified. zdtd mirrors the observed gate; a loadgen join
/// with "V 3.2.0" must PASS.
pub const stock_wire_comp = "V 3.2.0";
