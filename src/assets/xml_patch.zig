//! Clean-room config XML patches (stock XmlPatcher subset).
//! Sources: modlet `Config/` dirs (via `applyModDirs`, stock mod order) and
//! `--config-overrides` dirs (via `applyOverrideDirs`), both in file order.
//!
//! Supported ops (element local name, case-insensitive):
//!   set / setattribute / setbyxpath            : set attribute or replace element text
//!   remove / removebyxpath                     : delete matched element
//!   removeattribute / removeattributebyxpath   : delete an attribute
//!   append / appendbyxpath                     : append child markup under matched element
//!   prepend / prependbyxpath                   : prepend child markup under matched element
//!   insertafter / insertbefore (byxpath)       : sibling insert
//!   csvoperations                              : comma-list edits on an attribute value
//!   include                                    : pull another patch file (@modfolder: tokens)
//!   conditional                                : NOT implemented (RE gap G5); fails closed
//!
//! XPath subset: /tag/tag[@attr='val']/... and optional trailing /@attr
//! Root may be <configs file="blocks.xml"> … or file inferred from first /tag
//! (stock also routes by patch file name; see applyPatchDoc).

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const mods = @import("modlets.zig");
const util_log = @import("../util/log.zig");

/// One predicate inside a `[...]` group (stock evaluates real XPath 1.0; a
/// modlet uses a small subset of it).
const XPredKind = enum {
    attr_eq,
    attr_contains,
    attr_starts_with,
    attr_exists,
    index_eq,
    /// `[child]` / `[child[@a='b']]`: the candidate must contain a child
    /// element with that tag (and, when `val` is non-empty, matching that
    /// inner predicate clause).
    child_exists,
};

const XPred = struct {
    kind: XPredKind = .attr_exists,
    attr: []const u8 = "",
    val: []const u8 = "",
    /// 1-based positional index for `[N]`.
    index: u32 = 0,
};

const XSeg = struct {
    tag: []const u8 = "",
    preds: [8]XPred = [_]XPred{.{}} ** 8,
    pred_n: u8 = 0,
    /// Multiple predicates combine with AND unless the group is written as an
    /// `or` chain (`[@name='a' or @name='b']`; simple modlets use one or the
    /// other).
    any: bool = false,
    /// `[last()]`: select the last node of this segment's match list.
    last: bool = false,
};

const ParsedXPath = struct {
    segs: [16]XSeg = [_]XSeg{.{}} ** 16,
    n: usize = 0,
    /// Trailing attribute name when xpath ends with /@attr
    set_attr: ?[]const u8 = null,
};

fn parseXPath(xpath: []const u8) ?ParsedXPath {
    var out: ParsedXPath = .{};
    var s = std.mem.trim(u8, xpath, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '/') s = s[1..];
    // Trailing /@attr
    if (std.mem.findLast(u8, s, "/@")) |at| {
        out.set_attr = s[at + 2 ..];
        s = s[0..at];
    }
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        if (out.n >= out.segs.len) return null;
        var seg: XSeg = .{};
        if (std.mem.findScalar(u8, raw, '[')) |br| {
            seg.tag = raw[0..br];
            // One or more [ ... ] groups: [@name='x'], [contains(@name,'y')],
            // [@a='1' and @b='2'], [@a='1' or @a='2'], [2], [@tag].
            var rest = raw[br..];
            while (std.mem.findScalar(u8, rest, '[')) |b2| {
                const e2 = matchingBracket(rest, b2) orelse return null;
                if (!tryParsePredicateGroup(&seg, rest[b2 + 1 .. e2])) return null;
                rest = rest[e2 + 1 ..];
            }
        } else {
            seg.tag = raw;
        }
        if (seg.tag.len == 0) return null;
        out.segs[out.n] = seg;
        out.n += 1;
    }
    if (out.n == 0) return null;
    return out;
}

/// Infer stock config file from first xpath tag (blocks → blocks.xml).
pub fn fileFromXPath(xpath: []const u8) ?[]const u8 {
    const p = parseXPath(xpath) orelse return null;
    if (p.n == 0) return null;
    const tag = p.segs[0].tag;
    // Common stock roots
    const map = [_]struct { []const u8, []const u8 }{
        .{ "blocks", "blocks.xml" },
        .{ "items", "items.xml" },
        .{ "recipes", "recipes.xml" },
        .{ "lootcontainers", "loot.xml" },
        .{ "loot", "loot.xml" },
        .{ "entity_classes", "entityclasses.xml" },
        .{ "entityclasses", "entityclasses.xml" },
        .{ "entitygroups", "entitygroups.xml" },
        .{ "quests", "quests.xml" },
        .{ "traders", "traders.xml" },
        .{ "spawning", "spawning.xml" },
        .{ "buffs", "buffs.xml" },
        .{ "progression", "progression.xml" },
        .{ "vehicles", "vehicles.xml" },
        .{ "biomes", "biomes.xml" },
        .{ "materials", "materials.xml" },
        .{ "painting", "painting.xml" },
        .{ "worldglobal", "worldglobal.xml" },
        .{ "gamestages", "gamestages.xml" },
        .{ "dialogs", "dialogs.xml" },
        .{ "npc", "npc.xml" },
        .{ "rwgmixer", "rwgmixer.xml" },
        .{ "utilityai", "utilityai.xml" },
        .{ "weathersurvival", "weathersurvival.xml" },
        .{ "challenges", "challenges.xml" },
        .{ "item_modifiers", "item_modifiers.xml" },
        // The item_modifiers.xml root is the singular `<item_modifier>`, which
        // is also what its patches address (`//item_modifier/...`).
        .{ "item_modifier", "item_modifiers.xml" },
        .{ "qualityinfo", "qualityinfo.xml" },
        .{ "shapes", "shapes.xml" },
        .{ "sounds", "sounds.xml" },
        .{ "events", "events.xml" },
        .{ "gameevents", "gameevents.xml" },
        .{ "archetypes", "archetypes.xml" },
        .{ "nav_objects", "nav_objects.xml" },
        .{ "misc", "misc.xml" },
    };
    for (map) |e| {
        if (std.mem.eql(u8, tag, e[0])) return e[1];
    }
    // Fallback: tag.xml
    return null;
}

/// Parse one `[...]` group into `seg`'s predicate list. False = malformed
/// (the whole xpath is then treated as unparsable, like a stock XPath error).
fn tryParsePredicateGroup(seg: *XSeg, inner_raw: []const u8) bool {
    const inner = std.mem.trim(u8, inner_raw, " \t\r\n");
    if (inner.len == 0) return false;
    const depth0_or = depthZeroFind(inner, " or ") != null;
    const depth0_and = depthZeroFind(inner, " and ") != null;
    if (depth0_or and depth0_and) return false; // mixed precedence: not modelled
    // Sticky: a later positional group (`[1]`) must not reset an earlier
    // `or` group's mode.
    if (depth0_or) seg.any = true;
    // Depth-aware split: a nested predicate carries its own ` and `
    // (`property[@name='a' and @value='b']`), so a plain substring split would
    // cut the group in half and reject the xpath.
    var clauses: [8][]const u8 = undefined;
    var nc: usize = 0;
    {
        const sep: []const u8 = if (depth0_or) " or " else " and ";
        var pos: usize = 0;
        while (pos <= inner.len) {
            const end = depthZeroFind(inner[pos..], sep) orelse (inner.len - pos);
            if (nc >= clauses.len) return false;
            clauses[nc] = std.mem.trim(u8, inner[pos .. pos + end], " \t\r\n");
            nc += 1;
            if (pos + end >= inner.len) break;
            pos += end + sep.len;
        }
    }
    for (clauses[0..nc]) |clause_raw| {
        const clause = clause_raw;
        if (clause.len == 0) return false;
        if (seg.pred_n >= seg.preds.len) return false;
        var pred: XPred = .{};
        if (std.mem.startsWith(u8, clause, "contains(") or std.mem.startsWith(u8, clause, "starts-with(")) {
            pred.kind = if (std.mem.startsWith(u8, clause, "contains(")) .attr_contains else .attr_starts_with;
            const open_paren = std.mem.findScalar(u8, clause, '(') orelse return false;
            const close = std.mem.findScalar(u8, clause, ')') orelse return false;
            if (close <= open_paren) return false;
            const args = clause[open_paren + 1 .. close];
            const comma = std.mem.findScalar(u8, args, ',') orelse return false;
            var a = std.mem.trim(u8, args[0..comma], " \t");
            if (a.len == 0 or a[0] != '@') return false;
            a = a[1..];
            pred.attr = a;
            pred.val = unquote(std.mem.trim(u8, args[comma + 1 ..], " \t"));
        } else if (clause[0] == '@') {
            const rest = clause[1..];
            if (std.mem.findScalar(u8, rest, '=')) |eq| {
                pred.kind = .attr_eq;
                pred.attr = std.mem.trim(u8, rest[0..eq], " \t");
                pred.val = unquote(std.mem.trim(u8, rest[eq + 1 ..], " \t"));
            } else {
                pred.kind = .attr_exists;
                pred.attr = std.mem.trim(u8, rest, " \t");
            }
            if (pred.attr.len == 0) return false;
        } else if (std.mem.eql(u8, clause, "last()")) {
            seg.last = true;
            continue;
        } else if (std.fmt.parseInt(u32, clause, 10)) |n| {
            // Bare number = positional predicate.
            if (n == 0) return false;
            pred.kind = .index_eq;
            pred.index = n;
        } else |_| {
            // `[child]` / `[child[@a='b' and @c='d']]`: an element-existence
            // test, the form Real modlets use to select by a child property
            // (`block[property[@name='Tags' and @value='treasureHunter']]`).
            // The inner clause is kept verbatim and parsed at match time, so a
            // nested predicate is evaluated rather than ignored.
            const br = std.mem.findScalar(u8, clause, '[');
            const child = std.mem.trim(u8, if (br) |b| clause[0..b] else clause, " \t");
            if (child.len == 0 or !std.ascii.isAlphabetic(child[0])) return false;
            pred.kind = .child_exists;
            pred.attr = child;
            if (br) |b| {
                const close_in = matchingBracket(clause, b) orelse return false;
                if (close_in <= b + 1) return false;
                pred.val = std.mem.trim(u8, clause[b + 1 .. close_in], " \t");
                if (pred.val.len == 0) return false;
            }
        }
        seg.preds[seg.pred_n] = pred;
        seg.pred_n += 1;
    }
    return true;
}

/// Index of the `)` matching the `(` at `open_at` (depth- and quote-aware, so
/// a nested call's own parentheses are skipped: `xpath('a[fn(@b, "c")]')`).
fn matchingParen(hay: []const u8, open_at: usize) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i: usize = open_at;
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Index of the `]` matching the `[` at `open_at` (depth- and quote-aware, so
/// a nested predicate's own brackets are skipped).
fn matchingBracket(hay: []const u8, open_at: usize) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i: usize = open_at;
    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// First occurrence of `needle` at bracket depth 0 and outside quotes. A
/// nested predicate's own separators live at depth 1, so they are skipped.
fn depthZeroFind(hay: []const u8, needle: []const u8) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        const c = hay[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '[' => depth += 1,
            ']' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
        if (depth == 0 and std.mem.startsWith(u8, hay[i..], needle)) return i;
    }
    return null;
}

