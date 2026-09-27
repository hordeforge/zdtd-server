//! Stock ModManager subset for XML-only modlets (no DLL / IModApi hosting).
//!
//! Scans a mods root (`game-dir/Mods` or `--mods-dir`), parses each mod's
//! `ModInfo.xml` (V2), and exposes the mods' `Config/` dirs in mod order so
//! `xml_patch` can apply patches the way stock's `ModManager.LoadPatchStuff`
//! does (`../7dtd-engine-research/docs/admin/mod-loading.md` §1-2, §5.2).
//!
//! Non-goals: never loads DLLs, never reads `Bundles/` content, never runs
//! `IModApi`/`ModEvents`. A code mod's XML patches still apply (stock-like for
//! the XML part) with a loud warning that the code part is not hosted.

const std = @import("std");
const test_tmp = @import("../util/test_tmp.zig");
const io_fs = @import("../util/io_fs.zig");
const parallel = @import("../util/parallel.zig");
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
    /// ModInfo `Version` (validated 2-4 numeric components; "0.0" when the
    /// declared value is invalid). Used by `<conditional>` `mod_version(...)`.
    version: []const u8,
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
        allocator.free(self.version);
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

/// File name of the persisted enable/disable state, next to the world save.
/// One disabled mod `Name` per line; `#` starts a comment; blank lines are
/// ignored; a name that is not installed is harmless (the mod may come back).
pub const state_file_name = "modlets_disabled.txt";

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

