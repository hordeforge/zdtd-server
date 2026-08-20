//! Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate
//! it under fuel and memory budgets, register the minimal host import table,
//! and call the optional guest hooks (`Hook`: lifecycle plus the verdict and
//! text hooks documented in docs/PLUGIN_DEV.md).
//! Data crosses as flat bytes in the guest's linear memory; no host pointer
//! reaches a guest and WASI is deliberately not provided.
//!
//! Non-goals: WASI, hot reload, JIT, any hook the host table does not expose.

const std = @import("std");
const zwasm = @import("zwasm");
const io_fs = @import("../util/io_fs.zig");

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

    pub const names = [_][]const u8{
        "on_enable",        "on_tick",          "on_player_join",   "on_shutdown",
        "on_player_death",  "on_entity_killed", "on_block_damage",  "on_quest_complete",
        "on_admin_command", "on_chat",          "on_player_login",  "on_player_leave",
        "on_player_damage", "on_quest_accept",  "on_craft_request", "on_loot_roll",
        "on_trader_event",
    };
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
/// Ceiling on one `zdtd.sense` snapshot (BOTS_SPEC §3). The guest requests up
/// to this much; the host never writes past it into the guest.
pub const host_sense_max: usize = 2048;
/// Ceiling on one `zdtd.query` response (BOTS_SPEC §3). The host never writes
/// past this into the guest.
pub const query_resp_max: usize = 64;

