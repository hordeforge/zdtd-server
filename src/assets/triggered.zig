//! Triggered-effect rows: Trigger/TriggeredAction/Triggered shapes,
//! TriggeredResult outcome, and the row evaluator (gates, document-order
//! cvar writes, AddBuff/RemoveBuff/ModifyStats/CallGameEvent/GiveExp).
//!
//! Split out of buffs.zig (same code, moved verbatim); re-exported
//! through the buffs facade so existing `assets_buffs.Trigger` call
//! sites keep working.

const std = @import("std");
const requirements = @import("requirements.zig");
const cvars = @import("cvars.zig");
const buffs = @import("buffs.zig");
// Row element shapes owned by buffs.zig (Passive/StatMod/Op live with the
// passive VM and the loader that fills them):
const StatMod = buffs.StatMod;
const Op = buffs.Op;
const Table = buffs.Table;

/// Triggered rows per buff and in total (the onSelf* surface; only
/// ModifyStats/AddHealth/AddBuff/RemoveBuff/AddOrRemoveBuff/ModifyCVar/RemoveCVar
/// are evaluated - the other actions are recorded and skipped).
/// Measured against V3.2.0 `Data/Config` (2026-09-11): `buffStatusCheck02`
/// carries the most triggered rows at 126, then `buffFarmerSetBonus` 78 and
/// `buffStatusCheck01` 70; the file totals 3246. The old cap of 32 silently
/// dropped 94 of check02's rows, which is why the armor-set bonus rows never
/// parsed.
pub const max_triggered_per_buff: usize = 256;
pub const max_triggered_total: usize = 8192;

