//! `Config/Localization.csv` merge and the patch blob stock ships to joining
//! clients as `NetPackageLocalization`.
//!
//! Stock reads the base `Data/Config/Localization.csv`, then each mod's
//! `Config/Localization.csv` in load order (`Localization.LoadLocalization` +
//! `ModManager.LoadLocalizations`), marking every cell a mod file writes in
//! `patchedCells[key][column]`. A joining client is sent exactly those patched
//! cells: `Localization.WriteCsv()` (IL=190) writes `KEY` plus the base header
//! column names, then one CSV line per patched key whose patched columns carry
//! a value (quoted when the value contains a quote or a comma, with `\r`
//! folded to `\n`), and deflates the text (`DeflateOutputStream(_, 3)`) into
//! `PatchedData`, which `NetPackageLocalization` ships in 128 KiB parts
//! (`prepareDataPackets`, IL=107).
//!
//! zdtd keeps only what the wire needs: the base header row, and one entry per
//! patched key with its per-column values in mod order (a later mod wins).
//! Non-patched columns are written empty, which is what stock's writer does.

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

/// Column cap: stock's base header has 17 columns (Key, File, Type,
/// UsedInMainMenu, NoTranslate, KeepLoaded, english, Context / Alternate Text
/// and the 9 translations). 24 leaves room for a modded base header.
pub const max_columns: usize = 24;
/// Patched-key cap. The installed 6-mod Circle set patches ~900 keys.
pub const max_keys: usize = 8192;
/// Per-cell value cap (stock's longest cell in the base file is under 400).
pub const max_cell_len: usize = 1024;
/// Stock's `prepareDataPackets` part size (`ldc.i4 131072`).
pub const part_size: usize = 131072;

/// One patched key: `cells[i]` is set when a mod file wrote column `i`.
pub const Entry = struct {
    key: []const u8 = "",
    cells: [max_columns]?[]const u8 = .{null} ** max_columns,
};

pub const Table = struct {
    /// Base header row cells (index 0 is stock's `Key` column).
    header: [max_columns][]const u8 = .{""} ** max_columns,
    header_n: usize = 0,
    entries: []Entry = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn isEmpty(self: *const Table) bool {
        return self.entries.len == 0;
    }

    /// Column index of a header name (case-insensitive, stock's
    /// `languageToColumnIndex` lookup). Null when the name is not a column,
    /// i.e. a mod cell this server cannot place.
    pub fn columnIndex(self: *const Table, name: []const u8) ?usize {
        for (self.header[0..self.header_n], 0..) |h, i| {
            if (std.ascii.eqlIgnoreCase(h, name)) return i;
        }
        return null;
    }

    /// `Localization::WriteCsv` (IL=190) text: the header line, then one line
    /// per patched key. Caller owns the returned slice.
    pub fn csvText(self: *const Table, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "KEY");
        for (self.header[1..self.header_n]) |h| {
            try out.append(allocator, ',');
            try out.appendSlice(allocator, h);
        }
        try out.append(allocator, '\n');
        for (self.entries) |e| {
            try out.appendSlice(allocator, e.key);
            // Column 0 is stock's `Key` column, which the row's own key cell
            // already carries: the writer's per-row array starts at `File`.
            for (e.cells[1..self.header_n]) |cell| {
                try out.append(allocator, ',');
                const v = cell orelse continue;
                // Stock's quoting rule: quote when the value carries a quote
                // or a comma, doubling inner quotes; CR is folded to LF first.
                var buf: [max_cell_len * 2]u8 = undefined;
                var n: usize = 0;
                for (v) |c| {
                    const ch: u8 = if (c == '\r') '\n' else c;
                    if (n + 2 > buf.len) break;
                    if (ch == '"') {
                        buf[n] = '"';
                        buf[n + 1] = '"';
                        n += 2;
                    } else {
                        buf[n] = ch;
                        n += 1;
                    }
                }
                const folded = buf[0..n];
                const quote = std.mem.findScalar(u8, folded, '"') != null or
                    std.mem.findScalar(u8, folded, ',') != null;
                if (quote) try out.append(allocator, '"');
                try out.appendSlice(allocator, folded);
                if (quote) try out.append(allocator, '"');
            }
            try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Raw-Deflate the CSV text the way stock's `WriteCsv` does, so the client
    /// can inflate it. Stock compresses at level 3; the level only changes the
    /// ratio, not the decoded bytes. Caller owns the result.
    pub fn deflatedCsv(self: *const Table, allocator: std.mem.Allocator) ![]u8 {
        const text = try self.csvText(allocator);
        defer allocator.free(text);
        return deflate(allocator, text);
    }
};

/// Raw-Deflate `src` (no zlib/gzip wrapper), stock's `DeflateOutputStream`
/// shape. Caller owns the result.
pub fn deflate(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // The compressor asserts on an output buffer of 8 bytes or less, so the
    // sink starts big enough for the first block.
    try aw.ensureTotalCapacity(src.len / 2 + 64);
    var window: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(&aw.writer, &window, .raw, .default);
    try comp.writer.writeAll(src);
    try comp.finish();
    return try aw.toOwnedSlice();
}

/// Load the base header and merge every mod's `Config/Localization.csv`.
/// Null when the base file is absent (nothing to patch against).
pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    const mod_dirs = @import("paths.zig").mod_dirs;
    return tryLoadWithMods(allocator, game_dir, config_dir, mod_dirs);
}

