//! Nav-object bodies: add/remove map markers with the layout tests.
//!
//! Split out of the packages.zig facade (same builders, same tests);
//! import via `packages.stock_nav` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageNavObject add/remove map marker (quest/trader style).
/// Wire: class | name | pos | isAdd | useOverrideColor | color u32 | usingLoc bool | entityId
pub fn buildNavObjectAdd(
    buf: []u8,
    nav_class: []const u8,
    name: []const u8,
    x: f32,
    y: f32,
    z: f32,
    entity_id: i32,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(nav_class);
    try w.writeString(name);
    try w.writeF32(x);
    try w.writeF32(y);
    try w.writeF32(z);
    try w.writeBool(true); // isAdd
    try w.writeBool(false); // useOverrideColor
    try w.writeU32(0xffffffff); // Color32 white as packed ARGB-ish
    try w.writeBool(false); // usingLocalizationId
    try w.writeI32(entity_id);
    return w.written();
}

/// NetPackageNavObject remove form (Setup(Int32 _entityId) IL=20): every
/// field is still written, with an empty class/name and a zero position, and
/// isAdd = false. The client's ProcessPackage (IL=77, isAdd false branch) then
/// calls NavObjectManager.UnRegisterNavObjectByEntityID(entityId). Stock sends
/// this from AIDirectorAirDropComponent.RemoveSupplyCrate (IL=54), reached by
/// EntitySupplyCrate.OnEntityUnload (IL=17) when the unload reason is Killed;
/// EntitySupplyCrate.OnEntityDeath (IL=30) sends the parallel
/// NetPackageEntityMapMarkerRemove(SupplyDrop, entityId).
pub fn buildNavObjectRemove(buf: []u8, entity_id: i32) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(""); // navObjectClass
    try w.writeString(""); // name
    try w.writeF32(0);
    try w.writeF32(0);
    try w.writeF32(0); // position
    try w.writeBool(false); // isAdd
    try w.writeBool(false); // useOverrideColor
    try w.writeU32(0); // overrideColor, ignored by the remove branch
    try w.writeBool(false); // usingLocalizationId
    try w.writeI32(entity_id);
    return w.written();
}

test "nav object add body layout" {
    // No test covered this builder. Two strings, then a Vector3 whose three
    // words nothing read back, then a run of flags around a packed colour.
    var buf: [128]u8 = undefined;
    const body = try buildNavObjectAdd(&buf, "quest", "Trader Jen", 11, 12, 13, 106);
    var r: binary.Reader = .{ .data = body };
    var s_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("quest", try r.readString(&s_buf));
    try std.testing.expectEqualStrings("Trader Jen", try r.readString(&s_buf));
    try std.testing.expectEqual(@as(f32, 11), try r.readF32());
    try std.testing.expectEqual(@as(f32, 12), try r.readF32());
    try std.testing.expectEqual(@as(f32, 13), try r.readF32());
    try std.testing.expectEqual(true, try r.readBool()); // isAdd
    try std.testing.expectEqual(false, try r.readBool()); // useOverrideColor
    try std.testing.expectEqual(@as(u32, 0xffffffff), try r.readU32()); // colour
    try std.testing.expectEqual(false, try r.readBool()); // usingLocalizationId
    try std.testing.expectEqual(@as(i32, 106), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "nav object remove body is the same shape with isAdd clear" {
    // The stock remove form still writes every field; only the client branch
    // reads entityId. A body that omitted the leading strings/position would
    // desync the client's BinaryReader.
    var buf: [128]u8 = undefined;
    const body = try buildNavObjectRemove(&buf, 106);
    var r: binary.Reader = .{ .data = body };
    var s_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", try r.readString(&s_buf));
    try std.testing.expectEqualStrings("", try r.readString(&s_buf));
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(@as(f32, 0), try r.readF32());
    try std.testing.expectEqual(false, try r.readBool()); // isAdd
    try std.testing.expectEqual(false, try r.readBool()); // useOverrideColor
    _ = try r.readU32(); // colour, ignored by the remove branch
    try std.testing.expectEqual(false, try r.readBool()); // usingLocalizationId
    try std.testing.expectEqual(@as(i32, 106), try r.readI32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}