/// Stock onSelf* trigger names. `finish`/`stack` exist in the enum but have no
/// test: nothing in src evaluates one yet, so a row carrying either parses and
/// goes nowhere. Same fail-closed rule as every unhandled trigger; the row
/// stays in the table so a later engine change can consume it without
/// re-parsing.
pub const Trigger = enum(u8) {
    start,
    update,
    remove,
    entered_game,
    first_spawn,
    /// `onSelfProgressionUpdate`: fired when a progression value (perk,
    /// attribute, book) changes. progression.xml's `perkIntellectMastery` rows
    /// write `$perkBookwormChance` here, which the loot RandomRoll gates read.
    progression_update,
    /// `onPerkLevelChanged`: fired when a perk level is purchased (the 4
    /// `perkIntellectMastery` point-chance cvar rows).
    perk_level_changed,
    /// `onOtherAttackedSelf`: fired on the victim when another entity lands
    /// a hit (concussion/fatigue counters, PackMule display buff).
    other_attacked_self,
    /// `onSelfKilledOther`: fired on the killer's buffs and purchased
    /// perk/book rows when one of its hits kills (DeadEye/Berserker adds,
    /// stamina/health ModifyStats refunds).
    killed_other,
    /// `onSelfAttackedOther`: fired on the attacker when a hit lands
    /// (HitLocation-gated perk/buff rows: headshot/leg procs).
    self_attacked_other,
    /// `onSelfBuffFinish`: stock fires it when a buff's duration ends, after
    /// `onSelfBuffRemove` (87 buffs / 120 rows: stat restores, cvar clears,
    /// cooldown Adds, all currently inert).
    finish,
    /// `onSelfBuffStack`: stock fires it when AddBuff lands on an instance
    /// that is already active (42 buffs / 93 rows, mostly ModifyCVar chains
    /// like `buffHarvest`'s `$buffHarvestBonus`).
    stack,
    /// `onSelfLeaveGame`: fired on disconnect (storm/harvest/smell cleanup
    /// removes, debug-buff self-removes). Evaluated in the session-drop path
    /// before the entity is destroyed.
    leave_game,
    /// `onSelfDied`: fired on player death (infectionCounter set,
    /// aim/draw-buff removes). Evaluated in the hp-replicate death path
    /// before the game_on_death sequence runs.
    died,
    /// `onSelfPrimaryActionEnd`: fired when an eaten item's use ends; the
    /// consumable grants land here (beer/caffeine stamina buffs, drug
    /// water/DR buffs, goldenrod dysentery cure, medical buffProcessConsumables).
    /// Fired by the eat path, not the C2S damage/hit events.
    primary_action_end,
    /// `onSelfPrimaryActionRayHit`: fired when a ranged primary shot resolves
    /// a hit (DeepCuts/perception bleed-on-shot rows). The ranged hit path
    /// fires it; the C2S damage claim does not distinguish melee/ranged, so
    /// the held weapon's `ranged` tag selects it.
    primary_action_ray_hit,
    /// `onSelfDamagedOther`: fired when a landed hit applies its damage
    /// (Agility leg-cripple, Physician euthanizer on the stun baton). Fired
    /// alongside the attack event on the same C2S hit.
    self_damaged_other,
    /// `onOtherDamagedSelf`: fired on the victim when a landed hit applies
    /// damage from another entity (BarBrawling's rage on taking a fist hit).
    /// Fired alongside the victim's `other_attacked_self` path.
    other_damaged_self,
    /// `onCombatEntered`: fired on the out-of-combat -> in-combat transition
    /// (Enforcer Criminal Pursuit / Batter Up Stealing Bases stamina buffs).
    combat_entered,
    /// `onSelfFallImpact`: fired when the player lands after a fall (the
    /// buffStatusCheck01 leg-injury rows, gated on `_fallSpeed`). Driven by
    /// the falling-damage claim (dtype "falling"), which carries the impact.
    fall_impact,
    /// `onSelfJump`: fired when the player's move helper starts a jump
    /// (stock EntityAlive.set_Jumping IL=46). The leg buffs' activity
    /// escalation (buffLegGetsWorse, $legHurtCounter) rides this; driven by
    /// the AliveFlags 0x0010 edge on the C2S flags word.
    jump,
    /// `onSelfRespawn`: fired after the player respawns (stock
    /// EntityPlayer respawn flow). One stock row: buffNearDeathProtection
    /// removes itself here. Driven by the respawn funnel after the check
    /// buffs are re-added.
    respawn,
    /// `onSelfAimingGunStart/Stop`: fired when the player starts/stops
    /// aiming a gun (AliveFlags 0x0004 edge). One stock add row:
    /// buffHoldBreathAiming01 on start (gated `holdBreathAiming` held tag);
    /// its own stop/died/entered-game/equip-start rows remove it.
    aim_start,
    aim_stop,
    /// `onSelfCrouch` / `onSelfStand`: fired on the crouch flag (0x0200)
    /// set/clear edges. Crouch adds buffCrouching (its start/update rows
    /// apply the screen effect); stand removes it.
    crouch,
    stand,
    /// `onSelfTeleported`: fired when the player is teleported (stock
    /// Entity teleport flow). One stock row: buffNearDeathProtection
    /// removes itself here. Currently unfired: no teleport path drives it.
    teleported,
    /// `onSelfDamagedBlock`: fired when the player damages a block (the check
    /// buff's church-bell spawn gate; TriggerHasTags reads the block's tags).
    block_damaged,
    /// `onSelfEquipStart` / `onSelfEquipStop`: fired when an equipment item
    /// is worn / removed (armor set marker buffs like buffRogueBoots, the
    /// boot fall-damage cvars, miner healing cvars). The server reconciles
    /// them per tick from the worn slots rather than tracking equip edges.
    equip_start,
    equip_stop,
    /// `onSelfEquipUpdate`: fired when a worn item's quality/mods change
    /// (tier-curved cvars like $enforcerBuffResistance index valueList by
    /// the item's quality). Same reconcile path as the equip edges.
    equip_update,
    /// `onReloadStart` / `onReloadStop`: fired around a weapon reload
    /// (the check buff grants buffReloadMovementPenalty while the held
    /// weapon carries `reloadPenalty`; the buff removes itself on stop).
    reload_start,
    reload_stop,
    other,
};

/// The bounded action set the engine evaluates.
pub const TriggeredAction = enum(u8) {
    modify_stats,
    add_buff,
    remove_buff,
    /// `MinEventActionAddOrRemoveBuff`: the row gates decide, pass adds,
    /// fail removes (weather/hazard toggles on `onSelfBuffUpdate`).
    add_or_remove_buff,
    /// `MinEventActionModifyCVar`: write one custom variable.
    modify_cvar,
    /// `MinEventActionRemoveCVar`: drop one.
    remove_cvar,
    /// `RemoveAllNegativeBuffs`: flag every active buff whose DamageType is
    /// set (near-death regen cure).
    remove_all_negative,
    /// `ResetProgression`: the respec consumable (Grandpa's Forgetting Elixir
    /// `reset_skills="true"`) refunds SkillPoints and clears perk/attribute
    /// levels to base. Recorded; the caller resets the player.
    reset_progression,
    /// `CallGameEvent`: run a gameevents.xml sequence by name
    /// (`MinEventActionCallGameEvent`; Dentist silver/gold grants).
    call_game_event,
    /// `GiveExp`: grant XP on the event (medical Physician-scaled rows,
    /// schematics/books flat rows). Gated per row; passing rows sum.
    give_exp,
    other,
};

