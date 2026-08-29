//! Stock serveradmin.xml loader (AdminTools state, V3.1.0 b14).
//!
//! Parses the operator's `serveradmin.xml` (admins/whitelist/blacklist
//! sections) into the same in-memory lists the admin console mutates, so a
//! stock-format permission file applies on top of zdtd's own list files
//! (admins.zsv / whitelist.zsv / bans.zsv remain the runtime-persisted
//! form). RE: AdminTools.ParseSection / ParseUserIdentifier (platform +
//! userid attributes, legacy steamID fallback), AdminUsers.UserPermission
//! (permission_level), AdminWhitelist.WhitelistUser, and
//! AdminBlacklist.BannedUser.TryParse (unbandate DateTime) - pinned in
//! 7dtd-engine-research docs/dedicated-misc-systems.md.
//!
//! Divergence: stock hot-reloads the file via a file watcher
//! (InitFileWatcher -> OnFileChanged -> Load); zdtd applies it at startup,
//! so a serveradmin.xml edit takes effect on restart. Tracked in the
//! GAP_ANALYSIS bans row.

const std = @import("std");
const xml = @import("../assets/xml_util.zig");
const admin_cmds = @import("admin_cmds.zig");
const io_fs = @import("../util/io_fs.zig");
const util_log = @import("../util/log.zig");

/// Maximum serveradmin.xml size (stock files are small; bound operator
/// input so a mistaken path cannot consume unbounded memory at startup).
pub const max_serveradmin_bytes: usize = 4 * 1024 * 1024;

/// Platform-id composite key for the string-keyed admin/whitelist lists
/// ("Steam:76561198000000000"). Platform names never contain ':', so the
/// composite is unambiguous; the ban list stores the pair separately.
pub fn compositeKey(buf: []u8, platform: []const u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ platform, id }) catch return "";
}

/// `platform` + `userid` attributes, with the legacy `steamID` fallback
/// (AdminTools.ParseUserIdentifier, IL=39). Returns slices into `hay`.
fn platformId(hay: []const u8, at: usize) ?struct { platform: []const u8, id: []const u8 } {
    const platform = xml.attr(hay, at, "platform") orelse "";
    const userid = xml.attr(hay, at, "userid") orelse "";
    if (platform.len != 0 and userid.len != 0) return .{ .platform = platform, .id = userid };
    if (xml.attr(hay, at, "steamID")) |sid| {
        if (sid.len != 0) return .{ .platform = "Steam", .id = sid };
    }
    return null;
}

/// True when the element found by `nextElement(prefix)` is really that tag
/// and not a longer tag sharing the prefix (biome_layers pattern).
fn tagOk(hay: []const u8, el: xml.Element, comptime prefix: []const u8) bool {
    const after = el.open_at + prefix.len;
    if (after >= hay.len) return false;
    const c = hay[after];
    return std.ascii.isWhitespace(c) or c == '>' or c == '/';
}

/// Unix seconds from a wall-clock datetime string. Accepts the common stock
/// forms `YYYY-MM-DD[TH ][HH:MM[:SS]]` and `MM/DD/YYYY[ HH:MM[:SS]]`
/// (DateTime.TryParse); interpreted as UTC (a UTC server matches stock's
/// local-time reading). Uses the days-from-civil algorithm.
fn parseUnixDateTime(s: []const u8) ?i64 {
    var y: i64 = 0;
    var mo: i64 = 0;
    var d: i64 = 0;
    var h: i64 = 0;
    var mi: i64 = 0;
    var sec: i64 = 0;
    var digits: [6]i64 = undefined;
    var nd: usize = 0;
    var cur: i64 = 0;
    var have_digit = false;
    var field: u8 = 0;
    var sep: u8 = 0;
    var sep_set = false;
    for (s) |c| {
        if (std.ascii.isDigit(c)) {
            cur = cur * 10 + @as(i64, c - '0');
            have_digit = true;
            continue;
        }
        if (!have_digit) {
            if (c == ' ' or c == 'T') continue;
            return null;
        }
        if (nd < digits.len) digits[nd] = cur else return null;
        nd += 1;
        cur = 0;
        have_digit = false;
        if (c == ':' or c == '-' or c == '/') {
            if (!sep_set) {
                sep = c;
                sep_set = true;
            }
            field += 1;
        } else if (c == ' ' or c == 'T') {
            field += 1;
        } else {
            return null;
        }
    }
    if (have_digit) {
        if (nd < digits.len) digits[nd] = cur else return null;
        nd += 1;
    }
    if (nd < 3 or nd > 6) return null;
    if (sep == '/') {
        // MM/DD/YYYY
        mo = digits[0];
        d = digits[1];
        y = digits[2];
    } else {
        y = digits[0];
        mo = digits[1];
        d = digits[2];
    }
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    if (nd >= 4) h = digits[3];
    if (nd >= 5) mi = digits[4];
    if (nd >= 6) sec = digits[5];
    if (h > 23 or mi > 59 or sec > 60) return null;
    // days from civil (Hinnant)
    const y2 = y - @as(i64, @intFromBool(mo <= 2));
    const era = @divFloor(y2, 400);
    const yoe = y2 - era * 400;
    const mp = if (mo > 2) mo - 3 else mo + 9;
    const doy = (@divTrunc(153 * mp + 2, 5) + d - 1);
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + h * 3600 + mi * 60 + sec;
}

