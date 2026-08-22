//! Stock biomes.xml → per-biomemap-id terrain column layers (top → bottom),
//! weather groups, distant decorations and per-subbiome deco sets + noise
//! windows (GAP 18). Block names resolve via AssignIds (idByName), never XML
//! ordinals.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const maxdamage = @import("maxdamage.zig");
const assignids = @import("assignids_comptime.zig");

pub const max_layers: usize = 8;
pub const max_biomemap_id: usize = 50;
pub const max_biome_mod_rows: usize = 16;

/// biomes.xml per-biome stage modifiers (stock `get_gameStage` /
/// GetLootStage, RE progression.md 5): gamestage_modifier/bonus and
/// lootstage_modifier/bonus on the `<biome>` row.
pub const BiomeMods = struct {
    game_mod: f32 = 0,
    game_bonus: f32 = 0,
    loot_mod: f32 = 0,
    loot_bonus: f32 = 0,
};

pub const BiomeModRow = struct {
    name: []const u8 = "",
    mods: BiomeMods = .{},
};

/// One stock layer: depth blocks from the top of the remaining column, or fill
/// (`depth == 0`) until lower fixed depths need the rest.
pub const Layer = struct {
    depth: u16 = 0, // 0 = "*"
    block_id: u16 = assignids.terr_stone,
};

pub const Stack = struct {
    n: u8 = 0,
    layers: [max_layers]Layer = undefined,

    pub fn slice(self: *const Stack) []const Layer {
        return self.layers[0..self.n];
    }
};

/// Distant-decoration entries a biome can spawn. Only `<decoration type="block">`
/// rows whose Block carries `IsDistantDecoration` survive: that is exactly the
/// filter `BiomeDefinition::AddDecoBlock` applies when it builds the
/// `m_DistantDecoBlocks` list (asm.il 1249700-1249740), and that list is the only
/// one `DecoManager::decorateChunkRandom` samples (asm.il 1266097-1266179). It is
/// what keeps grass (prob .85 / .99) out of the deco burst.
pub const max_deco_per_biome: usize = 12;

pub const DecoBlock = struct {
    block_id: u16,
    /// biomes.xml `prob`, as written. The sampler applies stock's `* 0.125f * 16f`.
    prob: f32,
};

pub const DecoSet = struct {
    n: u8 = 0,
    blocks: [max_deco_per_biome]DecoBlock = undefined,

    /// XML order preserved: the stock sampler walks this list last to first.
    pub fn slice(self: *const DecoSet) []const DecoBlock {
        return self.blocks[0..self.n];
    }
};

/// One `<subbiome noise="freq, min, max" noiseoffset="x, y">` of a biome: its
/// own distant-deco set (GAP_ANALYSIS 18) and the noise window the resolver
/// uses. `decorateChunkRandom` resolves each cell through GetBiomeOrSubAt and
/// samples the subbiome's m_DistantDecoBlocks, where the real tree probability
/// mass lives (pine_forest sub lists carry .06-.08 vs .001-.007 top level).
pub const SubBiome = struct {
    noise_freq: f32 = 0,
    noise_min: f32 = 0,
    noise_max: f32 = 0,
    noise_ox: f32 = 0,
    noise_oz: f32 = 0,
    decos: DecoSet = .{},
};

/// Stock pine_forest has 8 subbiomes; other biomes top out at 2-3.
pub const max_subs_per_biome: usize = 12;

/// Pine-forest-like fallback when biomes.xml is not loaded.
pub fn defaultStack() Stack {
    return .{
        .n = 4,
        .layers = .{
            .{ .depth = 1, .block_id = assignids.terr_forest_ground },
            .{ .depth = 3, .block_id = assignids.terr_dirt },
            .{ .depth = 0, .block_id = assignids.terr_stone },
            .{ .depth = 3, .block_id = assignids.terr_bedrock },
            .{},
            .{},
            .{},
            .{},
        },
    };
}

pub const max_weather_biomes: usize = 16;
/// Stock biomes.xml tops out at 12 groups (wasteland); trailing extras are dropped.
/// Dropping only the tail keeps every kept group's document ordinal, which is the
/// wire groupIndex the client indexes weatherGroups with.
pub const max_weather_groups: usize = 12;
/// Stock tops out at two `<Condition>` entries per group; extras are dropped and
/// the remaining weights renormalize over what was kept.
pub const max_weather_ranges: usize = 4;
pub const max_weather_name: usize = 16;
/// BiomeDefinition/Probabilities/ProbType (asm.il ~1249177): Temperature,
/// Precipitation, CloudThickness, Wind, Fog. Same slot order as WeatherPackage.param.
pub const prob_type_count: usize = 5;

/// One `<Condition range="lo,hi" prob="w"/>`. `weight` is normalized across the
/// condition's entries (BiomeDefinition/Probabilities::Normalize, asm.il ~1249400).
pub const WeatherRange = struct {
    lo: f32 = 0,
    hi: f32 = 0,
    weight: f32 = 0,
};

/// One `<weather name= prob= duration= delay= buff=>` group of a biome.
/// Wire groupIndex is the group's document ordinal inside its own biome.
pub const WeatherGroup = struct {
    name_buf: [max_weather_name]u8 = [_]u8{0} ** max_weather_name,
    /// 0 when the XML name did not fit the buffer, so it matches no group query.
    name_len: u8 = 0,
    /// Normalized across the biome's groups (BiomeDefinition::SetupWeather).
    prob: f32 = 0,
    /// World ticks: AddWeatherGroup (asm.il ~1249840) scales XML hours by 1000.
    duration: i32 = 3000,
    delay_lo: i32 = 0,
    delay_hi: i32 = 0,
    range_n: [prob_type_count]u8 = [_]u8{0} ** prob_type_count,
    ranges: [prob_type_count][max_weather_ranges]WeatherRange =
        [_][max_weather_ranges]WeatherRange{[_]WeatherRange{.{}} ** max_weather_ranges} ** prob_type_count,

    pub fn name(self: *const WeatherGroup) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn rangeSlice(self: *const WeatherGroup, prob_type: usize) []const WeatherRange {
        return self.ranges[prob_type][0..self.range_n[prob_type]];
    }
};

/// Ordered weather groups of one biome (index == wire groupIndex).
pub const WeatherGroupSet = struct {
    n: u8 = 0,
    groups: [max_weather_groups]WeatherGroup = [_]WeatherGroup{.{}} ** max_weather_groups,

    /// BiomeDefinition::FindWeatherGroupIndex (asm.il ~1250180): -1 when absent.
    pub fn findIndex(self: *const WeatherGroupSet, group_name: []const u8) ?u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (std.mem.eql(u8, self.groups[i].name(), group_name)) return @intCast(i);
        }
        return null;
    }
};