/// One `<triggered_effect trigger=... action=...>` row with its nested
/// `<requirement>` children (stock reads them into the row's own
/// RequirementGroup, checked before the action runs).
pub const Triggered = struct {
    trigger: Trigger = .other,
    action: TriggeredAction = .other,
    /// ModifyStats target (case-insensitive compare like StatMod).
    stat: []const u8 = "",
    op: Op = .unknown,
    value: f32 = 0,
    /// AddBuff/RemoveBuff target.
    buff: []const u8 = "",
    /// `fireOneBuff="true"`: weighted single-pick over the comma `buff=` list
    /// (MinEventActionBuffModifierBase: GameRandom.RandomFloat walked against
    /// cumulative `buffWeights`; zombie-fist wound rows). Weights parsed into
    /// buff_weights; the caller picks one deterministically.
    fire_one_buff: bool = false,
    buff_weights: [16]f32 = .{0} ** 16,
    buff_weights_n: u8 = 0,
    /// `target="other"` on AddBuff/RemoveBuff rows: stock applies the buff
    /// to the event's other entity (victim-directed perk procs: shotgun
    /// stuns, cripples, bleeds) instead of self. `target="otherAOE"` rows
    /// apply to living entities within `range` of the other entity
    /// (SledgeSaga kill cripple); `target="selfAOE"` rows are recorded but
    /// not applied (admin RingOfFire only: no update-event range scan).
    target_other: bool = false,
    target_other_aoe: bool = false,
    /// `target="selfOtherPlayers"` on ModifyCVar/AddBuff rows: stock fans the
    /// row out to party/ally members (CharismaticNature level share + group
    /// buff). Parsed; the progression-update caller applies it.
    target_party: bool = false,
    /// `delay=` seconds on a row (stock `MinEventActionBase::Delay` runs the
    /// action through a coroutine; 21 kill-event stamina refunds carry 1.0).
    /// Parsed; the caller defers (0 = immediate).
    delay_s: f32 = 0,
    /// AoE range in metres (`range=`) and tag filter (`target_tags=`) for
    /// `target="otherAOE"` rows.
    aoe_range: f32 = 0,
    aoe_tags: []const u8 = "",
    /// CallGameEvent sequence name (`event=`); also reuses `buff` storage? No:
    /// a dedicated field keeps buff names and event names apart.
    game_event: []const u8 = "",
    /// ModifyCVar/RemoveCVar target (`cvar=`).
    cvar: []const u8 = "",
    /// ModifyCVar operation (`operation=`); `CVarOperation` defaults to set.
    cvar_op: cvars.Operation = .set,
    /// `value="@name"` on a ModifyCVar row: the operand is read from the
    /// entity's custom variable at apply time (`MinEventActionModifyCVar`'s
    /// `cvarRef`), not from `value`.
    value_cvar: []const u8 = "",
    /// Level-curved ModifyCVar `value="a,b,c"`: `Execute` indexes
    /// valueList[CalculatedLevel-1] when the event carries the row's
    /// ProgressionValue (spear-hunter metabolism curves). value_list_n = the
    /// parsed segment count; 0 = plain scalar.
    value_list: [16]f32 = .{0} ** 16,
    value_list_n: u8 = 0,
    /// The row's direct `<requirement>` children, evaluated by the shared
    /// evaluator (empty = ungated).
    reqs: []const requirements.Requirement = &.{},
};

