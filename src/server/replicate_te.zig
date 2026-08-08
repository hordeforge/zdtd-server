//! Tile-entity replication: the S2C wire out for workstations, storage
//! containers, vending machines and powered blocks.
//!
//! These were methods on `Game` in game.zig, which had grown past 13k lines with
//! every concern interleaved. They take `*Game` as the first parameter rather
//! than being methods, because a Zig method has to be declared inside the struct
//! and `usingnamespace` is gone. Call them as `replicate_te.sendStorageTe(g, …)`.
//!
//! Everything here reads sim and world state and writes package bodies; nothing
//! here mutates the sim. Body layout belongs to `wire/stock_*.zig` as always
//! (AGENTS: one stock package shape, one builder).

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const packages = @import("../wire/packages.zig");
const ecs = @import("../ecs/root.zig");
const workstations_mod = @import("../world/workstations.zig");
const vending_mod = @import("../world/vending.zig");
const containers_mod = @import("../world/containers.zig");
const world_store = @import("../world/store.zig");
const assets_traders = @import("../assets/traders.zig");
const io_fs = @import("../util/io_fs.zig");
const game_trader = @import("game/trader.zig");
const rng_util = @import("../util/rng.zig");
const ln_peer = @import("../litenet/peer.zig");
const stock_te = packages.stock_te;

pub fn wsGroupToStock(self: *Game, dst: []packages.stock_inv.StockSlot, src: []const ecs.components.InvSlot) void {
    for (dst, src) |*d, s| {
        d.* = if (s.count > 0 and s.item_id != 0) .{
            .type_id = Game.resolveItemType(@ptrCast(self), s.item_id),
            .count = s.count,
            .quality = s.quality,
            .meta = s.meta,
        } else .{};
    }
}

/// Encode one workstation's authoritative state at its client-declared array
/// lengths. `te_block_id` comes from the client's own write: ProcessPackage
/// drops the package when it disagrees with the block it finds (asm.il ~842882).
pub fn buildWorkstationBody(self: *Game, w: *const workstations_mod.Workstation, buf: []u8) ![]u8 {
    var fuel: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
    var input: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
    var tools: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
    var output: [workstations_mod.slots_per_group]packages.stock_inv.StockSlot = undefined;
    wsGroupToStock(self, fuel[0..w.fuel_len], w.fuel[0..w.fuel_len]);
    wsGroupToStock(self, input[0..w.input_len], w.input[0..w.input_len]);
    wsGroupToStock(self, tools[0..w.tools_len], w.tools[0..w.tools_len]);
    wsGroupToStock(self, output[0..w.output_len], w.output[0..w.output_len]);
    return stock_te.buildWorkstationTeBody(buf, 255, w.x, w.y, w.z, w.block_id, .{
        .fuel = fuel[0..w.fuel_len],
        .input = input[0..w.input_len],
        .tools = tools[0..w.tools_len],
        .output = output[0..w.output_len],
        .last_input_count = w.last_input_len,
        .last_input = w.last_input[0..w.last_input_blob_len],
        .queue = w.queue[0..w.queue_len],
        .craft_complete = w.craft_complete[0..w.craft_complete_n],
        .melt = w.melt[0..w.melt_len],
        .is_burning = w.is_burning,
        .burn_time_left = w.burn_time_left,
        .is_player_placed = w.is_player_placed,
    });
}

pub fn broadcastDirtyWorkstations(self: *Game) !void {
    for (self.workstations.items[0..], self.workstations.used[0..]) |*w, u| {
        if (!u or !w.dirty) continue;
        // Nothing is sent before a client write has told us the real array
        // lengths: a guessed count resizes the client's grids.
        if (!w.geometry_known) {
            w.dirty = false;
            continue;
        }
        // Keep dirty until encode+broadcast succeed so a failed send retries next tick.
        const body = buildWorkstationBody(self, w, self.body_buf[8192..16384]) catch |err| {
            self.harness.counters.inc(.encode_errors);
            std.debug.print(
                "zdtd: workstation TE encode failed at ({d},{d},{d}): {s}\n",
                .{ w.x, w.y, w.z, @errorName(err) },
            );
            continue;
        };
        self.broadcastNear(
            "NetPackageTileEntity",
            body,
            @floatFromInt(w.x),
            @floatFromInt(w.z),
            self.interest_range,
        ) catch |err| {
            self.harness.counters.inc(.net_send_errors);
            std.debug.print(
                "zdtd: workstation TE broadcast failed at ({d},{d},{d}): {s}\n",
                .{ w.x, w.y, w.z, @errorName(err) },
            );
            continue;
        };
        w.dirty = false;
    }
}

