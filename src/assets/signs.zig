//! Prefab sign libraries (*_signs.xml under Data/Prefabs) for NetPackageSignDataResponse.
//! Catalog data only; the wire encode lives in wire/stock_sign.zig.
//! Full SignData: guid + name + next_* ids + the ordered layer stack
//! (research gameplay/signs.md §1-2; IL-verified field orders). Layers nest
//! through GroupSignLayer; warps ride each layer's shared tail.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const io_fs = @import("../util/io_fs.zig");
const stock_paths = @import("../util/stock_paths.zig");

pub const max_signs: usize = 4096;
/// Cap on layers per sign (stock Default Sign carries ~30; groups nest).
pub const max_layers: usize = 256;
/// Cap on warps per layer.
pub const max_warps: usize = 16;

/// Binary TypeId bytes (SignLayer/LayerType + SignWarp/WarpType enum order).
pub const layer_group: u8 = 0;
pub const layer_text: u8 = 1;
pub const layer_polygon: u8 = 2;
pub const layer_noise: u8 = 3;
pub const warp_skew: u8 = 0;
pub const warp_bulge: u8 = 1;
pub const warp_twirl: u8 = 2;
pub const warp_kaleido: u8 = 3;
pub const warp_perspective: u8 = 4;
pub const warp_arc: u8 = 5;
pub const warp_stretch: u8 = 6;
pub const warp_grid: u8 = 7;

/// Render mode byte (SignRenderSettings/Mode enum order).
pub const mode_color_only: u8 = 0;
pub const mode_color_and_mask: u8 = 1;

pub const Warp = struct {
    kind: u8 = warp_skew,
    // Union payload by kind (floats; sides/mode as bit-cast i32):
    // skew: amount(vec2) rotation(f32); bulge: offset(vec2) amount;
    // twirl: offset(vec2) amount frequency; kaleido: offset(vec2) sides(i32)
    //   rotation offsetScale; perspective: rotation(vec3) strength;
    // arc: rotation radius width; stretch: offset(vec2) rotation distance
    //   width height(5th); grid: mode(i32) offset(vec2) rotation scale(vec2).
    f: [6]f32 = .{0} ** 6,
};

pub const Layer = struct {
    kind: u8 = layer_polygon,
    name: []const u8 = "",
    pos: [2]f32 = .{ 0, 0 },
    rot: f32 = 0,
    scale: [2]f32 = .{ 1, 1 },
    /// RGBA 0..1 (from the #RRGGBBAA color attr).
    color: [4]f32 = .{ 1, 1, 1, 1 },
    mode: u8 = mode_color_only,
    warps: []const Warp = &.{},
    // Subclass payload (InternalWrite order):
    // group: offsetTarget(u8) softnessOffset dilateOffset colorMode(u8) +
    //   nested layers; text: font text direction spacing softness dilate;
    // polygon: sides(i32) smoothness starify softness dilate frequency
    //   shapeMode(u8); noise: seed(i32) detail(i32) softness dilate fade.
    text_a: []const u8 = "",
    text_b: []const u8 = "",
    f: [7]f32 = .{0} ** 7,
    i: [2]i32 = .{ 0, 0 },
    b: [2]u8 = .{ 0, 0 },
    children: []const Layer = &.{},
};

pub const SignEntry = struct {
    /// Prefab library id (filename without `_signs.xml`).
    library: []const u8,
    name: []const u8,
    guid: [16]u8,
    next_poly: i32 = 0,
    next_text: i32 = 0,
    next_noise: i32 = 0,
    next_group: i32 = 0,
    /// .NET DateTime ticks (UTC); 0 is fine for wire.
    modified_ticks: i64 = 0,
    layers: []const Layer = &.{},
};

pub const Catalog = struct {
    entries: []SignEntry = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Catalog) void {
        arena_util.destroyHolder(&self.arena_ptr);
        self.* = .{};
    }

    pub fn empty() Catalog {
        return .{};
    }
};

