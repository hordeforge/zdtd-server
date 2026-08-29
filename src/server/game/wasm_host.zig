//! Wasm host shims for Game — callbacks the plugin layer calls back into.
//! Extracted verbatim so game.zig keeps only a re-export.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const plugin_mod = @import("../../plugin/root.zig");
const ecs = @import("../../ecs/root.zig");
const c2s_text = @import("../c2s_text.zig");
const nav = @import("../../world/nav.zig");
const game_step = @import("step.zig");

const wasm_log_level_tags = [_][]const u8{ "debug", "info", "warn", "err" };

/// Fail closed on out-of-range query coordinates. parseFloat can yield a
/// finite value far beyond the i32 range the nav/ground probes cast into, or
/// NaN/Inf; any of those returns no answer, never a cast (the @trunc
/// traps on the same values the C2S movement envelope rejects).
fn queryCoordLegal(v: f32) bool {
    return game_mod.coordInRange(v);
}

/// Bytes of guest text kept per `zdtd_log` call. Plugin hooks receive player
/// names and chat bodies, so an unbounded guest string could dump payloads of
/// player data into the operator log; the cap bounds one line's exposure.
pub const max_wasm_log_len: usize = 200;

/// Plugin callbacks receive the `*Game` installed at WasmHost.init as
/// `HostCtx.data` or the kill-verdict `anyopaque` ctx.
fn gameFromPtr(ptr: *anyopaque) *Game {
    return @ptrCast(@alignCast(ptr));
}

pub fn wasmLog(ctx: *plugin_mod.wasm.HostCtx, level: u8, msg: []const u8) void {
    _ = ctx;
    const tag = wasm_log_level_tags[@min(@as(usize, level), wasm_log_level_tags.len - 1)];
    // Guest-controlled bytes: C0/DEL would let a plugin forge whole log lines
    // (the operator audit trail is line-oriented stderr), so reuse the C2S text
    // sanitizer, which also drops invalid UTF-8 and truncates on a codepoint.
    var line: [max_wasm_log_len]u8 = undefined;
    const n = c2s_text.sanitizePlayerName(&line, msg);
    std.debug.print("zdtd wasm: {s}: {s}\n", .{ tag, line[0..n] });
}

pub fn wasmTick(ctx: *plugin_mod.wasm.HostCtx) u64 {
    const g = gameFromPtr(ctx.data orelse return 0);
    return g.tick_n;
}

pub fn killVerdict(ctx: ?*anyopaque, kind: ecs.Kind, victim: i32, attacker: i32) i32 {
    const g = gameFromPtr(ctx orelse return 0);
    return switch (kind) {
        .player => blk: {
            const sv = g.plugins.playerDeath(victim);
            break :blk if (sv != 0) sv else g.wasm_plugins.playerDeath(victim);
        },
        else => blk: {
            const sv = g.plugins.entityKilled(victim, attacker);
            break :blk if (sv != 0) sv else g.wasm_plugins.entityKilled(victim, attacker);
        },
    };
}

pub const max_plugin_cmd_len: usize = 128;

/// Owner callback for HostCtx.withdraw_fn: drop this src's pending commands
/// and applied spawns/bots. Invoked by WasmHost.reload after on_shutdown.
pub fn wasmWithdraw(ctx: *plugin_mod.wasm.HostCtx, src: i16) void {
    const g = gameFromPtr(ctx.data orelse return);
    game_step.withdrawPluginSrc(g, src);
}

/// World.pre_drain_fn: withdraw every plugin that disabled itself since the
/// last pass, immediately before drainCommands applies queued ops.
pub fn withdrawDisabled(ctx: ?*anyopaque) void {
    const g = gameFromPtr(ctx orelse return);
    game_step.withdrawDisabledPlugins(g);
}

