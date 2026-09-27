//! Game integration tests: land claims, block durability.
//!
//! Split out of server/game/game_tests.zig (same tests, moved verbatim).

const std = @import("std");
const test_tmp = @import("../../util/test_tmp.zig");
const Game = @import("../game.zig").Game;
const game = @import("../game.zig");
const ln_peer = @import("../../litenet/peer.zig");
const wire_binary = @import("../../wire/binary.zig");
const platform_user = @import("../../wire/platform_user.zig");
const io_fs = @import("../../util/io_fs.zig");
const packages = @import("../../wire/packages.zig");
const world_store = @import("../../world/store.zig");
const light_te_mod = @import("../../world/light_te.zig");
const ecs = @import("../../ecs/root.zig");
const systems = @import("../../ecs/systems.zig");
const schedule = @import("../../ecs/schedule.zig");
const game_hooks = @import("../game/hooks.zig");
const clock = @import("../../util/clock.zig");
const util_sim = @import("../../util/sim.zig");
const wire_frame = @import("../../wire/frame.zig");
const wire_stock_buff = @import("../../wire/stock_buff.zig");
const assets_unity_hash = @import("../../assets/unity_hash.zig");
const assets_biome_layers = @import("../../assets/biome_layers.zig");
const sleepers_mod = @import("../../world/sleepers.zig");
const replicate_te = @import("replicate_te.zig");
const containers_mod = @import("../../world/containers.zig");
const chunk_fill_mod = @import("../game/chunk_fill.zig");
const c2s_misc = @import("../c2s/misc.zig");
const plugin_mod = @import("../../plugin/root.zig");
const plugin_api = @import("../../plugin/api.zig");
const assets_gamestages = @import("../../assets/gamestages.zig");
const assets_buffs = @import("../../assets/buffs.zig");
const ecs_buff = @import("../../ecs/buff.zig");
const assets_progression = @import("../../assets/progression.zig");
const requirements = @import("../../assets/requirements.zig");
const assets_entitygroups = @import("../../assets/entitygroups.zig");
const assets_traders = @import("../../assets/traders.zig");
const assets_npc = @import("../../assets/npc.zig");
const game_craft = @import("../game/craft.zig");
const parallel = @import("../../util/parallel.zig");
const stock_paths = @import("../../util/stock_paths.zig");
const zpv2DropName = game.zpv2DropName;
test "land claim removed when keystone breaks and expires offline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const world_dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    g.sim.director.clock.day = 30;
    g.registerClaim(250, 70, 250, cl.entity_id);
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // Breaking a non-keystone block does not remove the claim, so it must not
    // take a marker off the wire either.
    cap.clear();
    g.removeClaimAt(249, 70, 250);
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    try std.testing.expect(cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) == null);
    // Breaking the keystone removes it and takes the map marker off the wire
    // (TEFeatureLandClaim.OnDestroy IL=28 broadcasts the remove-by-position
    // form with EnumMapObjectType 15).
    cap.clear();
    g.removeClaimAt(250, 70, 250);
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
    {
        const rm = cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(packages.map_marker_remove_by_position, std.mem.readInt(i32, rm[0..4], .little));
        try std.testing.expectEqual(@as(f32, 250), @as(f32, @bitCast(std.mem.readInt(u32, rm[4..8], .little))));
        try std.testing.expectEqual(@as(f32, 70), @as(f32, @bitCast(std.mem.readInt(u32, rm[8..12], .little))));
        try std.testing.expectEqual(@as(f32, 250), @as(f32, @bitCast(std.mem.readInt(u32, rm[12..16], .little))));
        try std.testing.expectEqual(
            @intFromEnum(packages.MapObjectType.land_claim),
            std.mem.readInt(i32, rm[16..20], .little),
        );
    }
    // Expiry: an offline claim past the window is released on the day roll,
    // and every removal path (expiry here, keystone break above) takes the
    // marker off the wire through the same hook.
    g.registerClaim(250, 70, 250, cl.entity_id);
    g.markClaimsForEntity(cl.entity_id, false);
    g.land_claims[0].owner_seen_day = g.sim.director.clock.day - 10;
    cap.clear();
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
    try std.testing.expect(cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) != null);
    // Expiry disabled (0) keeps even a very old offline claim.
    g.registerClaim(250, 70, 250, cl.entity_id);
    g.land_claim_expiry_days = 0;
    g.markClaimsForEntity(cl.entity_id, false);
    g.land_claims[0].owner_seen_day = 1;
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // An online claim never expires.
    g.land_claim_expiry_days = 3;
    g.markClaimsForEntity(cl.entity_id, true);
    g.land_claims[0].owner_seen_day = 1;
    g.expireClaims();
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    // Erasure: a claim carries the owner's login name, so wipeplayer has to
    // release it or the name outlives the players.zsv record in claims.zlc.
    try std.testing.expect(g.land_claims[0].owner_name_len > 0);
    var owner: [32]u8 = undefined;
    const on = g.land_claims[0].owner_name_len;
    @memcpy(owner[0..on], g.land_claims[0].owner_name[0..on]);
    try std.testing.expectEqual(@as(u32, 0), g.dropClaimsForName("someone-else"));
    try std.testing.expectEqual(@as(usize, 1), g.land_claims_n);
    cap.clear();
    try std.testing.expectEqual(@as(u32, 1), g.dropClaimsForName(owner[0..on]));
    try std.testing.expect(cap.findPkgId(packages.idOf("NetPackageEntityMapMarkerRemove").?) != null);
    try std.testing.expectEqual(@as(usize, 0), g.land_claims_n);
}

