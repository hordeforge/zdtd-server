//! Sleeper bodies: wakeup + passive-change entity-id bodies with the
//! layout tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_sleeper` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageSleeperWakeup (Assembly-CSharp NetPackageSleeperWakeup::write,
/// IL=8): after the base header the payload is WriteInt32(m_targetId).
/// GetLength()=8, PackageDirection=ToClient. Sent broadcast (unreliable) by
/// EntityAlive.ConditionalTriggerSleeperWakeUp when a sleeper zombie wakes
/// (proximity, noise, damage; protocol-packages.md §6.19). The client plays
/// the wake animation via EntityAlive.ConditionalTriggerSleeperWakeUp.
pub fn buildSleeperWakeupBody(buf: []u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    return w.written();
}

/// NetPackageSleeperPassiveChange (Assembly-CSharp, base NetPackageEntityTargeted):
/// payload is WriteInt32(entityId) via the base write. GetLength()=8,
/// PackageDirection=ToClient. Sent broadcast (unreliable) by
/// EntityAlive.SetSleeperActive (IL=26) when a volume's sleeper stays passive
/// after trigger; the client clears IsSleeperPassive (Process IL=21).
/// Note: NetPackageSleeperPose (entityId + pose byte) is registered but never
/// emitted by any stock server path in the V3.1.0 b14 dump - the sleep pose
/// rides the EntitySpawn is_sleeper/is_sleeper_passive flags instead.
pub fn buildSleeperPassiveChangeBody(buf: []u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(entity_id);
    return w.written();
}

test "SleeperWakeup body is the target entity id" {
    var buf: [8]u8 = undefined;
    const b = try buildSleeperWakeupBody(&buf, 107);
    try std.testing.expectEqual(@as(usize, 4), b.len);
    try std.testing.expectEqual(@as(i32, 107), std.mem.readInt(i32, b[0..4], .little));
}

test "SleeperPassiveChange body is the target entity id" {
    var buf: [8]u8 = undefined;
    const b = try buildSleeperPassiveChangeBody(&buf, -5);
    try std.testing.expectEqual(@as(usize, 4), b.len);
    try std.testing.expectEqual(@as(i32, -5), std.mem.readInt(i32, b[0..4], .little));
}
