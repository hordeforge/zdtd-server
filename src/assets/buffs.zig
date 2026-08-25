//! buffs.xml: metadata + passive_effect rows. Full triggered_effect VM is later.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const components = @import("../ecs/components.zig");

pub const max_buffs: usize = 2048;
pub const max_passives_per_buff: usize = 16;
pub const max_passives_total: usize = 8192;
pub const max_stat_mods_per_buff: usize = 8;
pub const max_stat_mods_total: usize = 2048;
pub const max_thresholds_per_buff: usize = 16;
pub const max_thresholds_total: usize = 512;
/// BuffClass::.ctor UpdateRateTicks default (asm.il 732691); update_rate is in
/// seconds and the client multiplies by 20 (asm.il 1371556).
pub const default_update_rate_ticks: i32 = 20;

/// passive_effect / triggered_effect `operation=`. The base_* and perc_* forms
/// come from passive_effect rows; the bare set/add/subtract/multiply forms come
/// from `action="ModifyStats"` and `ModifyCVar` triggered effects.
pub const Op = enum(u8) {
    base_set = 0,
    base_add = 1,
    perc_set = 2,
    perc_add = 3,
    base_subtract = 4,
    perc_subtract = 5,
    set = 6,
    add = 7,
    subtract = 8,
    multiply = 9,
    unknown = 255,
};

/// BuffEffectStackTypes (asm.il 738358), consumed by the stack switch in
/// EntityBuffs::AddBuff (asm.il 736259 IL_00e7). Lives with the component so
/// the rules in ecs/buff.zig need no dependency on the asset loader.
pub const StackType = components.StackType;

pub const max_curve_len: usize = 8;

pub const Passive = struct {
    name: []const u8 = "",
    op: Op = .unknown,
    /// First segment of a comma-separated curve value (level-1 value for
    /// perks; the flat value for single-segment rows). Kept for the legacy
    /// readers; `curveAt` is the level-aware accessor.
    value: f32 = 0,
    tags: []const u8 = "",
    /// Per-level curve segments (stock `value="v1,v2,..."`: segment i applies
    /// at level i+1, clamped past the end). Filled for every parsed row.
    curve: [max_curve_len]f32 = .{0} ** max_curve_len,
    curve_len: u8 = 0,
};

/// One `<triggered_effect action="ModifyStats" .../>` row. Stock drives
/// starvation and dehydration damage this way rather than through a passive
/// effect, so the survival loop has to read these to get the real rate.
pub const StatMod = struct {
    /// `stat=` verbatim from the file, which is inconsistently cased in stock
    /// ("Food", "water"), so compare case-insensitively.
    stat: []const u8 = "",
    op: Op = .unknown,
    value: f32 = 0,
};

/// One `<requirement name="StatComparePercCurrentToMax" .../>` gate. Stock
/// compares a **fraction of max**, not an absolute 0..100 value.
pub const StatThreshold = struct {
    /// The buff this requirement gates (the AddBuff target).
    buff: []const u8 = "",
    stat: []const u8 = "",
    /// Fraction of max, 0..1.
    value: f32 = 0,
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
    stat_mods: []const StatMod = &.{},
    thresholds: []const StatThreshold = &.{},
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
    /// Lowercased name -> defs index, built once at load (XML tables only;
    /// small builtin/empty tables fall back to the linear scan below).
    name_index: std.StringHashMapUnmanaged(u16) = .{},

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
        if (self.name_index.count() != 0 and name.len <= 63) {
            var buf: [63]u8 = undefined;
            const lower = std.ascii.lowerString(buf[0..name.len], name);
            return self.name_index.get(lower);
        }
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
                .base_set, .perc_set, .set => acc = p.value,
                .base_add, .perc_add, .add => acc = (acc orelse 0) + p.value,
                .base_subtract, .perc_subtract, .subtract => acc = (acc orelse 0) - p.value,
                .multiply => acc = (acc orelse 1) * p.value,
                .unknown => {},
            }
        }
        return acc;
    }
};

pub fn parseOp(s: []const u8) Op {
    if (std.mem.eql(u8, s, "base_set")) return .base_set;
    if (std.mem.eql(u8, s, "base_add")) return .base_add;
    if (std.mem.eql(u8, s, "perc_set")) return .perc_set;
    if (std.mem.eql(u8, s, "perc_add")) return .perc_add;
    if (std.mem.eql(u8, s, "base_subtract")) return .base_subtract;
    if (std.mem.eql(u8, s, "perc_subtract")) return .perc_subtract;
    if (std.mem.eql(u8, s, "set")) return .set;
    if (std.mem.eql(u8, s, "add")) return .add;
    if (std.mem.eql(u8, s, "subtract")) return .subtract;
    if (std.mem.eql(u8, s, "multiply")) return .multiply;
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
    return @trunc(ticks);
}

