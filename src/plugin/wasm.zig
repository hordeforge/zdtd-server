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

    pub const names = [_][]const u8{ "on_enable", "on_tick", "on_player_join", "on_shutdown" };
};

/// Per-call budget (PLUGIN_API.md). zwasm enforces both itself.
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
    hook_present: [4]bool = .{false} ** 4,

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
