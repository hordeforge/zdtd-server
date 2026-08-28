//! Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate
//! it under fuel and memory budgets, register the minimal host import table,
//! and call the optional guest hooks (`Hook`: lifecycle plus the verdict and
//! text hooks documented in docs/PLUGIN_DEV.md).
//! Data crosses as flat bytes in the guest's linear memory; no host pointer
//! reaches a guest and WASI is deliberately not provided.
//!
//! Non-goals: WASI, JIT, any hook the host table does not expose.

const std = @import("std");
const zwasm = @import("zwasm");
const io_fs = @import("../util/io_fs.zig");
const manifest = @import("manifest.zig");
const resolver = @import("resolver.zig");

/// Sentinel in WasmHost.claims: no module exclusively owns the point.
pub const no_claim: u8 = 0xFF;

pub const Hook = enum(u8) {
    on_enable = 0,
    on_tick = 1,
    on_player_join = 2,
    on_shutdown = 3,
    on_player_death = 4,
    on_entity_killed = 5,
    on_block_damage = 6,
    on_quest_complete = 7,
    on_admin_command = 8,
    on_chat = 9,
    on_player_login = 10,
    on_player_leave = 11,
    on_player_damage = 12,
    on_quest_accept = 13,
    on_craft_request = 14,
    on_loot_roll = 15,
    on_trader_event = 16,
    on_mcp_frame = 17,
    on_trade_price = 18,
    on_perk_spend = 19,
    on_stat_changed = 20,
    on_game_event = 21,

    pub const names = [_][]const u8{
        "on_enable",        "on_tick",          "on_player_join",   "on_shutdown",
        "on_player_death",  "on_entity_killed", "on_block_damage",  "on_quest_complete",
        "on_admin_command", "on_chat",          "on_player_login",  "on_player_leave",
        "on_player_damage", "on_quest_accept",  "on_craft_request", "on_loot_roll",
        "on_trader_event",  "on_mcp_frame",     "on_trade_price",   "on_perk_spend",
        "on_stat_changed",  "on_game_event",
    };
};

/// Host import field names under the `zdtd` module (`defineImports`). Keep in
/// sync with the `linker.defineFuncCtx` list: a new import that is missing
/// here is an undeclarable capability (`_zdtd_requires` would reject it).
pub const host_verbs = [_][]const u8{
    "log",        "tick",     "queue",    "sense",    "query",
    "json_parse", "json_str", "json_raw", "json_obj",
};

/// Verdict convention for the event hooks (T15 / PLUGIN_DEV.md): a return
/// below 0 denies the proposed outcome (death cancelled, damage not applied,
/// quest rewards withheld); 0 keeps today's behaviour; above 0 adjusts as a
/// percent (block damage applied and quest rewards paid at that percentage).
/// A module that does not export the hook costs nothing (missing export -> 0).
pub const verdict_deny: i32 = -1;
pub const verdict_keep: i32 = 0;

/// Per-instance budget: fuel is armed once at instantiate and decremented
/// per instruction, never re-armed (zwasm source; verified by the looper
/// fixture). A module spending ~10k fuel per tick silently disables after
/// minutes at the default. zwasm enforces both itself; an exhausted or
/// trapping module is disabled, other modules keep running.
pub const Budget = struct {
    fuel: u64 = 100_000_000,
    max_memory_pages: u64 = 1024,
};

/// Host context reachable from guest imports via Caller.data. The guest sees
/// only the import table; this struct is the host side of those calls.
/// Callbacks receive the HostCtx back so the owner (game.zig) can recover its
/// own state from `data`. This file never dereferences `data`; the owner casts.
/// Ceiling on one `zdtd.sense` snapshot (RFC 0001 §3). The guest requests up
/// to this much; the host never writes past it into the guest.
pub const host_sense_max: usize = 2048;
/// Ceiling on one `zdtd.query` response (RFC 0001 §3). The host never writes
/// past this into the guest.
pub const query_resp_max: usize = 64;
/// Fixed buffer per plugin for the std.json capability (ADR 0031): one parsed
/// JSON-RPC frame per plugin at a time, lazily allocated, reset per frame, so
/// the tick path never touches the heap. Fail closed at the cap. The buffer
/// also bounds nesting: std.json's parse allocates O(depth) and an extremely
/// nested doc exhausts the fixed buffer (parse error) instead of growing.
pub const json_buf_max: usize = 64 * 1024;

pub const HostCtx = struct {
    /// Owner state (a *Game in the server); cast by the callbacks the owner
    /// installs. Keeps this layer free of a Game dependency.
    data: ?*anyopaque = null,
    log_fn: *const fn (ctx: *HostCtx, level: u8, msg: []const u8) void,
    tick_fn: *const fn (ctx: *HostCtx) u64,
    /// `src` is the 1-based wasm slot the queued command came from (0 = not
    /// attributable). The owner uses it to withdraw a disabled plugin's
    /// pending effects (paper: temporal composability).
    queue_fn: *const fn (ctx: *HostCtx, src: i16, cmd: []const u8) void,
    /// Owner withdraws `src` after a plugin's `on_shutdown` (reload) so
    /// commands queued during shutdown and applied spawns do not outlive the
    /// disposed instance. Null in tests that do not own a command buffer.
    withdraw_fn: ?*const fn (ctx: *HostCtx, src: i16) void = null,
    /// Build a read-only world snapshot into `out`, returning bytes written.
    /// 0 when the owner has no sense (a plain event plugin). Signature keeps
    /// this layer free of a Game dependency; the owner casts via `data`.
    sense_fn: ?*const fn (ctx: *HostCtx, out: []u8) usize = null,
    /// Reverse-direction point query (RFC 0001 §3): the guest writes a text
    /// request (e.g. `cover x z tx tz`) and the host writes a text response,
    /// returning bytes written (0 = no answer / unknown query). Null when the
    /// owner has no query surface.
    query_fn: ?*const fn (ctx: *HostCtx, req: []const u8, out: []u8) usize = null,
    /// Runtime pointers of loaded instances, 1:1 with WasmHost slots. The
    /// queue import matches Caller.rt against this table to attribute a queued
    /// command to its plugin (slot index + 1; 0 = unattributed).
    rt_slot: [max_wasm_plugins]?*anyopaque = .{null} ** max_wasm_plugins,
    /// Plugin pointers, 1:1 with rt_slot: lets the host imports (std.json
    /// capability) reach a loaded plugin's per-instance state from a Caller.
    plugin_slot: [max_wasm_plugins]?*anyopaque = .{null} ** max_wasm_plugins,
};

pub const LoadError = error{
    ParseFailed,
    ImportForbidden,
    InstantiateFailed,
    OutOfMemory,
};