fn parseBoolAttr(s: []const u8, default: bool) bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return default;
}

pub fn firstF32(s: []const u8) f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse s.len;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s[0..comma], " \t")) catch 0;
}

/// Fill `out` with the comma-separated curve segments of a passive `value`
/// (stock: segment i applies at level i+1). Returns the segment count (0 for
/// an empty value). `out[0]` is always the flat/level-1 value.
pub fn parseCurveValue(s: []const u8, out: *[max_curve_len]f32) u8 {
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |seg| {
        const seg_t = std.mem.trim(u8, seg, " \t");
        if (seg_t.len == 0) continue;
        if (n >= max_curve_len) break;
        out[n] = std.fmt.parseFloat(f32, seg_t) catch 0;
        n += 1;
    }
    return n;
}

/// Stock curve evaluation (RE PassiveEffect::ModValue, IL=796): the curve
/// Levels are scaled so value[0] sits at level 1 and value[n-1] at
/// `max_level`, and the effect interpolates linearly between neighbours
/// (Mathf.Lerp on the level fraction); a level outside every segment applies
/// nothing (0). The item effect level is the raw ItemValue.Quality
/// (EffectManager.GetValue IL_0393), so 6-value armor curves are per-quality
/// values and 2-value curves interpolate Q1..Q6 (e.g. 8..12.3).
pub fn curveValueAt(level: u8, max_level: u8, curve: []const f32) f32 {
    if (curve.len == 0 or level == 0 or max_level < 2) return 0;
    if (curve.len == 1) return curve[0];
    const l: f32 = @floatFromInt(level);
    const hi: f32 = @floatFromInt(max_level);
    const n = curve.len;
    for (1..n) |i| {
        const l0: f32 = 1.0 + (hi - 1.0) * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(n - 1));
        const l1: f32 = 1.0 + (hi - 1.0) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
        if (l >= l0 and l <= l1) {
            const t: f32 = if (l1 > l0) (l - l0) / (l1 - l0) else 0;
            return curve[i - 1] + (curve[i] - curve[i - 1]) * t;
        }
    }
    return 0;
}