/// One `<requirement name="StatComparePercCurrentToMax" .../>` gate. Stock
/// compares a **fraction of max**, not an absolute 0..100 value.
pub fn parseTrigger(s: []const u8) Trigger {
    if (std.mem.eql(u8, s, "onSelfBuffStart")) return .start;
    if (std.mem.eql(u8, s, "onSelfBuffUpdate")) return .update;
    if (std.mem.eql(u8, s, "onSelfBuffRemove")) return .remove;
    if (std.mem.eql(u8, s, "onSelfEnteredGame")) return .entered_game;
    if (std.mem.eql(u8, s, "onSelfFirstSpawn")) return .first_spawn;
    if (std.mem.eql(u8, s, "onSelfProgressionUpdate")) return .progression_update;
    if (std.mem.eql(u8, s, "onPerkLevelChanged")) return .perk_level_changed;
    if (std.mem.eql(u8, s, "onOtherAttackedSelf")) return .other_attacked_self;
    if (std.mem.eql(u8, s, "onSelfKilledOther")) return .killed_other;
    if (std.mem.eql(u8, s, "onSelfAttackedOther")) return .self_attacked_other;
    if (std.mem.eql(u8, s, "onSelfBuffFinish")) return .finish;
    if (std.mem.eql(u8, s, "onSelfBuffStack")) return .stack;
    if (std.mem.eql(u8, s, "onSelfLeaveGame")) return .leave_game;
    if (std.mem.eql(u8, s, "onSelfDied")) return .died;
    if (std.mem.eql(u8, s, "onSelfPrimaryActionEnd")) return .primary_action_end;
    if (std.mem.eql(u8, s, "onSelfPrimaryActionRayHit")) return .primary_action_ray_hit;
    if (std.mem.eql(u8, s, "onSelfDamagedOther")) return .self_damaged_other;
    if (std.mem.eql(u8, s, "onOtherDamagedSelf")) return .other_damaged_self;
    if (std.mem.eql(u8, s, "onCombatEntered")) return .combat_entered;
    if (std.mem.eql(u8, s, "onSelfFallImpact")) return .fall_impact;
    if (std.mem.eql(u8, s, "onSelfJump")) return .jump;
    if (std.mem.eql(u8, s, "onSelfRespawn")) return .respawn;
    if (std.mem.eql(u8, s, "onSelfTeleported")) return .teleported;
    if (std.mem.eql(u8, s, "onSelfAimingGunStart")) return .aim_start;
    if (std.mem.eql(u8, s, "onSelfAimingGunStop")) return .aim_stop;
    if (std.mem.eql(u8, s, "onSelfCrouch")) return .crouch;
    if (std.mem.eql(u8, s, "onSelfCrouchRun")) return .crouch;
    if (std.mem.eql(u8, s, "onSelfCrouchWalk")) return .crouch;
    if (std.mem.eql(u8, s, "onSelfStand")) return .stand;
    if (std.mem.eql(u8, s, "onSelfDamagedBlock")) return .block_damaged;
    if (std.mem.eql(u8, s, "onSelfEquipStart")) return .equip_start;
    if (std.mem.eql(u8, s, "onSelfEquipStop")) return .equip_stop;
    if (std.mem.eql(u8, s, "onSelfEquipUpdate")) return .equip_update;
    if (std.mem.eql(u8, s, "onReloadStart")) return .reload_start;
    if (std.mem.eql(u8, s, "onReloadStop")) return .reload_stop;
    return .other;
}

pub fn parseTriggeredAction(s: []const u8) TriggeredAction {
    if (std.mem.eql(u8, s, "ModifyStats")) return .modify_stats;
    if (std.mem.eql(u8, s, "AddBuff")) return .add_buff;
    if (std.mem.eql(u8, s, "RemoveBuff")) return .remove_buff;
    if (std.mem.eql(u8, s, "AddOrRemoveBuff")) return .add_or_remove_buff;
    if (std.mem.eql(u8, s, "ModifyCVar")) return .modify_cvar;
    if (std.mem.eql(u8, s, "RemoveCVar")) return .remove_cvar;
    if (std.mem.eql(u8, s, "CallGameEvent")) return .call_game_event;
    if (std.mem.eql(u8, s, "RemoveAllNegativeBuffs")) return .remove_all_negative;
    if (std.mem.eql(u8, s, "ResetProgression")) return .reset_progression;
    if (std.mem.eql(u8, s, "GiveExp")) return .give_exp;
    return .other; // RefreshPerks is a no-op here: the passive fold reads skill_levels live.
}

/// Largest number of one action's rows any single stock buff fires for one
/// event (buffs.xml): AddBuff 16 and RemoveBuff 16 (buffStatusCheck02's
/// onSelfBuffUpdate armor-set rows), ModifyStats 1. Sized above the stock
/// maximum for modlet headroom; past a cap the request is dropped and counted
/// in `truncated` (never silently applied as a shorter list).
pub const max_triggered_adds = 24;
pub const max_triggered_removes = 24;
pub const max_triggered_mods = 8;