/// A loaded plugin: one instance, its hook presence flags, and a disabled bit.
pub const Plugin = struct {
    allocator: std.mem.Allocator,
    /// Heap-allocated: Linker (and friends) store `engine: *_Engine`, so the
    /// Engine must not move once derived handles exist.
    engine: *zwasm.Engine,
    module: zwasm.Module,
    /// The linker owns the host-import trampolines (`ctx_storage`); it must
    /// outlive every call the instance makes, so Plugin keeps it (canonical
    /// zwasm pattern: linker.deinit after instance.deinit).
    linker: zwasm.Linker,
    instance: zwasm.Instance,
    name: []const u8,
    /// PRD 0005: tier from mod.toml (default user for legacy [plugin] modules).
    tier: manifest.Tier = .user,
    /// PRD 0005: manifest name (duped at loadResolved; "" for legacy modules,
    /// which fall back to the path in `name`).
    display: []const u8 = "",
    /// Set when a hook traps or exhausts fuel: the module stops being called.
    disabled: bool = false,
    hook_present: [@typeInfo(Hook).@"enum".fields.len]bool = .{false} ** @typeInfo(Hook).@"enum".fields.len,
    /// Declarative dependency check (paper: reactive coeffects): `_zdtd_requires`
    /// returns a comma-separated list of capabilities (hook names + host verbs
    /// log/tick/queue/sense/query). Unknown or missing capabilities fail the
    /// load loudly instead of failing lazily at the first call.
    requires_failed: bool = false,
    requires_err: [128]u8 = undefined,
    requires_err_len: usize = 0,
    /// Guest offset and size of the host's scratch region for the request/reply
    /// hooks (admin command, chat, login). Reserved lazily; 0/0 until first use.
    scratch_off: u32 = 0,
    scratch_len: usize = 0,
    /// std.json capability (ADR 0031, RFC 0002 §5): the host parses the
    /// guest's JSON-RPC frame with std.json once into a lazily allocated fixed
    /// buffer (json_buf_max), so the tick path never allocates. One parsed doc
    /// per plugin at a time (frames are processed one at a time); a new
    /// json_parse replaces the previous doc.
    json_buf: ?[]u8 = null,
    json_fba: std.heap.FixedBufferAllocator = undefined,
    json_value: ?std.json.Value = null,

    pub fn load(
        allocator: std.mem.Allocator,
        name: []const u8,
        wasm_bytes: []const u8,
        ctx: *HostCtx,
        budget: Budget,
    ) LoadError!Plugin {
        const engine_ptr = allocator.create(zwasm.Engine) catch return error.OutOfMemory;
        errdefer allocator.destroy(engine_ptr);
        engine_ptr.* = zwasm.Engine.init(allocator, .{}) catch return error.OutOfMemory;
        errdefer engine_ptr.deinit();
        var module = engine_ptr.compile(wasm_bytes) catch return error.ParseFailed;
        errdefer module.deinit();
        var linker = engine_ptr.linker();
        errdefer linker.deinit();
        defineImports(&linker, ctx) catch return error.ImportForbidden;
        var instance = linker.instantiate(&module, .{
            .fuel = .{ .limited = budget.fuel },
            .max_memory_pages = .{ .limited = budget.max_memory_pages },
        }) catch |err| {
            std.debug.print("zdtd: wasm instantiate failed: {s}\n", .{@errorName(err)});
            return error.InstantiateFailed;
        };
        errdefer instance.deinit();
        var p = Plugin{
            .allocator = allocator,
            .engine = engine_ptr,
            .module = module,
            .linker = linker,
            .instance = instance,
            .name = allocator.dupe(u8, name) catch return error.OutOfMemory,
        };
        p.probeHooks();
        p.probeRequires();
        return p;
    }

    pub fn deinit(self: *Plugin) void {
        self.instance.deinit();
        self.linker.deinit();
        self.module.deinit();
        self.engine.deinit();
        if (self.json_buf) |b| self.allocator.free(b);
        self.allocator.destroy(self.engine);
        self.allocator.free(self.name);
        if (self.display.len > 0) self.allocator.free(self.display);
        self.* = undefined;
    }

    /// A hook is present when the module exports it. Missing exports are
    /// ordinary (a module registers only the hooks it needs).
    fn probeHooks(self: *Plugin) void {
        for (Hook.names, 0..) |hname, i| {
            self.hook_present[i] = self.instance.exportFuncSig(hname) != null;
        }
    }

    fn isHostVerb(cap: []const u8) bool {
        for (host_verbs) |v| {
            if (std.mem.eql(u8, cap, v)) return true;
        }
        return false;
    }

    /// Declarative capability check (`_zdtd_requires` -> "name,name,..." in
    /// guest memory). Every name must be a hook the module exports or a host
    /// verb it imports; anything else fails the load with the offending name.
    /// Coeffect fail-closed: a typo'd hook never silently never-fires.
    fn probeRequires(self: *Plugin) void {
        if (self.instance.exportFuncSig("_zdtd_requires") == null) return;
        const ret64 = self.instance.call(fn () i64, "_zdtd_requires", .{}) catch {
            self.requiresFailed("_zdtd_requires trapped");
            return;
        };
        // Packed i64 ABI: low 32 bits pointer, high 32 bits length.
        const packed_ret: u64 = @bitCast(ret64);
        const ptr: u32 = @truncate(packed_ret);
        const len: u32 = @truncate(packed_ret >> 32);
        if (len == 0 or len > 4096) {
            self.requiresFailed("_zdtd_requires returned an invalid range");
            return;
        }
        const mem = self.instance.memory() orelse {
            self.requiresFailed("_zdtd_requires: no memory");
            return;
        };
        const spec = mem.sliceAt(ptr, len) catch {
            self.requiresFailed("_zdtd_requires range out of bounds");
            return;
        };
        var it = std.mem.splitScalar(u8, spec, ',');
        while (it.next()) |raw| {
            const cap = std.mem.trim(u8, raw, " \t\r\n");
            if (cap.len == 0) continue;
            if (isHostVerb(cap)) continue;
            var found = false;
            for (Hook.names, 0..) |hname, i| {
                if (std.mem.eql(u8, cap, hname)) {
                    if (!self.hook_present[i]) {
                        self.requiresFailed2("requires hook '", cap, "' but does not export it");
                        return;
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.requiresFailed2("unknown capability '", cap, "'");
                return;
            }
        }
    }

    fn requiresFailed(self: *Plugin, why: []const u8) void {
        self.requiresFailed2("", why, "");
    }

    fn requiresFailed2(self: *Plugin, pre: []const u8, mid: []const u8, post: []const u8) void {
        const n = @min(pre.len + mid.len + post.len, self.requires_err.len);
        var w: usize = 0;
        @memcpy(self.requires_err[w .. w + @min(pre.len, n - w)], pre[0..@min(pre.len, n - w)]);
        w += @min(pre.len, n - w);
        @memcpy(self.requires_err[w .. w + @min(mid.len, n - w)], mid[0..@min(mid.len, n - w)]);
        w += @min(mid.len, n - w);
        @memcpy(self.requires_err[w .. w + @min(post.len, n - w)], post[0..@min(post.len, n - w)]);
        w += @min(post.len, n - w);
        self.requires_err_len = w;
        self.requires_failed = true;
    }

    /// Call a no-arg hook (on_enable, on_tick, on_shutdown). A trap or
    /// OutOfFuel disables the module.
    pub fn callHook(self: *Plugin, hook: Hook) bool {
        if (self.disabled) return false;
        if (!self.hook_present[@intFromEnum(hook)]) return false;
        const name = Hook.names[@intFromEnum(hook)];
        self.instance.call(fn () void, name, .{}) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' {s} disabled: {s}\n", .{ self.name, name, @errorName(err) });
            return false;
        };
        return true;
    }

    /// on_player_join(slot: i32, entity_id: i32).
    pub fn callPlayerJoin(self: *Plugin, slot: i32, entity_id: i32) bool {
        if (self.disabled) return false;
        if (!self.hook_present[@intFromEnum(Hook.on_player_join)]) return false;
        self.instance.call(fn (i32, i32) void, "on_player_join", .{ slot, entity_id }) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_join disabled: {s}\n", .{ self.name, @errorName(err) });
            return false;
        };
        return true;
    }

    /// on_player_leave(slot: i32, entity_id: i32): the join hook's mirror,
    /// fired when a joined client disconnects (Wasm-first: announcements and
    /// observers react to leaves through a plugin, not native code).
    pub fn callPlayerLeave(self: *Plugin, slot: i32, entity_id: i32) bool {
        if (self.disabled) return false;
        if (!self.hook_present[@intFromEnum(Hook.on_player_leave)]) return false;
        self.instance.call(fn (i32, i32) void, "on_player_leave", .{ slot, entity_id }) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_leave disabled: {s}\n", .{ self.name, @errorName(err) });
            return false;
        };
        return true;
    }

    /// on_trader_event(player: i32, trader_entity: i32, kind: i32).
    /// kind: 0 = trader window opened, 1 = player bought, 2 = player sold.
    /// Announcements/observers react through a plugin (Wasm-first); the trade
    /// itself already executed - this is an event, not a verdict.
    pub fn callTraderEvent(self: *Plugin, player: i32, trader_entity: i32, kind: i32) bool {
        if (self.disabled) return false;
        if (!self.hook_present[@intFromEnum(Hook.on_trader_event)]) return false;
        self.instance.call(fn (i32, i32, i32) void, "on_trader_event", .{ player, trader_entity, kind }) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_trader_event disabled: {s}\n", .{ self.name, @errorName(err) });
            return false;
        };
        return true;
    }

    /// on_trade_price(player: i32, item: i32, unit_price: i32) -> i32
    /// (pre-trade verdict: <0 deny the trade, 0 keep the price, >0 scale the
    /// unit price by percent). Fired on every buy against trader stock so
    /// plugins express price/tax policy (ADR-worthy extension; on_trader_event
    /// fires only after the trade).
    pub fn callTradePrice(self: *Plugin, player: i32, item: i32, unit_price: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_trade_price)]) return verdict_keep;
        return self.instance.call(fn (i32, i32, i32) i32, "on_trade_price", .{ player, item, unit_price }) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_trade_price disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_player_death(victim: i32) -> i32 (verdict convention: <0 deny,
    /// 0 keep, >0 adjust-percent where meaningful).
    pub fn callPlayerDeath(self: *Plugin, victim: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_player_death)]) return verdict_keep;
        return self.instance.call(fn (i32) i32, "on_player_death", .{victim}) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_death disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_player_damage(attacker: i32, victim: i32, amount: i32) -> i32
    /// (verdict convention: <0 deny the hit, 0 keep, >0 scale by percent).
    /// Fired for damage directed at a player after the native PvP/armor gate,
    /// so plugins express PvP/friendly-fire and damage-scaling policy
    /// (AGENTS rule 29, Wasm-first).
    pub fn callPlayerDamage(self: *Plugin, attacker: i32, victim: i32, amount: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_player_damage)]) return verdict_keep;
        return self.instance.call(fn (i32, i32, i32) i32, "on_player_damage", .{ attacker, victim, amount }) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_damage disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_quest_accept(player: i32, def_id: i32) -> i32 (verdict: <0 deny the
    /// accept, 0 keep). Fired on every quest acceptance so plugins gate which
    /// quests a player may take (AGENTS rule 29, Wasm-first).
    pub fn callQuestAccept(self: *Plugin, player: i32, def_id: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_quest_accept)]) return verdict_keep;
        return self.instance.call(fn (i32, i32) i32, "on_quest_accept", .{ player, def_id }) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_quest_accept disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_craft_request(player: i32, name_ptr: i32, name_len: i32, times: i32)
    /// -> i32 (verdict: <0 deny the craft, 0 keep, >0 caps the batch). The
    /// recipe name is copied into the guest's scratch (the stable key).
    pub fn callCraftRequest(self: *Plugin, player: i32, recipe_name: []const u8, times: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_craft_request)]) return verdict_keep;
        const mem = self.instance.memory() orelse return verdict_keep;
        const off = self.reserveScratch(mem, recipe_name.len) orelse return verdict_keep;
        @memcpy(mem.slice()[off..][0..recipe_name.len], recipe_name);
        return self.instance.call(
            fn (i32, i32, i32, i32) i32,
            "on_craft_request",
            .{ player, @intCast(off), @intCast(recipe_name.len), times },
        ) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_craft_request disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_perk_spend(player: i32, name_ptr: i32, name_len: i32, level: i32,
    /// cost: i32) -> i32 (ADR 0033: <0 deny the spend, 0 keep, >0 scale the
    /// skill-point cost by percent). The skill name is copied into the
    /// guest's scratch like on_craft_request.
    pub fn callPerkSpend(self: *Plugin, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_perk_spend)]) return verdict_keep;
        const mem = self.instance.memory() orelse return verdict_keep;
        const off = self.reserveScratch(mem, skill.len) orelse return verdict_keep;
        @memcpy(mem.slice()[off..][0..skill.len], skill);
        return self.instance.call(
            fn (i32, i32, i32, i32, i32) i32,
            "on_perk_spend",
            .{ player, @intCast(off), @intCast(skill.len), level, cost },
        ) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_perk_spend disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_game_event(player: i32, name_ptr: i32, name_len: i32, target: i32,
    /// var_count: i32) -> i32 (ADR 0035: <0 deny the event, 0 keep the stock
    /// APPROVED ack, >0 keep). The event name is copied into the guest's
    /// scratch like on_craft_request.
    pub fn callGameEvent(self: *Plugin, player: i32, event: []const u8, target: i32, var_count: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_game_event)]) return verdict_keep;
        const mem = self.instance.memory() orelse return verdict_keep;
        const off = self.reserveScratch(mem, event.len) orelse return verdict_keep;
        @memcpy(mem.slice()[off..][0..event.len], event);
        return self.instance.call(
            fn (i32, i32, i32, i32, i32) i32,
            "on_game_event",
            .{ player, @intCast(off), @intCast(event.len), target, var_count },
        ) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_game_event disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_stat_changed(player: i32, hp: i32, food: i32, water: i32,
    /// stamina: i32, level: i32, xp: i32) - observer (ADR 0034): the sim
    /// stays the authority; plugins react/announce.
    pub fn callStatChanged(self: *Plugin, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
        if (self.disabled) return;
        if (!self.hook_present[@intFromEnum(Hook.on_stat_changed)]) return;
        self.instance.call(fn (i32, i32, i32, i32, i32, i32, i32) void, "on_stat_changed", .{ player, hp, food, water, stamina, level, xp }) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_stat_changed disabled: {s}\n", .{ self.name, @errorName(err) });
        };
    }

    /// on_loot_roll(list_ptr: i32, list_len: i32, rolled: i32) -> i32
    /// (verdict: <0 deny the roll (empty), 0 keep, >0 scale the rolled stack
    /// count by percent). The loot-list name is copied into the guest's
    /// scratch (the stable key).
    pub fn callLootRoll(self: *Plugin, list_name: []const u8, rolled: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_loot_roll)]) return verdict_keep;
        const mem = self.instance.memory() orelse return verdict_keep;
        const off = self.reserveScratch(mem, list_name.len) orelse return verdict_keep;
        @memcpy(mem.slice()[off..][0..list_name.len], list_name);
        return self.instance.call(
            fn (i32, i32, i32) i32,
            "on_loot_roll",
            .{ @intCast(off), @intCast(list_name.len), rolled },
        ) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_loot_roll disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_entity_killed(killed: i32, killer: i32) -> i32.
    pub fn callEntityKilled(self: *Plugin, killed: i32, killer: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_entity_killed)]) return verdict_keep;
        return self.instance.call(fn (i32, i32) i32, "on_entity_killed", .{ killed, killer }) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_entity_killed disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_block_damage(x, y, z, dmg) -> i32: percent applied, or deny (< 0).
    pub fn callBlockDamage(self: *Plugin, x: i32, y: i32, z: i32, dmg: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_block_damage)]) return verdict_keep;
        return self.instance.call(fn (i32, i32, i32, i32) i32, "on_block_damage", .{ x, y, z, dmg }) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_block_damage disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// on_quest_complete(player: i32, quest_def: i32) -> i32: reward percent.
    pub fn callQuestComplete(self: *Plugin, player: i32, quest_def: i32) i32 {
        if (self.disabled) return verdict_keep;
        if (!self.hook_present[@intFromEnum(Hook.on_quest_complete)]) return verdict_keep;
        return self.instance.call(fn (i32, i32) i32, "on_quest_complete", .{ player, quest_def }) catch |err| blk: {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_quest_complete disabled: {s}\n", .{ self.name, @errorName(err) });
            break :blk verdict_keep;
        };
    }

    /// Reserve `need` bytes of guest memory the host may write into, for the
    /// hooks that pass a buffer in and take a reply out. The region is carved
    /// from freshly grown pages rather than a fixed low offset: wasm-ld puts the
    /// guest's static data at offset 1024 by default, so writing there would
    /// corrupt the plugin's own globals. Memory only ever grows, so the offset
    /// stays valid for later calls and is reserved once per size.
    /// Null when the guest has no memory or growth is refused (page cap).
    fn reserveScratch(self: *Plugin, mem: zwasm.Memory, need: usize) ?u32 {
        if (self.scratch_len >= need and self.scratch_len != 0) return self.scratch_off;
        const pages: u32 = @intCast((need + 65535) / 65536);
        const old_pages = mem.grow(pages) orelse {
            // Growth refused (the module's own max, or the page cap). Fall back
            // to the low fixed region so a fixed-size module still gets its
            // hooks called, accepting that it may overlap the guest's data.
            const fallback_off: u32 = 1024;
            if (fallback_off + need > mem.slice().len) return null;
            self.scratch_off = fallback_off;
            self.scratch_len = need;
            return fallback_off;
        };
        const base: u64 = @as(u64, old_pages) * 65536;
        if (base + need > std.math.maxInt(u32)) return null;
        self.scratch_off = @intCast(base);
        self.scratch_len = @as(usize, pages) * 65536;
        return self.scratch_off;
    }

    /// on_admin_command(cmd_ptr: i32, cmd_len: i32, out_ptr: i32, out_cap: i32) -> i32:
    /// bytes written, 0 not handled, <0 error. Handled means the host replies
    /// with the guest's buffer slice; not handled falls through to the next
    /// plugin / core unknown. Traps disable only that module.
    pub fn callAdminCommand(self: *Plugin, cmd: []const u8, out: []u8) ?[]const u8 {
        if (self.disabled) return null;
        if (!self.hook_present[@intFromEnum(Hook.on_admin_command)]) return null;
        // Copy the command into the guest, call the hook, copy the reply back.
        const mem = self.instance.memory() orelse return null;
        // Layout in the reserved scratch: [cmd_bytes][out_region].
        const cmd_off = self.reserveScratch(mem, cmd.len + out.len) orelse return null;
        const out_off: u32 = cmd_off + @as(u32, @intCast(cmd.len));
        @memcpy(mem.slice()[cmd_off..][0..cmd.len], cmd);
        const written: i32 = self.instance.call(
            fn (i32, i32, i32, i32) i32,
            "on_admin_command",
            .{ @intCast(cmd_off), @intCast(cmd.len), @intCast(out_off), @intCast(out.len) },
        ) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_admin_command disabled: {s}\n", .{ self.name, @errorName(err) });
            return null;
        };
        if (written <= 0) return null;
        const n: usize = @intCast(@min(@as(i32, @intCast(out.len)), written));
        // Re-fetch slice in case the call grew memory.
        const cur = mem.slice();
        @memcpy(out[0..n], cur[out_off..][0..n]);
        return out[0..n];
    }

    /// on_chat(sender: i32, msg_ptr: i32, msg_len: i32, out_ptr: i32, out_cap: i32) -> i32:
    /// <0 deny, 0 keep/probe miss, >0 bytes of filtered body. A filtered body
    /// that fails chatMsgOk is treated as deny by the caller. Traps disable
    /// only that module and are treated as keep.
    pub fn callChat(self: *Plugin, sender: i32, msg: []const u8, out: []u8) ?[]const u8 {
        if (self.disabled) return null;
        if (!self.hook_present[@intFromEnum(Hook.on_chat)]) return null;
        const mem = self.instance.memory() orelse return null;
        const msg_off = self.reserveScratch(mem, msg.len + out.len) orelse return null;
        const out_off: u32 = msg_off + @as(u32, @intCast(msg.len));
        @memcpy(mem.slice()[msg_off..][0..msg.len], msg);
        const written: i32 = self.instance.call(
            fn (i32, i32, i32, i32, i32) i32,
            "on_chat",
            .{ sender, @intCast(msg_off), @intCast(msg.len), @intCast(out_off), @intCast(out.len) },
        ) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_chat disabled: {s}\n", .{ self.name, @errorName(err) });
            return null;
        };
        if (written < 0) return "";
        if (written == 0) return null;
        const n: usize = @intCast(@min(@as(i32, @intCast(out.len)), written));
        const cur = mem.slice();
        @memcpy(out[0..n], cur[out_off..][0..n]);
        return out[0..n];
    }

    /// on_player_login(peer_slot: i32, name_ptr: i32, name_len: i32, out_ptr: i32, out_cap: i32) -> i32:
    /// <0 deny with reason written to out (trap/fuel -> allow), 0 allow (not handled), >0 also deny.
    /// Spelling: a deny that returns 0 bytes is still a deny with an empty reason; the caller falls back to "denied".
    pub fn callPlayerLogin(self: *Plugin, peer_slot: u16, name: []const u8, out: []u8) ?[]const u8 {
        if (self.disabled) return null;
        if (!self.hook_present[@intFromEnum(Hook.on_player_login)]) return null;
        const mem = self.instance.memory() orelse return null;
        const name_off = self.reserveScratch(mem, name.len + out.len) orelse return null;
        const out_off: u32 = name_off + @as(u32, @intCast(name.len));
        @memcpy(mem.slice()[name_off..][0..name.len], name);
        const ret: i32 = self.instance.call(
            fn (i32, i32, i32, i32, i32) i32,
            "on_player_login",
            .{ @intCast(peer_slot), @intCast(name_off), @intCast(name.len), @intCast(out_off), @intCast(out.len) },
        ) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_login disabled: {s}\n", .{ self.name, @errorName(err) });
            return null;
        };
        if (ret == 0) return null;
        if (ret < 0) {
            // Negative return is deny; out may be empty. `@abs` rather than
            // `-ret`: a guest returning i32 minInt would overflow the negation.
            if (out.len == 0) return "";
            const n: usize = @min(@as(usize, @abs(ret)), out.len);
            const cur = mem.slice();
            @memcpy(out[0..n], cur[out_off..][0..n]);
            return out[0..n];
        }
        const n: usize = @intCast(@min(@as(i32, @intCast(out.len)), ret));
        const cur = mem.slice();
        @memcpy(out[0..n], cur[out_off..][0..n]);
        return out[0..n];
    }

    /// on_mcp_frame(frame_ptr: i32, frame_len: i32, out_ptr: i32, out_cap: i32) -> i32:
    /// MCP transport bridge (ADR 0031): the host copies one client JSON-RPC
    /// frame into guest memory; the guest writes its response back and returns
    /// the bytes written (0 = nothing to send: notification, closed session, or
    /// overflowed response). Traps disable only that module.
    pub fn callMcpFrame(self: *Plugin, frame: []const u8, out: []u8) ?[]const u8 {
        if (self.disabled) return null;
        if (!self.hook_present[@intFromEnum(Hook.on_mcp_frame)]) return null;
        const mem = self.instance.memory() orelse return null;
        const frame_off = self.reserveScratch(mem, frame.len + out.len) orelse return null;
        const out_off: u32 = frame_off + @as(u32, @intCast(frame.len));
        @memcpy(mem.slice()[frame_off..][0..frame.len], frame);
        const written: i32 = self.instance.call(
            fn (i32, i32, i32, i32) i32,
            "on_mcp_frame",
            .{ @intCast(frame_off), @intCast(frame.len), @intCast(out_off), @intCast(out.len) },
        ) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_mcp_frame disabled: {s}\n", .{ self.name, @errorName(err) });
            return null;
        };
        if (written <= 0) return null;
        const n: usize = @intCast(@min(@as(i32, @intCast(out.len)), written));
        // Re-fetch slice in case the call grew memory.
        const cur = mem.slice();
        @memcpy(out[0..n], cur[out_off..][0..n]);
        return out[0..n];
    }

    /// std.json capability (ADR 0031). Parse the JSON doc `doc` (guest memory)
    /// with std.json; 0 = ok and the doc is now current for this plugin,
    /// -1 = parse error (invalid JSON, or the fixed buffer exhausted). The
    /// parse replaces any previous doc; allocations come from a lazily
    /// allocated fixed buffer reset per frame, so the tick path never allocs.
    pub fn jsonParse(self: *Plugin, doc: []const u8) i32 {
        if (self.json_buf == null) {
            const b = self.allocator.alloc(u8, json_buf_max) catch return -1;
            self.json_buf = b;
            self.json_fba = std.heap.FixedBufferAllocator.init(b);
        }
        self.json_fba.reset();
        self.json_value = null;
        const v = std.json.parseFromSliceLeaky(std.json.Value, self.json_fba.allocator(), doc, .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .use_last,
        }) catch return -1;
        self.json_value = v;
        return 0;
    }

    /// Walk a dot-separated key path from the parsed root; null on a missing
    /// key, a non-object mid-path, or an empty/leading/trailing segment.
    fn jsonWalk(v: std.json.Value, path: []const u8) ?std.json.Value {
        if (path.len == 0) return v;
        var it = std.mem.splitScalar(u8, path, '.');
        var cur = v;
        while (it.next()) |key| {
            if (key.len == 0) return null;
            cur = switch (cur) {
                .object => |o| o.get(key) orelse return null,
                else => return null,
            };
        }
        return cur;
    }

    /// Copy the decoded string at `path` into guest memory; returns the full
    /// length (0 = path missing or not a string, -1 = no parsed doc or bad
    /// path). The guest compares the length against its buffer cap.
    pub fn jsonStr(self: *Plugin, path: []const u8, out: []u8) i32 {
        const v = self.json_value orelse return -1;
        const target = jsonWalk(v, path) orelse return 0;
        const s = switch (target) {
            .string => |s| s,
            else => return 0,
        };
        const n = @min(out.len, s.len);
        @memcpy(out[0..n], s[0..n]);
        return @intCast(s.len);
    }

    /// Serialize the value at `path` as raw JSON into guest memory; returns
    /// the full length (0 = path missing, -1 = no parsed doc / bad path /
    /// serialize error). Used to echo the JSON-RPC `id` verbatim. The
    /// serialization allocates from the same fixed per-plugin buffer (bounded
    /// by json_buf_max, fail closed), never the heap.
    pub fn jsonRaw(self: *Plugin, path: []const u8, out: []u8) i32 {
        const v = self.json_value orelse return -1;
        const target = jsonWalk(v, path) orelse return 0;
        const bytes = std.json.Stringify.valueAlloc(self.json_fba.allocator(), target, .{}) catch return -1;
        const n = @min(out.len, bytes.len);
        @memcpy(out[0..n], bytes[0..n]);
        return @intCast(bytes.len);
    }

    /// 1 when the value at `path` is an object, 0 when absent or not an
    /// object, -1 on no parsed doc or a bad path.
    pub fn jsonObj(self: *Plugin, path: []const u8) i32 {
        const v = self.json_value orelse return -1;
        const target = jsonWalk(v, path) orelse return 0;
        return switch (target) {
            .object => 1,
            else => 0,
        };
    }

    /// Export the remaining fuel (diagnostics; the runtime enforces the budget).
    pub fn fuelRemaining(self: *Plugin) ?u64 {
        return self.instance.fuelRemaining();
    }
};

