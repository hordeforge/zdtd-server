//! Operator console surface: admin TCP + webui command handling, the stock
//! telnet reply shapes, persistent operator lists, and the guard/gamestage
//! admin replies.
//!
//! Extracted from game.zig (which had grown past 13k lines) following the
//! replicate_te precedent: these take `*Game` as the first parameter because a
//! Zig method has to be declared inside the struct and `usingnamespace` is
//! gone. Call them as `admin_console.runAdminLine(g, …)`. game.zig keeps
//! one-line delegating methods so existing callers (tests, webui, main) are
//! unchanged.

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const admin_mod = @import("admin.zig");
const webui_mod = @import("webui.zig");
const io_fs = @import("../util/io_fs.zig");
const clock = @import("../util/clock.zig");
const ln_peer = @import("../litenet/peer.zig");
const admin_cmds = @import("admin_cmds.zig");
const c2s_text = @import("c2s_text.zig");
const protocol = @import("../protocol.zig");
const version = @import("../version.zig");
const systems = @import("../ecs/systems.zig");
const max_clients = game_mod.max_clients;
const peerIpKey = game_mod.Game.peerIpKey;
const logPersistErr = game_mod.logPersistErr;
const admin_help_index = game_mod.admin_help_index;
const isPlayerConsoleCommand = c2s_text.isPlayerConsoleCommand;
const eqAny = c2s_text.eqAny;
const apm = @import("../apm/root.zig");
const world_store = @import("../world/store.zig");
const chatMsgOk = c2s_text.chatMsgOk;
const ecs = @import("../ecs/root.zig");
const packages = @import("../wire/packages.zig");
const assets_gamestages = @import("../assets/gamestages.zig");

pub fn pollAdmin(self: *Game) void {
    const chunk = self.admin.pollLine(&self.admin_line) orelse return;
    // One read may carry several newline-separated commands (piped input).
    var it = std.mem.tokenizeAny(u8, chunk, "\r\n");
    while (it.next()) |line| {
        // TCP-session-only: closing a session makes no sense on the webui path.
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) {
            self.admin.reply("bye\n");
            self.admin.closeActive();
            return;
        }
        self.runAdminLine(line, "admin_tcp");
    }
}

/// Admin TCP + optional webui sink (same text both paths).
pub fn adminReply(self: *Game, text: []const u8) void {
    self.admin.reply(text);
    if (self.admin_reply_sink) |sink| {
        const room = sink.len -% self.admin_reply_len;
        if (room == 0) return;
        const n = c2s_text.utf8TruncLen(text, room);
        @memcpy(sink[self.admin_reply_len..][0..n], text[0..n]);
        self.admin_reply_len += n;
    }
}

pub fn pollWebui(self: *Game) void {
    // Drain up to 4 queued console lines (same path as admin TCP).
    var drain_i: u32 = 0;
    while (drain_i < 4) : (drain_i += 1) {
        var line_buf: [webui_mod.max_cmd_line]u8 = undefined;
        const line = self.webui.takeCmd(&line_buf) orelse break;
        self.admin_reply_len = 0;
        self.admin_reply_sink = self.webui.cmd_out_buf[0..];
        self.runAdminLine(line, "webui");
        self.admin_reply_sink = null;
        self.webui.finishCmd(self.webui.cmd_out_buf[0..self.admin_reply_len]);
    }
    // Non-blocking HTTP; at most one request per poll call.
    self.webui.poll();
}

/// Copy live ops gauges into webui snapshot (call after step returns).
/// Writes in-place into webui.snap (no large stack frame).
pub fn fillWebuiSnap(self: *Game) void {
    if (!self.webui.enabled()) return;
    // Browser partials poll at >= 2s; rebuilding the snapshot (7 entity
    // scans + histogram percentiles) every tick is 10x wasted work.
    if (self.tick_n % 10 != 0) return;
    const s = &self.webui.snap;
    // Zero in place (avoid stack temp Snapshot which overflows step's frame).
    @memset(std.mem.asBytes(s), 0);
    s.tick_n = self.tick_n;
    s.last_tick_ns = clock.monoNs(); // readiness: wedged-loop detection
    const clk = self.sim.director.clock;
    s.day = clk.day;
    s.hours = clk.hours;
    s.bloodmoon_active = self.sim.director.bloodmoon_active;
    s.joined = self.countJoined();
    s.max_players = self.max_players;
    var entered_n: u16 = 0;
    var peers_alive: u16 = 0;
    for (&self.clients) |cl| {
        if (cl.entered) entered_n += 1;
    }
    for (&self.net.peers) |p| {
        if (p.alive) peers_alive += 1;
    }
    s.entered = entered_n;
    s.peers_alive = peers_alive;
    s.zombies = @intCast(@min(self.sim.countKind(.zombie), 65535));
    s.animals = @intCast(@min(self.sim.countKind(.animal), 65535));
    s.traders = @intCast(@min(self.sim.countKind(.trader), 65535));
    s.vehicles = @intCast(@min(self.sim.countKind(.vehicle), 65535));
    s.turrets = @intCast(@min(self.sim.countKind(.turret), 65535));
    s.loot_bags = @intCast(@min(self.sim.countKind(.loot_bag), 65535));
    s.players_ent = @intCast(@min(self.sim.countKind(.player), 65535));
    s.chunks = @intCast(@min(self.world.chunks.count(), 0xffff_ffff));
    s.bloodmoon_frequency = self.sim.director.clock.bloodmoon_frequency;
    s.net_packets_in = self.harness.counters.get(.net_packets_in);
    s.net_packets_out = self.harness.counters.get(.net_packets_out);
    s.net_bytes_in = self.harness.counters.get(.net_bytes_in);
    s.net_bytes_out = self.harness.counters.get(.net_bytes_out);
    s.entities_ticked = self.harness.counters.get(.entities_ticked);
    s.tick_overruns = self.harness.counters.get(.tick_overruns);
    s.encode_errors = self.harness.counters.get(.encode_errors);
    s.stream_errors = self.harness.counters.get(.stream_errors);
    s.join_ok = self.harness.counters.get(.join_ok);
    s.join_fail = self.harness.counters.get(.join_fail);
    s.packages_encoded = self.harness.counters.get(.packages_encoded);
    s.packages_broadcast = self.harness.counters.get(.packages_broadcast);
    s.net_poll_errors = self.harness.counters.get(.net_poll_errors);
    s.net_payload_errors = self.harness.counters.get(.net_payload_errors);
    s.net_send_errors = self.harness.counters.get(.net_send_errors);
    s.reliable_window_drops = self.harness.counters.get(.reliable_window_drops);
    s.persistence_errors = self.harness.counters.get(.persistence_errors);
    s.stale_peers_reaped = self.harness.counters.get(.stale_peers_reaped);
    s.phase_rejects = self.harness.counters.get(.phase_rejects);
    s.ownership_rejects = self.harness.counters.get(.ownership_rejects);
    s.bounds_rejects = self.harness.counters.get(.bounds_rejects);
    s.movement_rejects = self.harness.counters.get(.movement_rejects);
    s.decode_rejects = self.harness.counters.get(.decode_rejects);
    const th = self.harness.prof.histOf(.tick_total);
    s.tick_mean_ns = th.meanNs();
    s.tick_p50_ns = th.percentileNs(50);
    s.tick_p99_ns = th.percentileNs(99);
    s.tick_max_ns = th.max_ns;
    const nh = self.harness.prof.histOf(.net_poll);
    s.net_mean_ns = nh.meanNs();
    s.net_p99_ns = nh.percentileNs(99);
    const sh = self.harness.prof.histOf(.sim_entities);
    s.sim_mean_ns = sh.meanNs();
    s.sim_p99_ns = sh.percentileNs(99);
    const rh = self.harness.prof.histOf(.replicate);
    s.repl_mean_ns = rh.meanNs();
    s.repl_p99_ns = rh.percentileNs(99);
    const ch = self.harness.prof.histOf(.chunk_stream);
    s.stream_mean_ns = ch.meanNs();
    s.stream_p99_ns = ch.percentileNs(99);
    s.save_mean_ns = self.harness.prof.histOf(.save_io).meanNs();
    s.view_radius = self.view_radius;
    s.max_streamed_chunks = @intCast(@min(self.max_streamed_chunks, 65535));
    s.interest_range = self.interest_range;
    s.max_edit_range = self.max_edit_range;
    s.max_spawned_zombies = @intCast(@min(self.sim.director.max_alive, 65535));
    s.info_port = self.info_port;
    s.webui_port = self.webui.port;
    s.authority_correct = self.authority_mode == .correct;
    s.password_set = self.password.len > 0;
    s.wire_chunks = self.wire_chunks;
    const wn = self.world_name;
    // World names come from config/CLI and may be non-ASCII: cut on a codepoint
    // boundary so the dashboard header is not mojibake.
    const ncopy = c2s_text.utf8TruncLen(wn, s.world_name.len);
    @memcpy(s.world_name[0..ncopy], wn[0..ncopy]);
    s.world_name_len = @intCast(ncopy);
    var pi: usize = 0;
    for (&self.clients, 0..) |cl, slot| {
        if (!cl.joined and cl.peer == null) continue;
        if (pi >= webui_mod.max_players_snap) break;
        var row: webui_mod.PlayerRow = .{
            .used = true,
            .slot = @intCast(slot),
            .entity_id = cl.entity_id,
            .joined = cl.joined,
            .entered = cl.entered,
        };
        const nl = @min(cl.name_len, webui_mod.max_name);
        @memcpy(row.name[0..nl], cl.name[0..nl]);
        row.name_len = @intCast(nl);
        if (cl.entity_id > 0) {
            if (self.sim.slotOfNetId(cl.entity_id)) |es| {
                if (self.sim.mask[es].transform) {
                    const t = self.sim.transform[es];
                    row.x = t.x;
                    row.y = t.y;
                    row.z = t.z;
                }
            }
        }
        s.players[pi] = row;
        pi += 1;
    }
}