/// Strip one layer of matching quotes from a predicate value.
fn unquote(v_in: []const u8) []const u8 {
    var v = std.mem.trim(u8, v_in, " \t");
    if (v.len >= 2 and (v[0] == '\'' or v[0] == '"') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
    return v;
}

fn predicateHolds(hay: []const u8, open_at: usize, p: XPred) bool {
    switch (p.kind) {
        .attr_exists => return xml.attr(hay, open_at, p.attr) != null,
        .attr_eq => {
            const got = xml.attr(hay, open_at, p.attr) orelse return false;
            return std.mem.eql(u8, got, p.val);
        },
        .attr_contains => {
            const got = xml.attr(hay, open_at, p.attr) orelse return false;
            return std.mem.find(u8, got, p.val) != null;
        },
        .attr_starts_with => {
            const got = xml.attr(hay, open_at, p.attr) orelse return false;
            return std.mem.startsWith(u8, got, p.val);
        },
        // Positional predicates are resolved by the match counter.
        .index_eq => return true,
        .child_exists => {
            const span = elementSpan(hay, open_at) orelse return false;
            // Skip the candidate's own opening tag so `[div]` on a `<div>`
            // does not match the element itself.
            const gt = std.mem.findPos(u8, hay, open_at, ">") orelse return false;
            if (gt >= span.end) return false;
            var inner_seg = XSeg{ .tag = p.attr };
            if (p.val.len > 0) {
                if (!tryParsePredicateGroup(&inner_seg, p.val)) return false;
            }
            var from = gt + 1;
            while (from < span.end) {
                const lt = std.mem.findPos(u8, hay, from, "<") orelse return false;
                if (lt >= span.end) return false;
                if (lt + 1 < hay.len and (hay[lt + 1] == '/' or hay[lt + 1] == '!' or hay[lt + 1] == '?')) {
                    from = lt + 1;
                    continue;
                }
                if (elementMatches(hay, lt, inner_seg)) return true;
                from = lt + 1;
            }
            return false;
        },
    }
}

/// Positional index of a segment (0 = every match).
fn segIndex(seg: XSeg) u32 {
    for (seg.preds[0..seg.pred_n]) |p| {
        if (p.kind == .index_eq) return p.index;
    }
    return 0;
}

fn elementMatches(hay: []const u8, open_at: usize, seg: XSeg) bool {
    // open_at points at '<'
    if (open_at + 1 + seg.tag.len > hay.len) return false;
    if (hay[open_at] != '<') return false;
    const tag_start = open_at + 1;
    if (!std.mem.startsWith(u8, hay[tag_start..], seg.tag)) return false;
    const after = tag_start + seg.tag.len;
    if (after < hay.len) {
        const c = hay[after];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != '>' and c != '/')
            return false;
    }
    if (seg.pred_n == 0) return true;
    if (seg.any) {
        for (seg.preds[0..seg.pred_n]) |p| {
            if (p.kind == .index_eq) continue;
            if (predicateHolds(hay, open_at, p)) return true;
        }
        return false;
    }
    for (seg.preds[0..seg.pred_n]) |p| {
        if (p.kind == .index_eq) continue;
        if (!predicateHolds(hay, open_at, p)) return false;
    }
    return true;
}

/// Cap on XPath result nodes per patch op (stock iterates the whole result
/// list; a wildcard patch on a stock catalog can match hundreds of nodes).
pub const max_xpath_matches: usize = 512;

/// Every open index matching `xp`, in document order (stock `singlePatch`
/// applies an op to each node in the XPath result list).
/// One matched element as a byte range in the document.
const Range = struct { start: usize, end: usize };

/// Collect matches of `xp.segs[seg..]` inside `hay[from_in..limit]` into `out`.
/// Offsets stay absolute, so a descendant search passes the parent's body
/// bounds rather than a sub-slice.
fn collectRanges(
    hay: []const u8,
    xp: ParsedXPath,
    seg: usize,
    from_in: usize,
    limit: usize,
    out: []Range,
    n: *usize,
) void {
    if (seg >= xp.n) return;
    var scan = from_in;
    while (scan < limit) {
        const lt = std.mem.findPos(u8, hay, scan, "<") orelse return;
        if (lt >= limit) return;
        if (lt + 1 < hay.len and (hay[lt + 1] == '/' or hay[lt + 1] == '!' or hay[lt + 1] == '?')) {
            scan = lt + 1;
            continue;
        }
        if (elementMatches(hay, lt, xp.segs[seg])) {
            const span = elementSpan(hay, lt) orelse {
                scan = lt + 1;
                continue;
            };
            if (seg + 1 == xp.n) {
                if (n.* >= out.len) return;
                out[n.*] = .{ .start = lt, .end = span.end };
                n.* += 1;
                // Keep scanning after this element so a nested or later
                // sibling match is still found.
                scan = lt + 1;
                continue;
            }
            const gt = std.mem.findPos(u8, hay, lt, ">") orelse return;
            if (gt > lt and hay[gt - 1] == '/') {
                scan = gt + 1;
                continue;
            }
            collectRanges(hay, xp, seg + 1, gt + 1, @min(span.end, limit), out, n);
        }
        scan = lt + 1;
    }
}

fn findAll(hay: []const u8, xp: ParsedXPath, out: []usize) usize {
    // Collect every match of the whole path, not just the first per ancestor:
    // restarting the scan for the full path after a match only finds further
    // matches when the path's FIRST segment is the repeated element
    // (`//item[x]`), so `/blocks/block[x]` stopped after one block.
    var ranges: [max_xpath_matches]Range = undefined;
    var n: usize = 0;
    collectRanges(hay, xp, 0, 0, hay.len, &ranges, &n);
    for (0..@min(n, out.len)) |i| out[i] = ranges[i].start;
    if (n > out.len) n = out.len;
    // Positional predicates (`[2]`) select one node out of the result list.
    // Stock's XPath applies the predicate per segment; the common modlet form
    // puts it on the final segment, where the full-path ordinal is the same.
    const idx = pathIndex(xp);
    if (idx > 0) {
        if (idx > n) return 0;
        out[0] = out[idx - 1];
        return 1;
    }
    if (pathLast(xp)) {
        if (n == 0) return 0;
        out[0] = out[n - 1];
        return 1;
    }
    return n;
}

/// True when the path ends in a `[last()]` group.
fn pathLast(xp: ParsedXPath) bool {
    for (xp.segs[0..xp.n]) |seg| {
        if (seg.last) return true;
    }
    return false;
}

/// Positional index of the last segment that carries one (0 = none).
fn pathIndex(xp: ParsedXPath) u32 {
    var out: u32 = 0;
    for (xp.segs[0..xp.n]) |seg| {
        const i = segIndex(seg);
        if (i > 0) out = i;
    }
    return out;
}

fn elementSpan(hay: []const u8, open_at: usize) ?struct { start: usize, end: usize } {
    const gt = std.mem.findPos(u8, hay, open_at, ">") orelse return null;
    if (gt > open_at and hay[gt - 1] == '/') {
        return .{ .start = open_at, .end = gt + 1 };
    }
    // tag name
    var t0 = open_at + 1;
    while (t0 < hay.len and (hay[t0] == ' ' or hay[t0] == '\t')) t0 += 1;
    var t1 = t0;
    while (t1 < hay.len) : (t1 += 1) {
        const c = hay[t1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
    }
    const tag = hay[t0..t1];
    var close_buf: [72]u8 = undefined;
    if (tag.len + 3 > close_buf.len) return null;
    close_buf[0] = '<';
    close_buf[1] = '/';
    @memcpy(close_buf[2..][0..tag.len], tag);
    close_buf[2 + tag.len] = '>';
    const close_tag = close_buf[0 .. 3 + tag.len];
    const close = std.mem.findPos(u8, hay, gt + 1, close_tag) orelse return null;
    return .{ .start = open_at, .end = close + close_tag.len };
}

fn setAttribute(allocator: std.mem.Allocator, hay: []const u8, open_at: usize, attr_name: []const u8, new_val: []const u8) ![]u8 {
    const gt = std.mem.findPos(u8, hay, open_at, ">") orelse return error.BadElement;
    const window = hay[open_at .. gt + 1];
    // Find attr="..."
    var needle_buf: [80]u8 = undefined;
    if (attr_name.len + 2 > needle_buf.len) return error.NameTooLong;
    @memcpy(needle_buf[0..attr_name.len], attr_name);
    needle_buf[attr_name.len] = '=';
    const needle = needle_buf[0 .. attr_name.len + 1];
    if (std.mem.find(u8, window, needle)) |ai| {
        var p = open_at + ai + needle.len;
        while (p < hay.len and (hay[p] == ' ' or hay[p] == '\t')) p += 1;
        if (p >= hay.len or hay[p] != '"') return error.BadAttr;
        const vstart = p + 1;
        const vend = std.mem.findScalarPos(u8, hay, vstart, '"') orelse return error.BadAttr;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, hay[0..vstart]);
        try out.appendSlice(allocator, new_val);
        try out.appendSlice(allocator, hay[vend..]);
        return try out.toOwnedSlice(allocator);
    }
    // Insert before '>'
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const insert_at = if (gt > open_at and hay[gt - 1] == '/') gt - 1 else gt;
    try out.appendSlice(allocator, hay[0..insert_at]);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, attr_name);
    try out.appendSlice(allocator, "=\"");
    try out.appendSlice(allocator, new_val);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, hay[insert_at..]);
    return try out.toOwnedSlice(allocator);
}

fn opNameEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Context for one patch application. Stock `XmlPatcher.PatchXml` passes the
/// patch file and the issuing `Mod` to each op (`mod-loading.md` §5.3).
pub const PatchCtx = struct {
    /// Patch file basename. Stock routes a patch to the config named by its
    /// file name (modlet convention: `Config/items.xml` patches `items.xml`),
    /// so a file-name match applies even when the xpath root does not resolve
    /// (G3 target selection; unverified against IL, superset implementation).
    patch_file_name: ?[]const u8 = null,
    /// Absolute path of the issuing mod folder, for `@modfolder:` tokens.
    mod_path: ?[]const u8 = null,
    /// Directory of the patch file being applied. Stock resolves an
    /// `<include filename="...">` relative to the including file, so a mod's
    /// subdirectory patch (`Config/Agility/main.xml`) is reachable.
    patch_file_dir: ?[]const u8 = null,
};

/// Directory part of `path` ("" when it has none). Used to resolve an
/// `<include filename>` against the including patch file, which is what stock
/// does.
fn dirnameOf(path: []const u8) []const u8 {
    const i = std.mem.findLast(u8, path, "/") orelse return "";
    return path[0..i];
}

/// Join a relative include path onto the including file's directory. An
/// absolute path (leading `/`) is left alone.
fn resolveRelativeInclude(allocator: std.mem.Allocator, path: []const u8, dir: ?[]const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return allocator.dupe(u8, path);
    const d = dir orelse return allocator.dupe(u8, path);
    if (d.len == 0) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ d, path });
}

/// Strip a trailing `.xml` (case-insensitive) for file-name routing.
fn stripXmlExt(s: []const u8) []const u8 {
    if (s.len >= 4 and std.ascii.eqlIgnoreCase(s[s.len - 4 ..], ".xml")) return s[0 .. s.len - 4];
    return s;
}

