//! Thin wrappers around Zig 0.16 `std.Io` for one-shot FS ops.
//! Ordinary file/dir work goes through here or `std.Io` directly, never
//! `std.os.linux` / raw posix in application code.
//!
//! DST: `injectWriteFailures` / `injectReadFailures` force the next N write or
//! read calls to fail so crash/full-disk/torn-read paths can be replayed from
//! a seed without real I/O faults. `util.sim.disable` clears both counters.

const std = @import("std");

/// Remaining synthetic write failures for DST fault injection (0 = off).
var write_fail_remaining: std.atomic.Value(u32) = .init(0);
/// Remaining synthetic read failures for DST fault injection (0 = off).
var read_fail_remaining: std.atomic.Value(u32) = .init(0);

/// Force the next `n` `writeFile` / `writeFileSimple` calls to return
/// `error.DiskQuota` without touching the OS. Pair with a fixed sim seed so
/// the failure lands on the same save step every replay.
pub fn injectWriteFailures(n: u32) void {
    write_fail_remaining.store(n, .release);
}

/// Outstanding synthetic write failures (for tests / harness asserts).
pub fn pendingWriteFailures() u32 {
    return write_fail_remaining.load(.acquire);
}

/// Force the next `n` `readFileAll` / `readFileInto` calls to return
/// `error.InputOutput` without touching the OS. Pair with a fixed sim seed so
/// the failure lands on the same load step every replay.
pub fn injectReadFailures(n: u32) void {
    read_fail_remaining.store(n, .release);
}

/// Outstanding synthetic read failures (for tests / harness asserts).
pub fn pendingReadFailures() u32 {
    return read_fail_remaining.load(.acquire);
}

fn consumeFault(counter: *std.atomic.Value(u32)) bool {
    // CAS loop: only one caller consumes each injected fault.
    while (true) {
        const cur = counter.load(.acquire);
        if (cur == 0) return false;
        if (counter.cmpxchgWeak(cur, cur - 1, .acq_rel, .acquire)) |_| {
            continue;
        } else {
            return true;
        }
    }
}

fn consumeWriteFault() bool {
    return consumeFault(&write_fail_remaining);
}

fn consumeReadFault() bool {
    return consumeFault(&read_fail_remaining);
}

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

/// mkdirPath without a caller allocator (Threaded internals only).
pub fn mkdirPathSimple(rel: []const u8) void {
    mkdirPath(std.heap.page_allocator, rel);
}

pub fn writeFile(allocator: std.mem.Allocator, rel_path: []const u8, data: []const u8) !void {
    _ = allocator;
    if (consumeWriteFault()) return error.DiskQuota;
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
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("zdtd: cleanup temp '{s}' failed: {s}\n", .{ tmp_path, @errorName(err) }),
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), rel_path, io);
}

/// writeFile without a caller allocator (Threaded internals only).
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
    if (consumeReadFault()) return error.InputOutput;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Read up to `buf.len` bytes into `buf`. Returns slice of bytes read.
pub fn readFileInto(allocator: std.mem.Allocator, path: []const u8, buf: []u8) ![]u8 {
    _ = allocator;
    if (consumeReadFault()) return error.InputOutput;
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

/// fileExists without a caller allocator (Threaded internals only).
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

/// dirExists without a caller allocator (Threaded internals only).
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

/// deleteFile without a caller allocator (Threaded internals only).
pub fn deleteFileSimple(path: []const u8) void {
    deleteFile(std.heap.page_allocator, path);
}

/// Best-effort recursive removal of a directory tree (files, subdirs,
/// symlinks). A missing path is a no-op. Used by tests so each scenario world
/// starts fresh instead of inheriting persisted state from a previous run.
pub fn removeDirTreeSimple(rel: []const u8) void {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteTree(io, rel) catch |err| switch (err) {
        error.PathNotFound => {},
        else => std.debug.print("zdtd: remove tree '{s}' failed: {s}\n", .{ rel, @errorName(err) }),
    };
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

/// readLinkAbsolute without a caller allocator (Threaded internals only).
pub fn readLinkAbsoluteSimple(absolute_path: []const u8, buf: []u8) ![]u8 {
    return readLinkAbsolute(std.heap.page_allocator, absolute_path, buf);
}

test "write read roundtrip under cache dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&p_buf, "{s}/io_fs_test.txt", .{dir});
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

test "injectWriteFailures fails then recovers" {
    defer injectWriteFailures(0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&p_buf, "{s}/io_fs_fault.txt", .{dir});
    injectWriteFailures(2);
    try std.testing.expectEqual(@as(u32, 2), pendingWriteFailures());
    try std.testing.expectError(error.DiskQuota, writeFileSimple(p, "x"));
    try std.testing.expectEqual(@as(u32, 1), pendingWriteFailures());
    try std.testing.expectError(error.DiskQuota, writeFileSimple(p, "x"));
    try std.testing.expectEqual(@as(u32, 0), pendingWriteFailures());
    try writeFileSimple(p, "ok");
}

test "injectReadFailures fails then recovers" {
    defer injectReadFailures(0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&p_buf, "{s}/io_fs_read_fault.txt", .{dir});
    try writeFileSimple(p, "payload");
    injectReadFailures(1);
    try std.testing.expectEqual(@as(u32, 1), pendingReadFailures());
    try std.testing.expectError(error.InputOutput, readFileAll(std.testing.allocator, p));
    try std.testing.expectEqual(@as(u32, 0), pendingReadFailures());
    const got = try readFileAll(std.testing.allocator, p);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("payload", got);
}
