//! Server-owned particle sends. `EntityAlive.OnEntityDeath` (IL=146) spawns the
//! entityclass `ParticleOnDeath` through `GameManager.SpawnParticleEffectServer`,
//! which is the same `NetPackageParticleEffect` shape the client relay uses.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");

/// Broadcast a particle at a world position. `caused_by` becomes the package's
/// `entityThatCausedIt`, which stock uses as `allButAttachedToEntityId` when it
/// fans the effect out.
pub fn broadcastParticle(self: *Game, name: []const u8, x: f32, y: f32, z: f32, caused_by: i32) void {
    if (name.len == 0) return;
    var buf: [192]u8 = undefined;
    const body = packages.buildParticleEffectBody(&buf, .{
        .particle_id = packages.particleId(name),
        .x = x,
        .y = y,
        .z = z,
    }, caused_by, false, false) catch {
        self.harness.counters.inc(.encode_errors);
        return;
    };
    self.broadcastNear("NetPackageParticleEffect", body, x, z, self.interest_range) catch {
        self.harness.counters.inc(.net_send_errors);
    };
}

/// The `on_death_fn` hook body: the dying entity's class particle at its
/// position (`EntityAlive.OnEntityDeath` IL=146 spawns it through
/// `SpawnParticleEffectServer` before the corpse work).
pub fn onEntityDeath(ctx: ?*anyopaque, entity_id: i32, x: f32, y: f32, z: f32, particle: []const u8) void {
    const self: *Game = @ptrCast(@alignCast(ctx orelse return));
    if (particle.len == 0) return;
    broadcastParticle(self, particle, x, y + 0.5, z, entity_id);
}
