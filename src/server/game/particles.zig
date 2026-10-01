//! Server-owned particle sends. `EntityAlive.OnEntityDeath` (IL=146) spawns the
//! entityclass `ParticleOnDeath` through `GameManager.SpawnParticleEffectServer`,
//! which is the same `NetPackageParticleEffect` shape the client relay uses.

const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const packages = @import("../../wire/packages.zig");

/// Head height above the feet, the same torso/head offset the AI sight query
/// and the turret muzzle use.
const head_offset_blocks: f32 = 1.6;

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
    // Stock's SpawnParticleEffectServer fans out with
    // `allButAttachedToEntityId = entityThatCausedIt`: the client attached to
    // the causing entity already played it locally, so it is skipped.
    if (clientSlotForEntity(self, caused_by)) |skip| {
        self.broadcastNearExcept("NetPackageParticleEffect", body, x, z, self.interest_range, skip) catch {
            self.harness.counters.inc(.net_send_errors);
        };
        return;
    }
    self.broadcastNear("NetPackageParticleEffect", body, x, z, self.interest_range) catch {
        self.harness.counters.inc(.net_send_errors);
    };
}

/// The client slot owning an entity id, when one is attached. Null for an
/// entity nobody is driving (an NPC or a corpse).
fn clientSlotForEntity(self: *Game, entity_id: i32) ?usize {
    if (entity_id < 0) return null;
    for (self.clients, 0..) |cl, i| {
        if (cl.peer == null) continue;
        if (cl.entity_id == entity_id) return i;
    }
    return null;
}

/// The `on_death_fn` hook body: the dying entity's class particle at its
/// position (`EntityAlive.OnEntityDeath` IL=146 spawns it through
/// `SpawnParticleEffectServer` before the corpse work).
pub fn onEntityDeath(ctx: ?*anyopaque, entity_id: i32, x: f32, y: f32, z: f32, particle: []const u8) void {
    const self: *Game = @ptrCast(@alignCast(ctx orelse return));
    if (particle.len == 0) return;
    broadcastParticle(self, particle, x, y + 0.5, z, entity_id);
}

/// The destroy hook: `particleOnDestroy` fires at the head (spawning.md 1344),
/// so it is offset by the same head height the AI sight query uses.
pub fn onEntityDestroy(ctx: ?*anyopaque, entity_id: i32, x: f32, y: f32, z: f32, particle: []const u8) void {
    const self: *Game = @ptrCast(@alignCast(ctx orelse return));
    if (particle.len == 0) return;
    broadcastParticle(self, particle, x, y + head_offset_blocks, z, entity_id);
}
