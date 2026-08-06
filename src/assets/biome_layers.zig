//! Stock biomes.xml → per-biomemap-id terrain column layers (top → bottom).
//! Subbiomes ignored (noise); default biome layers only. Block names resolve
//! via AssignIds (idByName), never XML ordinals.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const assignids = @import("assignids_comptime.zig");

pub const max_layers: usize = 8;
pub const max_biomemap_id: usize = 50;

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

/// Wire snapshot defaults from biomes.xml weather name="default" (mid of first range).
/// Slot order matches WeatherPackage: temp, precip, cloud, wind, fog.
pub const WeatherDefaults = struct {
    biome_id: u8 = 0,
    params: [5]f32 = .{ 70, 0, 0.15, 0.1, 0.04 },
};

pub const max_weather_biomes: usize = 16;

pub const Table = struct {
    /// biomemap id → fill stack (missing → default_stack).
    stacks: [max_biomemap_id]Stack = [_]Stack{.{}} ** max_biomemap_id,
    default_stack: Stack = defaultStack(),
    /// Per biomemap id weather params from XML default group (missing = unset).
    weather: [max_biomemap_id]?[5]f32 = .{null} ** max_biomemap_id,
    /// Ordered biomemap ids that have weather (for NetPackageWeather body).
    weather_ids: [max_weather_biomes]u8 = .{0} ** max_weather_biomes,
    weather_n: u8 = 0,
    /// biomemap id → distant-decoration set (empty when the biome declares none,
    /// or when nothing in it resolved: no fabricated species).
    decos: [max_biomemap_id]DecoSet = [_]DecoSet{.{}} ** max_biomemap_id,
    loaded: bool = false,

    pub fn deinit(self: *Table) void {
        self.* = .{};
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

    /// True when at least one biome resolved a distant-decoration species.
    pub fn hasDecos(self: *const Table) bool {
        for (self.decos) |d| {
            if (d.n > 0) return true;
        }
        return false;
    }

    /// Fill out[] with WeatherDefaults for each biomemap that has weather XML.
    /// Returns count written (0 if none loaded; caller may omit Weather package).
    pub fn weatherPackages(self: *const Table, out: []WeatherDefaults) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.weather_n and n < out.len) : (i += 1) {
            const id = self.weather_ids[i];
            if (id >= max_biomemap_id) continue;
            const p = self.weather[id] orelse continue;
            out[n] = .{ .biome_id = id, .params = p };
            n += 1;
        }
        return n;
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
            if (layer.depth == 0) {
                // Fill until only fixed_after[li+1] blocks remain below.
                const reserve: i32 = @intCast(fixed_after[li + 1]);
                while (y >= reserve) : (y -= 1) {
                    out[@intCast(y)] = layer.block_id;
                    if (y == 0) {
                        y = -1;
                        break;
                    }
                }
            } else {
                var left: u16 = layer.depth;
                while (left > 0 and y >= 0) : (left -= 1) {
                    out[@intCast(y)] = layer.block_id;
                    y -= 1;
                }
            }
        }
        // Any gap below (malformed XML): stone, y=0 bedrock if empty.
        while (y >= 0) : (y -= 1) {
            out[@intCast(y)] = if (y == 0) assignids.terr_bedrock else assignids.terr_stone;
        }
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
    if (std.mem.indexOfScalar(u8, blockname, ',')) |c| return std.mem.trim(u8, blockname[0..c], " \t");
    return std.mem.trim(u8, blockname, " \t");
}

fn parseDepth(s: []const u8) ?u16 {
    if (s.len == 1 and s[0] == '*') return 0;
    return xml.parseU16(s);
}

/// Midpoint of first `range="lo,hi"` (or single value) on a weather child tag.
fn firstRangeMid(body: []const u8, tag: []const u8) ?f32 {
    var needle_buf: [48]u8 = undefined;
    if (tag.len + 1 > needle_buf.len) return null;
    needle_buf[0] = '<';
    @memcpy(needle_buf[1..][0..tag.len], tag);
    const needle = needle_buf[0 .. tag.len + 1];
    const ti = std.mem.indexOf(u8, body, needle) orelse return null;
    const range_s = xml.attr(body, ti, "range") orelse return null;
    if (std.mem.indexOfScalar(u8, range_s, ',')) |c| {
        const lo = xml.parseF32(std.mem.trim(u8, range_s[0..c], " \t")) orelse return null;
        const hi = xml.parseF32(std.mem.trim(u8, range_s[c + 1 ..], " \t")) orelse return null;
        return (lo + hi) * 0.5;
    }
    return xml.parseF32(std.mem.trim(u8, range_s, " \t"));
}

