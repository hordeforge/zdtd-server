//! Persistent player profiles: GamePref 110 `PersistentPlayerProfiles`.
//!
//! Stock keeps the character profile on the saved `EntityCreationData` and
//! reuses it instead of the one a client presents at spawn while the pref is
//! true (`GameManager::GetEntityCreationData` GameManager.il IL_02DA-02FF, and
//! the same test in `GameManager::StartAsServer` IL_0661-06B3). With the pref
//! false the incoming profile wins every time. zdtd has no PlayerDataFile of
//! stock's shape, so the profiles ride a sibling store
//! (`{world_dir}/profiles.zpf`, magic ZPF1, like allies.zal), keyed on the
//! client's platform identity, which is what stock's PersistentPlayerData keys
//! on too.
//!
//! No Game import: pure state plus save/load, so the join path can consult it
//! without a cycle. The tick path never touches it.

const std = @import("std");
const platform_user = @import("../wire/platform_user.zig");
const stock_entity = @import("../wire/stock_entity.zig");
const io_fs = @import("../util/io_fs.zig");

pub const Id = platform_user.Id;
pub const OwnedProfile = stock_entity.OwnedProfile;

/// Profiles kept at once. A server's player list is far smaller; at the cap the
/// oldest entry is replaced rather than refusing to remember a new one.
pub const max_profiles: usize = 64;

pub const Entry = struct {
    used: bool = false,
    id: platform_user.Stored = .{},
    profile: OwnedProfile = .{},
};

pub const Store = struct {
    entries: [max_profiles]Entry = @splat(.{}),

    /// The stored profile for an identity, or null when nothing is remembered
    /// (or the client has no identity to key on).
    pub fn get(self: *const Store, id: ?Id) ?*const OwnedProfile {
        const key = id orelse return null;
        for (&self.entries) |*e| {
            if (!e.used) continue;
            const stored = e.id.get() orelse continue;
            if (Id.eql(stored, key)) return &e.profile;
        }
        return null;
    }

    /// Remember a profile for an identity. A null identity is dropped, the same
    /// way stock's `SetStatus` drops one: two clients without a platform session
    /// must not collapse onto one record.
    pub fn put(self: *Store, id: ?Id, profile: OwnedProfile) void {
        const key = id orelse return;
        for (&self.entries) |*e| {
            if (!e.used) continue;
            const stored = e.id.get() orelse continue;
            if (!Id.eql(stored, key)) continue;
            e.profile = profile;
            return;
        }
        var slot: ?*Entry = null;
        for (&self.entries) |*e| {
            if (!e.used) {
                slot = e;
                break;
            }
        }
        const e = slot orelse blk: {
            // Full: replace the first entry (a bounded store must not grow).
            break :blk &self.entries[0];
        };
        e.* = .{ .used = true, .profile = profile };
        e.id.set(key) catch {
            e.used = false;
            return;
        };
    }

    /// Persist to `{dir}/profiles.zpf` (magic ZPF1, u16 count, len-prefixed
    /// identity + the profile's fields). Only used entries are written.
    pub fn save(self: *const Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/profiles.zpf", .{dir});
        const rec_max = 1 + platform_user.max_platform_len + 1 + platform_user.max_id_len +
            1 + stock_entity.profile_name_cap + 1 + 1 + stock_entity.profile_name_cap +
            1 + 1 + stock_entity.profile_name_cap + 1 + stock_entity.profile_name_cap +
            1 + stock_entity.profile_name_cap + 1 + stock_entity.profile_name_cap +
            1 + stock_entity.profile_name_cap + 1 + stock_entity.profile_name_cap;
        const buf = try allocator.alloc(u8, 6 + max_profiles * rec_max);
        defer allocator.free(buf);
        @memcpy(buf[0..4], "ZPF1");
        var o: usize = 6; // 4 magic + u16 count
        var n: u16 = 0;
        for (&self.entries) |*e| {
            if (!e.used) continue;
            const id = e.id.get() orelse continue;
            if (o + rec_max > buf.len) break;
            buf[o] = @intCast(id.platform.len);
            @memcpy(buf[o + 1 ..][0..id.platform.len], id.platform);
            o += 1 + id.platform.len;
            buf[o] = @intCast(id.id.len);
            @memcpy(buf[o + 1 ..][0..id.id.len], id.id);
            o += 1 + id.id.len;
            const v = e.profile.view();
            o += writeName(buf[o..], v.archetype);
            buf[o] = @intFromBool(v.is_male);
            o += 1;
            o += writeName(buf[o..], v.race_name);
            buf[o] = v.variant_number;
            o += 1;
            o += writeName(buf[o..], v.hair_name);
            o += writeName(buf[o..], v.hair_color);
            o += writeName(buf[o..], v.mustache_name);
            o += writeName(buf[o..], v.chops_name);
            o += writeName(buf[o..], v.beard_name);
            o += writeName(buf[o..], v.eye_color);
            n += 1;
        }
        std.mem.writeInt(u16, buf[4..6], n, .little);
        try io_fs.writeFile(path, buf[0..o]);
    }

    /// Restore from `{dir}/profiles.zpf`. A missing file is a fresh world, like
    /// the other sibling stores; anything else surfaces so the caller logs it
    /// before the next save clobbers data. Corrupt records stop the load.
    pub fn load(self: *Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/profiles.zpf", .{dir});
        const data = io_fs.readFileAll(allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.OpenFailed,
            else => return error.ReadFailed,
        };
        defer allocator.free(data);
        if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZPF1")) return error.ReadFailed;
        const n = std.mem.readInt(u16, data[4..6], .little);
        var pos: usize = 6;
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            const plat = readName(data, &pos, platform_user.max_platform_len) orelse return error.ReadFailed;
            const ident = readName(data, &pos, platform_user.max_id_len) orelse return error.ReadFailed;
            var prof: OwnedProfile = .{};
            prof.archetype_len = readNameInto(data, &pos, &prof.archetype) orelse return error.ReadFailed;
            if (pos >= data.len) return error.ReadFailed;
            prof.is_male = data[pos] != 0;
            pos += 1;
            prof.race_name_len = readNameInto(data, &pos, &prof.race_name) orelse return error.ReadFailed;
            if (pos >= data.len) return error.ReadFailed;
            prof.variant_number = data[pos];
            pos += 1;
            prof.hair_name_len = readNameInto(data, &pos, &prof.hair_name) orelse return error.ReadFailed;
            prof.hair_color_len = readNameInto(data, &pos, &prof.hair_color) orelse return error.ReadFailed;
            prof.mustache_name_len = readNameInto(data, &pos, &prof.mustache_name) orelse return error.ReadFailed;
            prof.chops_name_len = readNameInto(data, &pos, &prof.chops_name) orelse return error.ReadFailed;
            prof.beard_name_len = readNameInto(data, &pos, &prof.beard_name) orelse return error.ReadFailed;
            prof.eye_color_len = readNameInto(data, &pos, &prof.eye_color) orelse return error.ReadFailed;
            self.put(.{ .platform = plat, .id = ident }, prof);
        }
    }
};

