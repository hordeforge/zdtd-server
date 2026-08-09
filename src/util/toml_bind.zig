//! toml_bind.zig: comptime-reflected TOML-subset binder (ADR 0021 decision 1).
//!
//! `bind(T, dst, src, allocator)` walks `std.meta.fields(T)`: a struct field is
//! a `[section]` (dotted names like `[rules.combat]` recurse through nested
//! structs), a non-struct field is a root key when `allow_root` (or inside one
//! of `root_sections`), and the field's type drives value parsing. An `?T`
//! field means "unset", which is what the precedence merge keys on. Unknown
//! sections and keys abort with `error.UnknownTomlKey`; a key outside any
//! section is rejected.
//!
//! Optional per-struct comptime declarations:
//! - `toml_label`: message prefix for unknown-key / range warnings.
//! - `allow_root`: accept root-level keys (mode packs). Default false.
//! - `root_sections`: section names whose keys bind to the root fields.
//! - `aliases`: `.{ .root = [_][2][]const u8{.{alias, canonical}, ...},
//!   .<section> = ... }` accepted alternate spellings per scope.
//! - `ranges`: `.{ .<field> = .{ lo, hi }, ... }` clamp bounds, logged when a
//!   value lands outside.
//! - `enum_by_name`: `.{ .<field> = SomeEnum, ... }` validates a string field
//!   against enum variant names (case-insensitive) and stores the canonical
//!   `@tagName` spelling.
//!
//! Minimal TOML subset: `[section]` + `key = int|float|bool|string`. No arrays,
//! no tables-in-tables. The line splitter and quote-aware `stripComment`
//! preserve the previous zdtd.toml parser behaviour (docs/adr/0021).

const std = @import("std");

/// Parse `src` into `dst`, setting only the fields the file mentions. String
/// values (and only those) are duped through `a`; callers own the result via
/// their arena (zdtd_config.File / mode.Pack both carry one).
pub fn bind(comptime T: type, dst: *T, src: []const u8, a: std.mem.Allocator) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, try stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const end = std.mem.findScalar(u8, line, ']') orelse return error.BadToml;
            if (std.mem.trim(u8, line[end + 1 ..], " \t").len != 0) return error.BadToml;
            section = std.mem.trim(u8, line[1..end], " \t");
            if (section.len == 0) return error.BadToml;
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse return error.BadToml;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.BadToml;
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) return error.BadToml;
        try bindKV(T, dst, a, section, key, val);
    }
}

/// Strip a trailing comment, honouring single/double quotes so `#` inside a
/// string value survives. An unterminated quote is malformed.
fn stripComment(line: []const u8) ![]const u8 {
    var quote: ?u8 = null;
    for (line, 0..) |c, i| {
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            return line[0..i];
        }
    }
    if (quote != null) return error.BadToml;
    return line;
}

const label = struct {
    fn of(comptime T: type) []const u8 {
        return if (@hasDecl(T, "toml_label")) T.toml_label else "toml";
    }
};

fn allowRoot(comptime T: type) bool {
    return @hasDecl(T, "allow_root") and T.allow_root;
}

fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

/// Optional wrapper child; the field itself when not optional.
fn optionalChild(comptime T: type) type {
    return if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
}

/// A scalar field the binder can bind: bool / int / float / string / enum,
/// optionally wrapped, excluding structs (sections) and pointers that are not
/// strings (arena bookkeeping and the like).
fn isBindable(comptime T: type) bool {
    const base = optionalChild(T);
    return switch (@typeInfo(base)) {
        .bool, .int, .float, .@"enum" => true,
        .pointer => base == []const u8,
        else => false,
    };
}

