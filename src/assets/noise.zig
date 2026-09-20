//! sounds.xml noise table: per sound-group `Noise` (volume/time/muffle/heat)
//! for the movement-noise model. Stock `SoundsFromXml::Parse` builds
//! `Audio.XmlData` per `SoundDataNode name`, and `Audio.Manager::AddAudioData`
//! (IL=85) feeds each node's `noiseData` into `AIDirectorData::AddNoisySound`
//! keyed by the node name - the same key the client sends as the
//! `audioClipName` of a relayed `NetPackageSoundAtPosition`. Data, not code:
//! stock `Data/Config/sounds.xml` holds 1312 `<Noise>` rows (footsteps 3-11,
//! gunfire 60+, explosions 120, each with `muffled_when_crouched` and optional
//! `heat_map_strength`). The row's `heat_map_time` attribute is parsed by stock
//! into `AIDirectorData/Noise::heatMapTime` but never read: every heat event
//! uses the constant window in `AIDirector::NotifyNoise` (240 s, IL_00D9), so
//! zdtd models that constant instead of a dead field.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");
const stock_paths = @import("../util/stock_paths.zig");

/// One `<Noise>` element (RE `Audio.NoiseData` + `AIDirectorData/Noise`).
pub const Noise = struct {
    /// `noise` attribute: the AI noise volume the sound makes.
    volume: f32 = 0,
    /// `time` attribute: seconds the noise persists (`NotifyNoise` × 20 ticks).
    time: f32 = 0,
    /// `muffled_when_crouched` attribute: volume scale for crouched instigators
    /// (stock `AIDirector.NotifyNoise` multiplies the instigator's volumeScale).
    muffled_when_crouched: f32 = 1.0,
    /// `heat_map_strength` attribute: feeds `AIDirector.NotifyActivity` when > 0.
    heat_map_strength: f32 = 0,
};

/// Longest `SoundDataNode` key this table keeps: the client's `signalGroupName`
/// is a claim, and no stock sound group comes near this.
pub const max_clip_name: usize = 64;

pub const max_noise_entries: usize = 2048;

pub const Entry = struct {
    /// SoundDataNode name (the relayed clip key).
    name: []const u8,
    noise: Noise,
};

pub const Table = struct {
    map: std.StringHashMapUnmanaged(Noise) = .{},
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

    /// Look up a relayed clip name (read-only, safe off the net thread once
    /// the table is fully built - no writes happen after init).
    pub fn get(self: *const Table, name: []const u8) ?Noise {
        return self.map.get(name);
    }

    /// Look up a claimed clip name the way stock does before its dictionary
    /// lookup: `Audio.Manager::StripOffDirectories` keeps the basename and
    /// lowercases it (`Path.GetFileName(x).ToLower()`, Manager.il.txt IL=7),
    /// and the keys were lowercased the same way when `AddAudioData` (IL=85)
    /// built the map. Over-long or empty claims cannot be stock group keys.
    pub fn getClip(self: *const Table, name: []const u8) ?Noise {
        const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
        if (base.len == 0 or base.len > max_clip_name) return null;
        var buf: [max_clip_name]u8 = undefined;
        return self.map.get(std.ascii.lowerString(buf[0..base.len], base));
    }
};

/// Offline fixture matching stock V3.1.4 sounds.xml values (the rows used by
/// the stealth tests; the game-dir test re-checks against the real file).
pub const fixture_entries = [_]Entry{
    .{ .name = "stepdirt", .noise = .{ .volume = 5, .time = 1, .muffled_when_crouched = 0.507 } },
    .{ .name = "stepcloth", .noise = .{ .volume = 3, .time = 1, .muffled_when_crouched = 0.507 } },
    .{ .name = "stepbush", .noise = .{ .volume = 11, .time = 3, .muffled_when_crouched = 0.507 } },
    .{ .name = "pipe_pistol_fire", .noise = .{ .volume = 62, .time = 2, .muffled_when_crouched = 0.8, .heat_map_strength = 0.75 } },
    .{ .name = "Auger_Fire_Start", .noise = .{ .volume = 60, .time = 2, .heat_map_strength = 1.0 } },
};

/// Build a Table from comptime entries (tests / no game-dir fallback).
pub fn fromEntries(allocator: std.mem.Allocator, entries: []const Entry) Table {
    const arena_holder = arena_util.newArenaHolder(allocator) catch return .{};
    var t: Table = .{};
    t.arena_ptr = arena_holder;
    const arena = arena_holder.allocator();
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        t.map.put(arena, entries[i].name, entries[i].noise) catch continue;
    }
    return t;
}

