//! Loot XML loader: parse helpers, loadFromPath/Slice, tryLoad.
//!
//! Split out of assets/loot.zig (same code, moved verbatim).

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const requirements = @import("requirements.zig");
const sandbox = @import("sandbox.zig");
const io_fs = @import("../util/io_fs.zig");
const loot = @import("loot.zig");
const paths = @import("paths.zig");
const LootTable = loot.LootTable;
const LootEntry = loot.LootEntry;
const LootGroup = loot.LootGroup;
const LootContainer = loot.LootContainer;
const EntryGate = loot.EntryGate;
const ProbTemplate = loot.ProbTemplate;
const ProbScale = loot.ProbScale;
const QtyScale = loot.QtyScale;
const LootBuffSink = loot.LootBuffSink;
const ProbBand = loot.ProbBand;
const QualityTemplate = loot.QualityTemplate;
const QualityBand = loot.QualityBand;
const QualityPick = loot.QualityPick;
pub const hasClientEvaluator = loot.hasClientEvaluator;
pub const stripClientConditionals = loot.stripClientConditionals;
const max_groups = loot.max_groups;
const max_containers = loot.max_containers;
const max_entries = loot.max_entries;

fn parseCountRange(s: []const u8) struct { min: u16, max: u16 } {
    if (std.mem.cutScalar(u8, s, ',')) |parts| {
        const a = xml.parseU16(std.mem.trim(u8, parts[0], " \t")) orelse 1;
        const b = xml.parseU16(std.mem.trim(u8, parts[1], " \t")) orelse a;
        return .{ .min = a, .max = b };
    }
    const v = xml.parseU16(std.mem.trim(u8, s, " \t")) orelse 1;
    return .{ .min = v, .max = v };
}

fn parseItemOrGroup(tag_src: []const u8, tag_at: usize, templates: []const ProbTemplate) ?LootEntry {
    const is_group = xml.attr(tag_src, tag_at, "group") != null;
    const name = if (is_group) xml.attr(tag_src, tag_at, "group") else xml.attr(tag_src, tag_at, "name");
    const n = name orelse return null;
    const cr = parseCountRange(xml.attr(tag_src, tag_at, "count") orelse "1");
    const prob = xml.parseF32(xml.attr(tag_src, tag_at, "prob") orelse "1") orelse 1;
    const fp = xml.attr(tag_src, tag_at, "force_prob") orelse "";
    const quality: u8 = if (xml.attr(tag_src, tag_at, "quality")) |q|
        @intCast(@min(xml.parseU16(q) orelse 0, 255))
    else
        0;
    const stage_mod = xml.parseF32(xml.attr(tag_src, tag_at, "loot_stage_count_mod") orelse "") orelse 0;
    const mods_list = xml.attr(tag_src, tag_at, "mods") orelse "";
    const mod_chance = xml.parseF32(xml.attr(tag_src, tag_at, "mod_chance") orelse "") orelse 0;
    const rnd_dura = blk: {
        const v = xml.attr(tag_src, tag_at, "random_durability") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "True") or std.mem.eql(u8, v, "1");
    };
    // The entry's own `<requirement>` child, if any (the element extent keeps a
    // nested group's gated entries their own). Only `Biome` is rolled today;
    // every other class marks the entry omitted (see `EntryGate`).
    const entry_end = requirements.elementEnd(tag_src, tag_at);
    const inner = tag_src[tag_at..entry_end];
    var gate: EntryGate = .{};
    if (std.mem.findPos(u8, inner, 0, "<requirement")) |req_at| {
        const abs = tag_at + req_at;
        const class = xml.attr(tag_src, abs, "class") orelse "";
        const op = requirements.parseCompare(xml.attr(tag_src, abs, "operation") orelse "");
        if (std.mem.eql(u8, class, "Biome")) {
            gate = .{ .kind = .biome, .biomes = xml.attr(tag_src, abs, "biomes") orelse "" };
        } else if (std.mem.eql(u8, class, "Progression")) {
            gate = .{
                .kind = .progression,
                .arg = xml.attr(tag_src, abs, "name") orelse "",
                .op = op,
                .value = xml.parseF32(xml.attr(tag_src, abs, "value") orelse "") orelse 0,
            };
        } else if (std.mem.eql(u8, class, "CVar")) {
            gate = .{
                .kind = .cvar,
                .arg = xml.attr(tag_src, abs, "cvar") orelse "",
                .op = op,
                .value = xml.parseF32(xml.attr(tag_src, abs, "value") orelse "") orelse 0,
            };
        } else if (std.mem.eql(u8, class, "SandboxOption")) {
            gate = .{
                .kind = .sandbox,
                .arg = xml.attr(tag_src, abs, "option") orelse "",
                .op = op,
                .value = xml.parseF32(xml.attr(tag_src, abs, "value") orelse "") orelse 0,
            };
        } else if (std.mem.eql(u8, class, "RandomRoll")) {
            const value = xml.attr(tag_src, abs, "value") orelse "";
            gate = .{
                .kind = .random_roll,
                .op = op,
                .value = xml.parseF32(value) orelse 0,
                .value_cvar = cvarOperand(value),
                .min_max = parseMinMax(xml.attr(tag_src, abs, "min_max") orelse "0,100"),
            };
        } else {
            gate = .{ .kind = .other };
        }
    }
    var tpl: u16 = 0;
    if (xml.attr(tag_src, tag_at, "loot_prob_template")) |tn| {
        for (templates, 0..) |t, ti| {
            if (std.mem.eql(u8, t.name, tn)) {
                tpl = @intCast(ti + 1);
                break;
            }
        }
    }
    return .{
        .name = n,
        .is_group = is_group,
        .count_min = cr.min,
        .count_max = cr.max,
        .prob = prob,
        .prob_template = tpl,
        .quality = quality,
        .tags = xml.attr(tag_src, tag_at, "tags") orelse "",
        .loot_stage_count_mod = stage_mod,
        .random_durability = rnd_dura,
        .mods = mods_list,
        .mod_chance = mod_chance,
        .buffs = xml.attr(tag_src, tag_at, "buffs") orelse "",
        .force_prob = std.mem.eql(u8, fp, "true") or std.mem.eql(u8, fp, "True"),
        .gate = gate,
    };
}

