# Buffs and passive effects

This subsystem owns the runtime state of every active buff on an entity: the per-entity `BuffSet`, the add, stack, tick and expiry rules, the buff catalog parsed from stock `Data/Config/buffs.xml`, the two wire bodies that carry buff state to a client, and the fold that turns the passive rows of a buff, perk or attribute into tracked stat deltas. `ecs/buff.zig` states its own boundary in its header: it is pure over `BuffSet`, with no `World` and no wire (`src/ecs/buff.zig:1`), so the tick loop reports removals through the value types `Removed` and `Expiry` instead of importing a package builder. The catalog loader lives in `assets/buffs.zig`, the codec in `wire/stock_buff.zig`, and the C2S request path, the observer relay and the rejoin bundle in `server/game/social.zig`. Import direction is enforced: `ecs` may import `util` only (`src/ecs/root.zig:3`), `assets` may import `util` and pure `ecs` types (`src/assets/root.zig:3`), `wire` may import `util`, `assets`, `ecs` shapes and `world` domain types (`src/wire/root.zig:3`), and `server` sits on top of all of them (`src/server/root.zig:3`). The client ticks its own copy of the same buff, so the rules here mirror stock `EntityBuffs` and `BuffClass` rather than approximating them; a deviation moves the HUD icon and its timer to a different moment than the server believes (`src/ecs/buff.zig:2`).

Sources: [`src/ecs/buff.zig`](../../src/ecs/buff.zig), [`src/ecs/components.zig`](../../src/ecs/components.zig), [`src/ecs/systems.zig`](../../src/ecs/systems.zig), [`src/ecs/schedule.zig`](../../src/ecs/schedule.zig), [`src/assets/buffs.zig`](../../src/assets/buffs.zig), [`src/assets/passive_effects.zig`](../../src/assets/passive_effects.zig), [`src/assets/progression.zig`](../../src/assets/progression.zig), [`src/wire/stock_buff.zig`](../../src/wire/stock_buff.zig), [`src/server/game/social.zig`](../../src/server/game/social.zig), [`src/server/game/tick.zig`](../../src/server/game/tick.zig), [`src/server/c2s/quest.zig`](../../src/server/c2s/quest.zig).

## Runtime state and its bounds

The buff clock is 20 ticks per second, matching the component comment that a deviation expires HUD timers at the wrong moment (`src/ecs/components.zig:1253`), and one entity carries at most 32 concurrent buffs (`src/ecs/components.zig:1263`). The cap is a zdtd bound, not a stock rule: stock's `ActiveBuffs` list is unbounded, while a fixed set keeps the component plain data and bounds what one client can push at the server (`src/ecs/components.zig:1255`). One entry copies the class fields the tick needs at add time, because stock reads them off a shared `BuffClass` that `set_DurationMax` mutates process-wide, a behavior the sim refuses to model (`src/ecs/components.zig:1287`):

```zig
pub const BuffInstance = struct {
    active: bool = false,
    /// Index into the buffs.xml catalog (assets/buffs.Table.byId).
    def_id: u16 = 0,
    /// BuffValue::.ctor starts at 1; Effect stacking increments (asm.il 733486).
    stack_mult: u8 = 1,
    flags: BuffFlags = .{},
    duration_ticks: u32 = 0,
    update_ticks: u16 = 0,
    update_rate_ticks: i32 = 20,
    /// BuffClass::DurationMax in seconds; <= 0 never expires (asm.il 732754).
    duration_max: f32 = 0,
    remove_on_death: bool = true,
    instigator_id: i32 = -1,
    instigator_x: i32 = 0,
    instigator_y: i32 = 0,
    instigator_z: i32 = 0,
```

The flags byte is wire-visible: `BuffValue::Write` emits it verbatim, so the bit order is pinned by the stock layout (`src/ecs/components.zig:1270`).

```zig
pub const BuffFlags = packed struct(u8) {
    started: bool = false,
    finished: bool = false,
    remove: bool = false,
    update: bool = false,
    invalid: bool = false,
    paused: bool = false,
    /// The buff's own `onSelfBuffStart` rows have run (once per instance, fired
    /// by the survival pass because stock runs them from AddBuff).
    start_fired: bool = false,
    /// The buff's `onSelfEnteredGame` rows have run (once per instance; stock
    /// fires the event when the entity enters the game).
    entered_game_fired: bool = false,
};
```

The six stock bits are the ones the tick switch reads; the last two are bookkeeping for the triggered-row pass and never cross the wire (`src/ecs/components.zig:1279`). The set itself is one flat array with a linear lookup and a count (`src/ecs/components.zig:1315`):