/// Load the disabled list from `path` (replacing the in-memory set). Missing
/// file = nothing disabled. Malformed lines are skipped, not fatal: the file
/// is operator-editable. On I/O or OOM failure the previous list is left
/// intact (fail closed): clearing first then aborting would re-enable every
/// disabled modlet with no operator signal.
pub const State = struct {
    /// Mods the operator disabled (owned names), guarded because the webui poll
    /// thread toggles while the roster is read for rendering.
    disabled: std.ArrayList([]const u8) = .empty,
    disabled_lock: parallel.IoMutex = .{},
    /// Absolute path of the state file, set by `install` (owned by `state_alloc`).
    state_path: ?[]const u8 = null,
    /// Allocator that owns `state_path` and the disabled names. Stored so a later
    /// install/deinit from a different allocator (the tests use one DebugAllocator
    /// per Game) never frees another allocator's memory.
    state_alloc: ?std.mem.Allocator = null,
    installed: ?Scan = null,

    /// Free the state in place. Caller holds `disabled_lock`.
    fn freeStateLocked(
        self: *State,
    ) void {
        if (self.state_alloc) |al| {
            for (self.disabled.items) |d| al.free(d);
            self.disabled.deinit(al);
            if (self.state_path) |sp| al.free(sp);
        }
        self.disabled = .empty;
        self.state_path = null;
        self.state_alloc = null;
    }

    /// True when `name` is disabled (case-insensitive, like mod name matching).
    /// Caller must not hold `disabled_lock`.
    pub fn isDisabled(self: *State, name: []const u8) bool {
        self.disabled_lock.lock();
        defer self.disabled_lock.unlock();
        return self.isDisabledLocked(name);
    }

    /// Lock-free form for the loader (which already holds `disabled_lock`; the
    /// mutex is not recursive, so re-locking would deadlock).
    fn isDisabledLocked(self: *State, name: []const u8) bool {
        for (self.disabled.items) |d| {
            if (std.ascii.eqlIgnoreCase(d, name)) return true;
        }
        return false;
    }

    /// Number of disabled mods (roster size minus enabled).
    pub fn disabledCount(
        self: *State,
    ) usize {
        self.disabled_lock.lock();
        defer self.disabled_lock.unlock();
        return self.disabled.items.len;
    }

    fn loadDisabled(self: *State, allocator: std.mem.Allocator, path: []const u8) void {
        self.disabled_lock.lock();
        defer self.disabled_lock.unlock();
        const al = self.state_alloc orelse allocator;
        const raw = io_fs.readFileAll(allocator, path) catch |err| switch (err) {
            error.FileNotFound => {
                for (self.disabled.items) |d| al.free(d);
                self.disabled.clearRetainingCapacity();
                return;
            },
            else => {
                util_log.err(
                    "zdtd: load modlet self.disabled list {s} failed: {s}\n",
                    .{ path, @errorName(err) },
                );
                return;
            },
        };
        defer allocator.free(raw);

        var next: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (self.isDisabledLocked(line)) continue;
            const dup = al.dupe(u8, line) catch {
                util_log.err("zdtd: load modlet self.disabled list {s}: out of memory\n", .{path});
                for (next.items) |d| al.free(d);
                next.deinit(al);
                return;
            };
            next.append(al, dup) catch {
                al.free(dup);
                util_log.err("zdtd: load modlet self.disabled list {s}: out of memory\n", .{path});
                for (next.items) |d| al.free(d);
                next.deinit(al);
                return;
            };
        }

        for (self.disabled.items) |d| al.free(d);
        self.disabled.deinit(al);
        self.disabled = next;
    }

    /// Write the disabled list to `state_path` (create/overwrite). Caller holds no
    /// lock; takes it here.
    fn saveDisabled(self: *State, allocator: std.mem.Allocator) !void {
        const p = self.state_path orelse return;
        self.disabled_lock.lock();
        defer self.disabled_lock.unlock();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "# zdtd modlets self.disabled by the operator (webui / file edit); restart to apply\n");
        for (self.disabled.items) |d| {
            try buf.appendSlice(allocator, d);
            try buf.append(allocator, '\n');
        }
        try io_fs.writeFile(p, buf.items);
    }

    /// Enable/disable one mod by name, persisting the state file. Returns false
    /// when the name is not installed (no state change).
    pub fn setDisabled(self: *State, allocator: std.mem.Allocator, name: []const u8, disable: bool) !bool {
        const al = self.state_alloc orelse allocator;
        var known = false;
        if (self.installed) |*s| {
            for (s.mods) |*m| {
                if (std.ascii.eqlIgnoreCase(m.name, name)) {
                    known = true;
                    break;
                }
            }
        }
        if (!known) return false;
        {
            // The mutex is not reentrant and `saveDisabled` locks it itself, so
            // only the mutation runs under the lock; the scoped defer releases it
            // on the error paths too (an OOM must not wedge the webui poller).
            self.disabled_lock.lock();
            defer self.disabled_lock.unlock();
            if (disable) {
                var present = false;
                for (self.disabled.items) |d| {
                    if (std.ascii.eqlIgnoreCase(d, name)) {
                        present = true;
                        break;
                    }
                }
                if (!present) {
                    const dup = try al.dupe(u8, name);
                    errdefer al.free(dup);
                    try self.disabled.append(al, dup);
                }
            } else {
                var i: usize = 0;
                while (i < self.disabled.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.disabled.items[i], name)) {
                        al.free(self.disabled.items[i]);
                        _ = self.disabled.swapRemove(i);
                        continue;
                    }
                    i += 1;
                }
            }
        }
        try self.saveDisabled(allocator);
        return true;
    }

    /// Roster size (installed mods, enabled or not).
    pub fn rosterLen(
        self: *State,
    ) usize {
        const s = self.installed orelse return 0;
        return s.mods.len;
    }

    /// Roster entry by index, for the operator UI. Null past the end.
    pub fn rosterAt(self: *State, i: usize) ?*const Mod {
        const s = self.installed orelse return null;
        if (i >= s.mods.len) return null;
        return &s.mods[i];
    }

    /// Scan `mods_root` for XML-only modlets. A missing root is a no-op (stock:
    /// no Mods folder = no mods), not an error. `state_path_in` (optional) is the
    /// persisted disabled list; the roster keeps every installed mod while
    /// `mod_dirs` carries only the enabled ones.
    pub fn scan(self: *State, allocator: std.mem.Allocator, mods_root: []const u8, state_path_in: ?[]const u8) !Scan {
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

        {
            self.disabled_lock.lock();
            defer self.disabled_lock.unlock();
            self.freeStateLocked();
            self.state_alloc = allocator;
            if (state_path_in) |sp| {
                self.state_path = try allocator.dupe(u8, sp);
            }
        }
        self.loadDisabled(allocator, self.state_path orelse "");

        const dir_names = io_fs.listDirNames(allocator, mods_root) catch |err| switch (err) {
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

            // Fill the row field by field: a `try` inside an append argument
            // list aborts the whole statement and orphans the strings already
            // duped, so the row is built under one errdefer and handed to
            // `mods` (which takes ownership) only once complete.
            var row = Mod{
                .name = try allocator.dupe(u8, parsed.name),
                .display_name = "",
                .path = "",
                .config_dir = config_dir,
                .version = "",
                .has_bundles = has_bundles,
                .has_code = has_code,
            };
            var row_moved = false;
            errdefer if (!row_moved) row.deinit(allocator);
            row.display_name = try allocator.dupe(u8, parsed.display_name);
            row.path = try allocator.dupe(u8, mod_path);
            row.version = try allocator.dupe(u8, parsed.version);
            if (parsed.icon) |ic| {
                if (ic.len > 0) row.icon = try allocator.dupe(u8, ic);
            }
            try mods.append(allocator, row);
            row_moved = true;
            if (config_dir) |cd| {
                if (!self.isDisabled(parsed.name)) {
                    // Same rule as the row above: on a failed dupe the
                    // already-taken `config_dir` copy is released.
                    var md = ModDir{
                        .config_dir = try allocator.dupe(u8, cd),
                        .mod_path = "",
                    };
                    var md_moved = false;
                    errdefer if (!md_moved) {
                        allocator.free(md.config_dir);
                        allocator.free(md.mod_path);
                    };
                    md.mod_path = try allocator.dupe(u8, mod_path);
                    try mod_dirs.append(allocator, md);
                    md_moved = true;
                }
            }
            if (has_code) {
                util_log.warn("zdtd: mod '{s}' contains code (DLL); code part not hosted, XML patches still apply\n", .{parsed.name});
            }
            if (has_bundles) {
                util_log.info("zdtd: mod '{s}' has Bundles/ (client-side rendering; not read by zdtd)\n", .{parsed.name});
            }
            if (self.isDisabled(parsed.name)) {
                util_log.info("zdtd: modlet '{s}' v{s} self.disabled by operator; patches not applied\n", .{ parsed.name, parsed.version });
            } else {
                util_log.info("zdtd: modlet '{s}' v{s} '{s}' config={s}\n", .{ parsed.name, parsed.version, parsed.display_name, if (config_dir) |cd| cd else "(none)" });
            }
        }
        return .{
            .mods = try mods.toOwnedSlice(allocator),
            .mod_dirs = try mod_dirs.toOwnedSlice(allocator),
        };
    }

    /// Installed scan (process lifetime; freed by `deinit` at shutdown).
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.installed) |*s| {
            s.deinit(allocator);
            self.installed = null;
        }
        self.disabled_lock.lock();
        defer self.disabled_lock.unlock();
        self.freeStateLocked();
    }

    /// Scan `mods_root` and install the result; frees any previous scan.
    /// Returns the mod `Config/` dirs + mod paths in mod order (feed to xml_patch
    /// via `paths.setModDirs`).
    pub fn install(self: *State, allocator: std.mem.Allocator, mods_root: []const u8, state_path_in: ?[]const u8) ![]const ModDir {
        const s = try self.scan(allocator, mods_root, state_path_in);
        if (self.installed) |*old| old.deinit(allocator);
        self.installed = s;
        return s.mod_dirs;
    }

    /// True when a scanned mod carries `name` (case-insensitive).
    pub fn isLoaded(self: *State, name: []const u8) bool {
        const sc = self.installed orelse return false;
        for (sc.mods) |*m| {
            if (std.ascii.eqlIgnoreCase(m.name, name)) return true;
        }
        return false;
    }

    /// A scanned mod's version by Name.
    pub fn versionByName(self: *State, name: []const u8) ?[]const u8 {
        const sc = self.installed orelse return null;
        for (sc.mods) |*m| {
            if (std.ascii.eqlIgnoreCase(m.name, name)) return m.version;
        }
        return null;
    }

    /// A scanned mod's absolute path by V2 Name.
    pub fn modPathByName(self: *State, name: []const u8) ?[]const u8 {
        const sc = self.installed orelse return null;
        for (sc.mods) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m.path;
        }
        return null;
    }
};

