//! sounds.xml noise table: per sound-group `Noise` (volume/time/muffle/heat)
//! for the movement-noise model. Stock `SoundsFromXml::Parse` builds
//! `Audio.XmlData` per `SoundDataNode name`, and `Audio.Manager::AddAudioData`
//! (IL=85) feeds each node's `noiseData` into `AIDirectorData::AddNoisySound`
//! keyed by the node name - the same key the client sends as the
//! `audioClipName` of a relayed `NetPackageSoundAtPosition`. Data, not code:
//! stock `Data/Config/sounds.xml` holds 1312 `<Noise>` rows (footsteps 3–11,
//! gunfire 60+, explosions 120, each with `muffled_when_crouched` and optional
//! `heat_map_strength`/`heat_map_time`).

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

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
    /// `heat_map_time` attribute: heat window in seconds (stock ×10 ticks).
    heat_map_time: f32 = 0,
};

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
};

/// Offline fixture matching stock V3.1.4 sounds.xml values (the rows used by
/// the stealth tests; the game-dir test re-checks against the real file).
pub const fixture_entries = [_]Entry{
    .{ .name = "stepdirt", .noise = .{ .volume = 5, .time = 1, .muffled_when_crouched = 0.507 } },
    .{ .name = "stepcloth", .noise = .{ .volume = 3, .time = 1, .muffled_when_crouched = 0.507 } },
    .{ .name = "stepbush", .noise = .{ .volume = 11, .time = 3, .muffled_when_crouched = 0.507 } },
    .{ .name = "pipe_pistol_fire", .noise = .{ .volume = 62, .time = 2, .muffled_when_crouched = 0.8, .heat_map_strength = 0.75, .heat_map_time = 180 } },
    .{ .name = "Auger_Fire_Start", .noise = .{ .volume = 60, .time = 2, .heat_map_strength = 1.0, .heat_map_time = 90 } },
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
        const pi = std.mem.findPos(u8, clean, i, "<SoundDataNode ") orelse break;
        const name = xml.attr(clean, pi, "name") orelse {
            i = pi + 15;
            continue;
        };
        // Self-closing node (no body) or <SoundDataNode ...> body.
        var body_end = clean.len;
        if (std.mem.findPos(u8, clean, pi, ">")) |gt| {
            if (gt > pi and clean[gt - 1] != '/') {
                const close = std.mem.findPos(u8, clean, gt, "</SoundDataNode>") orelse break;
                body_end = close;
            }
        } else break;
        // The node's own Noise element: find the first `<Noise ` inside the
        // body - stock sounds.xml has at most one per SoundDataNode.
        var noise: Noise = .{};
        if (std.mem.findPos(u8, clean, pi, "<Noise ")) |ni| {
            if (ni < body_end) {
                if (xml.attr(clean, ni, "noise")) |v| noise.volume = xml.parseF32(v) orelse 0;
                if (xml.attr(clean, ni, "time")) |v| noise.time = xml.parseF32(v) orelse 0;
                if (xml.attr(clean, ni, "muffled_when_crouched")) |v| noise.muffled_when_crouched = xml.parseF32(v) orelse 1.0;
                if (xml.attr(clean, ni, "heat_map_strength")) |v| noise.heat_map_strength = xml.parseF32(v) orelse 0;
                if (xml.attr(clean, ni, "heat_map_time")) |v| noise.heat_map_time = xml.parseF32(v) orelse 0;
            }
        }
        // Insert only nodes that actually carry a Noise element (stock keeps
        // noise-less groups too; FindNoise would miss them anyway).
        if (noise.volume > 0 or noise.heat_map_strength > 0) {
            const kn = try arena.dupe(u8, name);
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

test "load sounds.xml noise table when present" {
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/sounds.xml";
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