pub const Table = struct {
    /// biomemap id → fill stack (missing → default_stack).
    stacks: [max_biomemap_id]Stack = [_]Stack{.{}} ** max_biomemap_id,
    default_stack: Stack = defaultStack(),
    /// Ordered biomemap ids that have weather groups (for NetPackageWeather body).
    /// Stock InitBiomeWeather (asm.il ~2050437) keeps exactly the biomes with
    /// weatherGroups.Count > 0, which is what sizes the wire body on both ends.
    weather_ids: [max_weather_biomes]u8 = .{0} ** max_weather_biomes,
    /// Parallel to weather_ids.
    weather_groups: [max_weather_biomes]WeatherGroupSet = [_]WeatherGroupSet{.{}} ** max_weather_biomes,
    weather_n: u8 = 0,
    /// biomemap id → distant-decoration set (empty when the biome declares none,
    /// or when nothing in it resolved: no fabricated species).
    decos: [max_biomemap_id]DecoSet = [_]DecoSet{.{}} ** max_biomemap_id,
    /// biomemap id → per-subbiome distant-deco sets + noise windows (GAP 18).
    subs: [max_biomemap_id][max_subs_per_biome]SubBiome =
        [_][max_subs_per_biome]SubBiome{[_]SubBiome{.{}} ** max_subs_per_biome} ** max_biomemap_id,
    sub_n: [max_biomemap_id]u8 = .{0} ** max_biomemap_id,
    /// biomemap id → biome name ("pine_forest", "wasteland", …), for the spawn
    /// system's per-biome entitygroup resolution.
    names: [max_biomemap_id]?[]const u8 = .{null} ** max_biomemap_id,
    /// biome name → gamestage/lootstage modifier row (biomes.xml attrs).
    mods: [max_biome_mod_rows]BiomeModRow = [_]BiomeModRow{.{}} ** max_biome_mod_rows,
    mod_n: u8 = 0,
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    loaded: bool = false,

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
        }
        self.* = .{};
    }

    /// Biome name for a biomemap id (from `<biomemap id="NN" name="X"/>`).
    pub fn nameById(self: *const Table, id: u8) ?[]const u8 {
        if (id >= max_biomemap_id) return null;
        return self.names[id];
    }

    /// Stage modifiers for a biome name (biomes.xml gamestage/lootstage
    /// modifier + bonus). Missing rows return the zero default.
    pub fn biomeMods(self: *const Table, name: []const u8) BiomeMods {
        for (self.mods[0..self.mod_n]) |row| {
            if (std.mem.eql(u8, row.name, name)) return row.mods;
        }
        return .{};
    }

    /// Number of biomes that resolved names (biomes.xml `<biomemap>` rows).
    /// Feeds the procedural biome field (W3): < 2 keeps single-biome fill.
    pub fn biomeCount(self: *const Table) u8 {
        var n: u8 = 0;
        for (self.names) |nm| {
            if (nm != null) n += 1;
        }
        return n;
    }

    /// The idx-th resolved biome's real biomemap id. ids are sparse in stock
    /// biomes.xml (1, 3, 5, 6, 7, 8, 9, 13, …), so an index into the resolved
    /// list must be translated before `stackFor`.
    pub fn biomeIdAt(self: *const Table, idx: u8) u8 {
        var seen: u8 = 0;
        for (self.names, 0..) |nm, id| {
            if (nm != null) {
                if (seen == idx) return @intCast(id);
                seen += 1;
            }
        }
        return 0;
    }

    pub fn stackFor(self: *const Table, biome_id: u8) Stack {
        if (biome_id < max_biomemap_id and self.stacks[biome_id].n > 0)
            return self.stacks[biome_id];
        if (self.default_stack.n > 0) return self.default_stack;
        return defaultStack();
    }

    /// Distant-decoration set for a biomemap id. Empty (not a fallback) when the
    /// biome has none: an unknown biome must place nothing rather than borrow
    /// another biome's species.
    pub fn decosFor(self: *const Table, biome_id: u8) DecoSet {
        if (biome_id >= max_biomemap_id) return .{};
        return self.decos[biome_id];
    }

    /// Per-subbiome deco sets + noise windows for a biomemap id (GAP 18). The
    /// resolver (subbiome_noise.subBiomeIdx) picks one per cell; -1 means the
    /// biome's own `decosFor` list.
    pub fn subBiomes(self: *const Table, biome_id: u8) []const SubBiome {
        if (biome_id >= max_biomemap_id) return &.{};
        return self.subs[biome_id][0..self.sub_n[biome_id]];
    }

    /// True when at least one biome resolved a distant-decoration species.
    pub fn hasDecos(self: *const Table) bool {
        for (self.decos) |d| {
            if (d.n > 0) return true;
        }
        return false;
    }

    /// Fill column blocks[0..h] inclusive from layers (surface at y=h).
    pub fn fillColumn(stack: Stack, h: u8, out: *[256]u16) void {
        @memset(out, 0);
        if (h >= 256) return;
        const layers = stack.slice();
        if (layers.len == 0) {
            fillFallback(h, out);
            return;
        }
        // Sum fixed depths after each index (for "*" budget).
        var fixed_after: [max_layers + 1]u32 = .{0} ** (max_layers + 1);
        var i: usize = layers.len;
        while (i > 0) {
            i -= 1;
            const d = layers[i].depth;
            const add: u32 = if (d == 0) 0 else d;
            fixed_after[i] = fixed_after[i + 1] + add;
        }
        var y: i32 = h;
        for (layers, 0..) |layer, li| {
            if (y < 0) break;
            // Each layer is a contiguous descending run of one id: write it as a
            // span so the fill is a vector store, not 256 scalar ones.
            if (layer.depth == 0) {
                // Fill until only fixed_after[li+1] blocks remain below.
                const reserve: i32 = @intCast(fixed_after[li + 1]);
                if (y >= reserve) {
                    @memset(out[@intCast(reserve)..@intCast(y + 1)], layer.block_id);
                    y = reserve - 1;
                }
            } else {
                const n: i32 = @min(@as(i32, layer.depth), y + 1);
                @memset(out[@intCast(y - n + 1)..@intCast(y + 1)], layer.block_id);
                y -= n;
            }
        }
        // Any gap below (malformed XML): stone, y=0 bedrock if empty.
        if (y >= 1) @memset(out[1..@intCast(y + 1)], assignids.terr_stone);
        if (y >= 0) out[0] = assignids.terr_bedrock;
        if (out[0] == 0) out[0] = assignids.terr_bedrock;
    }

    fn fillFallback(h: u8, out: *[256]u16) void {
        var y: u16 = 0;
        while (y <= h) : (y += 1) {
            if (y == 0) {
                out[y] = assignids.terr_bedrock;
            } else if (y + 3 < h) {
                out[y] = assignids.terr_stone;
            } else if (y == h) {
                out[y] = assignids.terr_dirt;
            } else {
                out[y] = assignids.terr_dirt;
            }
        }
    }
};

