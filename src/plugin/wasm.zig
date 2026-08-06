//! Wasm plugin runtime (ADR 0020, zwasm v2): load a .wasm module, instantiate
//! it under fuel and memory budgets, register the minimal host import table,
//! and call the four hooks (on_enable, on_tick, on_player_join, on_shutdown).
//! Data crosses as flat bytes in the guest's linear memory; no host pointer
//! reaches a guest and WASI is deliberately not provided.
//!
//! Non-goals: WASI, hot reload, JIT, any hook the host table does not expose.

const std = @import("std");
const zwasm = @import("zwasm");

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
pub const HostCtx = struct {
    log_fn: *const fn (level: u8, msg: []const u8) void,
    tick_fn: *const fn () u64,
    queue_fn: *const fn (cmd: []const u8) void,
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
    engine: zwasm.Engine,
    module: zwasm.Module,
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
        var engine = zwasm.Engine.init(allocator, .{}) catch return error.OutOfMemory;
        errdefer engine.deinit();
        var module = engine.compile(wasm_bytes) catch return error.ParseFailed;
        errdefer module.deinit();
        var linker = engine.linker();
        errdefer linker.deinit();
        defineImports(&linker, ctx) catch return error.ImportForbidden;
        const instance = linker.instantiate(&module, .{
            .fuel = .{ .limited = budget.fuel },
            .max_memory_pages = .{ .limited = budget.max_memory_pages },
        }) catch return error.InstantiateFailed;
        var p = Plugin{
            .allocator = allocator,
            .engine = engine,
            .module = module,
            .instance = instance,
            .name = name,
        };
        p.probeHooks();
        return p;
    }

    pub fn deinit(self: *Plugin) void {
        self.instance.deinit();
        self.module.deinit();
        self.engine.deinit();
        self.* = undefined;
    }

    /// A hook is present when the module exports it. Missing exports are
    /// ordinary (a module registers only the hooks it needs).
    fn probeHooks(self: *Plugin) void {
        for (Hook.names, 0..) |hname, i| {
            self.hook_present[i] = self.instance.exportFuncSig(hname) != null;
        }
    }

    /// Call a no-arg hook (on_enable, on_tick, on_shutdown). The guest returns
    /// i32: 0 = ok, non-zero = error (disable). A trap or OutOfFuel disables.
    pub fn callHook(self: *Plugin, hook: Hook) bool {
        if (self.disabled) return false;
        if (!self.hook_present[@intFromEnum(hook)]) return false;
        const name = Hook.names[@intFromEnum(hook)];
        const result = self.instance.call(fn () anyerror!i32, name, .{}) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' {s} disabled: {s}\n", .{ self.name, name, @errorName(err) });
            return false;
        };
        if (result != 0) {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' {s} returned error {d}\n", .{ self.name, name, result });
            return false;
        }
        return true;
    }

    /// on_player_join(slot: i32, entity_id: i32) -> i32.
    pub fn callPlayerJoin(self: *Plugin, slot: i32, entity_id: i32) bool {
        if (self.disabled) return false;
        if (!self.hook_present[@intFromEnum(Hook.on_player_join)]) return false;
        const result = self.instance.call(fn (i32, i32) anyerror!i32, "on_player_join", .{ slot, entity_id }) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_join disabled: {s}\n", .{ self.name, @errorName(err) });
            return false;
        };
        if (result != 0) {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_player_join returned error {d}\n", .{ self.name, result });
            return false;
        }
        return true;
    }

    /// Export the remaining fuel (diagnostics; the runtime enforces the budget).
    pub fn fuelRemaining(self: *Plugin) ?u64 {
        return self.instance.fuelRemaining();
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
            hc.log_fn(@intCast(@max(0, level)), msg);
        }
        fn tick(caller: *zwasm.Caller) anyerror!i64 {
            const hc = caller.data(HostCtx);
            return @intCast(hc.tick_fn());
        }
        fn queue(caller: *zwasm.Caller, ptr: i32, len: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return 1;
            if (ptr < 0 or len < 0) return 1;
            const cmd = mem.sliceAt(@intCast(ptr), @intCast(len)) catch return 1;
            hc.queue_fn(cmd);
            return 0;
        }
    };
    try linker.defineFuncCtx("zdtd", "log", ctx, fn (*zwasm.Caller, i32, i32, i32) anyerror!void, H.log);
    try linker.defineFuncCtx("zdtd", "tick", ctx, fn (*zwasm.Caller) anyerror!i64, H.tick);
    try linker.defineFuncCtx("zdtd", "queue", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.queue);
}

test "wasm runtime instantiates a trivial module and calls on_enable" {
    // Hand-built minimal wasm: (module (func (export "on_enable") (result i32)
    // i32.const 0)) — a no-op hook returning 0.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x0d, 0x01, 0x08, 'o', 'n', '_', 'e', 'n', 'a', 'b', 'l', 'e', 0x00, 0x00, // export on_enable -> func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0b, // code: i32.const 0, end
    };
    var ctx = HostCtx{
        .log_fn = &struct {
            fn f(_: u8, _: []const u8) void {}
        }.f,
        .tick_fn = &struct {
            fn f() u64 {
                return 42;
            }
        }.f,
        .queue_fn = &struct {
            fn f(_: []const u8) void {}
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
    // (module (func (export "on_tick") (result i32) (loop (br 0))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x07, 0x09, 0x01, 0x07, 'o', 'n', '_', 't', 'i', 'c', 'k', 0x00, 0x00, // export on_tick -> func 0
        0x0a, 0x07, 0x01, 0x05, 0x00, 0x03, 0x40, 0x0c, 0x00, 0x0b, // code: loop, br 0
    };
    var ctx = HostCtx{
        .log_fn = &struct {
            fn f(_: u8, _: []const u8) void {}
        }.f,
        .tick_fn = &struct {
            fn f() u64 {
                return 1;
            }
        }.f,
        .queue_fn = &struct {
            fn f(_: []const u8) void {}
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