/// `min_max="a,b"` on a RandomRoll requirement; a bare number is both ends.
fn parseMinMax(s: []const u8) [2]f32 {
    const comma = std.mem.findScalar(u8, s, ',') orelse {
        const v = xml.parseF32(s) orelse 0;
        return .{ v, v };
    };
    return .{
        xml.parseF32(std.mem.trim(u8, s[0..comma], " \t")) orelse 0,
        xml.parseF32(std.mem.trim(u8, s[comma + 1 ..], " \t")) orelse 100,
    };
}

/// `value="@$name"` / `value="@name"` names the entity's cvar; anything else is
/// a literal. `@:` is a localization key, never an operand.
fn cvarOperand(v: []const u8) []const u8 {
    if (std.mem.cutPrefix(u8, v, "@$")) |name| return name;
    if (std.mem.cutPrefix(u8, v, "@")) |name| return name;
    return "";
}

/// Deep-copy the arena-owned slices of one gate (the source buffer dies when
/// the parse returns).
fn dupeGate(arena: std.mem.Allocator, g: EntryGate) !EntryGate {
    var out = g;
    if (out.biomes.len > 0) out.biomes = try arena.dupe(u8, out.biomes);
    if (out.arg.len > 0) out.arg = try arena.dupe(u8, out.arg);
    if (out.value_cvar.len > 0) out.value_cvar = try arena.dupe(u8, out.value_cvar);
    return out;
}

/// `level="a,b"` on a `<loot>` band; a bare number covers exactly that level.
fn parseLevelRange(s: []const u8) struct { min: i32, max: i32 } {
    const comma = std.mem.findScalar(u8, s, ',') orelse {
        const v = std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t"), 10) catch 0;
        return .{ .min = v, .max = v };
    };
    const a = std.fmt.parseInt(i32, std.mem.trim(u8, s[0..comma], " \t"), 10) catch 0;
    const b = std.fmt.parseInt(i32, std.mem.trim(u8, s[comma + 1 ..], " \t"), 10) catch a;
    return .{ .min = a, .max = @max(a, b) };
}