fn firstBlockName(blockname: []const u8) []const u8 {
    // wasteland: "terrDestroyedStone,terrDestroyedGrass"
    if (std.mem.findScalar(u8, blockname, ',')) |c| return std.mem.trim(u8, blockname[0..c], " \t");
    return std.mem.trim(u8, blockname, " \t");
}

fn parseDepth(s: []const u8) ?u16 {
    if (s.len == 1 and s[0] == '*') return 0;
    return xml.parseU16(s);
}

/// Finite non-negative float or `fallback` (biomes.xml is patchable by mods, so
/// every number it yields is sanitized before it can steer a probability walk).
fn sanePositive(v: ?f32, fallback: f32) f32 {
    const f = v orelse return fallback;
    if (!std.math.isFinite(f) or f < 0) return fallback;
    return f;
}

fn saneFinite(v: ?f32, fallback: f32) f32 {
    const f = v orelse return fallback;
    if (!std.math.isFinite(f)) return fallback;
    return f;
}

/// XML hours → world ticks (AddWeatherGroup multiplies by 1000). Clamped so a
/// malformed duration can never trap @trunc or run time backwards.
fn ticksFromHours(hours: f32) i32 {
    if (!std.math.isFinite(hours) or hours <= 0) return 0;
    return @trunc(@min(hours * 1000.0, 2.0e9));
}

/// `lo,hi` pair, or a single value used for both components (Unity Vector2 parse).
fn parsePair(s: []const u8, lo: *f32, hi: *f32) void {
    if (std.mem.findScalar(u8, s, ',')) |c| {
        lo.* = saneFinite(xml.parseF32(std.mem.trim(u8, s[0..c], " \t")), lo.*);
        hi.* = saneFinite(xml.parseF32(std.mem.trim(u8, s[c + 1 ..], " \t")), hi.*);
        return;
    }
    const v = saneFinite(xml.parseF32(std.mem.trim(u8, s, " \t")), lo.*);
    lo.* = v;
    hi.* = v;
}

/// WorldBiomes::ParseWeather (asm.il ~1252740) matches condition tags case-insensitively.
fn probTypeFor(tag: []const u8) ?usize {
    if (std.ascii.eqlIgnoreCase(tag, "Temperature")) return 0;
    if (std.ascii.eqlIgnoreCase(tag, "Precipitation")) return 1;
    if (std.ascii.eqlIgnoreCase(tag, "CloudThickness")) return 2;
    if (std.ascii.eqlIgnoreCase(tag, "Wind")) return 3;
    if (std.ascii.eqlIgnoreCase(tag, "Fog")) return 4;
    return null;
}

/// Element name right after `<` (empty when the tag is a close/comment/decl).
fn tagNameAt(body: []const u8, lt: usize) []const u8 {
    var e = lt + 1;
    while (e < body.len and (std.ascii.isAlphanumeric(body[e]) or body[e] == '_')) e += 1;
    return body[lt + 1 .. e];
}

/// `<Temperature range=".." min=".." max=".." prob=".."/>` children of one group.
/// Defaults follow ParseWeather: 0..100, except Temperature which is -50..150.
fn parseWeatherConditions(group_body: []const u8, g: *WeatherGroup) void {
    var i: usize = 0;
    while (i < group_body.len) {
        const lt = std.mem.findScalarPos(u8, group_body, i, '<') orelse break;
        i = lt + 1;
        const tag = tagNameAt(group_body, lt);
        if (tag.len == 0) continue;
        const pt = probTypeFor(tag) orelse continue;
        if (g.range_n[pt] >= max_weather_ranges) continue;
        var lo: f32 = if (pt == 0) -50 else 0;
        var hi: f32 = if (pt == 0) 150 else 100;
        if (xml.attr(group_body, lt, "min")) |s| lo = saneFinite(xml.parseF32(s), lo);
        if (xml.attr(group_body, lt, "max")) |s| hi = saneFinite(xml.parseF32(s), hi);
        if (xml.attr(group_body, lt, "range")) |s| parsePair(s, &lo, &hi);
        const weight = sanePositive(if (xml.attr(group_body, lt, "prob")) |s| xml.parseF32(s) else null, 1);
        g.ranges[pt][g.range_n[pt]] = .{ .lo = lo, .hi = hi, .weight = weight };
        g.range_n[pt] += 1;
    }
}

/// Probabilities::Normalize: per condition, divide every weight by their sum.
fn normalizeConditions(g: *WeatherGroup) void {
    var pt: usize = 0;
    while (pt < prob_type_count) : (pt += 1) {
        var total: f32 = 0;
        for (g.ranges[pt][0..g.range_n[pt]]) |r| total += r.weight;
        if (total <= 0) continue;
        var i: usize = 0;
        while (i < g.range_n[pt]) : (i += 1) g.ranges[pt][i].weight /= total;
    }
}

/// Ordered `<weather>` groups of one `<biome>` body, probabilities normalized the
/// way BiomeDefinition::SetupWeather does (prob /= total + 1e-6).
pub fn parseWeatherGroups(body: []const u8) WeatherGroupSet {
    var set: WeatherGroupSet = .{};
    var i: usize = 0;
    while (set.n < max_weather_groups) {
        const el = xml.nextElement(body, i, "<weather", "</weather>") orelse break;
        i = el.next_i;
        // Guard against a longer tag that merely shares the prefix.
        const after = el.open_at + "<weather".len;
        if (after < body.len and !std.ascii.isWhitespace(body[after]) and body[after] != '>' and body[after] != '/')
            continue;
        var g: WeatherGroup = .{};
        if (xml.attr(body, el.open_at, "name")) |nm| {
            if (nm.len <= max_weather_name) {
                @memcpy(g.name_buf[0..nm.len], nm);
                g.name_len = @intCast(nm.len);
            }
        }
        g.prob = sanePositive(if (xml.attr(body, el.open_at, "prob")) |s| xml.parseF32(s) else null, 1);
        g.duration = ticksFromHours(sanePositive(
            if (xml.attr(body, el.open_at, "duration")) |s| xml.parseF32(s) else null,
            3,
        ));
        if (xml.attr(body, el.open_at, "delay")) |s| {
            var lo: f32 = 0;
            var hi: f32 = 0;
            parsePair(s, &lo, &hi);
            g.delay_lo = ticksFromHours(lo);
            g.delay_hi = ticksFromHours(hi);
        }
        parseWeatherConditions(el.body, &g);
        normalizeConditions(&g);
        set.groups[set.n] = g;
        set.n += 1;
    }
    var total: f32 = 0;
    var ti: usize = 0;
    while (ti < set.n) : (ti += 1) total += set.groups[ti].prob;
    const denom = total + 1e-6;
    var gi: usize = 0;
    while (gi < set.n) : (gi += 1) set.groups[gi].prob /= denom;
    return set;
}

