//! Thin wrappers around Zig 0.16 `std.Io` for one-shot FS ops.
//! Ordinary file/dir work goes through here or `std.Io` directly, never
//! `std.os.linux` / raw posix in application code.
//!
//! Each helper constructs a short-lived `std.Io.Threaded` so it can nest
//! inside a bound UDP/TCP Threaded (those save/restore SIGIO/SIGPIPE).
//!
//! DST: `injectWriteFailures` / `injectReadFailures` force the next N write or
//! read calls to fail so crash/full-disk/torn-read paths can be replayed from
//! a seed without real I/O faults. `util.sim.disable` clears both counters.

const std = @import("std");
const util_log = @import("log.zig");

/// Remaining synthetic write failures for DST fault injection (0 = off).
var write_fail_remaining: std.atomic.Value(u32) = .init(0);
/// Remaining synthetic read failures for DST fault injection (0 = off).
var read_fail_remaining: std.atomic.Value(u32) = .init(0);

/// Force the next `n` `writeFile` calls to return
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

/// `std.Io.Threaded` bookkeeping only. Always page_allocator so concurrent
/// callers (parallel chunk save, overlapping FS helpers) never share a
/// DebugAllocator/GPA with Threaded.init. Payload/list buffers still use the
/// caller allocator where the API returns owned memory. Paired init/deinit
/// so this can nest inside a bound socket Threaded.
fn ioThreaded() std.Io.Threaded {
    return std.Io.Threaded.init(std.heap.page_allocator, .{});
}

pub fn mkdirPath(rel: []const u8) void {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    // createDirPath is idempotent for existing dirs; surface real failures
    // (permission, full disk) so later writes are not mysterious.
    std.Io.Dir.cwd().createDirPath(io, rel) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => util_log.err("zdtd: mkdir '{s}' failed: {s}\n", .{ rel, @errorName(err) }),
    };
}

pub fn writeFile(rel_path: []const u8, data: []const u8) !void {
    if (consumeFault(&write_fail_remaining)) return error.DiskQuota;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    // Atomic materialize: a crash or full disk mid-write must not corrupt
    // the previous contents (players/chunks/containers all come through here).
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, rel_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    var wbuf: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &wbuf);
    file_writer.interface.writeAll(data) catch return file_writer.err.?;
    try file_writer.flush();
    try atomic_file.replace(io);
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

/// List subdirectory names under `dir_path`, sorted ascending for
/// deterministic iteration (sim rule 22). Caller frees each name and the
/// slice. Used by mod discovery (PRD 0005): a mod is a directory holding
/// `manifest.toml`.
pub fn listDirNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
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

/// Read entire file. Caller frees.
pub fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (consumeFault(&read_fail_remaining)) return error.InputOutput;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Read up to `buf.len` bytes into `buf`. Returns slice of bytes read.
pub fn readFileInto(path: []const u8, buf: []u8) ![]u8 {
    if (consumeFault(&read_fail_remaining)) return error.InputOutput;
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    return try std.Io.Dir.cwd().readFile(io, path, buf);
}

/// True if path can be opened for reading as a file.
pub fn fileExists(path: []const u8) bool {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Last-modification time in nanos, or null when the path is missing or not
/// statable. Used for change-polling (serveradmin.xml hot-reload); the tick
/// compares this to the value seen at the last apply.
pub fn fileMtimeNanos(path: []const u8) ?i64 {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    return @intCast(st.mtime.nanoseconds);
}

/// True if path is an existing directory (or can be opened as one).
pub fn dirExists(path: []const u8) bool {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Best-effort delete; ignores missing path. Other failures are logged.
pub fn deleteFile(path: []const u8) void {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => util_log.err("zdtd: delete '{s}' failed: {s}\n", .{ path, @errorName(err) }),
    };
}

/// Best-effort recursive removal of a directory tree (files, subdirs,
/// symlinks). A missing path is a no-op. Used by tests so each scenario world
/// starts fresh instead of inheriting persisted state from a previous run.
pub fn removeDirTree(rel: []const u8) void {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    // A missing path is a no-op (deleteTree returns null), so only real
    // failures surface here.
    std.Io.Dir.cwd().deleteTree(io, rel) catch |err| {
        util_log.err("zdtd: remove tree '{s}' failed: {s}\n", .{ rel, @errorName(err) });
    };
}

/// Read symlink target into `buf`. Returns slice of `buf` or error.
pub fn readLinkAbsolute(absolute_path: []const u8, buf: []u8) ![]u8 {
    var threaded = ioThreaded();
    defer threaded.deinit();
    const io = threaded.io();
    const n = try std.Io.Dir.readLinkAbsolute(io, absolute_path, buf);
    return buf[0..n];
}

test "write read roundtrip under cache dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&p_buf, "{s}/io_fs_test.txt", .{dir});
    try writeFile(p, "hello");
    const got = try readFileAll(a, p);
    defer a.free(got);
    try std.testing.expectEqualStrings("hello", got);
    try std.testing.expect(fileExists(p));
    try std.testing.expect(!fileExists("/no/such/zdtd_path_xyz"));
    var small: [8]u8 = undefined;
    const into = try readFileInto(p, &small);
    try std.testing.expectEqualStrings("hello", into);
    deleteFile(p);
    try std.testing.expect(!fileExists(p));
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
    try std.testing.expectError(error.DiskQuota, writeFile(p, "x"));
    try std.testing.expectEqual(@as(u32, 1), pendingWriteFailures());
    try std.testing.expectError(error.DiskQuota, writeFile(p, "x"));
    try std.testing.expectEqual(@as(u32, 0), pendingWriteFailures());
    try writeFile(p, "ok");
}

test "injectReadFailures fails then recovers" {
    defer injectReadFailures(0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&p_buf, "{s}/io_fs_read_fault.txt", .{dir});
    try writeFile(p, "payload");
    injectReadFailures(1);
    try std.testing.expectEqual(@as(u32, 1), pendingReadFailures());
    try std.testing.expectError(error.InputOutput, readFileAll(std.testing.allocator, p));
    try std.testing.expectEqual(@as(u32, 0), pendingReadFailures());
    const got = try readFileAll(std.testing.allocator, p);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("payload", got);
}