/// Basename of a path (after the last `/`).
fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, path, '/')) |sl| return path[sl + 1 ..];
    return path;
}

/// Splice `body` into `cur` at `pos` with newline framing (shared by
/// append/prepend/insertafter/insertbefore).
fn insertWithNewlines(allocator: std.mem.Allocator, cur: []const u8, pos: usize, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, cur[0..pos]);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, body);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, cur[pos..]);
    return try out.toOwnedSlice(allocator);
}

/// Remove `attr_name="..."` from the element opening at `open_at`.
/// Null when the attribute is absent (no-op, like a stock remove that matches
/// nothing). Caller frees the result when non-null.
fn removeAttributeFrom(allocator: std.mem.Allocator, cur: []const u8, open_at: usize, attr_name: []const u8) !?[]u8 {
    const gt = std.mem.findPos(u8, cur, open_at, ">") orelse return error.BadElement;
    const w = cur[open_at..gt];
    var i: usize = 0;
    while (i < w.len) {
        while (i < w.len and std.ascii.isWhitespace(w[i])) i += 1;
        const key_start = i;
        while (i < w.len and !std.ascii.isWhitespace(w[i]) and w[i] != '=') i += 1;
        const key = w[key_start..i];
        // A token that is not `key="value"` (the tag name, a bare valueless
        // attribute, an unquoted value) is skipped. `i` must move past it
        // first: the cursor only advances at the bottom of the loop, so a
        // `continue` from here without this would spin forever on operator
        // XML. An empty key means `i` is parked on punctuation; step over it.
        var eq = i;
        while (eq < w.len and std.ascii.isWhitespace(w[eq])) eq += 1;
        if (eq >= w.len or w[eq] != '=') {
            i = if (key.len == 0) i + 1 else eq;
            continue; // tag name or bare key
        }
        eq += 1;
        while (eq < w.len and std.ascii.isWhitespace(w[eq])) eq += 1;
        if (eq >= w.len or (w[eq] != '"' and w[eq] != '\'')) {
            i = eq;
            continue; // unquoted value
        }
        const quote = w[eq];
        eq += 1;
        while (eq < w.len and w[eq] != quote) eq += 1;
        if (eq >= w.len) return error.BadAttr;
        if (std.mem.eql(u8, key, attr_name)) {
            var seg_start = key_start;
            while (seg_start > 0 and std.ascii.isWhitespace(w[seg_start - 1])) seg_start -= 1;
            const seg_end = eq + 1;
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, cur[0 .. open_at + seg_start]);
            try out.appendSlice(allocator, cur[open_at + seg_end ..]);
            return try out.toOwnedSlice(allocator);
        }
        i = eq + 1;
    }
    return null;
}

/// Resolve `@modfolder:` / `@modfolder(Name):` tokens (stock
/// `ReadPatchXmlWithFixedModFolders`, G6). Absolute paths pass through.
/// Caller frees the result.
fn rewriteModFolder(allocator: std.mem.Allocator, path: []const u8, own_mod_path: ?[]const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "@modfolder:")) {
        const rest = path["@modfolder:".len..];
        const mp = own_mod_path orelse return error.MissingModFolder;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ mp, rest });
    }
    if (std.mem.startsWith(u8, path, "@modfolder(")) {
        const close = std.mem.findScalar(u8, path, ')') orelse return error.BadModFolderToken;
        const name = path["@modfolder(".len..close];
        var rest = path[close + 1 ..];
        if (rest.len > 0 and rest[0] == ':') rest = rest[1..];
        const mp = mods.modPathByName(name) orelse return error.UnknownModFolder;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ mp, rest });
    }
    return allocator.dupe(u8, path);
}

/// True when `want` is an entry of the comma-separated `cur_val`.
/// Delimiter of a `<csv>` patch: `delim` must be one character or the literal
/// two-character `\n` (stock CsvOperationsByXPath), default `,`.
fn csvDelim(clean: []const u8, op_open: usize) !u8 {
    const d = xml.attr(clean, op_open, "delim") orelse return ',';
    if (std.mem.eql(u8, d, "\\n") or std.mem.eql(u8, d, "\n")) return '\n';
    if (d.len != 1) return error.PatchInvalidDelim;
    return d[0];
}

fn csvHas(cur_val: []const u8, want: []const u8, delim: u8) bool {
    const want_t = std.mem.trim(u8, want, " \t");
    var it = std.mem.splitScalar(u8, cur_val, delim);
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " \t"), want_t)) return true;
    }
    return false;
}
fn csvRemove(allocator: std.mem.Allocator, cur_val: []const u8, drop: []const u8, delim: u8) !?[]u8 {
    const drop_t = std.mem.trim(u8, drop, " \t");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;
    var first = true;
    var it = std.mem.splitScalar(u8, cur_val, delim);
    while (it.next()) |entry| {
        const e = std.mem.trim(u8, entry, " \t");
        if (std.mem.eql(u8, e, drop_t)) {
            changed = true;
            continue;
        }
        if (!first) try out.append(allocator, delim);
        first = false;
        try out.appendSlice(allocator, entry);
    }
    if (!changed) return null;
    return try out.toOwnedSlice(allocator);
}

/// Replace a matched element's children with `body` (stock
/// `SetByXPath` -> `XElement.ReplaceNodes(patchElement.Nodes())`). A
/// self-closing match is expanded; an empty body clears the children.
fn replaceElementChildren(allocator: std.mem.Allocator, hay: []const u8, open_at: usize, body: []const u8) ![]u8 {
    const gt = std.mem.findPos(u8, hay, open_at, ">") orelse return error.BadElement;
    const self_close = gt > open_at and hay[gt - 1] == '/';
    const open_tag = if (self_close)
        try std.fmt.allocPrint(allocator, "{s}>", .{hay[open_at .. gt - 1]})
    else
        try allocator.dupe(u8, hay[open_at .. gt + 1]);
    defer allocator.free(open_tag);
    var t0 = open_at + 1;
    while (t0 < hay.len and (hay[t0] == ' ' or hay[t0] == '\t')) t0 += 1;
    var t1 = t0;
    while (t1 < hay.len) : (t1 += 1) {
        const c = hay[t1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
    }
    const tag = hay[t0..t1];
    const body_end = if (self_close) gt + 1 else blk: {
        const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
        defer allocator.free(close_tag);
        const cl = std.mem.findPos(u8, hay, gt + 1, close_tag) orelse return error.BadElement;
        break :blk cl + close_tag.len;
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, hay[0..open_at]);
    try out.appendSlice(allocator, open_tag);
    try out.appendSlice(allocator, body);
    try out.appendSlice(allocator, "</");
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, ">");
    try out.appendSlice(allocator, hay[body_end..]);
    return out.toOwnedSlice(allocator);
}

/// Append or prepend text to a matched element's attribute value (stock
/// `AppendByXPath`/`PrependByXPath` on an XAttribute target). Null when the
/// attribute is absent (no-op).
fn appendToAttributeValue(
    allocator: std.mem.Allocator,
    hay: []const u8,
    open_at: usize,
    attr_name: []const u8,
    text: []const u8,
    prepend: bool,
) !?[]u8 {
    const cur_val = xml.attr(hay, open_at, attr_name) orelse return null;
    const joined = if (prepend)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ text, cur_val })
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ cur_val, text });
    defer allocator.free(joined);
    return try setAttribute(allocator, hay, open_at, attr_name, joined);
}

/// XML entity unescape for a `cond` attribute value (the corpus writes
/// `&gt;` and `&quot;` inside the expression). Returns `in` when there is
/// nothing to unescape; otherwise writes into `buf` (a too-small buffer
/// leaves the text as-is, which then fails closed at the evaluator).
fn unescapeEntities(buf: []u8, in: []const u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < in.len) {
        if (in[i] == '&') {
            const rest = in[i..];
            const pair: ?struct { []const u8, u8 } = if (std.mem.startsWith(u8, rest, "&amp;"))
                .{ "&amp;", '&' }
            else if (std.mem.startsWith(u8, rest, "&lt;"))
                .{ "&lt;", '<' }
            else if (std.mem.startsWith(u8, rest, "&gt;"))
                .{ "&gt;", '>' }
            else if (std.mem.startsWith(u8, rest, "&quot;"))
                .{ "&quot;", '"' }
            else if (std.mem.startsWith(u8, rest, "&apos;"))
                .{ "&apos;", '\'' }
            else
                null;
            if (pair) |pr| {
                if (out >= buf.len) return in;
                buf[out] = pr[1];
                out += 1;
                i += pr[0].len;
                continue;
            }
        }
        if (out >= buf.len) return in;
        buf[out] = in[i];
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

/// A 4-component version, the shape NCalc's `version(a,b,c,d)` produces.
const Version = struct { c: [4]u16 = .{ 0, 0, 0, 0 } };

fn parseVersionString(s: []const u8) Version {
    var v: Version = .{};
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t"), '.');
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i >= 4) break;
        v.c[i] = std.fmt.parseInt(u16, std.mem.trim(u8, p, " \t"), 10) catch 0;
    }
    return v;
}

/// `version(1,0,81,1048)` or `mod_version('Name')` as a comparable version.
/// Null when the operand is neither (the caller then tries the string forms).
fn versionOperand(text_in: []const u8) ?Version {
    const t = std.mem.trim(u8, text_in, " \t");
    if (std.ascii.startsWithIgnoreCase(t, "version(")) {
        const open_paren = std.mem.findScalar(u8, t, '(') orelse return null;
        const close = matchingParen(t, open_paren) orelse return null;
        var v: Version = .{};
        var it = std.mem.splitScalar(u8, t[open_paren + 1 .. close], ',');
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) {
            if (i >= 4) break;
            v.c[i] = std.fmt.parseInt(u16, std.mem.trim(u8, p, " \t"), 10) catch return null;
        }
        return v;
    }
    if (std.ascii.startsWithIgnoreCase(t, "mod_version(")) {
        const open_paren = std.mem.findScalar(u8, t, '(') orelse return null;
        const close = matchingParen(t, open_paren) orelse return null;
        const name = unquote(std.mem.trim(u8, t[open_paren + 1 .. close], " \t"));
        if (name.len == 0) return null;
        // An absent mod compares as 0.0.0.0, which is what stock's
        // version-less ModInfo yields.
        return parseVersionString(mods.versionByName(name) orelse "");
    }
    return null;
}

const CmpOp = enum { eq, ne, gt, lt, ge, le };

fn compareVersions(a: Version, b: Version, op: CmpOp) bool {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (a.c[i] == b.c[i]) continue;
        const less = a.c[i] < b.c[i];
        return switch (op) {
            .eq => false,
            .ne => true,
            .gt => !less,
            .lt => less,
            .ge => !less,
            .le => less,
        };
    }
    return switch (op) {
        .eq, .ge, .le => true,
        .ne, .gt, .lt => false,
    };
}