/// Value of a passive at `level` (1-based): curve segment `level-1`, clamped
/// past the end; level 0 (unpurchased) is 0; single-segment rows repeat.
/// Hand-built rows that set only `value` (curve_len 0) repeat that value.
pub fn curveAt(p: Passive, level: u8) f32 {
    if (level == 0) return 0;
    if (p.curve_len == 0) return p.value;
    return p.curve[@min(@as(usize, level - 1), @as(usize, p.curve_len) - 1)];
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
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
    var mods_list: std.ArrayList(StatMod) = .empty;
    defer mods_list.deinit(allocator);
    var mod_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer mod_ranges.deinit(allocator);
    var thresholds_list: std.ArrayList(StatThreshold) = .empty;
    defer thresholds_list.deinit(allocator);
    var thr_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    defer thr_ranges.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and metas.items.len < max_buffs) {
        const bi = std.mem.findPos(u8, clean, i, "<buff ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 6;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, bi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > bi and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</buff>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        var meta: BuffDef = .{ .name = try arena.dupe(u8, name) };
        if (xml.attr(clean, bi, "duration")) |d| {
            meta.duration = std.fmt.parseFloat(f32, d) catch 0;
        } else if (std.mem.find(u8, body, "<duration")) |di| {
            if (xml.attr(body, di, "value")) |v| meta.duration = std.fmt.parseFloat(f32, v) catch 0;
        }
        if (std.mem.find(u8, body, "<stack_type")) |si| {
            if (xml.attr(body, si, "value")) |v| meta.stack_type = parseStackType(v);
        }
        if (std.mem.find(u8, body, "<update_rate")) |ui| {
            if (xml.attr(body, ui, "value")) |v| meta.update_rate_ticks = parseUpdateRateTicks(v);
        }
        if (xml.attr(clean, bi, "remove_on_death")) |v| meta.remove_on_death = parseBoolAttr(v, true);
        const m0 = mods_list.items.len;
        var mj: usize = 0;
        var mn: usize = 0;
        while (mj < body.len and mn < max_stat_mods_per_buff and mods_list.items.len < max_stat_mods_total) {
            const ti = std.mem.findPos(u8, body, mj, "action=\"ModifyStats\"") orelse break;
            mj = ti + 20;
            // Attributes sit on the same tag, so scan from the tag open.
            const tag = std.mem.findScalarLast(u8, body[0..ti], '<') orelse continue;
            const st = xml.attr(body, tag, "stat") orelse continue;
            const op_s = xml.attr(body, tag, "operation") orelse "add";
            const val_s = xml.attr(body, tag, "value") orelse "0";
            try mods_list.append(allocator, .{
                .stat = try arena.dupe(u8, st),
                .op = parseOp(op_s),
                .value = firstF32(val_s),
            });
            mn += 1;
        }

        const t0 = thresholds_list.items.len;
        var tj: usize = 0;
        var tn: usize = 0;
        while (tj < body.len and tn < max_thresholds_per_buff and thresholds_list.items.len < max_thresholds_total) {
            const ri = std.mem.findPos(u8, body, tj, "StatComparePercCurrentToMax") orelse break;
            tj = ri + 27;
            const tag = std.mem.findScalarLast(u8, body[0..ri], '<') orelse continue;
            const st = xml.attr(body, tag, "stat") orelse continue;
            const val_s = xml.attr(body, tag, "value") orelse continue;
            // The gated buff is the AddBuff on the enclosing triggered_effect,
            // which opens before this requirement.
            const te = std.mem.findLast(u8, body[0..ri], "<triggered_effect") orelse continue;
            const gated = xml.attr(body, te, "buff") orelse "";
            try thresholds_list.append(allocator, .{
                .buff = try arena.dupe(u8, gated),
                .stat = try arena.dupe(u8, st),
                .value = firstF32(val_s),
            });
            tn += 1;
        }

        const p0 = passives_list.items.len;
        var j: usize = 0;
        var pn: usize = 0;
        while (j < body.len and pn < max_passives_per_buff and passives_list.items.len < max_passives_total) {
            const pi = std.mem.findPos(u8, body, j, "<passive_effect ") orelse break;
            const en = xml.attr(body, pi, "name") orelse {
                j = pi + 16;
                continue;
            };
            const op_s = xml.attr(body, pi, "operation") orelse "base_add";
            const val_s = xml.attr(body, pi, "value") orelse "0";
            const tags = xml.attr(body, pi, "tags") orelse "";
            var curve: [max_curve_len]f32 = .{0} ** max_curve_len;
            const curve_len = parseCurveValue(val_s, &curve);
            try passives_list.append(allocator, .{
                .name = try arena.dupe(u8, en),
                .op = parseOp(op_s),
                .value = curve[0],
                .tags = try arena.dupe(u8, tags),
                .curve = curve,
                .curve_len = curve_len,
            });
            pn += 1;
            j = pi + 16;
        }
        try metas.append(allocator, meta);
        try ranges.append(allocator, .{ p0, passives_list.items.len - p0 });
        try mod_ranges.append(allocator, .{ m0, mods_list.items.len - m0 });
        try thr_ranges.append(allocator, .{ t0, thresholds_list.items.len - t0 });
        i = body_end + 1;
    }

    const pool = try arena.alloc(Passive, passives_list.items.len);
    @memcpy(pool, passives_list.items);
    const mod_pool = try arena.alloc(StatMod, mods_list.items.len);
    @memcpy(mod_pool, mods_list.items);
    const thr_pool = try arena.alloc(StatThreshold, thresholds_list.items.len);
    @memcpy(thr_pool, thresholds_list.items);
    const defs = try arena.alloc(BuffDef, metas.items.len);
    for (metas.items, ranges.items, 0..) |meta, rg, di| {
        defs[di] = meta;
        defs[di].passives = pool[rg[0] .. rg[0] + rg[1]];
        const mr = mod_ranges.items[di];
        defs[di].stat_mods = mod_pool[mr[0] .. mr[0] + mr[1]];
        const tr = thr_ranges.items[di];
        defs[di].thresholds = thr_pool[tr[0] .. tr[0] + tr[1]];
    }
    var name_index: std.StringHashMapUnmanaged(u16) = .{};
    try name_index.ensureTotalCapacity(arena, @intCast(defs.len));
    for (defs, 0..) |d, di| {
        const lower = try arena.alloc(u8, d.name.len);
        _ = std.ascii.lowerString(lower, d.name);
        const gop = name_index.getOrPutAssumeCapacity(lower);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(di);
    }

    return .{ .defs = defs, .passive_pool = pool, .arena_ptr = arena_holder, .name_index = name_index };
}

