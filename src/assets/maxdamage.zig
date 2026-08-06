//! MaxDamage lookup: blocks.xml name→hp + optional AssignIds map from .blocks.nim
//! or a version-matched id\tname dump. Without a full id map, callers fall back to
//! band defaults. Storage names (LootList / CompositeTileEntity) ride the same table.

const std = @import("std");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const blocks_nim = @import("blocks_nim.zig");

/// Bundled V3.1.4 full client AssignIds dump (ZDTD_DUMP_BLOCK_IDS Postfix).
/// Pins verified: treeDeadTree02=24626, cntWoodenChestClosed=18671. No stale saves.
/// Bundled dump basenames; resolved relative to cwd and common parents (playtest
/// orch often starts zdtd with a non-repo cwd).
pub const bundled_assignids_name = "assignids_v314.embed.txt";
pub const bundled_assignids_rel_paths = [_][]const u8{
    "src/assets/assignids_v314.embed.txt",
    "assets/fixtures/assignids_v314.txt",
    "zdtd/src/assets/assignids_v314.embed.txt",
    "zdtd/assets/fixtures/assignids_v314.txt",
    "../zdtd/src/assets/assignids_v314.embed.txt",
    "../zdtd/assets/fixtures/assignids_v314.txt",
    "../src/assets/assignids_v314.embed.txt",
    "../assets/fixtures/assignids_v314.txt",
};

/// blocks.xml `MultiBlockDim` (x,y,z). 1x1x1 is the single-block default.
pub const Dim = struct {
    x: u8 = 1,
    y: u8 = 1,
    z: u8 = 1,

    pub fn isMulti(self: Dim) bool {
        return self.x > 1 or self.y > 1 or self.z > 1;
    }
};