fn parseStackBody(body: []const u8, id_by_name: *const fn (?*anyopaque, []const u8) ?u16, ctx: ?*anyopaque) Stack {
    var st: Stack = .{};
    // Prefer first <layers>…</layers> in the biome (often inside the first subbiome).
    const layers_body: []const u8 = blk: {
        if (std.mem.find(u8, body, "<layers")) |ls| {
            const gt = std.mem.findPos(u8, body, ls, ">") orelse break :blk body;
            const close = std.mem.findPos(u8, body, gt, "</layers>") orelse break :blk body;
            break :blk body[gt + 1 .. close];
        }
        break :blk body;
    };
    var i: usize = 0;
    while (i < layers_body.len and st.n < max_layers) {
        const li = std.mem.findPos(u8, layers_body, i, "<layer") orelse break;
        const depth_s = xml.attr(layers_body, li, "depth") orelse {
            i = li + 6;
            continue;
        };
        const bname_raw = xml.attr(layers_body, li, "blockname") orelse {
            i = li + 6;
            continue;
        };
        const depth = parseDepth(depth_s) orelse {
            i = li + 6;
            continue;
        };
        const bname = firstBlockName(bname_raw);
        const bid = id_by_name(ctx, bname) orelse {
            i = li + 6;
            continue;
        };
        st.layers[st.n] = .{ .depth = depth, .block_id = bid };
        st.n += 1;
        i = li + 6;
    }
    return st;
}

/// Body of the biome's own `<decorations>` group, i.e. the one that is not
/// inside a `<subbiome>`. That is the group `IBiomeProvider::GetBiomeOrSubAt`
/// resolves to wherever no subbiome noise hits. Subbiome groups are parsed
/// separately (parseSubBiomes, GAP 18), so a biome whose only decorations live
/// inside subbiomes reports no own list instead of borrowing the first sub's.
fn decorationsBody(body: []const u8) ?[]const u8 {
    var i: usize = 0;
    var sub_end: usize = 0;
    while (i < body.len) {
        const di = std.mem.findPos(u8, body, i, "<decorations>") orelse break;
        const close = std.mem.findPos(u8, body, di, "</decorations>") orelse break;
        const inner = body[di + 13 .. close];
        // Is this group inside a <subbiome> that has not closed yet?
        if (di >= sub_end) {
            sub_end = 0;
            var si: usize = 0;
            while (std.mem.findPos(u8, body, si, "<subbiome")) |sb| {
                if (sb > di) break;
                const se = std.mem.findPos(u8, body, sb, "</subbiome>") orelse body.len;
                if (sb < di and di < se) {
                    sub_end = se;
                    break;
                }
                si = sb + 9;
            }
        }
        if (sub_end == 0) return inner;
        i = close + 14;
    }
    return null;
}

/// Parse the comma-separated float list of a `noise` / `noiseoffset` attribute
/// into `out`; returns the count written (0 on malformed input, fail closed).
fn parseFloats(v: []const u8, out: []f32) u8 {
    var n: u8 = 0;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |part| {
        if (n >= out.len) break;
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const f = xml.parseF32(trimmed) orelse return 0;
        out[n] = f;
        n += 1;
    }
    return n;
}

/// Parse every `<subbiome>` of a biome body: the noise window
/// (`noise="freq, min, max"`, optional `noiseoffset="x, y"`) and the
/// subbiome's own distant-deco set (its `<decorations>` group). Out-of-range
/// subbiomes are dropped; a malformed noise window drops just that subbiome.
fn parseSubBiomes(
    body: []const u8,
    id_by_name: *const fn (?*anyopaque, []const u8) ?u16,
    is_distant_deco: *const fn (?*anyopaque, []const u8) bool,
    ctx: ?*anyopaque,
    out: []SubBiome,
) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < body.len and n < out.len) {
        const si = std.mem.findPos(u8, body, i, "<subbiome") orelse break;
        const gt = std.mem.findPos(u8, body, si, ">") orelse break;
        const close = std.mem.findPos(u8, body, gt, "</subbiome>") orelse break;
        var noise_vals: [3]f32 = undefined;
        const noise_s = xml.attr(body, si, "noise") orelse {
            i = close + 11;
            continue;
        };
        if (parseFloats(noise_s, &noise_vals) != 3) {
            i = close + 11;
            continue;
        }
        var off_vals: [2]f32 = .{ 0, 0 };
        if (xml.attr(body, si, "noiseoffset")) |off_s| {
            if (parseFloats(off_s, &off_vals) != 2) {
                i = close + 11;
                continue;
            }
        }
        const inner = body[gt + 1 .. close];
        out[n] = .{
            .noise_freq = noise_vals[0],
            .noise_min = noise_vals[1],
            .noise_max = noise_vals[2],
            .noise_ox = off_vals[0],
            .noise_oz = off_vals[1],
            .decos = parseDecoBody(inner, id_by_name, is_distant_deco, ctx),
        };
        n += 1;
        i = close + 11;
    }
    return n;
}

fn parseDecoBody(
    body: []const u8,
    id_by_name: *const fn (?*anyopaque, []const u8) ?u16,
    is_distant_deco: *const fn (?*anyopaque, []const u8) bool,
    ctx: ?*anyopaque,
) DecoSet {
    var set: DecoSet = .{};
    const decos = decorationsBody(body) orelse return set;
    var i: usize = 0;
    while (i < decos.len and set.n < max_deco_per_biome) {
        const di = std.mem.findPos(u8, decos, i, "<decoration") orelse break;
        i = di + 11;
        // type="prefab" rows name a POI, not a block: no DecoObject to send.
        const kind = xml.attr(decos, di, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "block")) continue;
        const bname = xml.attr(decos, di, "blockname") orelse continue;
        const prob_s = xml.attr(decos, di, "prob") orelse continue;
        const prob = xml.parseF32(prob_s) orelse continue;
        if (prob <= 0) continue;
        if (!is_distant_deco(ctx, bname)) continue;
        // Unresolvable id would NRE the client's world-load coroutine; drop it.
        const bid = id_by_name(ctx, bname) orelse continue;
        if (bid == 0) continue;
        set.blocks[set.n] = .{ .block_id = bid, .prob = prob };
        set.n += 1;
    }
    return set;
}

fn noDistantDeco(_: ?*anyopaque, _: []const u8) bool {
    return false;
}