/// The engine's outcome for one buff event: the ModifyStats deltas and the
/// AddBuff/RemoveBuff requests. Bounded arrays; the caller owns the BuffSet
/// and the wire relay. `truncated` counts requests dropped past a cap so a
/// caller can surface the bound instead of losing them silently.
pub const TriggeredResult = struct {
    mods: [max_triggered_mods]StatMod = [_]StatMod{.{}} ** max_triggered_mods,
    mod_n: u8 = 0,
    add_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    remove_buffs: [max_triggered_removes][]const u8 = .{""} ** max_triggered_removes,
    add_n: u8 = 0,
    remove_n: u8 = 0,
    truncated: u8 = 0,
    /// Victim-directed adds (`target="other"`): parallel to add_buffs, same
    /// order. The caller applies these to the event's other entity.
    add_other_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_other_n: u8 = 0,
    /// fireOneBuff flags + weights per other add: the entry's comma list is a
    /// weighted single pick, not all.
    add_other_fireone: [max_triggered_adds]bool = .{false} ** max_triggered_adds,
    add_other_weights: [max_triggered_adds][16]f32 = .{.{0} ** 16} ** max_triggered_adds,
    add_other_weights_n: [max_triggered_adds]u8 = .{0} ** max_triggered_adds,
    /// Victim-directed removes, parallel to remove_buffs.
    remove_other_buffs: [max_triggered_removes][]const u8 = .{""} ** max_triggered_removes,
    remove_other_n: u8 = 0,
    /// AoE adds (`target="otherAOE"`): buff name + row range/tags per entry.
    /// The caller scans living entities around the event's other entity.
    add_aoe_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_aoe_range: [max_triggered_adds]f32 = .{0} ** max_triggered_adds,
    add_aoe_tags: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_aoe_n: u8 = 0,
    /// Party adds (`target="selfOtherPlayers"` AddBuff): buff names fanned out
    /// to party/ally members by the caller.
    add_party_buffs: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    add_party_n: u8 = 0,
    /// Party cvar writes (`target="selfOtherPlayers"` ModifyCVar): cvar + op
    /// + resolved value per entry, applied to each member's store.
    party_cvars: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    party_cvar_ops: [max_triggered_adds]cvars.Operation = .{.set} ** max_triggered_adds,
    party_cvar_vals: [max_triggered_adds]f32 = .{0} ** max_triggered_adds,
    party_cvar_n: u8 = 0,
    /// Game-event calls (`CallGameEvent`): sequence names the caller runs
    /// through the gameevents runner.
    game_events: [max_triggered_adds][]const u8 = .{""} ** max_triggered_adds,
    game_event_n: u8 = 0,
    /// Cure-all (`RemoveAllNegativeBuffs`): the caller flags every active
    /// buff whose DamageType is set.
    remove_all_negative: bool = false,
    /// Respec (`ResetProgression`): the caller refunds SkillPoints and clears
    /// perk/attribute levels to base.
    reset_progression: bool = false,
    /// XP (`GiveExp`): passing rows sum here; the caller awards the total
    /// through its XP ledger.
    give_exp: u32 = 0,
};

/// The triggered-effect engine: evaluate one buff's `onSelf*` rows for
/// `event`, gated by the row's own `<requirement>` children through the shared
/// evaluator (fail closed: a gate it cannot resolve refuses the row and is
/// counted). Unknown triggers/actions are skipped. Bounded: the result arrays
/// cap the outcome; no allocation.
pub fn evaluateTriggered(t: *const Table, def_id: u16, event: Trigger, ctx: requirements.Ctx, counts: *requirements.Counts) TriggeredResult {
    const def = t.byId(def_id) orelse return .{};
    return evaluateRows(def.triggered, event, ctx, counts);
}