fn writeName(out: []u8, name: []const u8) usize {
    const n: u8 = @intCast(@min(name.len, stock_entity.profile_name_cap));
    out[0] = n;
    @memcpy(out[1..][0..n], name[0..n]);
    return 1 + n;
}

fn readName(data: []const u8, pos: *usize, max_len: u8) ?[]const u8 {
    if (pos.* >= data.len) return null;
    const len = data[pos.*];
    if (len > max_len) return null;
    pos.* += 1;
    if (pos.* + len > data.len) return null;
    const s = data[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

/// Copy a length-prefixed name into a fixed buffer, returning its length.
fn readNameInto(data: []const u8, pos: *usize, buf: *[stock_entity.profile_name_cap]u8) ?u8 {
    const s = readName(data, pos, stock_entity.profile_name_cap) orelse return null;
    @memcpy(buf[0..s.len], s);
    return @intCast(s.len);
}

test "profile store round-trips through profiles.zpf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    io_fs.mkdirPath(dir);

    var s: Store = .{};
    var prof: OwnedProfile = .{};
    prof.archetype_len = try putName(&prof.archetype, "BaseFemale");
    prof.is_male = false;
    prof.race_name_len = try putName(&prof.race_name, "Black");
    prof.variant_number = 3;
    prof.hair_name_len = try putName(&prof.hair_name, "Hair08");
    s.put(.{ .platform = "Steam", .id = "76561198000000001" }, prof);
    try s.save(dir, std.testing.allocator);

    var back: Store = .{};
    try back.load(dir, std.testing.allocator);
    const got = back.get(.{ .platform = "Steam", .id = "76561198000000001" }).?;
    const gv = got.view();
    try std.testing.expectEqualStrings("BaseFemale", gv.archetype);
    try std.testing.expect(!gv.is_male);
    try std.testing.expectEqualStrings("Black", gv.race_name);
    try std.testing.expectEqual(@as(u8, 3), gv.variant_number);
    try std.testing.expectEqualStrings("Hair08", gv.hair_name);
    // An identity that was never stored, and a missing identity, both miss.
    try std.testing.expect(back.get(.{ .platform = "Steam", .id = "other" }) == null);
    try std.testing.expect(back.get(null) == null);
}

fn putName(buf: *[stock_entity.profile_name_cap]u8, value: []const u8) !u8 {
    if (value.len > stock_entity.profile_name_cap) return error.NameTooLong;
    @memcpy(buf[0..value.len], value);
    return @intCast(value.len);
}
