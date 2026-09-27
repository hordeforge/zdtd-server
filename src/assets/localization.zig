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
const test_tmp = @import("../util/test_tmp.zig");
const arena_util = @import("../util/arena.zig");
const io_fs = @import("../util/io_fs.zig");
const mods = @import("modlets.zig");
const paths = @import("paths.zig");

/// Column cap: stock's base header has 17 columns (Key, File, Type,
/// UsedInMainMenu, NoTranslate, KeepLoaded, english, Context / Alternate Text
/// and the 9 translations). 24 leaves room for a modded base header.
pub const max_columns: usize = 24;
/// Patched-key cap. The installed 6-mod Circle set patches ~900 keys.
pub const max_keys: usize = 8192;
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
        arena_util.destroyHolder(&self.arena_ptr);
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
                // or a comma, doubling inner quotes; CR is folded to LF. The
                // bytes stream straight out, so a cell of any length survives
                // whole and a multi-byte glyph is never split.
                const quote = std.mem.indexOfAny(u8, v, "\",") != null;
                if (quote) try out.append(allocator, '"');
                for (v) |c| {
                    try out.append(allocator, if (c == '\r') '\n' else c);
                    if (c == '"') try out.append(allocator, '"');
                }
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
    // Stock's `DeflateOutputStream(_, 3)`: level 3 (`Options.level_3`), so the
    // compressed size sits where stock's does rather than at the default.
    var comp = try flate.Compress.init(&aw.writer, &window, .raw, flate.Compress.Options.level_3);
    try comp.writer.writeAll(src);
    try comp.finish();
    return try aw.toOwnedSlice();
}

/// Load the base header and merge every mod's `Config/Localization.csv`.
/// Null when the base file is absent (nothing to patch against).
pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return tryLoadWithMods(allocator, game_dir, config_dir, paths.modDirs());
}

/// Testable form of `tryLoad`: the mod dirs are passed in.
pub fn tryLoadWithMods(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    mod_dirs: []const mods.ModDir,
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
        var pos: usize = 0;
        const line = (try nextRecord(arena, base, &pos) orelse return null);
        var fields: [max_columns][]const u8 = undefined;
        const n = parseCsvLine(line, &fields);
        for (fields[0..@min(n, max_columns)], 0..) |f, i| {
            // A mod author editing a CSV often leaves a UTF-8 BOM on the first
            // cell; without stripping it the `Key` column stops matching.
            t.header[i] = try arena.dupe(u8, stripBom(f));
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
    var pos: usize = 0;
    const header_line = (try nextRecord(arena, text, &pos) orelse return);
    var hfields: [max_columns][]const u8 = undefined;
    const hn = parseCsvLine(header_line, &hfields);
    if (hn == 0) return;
    // Map this file's column position to the base column index by name.
    var col_map: [max_columns]?usize = .{null} ** max_columns;
    for (hfields[0..@min(hn, max_columns)], 0..) |name, i| {
        col_map[i] = t.columnIndex(std.mem.trim(u8, stripBom(name), " \t\r"));
    }
    var fields: [max_columns][]const u8 = undefined;
    while (try nextRecord(arena, text, &pos)) |line_raw| {
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

/// A UTF-8 byte-order mark, which spreadsheet exports leave on the first cell.
const utf8_bom = "\xEF\xBB\xBF";

fn stripBom(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, utf8_bom)) s[utf8_bom.len..] else s;
}

fn trimCr(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r");
}

const Scan = struct { end: usize, in_quote: bool };

/// Scan from `from` to the end of the line, tracking quoted state so a record
/// that holds a line break inside a quoted cell is not cut in half. `in_quote`
/// is the state on entry (a continuation line starts inside an open cell).
fn scanRecordLine(text: []const u8, from: usize, in_quote_in: bool) Scan {
    var in_quote = in_quote_in;
    var i = from;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"') {
            if (in_quote and i + 1 < text.len and text[i + 1] == '"') {
                i += 1;
                continue;
            }
            in_quote = !in_quote;
        } else if (c == '\n' and !in_quote) break;
    }
    return .{ .end = i, .in_quote = in_quote };
}