pub const max_wasm_plugins: usize = 8;
/// Ceiling on one module's bytes at load time (operator-supplied path).
const max_wasm_module_bytes: usize = 16 * 1024 * 1024;

/// Fixed-table host for loaded .wasm plugins: ordered enable/tick/join/shutdown,
/// same hook order as the static host. Load happens once at init (allocation is
/// allowed there); the tick path only calls hooks, which are already budgeted.
pub const WasmHost = struct {
    slots: [max_wasm_plugins]Plugin = undefined,
    n: usize = 0,
    /// Load-time context + budget (stored so `reload` can dispose and
    /// reinstantiate a slot in place; paper: hot module replacement).
    allocator: std.mem.Allocator = undefined,
    ctx: ?*HostCtx = null,
    budget: Budget = .{},
    /// Pending-effect withdrawal marks: a disabled plugin's queued commands are
    /// dropped once (temporal composability); cleared on reload.
    withdrawn: [max_wasm_plugins]bool = .{false} ** max_wasm_plugins,
    /// PRD 0005: exclusive core override-point claims, point -> slot (load-fixed;
    /// no_claim when unclaimed). A claimed point routes only to its claimant.
    claims: [manifest.OverridePoint.count]u8 = .{no_claim} ** manifest.OverridePoint.count,

    /// Load through a resolved mod plan (PRD 0005): the plan is final load
    /// order with tiers and exclusive point claims; the caller owns the plan
    /// and its manifests. Explicit `[plugin] modules` are folded in as
    /// synthetic user mods by the resolver.
    pub fn loadResolved(
        self: *WasmHost,
        allocator: std.mem.Allocator,
        plan: *const resolver.ResolvedResult,
        ctx: *HostCtx,
        budget: Budget,
    ) void {
        self.allocator = allocator;
        self.ctx = ctx;
        self.budget = budget;
        for (plan.modules) |rm| {
            if (self.n >= max_wasm_plugins) {
                std.debug.print("zdtd: wasm plugin cap {d} reached; skipping '{s}'\n", .{ max_wasm_plugins, rm.manifest.wasm.? });
                return;
            }
            // Path = <manifest dir>/<wasm> for discovered mods; synthetic
            // explicit modules carry the full path as wasm with dir "".
            const full_path = if (rm.manifest.dir.len > 0)
                (std.fs.path.join(allocator, &.{ rm.manifest.dir, rm.manifest.wasm.? }) catch {
                    std.debug.print("zdtd: mod '{s}' bad wasm path; skipping\n", .{rm.manifest.name.?});
                    continue;
                })
            else
                rm.manifest.wasm.?;
            defer if (rm.manifest.dir.len > 0) allocator.free(full_path);
            self.loadInto(self.n, full_path) catch |err| {
                std.debug.print("zdtd: mod '{s}' load failed: {s}\n", .{ rm.manifest.name.?, @errorName(err) });
                continue;
            };
            self.slots[self.n].tier = rm.tier;
            self.slots[self.n].display = allocator.dupe(u8, rm.manifest.name.?) catch "";
            self.n += 1;
            const tier_s = switch (rm.tier) {
                .core => "core",
                .official => "official",
                .user => "user",
            };
            if (rm.replaces) |tgt| {
                std.debug.print("zdtd: mod '{s}' [{s}] loaded (replaces '{s}')\n", .{ rm.manifest.name.?, tier_s, tgt });
            } else {
                std.debug.print("zdtd: mod '{s}' [{s}] loaded\n", .{ rm.manifest.name.?, tier_s });
            }
        }
        // Install exclusive point claims (load-fixed table; no per-tick cost).
        self.claims = .{no_claim} ** manifest.OverridePoint.count;
        var it = plan.point_claims.iterator();
        while (it.next()) |entry| {
            const point = manifest.OverridePoint.parse(entry.key_ptr.*) orelse continue;
            self.claims[@intFromEnum(point)] = @intCast(entry.value_ptr.*);
        }
    }

    /// Load every module path that exists; a missing or unloadable module is
    /// logged and skipped so one bad file does not take the server down.
    pub fn loadAll(
        self: *WasmHost,
        allocator: std.mem.Allocator,
        paths: []const []const u8,
        ctx: *HostCtx,
        budget: Budget,
    ) void {
        self.allocator = allocator;
        self.ctx = ctx;
        self.budget = budget;
        for (paths) |p| {
            if (self.n >= max_wasm_plugins) {
                std.debug.print("zdtd: wasm plugin cap {d} reached; skipping '{s}'\n", .{ max_wasm_plugins, p });
                return;
            }
            self.loadInto(self.n, p) catch |err| {
                std.debug.print("zdtd: wasm plugin '{s}' load failed: {s}\n", .{ p, @errorName(err) });
                continue;
            };
            self.n += 1;
            std.debug.print("zdtd: wasm plugin loaded '{s}'\n", .{p});
        }
    }

    /// Load `path` into slot `idx` (append or in-place reload). On success the
    /// slot owns the new instance; on error the slot is left empty.
    fn loadInto(self: *WasmHost, idx: usize, path: []const u8) !void {
        const bytes = try io_fs.readFileAll(self.allocator, path);
        defer self.allocator.free(bytes);
        if (bytes.len > max_wasm_module_bytes) return error.ModuleTooLarge;
        const ctx = self.ctx orelse return error.NoContext;
        var p2 = try Plugin.load(self.allocator, path, bytes, ctx, self.budget);
        errdefer p2.deinit();
        if (p2.requires_failed) {
            std.debug.print(
                "zdtd: wasm plugin '{s}' rejected: {s}\n",
                .{ path, p2.requires_err[0..p2.requires_err_len] },
            );
            return error.RequiresUnmet;
        }
        const rt = p2.instance.handle.runtime orelse {
            std.debug.print("zdtd: wasm plugin '{s}' rejected: no runtime (cannot attribute queue src)\n", .{path});
            return error.NoRuntime;
        };
        ctx.rt_slot[idx] = @ptrCast(rt);
        ctx.plugin_slot[idx] = @ptrCast(&self.slots[idx]);
        self.slots[idx] = p2;
        self.withdrawn[idx] = false;
    }

    /// Dispose slot `idx` (on_shutdown + deinit) so a replacement can load
    /// into it (paper: dispose old fiber, reinstantiate the reloaded module).
    /// Returns false when no module occupies the slot or the reload failed.
    pub fn reload(self: *WasmHost, idx: usize, path: []const u8) bool {
        if (idx >= self.n) return false;
        // The module's own name is freed by deinit below; work on a copy so
        // callers passing slots[idx].name (the admin verb does) stay valid.
        const path_owned = self.allocator.dupe(u8, path) catch return false;
        defer self.allocator.free(path_owned);
        // Preserve tier/display across the reload (loadInto resets them). The
        // display copy is owned by this frame until it moves into the slot on
        // success; the failure path frees it explicitly. A defer here would
        // free it under the reloaded slot (use-after-free, then a double free
        // at deinit).
        const tier = self.slots[idx].tier;
        const display_copy = if (self.slots[idx].display.len > 0)
            self.allocator.dupe(u8, self.slots[idx].display) catch ""
        else
            "";
        _ = self.slots[idx].callHook(.on_shutdown);
        // Withdraw after on_shutdown and before deinit: shutdown may queue
        // (or spawn bots) that a pre-reload withdraw would miss, and those
        // effects must not land on the replacement or a compacted neighbor.
        if (self.ctx) |ctx| {
            if (ctx.withdraw_fn) |wf| wf(ctx, @intCast(idx + 1));
        }
        self.slots[idx].deinit();
        if (self.ctx) |ctx| {
            ctx.rt_slot[idx] = null;
            ctx.plugin_slot[idx] = null;
        }
        self.loadInto(idx, path_owned) catch |err| {
            std.debug.print("zdtd: wasm plugin reload '{s}' failed: {s}\n", .{ path_owned, @errorName(err) });
            // The disposed slot cannot stay inside 0..n (hooks and deinit
            // would run on undefined memory): drop it from the active range.
            self.dropDisposedSlot(idx);
            if (display_copy.len > 0) self.allocator.free(display_copy);
            return false;
        };
        self.slots[idx].tier = tier;
        self.slots[idx].display = display_copy;
        // Activate the new fiber (paper: reinstantiate + reinstall).
        _ = self.slots[idx].callHook(.on_enable);
        return true;
    }

    /// Remove an already-disposed (deinit'd) slot from the active range:
    /// shift later modules down so every slot in 0..n stays a valid live
    /// instance. Re-points each moved module's HostCtx backlink and shifts
    /// override-point claims to follow their module (the dropped slot's
    /// claims release). Never call on a live slot.
    fn dropDisposedSlot(self: *WasmHost, idx: usize) void {
        if (idx >= self.n) return;
        var i: usize = idx;
        while (i + 1 < self.n) : (i += 1) {
            self.slots[i] = self.slots[i + 1];
            self.withdrawn[i] = self.withdrawn[i + 1];
        }
        if (self.ctx) |ctx| {
            i = idx;
            while (i + 1 < self.n) : (i += 1) {
                ctx.rt_slot[i] = ctx.rt_slot[i + 1];
                // The moved module's backlink must address its new slot.
                ctx.plugin_slot[i] = if (ctx.plugin_slot[i + 1] != null)
                    @ptrCast(&self.slots[i])
                else
                    null;
            }
            ctx.rt_slot[self.n - 1] = null;
            ctx.plugin_slot[self.n - 1] = null;
        }
        for (&self.claims) |*c| {
            if (c.* == no_claim) continue;
            if (c.* == idx) {
                c.* = no_claim;
            } else if (c.* > idx) {
                c.* -= 1;
            }
        }
        self.n -= 1;
    }

    /// First slot matching `name`: exact display name (`plugin list` prints
    /// it), then a path suffix, then a path stem suffix (so `plugin reload bot`
    /// matches `fps_bot.wasm`). Empty names never match.
    pub fn findByName(self: *const WasmHost, name: []const u8) ?usize {
        if (name.len == 0) return null;
        for (0..self.n) |i| {
            const disp = self.slots[i].display;
            if (disp.len > 0 and std.mem.eql(u8, disp, name)) return i;
        }
        for (0..self.n) |i| {
            const path = self.slots[i].name;
            if (std.mem.endsWith(u8, path, name)) return i;
            if (std.mem.endsWith(u8, path, ".wasm")) {
                const stem = path[0 .. path.len - ".wasm".len];
                if (std.mem.endsWith(u8, stem, name)) return i;
            }
        }
        return null;
    }

    /// Temporal composability (paper): report the 1-based slots of plugins
    /// that disabled themselves (trap / fuel exhaustion) whose pending effects
    /// have not yet been withdrawn, and mark them withdrawn (once per
    /// disable). The owner (Game) calls CommandBuffer.dropFrom for each before
    /// the drain, so a broken plugin's queued commands never execute. Plugin
    /// stays a leaf package: it returns srcs, the owner owns the buffer.
    pub fn takeWithdrawn(self: *WasmHost, out: []i16) usize {
        var n: usize = 0;
        for (0..self.n) |i| {
            if (!self.slots[i].disabled or self.withdrawn[i]) continue;
            if (n < out.len) out[n] = @intCast(i + 1);
            self.withdrawn[i] = true;
            n += 1;
        }
        return n;
    }

    /// Call on_enable for every loaded plugin (once, at enable).
    pub fn enable(self: *WasmHost) void {
        for (0..self.n) |i| _ = self.slots[i].callHook(.on_enable);
    }

    pub fn onTick(self: *WasmHost) void {
        for (0..self.n) |i| _ = self.slots[i].callHook(.on_tick);
    }

    pub fn playerJoin(self: *WasmHost, slot: u16, entity_id: i32) void {
        for (0..self.n) |i| _ = self.slots[i].callPlayerJoin(@intCast(slot), entity_id);
    }

    pub fn playerLeave(self: *WasmHost, slot: u16, entity_id: i32) void {
        for (0..self.n) |i| _ = self.slots[i].callPlayerLeave(@intCast(slot), entity_id);
    }

    pub fn traderEvent(self: *WasmHost, player: i32, trader_entity: i32, kind: i32) void {
        for (0..self.n) |i| _ = self.slots[i].callTraderEvent(player, trader_entity, kind);
    }

    /// Event-hook verdicts: first non-zero return across plugins in load order.
    /// 0 (no plugin exports the hook, or all keep) preserves today's behaviour;
    /// a trap/fuel-exhaustion disables that plugin and it reports keep.
    pub fn playerDeath(self: *WasmHost, victim: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callPlayerDeath(victim);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    pub fn entityKilled(self: *WasmHost, killed: i32, killer: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callEntityKilled(killed, killer);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Player-damage verdict; point `damage.player_scale` is exclusive when
    /// claimed: only the claimant is consulted and its verdict is final.
    pub fn playerDamage(self: *WasmHost, attacker: i32, victim: i32, amount: i32) i32 {
        const c = self.claims[@intFromEnum(manifest.OverridePoint.damage_player_scale)];
        if (c != no_claim and c < self.n) return self.slots[c].callPlayerDamage(attacker, victim, amount);
        for (0..self.n) |i| {
            const v = self.slots[i].callPlayerDamage(attacker, victim, amount);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Perk-spend verdict (ADR 0033): every plugin exporting on_perk_spend is
    /// consulted in slot order; the first non-keep verdict wins.
    pub fn perkSpend(self: *WasmHost, player: i32, skill: []const u8, level: i32, cost: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callPerkSpend(player, skill, level, cost);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// GameEvent verdict (ADR 0035): every plugin exporting on_game_event is
    /// consulted in slot order; the first non-keep verdict wins.
    pub fn gameEvent(self: *WasmHost, player: i32, event: []const u8, target: i32, var_count: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callGameEvent(player, event, target, var_count);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Player stat observer (ADR 0034): notify every plugin exporting it.
    pub fn statChanged(self: *WasmHost, player: i32, hp: i32, food: i32, water: i32, stamina: i32, level: i32, xp: i32) void {
        for (0..self.n) |i| self.slots[i].callStatChanged(player, hp, food, water, stamina, level, xp);
    }

    pub fn questAccept(self: *WasmHost, player: i32, def_id: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callQuestAccept(player, def_id);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Craft-request verdict; point `craft.request` is exclusive when claimed.
    pub fn craftRequest(self: *WasmHost, player: i32, recipe_name: []const u8, times: i32) i32 {
        const c = self.claims[@intFromEnum(manifest.OverridePoint.craft_request)];
        if (c != no_claim and c < self.n) return self.slots[c].callCraftRequest(player, recipe_name, times);
        for (0..self.n) |i| {
            const v = self.slots[i].callCraftRequest(player, recipe_name, times);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Loot-roll verdict; point `loot.roll` is exclusive when claimed.
    pub fn lootRoll(self: *WasmHost, list_name: []const u8, rolled: i32) i32 {
        const c = self.claims[@intFromEnum(manifest.OverridePoint.loot_roll)];
        if (c != no_claim and c < self.n) return self.slots[c].callLootRoll(list_name, rolled);
        for (0..self.n) |i| {
            const v = self.slots[i].callLootRoll(list_name, rolled);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    pub fn blockDamage(self: *WasmHost, x: i32, y: i32, z: i32, dmg: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callBlockDamage(x, y, z, dmg);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Pre-trade price verdict: point `trade.price` is exclusive when claimed;
    /// 0 keeps the stock price.
    pub fn tradePrice(self: *WasmHost, player: i32, item: i32, unit_price: i32) i32 {
        const c = self.claims[@intFromEnum(manifest.OverridePoint.trade_price)];
        if (c != no_claim and c < self.n) return self.slots[c].callTradePrice(player, item, unit_price);
        for (0..self.n) |i| {
            const v = self.slots[i].callTradePrice(player, item, unit_price);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Quest-complete verdict; point `quest.payout` is exclusive when claimed.
    pub fn questComplete(self: *WasmHost, player: i32, quest_def: i32) i32 {
        const c = self.claims[@intFromEnum(manifest.OverridePoint.quest_payout)];
        if (c != no_claim and c < self.n) return self.slots[c].callQuestComplete(player, quest_def);
        for (0..self.n) |i| {
            const v = self.slots[i].callQuestComplete(player, quest_def);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Join gate: first deny wins.
    pub fn playerLoginDeny(self: *WasmHost, peer_slot: u16, name: []const u8, out: []u8) ?[]const u8 {
        for (0..self.n) |i| {
            if (self.slots[i].callPlayerLogin(peer_slot, name, out)) |reason| return reason;
        }
        return null;
    }

    /// Chat hook: first plugin that rewrites or denies wins. Returns the
    /// filtered body or "" for deny; null means keep original.
    pub fn chatFilter(self: *WasmHost, sender: i32, msg: []const u8, out: []u8) ?[]const u8 {
        for (0..self.n) |i| {
            if (self.slots[i].callChat(sender, msg, out)) |filtered| return filtered;
        }
        return null;
    }

    /// Admin command hook: first plugin that handles the verb wins. The
    /// handler writes into `out` and returns the written slice. 0 / null means
    /// not handled (try next plugin, then core unknown). Traps disable only
    /// that module.
    pub fn adminCommand(self: *WasmHost, cmd: []const u8, out: []u8) ?[]const u8 {
        for (0..self.n) |i| {
            if (self.slots[i].callAdminCommand(cmd, out)) |reply| return reply;
            // A disabled module is already filtered inside callAdminCommand.
        }
        return null;
    }

    /// Reverse order, like the static host: shutdown then deinit each plugin.
    pub fn shutdown(self: *WasmHost) void {
        var i: usize = self.n;
        while (i > 0) {
            i -= 1;
            _ = self.slots[i].callHook(.on_shutdown);
            self.slots[i].deinit();
        }
        self.n = 0;
        self.withdrawn = .{false} ** max_wasm_plugins;
        self.claims = .{no_claim} ** manifest.OverridePoint.count;
        if (self.ctx) |ctx| {
            ctx.rt_slot = .{null} ** max_wasm_plugins;
            ctx.plugin_slot = .{null} ** max_wasm_plugins;
        }
    }

    pub fn count(self: *const WasmHost) usize {
        return self.n;
    }

    pub fn disabledCount(self: *const WasmHost) usize {
        var c: usize = 0;
        for (0..self.n) |i| {
            if (self.slots[i].disabled) c += 1;
        }
        return c;
    }
};

/// Map a calling instance's runtime pointer to its loaded Plugin (per-plugin
/// state for the json capability). Mirrors the queue import's attribution loop.
fn pluginForCaller(hc: *HostCtx, rt: *anyopaque) ?*Plugin {
    for (hc.rt_slot, 0..) |r, i| {
        if (r == rt) {
            const p: *Plugin = @ptrCast(@alignCast(hc.plugin_slot[i] orelse return null));
            return p;
        }
    }
    return null;
}

/// Host import table, all under the "zdtd" module namespace. The import field
/// names are bare: "log" (level, ptr, len), "tick" () -> i64 and "queue"
/// (ptr, len) -> i32, so a guest imports zdtd.log, not zdtd.zdtd_log.
/// Every host fn copies in/out of the guest's linear memory; a missing memory
/// or an out-of-bounds range is a no-op for reads and an error for the guest.
fn defineImports(linker: *zwasm.Linker, ctx: *HostCtx) !void {
    const H = struct {
        fn log(caller: *zwasm.Caller, level: i32, ptr: i32, len: i32) anyerror!void {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return;
            if (ptr < 0 or len < 0) return;
            const msg = mem.sliceAt(@intCast(ptr), @intCast(len)) catch return;
            hc.log_fn(hc, @intCast(@max(0, level)), msg);
        }
        fn tick(caller: *zwasm.Caller) anyerror!i64 {
            const hc = caller.data(HostCtx);
            return @intCast(hc.tick_fn(hc));
        }
        fn queue(caller: *zwasm.Caller, ptr: i32, len: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return 1;
            if (ptr < 0 or len < 0) return 1;
            const cmd = mem.sliceAt(@intCast(ptr), @intCast(len)) catch return 1;
            // Attribute the command to its plugin via the caller's runtime
            // (paper: revertible effects - the owner withdraws a disabled
            // plugin's pending effects by src).
            var src: i16 = 0;
            const rt: *anyopaque = @ptrCast(caller.rt);
            for (hc.rt_slot, 0..) |r, i| {
                if (r == rt) {
                    src = @intCast(i + 1);
                    break;
                }
            }
            // Fail closed: an unattributed queue would run as native (src 0)
            // and could not be withdrawn. Drop it rather than leak the effect.
            if (src == 0) return 1;
            hc.queue_fn(hc, src, cmd);
            return 0;
        }
        fn sense(caller: *zwasm.Caller, ptr: i32, len: i32, token: i32) anyerror!i32 {
            _ = token; // reserved for future per-slot reads; single snapshot today
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return 0;
            if (ptr < 0 or len < 0) return 0;
            const sf = hc.sense_fn orelse return 0;
            var scratch: [host_sense_max:0]u8 = undefined;
            const written = sf(hc, &scratch);
            const guest_len: usize = @intCast(len);
            const copy = @min(guest_len, @min(written, host_sense_max));
            const dst = mem.sliceAt(@intCast(ptr), @intCast(copy)) catch return 0;
            @memcpy(dst, scratch[0..copy]);
            return @intCast(copy);
        }
        fn query(caller: *zwasm.Caller, req_ptr: i32, req_len: i32, out_ptr: i32, out_cap: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return 0;
            if (req_ptr < 0 or req_len < 0 or out_ptr < 0 or out_cap < 0) return 0;
            const qf = hc.query_fn orelse return 0;
            const req = mem.sliceAt(@intCast(req_ptr), @intCast(req_len)) catch return 0;
            var resp: [query_resp_max:0]u8 = undefined;
            const written = qf(hc, req, &resp);
            const copy = @min(@as(usize, @intCast(out_cap)), written);
            const dst = mem.sliceAt(@intCast(out_ptr), @intCast(copy)) catch return 0;
            @memcpy(dst, resp[0..copy]);
            return @intCast(copy);
        }
        // std.json capability (ADR 0031, RFC 0002 §5): parse the JSON
        // doc at guest memory (ptr, len) with std.json; 0 = ok, -1 = parse
        // error. The parsed doc is per-plugin state, replaced on the next
        // call. Conventions for all json_* imports: path is a dot-separated
        // key chain, and string/raw returns give the FULL length so the guest
        // can detect truncation against its own buffer cap.
        fn jsonParse(caller: *zwasm.Caller, ptr: i32, len: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return -1;
            if (ptr < 0 or len < 0) return -1;
            const p = pluginForCaller(hc, @ptrCast(caller.rt)) orelse return -1;
            const doc = mem.sliceAt(@intCast(ptr), @intCast(len)) catch return -1;
            return p.jsonParse(doc);
        }
        fn jsonStr(caller: *zwasm.Caller, path_ptr: i32, path_len: i32, out_ptr: i32, out_cap: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return -1;
            if (path_ptr < 0 or path_len < 0 or out_ptr < 0 or out_cap < 0) return -1;
            const p = pluginForCaller(hc, @ptrCast(caller.rt)) orelse return -1;
            const path = mem.sliceAt(@intCast(path_ptr), @intCast(path_len)) catch return -1;
            const dst = mem.sliceAt(@intCast(out_ptr), @intCast(out_cap)) catch return -1;
            return p.jsonStr(path, dst);
        }
        fn jsonRaw(caller: *zwasm.Caller, path_ptr: i32, path_len: i32, out_ptr: i32, out_cap: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return -1;
            if (path_ptr < 0 or path_len < 0 or out_ptr < 0 or out_cap < 0) return -1;
            const p = pluginForCaller(hc, @ptrCast(caller.rt)) orelse return -1;
            const path = mem.sliceAt(@intCast(path_ptr), @intCast(path_len)) catch return -1;
            const dst = mem.sliceAt(@intCast(out_ptr), @intCast(out_cap)) catch return -1;
            return p.jsonRaw(path, dst);
        }
        fn jsonObj(caller: *zwasm.Caller, path_ptr: i32, path_len: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return -1;
            if (path_ptr < 0 or path_len < 0) return -1;
            const p = pluginForCaller(hc, @ptrCast(caller.rt)) orelse return -1;
            const path = mem.sliceAt(@intCast(path_ptr), @intCast(path_len)) catch return -1;
            return p.jsonObj(path);
        }
    };
    try linker.defineFuncCtx("zdtd", "log", ctx, fn (*zwasm.Caller, i32, i32, i32) anyerror!void, H.log);
    try linker.defineFuncCtx("zdtd", "tick", ctx, fn (*zwasm.Caller) anyerror!i64, H.tick);
    try linker.defineFuncCtx("zdtd", "queue", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.queue);
    try linker.defineFuncCtx("zdtd", "sense", ctx, fn (*zwasm.Caller, i32, i32, i32) anyerror!i32, H.sense);
    try linker.defineFuncCtx("zdtd", "query", ctx, fn (*zwasm.Caller, i32, i32, i32, i32) anyerror!i32, H.query);
    try linker.defineFuncCtx("zdtd", "json_parse", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.jsonParse);
    try linker.defineFuncCtx("zdtd", "json_str", ctx, fn (*zwasm.Caller, i32, i32, i32, i32) anyerror!i32, H.jsonStr);
    try linker.defineFuncCtx("zdtd", "json_raw", ctx, fn (*zwasm.Caller, i32, i32, i32, i32) anyerror!i32, H.jsonRaw);
    try linker.defineFuncCtx("zdtd", "json_obj", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.jsonObj);
}

test "wasm runtime instantiates a trivial module and calls on_enable" { // Hand-built minimal wasm: (module (func (export "on_enable"))) — a no-op
    // void hook.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x0d, 0x01, 0x09, 'o', 'n', '_', 'e', 'n', 'a', 'b', 'l', 'e', 0x00, 0x00, // export on_enable -> func 0
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: locals 0, end
    };
    var ctx = HostCtx{
        .log_fn = &struct {
            fn f(_: *HostCtx, _: u8, _: []const u8) void {}
        }.f,
        .tick_fn = &struct {
            fn f(_: *HostCtx) u64 {
                return 42;
            }
        }.f,
        .queue_fn = &struct {
            fn f(_: *HostCtx, _: i16, _: []const u8) void {}
        }.f,
    };
    var p = try Plugin.load(std.testing.allocator, "trivial", &bytes, &ctx, .{});
    defer p.deinit();
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(!p.hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(p.callHook(.on_enable));
    try std.testing.expect(!p.disabled);
}

test "wasm runtime disables a looping module on fuel exhaustion" {
    // (module (func (export "on_tick") (loop (br 0)))) — an infinite loop that
    // burns fuel until the budget is exhausted.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x0b, 0x01, 0x07, 'o', 'n', '_', 't', 'i', 'c', 'k', 0x00, 0x00, // export on_tick -> func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x0b, // code: loop, br 0, end
    };
    var ctx = HostCtx{
        .log_fn = &struct {
            fn f(_: *HostCtx, _: u8, _: []const u8) void {}
        }.f,
        .tick_fn = &struct {
            fn f(_: *HostCtx) u64 {
                return 1;
            }
        }.f,
        .queue_fn = &struct {
            fn f(_: *HostCtx, _: i16, _: []const u8) void {}
        }.f,
    };
    var p = try Plugin.load(std.testing.allocator, "looper", &bytes, &ctx, .{ .fuel = 1_000 });
    defer p.deinit();
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(!p.callHook(.on_tick));
    try std.testing.expect(p.disabled);
    // A disabled plugin stops being called.
    try std.testing.expect(!p.callHook(.on_tick));
}

test "wasm host loads the C fixture modules: hooks fire, looper disabled" {
    // Fixtures built from C (assets/fixtures/plugin_hello.c / plugin_looper.c):
    // proof the runtime is language-agnostic, not a Zig-only artifact.
    const Cap = struct {
        var queued: [4][]const u8 = undefined;
        var queued_n: usize = 0;
        var logged_n: usize = 0;
        var tick: u64 = 0;
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {
            logged_n += 1;
        }
        fn tickFn(_: *HostCtx) u64 {
            return tick;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n < queued.len) {
                queued[queued_n] = cmd;
                queued_n += 1;
            }
        }
    };
    Cap.queued_n = 0;
    Cap.logged_n = 0;
    Cap.tick = 7;
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
    };
    var host: WasmHost = .{};
    const paths = [_][]const u8{
        "assets/fixtures/plugin_hello.wasm",
        "assets/fixtures/plugin_looper.wasm",
    };
    // Small fuel so the looper is cut off in microseconds, not seconds.
    host.loadAll(std.testing.allocator, &paths, &ctx, .{ .fuel = 50_000 });
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.count());

    // Hello registers every hook; the looper registers the ones it defines.
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_join)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_shutdown)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_tick)]);

    host.enable();
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());

    // Three ticks: hello observes the tick and queues three spawn commands.
    var t: usize = 0;
    while (t < 3) : (t += 1) {
        Cap.tick = 7 + @as(u64, @intCast(t));
        host.onTick();
    }
    try std.testing.expectEqual(@as(usize, 3), Cap.queued_n);
    try std.testing.expectEqualStrings("spawn 256 70 256 40", Cap.queued[0]);
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
    try std.testing.expect(!host.slots[0].disabled); // hello survived
    try std.testing.expect(host.slots[1].disabled); // looper cut off by fuel
    try std.testing.expect(Cap.logged_n > 0); // hello logged through zdtd_log

    // The disabled looper is not called again; hello keeps running.
    Cap.tick = 10;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
}

test "wasm host fires the T15 event hooks with deny/adjust verdicts" {
    // plugin_rules.wasm exports the four event hooks (T15): on_player_death
    // denies, on_block_damage and on_quest_complete double, on_entity_killed
    // keeps. plugin_trap.wasm traps in on_entity_killed: the host disables only
    // that module and the kill still proceeds (trap -> keep).
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
    };
    var host: WasmHost = .{};
    const paths = [_][]const u8{
        "assets/fixtures/plugin_trap.wasm",
        "assets/fixtures/plugin_rules.wasm",
    };
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.count());

    // plugin_rules (slot 1 after the trap reorder): deny death, double block
    // damage, double quest reward, scale kills 150%.
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_player_death)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_entity_killed)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_block_damage)]);
    try std.testing.expect(host.slots[1].hook_present[@intFromEnum(Hook.on_quest_complete)]);
    try std.testing.expectEqual(verdict_deny, host.playerDeath(7));
    try std.testing.expectEqual(@as(i32, 150), host.entityKilled(8, 1));
    try std.testing.expectEqual(@as(i32, 200), host.blockDamage(0, 0, 0, 50));
    try std.testing.expectEqual(@as(i32, 200), host.questComplete(9, 2));

    // plugin_trap (slot 0): on_entity_killed traps -> that module only is
    // disabled (returns keep), then plugin_rules (slot 1) scales 150%; the
    // sim's kill is not blocked by the broken plugin.
    try std.testing.expectEqual(@as(i32, 150), host.entityKilled(10, 1));
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
    try std.testing.expect(host.slots[0].disabled);
    try std.testing.expect(!host.slots[1].disabled);
    // A disabled module keeps reporting keep for every hook.
    try std.testing.expectEqual(@as(i32, 150), host.entityKilled(11, 1));
}

