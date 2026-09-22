//! C2S inventory and block editing: player inventory snapshots, holding/item
//! drop/bag, tile-entity edits, inventory transactions, block trigger/setblock
//! and explosions.
//!
//! Extracted from game.zig's handlePackage following the replicate_te
//! precedent. `handle` returns true when the package name belongs to this
//! domain; handlePackage falls through to the remaining arms otherwise.

const std = @import("std");
const inv_reload = @import("inv_reload.zig");
const inv_holding = @import("inv_holding.zig");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const invsys = @import("../../ecs/inventory.zig");
const inv_apply = @import("../inv_apply.zig");
const replicate_te = @import("../game/replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const clock = @import("../../util/clock.zig");
const stock_te = packages.stock_te;
const containers_mod = @import("../../world/containers.zig");
const game_locks = @import("../game/locks.zig");
const stabilityAfterSetBlock = game_mod.stabilityAfterSetBlock;
const reverseItemType = game_mod.Game.reverseItemType;
const resolveItemType = game_mod.Game.resolveItemType;
const eatProps = game_mod.Game.eatProps;
const assets_progression = @import("../../assets/progression.zig");
const game_craft = @import("../game/craft.zig");

/// Sign-text echo range. Stock `NetPackageTileEntity::ProcessPackage` calls
/// `SendPackage(..., pos = te.ToWorldCenterPos(), range = 192, exclude = false)`
/// (NetPackageTileEntity.il.txt IL_00B4), so every spawned client inside 192 m
/// gets the applied TE - the sender included, which is what clears its
/// `lockHandleWaitingFor` and unblocks the sign UI.
const sign_echo_range: f32 = 192;

/// Server-authoritative mod attachment scrub. Lives in inv_reload.zig;
/// this alias keeps the name resolving for existing callers.
pub const scrubIllegalMods = inv_reload.scrubIllegalMods;

/// True when `name` belongs to this domain and was handled.
pub fn handle(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (try inv_reload.handleReload(self, c, peer, name, body)) return true;
    if (try inv_holding.handleHolding(self, c, peer, name, body)) return true;
    if (std.mem.eql(u8, name, "NetPackageDropItemsContainer")) {
        // Death/drop containers are created from server-owned inventory by
        // the death path. Never accept a client-supplied item list.
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageTileEntity")) {
        if (self.quarantineDenies(c, .container)) return true;
        // Rate gate: every TE write mutates a container/workstation/trigger
        // and rebroadcasts to nearby peers (same amplification rationale as
        // SetBlock; the SetBlock order is quarantine first, then token).
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Vending TE (type 7) first: its payload version i32 (3) cleanly
        // discriminates it from the storage size-marker and the
        // workstation version byte, so no other parse can misroute it.
        {
            var v_plat: [packages.platform_user.max_platform_len]u8 = undefined;
            var v_id: [packages.platform_user.max_id_len]u8 = undefined;
            var v_pw: [vending_mod.max_password_hash]u8 = undefined;
            // parseVendingTeBody indexes this scratch by stock_te.max_vending_allowed
            // while the store's own cap sizes it. The two are independent
            // constants in different layers (world must not import wire), so
            // tie them here rather than letting a bump on one side write past
            // the end of the other's buffer.
            comptime std.debug.assert(stock_te.max_vending_allowed == vending_mod.max_allowed_users);
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
                if (self.rejectIfBeyondEditRange(
                    c,
                    peer.local_id,
                    c.entity_id,
                    .container,
                    op.x,
                    op.y,
                    op.z,
                    @floatFromInt(ve.world_x),
                    @floatFromInt(ve.world_y),
                    @floatFromInt(ve.world_z),
                )) return true;
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
        // Sign text (stock TEFeatureSignable). Sign data is not its own
        // package: the client's TileEntity::setModified sends the composite TE
        // body with a fresh handle and the server applies it to its own TE and
        // rebroadcasts it verbatim (ProcessPackage never re-encodes, so the
        // relayed bytes are the applied state). Bodies that also carry
        // TEFeatureStorage (the writable crates) belong to the storage leg
        // below, which owns their item list.
        var sign_text: [stock_te.max_sign_text_bytes]u8 = undefined;
        if (stock_te.parseSignableTeBody(body, &sign_text) catch |err| blk: {
            if (err != error.NotSignableTe) self.harness.counters.inc(.c2s_malformed);
            break :blk null;
        }) |sign| {
            if (!sign.has_storage) {
                const owner = self.sim.playerByPeer(c.slot) orelse return true;
                const op = self.sim.transform[owner];
                if (self.rejectIfBeyondEditRange(
                    c,
                    peer.local_id,
                    c.entity_id,
                    .container,
                    op.x,
                    op.y,
                    op.z,
                    @floatFromInt(sign.world_x),
                    @floatFromInt(sign.world_y),
                    @floatFromInt(sign.world_z),
                )) return true;
                // Stock drops the package when the block at the addressed
                // position no longer matches the claimed type; zdtd also
                // requires the block to be one whose composite carries the
                // signable module, so a forged body cannot write sign text
                // into an unrelated block's TE slot.
                if (sign.block_id <= 0 or sign.block_id > std.math.maxInt(u16)) return true;
                const cur = self.world.blockWorld(sign.world_x, sign.world_y, sign.world_z) catch return true;
                if (@as(i32, cur) != sign.block_id) return true;
                const bdef = self.blocks.byId(@intCast(sign.block_id)) orelse return true;
                if (!bdef.signable) return true;
                // Keep the applied body so the chunk stream can replay it to a
                // client that streams this area later (stock ships the TE with
                // the chunk). A table-full or oversized body only loses the
                // replay, never the echo.
                _ = self.sign_texts.put(.{ .x = sign.world_x, .y = sign.world_y, .z = sign.world_z }, sign.block_id, body);
                self.harness.counters.inc(.c2s_te_sign_echo);
                try self.broadcastNear("NetPackageTileEntity", body, @floatFromInt(sign.world_x), @floatFromInt(sign.world_z), sign_echo_range);
                return true;
            }
        }
        if (stock_te.parseStorageTeBody(body)) |parsed| {
            // Reach: TE writes must be near the acting player (cross-map chest
            // overwrite + container-store fill guard).
            const owner = self.sim.playerByPeer(c.slot) orelse return true;
            const op = self.sim.transform[owner];
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                c.entity_id,
                .container,
                op.x,
                op.y,
                op.z,
                @floatFromInt(parsed.world_x),
                @floatFromInt(parsed.world_y),
                @floatFromInt(parsed.world_z),
            )) return true;
            const pos: containers_mod.PosKey = .{ .x = parsed.world_x, .y = parsed.world_y, .z = parsed.world_z };
            const sc: u16 = if (parsed.size_x > 0 and parsed.size_y > 0)
                @intCast(@min(@as(usize, parsed.size_x) * @as(usize, parsed.size_y), containers_mod.max_container_slots))
            else
                @intCast(@min(@max(parsed.item_count, 8), containers_mod.max_container_slots));
            const cont = self.containers.getOrCreate(pos, sc, parsed.block_id) orelse return true;
            // The client's TE write carries the loot.xml container grid it
            // observes (6x2 wooden chest, 9x6 gun safe, ...): keep it on the
            // container so the storage TE echo (chunk stream and lock grant)
            // renders the real grid instead of the 2xN synthesis. Validate:
            // both axes non-zero and the grid must hold the slot count (the
            // client's TEFeatureStorage.read indexes by the declared size).
            if (parsed.size_x > 0 and parsed.size_y > 0 and
                @as(usize, parsed.size_x) * @as(usize, parsed.size_y) >= cont.slot_count and
                @as(usize, parsed.size_x) * @as(usize, parsed.size_y) <= containers_mod.max_container_slots)
            {
                cont.size_x = @intCast(parsed.size_x);
                cont.size_y = @intCast(parsed.size_y);
            }
            inv_apply.applyParsedToContainer(&parsed, cont, reverseItemType, self);
            self.clampStackSlots(cont.slots[0..cont.slot_count]);
            // A player looting a container is the server-side trigger for
            // FetchFromContainer quests (stock's quest object observes the
            // container TE); advance fetch phases so they can reach turn-in.
            systems.questOnFetchItem(&self.sim, c.slot, 1);
            // Echo stock TE to nearby clients. Stock applies the client's whole
            // composite to its own TE and resends it, so when the received body
            // carries more than the storage module (a writable crate's sign text
            // and lock state) the echo keeps those modules and swaps in the
            // server's clamped storage module; if the module cannot be spliced
            // in place the storage-only body stands, which the client's modern
            // composite reader accepts.
            if (stock_te.spliceStorageEcho(&self.body_buf, body, &parsed, cont, Game.resolveItemType, self)) |echo| {
                try self.broadcastNear(
                    "NetPackageTileEntity",
                    echo,
                    @floatFromInt(cont.pos.x),
                    @floatFromInt(cont.pos.z),
                    self.interest_range,
                );
            } else {
                try replicate_te.broadcastStorageTe(self, cont);
            }
            return true;
        } else |_| {}
        // Workstation TE (type 12 classic): apply arrays + queue into the
        // workstation store (craft tick advances it) and echo to nearby peers.
        if (stock_te.parseWorkstationTeBody(body)) |ws| {
            const wsp = self.sim.playerByPeer(c.slot) orelse return true;
            const wp = self.sim.transform[wsp];
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                c.entity_id,
                .container,
                wp.x,
                wp.y,
                wp.z,
                @floatFromInt(ws.world_x),
                @floatFromInt(ws.world_y),
                @floatFromInt(ws.world_z),
            )) return true;
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
                        // (forge smelter outputs from molten units) queue
                        // like any other recipe once the area matches: the
                        // unit ingredients ride the client's input arrays
                        // the same way normal ingredients do.
                        if (rd.craft_area.len > 0 and !self.blocks.allowsCraftArea(@intCast(ws.block_id), rd.craft_area)) {
                            dst.* = .{};
                            continue;
                        }
                        // Authority: per-craft count and duration come from
                        // recipes.xml, not the client blob (a modified client
                        // could otherwise claim any output count or craft in
                        // zero time). Stock HandleRecipeQueue reads the Recipe
                        // object for both; the item restarts on the server time.
                        if (assets_progression.unlockRequirement(&self.progression_table, rd.name)) |req| {
                            if (self.skillLevelOf(c.slot, req[0]) < req[1]) {
                                dst.* = .{};
                                continue;
                            }
                        }
                        dst.* = q;
                        dst.output_count = rd.count;
                        // Stock `Recipe::Init` (IL=79): an omitted craft_time
                        // resolves through the item table, not the old 1 s
                        // default (and never the client's spoofed time).
                        dst.one_item_craft_time = game_craft.craftTimeFor(self, rd);
                        dst.craft_time_left = dst.one_item_craft_time;
                        dst.craft_exp_gain = @max(rd.craft_exp_gain, 0);
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
                // Fuel-/material-module presence is block-derived (not on the wire):
                // the craft queue waits for burning only on fuel stations;
                // material_input gates HandleMaterialInput (forge melt).
                st.has_fuel_module = self.blocks.hasFuelModule(@intCast(ws.block_id));
                st.has_material_input = self.blocks.hasMaterialInput(@intCast(ws.block_id));
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
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                c.entity_id,
                .container,
                tpos.x,
                tpos.y,
                tpos.z,
                @floatFromInt(trig.world_x),
                @floatFromInt(trig.world_y),
                @floatFromInt(trig.world_z),
            )) return true;
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
            // A motion sensor carries its TargetType bitmask (stock
            // PowerTrigger.TargetType for TriggerType 3). The parser already
            // read it and the handler dropped it, so the echo below reset the
            // player's target selection to 0 the moment they set it.
            if (trig.trigger_type == stock_te.trigger_type_motion) {
                _ = self.sim.power.setTriggerTargetAt(
                    trig.world_x,
                    trig.world_y,
                    trig.world_z,
                    trig.target_type,
                );
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
        // A real stock client sends InventoryTransaction.Write (RE
        // protocol-packages.md 6.13). Try the stock layout first: the native
        // 11-byte parser only checks len >= 11, so a stock body would
        // otherwise be misread as a native request. Native bodies fail the
        // stock parse (the first i32 count misreads the op bytes).
        if (packages.parseStockInvTx(body) catch null) |stx| {
            // Apply the stock ops to the player's inventory (same
            // client-trust model as ADR 0007 PlayerInventory: the C2S
            // PlayerInventory push is already authoritative, so a stock
            // backpack/container transaction is no wider a surface) and ack
            // with the stock minimal response. The Guid registry population
            // path is unpinned RE, so the player's own transactions accept
            // without key validation; bounds + stack caps hold.
            self.harness.counters.inc(.c2s_stock_invtx);
            if (self.sim.playerByPeer(c.slot)) |ps| {
                if (self.sim.mask[ps].inventory) {
                    var ok = true;
                    // Stage into a copy and commit only on success. Stock
                    // applies the whole InventoryTransaction and then checks
                    // ValidateFinalHashes (InventoryManager
                    // TransactionRequestServer IL=46); a failure there force-
                    // unlocks and sends nothing, so a rejected transaction
                    // never leaves half its ops applied. The SetAbsolute /
                    // SetRelative arm used to write straight into the live
                    // inventory, so an op that failed after an earlier one had
                    // landed left those stacks applied, unclamped (the clamp
                    // sits in the success branch) and unreplicated.
                    var staged = self.sim.inventory[ps].slots;
                    for (stx.entries[0..stx.entry_n]) |*en| {
                        for (en.ops[0..en.op_n]) |op| {
                            switch (op.op) {
                                0, 1 => { // SetAbsolute / SetRelative:
                                    // the client's reported stack at the index
                                    // is authoritative
                                    if (op.index < 0 or op.index >= @as(i32, @intCast(ecs.components.max_inv_slots))) {
                                        ok = false;
                                        continue;
                                    }
                                    const slot = packages.stock_inv.toEcs(op.stack, reverseItemType, self);
                                    // T18 hardening: a NON-EMPTY client stack
                                    // that does not resolve to a server
                                    // catalog item is a reject, not a silent
                                    // clear - the ack must tell the client the
                                    // transaction failed (fail-closed, honest
                                    // success bit).
                                    if (op.stack.type_id != 0 and op.stack.count != 0 and slot.item_id == 0) {
                                        ok = false;
                                        self.harness.counters.inc(.c2s_rejects);
                                        continue;
                                    }
                                    staged[@intCast(op.index)] = slot;
                                },
                                2 => { // SetAll: replace the inventory array
                                    if (op.new_n > ecs.components.max_inv_slots) {
                                        ok = false;
                                        continue;
                                    }
                                    var slots: [ecs.components.max_inv_slots]ecs.components.InvSlot = @splat(.{});
                                    var si: u16 = 0;
                                    while (si < op.new_n) : (si += 1) {
                                        const slot = packages.stock_inv.toEcs(op.new_stacks[si], reverseItemType, self);
                                        // Same T18 reject: an unresolvable
                                        // non-empty stack fails the whole tx.
                                        if (op.new_stacks[si].type_id != 0 and op.new_stacks[si].count != 0 and slot.item_id == 0) {
                                            ok = false;
                                            self.harness.counters.inc(.c2s_rejects);
                                            break;
                                        }
                                        slots[si] = slot;
                                    }
                                    if (ok) staged = slots;
                                },
                                else => ok = false,
                            }
                        }
                    }
                    if (ok) {
                        self.sim.inventory[ps].slots = staged;
                        self.clampInventoryStacks(&self.sim.inventory[ps]);
                        // Stock minimal ack: success true + count 0 (full
                        // stacks ride only for non-primary players).
                        var ack: [5]u8 = .{ 1, 0, 0, 0, 0 };
                        try self.sendGame(peer, "NetPackageInventoryTransactionResponse", &ack);
                    } else {
                        // Stock TransactionRequestServer (IL=46, RE
                        // protocol-packages.md:1245): a failed apply logs and
                        // calls LockManager.ForceUnlockByPlayer. The client's
                        // window is showing a transaction the server refused,
                        // so leaving the lock held keeps that window open over
                        // a container whose contents no longer match, and pins
                        // the channel against everyone else.
                        self.harness.counters.inc(.c2s_rejects);
                        self.releaseOtherLocksForPeer(c.slot, game_locks.keep_no_channel);
                    }
                }
            }
            return true;
        }
        const tx = packages.parseInvTxRequest(body) catch return true;
        var r: invsys.Result = .{};
        var bag_pos: ?[3]i32 = null;
        // Captured before apply: a rejected place must refund what it consumed.
        const place_item_id: u16 = blk: {
            if (tx.op != @intFromEnum(invsys.Op.place) and tx.op != @intFromEnum(invsys.Op.use)) break :blk 0;
            if (tx.a >= ecs.components.max_inv_slots) break :blk 0;
            const ps = self.sim.playerByPeer(c.slot) orelse break :blk 0;
            if (!self.sim.mask[ps].inventory) break :blk 0;
            break :blk self.sim.inventory[ps].slots[tx.a].item_id;
        };
        const ledger_before = self.sim.inv_ledger.total;
        if (tx.op == @intFromEnum(invsys.Op.craft)) {
            r = .{ .ok = self.tryCraft(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
        } else if (tx.op == @intFromEnum(invsys.Op.scrap)) {
            r = .{ .ok = self.tryScrap(c.slot, tx.a, if (tx.qty == 0) 1 else tx.qty) };
        } else if (tx.op > @intFromEnum(invsys.Op.equip)) {
            // Compact path: craft/scrap are handled above; any other op past
            // equip is unknown. Mapping unknowns to `.list` used to ack success
            // with no mutation (fail-open); stock InvTx rejects instead.
            r = .{ .ok = false };
            self.harness.counters.inc(.c2s_rejects);
        } else {
            const op: invsys.Op = @enumFromInt(tx.op);
            // Per-surface quarantine, the same gate the Bag and TileEntity
            // arms apply. This one packet reaches both surfaces: open / take /
            // put mutate a container's contents, and place writes a world
            // block. Ungated, a peer quarantined off either surface kept
            // working through the transaction route while its direct packets
            // were refused.
            switch (op) {
                .open, .take, .put => if (self.quarantineDenies(c, .container)) return true,
                .place => if (self.quarantineDenies(c, .block)) return true,
                else => {},
            }
            // Repair-by-combine first: dragging a damaged tool onto another
            // is MergeBest, not a move/swap. Falls through to the normal
            // path when the pair does not combine.
            if (op == .move and self.tryCombineTools(c.slot, tx.a, tx.b)) {
                var ack: [5]u8 = .{ 1, 0, 0, 0, 0 };
                try self.sendGame(peer, "NetPackageInventoryTransactionResponse", &ack);
                return true;
            }
            // The open bag's position, read while it still exists: a drain
            // that empties it destroys the entity, and the marker is keyed by
            // position.
            if (op == .take) {
                if (self.sim.playerByPeer(c.slot)) |tps| {
                    const cid = self.sim.inventory[tps].open_container;
                    if (cid > 0) {
                        if (self.sim.slotOfNetId(cid)) |bs| {
                            if (self.sim.mask[bs].transform) {
                                const bt = self.sim.transform[bs];
                                bag_pos = .{ @trunc(bt.x), @trunc(bt.y), @trunc(bt.z) };
                            }
                        }
                    }
                }
            }
            // ItemActionEat: resolve food/water/hp from items.xml via eatProps.
            r = invsys.applyTransactionEx(&self.sim, c.slot, op, tx.a, tx.b, tx.qty, tx.entity_id, eatProps, self);
        }
        // Draining a death bag slot-by-slot destroys it the same way
        // collecting the whole bag does, so the backpack marker must clear on
        // both, or the map keeps a marker on a bag that no longer exists.
        // The position has to be read before the drain: the entity is gone by
        // the time `emptied_bag` reports it.
        if (r.ok and r.emptied_bag > 0) {
            if (bag_pos) |bp| {
                if (c.removeBackpackAt(bp[0], bp[1], bp[2])) {
                    self.broadcastPlayerBackpack(c) catch {};
                }
            }
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
            // Drop any prior sparse raw at this cell so a re-place cannot
            // echo stale rotation/meta over the bare placed id (GAP 13).
            self.clearBlockRaw(r.place_x, r.place_y, r.place_z);
            // A placed bedroll becomes the player's respawn point (stock
            // bedroll blocks set EntityPlayer.spawnPoint on placement).
            if (self.isBedrollId(r.place_block)) {
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
            self.grantMagazineRead(c.slot, place_item_id);
            try self.sendSurvivalStats(peer, c.entity_id, r.hp, r.max_hp, r.food, r.food_max, r.water, r.water_max);
        }
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageInventoryDataRequest")) {
        // Rate gate: each request serves up to 54 container slots; unthrottled
        // a spam loop turns a few bytes into a full response per packet.
        if (!self.takeInvToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        // Stock: KeyHashPair (Guid+hash) + managerToken Guid.
        // Serve TE container slots when Guid matches our deterministic pos-key.
        if (packages.parseInvDataRequestStock(body)) |req| {
            if (self.containers.getByGuid(&req.inventory_key)) |cont| {
                // Stock LootManager.LootContainerOpened: an untouched world
                // container rolls here with the opener's loot stage (the roll
                // no longer happens at chunk load), and a looted one re-rolls
                // once LootRespawnDays have elapsed.
                self.ensureContainerLoot(cont, c.slot);
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