/// Next CSV record starting at `start.*`, advancing it past the record. Blank
/// lines are skipped. A record whose quoted cell spans a line break is joined
/// with `\n` into arena memory; every other record borrows `text`.
fn nextRecord(arena: std.mem.Allocator, text: []const u8, start: *usize) !?[]const u8 {
    while (start.* < text.len) {
        const first = start.*;
        const scan = scanRecordLine(text, first, false);
        start.* = if (scan.end < text.len) scan.end + 1 else text.len;
        if (!scan.in_quote) {
            const line = text[first..scan.end];
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            return line;
        }
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(arena, trimCr(text[first..scan.end]));
        var pos = start.*;
        var in_quote = true;
        while (in_quote and pos < text.len) {
            const cont = scanRecordLine(text, pos, true);
            try joined.append(arena, '\n');
            try joined.appendSlice(arena, trimCr(text[pos..cont.end]));
            in_quote = cont.in_quote;
            pos = if (cont.end < text.len) cont.end + 1 else text.len;
        }
        start.* = pos;
        return joined.items;
    }
    return null;
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
    const dir = try test_tmp.rootOf(&tmp);
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Config", .{dir});
    io_fs.mkdirPath(cfg);
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path = try std.fmt.bufPrint(&base_buf, "{s}/Localization.csv", .{cfg});
    try io_fs.writeFile(base_path,
        \\Key,File,Type,UsedInMainMenu,NoTranslate,KeepLoaded,english,Context,german
        \\cntTestCashRegister,blocks,Block,,x,,Test Cash Register,only for testing,x
        \\buffBase,buffs,Buff,,,,Base buff,,
        \\
    );
    var mod_a_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mod_a = try std.fmt.bufPrint(&mod_a_buf, "{s}/modA/Config", .{dir});
    io_fs.mkdirPath(mod_a);
    var mod_a_csv_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mod_a_csv = try std.fmt.bufPrint(&mod_a_csv_buf, "{s}/Localization.csv", .{mod_a});
    try io_fs.writeFile(mod_a_csv,
        \\Key,english
        \\buffBase,"Broken, Mod"
        \\modOnly,"He said ""hi"""
        \\
    );
    var mod_b_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mod_b = try std.fmt.bufPrint(&mod_b_buf, "{s}/modB/Config", .{dir});
    io_fs.mkdirPath(mod_b);
    var mod_b_csv_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mod_b_csv = try std.fmt.bufPrint(&mod_b_csv_buf, "{s}/Localization.csv", .{mod_b});
    try io_fs.writeFile(mod_b_csv,
        \\Key,german
        \\buffBase,Deutsch
        \\
    );

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
    const dir = try test_tmp.rootOf(&tmp);
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Config", .{dir});
    io_fs.mkdirPath(cfg);
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(try std.fmt.bufPrint(&base_buf, "{s}/Localization.csv", .{cfg}),
        \\Key,english
        \\a,one
        \\
    );
    var mod_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mod = try std.fmt.bufPrint(&mod_buf, "{s}/m/Config", .{dir});
    io_fs.mkdirPath(mod);
    var mod_csv_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(try std.fmt.bufPrint(&mod_csv_buf, "{s}/Localization.csv", .{mod}),
        \\Key,english
        \\zzPatched,patched value
        \\
    );
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

test "non-ASCII cells, a BOM header and a line break inside a cell all survive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{s}/Config", .{dir});
    io_fs.mkdirPath(cfg);
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(
        try std.fmt.bufPrint(&base_buf, "{s}/Localization.csv", .{cfg}),
        "\xEF\xBB\xBFKey,english,japanese\nbaseOnly,base value,ベース\n",
    );
    var mod_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const mod = try std.fmt.bufPrint(&mod_buf, "{s}/m/Config", .{dir});
    io_fs.mkdirPath(mod);
    var mod_csv_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(try std.fmt.bufPrint(&mod_csv_buf, "{s}/Localization.csv", .{mod}),
        \\Key,japanese
        \\multiLine,"first line
        \\second line"
        \\afterMulti,still a key
        \\
    );

    // A cell far past the per-cell cap, in a 3-byte script: the writer used to
    // drop it into a fixed stack buffer, which cut it and split glyphs.
    var long_jp: std.ArrayList(u8) = .empty;
    defer long_jp.deinit(std.testing.allocator);
    try long_jp.appendSlice(std.testing.allocator, "Key,japanese\nlongCell,\"");
    for (0..900) |_| try long_jp.appendSlice(std.testing.allocator, "日本語のテキスト");
    try long_jp.appendSlice(std.testing.allocator, "\"\n");
    const long_dir = try std.fmt.bufPrint(&mod_csv_buf, "{s}/../long/Config", .{mod});
    io_fs.mkdirPath(long_dir);
    var long_csv_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try io_fs.writeFile(try std.fmt.bufPrint(&long_csv_buf, "{s}/Localization.csv", .{long_dir}), long_jp.items);

    const dirs = [_]mods.ModDir{
        .{ .config_dir = mod, .mod_path = dir },
        .{ .config_dir = long_dir, .mod_path = dir },
    };
    var t = (try tryLoadWithMods(std.testing.allocator, null, cfg, &dirs)).?;
    defer t.deinit();
    // The BOM does not hide the base `Key` column from a mod's column mapping.
    try std.testing.expectEqualStrings("Key", t.header[0]);
    try std.testing.expectEqualStrings("japanese", t.header[2]);
    try std.testing.expectEqual(@as(usize, 3), t.entries.len);
    // The quoted cell holding a line break is one value, and the row after it
    // is still a row of its own.
    try std.testing.expectEqualStrings("first line\nsecond line", t.entries[0].cells[2].?);
    try std.testing.expectEqualStrings("afterMulti", t.entries[1].key);
    try std.testing.expectEqualStrings("still a key", t.entries[1].cells[2].?);

    const text = try t.csvText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "first line\nsecond line") != null);
    // The long cell is written whole, with every glyph intact.
    const cell_start = std.mem.indexOf(u8, text, "longCell,").?;
    var written: usize = 0;
    var it = std.mem.splitSequence(u8, text[cell_start..], "日本語のテキスト");
    while (it.next()) |_| written += 1;
    // `splitSequence` yields one more piece than it finds matches.
    try std.testing.expectEqual(@as(usize, 901), written);
}
