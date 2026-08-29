//! Stock ModManager subset for XML-only modlets (no DLL / IModApi hosting).
//!
//! Scans a mods root (`game-dir/Mods` or `--mods-dir`), parses each mod's
//! `ModInfo.xml` (V2), and exposes the mods' `Config/` dirs in mod order so
//! `xml_patch` can apply patches the way stock's `ModManager.LoadPatchStuff`
//! does (`../7dtd-engine-research/docs/mod-loading.md` §1-2, §5.2).
//!
//! Non-goals: never loads DLLs, never reads `Bundles/` content, never runs
//! `IModApi`/`ModEvents`. A code mod's XML patches still apply (stock-like for
//! the XML part) with a loud warning that the code part is not hosted.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml = @import("xml_util.zig");
const util_log = @import("../util/log.zig");

/// One XML-only modlet (stock `Mod` after `parseModInfoV2`).
pub const Mod = struct {
    /// V2 Name (stock `nameValidationRegex`; see parseModInfo).
    name: []const u8,
    /// DisplayName (stock: must be non-empty).
    display_name: []const u8,
    /// Absolute path of the mod folder.
    path: []const u8,
    /// The mod's `Config/` dir when present (patch XML source for xml_patch).
    config_dir: ?[]const u8,
    /// Stock ModInfo `Icon` property (relative path, e.g. "icon.png").
    /// Metadata only: the host never loads or renders it.
    icon: ?[]const u8 = null,
    /// `Bundles/` folder present. Tolerated, never read (PRD R11).
    has_bundles: bool,
    /// Any `.dll` at the mod root: code part is not hosted; XML still applies.
    has_code: bool,

    pub fn deinit(self: *Mod, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.display_name);
        allocator.free(self.path);
        if (self.config_dir) |cd| allocator.free(cd);
        if (self.icon) |ic| allocator.free(ic);
    }
};

/// One mod's patch source: `Config/` dir plus the issuing mod's absolute path
/// (the latter for `@modfolder:` include tokens, stock
/// `ReadPatchXmlWithFixedModFolders`).
pub const ModDir = struct {
    config_dir: []const u8,
    mod_path: []const u8,
};

/// Result of a mods-root scan; all strings owned.
pub const Scan = struct {
    mods: []Mod,
    /// Each mod's `Config/` dir + mod path in mod order (patches apply in this
    /// order).
    mod_dirs: []const ModDir,

    pub fn deinit(self: *Scan, allocator: std.mem.Allocator) void {
        for (self.mods) |*m| m.deinit(allocator);
        allocator.free(self.mods);
        for (self.mod_dirs) |md| {
            allocator.free(md.config_dir);
            allocator.free(md.mod_path);
        }
        allocator.free(self.mod_dirs);
    }
};

/// Subdirectory basenames of `dir_path`, sorted lexicographically (readdir
/// order is filesystem-dependent; stock scan order is unverified, G2, so a
/// deterministic sort is the documented fallback).
fn listDirNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try names.toOwnedSlice(allocator);
}

/// Stock `getElementAttributeValue`: exactly one child element of `element_name`
/// carrying a `value` attribute. Returns the value or null (both violations log
/// and return null in stock).
fn childValue(hay: []const u8, element_name: []const u8) ?[]const u8 {
    var count: usize = 0;
    var found: []const u8 = "";
    var i: usize = 0;
    while (i < hay.len) {
        const open_at = std.mem.findPos(u8, hay, i, element_name) orelse break;
        // Element boundary: what follows must be whitespace, `>`, or `/>`
        // (so `<NameSpace` does not match `<Name`).
        const after = open_at + element_name.len;
        if (after < hay.len) {
            const c = hay[after];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '>' and c != '/') {
                i = after;
                continue;
            }
        }
        // Skip closing tags (`</Name`).
        if (open_at > 0 and hay[open_at - 1] == '/') {
            i = after;
            continue;
        }
        const v = xml.attr(hay, open_at, "value") orelse {
            i = after;
            continue;
        };
        count += 1;
        found = v;
        i = after;
    }
    if (count != 1) return null;
    return found;
}

/// Stock `System.Version.TryParse` subset: 2-4 dot-separated `u16` components.
/// Anything else is invalid (stock warns; load continues with "0.0").
fn versionValid(s: []const u8) bool {
    if (s.len == 0) return false;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        parts += 1;
        if (parts > 4) return false;
        if (std.fmt.parseInt(u16, part, 10) catch null) |_| {} else return false;
    }
    return parts >= 2;
}

