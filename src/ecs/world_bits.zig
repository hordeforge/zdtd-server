//! Word-packed slot set for parallel workers (fetchOr/fetchAnd).
//!
//! Split out of ecs/world.zig (same code, moved verbatim).

const std = @import("std");
const max_entities = @import("world.zig").max_entities;

pub const AtomicBits = struct {
    const words_n = (max_entities + 63) / 64;

    words: [words_n]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.{ .raw = 0 }} ** words_n,

    pub fn initEmpty() AtomicBits {
        return .{};
    }

    fn wordBit(index: usize) struct { word: usize, bit: u64 } {
        std.debug.assert(index < max_entities);
        return .{ .word = index >> 6, .bit = @as(u64, 1) << @as(u6, @truncate(index)) };
    }

    pub fn set(self: *AtomicBits, index: usize) void {
        const wb = wordBit(index);
        _ = self.words[wb.word].fetchOr(wb.bit, .monotonic);
    }

    pub fn unset(self: *AtomicBits, index: usize) void {
        const wb = wordBit(index);
        _ = self.words[wb.word].fetchAnd(~wb.bit, .monotonic);
    }

    pub fn isSet(self: *const AtomicBits, index: usize) bool {
        const wb = wordBit(index);
        return (self.words[wb.word].load(.monotonic) & wb.bit) != 0;
    }

    pub fn count(self: *const AtomicBits) usize {
        var total: usize = 0;
        for (&self.words) |*word| total += @popCount(word.load(.monotonic));
        return total;
    }

    /// Keep only slots also present in the StaticBitSet source. Main-thread
    /// use only (replicate intersects its candidate copy against `alive_bits`).
    /// Word-wise: the per-slot form ran `max_entities` atomic RMWs per tick.
    pub fn intersectFromStatic(self: *AtomicBits, src: std.StaticBitSet(max_entities)) void {
        for (&self.words, src.masks) |*w, m| _ = w.fetchAnd(m, .monotonic);
    }

    /// Replace contents with the StaticBitSet source. Main-thread use only
    /// (replicate's heartbeat pass seeds candidates from `alive_bits`).
    pub fn copyFromStatic(self: *AtomicBits, src: std.StaticBitSet(max_entities)) void {
        for (&self.words, src.masks) |*w, m| w.store(m, .monotonic);
    }

    pub const Iterator = struct {
        bits: *const AtomicBits,
        word: usize = 0,
        pending: u64 = 0,
        base: usize = 0,

        pub fn next(self: *Iterator) ?usize {
            while (self.pending == 0) {
                if (self.word >= words_n) return null;
                self.pending = self.bits.words[self.word].load(.monotonic);
                self.base = self.word << 6;
                self.word += 1;
            }
            const tz = @ctz(self.pending);
            self.pending &= self.pending - 1;
            return self.base + @as(usize, tz);
        }
    };

    pub fn iterator(self: *const AtomicBits, comptime opts: anytype) Iterator {
        _ = opts;
        return .{ .bits = self };
    }
};
