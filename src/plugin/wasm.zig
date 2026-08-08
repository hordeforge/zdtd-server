//! Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate
//! it under fuel and memory budgets, register the minimal host import table,
//! and call the four hooks (on_enable, on_tick, on_player_join, on_shutdown).
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

    pub const names = [_][]const u8{
        "on_enable",        "on_tick",          "on_player_join",  "on_shutdown",
        "on_player_death",  "on_entity_killed", "on_block_damage", "on_quest_complete",
        "on_admin_command", "on_chat",          "on_player_login",
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
pub const HostCtx = struct {
    /// Owner state (a *Game in the server); cast by the callbacks the owner
    /// installs. Keeps this layer free of a Game dependency.
    data: ?*anyopaque = null,
    log_fn: *const fn (ctx: *HostCtx, level: u8, msg: []const u8) void,
    tick_fn: *const fn (ctx: *HostCtx) u64,
    queue_fn: *const fn (ctx: *HostCtx, cmd: []const u8) void,
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
    hook_present: [11]bool = .{false} ** 11,

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
        defineImports(&linker, ctx) catch return error.ImportForbidden;
        const instance = linker.instantiate(&module, .{
            .fuel = .{ .limited = budget.fuel },
            .max_memory_pages = .{ .limited = budget.max_memory_pages },
        }) catch |err| {
            std.debug.print("zdtd: wasm instantiate failed: {s}\n", .{@errorName(err)});
            return error.InstantiateFailed;
        };
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

    /// on_admin_command(cmd_ptr: i32, cmd_len: i32, out_ptr: i32, out_cap: i32) -> i32:
    /// bytes written, 0 not handled, <0 error. Handled means the host replies
    /// with the guest's buffer slice; not handled falls through to the next
    /// plugin / core unknown. Traps disable only that module.
    pub fn callAdminCommand(self: *Plugin, cmd: []const u8, out: []u8) ?[]const u8 {
        if (self.disabled) return null;
        if (!self.hook_present[@intFromEnum(Hook.on_admin_command)]) return null;
        // Copy the command into the guest, call the hook, copy the reply back.
        const mem = self.instance.memory() orelse return null;
        // Allocate guest scratch via a bump helper if the module exports it
        // (`zdtd_alloc`), otherwise use the low end of linear memory with a
        // bounds check — small cmds (<= 512 bytes) so we can reuse a fixed
        // region without growing. Simpler: use host-provided buffers through
        // the imported write path: pass ptr/len into the instance's memory and
        // read the return length.
        var guest_mem = mem.slice();
        // Ensure we have space: guest must have at least cmd.len + out.len.
        // Grow if needed (one page = 64k).
        const need: usize = cmd.len + out.len + 16;
        if (guest_mem.len < need) {
            const pages: u32 = @intCast((need - guest_mem.len + 65535) / 65536);
            _ = mem.grow(pages) orelse return null;
            guest_mem = mem.slice();
        }
        // Layout: [cmd_bytes][out_region]. Keep out_region at a page-aligned-ish
        // offset to avoid overlap with guest stack if it grows from 0.
        const cmd_off: u32 = 1024;
        if (@as(usize, cmd_off) + cmd.len + out.len > guest_mem.len) return null;
        const out_off: u32 = cmd_off + @as(u32, @intCast(cmd.len));
        @memcpy(guest_mem[cmd_off..][0..cmd.len], cmd);
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
        var guest_mem = mem.slice();
        const need: usize = msg.len + out.len + 16;
        if (guest_mem.len < need) {
            const pages: u32 = @intCast((need - guest_mem.len + 65535) / 65536);
            _ = mem.grow(pages) orelse return null;
            guest_mem = mem.slice();
        }
        const msg_off: u32 = 1024;
        if (@as(usize, msg_off) + msg.len + out.len > guest_mem.len) return null;
        const out_off: u32 = msg_off + @as(u32, @intCast(msg.len));
        @memcpy(guest_mem[msg_off..][0..msg.len], msg);
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
        var guest_mem = mem.slice();
        const need: usize = name.len + out.len + 16;
        if (guest_mem.len < need) {
            const pages: u32 = @intCast((need - guest_mem.len + 65535) / 65536);
            _ = mem.grow(pages) orelse return null;
            guest_mem = mem.slice();
        }
        const name_off: u32 = 1024;
        if (@as(usize, name_off) + name.len + out.len > guest_mem.len) return null;
        const out_off: u32 = name_off + @as(u32, @intCast(name.len));
        @memcpy(guest_mem[name_off..][0..name.len], name);
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
            // Negative return is deny; out may be empty.
            if (out.len == 0) return "";
            const n: usize = @intCast(@min(@as(usize, @intCast(-ret)), out.len));
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

/// Host import table, all under the "zdtd" module namespace. The guest calls
/// zdtd_log(level, ptr, len), zdtd_tick() -> i64, zdtd_queue(ptr, len) -> i32.
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
    };
    try linker.defineFuncCtx("zdtd", "log", ctx, fn (*zwasm.Caller, i32, i32, i32) anyerror!void, H.log);
    try linker.defineFuncCtx("zdtd", "tick", ctx, fn (*zwasm.Caller) anyerror!i64, H.tick);
    try linker.defineFuncCtx("zdtd", "queue", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.queue);
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
    // ping -> pong
    {
        const rep = host.adminCommand("ping", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("pong\n", rep.?);
    }
    // echo with args
    {
        const rep = host.adminCommand("echo hello world", &out);
        try std.testing.expect(rep != null);
        try std.testing.expectEqualStrings("hello world\n", rep.?);
    }
    // unknown verb -> not handled
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