fn warnEntry(what: []const u8, reason: []const u8) void {
    util_log.warn("zdtd: serveradmin.xml: {s} skipped ({s})\n", .{ what, reason });
}

/// Merge the file's sections into the three operator lists. A missing file
/// is a normal "no serveradmin.xml" state; a corrupt entry is skipped with a
/// warning (fail closed, matching stock's ignore-and-log behaviour).
pub fn load(
    allocator: std.mem.Allocator,
    path: []const u8,
    admin_list: *admin_cmds.PermissionList,
    whitelist: *admin_cmds.PermissionList,
    ban_list: *admin_cmds.BanList,
) !void {
    const text = try io_fs.readFileAll(allocator, path);
    defer allocator.free(text);
    if (text.len > max_serveradmin_bytes) {
        warnEntry("file", "larger than 4 MiB");
        return;
    }
    var key_buf: [admin_cmds.max_composite_id]u8 = undefined;

    // Admin users: V3.1.0 writes a top-level <users> section; older builds
    // nested it under <admins>. Support both.
    var users_gt: ?usize = null;
    if (xml.nextElement(text, 0, "<users", "</users>")) |usec| {
        if (tagOk(text, usec, "<users")) {
            // Start past the <users> open tag so the <user prefix cannot
            // match the section tag itself.
            users_gt = (std.mem.findPos(u8, text, usec.open_at, ">") orelse usec.open_at) + 1;
        }
    }
    if (users_gt == null) {
        if (xml.nextElement(text, 0, "<admins", "</admins>")) |sec| {
            if (tagOk(text, sec, "<admins")) {
                if (xml.nextElement(text, sec.open_at, "<users", "</users>")) |usec| {
                    if (tagOk(text, usec, "<users")) {
                        users_gt = (std.mem.findPos(u8, text, usec.open_at, ">") orelse usec.open_at) + 1;
                    }
                }
            }
        }
    }
    if (users_gt) |ug| {
        var k: usize = ug;
        while (xml.nextElement(text, k, "<user", "</user>")) |el| {
            k = el.next_i;
            if (!tagOk(text, el, "<user")) continue;
            const at = el.open_at;
            const pid = platformId(text, at) orelse {
                warnEntry("admin entry", "missing platform/userid");
                continue;
            };
            const lvl_s = xml.attr(text, at, "permission_level") orelse {
                warnEntry("admin entry", "missing permission_level");
                continue;
            };
            const lvl = std.fmt.parseInt(u8, lvl_s, 10) catch {
                warnEntry("admin entry", "non-numeric permission_level");
                continue;
            };
            const key = compositeKey(&key_buf, pid.platform, pid.id);
            if (key.len == 0 or !admin_list.add(key, lvl)) {
                warnEntry("admin entry", "list full");
                continue;
            }
            admin_list.markXml(key);
        }
    }

    // <whitelist><whitelisted platform userid name/></whitelist>
    if (xml.nextElement(text, 0, "<whitelist", "</whitelist>")) |sec| {
        if (tagOk(text, sec, "<whitelist")) {
            var k: usize = sec.open_at;
            while (xml.nextElement(text, k, "<whitelisted", "</whitelisted>")) |el| {
                k = el.next_i;
                if (!tagOk(text, el, "<whitelisted")) continue;
                const at = el.open_at;
                const pid = platformId(text, at) orelse {
                    warnEntry("whitelist entry", "missing platform/userid");
                    continue;
                };
                const key = compositeKey(&key_buf, pid.platform, pid.id);
                if (key.len == 0 or !whitelist.add(key, 0)) {
                    warnEntry("whitelist entry", "list full");
                    continue;
                }
                whitelist.markXml(key);
            }
        }
    }

    // <blacklist><blacklisted platform userid name unbandate reason/></blacklist>
    if (xml.nextElement(text, 0, "<blacklist", "</blacklist>")) |sec| {
        if (tagOk(text, sec, "<blacklist")) {
            var k: usize = sec.open_at;
            while (xml.nextElement(text, k, "<blacklisted", "</blacklisted>")) |el| {
                k = el.next_i;
                if (!tagOk(text, el, "<blacklisted")) continue;
                const at = el.open_at;
                const pid = platformId(text, at) orelse {
                    warnEntry("blacklist entry", "missing platform/userid");
                    continue;
                };
                const until_s = xml.attr(text, at, "unbandate") orelse {
                    warnEntry("blacklist entry", "missing unbandate");
                    continue;
                };
                const until = parseUnixDateTime(until_s) orelse {
                    warnEntry("blacklist entry", "invalid unbandate");
                    continue;
                };
                const name = xml.attr(text, at, "name") orelse "";
                const reason = xml.attr(text, at, "reason") orelse "";
                if (name.len > admin_cmds.max_name) {
                    warnEntry("blacklist entry", "name too long");
                    continue;
                }
                if (!ban_list.addId(pid.platform, pid.id, name, until, reason)) {
                    warnEntry("blacklist entry", "list full");
                    continue;
                }
                ban_list.markXmlId(pid.platform, pid.id);
            }
        }
    }
}