/// Split `LHS OP RHS` on the first comparison operator outside quotes and
/// parentheses. Null when the expression carries no operator.
fn findComparison(expr: []const u8) ?struct { lhs: []const u8, rhs: []const u8, op: CmpOp } {
    var quote: u8 = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '=', '!', '>', '<' => {
                // Only a top-level operator compares: one inside `xpath(...)`
                // or a quoted value is part of an operand.
                if (depth != 0) continue;
                const two = i + 1 < expr.len and expr[i + 1] == '=';
                const op: CmpOp = if (c == '=') .eq else if (c == '!') .ne else if (c == '>') (if (two) .ge else .gt) else (if (two) .le else .lt);
                const skip: usize = if (two) 2 else 1;
                return .{
                    .lhs = std.mem.trim(u8, expr[0..i], " \t"),
                    .rhs = std.mem.trim(u8, expr[i + skip ..], " \t"),
                    .op = op,
                };
            },
            else => {},
        }
    }
    return null;
}

/// `null` / `!= null` / `== null` operand, the second half of an `xpath()`
/// existence test.
fn isNullLiteral(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), "null");
}

/// Evaluate the NCalc subset a modlet's `<if cond="...">` uses: `mod_loaded`,
/// `mod_version`, `version(a,b,c,d)` comparisons and the `xpath('...')`
/// existence test against the document being patched. Null = not evaluable
/// here (the caller skips the whole conditional with a warning rather than
/// guessing).
fn evaluateCondition(expr_in: []const u8, base: ?[]const u8) ?bool {
    var unesc_buf: [512]u8 = undefined;
    const unescaped = unescapeEntities(&unesc_buf, expr_in);
    var expr = std.mem.trim(u8, unescaped, " \t\r\n");
    var negate = false;
    while (expr.len > 0 and (expr[0] == '!')) {
        negate = !negate;
        expr = std.mem.trim(u8, expr[1..], " \t");
    }
    const answer: ?bool = blk: {
        if (findComparison(expr)) |cmp| {
            const lv = versionOperand(cmp.lhs);
            const rv = versionOperand(cmp.rhs);
            if (lv != null and rv != null) break :blk compareVersions(lv.?, rv.?, cmp.op);
            // xpath('...') == null / != null: an existence test against the
            // document being patched (stock evaluates the NCalc xpath()
            // function on the live XmlDocument).
            if (std.ascii.startsWithIgnoreCase(cmp.lhs, "xpath(") and isNullLiteral(cmp.rhs)) {
                const doc = base orelse break :blk null;
                const open_paren = std.mem.findScalar(u8, cmp.lhs, '(') orelse break :blk null;
                const close = matchingParen(cmp.lhs, open_paren) orelse break :blk null;
                const inner = unquote(std.mem.trim(u8, cmp.lhs[open_paren + 1 .. close], " \t"));
                const xp = parseXPath(inner) orelse break :blk null;
                var matches: [max_xpath_matches]usize = undefined;
                const exists = findAll(doc, xp, &matches) > 0;
                break :blk if (cmp.op == .ne) exists else !exists;
            }
        }
        if (std.ascii.startsWithIgnoreCase(expr, "mod_loaded(")) {
            const close = std.mem.findScalar(u8, expr, ')') orelse break :blk null;
            const arg = unquote(std.mem.trim(u8, expr["mod_loaded(".len..close], " \t"));
            if (arg.len == 0) break :blk null;
            break :blk mods.isLoaded(arg);
        }
        if (std.ascii.startsWithIgnoreCase(expr, "mod_version(")) {
            // mod_version('X') == '1.2' (also !=).
            const close = std.mem.findScalar(u8, expr, ')') orelse break :blk null;
            const arg = unquote(std.mem.trim(u8, expr["mod_version(".len..close], " \t"));
            const rest = std.mem.trim(u8, expr[close + 1 ..], " \t");
            const eq = std.mem.startsWith(u8, rest, "==");
            const ne = std.mem.startsWith(u8, rest, "!=");
            if (!eq and !ne) break :blk null;
            const want = unquote(std.mem.trim(u8, rest[2..], " \t"));
            const got = mods.versionByName(arg) orelse break :blk false;
            break :blk if (eq) std.mem.eql(u8, got, want) else !std.mem.eql(u8, got, want);
        }
        // game_version(...) needs the stock version string mapping, which
        // this server does not carry; leave it unevaluated.
        break :blk null;
    };
    const v = answer orelse return null;
    return if (negate) !v else v;
}

/// Inner XML of the conditional branch that applies: the first `<if cond=...>`
/// whose expression evaluates true, else the `<else>` body. Null when no
/// branch applies (or the expression language is not evaluable -> warn).
fn findConditionalBranch(clean: []const u8, op_open: usize, op_body: []const u8, base: ?[]const u8) ?[]const u8 {
    var else_body: ?[]const u8 = null;
    var saw_if = false;
    var i: usize = 0;
    while (i < op_body.len) {
        const lt = std.mem.findPos(u8, op_body, i, "<") orelse break;
        if (lt + 1 >= op_body.len) break;
        if (op_body[lt + 1] == '/') {
            i = lt + 1;
            continue;
        }
        var ne = lt + 1;
        while (ne < op_body.len) : (ne += 1) {
            const c = op_body[ne];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
        }
        const name = op_body[lt + 1 .. ne];
        const gt = std.mem.findPos(u8, op_body, lt, ">") orelse break;
        const self_close = gt > lt and op_body[gt - 1] == '/';
        var inner: []const u8 = "";
        var next_i = gt + 1;
        if (!self_close) {
            const close_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{name}) catch return null;
            defer std.heap.page_allocator.free(close_tag);
            const cl = std.mem.findPos(u8, op_body, gt + 1, close_tag) orelse break;
            inner = op_body[gt + 1 .. cl];
            next_i = cl + close_tag.len;
        }
        if (std.ascii.eqlIgnoreCase(name, "if")) {
            saw_if = true;
            const cond = xml.attr(op_body, lt, "cond") orelse {
                util_log.warn("zdtd: conditional patch 'if' without cond; block skipped\n", .{});
                return null;
            };
            if (evaluateCondition(cond, base)) |ok| {
                if (ok) return inner;
            } else {
                util_log.warn(
                    "zdtd: conditional expression '{s}' is not evaluable by this server; block skipped\n",
                    .{cond},
                );
                return null;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "else")) {
            else_body = inner;
        }
        i = next_i;
    }
    if (saw_if) return else_body;
    _ = clean;
    _ = op_open;
    return null;
}

/// True when `op` is one of the op local names this engine applies. Stock
/// resolves the op through a name lookup; a miss warns and skips the element.
fn isKnownOp(op: []const u8) bool {
    const names = [_][]const u8{
        "set",                    "setbyxpath",    "setattribute",       "setattributebyxpath",
        "setattributewithxpath",  "remove",        "removebyxpath",      "removeattribute",
        "removeattributebyxpath", "append",        "appendbyxpath",      "prepend",
        "prependbyxpath",         "insertafter",   "insertafterbyxpath", "insertbefore",
        "insertbeforebyxpath",    "csvoperations", "csv",                "include",
        "conditional",
    };
    for (names) |n| {
        if (opNameEq(op, n)) return true;
    }
    return false;
}

/// First 160 bytes of a rejected xpath, for one-line logging.
fn truncLog(v: []const u8) []const u8 {
    return v[0..@min(v.len, 160)];
}