pub fn wasmQueue(ctx: *plugin_mod.wasm.HostCtx, src: i16, cmd: []const u8) void {
    const g = gameFromPtr(ctx.data orelse return);
    if (cmd.len > max_plugin_cmd_len) {
        std.debug.print("zdtd wasm: queued command too long ({d} bytes); dropped\n", .{cmd.len});
        return;
    }
    // `bot <verb>` commands are host-side BotManager calls (ADR 0026), not ECS
    // ops: the BotManager owns spawn/move/look/shoot/remove/count and returns
    // true for any command starting with `bot `. Everything else falls through
    // to the ECS plugin verbs (spawn/despawn/damage).
    if (g.bots.handleCommand(g, cmd, src)) return;
    const op = parsePluginCommand(cmd) orelse {
        const verb_end = std.mem.findScalar(u8, cmd, ' ') orelse cmd.len;
        // Guest-controlled bytes: same one-line rule as wasmLog above.
        var vb: [64]u8 = undefined;
        const vn = c2s_text.sanitizePlayerName(&vb, cmd[0..verb_end]);
        std.debug.print("zdtd wasm: unknown queued command '{s}'\n", .{vb[0..vn]});
        return;
    };
    _ = g.sim.commands.pushSrc(src, op);
}

fn parsePluginCommand(cmd: []const u8) ?ecs.command.Op {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const verb = it.next() orelse return null;
    if (std.mem.eql(u8, verb, "say")) {
        // The rest of the line (after the first space) is the message; the
        // tokenizer would split it, so slice the raw remainder.
        const sp = std.mem.findScalar(u8, cmd, ' ') orelse return null;
        const msg = std.mem.trim(u8, cmd[sp + 1 ..], " \t\r\n");
        if (msg.len == 0) return null;
        var op = ecs.command.Op{ .say = .{ .text = undefined, .len = 0 } };
        const n = @min(msg.len, op.say.text.len);
        @memcpy(op.say.text[0..n], msg[0..n]);
        op.say.len = @intCast(n);
        return op;
    }
    if (std.mem.eql(u8, verb, "spawn")) {
        const x = it.next() orelse return null;
        const y = it.next() orelse return null;
        const z = it.next() orelse return null;
        const hp = it.next() orelse return null;
        if (it.next() != null) return null;
        const fx = std.fmt.parseFloat(f32, x) catch return null;
        const fy = std.fmt.parseFloat(f32, y) catch return null;
        const fz = std.fmt.parseFloat(f32, z) catch return null;
        const fhp = std.fmt.parseFloat(f32, hp) catch return null;
        // Same ceiling as C2S movement: a spawn coordinate beyond it lands the
        // transform outside the i32 range the tick path casts into. Fail closed
        // like a parse error (command dropped, never applied).
        if (!queryCoordLegal(fx) or !queryCoordLegal(fy) or !queryCoordLegal(fz)) return null;
        if (!std.math.isFinite(fhp) or fhp < 0) return null;
        return .{ .spawn_zombie = .{
            .x = fx,
            .y = fy,
            .z = fz,
            .hp = fhp,
        } };
    }
    if (std.mem.eql(u8, verb, "despawn")) {
        const id = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .despawn = .{ .net_id = std.fmt.parseInt(i32, id, 10) catch return null } };
    }
    if (std.mem.eql(u8, verb, "damage")) {
        const id = it.next() orelse return null;
        const amt = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{ .damage = .{
            .net_id = std.fmt.parseInt(i32, id, 10) catch return null,
            .amount = std.fmt.parseFloat(f32, amt) catch return null,
        } };
    }
    if (std.mem.eql(u8, verb, "glide")) {
        // ADR 0037: `glide <net_id> <0|1>` arms/clears the player's glide
        // window (movement-envelope exemption). `1`/`on`/`true` arm.
        const id = it.next() orelse return null;
        const on = it.next() orelse return null;
        if (it.next() != null) return null;
        const on_b = std.mem.eql(u8, on, "1") or std.mem.eql(u8, on, "on") or std.mem.eql(u8, on, "true");
        if (!on_b and !std.mem.eql(u8, on, "0") and !std.mem.eql(u8, on, "off") and !std.mem.eql(u8, on, "false")) return null;
        return .{ .glide = .{
            .net_id = std.fmt.parseInt(i32, id, 10) catch return null,
            .on = on_b,
        } };
    }
    return null;
}

/// Build a fixed-layout world snapshot for a `zdtd.sense` call (RFC 0001 §3).
/// Header (24 bytes: magic/count/tick/self_net_id/world_time/blood_moon)
/// then fixed 32-byte entity records, then an optional 16-byte event trailer
/// (bot-info records kind 4, then damage events kind 3); all little-endian.
/// Returns bytes written; 0 when `out` cannot fit a header.
/// No heap on the tick path.
pub const sense_header_len: usize = 24;

