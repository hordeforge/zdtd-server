//! Stock item_modifiers.xml catalog (RE items.md `ItemModificationsFromXml`
//! ParseModifier IL=63): the tag gates for mod attachment validation. A mod
//! (an ItemClassModifier, `Groups = {"Mods"}`) declares `installable_tags` /
//! `blocked_tags` / `modifier_tags`; it fits an item when its installable tags
//! intersect the item's `Tags` and its blocked tags are disjoint, and the
//! item's ModSlots quality curve caps the count (see items.zig modSlotsFor).
//! The mods' stat effects themselves stay client-side (the wire round-trip is
//! id-only); this catalog only gates what the server accepts.
//!
//! Lookup is by item name (the mod is a full item; the ECS mod ids resolve
//! through items.zig byId → name). Fail closed: an unknown mod entry or empty
//! installable tags reject the attachment.

const std = @import("std");
const xml = @import("xml_util.zig");
const paths = @import("paths.zig");
const io_fs = @import("../util/io_fs.zig");

pub const ModDef = struct {
    /// Mod item name (items.xml id for the mod; must point at static or
    /// arena-lifetime data).
    name: []const u8 = "",
    /// `installable_tags`: the item tags this mod can attach to. A mod fits
    /// only when at least one intersects the item's Tags.
    installable: []const u8 = "",
    /// `blocked_tags`: item tags that forbid this mod (disjoint required).
    blocked: []const u8 = "",
    /// `modifier_tags`: the tags the mod contributes once installed (used by
    /// the pre-install random selection in stock; recorded, not gating the
    /// player attach path yet).
    modifier: []const u8 = "",
};

pub const ModTable = struct {
    defs: []const ModDef = &.{},
    /// Owns the def strings (like items.zig ItemTable.arena_ptr); null for a
    /// static/empty table.
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *ModTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
            self.defs = &.{};
        }
    }

    pub fn byName(self: *const ModTable, name: []const u8) ?ModDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    /// Comma-list tag intersection ("" list = the gate is empty).
    fn tagListIntersects(list: []const u8, tags: []const u8) bool {
        if (list.len == 0 or tags.len == 0) return false;
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |t| {
            const tag = std.mem.trim(u8, t, " \t");
            if (tag.len == 0) continue;
            var it2 = std.mem.splitScalar(u8, tags, ',');
            while (it2.next()) |u| {
                if (std.mem.eql(u8, tag, std.mem.trim(u8, u, " \t"))) return true;
            }
        }
        return false;
    }

    /// RE items.md ItemClassModifier suitability: a mod fits an item whose
    /// Tags intersect its installable_tags and are disjoint from its
    /// blocked_tags. Fail closed: an unknown mod or empty installable gate
    /// never fits.
    pub fn isSuitable(self: *const ModTable, name: []const u8, item_tags: []const u8) bool {
        const m = self.byName(name) orelse return false;
        if (!tagListIntersects(m.installable, item_tags)) return false;
        return !tagListIntersects(m.blocked, item_tags);
    }
};

/// Parse the file at `path` (stock item_modifiers.xml or a fixture). Mod
/// entries are `<item_modifier name="..." installable_tags="..." ...>` with
/// the attrs extractable in any order; comments are stripped by
/// readCleanFile.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !ModTable {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const ap = try allocator.create(std.heap.ArenaAllocator);
    ap.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        ap.deinit();
        allocator.destroy(ap);
    }
    const arena = ap.allocator();

    var defs: std.ArrayList(ModDef) = .empty;
    var i: usize = 0;
    while (i < clean.len) {
        const ii = std.mem.findPos(u8, clean, i, "<item_modifier ") orelse break;
        const name = xml.attr(clean, ii, "name") orelse {
            i = ii + 15;
            continue;
        };
        const installable = xml.attr(clean, ii, "installable_tags") orelse "";
        const modifier = xml.attr(clean, ii, "modifier_tags") orelse "";
        const blocked = xml.attr(clean, ii, "blocked_tags") orelse "";
        try defs.append(arena, .{
            .name = try arena.dupe(u8, name),
            .installable = try arena.dupe(u8, installable),
            .blocked = try arena.dupe(u8, blocked),
            .modifier = try arena.dupe(u8, modifier),
        });
        i = ii + 15;
    }
    const out = try arena.alloc(ModDef, defs.items.len);
    @memcpy(out, defs.items);
    return ModTable{ .defs = out, .arena_ptr = ap };
}

/// Load the stock item_modifiers.xml through the standard config path (with
/// modlet patch support); null when no game-dir/config-dir file exists.
pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?ModTable {
    return paths.tryLoadConfig("item_modifiers.xml", ModTable, loadFromPath, allocator, game_dir, config_dir);
}

test "item_modifiers parses installable/blocked/modifier gates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/item_modifiers.xml", .{dir});
    try io_fs.writeFile(path,
        \\<!-- a commented-out entry is not parsed -->
        \\<!-- <item_modifier name="modGunSoundSuppressorSilencer" installable_tags="gun" modifier_tags="barrelTipAttachment" blocked_tags="noMods,noSilencer" type="attachment"> -->
        \\<item_modifiers>
        \\  <item_modifier name="modMeleeCrafted04" installable_tags="melee,stabbing" modifier_tags="damage" blocked_tags="noMods,blunt" type="modification">
        \\  <item_modifier name="modGunBarrelExtender" installable_tags="barrelAttachments,turretRanged" modifier_tags="barrelAttachment" blocked_tags="noMods,shotgun" type="attachment">
        \\</item_modifiers>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.defs.len);
    const melee = t.byName("modMeleeCrafted04") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("melee,stabbing", melee.installable);
    try std.testing.expectEqualStrings("noMods,blunt", melee.blocked);
    try std.testing.expectEqualStrings("damage", melee.modifier);
    // Suitability: a blade (tags melee,blade) fits, a blunt item is blocked,
    // a gun does not intersect; unknown mods never fit.
    try std.testing.expect(t.isSuitable("modMeleeCrafted04", "T0,melee,blade"));
    try std.testing.expect(!t.isSuitable("modMeleeCrafted04", "T0,blunt,melee"));
    try std.testing.expect(!t.isSuitable("modMeleeCrafted04", "T0,gun"));
    try std.testing.expect(!t.isSuitable("noSuchMod", "T0,melee"));
}

test "item_modifiers loads the stock catalog when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/item_modifiers.xml";
    if (!io_fs.fileExists(path)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    // 111 live entries in the stock file (4 commented out).
    try std.testing.expect(t.defs.len > 100);
    // The stock suppressor is commented out; a live entry parses its gates.
    const ext = t.byName("modGunBarrelExtender") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("barrelAttachments,turretRanged", ext.installable);
    try std.testing.expectEqualStrings("noMods,shotgun", ext.blocked);
    // A pistol (Tags carry gun,barrelAttachments,sideAttachments) fits.
    try std.testing.expect(t.isSuitable("modGunBarrelExtender", "T0,weapon,gun,barrelAttachments"));
    // A melee item (no gun/barrel tags) does not.
    try std.testing.expect(!t.isSuitable("modGunBarrelExtender", "T0,axe,melee"));
}
