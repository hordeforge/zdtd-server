//! gameevents.xml action sequences: the server-executable subset.
//!
//! Stock's `GameEventManager` runs a named `<action_sequence>` of `<action>`
//! elements. The death and respawn flows trigger two families of them:
//! `EntityPlayer.HandleClientDeath` selects `game_on_death_*` and the client's
//! `PlayerMoveController.updateRespawn` (IL=1215) selects `game_on_respawn_*`
//! by the DeathPenalty stat - and on a client that call only builds
//! `NetPackageGameEventRequest` (`GameEventManager::HandleActionClient` IL=416
//! calls `SendToServer` and returns), so the SERVER is what actually executes
//! the sequence (`HandleAction` server branch, IL_006B). zdtd therefore has to
//! read the data instead of hardcoding respawn stats.
//!
//! Only the action classes these sequences need and a dedicated server can
//! express are modelled. A sequence containing anything else - a `<decision>`
//! gate, `<action class="RemoveItems">`, `<action class="AddStartingItems">` -
//! is marked unsupported and refused whole: running a subset would invent
//! behaviour the XML does not describe (missing beats fake).

const std = @import("std");
const arena_util = @import("../util/arena.zig");
const xml = @import("xml_util.zig");
const io_fs = @import("../util/io_fs.zig");
const paths = @import("paths.zig");

pub const Stat = enum { food, water, health, stamina, unknown };

/// `ModifyEntityStat` operation: `SetMax` (the stat's current maximum) or `Set`
/// (the literal value, or `value` x max when `is_percent`).
pub const StatOp = enum { set, set_max };

pub const CmpOp = enum { gt, gte, lt, lte, equals, not_equals, unknown };

pub const Class = enum {
    modify_entity_stat,
    remove_death_buffs,
    add_buff,
    modify_cvar,
    /// `AddXPDeficit`: the death penalty deficit is earned by the dead client
    /// itself (passive 0x61), which the server drives with a ClientSequenceAction
    /// response; server-side it is a no-op, so the sequence stays runnable.
    add_xp_deficit,
    /// `RemoveItems` / `AddStartingItems`: item actions extend
    /// `ActionBaseClientAction` and only implement `OnClientPerform`
    /// (ActionBaseItemAction IL=5, ActionAddStartingItems IL=5), so the server's
    /// leg is the ClientSequenceAction response - the client removes or grants
    /// its own stack.
    remove_items,
    add_starting_items,
    /// `AddItems`: same client-performed shape (`ActionAddItems::OnClientPerform`
    /// only; Dentist silver/gold grant a nugget). Server leg is the response.
    add_items,
};

pub const Action = struct {
    class: Class,
    // ModifyEntityStat
    stat: Stat = .unknown,
    op: StatOp = .set,
    value: f32 = 0,
    is_percent: bool = false,
    // AddBuff
    buff_name: []const u8 = "",
    // RemoveDeathBuffs
    exclude_tags: []const u8 = "",
    // ModifyCVar
    cvar: []const u8 = "",
    cvar_op: []const u8 = "",
    // CVar requirement (AddBuff)
    req_cvar: []const u8 = "",
    req_op: CmpOp = .unknown,
    req_value: f32 = 0,
    has_requirement: bool = false,
};

pub const Sequence = struct {
    name: []const u8,
    actions: []const Action = &.{},
    /// False when the sequence holds an element this server cannot execute.
    /// The runner refuses the whole sequence (`runGameEventSequence`).
    supported: bool = true,
};

pub const Table = struct {
    sequences: []const Sequence = &.{},
    by_name: std.StringHashMapUnmanaged(u32) = .{},
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        if (self.arena_ptr) |ap| {
            const child = ap.child_allocator;
            ap.deinit();
            child.destroy(ap);
            self.arena_ptr = null;
        }
        self.* = .{};
    }

    pub fn find(self: *const Table, name: []const u8) ?*const Sequence {
        const i = self.by_name.get(name) orelse return null;
        return &self.sequences[i];
    }
};

fn statOf(name: []const u8) Stat {
    if (std.ascii.eqlIgnoreCase(name, "Food")) return .food;
    if (std.ascii.eqlIgnoreCase(name, "Water")) return .water;
    if (std.ascii.eqlIgnoreCase(name, "Health")) return .health;
    if (std.ascii.eqlIgnoreCase(name, "Stamina")) return .stamina;
    return .unknown;
}

