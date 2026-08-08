//! Stability helpers extracted verbatim from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const stability_mod = @import("../../world/stability.zig");

pub fn stabilityFacts(ctx: ?*anyopaque, id: u16) stability_mod.Facts {
    const g: *Game = @ptrCast(@alignCast(ctx orelse return .{ .support = true, .ignore = false }));
    const name = g.blocks.byId(id) orelse return .{ .support = true, .ignore = false };
    return .{
        .support = g.maxdamage.stabilitySupport(name.name),
        .ignore = g.maxdamage.stabilityIgnore(name.name),
    };
}

pub fn bloodMoonDayFor(clk: @import("../../ecs/aidirector.zig").WorldClock) i32 {
    return clk.bloodMoonDayFor(clk.day);
}

pub fn stabilityAfterSetBlock(self: *Game, x: i32, y: i32, z: i32, old_id: u16, new_id: u16) usize {
    var n: usize = 0;
    if (old_id != 0) {
        var fallen: [stability_mod.max_fallen]stability_mod.Pos = undefined;
        n = stability_mod.removeBlockAt(
            &self.world,
            x,
            y,
            z,
            self.allocator,
            self,
            stabilityFacts,
            &fallen,
        );
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = fallen[i];
            self.clearBlockHp(p.x, p.y, p.z);
            self.removeClaimAt(p.x, p.y, p.z);
            self.clearBlockRaw(p.x, p.y, p.z);
            self.containers.remove(.{ .x = p.x, .y = p.y, .z = p.z });
            self.world.setBlockWorld(p.x, p.y, p.z, 0) catch continue;
            if (packages.buildSetBlockBodyRaw(
                self.body_buf[0..96],
                p.x,
                p.y,
                p.z,
                0,
                0,
                -1,
                -1,
            )) |sb| {
                self.broadcastNear("NetPackageSetBlock", sb, @floatFromInt(p.x), @floatFromInt(p.z), self.interest_range) catch {};
            } else |_| {}
        }
    }
    if (new_id != 0) {
        stability_mod.placeBlockAt(&self.world, x, y, z, self.allocator, self, stabilityFacts);
    }
    return n;
}
