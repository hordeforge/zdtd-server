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

const XSeg = struct {
    tag: []const u8 = "",
    filter_attr: ?[]const u8 = null,
    filter_val: ?[]const u8 = null,
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
            // [@name='val'] or [@name="val"]
            const filt = raw[br..];
            if (std.mem.find(u8, filt, "@")) |ai| {
                const rest = filt[ai + 1 ..];
                const eq = std.mem.findScalar(u8, rest, '=') orelse return null;
                seg.filter_attr = std.mem.trim(u8, rest[0..eq], " \t");
                var v = std.mem.trim(u8, rest[eq + 1 ..], " \t]");
                if (v.len >= 2 and (v[0] == '\'' or v[0] == '"')) {
                    const q = v[0];
                    v = v[1..];
                    if (std.mem.findScalar(u8, v, q)) |qe| v = v[0..qe];
                }
                seg.filter_val = v;
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
    if (seg.filter_attr) |fa| {
        const fv = seg.filter_val orelse return false;
        const got = xml.attr(hay, open_at, fa) orelse return false;
        return std.mem.eql(u8, got, fv);
    }
    return true;
}

/// Find open index of element matching full path; returns open_at or null.
fn findElement(hay: []const u8, xp: ParsedXPath) ?usize {
    return findElementIn(hay, xp, 0);
}

fn findElementIn(hay: []const u8, xp: ParsedXPath, start_seg: usize) ?usize {
    if (start_seg >= xp.n) return null;
    var search_from: usize = 0;
    while (search_from < hay.len) {
        const lt = std.mem.findPos(u8, hay, search_from, "<") orelse break;
        if (lt + 1 < hay.len and (hay[lt + 1] == '/' or hay[lt + 1] == '!' or hay[lt + 1] == '?')) {
            search_from = lt + 1;
            continue;
        }
        if (elementMatches(hay, lt, xp.segs[start_seg])) {
            if (start_seg + 1 == xp.n) return lt;
            const gt = std.mem.findPos(u8, hay, lt, ">") orelse break;
            if (gt > lt and hay[gt - 1] == '/') {
                search_from = gt + 1;
                continue;
            }
            const tag = xp.segs[start_seg].tag;
            var close_buf: [64]u8 = undefined;
            if (tag.len + 3 > close_buf.len) return null;
            close_buf[0] = '<';
            close_buf[1] = '/';
            @memcpy(close_buf[2..][0..tag.len], tag);
            close_buf[2 + tag.len] = '>';
            const close_tag = close_buf[0 .. 3 + tag.len];
            const close = std.mem.findPos(u8, hay, gt + 1, close_tag) orelse {
                search_from = gt + 1;
                continue;
            };
            const body = hay[gt + 1 .. close];
            if (findElementIn(body, xp, start_seg + 1)) |rel| {
                return (gt + 1) + rel;
            }
            search_from = close + close_tag.len;
            continue;
        }
        search_from = lt + 1;
    }
    return null;
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
};

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
        var eq = i;
        while (eq < w.len and std.ascii.isWhitespace(w[eq])) eq += 1;
        if (eq >= w.len or w[eq] != '=') continue; // tag name or bare key
        eq += 1;
        while (eq < w.len and std.ascii.isWhitespace(w[eq])) eq += 1;
        if (eq >= w.len or (w[eq] != '"' and w[eq] != '\'')) continue;
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
fn csvHas(cur_val: []const u8, want: []const u8) bool {
    const want_t = std.mem.trim(u8, want, " \t");
    var it = std.mem.splitScalar(u8, cur_val, ',');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " \t"), want_t)) return true;
    }
    return false;
}

/// Remove an entry from a comma-separated value; caller frees the result when
/// the value changed.
fn csvRemove(allocator: std.mem.Allocator, cur_val: []const u8, drop: []const u8) !?[]u8 {
    const drop_t = std.mem.trim(u8, drop, " \t");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;
    var first = true;
    var it = std.mem.splitScalar(u8, cur_val, ',');
    while (it.next()) |entry| {
        const e = std.mem.trim(u8, entry, " \t");
        if (std.mem.eql(u8, e, drop_t)) {
            changed = true;
            continue;
        }
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, entry);
    }
    if (!changed) return null;
    return try out.toOwnedSlice(allocator);
}