/// Apply one patch document to base XML. Caller frees result.
/// Errors are load-time fatal (PRD R6): a patch that cannot be applied must
/// stop the server rather than silently desync AssignIds against the client.
pub fn applyPatchDoc(allocator: std.mem.Allocator, base: []const u8, patch_xml: []const u8, target_file: []const u8, ctx: PatchCtx) ![]u8 {
    const clean = try xml.stripComments(allocator, patch_xml);
    defer allocator.free(clean);
    var cur = try allocator.dupe(u8, base);
    errdefer allocator.free(cur);
    // Elements skipped because this engine's XPath subset could not parse
    // them. Counted (not just logged) so a partial patch is visible.
    var rejected_xpath_count: usize = 0;
    defer if (rejected_xpath_count > 0) {
        util_log.warn("zdtd: {d} patch element(s) skipped in this file (unsupported xpath)\n", .{rejected_xpath_count});
    };

    // Optional file= on configs root (explicit wins over everything).
    var patch_file_filter: ?[]const u8 = null;
    if (std.mem.find(u8, clean, "<configs")) |ci| {
        if (xml.attr(clean, ci, "file")) |f| patch_file_filter = f;
    }
    if (patch_file_filter) |pf| {
        if (!std.mem.eql(u8, pf, target_file)) {
            // Patch not for this file.
            return cur;
        }
    }
    // Stock file-name routing (G3): a patch file named after the config
    // applies to it even when the xpath root cannot be inferred.
    const file_name_match = if (ctx.patch_file_name) |pfn|
        std.mem.eql(u8, stripXmlExt(pfn), stripXmlExt(target_file))
    else
        false;

    var i: usize = 0;
    while (i < clean.len) {
        const lt = std.mem.findPos(u8, clean, i, "<") orelse break;
        if (lt + 1 >= clean.len) break;
        if (clean[lt + 1] == '/' or clean[lt + 1] == '!' or clean[lt + 1] == '?') {
            i = lt + 1;
            continue;
        }
        // op name
        var ne = lt + 1;
        while (ne < clean.len) : (ne += 1) {
            const c = clean[ne];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
        }
        const op = clean[lt + 1 .. ne];
        if (opNameEq(op, "configs") or opNameEq(op, "config")) {
            i = ne;
            continue;
        }
        const is_include = opNameEq(op, "include");
        const is_conditional = opNameEq(op, "conditional");
        const xpath = xml.attr(clean, lt, "xpath");
        const gt = std.mem.findPos(u8, clean, lt, ">") orelse break;
        const self_close = gt > lt and clean[gt - 1] == '/';
        var body: []const u8 = "";
        var next_i = gt + 1;
        if (!self_close) {
            var cbuf: [80]u8 = undefined;
            if (op.len + 3 > cbuf.len) {
                i = gt + 1;
                continue;
            }
            cbuf[0] = '<';
            cbuf[1] = '/';
            @memcpy(cbuf[2..][0..op.len], op);
            cbuf[2 + op.len] = '>';
            const ct = cbuf[0 .. 3 + op.len];
            const cl = std.mem.findPos(u8, clean, gt + 1, ct) orelse {
                i = gt + 1;
                continue;
            };
            body = std.mem.trim(u8, clean[gt + 1 .. cl], " \t\r\n");
            next_i = cl + ct.len;
        }

        if (!is_include and !is_conditional and xpath == null) {
            // An element with no xpath is either a container root (stock walks
            // the root's children and never treats it as an op, e.g. 0-SCore's
            // `<SCore name="XUi_Common/styles.xml">`) or a known op missing its
            // required xpath. Stock warns for the first and raises
            // XmlPatchException (abandoning that one file, continuing the boot)
            // for the second; both keep the ops already applied.
            if (isKnownOp(op)) {
                util_log.warn("zdtd: patch op '{s}' has no xpath; abandoning this patch file\n", .{op});
                return cur;
            }
            // A container: stock iterates the root's children, so the element
            // itself is not an op and its *children* are. Step just inside it.
            util_log.warn("zdtd: patch element '{s}' is not an op; treating it as a container\n", .{op});
            i = gt + 1;
            continue;
        }
        if (is_conditional) {
            // Stock `XmlPatchMethods.Conditional`: pick the active
            // `<if cond="...">` / `<else>` branch and patch with its children.
            // The condition language is NCalc; the functions a simple modlet
            // uses (mod_loaded, mod_version) are evaluated here. An expression
            // that cannot be evaluated skips the block with a warning rather
            // than aborting the boot: refusing to start on a popular mod is
            // worse than not applying one conditional block (the fail-closed
            // stance stays for a *malformed* patch, not for an unported
            // expression language).
            const branch = findConditionalBranch(clean, lt, body, cur) orelse {
                i = next_i;
                continue;
            };
            const next = applyPatchDoc(allocator, cur, branch, target_file, ctx) catch |err| {
                util_log.warn("zdtd: conditional patch branch failed: {s}\n", .{@errorName(err)});
                i = next_i;
                continue;
            };
            allocator.free(cur);
            cur = next;
            i = next_i;
            continue;
        }
        if (xpath) |xp0| {
            if (!is_include and patch_file_filter == null and !file_name_match) {
                // No file= and the file name does not select this target: route
                // by xpath root; no routing evidence means the op does not
                // belong to this config (skip the whole element, PRD R6).
                const inferred = fileFromXPath(xp0);
                if (inferred) |inf| {
                    if (!std.mem.eql(u8, inf, target_file)) {
                        i = next_i;
                        continue;
                    }
                } else {
                    i = next_i;
                    continue;
                }
            }
        }

        // include needs no xpath; handle it before the common xpath parse.
        // Stock reads `filename=` (XmlPatchMethods::Include) and resolves it
        // against the *including file's* directory; `path=`/`xpath=` stay as
        // tolerated aliases for older zdtd behaviour.
        if (is_include) {
            const inc_attr = xml.attr(clean, lt, "filename") orelse
                xml.attr(clean, lt, "path") orelse
                xml.attr(clean, lt, "xpath") orelse {
                util_log.warn("zdtd: include without filename/path; element skipped\n", .{});
                i = next_i;
                continue;
            };
            const rewritten = rewriteModFolder(allocator, inc_attr, ctx.mod_path) catch |err| {
                util_log.warn("zdtd: include '{s}' not resolvable: {s}; element skipped\n", .{ inc_attr, @errorName(err) });
                i = next_i;
                continue;
            };
            defer allocator.free(rewritten);
            const resolved = try resolveRelativeInclude(allocator, rewritten, ctx.patch_file_dir);
            defer allocator.free(resolved);
            const included = io_fs.readFileAll(allocator, resolved) catch |err| {
                // Stock raises XmlPatchException, which LoadAndPatchConfig
                // catches: that one patch file is dropped and the boot goes on.
                util_log.warn("zdtd: include '{s}' unreadable: {s}; file skipped\n", .{ resolved, @errorName(err) });
                return cur;
            };
            defer allocator.free(included);
            const next = applyPatchDoc(allocator, cur, included, target_file, .{
                .patch_file_name = basenameOf(resolved),
                .mod_path = ctx.mod_path,
                .patch_file_dir = dirnameOf(resolved),
            }) catch |err| {
                util_log.warn("zdtd: include '{s}' failed: {s}; file skipped\n", .{ resolved, @errorName(err) });
                return cur;
            };
            allocator.free(cur);
            cur = next;
            i = next_i;
            continue;
        }

        const xp = parseXPath(xpath.?) orelse {
            // The XPath subset here is narrower than XPath 1.0: a nested
            // predicate, `last()`, `*` or `//` lands here. Stock compiles the
            // real thing, so an xpath that reaches this arm may be valid stock
            // (logged loudly rather than skipped in silence): abandoning the
            // whole file would lose the ops the subset does handle.
            util_log.warn("zdtd: patch xpath not supported, element skipped: {s}\n", .{truncLog(xpath.?)});
            rejected_xpath_count += 1;
            i = next_i;
            continue;
        };

        // Stock `singlePatch` applies the op to every node in the XPath
        // result list; process them last-to-first so an earlier match's offset
        // stays valid while a later one is rewritten.
        var matches: [max_xpath_matches]usize = undefined;
        const nm = findAll(cur, xp, &matches);
        if (nm == 0) {
            // Stock logs a zero-match op and carries on (`XML patch for "X"
            // from mod "Y" did not apply`); the same signal is what tells an
            // operator a modlet's target moved. A/B against the stock server
            // on the installed SphereII corpus shows exactly two such rows.
            util_log.warn("zdtd: patch did not apply (no match) for {s}: {s}\n", .{ target_file, truncLog(xpath.?) });
            i = next_i;
            continue;
        }
        // Stock `set` handles both an attribute target (trailing /@attr) and an
        // element target (ReplaceNodes); `setattribute` is a distinct op whose
        // attribute name comes from the patch element's `name` attribute.
        const is_set = opNameEq(op, "set") or opNameEq(op, "setbyxpath");
        const is_set_attr = opNameEq(op, "setattribute") or opNameEq(op, "setattributebyxpath") or opNameEq(op, "setattributewithxpath");
        const is_remove = opNameEq(op, "remove") or opNameEq(op, "removebyxpath");
        const is_remove_attr = opNameEq(op, "removeattribute") or opNameEq(op, "removeattributebyxpath");
        const is_append = opNameEq(op, "append") or opNameEq(op, "appendbyxpath") or opNameEq(op, "prepend") or opNameEq(op, "prependbyxpath");
        const is_insert = opNameEq(op, "insertafter") or opNameEq(op, "insertafterbyxpath") or opNameEq(op, "insertbefore") or opNameEq(op, "insertbeforebyxpath");
        const is_csv = opNameEq(op, "csvoperations") or opNameEq(op, "csv");
        if (!is_set and !is_set_attr and !is_remove and !is_remove_attr and !is_append and !is_insert and !is_csv) {
            // Stock's local-name lookup miss warns and skips the element; the
            // boot continues (a code mod that registers its own op must not
            // take the whole config load with it).
            util_log.warn("zdtd: patch op '{s}' is not supported; element skipped\n", .{op});
            i = next_i;
            continue;
        }
        var mi: usize = nm;
        while (mi > 0) {
            mi -= 1;
            const open = matches[mi];
            if (is_set_attr) {
                // Stock SetAttributeByXPath: `name=` on the patch element names
                // the attribute; the xpath selects the element(s). Missing
                // `name` is a patch error in stock.
                const attr_name = xml.attr(clean, lt, "name") orelse return error.PatchMissingNameAttribute;
                const new_val = if (body.len > 0) body else (xml.attr(clean, lt, "value") orelse continue);
                const updated = try setAttribute(allocator, cur, open, attr_name, new_val);
                allocator.free(cur);
                cur = updated;
            } else if (is_set) {
                if (xp.set_attr) |attr_name| {
                    const new_val = if (body.len > 0) body else (xml.attr(clean, lt, "value") orelse continue);
                    const updated = try setAttribute(allocator, cur, open, attr_name, new_val);
                    allocator.free(cur);
                    cur = updated;
                } else {
                    // Element target: the patch body replaces the element's
                    // children (stock ReplaceNodes). A `value=` attribute is
                    // not part of the stock form for elements.
                    const updated = try replaceElementChildren(allocator, cur, open, body);
                    allocator.free(cur);
                    cur = updated;
                }
            } else if (is_remove) {
                // Stock RemoveByXPath refuses an attribute target ("use
                // removeattribute instead").
                if (xp.set_attr != null) continue;
                const span = elementSpan(cur, open) orelse continue;
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, cur[0..span.start]);
                try out.appendSlice(allocator, cur[span.end..]);
                allocator.free(cur);
                cur = try out.toOwnedSlice(allocator);
            } else if (is_remove_attr) {
                const attr_name = xp.set_attr orelse continue;
                const updated = try removeAttributeFrom(allocator, cur, open, attr_name) orelse continue;
                allocator.free(cur);
                cur = updated;
            } else if (is_append) {
                const is_prepend = opNameEq(op, "prepend") or opNameEq(op, "prependbyxpath");
                if (xp.set_attr) |attr_name| {
                    // Attribute target: text appended/prepended to the value.
                    if (try appendToAttributeValue(allocator, cur, open, attr_name, body, is_prepend)) |updated| {
                        allocator.free(cur);
                        cur = updated;
                    }
                    continue;
                }
                const span = elementSpan(cur, open) orelse continue;
                const gt2 = std.mem.findPos(u8, cur, open, ">") orelse continue;
                if (gt2 > open and cur[gt2 - 1] == '/') continue;
                const insert_at = if (is_prepend) gt2 + 1 else span.end - blk: {
                    // length of </tag>
                    var t0 = open + 1;
                    while (t0 < cur.len and (cur[t0] == ' ' or cur[t0] == '\t')) t0 += 1;
                    var t1 = t0;
                    while (t1 < cur.len) : (t1 += 1) {
                        const c = cur[t1];
                        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/') break;
                    }
                    break :blk (t1 - t0) + 3; // </tag>
                };
                if (insert_at > span.end or insert_at < open) continue;
                const updated = try insertWithNewlines(allocator, cur, insert_at, body);
                allocator.free(cur);
                cur = updated;
            } else if (is_insert) {
                if (xp.set_attr != null) continue;
                const span = elementSpan(cur, open) orelse continue;
                const is_after = opNameEq(op, "insertafter") or opNameEq(op, "insertafterbyxpath");
                const insert_at = if (is_after) span.end else span.start;
                const updated = try insertWithNewlines(allocator, cur, insert_at, body);
                allocator.free(cur);
                cur = updated;
            } else if (is_csv) {
                const attr_name = xp.set_attr orelse continue;
                const csv_op = xml.attr(clean, lt, "op") orelse continue;
                const val = if (body.len > 0) body else (xml.attr(clean, lt, "value") orelse continue);
                const delim = try csvDelim(clean, lt);
                // Stock splits the patch text on `delim`, trims each entry and
                // drops the empty ones, then adds/removes each entry against the
                // target list.
                var list: std.ArrayList(u8) = .empty;
                defer list.deinit(allocator);
                try list.appendSlice(allocator, xml.attr(cur, open, attr_name) orelse "");
                var vit = std.mem.splitScalar(u8, val, delim);
                while (vit.next()) |raw_entry| {
                    const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
                    if (entry.len == 0) continue;
                    if (opNameEq(csv_op, "add")) {
                        if (csvHas(list.items, entry, delim)) continue;
                        if (list.items.len > 0) try list.append(allocator, delim);
                        try list.appendSlice(allocator, entry);
                    } else if (opNameEq(csv_op, "remove")) {
                        const rv = try csvRemove(allocator, list.items, entry, delim) orelse continue;
                        defer allocator.free(rv);
                        list.clearRetainingCapacity();
                        try list.appendSlice(allocator, rv);
                    } else if (opNameEq(csv_op, "set")) {
                        list.clearRetainingCapacity();
                        try list.appendSlice(allocator, entry);
                    } else continue;
                }
                const updated = try setAttribute(allocator, cur, open, attr_name, list.items);
                allocator.free(cur);
                cur = updated;
            }
        }
        i = next_i;
    }
    return cur;
}