/// Push a workstation's authoritative state to one peer (lock/open path).
pub fn sendWorkstationTe(self: *Game, peer: *ln_peer.Peer, x: i32, y: i32, z: i32) !void {
    const w = self.workstations.get(x, y, z) orelse return;
    if (!w.geometry_known) return;
    const body = try buildWorkstationBody(self, w, self.body_buf[8192..16384]);
    try self.sendGame(peer, "NetPackageTileEntity", body);
}

pub fn applyWsGroup(self: *Game, dst: []ecs.components.InvSlot, src: []const packages.stock_inv.StockSlot) void {
    for (dst, 0..) |*d, i| {
        if (i < src.len and src[i].count > 0 and src[i].type_id != 0) {
            d.* = .{
                .item_id = Game.reverseItemType(self, src[i].type_id),
                .count = src[i].count,
                .quality = @min(src[i].quality, 255),
                .meta = src[i].meta,
            };
        } else {
            d.* = .{};
        }
    }
}

/// Runtime AssignIds id for seed chest. Preference order: AssignIds dump
/// (id_by_name), then optional world-dir override file, then V3.1.4 pin.
pub fn seedChestBlockId(self: *Game) u16 {
    const captured: u16 = self.maxdamage.idByName("cntWoodenChestClosed") orelse
        @intCast(packages.stock_deco.cnt_wooden_chest_closed);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/seed_chest_block_id", .{self.world.world_dir}) catch return captured;
    var buf: [32]u8 = undefined;
    // Optional override file: missing is fine; other I/O must not look like
    // "no override" when the operator left a broken/unreadable file.
    const slice = io_fs.readFileInto(self.allocator, path, &buf) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print(
                "zdtd: seed_chest_block_id read failed: {s}; using AssignIds/default\n",
                .{@errorName(err)},
            );
        }
        return captured;
    };
    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    const v = std.fmt.parseInt(u16, trimmed, 10) catch {
        std.debug.print("zdtd: seed_chest_block_id not a u16; using AssignIds/default\n", .{});
        return captured;
    };
    return if (v >= 20) v else captured;
}

pub fn broadcastStorageTe(self: *Game, cont: *const containers_mod.Container) !void {
    // Encode failure must surface: callers use try after mutating container
    // state, and a silent return would leave remotes on a stale TE.
    const body = try stock_te.buildStorageTeBody(
        &self.body_buf,
        255,
        cont.pos.x,
        cont.pos.y,
        cont.pos.z,
        cont.block_id,
        cont,
        Game.resolveItemType,
        self,
    );
    try self.broadcast("NetPackageTileEntity", body);
}