/// Parse UUID "aabbccdd-eeff-0011-2233-445566778899" to .NET Guid.TryWriteBytes order.
pub fn guidFromHyphenString(s: []const u8, out: *[16]u8) !void {
    // Expected 8-4-4-4-12 hex with hyphens → 36 chars.
    var hex: [32]u8 = undefined;
    var hi: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (hi >= 32) return error.BadGuid;
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.BadGuid,
        };
        if (hi % 2 == 0) {
            hex[hi / 2] = v << 4;
        } else {
            hex[hi / 2] |= v;
        }
        hi += 1;
    }
    if (hi != 32) return error.BadGuid;
    // .NET Guid layout: Data1 LE, Data2 LE, Data3 LE, Data4[8] as-is.
    // String groups: tttttttt-tttt-tttt-cccc-nnnnnnnnnnnn
    // bytes raw big-endian groups → rearrange:
    const raw = hex;
    out[0] = raw[3];
    out[1] = raw[2];
    out[2] = raw[1];
    out[3] = raw[0];
    out[4] = raw[5];
    out[5] = raw[4];
    out[6] = raw[7];
    out[7] = raw[6];
    @memcpy(out[8..16], raw[8..16]);
}

fn attrValue(open_tag: []const u8, key: []const u8) ?[]const u8 {
    // key="value"
    var needle_buf: [64]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    @memcpy(needle_buf[0..key.len], key);
    needle_buf[key.len] = '=';
    needle_buf[key.len + 1] = '"';
    const needle = needle_buf[0 .. key.len + 2];
    // Anchor on a preceding delimiter: `prob=` must not match `force_prob=`.
    var from: usize = 0;
    const i = while (std.mem.findPos(u8, open_tag, from, needle)) |k| {
        if (k > 0 and (open_tag[k - 1] == ' ' or open_tag[k - 1] == '\t' or
            open_tag[k - 1] == '\n' or open_tag[k - 1] == '\r')) break k;
        from = k + 1;
    } else return null;
    const start = i + needle.len;
    const end = std.mem.findPos(u8, open_tag, start, "\"") orelse return null;
    return open_tag[start..end];
}

fn parseI32Attr(open_tag: []const u8, key: []const u8, default: i32) i32 {
    const v = attrValue(open_tag, key) orelse return default;
    return std.fmt.parseInt(i32, v, 10) catch default;
}

/// Parse a stock `modified="yyyy-MM-dd HH:mm:ssZ"` timestamp into .NET
/// DateTime ticks (100 ns since 0001-01-01). Returns 0 when the shape is
/// wrong rather than guessing: the writer sends the raw ticks and a wrong
/// date is worse than the 0 the wire already sends today.
fn parseModifiedTicks(s: []const u8) i64 {
    // "2026-02-27 13:43:31Z" (19 chars + Z).
    if (s.len != 20 or s[19] != 'Z') return 0;
    const digits = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
    for (digits) |i| {
        if (s[i] < '0' or s[i] > '9') return 0;
    }
    if (s[4] != '-' or s[7] != '-' or s[10] != ' ' or s[13] != ':' or s[16] != ':') return 0;
    const y: i64 = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const mo: i64 = std.fmt.parseInt(i64, s[5..7], 10) catch return 0;
    const d: i64 = std.fmt.parseInt(i64, s[8..10], 10) catch return 0;
    const h: i64 = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const mi: i64 = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const sec: i64 = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;
    if (y < 1 or mo < 1 or mo > 12 or d < 1 or h > 23 or mi > 59 or sec > 59) return 0;
    if (d > std.time.epoch.getDaysInMonth(@intCast(y), @enumFromInt(mo))) return 0;
    // Days from civil date (Howard Hinnant's algorithm) → .NET ticks.
    var yy = y;
    if (mo <= 2) yy -= 1;
    const era: i64 = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe: i64 = yy - era * 400;
    const mp: i64 = @mod(mo - 3, 12);
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    // .NET epoch 0001-01-01 is 719162 days before Unix 1970-01-01.
    const unix_days = days;
    const ticks: i64 = (unix_days + 719162) * 86400 * 10000000 + (h * 3600 + mi * 60 + sec) * 10000000;
    return ticks;
}

