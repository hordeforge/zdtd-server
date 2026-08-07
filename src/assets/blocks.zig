//! blocks.xml solid/name table. Wire ids come only from AssignIds (idByName),
//! never sequential XML declaration order.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const assignids = @import("assignids_comptime.zig");

pub const max_blocks: usize = 8192;

pub const BlockDef = struct {
    id: u16 = 0,
    name: []const u8 = "",
    solid: bool = true,
    /// Block Class property (engine class name, e.g. "VendingMachine"). 0
    /// length = not parsed / unknown.
    class: []const u8 = "",
    /// TraderID property (blocks.xml), resolved through the Extends chain.
    trader_id: i32 = 0,
    /// IndexName="TraderOnOff": trader-area gate/loudspeaker blocks that
    /// TraderArea::SetClosed toggles (doors lock, lights flip meta bit 0x2).
    trader_onoff: bool = false,
};

pub const IdByNameFn = *const fn (?*anyopaque, []const u8) ?u16;

pub const BlockTable = struct {
    defs: []const BlockDef = &.{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,
    source: enum { builtin, xml } = .builtin,

    pub fn deinit(self: *BlockTable) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = builtin();
    }

    pub fn builtin() BlockTable {
        return .{ .defs = builtin_defs[0..], .source = .builtin };
    }

    pub fn byId(self: *const BlockTable, id: u16) ?BlockDef {
        for (self.defs) |d| if (d.id == id) return d;
        return null;
    }

    pub fn byName(self: *const BlockTable, name: []const u8) ?BlockDef {
        for (self.defs) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn isSolid(self: *const BlockTable, id: u16) bool {
        if (id == 0) return false;
        if (self.byId(id)) |d| return d.solid;
        return true;
    }

    /// True for blocks whose resolved Class is VendingMachine (own or inherited
    /// through Extends): the TE the client instantiates for these is
    /// TileEntityVendingMachine (TileEntityType.VendingMachine = 7).
    pub fn isVending(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return std.mem.eql(u8, d.class, "VendingMachine");
        return false;
    }

    /// TraderID for a block (TraderData.TraderID drives trader_info stock).
    pub fn traderId(self: *const BlockTable, id: u16) i32 {
        if (self.byId(id)) |d| return d.trader_id;
        return 0;
    }

    /// TraderArea::SetClosed gate set (IndexName="TraderOnOff"): these blocks
    /// toggle when the owning trader opens/closes.
    pub fn isTraderOnOff(self: *const BlockTable, id: u16) bool {
        if (self.byId(id)) |d| return d.trader_onoff;
        return false;
    }
};

// Offline / no-dump slice: dump-validated pins only (assignids_comptime).
pub const builtin_defs = [_]BlockDef{
    .{ .id = assignids.air, .name = "air", .solid = false },
    .{ .id = assignids.terr_stone, .name = "terrStone", .solid = true },
    .{ .id = assignids.terrain_filler, .name = "terrainFiller", .solid = true },
    .{ .id = assignids.terrain_filler_adaptive, .name = "terrainFillerAdaptive", .solid = true },
    .{ .id = assignids.terr_bedrock, .name = "terrBedrock", .solid = true },
    .{ .id = assignids.terr_dirt, .name = "terrDirt", .solid = true },
    .{ .id = assignids.terr_forest_ground, .name = "terrForestGround", .solid = true },
    .{ .id = assignids.terr_sand, .name = "terrSand", .solid = true },
    .{ .id = assignids.terr_topsoil, .name = "terrTopSoil", .solid = true },
    .{ .id = assignids.water, .name = "water", .solid = false },
};

fn isSolidName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "air")) return false;
    if (std.mem.eql(u8, name, "water")) return false;
    if (std.mem.startsWith(u8, name, "water")) return false;
    if (std.mem.startsWith(u8, name, "terrWater")) return false;
    return true;
}