```zig
pub const BuffSet = struct {
    slots: [max_buffs_per_entity]BuffInstance = [_]BuffInstance{.{}} ** max_buffs_per_entity,

    pub fn find(self: *BuffSet, def_id: u16) ?*BuffInstance {
        for (&self.slots) |*s| {
            if (s.active and s.def_id == def_id) return s;
        }
        return null;
    }

    pub fn findFree(self: *BuffSet) ?*BuffInstance {
        for (&self.slots) |*s| {
            if (!s.active) return s;
        }
        return null;
    }
```

## Add, stack, expiry

`add` follows stock `EntityBuffs::AddBuff` with the client-only gates left out: immunity, editor, `RequiredGameStat` and the friendly-fire check are deliberately absent (`src/ecs/buff.zig:38`). Its input carries only the class fields the tick reads (`src/ecs/buff.zig:19`):

```zig
pub const Def = struct {
    def_id: u16,
    /// BuffClass::InitialDurationMax in seconds; <= 0 never expires.
    duration: f32 = 0,
    stack_type: StackType = .ignore,
    update_rate_ticks: i32 = 20,
    remove_on_death: bool = true,
};
```

When the buff is already active, the stack type decides what happens instead of a second instance: `ignore` clears a pending removal and leaves the timer alone, `duration` extends by whatever is left floored at the class duration, `effect` increments the stack multiplier with a saturating add, and `replace` restarts the timer (`src/ecs/buff.zig:54`). A new instance takes the first free slot or reports `no_slot` (`src/ecs/buff.zig:29`, `:72`). A wire duration of `-1` means "use the buff's own class duration" (`src/ecs/buff.zig:17`), and the server always sends `-1` because any value at or above zero retunes the client's shared `BuffClass` for every entity for the rest of the session (`src/wire/stock_buff.zig:87`). `remove` only sets the removal flag; the next tick does the deleting, as stock does (`src/ecs/buff.zig:92`).

The tick runs the stock order in one pass: drop invalid instances, raise `remove` from `finished`, fire and delete flagged removals, skip paused and dead entities, mark `started` on the first live tick, advance the duration, then expire at `DurationMax` (`src/ecs/buff.zig:118`).

```zig
pub fn tick(set: *BuffSet, dead: bool, out: []Removed) u8 {
    var n: u8 = 0;
    for (&set.slots) |*e| {
        if (!e.active) continue;
        if (e.flags.invalid) {
            e.* = .{};
            continue;
        }
        if (e.flags.finished) e.flags.remove = true;
        if (e.flags.remove) {
            if (n < out.len) {
                out[n] = .{ .def_id = e.def_id };
                n += 1;
            }
            e.* = .{};
            continue;
        }
        if (e.flags.paused) continue;
        if (dead) continue;
        e.flags.started = true;
        durationTick(e);
        // BuffClass::Tick (asm.il 732754): DurationMax <= 0 never expires.
        if (e.duration_max > 0 and e.durationSeconds() >= e.duration_max) e.flags.finished = true;
```

Both counters advance with wrapping addition because stock's unchecked add wraps, so saturating here would diverge (`src/ecs/buff.zig:152`). The `update` flag is set and cleared inside the same tick from the class update rate; with no triggered-effect evaluator in the tick, it is only ever observed clear (`src/ecs/buff.zig:145`). `durationSeconds` divides the tick count by the 20 Hz buff clock (`src/ecs/components.zig:1309`). Death clears the buffs the client drops on its own, and each cleared one is reported so the net layer can relay the removal; a removal the clients never hear about leaves the icon on their HUD forever (`src/ecs/buff.zig:163`).

## The buff phase in the tick

The schedule names the buffs phase directly before the director and AI, because movement and damage must read this tick's buff state (`src/ecs/schedule.zig:12`, enum at `src/ecs/schedule.zig:10`):

```zig
pub const Phase = enum(u8) {
    begin,
    /// Before ai so movement and damage read this tick's buff state.
    buffs,
```

The phase order is pinned by a test and a mode pack may disable an entry through `w.rules.systems.<name>` but never reorder one, because the order encodes the dependency (`src/ecs/schedule.zig:67`). The buff slot in the run order is the first entry (`src/ecs/schedule.zig:76`). `run` calls the system only when the toggle is on, so a disabled system leaves its slice of the tick result zero rather than running a stub (`src/ecs/schedule.zig:83`). The system walks the alive bitset, skips entities without the buffs component mask, and treats an entity whose health reached zero as dead, which skips the started and duration half of the tick (`src/ecs/systems.zig:3676`, `:3684`):

