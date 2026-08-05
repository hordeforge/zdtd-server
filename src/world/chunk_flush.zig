//! Async chunk flush: encode on the tick thread, write on one background thread.
//!
//! Shape mirrors stock `RegionFileManager` (Assembly-CSharp.dll IL): it keeps a
//! pending map `chunksToSave` (asm.il:1178765), a serialized-snapshot map
//! `chunkMemoryStreamsToSave` (asm.il:1178768), the key under the writer's hand
//! `chunkKeyCurrentlySaved` (asm.il:1178778), a `saveLock` (asm.il:1178791) and
//! one writer thread `thread_SaveChunks` (spawn asm.il:1178937, body
//! asm.il:1182397). `IsChunkSavedAndDormant` (asm.il:1182993) refuses to treat a
//! chunk as on-disk while it is queued or currently being written; `waitKey`
//! here is the same guard, and `WaitSaveDone` (asm.il:1183341) is `deinit`.
//!
//! Double buffering: the queued payloads *are* the second buffer. `Chunk.dirty`
//! is cleared at encode time on the tick thread, so edits that land while a
//! write is in flight accumulate into a fresh dirty set and are picked up by the
//! next `saveAll`. Nothing here ever touches live `Chunk` memory.
//!
//! Ownership: `submit` takes `path` and `payload`, both allocated from
//! `std.heap.page_allocator` (never `World.allocator`, which is a
//! DebugAllocator/GPA and is not thread-safe), and the writer thread frees them.
//!
//! Limitation: `io_fs.injectWriteFailures` faults are consumed on the writer
//! thread, so they surface as the `errors` counter rather than as an error
//! return from `saveAll`. DST therefore keeps the flush synchronous
//! (`World.asyncEnabled` returns false under `parallel.isForceSerial`).

const std = @import("std");
const builtin = @import("builtin");
const io_fs = @import("../util/io_fs.zig");
const parallel = @import("../util/parallel.zig");

/// Queue depth. A full queue falls back to a synchronous write, never drops.
pub const max_pending: usize = 512;
/// Byte budget for queued payloads (~64 MiB, i.e. ~76 fully populated chunks).
pub const max_pending_bytes: usize = 64 * 1024 * 1024;

const Entry = struct {
    key: u64,
    path: []u8,
    payload: []u8,
};

pub const SubmitError = error{
    /// Count or byte budget reached; caller writes synchronously instead.
    QueueFull,
    /// `deinit` already ran (shutdown). Caller writes synchronously instead.
    Shutdown,
};

pub const Flusher = struct {
    mu: std.Io.Mutex = .init,
    /// Signalled on submit and on shutdown.
    work_cv: std.Io.Condition = .init,
    /// Broadcast after every completed write (waitKey / waitAll wake here).
    done_cv: std.Io.Condition = .init,

    ring: [max_pending]Entry = undefined,
    /// Index of the oldest queued entry; the writer pops here (FIFO per key).
    head: usize = 0,
    n: usize = 0,
    bytes: usize = 0,
    /// Stock `chunkKeyCurrentlySaved`: the key the writer has popped but not
    /// finished. A `waitKey` on it must block, or a read races the write.
    cur_key: u64 = 0,
    cur_active: bool = false,
    shutdown: bool = false,
    thread: ?std.Thread = null,
    /// Published (release) after the writer spawns. Read lock-free by the wait
    /// helpers so the never-async case costs one atomic load, not a mutex.
    started: std.atomic.Value(bool) = .init(false),

    /// Sampled as deltas by the tick thread and pushed into apm counters
    /// (`world` may not import `apm`, see src/world/root.zig).
    queued: std.atomic.Value(u64) = .init(0),
    written: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    waits: std.atomic.Value(u64) = .init(0),

    /// True when a background writer can run at all (never in single-threaded builds).
    pub fn available() bool {
        return !builtin.single_threaded;
    }

    /// Take ownership of `path` and `payload` (page_allocator) and queue a write.
    /// On error the caller still owns both and must write/free them itself.
    pub fn submit(self: *Flusher, key: u64, path: []u8, payload: []u8) SubmitError!void {
        if (!available()) return error.Shutdown;
        const io = parallel.poolIo();
        self.mu.lockUncancelable(io);
        if (self.shutdown) {
            self.mu.unlock(io);
            return error.Shutdown;
        }
        if (self.n >= max_pending or self.bytes + payload.len > max_pending_bytes) {
            self.mu.unlock(io);
            return error.QueueFull;
        }
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, writerMain, .{self}) catch |err| {
                self.mu.unlock(io);
                std.debug.print("zdtd: chunk flush writer spawn failed: {s}; writing inline\n", .{@errorName(err)});
                return error.Shutdown;
            };
            self.started.store(true, .release);
        }
        self.ring[(self.head + self.n) % max_pending] = .{ .key = key, .path = path, .payload = payload };
        self.n += 1;
        self.bytes += payload.len;
        _ = self.queued.fetchAdd(1, .monotonic);
        self.work_cv.signal(io);
        self.mu.unlock(io);
    }

    fn pendingLocked(self: *const Flusher, key: u64) bool {
        if (self.cur_active and self.cur_key == key) return true;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.ring[(self.head + i) % max_pending].key == key) return true;
        }
        return false;
    }

    /// Block until nothing for `key` is queued or in flight. No-op when idle.
    /// Gates disk reads and evictions so a stale file is never read back.
    pub fn waitKey(self: *Flusher, key: u64) void {
        if (!available() or !self.started.load(.acquire)) return;
        const io = parallel.poolIo();
        self.mu.lockUncancelable(io);
        var waited = false;
        while (self.pendingLocked(key)) {
            waited = true;
            self.done_cv.waitUncancelable(io, &self.mu);
        }
        self.mu.unlock(io);
        if (waited) _ = self.waits.fetchAdd(1, .monotonic);
    }

    /// Block until the queue is empty and the writer is idle.
    pub fn waitAll(self: *Flusher) void {
        if (!available() or !self.started.load(.acquire)) return;
        const io = parallel.poolIo();
        self.mu.lockUncancelable(io);
        var waited = false;
        while (self.n > 0 or self.cur_active) {
            waited = true;
            self.done_cv.waitUncancelable(io, &self.mu);
        }
        self.mu.unlock(io);
        if (waited) _ = self.waits.fetchAdd(1, .monotonic);
    }

    /// Queued payload count (test / apm gauge).
    pub fn pending(self: *Flusher) usize {
        if (!available()) return 0;
        const io = parallel.poolIo();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        return self.n + @as(usize, if (self.cur_active) 1 else 0);
    }

    /// Drain every queued write, then join the writer. Joined, never detached:
    /// a detached writer would lose queued chunks at process exit. Terminal:
    /// later `submit` calls return `error.Shutdown` and fall back to sync.
    pub fn deinit(self: *Flusher) void {
        if (!available()) return;
        if (!self.started.load(.acquire) and !self.shutdown) {
            // Never spawned: nothing queued, nothing to join.
            self.shutdown = true;
            std.debug.assert(self.n == 0);
            return;
        }
        const io = parallel.poolIo();
        self.mu.lockUncancelable(io);
        self.shutdown = true;
        self.work_cv.broadcast(io);
        self.mu.unlock(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // Writer exits only after the ring is empty; assert rather than leak.
        std.debug.assert(self.n == 0);
    }

    fn writerMain(self: *Flusher) void {
        const io = parallel.poolIo();
        const a = std.heap.page_allocator;
        while (true) {
            self.mu.lockUncancelable(io);
            while (self.n == 0 and !self.shutdown) self.work_cv.waitUncancelable(io, &self.mu);
            if (self.n == 0) {
                // shutdown with an empty ring: every queued write landed.
                self.mu.unlock(io);
                return;
            }
            const e = self.ring[self.head];
            self.head = (self.head + 1) % max_pending;
            self.n -= 1;
            self.bytes -= e.payload.len;
            self.cur_key = e.key;
            self.cur_active = true;
            self.mu.unlock(io);

            io_fs.writeFile(a, e.path, e.payload) catch |err| {
                _ = self.errors.fetchAdd(1, .monotonic);
                std.debug.print("zdtd: async chunk write '{s}' failed: {s}\n", .{ e.path, @errorName(err) });
            };
            a.free(e.path);
            a.free(e.payload);

            self.mu.lockUncancelable(io);
            self.cur_active = false;
            _ = self.written.fetchAdd(1, .monotonic);
            self.done_cv.broadcast(io);
            self.mu.unlock(io);
        }
    }
};

