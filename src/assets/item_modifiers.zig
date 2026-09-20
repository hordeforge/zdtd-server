//! Stock item_modifiers.xml catalog (RE items.md `ItemModificationsFromXml`
//! ParseModifier IL=63): the tag gates for mod attachment validation. A mod
//! (an ItemClassModifier, `Groups = {"Mods"}`) declares `installable_tags` /
//! `blocked_tags` / `modifier_tags`; it fits an item when its installable tags
//! intersect the item's `Tags` and its blocked tags are disjoint, and the
//! item's ModSlots quality curve caps the count (see items.zig modSlotsFor).
//! The catalog also carries each mod's `<passive_effect>` rows (`passives`), so
//! a mod's *server-side* stats fold where they matter: `EffectManager.GetValue`
//! layer 13 applies a modifier item's effects at the mod's tier, and the
//! stock modifier rows that reach the server (armour resistances, max stats,
//! HealthChangeOT) are flat, so the fold does not need the mod's quality.
//! Attacker-side rows (EntityDamage and friends) stay client-computed: the
//! client's `NetPackageDamageEntity` already carries the finished number.
//!
//! Lookup is by item name (the mod is a full item; the ECS mod ids resolve
//! through items.zig byId → name). Fail closed: an unknown mod entry or empty
//! installable tags reject the attachment.

const std = @import("std");
const buffs = @import("buffs.zig");
const requirements = @import("requirements.zig");
const xml = @import("xml_util.zig");
const paths = @import("paths.zig");
const io_fs = @import("../util/io_fs.zig");
const stock_paths = @import("../util/stock_paths.zig");

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
    /// The modifier's `<passive_effect>` rows with their group gates, through
    /// the shared buffs scanner (layer 13). Arena-owned like the other
    /// strings; empty for a mod with no stat rows.
    passives: []const buffs.Passive = &.{},
    /// `Extends` parent (mods inherit EconomicValue/Stacknumber and the
    /// owner-tiered quality flag from modGeneralMaster).
    extends: []const u8 = "",
    /// items.xml-shape ItemClass fields the mod carries as an item class:
    /// EconomicValue (modGeneralMaster 400, inherited by 106 live rows),
    /// Stacknumber (1) and HasQuality (37 live mods are owner-tiered). The
    /// trader prices a mod from its econ like any item.
    econ: f32 = 0,
    stack: u16 = 1,
    has_quality: bool = false,
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
    /// True when the comma list `list` carries `tag` (case-sensitive, like
    /// FastTags).
    pub fn tagListContains(list: []const u8, tag: []const u8) bool {
        if (list.len == 0 or tag.len == 0) return false;
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |seg| {
            if (std.mem.eql(u8, std.mem.trim(u8, seg, " \t"), tag)) return true;
        }
        return false;
    }

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
    // Layer 13 rows: one shared pool in encounter order, with each mod's range
    // recorded and patched after the walk (the scanner appends into the pool).
    var passives_list: std.ArrayList(buffs.Passive) = .empty;
    var reqs_list: std.ArrayList(requirements.Requirement) = .empty;
    var req_ranges: std.ArrayList(struct { usize, usize }) = .empty;
    var ranges: std.ArrayList(struct { usize, usize }) = .empty;
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
        // Inner body only: the scanner's unknown-tag branch skips a whole
        // element, so passing `<item_modifier ...>` itself would skip its rows.
        const gt = std.mem.findPos(u8, clean, ii, ">") orelse {
            i = ii + 15;
            continue;
        };
        const end = requirements.elementEnd(clean, ii);
        const body = clean[gt + 1 .. end];
        const ext = xml.propertyValue(body, "Extends") orelse "";
        // Single in stock (ItemClass IL_0666 parses it with ParseFloat): a
        // modifier priced above 65535 or with a fraction must not become 0.
        const econ = if (xml.propertyValue(body, "EconomicValue")) |v| xml.parseF32(v) orelse 0 else 0;
        const stack = if (xml.propertyValue(body, "Stacknumber")) |v| xml.parseU16(v) orelse 1 else 1;
        const has_quality = xml.hasTieredEffectGroup(body);
        const p0 = passives_list.items.len;
        // Match items.xml / buffs.xml: fail the load instead of shipping mods
        // whose effect_group rows were silently dropped mid-parse.
        _ = try buffs.scanPassives(
            arena,
            arena,
            clean[gt + 1 .. end],
            &passives_list,
            &reqs_list,
            &req_ranges,
            std.math.maxInt(usize),
        );
        try ranges.append(arena, .{ p0, passives_list.items.len - p0 });
        try defs.append(arena, .{
            .name = try arena.dupe(u8, name),
            .installable = try arena.dupe(u8, installable),
            .blocked = try arena.dupe(u8, blocked),
            .modifier = try arena.dupe(u8, modifier),
            .extends = if (ext.len > 0) try arena.dupe(u8, ext) else "",
            .econ = econ,
            .stack = stack,
            .has_quality = has_quality,
        });
        i = ii + 15;
    }
    // Freeze the pools and patch each row's gate slice, exactly like the buffs
    // loader (the scanner appends ranges parallel to the passive list).
    const pool = try arena.alloc(buffs.Passive, passives_list.items.len);
    @memcpy(pool, passives_list.items);
    if (req_ranges.items.len != pool.len) return error.MalformedModifiers;
    const req_pool = try arena.alloc(requirements.Requirement, reqs_list.items.len);
    @memcpy(req_pool, reqs_list.items);
    for (pool, req_ranges.items) |*p, rg| {
        p.reqs = req_pool[rg[0] .. rg[0] + rg[1]];
    }
    const out = try arena.alloc(ModDef, defs.items.len);
    @memcpy(out, defs.items);
    for (out, ranges.items) |*d, rg| {
        d.passives = pool[rg[0] .. rg[0] + rg[1]];
    }
    // Extends pass: EconomicValue/Stacknumber/quality inherit from the parent
    // (modGeneralMaster carries econ 400). A child can precede its parent in
    // the file, so this is a second walk.
    var idx: std.StringHashMapUnmanaged(usize) = .{};
    for (out, 0..) |d, di| try idx.put(arena, d.name, di);
    for (out) |*d| {
        var cur = d.extends;
        var hops: usize = 0;
        while (hops < 8 and cur.len > 0) : (hops += 1) {
            const pi = idx.get(cur) orelse break;
            const par = out[pi];
            if (d.econ == 0) d.econ = par.econ;
            if (d.stack <= 1) d.stack = par.stack;
            if (!d.has_quality) d.has_quality = par.has_quality;
            cur = par.extends;
        }
    }
    return ModTable{ .defs = out, .arena_ptr = ap };
}