/// Load blocks.xml names; resolve ids only via AssignIds (`id_by_name`).
/// Names missing from the dump are omitted (fail closed).
pub fn loadFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !BlockTable {
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

    var list: std.ArrayList(BlockDef) = .empty;
    defer list.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    // Raw per-block props for Class / TraderID / Extends, keyed by name, so the
    // extends chain can be resolved after the single scan pass.
    const Parsed = struct {
        id: u16,
        name: []const u8,
        class: ?[]const u8 = null,
        trader_id: i32 = -1, // -1 = not declared
        extends: ?[]const u8 = null,
        trader_onoff: bool = false,
    };
    var parsed: std.ArrayList(Parsed) = .empty;
    defer parsed.deinit(allocator);
    var name_idx: std.StringHashMapUnmanaged(usize) = .{};
    defer name_idx.deinit(allocator);

    var i: usize = 0;
    while (i < clean.len and parsed.items.len < max_blocks) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<block ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        if (seen.contains(name)) {
            i = bi + 7;
            continue;
        }
        const id = id_by_name(ctx, name) orelse {
            i = bi + 7;
            continue;
        };
        const kn = try arena.dupe(u8, name);
        try seen.put(allocator, kn, {});
        // Scan this block's body for Class / TraderID / Extends / IndexName.
        var class: ?[]const u8 = null;
        var trader_id: i32 = -1;
        var extends: ?[]const u8 = null;
        var trader_onoff = false;
        const body_end = if (std.mem.indexOfPos(u8, clean, bi, "</block>")) |e| e else clean.len;
        var p = bi + 7;
        while (p < body_end) : (p += 1) {
            const pi = std.mem.indexOfPos(u8, clean, p, "<property ") orelse break;
            if (pi > body_end) break;
            const pname = xml.attr(clean, pi, "name") orelse {
                p = pi + 10;
                continue;
            };
            if (std.mem.eql(u8, pname, "Class")) {
                class = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "TraderID")) {
                if (xml.attr(clean, pi, "value")) |v| trader_id = std.fmt.parseInt(i32, v, 10) catch -1;
            } else if (std.mem.eql(u8, pname, "Extends")) {
                extends = xml.attr(clean, pi, "value");
            } else if (std.mem.eql(u8, pname, "IndexName")) {
                if (xml.attr(clean, pi, "value")) |v| {
                    if (std.mem.eql(u8, v, "TraderOnOff")) trader_onoff = true;
                }
            }
            p = pi + 10;
        }
        const idx = parsed.items.len;
        try name_idx.put(allocator, kn, idx);
        try parsed.append(allocator, .{
            .id = id,
            .name = kn,
            .class = class,
            .trader_id = trader_id,
            .extends = extends,
            .trader_onoff = trader_onoff,
        });
        i = bi + 7;
    }

    if (parsed.items.len == 0) {
        // No dump match: fall back to builtin pins (offline).
        arena_holder.deinit();
        allocator.destroy(arena_holder);
        return BlockTable.builtin();
    }

    // Resolve the Extends chain for Class / TraderID (own props win). Depth-capped
    // so a corrupt cycle cannot spin; a block inheriting a VendingMachine class is
    // itself treated as vending (cntVendingMachineTrader extends cntVendingMachine).
    const max_extends_depth: usize = 8;
    for (parsed.items, 0..) |*pb, idx_cur| {
        var depth: usize = 0;
        var seen_chain: [max_extends_depth]usize = undefined;
        var chain_n: usize = 0;
        var own_class = pb.class;
        var own_trader = pb.trader_id;
        var ext = pb.extends;
        while (ext) |e| : (depth += 1) {
            if (depth >= max_extends_depth) break;
            if (own_class != null and own_trader >= 0) break;
            var dup = false;
            for (seen_chain[0..chain_n]) |s| {
                if (s == idx_cur) dup = true;
            }
            if (dup) break;
            seen_chain[chain_n] = idx_cur;
            chain_n += 1;
            const base = name_idx.get(e) orelse break;
            const base_p = &parsed.items[base];
            if (own_class == null) own_class = base_p.class;
            if (own_trader < 0) own_trader = base_p.trader_id;
            ext = base_p.extends;
        }
        pb.class = own_class;
        pb.trader_id = if (own_trader < 0) 0 else own_trader;
    }

    const defs = try arena.alloc(BlockDef, parsed.items.len);
    for (parsed.items, 0..) |pb, di| {
        defs[di] = .{
            .id = pb.id,
            .name = pb.name,
            .solid = isSolidName(pb.name),
            .class = if (pb.class) |c| try arena.dupe(u8, c) else "",
            .trader_id = pb.trader_id,
            .trader_onoff = pb.trader_onoff,
        };
    }
    return .{ .defs = defs, .arena_ptr = arena_holder, .source = .xml };
}

pub fn tryLoad(
    allocator: std.mem.Allocator,
    game_dir: ?[]const u8,
    config_dir: ?[]const u8,
    id_by_name: IdByNameFn,
    ctx: ?*anyopaque,
) !?BlockTable {
    const paths = @import("paths.zig");
    var path_buf: [2048]u8 = undefined;
    const base = paths.resolveConfigXml(&path_buf, "blocks.xml", game_dir, config_dir) orelse return null;
    if (paths.override_dirs.len == 0) {
        return loadLogged(allocator, base, id_by_name, ctx);
    }
    const merged = try paths.readConfigXml(allocator, "blocks.xml", game_dir, config_dir) orelse return null;
    defer allocator.free(merged);
    io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
    const cp = ".zdtd_cfg_cache/blocks.xml";
    {
        io_fs.writeFile(allocator, cp, merged) catch |err| {
            std.debug.print("zdtd: write config cache {s} failed: {s}; using base path\n", .{ cp, @errorName(err) });
            return loadLogged(allocator, base, id_by_name, ctx);
        };
    }
    return loadLogged(allocator, cp, id_by_name, ctx);
}

