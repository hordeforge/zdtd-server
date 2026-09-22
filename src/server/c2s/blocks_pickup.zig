//! C2S block arms: pickup block, set-block texture.
//!
//! Split out of c2s/blocks.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const platform_user = packages.platform_user;
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const invsys = @import("../../ecs/inventory.zig");
const game_world = @import("../game/world.zig");

/// True when `name` is a pickup/texture package and was handled.
pub fn handlePickup(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    if (std.mem.eql(u8, name, "NetPackagePickupBlock")) {
        // Wrench pickup. RE: GameManager.PickupBlockServer IL=77 (verify type
        // match, echo the pickup to the requesting player, replace the block
        // with PickupSource/Air via SetBlocksRPC); the item itself is added
        // client-side by PickupBlockClient -> Block.OnBlockPickedUp and rides
        // the player's normal inventory sync, exactly like stock (the dedi
        // never fabricates the item).
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        var plat_buf: [platform_user.max_platform_len]u8 = undefined;
        var id_buf: [platform_user.max_id_len]u8 = undefined;
        var sent_id: ?platform_user.Id = null;
        const pk = packages.parsePickupBlockBody(body, &plat_buf, &id_buf, &sent_id) catch return true;
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const editor_ent = self.sim.network_id[ps].id;
        // ValidEntityIdForSender: the pickup must claim the sender's own
        // entity (asm.il NetPackage.ValidEntityIdForSender).
        if (pk.player_id != editor_ent) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        // ValidUserIdForSender (asm.il NetPackage IL=29): exact match against
        // the sender's PlatformId or CrossplatformId; a null sent identity
        // passes only when the sender registered none (EAC-off / loadgen).
        if (sent_id) |sent| {
            if (!c.puid_primary.matches(sent) and !c.puid_native.matches(sent)) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        } else {
            if (c.puid_primary.get() != null or c.puid_native.get() != null) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        // Type match: the world block must still be what the client snapped
        // (IL=77 IL_0031-0048; a mismatch silently drops, so a stale or
        // spoofed pickup never removes a different block).
        const cur_id = self.world.blockWorld(pk.x, pk.y, pk.z) catch return true;
        if (cur_id != world_store.typeId(pk.raw)) return true;
        // zdtd trust bounds (stock checks CanPickup client-side; the server
        // still enforces reach and claims so a spoofed pickup cannot delete
        // distant or claimed blocks).
        const ep = self.sim.transform[ps];
        if (self.rejectIfBeyondEditRange(
            c,
            peer.local_id,
            editor_ent,
            .block,
            ep.x,
            ep.y,
            ep.z,
            @floatFromInt(pk.x),
            @floatFromInt(pk.y),
            @floatFromInt(pk.z),
        )) return true;
        if (self.claimCovering(pk.x, pk.z)) |claim| {
            if (claim.owner_entity != editor_ent) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        // 1) Echo the pickup to the requesting player. Setup(pos, bv, playerId,
        //    null) writes a null identity, which the client's
        //    ValidUserIdForSender skips (it is not the server).
        const echo = packages.buildPickupBlockBody(self.body_buf[0..32], pk.x, pk.y, pk.z, pk.raw, pk.player_id) catch return true;
        try self.sendGame(peer, "NetPackagePickupBlock", echo);
        // 2) Replacement block: PickupSource name resolved via AssignIds, or
        //    Air. V3.1.0 b14 ships no PickupSource property, so stock leaves
        //    Air behind on every pickup; a modded blocks.xml is honoured.
        var repl_raw: u32 = 0;
        if (self.blocks.pickupSource(cur_id)) |src_name| {
            repl_raw = self.maxdamage.idByName(src_name) orelse 0;
        }
        // 3) Apply it to the world, then broadcast (stock SetBlocksRPC carries
        //    a BlockChangeInfo; the SetBlock S2C body is the same shape the
        //    client Reads for every server block change). The write has to
        //    happen here: stock replicates the pickup rather than simulating
        //    it client-side (RE blocks.md "Server authority"), so a broadcast
        //    without a world write leaves the block standing on the server.
        //    The picked block is gone for the client until the next chunk
        //    load puts it back, and it still blocks placement and pathing.
        try self.world.setBlockRawWorld(pk.x, pk.y, pk.z, repl_raw);
        self.clearBlockHp(pk.x, pk.y, pk.z);
        // Invalidate the sparse raw mirror: the picked cell's prior rotation
        // must not outlive the chunk write (GAP 13).
        if (repl_raw != 0) {
            self.setBlockRaw(pk.x, pk.y, pk.z, repl_raw);
        } else {
            self.clearBlockRaw(pk.x, pk.y, pk.z);
        }
        if (repl_raw == 0) {
            self.noteBlockRemoved(pk.x, pk.y, pk.z, cur_id);
            self.removeClaimAt(pk.x, pk.y, pk.z);
        }
        if (packages.buildSetBlockBodyRaw(self.body_buf[0..96], pk.x, pk.y, pk.z, repl_raw, 0, editor_ent, editor_ent)) |sb| {
            try self.broadcastNear("NetPackageSetBlock", sb, ep.x, ep.z, self.interest_range);
        } else |_| {}
        return true;
    }
    if (std.mem.eql(u8, name, "NetPackageSetBlockTexture")) {
        // Paint. RE: GameManager.SetBlockTextureServer IL=41 (apply the face
        // texture, rebroadcast to everyone but the sender with
        // playerIdThatChanged=-1 on a dedi); Chunk.SetBlockFaceTexture IL=48
        // stores the BlockTextureData catalog idx raw (`_texture & 255`) in
        // the face*8 bits of the per-block textureFull.
        if (!self.takeBlockToken(c)) {
            self.harness.counters.inc(.c2s_throttle);
            return true;
        }
        const st = packages.parseSetBlockTexture(body) catch return true;
        // chnTextures is a 1-element array (Chunk IL_01F8-01FE: `ldc.i4.1;
        // newarr`), so channel 0 is the only valid one; fail closed.
        if (st.channel != 0) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        if (st.face > 5) {
            self.harness.counters.inc(.bounds_rejects);
            return true;
        }
        const ps = self.sim.playerByPeer(c.slot) orelse return true;
        const editor_ent = self.sim.network_id[ps].id;
        // ValidEntityIdForSender: the paint must claim the sender's own entity.
        if (st.player_id != editor_ent) {
            self.harness.counters.inc(.ownership_rejects);
            return true;
        }
        const ep = self.sim.transform[ps];
        if (self.rejectIfBeyondEditRange(
            c,
            peer.local_id,
            editor_ent,
            .block,
            ep.x,
            ep.y,
            ep.z,
            @floatFromInt(st.x),
            @floatFromInt(st.y),
            @floatFromInt(st.z),
        )) return true;
        if (self.claimCovering(st.x, st.z)) |claim| {
            if (claim.owner_entity != editor_ent) {
                self.harness.counters.inc(.ownership_rejects);
                return true;
            }
        }
        const cur_id = self.world.blockWorld(st.x, st.y, st.z) catch return true;
        if (cur_id == 0) return true; // nothing to paint on
        // Base textureFull: stored paint, else the block's default (what the
        // client renders unpainted) so the other five faces do not go grey.
        const wt = world_store.World.worldToChunk(st.x, st.z);
        const ch = try self.world.getOrCreate(wt.pos);
        var base = ch.texAt(wt.lx, st.y, wt.lz);
        if (base == 0) base = self.block_textures.get(cur_id);
        const shift: u6 = @intCast(st.face * 8);
        const new_tex = (base & ~(@as(u64, 0xff) << shift)) | (@as(u64, st.idx) << shift);
        try self.world.setBlockTexDensWorld(st.x, st.y, st.z, self.blockRawAt(st.x, st.y, st.z), new_tex, null);
        // Rebroadcast to everyone but the painter (stock flags 192 excludes
        // the sender; the painter already applied the paint locally).
        const s2c: packages.SetBlockTexture = .{
            .x = st.x,
            .y = st.y,
            .z = st.z,
            .face = st.face,
            .idx = st.idx,
            .player_id = -1, // dedi (IL=41 IL_0018-0027)
            .channel = st.channel,
        };
        if (packages.buildSetBlockTextureBody(self.body_buf[0..32], s2c)) |sb| {
            try self.broadcastExcept("NetPackageSetBlockTexture", sb, c.slot);
        } else |_| {}
        return true;
    }
    return false;
}
