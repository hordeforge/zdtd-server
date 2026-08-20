//! C2S inventory and block editing: player inventory snapshots, holding/item
//! drop/bag, tile-entity edits, inventory transactions, block trigger/setblock
//! and explosions.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const invsys = @import("../../ecs/inventory.zig");
const replicate_te = @import("../replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const clock = @import("../../util/clock.zig");
const stock_te = packages.stock_te;
const containers_mod = @import("../../world/containers.zig");
const stabilityAfterSetBlock = game_mod.stabilityAfterSetBlock;
const reverseItemType = game_mod.Game.reverseItemType;
const resolveItemType = game_mod.Game.resolveItemType;
const eatProps = game_mod.Game.eatProps;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackagePlayerInventory")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].inventory) return true;
        var before: [64]struct { id: u16, n: u32 } = undefined;
        var bn: usize = 0;
        var before_total: u32 = 0;
        for (self.sim.inventory[ps].slots) |sl| {
            if (sl.count == 0 or sl.item_id == 0) continue;
            if (!self.items.isEat(sl.item_id)) continue;
            before_total += sl.count;
            var found = false;
            for (before[0..bn]) |*e| {
                if (e.id == sl.item_id) {
                    e.n += sl.count;
                    found = true;
                    break;
                }
            }
            if (!found and bn < before.len) {
                before[bn] = .{ .id = sl.item_id, .n = sl.count };
                bn += 1;
            }
        }
        const baseline_total = if (before_total > 0) before_total else c.last_eatable_units;
        // Apply may partially mutate toolbelt then fail on bag/equip/prefs.
        // Keep stack-loss detect even on error (toolbelt is first on the wire).
        packages.stock_inv.applyPlayerInventoryBody(body, &self.sim.inventory[ps], reverseItemType, self) catch |err| {
            std.debug.print("zdtd: PlayerInventory apply err={s} body={d} peer={d}\n", .{ @errorName(err), body.len, c.slot });
        };
        self.clampInventoryStacks(&self.sim.inventory[ps]);
        var after_total: u32 = 0;
        var first_eat_id: u16 = 0;
        for (self.sim.inventory[ps].slots) |sl| {
            if (sl.count == 0 or sl.item_id == 0) continue;
            if (!self.items.isEat(sl.item_id)) continue;
            after_total += sl.count;
            if (first_eat_id == 0) first_eat_id = sl.item_id;
        }
        // Body-side eatable count by stock type (reverse-independent).
        const body_eat = packages.stock_inv.countEatableInPlayerInventoryBody(
            body,
            reverseItemType,
            self,
            struct {
                fn isEatStock(ctx: ?*anyopaque, stock_type: i32) bool {
                    const g: *Game = @ptrCast(@alignCast(ctx.?));
                    return g.items.isEatStockType(stock_type);
                }
            }.isEatStock,
        );
        if (first_eat_id == 0 and body_eat.first_ecs != 0) first_eat_id = body_eat.first_ecs;

        if (self.sim.mask[ps].health and c.entity_id > 0) {
            var ate_any = false;
            var units_left: u32 = 4;
            // Path A: per-id loss within this package (ECS before → after).
            for (before[0..bn]) |e| {
                if (units_left == 0) break;
                var after_n: u32 = 0;
                for (self.sim.inventory[ps].slots) |sl| {
                    if (sl.item_id == e.id) after_n += sl.count;
                }
                if (after_n >= e.n) continue;
                const lost = @min(e.n - after_n, units_left);
                var u: u32 = 0;
                while (u < lost) : (u += 1) {
                    const props = eatProps(self, e.id);
                    const r = invsys.applyEatProps(&self.sim, ps, props);
                    if (!r.ate) break;
                    ate_any = true;
                    units_left -= 1;
                }
            }
            // Path B: ECS aggregate drop vs baseline (only with known eat id).
            if (!ate_any and baseline_total > after_total and units_left > 0) {
                const lost = @min(baseline_total - after_total, units_left);
                var eid: u16 = first_eat_id;
                if (eid == 0 and bn > 0) eid = before[0].id;
                if (eid == 0 and body_eat.first_ecs != 0) eid = body_eat.first_ecs;
                if (eid != 0 and self.items.isEat(eid)) {
                    var u: u32 = 0;
                    while (u < lost) : (u += 1) {
                        const props = eatProps(self, eid);
                        const r = invsys.applyEatProps(&self.sim, ps, props);
                        if (!r.ate) break;
                        ate_any = true;
                        units_left -= 1;
                    }
                }
            }
            // Path C: body stock-type count dropped vs last_eatable (primary live path).
            // Require a resolved eatable ecs id. Do not invent chili/beef/id=2 props
            // for unknown multi-unit losses (drop/trade false-eat under ADR 0007).
            if (!ate_any and c.last_eatable_units > body_eat.total and units_left > 0) {
                const lost = @min(c.last_eatable_units - body_eat.total, units_left);
                var eid: u16 = body_eat.first_ecs;
                if (eid == 0 and first_eat_id != 0) eid = first_eat_id;
                if (eid == 0 and bn > 0) eid = before[0].id;
                if (eid != 0 and self.items.isEat(eid)) {
                    var u: u32 = 0;
                    while (u < lost) : (u += 1) {
                        const props = eatProps(self, eid);
                        const r = invsys.applyEatProps(&self.sim, ps, props);
                        if (!r.ate) break;
                        ate_any = true;
                        units_left -= 1;
                    }
                } else if (lost > 0) {
                    std.debug.print("zdtd: PI eatable drop skipped (no eat eid) lost={d} last={d} body_eat={d} stock0={d}\n", .{
                        lost, c.last_eatable_units, body_eat.total, body_eat.first_stock,
                    });
                }
            }
            if (ate_any) {
                const h = self.sim.health[ps];
                std.debug.print("zdtd: ItemActionEat stack-loss food={d:.1} before={d} after={d} last={d} body_eat={d} stock0={d}\n", .{
                    h.food, before_total, after_total, c.last_eatable_units, body_eat.total, body_eat.first_stock,
                });
                try self.sendSurvivalStats(peer, c.entity_id, h.hp, h.max_hp, h.food, h.food_max, h.water, h.water_max);
            } else if (body_eat.total != c.last_eatable_units or before_total != after_total) {
                std.debug.print("zdtd: PI eatable before={d} after={d} last={d} body={d} body_eat={d} stock0={d}\n", .{
                    before_total, after_total, c.last_eatable_units, body.len, body_eat.total, body_eat.first_stock,
                });
            }
        }
        // Body-driven baseline so seed→eat works even when reverse leaves ECS empty.
        c.last_eatable_units = body_eat.total;
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageHoldingItem")) {
        const h = packages.stock_inv.readHoldingItem(body) catch return true;
        if (h.entity_id != 0 and h.entity_id != c.entity_id) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (!self.sim.mask[ps].inventory) return true;
        if (h.holding_index < ecs.components.inv_toolbelt) {
            _ = self.sim.inventory[ps].setHolding(h.holding_index);
        }
        // Rebroadcast to other peers (stock server behavior).
        const hb = try packages.buildHoldingBodyResolved(
            &self.body_buf,
            c.entity_id,
            &self.sim.inventory[ps],
            resolveItemType,
            self,
        );
        try self.broadcastExcept("NetPackageHoldingItem", hb, c.slot);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageItemDrop")) {
        const d = packages.stock_inv.readItemDrop(body) catch return true;
        const item_id = reverseItemType(self, d.stack.type_id);
        if (item_id == 0 or d.stack.count == 0) return true;
        // Prefer drop from matching player stack; else spawn at drop pos.
        var dropped: i32 = -1;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        if (self.sim.mask[ps].inventory) {
            var slot_i: u16 = 0;
            while (slot_i < ecs.components.max_inv_slots) : (slot_i += 1) {
                const s = self.sim.inventory[ps].slots[slot_i];
                if (s.item_id == item_id and s.count > 0) {
                    const qty = @min(s.count, d.stack.count);
                    const r = invsys.applyTransaction(&self.sim, c.slot, .drop, slot_i, 0, qty, -1);
                    dropped = r.dropped_entity;
                    break;
                }
            }
        }
        // The server inventory is authoritative. A claimed stack that was
        // not actually present must not materialize a new item entity.
        if (dropped > 0) {
            // Stock ItemDropServer → EntityItem (class "item"), not death bag.
            try self.broadcastItemDropSpawn(dropped, d.stack, c.entity_id, d.client_instance_id);
            // EntitySpawnResponse(success, item): the thrower's client DecItems
            // its own inventory on receipt, committing the drop. Without it the
            // stack stays in the client bag until the next inventory sync.
            if (packages.buildEntitySpawnResponse(self.body_buf[16..48], true, d.stack)) |rb| {
                try self.sendGame(peer, "NetPackageEntitySpawnResponse", rb);
            } else |_| {}
            try self.sendHoldingEcho(peer, c);
            // Rebaseline eatable units so Path C does not treat drop as eat.
            if (self.sim.mask[ps].inventory) {
                var eat_n: u32 = 0;
                for (self.sim.inventory[ps].slots) |sl| {
                    if (sl.count == 0 or sl.item_id == 0) continue;
                    if (self.items.isEat(sl.item_id)) eat_n += sl.count;
                }
                c.last_eatable_units = eat_n;
            }
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageBag")) {
        const entity_id = packages.stock_inv.peekBagEntityId(body) catch return true;
        if (entity_id == c.entity_id or entity_id == 0) {
            const ps = self.sim.playerByPeer(c.slot) orelse return true;
            if (!self.sim.mask[ps].inventory) return true;
            _ = packages.stock_inv.applyBagPackage(body, &self.sim.inventory[ps], reverseItemType, self, true) catch return true;
            self.clampInventoryStacks(&self.sim.inventory[ps]);
        } else if (self.sim.slotOfNetId(entity_id)) |si| {
            // Ownership: never let a peer write another player's inventory.
            if (self.sim.mask[si].player) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
            // Reach: same as Collect/TE. Without this, any peer can rewrite
            // distant loot-bag (or other non-player inv) contents by id.
            const ps = self.sim.playerByPeer(c.slot) orelse return true;
            const pp = self.sim.transform[ps];
            const bp = self.sim.transform[si];
            if (!self.withinEditReach(pp.x, pp.y, pp.z, bp.x, bp.y, bp.z)) {
                self.harness.counters.inc(.bounds_rejects);
                return true;
            }
            if (self.sim.mask[si].inventory) {
                _ = packages.stock_inv.applyBagPackage(body, &self.sim.inventory[si], reverseItemType, self, false) catch return true;
                self.clampInventoryStacks(&self.sim.inventory[si]);
            }
        } else return true;
        try self.sendHoldingEcho(peer, c);
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageDropItemsContainer")) {
        // Death/drop containers are created from server-owned inventory by
        // the death path. Never accept a client-supplied item list.
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTileEntity")) {
        if (self.quarantineDenies(c, .container)) return true;
        // Vending TE (type 7) first: its payload version i32 (3) cleanly
        // discriminates it from the storage size-marker and the
        // workstation version byte, so no other parse can misroute it.
        {
            var v_plat: [packages.platform_user.max_platform_len]u8 = undefined;
            var v_id: [packages.platform_user.max_id_len]u8 = undefined;
            var v_pw: [vending_mod.max_password_hash]u8 = undefined;
            var v_allowed_plat: [vending_mod.max_allowed_users * packages.platform_user.max_platform_len]u8 = undefined;
            var v_allowed_id: [vending_mod.max_allowed_users * packages.platform_user.max_id_len]u8 = undefined;
            if (stock_te.parseVendingTeBody(body, &v_plat, &v_id, &v_pw, &v_allowed_plat, &v_allowed_id) catch |err| blk: {
                self.harness.counters.inc(.c2s_malformed);
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} vend parse err: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
                break :blk null;
            }) |ve| {
                const owner = self.sim.playerByPeer(c.slot) orelse return true;
                const op = self.sim.transform[owner];
                if (!self.withinEditReach(op.x, op.y, op.z, @floatFromInt(ve.world_x), @floatFromInt(ve.world_y), @floatFromInt(ve.world_z))) {
                    self.harness.counters.inc(.bounds_rejects);
                    return true;
                }
                const vm = self.vending.get(.{ .x = ve.world_x, .y = ve.world_y, .z = ve.world_z }) orelse return true;
                // Owner-editable surface (lock / password / allowed users).
                // Only the machine's owner may edit; ownership and the
                // rental term stay server-applied (the rent SM owns them).
                const mine = c.puid_primary.get() orelse c.puid_native.get() orelse return true;
                if (!vm.owner.matches(mine)) return true;
                vm.is_locked = ve.is_locked;
                if (ve.password.len <= vending_mod.max_password_hash) {
                    @memcpy(vm.password_hash[0..ve.password.len], ve.password);
                    vm.password_len = @intCast(ve.password.len);
                }
                vm.allowed_n = @intCast(@min(ve.allowed_n, vending_mod.max_allowed_users));
                var ai: usize = 0;
                while (ai < vm.allowed_n) : (ai += 1) {
                    vm.allowed[ai].set(ve.allowed[ai]) catch {
                        vm.allowed_n = @intCast(ai);
                        break;
                    };
                }
                try replicate_te.sendVendingTe(self, peer, ve.world_x, ve.world_y, ve.world_z);
                return true;
            }
        }
        if (stock_te.parseStorageTeBody(body)) |parsed| {
            // Reach: TE writes must be near the acting player (cross-map chest
            // overwrite + container-store fill guard).
            const owner = self.sim.playerByPeer(c.slot) orelse return true;
            const op = self.sim.transform[owner];
            const tdx = @as(f32, @floatFromInt(parsed.world_x)) - op.x;
            const tdy = @as(f32, @floatFromInt(parsed.world_y)) - op.y;
            const tdz = @as(f32, @floatFromInt(parsed.world_z)) - op.z;
            const te_d2 = tdx * tdx + tdy * tdy + tdz * tdz;
            if (te_d2 > self.max_edit_range * self.max_edit_range) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, c.entity_id, .bounds, .strong, .container, @sqrt(te_d2), self.max_edit_range);
                return true;
            }
            const pos: containers_mod.PosKey = .{ .x = parsed.world_x, .y = parsed.world_y, .z = parsed.world_z };
            const sc: u16 = if (parsed.size_x > 0 and parsed.size_y > 0)
                @intCast(@min(@as(usize, parsed.size_x) * @as(usize, parsed.size_y), containers_mod.max_container_slots))
            else
                @intCast(@min(@max(parsed.item_count, 8), containers_mod.max_container_slots));
            const cont = self.containers.getOrCreate(pos, sc, parsed.block_id) orelse return true;
            stock_te.applyParsedToContainer(&parsed, cont, reverseItemType, self);
            self.clampStackSlots(cont.slots[0..cont.slot_count]);
            // A player looting a container is the server-side trigger for
            // FetchFromContainer quests (stock's quest object observes the
            // container TE); advance fetch phases so they can reach turn-in.
            systems.questOnFetchItem(&self.sim, c.slot, 1);
            // Echo stock TE to nearby clients.
            try replicate_te.broadcastStorageTe(self, cont);
            return true;
        } else |_| {}
        // Workstation TE (type 12 classic): apply arrays + queue into the
        // workstation store (craft tick advances it) and echo to nearby peers.
        if (stock_te.parseWorkstationTeBody(body)) |ws| {
            const wsp = self.sim.playerByPeer(c.slot) orelse return true;
            const wp = self.sim.transform[wsp];
            const wdx = @as(f32, @floatFromInt(ws.world_x)) - wp.x;
            const wdy = @as(f32, @floatFromInt(ws.world_y)) - wp.y;
            const wdz = @as(f32, @floatFromInt(ws.world_z)) - wp.z;
            const ws_d2 = wdx * wdx + wdy * wdy + wdz * wdz;
            if (ws_d2 > self.max_edit_range * self.max_edit_range) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, c.entity_id, .bounds, .strong, .container, @sqrt(ws_d2), self.max_edit_range);
                return true;
            }
            if (self.workstations.getOrCreate(ws.world_x, ws.world_y, ws.world_z)) |st| {
                replicate_te.applyWsGroup(self, st.fuel[0..], ws.fuel[0..ws.fuel_n]);
                replicate_te.applyWsGroup(self, st.input[0..], ws.input[0..ws.input_n]);
                replicate_te.applyWsGroup(self, st.tools[0..], ws.tools[0..ws.tools_n]);
                replicate_te.applyWsGroup(self, st.output[0..], ws.output[0..ws.output_n]);
                self.clampStackSlots(st.fuel[0..]);
                self.clampStackSlots(st.input[0..]);
                self.clampStackSlots(st.tools[0..]);
                self.clampStackSlots(st.output[0..]);
                @memcpy(st.last_input[0..ws.last_input_blob_len], ws.last_input[0..ws.last_input_blob_len]);
                st.last_input_blob_len = ws.last_input_blob_len;
                // Trust boundary (GAP: workstation recipe validation): the
                // queued output type/count come from the client blob verbatim,
                // so a modified client could queue any output at any rate.
                // With stock recipes.xml loaded, only queue items whose output
                // type resolves to a recipe output survive; unresolvable
                // types and non-recipe outputs are dropped. Builtin recipes
                // (offline/test) carry no stock types, so validation is off.
                if (self.recipes.source == .xml) {
                    // Validate in place: the stock client treats the LAST
                    // queue slot as the active crafting entry, so compacting
                    // accepted items to the front would strand them. Rejected
                    // slots are cleared so nothing stale keeps crafting.
                    for (st.queue[0..ws.queue_n], ws.queue[0..ws.queue_n]) |*dst, q| {
                        if (q.output_type == 0 or q.output_count <= 0) {
                            dst.* = .{};
                            continue;
                        }
                        // Stock type → name: prefer the items table (loaded
                        // items.xml), fall back to the runtime AssignIds dump
                        // so a recipes.xml-only config still validates.
                        const iname = self.items.nameByStockType(q.output_type) orelse blk: {
                            if (q.output_type < 0 or q.output_type > std.math.maxInt(u16)) break :blk null;
                            break :blk self.maxdamage.idName(@intCast(q.output_type));
                        } orelse {
                            dst.* = .{};
                            continue;
                        };
                        const rd = self.recipes.byName(iname) orelse {
                            dst.* = .{};
                            continue;
                        };
                        // The recipe must also be craftable on THIS station:
                        // its craft_area has to be in the block's
                        // CraftingAreaRecipes (or the block name when no list
                        // is declared), so a modified client cannot queue a
                        // forge output on a campfire. Material-based recipes
                        // (the material system, 34 stock) have no queue here.
                        if (rd.craft_area.len > 0 and !self.blocks.allowsCraftArea(@intCast(ws.block_id), rd.craft_area)) {
                            dst.* = .{};
                            continue;
                        }
                        if (rd.material_based) {
                            dst.* = .{};
                            continue;
                        }
                        // Authority: per-craft count and duration come from
                        // recipes.xml, not the client blob (a modified client
                        // could otherwise claim any output count or craft in
                        // zero time). Stock HandleRecipeQueue reads the Recipe
                        // object for both; the item restarts on the server time.
                        dst.* = q;
                        dst.output_count = rd.count;
                        dst.one_item_craft_time = rd.craft_time;
                        dst.craft_time_left = rd.craft_time;
                    }
                } else {
                    @memcpy(st.queue[0..ws.queue_n], ws.queue[0..ws.queue_n]);
                }
                @memcpy(st.melt[0..ws.melt_n], ws.melt[0..ws.melt_n]);
                // The client returns the craft-complete entries its
                // CheckForCraftComplete has not consumed: that list is the
                // acknowledgement, so it replaces ours wholesale.
                st.setCraftComplete(ws.craft_complete[0..ws.craft_complete_n]);
                // Array lengths are the client's, never a used prefix: the
                // echo must send them back unchanged or its grids resize.
                st.fuel_len = ws.fuel_n;
                st.input_len = ws.input_n;
                st.tools_len = ws.tools_n;
                st.output_len = ws.output_n;
                st.last_input_len = ws.last_input_n;
                st.queue_len = ws.queue_n;
                st.melt_len = ws.melt_n;
                st.is_burning = ws.is_burning;
                st.burn_time_left = ws.burn_time_left;
                // Fuel-module presence is block-derived (not on the wire):
                // the craft queue waits for burning only on fuel stations.
                st.has_fuel_module = self.blocks.hasFuelModule(@intCast(ws.block_id));
                st.is_player_placed = ws.is_player_placed;
                st.block_id = ws.block_id;
                st.geometry_known = true;
                st.dirty = false;
            }
            try self.broadcastNear(
                "NetPackageTileEntity",
                body,
                @floatFromInt(ws.world_x),
                @floatFromInt(ws.world_z),
                self.interest_range,
            );
            return true;
        } else |_| {}
        // TileEntityPoweredTrigger (TileEntityType.Trigger = 19): delay /
        // duration / reset from the trigger's own UI. Tried last and gated on
        // the outer teBlockId resolving to a registered power block, so this
        // reader can never swallow a storage or workstation payload.
        if (stock_te.parsePoweredTriggerTeBody(body)) |trig| {
            const bid: u16 = if (trig.block_id > 0 and trig.block_id <= 65535)
                @intCast(trig.block_id)
            else
                return true;
            const props = self.power_registry.lookup(bid) orelse return true;
            if (props.trigger_type == null) return true;
            // Stock only ever writes TriggerTypes 0..4 (asm.il:900244).
            if (trig.trigger_type > stock_te.trigger_type_trip_wire) return true;
            const tp = self.sim.playerByPeer(c.slot) orelse return true;
            const tpos = self.sim.transform[tp];
            const gdx = @as(f32, @floatFromInt(trig.world_x)) - tpos.x;
            const gdy = @as(f32, @floatFromInt(trig.world_y)) - tpos.y;
            const gdz = @as(f32, @floatFromInt(trig.world_z)) - tpos.z;
            const g_d2 = gdx * gdx + gdy * gdy + gdz * gdz;
            if (g_d2 > self.max_edit_range * self.max_edit_range) {
                self.harness.counters.inc(.bounds_rejects);
                self.noteEvidence(c, peer.local_id, c.entity_id, .bounds, .strong, .container, @sqrt(g_d2), self.max_edit_range);
                return true;
            }
            // A Switch carries no delay/duration on the wire; its state is the
            // block meta, which arrives on the SetBlock path instead.
            if (trig.trigger_type != stock_te.trigger_type_switch and
                trig.trigger_type != stock_te.trigger_type_timer_relay)
            {
                _ = self.sim.power.setTriggerConfigAt(
                    trig.world_x,
                    trig.world_y,
                    trig.world_z,
                    trig.property1,
                    trig.property2,
                );
                if (trig.reset_trigger) _ = self.sim.power.resetTriggerAt(trig.world_x, trig.world_y, trig.world_z);
            }
            self.sim.power.resolve();
            try replicate_te.broadcastPoweredTriggerTe(self, trig.world_x, trig.world_y, trig.world_z);
            return true;
        } else |_| {}
        // Unparsed TE payload: drop (stock formats only).
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageInventoryTransactionRequest")) {
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const tx = packages.parseInvTxRequest(body) catch return true;
        var r: invsys.Result = .{};
        // Captured before apply: a rejected place must refund what it consumed.
        const place_item_id: u16 = blk: {
            if (tx.op != @intFromEnum(invsys.Op.place) or tx.a >= ecs.components.max_inv_slots) break :blk 0;
            const ps = self.sim.playerByPeer(c.slot) orelse break :blk 0;
            if (!self.sim.mask[ps].inventory) break :blk 0;
            break :blk self.sim.inventory[ps].slots[tx.a].item_id;
        };
        const ledger_before = self.sim.inv_ledger.total;
        if (tx.op == @intFromEnum(invsys.Op.craft)) {
            r = .{ .ok = self.tryCraft(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
        } else {
            const op: invsys.Op = if (tx.op <= @intFromEnum(invsys.Op.equip))
                @enumFromInt(tx.op)
            else
                .list;
            // ItemActionEat: resolve food/water/hp from items.xml via eatProps.
            r = invsys.applyTransactionEx(&self.sim, c.slot, op, tx.a, tx.b, tx.qty, tx.entity_id, eatProps, self);
        }
        if (r.ok and r.place_block != 0) {
            // Land claim is authoritative on every apply path (ADR 0004); the
            // InvTx place route must not be a way around it. Refund the unit the
            // transaction already consumed (mirrors the refuel path).
            if (self.claimCovering(r.place_x, r.place_z)) |claim| {
                if (claim.owner_entity != c.entity_id) {
                    if (place_item_id != 0) _ = invsys.give(&self.sim, c.slot, place_item_id, 1);
                    r.ok = false;
                }
            }
        }
        if (r.ok and r.place_block != 0) {
            try self.world.setBlockWorld(r.place_x, r.place_y, r.place_z, r.place_block);
            // A placed bedroll becomes the player's respawn point (stock
            // bedroll blocks set EntityPlayer.spawnPoint on placement).
            if (self.isBedrollId(@truncate(r.place_block))) {
                c.bed_x = r.place_x;
                c.bed_y = r.place_y;
                c.bed_z = r.place_z;
                c.has_bed = true;
            }
            const sb = try packages.buildSetBlockBody(&self.body_buf, r.place_x, r.place_y, r.place_z, r.place_block);
            try self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(r.place_x), @floatFromInt(r.place_z), self.interest_range);
            // Power nodes from placeable generators (same path as SetBlock).
            if (self.power_registry.lookup(r.place_block)) |pn| {
                if (self.sim.power.addNodeAt(pn.kind, r.place_x, r.place_y, r.place_z, pn.watts)) |nid| {
                    if (self.sim.power.indexOfId(nid)) |ni| pn.applyToNode(&self.sim.power.nodes[ni]);
                }
                self.sim.power.resolve();
            }
        } else if (r.ok and r.refuel_amount > 0) {
            // Gas can / FuelValue item used on a vehicle or at generator coords
            // (InvTx place). Vehicle first: the client targets the body.
            if (!self.tryRefuelVehicle(c, r.place_x, r.place_y, r.place_z, r.refuel_amount)) {
                if (!self.tryRefuelGenerator(c, r.place_x, r.place_y, r.place_z, r.refuel_amount)) {
                    // Refund the consumed fuel unit (inventory already took one).
                    if (r.refuel_item_id != 0) _ = invsys.give(&self.sim, c.slot, r.refuel_item_id, 1);
                    r.ok = false;
                }
            }
        }
        // Refunds via give() also append; count all ledger appends for this C2S.
        const ledger_delta = self.sim.inv_ledger.total -% ledger_before;
        if (ledger_delta != 0) self.harness.counters.add(.inv_ledger_events, ledger_delta);
        var head_buf: [16]u8 = undefined;
        const head = try packages.buildInvTxResponseHead(&head_buf, r.ok, r.dropped_entity);
        // Stock inventory (toolbelt 10 + bag 45 + equip) needs ~0.5–3 KiB.
        var snap: [4096]u8 = undefined;
        const inv_body = try self.buildInventorySnap(c, &snap);
        if (head.len + inv_body.len <= self.body_buf.len) {
            @memcpy(self.body_buf[0..head.len], head);
            @memcpy(self.body_buf[head.len..][0..inv_body.len], inv_body);
            try self.sendGame(peer, "NetPackageInventoryTransactionResponse", self.body_buf[0 .. head.len + inv_body.len]);
        }
        if (r.dropped_entity > 0) {
            try self.broadcastLootSpawn(r.dropped_entity);
        }
        // ItemActionEat.consume → EntityStatChanged food/water/health (stock path).
        if (r.ok and r.ate and c.entity_id > 0) {
            try self.sendSurvivalStats(peer, c.entity_id, r.hp, r.max_hp, r.food, r.food_max, r.water, r.water_max);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageInventoryDataRequest")) {
        // Stock: KeyHashPair (Guid+hash) + managerToken Guid.
        // Serve TE container slots when Guid matches our deterministic pos-key.
        if (packages.parseInvDataRequestStock(body)) |req| {
            if (self.containers.getByGuid(&req.inventory_key)) |cont| {
                // LootRespawnDays: a looted world container re-rolls here
                // when its interval has elapsed (before the slots serve).
                self.maybeRespawnContainer(cont);
                var slots: [containers_mod.max_container_slots]packages.stock_inv.StockSlot =
                    [_]packages.stock_inv.StockSlot{.{}} ** containers_mod.max_container_slots;
                var si: usize = 0;
                const n: usize = cont.slot_count;
                while (si < n) : (si += 1) {
                    const s = cont.slots[si];
                    if (s.count > 0 and s.item_id != 0) {
                        slots[si] = .{
                            .type_id = self.items.stockTypeFor(s.item_id),
                            .count = s.count,
                            .quality = s.quality,
                            .meta = s.meta,
                        };
                    }
                }
                const resp = try packages.buildInvDataResponseItems(
                    &self.body_buf,
                    req.inventory_key,
                    req.manager_token,
                    slots[0..n],
                );
                try self.sendGame(peer, "NetPackageInventoryDataResponse", resp);
            } else {
                const resp = try packages.buildInvDataResponseNotFound(
                    &self.body_buf,
                    req.inventory_key,
                    req.manager_token,
                );
                try self.sendGame(peer, "NetPackageInventoryDataResponse", resp);
            }
        } else |_| if (packages.parseInvDataRequest(body)) |eid| {
            if (self.sim.slotOfNetId(eid)) |si| {
                // Loot containers only: another player's slots are not a
                // lootable inventory, and echoing them leaks their bag.
                if (self.sim.mask[si].inventory and !self.sim.mask[si].player) {
                    const body_out = try packages.buildInventoryBodyStockResolved(
                        &self.body_buf,
                        &self.sim.inventory[si],
                        resolveItemType,
                        self,
                    );
                    try self.sendGame(peer, "NetPackageInventoryDataResponse", body_out);
                    _ = invsys.openContainer(&self.sim, c.slot, eid);
                }
            }
        } else |_| {}
        return true;
    }
    return false;
}
