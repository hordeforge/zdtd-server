//! Per-entity custom variables (CVars): the value store the EffectManager's
//! `ModifyCVar`/`RemoveCVar` rows write, and that `CVarCompare` gates and
//! `value="@name"` passive rows read.
//!
//! Lives in ecs, not assets, because the World carries the per-entity column
//! and ecs may not import assets (`scripts/lint-architecture.sh`); assets
//! re-exports the same types from its `cvars.zig` facade.
//!
//! Semantics are the IL, not a guess: `EntityBuffs::SetCustomVar` (IL=130) is
//! the single write path (the six stock operation spellings plus
//! `percentadd`/`percentsubtract`), `GetCustomVar` (IL=10) reads a missing name
//! as 0, and `RemoveCustomVar` (IL=21) drops the key. Names are compared
//! case-insensitively (`CaseInsensitiveStringDictionary`).
//!
//! Non-goals: persistence (stock saves CVars with the entity; zdtd's store is
//! per client session), the random-roll value forms, and the
//! `NetPackageModifyCVar` relay (see `netSyncedName` for the stock prefix rule
//! and why the server does not push min-event writes).

const std = @import("std");
const testing = std.testing;

/// One entity's CVar capacity. Stock's `buffs.xml`/`items.xml` name 594
/// distinct CVars in total, but a single entity only materialises the ones its
/// active buffs, held items and quest state write; 128 leaves headroom and
/// stays a fixed array (no tick-path allocation).
pub const max_cvars: usize = 128;

/// `CVarOperation` (CVarOperation.il.txt) in declaration order: set, setvalue,
/// add, subtract, multiply, divide, percentadd, percentsubtract. `setvalue`
/// and `set` take the same branch in `SetCustomVar` IL=130 (the switch sends
/// both to IL_003D), so they differ only in name.
pub const Operation = enum(i16) {
    set = 0,
    setvalue = 1,
    add = 2,
    subtract = 3,
    multiply = 4,
    divide = 5,
    percent_add = 6,
    percent_subtract = 7,

    /// `EnumUtils::Parse<CVarOperation>` (`MinEventActionModifyCVar::ParseXmlAttribute`
    /// IL=64) accepts the enum name; the XML spells them `set`, `add`,
    /// `subtract`, `multiply`, `divide`, `setvalue`.
    pub fn parse(s: []const u8) ?Operation {
        inline for (@typeInfo(Operation).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
            // XML uses the run-together spelling for the percent forms.
            if (std.mem.eql(u8, f.name, "percent_add") and std.ascii.eqlIgnoreCase(s, "percentadd")) return .percent_add;
            if (std.mem.eql(u8, f.name, "percent_subtract") and std.ascii.eqlIgnoreCase(s, "percentsubtract")) return .percent_subtract;
        }
        return null;
    }
};

pub const CVar = struct {
    name: []const u8 = "",
    value: f32 = 0,
};

/// A fixed-capacity name -> f32 map for one entity.
pub const Set = struct {
    entries: [max_cvars]CVar = [_]CVar{.{}} ** max_cvars,
    n: u8 = 0,
    /// Writes dropped because the store was full (an instrumented bound, never
    /// a silent truncation).
    dropped: u32 = 0,

    pub fn indexOf(self: *const Set, name: []const u8) ?u8 {
        var i: u8 = 0;
        while (i < self.n) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(self.entries[i].name, name)) return i;
        }
        return null;
    }

    /// `EntityBuffs::GetCustomVar` IL=10: a missing name reads 0.
    pub fn get(self: *const Set, name: []const u8) f32 {
        const i = self.indexOf(name) orelse return 0;
        return self.entries[i].value;
    }

    /// `EntityBuffs::SetCustomVar` IL=130. Returns whether the value changed
    /// (stock's `changed`, which is false only for a `set` that writes the
    /// value already there). Names must outlive the store (they are arena-owned
    /// catalog strings); a name that is not in the store and does not fit is
    /// counted in `dropped`.
    pub fn apply(self: *Set, name: []const u8, op: Operation, value: f32) bool {
        const i = self.indexOf(name) orelse blk: {
            if (self.n >= max_cvars) {
                self.dropped += 1;
                return false;
            }
            self.entries[self.n].name = name;
            self.n += 1;
            break :blk self.n - 1;
        };
        const old = self.entries[i].value;
        const new: f32 = switch (op) {
            .set, .setvalue => if (old == value) return false else value,
            .add => old + value,
            .subtract => old - value,
            .multiply => old * value,
            // IL_008A: a zero divisor becomes 0.0001 rather than inf/NaN.
            .divide => old / (if (value == 0) 0.0001 else value),
            // IL_00AA / IL_00BD: percent of the CURRENT value, added to it.
            .percent_add => old + old * value,
            .percent_subtract => old - old * value,
        };
        self.entries[i].value = new;
        return true;
    }

    /// `EntityBuffs::RemoveCustomVar` IL=21: drop the key. Subsequent reads see
    /// 0 again.
    pub fn remove(self: *Set, name: []const u8) bool {
        const i = self.indexOf(name) orelse return false;
        var j: u8 = i;
        while (j + 1 < self.n) : (j += 1) self.entries[j] = self.entries[j + 1];
        self.n -= 1;
        return true;
    }

    /// `EntityBuffs::SetCustomVar` IL=0106-IL_0139: a name starting with `.` or
    /// `_` is never networked, one starting with `%` always is, and everything
    /// else follows the caller's `_netSync`. Read-only helper: zdtd's server
    /// does not push min-event writes (stock passes `_netSync = IsLocal`, false
    /// on the server, because the owning client runs the same XML).
    pub fn netSyncedName(name: []const u8, net_sync: bool) bool {
        if (name.len == 0) return net_sync;
        return switch (name[0]) {
            '%' => true,
            '.', '_' => false,
            else => net_sync,
        };
    }
};