/// Case-insensitive element scan. Stock matches child elements by LocalName
/// with `Extensions::EqualsCaseInsensitive` (SoundsFromXml.il.txt IL_0075), so
/// `<noise>` is the same element as `<Noise>`. The tag boundary check keeps
/// `<NoiseData>` from matching `<Noise`.
fn findElement(hay: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.findPos(u8, hay, i, "<")) |lt| {
        const after = lt + 1;
        if (after + name.len <= hay.len and std.ascii.eqlIgnoreCase(hay[after .. after + name.len], name)) {
            const next: u8 = if (after + name.len < hay.len) hay[after + name.len] else 0;
            if (next == 0 or next == '>' or next == '/' or std.ascii.isWhitespace(next)) return lt;
        }
        i = lt + 1;
    }
    return null;
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

    var t: Table = .{};
    t.arena_ptr = arena_holder;
    errdefer t.deinit();

    var i: usize = 0;
    while (i < clean.len) {
        const pi = findElement(clean, i, "SoundDataNode") orelse break;
        const name = xml.attr(clean, pi, "name") orelse {
            i = pi + 1;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, pi, ">") orelse break;
        // Self-closing `<SoundDataNode .../>` has no body; the scan resumes
        // after it (a self-closing node used to end the whole scan, dropping
        // every later node). A body node ends at its closing tag.
        var body_end = gt;
        if (!(gt > pi and clean[gt - 1] == '/')) {
            body_end = findElement(clean, gt, "/SoundDataNode") orelse break;
        }
        // The node's own Noise element: the first `<Noise>` inside its body -
        // stock sounds.xml and its modlets carry at most one per node.
        var noise: Noise = .{};
        if (findElement(clean, pi, "noise")) |ni| {
            if (ni < body_end) {
                if (xml.attr(clean, ni, "noise")) |v| noise.volume = xml.parseF32(v) orelse 0;
                if (xml.attr(clean, ni, "time")) |v| noise.time = xml.parseF32(v) orelse 0;
                if (xml.attr(clean, ni, "muffled_when_crouched")) |v| noise.muffled_when_crouched = xml.parseF32(v) orelse 1.0;
                if (xml.attr(clean, ni, "heat_map_strength")) |v| noise.heat_map_strength = xml.parseF32(v) orelse 0;
            }
        }
        // Insert only nodes that actually carry a Noise element (stock keeps
        // noise-less groups too; FindNoise would miss them anyway).
        if (noise.volume > 0 or noise.heat_map_strength > 0) {
            const kn = try arena.alloc(u8, name.len);
            _ = std.ascii.lowerString(kn, name);
            try t.map.put(arena, kn, noise);
        }
        i = body_end + 1;
    }
    return t;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("sounds.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

test "noise fixture table resolves stock rows" {
    var t = fromEntries(std.testing.allocator, &fixture_entries);
    defer t.deinit();
    try std.testing.expectEqual(@as(f32, 5), t.get("stepdirt").?.volume);
    try std.testing.expectEqual(@as(f32, 0.507), t.get("stepdirt").?.muffled_when_crouched);
    try std.testing.expectEqual(@as(f32, 62), t.get("pipe_pistol_fire").?.volume);
    try std.testing.expectEqual(@as(f32, 0.75), t.get("pipe_pistol_fire").?.heat_map_strength);
    try std.testing.expect(t.get("no_such_clip") == null);
}

test "noise scan survives a self-closing node and matches tags case-insensitively" {
    // Stock matches child element names with Extensions::EqualsCaseInsensitive
    // (SoundsFromXml.il.txt IL_0075), and AddAudioData keys the map by the
    // lowercased basename. A self-closing <SoundDataNode/> has no body: it must
    // not end the scan (the old body_end = clean.len did, dropping every node
    // after it).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/sounds.xml", .{dir});
    try io_fs.writeFile(path,
        \\<Sounds>
        \\  <SoundDataNode name="emptyGroup"/>
        \\  <SoundDataNode name="Walking">
        \\    <noise noise="5" time="1" muffled_when_crouched="0.507"/>
        \\  </SoundDataNode>
        \\  <SoundDataNode name="loud">
        \\    <NoiseScale value="1"/> <!-- the boundary check must not match this -->
        \\    <NOISE noise="120" time="4" heat_map_strength="5" heat_map_time="300"/>
        \\  </SoundDataNode>
        \\</Sounds>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.map.count()); // the empty node is not a row
    // Keys are lowercased; the claimed clip name is stripped and lowercased.
    try std.testing.expectEqual(@as(f32, 5), t.get("walking").?.volume);
    try std.testing.expectEqual(@as(f32, 5), t.getClip("Walking").?.volume);
    try std.testing.expectEqual(@as(f32, 5), t.getClip("Sounds/Walking").?.volume);
    const loud = t.getClip("LOUD").?;
    try std.testing.expectEqual(@as(f32, 120), loud.volume);
    try std.testing.expectEqual(@as(f32, 5), loud.heat_map_strength);
    // Over-long / empty claims cannot be group keys.
    try std.testing.expect(t.getClip("") == null);
    try std.testing.expect(t.getClip("x" ** (max_clip_name + 1)) == null);
}

test "load sounds.xml noise table when present" {
    const p = stock_paths.configFile("sounds.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    try std.testing.expect(t.map.count() > 100);
    // Pinned stock rows (V3.1.4): player footsteps + a heat-carrying gunshot.
    try std.testing.expectEqual(@as(f32, 5), t.get("stepdirt").?.volume);
    try std.testing.expectEqual(@as(f32, 0.507), t.get("stepdirt").?.muffled_when_crouched);
    try std.testing.expectEqual(@as(f32, 11), t.get("stepbush").?.volume);
    const pistol = t.get("pipe_pistol_fire").?;
    try std.testing.expectEqual(@as(f32, 62), pistol.volume);
    try std.testing.expectEqual(@as(f32, 0.75), pistol.heat_map_strength);
}