/// zdtd's Block::ActivateBlock (asm.il:127088 / 137044): rewrite meta bit 0x1
/// (isPowered) and bit 0x2 (isOn) into the stored BlockValue and SetBlockRPC it,
/// so lights, traps and switches visibly react to the grid. Strictly edge
/// triggered: a node that did not flip costs one comparison and no packet.
pub fn broadcastPowerVisuals(self: *Game) void {
    var i: usize = 0;
    while (i < self.sim.power.node_n) : (i += 1) {
        const n = &self.sim.power.nodes[i];
        const on = ecs.electric.nodeIsOn(n.*);
        if (n.net_synced and n.net_on == on and n.net_powered == n.powered) continue;
        n.net_synced = true;
        n.net_on = on;
        n.net_powered = n.powered;
        const block_id = self.world.blockWorld(n.x, n.y, n.z) catch continue;
        if (block_id == 0) continue;
        const stored = self.blockRawAt(n.x, n.y, n.z);
        const base: u32 = if ((stored & 0xffff) == block_id) stored else @as(u32, block_id);
        var meta = packages.blockMeta(base) &
            ~(packages.block_meta_on | packages.block_meta_powered);
        if (on) meta |= packages.block_meta_on;
        if (n.powered) meta |= packages.block_meta_powered;
        const raw = packages.withBlockMeta(base, meta);
        self.setBlockRaw(n.x, n.y, n.z, raw);
        const dmg = self.getBlockHp(n.x, n.y, n.z);
        const sb = packages.buildSetBlockBodyRaw(self.body_buf[0..96], n.x, n.y, n.z, raw, dmg, -1, -1) catch continue;
        self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(n.x), @floatFromInt(n.z), self.interest_range) catch {
            self.harness.counters.inc(.net_send_errors);
        };
    }
}

/// Echo a powered trigger's authoritative state to nearby clients
/// (StreamModeWrite.ToClient). Silently does nothing when the cell holds no
/// registered trigger: nothing to describe, and the stock client drops a TE
/// update for a position where it holds no TileEntity anyway.
pub fn broadcastPoweredTriggerTe(self: *Game, x: i32, y: i32, z: i32) !void {
    const ni = self.sim.power.indexOfPosition(x, y, z) orelse return;
    const node = self.sim.power.nodes[ni];
    const block_id = self.world.blockWorld(x, y, z) catch return;
    const props = self.power_registry.lookup(block_id) orelse return;
    const tt = props.trigger_type orelse return;
    // Wire list is the child edges zdtd tracks; the parent link is undirected
    // here, so parentPos stays zero rather than inventing a direction.
    var wires: [stock_te.max_te_wires]stock_te.Vec3i = undefined;
    var wire_n: usize = 0;
    var w: usize = 0;
    while (w < self.sim.power.wire_n and wire_n < wires.len) : (w += 1) {
        const wire = self.sim.power.wires[w];
        const other: u16 = if (wire.a == node.id) wire.b else if (wire.b == node.id) wire.a else continue;
        const oi = self.sim.power.indexOfId(other) orelse continue;
        const on = self.sim.power.nodes[oi];
        wires[wire_n] = .{ .x = on.x, .y = on.y, .z = on.z };
        wire_n += 1;
    }
    // Propagate encode failure: a silent return left power switches/traps
    // looking unpowered on remotes after the sim already flipped the node.
    const body = try stock_te.buildPoweredTriggerTeBody(&self.body_buf, 255, x, y, z, block_id, .{
        .power_item_type = ecs.powerblocks.powerItemTypeOf(tt),
        .wires = wires[0..wire_n],
        .is_powered = node.powered,
        .trigger_type = @intFromEnum(tt),
        .property1 = node.delay_idx,
        .property2 = node.duration_idx,
    });
    try self.broadcastNear("NetPackageTileEntity", body, @floatFromInt(x), @floatFromInt(z), self.interest_range);
}

/// Open/sync a world container to one peer (stock TE body).
pub fn sendStorageTe(self: *Game, peer: *ln_peer.Peer, x: i32, y: i32, z: i32) !void {
    const cont = self.containers.get(.{ .x = x, .y = y, .z = z }) orelse return;
    const body = try stock_te.buildStorageTeBody(
        &self.body_buf,
        255,
        cont.pos.x,
        cont.pos.y,
        cont.pos.z,
        cont.block_id,
        cont,
        Game.resolveItemType,
        self,
    );
    try self.sendGame(peer, "NetPackageTileEntity", body);
}