/// Testable form of `tryLoad`: the mod dirs are passed in.
pub fn tryLoadWithMods(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    mod_dirs: []const @import("modlets.zig").ModDir,
) !?Table {
    var path_buf: [2048]u8 = undefined;
    const base_path = paths.resolveConfigXml(&path_buf, "Localization.csv", game_dir, config_dir) orelse return null;
    const base = io_fs.readFileAll(allocator, base_path) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(base);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var t: Table = .{ .arena_ptr = arena_holder };
    errdefer t.deinit();

    // Header: the base file's first row, which is also stock's column index.
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    {
        const line = firstLine(base);
        var fields: [max_columns][]const u8 = undefined;
        const n = parseCsvLine(line, &fields);
        for (fields[0..@min(n, max_columns)], 0..) |f, i| {
            t.header[i] = try arena.dupe(u8, f);
        }
        t.header_n = @min(n, max_columns);
    }
    if (t.header_n < 2) return null;

    // Merge the base file's own rows first: stock's `patchedCells` only marks
    // what a *mod* writes, so base rows are not sent back to the client.
    for (mod_dirs) |md| {
        var mbuf: [2048]u8 = undefined;
        const mpath = std.fmt.bufPrint(&mbuf, "{s}/Localization.csv", .{md.config_dir}) catch continue;
        const text = io_fs.readFileAll(allocator, mpath) catch continue;
        defer allocator.free(text);
        try mergeFile(allocator, arena, &t, text, &entries);
    }
    if (entries.items.len == 0) {
        t.deinit();
        return null;
    }
    t.entries = try arena.dupe(Entry, entries.items);
    return t;
}

/// Merge one CSV file's rows into `t`: the file's own header names resolve to
/// base column indices, and a later write to the same cell wins.
fn mergeFile(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    t: *Table,
    text: []const u8,
    entries: *std.ArrayList(Entry),
) !void {
    var line_it = std.mem.splitScalar(u8, text, '\n');
    const header_line = line_it.next() orelse return;
    var hfields: [max_columns][]const u8 = undefined;
    const hn = parseCsvLine(header_line, &hfields);
    if (hn == 0) return;
    // Map this file's column position to the base column index by name.
    var col_map: [max_columns]?usize = .{null} ** max_columns;
    for (hfields[0..@min(hn, max_columns)], 0..) |name, i| {
        const trimmed = std.mem.trim(u8, name, " \t\r");
        col_map[i] = t.columnIndex(trimmed);
    }
    var fields: [max_columns][]const u8 = undefined;
    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const n = parseCsvLine(line, &fields);
        if (n == 0) continue;
        const key = std.mem.trim(u8, fields[0], " \t");
        if (key.len == 0) continue;
        const slot = try slotFor(allocator, arena, entries, key);
        for (fields[1..n], 1..) |raw, fi| {
            if (fi >= max_columns) break;
            const base_col = col_map[fi] orelse continue;
            const v = std.mem.trim(u8, raw, " \t");
            entries.items[slot].cells[base_col] = try dupUnescaped(arena, v);
        }
    }
}

/// Index of `key` in `entries`, appending a fresh entry (arena-owned key) when
/// the key is new. Stock's dictionary keeps first-touch order.
fn slotFor(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    key: []const u8,
) !usize {
    for (entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.key, key)) return i;
    }
    if (entries.items.len >= max_keys) return error.TooManyKeys;
    const owned = try arena.dupe(u8, key);
    try entries.append(allocator, .{ .key = owned });
    return entries.items.len - 1;
}

