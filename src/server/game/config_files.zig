//! Config-file S2C: stock `SendXmlsToClient` / `NetPackageConfigFile`
//! (`../7dtd-engine-research/docs/admin/mod-loading.md` §5.6, `protocol-packages.md`
//! IL=25). Patched config bytes are Deflate-cached once at init
//! (serialize-once, PRD R8); the join send streams name + len + blob per row.
//!
//! Divergence from stock (documented in PRD §6 R9): stock skips rows whose
//! cache is null; zdtd sends `-1` instead so a vanilla client's
//! `WaitForConfigsFromServer` always completes, falling back to local files.

const std = @import("std");
const game_mod = @import("../game.zig");
const Client = game_mod.Client;
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const game_net = @import("net.zig");
const wire_frame = @import("../../wire/frame.zig");
const packages = @import("../../wire/packages.zig");
const protocol = @import("../../protocol.zig");
const paths = @import("../../assets/paths.zig");
const flate = std.compress.flate;
const clock = @import("../../util/clock.zig");
const assets_localization = @import("../../assets/localization.zig");

/// Cap per deflated config blob. The DeflateFramer writes into `body_buf`
/// (512 KiB); deflate of already-deflated data is nearly incompressible, so
/// the framed output is ~blob + envelope. A bigger patched config refuses to
/// start rather than silently truncating what the client `Read`s (PRD R12).
pub const max_config_blob_len: usize = 384 * 1024;

/// 42 of the stock `xmlsToLoad` rows (49 total per
/// `../7dtd-engine-research/docs/inventories/xmlsToLoad.md`: the
/// `SendToClients`-flagged set plus the clientFile/XUi rows). `archetypes` is
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

/// NetPackageIdMapping row name for the item id space (stock `ldstr items`,
/// `RequestToEnterGame` IL_0207). One byte as a 7-bit length.
const map_items_name = "items";

/// Cap on the raw item NameIdMapping blob. The stock catalog lands near 40 KB;
/// the cap only exists so a catalog that somehow explodes skips the send (the
/// client then keeps the map it built from items.xml) instead of shipping a
/// mapping the client reads as complete.
pub const max_item_idmap_len: usize = 128 * 1024;

/// One cached S2C row: raw-Deflate(patched xml). Empty = send name-only (-1).
const Blob = struct {
    data: []u8 = &.{},
};

/// The cached blobs live on the Game, not in module scope: the rows are
/// built from that Game's game_dir/config_dir inputs, so a process-global
/// latch would let a second Game in the same process silently reuse (or skip
/// rebuilding) another instance's data (paper: shared mutable state belongs
/// to the context that owns the inputs). Game teardown frees it.
pub const Cache = struct {
    rows: [s2c_names.len]Blob = [_]Blob{.{}} ** s2c_names.len,
    built: bool = false,
};

pub fn deinitCache(self: *Game) void {
    for (&self.config_cache.rows) |*b| {
        if (b.data.len > 0) self.allocator.free(b.data);
        b.data = &.{};
    }
    self.config_cache.built = false;
}

/// Raw-Deflate `src` into an owned buffer. A result that does not fit the
/// blob cap fails with `error.ConfigBlobTooLarge` (never truncate, PRD R12).
fn deflateBlob(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    // One byte of slack past the cap so an exactly-at-cap blob still fits and
    // an over-cap one is rejected by the explicit check, not by a writer
    // overflow that cannot tell "too large" from "encoder broke".
    const out_buf = try allocator.alloc(u8, max_config_blob_len + 1);
    errdefer allocator.free(out_buf);
    var window: [flate.max_window_len]u8 = undefined;
    var sink: std.Io.Writer = .fixed(out_buf);
    var comp = flate.Compress.init(&sink, &window, .raw, .default) catch return error.Overflow;
    comp.writer.writeAll(src) catch return error.ConfigBlobTooLarge;
    comp.finish() catch return error.ConfigBlobTooLarge;
    if (sink.end > max_config_blob_len) return error.ConfigBlobTooLarge;
    return try allocator.realloc(out_buf, sink.end);
}