/// Load biomes.xml: biomemap id→name, then each biome's top-level layers.
/// `is_distant_deco` gates `<decorations>` parsing; pass null to skip it.
pub fn loadFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    id_by_name: *const fn (?*anyopaque, []const u8) ?u16,
    is_distant_deco: ?*const fn (?*anyopaque, []const u8) bool,
    ctx: ?*anyopaque,
) !Table {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var table: Table = .{ .arena_ptr = arena_holder };
    // biomemap id → name (duped into the table arena so the names outlive `clean`).
    var name_by_id: [max_biomemap_id]?[]const u8 = .{null} ** max_biomemap_id;
    var i: usize = 0;
    while (i < clean.len) {
        const mi = std.mem.findPos(u8, clean, i, "<biomemap") orelse break;
        const id_s = xml.attr(clean, mi, "id") orelse {
            i = mi + 9;
            continue;
        };
        const nm = xml.attr(clean, mi, "name") orelse {
            i = mi + 9;
            continue;
        };
        // ids are often "03" / "09"
        const id_n = std.fmt.parseInt(u8, id_s, 10) catch {
            i = mi + 9;
            continue;
        };
        if (id_n < max_biomemap_id) name_by_id[id_n] = nm;
        i = mi + 9;
    }

    // Parse each <biome name="..."> … </biome> for layer stack; keep the body slice
    // so weather groups are only parsed for the biomes a biomemap id points at.
    var stacks_by_name: std.StringHashMapUnmanaged(Stack) = .{};
    defer stacks_by_name.deinit(allocator);
    var bodies_by_name: std.StringHashMapUnmanaged([]const u8) = .{};
    defer bodies_by_name.deinit(allocator);
    var decos_by_name: std.StringHashMapUnmanaged(DecoSet) = .{};
    defer decos_by_name.deinit(allocator);
    var subs_by_name: std.StringHashMapUnmanaged([]SubBiome) = .{};
    defer subs_by_name.deinit(allocator);
    var mods_by_name: std.StringHashMapUnmanaged(BiomeMods) = .{};
    defer mods_by_name.deinit(allocator);
    const deco_ok = is_distant_deco orelse noDistantDeco;
    i = 0;
    while (i < clean.len) {
        const bi = std.mem.findPos(u8, clean, i, "<biome ") orelse break;
        const bname = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        // Stage modifiers ride the <biome> tag (gamestage/lootstage modifier
        // + bonus); stock applies them in get_gameStage / GetLootStage
        // (progression.md 5).
        var biome_mods: BiomeMods = .{};
        if (xml.attr(clean, bi, "gamestage_modifier")) |v| biome_mods.game_mod = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, bi, "gamestage_bonus")) |v| biome_mods.game_bonus = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, bi, "lootstage_modifier")) |v| biome_mods.loot_mod = std.fmt.parseFloat(f32, v) catch 0;
        if (xml.attr(clean, bi, "lootstage_bonus")) |v| biome_mods.loot_bonus = std.fmt.parseFloat(f32, v) catch 0;
        try mods_by_name.put(allocator, bname, biome_mods);
        const gt = std.mem.findPos(u8, clean, bi, ">") orelse break;
        const close = std.mem.findPos(u8, clean, gt, "</biome>") orelse break;
        const body = clean[gt + 1 .. close];
        // First <layers> group (top-level or first subbiome).
        const st = parseStackBody(body, id_by_name, ctx);
        if (st.n > 0) {
            try stacks_by_name.put(allocator, bname, st);
        }
        try bodies_by_name.put(allocator, bname, body);
        const ds = parseDecoBody(body, id_by_name, deco_ok, ctx);
        if (ds.n > 0) {
            try decos_by_name.put(allocator, bname, ds);
        }
        // Per-subbiome deco sets (GAP 18): each sub carries its own list and a
        // noise window; the top-level decos above stay the no-sub fallback.
        var sub_buf: [max_subs_per_biome]SubBiome = undefined;
        const sn = parseSubBiomes(body, id_by_name, deco_ok, ctx, &sub_buf);
        if (sn > 0) {
            const kept = try arena.dupe(SubBiome, sub_buf[0..sn]);
            try subs_by_name.put(allocator, bname, kept);
        }
        i = close + 8;
    }

    // Default: pine_forest if present, else dirt/stone/bedrock fallback stack.
    if (stacks_by_name.get("pine_forest")) |st| {
        table.default_stack = st;
    } else {
        table.default_stack = defaultStack();
    }

    var id: usize = 0;
    while (id < max_biomemap_id) : (id += 1) {
        const nm = name_by_id[id] orelse continue;
        if (stacks_by_name.get(nm)) |st| {
            table.stacks[id] = st;
        }
        if (decos_by_name.get(nm)) |ds| {
            table.decos[id] = ds;
        }
        if (subs_by_name.get(nm)) |sn| {
            table.sub_n[id] = @intCast(@min(sn.len, max_subs_per_biome));
            var si: usize = 0;
            while (si < table.sub_n[id]) : (si += 1) table.subs[id][si] = sn[si];
        }
        const body = bodies_by_name.get(nm) orelse continue;
        if (table.weather_n >= max_weather_biomes) continue;
        const set = parseWeatherGroups(body);
        if (set.n == 0) continue;
        table.weather_ids[table.weather_n] = @intCast(id);
        table.weather_groups[table.weather_n] = set;
        table.weather_n += 1;
    }
    // water / underwater: keep default (no land layers); surface gen still uses heights.
    for (name_by_id, 0..) |nm, idx| {
        table.names[idx] = if (nm) |n| try arena.dupe(u8, n) else null;
    }
    var mod_it = mods_by_name.iterator();
    while (mod_it.next()) |e| {
        if (table.mod_n >= max_biome_mod_rows) break;
        table.mods[table.mod_n] = .{ .name = try arena.dupe(u8, e.key_ptr.*), .mods = e.value_ptr.* };
        table.mod_n += 1;
    }
    table.loaded = true;
    return table;
}

pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    id_by_name: *const fn (?*anyopaque, []const u8) ?u16,
    is_distant_deco: ?*const fn (?*anyopaque, []const u8) bool,
    ctx: ?*anyopaque,
) !?Table {
    const paths = @import("paths.zig");
    var path_buf: [2048]u8 = undefined;
    const base = paths.resolveConfigXml(&path_buf, "biomes.xml", game_dir, config_dir) orelse return null;
    // Parse/I/O failures must not look like "biomes absent": an operator's
    // custom/overridden biomes.xml failing to load silently falls back to
    // builtin defaults (wrong terrain layers, weather groups, deco) with no
    // diagnostics. Log with the path, like the blocks/quests loaders.
    const loadLogged = struct {
        fn call(alloc: std.mem.Allocator, p: []const u8, ibn: *const fn (?*anyopaque, []const u8) ?u16, idd: ?*const fn (?*anyopaque, []const u8) bool, cctx: ?*anyopaque) !?Table {
            return loadFromPath(alloc, p, ibn, idd, cctx) catch |err| {
                std.debug.print(
                    "zdtd: load biomes.xml failed: {s} ({s})\n",
                    .{ @errorName(err), p },
                );
                return null;
            };
        }
    }.call;
    if (paths.override_dirs.len == 0) {
        return try loadLogged(allocator, base, id_by_name, is_distant_deco, ctx);
    }
    const merged = try paths.readConfigXml(allocator, "biomes.xml", game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    io_fs.mkdirPath(".zdtd_cfg_cache");
    const cp = ".zdtd_cfg_cache/biomes.xml";
    {
        io_fs.writeFile(cp, merged) catch return loadLogged(allocator, base, id_by_name, is_distant_deco, ctx);
    }
    return loadLogged(allocator, cp, id_by_name, is_distant_deco, ctx);
}

fn testId(_: ?*anyopaque, name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "terrBurntForestGround")) return assignids.terr_burnt_forest_ground;
    if (std.mem.eql(u8, name, "terrForestGround")) return assignids.terr_forest_ground;
    if (std.mem.eql(u8, name, "terrDirt")) return assignids.terr_dirt;
    if (std.mem.eql(u8, name, "terrStone")) return assignids.terr_stone;
    if (std.mem.eql(u8, name, "terrBedrock")) return assignids.terr_bedrock;
    if (std.mem.eql(u8, name, "terrDesertGround")) return assignids.terr_desert_ground;
    if (std.mem.eql(u8, name, "terrSnow")) return assignids.terr_snow;
    if (std.mem.eql(u8, name, "terrSandStone")) return assignids.terr_sand_stone;
    if (std.mem.eql(u8, name, "terrDestroyedStone")) return assignids.terr_destroyed_stone;
    if (std.mem.eql(u8, name, "terrDestroyedGrass")) return assignids.terr_destroyed_grass;
    return null;
}

test "fillColumn burnt_forest surface" {
    const st: Stack = .{
        .n = 4,
        .layers = .{
            .{ .depth = 1, .block_id = assignids.terr_burnt_forest_ground },
            .{ .depth = 3, .block_id = assignids.terr_dirt },
            .{ .depth = 0, .block_id = assignids.terr_stone },
            .{ .depth = 3, .block_id = assignids.terr_bedrock },
            .{},
            .{},
            .{},
            .{},
        },
    };
    var col: [256]u16 = undefined;
    Table.fillColumn(st, 60, &col);
    try std.testing.expectEqual(assignids.terr_burnt_forest_ground, col[60]);
    try std.testing.expectEqual(assignids.terr_dirt, col[59]);
    try std.testing.expectEqual(assignids.terr_dirt, col[57]);
    try std.testing.expectEqual(assignids.terr_stone, col[56]);
    try std.testing.expectEqual(assignids.terr_stone, col[3]);
    try std.testing.expectEqual(assignids.terr_bedrock, col[2]);
    try std.testing.expectEqual(assignids.terr_bedrock, col[0]);
    try std.testing.expectEqual(@as(u16, 0), col[61]);
}

/// Stand-in for maxdamage's resolved `IsDistantDecoration`: trees yes, the
/// high-probability grass and shrub rows no.
fn testDistantDeco(_: ?*anyopaque, name: []const u8) bool {
    return std.mem.startsWith(u8, name, "tree") and
        !std.mem.eql(u8, name, "treeShortGrass") and
        !std.mem.eql(u8, name, "treeTallGrassDiagonal");
}

fn testDecoId(_: ?*anyopaque, name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "treeOak")) return 24629;
    if (std.mem.eql(u8, name, "treeJuniper")) return 24630;
    if (std.mem.eql(u8, name, "treeShortGrass")) return 24700;
    if (std.mem.eql(u8, name, "treeTallGrassDiagonal")) return 24701;
    if (std.mem.eql(u8, name, "terrForestGround")) return assignids.terr_forest_ground;
    return null;
}

test "decorations parse keeps distant deco in XML order" {
    const src =
        \\<biomes>
        \\<biomemap id="03" name="pine_forest"/>
        \\<biomemap id="05" name="desert"/>
        \\<biome name="pine_forest">
        \\  <subbiome noise=".01, 0, .2">
        \\    <decorations>
        \\      <decoration type="block" blockname="treeOak" prob=".9"/>
        \\    </decorations>
        \\  </subbiome>
        \\  <decorations>
        \\    <decoration type="prefab" name="rock_form02" prob=".001"/>
        \\    <decoration type="block" blockname="treeJuniper" prob=".06" rotatemax="7"/>
        \\    <decoration type="block" blockname="treeOak" prob=".07" rotatemax="7"/>
        \\    <decoration type="block" blockname="treeMissingFromDump" prob=".5"/>
        \\    <decoration type="block" blockname="treeTallGrassDiagonal" prob=".99"/>
        \\    <decoration type="block" blockname="treeShortGrass" prob=".85"/>
        \\  </decorations>
        \\</biome>
        \\<biome name="desert">
        \\  <layers><layer depth="1" blockname="terrForestGround"/></layers>
        \\</biome>
        \\</biomes>
    ;
    const path = ".zdtd_test_biomes_deco.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);

    var t = try loadFromPath(std.testing.allocator, path, testDecoId, testDistantDeco, null);
    defer t.deinit();
    try std.testing.expect(t.hasDecos());

    // biomemap id → biome name for the spawn-group resolver.
    try std.testing.expectEqualStrings("pine_forest", t.nameById(3).?);
    try std.testing.expectEqualStrings("desert", t.nameById(5).?);
    try std.testing.expectEqual(@as(?[]const u8, null), t.nameById(9));

    // Biome-level group wins over the subbiome group (GetBiomeOrSubAt default).
    const pine = t.decosFor(3);
    try std.testing.expectEqual(@as(u8, 2), pine.n);
    try std.testing.expectEqual(@as(u16, 24630), pine.slice()[0].block_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.06), pine.slice()[0].prob, 1e-6);
    try std.testing.expectEqual(@as(u16, 24629), pine.slice()[1].block_id);
    // GAP 18: the subbiome's own group parses into its own set + noise window.
    const subs = t.subBiomes(3);
    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), subs[0].noise_freq, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), subs[0].noise_min, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), subs[0].noise_max, 1e-6);
    try std.testing.expectEqual(@as(u8, 1), subs[0].decos.n);
    try std.testing.expectEqual(@as(u16, 24629), subs[0].decos.slice()[0].block_id); // treeOak
    // A biome with no subbiomes reports an empty list, never a fabricated one.
    try std.testing.expectEqual(@as(usize, 0), t.subBiomes(5).len);
    try std.testing.expectEqual(@as(usize, 0), t.subBiomes(max_biomemap_id).len);
    // Grass and the unresolvable name are both dropped, never fabricated.
    for (pine.slice()) |d| {
        try std.testing.expect(d.block_id != 24700 and d.block_id != 24701);
    }
    // A biome with no <decorations> inherits nothing.
    try std.testing.expectEqual(@as(u8, 0), t.decosFor(5).n);
    // Unmapped biome ids stay empty rather than borrowing another biome.
    try std.testing.expectEqual(@as(u8, 0), t.decosFor(9).n);
    try std.testing.expectEqual(@as(u8, 0), t.decosFor(max_biomemap_id).n);
}