/// Apply one patch document to base XML. Caller frees result.
/// Errors are load-time fatal (PRD R6): a patch that cannot be applied must
/// stop the server rather than silently desync AssignIds against the client.
pub fn applyPatchDoc(allocator: std.mem.Allocator, base: []const u8, patch_xml: []const u8, target_file: []const u8, ctx: PatchCtx) ![]u8 {
    const clean = try xml.stripComments(allocator, patch_xml);
    defer allocator.free(clean);
    var cur = try allocator.dupe(u8, base);
    errdefer allocator.free(cur);

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
        if (opNameEq(op, "conditional")) {
            // RE gap G5: the condition grammar is not pinned. Applying a
            // conditional patch blindly could change ids vs the client, so
            // fail closed instead of guessing (PRD R6).
            return error.PatchOpConditionalUnsupported;
        }
        const is_include = opNameEq(op, "include");
        const xpath = xml.attr(clean, lt, "xpath");
        if (!is_include and xpath == null) {
            // include may carry the path in `path=`; no other op works
            // without xpath (fail closed rather than silently skip, PRD R6).
            return error.UnknownPatchOp;
        }
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

        // include needs no xpath (path= form); handle it before the common
        // xpath parse.
        if (is_include) {
            const inc_path = xpath orelse (xml.attr(clean, lt, "path") orelse return error.MissingIncludePath);
            const resolved = try rewriteModFolder(allocator, inc_path, ctx.mod_path);
            defer allocator.free(resolved);
            const included = io_fs.readFileAll(allocator, resolved) catch |err| {
                std.debug.print("zdtd: include '{s}' unreadable: {s}\n", .{ resolved, @errorName(err) });
                return err;
            };
            defer allocator.free(included);
            const next = try applyPatchDoc(allocator, cur, included, target_file, .{
                .patch_file_name = basenameOf(resolved),
                .mod_path = ctx.mod_path,
            });
            allocator.free(cur);
            cur = next;
            i = next_i;
            continue;
        }

        const xp = parseXPath(xpath.?) orelse {
            // Malformed xpath: stock logs and skips the element.
            i = next_i;
            continue;
        };

        if (opNameEq(op, "set") or opNameEq(op, "setattribute") or opNameEq(op, "setattributewithxpath") or opNameEq(op, "setbyxpath") or opNameEq(op, "setattributebyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const attr_name = xp.set_attr orelse "value";
            const new_val = if (body.len > 0) body else (xml.attr(clean, lt, "value") orelse {
                i = next_i;
                continue;
            });
            const updated = try setAttribute(allocator, cur, open, attr_name, new_val);
            allocator.free(cur);
            cur = updated;
        } else if (opNameEq(op, "remove") or opNameEq(op, "removebyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const span = elementSpan(cur, open) orelse {
                i = next_i;
                continue;
            };
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, cur[0..span.start]);
            try out.appendSlice(allocator, cur[span.end..]);
            allocator.free(cur);
            cur = try out.toOwnedSlice(allocator);
        } else if (opNameEq(op, "removeattribute") or opNameEq(op, "removeattributebyxpath")) {
            const attr_name = xp.set_attr orelse {
                i = next_i;
                continue;
            };
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const updated = try removeAttributeFrom(allocator, cur, open, attr_name) orelse {
                // Attribute absent: no-op (stock remove of a missing node).
                i = next_i;
                continue;
            };
            allocator.free(cur);
            cur = updated;
        } else if (opNameEq(op, "append") or opNameEq(op, "appendbyxpath") or opNameEq(op, "prepend") or opNameEq(op, "prependbyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const span = elementSpan(cur, open) orelse {
                i = next_i;
                continue;
            };
            const gt2 = std.mem.findPos(u8, cur, open, ">") orelse {
                i = next_i;
                continue;
            };
            if (gt2 > open and cur[gt2 - 1] == '/') {
                i = next_i;
                continue;
            }
            const is_prepend = opNameEq(op, "prepend") or opNameEq(op, "prependbyxpath");
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
            if (insert_at > span.end or insert_at < open) {
                i = next_i;
                continue;
            }
            const updated = try insertWithNewlines(allocator, cur, insert_at, body);
            allocator.free(cur);
            cur = updated;
        } else if (opNameEq(op, "insertafter") or opNameEq(op, "insertafterbyxpath") or opNameEq(op, "insertbefore") or opNameEq(op, "insertbeforebyxpath")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const span = elementSpan(cur, open) orelse {
                i = next_i;
                continue;
            };
            const is_after = opNameEq(op, "insertafter") or opNameEq(op, "insertafterbyxpath");
            const insert_at = if (is_after) span.end else span.start;
            const updated = try insertWithNewlines(allocator, cur, insert_at, body);
            allocator.free(cur);
            cur = updated;
        } else if (opNameEq(op, "csvoperations")) {
            const open = findElement(cur, xp) orelse {
                i = next_i;
                continue;
            };
            const attr_name = xp.set_attr orelse {
                i = next_i;
                continue;
            };
            const csv_op = xml.attr(clean, lt, "op") orelse {
                i = next_i;
                continue;
            };
            const val = if (body.len > 0) body else (xml.attr(clean, lt, "value") orelse {
                i = next_i;
                continue;
            });
            const cur_val = xml.attr(cur, open, attr_name) orelse {
                i = next_i;
                continue;
            };
            var owned_new: ?[]u8 = null;
            defer if (owned_new) |on| allocator.free(on);
            const new_val: []const u8 = if (opNameEq(csv_op, "add")) blk: {
                if (csvHas(cur_val, val)) break :blk cur_val;
                if (cur_val.len == 0) break :blk std.mem.trim(u8, val, " \t");
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, cur_val);
                try out.append(allocator, ',');
                try out.appendSlice(allocator, std.mem.trim(u8, val, " \t"));
                owned_new = try out.toOwnedSlice(allocator);
                break :blk owned_new.?;
            } else if (opNameEq(csv_op, "remove")) blk: {
                if (try csvRemove(allocator, cur_val, val)) |rv| {
                    owned_new = rv;
                    break :blk rv;
                } else {
                    i = next_i;
                    continue;
                }
            } else if (opNameEq(csv_op, "set")) val else {
                i = next_i;
                continue;
            };
            const updated = try setAttribute(allocator, cur, open, attr_name, new_val);
            allocator.free(cur);
            cur = updated;
        } else {
            return error.UnknownPatchOp;
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
        var files: std.ArrayList([]const u8) = .empty;
        defer {
            for (files.items) |p| allocator.free(p);
            files.deinit(allocator);
        }
        try listXmlFilesSorted(allocator, md.config_dir, &files);
        for (files.items) |fp| {
            const patch_raw = try io_fs.readFileAll(allocator, fp);
            defer allocator.free(patch_raw);
            const next = try applyPatchDoc(allocator, cur, patch_raw, target_file, .{
                .patch_file_name = basenameOf(fp),
                .mod_path = md.mod_path,
            });
            allocator.free(cur);
            cur = next;
        }
    }
    return cur;
}

