//! Despawn system: idle/wandering zombies far from every player.
//!
//! Split out of ecs/systems.zig (same code, moved verbatim);
//! re-exported so existing `systems.*` call sites keep working.

const std = @import("std");
const World = @import("world.zig").World;
const Slot = @import("world.zig").Slot;
const max_entities = @import("world.zig").max_entities;
const query = @import("query.zig");
const sensing = @import("sensing.zig");
const PlayerScan = sensing.PlayerScan;
const anyWithin = sensing.anyWithin;
const snapshotPlayers = @import("systems.zig").snapshotPlayers;

/// Remove idle/wandering zombies far from every player. Returns removed ids
/// (caller broadcasts EntityRemove with Despawned reason).
/// Horde zombies never despawn here: stock tags them `bIsChunkObserver` so
/// they keep their own chunk loaded (`AIDirectorBloodMoonParty.SpawnZombie`,
/// `AIWanderingHordeSpawner`), and the recount/teleport pass owns their
/// lifecycle instead (dawn clears the marks, empty parties destroy the
/// stragglers). zdtd has no chunk-observer refcount, but the lifecycle half
/// is the same: skip `is_horde` and let the horde passes decide.
/// `out_slots`, when given, receives the slot each despawned mob occupied at
/// the moment it was destroyed, parallel to `out_ids`. The net layer scopes
/// the EntityRemove by it: after `destroy` the id no longer resolves, so the
/// caller cannot recover the slot. Must be at least as long as `out_ids`.
pub fn systemDespawnFar(w: *World, out_ids: []i32, out_slots: ?[]Slot) u8 {
    if (out_slots) |os| std.debug.assert(os.len >= out_ids.len);
    const despawn_dist_sq = w.rules.ai.despawn_dist_sq;
    if (w.countKind(.zombie) == 0 and w.countKind(.animal) == 0) return 0;
    var scan: PlayerScan = .{};
    _ = snapshotPlayers(w, &scan, false);
    var n: u8 = 0;
    // This loop destroys, so it walks a slot-ascending snapshot of both mob
    // kinds rather than the live groups. Concatenating groups would be
    // kind-major and would change which ids fill the capped out_ids list.
    var slots: [max_entities]Slot = undefined;
    const kn = query.copyKindsInto(w, &.{ .zombie, .animal }, &slots);
    for (slots[0..kn]) |i| {
        if (n >= out_ids.len) break;
        if (!w.alive[i] or !w.mask[i].transform) continue;
        // Sleepers stay (POI volumes re-trigger on approach otherwise).
        if (w.mask[i].sleeper) continue;
        if (w.mask[i].zombie_ai and w.zombie_ai[i].alert) continue;
        // Horde members stay however far they roam (see fn doc).
        if (w.mask[i].zombie_ai and w.zombie_ai[i].is_horde) continue;
        // Packed column scan: any player inside the despawn radius pins the
        // mob, so the per-mob inner loop is eight lanes at a time.
        if (anyWithin(&scan, w.transform[i].x, w.transform[i].z, despawn_dist_sq)) continue;
        if (w.mask[i].network_id) {
            out_ids[n] = w.network_id[i].id;
            if (out_slots) |os| os[n] = i;
            n += 1;
        }
        w.destroy(i);
    }
    return n;
}
