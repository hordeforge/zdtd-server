//! Stability helpers extracted verbatim from game.zig.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");
const stability_mod = @import("../../world/stability.zig");
const ecs_components = @import("../../ecs/components.zig");

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
        // Falling-block group (RE entity-ai.md LetBlocksFall): snapshot the
        // raw values BEFORE the air write, then spawn one EntityFallingBlock
        // carrying the group. The client renders the fall; landing removes it
        // (no re-placement). Group cap 32 matches stock GroupBounds.
        var cells: [ecs_components.falling_group_cap]ecs_components.FallingCell = undefined;
        var cn: usize = 0;
        var i: usize = 0;
        while (i < n and cn < cells.len) : (i += 1) {
            const p = fallen[i];
            const raw: u32 = @intCast(self.world.blockWorld(p.x, p.y, p.z) catch 0);
            self.clearBlockHp(p.x, p.y, p.z);
            self.removeClaimAt(p.x, p.y, p.z);
            self.clearBlockRaw(p.x, p.y, p.z);
            self.containers.remove(.{ .x = p.x, .y = p.y, .z = p.z });
            self.world.setBlockWorld(p.x, p.y, p.z, 0) catch continue;
            cells[cn] = .{ .x = p.x, .y = p.y, .z = p.z, .raw = raw };
            cn += 1;
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
        if (cn > 0) {
            _ = self.sim.spawnFallingBlocks(cells[0..cn]);
        }
    }
    if (new_id != 0) {
        stability_mod.placeBlockAt(&self.world, x, y, z, self.allocator, self, stabilityFacts);
    }
    return n;
}
