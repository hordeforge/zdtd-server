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
const api = @import("api.zig");
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
    on_evidence = 22,
    on_buff = 23,

    pub const names = [_][]const u8{
        "on_enable",        "on_tick",          "on_player_join",   "on_shutdown",
        "on_player_death",  "on_entity_killed", "on_block_damage",  "on_quest_complete",
        "on_admin_command", "on_chat",          "on_player_login",  "on_player_leave",
        "on_player_damage", "on_quest_accept",  "on_craft_request", "on_loot_roll",
        "on_trader_event",  "on_mcp_frame",     "on_trade_price",   "on_perk_spend",
        "on_stat_changed",  "on_game_event",    "on_evidence",      "on_buff",
    };
};

/// Host import field names under the `zdtd` module (`defineImports`). Keep in
/// sync with the `linker.defineFuncCtx` list: a new import that is missing
/// here is an undeclarable capability (`_zdtd_requires` would reject it).
pub const host_verbs = [_][]const u8{
    "log",        "tick",     "queue",    "sense",    "query",
    "json_parse", "json_str", "json_raw", "json_obj", "config",
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
    /// Set by the loader for the duration of a discovered-mod load: a mod's
    /// manifest is a claim about its capabilities, so `_zdtd_requires` presence
    /// is fail-closed for it. `loadResolved` sets it for every planned module,
    /// legacy `[plugin] modules` entries included: an operator-listed path is
    /// as much a capability claim as a discovered manifest. False on the raw
    /// `loadAll`/`loadInto` path (in-repo test fixtures), where `--export-all`
    /// fixtures would otherwise be refused for exporting hooks they never meant
    /// to claim.
    require_declaration: bool = false,
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
    /// Owner remaps its per-plugin attribution after a failed reload drops the
    /// slot and later modules compact down: `dropped` is the 1-based src that
    /// left, and every surviving src above it decrements. Without it a later
    /// withdrawal targets the wrong module (paper 3.1 attribution must survive
    /// compaction). Null in tests that hold no attributed state.
    shift_srcs_fn: ?*const fn (ctx: *HostCtx, dropped: i16) void = null,
    /// Build a read-only world snapshot into `out`, returning bytes written.
    /// 0 when the owner has no sense (a plain event plugin). Signature keeps
    /// this layer free of a Game dependency; the owner casts via `data`.
    /// `src` is the 1-based slot of the plugin issuing the sense (0 = not
    /// attributable / native): the bot-damage event feed is routed to the
    /// owning fiber's drain only (paper: effects stay in their component's
    /// context), while the world snapshot itself stays shared.
    sense_fn: ?*const fn (ctx: *HostCtx, src: i16, out: []u8) usize = null,
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
    /// The loader required a `_zdtd_requires` declaration and the module did
    /// not provide one it can honour (absent while exporting hooks, unknown
    /// capability, or a declared hook it does not export).
    RequiresUnmet,
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
    /// PRD 0005: tier from manifest.toml (default user for legacy [plugin] modules).
    tier: manifest.Tier = .user,
    /// PRD 0005: manifest name (duped at loadResolved; "" for legacy modules,
    /// which fall back to the path in `name`).
    display: []const u8 = "",
    /// This slot was loaded from a `manifest.toml` (loadResolved). `reload`
    /// preserves it so the module's declaration can be re-read: a legacy
    /// `[plugin] modules` path has no manifest to reconcile and must not pick
    /// up claims from a manifest.toml that happens to sit beside it.
    manifest_loaded: bool = false,
    /// Self-contained default config (the mod's config.toml, raw text; "" when
    /// absent). Served to the guest via the zdtd.config import; owned here.
    config_bytes: []const u8 = "",
    /// Set when a hook traps or exhausts fuel: the module stops being called.
    disabled: bool = false,
    /// Activation latch (paper: a fiber activates once per instantiation):
    /// `enable` runs `on_enable` only for instances not yet activated, so a
    /// repeated call cannot re-run an initializer additively (double-queue).
    /// A reload builds a fresh Plugin (false) and sets it next to the
    /// replacement's `on_enable`.
    activated: bool = false,
    /// The declaration rule this slot was loaded under, recorded by `loadInto`
    /// from `HostCtx.require_declaration` (the probe itself runs inside
    /// `Plugin.load`, before the slot exists, so the live flag lives on the
    /// host). `reload` replays it so HMR holds the same rule as boot: a module
    /// swapped on disk to drop `_zdtd_requires` must not load here and then be
    /// refused on the next restart.
    require_declaration: bool = false,
    hook_present: [@typeInfo(Hook).@"enum".fields.len]bool = .{false} ** @typeInfo(Hook).@"enum".fields.len,
    /// Declarative dependency check (paper: reactive coeffects): `_zdtd_requires`
    /// returns a comma-separated list of capabilities (hook names + host verbs
    /// log/tick/queue/sense/query). Unknown or missing capabilities fail the
    /// load loudly instead of failing lazily at the first call.
    requires_failed: bool = false,
    requires_err: [128]u8 = undefined,
    requires_err_len: usize = 0,
    /// Guest contract version from the optional `_zdtd_api` export (paper 6.6).
    /// Null = the module declares none (the permissive legacy path).
    api_version: ?u32 = null,
    /// Verb mask this module's own `manifest.toml deny` declares.
    module_deny: manifest.QueueVerbMask = 0,
    /// Operator verb policy from `[plugin] deny` / `allow` (right-biased over
    /// the module declaration, paper 3.2.3 / ADR 0039). Preserved across a
    /// reload like tier/display, since the operator config does not change.
    op_deny: manifest.QueueVerbMask = 0,
    op_allow: manifest.QueueVerbMask = 0,
    /// Effective policy the queue boundary checks: `(module | operator deny)`
    /// minus the operator's explicit allows. Recomputed by `refreshDenied`.
    denied: manifest.QueueVerbMask = 0,
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
        // `adopted` lets the declaration failure below release the fully
        // constructed Plugin with the same code the success path uses at
        // shutdown. While it is false the guard errdefers own their own pieces
        // and Plugin.deinit (which also destroys the engine) must not run, or
        // the engine would be freed twice.
        var adopted = false;
        const engine_ptr = allocator.create(zwasm.Engine) catch return error.OutOfMemory;
        errdefer if (!adopted) allocator.destroy(engine_ptr);
        engine_ptr.* = zwasm.Engine.init(allocator, .{}) catch return error.OutOfMemory;
        errdefer if (!adopted) engine_ptr.deinit();
        var module = engine_ptr.compile(wasm_bytes) catch return error.ParseFailed;
        errdefer if (!adopted) module.deinit();
        var linker = engine_ptr.linker();
        errdefer if (!adopted) linker.deinit();
        defineImports(&linker, ctx) catch return error.ImportForbidden;
        // A zero fuel or page budget traps (or OOMs) the module on its first
        // call, so every plugin would disable immediately. Config clamps this
        // at bind, but load is also reachable from tests and the raw path, so
        // normalize here too: the floor is fail-loud at instantiate, not a
        // silent mass-disable one tick later.
        const fuel = if (budget.fuel == 0) 1 else budget.fuel;
        const pages = if (budget.max_memory_pages == 0) 1 else budget.max_memory_pages;
        var instance = linker.instantiate(&module, .{
            .fuel = .{ .limited = fuel },
            .max_memory_pages = .{ .limited = pages },
        }) catch |err| {
            std.debug.print("zdtd: wasm instantiate failed: {s}\n", .{@errorName(err)});
            return error.InstantiateFailed;
        };
        errdefer if (!adopted) instance.deinit();
        var p: Plugin = .{
            .allocator = allocator,
            .engine = engine_ptr,
            .module = module,
            .linker = linker,
            .instance = instance,
            .name = allocator.dupe(u8, name) catch return error.OutOfMemory,
        };
        p.probeHooks();
        p.probeRequires(ctx.require_declaration, ctx);
        p.probeApiVersion();
        if (ctx.require_declaration and p.requires_failed) {
            // Fail closed at the load boundary: the caller wanted a declared
            // contract and this module does not have one (or declared names it
            // cannot honour). The message is already set for the caller to log.
            adopted = true;
            p.deinit();
            return error.RequiresUnmet;
        }
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
        if (self.config_bytes.len > 0) self.allocator.free(self.config_bytes);
        self.* = undefined;
    }

    /// Recompute the effective queued-verb policy. Paper 3.2.3 interception is
    /// a right-biased merge: the enclosing (operator) context is applied last,
    /// so its denies add to the module's own declaration and its allows clear a
    /// verb the module denied.
    pub fn refreshDenied(self: *Plugin) void {
        self.denied = (self.module_deny | self.op_deny) & ~self.op_allow;
    }

    /// A hook is present when the module exports it. Missing exports are
    /// ordinary (a module registers only the hooks it needs).
    fn probeHooks(self: *Plugin) void {
        for (Hook.names, 0..) |hname, i| {
            self.hook_present[i] = self.instance.exportFuncSig(hname) != null;
        }
    }

    /// Is `cap` a host verb this context can actually serve? The mandatory
    /// verbs (`log`/`tick`/`queue` and the JSON helpers) are always installed;
    /// `sense` and `query` are optional callbacks, so a module that declares
    /// one against an owner that never wired it would pass validation and then
    /// silently read 0 bytes forever. That is the same never-fire shape the
    /// capability check exists to prevent, so the two optional verbs are
    /// accepted only when their callback is present. `ctx` is null only in
    /// unit tests that build a Plugin without a host.
    pub fn isHostVerb(cap: []const u8, ctx: ?*HostCtx) bool {
        if (std.mem.eql(u8, cap, "sense")) return ctx != null and ctx.?.sense_fn != null;
        if (std.mem.eql(u8, cap, "query")) return ctx != null and ctx.?.query_fn != null;
        for (host_verbs) |v| {
            if (std.mem.eql(u8, cap, v)) return true;
        }
        return false;
    }

    /// Is `want` one of the capabilities the declaration lists? Comma-split
    /// with the same trim the validation loop uses.
    fn declaredHas(spec: []const u8, want: []const u8) bool {
        var it = std.mem.splitScalar(u8, spec, ',');
        while (it.next()) |raw| {
            if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), want)) return true;
        }
        return false;
    }

    /// Declarative capability check (`_zdtd_requires` -> "name,name,..." in
    /// guest memory). Every name must be a hook the module exports or a host
    /// verb it imports; anything else fails the load with the offending name.
    /// Coeffect fail-closed: a typo'd hook never silently never-fires.
    fn probeRequires(self: *Plugin, require_declaration: bool, ctx: *HostCtx) void {
        if (self.instance.exportFuncSig("_zdtd_requires") == null) {
            // A planned module must declare its contract; the raw load path
            // does not, because its callers are the in-repo test harness (the
            // C fixtures export every symbol via --export-all, so "exports a
            // hook" is not evidence of intent there). `require_declaration` is
            // set by loadResolved for every planned module and by reload for a
            // manifest-backed slot.
            //
            // The hole this closes: nothing validated the hook names a mod
            // believes it registered, so a typo was a silent never-fire. A mod
            // that exports no hook at all is left alone - it has nothing to
            // declare.
            if (require_declaration) {
                for (self.hook_present) |present| {
                    if (present) {
                        self.requiresFailed("exports hooks but has no _zdtd_requires");
                        return;
                    }
                }
            }
            return;
        }
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
            if (isHostVerb(cap, ctx)) continue;
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
        if (require_declaration) {
            // The import side of the declaration contract, narrowed to the
            // conditional verbs (paper: inject): a `zdtd.sense` / `zdtd.query`
            // import whose declaration omits it reads zero forever against an
            // owner that never wired the callback, with no claim to inspect -
            // the never-fire shape the name set exists to prevent. The other
            // host verbs are bound unconditionally by the host import table,
            // so every call they make already flows through the context's
            // provided surface and the name set adds no tracking the linker
            // table lacks (an under-declared always-linked verb is a
            // documentation inaccuracy, recorded as a skip). Fixtures stay
            // permissive on the raw load path either way.
            var imps = self.module.imports(self.allocator) catch {
                self.requiresFailed("cannot introspect the import section");
                return;
            };
            defer imps.deinit();
            for (imps.items) |imp| {
                if (imp.kind != .func) continue;
                if (!std.mem.eql(u8, imp.module, "zdtd")) continue;
                if (!std.mem.eql(u8, imp.name, "sense") and !std.mem.eql(u8, imp.name, "query")) continue;
                if (!declaredHas(spec, imp.name)) {
                    self.requiresFailed2("imports host verb '", imp.name, "' but does not declare it");
                    return;
                }
            }
        }
    }

    fn requiresFailed(self: *Plugin, why: []const u8) void {
        self.requiresFailed2("", why, "");
    }

    /// Paper 6.6 (review F6): the dependency link is a name set, so it cannot
    /// see a semantic change between two contract versions that still share the
    /// hook vocabulary. A module may declare the version it was built against
    /// with an optional `_zdtd_api() -> i32` export: a version newer than this
    /// host is refused fail-closed (the same channel as an unmet
    /// `_zdtd_requires`), an older one is accepted and logged, and a module
    /// without the export keeps the permissive path (the shipped C fixtures and
    /// any pre-versioning module), which is recorded in PLUGIN_API.md.
    fn probeApiVersion(self: *Plugin) void {
        if (self.instance.exportFuncSig("_zdtd_api") == null) return;
        const ver: u32 = @bitCast(self.instance.call(fn () i32, "_zdtd_api", .{}) catch {
            self.requiresFailed("_zdtd_api trapped");
            return;
        });
        self.api_version = ver;
        if (ver > api.plugin_api_version) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "declares plugin API v{d}; this host is v{d}",
                .{ ver, api.plugin_api_version },
            ) catch "declares a newer plugin API version";
            self.requiresFailed(msg);
        } else if (ver < api.plugin_api_version) {
            std.debug.print(
                "zdtd: plugin '{s}' declares plugin API v{d}, host v{d}; accepted as older\n",
                .{ self.name, ver, api.plugin_api_version },
            );
        }
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

    /// on_buff(entity: i32, name_ptr: i32, name_len: i32, adding: i32) -
    /// observer. Fires for every buff the server applies or drops, whatever
    /// caused it: a C2S request, the tick expiry drain, or the death clear on
    /// respawn. The buff name is copied into the guest's scratch (the stable
    /// key; the numeric def_id is a per-load catalog index and must not cross
    /// the boundary). Pure observer - the sim stays the authority, and the
    /// return is discarded, so a plugin cannot veto a buff the server has
    /// already applied and relayed.
    pub fn callBuff(self: *Plugin, entity: i32, name: []const u8, adding: bool) void {
        if (self.disabled) return;
        if (!self.hook_present[@intFromEnum(Hook.on_buff)]) return;
        const mem = self.instance.memory() orelse return;
        const off = self.reserveScratch(mem, name.len) orelse return;
        @memcpy(mem.slice()[off..][0..name.len], name);
        self.instance.call(
            fn (i32, i32, i32, i32) void,
            "on_buff",
            .{ entity, @intCast(off), @intCast(name.len), @intFromBool(adding) },
        ) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_buff disabled: {s}\n", .{ self.name, @errorName(err) });
        };
    }

    /// on_evidence(tick: i32, peer_local: i32, entity_id: i32, detector: i32,
    /// severity: i32, surface: i32, observed_bits: i32, bound_bits: i32) -
    /// read-only observer (T21): the guard's evidence ring event, streamed to
    /// guests for custom detection/alerting. NEVER a gate: the host already
    /// applied the T20 severity ceiling and the verdict is discarded. Floats
    /// arrive as f32 bits (@bitCast back in the guest); `severity` is the
    /// EFFECTIVE severity (post-ceiling).
    pub fn callEvidence(self: *Plugin, tick: i32, peer_local: i32, entity_id: i32, detector: i32, severity: i32, surface: i32, observed_bits: i32, bound_bits: i32) void {
        if (self.disabled) return;
        if (!self.hook_present[@intFromEnum(Hook.on_evidence)]) return;
        self.instance.call(fn (i32, i32, i32, i32, i32, i32, i32, i32) void, "on_evidence", .{ tick, peer_local, entity_id, detector, severity, surface, observed_bits, bound_bits }) catch |err| {
            self.disabled = true;
            std.debug.print("zdtd: plugin '{s}' on_evidence disabled: {s}\n", .{ self.name, @errorName(err) });
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

/// Fixed-table capacity for loaded .wasm plugins. A ceiling, not a policy: the
/// slot table is inline in the host, so every slot costs a Plugin header even
/// when empty. It was 8 while the shipped tree already carries 14 modules (12
/// core plugins plus the mcp/parachute addons), so a full `[plugin] modules`
/// list silently lost modules at the cap; 32 leaves headroom and the
/// `shipped core plugins declare the host contract version` test asserts the
/// shipped set still fits. Past the ceiling the loader logs and skips (fail
/// closed on composition, never a partial or fake module).
pub const max_wasm_plugins: usize = 32;
/// Ceiling on one module's bytes at load time (operator-supplied path).
const max_wasm_module_bytes: usize = 16 * 1024 * 1024;

/// Fixed-table host for loaded .wasm plugins: ordered enable/tick/join/shutdown,
/// same hook order as the static host. Load happens once at init (allocation is
/// allowed there); the tick path only calls hooks, which are already budgeted.
/// Index of `name` in the fixed hook table, or `Hook.names.len` when the name
/// is not a hook (callers must fail closed on that).
/// The exclusive-point -> hook link, typed: the three claim sites index
/// `hook_present` with `@intFromEnum`, so an added OverridePoint variant can
/// only name a hook that exists in the table (the stringly
/// `hookIndex(name)` answer, `Hook.names.len` on a miss, read one past
/// `hook_present` at the first dispatch through a mistyped point).
pub fn overrideHook(p: manifest.OverridePoint) Hook {
    return switch (p) {
        .loot_roll => .on_loot_roll,
        .quest_payout => .on_quest_complete,
        .damage_player_scale => .on_player_damage,
        .craft_request => .on_craft_request,
        .trade_price => .on_trade_price,
    };
}

/// A manifest's `deny` list as a verb mask. The resolver validated it at load,
/// so a parse failure here is unreachable; it still fails closed (every verb
/// denied) rather than open, since this is a module's own restriction.
fn moduleDenyMask(list: ?[]const u8) manifest.QueueVerbMask {
    const s = list orelse return 0;
    var bad: []const u8 = "";
    return manifest.queueVerbMask(s, &bad) orelse (@as(manifest.QueueVerbMask, 1) << manifest.QueueVerb.count) - 1;
}

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
        // Plan index -> loaded slot. The two differ whenever a module is
        // skipped (unloadable, or the plugin cap), and `point_claims` is keyed
        // by PLAN index. Binding a claim by plan index would name whichever
        // module happened to land in that slot (whose hook_present may pass),
        // or a slot >= self.n that claimSlot voids forever.
        var slot_of_plan: [max_wasm_plugins]u8 = .{no_claim} ** max_wasm_plugins;
        for (plan.modules) |rm| {
            if (self.n >= max_wasm_plugins) {
                std.debug.print("zdtd: wasm plugin cap {d} reached; skipping '{s}'\n", .{ max_wasm_plugins, rm.manifest.wasm.? });
                // `break`, not `return`: the claim install below is the only
                // thing that binds points to loaded slots, so returning from
                // here left every module that DID load with no claims at all.
                break;
            }
            // Path = <manifest dir>/<wasm> for discovered mods; synthetic
            // explicit modules carry the full path as wasm with dir "".
            const full_path = if (rm.manifest.dir.len > 0)
                (std.Io.Dir.path.join(allocator, &.{ rm.manifest.dir, rm.manifest.wasm.? }) catch {
                    std.debug.print("zdtd: mod '{s}' bad wasm path; skipping\n", .{rm.manifest.name.?});
                    continue;
                })
            else
                rm.manifest.wasm.?;
            defer if (rm.manifest.dir.len > 0) allocator.free(full_path);
            // A discovered mod's manifest is a claim about capabilities, so its
            // `_zdtd_requires` presence is fail-closed (ADR 0030). The flag is
            // set on the host because the probe runs inside Plugin.load, before
            // the slot is installed; restore it so the raw load path (test
            // fixtures, legacy `[plugin] modules`) keeps its permissive rule.
            const prev_require = ctx.require_declaration;
            ctx.require_declaration = true;
            const load_res = self.loadInto(self.n, full_path);
            ctx.require_declaration = prev_require;
            load_res catch |err| {
                std.debug.print("zdtd: mod '{s}' load failed: {s}\n", .{ rm.manifest.name.?, @errorName(err) });
                continue;
            };
            self.slots[self.n].tier = rm.tier;
            self.slots[self.n].display = allocator.dupe(u8, rm.manifest.name.?) catch "";
            // Only a discovered mod directory has a `manifest.toml` for
            // `reload` to re-read (paper 5.2.1). A legacy `[plugin] modules`
            // entry reaches here as a synthetic manifest with dir "", and the
            // boot path never read a manifest for it: marking it
            // manifest-backed would make a reload adopt point claims, a deny
            // list and a config from a `manifest.toml` that happens to sit
            // beside the .wasm, and drop the config.toml bytes loaded below
            // whenever no manifest sits there at all.
            self.slots[self.n].manifest_loaded = rm.manifest.dir.len > 0;
            self.slots[self.n].module_deny = moduleDenyMask(rm.manifest.deny);
            self.slots[self.n].refreshDenied();
            if (rm.manifest.config.len > 0) {
                self.slots[self.n].config_bytes = allocator.dupe(u8, rm.manifest.config) catch "";
            } else if (rm.manifest.dir.len == 0) {
                // Legacy explicit `[plugin] modules` path (how the shipped core
                // plugins load): the manifest has no dir, so derive the
                // self-contained config from the wasm's own folder - a plugin
                // stays self-contained no matter how it is loaded.
                if (std.Io.Dir.path.dirname(full_path)) |wdir| {
                    const cfg_path = std.Io.Dir.path.join(allocator, &.{ wdir, "config.toml" }) catch null;
                    if (cfg_path) |cp| {
                        defer allocator.free(cp);
                        if (io_fs.fileExists(cp)) {
                            const cfg = io_fs.readFileAll(allocator, cp) catch null;
                            if (cfg) |c| {
                                if (c.len <= manifest.max_config_bytes)
                                    self.slots[self.n].config_bytes = allocator.dupe(u8, c) catch "";
                                allocator.free(c);
                            }
                        }
                    }
                }
            }
            // `rm.slot` is the resolver's final slot index, which is also where
            // this module lands when every earlier module loaded; record where
            // it actually landed instead.
            if (rm.slot < slot_of_plan.len) slot_of_plan[rm.slot] = @intCast(self.n);
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
        // A claim routes the point to its claimant ALONE, so an installed claim
        // whose module never exported the mapped hook would silently drop that
        // point for every other plugin and for the native path. The resolver
        // cannot see exports (it never reads the wasm), so the check is here:
        // a claimant that does not export its hook keeps the claim off the
        // table and reaches the ordinary composition loop instead, which
        // degrades exactly the way an unloaded claimant does.
        self.claims = .{no_claim} ** manifest.OverridePoint.count;
        var it = plan.point_claims.iterator();
        while (it.next()) |entry| {
            const point = manifest.OverridePoint.parsePoint(entry.key_ptr.*) orelse continue;
            // point_claims is keyed by PLAN index; translate to the loaded slot.
            const plan_slot: usize = @intCast(entry.value_ptr.*);
            if (plan_slot >= slot_of_plan.len) continue;
            const slot: usize = slot_of_plan[plan_slot];
            if (slot == no_claim) {
                std.debug.print(
                    "zdtd: claim on {s} names a module that did not load; claim refused\n",
                    .{manifest.OverridePoint.wire(point)},
                );
                continue;
            }
            if (slot < self.n and !self.slots[slot].hook_present[@intFromEnum(overrideHook(point))]) {
                std.debug.print(
                    "zdtd: mod '{s}' claims {s} but does not export {s}; claim refused\n",
                    .{ self.slots[slot].display, manifest.OverridePoint.wire(point), Hook.names[@intFromEnum(overrideHook(point))] },
                );
                continue;
            }
            self.claims[@intFromEnum(point)] = @intCast(slot);
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
    pub fn loadInto(self: *WasmHost, idx: usize, path: []const u8) !void {
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
        self.slots[idx].require_declaration = ctx.require_declaration;
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
        const manifest_loaded = self.slots[idx].manifest_loaded;
        // `config.toml` bytes are loaded by loadResolved/loadAll, not by
        // loadInto, so a reload that only preserved tier/display silently
        // dropped them: every module with a config reverts to its compiled
        // defaults on `plugin reload` while on_enable still reports success
        // (zdtd.config then returns 0 bytes). Copy them here for the same
        // reason as the display name, and with the same ownership rule - the
        // frame owns the copy until the reload succeeds, and frees it on the
        // failure path. A manifest-backed slot re-reads `config.toml` from
        // disk instead (review F11), so its copy starts empty.
        const config_copy = if (!manifest_loaded and self.slots[idx].config_bytes.len > 0)
            self.allocator.dupe(u8, self.slots[idx].config_bytes) catch ""
        else
            "";
        // The operator's interception policy is config-derived, not part of the
        // module, so a reload keeps it (paper 3.2.3 right-bias must not wash out
        // on HMR). `refreshDenied` recombines it with the fresh declaration.
        const module_deny = self.slots[idx].module_deny;
        const op_deny = self.slots[idx].op_deny;
        const op_allow = self.slots[idx].op_allow;
        // Read before deinit: the slot is `undefined` afterwards.
        const require_decl = self.slots[idx].require_declaration;
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
        // HMR holds the same fail-closed rule the slot booted under, whatever
        // that was: a module swapped on disk to drop `_zdtd_requires` must not
        // load here and then be refused on restart (review F8). `manifest_loaded`
        // is the wrong proxy for it, since a legacy `[plugin] modules` entry
        // also loads through loadResolved with the rule on.
        const prev_require = if (self.ctx) |ctx| ctx.require_declaration else false;
        if (require_decl) {
            if (self.ctx) |ctx| ctx.require_declaration = true;
        }
        defer {
            if (self.ctx) |ctx| ctx.require_declaration = prev_require;
        }
        self.loadInto(idx, path_owned) catch |err| {
            std.debug.print("zdtd: wasm plugin reload '{s}' failed: {s}\n", .{ path_owned, @errorName(err) });
            // The disposed slot cannot stay inside 0..n (hooks and deinit
            // would run on undefined memory): drop it from the active range.
            self.dropDisposedSlot(idx);
            // Later modules just compacted down, so the owner's attribution
            // (pending commands, applied spawns and bots, glide flags) has to
            // follow them or a later withdrawal hits the wrong module. This is
            // an invariant of the runtime, not a duty of whoever called reload.
            if (self.ctx) |ctx| {
                if (ctx.shift_srcs_fn) |sf| sf(ctx, @intCast(idx + 1));
            }
            if (display_copy.len > 0) self.allocator.free(display_copy);
            if (config_copy.len > 0) self.allocator.free(config_copy);
            return false;
        };
        self.slots[idx].tier = tier;
        self.slots[idx].display = display_copy;
        self.slots[idx].config_bytes = config_copy;
        self.slots[idx].manifest_loaded = manifest_loaded;
        self.slots[idx].module_deny = module_deny;
        self.slots[idx].op_deny = op_deny;
        self.slots[idx].op_allow = op_allow;
        // Re-read the on-disk declaration before it goes live: a replaced
        // module may have dropped or added a `points` claim or edited its
        // `config.toml` (reviews F11 and the claim reconciliation below), and
        // the install-time table is load-fixed (paper 5.2.1/5.2.2).
        if (manifest_loaded) {
            self.rereadConfig(idx, path_owned);
            self.reconcileClaims(idx, path_owned);
        }
        self.slots[idx].refreshDenied();
        // Activate the new fiber (paper: reinstantiate + reinstall): a fresh
        // instance has `activated` false, so set it beside its on_enable to
        // keep the one-activation-per-instance rule after HMR.
        self.slots[idx].activated = true;
        _ = self.slots[idx].callHook(.on_enable);
        return true;
    }

    /// Re-read `<mod dir>/config.toml` into slot `idx` (review F11). HMR
    /// reloads a manifest-backed module's declaration, so an edited config
    /// must not keep the pre-reload copy. Missing, oversized or unreadable
    /// fails closed to no config, the same rule `loadResolved` applies.
    fn rereadConfig(self: *WasmHost, idx: usize, path: []const u8) void {
        const dir = std.Io.Dir.path.dirname(path) orelse {
            self.setSlotConfig(idx, "");
            return;
        };
        var m = manifest.bindManifest(self.allocator, dir) catch |err| {
            std.debug.print(
                "zdtd: mod '{s}' config re-read failed ({s}); config kept\n",
                .{ self.slots[idx].display, @errorName(err) },
            );
            return;
        };
        defer manifest.free(self.allocator, &m);
        self.setSlotConfig(idx, m.config);
    }

    /// Replace slot `idx`'s owned config bytes ("" = none). Frees the previous
    /// allocation, so every caller hands over a slice it does not own.
    fn setSlotConfig(self: *WasmHost, idx: usize, bytes: []const u8) void {
        if (self.slots[idx].config_bytes.len > 0) self.allocator.free(self.slots[idx].config_bytes);
        self.slots[idx].config_bytes = if (bytes.len > 0)
            (self.allocator.dupe(u8, bytes) catch "")
        else
            "";
    }

    /// Re-install slot `idx`'s exclusive point claims from its on-disk
    /// `manifest.toml`. `loadResolved` builds the claim table once at boot, so
    /// without this a reloaded module keeps exclusivity its replacement no
    /// longer declares, and one that adds a claim never gets it. The slot's
    /// existing claims are released first: the declaration on disk is the only
    /// source of truth. A claim whose hook the module does not export, or whose
    /// point another live module already holds, is refused with a log - the same
    /// fail-closed rule the boot install applies. No manifest on disk means no
    /// claims (a legacy `[plugin] modules` path).
    pub fn reconcileClaims(self: *WasmHost, idx: usize, path: []const u8) void {
        // The on-disk declaration is the source of the module's point claims
        // AND of its queued-verb deny list. Read it first and change state only
        // on success: a vanished manifest means "no claims, no module deny",
        // but an unreadable or invalid one must not silently release
        // exclusivity or lift the deny list the module booted with (review F9;
        // a later restart re-reads it with validate()).
        const dir = std.Io.Dir.path.dirname(path) orelse {
            for (&self.claims) |*c| {
                if (c.* == idx) c.* = no_claim;
            }
            self.slots[idx].module_deny = 0;
            self.slots[idx].refreshDenied();
            return;
        };
        var m = manifest.bindManifest(self.allocator, dir) catch |err| {
            std.debug.print(
                "zdtd: mod '{s}' manifest re-read failed ({s}); deny list kept\n",
                .{ self.slots[idx].display, @errorName(err) },
            );
            return;
        };
        defer manifest.free(self.allocator, &m);
        for (&self.claims) |*c| {
            if (c.* == idx) c.* = no_claim;
        }
        self.slots[idx].module_deny = moduleDenyMask(m.deny);
        defer self.slots[idx].refreshDenied();
        const pts = m.points orelse return;
        var it = std.mem.splitScalar(u8, pts, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            const point = manifest.OverridePoint.parsePoint(name) orelse continue; // validate() rejected unknown names
            const pi = @intFromEnum(point);
            if (!self.slots[idx].hook_present[@intFromEnum(overrideHook(point))]) {
                std.debug.print(
                    "zdtd: mod '{s}' claims {s} but does not export {s}; claim refused\n",
                    .{ self.slots[idx].display, manifest.OverridePoint.wire(point), Hook.names[@intFromEnum(overrideHook(point))] },
                );
                continue;
            }
            if (self.claims[pi] != no_claim and self.claims[pi] != idx) {
                std.debug.print(
                    "zdtd: mod '{s}' claims {s} but slot {d} already holds it; claim refused\n",
                    .{ self.slots[idx].display, manifest.OverridePoint.wire(point), self.claims[pi] },
                );
                continue;
            }
            self.claims[pi] = @intCast(idx);
        }
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
        // The vacated tail keeps the departing module's withdrawal mark
        // otherwise; `loadInto` clears it for a slot it fills, but a slot left
        // empty must not hand a stale mark to whoever lands there next.
        self.withdrawn[self.n - 1] = false;
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
            // A src that does not fit stays unmarked so the next pass still
            // reports it: marking it here would return a count past `out.len`
            // (the caller slices `out[0..n]`) and silently skip the only
            // withdrawal that module will ever get.
            if (n >= out.len) break;
            out[n] = @intCast(i + 1);
            self.withdrawn[i] = true;
            n += 1;
        }
        return n;
    }

    /// Call on_enable for every not-yet-activated loaded plugin. Idempotent:
    /// a second `enable` (or one after a reload already activated its
    /// replacement) must not re-fire an initializer, matching the static
    /// host's `enabled[]` guard.
    pub fn enable(self: *WasmHost) void {
        for (0..self.n) |i| {
            if (self.slots[i].activated) continue;
            self.slots[i].activated = true;
            _ = self.slots[i].callHook(.on_enable);
        }
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

    /// The exclusive claimant for `point`, or null when the claim is not
    /// currently provided. A binding is available to its dependents only while
    /// the fiber that installed it is ACTIVE (paper 5.1.2), and a claimant that
    /// trapped or ran out of fuel has stopped providing even though the claim
    /// table still names it: routing to it would answer `verdict_keep` for
    /// every caller, which for a gate point silently lifts the very check the
    /// claim exists to serve (a user-tier claimant that crashes would disable
    /// the core gate it overrode). The same check catches a reloaded module
    /// that no longer exports the point's hook, since a module that cannot
    /// answer must not hold the point for everyone else.
    pub fn claimSlot(self: *const WasmHost, point: manifest.OverridePoint) ?usize {
        const c = self.claims[@intFromEnum(point)];
        if (c == no_claim or c >= self.n) return null;
        const slot: usize = c;
        if (self.slots[slot].disabled) return null;
        if (!self.slots[slot].hook_present[@intFromEnum(overrideHook(point))]) return null;
        return slot;
    }

    /// Player-damage verdict; point `damage.player_scale` is exclusive when
    /// claimed: only the claimant is consulted and its verdict is final.
    pub fn playerDamage(self: *WasmHost, attacker: i32, victim: i32, amount: i32) i32 {
        if (self.claimSlot(.damage_player_scale)) |c| return self.slots[c].callPlayerDamage(attacker, victim, amount);
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

    /// Buff observer: notify every plugin exporting on_buff. Read-only, so
    /// every slot is called and no return is collected.
    pub fn buff(self: *WasmHost, entity: i32, name: []const u8, adding: bool) void {
        for (0..self.n) |i| self.slots[i].callBuff(entity, name, adding);
    }

    /// Evidence observer (T21): notify every plugin exporting on_evidence.
    /// Read-only - the guard already applied the T20 ceiling and the guest's
    /// return is discarded (host authority).
    pub fn evidence(self: *WasmHost, tick: i32, peer_local: i32, entity_id: i32, detector: i32, severity: i32, surface: i32, observed_bits: i32, bound_bits: i32) void {
        for (0..self.n) |i| self.slots[i].callEvidence(tick, peer_local, entity_id, detector, severity, surface, observed_bits, bound_bits);
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
        if (self.claimSlot(.craft_request)) |c| return self.slots[c].callCraftRequest(player, recipe_name, times);
        for (0..self.n) |i| {
            const v = self.slots[i].callCraftRequest(player, recipe_name, times);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Loot-roll verdict; point `loot.roll` is exclusive when claimed.
    pub fn lootRoll(self: *WasmHost, list_name: []const u8, rolled: i32) i32 {
        if (self.claimSlot(.loot_roll)) |c| return self.slots[c].callLootRoll(list_name, rolled);
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
        if (self.claimSlot(.trade_price)) |c| return self.slots[c].callTradePrice(player, item, unit_price);
        for (0..self.n) |i| {
            const v = self.slots[i].callTradePrice(player, item, unit_price);
            if (v != verdict_keep) return v;
        }
        return verdict_keep;
    }

    /// Quest-complete verdict; point `quest.payout` is exclusive when claimed.
    pub fn questComplete(self: *WasmHost, player: i32, quest_def: i32) i32 {
        if (self.claimSlot(.quest_payout)) |c| return self.slots[c].callQuestComplete(player, quest_def);
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

    /// Route one MCP JSON-RPC frame to the first LIVE exporter of
    /// `on_mcp_frame` and return the response bytes it wrote (0 = no module
    /// answered). `callMcpFrame` returns null for a module that is disabled,
    /// has no memory, exhausted scratch, or trapped (which latches it
    /// disabled); the first `hook_present` match used to end the search there,
    /// so a trapped module dropped the frame even when a later one could
    /// answer. A withdrawn module is already skipped by every other hook and
    /// must not own this one either.
    pub fn routeMcpFrame(self: *WasmHost, frame: []const u8, out: []u8) usize {
        for (self.slots[0..self.n]) |*p| {
            // A trapped module must not own the frame even though
            // callMcpFrame would also refuse it: the skip belongs at the
            // routing decision, not one layer down.
            if (p.disabled) continue;
            if (!p.hook_present[@intFromEnum(Hook.on_mcp_frame)]) continue;
            const rep = p.callMcpFrame(frame, out) orelse continue;
            return rep.len;
        }
        return 0;
    }

    /// Is the 1-based plugin slot `src` withdrawn (disabled or trapped)?
    /// `World.drainCommands` asks this once per queued op so a module that
    /// disables itself while an earlier op is being applied (an
    /// `on_entity_killed` verdict that traps) cannot keep executing the ops it
    /// queued before that. src 0 (native) is never withdrawn.
    pub fn srcWithdrawn(self: *const WasmHost, src: i16) bool {
        if (src <= 0) return false;
        const idx: usize = @intCast(src - 1);
        if (idx >= self.n) return false;
        return self.slots[idx].disabled;
    }

    pub fn disabledCount(self: *const WasmHost) usize {
        var c: usize = 0;
        for (0..self.n) |i| {
            if (self.slots[i].disabled) c += 1;
        }
        return c;
    }
};

/// 0-based slot of the calling instance's runtime pointer, or null when the
/// caller is not attributable. The single rt_slot scan: the queue import
/// derives its 1-based src from this, the sense import routes its event feed
/// the same way, and the json capability reaches per-plugin state through it.
pub fn slotForCaller(hc: *HostCtx, rt: *anyopaque) ?usize {
    for (hc.rt_slot, 0..) |r, i| {
        if (r == rt) return i;
    }
    return null;
}

/// Map a calling instance's runtime pointer to its loaded Plugin (per-plugin
/// state for the json capability).
pub fn pluginForCaller(hc: *HostCtx, rt: *anyopaque) ?*Plugin {
    const i = slotForCaller(hc, rt) orelse return null;
    const p: *Plugin = @ptrCast(@alignCast(hc.plugin_slot[i] orelse return null));
    return p;
}

/// Host import table, all under the "zdtd" module namespace. The import field
/// names are bare: "log" (level, ptr, len), "tick" () -> i64 and "queue"
/// (ptr, len) -> i32, so a guest imports zdtd.log, not zdtd.zdtd_log.
/// Every host fn copies in/out of the guest's linear memory; a missing memory
/// or an out-of-bounds range is a no-op for reads and an error for the guest.
const imports = @import("imports.zig");
const defineImports = imports.defineImports;

test "declaredHas matches the validation loop's comma trim" {
    const spec = "log,on_enable, queue";
    try std.testing.expect(Plugin.declaredHas(spec, "log"));
    try std.testing.expect(Plugin.declaredHas(spec, "on_enable"));
    try std.testing.expect(Plugin.declaredHas(spec, "queue")); // trimmed on both sides
    try std.testing.expect(!Plugin.declaredHas(spec, "que")); // whole token or nothing
    try std.testing.expect(!Plugin.declaredHas("", "log"));
    try std.testing.expect(Plugin.declaredHas("tick", "tick"));
}

test "an undeclared host verb import fails the declared contract on the strict path" {
    // Hand-built module: imports zdtd.log and zdtd.queue, exports
    // _zdtd_requires returning the spec "log" (data at 0, len 3 packed into
    // the i64). The declared set omits the queue import, so a load under
    // `require_declaration` (a discovered mod or a reload) is refused at the
    // load boundary; the raw test-fixture path stays permissive.
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
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x12, 0x03, // type section: three types, payload 18
        0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x00, // 0: (i32,i32,i32) -> () (log)
        0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f, // 1: (i32,i32,i32) -> i32 (sense)
        0x60, 0x00, 0x01, 0x7e, // 2: () -> i64
        0x02, 0x19, 0x02, // import section: one module, two funcs
        0x04, 'z', 'd', 't', 'd', 0x03, 'l', 'o', 'g', 0x00, 0x00, // zdtd.log type 0
        0x04, 'z', 'd', 't', 'd', 0x05, 's', 'e', 'n', 's', 'e', 0x00, 0x01, // zdtd.sense type 1
        0x03, 0x02, 0x01, 0x02, // function section: one local func of type 2
        0x05, 0x03, 0x01, 0x00, 0x01, // memory section: min 1 page
        0x07, 0x12, 0x01, // export section: one entry
        0x0e, '_',  'z',
        'd',  't',  'd',
        '_',  'r',  'e',
        'q',  'u',  'i',
        'r',  'e',  's',
        0x00, 0x02,
        0x0a, 0x0a, 0x01, 0x08, // code section: one body of 8 bytes
        0x00, 0x42, 0x80, 0x80, 0x80, 0x80, 0x30, 0x0b, // locals 0, i64.const 3<<32 ("log"), end
        0x0b, 0x09, 0x01, // data section: one segment
        0x00, 0x41, 0x00, 0x0b, // active at mem 0, offset 0
        0x03, 'l', 'o', 'g', // the spec string
    };
    ctx.require_declaration = true;
    try std.testing.expectError(
        error.RequiresUnmet,
        Plugin.load(std.testing.allocator, "undeclared_verb.wasm", &bytes, &ctx, .{ .fuel = 100_000 }),
    );
    ctx.require_declaration = false;
    var p = try Plugin.load(std.testing.allocator, "undeclared_verb.wasm", &bytes, &ctx, .{ .fuel = 100_000 });
    defer p.deinit();
    try std.testing.expect(!p.requires_failed);
}