/// Parse weather name="default" (or first weather group) into param slots.
/// XML units: Temp F, others 0..100 → wire uses same numeric scale stock sends.
fn parseWeatherDefaults(body: []const u8) ?[5]f32 {
    // Prefer <weather name="default" ...> … </weather>
    var wi: usize = 0;
    var weather_body: ?[]const u8 = null;
    while (wi < body.len) {
        const at = std.mem.indexOfPos(u8, body, wi, "<weather") orelse break;
        const gt = std.mem.indexOfPos(u8, body, at, ">") orelse break;
        const name_a = xml.attr(body, at, "name");
        const close = std.mem.indexOfPos(u8, body, gt, "</weather>") orelse break;
        const inner = body[gt + 1 .. close];
        if (name_a) |nm| {
            if (std.mem.eql(u8, nm, "default")) {
                weather_body = inner;
                break;
            }
        } else if (weather_body == null) {
            weather_body = inner;
        }
        wi = close + 10;
    }
    const wb = weather_body orelse return null;
    const temp = firstRangeMid(wb, "Temperature") orelse 70;
    const precip = firstRangeMid(wb, "Precipitation") orelse 0;
    const cloud = firstRangeMid(wb, "CloudThickness") orelse 15;
    const wind = firstRangeMid(wb, "Wind") orelse 10;
    const fog = firstRangeMid(wb, "Fog") orelse 1;
    // Stock wire param scale: temp F as-is; precip/cloud/wind/fog as 0..1 fractions of 100.
    return .{
        temp,
        precip * 0.01,
        cloud * 0.01,
        wind * 0.01,
        fog * 0.01,
    };
}