/// List *.xml under dir (non-recursive) into out paths (caller frees each full path).
/// Missing dir is a no-op (override path optional). Any other list failure is
/// logged and returned so a bad override path does not look like "no patches".
pub fn listXmlFilesSorted(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    const names = io_fs.listFileNames(allocator, dir_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.debug.print("zdtd: list override dir '{s}' failed: {s}\n", .{ dir_path, @errorName(err) });
            return err;
        },
    };
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    var xml_names: std.ArrayList([]const u8) = .empty;
    defer xml_names.deinit(allocator);
    for (names) |n| {
        if (!std.mem.endsWith(u8, n, ".xml")) continue;
        try xml_names.append(allocator, n);
    }
    std.mem.sort([]const u8, xml_names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (xml_names.items) |n| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, n });
        try out.append(allocator, full);
    }
}

/// Apply all override XMLs from dirs (dir order, then filename order) onto
/// base for target_file. Overrides stay optional: failures keep the current
/// bytes (paths.zig logs and uses what it has).
pub fn applyOverrideDirs(
    allocator: std.mem.Allocator,
    base: []const u8,
    target_file: []const u8,
    override_dirs: []const []const u8,
) ![]u8 {
    var cur = try allocator.dupe(u8, base);
    errdefer allocator.free(cur);
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    for (override_dirs) |d| {
        if (d.len == 0) continue;
        try listXmlFilesSorted(allocator, d, &files);
    }
    for (files.items) |fp| {
        const patch_raw = io_fs.readFileAll(allocator, fp) catch |err| {
            std.debug.print("zdtd: override {s} unreadable: {s}; skipped\n", .{ fp, @errorName(err) });
            continue;
        };
        defer allocator.free(patch_raw);
        const next = applyPatchDoc(allocator, cur, patch_raw, target_file, .{
            .patch_file_name = basenameOf(fp),
        }) catch |err| {
            std.debug.print("zdtd: override {s} failed: {s}; skipped\n", .{ fp, @errorName(err) });
            continue;
        };
        allocator.free(cur);
        cur = next;
    }
    return cur;
}

/// Apply mod `Config/` patch dirs in mod order (then file order per dir) onto
/// base for target_file, carrying each mod's path for `@modfolder:` tokens.
/// Errors are fatal (PRD R6): a mod patch that cannot be applied stops the
/// server instead of silently desyncing AssignIds against the client.
pub fn applyModDirs(
    allocator: std.mem.Allocator,
    base: []const u8,
    target_file: []const u8,
    mod_dirs: []const mods.ModDir,
) ![]u8 {
    var cur = try allocator.dupe(u8, base);
    errdefer allocator.free(cur);
    for (mod_dirs) |md| {
        // Stock `XmlPatcher.LoadAndPatchConfig` resolves a mod's patch for one
        // config as `<mod>/Config/<configName>` (".xml" appended when the name
        // does not carry it), which is also how a config in a subdirectory is
        // patched (`Config/XUi_InGame/windows.xml`). Apply that file first.
        var exact_buf: [2048]u8 = undefined;
        var exact_buf2: [2048]u8 = undefined;
        var exact: ?[]const u8 = null;
        if (std.fmt.bufPrint(&exact_buf, "{s}/{s}", .{ md.config_dir, target_file })) |p| {
            if (io_fs.fileExists(p)) {
                exact = p;
            } else if (!std.mem.endsWith(u8, p, ".xml")) {
                if (std.fmt.bufPrint(&exact_buf2, "{s}.xml", .{p})) |p2| {
                    if (io_fs.fileExists(p2)) exact = p2;
                } else |_| {}
            }
        } else |_| {}
        if (exact) |ep| {
            // The stock path evidence is the exact config name, so route the
            // patch by it (a subdirectory config like XUi_InGame/windows has
            // no inferable xpath root).
            const next = try applyOnePatchFile(allocator, cur, ep, target_file, md.mod_path, target_file);
            allocator.free(cur);
            cur = next;
        }
        // Plus every other xml under the mod's `Config/` (the common modlet
        // layout is already covered above; a file named differently is routed
        // by its xpath root, which is what zdtd has always done and what
        // mods with a single combined patch file rely on).
        var files: std.ArrayList([]const u8) = .empty;
        defer {
            for (files.items) |p| allocator.free(p);
            files.deinit(allocator);
        }
        try listXmlFilesSorted(allocator, md.config_dir, &files);
        for (files.items) |fp| {
            if (exact) |ep| {
                if (std.mem.eql(u8, fp, ep)) continue;
            }
            const next = try applyOnePatchFile(allocator, cur, fp, target_file, md.mod_path, basenameOf(fp));
            allocator.free(cur);
            cur = next;
        }
    }
    return cur;
}

/// Read one patch file and apply it to `cur_in` (caller owns the result).
fn applyOnePatchFile(
    allocator: std.mem.Allocator,
    cur_in: []const u8,
    patch_path: []const u8,
    target_file: []const u8,
    mod_path: []const u8,
    /// Name used for the stock file-name routing: the exact config name for
    /// the `<mod>/Config/<configName>` pass, the basename for the per-file
    /// scan.
    route_name: []const u8,
) ![]u8 {
    const patch_raw = try io_fs.readFileAll(allocator, patch_path);
    defer allocator.free(patch_raw);
    return applyPatchDoc(allocator, cur_in, patch_raw, target_file, .{
        .patch_file_name = route_name,
        .mod_path = mod_path,
        .patch_file_dir = dirnameOf(patch_path),
    });
}

test "parse xpath property value" {
    const p = parseXPath("/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value").?;
    try std.testing.expectEqual(@as(usize, 3), p.n);
    try std.testing.expectEqualStrings("blocks", p.segs[0].tag);
    try std.testing.expectEqualStrings("block", p.segs[1].tag);
    try std.testing.expectEqual(@as(u8, 1), p.segs[1].pred_n);
    try std.testing.expectEqual(XPredKind.attr_eq, p.segs[1].preds[0].kind);
    try std.testing.expectEqualStrings("name", p.segs[1].preds[0].attr);
    try std.testing.expectEqualStrings("generatorbank", p.segs[1].preds[0].val);
    try std.testing.expectEqualStrings("value", p.set_attr.?);
}

test "set MaxFuel on generatorbank" {
    const base =
        \\<blocks>
        \\<block name="generatorbank">
        \\  <property name="MaxFuel" value="1000"/>
        \\  <property name="MaxPower" value="12250"/>
        \\</block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <set xpath="/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value">50</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "value=\"50\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "12250") != null);
}

test "set the root element attribute a modlet raises the quality tier with" {
    // The stock-supported way to move `ItemClass.MaxQualityTier`: a root
    // attribute patch (`/items/@max_quality_tier`), which `items.zig` then
    // reads as the quality-axis bound.
    const base =
        \\<items>
        \\<item name="gunMaster">
        \\  <property name="Stacknumber" value="1"/>
        \\</item>
        \\</items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <set xpath="/items/@max_quality_tier">10</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "max_quality_tier=\"10\"") != null);
}

test "remove block" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\<block name="b"><property name="x" value="2"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs>
        \\  <remove xpath="/blocks/block[@name='a']"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"a\"") == null);
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);
}

test "prepend inserts after the opening tag" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <prepend xpath="/blocks/block[@name='a']"><property name="pre" value="1"/></prepend>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    // prepended property precedes the original child
    const pre = std.mem.find(u8, out, "name=\"pre\"").?;
    const x = std.mem.find(u8, out, "name=\"x\"").?;
    try std.testing.expect(pre < x);
}

test "insertafter places a sibling after the matched element" {
    const base =
        \\<blocks>
        \\<block name="a"><property name="x" value="1"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <insertafter xpath="/blocks/block[@name='a']"><block name="b"/></insertafter>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);
    const a = std.mem.find(u8, out, "name=\"a\"").?;
    const b = std.mem.find(u8, out, "name=\"b\"").?;
    try std.testing.expect(a < b);
}

test "removeattribute drops one attribute from the element" {
    const base =
        \\<blocks>
        \\<block name="a" class="terrain" hardness="3"><property name="x" value="1"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <removeattribute xpath="/blocks/block[@name='a']/@class"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "class=") == null);
    try std.testing.expect(std.mem.find(u8, out, "hardness=\"3\"") != null);
}

test "removeattribute terminates on an unquoted or bare attribute" {
    // The attribute scan must always advance: a modlet is operator-supplied
    // XML, so an unquoted value (hardness=3) or a bare token (disabled) in the
    // opening tag used to leave the cursor parked and spin forever, hanging the
    // load. Malformed input must fail or no-op, never hang.
    const cases = [_][]const u8{
        // unquoted value after the target attribute
        \\<blocks>
        \\<block name="a" class="terrain" hardness=3></block>
        \\</blocks>
        ,
        // bare valueless token in the opening tag
        \\<blocks>
        \\<block name="a" class="terrain" disabled></block>
        \\</blocks>
        ,
        // unquoted value before the target attribute
        \\<blocks>
        \\<block name="a" hardness=3 class="terrain"></block>
        \\</blocks>
        ,
    };
    const patch =
        \\<configs file="blocks.xml">
        \\  <removeattribute xpath="/blocks/block[@name='a']/@class"/>
        \\</configs>
    ;
    for (cases) |base| {
        const out = applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{}) catch continue;
        defer std.testing.allocator.free(out);
        // Termination is the point, but the scan must still find the target:
        // a quoted attribute after a malformed neighbour is removed normally.
        try std.testing.expect(std.mem.find(u8, out, "class=") == null);
        try std.testing.expect(std.mem.find(u8, out, "name=\"a\"") != null);
    }
}

test "csvoperations add and remove on a comma list" {
    const base =
        \\<items>
        \\<item name="x"><property name="Tags" value="a,b,c"/></item>
        \\</items>
    ;
    const add_patch =
        \\<configs file="items.xml">
        \\  <csvoperations xpath="/items/item[@name='x']/property[@name='Tags']/@value" op="add" value="d"/>
        \\</configs>
    ;
    const after_add = try applyPatchDoc(std.testing.allocator, base, add_patch, "items.xml", .{});
    defer std.testing.allocator.free(after_add);
    try std.testing.expect(std.mem.find(u8, after_add, "value=\"a,b,c,d\"") != null);

    const rm_patch =
        \\<configs file="items.xml">
        \\  <csvoperations xpath="/items/item[@name='x']/property[@name='Tags']/@value" op="remove" value="b"/>
        \\</configs>
    ;
    const after_rm = try applyPatchDoc(std.testing.allocator, base, rm_patch, "items.xml", .{});
    defer std.testing.allocator.free(after_rm);
    try std.testing.expect(std.mem.find(u8, after_rm, "value=\"a,c\"") != null);
}

test "file name routes a patch with an unresolvable xpath root" {
    // Stock modlet convention (G3): Config/loadingscreen.xml targets
    // loadingscreen.xml, and must not leak into other catalogs even though
    // /loadingscreen is not in the inference map.
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    const patch =
        \\<configs>
        \\  <append xpath="/loadingscreen/tip"><tip text="hi"/></append>
        \\</configs>
    ;
    // Patch file named blocks.xml applies to blocks.xml (append no-ops: xpath
    // not found) instead of leaking.
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{ .patch_file_name = "blocks.xml" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("<blocks><block name=\"a\"/></blocks>", out);
    // With no routing evidence and no file name, the op is skipped entirely.
    const out2 = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings("<blocks><block name=\"a\"/></blocks>", out2);
}

test "unknown op is skipped, the rest of the file still applies" {
    // Stock resolves the op through a local-name lookup and warns on a miss
    // (XmlPatcher IL_0176-0204); killing the server instead turned a code
    // modlet that registers its own op into a boot failure. Everything else
    // in the file still applies.
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <append xpath="/blocks"><block name="b"/></append>
        \\  <frobnicate xpath="/blocks/block[@name='a']"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);
}