fn loadLogged(allocator: std.mem.Allocator, path: []const u8, id_by_name: IdByNameFn, ctx: ?*anyopaque) ?BlockTable {
    return loadFromPath(allocator, path, id_by_name, ctx) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print("zdtd: load blocks.xml failed: {s} ({s})\n", .{ @errorName(err), path }),
        }
        return null;
    };
}

test "builtin block table" {
    const t = BlockTable.builtin();
    try std.testing.expect(t.isSolid(1)); // terrStone
    try std.testing.expect(!t.isSolid(0));
    try std.testing.expectEqualStrings("terrainFiller", t.byId(2).?.name);
    try std.testing.expectEqualStrings("terrDirt", t.byId(5).?.name);
    try std.testing.expect(!t.isSolid(240)); // water
}

test "vending class and TraderID resolve with Extends inheritance" {
    // Fixture mirrors the stock chain: cntVendingMachineTrader extends
    // cntVendingMachine (Class inherited, TraderID overridden), the soda
    // machines extend cntVendingMachine2Broken (TraderID overridden).
    const src =
        \\<blocks>
        \\<block name="cntVendingMachine">
        \\  <property name="Class" value="VendingMachine"/>
        \\  <property name="TraderID" value="3"/>
        \\</block>
        \\<block name="cntVendingMachineTrader">
        \\  <property name="Extends" value="cntVendingMachine"/>
        \\  <property name="TraderID" value="5"/>
        \\</block>
        \\<block name="cntVendingMachine2Broken">
        \\  <property name="Class" value="VendingMachine"/>
        \\  <property name="TraderID" value="10"/>
        \\</block>
        \\<block name="cntVendingMachine2">
        \\  <property name="Extends" value="cntVendingMachine2Broken"/>
        \\  <property name="TraderID" value="4"/>
        \\</block>
        \\<block name="cntWoodCrateWood01">
        \\  <property name="Class" value="Storage"/>
        \\</block>
        \\<block name="doorWoodLargeGate">
        \\  <property name="IndexName" value="TraderOnOff"/>
        \\</block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_vending.xml";
    try io_fs.writeFile(std.testing.allocator, path, src);
    defer io_fs.deleteFile(std.testing.allocator, path);

    var t = try loadFromPath(std.testing.allocator, path, fixtureId, null);
    defer t.deinit();
    try std.testing.expect(t.source == .xml);

    const vm = t.byName("cntVendingMachine").?;
    try std.testing.expect(t.isVending(vm.id));
    try std.testing.expectEqual(@as(i32, 3), t.traderId(vm.id));
    // Inherited class + overridden TraderID through Extends.
    const vmt = t.byName("cntVendingMachineTrader").?;
    try std.testing.expect(t.isVending(vmt.id));
    try std.testing.expectEqual(@as(i32, 5), t.traderId(vmt.id));
    // Soda machine: extends cntVendingMachine2Broken, own TraderID 4.
    const soda = t.byName("cntVendingMachine2").?;
    try std.testing.expect(t.isVending(soda.id));
    try std.testing.expectEqual(@as(i32, 4), t.traderId(soda.id));
    // Non-vending block stays clear.
    const crate = t.byName("cntWoodCrateWood01").?;
    try std.testing.expect(!t.isVending(crate.id));
    try std.testing.expectEqual(@as(i32, 0), t.traderId(crate.id));
    // TraderOnOff gate block (IndexName property).
    const gate = t.byName("doorWoodLargeGate").?;
    try std.testing.expect(t.isTraderOnOff(gate.id));
    try std.testing.expect(!t.isTraderOnOff(crate.id));
}

fn fixtureId(_: ?*anyopaque, name: []const u8) ?u16 {
    // Stable fixture ids (test-only; not the AssignIds table).
    const map = .{
        .{ "cntVendingMachine", 100 },
        .{ "cntVendingMachineTrader", 101 },
        .{ "cntVendingMachine2Broken", 102 },
        .{ "cntVendingMachine2", 103 },
        .{ "cntWoodCrateWood01", 104 },
        .{ "doorWoodLargeGate", 105 },
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}