/// Collects console output lines into a scratch buffer for one reply.
pub const ConsoleOut = struct {
    buf: [4096]u8 = undefined,
    used: usize = 0,
    lines: [64][]const u8 = undefined,
    n: usize = 0,
    fn line(self: *ConsoleOut, s: []const u8) void {
        if (self.n >= self.lines.len) return;
        const w = @min(s.len, self.buf.len - self.used);
        @memcpy(self.buf[self.used..][0..w], s[0..w]);
        self.lines[self.n] = self.buf[self.used..][0..w];
        self.used += w;
        self.n += 1;
    }
    fn linef(self: *ConsoleOut, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        self.line(std.fmt.bufPrint(&tmp, fmt, args) catch return);
    }
};

/// Bytes of a command verb kept in an audit line. Real verbs are short; the cap
/// bounds what an unknown one can push into the operator log.
pub const max_audit_verb_len: usize = 32;

/// Copy a command verb into `dst` fit for a one-line audit record. The verb is
/// caller-controlled (the F1 console verb arrives straight off the wire), and
/// the audit trail is line-oriented stderr, so an embedded newline would let a
/// client forge whole `audit source=…` lines. Reuses the C2S text sanitizer:
/// drops C0/DEL and invalid UTF-8, truncates on a codepoint boundary.
fn auditVerb(dst: []u8, verb: []const u8) usize {
    return c2s_text.sanitizePlayerName(dst, verb);
}

/// In-game console (F1) command set, executed for the sending player.
/// Reply is NetPackageConsoleCmdClient (output lines, bExecute=false).
pub fn handleConsoleCmd(self: *Game, peer: *ln_peer.Peer, c: *Client, body: []const u8) !void {
    var cmdbuf: [512]u8 = undefined;
    const cmd = packages.parseConsoleCmd(body, &cmdbuf);
    if (cmd.len == 0) return;
    // Log verb only: args may include player names, chat text, or coords.
    const verb_end = std.mem.findScalar(u8, cmd, ' ') orelse cmd.len;
    self.harness.counters.inc(.player_console_commands);
    var ts: [19]u8 = undefined;
    var vb: [max_audit_verb_len]u8 = undefined;
    const vn = auditVerb(&vb, cmd[0..verb_end]);
    std.debug.print("zdtd: {s} audit source=player_console slot={d} command={s}\n", .{ clock.wallStamp(&ts), c.slot, vb[0..vn] });

    var out: ConsoleOut = .{};
    var it = std.mem.tokenizeAny(u8, cmd, " ");
    const verb = it.next() orelse return;

    if (!isPlayerConsoleCommand(verb)) {
        var denied: ConsoleOut = .{};
        denied.line("permission denied");
        const resp = try packages.buildConsoleCmdClient(self.body_buf[0..8192], denied.lines[0..denied.n], false);
        try self.sendGame(peer, "NetPackageConsoleCmdClient", resp);
        return;
    }

    if (eqAny(verb, &.{ "help", "commands", "?" })) {
        // Keep in sync with c2s_text.isPlayerConsoleCommand allowlist.
        out.line("zdtd console commands:");
        out.line(" gettime|gt  listplayers|lp  listplayerids|lpi  listents|le  version");
        out.line(" say|s <msg>");
        out.line(" dm|cm|settempunit|debugmenu (client-side)");
    } else if (eqAny(verb, &.{ "gettime", "gt" })) {
        const clk = &self.sim.director.clock;
        const hh: u32 = @trunc(clk.hours);
        const mm: u32 = @trunc((clk.hours - @floor(clk.hours)) * 60.0);
        out.linef("Day {d}, {d:0>2}:{d:0>2}  (bloodmoon in {d} days)", .{
            clk.day, hh, mm, self.daysToBloodMoon(),
        });
    } else if (eqAny(verb, &.{ "listplayers", "lp" })) {
        var i: usize = 0;
        for (&self.clients) |*cl| {
            if (!cl.joined) continue;
            out.linef("{d}. {s} (entity {d})", .{ i, cl.name[0..cl.name_len], cl.entity_id });
            i += 1;
        }
        if (i == 0) out.line("no players");
    } else if (eqAny(verb, &.{ "listplayerids", "lpi" })) {
        // Same rows as the admin console (ConsoleCmdListPlayerIds); the player
        // console allowlist permits it, so it must not fall through to unknown.
        var i: usize = 0;
        for (&self.clients) |*cl| {
            if (!cl.joined) continue;
            out.linef("{d}. id={d}, {s}", .{ i, cl.entity_id, cl.name[0..cl.name_len] });
            i += 1;
        }
        out.linef("Total of {d} in the game", .{i});
    } else if (eqAny(verb, &.{ "listents", "le" })) {
        out.linef("zombies={d} animals={d} players={d}", .{
            self.sim.countKind(.zombie), self.sim.countKind(.animal), self.countJoined(),
        });
    } else if (eqAny(verb, &.{ "say", "s" })) {
        const msg = it.rest();
        if (!chatMsgOk(msg)) {
            out.line("message too long or has control characters");
        } else if (!self.acceptChatRate(c)) {
            out.line("slow down");
        } else {
            const chat = try packages.buildStockChat(&self.body_buf, 0, c.entity_id, msg, &.{});
            try self.broadcast("NetPackageChat", chat);
            out.line("sent");
        }
    } else if (eqAny(verb, &.{"version"})) {
        out.line("zdtd " ++ version.product ++ " (" ++ version.stock_wire ++ " wire)");
    } else if (eqAny(verb, &.{ "dm", "cm", "settempunit", "debugmenu" })) {
        out.line("ok (client-side toggle)");
    } else {
        out.linef("unknown command '{s}'; try 'help'", .{verb});
    }

    const resp = try packages.buildConsoleCmdClient(self.body_buf[0..8192], out.lines[0..out.n], false);
    try self.sendGame(peer, "NetPackageConsoleCmdClient", resp);
}

pub fn consoleTeleport(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
    const ps = player orelse {
        out.line("no player entity");
        return;
    };
    const xs = it.next();
    const ys = it.next();
    const zs = it.next();
    if (xs == null or ys == null or zs == null) {
        out.line("usage: tp <x> <y> <z>");
        return;
    }
    const x = std.fmt.parseFloat(f32, xs.?) catch {
        out.line("bad x");
        return;
    };
    const y = std.fmt.parseFloat(f32, ys.?) catch {
        out.line("bad y");
        return;
    };
    const z = std.fmt.parseFloat(f32, zs.?) catch {
        out.line("bad z");
        return;
    };
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) {
        out.line("coordinates must be finite");
        return;
    }
    self.sim.transform[ps] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
    if (self.sim.mask[ps].player) {
        self.resetMoveEnvelopePeer(@intCast(self.sim.player[ps].peer_slot), x, y, z);
    }
    const entity_id = self.sim.netId(ps);
    const body = packages.buildEntityTeleportBody(&self.body_buf, entity_id, x, y, z, 0, 0, 0, true) catch return;
    self.broadcast("NetPackageEntityTeleport", body) catch {};
    out.linef("teleported to {d:.0} {d:.0} {d:.0}", .{ x, y, z });
}

pub fn consoleSpawnEntity(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
    const ps = player orelse {
        out.line("no player entity");
        return;
    };
    const nm = it.next() orelse {
        out.line("usage: spawnentity <class>");
        return;
    };
    const def = self.entities.byName(nm) orelse {
        out.linef("unknown class '{s}'", .{nm});
        return;
    };
    const t = self.sim.transform[ps];
    const sy = self.spawnYNearPlayer(t.x, t.y, t.z);
    // A35: spawn the full resolved class so speeds/damage/is_enemy reach the
    // sim even for classes outside the fixed class_table.
    const nid = if (def.kind == .animal)
        self.sim.spawnAnimalDef(t.x + 3, sy, t.z + 3, self.entityClassOf(def))
    else
        self.sim.spawnZombieDef(t.x + 3, sy, t.z + 3, def.max_hp, self.entityClassOf(def));
    if (nid) |eid| {
        if (self.sim.slotOfNetId(eid)) |es| {
            for (&self.clients) |*cl| {
                if (!cl.joined) continue;
                cl.known_entities.unset(es);
            }
        }
        out.linef("spawned {s}", .{nm});
    } else out.line("spawn failed (capacity)");
}

