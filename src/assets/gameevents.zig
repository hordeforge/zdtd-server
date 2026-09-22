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
    /// `SpawnEntity`: spawn a stock entity group near the player (the
    /// church-bell horde: SleeperGSList x4, aggressive, 10-20 m).
    spawn_entity,
    /// `RageZombies`: alert nearby zombies and scale chase speed (bell phase 2).
    rage_zombies,
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
    // SpawnEntity
    entity_group: []const u8 = "",
    spawn_count: u8 = 0,
    min_distance: f32 = 0,
    max_distance: f32 = 0,
    aggressive: bool = false,
    /// RageZombies `speed_percent` (1.5 on the church bell).
    speed_percent: f32 = 1,
};

pub const Sequence = struct {
    name: []const u8,
    actions: []const Action = &.{},
    /// False when the sequence holds an element this server cannot execute.
    /// The runner refuses the whole sequence (`runGameEventSequence`).
    supported: bool = true,
    /// Sequence-level `RandomRoll` gate (church-bell `block_bell_spawn` is
    /// LTE 99 on 0..100). Evaluated at run; other sequence requirements still
    /// refuse the whole sequence.
    has_random_roll: bool = false,
    roll_min: f32 = 0,
    roll_max: f32 = 100,
    roll_op: CmpOp = .lte,
    roll_value: f32 = 0,
};

pub const Table = struct {
    sequences: []const Sequence = &.{},
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    arena_ptr: ?*std.heap.ArenaAllocator = null,

    pub fn empty() Table {
        return .{};
    }

    pub fn deinit(self: *Table) void {
        arena_util.destroyHolder(&self.arena_ptr);
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
    if (std.mem.eql(u8, name, "SpawnEntity")) return .spawn_entity;
    if (std.mem.eql(u8, name, "RageZombies")) return .rage_zombies;
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
        .remove_death_buffs, .add_buff, .spawn_entity, .rage_zombies => false,
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

/// Walk sequence-level `<requirement>` elements (outside `<action>` bodies).
/// RandomRoll is recorded for the runner; any other class returns false so the
/// sequence is refused. Nested action requirements are skipped.
fn absorbSequenceRequirements(
    body: []const u8,
    has_roll: *bool,
    roll_min: *f32,
    roll_max: *f32,
    roll_op: *CmpOp,
    roll_value: *f32,
) bool {
    var p: usize = 0;
    while (p < body.len) {
        const ri = std.mem.findPos(u8, body, p, "<requirement") orelse break;
        // Skip requirements nested inside an action (AddBuff CVar gate).
        if (insideAction(body, ri)) {
            p = ri + 12;
            continue;
        }
        const rclass = xml.attr(body, ri, "class") orelse return false;
        if (!std.mem.eql(u8, rclass, "RandomRoll")) return false;
        const rgt = std.mem.findPos(u8, body, ri, ">") orelse return false;
        const self_closing = rgt > ri and body[rgt - 1] == '/';
        const rend = if (self_closing) rgt else (std.mem.findPos(u8, body, rgt, "</requirement>") orelse return false);
        const rbody: []const u8 = if (self_closing) "" else body[rgt + 1 .. rend];
        const mm = xml.propertyValue(rbody, "min_max") orelse "0,100";
        var it = std.mem.splitScalar(u8, mm, ',');
        const lo = xml.parseF32(std.mem.trim(u8, it.next() orelse "0", " \t")) orelse 0;
        const hi = xml.parseF32(std.mem.trim(u8, it.next() orelse "0", " \t")) orelse 0;
        has_roll.* = true;
        roll_min.* = lo;
        roll_max.* = hi;
        roll_op.* = cmpOf(xml.propertyValue(rbody, "operation") orelse "LTE");
        roll_value.* = if (xml.propertyValue(rbody, "value")) |v| xml.parseF32(v) orelse 0 else 0;
        if (roll_op.* == .unknown) return false;
        p = rend + 1;
    }
    return true;
}

fn insideAction(body: []const u8, pos: usize) bool {
    // Walk backward for the nearest `<action` / `</action>` open count.
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < pos) {
        if (std.mem.startsWith(u8, body[i..], "<action ")) {
            depth += 1;
            i += 8;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "</action>")) {
            depth -= 1;
            i += 9;
            continue;
        }
        i += 1;
    }
    return depth > 0;
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

    var list: std.ArrayList(Sequence) = .empty;
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

        var acts: std.ArrayList(Action) = .empty;
        var supported = true;
        var p: usize = 0;
        while (p < body.len) {
            const ai = std.mem.findPos(u8, body, p, "<action ") orelse break;
            // Sequence-level requirements are parsed after the action walk
            // (RandomRoll is modelled; other classes refuse). Do not refuse
            // here or the church-bell gate would never stay supported.
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
                .spawn_entity => {
                    a.entity_group = try arena.dupe(u8, xml.propertyValue(abody, "entity_group") orelse "");
                    if (a.entity_group.len == 0) supported = false;
                    if (xml.propertyValue(abody, "spawn_count")) |v| {
                        const sv: u32 = @trunc(@min(xml.parseF32(v) orelse 0, 64));
                        a.spawn_count = @intCast(sv);
                    }
                    a.min_distance = if (xml.propertyValue(abody, "min_distance")) |v| xml.parseF32(v) orelse 0 else 0;
                    a.max_distance = if (xml.propertyValue(abody, "max_distance")) |v| xml.parseF32(v) orelse 0 else 0;
                    // The bell's spawn is aggressive (WanderingHorde); keep the
                    // flag on the action for the runner.
                    if (xml.propertyValue(abody, "is_aggressive")) |v| {
                        a.aggressive = v.len > 0 and (v[0] == 't' or v[0] == 'T' or v[0] == '1');
                    }
                    if (a.max_distance <= 0) supported = false;
                },
                .rage_zombies => {
                    a.speed_percent = if (xml.propertyValue(abody, "speed_percent")) |v|
                        xml.parseF32(v) orelse 1
                    else
                        1;
                    // `time` is stock's duration; zdtd applies the scale once
                    // (no timed un-rage column yet). Missing beats a fake timer.
                },
            }
            try acts.append(arena, a);
            p = aend + 1;
        }
        var has_random_roll = false;
        var roll_min: f32 = 0;
        var roll_max: f32 = 100;
        var roll_op: CmpOp = .lte;
        var roll_value: f32 = 0;
        // Sequence-level `<requirement>` before/between actions: RandomRoll is
        // modelled (church-bell gate); any other class refuses the sequence.
        if (!absorbSequenceRequirements(body, &has_random_roll, &roll_min, &roll_max, &roll_op, &roll_value)) {
            supported = false;
        }
        // A gate anywhere in the sequence (or in its property block) means the
        // action list is conditional: refuse rather than run it unconditionally.
        if (std.mem.findPos(u8, body, 0, "<decision ") != null) supported = false;

        const kn = try arena.dupe(u8, name);
        const acts_slice = try arena.dupe(Action, acts.items);
        try list.append(allocator, .{
            .name = kn,
            .actions = acts_slice,
            .supported = supported,
            .has_random_roll = has_random_roll,
            .roll_min = roll_min,
            .roll_max = roll_max,
            .roll_op = roll_op,
            .roll_value = roll_value,
        });
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