test "wasm plugin admin command hook handles ping/echo and falls through" {
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    const paths = [_][]const u8{"assets/fixtures/plugin_admin.wasm"};
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_admin_command)]);

    var out: [4096]u8 = undefined;
    {
        const rep = host.adminCommand("ping", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("pong\n", rep.?);
    }
    {
        const rep = host.adminCommand("echo hello world", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("hello world\n", rep.?);
    }
    {
        const rep = host.adminCommand("unknown_verb", &out);
        try std.testing.expect(rep == null);
    }
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "wasm chat filter hook deny/rewrite/keep" {
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    const paths = [_][]const u8{"assets/fixtures/plugin_chat.wasm"};
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_chat)]);
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", host.chatFilter(1, "bad", &out).?);
    try std.testing.expectEqualStrings("hi", host.chatFilter(1, "hello", &out).?);
    try std.testing.expect(host.chatFilter(1, "other", &out) == null);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "wasm on_player_login join gate: deny reason, allow others" {
    // T9 proof (WORK_PLAN): the join gate hook is covered with a real .wasm
    // fixture. "rejectme" is denied with the reason "nope"; any other name is
    // allowed; traps/fuel keep the gate open (allow).
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    const paths = [_][]const u8{"assets/fixtures/plugin_login.wasm"};
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_login)]);
    var out: [256]u8 = undefined;
    const reason = host.playerLoginDeny(1, "rejectme", &out).?;
    try std.testing.expectEqualStrings("nope", reason);
    try std.testing.expect(host.playerLoginDeny(1, "SurvivorBob", &out) == null);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_announce.wasm (zig-built) join/leave says + clock announcements" {
    const Cap = struct {
        var queued: [8][128]u8 = undefined;
        var queued_len: [8]usize = .{0} ** 8;
        var queued_n: usize = 0;
        var world_time: u32 = 2 * 24000; // day 2
        var blood_moon: u32 = 1;
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 7;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n < queued.len) {
                const n = @min(cmd.len, 128);
                @memcpy(queued[queued_n][0..n], cmd[0..n]);
                queued_len[queued_n] = n;
                queued_n += 1;
            }
        }
        fn senseFn(_: *HostCtx, out_buf: []u8) usize {
            if (out_buf.len < 24) return 0;
            std.mem.writeInt(u32, out_buf[0..4], 0x3353425a, .little); // 'ZBS3'
            std.mem.writeInt(u32, out_buf[4..8], 0, .little);
            std.mem.writeInt(u32, out_buf[8..12], 1, .little);
            std.mem.writeInt(i32, out_buf[12..16], -1, .little);
            std.mem.writeInt(u32, out_buf[16..20], world_time, .little);
            std.mem.writeInt(u32, out_buf[20..24], blood_moon, .little);
            return 24;
        }
    };
    Cap.queued_n = 0;
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_announce/core_announce.wasm"}, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_tick)]);
    host.enable();
    host.playerJoin(3, 77);
    host.playerLeave(3, 77);
    // First tick: baseline only (no announcements yet).
    host.onTick();
    // Second tick with the same clock: still nothing.
    host.onTick();
    try std.testing.expectEqual(@as(usize, 2), Cap.queued_n); // join + leave says
    try std.testing.expectEqualStrings("say A new survivor has joined the wasteland.", Cap.queued[0][0..Cap.queued_len[0]]);
    try std.testing.expectEqualStrings("say A survivor has left the wasteland.", Cap.queued[1][0..Cap.queued_len[1]]);
    // Day roll + blood-moon end on the next tick.
    Cap.queued_n = 0;
    Cap.world_time = 3 * 24000; // day 3
    Cap.blood_moon = 0;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 2), Cap.queued_n);
    try std.testing.expectEqualStrings("say Day 3", Cap.queued[0][0..Cap.queued_len[0]]);
    try std.testing.expectEqualStrings("say The blood moon fades.", Cap.queued[1][0..Cap.queued_len[1]]);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_killfeed.wasm observer keeps every verdict and never disables" {
    // The reference event-observer plugin (AGENTS.md rule 29, Wasm-first):
    // loaded from the committed module, its verdict hooks must always keep
    // (0) and the module must never trap/disable — a pure observer is a
    // zero-risk addition (docs/PLUGIN_DEV.md "What belongs in a plugin").
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_killfeed/core_killfeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_join)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_leave)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_death)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_entity_killed)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_quest_complete)]);
    // Observer: keep every outcome (0), never deny/adjust.
    try std.testing.expectEqual(@as(i32, 0), host.playerDeath(7));
    try std.testing.expectEqual(@as(i32, 0), host.entityKilled(8, 1));
    try std.testing.expectEqual(@as(i32, 0), host.questComplete(9, 2));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
    // Join/leave are void notifications: they never disable the module.
    host.playerJoin(0, 10);
    host.playerLeave(0, 10);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_pvp.wasm denies player-vs-player damage via kind query" {
    // The player-damage policy plugin (AGENTS rule 29): with the "kind" query
    // verb stubbed (100/200 players, 300 zombie), on_player_damage must deny
    // player-vs-player and keep everything else, never disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn queryFn(_: *HostCtx, req: []const u8, out: []u8) usize {
            var it = std.mem.tokenizeScalar(u8, req, ' ');
            _ = it.next();
            const id_s = it.next() orelse return 0;
            const id = std.fmt.parseInt(i32, id_s, 10) catch return 0;
            const k: u8 = switch (id) {
                100, 200 => 0, // players
                300 => 1, // zombie
                else => return 0,
            };
            out[0] = '0' + k;
            return 1;
        }
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn, .query_fn = &Cap.queryFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_pvp/core_pvp.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_damage)]);
    try std.testing.expectEqual(@as(i32, -1), host.playerDamage(100, 200, 50)); // both players: deny
    try std.testing.expectEqual(@as(i32, 0), host.playerDamage(300, 200, 50)); // zombie -> player: keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_questgate.wasm denies forbidden_* quests via quest query" {
    // The quest-acceptance policy plugin (AGENTS rule 29): with the "quest"
    // query verb stubbed (def 1 -> "forbidden_evil", def 2 -> "tier1_clear"),
    // on_quest_accept must deny the forbidden name and keep the rest, never
    // disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn queryFn(_: *HostCtx, req: []const u8, out: []u8) usize {
            var it = std.mem.tokenizeScalar(u8, req, ' ');
            _ = it.next();
            const id_s = it.next() orelse return 0;
            const id = std.fmt.parseInt(i32, id_s, 10) catch return 0;
            const name: []const u8 = switch (id) {
                1 => "forbidden_evil",
                2 => "tier1_clear",
                else => return 0,
            };
            const n = @min(name.len, out.len);
            @memcpy(out[0..n], name[0..n]);
            return n;
        }
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn, .query_fn = &Cap.queryFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_questgate/core_questgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_quest_accept)]);
    try std.testing.expectEqual(@as(i32, -1), host.questAccept(5, 1)); // forbidden_evil: deny
    try std.testing.expectEqual(@as(i32, 0), host.questAccept(5, 2)); // tier1_clear: keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_craftgate.wasm denies forbidden_* recipes via on_craft_request" {
    // The craft-request policy plugin (AGENTS rule 29): on_craft_request must
    // deny the forbidden recipe name and keep the rest, never disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_craftgate/core_craftgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_craft_request)]);
    try std.testing.expectEqual(@as(i32, -1), host.craftRequest(5, "forbidden_sword", 1)); // deny
    try std.testing.expectEqual(@as(i32, 0), host.craftRequest(5, "resourceWood", 3)); // keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_lootgate.wasm scales loot rolls to 50% via on_loot_roll" {
    // The loot-roll policy plugin (AGENTS rule 29): on_loot_roll must return
    // 50 (scale percent) for every list and never disable.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_lootgate/core_lootgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_loot_roll)]);
    try std.testing.expectEqual(@as(i32, 50), host.lootRoll("EntityLootContainerRegular", 4));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_tradefeed.wasm observes trader events via on_trader_event" {
    // The trader-event observer plugin (AGENTS rule 29): on_trader_event must
    // be present, fire for every kind without disabling, and stay loaded.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    host.traderEvent(107, 42, 0); // open
    host.traderEvent(107, 42, 1); // buy
    host.traderEvent(107, 42, 2); // sell
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "_zdtd_requires validates declarative dependencies at load" {
    // Coeffect fail-closed (paper): a module declaring a capability it does
    // not export (typo'd hook) is rejected at load with a loud error, instead
    // of silently never firing. The valid tradefeed module passes.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.n);
    try std.testing.expect(!host.slots[0].requires_failed);

    var bad: WasmHost = .{};
    bad.loadAll(std.testing.allocator, &[_][]const u8{"assets/fixtures/plugin_requires_bad.wasm"}, &ctx, .{});
    defer bad.shutdown();
    // The module names an unknown capability: it must be rejected, not loaded.
    try std.testing.expectEqual(@as(usize, 0), bad.n);
}