const testing = std.testing;

fn dupPage(s: []const u8) ![]u8 {
    return std.heap.page_allocator.dupe(u8, s);
}

test "flusher writes every submitted payload" {
    if (!Flusher.available()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    var f: Flusher = .{};
    defer f.deinit();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "{s}/f_{d}.bin", .{ dir, i });
        const path = try dupPage(p);
        const payload = try dupPage(&[_]u8{@intCast(i)} ** 4);
        try f.submit(@intCast(i), path, payload);
    }
    f.waitAll();
    try testing.expectEqual(@as(u64, 8), f.written.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), f.errors.load(.monotonic));

    i = 0;
    while (i < 8) : (i += 1) {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "{s}/f_{d}.bin", .{ dir, i });
        const data = try io_fs.readFileAll(testing.allocator, p);
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, &[_]u8{@intCast(i)} ** 4, data);
    }
}

test "flusher deinit drains pending writes" {
    if (!Flusher.available()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    var f: Flusher = .{};
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/drain.bin", .{dir});
    try f.submit(7, try dupPage(p), try dupPage("drained"));
    // No waitAll: deinit alone must land the write.
    f.deinit();
    const data = try io_fs.readFileAll(testing.allocator, p);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("drained", data);
}

test "flusher rejects over the byte budget and after shutdown" {
    if (!Flusher.available()) return error.SkipZigTest;
    var f: Flusher = .{};
    // Never started: force the budget check without touching the disk.
    f.bytes = max_pending_bytes;
    var path_buf: [8]u8 = "x/y.bin\x00".*;
    var payload_buf: [1]u8 = .{0};
    try testing.expectError(error.QueueFull, f.submit(1, path_buf[0..7], payload_buf[0..]));
    f.n = max_pending;
    f.bytes = 0;
    try testing.expectError(error.QueueFull, f.submit(1, path_buf[0..7], payload_buf[0..]));
    f.n = 0;
    f.shutdown = true;
    try testing.expectError(error.Shutdown, f.submit(1, path_buf[0..7], payload_buf[0..]));
    f.deinit();
}

test "flusher waitKey returns immediately when idle" {
    if (!Flusher.available()) return error.SkipZigTest;
    var f: Flusher = .{};
    defer f.deinit();
    f.waitKey(1234);
    try testing.expectEqual(@as(usize, 0), f.pending());
    try testing.expectEqual(@as(u64, 0), f.waits.load(.monotonic));
}

test "flusher ring is FIFO per key" {
    if (!Flusher.available()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    var f: Flusher = .{};
    defer f.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/fifo.bin", .{dir});
    // Same key twice: the newest submit must be the file that survives.
    try f.submit(42, try dupPage(p), try dupPage("old"));
    try f.submit(42, try dupPage(p), try dupPage("new"));
    f.waitKey(42);
    const data = try io_fs.readFileAll(testing.allocator, p);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("new", data);
}