test "decorations parse without a distant-deco filter yields nothing" {
    const src =
        \\<biomes>
        \\<biomemap id="03" name="pine_forest"/>
        \\<biome name="pine_forest">
        \\  <decorations>
        \\    <decoration type="block" blockname="treeOak" prob=".07"/>
        \\  </decorations>
        \\</biome>
        \\</biomes>
    ;
    const path = ".zdtd_test_biomes_nodeco.xml";
    try io_fs.writeFile(path, src);
    defer io_fs.deleteFile(path);
    var t = try loadFromPath(std.testing.allocator, path, testDecoId, null, null);
    defer t.deinit();
    try std.testing.expect(!t.hasDecos());
}

test "load stock biomes.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/biomes.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p, testId, null, null);
    defer t.deinit();
    try std.testing.expect(t.loaded);
    const burnt = t.stackFor(9);
    try std.testing.expect(burnt.n >= 3);
    try std.testing.expectEqual(assignids.terr_burnt_forest_ground, burnt.layers[0].block_id);
    const pine = t.stackFor(3);
    try std.testing.expectEqual(assignids.terr_forest_ground, pine.layers[0].block_id);
    // biomemap id → name for the per-biome spawn-group resolver.
    try std.testing.expectEqualStrings("pine_forest", t.nameById(3).?);
    try std.testing.expectEqualStrings("desert", t.nameById(5).?);
    // The procedural biome field (W3) resolves sparse ids in order: the first
    // named biome in stock biomes.xml is snow (id 1), pine_forest (3) second,
    // desert (5) third.
    try std.testing.expect(t.biomeCount() >= 7);
    try std.testing.expectEqual(@as(u8, 1), t.biomeIdAt(0));
    try std.testing.expectEqual(@as(u8, 3), t.biomeIdAt(1));
    try std.testing.expectEqual(@as(u8, 5), t.biomeIdAt(2));
    try std.testing.expectEqualStrings("snow", t.nameById(1).?);
    try std.testing.expectEqualStrings("wasteland", t.nameById(8).?);
    try std.testing.expectEqualStrings("burnt_forest", t.nameById(9).?);
    try std.testing.expectEqual(@as(?[]const u8, null), t.nameById(max_biomemap_id));
    // Stock ships weather groups for exactly 5 biomes: snow 1, pine_forest 3,
    // desert 5, wasteland 8, burnt_forest 9 (ascending biomemap id here).
    try std.testing.expectEqual(@as(u8, 5), t.weather_n);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 5, 8, 9 }, t.weather_ids[0..5]);
    // Group index is per biome document order, never global: pine_forest has a
    // "fog" group that desert lacks, so their storm indices differ.
    const pine_set = &t.weather_groups[1];
    try std.testing.expectEqual(@as(u8, 11), pine_set.n);
    try std.testing.expectEqual(@as(?u8, 0), pine_set.findIndex("default"));
    try std.testing.expectEqual(@as(?u8, 4), pine_set.findIndex("stormbuild"));
    try std.testing.expectEqual(@as(?u8, 5), pine_set.findIndex("storm"));
    const desert_set = &t.weather_groups[2];
    try std.testing.expectEqual(@as(?u8, 3), desert_set.findIndex("stormbuild"));
    // duration="1.1" delay="26,36" → 1100 ticks, 26000..36000 tick gap.
    const storm = &pine_set.groups[5];
    try std.testing.expectEqual(@as(i32, 1100), storm.duration);
    try std.testing.expectEqual(@as(i32, 26000), storm.delay_lo);
    try std.testing.expectEqual(@as(i32, 36000), storm.delay_hi);
    // Every biome has a bloodMoon group (the global forced weather type).
    var i: usize = 0;
    while (i < t.weather_n) : (i += 1) {
        try std.testing.expect(t.weather_groups[i].findIndex("bloodMoon") != null);
    }
}

test "stock biomes.xml subbiomes carry the dense tree lists (GAP 18)" {
    // The GAP's core claim: pine_forest's subbiome `<decorations>` lists carry
    // the real tree probability mass (treeJuniper4m .06, treeDeadTree01 .07,
    // treeDeadPineLeaf .08) while the top-level list is .001-.007, so a cell
    // that resolves a subbiome gets stock-like density instead of ~3 objects
    // per join window. Real ids come from the maxdamage table.
    const game_dir = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    if (!io_fs.dirExists(game_dir ++ "/Data/Config")) return error.SkipZigTest;
    var md = (try maxdamage.tryLoad(std.testing.allocator, game_dir, null)) orelse return error.SkipZigTest;
    defer md.deinit();
    // Production Game merges the operator's AssignIds dump; the test uses the
    // bundled one so tree names resolve to real wire ids.
    md.tryMergeBundledAssignIds(std.testing.allocator);
    try std.testing.expect(md.idByName("treeJuniper4m") != null);
    const DecoCtx = struct {
        md: *const maxdamage.Table,
        fn lookup(ctx: ?*anyopaque, name: []const u8) ?u16 {
            return @as(*const @This(), @ptrCast(@alignCast(ctx.?))).md.idByName(name);
        }
        fn distant(ctx: ?*anyopaque, name: []const u8) bool {
            return @as(*const @This(), @ptrCast(@alignCast(ctx.?))).md.isDistantDeco(name);
        }
    };
    var deco_ctx: DecoCtx = .{ .md = &md };
    var t = try loadFromPath(std.testing.allocator, game_dir ++ "/Data/Config/biomes.xml", DecoCtx.lookup, DecoCtx.distant, &deco_ctx);
    defer t.deinit();

    const subs = t.subBiomes(3); // pine_forest
    try std.testing.expect(subs.len >= 2);
    // Sub lists carry a dense tree row (prob > .05); the sub total dominates
    // the top-level total by an order of magnitude.
    var found_dense = false;
    for (subs) |sb| {
        for (sb.decos.slice()) |d| {
            if (d.prob > 0.05) found_dense = true;
        }
    }
    try std.testing.expect(found_dense);
    var top_prob: f32 = 0;
    for (t.decosFor(3).slice()) |d| top_prob += d.prob;
    var sub_prob: f32 = 0;
    for (subs) |sb| {
        for (sb.decos.slice()) |d| sub_prob += d.prob;
    }
    try std.testing.expect(sub_prob > top_prob * 10);
    // The resolver windows come from the XML noise attrs.
    try std.testing.expect(subs[0].noise_freq > 0 and subs[0].noise_max > subs[0].noise_min);
}