test "plugin reload disposes and reinstantiates the module in place" {
    // HMR (paper): dispose the old fiber (on_shutdown + deinit), reload the
    // module from disk into the same slot, and re-activate (on_enable). The
    // reloaded module must be fully functional and not disabled.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    try std.testing.expect(!host.slots[0].disabled);
    host.traderEvent(107, 42, 1);
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "plugin reload keeps a heap-owned display name valid" {
    // Regression: reload used to free its display copy via defer on the
    // success path while the reloaded slot still pointed at it (use-after-free
    // on the next `plugin list` render, double free at shutdown). A resolved
    // mod slot (PRD 0005) owns its display string, so reload must transfer
    // that ownership, not release it under the slot.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 1), host.n);
    // Install a manifest-style display name owned by the slot.
    host.slots[0].display = try std.testing.allocator.dupe(u8, "core_tradefeed");
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    // Readable after the reload...
    try std.testing.expectEqualStrings("core_tradefeed", host.slots[0].display);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    // ...and freed exactly once at shutdown (the defer above); a double free
    // fails this test under std.testing.allocator.
}

test "plugin reload failure frees the display copy and reports false" {
    // The failed-reload branch must not leave a disposed slot inside 0..n:
    // hooks/deinit would run on undefined memory on the next tick or at
    // shutdown. The dead module is dropped from the range and later modules
    // shift down (HostCtx backlinks and override-point claims follow).
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(
        std.testing.allocator,
        &[_][]const u8{ "plugins/core_tradefeed/core_tradefeed.wasm", "assets/fixtures/plugin_hello.wasm" },
        &ctx,
        .{},
    );
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.n);
    host.slots[0].display = try std.testing.allocator.dupe(u8, "core_tradefeed");
    // Claim points on both modules so claim handling is observable:
    // craft_request -> slot 1 (survivor, must follow down to 0),
    // loot_roll -> slot 0 (dropped, must release).
    host.claims[@intFromEnum(manifest.OverridePoint.craft_request)] = 1;
    host.claims[@intFromEnum(manifest.OverridePoint.loot_roll)] = 0;
    try std.testing.expect(!host.reload(0, "/no/such/plugin.wasm"));
    try std.testing.expectEqual(@as(usize, 1), host.n);
    // Slot 0 now holds the survivor; its backlink addresses its new slot.
    try std.testing.expect(std.mem.endsWith(u8, host.slots[0].name, "plugin_hello.wasm"));
    try std.testing.expect(ctx.plugin_slot[0] != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&host.slots[0])), ctx.plugin_slot[0].?);
    try std.testing.expect(ctx.plugin_slot[1] == null and ctx.rt_slot[1] == null);
    // The survivor's claim followed it down; the dropped module's released.
    try std.testing.expectEqual(@as(u8, 0), host.claims[@intFromEnum(manifest.OverridePoint.craft_request)]);
    try std.testing.expectEqual(no_claim, host.claims[@intFromEnum(manifest.OverridePoint.loot_roll)]);
}