/// Survival numbers stock ships as data, resolved out of the loaded table so
/// the sim does not have to know buff names or walk effect rows every tick.
///
/// What is here is what buffs.xml actually carries. The **base** food and water
/// depletion is deliberately absent: stock decays those engine-side through
/// `Stat.Tick` (activity scaled), and no XML row states the rate, so that one
/// stays a documented policy tunable in `Rules.progression` rather than being
/// invented here and presented as stock (AGENTS: prefer missing over fake).
pub const Survival = struct {
    /// Fraction of max Food at or below which each hunger stage applies
    /// (stock buffStatusCheck01: .5, .25, .02). 0 = not found.
    hungry_frac: [3]f32 = .{ 0, 0, 0 },
    /// Same for Water (buffStatusThirsty01/02/03).
    thirsty_frac: [3]f32 = .{ 0, 0, 0 },
    /// HP lost per **real** second at the final hunger stage. Stock applies
    /// `ModifyStats Health subtract .25` once per buff update, so this is that
    /// value divided by the buff's update rate.
    starve_hp_per_s: f32 = 0,
    /// Same for the final thirst stage (Dehydration).
    dehydrate_hp_per_s: f32 = 0,
    /// Fraction of max stamina subtracted while starving
    /// (buffStatusHungry03 `StaminaChangeOT perc_subtract`).
    starve_stamina_perc: f32 = 0,

    /// True when the table carried enough to drive the sim. False keeps the
    /// caller on its Rules floor rather than on a half-resolved mix.
    pub fn ok(self: Survival) bool {
        return self.hungry_frac[0] > 0 and self.thirsty_frac[0] > 0 and self.starve_hp_per_s > 0;
    }
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Health lost per real second by `buff_name`'s ModifyStats Health row.
fn healthLossPerSecond(t: *const Table, buff_name: []const u8) f32 {
    const d = t.byName(buff_name) orelse return 0;
    const rate_ticks: f32 = @floatFromInt(@max(1, d.update_rate_ticks));
    const secs = rate_ticks / 20.0; // update_rate is stored in 20 TPS ticks
    for (d.stat_mods) |m| {
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .base_subtract and m.op != .subtract) continue;
        if (m.value <= 0 or secs <= 0) continue;
        return m.value / secs;
    }
    return 0;
}

/// Resolve the survival numbers stock ships. Missing rows stay 0 so the caller
/// can tell "not in this file" from "stock says zero".
pub fn survival(t: *const Table) Survival {
    var out: Survival = .{};
    const check = t.byName("buffStatusCheck01");
    if (check) |c| {
        for (c.thresholds) |th| {
            const stage: usize = if (std.mem.endsWith(u8, th.buff, "01"))
                0
            else if (std.mem.endsWith(u8, th.buff, "02"))
                1
            else if (std.mem.endsWith(u8, th.buff, "03"))
                2
            else
                continue;
            if (eqIgnoreCase(th.stat, "Food") and std.mem.find(u8, th.buff, "Hungry") != null) {
                out.hungry_frac[stage] = th.value;
            } else if (eqIgnoreCase(th.stat, "Water") and std.mem.find(u8, th.buff, "Thirsty") != null) {
                out.thirsty_frac[stage] = th.value;
            }
        }
    }
    out.starve_hp_per_s = healthLossPerSecond(t, "buffStatusHungry03");
    out.dehydrate_hp_per_s = healthLossPerSecond(t, "buffStatusThirsty03");
    if (t.byName("buffStatusHungry03")) |h3| {
        for (h3.passives) |ps| {
            if (std.mem.eql(u8, ps.name, "StaminaChangeOT") and ps.op == .perc_subtract) {
                out.starve_stamina_perc = ps.value;
                break;
            }
        }
    }
    return out;
}