```zig
pub fn systemBuffs(w: *World, out: []buff.Expiry) u8 {
    var n: u8 = 0;
    var removed: [c.max_buffs_per_entity]buff.Removed = undefined;
    var it = w.alive_bits.iterator(.{});
    while (it.next()) |idx| {
```

Removals land in a 16-entry result buffer on the tick result (`src/ecs/schedule.zig:56`, `:129`). The step drains that buffer after the sim tick and broadcasts one `AddRemoveBuff` per expiry with `adding = false`, so every observer drops the icon (`src/server/game/step.zig:372`, `src/server/game/social.zig:148`). A tick that removes more than 16 buffs still clears all of them; only the report saturates, matching the saturating report inside `tick` (`src/ecs/buff.zig:169`).

## Catalog shape from buffs.xml

`assets/buffs.zig` parses the catalog into a `Table` and never touches an entity. Each buff keeps its class fields, its tag list, its passive rows, its stat mods, its stat thresholds and its bounded triggered surface (`src/assets/buffs.zig:200`):

```zig
pub const BuffDef = struct {
    name: []const u8 = "",
    /// BuffClass::InitialDurationMax in seconds; <= 0 never expires (asm.il 732754).
    duration: f32 = 0,
    stack_type: StackType = .ignore,
    update_rate_ticks: i32 = default_update_rate_ticks,
    /// BuffClass::RemoveOnDeath (asm.il 1371585), default true per .ctor.
    remove_on_death: bool = true,
```

The caps are zdtd bounds measured against the stock file, not stock rules: 2048 buff defs against 483 stock definitions, 32 passive rows per buff against a maximum of 26 on `buffShocked`, and separate totals for stat mods and thresholds (`src/assets/buffs.zig:14`, `:19`, `:22`). Loading goes through `loadFromPath` into one arena (`src/assets/buffs.zig:687`), and the table keeps a lowercased name index next to the def list because stock's `BuffManager.Buffs` is a case-insensitive dictionary, so lookup must ignore case (`src/assets/buffs.zig:240`, `:262`). `byId` is the indexed accessor the sim uses; `byName` resolves a wire string (`src/assets/buffs.zig:274`, `:279`). With no XML the table falls back to five verbatim stock buffs, and the comment forbids inventing names there because the client resolves them against its own file (`src/assets/buffs.zig:220`). `passive_effects.zig` is a different artifact: it is the generated ordinal table for the stock `PassiveEffects` enum, the numeric id an `ItemValue` stat entry carries on the wire, 204 members including the `Count` sentinel (`src/assets/passive_effects.zig:1`, `:10`). It is the numbering, not the evaluator.

## The perk and attribute passive path

The passive effects that reach gameplay are folded into one POD of tracked stats: the four survival maxima, their change over time, the two injury blockage caps and the three damage resistances (`src/assets/buffs.zig:993`):

```zig
pub const TrackedDeltas = struct {
    hp_max: f32 = 0,
    hp_ot: f32 = 0,
    food_max: f32 = 0,
    food_ot: f32 = 0,
    water_max: f32 = 0,
    water_ot: f32 = 0,
    stamina_max: f32 = 0,
    stamina_ot: f32 = 0,
```

Rows outside that surface are counted but not simulated, which the file states as recorded rather than guessed (`src/assets/buffs.zig:990`). Every delta is clamped to a named ceiling, 1e6 for finite values, with NaN folding to zero, so a pathological modded curve cannot reach the tick's integer casts (`src/assets/buffs.zig:1059`). The fold over an entity's active buffs is recomputation, not incremental state, so removing a buff drops its contribution exactly (`src/assets/buffs.zig:1358`):

```zig
pub fn effectTotals(t: *const Table, set: *const components.BuffSet, ctx: requirements.Ctx, counts: *requirements.Counts) TrackedDeltas {
    var out: TrackedDeltas = .{};
    for (&set.slots) |*slot| {
        if (!slot.active) continue;
        if (t.byId(slot.def_id)) |def| {
            addDeltas(&out, trackedDeltas(&def, slot.durationSeconds(), ctx, counts));
        }
    }
    return out;
}
```

Perk and attribute levels take the same route: `trackedDeltasAtLevel` folds a progression value's passive rows at the purchased level, curve segment `i` applying at level `i + 1`, gated by the row requirements, and `perkTotals` sums that over the player's skill ledger (`src/assets/progression.zig:235`, `:265`). The consumers add buff, perk and item contributions into one delta before applying it: a stamina regeneration pass computes `effectTotals` for the active buffs plus `perkTotals` for the ledger plus the held and equipped item rows (`src/server/game/tick.zig:851`). Named multiplicative passives leave the additive surface and use a separate chained fold, which is how `BuffResistance` is read from the active set (`src/assets/buffs.zig:1374`, `src/server/game/tick.zig:330`).