fn keyIs(comptime Root: type, scope: []const u8, comptime canonical: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, key, canonical)) return true;
    if (@hasDecl(Root, "aliases")) {
        // Aliases are grouped by scope name ("root" or a section) and declared
        // on the root struct (the leaf scope only names its own fields).
        inline for (std.meta.fields(@TypeOf(Root.aliases))) |af| {
            if (std.mem.eql(u8, scope, af.name)) {
                // Unrolled so each pair is comptime (aliases is comptime-only).
                inline for (@field(Root.aliases, af.name)) |pair| {
                    if (std.mem.eql(u8, key, pair[0]) and std.mem.eql(u8, pair[1], canonical)) return true;
                }
            }
        }
    }
    return false;
}

fn unknownKey(comptime T: type, section: []const u8, key: []const u8) error{UnknownTomlKey} {
    std.debug.print("zdtd: {s} unknown key [{s}].{s}\n", .{ label.of(T), section, key });
    return error.UnknownTomlKey;
}

fn bindKV(comptime T: type, dst: *T, a: std.mem.Allocator, section: []const u8, key: []const u8, val: []const u8) !void {
    if (section.len == 0) {
        if (!allowRoot(T)) {
            std.debug.print("zdtd: {s} key '{s}' must be inside a known section\n", .{ label.of(T), key });
            return error.UnknownTomlKey;
        }
        try bindKeys(T, T, dst, a, "root", key, val);
        return;
    }
    if (@hasDecl(T, "root_sections")) {
        inline for (T.root_sections) |rs| {
            if (std.mem.eql(u8, section, rs)) {
                try bindKeys(T, T, dst, a, "root", key, val);
                return;
            }
        }
    }
    try bindScope(T, T, dst, a, section, key, val);
}

/// Resolve a (possibly dotted) section path against nested struct fields and
/// bind the key into the leaf scope. Unknown sections fail closed.
fn bindScope(comptime Root: type, comptime T: type, dst: *T, a: std.mem.Allocator, section: []const u8, key: []const u8, val: []const u8) !void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime !isStruct(f.type)) continue;
        if (std.mem.eql(u8, section, f.name)) {
            try bindKeys(Root, f.type, &@field(dst, f.name), a, f.name, key, val);
            return;
        }
        if (std.mem.startsWith(u8, section, f.name) and section.len > f.name.len and section[f.name.len] == '.') {
            try bindScope(Root, f.type, &@field(dst, f.name), a, section[f.name.len + 1 ..], key, val);
            return;
        }
    }
    return unknownKey(Root, section, key);
}

/// Match the key against the scope's scalar fields (aliases included) and bind.
fn bindKeys(comptime Root: type, comptime T: type, dst: *T, a: std.mem.Allocator, scope: []const u8, key: []const u8, val: []const u8) !void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime !isBindable(f.type)) continue;
        if (keyIs(Root, scope, f.name, key)) {
            try setField(Root, f, dst, a, val);
            return;
        }
    }
    return unknownKey(Root, scope, key);
}

/// Parse + range-check one field value and store it (optionals are filled,
/// plain fields overwritten). The destination's declared type drives parsing.
fn setField(comptime Root: type, comptime f: std.builtin.Type.StructField, dst: anytype, a: std.mem.Allocator, val: []const u8) !void {
    const base = optionalChild(f.type);
    const v = stripQuotes(val);
    if (@typeInfo(base) == .pointer) {
        // String. enum_by_name validates constrained strings (e.g. authority
        // mode) and canonicalises the spelling before it is stored.
        if (@hasDecl(Root, "enum_by_name") and @hasField(@TypeOf(Root.enum_by_name), f.name)) {
            const E = @field(Root.enum_by_name, f.name);
            const e = try parseEnum(E, v);
            @field(dst, f.name) = try a.dupe(u8, @tagName(e));
            return;
        }
        @field(dst, f.name) = try a.dupe(u8, v);
        return;
    }
    const parsed = switch (@typeInfo(base)) {
        .bool => try parseBool(v),
        .int => try std.fmt.parseInt(base, v, 10),
        .float => try std.fmt.parseFloat(base, v),
        .@"enum" => try parseEnum(base, v),
        else => @compileError("toml_bind: unsupported field type " ++ @typeName(base) ++ " for key '" ++ f.name ++ "'"),
    };
    const out: base = clamp(Root, f.name, parsed);
    @field(dst, f.name) = out;
}