pub fn consoleGiveSelf(self: *Game, player: ?ecs.Slot, it: *std.mem.TokenIterator(u8, .any), out: *ConsoleOut) void {
    const ps = player orelse {
        out.line("no player entity");
        return;
    };
    const nm = it.next() orelse {
        out.line("usage: giveself <item> [count]");
        return;
    };
    const def = self.items.byName(nm) orelse {
        out.linef("unknown item '{s}'", .{nm});
        return;
    };
    const count: u16 = if (it.next()) |cs| (std.fmt.parseInt(u16, cs, 10) catch 1) else 1;
    const t = self.sim.transform[ps];
    if (self.sim.spawnLootBag(t.x + 1, t.y, t.z + 1, def.id, count)) |nid| {
        self.broadcastLootSpawn(nid) catch {};
        out.linef("dropped {d}x {s} at your feet", .{ count, nm });
    } else out.line("give failed");
}

pub fn consoleKickBan(self: *Game, name: ?[]const u8, out: *ConsoleOut, do_ban: bool) void {
    const nm = name orelse {
        out.line("usage: kick|ban <name>");
        return;
    };
    for (&self.clients, 0..) |*cl, i| {
        if (!cl.joined or !std.mem.eql(u8, cl.name[0..cl.name_len], nm)) continue;
        if (cl.peer) |p| {
            if (do_ban) self.banIp(peerIpKey(p));
            p.alive = false;
        }
        self.clearLocksForPeer(i);
        self.clients[i] = .{};
        out.linef("{s} {s}", .{ if (do_ban) "banned" else "kicked", nm });
        return;
    }
    out.linef("no player named '{s}'", .{nm});
}

pub fn consoleKillAll(self: *Game) u32 {
    var n: u32 = 0;
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (!self.sim.alive[s] or self.sim.kind[s] != .zombie) continue;
        const eid = self.sim.network_id[s].id;
        const dmg = self.sim.damage(eid, 99999);
        if (dmg.killed) {
            if (packages.buildRemoveBody(&self.body_buf, eid)) |rm| {
                self.broadcast("NetPackageEntityRemove", rm) catch {};
            } else |_| {}
            // Drop loot bags silently (caller may sweep). Avoid flooding bag.
            if (dmg.loot_bag_id > 0) {
                if (self.sim.slotOfNetId(dmg.loot_bag_id)) |ls| {
                    if (self.sim.alive[ls]) self.sim.destroy(ls);
                }
            }
            n += 1;
        }
    }
    return n;
}

/// Force every storm-capable biome into an active storm (console `storm`)
/// and broadcast the new weather state. Returns false when no biomes have
/// weather groups (weather table empty).
pub fn forceStorm(self: *Game) bool {
    if (self.world.biome_layers_table.weather_n == 0) return false;
    self.world.weather.setStormNow(&self.world.biome_layers_table, @intCast(self.sim.director.clock.worldTimeBits()));
    self.broadcastWeather() catch {};
    return true;
}

/// End any active storm and push the next one a day out (console `clearweather`).
pub fn clearStorm(self: *Game) bool {
    if (self.world.biome_layers_table.weather_n == 0) return false;
    self.world.weather.clearStorm(&self.world.biome_layers_table, @intCast(self.sim.director.clock.worldTimeBits()));
    self.broadcastWeather() catch {};
    return true;
}

/// Trigger an air drop immediately (console spawnairdrop). Returns false if
/// no joined player to drop near.
pub fn forceAirDrop(self: *Game) bool {
    for (&self.clients) |*cl| {
        if (!cl.joined) continue;
        const ps = self.sim.playerByPeer(cl.slot) orelse continue;
        const t = self.sim.transform[ps];
        if (self.sim.spawnLootBag(t.x, t.y + 2, t.z, 1, 1)) |bag| {
            self.fillLootBagFromTable(bag, "supplyCrate", @intCast(bag), self.lootStageForPlayer(cl.slot));
            self.broadcastLootSpawn(bag) catch {};
            return true;
        }
    }
    return false;
}

pub fn daysToBloodMoon(self: *const Game) u32 {
    const clk = self.sim.director.clock;
    if (clk.bloodmoon_frequency == 0) return 999;
    if (clk.day % clk.bloodmoon_frequency == 0) return 0;
    const next = ((clk.day / clk.bloodmoon_frequency) + 1) * clk.bloodmoon_frequency;
    return next - clk.day;
}

pub fn webuiAdminThunk(ctx: *anyopaque, line: []const u8, out: []u8) usize {
    const self: *Game = @ptrCast(@alignCast(ctx));
    self.admin_reply_len = 0;
    self.admin_reply_sink = out;
    self.runAdminLine(line, "webui");
    self.admin_reply_sink = null;
    return self.admin_reply_len;
}

/// Stock `ban add|remove|list` (ConsoleCmdBan, asm.il 209578-210270). The list
/// is by identity and survives restart; the IP ban table still does the
/// immediate enforcement for the connection that is being dropped.
pub fn runBanCommand(self: *Game, sub: admin_mod.BanSub) void {
    switch (sub) {
        .list => {
            self.ban_list.expire(clock.wallSeconds());
            self.adminWrite(admin_cmds.writeBanList, .{&self.ban_list});
        },
        .remove => |t| {
            var idb: [96]u8 = undefined;
            const id = self.adminTargetId(t, &idb);
            // A platform id (digits beyond slot range, or an online slot with
            // a platform session) resolves to a platform-keyed entry; names
            // fall back to the name-keyed entries (legacy/no-session).
            var removed = false;
            switch (self.resolveAdminTarget(t)) {
                .slot => |slot| {
                    if (self.clients[slot].puid_primary.get()) |pid| {
                        removed = self.ban_list.removeId(pid.platform, pid.id);
                    }
                },
                else => {},
            }
            if (!removed) _ = self.ban_list.remove(id);
            self.saveAdminLists();
            var b: [160]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "{s} removed from ban list.\n", .{id}) catch return;
            self.adminReply(s);
        },
        .add => |a| {
            var idb: [96]u8 = undefined;
            const id = self.adminTargetId(a.target, &idb);
            const now = clock.wallSeconds();
            const until = std.math.add(i64, now, a.seconds) catch std.math.maxInt(i64);
            // Key the ban on the target's platform id when one exists (stock
            // AdminBlacklist keys on the platform identifier), so a rename
            // cannot evade it; targets without a platform session (offline,
            // loadgen bots) fall back to a name-keyed entry.
            var added = false;
            switch (self.resolveAdminTarget(a.target)) {
                .slot => |slot| {
                    const cl = &self.clients[slot];
                    if (cl.puid_primary.get()) |pid| {
                        added = self.ban_list.addId(pid.platform, pid.id, cl.name[0..cl.name_len], until, a.reason);
                    }
                },
                else => {},
            }
            if (!added) added = self.ban_list.add(id, until, a.reason);
            if (!added) {
                self.adminReply("ban list full\n");
                return;
            }
            self.saveAdminLists();
            // Online target: drop the session and hold its address too, so a
            // reconnect before the next join check cannot slip through.
            switch (self.resolveAdminTarget(a.target)) {
                .slot => |slot| {
                    if (self.clients[slot].peer) |p| self.banIp(peerIpKey(p));
                    self.dropClientSlot(slot, "ban");
                },
                else => {},
            }
            var tb: [24]u8 = undefined;
            var b: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "{s} banned until {s} UTC, reason: {s}.\n", .{
                id, admin_cmds.formatUnix(&tb, until), a.reason,
            }) catch return;
            self.adminReply(s);
        },
    }
}

pub fn adminListsPath(self: *const Game, buf: []u8, name: []const u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/{s}", .{ self.world.world_dir, name });
}

/// All three lists are rewritten together: they are small, and a single call
/// site means no command can mutate one and forget to persist it.
pub fn saveAdminLists(self: *Game) void {
    self.saveAdminListFile("admins.zsv", admin_cmds.serializePermissions, &self.admin_list);
    self.saveAdminListFile("whitelist.zsv", admin_cmds.serializePermissions, &self.whitelist);
    self.saveAdminListFile("bans.zsv", admin_cmds.serializeBans, &self.ban_list);
}

pub fn saveAdminListFile(self: *Game, name: []const u8, comptime ser: anytype, list: anytype) void {
    var path_buf: [512]u8 = undefined;
    const path = self.adminListsPath(&path_buf, name) catch |e| {
        logPersistErr(self, "admin list path", e);
        return;
    };
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ser(&w, list) catch |e| return logPersistErr(self, "serialize admin list", e);
    io_fs.writeFile(path, w.buffered()) catch |e|
        logPersistErr(self, "save admin list", e);
}

/// Reads the three lists at startup. A missing file is normal; a corrupt line
/// is skipped and reported, never applied, so a damaged file cannot grant
/// permissions or silently drop a live ban without a warning.
pub fn loadAdminLists(self: *Game) void {
    const now = clock.wallSeconds();
    self.readAdminList("admins.zsv", "admin", struct {
        fn f(g: *Game, text: []const u8, _: i64) admin_cmds.LoadResult {
            return admin_cmds.deserializePermissions(&g.admin_list, text);
        }
    }.f, now);
    self.readAdminList("whitelist.zsv", "whitelist", struct {
        fn f(g: *Game, text: []const u8, _: i64) admin_cmds.LoadResult {
            return admin_cmds.deserializePermissions(&g.whitelist, text);
        }
    }.f, now);
    self.readAdminList("bans.zsv", "ban", struct {
        fn f(g: *Game, text: []const u8, t: i64) admin_cmds.LoadResult {
            return admin_cmds.deserializeBans(&g.ban_list, text, t);
        }
    }.f, now);
}