fn parseStackBody(body: []const u8, id_by_name: *const fn (?*anyopaque, []const u8) ?u16, ctx: ?*anyopaque) Stack {
    var st: Stack = .{};
    // Prefer first <layers>…</layers> in the biome (often inside the first subbiome).
    const layers_body: []const u8 = blk: {
        if (std.mem.indexOf(u8, body, "<layers")) |ls| {
            const gt = std.mem.indexOfPos(u8, body, ls, ">") orelse break :blk body;
            const close = std.mem.indexOfPos(u8, body, gt, "</layers>") orelse break :blk body;
            break :blk body[gt + 1 .. close];
        }
        break :blk body;
    };
    var i: usize = 0;
    while (i < layers_body.len and st.n < max_layers) {
        const li = std.mem.indexOfPos(u8, layers_body, i, "<layer") orelse break;
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
/// resolves to wherever no subbiome noise hits, which is most of the biome.
/// zdtd does not evaluate subbiome noise, so the first subbiome's group is only
/// used as a fallback when the biome declares none of its own (the same
/// approximation `parseStackBody` already makes for `<layers>`).
fn decorationsBody(body: []const u8) ?[]const u8 {
    var first_in_sub: ?[]const u8 = null;
    var i: usize = 0;
    var sub_end: usize = 0;
    while (i < body.len) {
        const di = std.mem.indexOfPos(u8, body, i, "<decorations>") orelse break;
        const close = std.mem.indexOfPos(u8, body, di, "</decorations>") orelse break;
        const inner = body[di + 13 .. close];
        // Is this group inside a <subbiome> that has not closed yet?
        if (di >= sub_end) {
            sub_end = 0;
            var si: usize = 0;
            while (std.mem.indexOfPos(u8, body, si, "<subbiome")) |sb| {
                if (sb > di) break;
                const se = std.mem.indexOfPos(u8, body, sb, "</subbiome>") orelse body.len;
                if (sb < di and di < se) {
                    sub_end = se;
                    break;
                }
                si = sb + 9;
            }
        }
        if (sub_end == 0) return inner;
        if (first_in_sub == null) first_in_sub = inner;
        i = close + 14;
    }
    return first_in_sub;
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
        const di = std.mem.indexOfPos(u8, decos, i, "<decoration") orelse break;
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
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var table: Table = .{};
    // biomemap id → name (arena-free: copy into fixed buffers on stack via hashmap of slices into clean)
    var name_by_id: [max_biomemap_id]?[]const u8 = .{null} ** max_biomemap_id;
    var i: usize = 0;
    while (i < clean.len) {
        const mi = std.mem.indexOfPos(u8, clean, i, "<biomemap") orelse break;
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

    // Parse each <biome name="..."> … </biome> for layer stack + default weather.
    var stacks_by_name: std.StringHashMapUnmanaged(Stack) = .{};
    defer stacks_by_name.deinit(allocator);
    var weather_by_name: std.StringHashMapUnmanaged([5]f32) = .{};
    defer weather_by_name.deinit(allocator);
    var decos_by_name: std.StringHashMapUnmanaged(DecoSet) = .{};
    defer decos_by_name.deinit(allocator);
    const deco_ok = is_distant_deco orelse noDistantDeco;
    i = 0;
    while (i < clean.len) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<biome ") orelse break;
        const bname = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
        const close = std.mem.indexOfPos(u8, clean, gt, "</biome>") orelse break;
        const body = clean[gt + 1 .. close];
        // First <layers> group (top-level or first subbiome).
        const st = parseStackBody(body, id_by_name, ctx);
        if (st.n > 0) {
            try stacks_by_name.put(allocator, bname, st);
        }
        if (parseWeatherDefaults(body)) |wp| {
            try weather_by_name.put(allocator, bname, wp);
        }
        const ds = parseDecoBody(body, id_by_name, deco_ok, ctx);
        if (ds.n > 0) {
            try decos_by_name.put(allocator, bname, ds);
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
        if (name_by_id[id]) |nm| {
            if (stacks_by_name.get(nm)) |st| {
                table.stacks[id] = st;
            }
            if (decos_by_name.get(nm)) |ds| {
                table.decos[id] = ds;
            }
            if (weather_by_name.get(nm)) |wp| {
                table.weather[id] = wp;
                if (table.weather_n < max_weather_biomes) {
                    table.weather_ids[table.weather_n] = @intCast(id);
                    table.weather_n += 1;
                }
            }
        }
    }
    // water / underwater: keep default (no land layers); surface gen still uses heights.
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
    if (paths.override_dirs.len == 0) {
        return loadFromPath(allocator, base, id_by_name, is_distant_deco, ctx) catch null;
    }
    const merged = try paths.readConfigXml(allocator, "biomes.xml", game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
    const cp = ".zdtd_cfg_cache/biomes.xml";
    {
        io_fs.writeFile(allocator, cp, merged) catch return loadFromPath(allocator, base, id_by_name, is_distant_deco, ctx) catch null;
    }
    return loadFromPath(allocator, cp, id_by_name, is_distant_deco, ctx) catch null;
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
    try io_fs.writeFile(std.testing.allocator, path, src);
    defer io_fs.deleteFile(std.testing.allocator, path);

    var t = try loadFromPath(std.testing.allocator, path, testDecoId, testDistantDeco, null);
    defer t.deinit();
    try std.testing.expect(t.hasDecos());

    // Biome-level group wins over the subbiome group (GetBiomeOrSubAt default).
    const pine = t.decosFor(3);
    try std.testing.expectEqual(@as(u8, 2), pine.n);
    try std.testing.expectEqual(@as(u16, 24630), pine.slice()[0].block_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.06), pine.slice()[0].prob, 1e-6);
    try std.testing.expectEqual(@as(u16, 24629), pine.slice()[1].block_id);
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
    try io_fs.writeFile(std.testing.allocator, path, src);
    defer io_fs.deleteFile(std.testing.allocator, path);
    var t = try loadFromPath(std.testing.allocator, path, testDecoId, null, null);
    defer t.deinit();
    try std.testing.expect(!t.hasDecos());
}

test "load stock biomes.xml when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/biomes.xml";
    const t = loadFromPath(std.testing.allocator, p, testId, null, null) catch return error.SkipZigTest;
    try std.testing.expect(t.loaded);
    const burnt = t.stackFor(9);
    try std.testing.expect(burnt.n >= 3);
    try std.testing.expectEqual(assignids.terr_burnt_forest_ground, burnt.layers[0].block_id);
    const pine = t.stackFor(3);
    try std.testing.expectEqual(assignids.terr_forest_ground, pine.layers[0].block_id);
    // Weather defaults from XML (pine_forest temp ~78 F mid of 76..80).
    try std.testing.expect(t.weather_n >= 4);
    const pine_w = t.weather[3] orelse return error.TestUnexpectedResult;
    try std.testing.expect(pine_w[0] > 70 and pine_w[0] < 85);
    var pkgs: [max_weather_biomes]WeatherDefaults = undefined;
    const n = t.weatherPackages(&pkgs);
    try std.testing.expect(n >= 4);
    try std.testing.expect(pkgs[0].biome_id != 0 or pkgs[1].biome_id != 0);
}