test "parse xpath property value" {
    const p = parseXPath("/blocks/block[@name='generatorbank']/property[@name='MaxFuel']/@value").?;
    try std.testing.expectEqual(@as(usize, 3), p.n);
    try std.testing.expectEqualStrings("blocks", p.segs[0].tag);
    try std.testing.expectEqualStrings("block", p.segs[1].tag);
    try std.testing.expectEqualStrings("generatorbank", p.segs[1].filter_val.?);
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

test "unknown op fails closed" {
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <append xpath="/blocks"><block name="b"/></append>
        \\  <frobnicate xpath="/blocks/block[@name='a']"/>
        \\</configs>
    ;
    try std.testing.expectError(error.UnknownPatchOp, applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{}));
}

test "conditional fails closed until RE pins the grammar (G5)" {
    const base =
        \\<blocks><block name="a"/></blocks>
    ;
    const patch =
        \\<configs file="blocks.xml">
        \\  <conditional xpath="/blocks"><append xpath="/blocks"><block name="b"/></append></conditional>
        \\</configs>
    ;
    try std.testing.expectError(error.PatchOpConditionalUnsupported, applyPatchDoc(std.testing.allocator, base, patch, "blocks.xml", .{}));
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

    const mod_dirs = try mods.install(std.testing.allocator, mods_root);
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