test "modifier rows carry econ, stack and quality from Extends" {
    // A modifier is an ItemClassModifier item class: EconomicValue (400 on
    // modGeneralMaster, inherited by every live row), Stacknumber 1 and the
    // owner-tiered HasQuality flag (35 live tier= rows) belong to it. Without
    // these the trader priced a mod at the 5-duke unknown fallback.
    const game = stock_paths.dedicated_server;
    var t = (tryLoad(std.testing.allocator, game, null) catch null) orelse return error.SkipZigTest;
    defer t.deinit();
    const base = t.byName("modGeneralMaster").?;
    try std.testing.expectEqual(@as(f32, 400), base.econ);
    const barrel = t.byName("modGunBarrelExtender").?;
    try std.testing.expectEqual(@as(f32, 400), barrel.econ);
    try std.testing.expectEqual(@as(u16, 1), barrel.stack);
    try std.testing.expect(!barrel.has_quality);
    const mag = t.byName("modGunMagazineExtender").?;
    try std.testing.expect(mag.has_quality);
    try std.testing.expectEqual(@as(f32, 400), mag.econ);
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
        \\  <item_modifier name="modTestLiner" installable_tags="armor" modifier_tags="armorMod" blocked_tags="" type="modification">
        \\    <effect_group>
        \\      <passive_effect name="ElementalDamageResist" operation="base_add" value="1" tags="heat,electrical"/>
        \\    </effect_group>
        \\  </item_modifier>
        \\</item_modifiers>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.defs.len);
    // Layer 13 rows parse alongside the attachment gates.
    const liner = t.byName("modTestLiner") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), liner.passives.len);
    try std.testing.expectEqualStrings("ElementalDamageResist", liner.passives[0].name);
    try std.testing.expectEqualStrings("heat,electrical", liner.passives[0].tags);
    try std.testing.expectApproxEqAbs(@as(f32, 1), liner.passives[0].value, 0.001);
    try std.testing.expectEqual(@as(usize, 0), liner.passives[0].reqs.len);
    // A mod with no effect rows keeps an empty slice, not a neighbour's rows.
    const no_rows = t.byName("modMeleeCrafted04") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), no_rows.passives.len);
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
    const path = stock_paths.configFile("item_modifiers.xml");
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