/// Comma list of floats into an arena slice (`poi_tier_mod="0.05,0.1,…"`).
fn parseF32List(arena: std.mem.Allocator, s: []const u8) ![]const f32 {
    var n: usize = 0;
    var count_it = std.mem.splitScalar(u8, s, ',');
    while (count_it.next()) |_| n += 1;
    const out = try arena.alloc(f32, n);
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| : (i += 1) {
        out[i] = xml.parseF32(std.mem.trim(u8, part, " \t")) orelse 0;
    }
    return out;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !LootTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    return loadFromSlice(allocator, raw);
}

pub fn loadFromSlice(allocator: std.mem.Allocator, raw: []const u8) !LootTable {
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var groups: std.ArrayList(LootGroup) = .empty;
    defer groups.deinit(allocator);
    var containers: std.ArrayList(LootContainer) = .empty;
    defer containers.deinit(allocator);

    // <loot_settings poi_tier_mod="…" poi_tier_bonus="…"/>
    var poi_mod: []const f32 = &.{};
    var poi_bonus: []const f32 = &.{};
    if (std.mem.find(u8, clean, "<loot_settings")) |ls| {
        if (xml.attr(clean, ls, "poi_tier_mod")) |v| poi_mod = try parseF32List(arena, v);
        if (xml.attr(clean, ls, "poi_tier_bonus")) |v| poi_bonus = try parseF32List(arena, v);
    }

    // lootprobtemplate: parsed first so item rows can resolve to an index.
    var templates: std.ArrayList(ProbTemplate) = .empty;
    defer templates.deinit(allocator);
    var bands: std.ArrayList(ProbBand) = .empty;
    defer bands.deinit(allocator);
    var ti: usize = 0;
    while (std.mem.findPos(u8, clean, ti, "<lootprobtemplate")) |tag| {
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            ti = gt + 1;
            continue;
        };
        var body: []const u8 = "";
        ti = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootprobtemplate>") orelse break;
            body = clean[gt + 1 .. close];
            ti = close + 19;
        }
        bands.clearRetainingCapacity();
        var bi: usize = 0;
        while (std.mem.findPos(u8, body, bi, "<loot")) |ltag| {
            bi = ltag + 5;
            const lvl = xml.attr(body, ltag, "level") orelse continue;
            const lr = parseLevelRange(lvl);
            try bands.append(allocator, .{
                .min_level = lr.min,
                .max_level = lr.max,
                .prob = xml.parseF32(std.mem.trim(u8, xml.attr(body, ltag, "prob") orelse "0", " \t")) orelse 0,
            });
        }
        if (bands.items.len == 0) continue;
        try templates.append(allocator, .{
            .name = try arena.dupe(u8, name),
            .bands = try arena.dupe(ProbBand, bands.items),
        });
    }
    const tpl = try arena.dupe(ProbTemplate, templates.items);

    // lootqualitytemplate: level bands with prob-weighted quality picks.
    var q_templates: std.ArrayList(QualityTemplate) = .empty;
    defer q_templates.deinit(allocator);
    var qti: usize = 0;
    while (std.mem.findPos(u8, clean, qti, "<lootqualitytemplate")) |qt_tag| {
        const qt_name = xml.attr(clean, qt_tag, "name") orelse {
            qti = qt_tag + 21;
            continue;
        };
        const qt_gt = std.mem.findPos(u8, clean, qt_tag, ">") orelse break;
        var qt_body: []const u8 = "";
        qti = qt_gt + 1;
        if (!(qt_gt > qt_tag and clean[qt_gt - 1] == '/')) {
            const qt_close = std.mem.findPos(u8, clean, qt_gt, "</lootqualitytemplate>") orelse break;
            qt_body = clean[qt_gt + 1 .. qt_close];
            qti = qt_close + 22;
        }
        var q_bands: std.ArrayList(QualityBand) = .empty;
        defer q_bands.deinit(allocator);
        var bi: usize = 0;
        while (std.mem.findPos(u8, qt_body, bi, "<qualitytemplate")) |b_tag| {
            bi = b_tag + 16;
            const lvl = xml.attr(qt_body, b_tag, "level") orelse continue;
            const lr = parseLevelRange(lvl);
            const dflt = xml.parseU16(std.mem.trim(u8, xml.attr(qt_body, b_tag, "default_quality") orelse "1", " \t")) orelse 1;
            const b_gt = std.mem.findPos(u8, qt_body, b_tag, ">") orelse break;
            var b_body: []const u8 = "";
            if (!(b_gt > b_tag and qt_body[b_gt - 1] == '/')) {
                const b_close = std.mem.findPos(u8, qt_body, b_gt, "</qualitytemplate>") orelse break;
                b_body = qt_body[b_gt + 1 .. b_close];
            }
            var picks: std.ArrayList(QualityPick) = .empty;
            defer picks.deinit(allocator);
            var pi: usize = 0;
            while (std.mem.findPos(u8, b_body, pi, "<loot ")) |p_tag| {
                pi = p_tag + 6;
                const q = xml.parseU16(std.mem.trim(u8, xml.attr(b_body, p_tag, "quality") orelse "1", " \t")) orelse 1;
                const p = xml.parseF32(std.mem.trim(u8, xml.attr(b_body, p_tag, "prob") orelse "0", " \t")) orelse 0;
                try picks.append(allocator, .{ .quality = @intCast(@min(q, 255)), .prob = p });
            }
            try q_bands.append(allocator, .{
                .min_level = lr.min,
                .max_level = lr.max,
                .default_quality = @intCast(@min(dflt, 255)),
                .picks = try arena.dupe(QualityPick, picks.items),
            });
        }
        if (q_bands.items.len == 0) continue;
        try q_templates.append(allocator, .{
            .name = try arena.dupe(u8, qt_name),
            .bands = try arena.dupe(QualityBand, q_bands.items),
        });
    }
    const q_tpl = try arena.dupe(QualityTemplate, q_templates.items);

    // lootgroup
    var i: usize = 0;
    while (i < clean.len and groups.items.len < max_groups) {
        const tag = std.mem.findPos(u8, clean, i, "<lootgroup") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 10;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootgroup>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 12;
        }
        var g: LootGroup = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "loot_quality_template")) |lqt| {
            g.quality_template = try arena.dupe(u8, lqt);
        }
        if (xml.attr(clean, tag, "count")) |cv| {
            if (std.mem.eql(u8, cv, "all")) {
                g.pick_all = true;
            } else {
                const cr = parseCountRange(cv);
                g.pick_min = @intCast(@min(cr.min, 255));
                g.pick_max = @intCast(@min(cr.max, 255));
            }
        }
        if (xml.attr(clean, tag, "abundance_type")) |at| {
            g.abundance_type = try arena.dupe(u8, at);
        }
        const scan_body = try stripClientConditionals(allocator, body);
        defer if (scan_body.ptr != body.ptr) allocator.free(scan_body);
        var bi: usize = 0;
        while (bi < scan_body.len and g.entry_n < max_entries) {
            const itag = std.mem.findPos(u8, scan_body, bi, "<item") orelse break;
            if (parseItemOrGroup(scan_body, itag, tpl)) |ent| {
                var e = ent;
                e.name = try arena.dupe(u8, ent.name);
                if (ent.buffs.len > 0) e.buffs = try arena.dupe(u8, ent.buffs);
                if (ent.tags.len > 0) e.tags = try arena.dupe(u8, ent.tags);
                if (ent.mods.len > 0) e.mods = try arena.dupe(u8, ent.mods);
                // The gate's biome list points into the freed source text.
                e.gate = try dupeGate(arena, ent.gate);
                g.entries[g.entry_n] = e;
                g.entry_n += 1;
            }
            bi = itag + 5;
        }
        try groups.append(allocator, g);
        i = next_i;
    }

    // lootcontainer
    i = 0;
    while (i < clean.len and containers.items.len < max_containers) {
        const tag = std.mem.findPos(u8, clean, i, "<lootcontainer") orelse break;
        const name = xml.attr(clean, tag, "name") orelse {
            i = tag + 14;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, tag, ">") orelse break;
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > tag and clean[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, clean, gt, "</lootcontainer>") orelse break;
            body = clean[gt + 1 .. close];
            next_i = close + 16;
        }
        var c: LootContainer = .{
            .name = try arena.dupe(u8, name),
        };
        if (xml.attr(clean, tag, "loot_quality_template")) |lqt| {
            c.quality_template = try arena.dupe(u8, lqt);
        }
        if (xml.attr(clean, tag, "size")) |sz| {
            if (std.mem.cutScalar(u8, sz, ',')) |parts| {
                c.size_x = @intCast(xml.parseU16(std.mem.trim(u8, parts[0], " \t")) orelse 8);
                c.size_y = @intCast(xml.parseU16(std.mem.trim(u8, parts[1], " \t")) orelse 6);
            }
        }
        // destroy_on_close: "true" (1) / "empty" (2) / absent (0). Values
        // feed TEFeatureStorage.ShouldDestroyOnClose (loot-economy.md).
        if (xml.attr(clean, tag, "destroy_on_close")) |doc| {
            if (std.mem.eql(u8, doc, "true")) {
                c.destroy_on_close = 1;
            } else if (std.mem.eql(u8, doc, "empty")) {
                c.destroy_on_close = 2;
            }
        }
        // LootAbundance/type/lootstage/open flags (RE loot-economy.md):
        // ignore_loot_abundance skips the global abundance scale; the rest
        // are parsed for the audit (type multipliers and the stage chain are
        // not applied server-side yet).
        if (xml.attr(clean, tag, "ignore_loot_abundance")) |ila| {
            c.ignore_abundance = std.mem.eql(u8, ila, "true");
        }
        // Stock's loader reads the PLURAL (`LootFromXml` IL_01B8/IL_01CB parse
        // "unique_items" into `LootContainer::UniqueItems`); the singular is
        // what the one stock row happens to carry, so honour both.
        if (xml.attr(clean, tag, "unique_items") orelse xml.attr(clean, tag, "unique_item")) |ui| {
            c.unique_item = std.mem.eql(u8, ui, "true");
        }
        if (xml.attr(clean, tag, "unmodified_lootstage")) |ul| {
            c.raw_lootstage = std.mem.eql(u8, ul, "true");
        }
        if (xml.attr(clean, tag, "open_time")) |ot| {
            c.open_time = xml.parseF32(ot) orelse 0;
        }
        // count="N" or "min,max": how many entries the fill picks. Stock
        // ParseMinMaxCount leaves 1,1 when the attribute is absent.
        if (xml.attr(clean, tag, "count")) |cv| {
            if (!std.mem.eql(u8, cv, "all")) {
                const cr = parseCountRange(cv);
                c.pick_min = cr.min;
                c.pick_max = cr.max;
            }
        }
        const scan_body = try stripClientConditionals(allocator, body);
        defer if (scan_body.ptr != body.ptr) allocator.free(scan_body);
        var bi: usize = 0;
        while (bi < scan_body.len and c.entry_n < max_entries) {
            const itag = std.mem.findPos(u8, scan_body, bi, "<item") orelse break;
            if (parseItemOrGroup(scan_body, itag, tpl)) |ent| {
                var e = ent;
                e.name = try arena.dupe(u8, ent.name);
                if (ent.buffs.len > 0) e.buffs = try arena.dupe(u8, ent.buffs);
                if (ent.tags.len > 0) e.tags = try arena.dupe(u8, ent.tags);
                if (ent.mods.len > 0) e.mods = try arena.dupe(u8, ent.mods);
                e.gate = try dupeGate(arena, ent.gate);
                c.entries[c.entry_n] = e;
                c.entry_n += 1;
            }
            bi = itag + 5;
        }
        try containers.append(allocator, c);
        i = next_i;
    }

    return .{
        .groups = try arena.dupe(LootGroup, groups.items),
        .containers = try arena.dupe(LootContainer, containers.items),
        .prob_templates = tpl,
        .quality_templates = q_tpl,
        .poi_tier_mod = poi_mod,
        .poi_tier_bonus = poi_bonus,
        .arena_ptr = arena_holder,
        .source = .xml,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?LootTable {
    return paths.tryLoadConfig("loot.xml", LootTable, loadFromPath, allocator, game_dir, config_dir);
}