test "findByName matches display name and wasm stem suffix" {
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(
        std.testing.allocator,
        &[_][]const u8{ "plugins/core_tradefeed/core_tradefeed.wasm", "assets/fixtures/plugin_hello.wasm" },
        &ctx,
        .{},
    );
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.n);
    host.slots[0].display = try std.testing.allocator.dupe(u8, "core_tradefeed");
    // Display name is what `plugin list` prints.
    try std.testing.expectEqual(@as(?usize, 0), host.findByName("core_tradefeed"));
    // Stem suffix: `plugin reload hello` matches plugin_hello.wasm.
    try std.testing.expectEqual(@as(?usize, 1), host.findByName("hello"));
    try std.testing.expectEqual(@as(?usize, 1), host.findByName("plugin_hello.wasm"));
    try std.testing.expectEqual(@as(?usize, null), host.findByName(""));
    try std.testing.expectEqual(@as(?usize, null), host.findByName("no_such_mod"));
    host.shutdown();
    try std.testing.expectEqual(@as(usize, 0), host.n);
    try std.testing.expect(ctx.rt_slot[0] == null and ctx.plugin_slot[0] == null);
    try std.testing.expect(ctx.rt_slot[1] == null and ctx.plugin_slot[1] == null);
}

test "host_verbs is the _zdtd_requires vocabulary for host imports" {
    try std.testing.expectEqual(@as(usize, 9), host_verbs.len);
    try std.testing.expect(Plugin.isHostVerb("log"));
    try std.testing.expect(Plugin.isHostVerb("json_obj"));
    try std.testing.expect(!Plugin.isHostVerb("on_tick"));
    try std.testing.expect(!Plugin.isHostVerb("bot"));
}

