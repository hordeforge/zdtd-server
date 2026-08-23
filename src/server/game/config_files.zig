//! Config-file S2C: stock `SendXmlsToClient` / `NetPackageConfigFile`
//! (`../7dtd-engine-research/docs/mod-loading.md` §5.6, `protocol-packages.md`
//! IL=25). Patched config bytes are Deflate-cached once at init
//! (serialize-once, PRD R8); the join send streams name + len + blob per row.
//!
//! Divergence from stock (documented in PRD §6 R9): stock skips rows whose
//! cache is null; zdtd sends `-1` instead so a vanilla client's
//! `WaitForConfigsFromServer` always completes, falling back to local files.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const wire_frame = @import("../../wire/frame.zig");
const packages = @import("../../wire/packages.zig");
const paths = @import("../../assets/paths.zig");
const flate = std.compress.flate;

/// Cap per deflated config blob. The DeflateFramer writes into `body_buf`
/// (512 KiB); deflate of already-deflated data is nearly incompressible, so
/// the framed output is ~blob + envelope. A bigger patched config refuses to
/// start rather than silently truncating what the client `Read`s (PRD R12).
pub const max_config_blob_len: usize = 384 * 1024;

/// The 42 `SendToClients=true` rows of `xmlsToLoad`
/// (`../7dtd-engine-research/docs/inventories/xmlsToLoad.md`). `archetypes` is
/// `LoadClientFile` (name-only, RE §5.6). Never sent: rwgmixer, gamestages,
/// spawning, signs, loadingscreen, subtitles, videos.
const s2c_names = [_][]const u8{
    "events",               "materials",          "physicsbodies",   "painting",          "shapes",               "blocks",
    "progression",          "buffs",              "misc",            "items",             "item_modifiers",       "entityclasses",
    "qualityinfo",          "sounds",             "recipes",         "blockplaceholders", "loot",                 "entitygroups",
    "utilityai",            "vehicles",           "weathersurvival", "archetypes",        "challenges",           "quests",
    "traders",              "npc",                "dialogs",         "ui_display",        "nav_objects",          "gameevents",
    "twitch",               "twitch_events",      "dmscontent",      "XUi_Common/styles", "XUi_Common/templates", "XUi_InGame/styles",
    "XUi_InGame/templates", "XUi_InGame/windows", "XUi_InGame/xui",  "biomes",            "worldglobal",          "sandbox_overrides",
};

/// One cached S2C row: raw-Deflate(patched xml). Empty = send name-only (-1).
const Blob = struct {
    data: []u8 = &.{},
};

var cache: [s2c_names.len]Blob = [_]Blob{.{}} ** s2c_names.len;
var cache_built = false;

pub fn deinitCache(allocator: std.mem.Allocator) void {
    for (&cache) |*b| {
        if (b.data.len > 0) allocator.free(b.data);
        b.data = &.{};
    }
    cache_built = false;
}

/// Raw-Deflate `src` into an owned buffer. A result that does not fit the
/// blob cap fails with `error.ConfigBlobTooLarge` (never truncate, PRD R12).
fn deflateBlob(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const sink_cap = max_config_blob_len + 1024;
    const out_buf = try allocator.alloc(u8, sink_cap);
    defer allocator.free(out_buf);
    var window: [flate.max_window_len]u8 = undefined;
    var sink: std.Io.Writer = .fixed(out_buf);
    var comp = flate.Compress.init(&sink, &window, .raw, .default) catch return error.Overflow;
    comp.writer.writeAll(src) catch return error.ConfigBlobTooLarge;
    comp.finish() catch return error.ConfigBlobTooLarge;
    return try allocator.dupe(u8, out_buf[0..sink.end]);
}

/// Build the Deflate cache from the same patched bytes the loaders use
/// (`paths.readConfigXml`, PRD R7). Init/load-time only; alloc allowed.
/// Mod-patch failures are already fatal inside readConfigXml (PRD R6); a
/// missing base file is a skip (row sends -1), like stock's null cache.
pub fn buildCache(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !void {
    if (cache_built) return;
    var name_buf: [128]u8 = undefined;
    for (s2c_names, 0..) |name, idx| {
        if (std.mem.eql(u8, name, "archetypes")) continue; // LoadClientFile: name-only
        const file_name = std.fmt.bufPrint(&name_buf, "{s}.xml", .{name}) catch continue;
        const patched = paths.readConfigXml(allocator, file_name, game_dir, config_dir) catch |err| {
            std.debug.print("zdtd: config cache {s} failed: {s}\n", .{ name, @errorName(err) });
            return err;
        } orelse continue;
        defer allocator.free(patched);
        const blob = deflateBlob(allocator, patched) catch |err| {
            std.debug.print(
                "zdtd: config cache deflate {s} failed: {s} ({d} raw bytes)\n",
                .{ name, @errorName(err), patched.len },
            );
            return err;
        };
        cache[idx] = .{ .data = blob };
    }
    cache_built = true;
    var blobs: usize = 0;
    for (&cache) |*b| {
        if (b.data.len > 0) blobs += 1;
    }
    std.debug.print("zdtd: config s2c cache rows={d}/{d}\n", .{ blobs, s2c_names.len });
}

/// Join-phase config shipping (stock `SendXmlsToClient`, after localization
/// start and before WorldInfo; c2s/join.zig calls this at the right point).
/// One Deflate-framed package per row, like `sendBlockIdMapping`.
pub fn sendLocalConfigFiles(self: *Game, peer: *ln_peer.Peer) !void {
    for (s2c_names, 0..) |name, idx| {
        const blob = cache[idx].data;
        // All 42 names are < 128 chars, so the 7-bit length is one byte.
        comptime {
            var longest: usize = 0;
            for (s2c_names) |n| longest = @max(longest, n.len);
            std.debug.assert(longest < 0x80);
        }
        const body_len = 1 + name.len + 4 + blob.len;
        var fr: wire_frame.DeflateFramer = undefined;
        fr.begin(&self.body_buf, &self.deflate_window, 0, packages.idOf("NetPackageConfigFile").?, body_len) catch |err| {
            std.debug.print("zdtd: config file frame init failed for {s}: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        const w = fr.writer();
        w.writeByte(@intCast(name.len)) catch {
            std.debug.print("zdtd: config file frame write failed for {s}\n", .{name});
            return error.Overflow;
        };
        w.writeAll(name) catch return error.Overflow;
        if (blob.len > 0) {
            w.writeInt(i32, @intCast(blob.len), .little) catch return error.Overflow;
            w.writeAll(blob) catch return error.Overflow;
        } else {
            w.writeInt(i32, -1, .little) catch return error.Overflow;
        }
        const framed = fr.finish() catch |err| {
            std.debug.print("zdtd: config file {s} deflate failed: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        self.sendFramedReliable(peer, "NetPackageConfigFile", framed, game_mod.critical_retry_budget_ns, true) catch |err| {
            std.debug.print("zdtd: config file {s} send failed: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        // Flush per row so the client's config wait makes progress between the
        // 42 packages (same pacing as the pre-cache advertisement loop).
        peer.resendPending(&self.net.sock) catch self.harness.counters.inc(.net_send_errors);
        self.pollNetOnce();
    }
}