pub const HostCtx = struct {
    /// Owner state (a *Game in the server); cast by the callbacks the owner
    /// installs. Keeps this layer free of a Game dependency.
    data: ?*anyopaque = null,
    log_fn: *const fn (ctx: *HostCtx, level: u8, msg: []const u8) void,
    tick_fn: *const fn (ctx: *HostCtx) u64,
    queue_fn: *const fn (ctx: *HostCtx, cmd: []const u8) void,
    /// Build a read-only world snapshot into `out`, returning bytes written.
    /// 0 when the owner has no sense (a plain event plugin). Signature keeps
    /// this layer free of a Game dependency; the owner casts via `data`.
    sense_fn: ?*const fn (ctx: *HostCtx, out: []u8) usize = null,
    /// Reverse-direction point query (BOTS_SPEC §3): the guest writes a text
    /// request (e.g. `cover x z tx tz`) and the host writes a text response,
    /// returning bytes written (0 = no answer / unknown query). Null when the
    /// owner has no query surface.
    query_fn: ?*const fn (ctx: *HostCtx, req: []const u8, out: []u8) usize = null,
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
    /// Set when a hook traps or exhausts fuel: the module stops being called.
    disabled: bool = false,
    hook_present: [@typeInfo(Hook).@"enum".fields.len]bool = .{false} ** @typeInfo(Hook).@"enum".fields.len,
    /// Guest offset and size of the host's scratch region for the request/reply
    /// hooks (admin command, chat, login). Reserved lazily; 0/0 until first use.
    scratch_off: u32 = 0,
    scratch_len: usize = 0,

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
        return p;
    }

    pub fn deinit(self: *Plugin) void {
        self.instance.deinit();
        self.linker.deinit();
        self.module.deinit();
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// A hook is present when the module exports it. Missing exports are
    /// ordinary (a module registers only the hooks it needs).
    fn probeHooks(self: *Plugin) void {
        for (Hook.names, 0..) |hname, i| {
            self.hook_present[i] = self.instance.exportFuncSig(hname) != null;
        }
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

    /// Load every module path that exists; a missing or unloadable module is
    /// logged and skipped so one bad file does not take the server down.
    pub fn loadAll(
        self: *WasmHost,
        allocator: std.mem.Allocator,
        paths: []const []const u8,
        ctx: *HostCtx,
        budget: Budget,
    ) void {
        for (paths) |p| {
            if (self.n >= max_wasm_plugins) {
                std.debug.print("zdtd: wasm plugin cap {d} reached; skipping '{s}'\n", .{ max_wasm_plugins, p });
                return;
            }
            const bytes = io_fs.readFileAll(allocator, p) catch |err| {
                std.debug.print("zdtd: wasm plugin '{s}' unreadable: {s}\n", .{ p, @errorName(err) });
                continue;
            };
            defer allocator.free(bytes);
            if (bytes.len > max_wasm_module_bytes) {
                std.debug.print("zdtd: wasm plugin '{s}' too large ({d} bytes)\n", .{ p, bytes.len });
                continue;
            }
            const p2 = Plugin.load(allocator, p, bytes, ctx, budget) catch |err| {
                std.debug.print("zdtd: wasm plugin '{s}' load failed: {s}\n", .{ p, @errorName(err) });
                continue;
            };
            self.slots[self.n] = p2;
            self.n += 1;
            std.debug.print("zdtd: wasm plugin loaded '{s}'\n", .{p});
        }
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

    pub fn playerDamage(self: *WasmHost, attacker: i32, victim: i32, amount: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callPlayerDamage(attacker, victim, amount);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    pub fn questAccept(self: *WasmHost, player: i32, def_id: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callQuestAccept(player, def_id);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    pub fn craftRequest(self: *WasmHost, player: i32, recipe_name: []const u8, times: i32) i32 {
        for (0..self.n) |i| {
            const v = self.slots[i].callCraftRequest(player, recipe_name, times);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    pub fn lootRoll(self: *WasmHost, list_name: []const u8, rolled: i32) i32 {
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

    pub fn questComplete(self: *WasmHost, player: i32, quest_def: i32) i32 {
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
            hc.queue_fn(hc, cmd);
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
    };
    try linker.defineFuncCtx("zdtd", "log", ctx, fn (*zwasm.Caller, i32, i32, i32) anyerror!void, H.log);
    try linker.defineFuncCtx("zdtd", "tick", ctx, fn (*zwasm.Caller) anyerror!i64, H.tick);
    try linker.defineFuncCtx("zdtd", "queue", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.queue);
    try linker.defineFuncCtx("zdtd", "sense", ctx, fn (*zwasm.Caller, i32, i32, i32) anyerror!i32, H.sense);
    try linker.defineFuncCtx("zdtd", "query", ctx, fn (*zwasm.Caller, i32, i32, i32, i32) anyerror!i32, H.query);
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
            fn f(_: *HostCtx, _: []const u8) void {}
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
            fn f(_: *HostCtx, _: []const u8) void {}
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
        fn queueFn(_: *HostCtx, cmd: []const u8) void {
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
        fn queueFn(_: *HostCtx, _: []const u8) void {}
    };
    var ctx = HostCtx{
        .log_fn = &Cap.logFn,
        .tick_fn = &Cap.tickFn,
        .queue_fn = &Cap.queueFn,
    };
    var host: WasmHost = .{};
    const paths = [_][]const u8{
        "assets/fixtures/plugin_rules.wasm",
        "assets/fixtures/plugin_trap.wasm",
    };
    host.loadAll(std.testing.allocator, &paths, &ctx, .{});
    defer host.shutdown();
    try std.testing.expectEqual(@as(usize, 2), host.count());

    // plugin_rules: deny death, double block damage, double quest reward,
    // observe kills.
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_death)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_entity_killed)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_block_damage)]);
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_quest_complete)]);
    try std.testing.expectEqual(verdict_deny, host.playerDeath(7));
    try std.testing.expectEqual(@as(i32, 0), host.entityKilled(8, 1));
    try std.testing.expectEqual(@as(i32, 200), host.blockDamage(0, 0, 0, 50));
    try std.testing.expectEqual(@as(i32, 200), host.questComplete(9, 2));

    // plugin_trap: on_entity_killed traps -> that module only is disabled; the
    // verdict keeps (0) so the sim's kill is not blocked by a broken plugin.
    try std.testing.expectEqual(@as(i32, 0), host.entityKilled(10, 1));
    try std.testing.expectEqual(@as(usize, 1), host.disabledCount());
    try std.testing.expect(host.slots[1].disabled);
    try std.testing.expect(!host.slots[0].disabled);
    // A disabled module keeps reporting keep for every hook.
    try std.testing.expectEqual(@as(i32, 0), host.entityKilled(11, 1));
}