test "Hook.names is the _zdtd_requires vocabulary for hooks" {
    try std.testing.expectEqual(@typeInfo(Hook).@"enum".fields.len, Hook.names.len);
    inline for (@typeInfo(Hook).@"enum".fields, 0..) |f, i| {
        try std.testing.expectEqualStrings(f.name, Hook.names[i]);
    }
}

test "plugin reload withdraws after on_shutdown before deinit" {
    // HMR: on_shutdown may queue; the owner must withdraw that src after
    // shutdown and before deinit so the replacement (or a compacted neighbor
    // on failed reload) does not inherit the dying fiber's effects.
    const Cap = struct {
        var srcs: [4]i16 = undefined;
        var n: usize = 0;
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn withdrawFn(_: *HostCtx, src: i16) void {
            if (n < srcs.len) {
                srcs[n] = src;
                n += 1;
            }
        }
    };
    Cap.n = 0;
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .withdraw_fn = &Cap.withdrawFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_tradefeed/core_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    const path = host.slots[0].name;
    try std.testing.expect(host.reload(0, path));
    try std.testing.expectEqual(@as(usize, 1), Cap.n);
    try std.testing.expectEqual(@as(i16, 1), Cap.srcs[0]);
    Cap.n = 0;
    try std.testing.expect(!host.reload(0, "/no/such/plugin.wasm"));
    try std.testing.expectEqual(@as(usize, 1), Cap.n);
    try std.testing.expectEqual(@as(i16, 1), Cap.srcs[0]);
}

test "queue import attributes commands to the calling plugin slot" {
    // Temporal composability plumbing: plugin_hello queues a spawn each of the
    // first ticks; the queue import must hand the owner the 1-based slot so a
    // disabled plugin's pending effects can be withdrawn by src.
    const Cap = struct {
        var last_src: i16 = 0;
        var last_cmd: [64]u8 = undefined;
        var last_len: usize = 0;
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, src: i16, cmd: []const u8) void {
            last_src = src;
            const n = @min(cmd.len, last_cmd.len);
            @memcpy(last_cmd[0..n], cmd[0..n]);
            last_len = n;
        }
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"assets/fixtures/plugin_hello.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    host.onTick();
    try std.testing.expectEqual(@as(i16, 1), Cap.last_src);
    try std.testing.expect(std.mem.startsWith(u8, Cap.last_cmd[0..Cap.last_len], "spawn"));
}

