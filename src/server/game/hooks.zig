//! ECS hooks: sim callbacks that read Game / World state.
//! Verbatim move from game.zig — thin wrappers remain there as `ctx: ?*anyopaque` adapters.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const world_store = @import("../../world/store.zig");
const ecs = @import("../../ecs/root.zig");
const assets_maxdamage = @import("../../assets/maxdamage.zig");
const invsys = @import("../../ecs/inventory.zig");

pub fn heightAtWorld(ctx: ?*anyopaque, wx: i32, wz: i32) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const t = world_store.World.worldToChunk(wx, wz);
    g.terrain_mu.lock();
    defer g.terrain_mu.unlock();
    const ch = g.world.getOrCreate(t.pos) catch |err| {
        std.debug.print(
            "zdtd: heightAtWorld chunk ({d},{d}) failed: {s}; fallback y=61\n",
            .{ t.pos.x, t.pos.z, @errorName(err) },
        );
        return 61;
    };
    return @as(f32, @floatFromInt(ch.heightAt(t.lx, t.lz))) + 1.0;
}

pub fn spawnPoiTraders(self: *Game) void {
    const pf = if (self.world.prefabs) |*p| p else return;
    for (pf.items) |d| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const qd = pf.questData(d.name) orelse continue;
        if (qd.trader_tag.len == 0) continue;
        var cname_buf: [64]u8 = undefined;
        const cname = std.fmt.bufPrint(&cname_buf, "npcTrader{s}", .{qd.trader_tag[6..]}) catch continue;
        const def = self.entities.byName(cname) orelse continue;
        const r = @import("../../world/tts.zig").rotateLocalXZ(qd.trader_x, qd.trader_z, d.size_x, d.size_z, d.rot);
        const wx: f32 = @floatFromInt(d.x + r.x);
        const wy: f32 = @floatFromInt(d.stampY() + qd.trader_y);
        const wz: f32 = @floatFromInt(d.z + r.z);
        const nid = self.sim.spawnTrader(cname, wx, wy, wz, self.npc.traderIdForClass(cname), self.trader_wallet_dukes) orelse continue;
        if (self.sim.slotOfNetId(nid)) |s| {
            self.sim.class_id[s].hash = def.hash;
            self.sim.class_id[s].loot_list = def.loot_list;
        }
        self.fillTraderFromXml(nid);
        std.debug.print("zdtd: POI trader {s} at ({d},{d},{d}) entity={d}\n", .{ d.name, wx, @as(i32, @trunc(wy)), wz, nid });
    }
}

pub fn poiRectAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pf = if (g.world.prefabs) |*p| p else return null;
    const wx: i32 = @floor(x);
    const wz: i32 = @floor(z);
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const b = pf.boundsXZ(i);
        if (wx < b.x0 or wx >= b.x1 or wz < b.z0 or wz >= b.z1) continue;
        return .{
            .x = @floatFromInt(b.x0),
            .y = @floatFromInt(d.y),
            .z = @floatFromInt(b.z0),
            .size_x = @floatFromInt(b.x1 - b.x0),
            .size_y = @floatFromInt(d.size_y),
            .size_z = @floatFromInt(b.z1 - b.z0),
        };
    }
    return null;
}

pub fn partySame(ctx: ?*anyopaque, a: i32, b: i32) bool {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pa = g.parties.partyByMember(a) orelse return false;
    return pa == g.parties.partyByMember(b);
}

pub fn nearestPoiAtWorld(ctx: ?*anyopaque, x: f32, z: f32) ?ecs.components.PoiRect {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const pf = if (g.world.prefabs) |*p| p else return null;
    var best: ?ecs.components.PoiRect = null;
    var best_d: f32 = std.math.inf(f32);
    for (pf.items, 0..) |d, i| {
        if (world_store.prefabs.isPart(d.name)) continue;
        const b = pf.boundsXZ(i);
        const cx = (@as(f32, @floatFromInt(b.x0)) + @as(f32, @floatFromInt(b.x1))) * 0.5;
        const cz = (@as(f32, @floatFromInt(b.z0)) + @as(f32, @floatFromInt(b.z1))) * 0.5;
        const dx = cx - x;
        const dz = cz - z;
        const dist = dx * dx + dz * dz;
        if (dist < best_d) {
            best_d = dist;
            best = .{
                .x = @floatFromInt(b.x0),
                .y = @floatFromInt(d.y),
                .z = @floatFromInt(b.z0),
                .size_x = @floatFromInt(b.x1 - b.x0),
                .size_y = @floatFromInt(d.size_y),
                .size_z = @floatFromInt(b.z1 - b.z0),
            };
        }
    }
    return best;
}

pub fn pathStepAt(ctx: ?*anyopaque, _: i32, _: i32, from_y: i32, tx: i32, tz: i32) ?i32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.terrain_snapshot_on) {
        if (g.terrain_snap.standable(tx, tz, from_y)) |y| return y;
    }
    g.terrain_mu.lock();
    defer g.terrain_mu.unlock();
    return g.world.standableWorld(tx, tz, from_y) catch null;
}

pub fn placeBlockId(ctx: ?*anyopaque, item_id: u16) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    const iname: ?[]const u8 = if (g.items.byId(item_id)) |d| d.name else invsys.builtinStockNameFallback(item_id);
    const IdCtx = struct {
        t: *const assets_maxdamage.Table,
        fn lookup(c: ?*anyopaque, n: []const u8) ?u16 {
            const s: *const @This() = @ptrCast(@alignCast(c.?));
            return s.t.idByName(n);
        }
    };
    var id_ctx: IdCtx = .{ .t = &g.maxdamage };
    const resolved = invsys.itemToBlockResolved(item_id, iname, IdCtx.lookup, &id_ctx);
    if (resolved != 0) return resolved;
    const offline = invsys.itemToBlock(item_id);
    if (offline != 0) return offline;
    return 0;
}

pub fn itemFuelValue(ctx: ?*anyopaque, item_id: u16) f32 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    return g.items.fuelValueFor(item_id);
}

pub fn itemStackFor(ctx: ?*anyopaque, item_id: u16) u16 {
    const g: *Game = @ptrCast(@alignCast(ctx.?));
    if (g.items.byId(item_id)) |_| return g.items.stackFor(item_id);
    return invsys.maxStackBuiltin(item_id);
}