/// Parse `ModInfo.xml` V2 (children carry `value` attributes, stock
/// `getElementAttributeValue`). Null = skip the mod; the stock warning is
/// logged. Returned values alias `info` (caller keeps the buffer alive through
/// the mod record build). No comment stripping: a `<!-- <Name ...> -->` inside
/// ModInfo.xml would otherwise need a second buffer that outlives the return.
fn parseModInfo(folder: []const u8, info: []const u8) ?struct {
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
    icon: ?[]const u8,
} {
    const name = childValue(info, "<Name") orelse {
        util_log.warn("zdtd: [MODS]{s}/ModInfo.xml missing or invalid Name; mod skipped\n", .{folder});
        return null;
    };
    // nameValidationRegex is not pinned from IL (G2): enforce the observable
    // stock contract (non-empty, no path separators) plus a sane cap.
    if (name.len == 0 or name.len > 64 or std.mem.findAny(u8, name, "/\\") != null) {
        util_log.warn("zdtd: [MODS]{s}/ModInfo.xml Name '{s}' invalid; mod skipped\n", .{ folder, name });
        return null;
    }
    const display = childValue(info, "<DisplayName") orelse {
        util_log.warn("zdtd: [MODS]{s}/ModInfo.xml missing or invalid DisplayName; mod skipped\n", .{folder});
        return null;
    };
    if (display.len == 0) {
        util_log.warn("zdtd: [MODS]{s}/ModInfo.xml DisplayName empty; mod skipped\n", .{folder});
        return null;
    }
    var version = childValue(info, "<Version") orelse "";
    if (version.len == 0 or !versionValid(version)) {
        util_log.warn("zdtd: [MODS]{s}/ModInfo.xml Version '{s}' invalid; assuming 0.0\n", .{ folder, version });
        version = "0.0";
    }
    const icon = childValue(info, "<Icon");
    return .{ .name = name, .display_name = display, .version = version, .icon = icon };
}

/// Scan `mods_root` for XML-only modlets. A missing root is a no-op (stock:
/// no Mods folder = no mods), not an error.
pub fn scan(allocator: std.mem.Allocator, mods_root: []const u8) !Scan {
    var mods: std.ArrayList(Mod) = .empty;
    errdefer {
        for (mods.items) |*m| m.deinit(allocator);
        mods.deinit(allocator);
    }
    var mod_dirs: std.ArrayList(ModDir) = .empty;
    errdefer {
        for (mod_dirs.items) |md| {
            allocator.free(md.config_dir);
            allocator.free(md.mod_path);
        }
        mod_dirs.deinit(allocator);
    }

    const dir_names = listDirNames(allocator, mods_root) catch |err| switch (err) {
        error.FileNotFound => return .{ .mods = &.{}, .mod_dirs = &.{} },
        else => return err,
    };
    defer {
        for (dir_names) |n| allocator.free(n);
        allocator.free(dir_names);
    }

    for (dir_names) |folder| {
        var path_buf: [2048]u8 = undefined;
        const mod_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ mods_root, folder }) catch continue;
        var mi_buf: [2048]u8 = undefined;
        const mi_path = std.fmt.bufPrint(&mi_buf, "{s}/ModInfo.xml", .{mod_path}) catch continue;
        const info = io_fs.readFileAll(allocator, mi_path) catch |err| switch (err) {
            error.FileNotFound => {
                util_log.warn("zdtd: [MODS]{s}/ModInfo.xml missing; mod skipped\n", .{folder});
                continue;
            },
            else => {
                util_log.warn("zdtd: [MODS]{s}/ModInfo.xml unreadable: {s}; mod skipped\n", .{ folder, @errorName(err) });
                continue;
            },
        };
        defer allocator.free(info);
        const parsed = parseModInfo(folder, info) orelse continue;

        var cfg_buf: [2048]u8 = undefined;
        var config_dir: ?[]const u8 = null;
        if (std.fmt.bufPrint(&cfg_buf, "{s}/Config", .{mod_path})) |p| {
            if (io_fs.dirExists(p)) config_dir = try allocator.dupe(u8, p);
        } else |_| {}

        var bnd_buf: [2048]u8 = undefined;
        var has_bundles = false;
        if (std.fmt.bufPrint(&bnd_buf, "{s}/Bundles", .{mod_path})) |p| {
            has_bundles = io_fs.dirExists(p);
        } else |_| {}

        // Code detection: top-level `.dll` only (stock LoadAssemblies loads
        // the mod's DLLs; exact glob is unverified, G2).
        const dll_names = io_fs.listFileNames(allocator, mod_path) catch null;
        var has_code = false;
        if (dll_names) |dns| {
            defer {
                for (dns) |n| allocator.free(n);
                allocator.free(dns);
            }
            for (dns) |n| {
                if (std.mem.endsWith(u8, n, ".dll")) {
                    has_code = true;
                    break;
                }
            }
        }

        try mods.append(allocator, .{
            .name = try allocator.dupe(u8, parsed.name),
            .display_name = try allocator.dupe(u8, parsed.display_name),
            .path = try allocator.dupe(u8, mod_path),
            .config_dir = config_dir,
            .icon = if (parsed.icon) |ic| (if (ic.len > 0) try allocator.dupe(u8, ic) else null) else null,
            .has_bundles = has_bundles,
            .has_code = has_code,
        });
        if (config_dir) |cd| {
            try mod_dirs.append(allocator, .{
                .config_dir = try allocator.dupe(u8, cd),
                .mod_path = try allocator.dupe(u8, mod_path),
            });
        }
        if (has_code) {
            util_log.warn("zdtd: mod '{s}' contains code (DLL); code part not hosted, XML patches still apply\n", .{parsed.name});
        }
        if (has_bundles) {
            util_log.info("zdtd: mod '{s}' has Bundles/ (client-side rendering; not read by zdtd)\n", .{parsed.name});
        }
        util_log.info("zdtd: modlet '{s}' v{s} '{s}' config={s}\n", .{ parsed.name, parsed.version, parsed.display_name, if (config_dir) |cd| cd else "(none)" });
    }
    return .{
        .mods = try mods.toOwnedSlice(allocator),
        .mod_dirs = try mod_dirs.toOwnedSlice(allocator),
    };
}