const pine_weather_xml =
    \\<weather name="default" prob="83" duration="6">
    \\  <Temperature range="76,80"/>
    \\  <CloudThickness range="0,0" prob="35"/>
    \\  <CloudThickness range="10,70" prob="65"/>
    \\  <Precipitation range="0,0"/>
    \\  <Fog range="0,2"/>
    \\  <Wind range="3,22"/>
    \\</weather>
    \\<weather name="fog" prob="7">
    \\  <Temperature range="65,70"/>
    \\  <CloudThickness min="35" max="70"/>
    \\  <Fog min="17" max="27"/>
    \\</weather>
    \\<weather name="stormbuild" prob="0" duration=".2">
    \\  <Wind range="25,25"/>
    \\  <spectrum name="Stormy"/>
    \\</weather>
    \\<weather name="storm" prob="0" duration="1.1" delay="26,36">
    \\  <Wind range="40,40"/>
    \\</weather>
;

test "parseWeatherGroups pine forest shape" {
    const set = parseWeatherGroups(pine_weather_xml);
    try std.testing.expectEqual(@as(u8, 4), set.n);
    try std.testing.expectEqualStrings("default", set.groups[0].name());
    try std.testing.expectEqual(@as(?u8, 3), set.findIndex("storm"));
    try std.testing.expectEqual(@as(?u8, null), set.findIndex("rainheavy"));
    // 83 + 7 + 0 + 0 = 90, normalized by 90 + 1e-6.
    try std.testing.expectApproxEqAbs(@as(f32, 83.0 / 90.0), set.groups[0].prob, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0 / 90.0), set.groups[1].prob, 1e-5);
    try std.testing.expectEqual(@as(f32, 0), set.groups[3].prob);
    // Two CloudThickness entries, weights normalized over 35 + 65.
    const cloud = set.groups[0].rangeSlice(2);
    try std.testing.expectEqual(@as(usize, 2), cloud.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), cloud[0].weight, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), cloud[1].weight, 1e-5);
    try std.testing.expectEqual(@as(f32, 10), cloud[1].lo);
    try std.testing.expectEqual(@as(f32, 70), cloud[1].hi);
    // Legacy min=/max= form is equivalent to range=.
    const fog_cloud = set.groups[1].rangeSlice(2);
    try std.testing.expectEqual(@as(f32, 35), fog_cloud[0].lo);
    try std.testing.expectEqual(@as(f32, 70), fog_cloud[0].hi);
    // Absent condition: stock rolls 0 for it, so no range entry is synthesized.
    try std.testing.expectEqual(@as(usize, 0), set.groups[1].rangeSlice(3).len);
    // duration is XML hours * 1000; ".2" → 200 ticks.
    try std.testing.expectEqual(@as(i32, 200), set.groups[2].duration);
    try std.testing.expectEqual(@as(i32, 1100), set.groups[3].duration);
    try std.testing.expectEqual(@as(i32, 26000), set.groups[3].delay_lo);
    // Params carry the raw 0..100 XML scale: the client divides by 100 in
    // BiomeWeather::FogPercent and WeatherManager::GetCurrentCloudThicknessPercent.
    try std.testing.expectEqual(@as(f32, 40), set.groups[3].rangeSlice(3)[0].lo);
}

test "parseWeatherGroups defaults and malformed input" {
    // No attributes: name "" (matches nothing), prob 1, duration 3 hours.
    const bare = parseWeatherGroups("<weather><Fog/></weather>");
    try std.testing.expectEqual(@as(u8, 1), bare.n);
    try std.testing.expectEqual(@as(i32, 3000), bare.groups[0].duration);
    try std.testing.expectApproxEqAbs(@as(f32, 1), bare.groups[0].prob, 1e-5);
    // Condition defaults: 0..100, Temperature -50..150.
    const fog = bare.groups[0].rangeSlice(4);
    try std.testing.expectEqual(@as(f32, 0), fog[0].lo);
    try std.testing.expectEqual(@as(f32, 100), fog[0].hi);
    // Self-closing group, then a normal one: the scan must not swallow the rest.
    const mixed = parseWeatherGroups("<weather/><weather name=\"storm\"><Wind range=\"1,2\"/></weather>");
    try std.testing.expectEqual(@as(u8, 2), mixed.n);
    try std.testing.expectEqual(@as(?u8, 1), mixed.findIndex("storm"));
    // Unclosed group is dropped, not read past the end.
    try std.testing.expectEqual(@as(u8, 0), parseWeatherGroups("<weather name=\"x\">").n);
    // Junk numbers fall back to the stock defaults instead of NaN/inf.
    const junk = parseWeatherGroups("<weather prob=\"nan\" duration=\"1e40\"><Wind range=\"inf,2\"/></weather>");
    try std.testing.expectApproxEqAbs(@as(f32, 1), junk.groups[0].prob, 1e-5);
    try std.testing.expectEqual(@as(i32, 3000), junk.groups[0].duration);
    try std.testing.expectEqual(@as(f32, 0), junk.groups[0].rangeSlice(3)[0].lo);
    // A finite but absurd duration saturates instead of trapping @trunc.
    const huge = parseWeatherGroups("<weather duration=\"3000000\"/>");
    try std.testing.expectEqual(@as(i32, 2_000_000_000), huge.groups[0].duration);
    // A name longer than the buffer is stored as unnamed so it matches no query.
    const long = parseWeatherGroups("<weather name=\"a_very_long_group_name\"/>");
    try std.testing.expectEqual(@as(usize, 0), long.groups[0].name().len);
    // Groups beyond the cap are dropped from the tail; kept ordinals stay stable.
    var buf: [1024]u8 = undefined;
    var o: usize = 0;
    var k: usize = 0;
    while (k < max_weather_groups + 4) : (k += 1) {
        const s = try std.fmt.bufPrint(buf[o..], "<weather name=\"g{d}\"/>", .{k});
        o += s.len;
    }
    const capped = parseWeatherGroups(buf[0..o]);
    try std.testing.expectEqual(@as(u8, max_weather_groups), capped.n);
    try std.testing.expectEqualStrings("g0", capped.groups[0].name());
}