pub fn wasmSense(ctx: *plugin_mod.wasm.HostCtx, out: []u8) usize {
    const g = gameFromPtr(ctx.data orelse return 0);
    if (out.len < sense_header_len) return 0;
    // Reserve room for the event trailer up front so a full record set still
    // leaves space for it (the guest parses the trailer after the records; a
    // truncated tail would desync its offsets).
    const bot_mod = @import("bot.zig");
    const trailer_cap = (bot_mod.max_sense_info + bot_mod.max_sense_events) * bot_mod.sense_event_len;
    const rec_len = bot_mod.sense_record_len;
    const max_records = if (out.len >= sense_header_len + trailer_cap) (out.len - sense_header_len - trailer_cap) / rec_len else (out.len - sense_header_len) / rec_len;
    std.mem.writeInt(u32, out[0..4], 0x3453425a, .little); // 'ZBS4' (v4: vy + wearing_glider per record)
    std.mem.writeInt(u32, out[4..8], 0, .little); // count, filled below
    // Header ABI is u32; tick and world-time wrap at 2^32 by design.
    std.mem.writeInt(u32, out[8..12], @truncate(g.tick_n), .little);
    std.mem.writeInt(i32, out[12..16], 0, .little); // self_net_id
    // v3+: world ticks (low 32) + blood-moon flag, so announcement/clock
    // modules can schedule from the header without a separate query.
    std.mem.writeInt(u32, out[16..20], @truncate(g.sim.director.clock.worldTimeBits()), .little);
    std.mem.writeInt(u32, out[20..24], @as(u32, @intFromBool(g.sim.director.bloodmoon_active)), .little);
    var n: usize = 0;
    var s: ecs.Slot = 0;
    while (s < ecs.max_entities and n < max_records) : (s += 1) {
        if (!g.sim.alive[s] or !g.sim.mask[s].network_id) continue;
        const k: u8 = switch (g.sim.kind[s]) {
            .player => 0,
            // Zombies and animals share the hostile bucket in the guest.
            .zombie, .animal => 1,
            // Non-combat world objects are not combat candidates; omit.
            .trader, .vehicle, .turret, .loot_bag, .falling_block => continue,
        };
        const base = sense_header_len + n * rec_len;
        const r = out[base .. base + rec_len];
        std.mem.writeInt(i32, r[0..4], g.sim.network_id[s].id, .little);
        r[4] = k;
        r[5] = 0; // self
        r[6] = @intFromBool(g.sim.health[s].hp > 0); // alive
        r[7] = 0; // pad
        const t = &g.sim.transform[s];
        std.mem.writeInt(u32, r[8..12], @bitCast(t.x), .little);
        std.mem.writeInt(u32, r[12..16], @bitCast(t.y), .little);
        std.mem.writeInt(u32, r[16..20], @bitCast(t.z), .little);
        std.mem.writeInt(u32, r[20..24], @bitCast(g.sim.health[s].hp), .little);
        std.mem.writeInt(u32, r[24..28], @bitCast(t.yaw), .little);
        // v4 (ADR 0037): server-derived vertical velocity (blocks/s) from the
        // C2S position history (Client.vy_blocks_per_s); 0 when no peer.
        var vy: i32 = 0;
        if (k == 0) {
            if (g.sim.player[s].peer_slot >= 0 and g.sim.player[s].peer_slot < game_mod.max_clients) {
                vy = @intFromFloat(g.clients[@intCast(g.sim.player[s].peer_slot)].vy_blocks_per_s);
            }
        }
        std.mem.writeInt(i32, r[28..32], vy, .little);
        std.mem.writeInt(i32, r[32..36], -1, .little); // target_id
        // v4: wearing_glider — the player's armor slots (55..66) carry an item
        // whose items.xml Tags include `[rules.glide] item_tag` (ADR 0037).
        var wearing: u8 = 0;
        if (k == 0 and g.sim.rules.glide.item_tag.len > 0) {
            if (g.sim.mask[s].inventory) {
                const inv = &g.sim.inventory[s];
                var ei: usize = ecs.components.inv_equip_start;
                while (ei < ecs.components.inv_equip_start + ecs.components.inv_equip_count) : (ei += 1) {
                    const sl = inv.slots[ei];
                    if (sl.item_id == 0 or sl.count == 0) continue;
                    const def = g.items.byId(sl.item_id) orelse continue;
                    if (hasTag(def.tags, g.sim.rules.glide.item_tag)) {
                        wearing = 1;
                        break;
                    }
                }
            }
        }
        r[36] = wearing;
        n += 1;
    }
    // Host-side bots (ADR 0026) are not ECS entities; append them after the
    // ECS actor records as kind==2, sharing the same 32-byte record layout.
    // fillSense offsets by its own running `n` (which already counts the ECS
    // actor records), so base must be the header end (16), NOT 16 + n*32 —
    // the latter double-offsets the bot records past the copied region.
    g.bots.fillSense(out, sense_header_len, max_records, &n);
    // Event trailer (RFC 0001 §3): kind-4 bot-info records first (the guest's
    // weapon map), then kind-3 damage events (attributed hits since the last
    // sense pass — the guest keys on victim == its own bot net id to
    // retaliate).
    const ev_base = sense_header_len + n * rec_len;
    const info_n = g.bots.fillSenseBotInfo(out, ev_base, bot_mod.max_sense_info);
    var ev_n: usize = 0;
    const ev_base2 = ev_base + info_n * bot_mod.sense_event_len;
    if (ev_base2 + bot_mod.sense_event_len <= out.len) {
        ev_n = g.bots.drainSenseEvents(out, ev_base2, bot_mod.max_sense_events);
    }
    std.mem.writeInt(u32, out[4..8], @intCast(n), .little);
    return sense_header_len + n * rec_len + (info_n + ev_n) * bot_mod.sense_event_len;
}

