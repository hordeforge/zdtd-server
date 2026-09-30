//! C2S tile-entity arms: drop-container refusal, TE edits.
//!
//! Split out of c2s/inv.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const ecs = @import("../../ecs/root.zig");
const inv_apply = @import("../inv_apply.zig");
const replicate_te = @import("../game/replicate_te.zig");
const vending_mod = @import("../../world/vending.zig");
const clock = @import("../../util/clock.zig");
const stock_te = packages.stock_te;
const containers_mod = @import("../../world/containers.zig");
const stabilityAfterSetBlock = game_mod.stabilityAfterSetBlock;
const reverseItemType = game_mod.Game.reverseItemType;
const systems = @import("../../ecs/systems.zig");
const assets_progression = @import("../../assets/progression.zig");
const game_craft = @import("../game/craft.zig");
// NetPackageTileEntity::ProcessPackage rebroadcasts the applied composite
// TE with SendPackage(..., pos = te.ToWorldCenterPos(), range = 192,
// exclude = false) (NetPackageTileEntity.il.txt IL_00B4). Stock includes
// the sender: that echo is what clears its lockHandleWaitingFor, so this
// stays the RE literal rather than the configurable interest_range the
// container and workstation TE paths use.
const sign_echo_range: f32 = 192;

/// True when `name` is a tile-entity package and was handled.
pub fn handleTe(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
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
                // module the body wrote (signable text or a canvas state), so a
                // forged body cannot write into an unrelated block's TE slot.
                if (sign.block_id <= 0 or sign.block_id > std.math.maxInt(u16)) return true;
                const cur = self.world.blockWorld(sign.world_x, sign.world_y, sign.world_z) catch return true;
                if (@as(i32, cur) != sign.block_id) return true;
                const bdef = self.blocks.byId(@intCast(sign.block_id)) orelse return true;
                if (!bdef.signable and !bdef.canvas) return true;
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
            // TEFeatureLockable: the client's padlock change becomes server
            // state here, so the chunk stream, a rejoin and the next restart
            // all carry it (before this the module only rode the echo, and a
            // player who streamed the area later saw an unlocked chest). A
            // composite without the module is the client's unlock or removal,
            // so it clears what we held.
            if (parsed.found_lock and parsed.lock_blob_len > 0 and
                parsed.lock_blob_len <= containers_mod.max_lock_feature_bytes and
                parsed.lock_blob_off + parsed.lock_blob_len <= body.len)
            {
                cont.lock_len = @intCast(parsed.lock_blob_len);
                @memcpy(cont.lock_blob[0..parsed.lock_blob_len], body[parsed.lock_blob_off..][0..parsed.lock_blob_len]);
            } else {
                cont.lock_len = 0;
            }
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
        // Door TE (`TEFeatureDoor` + `TEFeatureLockable`): the only state the
        // block meta does not already carry is the lock, so the lockable module
        // is stored and re-emitted to nearby peers, which is what makes a locked
        // door read as locked for everyone else.
        if (stock_te.parseDoorTeBody(body) catch |err| switch (err) {
            error.NotDoorTe => null,
            else => blk: {
                self.harness.counters.inc(.c2s_malformed);
                break :blk null;
            },
        }) |dr| {
            const dp = self.sim.playerByPeer(c.slot) orelse return true;
            const dpos = self.sim.transform[dp];
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                c.entity_id,
                .container,
                dpos.x,
                dpos.y,
                dpos.z,
                @floatFromInt(dr.world_x),
                @floatFromInt(dr.world_y),
                @floatFromInt(dr.world_z),
            )) return true;
            if (dr.found_lock) {
                const door = self.doors.getOrCreate(dr.world_x, dr.world_y, dr.world_z, @intCast(@max(dr.block_id, 0))) orelse return true;
                if (dr.lock_blob_len > 0 and dr.lock_blob_len <= door.lock_blob.len and
                    dr.lock_blob_off + dr.lock_blob_len <= body.len)
                {
                    door.lock_len = @intCast(dr.lock_blob_len);
                    @memcpy(door.lock_blob[0..dr.lock_blob_len], body[dr.lock_blob_off..][0..dr.lock_blob_len]);
                }
                if (replicate_te.buildDoorBody(self, door, dr.is_open)) |dbody| {
                    self.broadcastNear(
                        "NetPackageTileEntity",
                        dbody,
                        @floatFromInt(door.x),
                        @floatFromInt(door.z),
                        self.interest_range,
                    ) catch {};
                } else |_| {}
            }
            return true;
        }
        // Collector TE (`TileEntityCollector`): the body carries no version
        // byte (`write` emits the version only on the persistent stream,
        // IL_0008-000E), so the outer header's block id is what routes it. A
        // player taking the produced item sends the array with the slot emptied.
        const collector_block: ?u16 = blk: {
            const bid = stock_te.peekTeBlockId(body) orelse break :blk null;
            if (bid < 0 or bid > 65535) break :blk null;
            const id: u16 = @intCast(bid);
            const bd = self.blocks.byId(id) orelse break :blk null;
            if (!bd.collector) break :blk null;
            break :blk id;
        };
        if (collector_block) |want_block| {
            const cs = stock_te.parseCollectorTeBody(body) catch |err| blk: {
                self.harness.counters.inc(.c2s_malformed);
                var ts: [19]u8 = undefined;
                std.debug.print("zdtd: {s} collector parse err: {s}\n", .{ clock.wallStamp(&ts), @errorName(err) });
                break :blk null;
            } orelse return true;
            const col = self.collectors.get(cs.world_x, cs.world_y, cs.world_z) orelse return true;
            if (col.block_id != want_block) return true;
            const cp = self.sim.playerByPeer(c.slot) orelse return true;
            const cpos = self.sim.transform[cp];
            if (self.rejectIfBeyondEditRange(
                c,
                peer.local_id,
                c.entity_id,
                .container,
                cpos.x,
                cpos.y,
                cpos.z,
                @floatFromInt(col.x),
                @floatFromInt(col.y),
                @floatFromInt(col.z),
            )) return true;
            // Apply the output array verbatim (the move itself is the client's
            // inventory transaction, per ADR 0007's client-trusting apply), so an
            // emptied slot is how the water leaves the collector.
            var n: usize = 0;
            while (n < cs.items_n and n < col.items.len) : (n += 1) {
                const st = cs.items[n];
                col.items[n] = .{
                    .type_id = st.type_id,
                    .count = @intCast(@max(st.count, 0)),
                    .quality = st.quality,
                };
            }
            while (n < col.items.len) : (n += 1) col.items[n] = .{};
            // The fuel grid rides the same body (`fuelSlotsInternal`).
            var f: usize = 0;
            while (f < cs.fuel_n and f < col.fuel.len) : (f += 1) {
                const st = cs.fuel[f];
                col.fuel[f] = .{
                    .type_id = st.type_id,
                    .count = @intCast(@max(st.count, 0)),
                    .quality = st.quality,
                };
            }
            while (f < col.fuel.len) : (f += 1) col.fuel[f] = .{};
            var k: usize = 0;
            while (k < cs.catalyst_n and k < col.catalyst.len) : (k += 1) {
                const st = cs.catalyst[k];
                col.catalyst[k] = .{
                    .type_id = st.type_id,
                    .count = @intCast(@max(st.count, 0)),
                    .quality = st.quality,
                };
            }
            while (k < col.catalyst.len) : (k += 1) col.catalyst[k] = .{};
            var m: usize = 0;
            while (m < cs.mods_n and m < col.mods.len) : (m += 1) {
                const st = cs.mods[m];
                col.mods[m] = .{
                    .type_id = st.type_id,
                    .count = @intCast(@max(st.count, 0)),
                    .quality = st.quality,
                };
            }
            while (m < col.mods.len) : (m += 1) col.mods[m] = .{};
            col.dirty = true;
            try replicate_te.broadcastDirtyCollectors(self);
            try self.sendGame(peer, "NetPackageTileEntity", body);
            return true;
        }
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
    return false;
}
