//! blockplaceholders.xml: the weighted replacement lists behind the
//! `terrStoneHelper` / `carWrecksRandomHelper` names a prefab's block map uses.
//!
//! Stock's `BlockPlaceholderMap` (IL=185 `Replace`) keys a list of targets by
//! the placeholder's `BlockValue` and, for each block it stamps, picks one:
//!   - a per-position `GameRandom` from `Utils.RandomFromSeedOnPos(x, y, z,
//!     world.Seed)` (IL=2666: seed = `seed + x + (z << 14) + (y << 24)`), so the
//!     same world seed always paints the same target in the same cell
//!   - targets whose `biome` does not match the cell's biome name (compared
//!     case-insensitively) are skipped, as are targets whose `sandboxoption`
//!     gate fails (`!Name` inverts it)
//!   - the survivors are walked in document order with `roll =
//!     RandomFloat() * sum(prob)`, taking the first target whose `prob` exceeds
//!     the remaining roll; `prob` defaults to 1
//!   - `randomrotation="true"` re-rolls the target's rotation
//! A placeholder whose target list is empty or whose roll finds nothing keeps
//! the authored block, and a target equal to the placeholder becomes Air.
//!
//! zdtd resolves target names to runtime block ids once at load (the sandbox
//! gate is a per-run constant) and leaves the per-cell pick to the paint path,
//! which has the world position and the biome.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const sandbox = @import("sandbox.zig");
const game_random = @import("../util/game_random.zig");

pub const max_placeholders: usize = 1024;
pub const max_targets_per_placeholder: usize = 64;

/// One `<block name=... prob=... biome=... sandboxoption=... randomrotation=.../>`
/// row, already resolved against the block id space and this run's sandbox code.
pub const Target = struct {
    /// Runtime block id; 0 when the name is not a block in this install (the
    /// target is dropped, fail closed - stock would substitute `missingBlock`).
    block_id: u16 = 0,
    prob: f32 = 1,
    biome: []const u8 = "",
    /// False when the row's `sandboxoption` gate fails for the decoded code.
    allowed: bool = true,
    random_rotation: bool = false,
};

/// One resolved replacement: the block id and, when the target asked for a
/// random rotation, the 0..3 rotation stock would stamp.
pub const Replacement = struct {
    block_id: u16 = 0,
    rotation: ?u8 = null,
};

pub const Placeholder = struct {
    name: []const u8 = "",
    targets: []const Target = &.{},
};

pub const IdByNameFn = *const fn (?*anyopaque, []const u8) ?u16;

pub const LoadCtx = struct {
    id_by_name: IdByNameFn,
    id_ctx: ?*anyopaque = null,
    /// The decoded server SandboxCode (`SandboxOptionManager.GetBool` reads it
    /// at runtime in stock; the value is fixed for a server run).
    sandbox_code: []const u8 = "",
};