/// True when the comma-separated item Tags string contains `tag`
/// (ADR 0037 glider detection; case-sensitive like stock FastTags).
fn hasTag(tags: []const u8, tag: []const u8) bool {
    if (tags.len == 0 or tag.len == 0) return false;
    var it = std.mem.splitScalar(u8, tags, ',');
    while (it.next()) |t| {
        if (std.mem.eql(u8, std.mem.trim(u8, t, " \t"), tag)) return true;
    }
    return false;
}

/// `zdtd.query(req_ptr, req_len, out_ptr, out_cap)` — reverse-direction point
/// query (RFC 0001 §3; the sense `token` stays reserved). The guest writes a
/// text request, the host writes a text response into the guest's out buffer
/// and returns bytes written (0 = no answer). Requests are host-budgeted
/// (small, text-parsed) and never mutate the sim.
///
///   "cover <x> <z> <tx> <tz>"  -> "<cx> <cz>" (a point near (x,z) not visible
///                                 from (tx,tz)), or "" when none exists.
///   "kind <net_id>"            -> "0" player, "1" zombie/animal, "2" bot, or
///                                 "" when the id is unknown/absent (lets
///                                 plugins classify an attacker/victim, e.g.
///                                 PvP/friendly-fire policies).
///   "quest <def_id>"           -> the quest def's name (stable key), or ""
///                                 when unknown (lets plugins gate by name).
/// MCP frame handler (mcp_transport.FrameFn): route one client JSON-RPC
/// frame to the first plugin that exports on_mcp_frame; returns the guest's
/// response bytes (0 = no MCP module / nothing to send). The transport owns
/// the HTTP; this is the boundary crossing (ADR 0031 D3).
pub fn mcpFrameThunk(ctx: *anyopaque, frame: []const u8, out: []u8) usize {
    const g = gameFromPtr(ctx);
    for (g.wasm_plugins.slots[0..g.wasm_plugins.n]) |*p| {
        if (p.hook_present[@intFromEnum(plugin_mod.wasm.Hook.on_mcp_frame)]) {
            const rep = p.callMcpFrame(frame, out) orelse return 0;
            return rep.len;
        }
    }
    return 0;
}