fn clamp(comptime Root: type, comptime fname: []const u8, v: anytype) @TypeOf(v) {
    const base = @TypeOf(v);
    if (!@hasDecl(Root, "ranges") or !@hasField(@TypeOf(Root.ranges), fname)) return v;
    const r: [2]base = @field(Root.ranges, fname);
    if (v >= r[0] and v <= r[1]) return v;
    const c: base = @min(@max(v, r[0]), r[1]);
    std.debug.print("zdtd: {s} {s}={d} out of range [{d}..{d}]; using {d}\n", .{ label.of(Root), fname, v, r[0], r[1], c });
    return c;
}

fn parseBool(v: []const u8) !bool {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no")) return false;
    return error.BadTomlBool;
}

fn parseEnum(comptime E: type, v: []const u8) !E {
    inline for (@typeInfo(E).@"enum".fields) |ef| {
        if (std.ascii.eqlIgnoreCase(v, ef.name)) return @enumFromInt(ef.value);
    }
    return error.InvalidTomlEnum;
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        return v[1 .. v.len - 1];
    }
    return v;
}

/// Merge an overlay (all-optional mirror of `T`) into a concrete value. Only
/// non-null overlay fields override, so precedence can be applied by calling in
/// order: defaults < mode pack < zdtd.toml. The overlay type is hand-written
/// next to its struct (rules.zig) with a comptime parity test, because Zig
/// 0.16's `@Struct` cannot lay out a recursive anonymous type (used for a
/// generic `Overlay(T)` mirror).
pub fn mergeOverlay(comptime T: type, dst: *T, o: anytype) void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime isStruct(f.type)) {
            mergeOverlay(f.type, &@field(dst, f.name), &@field(o, f.name));
        } else if (@field(o, f.name)) |v| {
            @field(dst, f.name) = v;
        }
    }
}

const TestGroup = struct {
    count: u32 = 0,
    ratio: f32 = 0,
    label: []const u8 = "",
    on: bool = false,
};

const TestCfg = struct {
    pub const toml_label = "test";
    pub const allow_root = true;
    pub const aliases = .{
        .root = [_][2][]const u8{.{ "short_label", "name" }},
        .group = [_][2][]const u8{.{ "n", "count" }},
    };
    pub const ranges = .{ .count = .{ 1, 10 } };
    pub const enum_by_name = .{ .mode_name = TestMode };

    const TestMode = enum { a, b, c };
    name: []const u8 = "",
    mode_name: []const u8 = "",
    group: TestGroup = .{},
    nested: Nested = .{},
    count: u32 = 0,
};

const Nested = struct {
    depth: ?u8 = null,
    enabled: ?bool = null,
};

test "bind covers every supported field type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: TestCfg = .{};
    try bind(TestCfg, &c,
        \\name = "world1"
        \\count = 5
        \\short_label = "alias"
        \\mode_name = "B"
        \\[group]
        \\ratio = 0.5
        \\n = 3
        \\label = "g1"
        \\[nested]
        \\depth = 7
        \\enabled = yes
    , arena.allocator());
    try std.testing.expectEqualStrings("alias", c.name);
    try std.testing.expectEqual(@as(u32, 5), c.count);
    try std.testing.expectEqualStrings("b", c.mode_name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c.group.ratio, 0.001);
    try std.testing.expectEqual(@as(u32, 3), c.group.count);
    try std.testing.expectEqualStrings("g1", c.group.label);
    try std.testing.expectEqual(@as(?u8, 7), c.nested.depth);
    try std.testing.expectEqual(@as(?bool, true), c.nested.enabled);
}

test "bind dotted section with a struct under a struct" {
    var c: TestCfg = .{};
    try bind(TestCfg, &c, "[nested]\ndepth = 1\n", std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 1), c.nested.depth);
    // A dotted path into a non-struct is an unknown section (fail closed).
    try std.testing.expectError(
        error.UnknownTomlKey,
        bind(TestCfg, &c, "[nested.more]\ndepth = 1\n", std.testing.allocator),
    );
}