/// Evaluate one row list for `event`. Shared by the buff engine (a buff's own
/// rows) and the progression engine (progression.xml's `perkIntellectMastery`
/// `onSelfProgressionUpdate` rows write `$perkBookwormChance`), so the row
/// semantics - gate, document-order cvar writes - live in one place.
pub fn evaluateRows(rows: []const Triggered, event: Trigger, ctx: requirements.Ctx, counts: *requirements.Counts) TriggeredResult {
    var out: TriggeredResult = .{};
    for (rows) |tr| {
        if (tr.trigger != event) continue;
        // `AddOrRemoveBuff` toggles on the gates: pass adds, fail removes.
        // Every other action runs only on pass.
        if (tr.action == .add_or_remove_buff) {
            if (tr.buff.len == 0) continue;
            const pass = tr.reqs.len == 0 or requirements.evaluate(tr.reqs, ctx, counts) == .pass;
            if (pass) {
                if (out.add_n >= out.add_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.add_buffs[out.add_n] = tr.buff;
                out.add_n += 1;
                if (ctx.sink) |sk| sk.add_buff(sk.ctx, tr.buff);
            } else {
                if (out.remove_n >= out.remove_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.remove_buffs[out.remove_n] = tr.buff;
                out.remove_n += 1;
                if (ctx.sink) |sk| sk.remove_buff(sk.ctx, tr.buff);
            }
            continue;
        }
        if (tr.reqs.len > 0 and requirements.evaluate(tr.reqs, ctx, counts) != .pass) continue;
        switch (tr.action) {
            .modify_stats => {
                if (tr.op == .unknown) continue;
                if (out.mod_n >= out.mods.len) {
                    out.truncated +|= 1;
                    continue;
                }
                // `value="@cvar"` resolves at execute time against the
                // holder's store (falling-damage @.impactSpeed); missing
                // reads 0 like GetCustomVar.
                const v = if (tr.value_cvar.len > 0) requirements.cvarValue(ctx, tr.value_cvar) else tr.value;
                out.mods[out.mod_n] = .{ .stat = tr.stat, .op = tr.op, .value = v, .target_other = tr.target_other, .delay_s = tr.delay_s };
                out.mod_n += 1;
            },
            .add_buff => {
                if (tr.buff.len == 0) continue;
                if (tr.target_party) {
                    // Party adds skip every sink: the caller fans them out to
                    // party/ally members (CharismaticNature group buff).
                    if (out.add_party_n >= out.add_party_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.add_party_buffs[out.add_party_n] = tr.buff;
                    out.add_party_n += 1;
                    continue;
                }
                if (tr.target_other_aoe) {
                    // AoE adds skip every sink: the caller fans them out over
                    // living entities in range (no victims on update events).
                    if (out.add_aoe_n >= out.add_aoe_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.add_aoe_buffs[out.add_aoe_n] = tr.buff;
                    out.add_aoe_range[out.add_aoe_n] = tr.aoe_range;
                    out.add_aoe_tags[out.add_aoe_n] = tr.aoe_tags;
                    out.add_aoe_n += 1;
                    continue;
                }
                if (tr.target_other) {
                    if (out.add_other_n >= out.add_other_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.add_other_buffs[out.add_other_n] = tr.buff;
                    out.add_other_fireone[out.add_other_n] = tr.fire_one_buff;
                    out.add_other_weights[out.add_other_n] = tr.buff_weights;
                    out.add_other_weights_n[out.add_other_n] = tr.buff_weights_n;
                    out.add_other_n += 1;
                    // Victim-directed adds skip the self sink: the caller
                    // applies them to the event's other entity. A fireOneBuff
                    // row skips the live sink too (the weighted single pick
                    // happens in the applier; the sink would apply all).
                    if (ctx.other_sink) |sk| {
                        if (!tr.fire_one_buff) sk.add_buff(sk.ctx, tr.buff);
                    }
                    continue;
                }
                if (out.add_n >= out.add_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.add_buffs[out.add_n] = tr.buff;
                out.add_n += 1;
                // Stock applies the add as the row passes, so a later row's
                // HasBuff gate (through the live lookup) sees it.
                if (ctx.sink) |sk| sk.add_buff(sk.ctx, tr.buff);
            },
            .remove_buff => {
                if (tr.buff.len == 0) continue;
                if (tr.target_other) {
                    if (out.remove_other_n >= out.remove_other_buffs.len) {
                        out.truncated +|= 1;
                        continue;
                    }
                    out.remove_other_buffs[out.remove_other_n] = tr.buff;
                    out.remove_other_n += 1;
                    if (ctx.other_sink) |sk| sk.remove_buff(sk.ctx, tr.buff);
                    continue;
                }
                if (out.remove_n >= out.remove_buffs.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.remove_buffs[out.remove_n] = tr.buff;
                out.remove_n += 1;
                if (ctx.sink) |sk| sk.remove_buff(sk.ctx, tr.buff);
            },
            .modify_cvar => {
                // Applied as the row is scanned, in document order, so a later
                // row's gate sees this write (check02's `.ArmorLightTotal` is
                // `set @.ArmorLightLevel` then `multiply @.ArmorLightWorn`).
                // `target="other"` writes go to the victim's store when the
                // event supplies one (player client stores, or the lazy
                // per-entity column for zombies/others).
                if (tr.target_other) {
                    if (ctx.other_cvars) |ostore| {
                        if (tr.cvar.len == 0) continue;
                        const v = if (tr.value_cvar.len > 0) ostore.get(tr.value_cvar) else tr.value;
                        _ = ostore.apply(tr.cvar, tr.cvar_op, v);
                    }
                    continue;
                }
                if (tr.target_party) {
                    // Party cvar writes record for the caller's fan-out; the
                    // self write still lands through the normal path below
                    // when a store exists (stock writes self too).
                    if (out.party_cvar_n < out.party_cvars.len and tr.cvar.len > 0) {
                        const self_store = ctx.cvars;
                        const v = if (tr.value_cvar.len > 0 and self_store != null) self_store.?.get(tr.value_cvar) else tr.value;
                        out.party_cvars[out.party_cvar_n] = tr.cvar;
                        out.party_cvar_ops[out.party_cvar_n] = tr.cvar_op;
                        out.party_cvar_vals[out.party_cvar_n] = v;
                        out.party_cvar_n += 1;
                    } else if (out.party_cvar_n >= out.party_cvars.len) {
                        out.truncated +|= 1;
                    }
                }
                const store = ctx.cvars orelse continue;
                if (tr.cvar.len == 0) continue;
                // A level-curved `value="a,b,c"` indexes valueList[level-1]
                // when the event carries the row's ProgressionValue (stock
                // Execute IL: CalculatedLevel); the progression-update caller
                // supplies the changing perk's level. Item-parent rows index
                // by the firing item's quality tier instead (minevents.md
                // Execute IL=154 scales valueList by item quality).
                const curve_level: u8 = ctx.item_level orelse ctx.progression_level orelse 1;
                const v = if (tr.value_list_n > 0 and tr.value_cvar.len == 0)
                    tr.value_list[@min(tr.value_list_n, @max(1, curve_level)) - 1]
                else if (tr.value_cvar.len > 0) store.get(tr.value_cvar) else tr.value;
                _ = store.apply(tr.cvar, tr.cvar_op, v);
            },
            .remove_cvar => {
                // Stock splits `cvar=` on commas into cvarNames (ParseXml IL=23);
                // every listed name is removed.
                if (tr.target_other) {
                    if (ctx.other_cvars) |ostore| {
                        if (tr.cvar.len == 0) continue;
                        var it = std.mem.splitScalar(u8, tr.cvar, ',');
                        while (it.next()) |seg| {
                            const name = std.mem.trim(u8, seg, " \t");
                            if (name.len == 0) continue;
                            _ = ostore.remove(name);
                        }
                    }
                    continue;
                }
                const store = ctx.cvars orelse continue;
                if (tr.cvar.len == 0) continue;
                var it = std.mem.splitScalar(u8, tr.cvar, ',');
                while (it.next()) |seg| {
                    const name = std.mem.trim(u8, seg, " \t");
                    if (name.len == 0) continue;
                    _ = store.remove(name);
                }
            },
            .call_game_event => {
                if (tr.game_event.len == 0) continue;
                if (out.game_event_n >= out.game_events.len) {
                    out.truncated +|= 1;
                    continue;
                }
                out.game_events[out.game_event_n] = tr.game_event;
                out.game_event_n += 1;
            },
            .remove_all_negative => {
                // Flagged in the result; the caller resolves DamageType
                // against its buff table (the engine has no table here).
                if (out.remove_all_negative) continue;
                out.remove_all_negative = true;
            },
            .reset_progression => {
                if (out.reset_progression) continue;
                out.reset_progression = true;
            },
            .give_exp => {
                // Gated rows sum: an ungated base row plus the owned tier's
                // gated row both land (bandage 10 + Physician bonus).
                out.give_exp +|= @trunc(@max(0, tr.value));
            },
            .add_or_remove_buff => unreachable, // handled above (toggle, not gate)
            .other => continue,
        }
    }
    return out;
}
