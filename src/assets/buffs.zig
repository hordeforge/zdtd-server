//! buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const components = @import("../ecs/components.zig");

pub const max_buffs: usize = 2048;
pub const max_passives_per_buff: usize = 16;
pub const max_passives_total: usize = 8192;
/// BuffClass::.ctor UpdateRateTicks default (asm.il 732691); update_rate is in
/// seconds and the client multiplies by 20 (asm.il 1371556).
pub const default_update_rate_ticks: i32 = 20;

pub const Op = enum(u8) { base_set = 0, base_add = 1, perc_set = 2, perc_add = 3, unknown = 255 };

/// BuffEffectStackTypes (asm.il 738358), consumed by the stack switch in
/// EntityBuffs::AddBuff (asm.il 736259 IL_00e7). Lives with the component so
/// the rules in ecs/buff.zig need no dependency on the asset loader.
pub const StackType = components.StackType;

pub const Passive = struct {
    name: []const u8 = "",
    op: Op = .unknown,
    value: f32 = 0,
    tags: []const u8 = "",
};

pub const BuffDef = struct {
    name: []const u8 = "",
    /// BuffClass::InitialDurationMax in seconds; <= 0 never expires (asm.il 732754).
    duration: f32 = 0,
    stack_type: StackType = .ignore,
    update_rate_ticks: i32 = default_update_rate_ticks,
    /// BuffClass::RemoveOnDeath (asm.il 1371585), default true per .ctor.
    remove_on_death: bool = true,
    passives: []const Passive = &.{},
};

/// Fallback catalog when buffs.xml is absent (headless tests, no game dir).
/// Verbatim subset of the stock file: name, stack_type, duration, update_rate,
/// remove_on_death only. Never invent buff names here, the client resolves them
/// against its own buffs.xml and drops anything it does not know.
pub const builtin_defs = [_]BuffDef{
    .{ .name = "buffInjuryBleeding", .duration = 0, .stack_type = .replace },
    .{ .name = "buffShocked", .duration = 4, .stack_type = .duration, .update_rate_ticks = 20 },
    .{ .name = "buffIsOnFire", .duration = 0, .stack_type = .ignore, .update_rate_ticks = 10 },
    .{ .name = "buffHarvest", .duration = 0, .stack_type = .effect, .remove_on_death = false },
    .{ .name = "buffStatusCheck01", .duration = 0, .stack_type = .ignore, .update_rate_ticks = 40, .remove_on_death = false },
};

pub fn builtin() Table {
    return .{ .defs = builtin_defs[0..] };
}