test "fps_bot.wasm integration: sense drives brain; aim/look, gating, memory-pursue" {
    // Loads the real committed bot brain and drives it through the host sense
    // import with a canned snapshot, proving the end-to-end sense→brain→queue
    // pipe (RFC 0001 §3 / ADR 0026). The brain must NOT be modified; this is
    // the host-side regression the uncommitted work dropped.
    const Cap = struct {
        // queueFn COPIES each command into owned bytes — the guest reuses one
        // `out` buffer per queue call, so storing a slice would alias.
        var queued: [8][64]u8 = undefined;
        var queued_n: usize = 0;
        var queued_len: [8]usize = undefined;
        var hide_player: bool = false;
        var show_zombie: bool = false;
        var show_flanker: bool = false;
        var with_trailer: bool = false;
        var bot_hp: f32 = 100;

        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn writeRec(b: []u8, base: usize, net: i32, kind: u8, is_self: u8, alive: u8, x: f32, y: f32, z: f32, hp: f32, yaw: f32, target: i32) void {
            const r = b[base .. base + 32];
            std.mem.writeInt(i32, r[0..4], net, .little);
            r[4] = kind;
            r[5] = is_self;
            r[6] = alive;
            r[7] = 0; // pad
            std.mem.writeInt(u32, r[8..12], @bitCast(x), .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(y), .little);
            std.mem.writeInt(u32, r[16..20], @bitCast(z), .little);
            std.mem.writeInt(u32, r[20..24], @bitCast(hp), .little);
            std.mem.writeInt(u32, r[24..28], @bitCast(yaw), .little);
            std.mem.writeInt(i32, r[28..32], target, .little);
        }
        // One 16-byte trailer record (RFC 0001 §3 event layout).
        fn writeEv(b: []u8, base: usize, kind: u8, a: i32, c: i32, amount: f32) void {
            const r = b[base .. base + 16];
            @memset(r, 0);
            r[0] = kind;
            std.mem.writeInt(i32, r[4..8], a, .little);
            std.mem.writeInt(i32, r[8..12], c, .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(amount), .little);
        }
        fn senseFn(_: *HostCtx, out: []u8) usize {
            // header: magic 'ZBS3' (24 bytes: magic, count, tick, self,
            // world_time, blood_moon), records at base 24.
            std.mem.writeInt(u32, out[0..4], 0x3353425a, .little);
            const count: u32 = if (hide_player)
                1
            else
                (if (show_zombie) @as(u32, 3) else @as(u32, 2)) + @as(u32, @intFromBool(show_flanker));
            std.mem.writeInt(u32, out[4..8], count, .little);
            std.mem.writeInt(u32, out[8..12], 1, .little);
            std.mem.writeInt(i32, out[12..16], 0, .little);
            std.mem.writeInt(u32, out[16..20], 1 * 24000 + 12 * 1000, .little); // world_time: day 1, noon
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon off
            var n: u32 = 0;
            // one bot at the origin (self), facing +45deg toward the visible
            // player (yaw = atan2(10,10)+90deg); hp is mutable so the dodge
            // phase can simulate the bot taking damage (100 -> 60).
            writeRec(out, 24, 1000, 2, 1, 1, 0.0, 0.0, 0.0, bot_hp, 2.356, -1);
            n += 1;
            if (!hide_player) {
                // a player at (10, 0, 10) unless hidden (LOS pull-down)
                writeRec(out, 24 + 32, 2000, 0, 0, 1, 10.0, 0.0, 10.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (show_zombie) {
                // a zombie CLOSER to the bot (9,10) than the player (10,10);
                // player-preference targeting must still pick the player.
                writeRec(out, 24 + 64, 3000, 1, 0, 1, 9.0, 0.0, 10.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (show_flanker) {
                // a player BEHIND the bot (facing +X, yaw 0) and closer than the
                // visible player: the FOV cone must exclude it.
                writeRec(out, 24 + @as(usize, n) * 32, 4000, 0, 0, 1, -12.0, 0.0, 0.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (with_trailer) {
                // v2 event trailer: a kind-4 bot-info record (bot 1000 carries a
                // sniper, weapon_id 3) followed by a kind-3 damage event (player
                // 2000 hit bot 1000 for 42). The guest must keep parsing records
                // at the 32-byte stride and derive the trailer from the length.
                const eb = 24 + @as(usize, n) * 32;
                writeEv(out, eb, 4, 1000, 0, 0);
                out[eb + 1] = 3; // weapon_id sniper (loadout-pool index 3)
                writeEv(out, eb + 16, 3, 2000, 1000, 42.0);
                return 24 + @as(usize, n) * 32 + 32;
            }
            return 24 + @as(usize, n) * 32;
        }
    };
    Cap.queued_n = 0;
    Cap.hide_player = false;

    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/fps_bot/fps_bot.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    // The bot module exports the lifecycle hooks we rely on.
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_tick)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_admin_command)]);

    // Admin command round-trip: bot help is handled by the brain, not the core.
    var out: [4096]u8 = undefined;
    const rep = host.adminCommand("bot help", &out);
    try std.testing.expect(rep != null);
    try std.testing.expect(std.mem.find(u8, rep.?, "bot help") != null);

    // Tick 1 (player visible): the brain aims and moves on the player.
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expect(Cap.queued_n >= 2);
    var saw_move = false;
    var saw_look = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        const s = c[0..Cap.queued_len[qi]];
        if (std.mem.startsWith(u8, s, "bot move 1000")) saw_move = true;
        if (std.mem.startsWith(u8, s, "bot look 1000")) saw_look = true;
    }
    try std.testing.expect(saw_move);
    try std.testing.expect(saw_look);

    // Per-bot skill override: after tick 1 the roster knows bot 1000, so
    // `bot skill 4 1000` must reply with the id it targeted.
    var skill_out: [256]u8 = undefined;
    const srep = host.adminCommand("bot skill 4 1000", &skill_out);
    try std.testing.expect(srep != null);
    try std.testing.expect(std.mem.find(u8, srep.?, "id=1000") != null);

    // Roster integrity: the brain locked the player (2000) as its target, so
    // `bot list` must show a valid, non-garbage target for bot 1000.
    var list_out: [512]u8 = undefined;
    const lrep = host.adminCommand("bot list", &list_out);
    try std.testing.expect(lrep != null);
    try std.testing.expect(std.mem.find(u8, lrep.?, "id=1000") != null);
    try std.testing.expect(std.mem.find(u8, lrep.?, "target=2000") != null);

    // Per-bot `bot cfg` overrides parse and reply; unknown keys are rejected.
    // vision/reaction are reset to the skill default (0) right after so the
    // later phases still engage the player at range 14.
    var cfg_out: [256]u8 = undefined;
    const c1 = host.adminCommand("bot cfg 1000 vision 5", &cfg_out);
    try std.testing.expect(c1 != null and std.mem.find(u8, c1.?, "cfg set") != null);
    const c2 = host.adminCommand("bot cfg 1000 reaction 1", &cfg_out);
    try std.testing.expect(c2 != null and std.mem.find(u8, c2.?, "cfg set") != null);
    const c3 = host.adminCommand("bot cfg 1000 bogus 1", &cfg_out);
    try std.testing.expect(c3 != null and std.mem.find(u8, c3.?, "unknown key") != null);
    const c4 = host.adminCommand("bot cfg 1000 vision 0", &cfg_out);
    try std.testing.expect(c4 != null and std.mem.find(u8, c4.?, "cfg set") != null);
    const c5 = host.adminCommand("bot cfg 1000 reaction 0", &cfg_out);
    try std.testing.expect(c5 != null and std.mem.find(u8, c5.?, "cfg set") != null);

    // Tick 2 (identical scene): command gating suppresses redundant move/look.
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expectEqual(@as(usize, 0), Cap.queued_n);

    // Tick 3 (player hidden): the brain keeps hunting the last-known position.
    Cap.hide_player = true;
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expect(Cap.queued_n >= 1);
    var found_pursue = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        if (std.mem.find(u8, c[0..Cap.queued_len[qi]], "10.00 0.00 10.00") != null) found_pursue = true;
    }
    try std.testing.expect(found_pursue);

    // Tick 4 (dodge-on-hit): player visible again and the bot took damage
    // (hp 100 -> 60). The brain must enter an evasive dodge and FORCE a move at
    // the dodge speed (4.00 — no other branch uses it), bypassing command
    // gating even though the scene is otherwise unchanged.
    Cap.hide_player = false;
    Cap.bot_hp = 60;
    Cap.queued_n = 0;
    host.onTick();
    var found_dodge = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        const s = c[0..Cap.queued_len[qi]];
        if (std.mem.startsWith(u8, s, "bot move ") and std.mem.endsWith(u8, s, " 4.00")) found_dodge = true;
    }
    try std.testing.expect(found_dodge);

    // Tick 5+ (fire phase): the static scene stays (bot hp 60, no further
    // damage), so the dodge expires and the reaction gate runs down. A zombie
    // appears CLOSER to the bot than the player, so player-preference targeting
    // must still make the brain fire at the player (2000). The brain must queue
    // `bot shoot 1000 2000` (optionally flagged `head`), proving both the fire
    // path and the target preference work end-to-end.
    Cap.show_zombie = true;
    Cap.show_flanker = true; // closer player behind the bot: FOV must exclude it
    var found_shoot = false;
    var burst_count: usize = 0;
    var fire_ticks: usize = 0;
    while (fire_ticks < 16 and !found_shoot) : (fire_ticks += 1) {
        Cap.queued_n = 0;
        host.onTick();
        var tick_shoots: usize = 0;
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot shoot 1000 2000")) {
                found_shoot = true;
                tick_shoots += 1;
            }
        }
        burst_count = tick_shoots;
    }
    try std.testing.expect(found_shoot);
    // Burst volley: at least two shots queued in the firing tick (skill 2 => 2).
    try std.testing.expect(burst_count >= 2);

    // Tick (flee phase): a nearly-dead bot (hp 15, 0.15 < HP_FLEE_FRAC) of ANY
    // skill (skill 4 was set earlier) must retreat and HOLD fire — no shoot is
    // queued across several ticks, while it still moves (backpedal).
    Cap.bot_hp = 15;
    var flee_ticks: usize = 0;
    var saw_flee_move = false;
    var saw_flee_shoot = false;
    while (flee_ticks < 4) : (flee_ticks += 1) {
        Cap.queued_n = 0;
        host.onTick();
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot move ")) saw_flee_move = true;
            if (std.mem.startsWith(u8, s, "bot shoot ")) saw_flee_shoot = true;
        }
    }
    try std.testing.expect(saw_flee_move);
    try std.testing.expect(!saw_flee_shoot);

    // Stuck juke: with the player hidden and the bot unable to move (the canned
    // host never integrates, so its position is static), the memory-pursue dest
    // is juked perpendicularly after STUCK_TICKS and a NEW move (not the plain
    // 10,10) is queued, instead of grinding forever.
    Cap.hide_player = true;
    var juked = false;
    var k: usize = 0;
    while (k < 26) : (k += 1) {
        Cap.queued_n = 0;
        host.onTick();
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot move ") and std.mem.find(u8, s, "10.00 0.00 10.00") == null) juked = true;
        }
    }
    try std.testing.expect(juked);

    // Trailer phase: a sense pass that ALSO carries kind-4 bot-info (sniper)
    // and kind-3 damage-event records (player 2000 hit bot 1000 for 42) must
    // not desync the brain's record offsets — it still tracks and drives on
    // the player (the grudge keeps it locked), proving the v2 event trailer
    // parses end-to-end (RFC 0001 §3).
    Cap.with_trailer = true;
    Cap.hide_player = false;
    Cap.bot_hp = 58;
    Cap.queued_n = 0;
    host.onTick();
    try std.testing.expect(Cap.queued_n >= 1);
    var trailer_drove = false;
    for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
        const s = c[0..Cap.queued_len[qi]];
        if (std.mem.startsWith(u8, s, "bot look 1000") or std.mem.startsWith(u8, s, "bot move 1000")) trailer_drove = true;
    }
    try std.testing.expect(trailer_drove);
    var list2_out: [512]u8 = undefined;
    const l2 = host.adminCommand("bot list", &list2_out);
    try std.testing.expect(l2 != null);
    try std.testing.expect(std.mem.find(u8, l2.?, "target=2000") != null); // grudge holds the player

    // Ammo/reload phase: the trailer gives bot 1000 a SNIPER (weapon_id 3,
    // mag 5, burst 1, ~0.6 s between shots). Firing must run the mag dry and
    // then hold fire through a reload gap (weapon_reload 2.5 s = 50 ticks)
    // before resuming — proving ammo pacing end-to-end (RFC 0001 §5.1).
    var shoot_ticks: [64]usize = undefined;
    var shoot_n: usize = 0;
    var t: usize = 0;
    while (t < 200 and shoot_n < shoot_ticks.len) : (t += 1) {
        Cap.queued_n = 0;
        host.onTick();
        for (Cap.queued[0..Cap.queued_n], 0..) |*c, qi| {
            const s = c[0..Cap.queued_len[qi]];
            if (std.mem.startsWith(u8, s, "bot shoot ")) {
                if (shoot_n < shoot_ticks.len) shoot_ticks[shoot_n] = t;
                shoot_n += 1;
            }
        }
    }
    // At least two shots (before AND after the reload).
    try std.testing.expect(shoot_n >= 2);
    // The reload window: a gap of at least ~2 s between shots (throttle alone
    // is ~0.6 s; the 2.5 s reload is the only way to see a 45+ tick gap).
    var max_gap: usize = 0;
    var gi: usize = 1;
    while (gi < shoot_n) : (gi += 1) {
        const gap = shoot_ticks[gi] - shoot_ticks[gi - 1];
        if (gap > max_gap) max_gap = gap;
    }
    try std.testing.expect(max_gap >= 45);

    // No module exhausted fuel or trapped through the whole sequence.
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "mcp.wasm: MCP protocol core (session, ping, tools, errors)" {
    // The MCP addon guest (ADR 0031, docs/rfc/0002-mcp-server-design.md M1): the host feeds a
    // client JSON-RPC frame through the on_mcp_frame hook and gets the guest's
    // response back. The guest owns protocol logic; JSON parsing is the host
    // std.json capability; the sense/query surfaces here stand in for the real
    // transport bridge.
    const Cap = struct {
        var sense_enabled: bool = false;
        var queued: [4][64]u8 = undefined;
        var queued_len: [4]usize = undefined;
        var queued_n: usize = 0;

        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, cmd: []const u8) void {
            if (queued_n >= queued.len) return;
            const n = @min(cmd.len, queued[queued_n].len);
            @memcpy(queued[queued_n][0..n], cmd[0..n]);
            queued_len[queued_n] = n;
            queued_n += 1;
        }
        fn writeRec(b: []u8, base: usize, net: i32, kind: u8, x: f32, y: f32, z: f32, hp: f32) void {
            const r = b[base .. base + 32];
            std.mem.writeInt(i32, r[0..4], net, .little);
            r[4] = kind;
            r[5] = 0; // is_self
            r[6] = 1; // alive
            r[7] = 0; // pad
            std.mem.writeInt(u32, r[8..12], @bitCast(x), .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(y), .little);
            std.mem.writeInt(u32, r[16..20], @bitCast(z), .little);
            std.mem.writeInt(u32, r[20..24], @bitCast(hp), .little);
            std.mem.writeInt(u32, r[24..28], @bitCast(@as(f32, 0.0)), .little);
            std.mem.writeInt(i32, r[28..32], -1, .little);
        }
        fn senseFn(_: *HostCtx, out: []u8) usize {
            if (!sense_enabled) return 0;
            // header: magic 'ZBS3' (24 bytes), 2 records, tick 42, self -1
            std.mem.writeInt(u32, out[0..4], 0x3353425a, .little);
            std.mem.writeInt(u32, out[4..8], 2, .little);
            std.mem.writeInt(u32, out[8..12], 42, .little);
            std.mem.writeInt(i32, out[12..16], -1, .little);
            std.mem.writeInt(u32, out[16..20], 0, .little); // world_time
            std.mem.writeInt(u32, out[20..24], 0, .little); // blood_moon
            writeRec(out, 24, 2000, 0, 10.0, 0.0, 10.0, 100.0); // player
            writeRec(out, 56, 3000, 1, 9.0, 0.0, 10.0, 100.0); // zombie
            return 24 + 64;
        }
        fn queryFn(_: *HostCtx, req: []const u8, out: []u8) usize {
            if (!std.mem.eql(u8, req, "mcp.allowlist")) return 0;
            const allow = "bot count\nsay";
            const n = @min(out.len, allow.len);
            @memcpy(out[0..n], allow[0..n]);
            return n;
        }
    };
    Cap.queued_n = 0;
    Cap.sense_enabled = false;

    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
        .sense_fn = &Cap.senseFn,
        .query_fn = &Cap.queryFn,
    };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/mcp/mcp.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expectEqual(@as(usize, 1), host.count());
    const p = &host.slots[0];
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_enable)]);
    try std.testing.expect(p.hook_present[@intFromEnum(Hook.on_mcp_frame)]);
    try std.testing.expect(!p.requires_failed);

    var out: [8192]u8 = undefined;

    // Malformed JSON is a parse error, not a crash.
    {
        const rep = p.callMcpFrame("{nope", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32700") != null);
    }
    // Batches are refused with Invalid Request.
    {
        const rep = p.callMcpFrame("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32600") != null);
    }
    // tools/list before initialize is not allowed (spec -32002).
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32002") != null);
    }
    // ping is allowed pre-initialize and echoes the id.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", rep.?);
    }
    // initialize negotiates the pinned spec version and capabilities.
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":" ++
                "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"id\":7") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"protocolVersion\":\"2025-06-18\"") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"serverInfo\"") != null);
    }
    // Re-initialize is refused.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"initialize\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32600") != null);
    }
    // The initialized notification gets no response and unlocks the tools.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}", &out);
        try std.testing.expect(rep == null);
    }
    // tools/list now lists the registry.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"tools\":[") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"name\":\"server_status\"") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"name\":\"admin_command\"") != null);
    }
    // Unknown tool and missing name are Invalid Params.
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32602") != null);
    }
    // Read tool without a sense surface fails closed (isError, not fake data).
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"server_status\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "no world data available") != null);
    }
    // With a snapshot the same tool reports real host data.
    Cap.sense_enabled = true;
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"server_status\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "ticks=42") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "players=1") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "zombies=1") != null);
    }
    {
        const rep = p.callMcpFrame("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"player_list\"}}", &out);
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "id=2000") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "x=10.0") != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "hp=100.0") != null);
    }
    // admin_command: allowlisted verb queues through the plugin boundary...
    Cap.queued_n = 0;
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{\"verb\":\"bot count 6\"}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "\"result\"") != null);
        try std.testing.expectEqual(@as(usize, 1), Cap.queued_n);
        try std.testing.expect(std.mem.eql(u8, Cap.queued[0][0..Cap.queued_len[0]], "bot count 6"));
    }
    // ...an unlisted verb is denied by the allowlist policy.
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{\"verb\":\"kick Bob\"}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "verb not in allowlist") != null);
    }
    // admin_command without a verb is Invalid Params.
    {
        const rep = p.callMcpFrame(
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"admin_command\",\"arguments\":{}}}",
            &out,
        );
        try std.testing.expect(rep != null);
        try std.testing.expect(std.mem.find(u8, rep.?, "-32602") != null);
    }
    // No module trapped or exhausted fuel through the whole sequence.
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "core_perkgate.wasm denies forbidden_* perk spends via on_perk_spend" {
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: i16, _: []const u8) void {}
        fn queryFn(_: *HostCtx, _: []const u8, _: []u8) usize {
            return 0;
        }
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn, .query_fn = &Cap.queryFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"plugins/core_perkgate/core_perkgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_perk_spend)]);
    // Deny a forbidden-named perk spend; keep everything else.
    try std.testing.expectEqual(@as(i32, -1), host.perkSpend(100, "forbidden_evil", 1, 1));
    try std.testing.expectEqual(@as(i32, 0), host.perkSpend(100, "perkLightEater", 1, 1));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}