/// --- Revertible passive-effects VM (bounded EffectManager surface) ---
///
/// Stock evaluates every active buff's passive_effect rows against the entity
/// on each buff update (EffectManager.GetValue); this VM folds the rows of a
/// tracked surface into one additive delta set per buff and sums the active
/// set. Removing a buff reverses its contribution exactly - the total is a
/// pure recomputation over the active set (the paper's revertible-effects
/// discipline, no stale inverse records). The pass is bounded:
/// `max_buffs_per_entity` active slots, no allocation, no table writes.
/// The tracked surface is the stats the sim owns: health/food/water/stamina
/// (values and change-over-time) and the damage-resist percents. Rows outside
/// it are counted but not simulated (recorded, not guessed).
pub const TrackedDeltas = struct {
    hp_max: f32 = 0,
    hp_ot: f32 = 0,
    food_max: f32 = 0,
    food_ot: f32 = 0,
    water_max: f32 = 0,
    water_ot: f32 = 0,
    stamina_max: f32 = 0,
    stamina_ot: f32 = 0,
    /// PhysicalDamageResist percent (stock passive 41, GetTotalPhysicalArmorRating).
    phys_resist: f32 = 0,
    general_resist: f32 = 0,
    elem_resist: f32 = 0,

    pub fn any(self: TrackedDeltas) bool {
        return self.hp_max != 0 or self.hp_ot != 0 or self.food_max != 0 or
            self.food_ot != 0 or self.water_max != 0 or self.water_ot != 0 or
            self.stamina_max != 0 or self.stamina_ot != 0 or
            self.phys_resist != 0 or self.general_resist != 0 or self.elem_resist != 0;
    }
};

const TrackedField = enum(u8) {
    hp_max,
    hp_ot,
    food_max,
    food_ot,
    water_max,
    water_ot,
    stamina_max,
    stamina_ot,
    phys_resist,
    general_resist,
    elem_resist,
};

const tracked_names = [_]struct { name: []const u8, field: TrackedField }{
    .{ .name = "HealthChangeOT", .field = .hp_ot },
    .{ .name = "FoodChangeOT", .field = .food_ot },
    .{ .name = "WaterChangeOT", .field = .water_ot },
    .{ .name = "StaminaChangeOT", .field = .stamina_ot },
    .{ .name = "HealthMax", .field = .hp_max },
    .{ .name = "FoodMax", .field = .food_max },
    .{ .name = "WaterMax", .field = .water_max },
    .{ .name = "StaminaMax", .field = .stamina_max },
    .{ .name = "PhysicalDamageResist", .field = .phys_resist },
    .{ .name = "GeneralDamageResist", .field = .general_resist },
    .{ .name = "ElementalDamageResist", .field = .elem_resist },
};

fn addTo(out: *TrackedDeltas, field: TrackedField, v: f32) void {
    switch (field) {
        inline else => |f| @field(out, @tagName(f)) += v,
    }
}

fn addDeltas(a: *TrackedDeltas, b: TrackedDeltas) void {
    inline for (@typeInfo(TrackedDeltas).@"struct".fields) |f| {
        @field(a, f.name) += @field(b, f.name);
    }
}

/// Fold a passive_effect list over the tracked surface.
/// `base_add`/`base_subtract` are flat deltas; `perc_*` keep the raw XML
/// fraction (the survival loop applies `fraction x base / 100` per second -
/// the pre-VM arithmetic, unchanged). `base_set` and any other op over a
/// tracked name are omitted: without the per-entity base value the delta is
/// not defined (recorded, not guessed).
pub fn trackedDeltasAt(passives: []const Passive, level: u8) TrackedDeltas {
    var out: TrackedDeltas = .{};
    for (passives) |p| {
        const field = blk: {
            for (tracked_names) |t| {
                if (std.mem.eql(u8, t.name, p.name)) break :blk t.field;
            }
            break :blk null;
        } orelse continue;
        const v = curveAt(p, level);
        switch (p.op) {
            .base_add => addTo(&out, field, v),
            .base_subtract => addTo(&out, field, -v),
            .perc_add => addTo(&out, field, v),
            .perc_subtract => addTo(&out, field, -v),
            else => continue,
        }
    }
    return out;
}

/// The level-1 (flat) variant, used by the buff VM.
pub fn trackedDeltasFrom(passives: []const Passive) TrackedDeltas {
    return trackedDeltasAt(passives, 1);
}

/// Fold one buff's passive_effect rows over the tracked surface (the buff
/// variant of trackedDeltasFrom).
pub fn trackedDeltas(def: *const BuffDef) TrackedDeltas {
    return trackedDeltasFrom(def.passives);
}

/// Sum two delta sets (perk leg + buff leg, level-scaled).
pub fn deltasPlus(a: TrackedDeltas, b: TrackedDeltas) TrackedDeltas {
    var out = a;
    addDeltas(&out, b);
    return out;
}

/// Sum of the tracked deltas over an entity's active buffs (revertible by
/// recomputation: removing a buff drops its contribution exactly).
pub fn effectTotals(t: *const Table, set: *const components.BuffSet) TrackedDeltas {
    var out: TrackedDeltas = .{};
    for (&set.slots) |*slot| {
        if (!slot.active) continue;
        if (t.byId(slot.def_id)) |def| {
            addDeltas(&out, trackedDeltas(&def));
        }
    }
    return out;
}