/// Installed scan (process lifetime; freed by `deinit` at shutdown).
var installed: ?Scan = null;

pub fn deinit(allocator: std.mem.Allocator) void {
    if (installed) |*s| {
        s.deinit(allocator);
        installed = null;
    }
}

/// Scan `mods_root` and install the result; frees any previous scan.
/// Returns the mod `Config/` dirs + mod paths in mod order (feed to xml_patch
/// via `paths.setModDirs`).
pub fn install(allocator: std.mem.Allocator, mods_root: []const u8) ![]const ModDir {
    const s = try scan(allocator, mods_root);
    if (installed) |*old| old.deinit(allocator);
    installed = s;
    return s.mod_dirs;
}

/// Lookup a mod's absolute path by V2 Name, for `@modfolder(Name):` include
/// token rewriting (stock `ReadPatchXmlWithFixedModFolders`).
pub fn modPathByName(name: []const u8) ?[]const u8 {
    const s = installed orelse return null;
    for (s.mods) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m.path;
    }
    return null;
}

test "parseModInfo accepts V2 and rejects malformed" {
    const ok =
        \\<xml>
        \\  <Name value="TestMod"/>
        \\  <DisplayName value="Test Mod"/>
        \\  <Version value="1.2.3"/>
        \\</xml>
    ;
    const p = parseModInfo("t", ok).?;
    try std.testing.expectEqualStrings("TestMod", p.name);
    try std.testing.expectEqualStrings("1.2.3", p.version);

    const with_icon =
        \\<xml>
        \\  <Name value="IconMod"/>
        \\  <DisplayName value="Icon Mod"/>
        \\  <Version value="1.0"/>
        \\  <Icon value="icon.png"/>
        \\</xml>
    ;
    const pi = parseModInfo("t", with_icon).?;
    try std.testing.expectEqualStrings("icon.png", pi.icon.?);
    // No Icon property: the field is null (not "").
    try std.testing.expect(parseModInfo("t", ok).?.icon == null);

    const no_name =
        \\<xml><DisplayName value="x"/></xml>
    ;
    try std.testing.expect(parseModInfo("t", no_name) == null);

    const dup_name =
        \\<xml><Name value="a"/><Name value="b"/><DisplayName value="x"/></xml>
    ;
    try std.testing.expect(parseModInfo("t", dup_name) == null);

    const no_display =
        \\<xml><Name value="a"/></xml>
    ;
    try std.testing.expect(parseModInfo("t", no_display) == null);
}

test "versionValid matches System.Version.TryParse subset" {
    try std.testing.expect(versionValid("1.0"));
    try std.testing.expect(versionValid("1.2.3.4"));
    try std.testing.expect(!versionValid(""));
    try std.testing.expect(!versionValid("1"));
    try std.testing.expect(!versionValid("1.2.3.4.5"));
    try std.testing.expect(!versionValid("a.b"));
    try std.testing.expect(!versionValid("1.70000"));
}