pub const Table = struct {
    /// name → MaxDamage
    by_name: std.StringHashMapUnmanaged(u16) = .{},
    /// AssignIds → MaxDamage (filled when .blocks.nim / dump loaded)
    by_id: std.AutoHashMapUnmanaged(u16, u16) = .{},
    /// AssignIds → true for blocks with LootList or CompositeTileEntity class
    storage_ids: std.AutoHashMapUnmanaged(u16, void) = .{},
    /// name → true (storage from blocks.xml); keys live in arena
    storage_names: std.StringHashMapUnmanaged(void) = .{},
    /// block name → blocks.xml LootList (the loot.xml container the block rolls).
    loot_list_by_name: std.StringHashMapUnmanaged([]const u8) = .{},
    /// AssignIds → LootList (filled from the dump/nim merge; arena values).
    loot_list_by_id: std.AutoHashMapUnmanaged(u16, []const u8) = .{},
    /// block name → AssignIds runtime id (every dump row, not just MaxDamage hits).
    id_by_name: std.StringHashMapUnmanaged(u16) = .{},
    /// block name → power watts (MaxPower for sources, else RequiredPower for
    /// consumers). From blocks.xml DynamicProperties, keyed by name like by_name.
    power_watts_by_name: std.StringHashMapUnmanaged(f32) = .{},
    /// block name → blocks.xml Class (Generator, BatteryBank, …). Arena keys.
    power_class_by_name: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Generator MaxFuel (blocks.xml); missing → no fuel budget entry.
    power_max_fuel_by_name: std.StringHashMapUnmanaged(f32) = .{},
    /// Generator OutputPerFuel (blocks.xml).
    power_output_per_fuel_by_name: std.StringHashMapUnmanaged(f32) = .{},
    /// Battery OutputPerCharge (blocks.xml); used as capacity scale with MaxPower.
    power_output_per_charge_by_name: std.StringHashMapUnmanaged(f32) = .{},
    /// OutputPerStack (solar/battery/gen sub-cell scale).
    power_output_per_stack_by_name: std.StringHashMapUnmanaged(f32) = .{},
    /// materials.xml id → MaxDamage (e.g. Mhay → 50). Used when block has no
    /// MaxDamage property and only a Material ref.
    material_max: std.StringHashMapUnmanaged(u16) = .{},
    /// block name → material id (from blocks.xml Material property).
    block_material: std.StringHashMapUnmanaged([]const u8) = .{},
    /// block name → resolved `IsDistantDecoration` (blocks.xml property, after
    /// the Extends chain). Only `true` entries are stored; absent means false,
    /// so an unparsed or unknown name fails closed out of the deco tables.
    distant_deco: std.StringHashMapUnmanaged(void) = .{},
    /// block name → resolved `MultiBlockDim` (absent means 1x1x1, single block).
    multi_block_dim: std.StringHashMapUnmanaged(Dim) = .{},
    /// block name → resolved `StabilitySupport == false` after the Extends
    /// chain. Stock Block.StabilitySupport defaults true; only explicit false
    /// is stored. A non-support block caps its stability byte at 1.
    non_support: std.StringHashMapUnmanaged(void) = .{},
    /// block name → resolved `StabilityIgnore` (default false): exempt from the
    /// stability plane, never falls and never carries support.
    stability_ignore_names: std.StringHashMapUnmanaged(void) = .{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            // hashmaps use arena for keys; just free arena
            self.by_name = .{};
            self.by_id = .{};
            self.storage_ids = .{};
            self.storage_names = .{};
            self.loot_list_by_name = .{};
            self.loot_list_by_id = .{};
            self.id_by_name = .{};
            self.power_watts_by_name = .{};
            self.power_class_by_name = .{};
            self.power_max_fuel_by_name = .{};
            self.power_output_per_fuel_by_name = .{};
            self.power_output_per_charge_by_name = .{};
            self.power_output_per_stack_by_name = .{};
            self.material_max = .{};
            self.block_material = .{};
            self.distant_deco = .{};
            self.multi_block_dim = .{};
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn empty() Table {
        return .{};
    }

    pub fn maxDamage(self: *const Table, block_id: u16) ?u16 {
        return self.by_id.get(block_id);
    }

    pub fn maxDamageByName(self: *const Table, name: []const u8) ?u16 {
        return self.by_name.get(name);
    }

    pub fn isStorageId(self: *const Table, block_id: u16) bool {
        return self.storage_ids.contains(block_id);
    }

    /// blocks.xml LootList for a block id (the loot.xml container it rolls on
    /// first open). Id lookup first (dump/nim merge), then the name table.
    pub fn lootListFor(self: *const Table, block_id: u16) ?[]const u8 {
        if (self.loot_list_by_id.get(block_id)) |ll| return ll;
        // No reverse id→name map; walk the name table only when small.
        var it = self.loot_list_by_name.iterator();
        while (it.next()) |e| {
            if (self.idByName(e.key_ptr.*)) |id| {
                if (id == block_id) return e.value_ptr.*;
            }
        }
        return null;
    }

    /// Runtime AssignIds id for a stock block name (from dump / .nim), else null.
    pub fn idByName(self: *const Table, name: []const u8) ?u16 {
        return self.id_by_name.get(name);
    }

    /// Rows in the loaded AssignIds map. Zero means no dump: callers that
    /// negotiate ids with the client must refuse to send in that case.
    pub fn idNameCount(self: *const Table) u32 {
        return self.id_by_name.count();
    }

    /// Read-only walk over every AssignIds row, in hash order. Shape matches what
    /// `wire/stock_nameid.zig` consumes; the table must not be mutated while one
    /// of these is live.
    pub const IdNameIter = struct {
        inner: std.StringHashMapUnmanaged(u16).Iterator,

        pub fn next(self: *IdNameIter) ?struct { id: u16, name: []const u8 } {
            const e = self.inner.next() orelse return null;
            return .{ .id = e.value_ptr.*, .name = e.key_ptr.* };
        }
    };

    pub fn idNameIterator(self: *const Table) IdNameIter {
        return .{ .inner = self.id_by_name.iterator() };
    }

    /// blocks.xml `IsDistantDecoration` after Extends resolution. This is the
    /// exact filter `BiomeDefinition::AddDecoBlock` uses to build the biome's
    /// `m_DistantDecoBlocks` list (asm.il 1249700-1249740), which is the only
    /// list `DecoManager::decorateChunkRandom` samples from.
    pub fn isDistantDeco(self: *const Table, name: []const u8) bool {
        return self.distant_deco.contains(name);
    }

    /// blocks.xml `MultiBlockDim` after Extends resolution; 1x1x1 when unset.
    pub fn multiBlockDim(self: *const Table, name: []const u8) Dim {
        return self.multi_block_dim.get(name) orelse .{};
    }

    /// blocks.xml `StabilitySupport` after Extends resolution (default true:
    /// only explicit false is stored, matching the stock Block.StabilitySupport
    /// default). A non-support block caps its stability byte at 1.
    pub fn stabilitySupport(self: *const Table, name: []const u8) bool {
        return !self.non_support.contains(name);
    }

    /// blocks.xml `StabilityIgnore` after Extends resolution (default false):
    /// exempt from the stability plane, never falls and never carries support.
    pub fn stabilityIgnore(self: *const Table, name: []const u8) bool {
        return self.stability_ignore_names.contains(name);
    }

    /// Power watts for a stock block name (MaxPower/RequiredPower), else null.
    pub fn wattsByName(self: *const Table, name: []const u8) ?f32 {
        return self.power_watts_by_name.get(name);
    }

    /// blocks.xml Class property for a block name, else null.
    pub fn classByName(self: *const Table, name: []const u8) ?[]const u8 {
        return self.power_class_by_name.get(name);
    }

    pub fn maxFuelByName(self: *const Table, name: []const u8) ?f32 {
        return self.power_max_fuel_by_name.get(name);
    }

    pub fn outputPerFuelByName(self: *const Table, name: []const u8) ?f32 {
        return self.power_output_per_fuel_by_name.get(name);
    }

    pub fn outputPerChargeByName(self: *const Table, name: []const u8) ?f32 {
        return self.power_output_per_charge_by_name.get(name);
    }

    pub fn outputPerStackByName(self: *const Table, name: []const u8) ?f32 {
        return self.power_output_per_stack_by_name.get(name);
    }

    fn ensureArena(self: *Table, allocator: std.mem.Allocator) !std.mem.Allocator {
        if (self.arena_ptr) |ap| return ap.allocator();
        const ap = try allocator.create(std.heap.ArenaAllocator);
        ap.* = std.heap.ArenaAllocator.init(allocator);
        self.arena_ptr = ap;
        return ap.allocator();
    }

    fn arenaAlloc(self: *Table, allocator: std.mem.Allocator) !std.mem.Allocator {
        return self.ensureArena(allocator);
    }

    fn markStorageIfKnown(self: *Table, arena: std.mem.Allocator, id: u16, name: []const u8) !void {
        if (self.storage_names.contains(name)) {
            try self.storage_ids.put(arena, id, {});
        }
    }

    /// Merge AssignIds→name from a .blocks.nim into by_id using by_name MaxDamage.
    /// Prefab nim local ids may not match runtime AssignIds; still useful when they do.
    pub fn mergeNim(self: *Table, allocator: std.mem.Allocator, nim_path: []const u8) !void {
        var nim = blocks_nim.loadFromPath(allocator, nim_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer nim.deinit();
        const arena = try self.arenaAlloc(allocator);
        for (nim.names, 0..) |name, id| {
            if (name.len == 0) continue;
            // Prefab nim ids are local; only fill MaxDamage when they happen to match.
            // Do not mark storage from nim (wrong AssignIds pollution).
            if (self.by_name.get(name)) |hp| {
                try self.by_id.put(arena, @intCast(id), hp);
            }
        }
    }

    /// Merge AssignIds dump: lines `id\tname` or `id name` (client ZDTD_DUMP_BLOCK_IDS).
    pub fn mergeAssignIdsDump(self: *Table, allocator: std.mem.Allocator, path: []const u8) !void {
        // Missing dump is optional (bundled/fixture probe); other I/O must not be silent.
        const raw = io_fs.readFileAll(allocator, path) catch |err| {
            switch (err) {
                error.FileNotFound => return,
                else => {
                    std.debug.print(
                        "zdtd: assignids dump {s} failed: {s}\n",
                        .{ path, @errorName(err) },
                    );
                    return;
                },
            }
        };
        defer allocator.free(raw);
        const arena = try self.ensureArena(allocator);
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line_raw| {
            var line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            // Accept "id\tname", "id name", "name=id"
            var id: u16 = 0;
            var name: []const u8 = "";
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                name = std.mem.trim(u8, line[0..eq], " \t");
                const id_s = std.mem.trim(u8, line[eq + 1 ..], " \t");
                id = std.fmt.parseInt(u16, id_s, 10) catch continue;
            } else {
                var sp = std.mem.tokenizeAny(u8, line, " \t");
                const id_s = sp.next() orelse continue;
                id = std.fmt.parseInt(u16, id_s, 10) catch continue;
                name = std.mem.trim(u8, sp.rest(), " \t");
            }
            if (name.len == 0) continue;
            if (self.by_name.get(name)) |hp| {
                try self.by_id.put(arena, id, hp);
            } else if (self.block_material.get(name)) |mat| {
                // Material-only MaxDamage (hayBaleSquare → Mhay → 50).
                if (self.material_max.get(mat)) |mhp| {
                    try self.by_id.put(arena, id, mhp);
                    try self.by_name.put(arena, try arena.dupe(u8, name), mhp);
                }
            }
            try self.markStorageIfKnown(arena, id, name);
            const name_dup = try arena.dupe(u8, name);
            try self.id_by_name.put(arena, name_dup, id);
            if (self.loot_list_by_name.get(name)) |ll| {
                try self.loot_list_by_id.put(arena, id, ll);
            }
        }
    }

    /// Load materials.xml MaxDamage table (material id → hp).
    pub fn mergeMaterialsXml(self: *Table, allocator: std.mem.Allocator, path: []const u8) !void {
        const raw = try io_fs.readFileAll(allocator, path);
        defer allocator.free(raw);
        const clean = try xml.stripComments(allocator, raw);
        defer allocator.free(clean);
        const arena = try self.arenaAlloc(allocator);
        var i: usize = 0;
        while (i < clean.len) {
            const mi = std.mem.indexOfPos(u8, clean, i, "<material ") orelse break;
            const mid = xml.attr(clean, mi, "id") orelse {
                i = mi + 10;
                continue;
            };
            const gt = std.mem.indexOfPos(u8, clean, mi, ">") orelse break;
            var body_end = gt + 1;
            if (!(gt > mi and clean[gt - 1] == '/')) {
                const close = std.mem.indexOfPos(u8, clean, gt, "</material>") orelse break;
                body_end = close;
            }
            const body = clean[gt + 1 .. body_end];
            if (xml.propertyValue(body, "MaxDamage")) |md| {
                if (xml.parseU16(md)) |hp| {
                    const kn = try arena.dupe(u8, mid);
                    try self.material_max.put(arena, kn, hp);
                }
            }
            i = body_end;
        }
    }

    /// After materials + blocks Material refs + AssignIds: fill by_id for material-only blocks.
    pub fn resolveMaterialMaxDamage(self: *Table, allocator: std.mem.Allocator) !void {
        const arena = try self.arenaAlloc(allocator);
        var it = self.block_material.iterator();
        while (it.next()) |e| {
            const bname = e.key_ptr.*;
            const mat = e.value_ptr.*;
            if (self.by_name.contains(bname)) continue;
            const mhp = self.material_max.get(mat) orelse continue;
            try self.by_name.put(arena, bname, mhp);
            if (self.id_by_name.get(bname)) |id| {
                try self.by_id.put(arena, id, mhp);
            }
        }
    }

    /// Try bundled fixture paths (cwd-relative + next to executable). Silent no-op if none exist.
    pub fn tryMergeBundledAssignIds(self: *Table, allocator: std.mem.Allocator) void {
        for (bundled_assignids_rel_paths) |p| {
            self.mergeAssignIdsDump(allocator, p) catch continue;
            if (self.id_by_name.count() > 0) return;
        }
        // zig-out/bin/zdtd → ../../src/assets/… via /proc/self/exe
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (io_fs.readLinkAbsoluteSimple("/proc/self/exe", &exe_buf)) |exe| {
            if (std.fs.path.dirname(exe)) |bin_dir| {
                if (std.fs.path.dirname(bin_dir)) |out_dir| {
                    if (std.fs.path.dirname(out_dir)) |root| {
                        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        if (std.fmt.bufPrint(&path_buf, "{s}/src/assets/{s}", .{ root, bundled_assignids_name })) |p| {
                            // Best-effort bundled dump; missing path is fine (logged inside on real I/O errors).
                            self.mergeAssignIdsDump(allocator, p) catch {};
                            if (self.id_by_name.count() > 0) return;
                        } else |_| {}
                        if (std.fmt.bufPrint(&path_buf, "{s}/assets/fixtures/assignids_v314.txt", .{root})) |p| {
                            // Best-effort fixture dump when not under src/assets layout.
                            self.mergeAssignIdsDump(allocator, p) catch {};
                        } else |_| {}
                    }
                }
            }
        } else |_| {}
    }
};

/// blocks.xml `MultiBlockDim="x,y,z"`. Zero or missing components make the block
/// single, not degenerate: a 0-wide multiblock would emit no child cells at all.
fn parseDim(s: []const u8) ?Dim {
    var it = std.mem.splitScalar(u8, s, ',');
    var v: [3]u8 = .{ 1, 1, 1 };
    for (&v) |*slot| {
        const part = std.mem.trim(u8, it.next() orelse return null, " \t");
        const n = std.fmt.parseInt(u8, part, 10) catch return null;
        if (n == 0) return null;
        slot.* = n;
    }
    if (it.next() != null) return null;
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

/// `StringParsers::ParseBool` accepts true/false plus 1/0 (asm.il 91775).
fn parseBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

/// Own (not inherited) deco facts for one `<block>`; null = "ask the parent".
const DecoFacts = struct {
    extends: ?[]const u8 = null,
    distant: ?bool = null,
    dim: ?Dim = null,
    /// Direct blocks.xml LootList (resolved through Extends in a second pass).
    loot_list: ?[]const u8 = null,
    /// StabilitySupport / StabilityIgnore (resolved through Extends; null =
    /// "ask the parent", both default true/false when the chain is exhausted).
    stability_support: ?bool = null,
    stability_ignore: ?bool = null,
};

/// Resolve one block's inherited facts by walking `Extends`. Stock chains are
/// two or three deep (treeOakSml01 → treeMaster); the hop cap only exists so a
/// modded cycle cannot spin forever.
fn resolveDecoFacts(facts: *const std.StringHashMapUnmanaged(DecoFacts), name: []const u8) DecoFacts {
    const max_hops: usize = 16;
    var out: DecoFacts = .{};
    var cur = name;
    var hops: usize = 0;
    while (hops < max_hops) : (hops += 1) {
        const f = facts.get(cur) orelse break;
        if (out.distant == null) out.distant = f.distant;
        if (out.dim == null) out.dim = f.dim;
        if (out.stability_support == null) out.stability_support = f.stability_support;
        if (out.stability_ignore == null) out.stability_ignore = f.stability_ignore;
        if (out.distant != null and out.dim != null and
            out.stability_support != null and out.stability_ignore != null) break;
        cur = f.extends orelse break;
    }
    return out;
}

/// Resolve a block's LootList by walking `Extends` (children can precede their
/// parent in blocks.xml; the hop cap only exists so a modded cycle cannot spin
/// forever).
fn resolveLootList(facts: *const std.StringHashMapUnmanaged(DecoFacts), name: []const u8) ?[]const u8 {
    const max_hops: usize = 16;
    var cur = name;
    var hops: usize = 0;
    while (hops < max_hops) : (hops += 1) {
        const f = facts.get(cur) orelse return null;
        if (f.loot_list) |ll| return ll;
        cur = f.extends orelse return null;
    }
    return null;
}

fn bodyHasStorage(body: []const u8) bool {
    // LootList property or CompositeTileEntity class → storage TE candidate.
    if (xml.propertyValue(body, "LootList") != null) return true;
    if (xml.propertyValue(body, "Class")) |cls| {
        if (std.mem.eql(u8, cls, "CompositeTileEntity")) return true;
    }
    return false;
}

pub fn loadFromBlocksXml(allocator: std.mem.Allocator, path: []const u8) !Table {
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

    var by_name: std.StringHashMapUnmanaged(u16) = .{};
    var storage_names: std.StringHashMapUnmanaged(void) = .{};
    var loot_list_by_name: std.StringHashMapUnmanaged([]const u8) = .{};
    var power_watts_by_name: std.StringHashMapUnmanaged(f32) = .{};
    var power_class_by_name: std.StringHashMapUnmanaged([]const u8) = .{};
    var power_max_fuel_by_name: std.StringHashMapUnmanaged(f32) = .{};
    var power_output_per_fuel_by_name: std.StringHashMapUnmanaged(f32) = .{};
    var power_output_per_charge_by_name: std.StringHashMapUnmanaged(f32) = .{};
    var power_output_per_stack_by_name: std.StringHashMapUnmanaged(f32) = .{};
    var block_material: std.StringHashMapUnmanaged([]const u8) = .{};
    // Own facts first; Extends chains are resolved in a second pass because a
    // child can appear before its parent in the file.
    var own_facts: std.StringHashMapUnmanaged(DecoFacts) = .{};
    var i: usize = 0;
    while (i < clean.len) {
        const bi = std.mem.indexOfPos(u8, clean, i, "<block ") orelse break;
        const name = xml.attr(clean, bi, "name") orelse {
            i = bi + 7;
            continue;
        };
        const gt = std.mem.indexOfPos(u8, clean, bi, ">") orelse break;
        var body_end = gt + 1;
        if (!(gt > bi and clean[gt - 1] == '/')) {
            const close = std.mem.indexOfPos(u8, clean, gt, "</block>") orelse break;
            body_end = close;
        }
        const body = clean[gt + 1 .. body_end];
        const kn = try arena.dupe(u8, name);
        if (xml.propertyValue(body, "MaxDamage")) |md| {
            if (xml.parseU16(md)) |hp| {
                try by_name.put(arena, kn, hp);
            }
        }
        if (xml.propertyValue(body, "Material")) |mat| {
            const mn = try arena.dupe(u8, mat);
            try block_material.put(arena, kn, mn);
        }
        if (bodyHasStorage(body)) {
            try storage_names.put(arena, kn, {});
        }
        var facts: DecoFacts = .{};
        if (xml.propertyValue(body, "Extends")) |ext| {
            facts.extends = try arena.dupe(u8, ext);
        }
        if (xml.propertyValue(body, "LootList")) |ll| {
            facts.loot_list = try arena.dupe(u8, ll);
        }
        const watts: ?f32 = if (xml.propertyValue(body, "MaxPower")) |mp|
            xml.parseF32(mp)
        else if (xml.propertyValue(body, "RequiredPower")) |rp|
            xml.parseF32(rp)
        else
            null;
        if (watts) |w| {
            try power_watts_by_name.put(arena, kn, w);
        }
        if (xml.propertyValue(body, "Class")) |cls| {
            const cn = try arena.dupe(u8, cls);
            try power_class_by_name.put(arena, kn, cn);
        }
        if (xml.propertyValue(body, "MaxFuel")) |mf| {
            if (xml.parseF32(mf)) |v| try power_max_fuel_by_name.put(arena, kn, v);
        }
        if (xml.propertyValue(body, "OutputPerFuel")) |opf| {
            if (xml.parseF32(opf)) |v| try power_output_per_fuel_by_name.put(arena, kn, v);
        }
        if (xml.propertyValue(body, "OutputPerCharge")) |opc| {
            if (xml.parseF32(opc)) |v| try power_output_per_charge_by_name.put(arena, kn, v);
        }
        if (xml.propertyValue(body, "OutputPerStack")) |ops| {
            if (xml.parseF32(ops)) |v| try power_output_per_stack_by_name.put(arena, kn, v);
        }
        if (xml.propertyValue(body, "IsDistantDecoration")) |dd| {
            facts.distant = parseBool(dd);
        }
        if (xml.propertyValue(body, "MultiBlockDim")) |md| {
            facts.dim = parseDim(md);
        }
        if (xml.propertyValue(body, "StabilitySupport")) |ss| {
            facts.stability_support = parseBool(ss);
        }
        if (xml.propertyValue(body, "StabilityIgnore")) |si| {
            facts.stability_ignore = parseBool(si);
        }
        try own_facts.put(arena, kn, facts);
        i = body_end;
    }

    var distant_deco: std.StringHashMapUnmanaged(void) = .{};
    var multi_block_dim: std.StringHashMapUnmanaged(Dim) = .{};
    var non_support: std.StringHashMapUnmanaged(void) = .{};
    var stability_ignore_names: std.StringHashMapUnmanaged(void) = .{};
    var fit = own_facts.iterator();
    while (fit.next()) |e| {
        const r = resolveDecoFacts(&own_facts, e.key_ptr.*);
        if (r.distant orelse false) try distant_deco.put(arena, e.key_ptr.*, {});
        if (r.dim) |d| {
            if (d.isMulti()) try multi_block_dim.put(arena, e.key_ptr.*, d);
        }
        if (r.stability_support orelse true == false) try non_support.put(arena, e.key_ptr.*, {});
        if (r.stability_ignore orelse false) try stability_ignore_names.put(arena, e.key_ptr.*, {});
        if (resolveLootList(&own_facts, e.key_ptr.*)) |ll| {
            try loot_list_by_name.put(arena, e.key_ptr.*, ll);
        }
    }
    own_facts.deinit(arena);

    return .{
        .by_name = by_name,
        .by_id = .{},
        .storage_ids = .{},
        .storage_names = storage_names,
        .loot_list_by_name = loot_list_by_name,
        .power_watts_by_name = power_watts_by_name,
        .power_class_by_name = power_class_by_name,
        .power_max_fuel_by_name = power_max_fuel_by_name,
        .power_output_per_fuel_by_name = power_output_per_fuel_by_name,
        .power_output_per_charge_by_name = power_output_per_charge_by_name,
        .power_output_per_stack_by_name = power_output_per_stack_by_name,
        .block_material = block_material,
        .distant_deco = distant_deco,
        .multi_block_dim = multi_block_dim,
        .non_support = non_support,
        .stability_ignore_names = stability_ignore_names,
        .arena_ptr = arena_holder,
    };
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    const paths = @import("paths.zig");
    // Patched blocks.xml (overrides apply); materials merged after.
    var tbl = (try paths.tryLoadConfig("blocks.xml", Table, loadFromBlocksXml, allocator, game_dir, config_dir)) orelse return null;
    errdefer tbl.deinit();
    var path_buf: [2048]u8 = undefined;
    if (paths.resolveConfigXml(&path_buf, "materials.xml", game_dir, config_dir)) |mp| {
        // Apply materials patches via cache path when overrides set.
        if (paths.override_dirs.len > 0) {
            if (try paths.readConfigXml(allocator, "materials.xml", game_dir, config_dir)) |merged| {
                defer allocator.free(merged);
                io_fs.mkdirPath(allocator, ".zdtd_cfg_cache");
                const cp = ".zdtd_cfg_cache/materials.xml";
                if (io_fs.writeFile(allocator, cp, merged)) |_| {
                    mergeMaterialsLogged(&tbl, allocator, cp);
                } else |err| {
                    std.debug.print("zdtd: materials.xml cache write failed: {s}; using base path\n", .{@errorName(err)});
                    mergeMaterialsLogged(&tbl, allocator, mp);
                }
            } else {
                mergeMaterialsLogged(&tbl, allocator, mp);
            }
        } else {
            mergeMaterialsLogged(&tbl, allocator, mp);
        }
        tbl.resolveMaterialMaxDamage(allocator) catch |err| {
            std.debug.print("zdtd: resolveMaterialMaxDamage failed: {s}\n", .{@errorName(err)});
        };
    }
    return tbl;
}

fn mergeMaterialsLogged(tbl: *Table, allocator: std.mem.Allocator, path: []const u8) void {
    tbl.mergeMaterialsXml(allocator, path) catch |err| {
        std.debug.print("zdtd: merge materials.xml failed: {s} ({s})\n", .{ @errorName(err), path });
    };
}

test "load blocks.xml MaxDamage when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/blocks.xml";
    var t = loadFromBlocksXml(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.by_name.count() > 50);
    try std.testing.expectEqual(@as(u16, 7500), t.maxDamageByName("cntHardenedChestInsecure").?);
    try std.testing.expect(t.storage_names.contains("cntWoodenChestClosed"));
    // Power watts: source MaxPower and consumer RequiredPower from blocks.xml.
    try std.testing.expect(t.wattsByName("generatorbank").? >= 12250);
    try std.testing.expectEqual(@as(f32, 1000), t.maxFuelByName("generatorbank").?);
    try std.testing.expectEqual(@as(f32, 11250), t.outputPerFuelByName("generatorbank").?);
    try std.testing.expectEqual(@as(f32, 90), t.outputPerChargeByName("batterybank").?);
    try std.testing.expectEqual(@as(f32, 15), t.wattsByName("autoTurret").?);
    // Merge nim map
    const nim = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Prefabs/POIs/abandoned_house_01.blocks.nim";
    try t.mergeNim(std.testing.allocator, nim);
    try std.testing.expect(t.by_id.count() > 0);
}

test "blocks.xml LootList resolves per block after the AssignIds merge" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/blocks.xml";
    var t = loadFromBlocksXml(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    t.tryMergeBundledAssignIds(std.testing.allocator);
    // Direct property and Extends-inherited property both resolve to the
    // loot.xml container each block rolls (chest vs gun safe differ).
    try std.testing.expectEqualStrings("woodenChest", t.lootListFor(t.idByName("cntWoodenChestClosed").?).?);
    try std.testing.expectEqualStrings("smallSafes", t.lootListFor(t.idByName("cntDeskSafe").?).?);
    // A non-storage block has no LootList.
    try std.testing.expect(t.lootListFor(t.idByName("treeDeadTree02").?) == null);
}

test "deco facts follow Extends chains and fail closed" {
    const xml_src =
        \\<blocks>
        \\<block name="treeMaster">
        \\  <property name="Shape" value="DistantDecoTree" />
        \\  <property name="IsDistantDecoration" value="true" />
        \\</block>
        \\<block name="treeOakSml01">
        \\  <property name="Extends" value="treeMaster" />
        \\  <property name="MultiBlockDim" value="1,7,1" />
        \\</block>
        \\<block name="treeGrassMaster">
        \\  <property name="IsDecoration" value="true" />
        \\</block>
        \\<block name="treeShortGrass">
        \\  <property name="Extends" value="treeGrassMaster" param1="CustomIcon" />
        \\</block>
        \\<block name="resourceRock01">
        \\  <property name="Extends" value="treeMaster" />
        \\  <property name="IsDistantDecoration" value="false" />
        \\  <property name="MultiBlockDim" value="3,2,3" />
        \\</block>
        \\<block name="loopA"><property name="Extends" value="loopB" /></block>
        \\<block name="loopB"><property name="Extends" value="loopA" /></block>
        \\</blocks>
    ;
    const path = ".zdtd_test_blocks_deco.xml";
    try io_fs.writeFile(std.testing.allocator, path, xml_src);
    defer io_fs.deleteFile(std.testing.allocator, path);

    var t = try loadFromBlocksXml(std.testing.allocator, path);
    defer t.deinit();

    try std.testing.expect(t.isDistantDeco("treeMaster"));
    // Inherited through Extends, which is how every stock tree gets the flag.
    try std.testing.expect(t.isDistantDeco("treeOakSml01"));
    // Grass is the reason the filter exists: prob .85 but not distant deco.
    try std.testing.expect(!t.isDistantDeco("treeShortGrass"));
    // An explicit false on the child beats the parent's true.
    try std.testing.expect(!t.isDistantDeco("resourceRock01"));
    // Unknown names must answer false, never inherit anything.
    try std.testing.expect(!t.isDistantDeco("noSuchBlock"));
    // A modded Extends cycle terminates instead of spinning.
    try std.testing.expect(!t.isDistantDeco("loopA"));

    try std.testing.expectEqual(Dim{ .x = 1, .y = 7, .z = 1 }, t.multiBlockDim("treeOakSml01"));
    try std.testing.expectEqual(Dim{ .x = 3, .y = 2, .z = 3 }, t.multiBlockDim("resourceRock01"));
    try std.testing.expectEqual(Dim{}, t.multiBlockDim("treeMaster"));
    try std.testing.expectEqual(Dim{}, t.multiBlockDim("noSuchBlock"));
}

test "MultiBlockDim parse rejects malformed dims" {
    try std.testing.expectEqual(Dim{ .x = 1, .y = 7, .z = 1 }, parseDim("1,7,1").?);
    try std.testing.expectEqual(Dim{ .x = 3, .y = 2, .z = 3 }, parseDim(" 3 , 2 , 3 ").?);
    try std.testing.expectEqual(@as(?Dim, null), parseDim("1,7"));
    try std.testing.expectEqual(@as(?Dim, null), parseDim("1,7,1,1"));
    try std.testing.expectEqual(@as(?Dim, null), parseDim("0,7,1"));
    try std.testing.expectEqual(@as(?Dim, null), parseDim("1,x,1"));
    try std.testing.expectEqual(@as(?Dim, null), parseDim(""));
    try std.testing.expect(!(Dim{}).isMulti());
    try std.testing.expect((Dim{ .x = 1, .y = 2, .z = 1 }).isMulti());
}

test "stock blocks.xml deco facts when present" {
    const path = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/blocks.xml";
    var t = loadFromBlocksXml(std.testing.allocator, path) catch return error.SkipZigTest;
    defer t.deinit();
    try std.testing.expect(t.isDistantDeco("treeOakSml01"));
    try std.testing.expect(t.isDistantDeco("treeDeadTree02"));
    try std.testing.expect(t.isDistantDeco("treeCactus01"));
    // High-probability biome entries that the filter must drop.
    try std.testing.expect(!t.isDistantDeco("treeShortGrass"));
    try std.testing.expect(!t.isDistantDeco("treeTallGrassDiagonal"));
    try std.testing.expect(!t.isDistantDeco("plantShrub"));
    try std.testing.expectEqual(Dim{ .x = 1, .y = 7, .z = 1 }, t.multiBlockDim("treeOakSml01"));
}

test "AssignIds rows are walkable for id negotiation" {
    var t = Table.empty();
    defer t.deinit();
    try std.testing.expectEqual(@as(u32, 0), t.idNameCount());
    t.tryMergeBundledAssignIds(std.testing.allocator);
    if (t.idNameCount() == 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 24629), t.idByName("treeOakSml01").?);
    var it = t.idNameIterator();
    var n: u32 = 0;
    var saw_oak = false;
    while (it.next()) |e| {
        try std.testing.expect(e.name.len > 0);
        if (std.mem.eql(u8, e.name, "treeOakSml01")) {
            saw_oak = true;
            try std.testing.expectEqual(@as(u16, 24629), e.id);
        }
        n += 1;
    }
    try std.testing.expectEqual(t.idNameCount(), n);
    try std.testing.expect(saw_oak);
}