pub fn readAdminList(
    self: *Game,
    name: []const u8,
    label: []const u8,
    load: *const fn (*Game, []const u8, i64) admin_cmds.LoadResult,
    now: i64,
) void {
    var path_buf: [512]u8 = undefined;
    const path = self.adminListsPath(&path_buf, name) catch |e| {
        logPersistErr(self, "admin list path", e);
        return;
    };
    const text = io_fs.readFileAll(self.allocator, path) catch |e| {
        if (e != error.FileNotFound) logPersistErr(self, "load admin list", e);
        return;
    };
    defer self.allocator.free(text);
    const res = load(self, text, now);
    if (res.skipped != 0) {
        std.debug.print(
            "zdtd: warning: {d} corrupt {s} list entries skipped (not applied)\n",
            .{ res.skipped, label },
        );
    }
}

/// Stock `getgamepref` (asm.il 220877): "GamePref.{0} = {1}" per pref, filtered
/// by substring. Only prefs zdtd actually applies are listed; printing a stock
/// name zdtd ignores would tell an operator a lie.
pub fn replyGamePrefs(self: *Game, filter: []const u8) void {
    self.gamePref(filter, "ServerPort", "{d}", .{self.info_port});
    self.gamePref(filter, "ServerMaxPlayerCount", "{d}", .{self.max_players});
    self.gamePref(filter, "GameName", "{s}", .{self.world_name});
    self.gamePref(filter, "ViewRadius", "{d}", .{self.view_radius});
    self.gamePref(filter, "GameDifficulty", "{d}", .{self.sim.director.difficulty});
    self.gamePref(filter, "DayNightLength", "{d}", .{
        @as(u32, @round(self.sim.director.clock.seconds_per_hour * 24.0 / 60.0)),
    });
    self.gamePref(filter, "TelnetPort", "{d}", .{self.admin.port});
}

pub fn gamePref(self: *Game, filter: []const u8, name: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (filter.len != 0 and std.ascii.findIgnoreCase(name, filter) == null) return;
    var vb: [96]u8 = undefined;
    const v = std.fmt.bufPrint(&vb, fmt, args) catch return;
    self.adminWrite(admin_cmds.writeGamePref, .{ name, v });
}

/// ConsoleCmdGetGameStats (asm.il 224074): the GameStats this sim tracks,
/// printed as `GameStat.X = value` (stock console shape). Values come from
/// gameStatsValues(), the same set the wire GameStats blob carries, so the
/// console shows exactly what the client is told. Untracked stock stats are
/// omitted; a missing stat is a finding to triage, not a value to invent.
pub fn replyGameStats(self: *Game, filter: []const u8) void {
    const v = self.gameStatsValues();
    gameStat(self, filter, "GameState", "{d}", .{@as(i32, 1)});
    gameStat(self, filter, "GameDifficulty", "{d}", .{v.game_difficulty});
    gameStat(self, filter, "BloodMoonEnemyCount", "{d}", .{v.blood_moon_enemy_count});
    gameStat(self, filter, "EnemyDifficulty", "{d}", .{v.enemy_difficulty});
    gameStat(self, filter, "DayLightLength", "{d}", .{v.day_light_length});
    gameStat(self, filter, "DayNightLength", "{d}", .{v.day_night_length});
    gameStat(self, filter, "BloodMoonDay", "{d}", .{v.blood_moon_day});
    gameStat(self, filter, "BloodMoonWarning", "{d}", .{v.blood_moon_warning});
    gameStat(self, filter, "BlockDamagePlayer", "{d}", .{v.block_damage_player});
    gameStat(self, filter, "BlockDamageAI", "{d}", .{v.block_damage_ai});
    gameStat(self, filter, "BlockDamageAIBM", "{d}", .{v.block_damage_ai_bm});
    gameStat(self, filter, "XPMultiplier", "{d}", .{v.xp_multiplier});
    gameStat(self, filter, "PlayerKillingMode", "{d}", .{v.player_killing_mode});
    gameStat(self, filter, "DropOnDeath", "{d}", .{v.drop_on_death});
    gameStat(self, filter, "LandClaimSize", "{d}", .{v.land_claim_size});
    gameStat(self, filter, "LandClaimOnlineDurabilityModifier", "{d}", .{v.land_claim_online_dur});
    gameStat(self, filter, "LandClaimOfflineDurabilityModifier", "{d}", .{v.land_claim_offline_dur});
    gameStat(self, filter, "AirDropFrequency", "{d}", .{v.air_drop_frequency});
    gameStat(self, filter, "PartySharedKillRange", "{d}", .{v.party_shared_kill_range});
    gameStat(self, filter, "ShowFriendPlayerOnMap", "{s}", .{boolWord(v.show_friend_player_on_map)});
    gameStat(self, filter, "IsSpawnEnemies", "{s}", .{boolWord(v.is_spawn_enemies)});
    gameStat(self, filter, "EnemySpawnMode", "{s}", .{boolWord(v.enemy_spawn_mode)});
    gameStat(self, filter, "TimeOfDayIncPerSec", "{d}", .{v.time_of_day_inc_per_sec});
    gameStat(self, filter, "DeathPenalty", "{d}", .{v.death_penalty});
    gameStat(self, filter, "QuestProgressionDailyLimit", "{d}", .{v.quest_progression_daily_limit});
    gameStat(self, filter, "StormFreq", "{d}", .{v.storm_freq});
    gameStat(self, filter, "LootAbundance", "{d}", .{v.loot_abundance});
    gameStat(self, filter, "LootRespawnDays", "{d}", .{v.loot_respawn_days});
    gameStat(self, filter, "BedrollExpiryTime", "{d}", .{v.bedroll_expiry_time});
    gameStat(self, filter, "LandClaimCount", "{d}", .{v.land_claim_count});
    gameStat(self, filter, "LandClaimDeadZone", "{d}", .{v.land_claim_dead_zone});
    gameStat(self, filter, "LandClaimExpiryTime", "{d}", .{v.land_claim_expiry_time});
    gameStat(self, filter, "LandClaimDecayMode", "{d}", .{v.land_claim_decay_mode});
    gameStat(self, filter, "LandClaimOfflineDelay", "{d}", .{v.land_claim_offline_delay});
    gameStat(self, filter, "JarRefund", "{d}", .{v.jar_refund});
    gameStat(self, filter, "SandboxPreset", "{s}", .{v.sandbox_preset});
    gameStat(self, filter, "SandboxCode", "{s}", .{v.sandbox_code});
}

fn gameStat(self: *Game, filter: []const u8, name: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (filter.len != 0 and std.ascii.findIgnoreCase(name, filter) == null) return;
    var vb: [96]u8 = undefined;
    const val = std.fmt.bufPrint(&vb, fmt, args) catch return;
    self.adminWrite(admin_cmds.writeGameStat, .{ name, val });
}

fn boolWord(b: bool) []const u8 {
    return if (b) "True" else "False";
}

/// Runtime `setgamepref` for the GameStats-backed prefs: parse the value,
/// clamp to this function's own range (independent of config.zig's startup
/// ranges — they are not guaranteed to match), and write the sim/Game field
/// the stats blob reads, so the client HUD follows. Unknown or startup-only
/// prefs (ServerPort, world paths) return false and the caller keeps the
/// honest read-only reply.
pub fn applyGamePrefSet(self: *Game, name: []const u8, value: []const u8) bool {
    const v = std.fmt.parseInt(i32, std.mem.trim(u8, value, " \t"), 10) catch return false;
    if (std.mem.eql(u8, name, "GameDifficulty")) {
        self.sim.director.difficulty = @intCast(@min(@max(v, 0), 5));
    } else if (std.mem.eql(u8, name, "BloodMoonEnemyCount")) {
        self.sim.director.bloodmoon_enemy_count = @intCast(@min(@max(v, 0), 60));
    } else if (std.mem.eql(u8, name, "EnemyDifficulty")) {
        self.sim.director.enemy_difficulty = @intCast(@min(@max(v, 0), 1));
    } else if (std.mem.eql(u8, name, "BloodMoonFrequency")) {
        self.sim.director.clock.bloodmoon_frequency = @intCast(@min(@max(v, 0), 255));
    } else if (std.mem.eql(u8, name, "DayNightLength")) {
        self.sim.director.clock.setDayNightLength(@intCast(@min(@max(v, 10), 1200)));
    } else if (std.mem.eql(u8, name, "BlockDamagePlayer")) {
        self.block_damage_player = @intCast(@min(@max(v, 0), 1000));
    } else if (std.mem.eql(u8, name, "XPMultiplier")) {
        self.xp_multiplier = @intCast(@min(@max(v, 0), 1000));
    } else if (std.mem.eql(u8, name, "PlayerKillingMode")) {
        self.pvp_mode = @intCast(@min(@max(v, 0), 3));
    } else if (std.mem.eql(u8, name, "DropOnDeath")) {
        self.drop_on_death = @intCast(@min(@max(v, 0), 3));
    } else if (std.mem.eql(u8, name, "LootRespawnDays")) {
        self.loot_respawn_days = @intCast(@min(@max(v, 0), 365));
    } else if (std.mem.eql(u8, name, "AirDropFrequency")) {
        self.air_drop_interval_hours = @intCast(@min(@max(v, 0), 168));
    } else {
        return false;
    }
    return true;
}

