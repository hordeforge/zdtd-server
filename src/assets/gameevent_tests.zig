//! Game-event catalog tests: actions, respawn family.
//!
//! Split out of assets/gameevents.zig (same tests, moved verbatim).

const std = @import("std");
const gameevents = @import("gameevents.zig");
const CmpOp = gameevents.CmpOp;
const Stat = gameevents.Stat;
const StatOp = gameevents.StatOp;
const isClientAction = gameevents.isClientAction;
const loadFromPath = gameevents.loadFromPath;
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "gameevents respawn sequences parse into runnable actions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/gameevents.xml", .{dir});
    try io_fs.writeFile(path,
        \\<gameevents>
        \\  <action_sequence name="game_on_respawn_default">
        \\    <property name="allow_user_trigger" value="false" />
        \\    <action class="ModifyEntityStat">
        \\      <property name="stat" value="Food" />
        \\      <property name="operation" value="SetMax" />
        \\    </action>
        \\    <action class="ModifyEntityStat">
        \\      <property name="stat" value="Health" />
        \\      <property name="operation" value="SetMax" />
        \\    </action>
        \\  </action_sequence>
        \\  <action_sequence name="game_on_respawn_injured">
        \\    <action class="ModifyEntityStat">
        \\      <property name="stat" value="Food" />
        \\      <property name="value" value=".5" />
        \\      <property name="is_percent" value="true" />
        \\      <property name="operation" value="Set" />
        \\    </action>
        \\    <action class="AddBuff">
        \\      <property name="buff_name" value="buffInfectionCatch" />
        \\      <requirement class="CVar">
        \\        <property name="cvar" value="infectionCounterRespawn"/>
        \\        <property name="operation" value="GT" />
        \\        <property name="value" value="0" />
        \\      </requirement>
        \\    </action>
        \\  </action_sequence>
        \\  <action_sequence name="game_on_death_default">
        \\    <action class="AddXPDeficit" />
        \\    <action class="RemoveDeathBuffs" />
        \\  </action_sequence>
        \\  <action_sequence name="conditional">
        \\    <decision class="If">
        \\      <action class="RemoveDeathBuffs" />
        \\    </decision>
        \\  </action_sequence>
        \\</gameevents>
    );
    var t = try loadFromPath(std.testing.allocator, path);
    defer t.deinit();

    const dflt = t.find("game_on_respawn_default").?;
    try std.testing.expect(dflt.supported);
    try std.testing.expectEqual(@as(usize, 2), dflt.actions.len);
    try std.testing.expectEqual(Stat.food, dflt.actions[0].stat);
    try std.testing.expectEqual(StatOp.set_max, dflt.actions[0].op);
    try std.testing.expectEqual(Stat.health, dflt.actions[1].stat);

    const injured = t.find("game_on_respawn_injured").?;
    try std.testing.expect(injured.supported);
    try std.testing.expectEqual(Stat.food, injured.actions[0].stat);
    try std.testing.expectEqual(StatOp.set, injured.actions[0].op);
    try std.testing.expect(injured.actions[0].is_percent);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), injured.actions[0].value, 0.0001);
    const buff = injured.actions[1];
    try std.testing.expectEqualStrings("buffInfectionCatch", buff.buff_name);
    try std.testing.expect(buff.has_requirement);
    try std.testing.expectEqualStrings("infectionCounterRespawn", buff.req_cvar);
    try std.testing.expectEqual(CmpOp.gt, buff.req_op);

    // The death sequence is runnable: AddXPDeficit is the client's own action
    // and the server models it as a no-op, so its RemoveDeathBuffs half still
    // runs. The deficit action index rides the parsed order.
    const dd = t.find("game_on_death_default").?;
    try std.testing.expect(dd.supported);
    // A gate makes the action list conditional: also refused.
    try std.testing.expect(!t.find("conditional").?.supported);
    // Item actions are client legs: they carry no server work but the
    // sequence stays runnable (their ClientSequenceAction is the server leg).
    const items_src =
        \\<gameevents><action_sequence name="permanent">
        \\  <action class="RemoveItems">
        \\    <property name="items_location" value="Toolbelt,Backpack,Equipment,BiomeBadge" param1="itemlocation" />
        \\  </action>
        \\  <action class="RemoveDeathBuffs" />
        \\  <action class="AddStartingItems" />
        \\</action_sequence></gameevents>
    ;
    try io_fs.writeFile(path, items_src);
    var t3 = try loadFromPath(std.testing.allocator, path);
    defer t3.deinit();
    const perm = t3.find("permanent").?;
    try std.testing.expect(perm.supported);
    try std.testing.expectEqual(@as(usize, 3), perm.actions.len);
    try std.testing.expect(isClientAction(perm.actions[0].class));
    try std.testing.expect(!isClientAction(perm.actions[1].class));
    try std.testing.expect(isClientAction(perm.actions[2].class));
    try std.testing.expect(t.find("nope") == null);
}

test "stock gameevents.xml respawn family parses when present" {
    const p = stock_paths.configFile("gameevents.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    var t = try loadFromPath(std.testing.allocator, p);
    defer t.deinit();
    // All four respawn sequences now run: permanent's RemoveItems and
    // ModifyCVar legs are client actions (answered with a
    // ClientSequenceAction), RemoveDeathBuffs is the server leg.
    for ([_][]const u8{
        "game_on_respawn_none",
        "game_on_respawn_default",
        "game_on_respawn_injured",
        "game_on_respawn_permanent",
    }) |n| {
        const sq = t.find(n) orelse return error.TestUnexpectedResult;
        try std.testing.expect(sq.supported);
        try std.testing.expect(sq.actions.len > 0);
    }
    // The death family: none/default/injured run (RemoveDeathBuffs and, for the
    // first two, AddXPDeficit). `permanent` holds ResetMap/ResetPlayerData,
    // which this server does not implement, so it stays refused whole.
    for ([_][]const u8{ "game_on_death_none", "game_on_death_default", "game_on_death_injured" }) |n| {
        try std.testing.expect(t.find(n).?.supported);
    }
    try std.testing.expect(!t.find("game_on_death_permanent").?.supported);
}