test "materials.xml MaxDamage fills hayBaleSquare" {
    const game = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";
    var t = (tryLoad(std.testing.allocator, game, null) catch null) orelse return error.SkipZigTest;
    defer t.deinit();
    t.tryMergeBundledAssignIds(std.testing.allocator);
    // hay has no block MaxDamage; material Mhay = 50.
    try std.testing.expectEqual(@as(u16, 50), t.maxDamageByName("hayBaleSquare").?);
    if (t.idByName("hayBaleSquare")) |hid| {
        try std.testing.expectEqual(@as(u16, 50), t.maxDamage(hid).?);
    }
}

test "bundled assignids dump matches stock_deco pins" {
    var t = Table.empty();
    defer t.deinit();
    // Minimal name table so merge keeps hp rows; storage names for isStorageId.
    var arena_holder = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_holder.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    t.arena_ptr = arena_holder;
    const arena = arena_holder.allocator();
    const names = [_]struct { []const u8, u16 }{
        .{ "cntWoodenChestClosed", 300 },
        .{ "cntWoodenChestOpen", 300 },
        .{ "cntHardenedChestInsecure", 7500 },
        .{ "cntDeskSafe", 2000 },
        .{ "cntWoodWritableCrate", 500 },
        .{ "treeDeadTree02", 100 },
        .{ "air", 1 },
        .{ "water", 100 },
    };
    for (names) |pair| {
        const kn = try arena.dupe(u8, pair[0]);
        try t.by_name.put(arena, kn, pair[1]);
        if (std.mem.startsWith(u8, pair[0], "cnt")) {
            try t.storage_names.put(arena, kn, {});
        }
    }
    t.tryMergeBundledAssignIds(std.testing.allocator);
    if (t.id_by_name.count() == 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 300), t.maxDamage(18671).?);
    try std.testing.expectEqual(@as(u16, 7500), t.maxDamage(18650).?);
    try std.testing.expectEqual(@as(u16, 2000), t.maxDamage(18515).?);
    try std.testing.expectEqual(@as(u16, 100), t.maxDamage(24626).?); // treeDeadTree02
    try std.testing.expect(t.isStorageId(18671));
    try std.testing.expect(t.isStorageId(18650));
    try std.testing.expect(!t.isStorageId(24626)); // tree, not storage
    try std.testing.expect(t.by_id.count() >= 8);
}