/// Stock `mem` (asm.il 235864). zdtd has no Unity heap, so the Unity-only
/// fields report 0 rather than a made-up number; the separators are stock's
/// so a scraper still finds the counts it can use.
pub fn replyMem(self: *Game) void {
    var players: usize = 0;
    var zombies: usize = 0;
    var entities: usize = 0;
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities) : (s += 1) {
        if (!self.sim.alive[s]) continue;
        entities += 1;
        switch (self.sim.kind[s]) {
            .player => players += 1,
            .zombie => zombies += 1,
            else => {},
        }
    }
    self.adminWrite(admin_cmds.writeMem, .{admin_cmds.MemStats{
        .minutes = clock.monoNs() / std.time.ns_per_min,
        .fps = protocol.ticks_per_second,
        .heap_mb = 0,
        .max_mb = 0,
        .chunks = self.world.chunks.count(),
        .chunk_game_objects = 0,
        .players = players,
        .zombies = zombies,
        .entities = entities,
        .entities_of_type = entities,
        .items = 0,
        .collision_objects = 0,
        .rss_mb = 0,
    }});
}

/// Render one `admin_cmds` formatter straight into the admin reply stream.
/// Sized for the largest single formatter output, a full `ban list`
/// (admin_cmds.max_entries rows of id + reason + timestamp).
pub fn adminWrite(self: *Game, comptime f: anytype, args: anytype) void {
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    @call(.auto, f, .{&w} ++ args) catch return;
    self.adminReply(w.buffered());
}

/// Stock console target resolution (ConsoleHelper::ParseParamPartialNameOrId,
/// asm.il:268297): entity id, peer slot or (partial) player name.
pub const TargetResult = union(enum) { slot: usize, none, ambiguous };

pub fn resolveAdminTarget(self: *const Game, t: admin_mod.Target) TargetResult {
    switch (t) {
        .id => |n| {
            if (n < 0) return .none;
            const u: usize = @intCast(n);
            if (u < max_clients and self.clients[u].joined) return .{ .slot = u };
            for (&self.clients, 0..) |*cl, i| {
                if (cl.joined and cl.entity_id == n) return .{ .slot = i };
            }
            return .none;
        },
        .name => |nm| {
            if (nm.len == 0) return .none;
            for (&self.clients, 0..) |*cl, i| {
                if (cl.joined and std.ascii.eqlIgnoreCase(cl.name[0..cl.name_len], nm)) return .{ .slot = i };
            }
            var hit: ?usize = null;
            for (&self.clients, 0..) |*cl, i| {
                if (!cl.joined) continue;
                if (std.ascii.findIgnoreCase(cl.name[0..cl.name_len], nm) == null) continue;
                if (hit != null) return .ambiguous;
                hit = i;
            }
            return if (hit) |h| .{ .slot = h } else .none;
        },
    }
}

/// The stock error lines a miss produces, so tooling can branch on them.
pub fn adminTargetError(self: *Game, t: admin_mod.Target, res: TargetResult) void {
    var tb: [96]u8 = undefined;
    const tok = switch (t) {
        .id => |n| std.fmt.bufPrint(&tb, "{d}", .{n}) catch "?",
        .name => |nm| nm,
    };
    var b: [256]u8 = undefined;
    const s = switch (res) {
        .ambiguous => std.fmt.bufPrint(&b, "\"{s}\" matches multiple player names.\n", .{tok}),
        else => std.fmt.bufPrint(&b, "\"{s}\" is not a valid entity id, player name or user id.\n", .{tok}),
    } catch return;
    self.adminReply(s);
}