What is incomplete is the triggered-effects virtual machine, and `docs/GAP_ANALYSIS.md` scores the perk and attribute passive-effects row as the one PARTIAL entry in Player progression, with the requirement vocabulary and the foreign-target kinds as the named shortfall (`docs/GAP_ANALYSIS.md:3689`). In this repository the bounded action set is evaluated for the tracked stats; every other action rides item, combat, weather or Twitch triggers and has no server-side consumer, which the same row records. `BuffDef.triggered` keeps the parsed rows, and the buff lifecycle consumes only the actions it implements (`src/assets/buffs.zig:215`).

## Wire bodies and the C2S path

Three shapes cross the wire. The `EntityBuffs` blob is a version byte, a `u16` count, one `BuffValue` per active buff, then a `u16` cvar count with string and `f32` pairs; zdtd holds no cvars, so that section is written empty, which the file argues is a legal output of stock's own filter rather than a shape stock never emits (`src/wire/stock_buff.zig:49`). One `BuffValue` is exactly the sim's instance fields (`src/wire/stock_buff.zig:23`):

```zig
pub const BuffValueWire = struct {
    name: []const u8,
    /// BuffValue::.ctor starts this at 1 (asm.il 733486), not 0.
    stack_mult: u8 = 1,
    duration_ticks: u32 = 0,
    instigator_id: i32 = -1,
    flags: u8 = 0,
    update_ticks: u16 = 0,
    instigator_x: i32 = 0,
    instigator_y: i32 = 0,
    instigator_z: i32 = 0,
};
```

The blob is version 3; version 2 wrote `updateTicks` as a byte and had no instigator position, and v3 is the only version zdtd emits (`src/wire/stock_buff.zig:9`). `writeEntityBuffs` builds it into the caller's buffer, and `buildEntityStatsBuffBody` wraps it as an entity id, a length and the bytes for `NetPackageEntityStatsBuff`, which is unreliable in stock and applied only to remote entities (`src/wire/stock_buff.zig:60`, `:69`). The direct path is `NetPackageAddRemoveBuff`, which is reliable and the only server-to-client package that touches a client's own buffs (`src/wire/stock_buff.zig:80`):

```zig
pub const AddRemoveBuff = struct {
    entity_id: i32,
    /// Slice into the caller's name buffer.
    name: []const u8,
    /// -1 means "use the client's own BuffClass duration". Any value >= 0 calls
    /// BuffClass::set_DurationMax (asm.il 736259 IL_00cf / IL_0246), which
    /// retunes the SHARED BuffClass for every entity on that client for the rest
    /// of the session. The server always sends -1.
    duration: f32,
    adding: bool,
    instigator_id: i32,
    instigator_x: i32,
    instigator_y: i32,
    instigator_z: i32,
};
```

`parseAddRemoveBuff` reads the same order off untrusted input, bounds-checking every field and capping the name through the caller's buffer (`src/wire/stock_buff.zig:113`). The C2S route is registered with the other social packages in the quest-domain handler, then delegated to `handleAddRemoveBuff` (`src/server/c2s/quest.zig:366`, `:374`). That handler parses the body, rejects a malformed one and a body whose entity id is not the sender's, increments the buff-reject counter, then resolves the name through the catalog and refuses an unknown name rather than inventing a def (`src/server/game/social.zig:15`, `:20`, `:25`). A successful add or remove is relayed to every other peer through one function, which is also the single place the server applies, drops or clears a buff, so hooking it gives an observer the whole set rather than the one path that happened to be wired (`src/server/game/social.zig:121`, `:136`).

Two rejoin paths exist because the player data file's buff section is written empty in the fresh form. `sendBuffSync` sends a `NetPackageEntityStatsBuff` per other player with a non-empty blob (`src/server/game/social.zig:54`), and `sendOwnBuffs` sends one adding `AddRemoveBuff` per active buff of the joining player, without which the client's icons vanish on rejoin even though the server kept the state (`src/server/game/social.zig:93`). Both build from the same instance fields, and the wire tests assert the encoder against hand-built byte arrays taken from the client IL rather than against the decoder, which is what pins the field order (`src/wire/stock_buff.zig:135`, `:147`).

## See also

- [`ecs.md`](ecs.md): the SoA world, the component masks and the buffs column this set lives in.
- [`tick.md`](tick.md): the full phase order and the tick result the expiry buffer travels in.
- [`wire.md`](wire.md): the binary helpers and how a body becomes a framed package.
- [`c2s.md`](c2s.md): the dispatch order and the phase gate the buff request passes through.
- [`inventory.md`](inventory.md): the item passive rows folded into the same tracked deltas.
