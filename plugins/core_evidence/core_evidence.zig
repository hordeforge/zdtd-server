// core_evidence - sample `on_evidence` observer (T21).
//
// The guard's evidence ring is the honest "seen it" record (AUTHORITY.md
// observe records but never denies). This guest is the reference
// implementation of the hook: it logs each finding so an operator can see
// the detector, severity and surface stream without opening the admin
// console. It does not judge, score or deny - that stays in `guard_policy`.
//
// All formatting is the mod's own; the `log` verb is the protocol.

const std = @import("std");
const common = @import("plugin_common");

var out: common.Buf = .{};

/// `on_evidence(tick, peer_local, entity_id, detector, severity, surface,
/// observed_bits, bound_bits)` (src/plugin/api.zig:70). observed_bits and
/// bound_bits are f32 bit patterns, so the sample prints the raw bits rather
/// than guessing a decode.
export fn on_evidence(
    tick: i32,
    peer_local: i32,
    entity_id: i32,
    detector: i32,
    severity: i32,
    surface: i32,
    observed_bits: i32,
    bound_bits: i32,
) void {
    out.reset();
    out.put("evidence tick=");
    out.putInt(tick);
    out.put(" peer=");
    out.putInt(peer_local);
    out.put(" ent=");
    out.putInt(entity_id);
    out.put(" det=");
    out.putInt(detector);
    out.put(" sev=");
    out.putInt(severity);
    out.put(" surf=");
    out.putInt(surface);
    out.put(" obs=");
    out.putInt(observed_bits);
    out.put(" bound=");
    out.putInt(bound_bits);
    out.logLine(0);
}

export fn on_enable() void {}
export fn on_shutdown() void {}

comptime {
    common.exportRequires("on_evidence,log");
}