/// Load all `*_signs.xml` under prefabs_root (e.g. Data/Prefabs) plus, when
/// `default_signs_path` is set, the stock `Data/Config/signs.xml` default
/// `[D]` library (which carries the mandatory zero-guid Default Sign the
/// client needs when placing a new canvas block; prefab libraries only cover
/// the world). A missing file is skipped like a missing Prefabs tree.
pub fn loadFromPrefabsRoot(
    allocator: std.mem.Allocator,
    prefabs_root: []const u8,
    default_signs_path: ?[]const u8,
) !Catalog {
    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var list: std.ArrayList(SignEntry) = .empty;
    defer list.deinit(allocator);

    if (default_signs_path) |dsp| {
        // Parsed first so "[D]" sorts ahead of the prefab libraries.
        try parseSignsFile(allocator, arena, dsp, "[D]", &list);
    }
    try walkSigns(allocator, arena, prefabs_root, &list);

    // readdir order is OS/filesystem dependent; wire batches iterate this
    // slice, so sort for seed-stable SignDataResponse across machines (DST).
    std.mem.sort(SignEntry, list.items, {}, struct {
        fn less(_: void, a: SignEntry, b: SignEntry) bool {
            const o = std.mem.order(u8, a.library, b.library);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    const entries = try arena.alloc(SignEntry, list.items.len);
    @memcpy(entries, list.items);
    return .{ .entries = entries, .arena_ptr = arena_holder };
}

fn walkSigns(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    list: *std.ArrayList(SignEntry),
) !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Missing Prefabs tree is normal without a full game install; other open
    // failures must not look like "no sign libraries".
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.debug.print("zdtd: open signs dir '{s}' failed: {s}\n", .{ dir_path, @errorName(err) });
            return;
        },
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        var child_buf: [2048]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const kind = try io_fs.entryKind(dir, io, entry);
        if (kind == .directory) {
            try walkSigns(gpa, arena, child, list);
            continue;
        }
        if (kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "_signs.xml")) continue;
        const lib = entry.name[0 .. entry.name.len - "_signs.xml".len];
        try parseSignsFile(gpa, arena, child, lib, list);
        if (list.items.len >= max_signs) return;
    }
}

fn parseSignsFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    library: []const u8,
    list: *std.ArrayList(SignEntry),
) !void {
    // Skip one unreadable library file rather than aborting the whole catalog,
    // but log non-missing failures so a permission/I/O issue is not invisible.
    const raw = io_fs.readFileAll(gpa, path) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print("zdtd: read signs '{s}' failed: {s}\n", .{ path, @errorName(err) }),
        }
        return;
    };
    defer gpa.free(raw);

    const lib_owned = try arena.dupe(u8, library);
    var i: usize = 0;
    while (i < raw.len and list.items.len < max_signs) {
        const si = std.mem.findPos(u8, raw, i, "<sign ") orelse break;
        const gt = std.mem.findPos(u8, raw, si, ">") orelse break;
        const tag = raw[si .. gt + 1];
        // Self-closing `<sign .../>` carries no layers; the body form runs to
        // `</sign>`.
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!(gt > si and raw[gt - 1] == '/')) {
            const close = std.mem.findPos(u8, raw, gt, "</sign>") orelse break;
            body = raw[gt + 1 .. close];
            next_i = close + 7;
        }
        i = next_i;

        const guid_s = attrValue(tag, "guid") orelse continue;
        var guid: [16]u8 = undefined;
        guidFromHyphenString(guid_s, &guid) catch continue;
        const name_s = attrValue(tag, "name") orelse "";
        const layers = parseLayers(arena, body) catch &.{};
        try list.append(gpa, .{
            .library = lib_owned,
            .name = try arena.dupe(u8, name_s),
            .guid = guid,
            // Stock `SignData.lastModified` (written with format "u" =
            // "yyyy-MM-dd HH:mm:ssZ"); absent/unparseable stays 0, which the
            // wire already sends today.
            .modified_ticks = if (attrValue(tag, "modified")) |m| parseModifiedTicks(m) else 0,
            .next_poly = parseI32Attr(tag, "next_poly_id", 0),
            .next_text = parseI32Attr(tag, "next_text_id", 0),
            .next_noise = parseI32Attr(tag, "next_noise_id", 0),
            .next_group = parseI32Attr(tag, "next_group_id", 0),
            .layers = layers,
        });
    }
}