test "conditional picks the if/else branch, unknown expressions skip" {
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    // No mods installed: mod_loaded('X') is false, so the else branch applies.
    const patch =
        \\<configs file="blocks.xml">
        \\  <conditional>
        \\    <if cond="mod_loaded('NotInstalled')"><append xpath="/blocks"><block name="fromIf"/></append></if>
        \\    <else><append xpath="/blocks"><block name="fromElse"/></append></else>
        \\  </conditional>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "fromElse") != null);
    try std.testing.expect(std.mem.find(u8, out, "fromIf") == null);

    // An expression this server cannot evaluate skips the whole block (no
    // change, no boot failure): NCalc's game_version needs the stock version
    // string mapping zdtd does not carry.
    const unevaluable =
        \\<configs file="blocks.xml">
        \\  <conditional>
        \\    <if cond="game_version('V 2.0 (b8)')"><append xpath="/blocks"><block name="gv"/></append></if>
        \\  </conditional>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, unevaluable, "blocks.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(base, out2);
}

test "xpath predicates: contains, starts-with, and/or, position, existence" {
    const base =
        \\<items>
        \\<item name="a_rifle"><property name="Tags" value="rifleSkill"/><property name="Damage" value="1"/></item>
        \\<item name="a_pistol"><property name="Tags" value="handgunSkill"/></item>
        \\<item name="b_rifle"><property name="Tags" value="rifleSkill"/></item>
        \\</items>
    ;
    // contains(): every rifle item is patched (stock applies to all matches).
    const contains_patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[contains(@name,'rifle')]/property[@name='Tags']/@value">patched</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, contains_patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "value=\"patched\""));

    // starts-with() + 'or' over two name values, through `setattribute`
    // (attribute name from the patch element's `name` attribute, stock
    // SetAttributeByXPath) on the element target.
    const or_patch =
        \\<configs file="items.xml">
        \\  <setattribute xpath="//item[starts-with(@name,'a_') or @name='b_rifle'][1]" name="CustomIcon">anIcon</setattribute>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, or_patch, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "CustomIcon=\"anIcon\"") != null);
    // A `name`-less setattribute is a patch error (stock throws).
    const bad_attr =
        \\<configs file="items.xml">
        \\  <setattribute xpath="//item[@name='a_rifle']">x</setattribute>
        \\</configs>
    ;
    try std.testing.expectError(error.PatchMissingNameAttribute, applyPatchDoc(std.testing.allocator, base, bad_attr, "items.xml", .{}));

    // Positional [2] selects the second match.
    const pos_patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[contains(@name,'rifle')][2]/property[@name='Tags']/@value">second</set>
        \\</configs>
    ;
    const out3 = try applyPatchDoc(std.testing.allocator, base, pos_patch, "items.xml", .{});
    defer std.testing.allocator.free(out3);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out3, "second"));

    // Attribute existence.
    const exists_patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[@name]"><item name="renamed"/></set>
        \\</configs>
    ;
    const out4 = try applyPatchDoc(std.testing.allocator, base, exists_patch, "items.xml", .{});
    defer std.testing.allocator.free(out4);
    try std.testing.expect(std.mem.find(u8, out4, "renamed") != null);
}

test "csv op name and attribute append match the stock forms" {
    const base =
        \\<items><item name="x"><property name="Tags" value="a,b"/></item></items>
    ;
    const csv_patch =
        \\<configs file="items.xml">
        \\  <csv op="add" xpath="/items/item[@name='x']/property[@name='Tags']/@value">c</csv>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, csv_patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "value=\"a,b,c\"") != null);

    // append to an /@attr target appends to the attribute text (stock
    // AppendByXPath on an XAttribute).
    const append_patch =
        \\<configs file="items.xml">
        \\  <append xpath="/items/item[@name='x']/property[@name='Tags']/@value">,d</append>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, append_patch, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "value=\"a,b,d\"") != null);
}

test "csv honours delim and adds each entry (stock grammar)" {
    // Stock CsvOperationsByXPath: op add|remove, `delim` exactly one character
    // or the literal \n, default comma; the patch text is split, trimmed and
    // each entry added/removed against the target list.
    const base =
        \\<items><item name="x"><property name="Groups" value="a;b"/></item></items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <csv op="add" delim=";" xpath="/items/item[@name='x']/property[@name='Groups']/@value">c;d</csv>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "value=\"a;b;c;d\"") != null);

    // Adding an entry already present is a no-op; removing one works.
    const dedup =
        \\<configs file="items.xml">
        \\  <csv op="add" delim=";" xpath="/items/item[@name='x']/property[@name='Groups']/@value">b</csv>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, dedup, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "value=\"a;b\"") != null);
    const rm =
        \\<configs file="items.xml">
        \\  <csv op="remove" delim=";" xpath="/items/item[@name='x']/property[@name='Groups']/@value">a</csv>
        \\</configs>
    ;
    const out3 = try applyPatchDoc(std.testing.allocator, base, rm, "items.xml", .{});
    defer std.testing.allocator.free(out3);
    try std.testing.expect(std.mem.find(u8, out3, "value=\"b\"") != null);

    // The literal `\n` delim splits on real newlines in the patch text.
    const nl_base = "<items><item name=\"x\"><property name=\"Groups\" value=\"a\"/></item></items>";
    const nl_patch =
        \\<configs file="items.xml">
        \\  <csv op="add" delim="\n" xpath="/items/item[@name='x']/property[@name='Groups']/@value">
        \\b
        \\c
        \\  </csv>
        \\</configs>
    ;
    const out4 = try applyPatchDoc(std.testing.allocator, nl_base, nl_patch, "items.xml", .{});
    defer std.testing.allocator.free(out4);
    try std.testing.expect(std.mem.find(u8, out4, "value=\"a\nb\nc\"") != null);

    // A multi-character delimiter is a patch error (stock throws).
    const bad =
        \\<configs file="items.xml">
        \\  <csv op="add" delim=";;" xpath="/items/item[@name='x']/property[@name='Groups']/@value">c</csv>
        \\</configs>
    ;
    try std.testing.expectError(error.PatchInvalidDelim, applyPatchDoc(std.testing.allocator, base, bad, "items.xml", .{}));
}

test "set on an element replaces its children (stock ReplaceNodes)" {
    const base =
        \\<items><item name="x"><property name="Old" value="1"/></item></items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <set xpath="//item[@name='x']"><property name="New" value="2"/></set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"New\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "name=\"Old\"") == null);
    // A self-closing match expands to hold the new children.
    const base2 =
        \\<items><item name="y"/></items>
    ;
    const patch2 =
        \\<configs file="items.xml">
        \\  <set xpath="//item[@name='y']"><property name="A" value="1"/></set>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base2, patch2, "items.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "<item name=\"y\"><property name=\"A\" value=\"1\"/></item>") != null);
}

test "remove with an attribute target is a no-op (stock guard)" {
    const base =
        \\<items><item name="x"><property name="Tags" value="a"/></item></items>
    ;
    const patch =
        \\<configs file="items.xml">
        \\  <remove xpath="/items/item[@name='x']/property[@name='Tags']/@value"/>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "items.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(base, out);
}

test "a realistic xml-only modlet applies through the scan and patch path" {
    // The shape a 7daystodiemods.com XML-only modlet ships: ModInfo.xml V2,
    // Config/ patches (append a new item, set an existing property, csv-add a
    // tag, conditional on a mod that is not installed), Bundles/ and
    // Localization.csv that the server tolerates without reading.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const mod_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods/SimpleMod", .{root});
    defer std.testing.allocator.free(mod_dir);
    const cfg_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Config", .{mod_dir});
    defer std.testing.allocator.free(cfg_dir);
    const bnd_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Bundles", .{mod_dir});
    defer std.testing.allocator.free(bnd_dir);
    io_fs.mkdirPath(cfg_dir);
    io_fs.mkdirPath(bnd_dir);
    const modinfo = try std.fmt.allocPrint(std.testing.allocator, "{s}/ModInfo.xml", .{mod_dir});
    defer std.testing.allocator.free(modinfo);
    try io_fs.writeFile(modinfo,
        \\<xml>
        \\  <Name value="SimpleMod"/>
        \\  <DisplayName value="Simple Mod"/>
        \\  <Version value="1.2"/>
        \\  <Author value="someone"/>
        \\</xml>
    );
    const items_patch = try std.fmt.allocPrint(std.testing.allocator, "{s}/items.xml", .{cfg_dir});
    defer std.testing.allocator.free(items_patch);
    try io_fs.writeFile(items_patch,
        \\<configs>
        \\  <append xpath="/items">
        \\    <item name="simpleModItem">
        \\      <property name="Stacknumber" value="250"/>
        \\      <property name="Tags" value="simple,modded"/>
        \\    </item>
        \\  </append>
        \\  <set xpath="/items/item[@name='existing']/property[@name='Stacknumber']/@value">99</set>
        \\  <csv op="add" xpath="/items/item[@name='existing']/property[@name='Tags']/@value">fromMod</csv>
        \\  <conditional>
        \\    <if cond="mod_loaded('SomeOtherMod')"><append xpath="/items"><item name="shouldNotAppear"/></append></if>
        \\  </conditional>
        \\</configs>
    );
    const loc = try std.fmt.allocPrint(std.testing.allocator, "{s}/Localization.csv", .{cfg_dir});
    defer std.testing.allocator.free(loc);
    try io_fs.writeFile(loc, "simpleModItem,simpleModItemName,Simple Mod Item\n");
    // A config that lives in a subdirectory of the base Config tree is patched
    // by the same relative path under the mod's Config/ (stock resolves
    // `<mod>/Config/<configName>`), e.g. XUi_InGame/windows.
    const xui_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/XUi_InGame", .{cfg_dir});
    defer std.testing.allocator.free(xui_dir);
    io_fs.mkdirPath(xui_dir);
    const xui_patch = try std.fmt.allocPrint(std.testing.allocator, "{s}/windows.xml", .{xui_dir});
    defer std.testing.allocator.free(xui_patch);
    try io_fs.writeFile(xui_patch,
        \\<configs>
        \\  <append xpath="/windows"><window name="modWindow"/></append>
        \\</configs>
    );

    const mods_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods", .{root});
    defer std.testing.allocator.free(mods_root);
    const dirs = try mods.install(std.testing.allocator, mods_root, null);
    defer mods.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expect(mods.isLoaded("simplemod"));
    try std.testing.expectEqualStrings("1.2", mods.versionByName("SimpleMod").?);

    const base =
        \\<items><item name="existing"><property name="Stacknumber" value="1"/><property name="Tags" value="a"/></item></items>
    ;
    const out = try applyModDirs(std.testing.allocator, base, "items.xml", dirs);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "simpleModItem") != null);
    try std.testing.expect(std.mem.find(u8, out, "value=\"99\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "value=\"a,fromMod\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "shouldNotAppear") == null);
    // The matching-name file is applied exactly once (the per-file scan skips
    // the file the exact-name pass already used).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "simpleModItem"));

    const xui_base = "<windows><window name=\"base\"/></windows>";
    const xui_out = try applyModDirs(std.testing.allocator, xui_base, "XUi_InGame/windows", dirs);
    defer std.testing.allocator.free(xui_out);
    try std.testing.expect(std.mem.find(u8, xui_out, "modWindow") != null);
}

test "include with @modfolder token pulls another patch file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    const mods_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/Mods", .{root});
    defer std.testing.allocator.free(mods_root);
    const mod_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/A", .{mods_root});
    defer std.testing.allocator.free(mod_dir);
    const cfg_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/Config", .{mod_dir});
    defer std.testing.allocator.free(cfg_dir);
    io_fs.mkdirPath(cfg_dir);
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mi = try std.fmt.bufPrint(&p_buf, "{s}/ModInfo.xml", .{mod_dir});
    try io_fs.writeFile(mi, "<xml><Name value=\"A\"/><DisplayName value=\"A\"/><Version value=\"1.0\"/></xml>");
    const main_f = try std.fmt.bufPrint(&p_buf, "{s}/main.xml", .{cfg_dir});
    try io_fs.writeFile(main_f, "<configs file=\"blocks.xml\"><include xpath=\"@modfolder:/Config/inc.xml\"/></configs>");
    const inc_f = try std.fmt.bufPrint(&p_buf, "{s}/inc.xml", .{cfg_dir});
    try io_fs.writeFile(inc_f, "<configs file=\"blocks.xml\"><append xpath=\"/blocks/block[@name='a']\"><property name=\"FromInclude\" value=\"1\"/></append></configs>");

    const mod_dirs = try mods.install(std.testing.allocator, mods_root, null);
    defer mods.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mod_dirs.len);

    const base =
        \\<blocks><block name="a"><property name="x" value="1"/></block></blocks>
    ;
    const out = try applyModDirs(std.testing.allocator, base, "blocks.xml", mod_dirs);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "FromInclude") != null);
}