test "serveradmin.xml sections merge into the operator lists" {
    const xml_text =
        \\<adminTools>
        \\  <users>
        \\    <user platform="Steam" userid="76561198000000000" name="Alice" permission_level="0" />
        \\    <user platform="EOS" userid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" name="Bob" permission_level="1" />
        \\    <user steamID="76561198000000001" name="Legacy" permission_level="2" />
        \\    <user platform="Steam" userid="999" name="Bad" />
        \\  </users>
        \\  <whitelist>
        \\    <whitelisted platform="Steam" userid="76561198000000002" name="Carol" />
        \\  </whitelist>
        \\  <blacklist>
        \\    <blacklisted platform="Steam" userid="76561198000000003" name="Dave" unbandate="2030-01-02 03:04:05" reason="griefing" />
        \\  </blacklist>
        \\</adminTools>
    ;
    var admins: admin_cmds.PermissionList = .{};
    var whitelist: admin_cmds.PermissionList = .{};
    var bans: admin_cmds.BanList = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "serveradmin.xml" });
    defer std.testing.allocator.free(path);
    try io_fs.writeFile(path, xml_text);
    try load(std.testing.allocator, path, &admins, &whitelist, &bans);

    try std.testing.expect(admins.find("Steam:76561198000000000") != null);
    try std.testing.expectEqual(@as(u8, 0), admins.entries[admins.find("Steam:76561198000000000").?].level);
    try std.testing.expect(admins.find("EOS:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    // Legacy steamID fallback resolves to Steam.
    try std.testing.expect(admins.find("Steam:76561198000000001") != null);
    // Missing permission_level is skipped, not applied.
    try std.testing.expect(admins.find("Steam:999") == null);

    try std.testing.expect(whitelist.find("Steam:76561198000000002") != null);

    try std.testing.expect(bans.bannedId("Steam", "76561198000000003", 1893553444)); // before 2030-01-02 03:04:05 UTC
    try std.testing.expect(!bans.bannedId("Steam", "76561198000000003", 1893553445));
}

test "serveradmin.xml unbandate parses common forms" {
    // YYYY-MM-DD HH:MM:SS (UTC)
    try std.testing.expectEqual(@as(i64, 1893553445), parseUnixDateTime("2030-01-02 03:04:05").?);
    // YYYY-MM-DDTHH:MM (seconds absent -> 00)
    try std.testing.expectEqual(@as(i64, 1893553440), parseUnixDateTime("2030-01-02T03:04").?);
    // YYYY-MM-DD (midnight UTC)
    try std.testing.expectEqual(@as(i64, 1893542400), parseUnixDateTime("2030-01-02").?);
    // MM/DD/YYYY
    try std.testing.expectEqual(@as(i64, 1893553445), parseUnixDateTime("01/02/2030 03:04:05").?);
    try std.testing.expect(parseUnixDateTime("not a date") == null);
    try std.testing.expect(parseUnixDateTime("2030-13-01") == null);
}

test "serveradmin.xml accepts the older <admins><users> nesting" {
    const xml_text =
        \\<adminTools>
        \\  <admins>
        \\    <users>
        \\      <user platform="Steam" userid="555" name="Nested" permission_level="0" />
        \\    </users>
        \\  </admins>
        \\</adminTools>
    ;
    var admins: admin_cmds.PermissionList = .{};
    var whitelist: admin_cmds.PermissionList = .{};
    var bans: admin_cmds.BanList = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "serveradmin.xml" });
    defer std.testing.allocator.free(path);
    try io_fs.writeFile(path, xml_text);
    try load(std.testing.allocator, path, &admins, &whitelist, &bans);
    try std.testing.expect(admins.find("Steam:555") != null);
}