/// Parse one `<sign>` body's top-level `<layer>` elements (recursing into
/// groups). Warps ride each layer's shared tail. Unknown layer/warp types
/// are skipped (fail closed); a group with no parseable children still
/// counts as a group layer.
fn parseLayers(arena: std.mem.Allocator, body: []const u8) ![]Layer {
    var list: std.ArrayList(Layer) = .empty;
    defer list.deinit(arena);
    var i: usize = 0;
    while (i < body.len and list.items.len < max_layers) {
        const li = std.mem.findPos(u8, body, i, "<layer") orelse break;
        const gt = std.mem.findPos(u8, body, li, ">") orelse break;
        const tag = body[li .. gt + 1];
        if (gt > li and body[gt - 1] == '/') {
            if (parseLayer(arena, tag, "")) |l| try list.append(arena, l) else {
                // Unknown type: skip the element, keep the rest.
            }
            i = gt + 1;
            continue;
        }
        // Matched close: nested group children carry their own </layer>,
        // so count depth from the open tag.
        const close = matchLayerClose(body, gt) orelse break;
        if (parseLayer(arena, tag, body[gt + 1 .. close])) |l| try list.append(arena, l) else {
            // Unknown type: skip the element, keep the rest.
        }
        i = close + 8;
    }
    return list.toOwnedSlice(arena);
}

/// Offset of the `</layer>` matching the element whose open tag ends at
/// `gt` (depth-counted; group children nest). Null when unbalanced.
fn matchLayerClose(body: []const u8, gt: usize) ?usize {
    var depth: usize = 1;
    var i: usize = gt + 1;
    while (i < body.len) {
        const open = std.mem.findPos(u8, body, i, "<layer");
        const close = std.mem.findPos(u8, body, i, "</layer>") orelse return null;
        if (open != null and open.? < close) {
            // Self-closing children do not nest.
            const ogt = std.mem.findPos(u8, body, open.?, ">") orelse return null;
            if (ogt <= open.? or body[ogt - 1] != '/') depth += 1;
            i = ogt + 1;
        } else {
            depth -= 1;
            if (depth == 0) return close;
            i = close + 8;
        }
    }
    return null;
}

fn parseLayer(arena: std.mem.Allocator, tag: []const u8, body: []const u8) ?Layer {
    const t = attrValue(tag, "type") orelse return null;
    var l: Layer = .{};
    if (std.mem.eql(u8, t, "GroupSignLayer")) {
        l.kind = layer_group;
        l.b[0] = parseOffsetTarget(attrValue(tag, "offsetTarget"));
        l.f[0] = parseF32Attr(tag, "softnessOffset");
        l.f[1] = parseF32Attr(tag, "dilateOffset");
        l.b[1] = parseColorMode(attrValue(tag, "colorMode"));
        l.children = parseLayers(arena, body) catch &.{};
    } else if (std.mem.eql(u8, t, "TextSignLayer")) {
        l.kind = layer_text;
        l.text_a = attrValue(tag, "font") orelse "";
        l.text_b = attrValue(tag, "text") orelse "";
        l.f[0] = parseF32Attr(tag, "direction");
        l.f[1] = parseF32Attr(tag, "spacing");
        l.f[2] = parseF32Attr(tag, "softness");
        l.f[3] = parseF32Attr(tag, "dilate");
    } else if (std.mem.eql(u8, t, "PolygonSignLayer")) {
        l.kind = layer_polygon;
        l.i[0] = parseI32Attr(tag, "sides", 0);
        l.f[0] = parseF32Attr(tag, "smoothness");
        l.f[1] = parseF32Attr(tag, "starify");
        l.f[2] = parseF32Attr(tag, "softness");
        l.f[3] = parseF32Attr(tag, "dilate");
        l.f[4] = parseF32Attr(tag, "frequency");
        l.b[0] = parseShapeMode(attrValue(tag, "shapeMode"));
    } else if (std.mem.eql(u8, t, "NoiseSignLayer")) {
        l.kind = layer_noise;
        l.i[0] = parseI32Attr(tag, "seed", 0);
        l.i[1] = parseI32Attr(tag, "detail", 0);
        l.f[0] = parseF32Attr(tag, "softness");
        l.f[1] = parseF32Attr(tag, "dilate");
        l.f[2] = parseF32Attr(tag, "fade");
    } else return null;
    // Shared head: name (absent = ""), transform, render settings.
    l.name = attrValue(tag, "name") orelse "";
    if (attrValue(tag, "pos")) |v| parseVec2(v, &l.pos);
    l.rot = parseF32Attr(tag, "rot");
    if (attrValue(tag, "scale")) |v| parseVec2(v, &l.scale);
    if (attrValue(tag, "color")) |v| parseColor(v, &l.color);
    l.mode = parseMode(attrValue(tag, "mode"));
    l.warps = parseWarps(arena, body) catch &.{};
    // Arena-dupe the retained strings (tag/body point into the freed raw).
    l.name = arena.dupe(u8, l.name) catch "";
    l.text_a = arena.dupe(u8, l.text_a) catch "";
    l.text_b = arena.dupe(u8, l.text_b) catch "";
    return l;
}