fn classOf(name: []const u8) ?Class {
    if (std.mem.eql(u8, name, "ModifyEntityStat")) return .modify_entity_stat;
    if (std.mem.eql(u8, name, "RemoveDeathBuffs")) return .remove_death_buffs;
    if (std.mem.eql(u8, name, "AddBuff")) return .add_buff;
    if (std.mem.eql(u8, name, "ModifyCVar")) return .modify_cvar;
    if (std.mem.eql(u8, name, "AddXPDeficit")) return .add_xp_deficit;
    if (std.mem.eql(u8, name, "RemoveItems")) return .remove_items;
    if (std.mem.eql(u8, name, "AddStartingItems")) return .add_starting_items;
    if (std.mem.eql(u8, name, "AddItems")) return .add_items;
    return null;
}

/// True when the action's real work happens on the client
/// (`ActionBaseClientAction` descendants: the server sends the
/// ClientSequenceAction and the client runs `OnClientPerform`). The
/// `ActionBaseTargetAction` legs (RemoveDeathBuffs, AddBuff) are the ones this
/// server executes itself.
pub fn isClientAction(c: Class) bool {
    return switch (c) {
        .modify_entity_stat, .modify_cvar, .add_xp_deficit, .remove_items, .add_starting_items, .add_items => true,
        .remove_death_buffs, .add_buff => false,
    };
}