test "fileFromXPath" {
    try std.testing.expectEqualStrings("blocks.xml", fileFromXPath("/blocks/block[@name='x']").?);
    try std.testing.expectEqualStrings("items.xml", fileFromXPath("/items/item[@name='y']").?);
}

test "include filename resolves against the including patch file's directory" {
    // Stock `XmlPatchMethods::Include` reads `filename=` and joins it with the
    // *including file's* directory, which is how a mod reaches a subdirectory
    // patch (SphereII's `Config/Agility/main.xml` includes `Init.xml` next to
    // it). zdtd used to read `xpath`/`path`, resolve against the CWD and treat
    // a miss as fatal, so those modlets refused the boot.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/Agility", .{dir});
    io_fs.mkdirPath(sub);
    var main_buf: [std.fs.max_path_bytes]u8 = undefined;
    const main_path = try std.fmt.bufPrint(&main_buf, "{s}/main.xml", .{sub});
    var inc_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inc_path = try std.fmt.bufPrint(&inc_buf, "{s}/Init.xml", .{sub});
    try io_fs.writeFile(main_path,
        \\<configs>
        \\  <include filename="Init.xml" />
        \\</configs>
    );
    try io_fs.writeFile(inc_path,
        \\<configs>
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">42</set>
        \\  <unknownop xpath="/blocks/block[@name='terrStone']/@maxdamage">7</unknownop>
        \\</configs>
    );
    const base =
        \\<blocks>
        \\<block name="terrStone" maxdamage="500" />
        \\</blocks>
    ;
    const patch = try io_fs.readFileAll(std.testing.allocator, main_path);
    defer std.testing.allocator.free(patch);
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{
        .patch_file_name = "main.xml",
        .patch_file_dir = sub,
    });
    defer std.testing.allocator.free(out);
    // The included op applied, and the unknown op in the same file was skipped
    // rather than aborting the load.
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"42\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"7\"") == null);

    // A missing include drops the file, never the boot.
    try io_fs.writeFile(main_path,
        \\<configs>
        \\  <include filename="nope.xml" />
        \\</configs>
    );
    const patch2 = try io_fs.readFileAll(std.testing.allocator, main_path);
    defer std.testing.allocator.free(patch2);
    const out2 = try applyPatchDoc(std.testing.allocator, base, patch2, "blocks.xml", .{
        .patch_file_name = "main.xml",
        .patch_file_dir = sub,
    });
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(base, out2);
}

test "a patch root that is not <configs> is a container, not an op" {
    // Stock walks the root element's children, so the root tag is irrelevant:
    // 0-SCore ships `<SCore name="XUi_Common/styles.xml">` and zdtd used to
    // fail the whole load on it.
    const base =
        \\<blocks>
        \\<block name="terrStone" maxdamage="500" />
        \\</blocks>
    ;
    const patch =
        \\<SCore name="XUi_Common/styles.xml">
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">9</set>
        \\</SCore>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"9\"") != null);
}

test "a known op with no xpath abandons the file instead of the boot" {
    // Stock raises XmlPatchException here; LoadAndPatchConfig catches it, so
    // the one patch file is dropped and the boot continues.
    const base = "<blocks><block name=\"terrStone\" maxdamage=\"500\" /></blocks>";
    const patch =
        \\<configs>
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">9</set>
        \\  <set>10</set>
        \\  <set xpath="/blocks/block[@name='terrStone']/@maxdamage">11</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    // Ops before the malformed element are applied; the ones after are not.
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"9\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "maxdamage=\"11\"") == null);
}

test "element-existence predicates and last() resolve the real modlet xpaths" {
    // Three xpaths that the installed SphereII/0-SCore corpus uses and the
    // subset used to reject (silently, before the logging change):
    //   /blocks/block[property[@name='Tags' and @value='treasureHunter']]
    //   //item_modifier/effect_group[passive_effect]
    //   /entitygroups/entitygroup[last()]
    const base =
        \\<blocks>
        \\<block name="a"><property name="Tags" value="treasureHunter"/></block>
        \\<block name="b"><property name="Tags" value="other"/></block>
        \\</blocks>
    ;
    const patch =
        \\<configs>
        \\  <set xpath="/blocks/block[property[@name='Tags' and @value='treasureHunter']]/@name">hit</set>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "name=\"hit\"") != null);
    // The non-matching sibling keeps its name.
    try std.testing.expect(std.mem.find(u8, out, "name=\"b\"") != null);

    // `[passive_effect]`: existence of a child element, evaluated on the
    // candidate's body.
    const mod_base =
        \\<item_modifiers>
        \\<item_modifier name="m1"><effect_group><passive_effect name="DamageModifier"/></effect_group></item_modifier>
        \\<item_modifier name="m2"><effect_group/></item_modifier>
        \\</item_modifiers>
    ;
    const mod_patch =
        \\<configs>
        \\  <set xpath="//item_modifier/effect_group[passive_effect]/@name">hit</set>
        \\</configs>
    ;
    // Routed by the patch file name, as production does (`<mod>/Config/
    // item_modifiers.xml`); the xpath root `<item_modifier>` is the singular
    // form the file itself uses.
    const mod_out = try applyPatchDoc(std.testing.allocator, mod_base, mod_patch, "item_modifiers.xml", .{
        .patch_file_name = "item_modifiers.xml",
    });
    defer std.testing.allocator.free(mod_out);
    try std.testing.expect(std.mem.find(u8, mod_out, "name=\"hit\"") != null);

    // `[last()]` selects the final match of the path.
    const grp_base =
        \\<entitygroups>
        \\<entitygroup name="g1"/>
        \\<entitygroup name="g2"/>
        \\</entitygroups>
    ;
    const grp_patch =
        \\<configs>
        \\  <set xpath="/entitygroups/entitygroup[last()]/@name">last</set>
        \\</configs>
    ;
    const grp_out = try applyPatchDoc(std.testing.allocator, grp_base, grp_patch, "entitygroups.xml", .{});
    defer std.testing.allocator.free(grp_out);
    try std.testing.expect(std.mem.find(u8, grp_out, "name=\"last\"") != null);
    try std.testing.expect(std.mem.find(u8, grp_out, "name=\"g1\"") != null);
}

test "conditional evaluates version() comparisons and xpath() existence" {
    // The two expressions the installed 0-SCore / SphereII corpus uses:
    //   cond="mod_version('0-SCore_sphereii') &gt;= version(1,0,81,1048)"
    //   cond="xpath('//entity_class[starts-with(@name, &quot;vehicle&quot;)]/property[@name=&quot;Buffs&quot;]') != null"
    // Both used to be skipped as "not evaluable", dropping their patch blocks.
    const base =
        \\<blocks>
        \\<block name="a" Buffs="yes"/>
        \\</blocks>
    ;
    const with_buffs =
        \\<configs>
        \\  <conditional>
        \\    <if cond="xpath('/blocks/block[@name=&quot;a&quot;]/@Buffs') != null">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\    <else>
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">miss</set>
        \\    </else>
        \\  </conditional>
        \\</configs>
    ;
    const out = try applyPatchDoc(std.testing.allocator, base, with_buffs, "blocks.xml", .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "Buffs=\"hit\"") != null);

    // `!= null` takes the else branch when the node is absent.
    const absent =
        \\<configs>
        \\  <conditional>
        \\    <if cond="xpath('/blocks/block[@name=&quot;zzz&quot;]') != null">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\    <else>
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">miss</set>
        \\    </else>
        \\  </conditional>
        \\</configs>
    ;
    const out2 = try applyPatchDoc(std.testing.allocator, base, absent, "blocks.xml", .{});
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.find(u8, out2, "Buffs=\"miss\"") != null);

    // The corpus form nests a call inside xpath(): the closing paren must be
    // the matching one, not the first `)` (which closes `starts-with(...)`).
    const nested =
        \\<configs>
        \\  <conditional>
        \\    <if cond="xpath('//block[starts-with(@name, &quot;a&quot;)]/property[@name=&quot;Tags&quot;]') != null">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\  </conditional>
        \\</configs>
    ;
    const nested_base =
        \\<blocks>
        \\<block name="a"><property name="Tags" value="x"/></block>
        \\</blocks>
    ;
    const out_nested = try applyPatchDoc(std.testing.allocator, nested_base, nested, "blocks.xml", .{});
    defer std.testing.allocator.free(out_nested);
    try std.testing.expect(std.mem.find(u8, out_nested, "Buffs=\"hit\"") != null);

    // version(): a mod that is not installed compares as 0.0.0.0, so
    // `>= version(1,0,0,0)` is false and the else branch wins. The escaped
    // `&gt;=` must be decoded for the comparison to be seen at all.
    const ver_patch =
        \\<configs>
        \\  <conditional>
        \\    <if cond="mod_version('no_such_mod') &gt;= version(1,0,0,0)">
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">hit</set>
        \\    </if>
        \\    <else>
        \\      <set xpath="/blocks/block[@name='a']/@Buffs">miss</set>
        \\    </else>
        \\  </conditional>
        \\</configs>
    ;
    const out3 = try applyPatchDoc(std.testing.allocator, base, ver_patch, "blocks.xml", .{});
    defer std.testing.allocator.free(out3);
    try std.testing.expect(std.mem.find(u8, out3, "Buffs=\"miss\"") != null);
}