fn parseWarps(arena: std.mem.Allocator, body: []const u8) ![]Warp {
    var list: std.ArrayList(Warp) = .empty;
    defer list.deinit(arena);
    var i: usize = 0;
    while (i < body.len and list.items.len < max_warps) {
        const wi = std.mem.findPos(u8, body, i, "<warp") orelse break;
        const gt = std.mem.findPos(u8, body, wi, ">") orelse break;
        const tag = body[wi .. gt + 1];
        // Warps are self-closing in stock files; a body form advances past
        // its close tag all the same.
        if (gt > wi and body[gt - 1] == '/') {
            i = gt + 1;
        } else {
            const close = std.mem.findPos(u8, body, gt, "</warp>") orelse break;
            i = close + 7;
        }
        if (parseWarp(tag)) |w| try list.append(arena, w);
    }
    return list.toOwnedSlice(arena);
}

fn parseWarp(tag: []const u8) ?Warp {
    const t = attrValue(tag, "type") orelse return null;
    var w: Warp = .{};
    if (std.mem.eql(u8, t, "SkewWarp")) {
        w.kind = warp_skew;
        if (attrValue(tag, "amount")) |v| parseVec2(v, w.f[0..2]);
        w.f[2] = parseF32Attr(tag, "rotation");
    } else if (std.mem.eql(u8, t, "BulgeWarp")) {
        w.kind = warp_bulge;
        if (attrValue(tag, "offset")) |v| parseVec2(v, w.f[0..2]);
        w.f[2] = parseF32Attr(tag, "amount");
    } else if (std.mem.eql(u8, t, "TwirlWarp")) {
        w.kind = warp_twirl;
        if (attrValue(tag, "offset")) |v| parseVec2(v, w.f[0..2]);
        w.f[2] = parseF32Attr(tag, "amount");
        w.f[3] = parseF32Attr(tag, "frequency");
    } else if (std.mem.eql(u8, t, "KaleidoWarp")) {
        w.kind = warp_kaleido;
        if (attrValue(tag, "offset")) |v| parseVec2(v, w.f[0..2]);
        w.f[2] = @floatFromInt(parseI32Attr(tag, "sides", 0));
        w.f[3] = parseF32Attr(tag, "rotation");
        w.f[4] = parseF32Attr(tag, "offsetScale");
    } else if (std.mem.eql(u8, t, "PerspectiveWarp")) {
        w.kind = warp_perspective;
        if (attrValue(tag, "rotation")) |v| parseVec3(v, w.f[0..3]);
        w.f[3] = parseF32Attr(tag, "strength");
    } else if (std.mem.eql(u8, t, "ArcWarp")) {
        w.kind = warp_arc;
        w.f[0] = parseF32Attr(tag, "rotation");
        w.f[1] = parseF32Attr(tag, "radius");
        w.f[2] = parseF32Attr(tag, "width");
    } else if (std.mem.eql(u8, t, "StretchWarp")) {
        w.kind = warp_stretch;
        if (attrValue(tag, "offset")) |v| parseVec2(v, w.f[0..2]);
        w.f[2] = parseF32Attr(tag, "rotation");
        w.f[3] = parseF32Attr(tag, "distance");
        w.f[4] = parseF32Attr(tag, "width");
        w.f[5] = parseF32Attr(tag, "height");
    } else if (std.mem.eql(u8, t, "GridWarp")) {
        w.kind = warp_grid;
        w.f[0] = @floatFromInt(parseGridMode(attrValue(tag, "mode")));
        if (attrValue(tag, "offset")) |v| parseVec2(v, w.f[1..3]);
        w.f[3] = parseF32Attr(tag, "rotation");
        if (attrValue(tag, "scale")) |v| parseVec2(v, w.f[4..6]);
    } else return null;
    return w;
}