fn cmpOf(name: []const u8) CmpOp {
    if (std.mem.eql(u8, name, "GT")) return .gt;
    if (std.mem.eql(u8, name, "GTE")) return .gte;
    if (std.mem.eql(u8, name, "LT")) return .lt;
    if (std.mem.eql(u8, name, "LTE")) return .lte;
    if (std.mem.eql(u8, name, "Equals")) return .equals;
    if (std.mem.eql(u8, name, "NotEquals")) return .not_equals;
    return .unknown;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
    const clean = try xml.readCleanFile(allocator, path);
    defer allocator.free(clean);

    const arena_holder = try arena_util.newArenaHolder(allocator);
    errdefer {
        arena_holder.deinit();
        allocator.destroy(arena_holder);
    }
    const arena = arena_holder.allocator();

    var t: Table = .{};
    t.arena_ptr = arena_holder;
    errdefer t.deinit();

    var list: std.ArrayListUnmanaged(Sequence) = .empty;
    var i: usize = 0;
    while (i < clean.len) {
        const si = std.mem.findPos(u8, clean, i, "<action_sequence ") orelse break;
        const name = xml.attr(clean, si, "name") orelse {
            i = si + 17;
            continue;
        };
        const gt = std.mem.findPos(u8, clean, si, ">") orelse break;
        if (gt > si and clean[gt - 1] == '/') {
            i = gt + 1;
            continue; // self-closing: no actions
        }
        const close = std.mem.findPos(u8, clean, gt, "</action_sequence>") orelse break;
        const body = clean[gt + 1 .. close];

        var acts: std.ArrayListUnmanaged(Action) = .empty;
        var supported = true;
        var p: usize = 0;
        var last_end: usize = 0;
        while (p < body.len) {
            const ai = std.mem.findPos(u8, body, p, "<action ") orelse break;
            // A sequence-level `<requirement>` gates the whole sequence: this
            // runner does not evaluate those, so it refuses the sequence
            // instead of running the actions unconditionally.
            if (std.mem.findPos(u8, body[p..ai], 0, "<requirement") != null) supported = false;
            const agt = std.mem.findPos(u8, body, ai, ">") orelse break;
            const self_closing = agt > ai and body[agt - 1] == '/';
            const aend = if (self_closing)
                agt
            else
                std.mem.findPos(u8, body, agt, "</action>") orelse gt;
            // `<action class="X" />` has no body; a body action's properties
            // live between `>` and `</action>`.
            const abody: []const u8 = if (self_closing) "" else body[agt + 1 .. aend];
            const cls_name = xml.attr(body, ai, "class") orelse {
                supported = false;
                p = aend + 1;
                continue;
            };
            const cls = classOf(cls_name) orelse {
                // An action class this server does not execute: the sequence
                // refuses whole (no partial application).
                supported = false;
                p = aend + 1;
                continue;
            };
            // Per-action requirements: only the AddBuff CVar gate is modelled
            // (below); anything else makes the action conditional and the
            // sequence is refused.
            if (cls != .add_buff and std.mem.findPos(u8, abody, 0, "<requirement") != null) {
                supported = false;
            }
            var a = Action{ .class = cls };
            switch (cls) {
                .modify_entity_stat => {
                    a.stat = statOf(xml.propertyValue(abody, "stat") orelse "");
                    if (a.stat == .unknown) supported = false;
                    // Only the two operations that converge when both the
                    // server and the client leg apply them: stock performs a
                    // client action on the server too (ActionBaseClientAction
                    // IL=50 sends the response and leaves OnServerPerform to the
                    // subclass), so an Add/Subtract here would land twice.
                    const op = xml.propertyValue(abody, "operation") orelse "Set";
                    if (std.ascii.eqlIgnoreCase(op, "SetMax")) {
                        a.op = .set_max;
                    } else if (std.ascii.eqlIgnoreCase(op, "Set")) {
                        a.op = .set;
                    } else {
                        supported = false;
                    }
                    a.value = if (xml.propertyValue(abody, "value")) |v| xml.parseF32(v) orelse 0 else 0;
                    if (xml.propertyValue(abody, "is_percent")) |b| {
                        a.is_percent = b.len > 0 and (b[0] == 't' or b[0] == 'T' or b[0] == '1');
                    }
                },
                .remove_death_buffs => {
                    if (xml.propertyValue(abody, "exclude_tags")) |v| a.exclude_tags = try arena.dupe(u8, v);
                },
                .add_buff => {
                    a.buff_name = try arena.dupe(u8, xml.propertyValue(abody, "buff_name") orelse "");
                    if (a.buff_name.len == 0) supported = false;
                    // <requirement class="CVar"> ... </requirement>
                    if (std.mem.findPos(u8, abody, 0, "<requirement ")) |ri| {
                        const rgt = std.mem.findPos(u8, abody, ri, ">") orelse abody.len;
                        const rend = std.mem.findPos(u8, abody, rgt, "</requirement>") orelse abody.len;
                        const rbody = abody[rgt + 1 .. rend];
                        const rclass = xml.attr(abody, ri, "class") orelse "";
                        if (!std.mem.eql(u8, rclass, "CVar")) {
                            supported = false; // only the CVar gate is modelled
                        } else {
                            a.has_requirement = true;
                            a.req_cvar = try arena.dupe(u8, xml.propertyValue(rbody, "cvar") orelse "");
                            a.req_op = cmpOf(xml.propertyValue(rbody, "operation") orelse "");
                            a.req_value = if (xml.propertyValue(rbody, "value")) |v| xml.parseF32(v) orelse 0 else 0;
                            if (a.req_cvar.len == 0 or a.req_op == .unknown) supported = false;
                        }
                    }
                },
                .add_xp_deficit, .remove_items, .add_starting_items, .add_items => {},
                .modify_cvar => {
                    a.cvar = try arena.dupe(u8, xml.propertyValue(abody, "cvar") orelse "");
                    a.cvar_op = try arena.dupe(u8, xml.propertyValue(abody, "operation") orelse "");
                    a.value = if (xml.propertyValue(abody, "value")) |v| xml.parseF32(v) orelse 0 else 0;
                    if (a.cvar.len == 0 or a.cvar_op.len == 0) supported = false;
                },
            }
            try acts.append(arena, a);
            p = aend + 1;
            last_end = aend + 1;
        }
        if (last_end < body.len and std.mem.findPos(u8, body[last_end..], 0, "<requirement") != null) {
            supported = false;
        }
        // A gate anywhere in the sequence (or in its property block) means the
        // action list is conditional: refuse rather than run it unconditionally.
        if (std.mem.findPos(u8, body, 0, "<decision ") != null) supported = false;

        const kn = try arena.dupe(u8, name);
        const acts_slice = try arena.dupe(Action, acts.items);
        try list.append(allocator, .{ .name = kn, .actions = acts_slice, .supported = supported });
        i = close + 18;
    }

    t.sequences = try arena.dupe(Sequence, list.items);
    for (t.sequences, 0..) |*sq, idx| {
        try t.by_name.put(arena, sq.name, @intCast(idx));
    }
    list.deinit(allocator);
    return t;
}

pub fn tryLoad(allocator: std.mem.Allocator, game_dir: ?[]const u8, config_dir: ?[]const u8) !?Table {
    return paths.tryLoadConfig("gameevents.xml", Table, loadFromPath, allocator, game_dir, config_dir);
}

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
    const p = "/home/maci/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server/Data/Config/gameevents.xml";
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