test "wasm plugin admin command hook handles ping/echo and falls through" {
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
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
        fn queueFn(_: *HostCtx, _: []const u8) void {}
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
        fn queueFn(_: *HostCtx, _: []const u8) void {}
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

test "zdtd_killfeed.wasm observer keeps every verdict and never disables" {
    // The reference event-observer plugin (AGENTS.md rule 29, Wasm-first):
    // loaded from the committed module, its verdict hooks must always keep
    // (0) and the module must never trap/disable — a pure observer is a
    // zero-risk addition (docs/PLUGIN_DEV.md "What belongs in a plugin").
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_killfeed/zdtd_killfeed.wasm"}, &ctx, .{});
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

test "zdtd_pvp.wasm denies player-vs-player damage via kind query" {
    // The player-damage policy plugin (AGENTS rule 29): with the "kind" query
    // verb stubbed (100/200 players, 300 zombie), on_player_damage must deny
    // player-vs-player and keep everything else, never disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
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
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_pvp/zdtd_pvp.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_player_damage)]);
    try std.testing.expectEqual(@as(i32, -1), host.playerDamage(100, 200, 50)); // both players: deny
    try std.testing.expectEqual(@as(i32, 0), host.playerDamage(300, 200, 50)); // zombie -> player: keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "zdtd_questgate.wasm denies forbidden_* quests via quest query" {
    // The quest-acceptance policy plugin (AGENTS rule 29): with the "quest"
    // query verb stubbed (def 1 -> "forbidden_evil", def 2 -> "tier1_clear"),
    // on_quest_accept must deny the forbidden name and keep the rest, never
    // disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
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
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_questgate/zdtd_questgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_quest_accept)]);
    try std.testing.expectEqual(@as(i32, -1), host.questAccept(5, 1)); // forbidden_evil: deny
    try std.testing.expectEqual(@as(i32, 0), host.questAccept(5, 2)); // tier1_clear: keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "zdtd_craftgate.wasm denies forbidden_* recipes via on_craft_request" {
    // The craft-request policy plugin (AGENTS rule 29): on_craft_request must
    // deny the forbidden recipe name and keep the rest, never disabling.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_craftgate/zdtd_craftgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_craft_request)]);
    try std.testing.expectEqual(@as(i32, -1), host.craftRequest(5, "forbidden_sword", 1)); // deny
    try std.testing.expectEqual(@as(i32, 0), host.craftRequest(5, "resourceWood", 3)); // keep
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "zdtd_lootgate.wasm scales loot rolls to 50% via on_loot_roll" {
    // The loot-roll policy plugin (AGENTS rule 29): on_loot_roll must return
    // 50 (scale percent) for every list and never disable.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_lootgate/zdtd_lootgate.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_loot_roll)]);
    try std.testing.expectEqual(@as(i32, 50), host.lootRoll("EntityLootContainerRegular", 4));
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "zdtd_tradefeed.wasm observes trader events via on_trader_event" {
    // The trader-event observer plugin (AGENTS rule 29): on_trader_event must
    // be present, fire for every kind without disabling, and stay loaded.
    const Cap = struct {
        fn logFn(_: *HostCtx, _: u8, _: []const u8) void {}
        fn tickFn(_: *HostCtx) u64 {
            return 1;
        }
        fn queueFn(_: *HostCtx, _: []const u8) void {}
    };
    var ctx = HostCtx{ .log_fn = &Cap.logFn, .tick_fn = &Cap.tickFn, .queue_fn = &Cap.queueFn };
    var host: WasmHost = .{};
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_tradefeed/zdtd_tradefeed.wasm"}, &ctx, .{});
    defer host.shutdown();
    host.enable();
    try std.testing.expect(host.slots[0].hook_present[@intFromEnum(Hook.on_trader_event)]);
    host.traderEvent(107, 42, 0); // open
    host.traderEvent(107, 42, 1); // buy
    host.traderEvent(107, 42, 2); // sell
    try std.testing.expectEqual(@as(usize, 0), host.disabledCount());
}

test "zdtd_bot.wasm integration: sense drives brain; aim/look, gating, memory-pursue" {
    // Loads the real committed bot brain and drives it through the host sense
    // import with a canned snapshot, proving the end-to-end sense→brain→queue
    // pipe (BOTS_SPEC §3 / ADR 0026). The brain must NOT be modified; this is
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

        fn queueFn(_: *HostCtx, cmd: []const u8) void {
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
        // One 16-byte trailer record (BOTS_SPEC §3 event layout).
        fn writeEv(b: []u8, base: usize, kind: u8, a: i32, c: i32, amount: f32) void {
            const r = b[base .. base + 16];
            @memset(r, 0);
            r[0] = kind;
            std.mem.writeInt(i32, r[4..8], a, .little);
            std.mem.writeInt(i32, r[8..12], c, .little);
            std.mem.writeInt(u32, r[12..16], @bitCast(amount), .little);
        }
        fn senseFn(_: *HostCtx, out: []u8) usize {
            // header: magic 'ZBS2', count, tick 1, self 0
            std.mem.writeInt(u32, out[0..4], 0x3253425a, .little);
            const count: u32 = if (hide_player)
                1
            else
                (if (show_zombie) @as(u32, 3) else @as(u32, 2)) + (if (show_flanker) @as(u32, 1) else 0);
            std.mem.writeInt(u32, out[4..8], count, .little);
            std.mem.writeInt(u32, out[8..12], 1, .little);
            std.mem.writeInt(i32, out[12..16], 0, .little);
            var n: u32 = 0;
            // one bot at the origin (self), facing +45deg toward the visible
            // player (yaw = atan2(10,10)+90deg); hp is mutable so the dodge
            // phase can simulate the bot taking damage (100 -> 60).
            writeRec(out, 16, 1000, 2, 1, 1, 0.0, 0.0, 0.0, bot_hp, 2.356, -1);
            n += 1;
            if (!hide_player) {
                // a player at (10, 0, 10) unless hidden (LOS pull-down)
                writeRec(out, 16 + 32, 2000, 0, 0, 1, 10.0, 0.0, 10.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (show_zombie) {
                // a zombie CLOSER to the bot (9,10) than the player (10,10);
                // player-preference targeting must still pick the player.
                writeRec(out, 16 + 64, 3000, 1, 0, 1, 9.0, 0.0, 10.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (show_flanker) {
                // a player BEHIND the bot (facing +X, yaw 0) and closer than the
                // visible player: the FOV cone must exclude it.
                writeRec(out, 16 + @as(usize, n) * 32, 4000, 0, 0, 1, -12.0, 0.0, 0.0, 100.0, 0.0, -1);
                n += 1;
            }
            if (with_trailer) {
                // v2 event trailer: a kind-4 bot-info record (bot 1000 carries a
                // sniper, weapon_id 3) followed by a kind-3 damage event (player
                // 2000 hit bot 1000 for 42). The guest must keep parsing records
                // at the 32-byte stride and derive the trailer from the length.
                const eb = 16 + @as(usize, n) * 32;
                writeEv(out, eb, 4, 1000, 0, 0);
                out[eb + 1] = 3; // weapon_id sniper (loadout-pool index 3)
                writeEv(out, eb + 16, 3, 2000, 1000, 42.0);
                return 16 + @as(usize, n) * 32 + 32;
            }
            return 16 + @as(usize, n) * 32;
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
    host.loadAll(std.testing.allocator, &[_][]const u8{"mods/zdtd_bot/zdtd_bot.wasm"}, &ctx, .{});
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
    try std.testing.expect(std.mem.indexOf(u8, rep.?, "bot help") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, srep.?, "id=1000") != null);

    // Roster integrity: the brain locked the player (2000) as its target, so
    // `bot list` must show a valid, non-garbage target for bot 1000.
    var list_out: [512]u8 = undefined;
    const lrep = host.adminCommand("bot list", &list_out);
    try std.testing.expect(lrep != null);
    try std.testing.expect(std.mem.indexOf(u8, lrep.?, "id=1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, lrep.?, "target=2000") != null);

    // Per-bot `bot cfg` overrides parse and reply; unknown keys are rejected.
    // vision/reaction are reset to the skill default (0) right after so the
    // later phases still engage the player at range 14.
    var cfg_out: [256]u8 = undefined;
    const c1 = host.adminCommand("bot cfg 1000 vision 5", &cfg_out);
    try std.testing.expect(c1 != null and std.mem.indexOf(u8, c1.?, "cfg set") != null);
    const c2 = host.adminCommand("bot cfg 1000 reaction 1", &cfg_out);
    try std.testing.expect(c2 != null and std.mem.indexOf(u8, c2.?, "cfg set") != null);
    const c3 = host.adminCommand("bot cfg 1000 bogus 1", &cfg_out);
    try std.testing.expect(c3 != null and std.mem.indexOf(u8, c3.?, "unknown key") != null);
    const c4 = host.adminCommand("bot cfg 1000 vision 0", &cfg_out);
    try std.testing.expect(c4 != null and std.mem.indexOf(u8, c4.?, "cfg set") != null);
    const c5 = host.adminCommand("bot cfg 1000 reaction 0", &cfg_out);
    try std.testing.expect(c5 != null and std.mem.indexOf(u8, c5.?, "cfg set") != null);

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
        if (std.mem.indexOf(u8, c[0..Cap.queued_len[qi]], "10.00 0.00 10.00") != null) found_pursue = true;
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
            if (std.mem.startsWith(u8, s, "bot move ") and std.mem.indexOf(u8, s, "10.00 0.00 10.00") == null) juked = true;
        }
    }
    try std.testing.expect(juked);

    // Trailer phase: a sense pass that ALSO carries kind-4 bot-info (sniper)
    // and kind-3 damage-event records (player 2000 hit bot 1000 for 42) must
    // not desync the brain's record offsets — it still tracks and drives on
    // the player (the grudge keeps it locked), proving the v2 event trailer
    // parses end-to-end (BOTS_SPEC §3).
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
    try std.testing.expect(std.mem.indexOf(u8, l2.?, "target=2000") != null); // grudge holds the player

    // Ammo/reload phase: the trailer gives bot 1000 a SNIPER (weapon_id 3,
    // mag 5, burst 1, ~0.6 s between shots). Firing must run the mag dry and
    // then hold fire through a reload gap (weapon_reload 2.5 s = 50 ticks)
    // before resuming — proving ammo pacing end-to-end (BOTS_SPEC §5.1).
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