fn parseF32Attr(tag: []const u8, key: []const u8) f32 {
    const v = attrValue(tag, key) orelse return 0;
    return std.fmt.parseFloat(f32, v) catch 0;
}

fn parseVec2(s: []const u8, out: []f32) void {
    var it = std.mem.splitScalar(u8, s, ',');
    if (it.next()) |a| out[0] = std.fmt.parseFloat(f32, std.mem.trim(u8, a, " ")) catch 0;
    if (it.next()) |b| out[1] = std.fmt.parseFloat(f32, std.mem.trim(u8, b, " ")) catch 0;
}

fn parseVec3(s: []const u8, out: []f32) void {
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |p| {
        if (i >= out.len) break;
        out[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, p, " ")) catch 0;
        i += 1;
    }
}

fn parseColor(s: []const u8, out: *[4]f32) void {
    // #RRGGBBAA.
    if (s.len != 9 or s[0] != '#') return;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const h = std.fmt.parseInt(u8, s[1 + i * 2 .. 3 + i * 2], 16) catch return;
        out[i] = @as(f32, @floatFromInt(h)) / 255.0;
    }
}

fn parseMode(s: ?[]const u8) u8 {
    const m = s orelse return mode_color_only;
    if (std.mem.eql(u8, m, "ColorAndMask")) return mode_color_and_mask;
    if (std.mem.eql(u8, m, "MaskOnly")) return 2;
    if (std.mem.eql(u8, m, "PunchOut")) return 3;
    return mode_color_only;
}

fn parseOffsetTarget(s: ?[]const u8) u8 {
    // Stock OffsetTarget enum order (byte): All, Shapes, Text, Noise.
    // Absent reads All (0), matching the field default.
    const m = s orelse return 0;
    if (std.mem.eql(u8, m, "Shapes")) return 1;
    if (std.mem.eql(u8, m, "Text")) return 2;
    if (std.mem.eql(u8, m, "Noise")) return 3;
    return 0;
}

fn parseColorMode(s: ?[]const u8) u8 {
    // Stock ColorMode enum order (byte): Multiply, Blend, Override.
    const m = s orelse return 0;
    if (std.mem.eql(u8, m, "Blend")) return 1;
    if (std.mem.eql(u8, m, "Override")) return 2;
    return 0;
}

fn parseShapeMode(s: ?[]const u8) u8 {
    // Stock ShapeMode enum order (byte): Normal, Invert, Line, Ripple.
    const m = s orelse return 0;
    if (std.mem.eql(u8, m, "Invert")) return 1;
    if (std.mem.eql(u8, m, "Line")) return 2;
    if (std.mem.eql(u8, m, "Ripple")) return 3;
    return 0;
}