/// Copy a CSV field, collapsing the doubled quotes a quoted field uses so the
/// stored cell is the decoded text.
fn dupUnescaped(arena: std.mem.Allocator, v: []const u8) ![]const u8 {
    if (std.mem.find(u8, v, "\"\"") == null) return arena.dupe(u8, v);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    var i: usize = 0;
    while (i < v.len) {
        if (v[i] == '"' and i + 1 < v.len and v[i + 1] == '"') {
            try out.append(arena, '"');
            i += 2;
            continue;
        }
        try out.append(arena, v[i]);
        i += 1;
    }
    return try arena.dupe(u8, out.items);
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

/// Parse one CSV line into `out`, honouring quoted fields (a quote inside a
/// quoted field is doubled). Returns the field count.
fn parseCsvLine(line: []const u8, out: *[max_columns][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i <= line.len and n < out.len) {
        const field_start = i;
        if (i < line.len and line[i] == '"') {
            i += 1;
            // A quoted field can carry commas and doubled quotes; the raw
            // slice still holds the doubled quotes, which `dupUnescaped`
            // collapses when the cell is stored.
            const q_start = i;
            while (i < line.len) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            out[n] = line[q_start..i];
            n += 1;
            if (i < line.len and line[i] == '"') i += 1;
        } else {
            while (i < line.len and line[i] != ',') i += 1;
            out[n] = line[field_start..i];
            n += 1;
        }
        if (i >= line.len) break;
        if (line[i] == ',') {
            i += 1;
            continue;
        }
        break;
    }
    return n;
}

test "localization CSV parses quoted fields and merges in mod order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Config", .{dir});
    io_fs.mkdirPath(cfg);
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_path = try std.fmt.bufPrint(&base_buf, "{s}/Localization.csv", .{cfg});
    try io_fs.writeFile(base_path,
        \\Key,File,Type,UsedInMainMenu,NoTranslate,KeepLoaded,english,Context,german
        \\cntTestCashRegister,blocks,Block,,x,,Test Cash Register,only for testing,x
        \\buffBase,buffs,Buff,,,,Base buff,,
        \\
    );
    var mod_a_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mod_a = try std.fmt.bufPrint(&mod_a_buf, "{s}/modA/Config", .{dir});
    io_fs.mkdirPath(mod_a);
    var mod_a_csv_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mod_a_csv = try std.fmt.bufPrint(&mod_a_csv_buf, "{s}/Localization.csv", .{mod_a});
    try io_fs.writeFile(mod_a_csv,
        \\Key,english
        \\buffBase,"Broken, Mod"
        \\modOnly,"He said ""hi"""
        \\
    );
    var mod_b_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mod_b = try std.fmt.bufPrint(&mod_b_buf, "{s}/modB/Config", .{dir});
    io_fs.mkdirPath(mod_b);
    var mod_b_csv_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mod_b_csv = try std.fmt.bufPrint(&mod_b_csv_buf, "{s}/Localization.csv", .{mod_b});
    try io_fs.writeFile(mod_b_csv,
        \\Key,german
        \\buffBase,Deutsch
        \\
    );

    const mods = @import("modlets.zig");
    const dirs = [_]mods.ModDir{
        .{ .config_dir = mod_a, .mod_path = dir },
        .{ .config_dir = mod_b, .mod_path = dir },
    };
    var t = (try tryLoadWithMods(std.testing.allocator, null, cfg, &dirs)).?;
    defer t.deinit();
    // Header comes from the base file; column names resolve per mod file.
    try std.testing.expectEqual(@as(usize, 9), t.header_n);
    try std.testing.expectEqualStrings("Key", t.header[0]);
    try std.testing.expectEqualStrings("english", t.header[6]);
    // Only mod-patched keys are sent (the base rows are not).
    try std.testing.expectEqual(@as(usize, 2), t.entries.len);
    try std.testing.expectEqualStrings("buffBase", t.entries[0].key);
    try std.testing.expectEqualStrings("Broken, Mod", t.entries[0].cells[6].?);
    try std.testing.expectEqualStrings("Deutsch", t.entries[0].cells[8].?);
    try std.testing.expectEqualStrings("modOnly", t.entries[1].key);
    try std.testing.expectEqualStrings("He said \"hi\"", t.entries[1].cells[6].?);

    const text = try t.csvText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // Header line, then one line per patched key with the patched cells
    // quoted; unpatched columns stay empty.
    try std.testing.expect(std.mem.startsWith(u8, text, "KEY,File,Type,UsedInMainMenu,NoTranslate,KeepLoaded,english,Context,german\n"));
    try std.testing.expect(std.mem.find(u8, text, "buffBase,,,,,,\"Broken, Mod\",,Deutsch\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "modOnly,,,,,,\"He said \"\"hi\"\"\",,\n") != null);
}

test "the localization blob is raw deflate the client can inflate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Config", .{dir});
    io_fs.mkdirPath(cfg);
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(try std.fmt.bufPrint(&base_buf, "{s}/Localization.csv", .{cfg}),
        \\Key,english
        \\a,one
        \\
    );
    var mod_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mod = try std.fmt.bufPrint(&mod_buf, "{s}/m/Config", .{dir});
    io_fs.mkdirPath(mod);
    var mod_csv_buf: [std.fs.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(try std.fmt.bufPrint(&mod_csv_buf, "{s}/Localization.csv", .{mod}),
        \\Key,english
        \\zzPatched,patched value
        \\
    );
    const mods = @import("modlets.zig");
    const dirs = [_]mods.ModDir{.{ .config_dir = mod, .mod_path = dir }};
    var t = (try tryLoadWithMods(std.testing.allocator, null, cfg, &dirs)).?;
    defer t.deinit();
    const blob = try t.deflatedCsv(std.testing.allocator);
    defer std.testing.allocator.free(blob);
    // Round-trip through the inflater the stock client uses (raw deflate, the
    // container the wire carries).
    var in: std.Io.Reader = .fixed(blob);
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var dec: std.compress.flate.Decompress = .init(&in, .raw, &.{});
    const n = try dec.reader.streamRemaining(&out);
    try std.testing.expect(std.mem.find(u8, out_buf[0..n], "zzPatched") != null);
    try std.testing.expect(std.mem.find(u8, out_buf[0..n], "patched value") != null);
}