test "bind clamps declared ranges and rejects overflow" {
    var c: TestCfg = .{};
    try bind(TestCfg, &c, "count = 99\n", std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 10), c.count);
    // u8 cannot hold 300: parseInt overflow propagates (no silent wrap).
    try std.testing.expectError(
        error.Overflow,
        bind(TestCfg, &c, "[nested]\ndepth = 300\n", std.testing.allocator),
    );
}

test "bind enum_by_name canonicalises and rejects unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: TestCfg = .{};
    try bind(TestCfg, &c, "mode_name = \"B\"\n", arena.allocator());
    try std.testing.expectEqualStrings("b", c.mode_name);
    try std.testing.expectError(
        error.InvalidTomlEnum,
        bind(TestCfg, &c, "mode_name = \"d\"\n", arena.allocator()),
    );
}

test "bind rejects unknown keys, sections, root keys, and malformed lines" {
    var c: TestCfg = .{};
    try std.testing.expectError(
        error.UnknownTomlKey,
        bind(TestCfg, &c, "nope = 1\n", std.testing.allocator),
    );
    try std.testing.expectError(
        error.UnknownTomlKey,
        bind(TestCfg, &c, "[stream]\ncount = 1\n", std.testing.allocator),
    );
    try std.testing.expectError(
        error.BadToml,
        bind(TestCfg, &c, "count 1\n", std.testing.allocator),
    );
    try std.testing.expectError(
        error.BadToml,
        bind(TestCfg, &c, "[stream] trailing\ncount = 1\n", std.testing.allocator),
    );
}

test "bind empty file and bare-bool errors" {
    var c: TestCfg = .{};
    try bind(TestCfg, &c, "", std.testing.allocator);
    try std.testing.expectEqualStrings("", c.name);
    try std.testing.expectEqual(@as(u32, 0), c.count);
    try std.testing.expectError(
        error.BadTomlBool,
        bind(TestCfg, &c, "[group]\non = maybe\n", std.testing.allocator),
    );
}

test "root keys rejected when allow_root is false" {
    const NoRoot = struct {
        pub const allow_root = false;
        group: TestGroup = .{},
    };
    var c: NoRoot = .{};
    try std.testing.expectError(
        error.UnknownTomlKey,
        bind(NoRoot, &c, "count = 1\n", std.testing.allocator),
    );
    try bind(NoRoot, &c, "[group]\ncount = 2\n", std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), c.group.count);
}

test "root_sections bind root keys from a named section" {
    const WithAlias = struct {
        pub const allow_root = false;
        pub const root_sections = [_][]const u8{"gameplay"};
        count: u32 = 0,
    };
    var c: WithAlias = .{};
    try bind(WithAlias, &c, "[gameplay]\ncount = 4\n", std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), c.count);
}

const TestOverlay = struct {
    name: ?[]const u8 = null,
    mode_name: ?[]const u8 = null,
    group: struct {
        count: ?u32 = null,
        ratio: ?f32 = null,
        label: ?[]const u8 = null,
        on: ?bool = null,
    } = .{},
    nested: struct { depth: ?u8 = null, enabled: ?bool = null } = .{},
    count: ?u32 = null,
};

test "mergeOverlay overrides only non-null fields" {
    var dst: TestCfg = .{ .name = "keep", .count = 1, .group = .{ .count = 2 } };
    var o: TestOverlay = .{};
    o.count = 9;
    o.group.count = 3;
    mergeOverlay(TestCfg, &dst, &o);
    try std.testing.expectEqualStrings("keep", dst.name);
    try std.testing.expectEqual(@as(u32, 9), dst.count);
    try std.testing.expectEqual(@as(u32, 3), dst.group.count);
    // untouched nested struct keeps its defaults.
    try std.testing.expectEqual(@as(f32, 0), dst.group.ratio);
}