/// Store stock rows as wire TraderStockEntry (ItemStack + markup).
pub fn vendingEntries(self: *Game, v: *const vending_mod.Vending, out: []packages.TraderStockEntry) usize {
    _ = self;
    var n: usize = 0;
    var e: usize = 0;
    while (e < v.stock_n and n < out.len) : (e += 1) {
        const ent = v.stock[e];
        if (ent.type_id == 0) continue;
        out[n] = .{
            .item = .{
                .type_id = ent.type_id,
                .count = @intCast(@min(ent.count, 65535)),
                .quality = ent.quality,
            },
            .markup = ent.markup,
        };
        n += 1;
    }
    return n;
}

/// Seed a vending TE's TraderData from trader_info: TraderData.TraderID is
/// the block's blocks.xml TraderID (stock BlockVendingMachine.OnBlockAdded
/// sets exactly that). Vending is owner-priced, so rows start at markup 0
/// (base EconomicValue); trader_info markups do not apply here.
pub fn fillVendingStore(self: *Game, v: *vending_mod.Vending) void {
    const tt = self.traders;
    var n: usize = 0;
    var refs: []const assets_traders.ItemRef = &.{};
    if (v.trader_id > 0 and v.trader_id <= 65535) {
        if (tt.traderInfo(@intCast(v.trader_id))) |ti| {
            if (ti.refs.len > 0) refs = ti.refs;
        }
    }
    if (refs.len == 0) refs = tt.trader_always_refs; // traderAlways fallback
    if (refs.len == 0) return;
    // Deterministic per machine per day (no entity id on a vending block;
    // the trader_id + day discriminates the stream).
    var rng = rng_util.XorShift32.initFromU64(game_trader.traderRollSeed(self, @intCast(v.trader_id)));
    var rolled: [assets_traders.max_expand]assets_traders.RolledItem = undefined;
    const rn = tt.rollAllRefs(refs, &rng, &rolled);
    if (rn == 0) return;
    // Vending is owner-priced: the renter sets each entry's markup, so the
    // trader_info buy/sell multipliers do not apply here (loot-economy.md
    // 6). Rows start at markup 0 = base EconomicValue, which the client
    // prices from; the purchase delta runs server-side.
    for (rolled[0..rn]) |r| {
        if (n >= vending_mod.max_vending_stock) break;
        const iid = self.ecsIdFromItemName(r.name);
        if (iid == 0) continue;
        const type_id = Game.resolveItemType(@ptrCast(self), iid);
        if (type_id == 0) continue;
        v.stock[n] = .{
            .type_id = type_id,
            .count = @intCast(r.count),
            .quality = r.quality,
            .markup = 0,
        };
        n += 1;
    }
    v.stock_n = @intCast(n);
}

/// Push a vending machine's TE to one peer (LockRequest open path and chunk
/// stream). Missing store = no TE (fail closed).
pub fn sendVendingTe(self: *Game, peer: *ln_peer.Peer, x: i32, y: i32, z: i32) !void {
    const v = self.vending.get(.{ .x = x, .y = y, .z = z }) orelse return;
    var entries_buf: [vending_mod.max_vending_stock]packages.TraderStockEntry = undefined;
    const n = vendingEntries(self, v, &entries_buf);
    const body = try stock_te.buildVendingTeBody(
        self.body_buf[0..4096],
        255,
        v.pos.x,
        v.pos.y,
        v.pos.z,
        .{
            .block_id = v.block_id,
            .is_locked = v.is_locked,
            .owner = vendingOwnerId(self, v),
            .password_hash = v.password_hash[0..v.password_len],
            .rental_end_day = v.rental_end_day,
            .trader_id = v.trader_id,
            .entries = entries_buf[0..n],
            .available_money = v.available_money,
            .rentable = v.rentable,
            .next_auto_buy = v.next_auto_buy,
        },
    );
    try self.sendGame(peer, "NetPackageTileEntity", body);
}

/// Convert a stored UserRef to a platform id slice (empty when absent).
pub fn vendingOwnerId(self: *Game, v: *const vending_mod.Vending) ?packages.platform_user.Id {
    _ = self;
    if (v.owner.platform_len == 0) return null;
    return .{
        .platform = v.owner.platform[0..v.owner.platform_len],
        .id = v.owner.id[0..v.owner.id_len],
    };
}