/// Build the Deflate cache from the same patched bytes the loaders use
/// (`paths.readConfigXml`, PRD R7). Init/load-time only; alloc allowed.
/// Mod-patch failures are already fatal inside readConfigXml (PRD R6); a
/// missing base file is a skip (row sends -1), like stock's null cache.
pub fn buildCache(self: *Game, allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !void {
    if (self.config_cache.built) return;
    var name_buf: [128]u8 = undefined;
    for (s2c_names, 0..) |name, idx| {
        if (std.mem.eql(u8, name, "archetypes")) continue; // LoadClientFile: name-only
        const file_name = std.fmt.bufPrint(&name_buf, "{s}.xml", .{name}) catch continue;
        const patched = paths.readConfigXml(allocator, file_name, game_dir, config_dir) catch |err| {
            std.debug.print("zdtd: config cache {s} failed: {s}\n", .{ name, @errorName(err) });
            // Drop any rows already stored so a retry starts clean and the
            // process-global blobs cannot accumulate across failed builds.
            deinitCache(self);
            return err;
        } orelse continue;
        defer allocator.free(patched);
        const blob = deflateBlob(allocator, patched) catch |err| {
            std.debug.print(
                "zdtd: config cache deflate {s} failed: {s} ({d} raw bytes)\n",
                .{ name, @errorName(err), patched.len },
            );
            deinitCache(self);
            return err;
        };
        self.config_cache.rows[idx] = .{ .data = blob };
    }
    self.config_cache.built = true;
    var blobs: usize = 0;
    for (&self.config_cache.rows) |*b| {
        if (b.data.len > 0) blobs += 1;
    }
    std.debug.print("zdtd: config s2c cache rows={d}/{d}\n", .{ blobs, s2c_names.len });
}

/// Join-phase localization shipping (stock `RequestToEnterGame` IL_0222:
/// `NetPackageLocalization.StartSendingPacketsToClient`, between the id
/// mapping and `SendXmlsToClient`). The patched CSV is raw-Deflated once and
/// split into stock's 128 KiB parts; the frame itself stays uncompressed
/// (`NetPackageLocalization.get_Compress` IL=2 returns false), which `sendGame`
/// already decides by package name.
pub fn sendLocalization(self: *Game, peer: *ln_peer.Peer) !void {
    if (self.localization.isEmpty()) return;
    const blob = self.localization.deflatedCsv(self.allocator) catch |err| {
        std.debug.print("zdtd: localization deflate failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const total: u32 = @intCast((blob.len + assets_localization.part_size - 1) / assets_localization.part_size);
    // GamePref 189: pace the download. Stock's localization sender is a
    // coroutine that ships one 128 KiB chunk per
    // `WaitForSeconds(chunk_bytes / (pref * 1024))`; zdtd has no coroutine, so
    // the same rate becomes one part per `localizationTicksPerPart` ticks,
    // drained by the tick's client pass. `<= 0` keeps the unthrottled send.
    const client: ?*Client = game_net.clientFor(self, peer);
    if (self.server_max_world_transfer_speed_kibs > 0 and client != null) {
        const c = client.?;
        if (c.loc_blob.len > 0) self.allocator.free(c.loc_blob);
        c.loc_blob = blob;
        c.loc_parts_sent = 0;
        c.loc_parts_total = total;
        c.loc_next_tick = self.tick_n;
        // The first part lands with the join; the rest follow at the cap.
        try sendLocalizationPart(self, c, 0);
        c.loc_parts_sent = 1;
        c.loc_next_tick = self.tick_n + localizationTicksPerPart(self.server_max_world_transfer_speed_kibs);
        return;
    }
    defer self.allocator.free(blob);
    var seq: u32 = 0;
    while (seq < total) : (seq += 1) {
        try sendLocalizationPartRaw(self, peer, blob, seq, total);
    }
    self.harness.counters.inc(.packages_encoded);
}

/// `NetPackageLocalization.prepareDataPackets` IL=107: `PACKET_SEND_DELAY =
/// WaitForSeconds(131072 / (pref * 1024))` between 128 KiB parts, expressed here
/// as whole ticks (at 20 TPS). `pref <= 0` disables the pacing, which the caller
/// handles by sending inline; this returns at least 1 so a tiny cap can never
/// send two parts in one tick.
pub fn localizationTicksPerPart(pref_kibs: i32) u64 {
    if (pref_kibs <= 0) return 1;
    // `delay = part_bytes / (pref * 1024)` seconds; in ticks that is
    // `part_bytes * ticks_per_second / (pref * 1024)`, rounded up so the
    // average rate never exceeds the cap.
    const part: u64 = assets_localization.part_size;
    const per_sec: u64 = @as(u64, @intCast(pref_kibs)) * 1024;
    return @max(1, (part * protocol.ticks_per_second + per_sec - 1) / per_sec);
}

/// Send one part of a queued localization blob to its client.
fn sendLocalizationPart(self: *Game, c: *Client, seq: u32) !void {
    const peer = c.peer orelse return;
    try sendLocalizationPartRaw(self, peer, c.loc_blob, seq, c.loc_parts_total);
}

fn sendLocalizationPartRaw(self: *Game, peer: *ln_peer.Peer, blob: []const u8, seq: u32, total: u32) !void {
    const start = @as(usize, seq) * assets_localization.part_size;
    if (start >= blob.len) return;
    const end = @min(start + assets_localization.part_size, blob.len);
    const body = packages.buildLocalizationBody(
        self.body_buf[0 .. end - start + 16],
        @intCast(seq),
        @intCast(total),
        blob[start..end],
    ) catch |err| {
        std.debug.print("zdtd: localization body failed: {s}\n", .{@errorName(err)});
        return err;
    };
    self.sendGameCritical(peer, "NetPackageLocalization", body) catch |err| {
        std.debug.print("zdtd: localization part {d}/{d} send failed: {s}\n", .{ seq, total, @errorName(err) });
        return err;
    };
    self.harness.counters.inc(.packages_encoded);
}

/// Tick-pass half of the paced localization download: ship the next part when
/// its tick arrives. The queue is freed when the last part goes out, so a
/// finished download costs nothing.
pub fn drainLocalization(self: *Game, c: *Client) void {
    if (c.loc_blob.len == 0) return;
    if (self.tick_n < c.loc_next_tick) return;
    if (c.loc_parts_sent >= c.loc_parts_total) {
        finishLocalization(self, c);
        return;
    }
    sendLocalizationPart(self, c, c.loc_parts_sent) catch {
        // A failed send keeps the part queued; the next window retries.
        c.loc_next_tick = self.tick_n + localizationTicksPerPart(self.server_max_world_transfer_speed_kibs);
        return;
    };
    c.loc_parts_sent += 1;
    c.loc_next_tick = self.tick_n + localizationTicksPerPart(self.server_max_world_transfer_speed_kibs);
    if (c.loc_parts_sent >= c.loc_parts_total) finishLocalization(self, c);
}

/// Drop a queued download (completed, or the peer left).
pub fn finishLocalization(self: *Game, c: *Client) void {
    if (c.loc_blob.len == 0) return;
    self.allocator.free(c.loc_blob);
    c.loc_blob = &.{};
    c.loc_parts_sent = 0;
    c.loc_parts_total = 0;
    c.loc_next_tick = 0;
}

/// Join-phase config shipping (stock `SendXmlsToClient`, after localization
/// start and before WorldInfo; c2s/join.zig calls this at the right point).
/// One Deflate-framed package per row, like `sendBlockIdMapping`.
pub fn sendLocalConfigFiles(self: *Game, peer: *ln_peer.Peer) !void {
    for (s2c_names, 0..) |name, idx| {
        const blob = self.config_cache.rows[idx].data;
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

pub fn sendBlockIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
    if (!self.block_id_mapping) return;
    const nameid = packages.stock_nameid;
    if (self.maxdamage.idNameCount() == 0) {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} blocks IdMapping skipped (no AssignIds dump loaded)\n", .{clock.wallStamp(&ts)});
        return;
    }
    const summary = nameid.measure(self.maxdamage.idNameIterator(), &self.nameid_seen) catch |err| {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} blocks IdMapping measure failed ({s})\n", .{ clock.wallStamp(&ts), @errorName(err) });
        return err;
    };

    // NetPackageIdMapping body: name | i32 dataLen | data (asm.il 822416-822438).
    const map_name = "blocks";
    // One-byte 7-bit length prefix; the writer below emits exactly one byte.
    comptime std.debug.assert(map_name.len < 0x80);
    const body_len = 1 + map_name.len + 4 + summary.bytes;
    // Framed into body_buf, not send_buf: the deflated mapping lands around
    // 255 KiB, which leaves no headroom in the 256 KiB send_buf if the dump
    // grows. body_buf is 512 KiB and idle here (the config files that use it
    // are sent after this returns).
    var fr: wire_frame.DeflateFramer = undefined;
    fr.begin(&self.body_buf, &self.deflate_window, 0, packages.idOf("NetPackageIdMapping").?, body_len) catch |err| {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} blocks IdMapping frame init failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
        return err;
    };
    const w = fr.writer();
    const ok = blk: {
        w.writeByte(@intCast(map_name.len)) catch break :blk false;
        w.writeAll(map_name) catch break :blk false;
        w.writeInt(i32, @intCast(summary.bytes), .little) catch break :blk false;
        nameid.write(w, self.maxdamage.idNameIterator(), summary) catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        var ts: [19]u8 = undefined;
        std.debug.print(
            "zdtd: {s} blocks IdMapping does not fit body_buf ({d} raw bytes)\n",
            .{ clock.wallStamp(&ts), summary.bytes },
        );
        return error.Overflow;
    }
    const framed = fr.finish() catch |err| {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} blocks IdMapping deflate failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
        return err;
    };
    self.sendFramedReliable(peer, "NetPackageIdMapping", framed, game_mod.critical_retry_budget_ns, true) catch |err| {
        var ts: [19]u8 = undefined;
        std.debug.print("zdtd: {s} blocks IdMapping send failed: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
        return err;
    };
    std.debug.print(
        "zdtd: blocks IdMapping objs={d} raw={d} wire={d}\n",
        .{ summary.count, summary.bytes, framed.len },
    );
}

/// Stock `ItemClass::createFullMappingForClients` (ItemClass.il.txt:4530,
/// `nameToItem` -> `ItemData.Id` for every loaded item) ships the WHOLE item
/// id space to the joining client, and `GameManager::IdMappingReceived`
/// (GameManager.il.txt:9862 IL_0049-0065) REPLACES `ItemClass::nameIdMapping`
/// wholesale with the blob that arrives - it is not merged into whatever the
/// client parsed from items.xml. The old 12-row ECS-builtin stub therefore
/// handed the client a mapping with 12 of ~1400 ids in it; the client recovers
/// lazily (`ItemValue` IL_0309 re-adds an id it meets), so it mostly showed up
/// as id drift on a modded catalog.
pub fn sendItemIdMapping(self: *Game, peer: *ln_peer.Peer) !void {
    if (self.items.stock_names.len == 0) {
        // No items.xml (offline/builtin catalogs): there is no full map to send
        // and a header-only blob would leave the client with an EMPTY id space.
        return;
    }
    const payload = self.items.writeNameIdMapping(self.item_idmap_buf[0..max_item_idmap_len]) catch |err| {
        std.debug.print("zdtd: items IdMapping does not fit {d} bytes ({s}); skipping (the client keeps its local map)\n", .{ max_item_idmap_len, @errorName(err) });
        return;
    };
    // NetPackageIdMapping body: name | i32 len | blob (asm.il 822416-822438).
    // Stock's `get_Compress` is true (IL=2), so the row rides the DeflateFramer
    // like the blocks mapping.
    const body_len = 1 + map_items_name.len + 4 + payload.len;
    var fr: wire_frame.DeflateFramer = undefined;
    fr.begin(&self.body_buf, &self.deflate_window, 0, packages.idOf("NetPackageIdMapping").?, body_len) catch |err| {
        std.debug.print("zdtd: items IdMapping frame init failed: {s}\n", .{@errorName(err)});
        return err;
    };
    const w = fr.writer();
    w.writeByte(@intCast(map_items_name.len)) catch return error.Overflow;
    w.writeAll(map_items_name) catch return error.Overflow;
    w.writeInt(i32, @intCast(payload.len), .little) catch return error.Overflow;
    w.writeAll(payload) catch return error.Overflow;
    const framed = fr.finish() catch |err| {
        std.debug.print("zdtd: items IdMapping deflate failed: {s}\n", .{@errorName(err)});
        return err;
    };
    self.sendFramedReliable(peer, "NetPackageIdMapping", framed, game_mod.critical_retry_budget_ns, true) catch |err| {
        std.debug.print("zdtd: items IdMapping send failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("zdtd: items IdMapping objs={d} raw={d} wire={d}\n", .{
        self.items.stock_names.len, payload.len, framed.len,
    });
}

test "deflateBlob rejects a blob past the cap instead of shipping it" {
    const gpa = std.testing.allocator;

    const small = try deflateBlob(gpa, "<configs><a/><b/></configs>");
    defer gpa.free(small);
    try std.testing.expect(small.len > 0);
    try std.testing.expect(small.len <= max_config_blob_len);

    // Seeded noise is incompressible, so raw Deflate lands just past its
    // input: 1 MiB of it must trip the cap, not silently ride out on the
    // sink's slack and desync the client's BinaryReader.
    const noise = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(noise);
    var prng = std.Random.DefaultPrng.init(0x7d7d);
    prng.random().bytes(noise);
    try std.testing.expectError(error.ConfigBlobTooLarge, deflateBlob(gpa, noise));
}