/// Identity a ban/permission entry is stored under: the login name when the
/// target is online, otherwise the operator's own token. zdtd has no stock
/// platform user id to key on, and inventing one would be a lie on the wire.
/// Always copied into `buf`: callers kick the client afterwards, which clears
/// the name the slice would otherwise point at.
pub fn adminTargetId(self: *const Game, t: admin_mod.Target, buf: []u8) []const u8 {
    const src: []const u8 = switch (self.resolveAdminTarget(t)) {
        .slot => |i| self.clients[i].name[0..self.clients[i].name_len],
        else => switch (t) {
            .id => |n| return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?",
            .name => |nm| nm,
        },
    };
    // The copy becomes the stored ban/permission key, so an over-long name is
    // cut on a codepoint boundary rather than mid-sequence.
    const n = c2s_text.utf8TruncLen(src, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

fn tryDispatchPluginAdmin(self: *Game, line: []const u8) bool {
    // Bounded reply buffer: plugin admin commands are informational, not bulk
    // dumps. 4k matches the largest single admin formatter (ban list).
    var out: [4096]u8 = undefined;
    if (self.plugins.adminCommand(line, &out)) |reply| {
        self.adminReply(reply);
        return true;
    }
    if (self.wasm_plugins.adminCommand(line, &out)) |reply| {
        self.adminReply(reply);
        return true;
    }
    return false;
}

pub fn runAdminLine(self: *Game, line: []const u8, source: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    const verb_end = std.mem.findAny(u8, trimmed, " \t") orelse trimmed.len;
    self.harness.counters.inc(.admin_commands);
    var ts: [19]u8 = undefined;
    var vb: [max_audit_verb_len]u8 = undefined;
    const vn = auditVerb(&vb, trimmed[0..verb_end]);
    std.debug.print("zdtd: {s} audit source={s} command={s}\n", .{ clock.wallStamp(&ts), source, vb[0..vn] });
    const cmd = admin_mod.parseCommand(line);
    switch (cmd) {
        .help => |topic| {
            if (topic) |t| {
                // `help <command>`: the one-line usage when known, else the
                // same unknown-command reply a bare miss gets.
                var hb: [320]u8 = undefined;
                if (admin_mod.usageFor(t)) |u| {
                    const s = std.fmt.bufPrint(&hb, "usage: {s}\n", .{u}) catch return;
                    self.adminReply(s);
                } else {
                    self.adminWrite(admin_cmds.writeUnknownCommand, .{t});
                }
            } else {
                var buf: [4096]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                admin_cmds.writeHelp(&w, &admin_help_index) catch return;
                self.adminReply(w.buffered());
            }
        },
        .unknown => {
            // Plugin admin commands: a plugin can handle a verb the core does
            // not know. Auth has already gated runAdminLine (admin TCP auth),
            // so a plugin cannot bypass it — it just handles a verb the core
            // would otherwise report as unknown.
            if (tryDispatchPluginAdmin(self, trimmed)) return;
            // Surface the first token so typos are obvious (matches player console).
            const bad_verb = if (verb_end > 0) trimmed[0..verb_end] else trimmed;
            self.adminWrite(admin_cmds.writeUnknownCommand, .{bad_verb});
        },
        .err_text => |e| {
            var eb: [320]u8 = undefined;
            const s = std.fmt.bufPrint(&eb, "{s}{s}{s}\n", .{ e.prefix, e.token, e.suffix }) catch return;
            self.adminReply(s);
        },
        .wrong_args => |a| {
            var eb: [96]u8 = undefined;
            const s = std.fmt.bufPrint(
                &eb,
                "Wrong number of arguments, expected {s}, found {d}.\n",
                .{ a.expected, a.found },
            ) catch return;
            self.adminReply(s);
        },
        .bad_args => |verb| {
            var eb: [128]u8 = undefined;
            const s = if (admin_mod.usageFor(verb)) |u|
                std.fmt.bufPrint(&eb, "bad arguments to '{s}'. usage: {s}\n", .{ verb, u }) catch
                    "bad arguments. 'help' for usage.\n"
            else
                std.fmt.bufPrint(&eb, "bad arguments to '{s}'. 'help' for usage.\n", .{verb}) catch
                    "bad arguments. 'help' for usage.\n";
            self.adminReply(s);
        },
        .status => {
            // One-line ops glance: load + key error counters for incident triage.
            var sb: [320]u8 = undefined;
            const s = std.fmt.bufPrint(
                &sb,
                "tick={d} players={d} zombies={d} chunks={d} overruns={d} encode_err={d} send_err={d} window_drop={d} persist_err={d}\n",
                .{
                    self.tick_n,
                    self.countJoined(),
                    self.sim.countKind(.zombie),
                    self.world.chunks.count(),
                    self.harness.counters.get(.tick_overruns),
                    self.harness.counters.get(.encode_errors),
                    self.harness.counters.get(.net_send_errors),
                    self.harness.counters.get(.reliable_window_drops),
                    self.harness.counters.get(.persistence_errors),
                },
            ) catch return;
            self.adminReply(s);
        },
        .guardstats => {
            var sb: [384]u8 = undefined;
            const s = std.fmt.bufPrint(&sb, "phase={d} ownership={d} bounds={d} movement={d} decode={d} throttle={d} malformed={d} reconnects={d} evidence={d}\n", .{
                self.harness.counters.get(.phase_rejects),
                self.harness.counters.get(.ownership_rejects),
                self.harness.counters.get(.bounds_rejects),
                self.harness.counters.get(.movement_rejects),
                self.harness.counters.get(.decode_rejects),
                self.harness.counters.get(.c2s_throttle),
                self.harness.counters.get(.c2s_malformed),
                self.harness.counters.get(.reconnects),
                self.evidence.total,
            }) catch return;
            self.adminReply(s);
            self.adminReplyGuardPolicy();
        },
        .guardclear => |peer| {
            if (peer >= max_clients or self.clients[peer].peer == null) {
                self.adminReply("no player in slot\n");
                return;
            }
            self.clients[peer].guard.quarantine = .{};
            self.clients[peer].guard.kick_at_tick = 0;
            self.adminReply("guard cleared\n");
        },
        .evidence => |path_opt| {
            if (path_opt) |p| {
                // JSONL flush (P4 evidence file): the ring only holds the
                // last 64 events, so the operator can persist them.
                var path_buf: [1024]u8 = undefined;
                const path = if (p.len == 0) blk: {
                    break :blk std.fmt.bufPrint(&path_buf, "{s}/evidence.jsonl", .{self.world.world_dir}) catch "evidence.jsonl";
                } else p;
                const n = self.dumpEvidenceFile(path) catch |err| {
                    var eb: [256]u8 = undefined;
                    self.adminReply(std.fmt.bufPrint(&eb, "evidence dump failed: {s}\n", .{@errorName(err)}) catch "evidence dump failed\n");
                    return;
                };
                var mb: [256]u8 = undefined;
                self.adminReply(std.fmt.bufPrint(&mb, "evidence dump: {d} events -> {s}\n", .{ n, path }) catch "evidence dumped\n");
            } else {
                var dump: [16384]u8 = undefined;
                const n = self.evidence.dumpText(&dump);
                if (n == 0) self.adminReply("evidence empty\n") else self.adminReply(dump[0..n]);
            }
        },
        .gamestage => |maybe_slot| self.adminReplyGameStage(maybe_slot),
        .apm => {
            // Full harness dump without waiting for the minute JSON line or --ticks exit.
            const snap = self.harness.snapshot();
            var ab: [apm.report.max_text_bytes]u8 = undefined;
            var w: std.Io.Writer = .fixed(&ab);
            apm.report.writeText(&snap, &w) catch |err| {
                std.debug.print("zdtd: admin apm dump failed: {s}\n", .{@errorName(err)});
            };
            if (w.buffered().len > 0) self.adminReply(w.buffered()) else self.adminReply("apm dump empty\n");
        },
        .save => {
            // Same honesty as saveworld: never claim success when disk I/O failed.
            self.adminReply(if (self.saveAllStores()) "saved\n" else "save failed; see server log\n");
        },
        .plugin => |rest| self.adminPlugin(rest),
        .kick => |k| {
            const res = self.resolveAdminTarget(k.target);
            const slot = switch (res) {
                .slot => |i| i,
                else => return self.adminTargetError(k.target, res),
            };
            var kb: [192]u8 = undefined;
            const s = std.fmt.bufPrint(&kb, "Kicking Player {s}: {s}\n", .{
                self.clients[slot].name[0..self.clients[slot].name_len], k.reason,
            }) catch "Kicking Player\n";
            self.adminReply(s);
            self.dropClientSlot(slot, "kick");
        },
        .kickall => |reason| {
            for (&self.clients, 0..) |*cl, i| {
                if (!cl.joined) continue;
                var kb: [192]u8 = undefined;
                const s = std.fmt.bufPrint(&kb, "Kicking Player {s}: {s}\n", .{
                    cl.name[0..cl.name_len], reason,
                }) catch "Kicking Player\n";
                self.adminReply(s);
                self.dropClientSlot(i, "kickall");
            }
        },
        .ban => |sub| self.runBanCommand(sub),
        .unban => |ip| {
            self.unbanIp(ip);
            self.adminReply("unbanned\n");
        },
        .admin => |sub| switch (sub) {
            .list => self.adminWrite(admin_cmds.writeAdminList, .{&self.admin_list}),
            .add => |a| {
                var idb: [96]u8 = undefined;
                const id = self.adminTargetId(a.target, &idb);
                if (!self.admin_list.add(id, a.level)) {
                    self.adminReply("permissions list full\n");
                    return;
                }
                self.saveAdminLists();
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{s} added with permission level of {d}.\n", .{ id, a.level }) catch return;
                self.adminReply(s);
            },
            .remove => |t| {
                var idb: [96]u8 = undefined;
                const id = self.adminTargetId(t, &idb);
                const removed = self.admin_list.remove(id);
                if (removed) self.saveAdminLists();
                var b: [160]u8 = undefined;
                const s = if (removed)
                    std.fmt.bufPrint(&b, "{s} removed from permissions list.\n", .{id}) catch return
                else
                    std.fmt.bufPrint(&b, "{s} was not on permissions list.\n", .{id}) catch return;
                self.adminReply(s);
            },
        },
        .whitelist => |sub| switch (sub) {
            .list => self.adminWrite(admin_cmds.writeWhitelist, .{&self.whitelist}),
            .add => |t| {
                var idb: [96]u8 = undefined;
                const id = self.adminTargetId(t, &idb);
                if (!self.whitelist.add(id, 0)) {
                    self.adminReply("whitelist full\n");
                    return;
                }
                self.saveAdminLists();
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{s} added to whitelist.\n", .{id}) catch return;
                self.adminReply(s);
            },
            .remove => |t| {
                var idb: [96]u8 = undefined;
                const id = self.adminTargetId(t, &idb);
                const removed = self.whitelist.remove(id);
                if (removed) self.saveAdminLists();
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(&b, "{s} {s} the whitelist.\n", .{
                    id, if (removed) "removed from" else "was not on",
                }) catch return;
                self.adminReply(s);
            },
        },
        .wipeplayer => |nm| {
            // Drop any online session with this login name first so the next
            // autosave cannot re-write the wiped players.zsv record.
            var kicked: u32 = 0;
            // allies.zal is keyed by platform identity, not login name, so
            // capture the identities before the drop clears the client and
            // erase them there too (a wiped player must not survive as an
            // ally partner). Offline players have no identity to match here.
            var allies_dropped: u32 = 0;
            for (&self.clients, 0..) |*cl, i| {
                if (!cl.joined or cl.name_len != nm.len) continue;
                if (!std.mem.eql(u8, cl.name[0..cl.name_len], nm)) continue;
                if (cl.puid_primary.get()) |id| allies_dropped += self.allies.dropByIdentity(id);
                if (cl.puid_native.get()) |id| allies_dropped += self.allies.dropByIdentity(id);
                self.dropClientSlot(i, "wipeplayer");
                kicked += 1;
            }
            const removed = self.wipePlayerRecordsByName(nm) catch |e| {
                logPersistErr(self, "wipe player", e);
                self.adminReply("wipe failed; see server log\n");
                return;
            };
            // claims.zlc records the owner's login name: wiping players.zsv
            // alone would leave that name on disk, so release those claims and
            // rewrite the file now rather than waiting for the autosave.
            const claims = self.dropClaimsForName(nm);
            if (claims != 0) self.saveClaims() catch |e| logPersistErr(self, "save claims", e);
            if (allies_dropped != 0) self.allies.save(self.world.world_dir, self.allocator) catch |e| logPersistErr(self, "save allies", e);
            var lb: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&lb, "wiped records={d} claims={d} allies={d} kicked={d}\n", .{ removed, claims, allies_dropped, kicked }) catch "wiped\n";
            self.adminReply(s);
            // Count only; never print the login name to process logs.
            std.debug.print("zdtd: wipeplayer records={d} claims={d} allies={d} kicked={d}\n", .{ removed, claims, allies_dropped, kicked });
        },
        .list, .listplayers => {
            // ConsoleCmdListPlayers::Execute (asm.il 231241) field order.
            // Names stay on admin/webui replies only (never process stdout; PlayerLogin logs name_len).
            var n: usize = 0;
            for (&self.clients, 0..) |*cl, i| {
                if (!cl.joined) continue;
                const ps = self.sim.playerByPeer(i);
                const t = if (ps) |p| self.sim.transform[p] else ecs.components.Transform{};
                const hp: i32 = if (ps) |p| @trunc(self.sim.health[p].hp) else 0;
                self.adminWrite(admin_cmds.writePlayerRow, .{ n, admin_cmds.PlayerRow{
                    .entity_id = cl.entity_id,
                    .name = cl.name[0..cl.name_len],
                    .x = t.x,
                    .y = t.y,
                    .z = t.z,
                    .rot_y = t.yaw,
                    .health = hp,
                } });
                n += 1;
            }
            self.adminWrite(admin_cmds.writeTotal, .{n});
        },
        .listplayerids => {
            var n: usize = 0;
            for (&self.clients) |*cl| {
                if (!cl.joined) continue;
                self.adminWrite(admin_cmds.writePlayerIdRow, .{ n, cl.entity_id, cl.name[0..cl.name_len] });
                n += 1;
            }
            self.adminWrite(admin_cmds.writeTotal, .{n});
        },
        .getgamepref => |filter| self.replyGamePrefs(filter),
        .getgamestat => |filter| self.replyGameStats(filter),
        .setgamepref => |sp| {
            // Runtime write for the GameStats-backed prefs: apply to the sim
            // and broadcast the new stats blob so client HUD values match.
            if (self.applyGamePrefSet(sp.name, sp.value)) {
                self.broadcastGameStats() catch {};
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &b,
                    "GamePref.{s} set to {s} (applied at runtime).\n",
                    .{ sp.name, sp.value },
                ) catch return;
                self.adminReply(s);
            } else {
                // Unknown or startup-only pref: honest read-only reply.
                var b: [160]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &b,
                    "GamePref.{s} is not runtime-writable on zdtd (set {s} in serverconfig.xml and restart).\n",
                    .{ sp.name, sp.name },
                ) catch return;
                self.adminReply(s);
            }
        },
        .chunkcache => self.adminWrite(admin_cmds.writeChunkCache, .{
            self.world.chunks.count(),
            @as(u64, self.world.chunks.count()) * @sizeOf(world_store.Chunk),
        }),
        .mem => self.replyMem(),
        .killall => {
            const n = self.consoleKillAll();
            // Also animals (consoleKillAll is zombies-only). No loot bags:
            // playtest clear_ai between combat and economy; loot floods the
            // client bag and fails bag_add_item / trader free-slot paths.
            var extra: u32 = 0;
            var s: ecs.Slot = 0;
            while (s < ecs.max_entities) : (s += 1) {
                if (!self.sim.alive[s] or self.sim.kind[s] != .animal) continue;
                const eid = self.sim.network_id[s].id;
                const dmg = self.sim.damage(eid, 99999);
                if (dmg.killed) {
                    if (packages.buildRemoveBody(&self.body_buf, eid)) |rm| {
                        self.broadcast("NetPackageEntityRemove", rm) catch {};
                    } else |_| {}
                    // Destroy any loot bag created by damage() without S2C spawn.
                    if (dmg.loot_bag_id > 0) {
                        if (self.sim.slotOfNetId(dmg.loot_bag_id)) |ls| {
                            if (self.sim.alive[ls]) self.sim.destroy(ls);
                        }
                    }
                    extra += 1;
                }
            }
            // Sweep existing ground loot so clear_ai leaves a clean field.
            var swept: u32 = 0;
            s = 0;
            while (s < ecs.max_entities) : (s += 1) {
                if (!self.sim.alive[s]) continue;
                if (self.sim.kind[s] != .loot_bag and !self.sim.mask[s].loot_bag) continue;
                const lid = self.sim.network_id[s].id;
                if (packages.buildRemoveBodyReason(&self.body_buf, lid, .despawned)) |rm| {
                    self.broadcast("NetPackageEntityRemove", rm) catch {};
                } else |_| {}
                self.sim.destroy(s);
                swept += 1;
            }
            var lb: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&lb, "killed {d}\n", .{n + extra + swept}) catch "killed\n";
            self.adminReply(msg);
        },
        .storm => self.adminReply(if (self.forceStorm()) "storm forced\n" else "no weather biomes\n"),
        .clearweather => self.adminReply(if (self.clearStorm()) "storm cleared\n" else "no weather biomes\n"),
        .spawnairdrop => self.adminReply(if (self.forceAirDrop()) "air drop spawned\n" else "no player to drop near\n"),
        .give => |g| {
            // Server-side inv writes get clobbered by the client's next C2S
            // PlayerInventory push. Stock-legal: drop a loot bag at the
            // player's feet; pickup runs the client-authoritative flow.
            const ps = self.sim.playerByPeer(g.peer) orelse {
                self.adminReply("no player in slot\n");
                return;
            };
            const t = self.sim.transform[ps];
            if (self.sim.spawnLootBag(t.x + 1, t.y, t.z + 1, g.item, g.count)) |nid| {
                self.broadcastLootSpawn(nid) catch {};
                self.adminReply("dropped at player\n");
            } else self.adminReply("give failed\n");
        },
        .tele => |t| {
            if (self.sim.playerByPeer(t.peer)) |ps| {
                self.sim.transform[ps] = .{ .x = t.x, .y = t.y, .z = t.z, .yaw = 0 };
                self.resetMoveEnvelopePeer(t.peer, t.x, t.y, t.z);
                const entity_id = self.sim.netId(ps);
                const body = packages.buildEntityTeleportBody(&self.body_buf, entity_id, t.x, t.y, t.z, 0, 0, 0, true) catch {
                    self.adminReply("teleport encode failed\n");
                    return;
                };
                self.broadcast("NetPackageEntityTeleport", body) catch {
                    self.adminReply("teleport send failed\n");
                    return;
                };
                self.adminReply("teleported\n");
            } else self.adminReply("no player in slot\n");
        },
        .say => |msg| {
            const body = packages.buildStockChat(&self.body_buf, 0, 0, msg, &.{}) catch return;
            self.broadcast("NetPackageChat", body) catch {};
            self.adminReply("sent\n");
        },
        .gettime => {
            const clk = &self.sim.director.clock;
            var tb2: [64]u8 = undefined;
            const hh: u32 = @trunc(clk.hours);
            const mm: u32 = @trunc((clk.hours - @floor(clk.hours)) * 60.0);
            const s = std.fmt.bufPrint(&tb2, "Day {d}, {d:0>2}:{d:0>2}\n", .{ clk.day, hh, mm }) catch return;
            self.adminReply(s);
        },
        .settime => |world_time| {
            // Stock world time: 24000 ticks/day, 1000/hour (asm.il 1926175).
            const clk = &self.sim.director.clock;
            clk.day = @intCast(world_time / 24000 + 1);
            const in_day = world_time % 24000;
            clk.hours = @as(f32, @floatFromInt(in_day)) / 1000.0;
            const wt = packages.buildWorldTimeBody(self.body_buf[0..16], clk.worldTimeBits()) catch return;
            self.broadcast("NetPackageWorldTime", wt) catch {};
            var b: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "Set time to {d}\n", .{world_time}) catch return;
            self.adminReply(s);
        },
        .spawnentity => |sp2| {
            const nm = line[sp2.name_off..][0..sp2.name_len];
            const def = self.entities.byName(nm) orelse {
                self.adminReply("unknown entity class\n");
                return;
            };
            // Accept peer slot (small) or stock player entity id (>= ~100).
            const ps: ?ecs.Slot = blk: {
                if (sp2.peer < max_clients) {
                    if (self.sim.playerByPeer(sp2.peer)) |s| break :blk s;
                }
                if (self.sim.slotOfNetId(@intCast(sp2.peer))) |s| {
                    if (self.sim.mask[s].player) break :blk s;
                }
                // First joined player fallback (playtest often only has one).
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined) continue;
                    if (self.sim.playerByPeer(i)) |s| break :blk s;
                }
                break :blk null;
            };
            const pslot = ps orelse {
                self.adminReply("no player in slot\n");
                return;
            };
            const tr = self.sim.transform[pslot];
            const sy = self.spawnYNearPlayer(tr.x, tr.y, tr.z);
            const sx = tr.x + 3;
            const sz = tr.z + 3;
            // Name-based vehicle/trader shortcuts (entityclasses often tags them as zombie).
            const low_vehicle = std.mem.find(u8, nm, "vehicle") != null or std.mem.find(u8, nm, "Bicycle") != null or std.mem.find(u8, nm, "Minibike") != null or std.mem.find(u8, nm, "Motorcycle") != null or std.mem.find(u8, nm, "4x4") != null or std.mem.find(u8, nm, "Truck") != null or std.mem.find(u8, nm, "Gyrocopter") != null;
            const nid = blk: {
                if (low_vehicle or def.kind == .vehicle) {
                    const vk: ecs.components.VehicleKind = if (std.mem.find(u8, nm, "Bicycle") != null or std.mem.find(u8, nm, "bicycle") != null)
                        .bicycle
                    else if (std.mem.find(u8, nm, "Minibike") != null or std.mem.find(u8, nm, "minibike") != null)
                        .minibike
                    else if (std.mem.find(u8, nm, "Motorcycle") != null or std.mem.find(u8, nm, "motorcycle") != null)
                        .motorcycle
                    else if (std.mem.find(u8, nm, "Gyro") != null or std.mem.find(u8, nm, "gyro") != null)
                        .gyrocopter
                    else
                        .four_by_four;
                    // Seats come from vehicles.xml when that kind is known,
                    // so a Truck4x4 gets four seats and not one.
                    const vd = self.vehicles.byKind(vk);
                    break :blk self.sim.spawnVehicleEx(
                        vk,
                        sx,
                        sy,
                        sz,
                        if (vd) |d| d.max_hp else 200,
                        if (vd) |d| d.velocity_max else 0,
                        if (vd) |d| d.seat_count else 1,
                    );
                }
                if (def.kind == .trader or std.mem.startsWith(u8, nm, "npcTrader")) {
                    break :blk self.sim.spawnTrader(nm, sx, sy, sz, self.npc.traderIdForClass(nm), self.trader_wallet_dukes);
                }
                if (def.kind == .animal) {
                    break :blk self.sim.spawnAnimalDef(sx, sy, sz, self.entityClassOf(def));
                }
                break :blk self.sim.spawnZombieDef(sx, sy, sz, def.max_hp, self.entityClassOf(def));
            };
            if (nid) |eid| {
                // Force clients to treat entity as unknown so next interest pass
                // sends ECD (playtest combat flake: spawn without client EntityAlive).
                if (self.sim.slotOfNetId(eid)) |es| {
                    for (&self.clients) |*cl| {
                        if (!cl.joined) continue;
                        cl.known_entities.unset(es);
                    }
                }
                self.adminReply("spawned\n");
                std.debug.print("zdtd: admin spawnentity {s} eid={d} y={d:.1} near peerArg={d}\n", .{ nm, eid, sy, sp2.peer });
            } else self.adminReply("spawn failed (capacity)\n");
        },
        .listents => {
            // ConsoleCmdListEntities (asm.il 230715) field order + total line.
            var n: usize = 0;
            var ei: ecs.Slot = 0;
            while (ei < ecs.max_entities) : (ei += 1) {
                if (!self.sim.alive[ei] or !self.sim.mask[ei].network_id) continue;
                const t = self.sim.transform[ei];
                self.adminWrite(admin_cmds.writeEntityRow, .{ n, admin_cmds.EntityRow{
                    .entity_id = self.sim.network_id[ei].id,
                    .name = @tagName(self.sim.kind[ei]),
                    .x = t.x,
                    .y = t.y,
                    .z = t.z,
                    .rot_y = t.yaw,
                    .dead = self.sim.mask[ei].health and self.sim.health[ei].hp <= 0,
                    .health = if (self.sim.mask[ei].health)
                        @trunc(self.sim.health[ei].hp)
                    else
                        null,
                } });
                n += 1;
            }
            self.adminWrite(admin_cmds.writeTotal, .{n});
        },
        .saveworld => {
            self.adminReply(if (self.saveAllStores()) "world saved\n" else "world save failed; see server log\n");
        },
        .shutdown => {
            self.adminReply("shutting down\n");
            self.running = false;
        },
        .version => self.adminReply("zdtd " ++ version.product ++ " (" ++ version.stock_wire ++ " wire)\n"),
        .inv => |peer_slot| {
            const ps = self.sim.playerByPeer(peer_slot) orelse {
                self.adminReply("no player in slot\n");
                return;
            };
            if (!self.sim.mask[ps].inventory) {
                self.adminReply("no inventory\n");
                return;
            }
            for (self.sim.inventory[ps].slots, 0..) |s, si| {
                if (s.count == 0) continue;
                var lb: [96]u8 = undefined;
                const out = std.fmt.bufPrint(&lb, "slot={d} item={d} count={d} q={d} meta={d}\n", .{
                    si, s.item_id, s.count, s.quality, s.meta,
                }) catch continue;
                self.adminReply(out);
            }
            self.adminReply("end\n");
        },
        .kill => |eid| {
            const was_zombie = blk: {
                if (self.sim.slotOfNetId(eid)) |ei|
                    break :blk self.sim.kind[ei] == .zombie or self.sim.kind[ei] == .animal;
                break :blk false;
            };
            const dmg = self.sim.damage(eid, 99999);
            if (!dmg.killed) {
                std.debug.print("zdtd: admin kill {d} missed (alive or unknown)\n", .{eid});
                self.adminReply("kill missed\n");
                return;
            }
            const is_player = blk: {
                if (self.sim.slotOfNetId(eid)) |ti| break :blk self.sim.mask[ti].player;
                break :blk false;
            };
            if (is_player) {
                // Push hp=0 stat so the client death flow triggers.
                if (packages.buildEntityStatBody(self.body_buf[512..640], eid, 0, 100)) |hb| {
                    self.broadcast("NetPackageEntityStatChanged", hb) catch {};
                } else |_| {}
                std.debug.print("zdtd: admin kill player entity={d} hp=0 sent\n", .{eid});
                self.adminReply("player killed\n");
                return;
            }
            const rm = packages.buildRemoveBody(&self.body_buf, eid) catch return;
            self.broadcast("NetPackageEntityRemove", rm) catch {};
            self.adminReply("killed\n");
            std.debug.print("zdtd: admin kill entity={d} remove sent\n", .{eid});
            if (was_zombie) {
                // quest credit to first joined peer if any
                for (&self.clients, 0..) |*cl, i| {
                    if (!cl.joined) continue;
                    systems.questOnZombieKilled(&self.sim, i);
                    systems.questOnFetchItem(&self.sim, i, 1);
                    break;
                }
            }
            if (dmg.loot_bag_id > 0) {
                self.fillLootBagFromTable(dmg.loot_bag_id, dmg.loot_list, @intCast(eid), self.partyLootStage());
                self.broadcastLootSpawn(dmg.loot_bag_id) catch {};
            }
        },
    }
}