pub fn wasmQuery(ctx: *plugin_mod.wasm.HostCtx, req: []const u8, out: []u8) usize {
    const g = gameFromPtr(ctx.data orelse return 0);
    var it = std.mem.tokenizeScalar(u8, req, ' ');
    const verb = it.next() orelse return 0;
    if (std.mem.eql(u8, verb, "mcp.allowlist")) {
        if (it.next() != null) return 0;
        // Comma-separated verb prefixes from [mcp] config, served one per
        // line (the MCP guest matches verb prefixes against these lines).
        var src = g.mcp_allowlist;
        var n: usize = 0;
        while (src.len > 0) {
            const comma = std.mem.findScalar(u8, src, ',') orelse src.len;
            const piece = std.mem.trim(u8, src[0..comma], " \t");
            if (piece.len > 0) {
                if (n > 0 and n < out.len) {
                    out[n] = '\n';
                    n += 1;
                }
                const m = @min(piece.len, out.len - n);
                @memcpy(out[n..][0..m], piece[0..m]);
                n += m;
            }
            if (comma >= src.len) break;
            src = src[comma + 1 ..];
        }
        return n;
    }
    if (std.mem.eql(u8, verb, "quest")) {
        const id_s = it.next() orelse return 0;
        if (it.next() != null) return 0;
        const id = std.fmt.parseInt(u16, id_s, 10) catch return 0;
        const d = g.sim.catalog.byId(id) orelse return 0;
        const n = @min(d.name.len, out.len);
        @memcpy(out[0..n], d.name[0..n]);
        return n;
    }
    if (std.mem.eql(u8, verb, "kind")) {
        const id_s = it.next() orelse return 0;
        if (it.next() != null) return 0;
        const id = std.fmt.parseInt(i32, id_s, 10) catch return 0;
        const k: u8 = if (g.bots.find(id) != null)
            2
        else if (g.sim.slotOfNetId(id)) |es| switch (g.sim.kind[es]) {
            .player => 0,
            .zombie, .animal => 1,
            else => return 0,
        } else return 0;
        out[0] = '0' + k;
        return 1;
    }
    if (!std.mem.eql(u8, verb, "cover")) {
        if (std.mem.eql(u8, verb, "path")) return wasmQueryPath(g, &it, out);
        return 0;
    }
    const sx = it.next() orelse return 0;
    const sz = it.next() orelse return 0;
    const tx = it.next() orelse return 0;
    const tz = it.next() orelse return 0;
    if (it.next() != null) return 0;
    const fx = std.fmt.parseFloat(f32, sx) catch return 0;
    const fz = std.fmt.parseFloat(f32, sz) catch return 0;
    const thx = std.fmt.parseFloat(f32, tx) catch return 0;
    const thz = std.fmt.parseFloat(f32, tz) catch return 0;
    if (!queryCoordLegal(fx) or !queryCoordLegal(fz) or !queryCoordLegal(thx) or !queryCoordLegal(thz)) return 0;
    const from: [3]f32 = .{ fx, g.groundHeight(@floor(fx), @floor(fz)), fz };
    const threat: [3]f32 = .{ thx, g.groundHeight(@floor(thx), @floor(thz)), thz };
    const cv = g.findCover(from, threat, 10.0) orelse return 0;
    const s = std.fmt.bufPrint(out, "{d} {d}", .{ cv[0], cv[2] }) catch return 0;
    return s.len;
}

/// `path <sx> <sz> <tx> <tz>` — nav-grid waypoints from the source to the
/// target in world block coords. Response: `<n> <x1> <z1> ... <xn> <zn>` (cell
/// centers), or empty when no path / a cell is unwalkable / the chunk is not
/// loaded. The guest buffer must hold the full response (see QRY_PATH_CAP).
fn wasmQueryPath(g: *Game, it: *std.mem.TokenIterator(u8, .scalar), out: []u8) usize {
    const sx = it.next() orelse return 0;
    const sz = it.next() orelse return 0;
    const tx = it.next() orelse return 0;
    const tz = it.next() orelse return 0;
    if (it.next() != null) return 0;
    const fx = std.fmt.parseFloat(f32, sx) catch return 0;
    const fz = std.fmt.parseFloat(f32, sz) catch return 0;
    const thx = std.fmt.parseFloat(f32, tx) catch return 0;
    const thz = std.fmt.parseFloat(f32, tz) catch return 0;
    if (!queryCoordLegal(fx) or !queryCoordLegal(fz) or !queryCoordLegal(thx) or !queryCoordLegal(thz)) return 0;
    const scx = @divFloor(@as(i32, @trunc(fx)), nav.cell_size);
    const scz = @divFloor(@as(i32, @trunc(fz)), nav.cell_size);
    const tcx = @divFloor(@as(i32, @trunc(thx)), nav.cell_size);
    const tcz = @divFloor(@as(i32, @trunc(thz)), nav.cell_size);
    var cells: [nav.max_waypoints]nav.Cell = undefined;
    const n = nav.findPath(&g.world, scx, scz, tcx, tcz, &cells);
    if (n == 0) return 0;
    var w = std.Io.Writer.fixed(out);
    w.print("{d}", .{n}) catch return 0;
    for (cells[0..n]) |c| {
        const wx = c.x * nav.cell_size + nav.cell_size / 2;
        const wz = c.z * nav.cell_size + nav.cell_size / 2;
        w.print(" {d} {d}", .{ wx, wz }) catch return 0;
    }
    return w.buffered().len;
}

