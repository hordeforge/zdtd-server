//! traders.xml: trader_item_groups with nested group refs (cycle-safe expand).

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const max_entries: usize = 128;
pub const max_groups: usize = 256;
pub const max_expand: usize = 64;
pub const max_group_depth: usize = 8;

pub const Entry = struct {
    name: []const u8 = "",
    count: u16 = 1,
};

pub const Group = struct {
    name: []const u8 = "",
    /// Direct item names in this group (not nested group refs).
    items: []const Entry = &.{},
    /// Nested group names.
    child_groups: []const []const u8 = &.{},
};

pub const TraderTable = struct {
    /// Expanded traderAlways stock (direct + resolved groups, deterministic first picks).
    entries: []const Entry = &.{},
    groups: []const Group = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *TraderTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
        }
        self.* = .{};
    }

    pub fn empty() TraderTable {
        return .{};
    }

    pub fn groupByName(self: *const TraderTable, name: []const u8) ?Group {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    /// Expand a named group into out[] (direct items + recursive children).
    /// Depth-limited; visits set prevents cycles. Returns count written.
    pub fn expandGroup(self: *const TraderTable, name: []const u8, out: []Entry) usize {
        var visited: [max_groups]bool = .{false} ** max_groups;
        return expandGroupRec(self, name, out, 0, &visited);
    }

    fn expandGroupRec(self: *const TraderTable, name: []const u8, out: []Entry, depth: usize, visited: *[max_groups]bool) usize {
        if (depth >= max_group_depth or out.len == 0) return 0;
        const g = self.groupByName(name) orelse return 0;
        // Find group index for visit bit
        var gi: usize = 0;
        while (gi < self.groups.len) : (gi += 1) {
            if (std.mem.eql(u8, self.groups[gi].name, name)) break;
        }
        if (gi < max_groups) {
            if (visited[gi]) return 0;
            visited[gi] = true;
        }
        var n: usize = 0;
        for (g.items) |e| {
            if (n >= out.len) break;
            out[n] = e;
            n += 1;
        }
        for (g.child_groups) |cg| {
            if (n >= out.len) break;
            n += expandGroupRec(self, cg, out[n..], depth + 1, visited);
        }
        return n;
    }
};

fn lowCount(v: []const u8) u16 {
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse v.len;
    return std.fmt.parseInt(u16, v[0..comma], 10) catch 1;
}

fn parseGroupBody(arena: std.mem.Allocator, gpa: std.mem.Allocator, body: []const u8) !struct { []Entry, [][]const u8 } {
    var items: std.ArrayList(Entry) = .empty;
    defer items.deinit(gpa);
    var children: std.ArrayList([]const u8) = .empty;
    defer children.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const ii = std.mem.indexOfPos(u8, body, i, "<item ") orelse break;
        i = ii + 6;
        if (xml.attr(body, ii, "group")) |gname| {
            try children.append(gpa, try arena.dupe(u8, gname));
            continue;
        }
        const name = xml.attr(body, ii, "name") orelse continue;
        const count: u16 = if (xml.attr(body, ii, "count")) |cv| lowCount(cv) else 1;
        try items.append(gpa, .{ .name = try arena.dupe(u8, name), .count = count });
    }
    const islice = try arena.alloc(Entry, items.items.len);
    @memcpy(islice, items.items);
    const cslice = try arena.alloc([]const u8, children.items.len);
    @memcpy(cslice, children.items);
    return .{ islice, cslice };
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !TraderTable {
    const raw = try io_fs.readFileAll(allocator, path);
    defer allocator.free(raw);
    const clean = try xml.stripComments(allocator, raw);
    defer allocator.free(clean);

    var arena_holder = try allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and groups.items.len < max_groups) {
        const gi = std.mem.indexOfPos(u8, clean, i, "<trader_item_group ") orelse break;
        const gname = xml.attr(clean, gi, "name") orelse {
            i = gi + 18;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, gi, ">") orelse break;
        const close = std.mem.indexOfPos(u8, clean, gt, "</trader_item_group>") orelse break;
        const body = clean[gt + 1 .. close];
        const parsed = try parseGroupBody(arena, allocator, body);
        try groups.append(allocator, .{
            .name = try arena.dupe(u8, gname),
            .items = parsed[0],
            .child_groups = parsed[1],
        });
        i = close + 20;
    }
    if (groups.items.len == 0) return error.OpenFailed;

    const gsl = try arena.alloc(Group, groups.items.len);
    @memcpy(gsl, groups.items);

    var table: TraderTable = .{ .groups = gsl, .arena_ptr = arena_holder };

    // Expand traderAlways into entries (primary stock list).
    var expand_buf: [max_expand]Entry = undefined;
    const en = table.expandGroup("traderAlways", &expand_buf);
    if (en == 0) {
        // Fallback: first group with direct items
        for (table.groups) |g| {
            if (g.items.len > 0) {
                const n = @min(g.items.len, max_entries);
                const entries = try arena.alloc(Entry, n);
                @memcpy(entries, g.items[0..n]);
                table.entries = entries;
                return table;
            }
        }
        return error.OpenFailed;
    }
    const n = @min(en, max_entries);
    const entries = try arena.alloc(Entry, n);
    @memcpy(entries, expand_buf[0..n]);
    table.entries = entries;
    return table;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) ?TraderTable {
    return paths.tryLoadConfig("traders.xml", TraderTable, loadFromPath, allocator, game_dir, config_dir) catch null;
}

test "trader table parses stock traderAlways when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/traders.xml";
    var t = loadFromPath(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.groups.len >= 5);
    try std.testing.expect(t.entries.len >= 5);
    var found_bandage = false;
    for (t.entries) |e| {
        if (std.mem.eql(u8, e.name, "medicalBandage")) {
            found_bandage = true;
            try std.testing.expect(e.count >= 3);
        }
    }
    try std.testing.expect(found_bandage);
    // Nested expand of a known group with children
    var buf: [64]Entry = undefined;
    const n = t.expandGroup("groupAllAmmo", &buf);
    try std.testing.expect(n > 0);
}
