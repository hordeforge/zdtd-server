//! Resolve Data/Config XML paths, optional modlet + override patch dirs,
//! generic tryLoad.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml_patch = @import("xml_patch.zig");
const mods = @import("modlets.zig");

/// Prefer `config_dir/<file>`, else `game_dir/Data/Config/<file>`.
/// Writes into `path_buf`; returns null if neither dir is set or path too long.
pub fn resolveConfigXml(
    path_buf: []u8,
    file_name: []const u8,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
) ?[]const u8 {
    if (config_dir) |cd| {
        return std.fmt.bufPrint(path_buf, "{s}/{s}", .{ cd, file_name }) catch null;
    }
    if (game_dir) |gd| {
        return std.fmt.bufPrint(path_buf, "{s}/Data/Config/{s}", .{ gd, file_name }) catch null;
    }
    return null;
}

/// Optional modlet `Config/` dirs (stock mod order, PRD R6: applied before
/// operator overrides). Owned by paths (see setModDirs) so Game teardown -
/// which frees the mods scan these come from - cannot leave loaders with
/// dangling dirs. Set at Game init from `mods.install`.
var mod_dirs_owned: []mods.ModDir = &.{};
pub var mod_dirs: []const mods.ModDir = &.{};

/// Optional override directories (xpath patch XMLs, filename order). Set at Game init.
pub var override_dirs: []const []const u8 = &.{};

fn freeOwnedModDirs(allocator: std.mem.Allocator, owned: []mods.ModDir, n: usize) void {
    for (owned[0..n]) |md| {
        allocator.free(md.config_dir);
        allocator.free(md.mod_path);
    }
    allocator.free(owned);
}

pub fn setModDirs(allocator: std.mem.Allocator, dirs: []const mods.ModDir) void {
    deinitModDirs(allocator);
    if (dirs.len == 0) return; // deinitModDirs already cleared the vars
    const owned = allocator.alloc(mods.ModDir, dirs.len) catch return;
    var filled: usize = 0;
    for (dirs, 0..) |d, idx| {
        owned[idx].config_dir = allocator.dupe(u8, d.config_dir) catch {
            freeOwnedModDirs(allocator, owned, filled);
            return;
        };
        owned[idx].mod_path = allocator.dupe(u8, d.mod_path) catch {
            allocator.free(owned[idx].config_dir);
            freeOwnedModDirs(allocator, owned, filled);
            return;
        };
        filled = idx + 1;
    }
    mod_dirs_owned = owned;
    mod_dirs = owned;
}

pub fn deinitModDirs(allocator: std.mem.Allocator) void {
    for (mod_dirs_owned) |md| {
        allocator.free(md.config_dir);
        allocator.free(md.mod_path);
    }
    if (mod_dirs_owned.len > 0) allocator.free(mod_dirs_owned);
    mod_dirs_owned = &.{};
    mod_dirs = &.{};
}

pub fn setOverrideDirs(dirs: []const []const u8) void {
    override_dirs = dirs;
}

/// True when any patch source is configured (fast-path guard for loaders).
pub fn hasPatches() bool {
    return mod_dirs.len > 0 or override_dirs.len > 0;
}