/// Active survival-stage state: which buffStatusHungry/Thirsty stage is in
/// effect, from buffStatusCheck01's StatComparePercCurrentToMax thresholds
/// (fractions of max). 0 = none; 1/2/3 = the buffStatus*0{1,2,3} stage.
pub const SurvivalStages = struct {
    hungry: u8 = 0,
    thirsty: u8 = 0,
};

fn stageFor(frac: f32, s0: f32, s1: f32, s2: f32) u8 {
    if (s2 > 0 and frac <= s2) return 3;
    if (s1 > 0 and frac <= s1) return 2;
    if (s0 > 0 and frac <= s0) return 1;
    return 0;
}

/// Stock drives starvation/dehydration from conditional buffs, not a fixed
/// rule: buffStatusCheck01 applies the matching stage buff on its 2 s update.
/// Stage 3 (<= 2% of max) is the damaging stage the survival loop reacts to.
pub fn survivalStages(sv: Survival, h: *const components.Health) SurvivalStages {
    const f = if (h.food_max > 0) h.food / h.food_max else 0;
    const w = if (h.water_max > 0) h.water / h.water_max else 0;
    return .{
        .hungry = stageFor(f, sv.hungry_frac[0], sv.hungry_frac[1], sv.hungry_frac[2]),
        .thirsty = stageFor(w, sv.thirsty_frac[0], sv.thirsty_frac[1], sv.thirsty_frac[2]),
    };
}

/// Name of the conditional survival buff for a stage, or null for stage 0.
pub fn stageBuffName(stage: u8, thirsty: bool) ?[]const u8 {
    if (stage < 1 or stage > 3) return null;
    return switch (stage) {
        1 => if (thirsty) "buffStatusThirsty01" else "buffStatusHungry01",
        2 => if (thirsty) "buffStatusThirsty02" else "buffStatusHungry02",
        else => if (thirsty) "buffStatusThirsty03" else "buffStatusHungry03",
    };
}

/// Health lost per real second by a buff's `ModifyStats Health subtract`
/// triggered row (stock applies it once per update_rate; this is value / the
/// update interval in seconds, the same conversion healthLossPerSecond used).
pub fn hpLossPerSecond(def: *const BuffDef) f32 {
    const rate_ticks: f32 = @floatFromInt(@max(1, def.update_rate_ticks));
    const secs = rate_ticks / 20.0;
    for (def.stat_mods) |m| {
        if (!eqIgnoreCase(m.stat, "Health")) continue;
        if (m.op != .base_subtract and m.op != .subtract) continue;
        if (m.value <= 0 or secs <= 0) continue;
        return m.value / secs;
    }
    return 0;
}

/// Combined HP-loss rate (per real second) for the active stage-3 survival
/// buffs: stock applies `ModifyStats Health subtract` on each stage-3 buff's
/// update, so the rate is the active buff's row over its update interval.
/// Stock names stay in the loader (xml-audit); the survival loop just passes
/// its resolved stages.
pub fn stage3HpLossPerSecond(t: *const Table, stages: SurvivalStages) f32 {
    var per_s: f32 = 0;
    if (stages.hungry == 3) {
        if (t.byName("buffStatusHungry03")) |d| per_s = @max(per_s, hpLossPerSecond(&d));
    }
    if (stages.thirsty == 3) {
        if (t.byName("buffStatusThirsty03")) |d| per_s = @max(per_s, hpLossPerSecond(&d));
    }
    return per_s;
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
    io_fs.mkdirPath("worlds");
    try io_fs.writeFile(path, xml_src);
    defer io_fs.deleteFile(path);

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
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.defs.len > 10);
    try std.testing.expect(t.passive_pool.len > 0);
}

