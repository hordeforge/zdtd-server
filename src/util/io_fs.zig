//! Thin wrappers around Zig 0.16 `std.Io` for one-shot FS ops.
//! Ordinary file/dir work goes through here or `std.Io` directly, never
//! `std.os.linux` / raw posix in application code.

const std = @import("std");

/// `std.Io.Threaded` bookkeeping only. Always page_allocator so concurrent
/// callers (parallel chunk save, overlapping FS helpers) never share a
/// DebugAllocator/GPA with Threaded.init. Payload/list buffers still use the
/// caller allocator where the API returns owned memory.
fn ioThreaded() std.Io.Threaded {
    return std.Io.Threaded.init(std.heap.page_allocator, .{});
}

pub fn mkdirPath(allocator: std.mem.Allocator, rel: []const u8) void {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    // createDirPath is idempotent for existing dirs; surface real failures
    // (permission, full disk) so later writes are not mysterious.
    std.Io.Dir.cwd().createDirPath(io, rel) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => std.debug.print("zdtd: mkdir '{s}' failed: {s}\n", .{ rel, @errorName(err) }),
    };
}

pub fn mkdirPathSimple(rel: []const u8) void {
    mkdirPath(std.heap.page_allocator, rel);
}

pub fn writeFile(allocator: std.mem.Allocator, rel_path: []const u8, data: []const u8) !void {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |sl| {
        if (sl > 0) try std.Io.Dir.cwd().createDirPath(io, rel_path[0..sl]);
    }
    // Write temp then rename: a crash or full disk mid-write must not corrupt
    // the previous contents (players/chunks/containers all come through here).
    var tmp_buf: [512 + 4]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{rel_path}) catch return error.NameTooLong;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), rel_path, io);
}

pub fn writeFileSimple(rel_path: []const u8, data: []const u8) !void {
    try writeFile(std.heap.page_allocator, rel_path, data);
}

/// List file basenames in `dir_path`, sorted lexicographically.
/// Sort removes readdir order (filesystem / OS dependent) so callers that
/// apply files in list order stay deterministic across machines (DST).
/// Caller frees each name and the slice.
pub fn listFileNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var threaded = ioThreaded();
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
        if (entry.kind != .file) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try names.toOwnedSlice(allocator);
}

/// Read entire file. Caller frees.
pub fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Read up to `buf.len` bytes into `buf`. Returns slice of bytes read.
pub fn readFileInto(allocator: std.mem.Allocator, path: []const u8, buf: []u8) ![]u8 {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    return try std.Io.Dir.cwd().readFile(io, path, buf);
}

/// True if path can be opened for reading as a file.
pub fn fileExists(allocator: std.mem.Allocator, path: []const u8) bool {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// fileExists without requiring a long-lived allocator (Threaded only).
pub fn fileExistsSimple(path: []const u8) bool {
    return fileExists(std.heap.page_allocator, path);
}

/// True if path is an existing directory (or can be opened as one).
pub fn dirExists(allocator: std.mem.Allocator, path: []const u8) bool {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn dirExistsSimple(path: []const u8) bool {
    return dirExists(std.heap.page_allocator, path);
}

/// Best-effort delete; ignores missing path. Other failures are logged.
pub fn deleteFile(allocator: std.mem.Allocator, path: []const u8) void {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("zdtd: delete '{s}' failed: {s}\n", .{ path, @errorName(err) }),
    };
}

pub fn deleteFileSimple(path: []const u8) void {
    deleteFile(std.heap.page_allocator, path);
}

/// Read symlink target into `buf`. Returns slice of `buf` or error.
pub fn readLinkAbsolute(allocator: std.mem.Allocator, absolute_path: []const u8, buf: []u8) ![]u8 {
    _ = allocator;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    const n = try std.Io.Dir.readLinkAbsolute(io, absolute_path, buf);
    return buf[0..n];
}

pub fn readLinkAbsoluteSimple(absolute_path: []const u8, buf: []u8) ![]u8 {
    return readLinkAbsolute(std.heap.page_allocator, absolute_path, buf);
}

test "write read roundtrip under cache dir" {
    const a = std.testing.allocator;
    mkdirPath(a, ".zdtd_cfg_cache");
    const p = ".zdtd_cfg_cache/io_fs_test.txt";
    try writeFile(a, p, "hello");
    const got = try readFileAll(a, p);
    defer a.free(got);
    try std.testing.expectEqualStrings("hello", got);
    try std.testing.expect(fileExists(a, p));
    try std.testing.expect(!fileExistsSimple("/no/such/zdtd_path_xyz"));
    var small: [8]u8 = undefined;
    const into = try readFileInto(a, p, &small);
    try std.testing.expectEqualStrings("hello", into);
    deleteFile(a, p);
    try std.testing.expect(!fileExists(a, p));
}