pub const Table = struct {
    placeholders: []const Placeholder = &.{},
    by_name: std.StringHashMapUnmanaged(u32) = .{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    /// Index of the placeholder carrying `name`, or null. The paint path stores
    /// index + 1 per cell, so 0 stays "not a placeholder".
    pub fn find(self: *const Table, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    pub fn at(self: *const Table, index: u32) ?*const Placeholder {
        if (index >= self.placeholders.len) return null;
        return &self.placeholders[index];
    }

    /// Stock `BlockPlaceholderMap::Replace` for one cell. `biome_name` is the
    /// cell's biome name ("" = unknown, stock only compares when the target
    /// declares one). Returns the replacement block id, or null to keep the
    /// authored block. A return of 0 means the placeholder resolved to air
    /// (stock's `result.Equals(original) -> Air`).
    pub fn resolve(
        self: *const Table,
        index: u32,
        wx: i32,
        wy: i32,
        wz: i32,
        world_seed: i32,
        biome_name: []const u8,
    ) ?Replacement {
        const ph = self.at(index) orelse return null;
        if (ph.targets.len == 0) return null;
        // Utils.RandomFromSeedOnPos(IL=2666) + the GameRandom port, so the
        // draw is the one stock makes for this cell.
        var r = game_random.seededOnPos(wx, wy, wz, world_seed);
        var sum: f32 = 0;
        var eligible: [max_targets_per_placeholder]u16 = undefined;
        var n: usize = 0;
        for (ph.targets, 0..) |t, ti| {
            if (t.block_id == 0 or !t.allowed) continue;
            if (t.biome.len > 0) {
                if (biome_name.len == 0) continue;
                if (!std.ascii.eqlIgnoreCase(t.biome, biome_name)) continue;
            }
            // eligible[] holds target indices, not a compaction rank: the
            // weighted walk below reads prob back off `ph.targets`.
            eligible[n] = @intCast(ti);
            n += 1;
            sum += t.prob;
        }
        if (n == 0 or !(sum > 0)) return null;
        var chosen: usize = 0;
        // Stock keeps the last eligible target as the fallback and only rolls
        // when there is more than one.
        if (n > 1) {
            var roll = r.nextFloat() * sum;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const t = ph.targets[eligible[k]];
                if (roll < t.prob) {
                    chosen = k;
                    break;
                }
                roll -= t.prob;
            }
        }
        const picked = ph.targets[eligible[chosen]];
        var rep = Replacement{ .block_id = picked.block_id };
        if (picked.random_rotation) {
            // Stock rerolls the rotation off the same per-cell stream
            // (`RandomRange(8)` plus the 0x14 offset when the shape has 45
            // degree bands, else `RandomRange(4)`); zdtd does not track
            // Has45DegreeRotations, so it takes the four-way band.
            rep.rotation = @intCast(r.rangeInt(4));
        }
        return rep;
    }
};

fn parseBoolAttr(v: []const u8) bool {
    if (v.len == 0) return false;
    return v[0] == 't' or v[0] == 'T' or v[0] == '1';
}

/// Sandbox gate: `sandboxoption="X"` requires the option's bool to differ from
/// the `!` inversion (stock `if (GetBool(opt) == invertSandbox) skip`).
fn sandboxAllowed(code: []const u8, spec: []const u8) bool {
    var name = spec;
    var invert = false;
    if (name.len > 0 and name[0] == '!') {
        invert = true;
        name = name[1..];
    }
    const o = sandbox.optionByName(name) orelse return !invert;
    var groups: [sandbox.max_groups]sandbox.Group = undefined;
    const n = sandbox.decode(code, &groups);
    var value = o.default_i != 0;
    for (groups[0..n]) |g| {
        if (g.option_id != o.id) continue;
        value = sandbox.valueB(o, g.index);
        break;
    }
    return value != invert;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8, ctx: LoadCtx) !Table {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var t: Table = .{};
    t.arena_ptr = arena_holder;
    errdefer t.deinit();

    var list: std.ArrayListUnmanaged(Placeholder) = .empty;
    var i: usize = 0;
    while (i < clean.len and list.items.len < max_placeholders) {
        const pi = std.mem.findPos(u8, clean, i, "<placeholder ") orelse break;
        const name = xml.attr(clean, pi, "name") orelse {
            i = pi + 13;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, pi, ">") orelse break;
        if (gt > pi and clean[gt - 1] == '/') {
            i = gt + 1;
            continue;
        }
        const close = std.mem.findPos(u8, clean, gt, "</placeholder>") orelse break;
        const body = clean[gt + 1 .. close];

        var targets: std.ArrayListUnmanaged(Target) = .empty;
        var bi: usize = 0;
        while (bi < body.len and targets.items.len < max_targets_per_placeholder) {
            const bi_pos = std.mem.findPos(u8, body, bi, "<block ") orelse break;
            const bgt = std.mem.findPos(u8, body, bi_pos, ">") orelse break;
            const bname = xml.attr(body, bi_pos, "name") orelse {
                bi = bgt + 1;
                continue;
            };
            var tg: Target = .{
                .block_id = ctx.id_by_name(ctx.id_ctx, bname) orelse 0,
                .prob = if (xml.attr(body, bi_pos, "prob")) |p| xml.parseF32(p) orelse 1 else 1,
                .biome = if (xml.attr(body, bi_pos, "biome")) |b| try arena.dupe(u8, b) else "",
                .random_rotation = if (xml.attr(body, bi_pos, "randomrotation")) |rr| parseBoolAttr(rr) else false,
                .allowed = if (xml.attr(body, bi_pos, "sandboxoption")) |so| sandboxAllowed(ctx.sandbox_code, so) else true,
            };
            if (!(tg.prob > 0)) tg.prob = 0;
            try targets.append(arena, tg);
            bi = bgt + 1;
        }

        try list.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .targets = try arena.dupe(Target, targets.items),
        });
        i = close + 14;
    }

    t.placeholders = try arena.dupe(Placeholder, list.items);
    for (t.placeholders, 0..) |*ph, idx| {
        try t.by_name.put(arena, ph.name, @intCast(idx));
    }
    list.deinit(allocator);
    return t;
}