/// Read base config XML and apply modlet patches (fatal on error, PRD R6) then
/// --config-overrides patches (optional) for this file.
/// Caller owns returned slice. Null if base path missing / unreadable.
pub fn readConfigXml(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
) !?[]u8 {
    var path_buf: [2048]u8 = undefined;
    const path = resolveConfigXml(&path_buf, file_name, game_dir, config_dir) orelse return null;
    // Missing base is "catalog absent"; permission/corrupt/OOM must not look the same.
    const base = io_fs.readFileAll(allocator, path) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print(
                "zdtd: read config {s} failed: {s} ({s})\n",
                .{ file_name, @errorName(err), path },
            ),
        }
        return null;
    };
    if (!hasPatches()) return base;
    var cur: []u8 = base;
    if (mod_dirs.len > 0) {
        // Modlet patches are mandatory: a patch that fails to apply changes
        // AssignIds vs the client, so the server must not start (PRD R6).
        const m = xml_patch.applyModDirs(allocator, cur, file_name, mod_dirs) catch |err| {
            std.debug.print(
                "zdtd: mod patches for {s} failed: {s}; refusing to start (modlet desync risk)\n",
                .{ file_name, @errorName(err) },
            );
            allocator.free(cur);
            return err;
        };
        allocator.free(cur);
        cur = m;
    }
    if (override_dirs.len > 0) {
        // Operator overrides stay optional: a bad override must not blank the
        // catalog; keep the mod-patched bytes.
        const m2 = xml_patch.applyOverrideDirs(allocator, cur, file_name, override_dirs) catch |err| {
            std.debug.print(
                "zdtd: config overrides for {s} failed: {s}; keeping mod-patched base\n",
                .{ file_name, @errorName(err) },
            );
            return cur;
        };
        allocator.free(cur);
        cur = m2;
    }
    return cur;
}

/// Load via `loadFn(allocator, path) !T` using config path resolution (no patches).
/// Thin wrapper kept: 4 call sites use the no-patch path and should not spell the
/// null `loadFromBytes` sentinel or pay the merge/cache branch.
pub fn tryLoadConfig(
    comptime file_name: []const u8,
    comptime T: type,
    comptime loadFn: *const fn (std.mem.Allocator, []const u8) anyerror!T,
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
) !?T {
    return tryLoadConfigPatched(file_name, T, loadFn, null, allocator, game_dir, config_dir);
}

/// Like tryLoadConfig but applies override patches. If `loadFromBytes` is set, parse
/// merged bytes directly; else write a temp file under the process cwd `.zdtd_cfg_cache/`
/// (disk-backed, not tmpfs) and call loadFn(path).
pub fn tryLoadConfigPatched(
    comptime file_name: []const u8,
    comptime T: type,
    comptime loadFn: *const fn (std.mem.Allocator, []const u8) anyerror!T,
    comptime loadFromBytes: ?*const fn (std.mem.Allocator, []const u8) anyerror!T,
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
) !?T {
    if (!hasPatches()) {
        var path_buf: [2048]u8 = undefined;
        const path = resolveConfigXml(&path_buf, file_name, game_dir, config_dir) orelse return null;
        return loadFn(allocator, path) catch |err| {
            logCatalogLoadFail(file_name, path, err);
            return null;
        };
    }
    const merged = try readConfigXml(allocator, file_name, game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    if (loadFromBytes) |lbytes| {
        return lbytes(allocator, merged) catch |err| {
            logCatalogLoadFail(file_name, "(patched bytes)", err);
            return null;
        };
    }
    // Cache patched XML next to cwd (not tmpfs /tmp).
    io_fs.mkdirPath(".zdtd_cfg_cache");
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, ".zdtd_cfg_cache/{s}", .{file_name}) catch return null;
    io_fs.writeFile(cache_path, merged) catch |err| {
        std.debug.print("zdtd: write config cache {s} failed: {s}\n", .{ cache_path, @errorName(err) });
        return null;
    };
    return loadFn(allocator, cache_path) catch |err| {
        logCatalogLoadFail(file_name, cache_path, err);
        return null;
    };
}

/// Missing / empty catalogs are expected without a full game install. Parse, I/O, and
/// OOM failures must not look like "catalog absent".
fn logCatalogLoadFail(file_name: []const u8, path: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound, error.OpenFailed => {},
        else => std.debug.print(
            "zdtd: load {s} failed: {s} ({s})\n",
            .{ file_name, @errorName(err), path },
        ),
    }
}

test "resolveConfigXml prefers config_dir" {
    var buf: [256]u8 = undefined;
    const p = resolveConfigXml(&buf, "blocks.xml", "/game", "/cfg").?;
    try std.testing.expectEqualStrings("/cfg/blocks.xml", p);
    const p2 = resolveConfigXml(&buf, "blocks.xml", "/game", null).?;
    try std.testing.expectEqualStrings("/game/Data/Config/blocks.xml", p2);
}
