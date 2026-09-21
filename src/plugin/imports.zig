//! Host import table for the Wasm guest runtime.
//!
//! Split out of plugin/wasm.zig (same code, moved verbatim); the import
//! field names are bare under the `zdtd` module namespace.

const std = @import("std");
const zwasm = @import("zwasm");
const HostCtx = @import("wasm.zig").HostCtx;
const pluginForCaller = @import("wasm.zig").pluginForCaller;
const host_sense_max = @import("wasm.zig").host_sense_max;
const query_resp_max = @import("wasm.zig").query_resp_max;

pub fn defineImports(linker: *zwasm.Linker, ctx: *HostCtx) !void {
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
        // Self-contained config (the mod's config.toml, raw text): copy the
        // calling module's config bytes into the guest buffer. 0 = no config
        // (module has none, or the buffer is too small - the guest checks the
        // returned length). The host never parses it; each plugin owns its
        // format. Declared via _zdtd_requires "config".
        fn config(caller: *zwasm.Caller, out_ptr: i32, out_cap: i32) anyerror!i32 {
            const hc = caller.data(HostCtx);
            const mem = caller.memory() orelse return 0;
            if (out_ptr < 0 or out_cap < 0) return 0;
            const p = pluginForCaller(hc, @ptrCast(caller.rt)) orelse return 0;
            if (p.config_bytes.len == 0) return 0;
            const copy = @min(@as(usize, @intCast(out_cap)), p.config_bytes.len);
            const dst = mem.sliceAt(@intCast(out_ptr), @intCast(copy)) catch return 0;
            @memcpy(dst, p.config_bytes[0..copy]);
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
    try linker.defineFuncCtx("zdtd", "config", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.config);
    try linker.defineFuncCtx("zdtd", "json_parse", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.jsonParse);
    try linker.defineFuncCtx("zdtd", "json_str", ctx, fn (*zwasm.Caller, i32, i32, i32, i32) anyerror!i32, H.jsonStr);
    try linker.defineFuncCtx("zdtd", "json_raw", ctx, fn (*zwasm.Caller, i32, i32, i32, i32) anyerror!i32, H.jsonRaw);
    try linker.defineFuncCtx("zdtd", "json_obj", ctx, fn (*zwasm.Caller, i32, i32) anyerror!i32, H.jsonObj);
}