fn parseGridMode(s: ?[]const u8) i32 {
    // Stock GridWarp.Mode enum order (i32): Column, Rectangle, Hex.
    const m = s orelse return 0;
    if (std.mem.eql(u8, m, "Rectangle")) return 1;
    if (std.mem.eql(u8, m, "Hex")) return 2;
    return 0;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8) !?Catalog {
    if (game_dir) |gd| {
        var path_buf: [2048]u8 = undefined;
        const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Prefabs", .{gd});
        var cfg_buf: [2048]u8 = undefined;
        // Stock default `[D]` library (mandatory zero-guid Default Sign).
        const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Data/Config/signs.xml", .{gd});
        return loadFromPrefabsRoot(allocator, p, cfg) catch null;
    }
    return null;
}

test "guid net order" {
    var g: [16]u8 = undefined;
    try guidFromHyphenString("00112233-4455-6677-8899-aabbccddeeff", &g);
    try std.testing.expectEqual(@as(u8, 0x33), g[0]);
    try std.testing.expectEqual(@as(u8, 0x22), g[1]);
    try std.testing.expectEqual(@as(u8, 0x11), g[2]);
    try std.testing.expectEqual(@as(u8, 0x00), g[3]);
    try std.testing.expectEqual(@as(u8, 0x55), g[4]);
    try std.testing.expectEqual(@as(u8, 0x44), g[5]);
    try std.testing.expectEqual(@as(u8, 0x77), g[6]);
    try std.testing.expectEqual(@as(u8, 0x66), g[7]);
    try std.testing.expectEqual(@as(u8, 0x88), g[8]);
    try std.testing.expectEqual(@as(u8, 0xaa), g[10]);
}

test "default [D] sign library loads from Data/Config/signs.xml" {
    const gd = stock_paths.dedicated_server;
    if (!io_fs.dirExists(gd)) return error.SkipZigTest;
    var path_buf: [2048]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/Data/Prefabs", .{gd});
    var cfg_buf: [2048]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Data/Config/signs.xml", .{gd});
    var cat = try loadFromPrefabsRoot(std.testing.allocator, p, cfg);
    defer cat.deinit();
    var found_default_sign = false;
    var prefab_modified: usize = 0;
    var prefab_total: usize = 0;
    for (cat.entries) |e| {
        if (std.mem.eql(u8, e.library, "[D]") and std.mem.eql(u8, e.name, "Default Sign")) {
            found_default_sign = true;
            // The stock `modified` timestamp parses to nonzero .NET ticks
            // (previously sent as 0 for all 1680 rows).
            try std.testing.expect(e.modified_ticks > 0);
            // The drawing tree parses: the Default Sign carries polygon +
            // group layers with warps (stock signs.xml: 285 layers, 101
            // warps over 8 signs).
            try std.testing.expect(e.layers.len > 0);
            var polys: usize = 0;
            var groups: usize = 0;
            var warps: usize = 0;
            for (e.layers) |l| {
                if (l.kind == layer_polygon) polys += 1;
                if (l.kind == layer_group) {
                    groups += 1;
                    try std.testing.expect(l.children.len > 0);
                }
                warps += l.warps.len;
                for (l.children) |c| warps += c.warps.len;
            }
            try std.testing.expect(polys > 0);
            try std.testing.expect(groups > 0);
            try std.testing.expect(warps > 0);
        }
        if (!std.mem.eql(u8, e.library, "[D]")) {
            prefab_total += 1;
            if (e.modified_ticks > 0) prefab_modified += 1;
        }
    }
    // Stock ships the mandatory zero-guid Default Sign in the [D] library.
    try std.testing.expect(found_default_sign);
    // Every prefab sign carries a modified stamp (0 missing in the shipped
    // Parts set); all must parse to nonzero ticks.
    try std.testing.expect(prefab_total > 0);
    try std.testing.expectEqual(prefab_total, prefab_modified);
    // Prefab signs carry next_* counters (unlike signs.xml): the Beanthere
    // Coffee sign pins all four through the catalog.
    for (cat.entries) |e| {
        if (!std.mem.eql(u8, e.name, "Beanthere Coffee")) continue;
        try std.testing.expectEqual(@as(i32, 8), e.next_poly);
        try std.testing.expectEqual(@as(i32, 5), e.next_text);
        try std.testing.expectEqual(@as(i32, 10), e.next_noise);
        try std.testing.expectEqual(@as(i32, 32), e.next_group);
    }
}