pub fn dumpEvidenceFile(self: *Game, path: []const u8) !usize {
    var dump: [16384]u8 = undefined;
    const n = self.evidence.dumpText(&dump);
    try io_fs.writeFile(path, dump[0..n]);
    return self.evidence.n;
}

pub fn adminReplyGameStage(self: *Game, maybe_slot: ?usize) void {
    if (maybe_slot) |slot| {
        if (slot >= max_clients or !self.clients[slot].joined) {
            self.adminReply("no player in slot\n");
            return;
        }
    }
    var sb: [512]u8 = undefined;
    const now = self.sim.director.clock.worldTimeBits();
    var any = false;
    for (&self.clients, 0..) |*c, i| {
        if (!c.joined) continue;
        if (maybe_slot) |slot| if (i != slot) continue;
        any = true;
        const days = assets_gamestages.daysAlive(now, c.game_stage_born_world_time, c.level);
        const s = std.fmt.bufPrint(
            &sb,
            "slot={d} gamestage={d} lootstage={d} level={d} biome_mod=0 quest_mod=0 days_alive={d} " ++
                "biome_bonus=0 quest_bonus=0 difficulty_bonus={d:.3} global_modifier=1.000 born_at={d}\n",
            .{
                i,
                self.gameStageOf(i),
                self.lootStageOf(i),
                c.level,
                days,
                self.gamestages.config.difficulty_bonus,
                c.game_stage_born_world_time,
            },
        ) catch return;
        self.adminReply(s);
    }
    if (!any) {
        self.adminReply("no players joined\n");
        return;
    }
    const p = std.fmt.bufPrint(&sb, "party_stage={d} party_lootstage={d} world_time={d}\n", .{
        self.partyStageAround(0, 0, -1),
        self.partyLootStage(),
        now,
    }) catch return;
    self.adminReply(p);
}