test "the six stock ModifyCVar spellings and the percent forms parse" {
    try testing.expectEqual(Operation.set, Operation.parse("set").?);
    try testing.expectEqual(Operation.setvalue, Operation.parse("setvalue").?);
    try testing.expectEqual(Operation.add, Operation.parse("add").?);
    try testing.expectEqual(Operation.subtract, Operation.parse("subtract").?);
    try testing.expectEqual(Operation.multiply, Operation.parse("multiply").?);
    try testing.expectEqual(Operation.divide, Operation.parse("divide").?);
    try testing.expectEqual(Operation.percent_add, Operation.parse("percentadd").?);
    try testing.expectEqual(Operation.percent_subtract, Operation.parse("percentsubtract").?);
    try testing.expect(Operation.parse("nonsense") == null);
}

test "Set applies the stock operations, including the zero-divisor guard" {
    var s: Set = .{};
    // set writes; setting the same value again is not a change (IL_0040).
    try testing.expect(s.apply("a", .set, 4));
    try testing.expect(!s.apply("a", .set, 4));
    try testing.expect(s.apply("a", .set, 5));
    try testing.expectEqual(@as(f32, 5), s.get("a"));
    // A missing name reads 0, so add lands on the operand and multiply zeroes.
    try testing.expectEqual(@as(f32, 0), s.get("missing"));
    try testing.expect(s.apply("b", .add, 3));
    try testing.expectEqual(@as(f32, 3), s.get("b"));
    try testing.expect(s.apply("b", .subtract, 1));
    try testing.expectEqual(@as(f32, 2), s.get("b"));
    try testing.expect(s.apply("b", .multiply, 5));
    try testing.expectEqual(@as(f32, 10), s.get("b"));
    try testing.expect(s.apply("b", .divide, 4));
    try testing.expectEqual(@as(f32, 2.5), s.get("b"));
    // IL_008A: divide by zero uses 0.0001, so the value stays finite.
    try testing.expect(s.apply("b", .divide, 0));
    try testing.expect(std.math.isFinite(s.get("b")));
    // percentadd/percentsubtract are relative to the current value.
    try testing.expect(s.apply("p", .set, 10));
    try testing.expect(s.apply("p", .percent_add, 0.5));
    try testing.expectEqual(@as(f32, 15), s.get("p"));
    try testing.expect(s.apply("p", .percent_subtract, 0.5));
    try testing.expectEqual(@as(f32, 7.5), s.get("p"));
    // Names are case-insensitive (CaseInsensitiveStringDictionary).
    try testing.expectEqual(@as(f32, 7.5), s.get("P"));
    // remove drops the key; a later read is 0.
    try testing.expect(s.remove("p"));
    try testing.expectEqual(@as(f32, 0), s.get("p"));
    try testing.expect(!s.remove("p"));
}

test "Set keeps the value a setvalue shares with set, and counts overflow" {
    var s: Set = .{};
    try testing.expect(s.apply("x", .setvalue, 2));
    try testing.expect(!s.apply("x", .setvalue, 2));
    try testing.expectEqual(@as(f32, 2), s.get("x"));
    // Fill the store: a new name past capacity is dropped and counted, never
    // silently aliased onto another entry. Each name needs its own storage
    // (the store keeps the slice).
    var names_buf: [max_cvars][8]u8 = undefined;
    var i: usize = 0;
    while (s.n < max_cvars) : (i += 1) {
        const name = std.fmt.bufPrint(&names_buf[i], "c{d}", .{i}) catch unreachable;
        _ = s.apply(name, .set, @floatFromInt(i));
    }
    try testing.expectEqual(max_cvars, s.n);
    try testing.expect(!s.apply("one-too-many", .set, 1));
    try testing.expectEqual(@as(u32, 1), s.dropped);
    try testing.expectEqual(@as(f32, 0), s.get("one-too-many"));
}

test "the stock networking prefix rule" {
    // SetCustomVar IL_0106-IL_0139.
    try testing.expect(!Set.netSyncedName(".ArmorLightTotal", true));
    try testing.expect(!Set.netSyncedName("_wetnessrate", true));
    try testing.expect(Set.netSyncedName("%something", false));
    try testing.expect(Set.netSyncedName("$bleedAmount", true));
    try testing.expect(!Set.netSyncedName("$bleedAmount", false));
}