test "prefab sign libraries parse deep nesting and enum values" {
    // The prefab libraries (47905 layers/warps) exercise what signs.xml
    // does not: 3-deep group nesting, shapeMode/offsetTarget/colorMode
    // enums, and named layers with fonts. part_billboard_beanthere carries
    // all three.
    const p = stock_paths.steam_client ++ "/Data/Prefabs/Parts/part_billboard_beanthere_signs.xml";
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    const raw = try io_fs.readFileAll(std.testing.allocator, p);
    defer std.testing.allocator.free(raw);
    var arena_holder: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_holder.deinit();
    const arena = arena_holder.allocator();
    // Find the first <sign> body and parse its layers.
    const si = std.mem.findPos(u8, raw, 0, "<sign ") orelse return error.TestUnexpectedResult;
    const gt = std.mem.findPos(u8, raw, si, ">") orelse return error.TestUnexpectedResult;
    const close = std.mem.findPos(u8, raw, gt, "</sign>") orelse return error.TestUnexpectedResult;
    const layers = try parseLayers(arena, raw[gt + 1 .. close]);
    try std.testing.expect(layers.len > 0);
    // Depth 3 exists: a group whose child group has children.
    var deep = false;
    var texts: usize = 0;
    var named = false;
    for (layers) |l| {
        if (l.name.len > 0) named = true;
        if (l.kind == layer_text) texts += 1;
        if (l.kind != layer_group) continue;
        for (l.children) |c| {
            if (c.kind == layer_group and c.children.len > 0) deep = true;
            if (c.kind == layer_text) texts += 1;
        }
    }
    try std.testing.expect(named);
    try std.testing.expect(texts > 0);
    try std.testing.expect(deep);
}

test "sign modified timestamps parse to .NET ticks" {
    // 2026-02-27 13:43:31Z (the stock Default Sign stamp).
    const t = parseModifiedTicks("2026-02-27 13:43:31Z");
    try std.testing.expect(t > 0);
    // Round-trip check: ticks / 10_000_000 - 62135596800 = unix seconds for
    // 2026-02-27 13:43:31Z = 1772199811.
    try std.testing.expectEqual(@as(i64, 1772199811), @divFloor(t, 10000000) - 62135596800);
    // Malformed stamps fail closed to 0, never a guessed date.
    try std.testing.expectEqual(@as(i64, 0), parseModifiedTicks(""));
    try std.testing.expectEqual(@as(i64, 0), parseModifiedTicks("2026-02-27"));
    try std.testing.expectEqual(@as(i64, 0), parseModifiedTicks("2026-13-27 13:43:31Z"));
    try std.testing.expectEqual(@as(i64, 0), parseModifiedTicks("not a date"));
}

test "sign modified timestamps reject invalid calendar dates" {
    const invalid = [_][]const u8{
        "2023-02-29 00:00:00Z",
        "1900-02-29 00:00:00Z",
        "2100-02-29 00:00:00Z",
        "2024-02-30 00:00:00Z",
        "2026-04-31 00:00:00Z",
        "0000-01-01 00:00:00Z",
        "2016-12-31 23:59:60Z",
    };
    for (invalid) |stamp| {
        try std.testing.expectEqual(@as(i64, 0), parseModifiedTicks(stamp));
    }
    const ticks_per_day: i64 = 86400 * 10000000;
    try std.testing.expectEqual(ticks_per_day, parseModifiedTicks("2000-03-01 00:00:00Z") - parseModifiedTicks("2000-02-29 00:00:00Z"));
    try std.testing.expectEqual(ticks_per_day, parseModifiedTicks("2024-02-29 00:00:00Z") - parseModifiedTicks("2024-02-28 00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 10000000), parseModifiedTicks("0001-01-01 00:00:01Z"));
    try std.testing.expectEqual(@as(i64, 3155378975990000000), parseModifiedTicks("9999-12-31 23:59:59Z"));
}