/// `plugin list` / `plugin reload <name>` (paper: hot module replacement).
pub fn adminPlugin(self: *Game, rest: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    const sub = it.next() orelse {
        self.adminReply("usage: plugin <list|reload <name>>\n");
        return;
    };
    if (std.mem.eql(u8, sub, "list")) {
        const h = &self.wasm_plugins;
        if (h.n == 0) {
            self.adminReply("no wasm plugins loaded\n");
            return;
        }
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (0..h.n) |i| {
            const p = &h.slots[i];
            const st: []const u8 = if (p.disabled) "disabled" else "enabled";
            const tier_s: []const u8 = switch (p.tier) {
                .core => "core",
                .official => "official",
                .user => "user",
            };
            // Legacy [plugin] modules have no manifest name; fall back to path.
            const nm: []const u8 = if (p.display.len > 0) p.display else p.name;
            w.print("{d}: {s} [{s}, {s}]\n", .{ i, nm, tier_s, st }) catch break;
        }
        self.adminReply(w.buffered());
        return;
    }
    if (std.mem.eql(u8, sub, "reload")) {
        const name = it.next() orelse {
            self.adminReply("usage: plugin reload <name>\n");
            return;
        };
        const idx = self.wasm_plugins.findByName(name) orelse {
            var eb: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&eb, "no loaded plugin matches '{s}'\n", .{name}) catch return;
            self.adminReply(s);
            return;
        };
        const path = self.wasm_plugins.slots[idx].name;
        // Paper HMR: withdraw applied spawns before dispose so the dying
        // module's entities are gone before on_shutdown. reload then
        // withdraws again after on_shutdown (HostCtx.withdraw_fn) so anything
        // queued during shutdown cannot land on the replacement.
        const src: i16 = @intCast(idx + 1);
        game_step.withdrawPluginSrc(self, src);
        const n_before = self.wasm_plugins.n;
        const ok = self.wasm_plugins.reload(idx, path);
        // A failed reload drops the slot and later modules compact: remap
        // remaining command/bot srcs so later withdrawal still matches.
        if (!ok and self.wasm_plugins.n < n_before) {
            self.sim.commands.shiftSrcsAfter(src);
            self.bots.shiftSrcsAfter(src);
        }
        self.adminReply(if (ok) "plugin reloaded\n" else "plugin reload failed; see server log\n");
        return;
    }
    self.adminReply("usage: plugin <list|reload <name>>\n");
}

test "plugin queue verbs fail closed on out-of-range coordinates" {
    // ECS spawn: absurd-but-finite coords, NaN and negative hp are dropped
    // like parse errors, never queued into the sim.
    try std.testing.expect(parsePluginCommand("spawn 3e38 3e38 3e38 100") == null);
    try std.testing.expect(parsePluginCommand("spawn nan 70 0 100") == null);
    try std.testing.expect(parsePluginCommand("spawn 0 70 0 nan") == null);
    try std.testing.expect(parsePluginCommand("spawn 0 70 0 -5") == null);
    const ok = parsePluginCommand("spawn 0 70 0 100") orelse return error.MissingOp;
    switch (ok) {
        .spawn_zombie => |z| {
            try std.testing.expectEqual(@as(f32, 70), z.y);
            try std.testing.expectEqual(@as(f32, 100), z.hp);
        },
        else => return error.WrongOp,
    }

    // The query guard rejects the same value classes the movement envelope
    // does: huge finite, NaN and Inf.
    try std.testing.expect(!queryCoordLegal(3e38));
    try std.testing.expect(!queryCoordLegal(std.math.nan(f32)));
    try std.testing.expect(!queryCoordLegal(std.math.inf(f32)));
    try std.testing.expect(queryCoordLegal(0));
    try std.testing.expect(queryCoordLegal(game_mod.max_player_coord));
    try std.testing.expect(!queryCoordLegal(-game_mod.max_player_coord - 1));
}