test "survival numbers resolve from the shipped buffs.xml" {
    const gd = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var t = (tryLoad(std.testing.allocator, gd, null) catch null) orelse return error.SkipZigTest;
    defer t.deinit();
    const sv = survival(&t);
    try std.testing.expect(sv.ok());
    // buffStatusCheck01 gates: Food <= .5 / .25 / .02 of max.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sv.hungry_frac[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), sv.hungry_frac[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), sv.hungry_frac[2], 0.001);
    try std.testing.expect(sv.thirsty_frac[0] > 0);
    // buffStatusHungry03: ModifyStats Health subtract .25 per update.
    try std.testing.expect(sv.starve_hp_per_s > 0);
    try std.testing.expect(sv.dehydrate_hp_per_s > 0);
    // The VM folds the real rows: Hungry03's StaminaChangeOT perc_subtract
    // lands in the tracked deltas and its stage-3 Health loss rate reads off
    // the def.
    const h3 = t.byName("buffStatusHungry03").?;
    const d3 = trackedDeltas(&h3);
    try std.testing.expectApproxEqAbs(@as(f32, -0.1), d3.stamina_ot, 0.001);
    try std.testing.expectApproxEqAbs(sv.starve_hp_per_s, hpLossPerSecond(&h3), 0.0001);
    // A starved player resolves to stage 3 for both bars.
    var hh: components.Health = .{ .food_max = 100, .water_max = 100, .food = 1, .water = 1 };
    const st = survivalStages(sv, &hh);
    try std.testing.expectEqual(@as(u8, 3), st.hungry);
    try std.testing.expectEqual(@as(u8, 3), st.thirsty);
}

test "an empty table resolves to not-ok rather than to zeros that look real" {
    var t = builtin();
    defer t.deinit();
    const sv = survival(&t);
    try std.testing.expect(!sv.ok());
}

test "trackedDeltas folds the tracked surface, omits base_set and untracked names" {
    const def = BuffDef{
        .name = "testBuff",
        .passives = &.{
            .{ .name = "HealthChangeOT", .op = .base_add, .value = 2 },
            .{ .name = "StaminaChangeOT", .op = .perc_subtract, .value = 0.1 },
            .{ .name = "PhysicalDamageResist", .op = .base_add, .value = 8 },
            .{ .name = "GeneralDamageResist", .op = .base_subtract, .value = 3 },
            .{ .name = "HealthMax", .op = .base_set, .value = 150 }, // no base -> omitted
            .{ .name = "HarvestCount", .op = .base_add, .value = 3 }, // untracked
        },
    };
    const d = trackedDeltas(&def);
    try std.testing.expectEqual(@as(f32, 2), d.hp_ot);
    try std.testing.expectEqual(@as(f32, -0.1), d.stamina_ot);
    try std.testing.expectEqual(@as(f32, 8), d.phys_resist);
    try std.testing.expectEqual(@as(f32, -3), d.general_resist);
    try std.testing.expectEqual(@as(f32, 0), d.hp_max); // base_set omitted
    try std.testing.expect(d.any());
}

test "effectTotals sums active buffs and reverts exactly on removal" {
    const def = BuffDef{
        .name = "testBuff",
        .passives = &.{
            .{ .name = "HealthChangeOT", .op = .base_add, .value = 2 },
            .{ .name = "StaminaMax", .op = .base_add, .value = 10 },
        },
    };
    const defs = [_]BuffDef{def};
    const t = Table{ .defs = defs[0..] };
    var set: components.BuffSet = .{};
    set.slots[0] = .{ .active = true, .def_id = 0 };
    const one = effectTotals(&t, &set);
    try std.testing.expectEqual(@as(f32, 2), one.hp_ot);
    try std.testing.expectEqual(@as(f32, 10), one.stamina_max);
    // A second active slot of the same def doubles the sum (additive deltas).
    set.slots[1] = .{ .active = true, .def_id = 0 };
    const two = effectTotals(&t, &set);
    try std.testing.expectEqual(@as(f32, 4), two.hp_ot);
    try std.testing.expectEqual(@as(f32, 20), two.stamina_max);
    // Removal recomputes without it: reverts exactly (revertible effects).
    set.slots[1].active = false;
    const back = effectTotals(&t, &set);
    try std.testing.expectEqual(@as(f32, 2), back.hp_ot);
    try std.testing.expectEqual(@as(f32, 10), back.stamina_max);
    set.slots[0].active = false;
    try std.testing.expect(!effectTotals(&t, &set).any());
}

test "survivalStages selects the stock stage thresholds (0.5 / 0.25 / 0.02)" {
    const sv = Survival{
        .hungry_frac = .{ 0.5, 0.25, 0.02 },
        .thirsty_frac = .{ 0.5, 0.25, 0.02 },
    };
    const expect = struct {
        fn stages(sv_in: Survival, food: f32, water: f32, want_h: u8, want_w: u8) !void {
            var hh: components.Health = .{ .food_max = 100, .water_max = 100, .food = food, .water = water };
            const s = survivalStages(sv_in, &hh);
            try std.testing.expectEqual(@as(u8, want_h), s.hungry);
            try std.testing.expectEqual(@as(u8, want_w), s.thirsty);
        }
    };
    try expect.stages(sv, 60, 60, 0, 0);
    try expect.stages(sv, 50, 50, 1, 1); // <= 0.5
    try expect.stages(sv, 25, 25, 2, 2); // <= 0.25
    try expect.stages(sv, 2, 2, 3, 3); // <= 0.02
    try expect.stages(sv, 1, 99, 3, 0);
}