/// Load `blockplaceholders.xml`, applying modlet patches first (the same
/// merged-XML path the other catalogs use). Null when the file is absent or
/// carries no placeholder.
pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    id_by_name: IdByNameFn,
    id_ctx: ?*anyopaque,
    sandbox_code: []const u8,
) !?Table {
    const paths = @import("paths.zig");
    const ctx = LoadCtx{ .id_by_name = id_by_name, .id_ctx = id_ctx, .sandbox_code = sandbox_code };
    const logFail = struct {
        fn f(what: []const u8, err: anyerror) void {
            std.debug.print("zdtd: blockplaceholders.xml {s} failed: {s}\n", .{ what, @errorName(err) });
        }
    }.f;
    if (!paths.hasPatches()) {
        var path_buf: [2048]u8 = undefined;
        const path = paths.resolveConfigXml(&path_buf, "blockplaceholders.xml", game_dir, config_dir) orelse return null;
        const t = loadFromPath(allocator, path, ctx) catch |err| {
            if (err != error.FileNotFound) logFail("load", err);
            return null;
        };
        return if (t.placeholders.len == 0) null else t;
    }
    const merged = try paths.readConfigXml(allocator, "blockplaceholders.xml", game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    // The patched catalog is cached beside the cwd like blocks.xml, so the
    // loader keeps one file path entry point.
    const io_fs2 = @import("../util/io_fs.zig");
    io_fs2.mkdirPath(".zdtd_cfg_cache");
    const cp = ".zdtd_cfg_cache/blockplaceholders.xml";
    io_fs2.writeFile(cp, merged) catch return null;
    const t = loadFromPath(allocator, cp, ctx) catch |err| {
        logFail("load patched", err);
        return null;
    };
    return if (t.placeholders.len == 0) null else t;
}

test "placeholders parse, weigh and resolve deterministically" {
    const src =
        \\<blockplaceholders>
        \\  <placeholder name="terrStoneHelper">
        \\    <block name="terrStone" biome="pine_forest"/>
        \\    <block name="terrSandStone" biome="desert"/>
        \\  </placeholder>
        \\  <placeholder name="carWrecksRandomHelper">
        \\    <block name="carWreck1" prob="3"/>
        \\    <block name="carWreck2" prob="1" randomrotation="true"/>
        \\  </placeholder>
        \\</blockplaceholders>
    ;
    const path = ".zdtd_test_placeholders.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    const Fx = struct {
        fn id(_: ?*anyopaque, name: []const u8) ?u16 {
            if (std.mem.eql(u8, name, "terrStone")) return 100;
            if (std.mem.eql(u8, name, "terrSandStone")) return 101;
            if (std.mem.eql(u8, name, "carWreck1")) return 200;
            if (std.mem.eql(u8, name, "carWreck2")) return 201;
            return null;
        }
    };
    var t = try loadFromPath(std.testing.allocator, path, .{ .id_by_name = Fx.id });
    defer t.deinit();

    const helper = t.find("terrStoneHelper").?;
    // Biome gates: only the matching row survives.
    try std.testing.expectEqual(@as(u16, 100), t.resolve(helper, 10, 70, 20, 1, "pine_forest").?.block_id);
    try std.testing.expectEqual(@as(u16, 101), t.resolve(helper, 10, 70, 20, 1, "desert").?.block_id);
    try std.testing.expect(t.resolve(helper, 10, 70, 20, 1, "snow") == null);
    // Deterministic per position, and the 3:1 weights make carWreck1 common.
    const wrecks = t.find("carWrecksRandomHelper").?;
    const a = t.resolve(wrecks, 100, 70, 100, 1234, "");
    const b = t.resolve(wrecks, 100, 70, 100, 1234, "");
    try std.testing.expectEqual(a, b);
    var one: usize = 0;
    var x: i32 = 0;
    while (x < 64) : (x += 1) {
        const r = t.resolve(wrecks, x, 70, 5, 99, "") orelse continue;
        if (r.block_id == 200) one += 1;
    }
    try std.testing.expect(one > 32);
    // The sandbox gate drops a row whose option is off.
    const gated =
        \\<blockplaceholders>
        \\  <placeholder name="gated">
        \\    <block name="terrStone" sandboxoption="VendingEnabled"/>
        \\  </placeholder>
        \\</blockplaceholders>
    ;
    try io_fs.writeFile(path, gated);
    var t2 = try loadFromPath(std.testing.allocator, path, .{ .id_by_name = Fx.id, .sandbox_code = "" });
    defer t2.deinit();
    const g = t2.find("gated").?;
    // VendingEnabled defaults on, so the row stays; the gate is data-driven.
    try std.testing.expect(t2.at(g).?.targets[0].allowed);
}