pub fn adminReplyGuardPolicy(self: *Game) void {
    var sb: [512]u8 = undefined;
    const s = std.fmt.bufPrint(
        &sb,
        "policy enforce={d} dry_run={d} quarantine={d} load_shed={d} mode={s} window={d} strong_distinct={d} hard_repeat={d} quarantines={d} kicks={d} would_kicks={d} q_rejects={d} shed_drops={d} shed={d}\n",
        .{
            @intFromBool(self.guard.enforce),
            @intFromBool(self.guard.dry_run),
            @intFromBool(self.guard.quarantine),
            @intFromBool(self.guard.load_shed),
            @tagName(self.authority_mode),
            self.guard.window_ticks,
            self.guard.strong_distinct,
            self.guard.hard_repeat,
            self.harness.counters.get(.guard_quarantines),
            self.harness.counters.get(.guard_kicks),
            self.harness.counters.get(.guard_would_kicks),
            self.harness.counters.get(.quarantine_rejects),
            self.harness.counters.get(.load_shed_drops),
            @intFromBool(self.loadShedding()),
        },
    ) catch return;
    self.adminReply(s);

    var qb: [512]u8 = undefined;
    var pos: usize = 0;
    for (&self.clients, 0..) |*cl, i| {
        const q = cl.guard.quarantine;
        if (!q.any() and cl.guard.kick_at_tick == 0) continue;
        const line = std.fmt.bufPrint(qb[pos..], "  slot={d} no_damage={d} no_container={d} no_setblock={d} kick_at={d}\n", .{
            i,
            @intFromBool(q.no_damage),
            @intFromBool(q.no_container),
            @intFromBool(q.no_setblock),
            cl.guard.kick_at_tick,
        }) catch break;
        pos += line.len;
    }
    if (pos > 0) self.adminReply(qb[0..pos]);
}

test "auditVerb keeps an injected verb on one audit line" {
    var buf: [max_audit_verb_len]u8 = undefined;
    // A client-sent verb carrying CRLF would otherwise forge a second record.
    const n = auditVerb(&buf, "help\r\nzdtd: audit source=admin command=ban");
    try std.testing.expect(n <= max_audit_verb_len);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "help"));
    try std.testing.expect(std.mem.findScalar(u8, buf[0..n], '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, buf[0..n], '\r') == null);
}