/// Load-window borrow for the XML patchers: `mod_loaded('X')`,
/// `mod_version('X')` and `@modfolder(X)` evaluate inside `readConfigXml`
/// during the Game's `loadAssets`, which binds the loading Game's state for
/// exactly that call (nil reads as "no mods", matching an empty roster).
var active: ?*State = null;

pub fn bind(s: *State) void {
    active = s;
}

pub fn unbind() void {
    active = null;
}

/// True when a scanned mod carries `name` (case-insensitive), for patch
/// `<conditional>` `mod_loaded('X')` tests.
pub fn isLoaded(name: []const u8) bool {
    const st = active orelse return false;
    return st.isLoaded(name);
}

/// A scanned mod's version by Name, for `mod_version('X')` tests.
pub fn versionByName(name: []const u8) ?[]const u8 {
    const st = active orelse return null;
    return st.versionByName(name);
}

/// Lookup a mod's absolute path by V2 Name, for `@modfolder(Name):` include
/// token rewriting (stock `ReadPatchXmlWithFixedModFolders`).
pub fn modPathByName(name: []const u8) ?[]const u8 {
    const st = active orelse return null;
    return st.modPathByName(name);
}

test "disabled modlets are listed but their patches are not applied" {
    // The state file lives next to the world save; one disabled Name per line.
    // A disabled mod stays on the roster (the webui lists it) while its
    // Config/ dir is left out of the patch list.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try test_tmp.rootOf(&tmp);
    const mods_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods", .{root});
    defer std.testing.allocator.free(mods_root);
    const enabled_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/AEnabled/Config", .{mods_root});
    defer std.testing.allocator.free(enabled_dir);
    const disabled_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/BDisabled/Config", .{mods_root});
    defer std.testing.allocator.free(disabled_dir);
    io_fs.mkdirPath(enabled_dir);
    io_fs.mkdirPath(disabled_dir);
    const mi_a = try std.fmt.allocPrint(std.testing.allocator, "{s}/AEnabled/ModInfo.xml", .{mods_root});
    defer std.testing.allocator.free(mi_a);
    const mi_b = try std.fmt.allocPrint(std.testing.allocator, "{s}/BDisabled/ModInfo.xml", .{mods_root});
    defer std.testing.allocator.free(mi_b);
    try io_fs.writeFile(mi_a, "<xml><Name value=\"AEnabled\"/><DisplayName value=\"A\"/><Version value=\"1.0\"/></xml>");
    try io_fs.writeFile(mi_b, "<xml><Name value=\"BDisabled\"/><DisplayName value=\"B\"/><Version value=\"2.0\"/></xml>");
    const items_a = try std.fmt.allocPrint(std.testing.allocator, "{s}/items.xml", .{enabled_dir});
    defer std.testing.allocator.free(items_a);
    try io_fs.writeFile(items_a, "<configs><append xpath=\"/items\"><item name=\"fromA\"/></append></configs>");
    const items_b = try std.fmt.allocPrint(std.testing.allocator, "{s}/items.xml", .{disabled_dir});
    defer std.testing.allocator.free(items_b);
    try io_fs.writeFile(items_b, "<configs><append xpath=\"/items\"><item name=\"fromB\"/></append></configs>");

    const state = try std.fmt.allocPrint(std.testing.allocator, "{s}/modlets_disabled.txt", .{root});
    defer std.testing.allocator.free(state);
    try io_fs.writeFile(state, "# operator state\nBDisabled\n");

    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    const dirs = try st.install(std.testing.allocator, mods_root, state);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expect(std.mem.find(u8, dirs[0].config_dir, "AEnabled") != null);
    try std.testing.expectEqual(@as(usize, 2), st.rosterLen());
    try std.testing.expect(st.isDisabled("bdisabled"));
    try std.testing.expect(!st.isDisabled("AEnabled"));
    try std.testing.expectEqual(@as(usize, 1), st.disabledCount());

    // Re-enabling writes the file back without that name.
    try std.testing.expect(try st.setDisabled(std.testing.allocator, "BDisabled", false));
    try std.testing.expect(!st.isDisabled("BDisabled"));
    try std.testing.expectEqual(@as(usize, 0), st.disabledCount());
    const after = try io_fs.readFileAll(std.testing.allocator, state);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.find(u8, after, "BDisabled") == null);
    // An unknown name is refused (no state change).
    try std.testing.expect(!try st.setDisabled(std.testing.allocator, "NoSuchMod", true));
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