pub const Table = struct {
    defs: []const BuffDef = &.{},
    passive_pool: []const Passive = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            self.defs = &.{};
            self.passive_pool = &.{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    /// Catalog index for a wire buff name. BuffManager::Buffs is a
    /// CaseInsensitiveStringDictionary (asm.il 733560), so lookup ignores case.
    pub fn indexOfName(self: *const Table, name: []const u8) ?u16 {
        for (self.defs, 0..) |d, i| {
            if (std.ascii.eqlIgnoreCase(d.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn byId(self: *const Table, id: u16) ?BuffDef {
        if (id >= self.defs.len) return null;
        return self.defs[id];
    }

    pub fn byName(self: *const Table, name: []const u8) ?BuffDef {
        const i = self.indexOfName(name) orelse return null;
        return self.defs[i];
    }

    /// Aggregate passive effect value for a buff (base_set overwrites, base_add sums).
    pub fn passiveValue(self: *const Table, buff_name: []const u8, effect: []const u8) ?f32 {
        const b = self.byName(buff_name) orelse return null;
        var acc: ?f32 = null;
        for (b.passives) |p| {
            if (!std.mem.eql(u8, p.name, effect)) continue;
            switch (p.op) {
                .base_set, .perc_set => acc = p.value,
                .base_add, .perc_add => acc = (acc orelse 0) + p.value,
                .unknown => {},
            }
        }
        return acc;
    }
};

fn parseOp(s: []const u8) Op {
    if (std.mem.eql(u8, s, "base_set")) return .base_set;
    if (std.mem.eql(u8, s, "base_add")) return .base_add;
    if (std.mem.eql(u8, s, "perc_set")) return .perc_set;
    if (std.mem.eql(u8, s, "perc_add")) return .perc_add;
    return .unknown;
}

/// EnumUtils::Parse<BuffEffectStackTypes> with ignoreCase:true (asm.il 1371510).
/// An absent or unparsable value leaves the BuffClass::.ctor default (Ignore).
fn parseStackType(s: []const u8) StackType {
    if (std.ascii.eqlIgnoreCase(s, "duration")) return .duration;
    if (std.ascii.eqlIgnoreCase(s, "effect")) return .effect;
    if (std.ascii.eqlIgnoreCase(s, "replace")) return .replace;
    return .ignore;
}

/// update_rate seconds → UpdateRateTicks (asm.il 1371556: ParseFloat * 20, conv.i4).
fn parseUpdateRateTicks(s: []const u8) i32 {
    if (s.len == 0) return default_update_rate_ticks;
    const secs = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch return default_update_rate_ticks;
    const ticks = secs * 20.0;
    if (!(ticks > 0)) return 0; // conv.i4 of a non-positive rate fires Update every tick
    if (ticks >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(ticks);
}

fn parseBoolAttr(s: []const u8, default: bool) bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return default;
}

fn firstF32(s: []const u8) f32 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " \t")) catch 0;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var ranges: std.ArrayList(struct { usize, usize }) = .empty; // passive start,len per def
    defer ranges.deinit(allocator);
    var passives_list: std.ArrayList(Passive) = .empty;
    defer passives_list.deinit(allocator);
    var metas: std.ArrayList(BuffDef) = .empty; // every field but passives
    defer metas.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and metas.items.len < max_buffs) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<buff ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 6;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > bi and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</buff>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        var meta: BuffDef = .{ .name = try arena.dupe(u8, name) };
        if (xml.attr(clean, bi, "duration")) |d| {
            meta.duration = std.fmt.parseFloat(f32, d) catch 0;
        } else if (std.mem.indexOf(u8, body, "<duration")) |di| {
            if (xml.attr(body, di, "value")) |v| meta.duration = std.fmt.parseFloat(f32, v) catch 0;
        }
        if (std.mem.indexOf(u8, body, "<stack_type")) |si| {
            if (xml.attr(body, si, "value")) |v| meta.stack_type = parseStackType(v);
        }
        if (std.mem.indexOf(u8, body, "<update_rate")) |ui| {
            if (xml.attr(body, ui, "value")) |v| meta.update_rate_ticks = parseUpdateRateTicks(v);
        }
        if (xml.attr(clean, bi, "remove_on_death")) |v| meta.remove_on_death = parseBoolAttr(v, true);
        const p0 = passives_list.items.len;
        var j: usize = 0;
        var pn: usize = 0;
        while (j < body.len and pn < max_passives_per_buff and passives_list.items.len < max_passives_total) {
            const pi = std.mem.indexOfPos(u8, body, j, "<passive_effect ") orelse break;
            const en = xml.attr(body, pi, "name") orelse {
                j = pi + 16;
                continue;
            };
            const op_s = xml.attr(body, pi, "operation") orelse "base_add";
            const val_s = xml.attr(body, pi, "value") orelse "0";
            const tags = xml.attr(body, pi, "tags") orelse "";
            try passives_list.append(allocator, .{
                .name = try arena.dupe(u8, en),
                .op = parseOp(op_s),
                .value = firstF32(val_s),
                .tags = try arena.dupe(u8, tags),
            });
            pn += 1;
            j = pi + 16;
        }
        try metas.append(allocator, meta);
        try ranges.append(allocator, .{ p0, passives_list.items.len - p0 });
        i = body_end + 1;
    }

    const pool = try arena.alloc(Passive, passives_list.items.len);
    @memcpy(pool, passives_list.items);
    const defs = try arena.alloc(BuffDef, metas.items.len);
    for (metas.items, ranges.items, 0..) |meta, rg, di| {
        defs[di] = meta;
        defs[di].passives = pool[rg[0] .. rg[0] + rg[1]];
    }
    return .{ .defs = defs, .passive_pool = pool, .arena_ptr = arena_holder };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("buffs.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "stack_type parse is case-insensitive and falls back to ignore" {
    try std.testing.expectEqual(StackType.duration, parseStackType("Duration"));
    try std.testing.expectEqual(StackType.effect, parseStackType("EFFECT"));
    try std.testing.expectEqual(StackType.replace, parseStackType("replace"));
    // Absent or garbage keeps BuffClass::.ctor's Ignore default (asm.il 732691).
    try std.testing.expectEqual(StackType.ignore, parseStackType(""));
    try std.testing.expectEqual(StackType.ignore, parseStackType("stacked"));
}

test "update_rate seconds convert to stock UpdateRateTicks" {
    try std.testing.expectEqual(@as(i32, 20), parseUpdateRateTicks("1"));
    try std.testing.expectEqual(@as(i32, 10), parseUpdateRateTicks(".5"));
    try std.testing.expectEqual(@as(i32, 44), parseUpdateRateTicks("2.217")); // truncating conv.i4
    // Absent / unparsable keeps the 20-tick default.
    try std.testing.expectEqual(default_update_rate_ticks, parseUpdateRateTicks(""));
    try std.testing.expectEqual(default_update_rate_ticks, parseUpdateRateTicks("fast"));
    // Zero and negative rates cannot count down; stock stores them as-is (fires every tick).
    try std.testing.expectEqual(@as(i32, 0), parseUpdateRateTicks("0"));
    try std.testing.expectEqual(@as(i32, 0), parseUpdateRateTicks("-3"));
}

test "builtin catalog resolves by name case-insensitively" {
    var t = builtin();
    defer t.deinit();
    const id = t.indexOfName("BUFFSHOCKED").?;
    const d = t.byId(id).?;
    try std.testing.expectEqualStrings("buffShocked", d.name);
    try std.testing.expectEqual(StackType.duration, d.stack_type);
    try std.testing.expectEqual(@as(f32, 4), d.duration);
    try std.testing.expect(d.remove_on_death);
    try std.testing.expect(t.indexOfName("buffNotInCatalog") == null);
    try std.testing.expect(t.byId(@intCast(builtin_defs.len)) == null);
    // buffHarvest survives death (stock hidden console buff).
    try std.testing.expect(!t.byName("buffHarvest").?.remove_on_death);
}

test "parsed buff fields: stack, duration, update rate, remove_on_death" {
    const xml_src =
        \\<buffs>
        \\<buff name="buffShocked">
        \\<stack_type value="duration"/>
        \\<duration value="4"/>
        \\<update_rate value="1"/>
        \\</buff>
        \\<buff name="buffHarvest" hidden="true" remove_on_death="false">
        \\<stack_type value="effect"/>
        \\<duration value="0"/>
        \\<passive_effect name="HarvestCount" operation="perc_add" value="0.5"/>
        \\</buff>
        \\<buff name="buffNoStack"/>
        \\</buffs>
    ;
    const path = "worlds/zdtd_buffs_parse.xml";
    io_fs.mkdirPathSimple("worlds");
    try io_fs.writeFileSimple(path, xml_src);
    defer io_fs.deleteFileSimple(path);

    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.defs.len);

    const shocked = t.byName("buffShocked").?;
    try std.testing.expectEqual(StackType.duration, shocked.stack_type);
    try std.testing.expectEqual(@as(f32, 4), shocked.duration);
    try std.testing.expectEqual(@as(i32, 20), shocked.update_rate_ticks);
    try std.testing.expect(shocked.remove_on_death);

    const harvest = t.byName("buffHarvest").?;
    try std.testing.expectEqual(StackType.effect, harvest.stack_type);
    try std.testing.expect(!harvest.remove_on_death);
    try std.testing.expectEqual(@as(usize, 1), harvest.passives.len);
    try std.testing.expectEqual(@as(f32, 0.5), t.passiveValue("buffHarvest", "HarvestCount").?);

    // No stack_type element at all: Ignore, not Replace (73 stock buffs rely on this).
    const nostack = t.byName("buffNoStack").?;
    try std.testing.expectEqual(StackType.ignore, nostack.stack_type);
    try std.testing.expectEqual(default_update_rate_ticks, nostack.update_rate_ticks);
}

test "load buffs.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/buffs.xml";
    var t = loadFromPath(std.testing.allocator, p) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.defs.len > 10);
    try std.testing.expect(t.passive_pool.len > 0);
}