test "land claim count and dead-zone gates refuse over-limit and adjacent claims" {
    // Stock LandClaimCount / LandClaimDeadZone: a claim past the owner's
    // count or inside another claim's dead zone is not registered.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const world_dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    g.land_claim_count = 2;
    g.land_claim_dead_zone = 60;
    // First claim: allowed.
    try std.testing.expect(g.claimAllowed(cl.entity_id, 100, 70, 100));
    g.registerClaim(100, 70, 100, cl.entity_id);
    // Second, far away: allowed (under the count, outside the dead zone).
    try std.testing.expect(g.claimAllowed(cl.entity_id, 400, 70, 400));
    g.registerClaim(400, 70, 400, cl.entity_id);
    try std.testing.expectEqual(@as(usize, 2), g.land_claims_n);
    // Over the count: refused.
    try std.testing.expect(!g.claimAllowed(cl.entity_id, 700, 70, 700));
    // Inside the dead zone of claim (100,100): refused.
    try std.testing.expect(!g.claimAllowed(cl.entity_id, 130, 70, 100));
    // A different owner is not counted against this one.
    g.registerClaim(700, 70, 700, cl.entity_id + 1000);
    try std.testing.expectEqual(@as(usize, 3), g.land_claims_n);
    // With count headroom, a far claim passes the dead-zone gate.
    g.land_claim_count = 5;
    try std.testing.expect(g.claimAllowed(cl.entity_id, 900, 70, 900));
    // Dead zone 0 disables the adjacency check.
    g.land_claim_dead_zone = 0;
    try std.testing.expect(g.claimAllowed(cl.entity_id, 105, 70, 105));
    // Count 0 disables the count check.
    g.land_claim_count = 0;
    try std.testing.expect(g.claimAllowed(cl.entity_id, 105, 70, 105));
}

test "land claims hold past the old 256 cap and survive restart (GAP 12)" {
    // The claim table was 256: the 257th register silently vanished. Now 1024;
    // register 300 and prove the save/restart round trip keeps every claim.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const world_dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var cap: ln_peer.Capture = .{};
    const cl = try g.attachJoinedClient(&cap);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        g.registerClaim(@intCast(1000 + i * 2), 70, @intCast(i), cl.entity_id);
    }
    try std.testing.expectEqual(@as(usize, 300), g.land_claims_n);
    try g.saveClaims();

    const g2 = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g2.deinit();
        std.testing.allocator.destroy(g2);
    }
    try std.testing.expectEqual(@as(usize, 300), g2.land_claims_n);
    std.debug.print("PASS claims-cap: 300 claims round-trip (cap was 256)\n", .{});
}

test "block durability has no eviction cap (GAP 12)" {
    // The damage store was a global FIFO: past the cap the oldest damaged
    // block's damage reverted mid-fight. Damage now lives in the chunk damage
    // plane (per-chunk, persisted by ZCH3), so any number of distinct damaged
    // blocks keeps its absolute value.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const world_dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        _ = try g.addBlockDamage(@intCast(200 + i), 70, 300, 5);
    }
    var ok = true;
    i = 0;
    while (i < 300) : (i += 1) {
        if (g.getBlockHp(@intCast(200 + i), 70, 300) != 5) ok = false;
    }
    try std.testing.expect(ok);
    std.debug.print("PASS blockhp-nocap: 300 damaged blocks retain damage\n", .{});
}

test "block durability survives far past the old 1024 cap" {
    // Regression for the GAP 12 eviction flaw: 2000 distinct damaged blocks
    // all keep their absolute damage (the old table capped at 1024 and reset
    // the oldest entry mid-fight).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const world_dir = try test_tmp.rootOf(&tmp);
    const g = try Game.create(std.testing.allocator, world_dir, 0);
    defer {
        g.deinit();
        std.testing.allocator.destroy(g);
    }
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = try g.addBlockDamage(@intCast(500 + i), 70, 400, 3);
    }
    var ok = true;
    i = 0;
    while (i < 2000) : (i += 1) {
        if (g.getBlockHp(@intCast(500 + i), 70, 400) != 3) ok = false;
    }
    try std.testing.expect(ok);
    std.debug.print("PASS blockhp-nocap: 2000 damaged blocks retain damage\n", .{});
}
