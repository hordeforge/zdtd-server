//! Lazy per-table scratch arena: created on first use, reused after.

const std = @import("std");

/// Heap-allocate and init an arena; caller still owns errdefer{deinit;destroy}.
pub fn newArenaHolder(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const ap = try allocator.create(std.heap.ArenaAllocator);
    ap.* = std.heap.ArenaAllocator.init(allocator);
    return ap;
}

pub fn ensureLazyArena(arena_ptr: *?*std.heap.ArenaAllocator, allocator: std.mem.Allocator) !std.mem.Allocator {
    if (arena_ptr.*) |ap| return ap.allocator();
    const ap = try newArenaHolder(allocator);
    arena_ptr.* = ap;
    return ap.allocator();
}

/// Release a holder created by `newArenaHolder` / `ensureLazyArena`.
/// Idempotent: a null pointer is a no-op.
pub fn destroyHolder(arena_ptr: *?*std.heap.ArenaAllocator) void {
    if (arena_ptr.*) |ap| {
        const child = ap.child_allocator;
        ap.deinit();
        child.destroy(ap);
        arena_ptr.* = null;
    }
}
