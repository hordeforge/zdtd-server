//! C2S sign-library packages (V3.3.0 b18): `NetPackageSingleSignData` and
//! `NetPackageSignDelete`, the one-way pushes that replace the removed
//! per-sign request/response (RE protocol-packages.md §1.5.2/§1.5.3,
//! gameplay/signs.md §7).
//!
//! The server relays both to every other client. Upload (`SingleSignData`) is
//! sender-checked, a deliberate divergence from stock: `ProcessSignReceived`
//! never reads `Sender` and accepts a blob into any player library (signs.md
//! §7). zdtd refuses a write whose library is not the sender's own, so a peer
//! cannot poison another player's library or a prefab library (DIVERGENCES
//! 1.18). Deletes are ownership-checked the same way (§6).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const stock_sign = packages.stock_sign;
const log = @import("../../util/log.zig");
/// The "not a shared library" ids (`SignDataManager..cctor` IL=14): `[I]`
/// (editor) and `[U]` (user). They never accept a delete and never relay as
/// player content (signs.md §3).
fn isLocalLibraryId(lib: []const u8) bool {
    return std.mem.eql(u8, lib, "[I]") or std.mem.eql(u8, lib, "[U]");
}

/// `SignDataManager.IsPlayerLibraryId` IL=17: a per-player library is a
/// non-empty id that is neither local nor `[D]` and parses as
/// `<platform>_<id>` (an arbitrary client string fails). `max_combined` bounds
/// the returned slice into `out`.
fn isPlayerLibraryId(lib: []const u8) bool {
    if (lib.len == 0) return false;
    if (isLocalLibraryId(lib)) return false;
    if (std.mem.eql(u8, lib, "[D]")) return false;
    // Must split into a non-empty platform and non-empty id on '_'.
    var sep: ?usize = null;
    for (lib, 0..) |ch, i| {
        if (ch == '_') {
            sep = i;
            break;
        }
    }
    const s = sep orelse return false;
    return s > 0 and s + 1 < lib.len;
}

/// The sender's player-library id, the `InternalId.CombinedString()`
/// `<platform>_<id>` form (platform-auth.md §2.1). Null when the peer has no
/// platform identity.
fn senderLibraryId(c: *const Client, out: []u8) ?[]const u8 {
    const pid = c.puid_primary.get() orelse return null;
    return std.fmt.bufPrint(out, "{s}_{s}", .{ pid.platform, pid.id }) catch null;
}

/// The 16-byte sign guid at the head of a `SignData` blob (`version i32` then
/// `guid`, signs.md §2). Null when the blob is too short to carry both.
fn signGuid(blob: []const u8) ?[16]u8 {
    if (blob.len < 4 + 16) return null;
    var g: [16]u8 = undefined;
    @memcpy(&g, blob[4..][0..16]);
    return g;
}

/// True when `name` is a sign-library package and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackageSingleSignData")) {
        var lib_buf: [160]u8 = undefined;
        const pkg = stock_sign.parseSingleSignData(body, &lib_buf) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        // Stock logs and ignores an empty blob (§1.5.2); nothing to relay.
        if (pkg.blob.len == 0) return true;
        // Sender check, the thing stock's upload path omits (signs.md §7): a
        // client may only write its own player library. Local libraries
        // (`[I]`, `[U]`) and `[D]` are stock editor/default content, and a
        // prefab library is server-side editor state (§3), so an id that is
        // not a player library is refused outright. Anything else that is not
        // the sender's own id (another player, or a prefab name that happens
        // to parse as one) is an ownership reject. Both are silent drops: no
        // store write, no relay, counted and logged like the delete refusals.
        if (isLocalLibraryId(pkg.library_id) or std.mem.eql(u8, pkg.library_id, "[D]") or !isPlayerLibraryId(pkg.library_id)) {
            self.harness.counters.inc(.c2s_rejects);
            const n = self.harness.counters.get(.c2s_rejects);
            log.warnEvery(n, "sign upload to non-player library '{s}' rejected local_id={d}\n", .{ pkg.library_id, peer.local_id });
            return true;
        }
        var mine_buf: [160]u8 = undefined;
        const mine = senderLibraryId(c, &mine_buf) orelse {
            // A peer with no platform identity owns no player library.
            self.harness.counters.inc(.ownership_rejects);
            return true;
        };
        if (!std.mem.eql(u8, pkg.library_id, mine)) {
            self.harness.counters.inc(.ownership_rejects);
            const n = self.harness.counters.get(.ownership_rejects);
            log.warnEvery(n, "sign upload to foreign library '{s}' rejected sender='{s}' local_id={d}\n", .{ pkg.library_id, mine, peer.local_id });
            return true;
        }
        // Store the opaque blob under (library, guid): the blob head is
        // `version i32 | guid 16` (signs.md §2). The upsert keys on the guid
        // so a re-draw replaces the same sign; only the owner reaches here.
        if (signGuid(pkg.blob)) |guid| {
            const stored = self.player_signs.put(pkg.library_id, &guid, pkg.blob);
            if (stored == null) {
                // A full or oversized store refuses the push (recorded, not a
                // silent drop); stock caps the deleted store too.
                self.harness.counters.inc(.c2s_rejects);
            }
        }
        self.broadcastExcept("NetPackageSingleSignData", body, c.slot) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            const n = self.harness.counters.get(.net_send_errors);
            log.warnEvery(n, "sign upload relay failed: {s}\n", .{@errorName(err)});
        };
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSignDelete")) {
        var lib_buf: [160]u8 = undefined;
        const pkg = stock_sign.parseSignDelete(body, &lib_buf) catch {
            self.harness.counters.inc(.c2s_malformed);
            return true;
        };
        const lib = pkg.library_id;
        // Refusals (§6), each logged and dropped: a local library, `[D]`, or a
        // player library the sender does not own. Prefab-library deletes are
        // gated on PrefabEditMode, which zdtd has no C2S surface for, so they
        // pass the id checks and relay.
        if (isLocalLibraryId(lib) or std.mem.eql(u8, lib, "[D]")) {
            self.harness.counters.inc(.c2s_rejects);
            return true;
        }
        if (isPlayerLibraryId(lib)) {
            var mine_buf: [160]u8 = undefined;
            const mine = senderLibraryId(c, &mine_buf) orelse {
                // A peer with no platform identity owns no player library.
                self.harness.counters.inc(.c2s_rejects);
                return true;
            };
            if (!std.mem.eql(u8, lib, mine)) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        // Drop it from the store so the next join no longer serves it (the
        // relay still tells the live clients).
        _ = self.player_signs.remove(lib, &pkg.sign_guid);
        self.broadcastExcept("NetPackageSignDelete", body, c.slot) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            const n = self.harness.counters.get(.net_send_errors);
            log.warnEvery(n, "sign delete relay failed: {s}\n", .{@errorName(err)});
        };
        return true;
    }
    return false;
}