test "hpLossPerSecond converts the ModifyStats Health row to a per-second rate" {
    const def = BuffDef{
        .name = "buffStatusHungry03",
        .update_rate_ticks = 44, // stock update_rate 2.2 s
        .stat_mods = &.{ .{ .stat = "Health", .op = .base_subtract, .value = 0.25 } },
    };
    const per_s = hpLossPerSecond(&def);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 / 2.2), per_s, 0.0001);
}

test "stageBuffName maps stages to the stock conditional buff names" {
    try std.testing.expectEqualStrings("buffStatusHungry01", stageBuffName(1, false).?);
    try std.testing.expectEqualStrings("buffStatusHungry02", stageBuffName(2, false).?);
    try std.testing.expectEqualStrings("buffStatusHungry03", stageBuffName(3, false).?);
    try std.testing.expectEqualStrings("buffStatusThirsty01", stageBuffName(1, true).?);
    try std.testing.expectEqualStrings("buffStatusThirsty03", stageBuffName(3, true).?);
    try std.testing.expect(stageBuffName(0, false) == null);
}


test "parseCurveValue fills per-level segments; curveAt clamps and levels" {
    var c: [max_curve_len]f32 = .{0} ** max_curve_len;
    const n = parseCurveValue(".011,.022,.05,.1,.16", &c);
    try std.testing.expectEqual(@as(u8, 5), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), c[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), c[4], 0.0001);
    const p = Passive{ .curve = c, .curve_len = n };
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), curveAt(p, 1), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), curveAt(p, 4), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), curveAt(p, 5), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), curveAt(p, 9), 0.0001); // clamp past end
    try std.testing.expectEqual(@as(f32, 0), curveAt(p, 0)); // unpurchased
    // Single-segment rows repeat the flat value.
    var c1: [max_curve_len]f32 = .{0} ** max_curve_len;
    _ = parseCurveValue("1.5", &c1);
    const p1 = Passive{ .curve = c1, .curve_len = 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), curveAt(p1, 3), 0.0001);
}

test "trackedDeltasAt scales a perk curve to its level" {
    const passives = [_]Passive{
        .{ .name = "HealthChangeOT", .op = .base_add, .curve = .{ 0.011, 0.022, 0.05, 0.1, 0.16, 0, 0, 0 }, .curve_len = 5 },
        .{ .name = "GeneralDamageResist", .op = .base_add, .curve = .{ 0.05, 0.25, 0, 0, 0, 0, 0, 0 }, .curve_len = 2 },
    };
    const l1 = trackedDeltasAt(&passives, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.011), l1.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), l1.general_resist, 0.0001);
    const l5 = trackedDeltasAt(&passives, 5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), l5.hp_ot, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), l5.general_resist, 0.0001); // clamp
    const l0 = trackedDeltasAt(&passives, 0);
    try std.testing.expect(!l0.any());
}

test "curveValueAt interpolates the stock quality curve (Q1..Q6)" {
    // RE PassiveEffect.ModValue (IL=796): levels scaled so value[0] = Q1 and
    // value[n-1] = Q6, piecewise-linear. armorPrimitiveHelmet "8,12.3".
    const two = [_]f32{ 8, 12.3 };
    try std.testing.expectApproxEqAbs(@as(f32, 8), curveValueAt(1, 6, &two), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.3), curveValueAt(6, 6, &two), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.72), curveValueAt(3, 6, &two), 0.001); // 8 + 4.3*(2/5)
    // A 6-value curve = per-quality values (armorPreacherOutfit .02..15).
    const six = [_]f32{ 0.02, 0.04, 0.06, 0.08, 0.1, 0.15 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), curveValueAt(1, 6, &six), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), curveValueAt(5, 6, &six), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), curveValueAt(6, 6, &six), 0.0001);
    // Single value is constant; level 0 / empty curve apply nothing.
    const one = [_]f32{5};
    try std.testing.expectApproxEqAbs(@as(f32, 5), curveValueAt(4, 6, &one), 0.001);
    try std.testing.expectEqual(@as(f32, 0), curveValueAt(0, 6, &two));
    try std.testing.expectEqual(@as(f32, 0), curveValueAt(3, 6, &.{}));
}
