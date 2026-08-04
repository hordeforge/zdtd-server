//! Resolve Data/Config XML paths, optional override patch dirs, generic tryLoad.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const xml_patch = @import("xml_patch.zig");

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

/// Optional override directories (xpath patch XMLs, filename order). Set at Game init.
pub var override_dirs: []const []const u8 = &.{};

pub fn setOverrideDirs(dirs: []const []const u8) void {
    override_dirs = dirs;
}

/// Read base config XML and apply --config-overrides patches for this file.
/// Caller owns returned slice. Null if base path missing / unreadable.
pub fn readConfigXml(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
) !?[]u8 {
    var path_buf: [2048]u8 = undefined;
    const path = resolveConfigXml(&path_buf, file_name, game_dir, config_dir) orelse return null;
    const base = io_fs.readFileAll(allocator, path) catch return null;
    errdefer allocator.free(base);
    if (override_dirs.len == 0) return base;
    const merged = xml_patch.applyOverrideDirs(allocator, base, file_name, override_dirs) catch {
        return base;
    };
    allocator.free(base);
    return merged;
}

/// Load via `loadFn(allocator, path) !T` using config path resolution (no patches).
/// Prefer tryLoadConfigPatched when overrides may be set.
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
    if (override_dirs.len == 0) {
        var path_buf: [2048]u8 = undefined;
        const path = resolveConfigXml(&path_buf, file_name, game_dir, config_dir) orelse return null;
        return loadFn(allocator, path) catch null;
    }
    const merged = try readConfigXml(allocator, file_name, game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    if (loadFromBytes) |lbytes| {
        return lbytes(allocator, merged) catch null;
    }
    // Cache patched XML next to cwd (not tmpfs /tmp).
    io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, ".zdtd_cfg_cache/{s}", .{file_name}) catch return null;
    io_fs.writeFile(allocator, cache_path, merged) catch return null;
    return loadFn(allocator, cache_path) catch null;
}

test "resolveConfigXml prefers config_dir" {
    var buf: [256]u8 = undefined;
    const p = resolveConfigXml(&buf, "blocks.xml", "/game", "/cfg").?;
    try std.testing.expectEqualStrings("/cfg/blocks.xml", p);
    const p2 = resolveConfigXml(&buf, "blocks.xml", "/game", null).?;
    try std.testing.expectEqualStrings("/game/Data/Config/blocks.xml", p2);
}
