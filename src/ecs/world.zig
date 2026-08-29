//! ECS world: dense SoA columns, resources, O(1) net id map, spawn helpers.

const std = @import("std");
const rng_util = @import("../util/rng.zig");
const ent = @import("entity.zig");
const c = @import("components.zig");
const electric = @import("electric.zig");
const quest = @import("quest.zig");
const director = @import("aidirector.zig");
const rules_mod = @import("rules.zig");
const command = @import("command.zig");
const inv_ledger = @import("inv_ledger.zig");
const locals_mod = @import("locals.zig");
const group = @import("group.zig");
const poi_lock = @import("poi_lock.zig");
const path_mod = @import("path.zig");
const buff = @import("buff.zig");

pub const max_entities = ent.max_entities;
/// Soft capacity warning threshold (fraction of max_entities).
pub const warn_ratio: f32 = 0.8;
const entity_warn_at: usize = @trunc(@as(f32, @floatFromInt(max_entities)) * warn_ratio);
pub const InvLedger = inv_ledger.Ledger;
pub const InvCause = inv_ledger.Cause;
pub const Slot = ent.Slot;
pub const NetId = ent.NetId;
pub const Kind = c.Kind;
pub const Mask = c.Mask;

/// A host-side bot's world presence as seen by the zombie AI (ADR 0026).
/// Bots are NOT ECS entities; `bot_snap_fn` fills this from the BotManager.
/// `net_id < 0` means "no bot" (empty result).
pub const BotSnap = struct {
    net_id: i32 = -1,
    x: f32 = 0,
    z: f32 = 0,
    d2: f32 = 0,
};
pub const CommandBuffer = command.Buffer;
pub const CommandOp = command.Op;
pub const TickLocals = locals_mod.TickLocals;

/// Word-packed slot set whose `set`/`unset` are safe to call from pool worker
/// threads (parallel AI marks dirty bits for knockback displacement).
/// `std.StaticBitSet`'s plain word OR would tear when adjacent slot ranges
/// share a 64-bit word, so every word is a fetchOr/fetchAnd target. Only
/// set/unset ever run concurrently (workers); readers run on the tick thread
/// after the parallel pass joins, so monotonic ordering is sufficient.
pub const AtomicBits = struct {
    const words_n = (max_entities + 63) / 64;

    words: [words_n]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.{ .raw = 0 }} ** words_n,

    pub fn initEmpty() AtomicBits {
        return .{};
    }

    fn wordBit(index: usize) struct { word: usize, bit: u64 } {
        std.debug.assert(index < max_entities);
        return .{ .word = index >> 6, .bit = @as(u64, 1) << @as(u6, @truncate(index)) };
    }

    pub fn set(self: *AtomicBits, index: usize) void {
        const wb = wordBit(index);
        _ = self.words[wb.word].fetchOr(wb.bit, .monotonic);
    }

    pub fn unset(self: *AtomicBits, index: usize) void {
        const wb = wordBit(index);
        _ = self.words[wb.word].fetchAnd(~wb.bit, .monotonic);
    }

    pub fn isSet(self: *const AtomicBits, index: usize) bool {
        const wb = wordBit(index);
        return (self.words[wb.word].load(.monotonic) & wb.bit) != 0;
    }

    pub fn count(self: *const AtomicBits) usize {
        var total: usize = 0;
        for (&self.words) |*word| total += @popCount(word.load(.monotonic));
        return total;
    }

    /// Keep only slots also present in the StaticBitSet source. Main-thread
    /// use only (replicate intersects its candidate copy against `alive_bits`).
    /// Word-wise: the per-slot form ran `max_entities` atomic RMWs per tick.
    pub fn intersectFromStatic(self: *AtomicBits, src: std.StaticBitSet(max_entities)) void {
        for (&self.words, src.masks) |*w, m| _ = w.fetchAnd(m, .monotonic);
    }

    /// Replace contents with the StaticBitSet source. Main-thread use only
    /// (replicate's heartbeat pass seeds candidates from `alive_bits`).
    pub fn copyFromStatic(self: *AtomicBits, src: std.StaticBitSet(max_entities)) void {
        for (&self.words, src.masks) |*w, m| w.store(m, .monotonic);
    }

    pub const Iterator = struct {
        bits: *const AtomicBits,
        word: usize = 0,
        pending: u64 = 0,
        base: usize = 0,

        pub fn next(self: *Iterator) ?usize {
            while (self.pending == 0) {
                if (self.word >= words_n) return null;
                self.pending = self.bits.words[self.word].load(.monotonic);
                self.base = self.word << 6;
                self.word += 1;
            }
            const tz = @ctz(self.pending);
            self.pending &= self.pending - 1;
            return self.base + @as(usize, tz);
        }
    };

    pub fn iterator(self: *const AtomicBits, comptime opts: anytype) Iterator {
        _ = opts;
        return .{ .bits = self };
    }
};

/// Stock zombieTemplateMale SleeperSightToWakeMin/Max (entityclasses.xml):
/// the per-entity wake-threshold ROLL ranges used when a class carries no
/// sleeper wake props (offline table). RE entity-ai.md D8.6 step 5.
const sleeper_wake_near_min_default: f32 = -40.0;
const sleeper_wake_near_max_default: f32 = 5.0;
const sleeper_wake_far_min_default: f32 = 340.0;
const sleeper_wake_far_max_default: f32 = 480.0;

/// RE entity-ai.md 3318-3320 (CopyPropertiesFromEntityClass): the
/// MoveSpeedRand per-entity roll on the day chase speed. When the class has a
/// roll range and a day aggro value < 1, add the roll, clamp min 0.1 and cap
/// at the aggro max; stock rolls once per entity. Deterministic per spawn: a
/// hash of the position + class + a salt seeds the roll (the sim has no
/// ad-hoc RNG). A class with no MoveSpeedRand or no day aggro keeps the
/// unrolled value (the sim's 0 = fall-to-floor convention).
fn rollChaseDay(def: EntityClass, x: f32, z: f32) f32 {
    const day = def.chase_speed_day;
    if ((def.move_speed_rand_min == 0 and def.move_speed_rand_max == 0) or day <= 0 or day >= 1.0) return day;
    const h = std.hash.Wyhash.hash(0x5eed, std.mem.asBytes(&.{ x, z, @as(f32, @floatFromInt(def.hash)) }));
    const frac = @as(f32, @floatFromInt(h >> 32)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
    const roll = def.move_speed_rand_min + (def.move_speed_rand_max - def.move_speed_rand_min) * frac;
    var out = @max(day + roll, 0.1);
    if (def.chase_speed > 0) out = @min(out, def.chase_speed);
    return out;
}

pub const EntityClass = struct {
    /// Class name for logging/debug. Must point to static/indefinite-lifetime
    /// data (comptime literal or binary-embedded table). Never assign an
    /// arena/allocator-owned slice.
    name: []const u8 = "zombie",
    max_hp: f32 = 40,
    kind: Kind = .zombie,
    /// ECD wire class (Unity Mono GetHashCode). 0 = stock zombieBoe default at encode.
    hash: i32 = 0,
    /// Loot container name (LootDropEntityClass / LootListOnDeath); empty → default.
    /// Must point to static/indefinite-lifetime data (comptime literal or
    /// binary-embedded table). Never assign an arena/allocator-owned slice.
    loot_list: []const u8 = "",
    /// Chance a death drops the loot bag (entityclasses LootDropProb). 1.0 default.
    drop_prob: f32 = 1.0,
    /// XML MoveSpeedAggro max (night chase) scaled to sim m/s; 0 = use systems default.
    chase_speed: f32 = 0,
    /// XML MoveSpeedAggro min (day chase); 0 = falls to chase_speed then default.
    chase_speed_day: f32 = 0,
    /// XML MoveSpeed (day shamble) scaled; 0 = use systems default.
    wander_speed: f32 = 0,
    /// XML MoveSpeedNight (night shamble); 0 = falls to wander_speed then default.
    wander_speed_night: f32 = 0,
    /// entityclasses MoveSpeedRand "min,max" roll range (stock "-.2, .25");
    /// 0,0 = unset (no roll).
    move_speed_rand_min: f32 = 0,
    move_speed_rand_max: f32 = 0,
    /// HandItem Action0 DamageEntity from items.xml; 0 = use systems default.
    attack_damage: f32 = 0,
    /// HandItem DamageBlock from items.xml (per-class block chew: zombie 8,
    /// feral 24); 0 = use the Rules chew floor.
    block_chew: f32 = 0,
    /// HandItem melee reach (items.xml Range/MaxRange: zombie hand 1.6,
    /// club/axe 2.4); 0 = use the Rules attack-range floor.
    melee_range: f32 = 0,
    /// TimeStayAfterDeath seconds a corpse lingers (entityclasses.xml).
    time_stay: f32 = 0,
    /// entityclasses SightRange in metres; 0 = use the Rules sense floor.
    sight_range: f32 = 0,
    /// entityclasses SightLightThreshold "min,max" (stock "-2,150" on the
    /// zombie template; cctor default 30/100). 0,0 = use the Rules floor.
    sight_light_min: f32 = 0,
    sight_light_max: f32 = 0,
    /// entityclasses SleeperSightToWakeMin/Max roll ranges (stock "-40,5" /
    /// "340,480"); 0 = unset → the stock default ranges at spawn.
    sleeper_wake_near_min: f32 = 0,
    sleeper_wake_near_max: f32 = 0,
    sleeper_wake_far_min: f32 = 0,
    sleeper_wake_far_max: f32 = 0,
    /// entityclasses MaxViewAngle in degrees, full cone (stock default 180);
    /// the sense gate halves it. 0 = use the Rules cone floor.
    view_angle_deg: f32 = 0,
    /// entityclasses ExplodeHealthThreshold (Demolition prime); 0 = no
    /// explosion. ExplodeDelay seconds (0.5 default).
    explode_threshold: f32 = 0,
    explode_delay_s: f32 = 0.5,
    /// <property class="Explosion"> blast params, Extends-resolved (RE
    /// entity-ai.md §9.x): per-entity radius/damages; 0 = Rules floor. The
    /// DamageBonus category multipliers (parallel arrays) scale block damage
    /// by the block's materials.xml damage_category (stock cop: earth → 0).
    explosion_radius: f32 = 0,
    explosion_radius_e: f32 = 0,
    explosion_block_dmg: f32 = 0,
    explosion_entity_dmg: f32 = 0,
    explosion_bonus_cat: [4][]const u8 = .{ "", "", "", "" },
    explosion_bonus_mult: [4]f32 = .{ 1, 1, 1, 1 },
    explosion_bonus_n: u8 = 0,
    /// IsEnemyEntity (wolf/bear/coyote hunt; stag/rabbit flee). Defaults true
    /// for zombies; passive animals carry false.
    is_enemy: bool = true,
    /// Inherited AITask-* list contains an attack task (see assets/entities.zig
    /// resolvedAiAttacks): timid animals never attack even when a player is
    /// close. Defaults true (brainless classes keep the zombie behavior).
    ai_attack: bool = true,
    /// entityclasses ExperienceGain kill XP; 0 = use the caller's flat floor.
    xp_gain: f32 = 0,
};

pub const World = struct {
    const no_player_slot = std.math.maxInt(Slot);

    /// Monotonic sim tick (incremented in beginTick; the drain and systems
    /// read it for windowed flags like the ADR 0037 glide exemption).
    sim_tick: u64 = 0,

    alive: [max_entities]bool = .{false} ** max_entities,
    mask: [max_entities]Mask = [_]Mask{.{}} ** max_entities,

    transform: [max_entities]c.Transform = [_]c.Transform{.{}} ** max_entities,
    health: [max_entities]c.Health = [_]c.Health{.{}} ** max_entities,
    network_id: [max_entities]c.NetworkId = [_]c.NetworkId{.{}} ** max_entities,
    kind: [max_entities]c.Kind = [_]c.Kind{.zombie} ** max_entities,
    player: [max_entities]c.Player = [_]c.Player{.{}} ** max_entities,
    /// Per-player stealth-noise state (RE entity-ai.md PlayerStealth): the
    /// movement-noise volume model (sounds.xml noise table → NotifyNoise →
    /// CalcVolume → attraction/hearing). Only meaningful for .player slots.
    stealth: [max_entities]c.Stealth = [_]c.Stealth{.{}} ** max_entities,
    zombie_ai: [max_entities]c.ZombieAi = [_]c.ZombieAi{.{}} ** max_entities,
    /// Combat-noise ring (group AI): melee/ranged hits push events (atomic
    /// counter; parallel AI workers + the net thread), the AI consume pass
    /// alerts zombies and wakes sleepers and drains the ring. Cap + per-tick
    /// budget bound the pass so a busy fight cannot stall the tick.
    noise_events: [c.noise_events_cap]c.NoiseEvent = undefined,
    noise_n: usize = 0,
    /// Player movement-noise ring (stock AIDirector.NotifyNoise): the net
    /// thread resolves relayed NetPackageSoundAtPosition clips in the
    /// sounds.xml noise table and pushes rows; the stealth system consumes
    /// them (crouch muffle, stealth-list accumulation, sleeper wake at the
    /// volume cap, heat map). Consume-owns-drain like combat noise.
    stealth_noise_events: [c.stealth_events_cap]c.StealthNoiseEvent = undefined,
    stealth_noise_n: usize = 0,
    /// Day/night ambient light (0..1, slice-1 world-light model
    /// world/sky.zig ambientLuma): the Game computes it once per tick from the
    /// world clock before tickAll; the sim's stealth light legs
    /// (CanSleeperAttackDetect crouch range) read it. Tests set it directly.
    ambient_light: f32 = 0,
    /// Sleeper-volume wake requests by noise position (stock
    /// World.CheckSleeperVolumeNoise): pushed by the stealth system when a
    /// player's sleeperNoiseVolume hits the 360 cap; the Game drains the ring
    /// after the tick and wakes volumes whose AABB contains the point.
    sleeper_volume_noise: [c.stealth_events_cap]c.NoiseEvent = undefined,
    sleeper_volume_noise_n: usize = 0,
    /// Demolition explode requests (RE entity-ai.md): pushed by parallel AI
    /// workers when a primed cop's countdown hits zero; the Game drains the
    /// ring and applies entity + block AoE. Consume-owns-drain like noise.
    explode_reqs: [c.explode_cap]c.ExplodeRequest = undefined,
    explode_n: usize = 0,
    dig_reqs: [c.dig_cap]c.DigRequest = undefined,
    dig_n: usize = 0,
    /// Sleeper wake requests (RE EntityAlive.ConditionalTriggerSleeperWakeUp):
    /// pushed by the AI/proximity/noise/damage paths when a sleeper flips to
    /// awake; the Game drains the ring and broadcasts NetPackageSleeperWakeup.
    /// Consume-owns-drain like noise; parallel AI workers push atomically.
    sleeper_wake_reqs: [c.sleeper_wake_cap]c.SleeperWakeRequest = undefined,
    sleeper_wake_n: usize = 0,
    falling: [max_entities]c.FallingBlocks = [_]c.FallingBlocks{.{}} ** max_entities,
    vehicle: [max_entities]c.Vehicle = [_]c.Vehicle{.{}} ** max_entities,
    turret: [max_entities]c.Turret = [_]c.Turret{.{}} ** max_entities,
    trader_stock: [max_entities]c.TraderStock = [_]c.TraderStock{.{}} ** max_entities,
    /// Trader restock refill policy (zdtd.toml [sim] trader_restock_*): each
    /// restock grows stackable entries toward `trader_restock_cap` by at most
    /// `trader_restock_refill`. Bucket B (zdtd sim strategy, not stock data).
    trader_restock_cap: u16 = 50,
    trader_restock_refill: u16 = 10,
    /// Sim rule parameters (ADR 0021): combat/ai/bloodmoon tuning, overlaid
    /// from the mode pack and zdtd.toml by main.zig (Game sets this at init).
    rules: rules_mod.Rules = .{},
    journal: [max_entities]c.Journal = [_]c.Journal{.{}} ** max_entities,
    wallet: [max_entities]c.Wallet = [_]c.Wallet{.{}} ** max_entities,
    inventory: [max_entities]c.Inventory = [_]c.Inventory{.{}} ** max_entities,
    class_id: [max_entities]c.ClassId = [_]c.ClassId{.{}} ** max_entities,
    loot_bag: [max_entities]c.LootBag = [_]c.LootBag{.{}} ** max_entities,
    sleeper: [max_entities]c.Sleeper = [_]c.Sleeper{.{}} ** max_entities,
    /// Owning SleeperVolume index per entity (0 = not sleeper-spawned): the
    /// volume re-arm alive-count recount (stock SleeperVolume.ClearedUpdate).
    sleeper_vol: [max_entities]u16 = [_]u16{0} ** max_entities,
    flags: [max_entities]c.Flags = [_]c.Flags{.{}} ** max_entities,
    dirty: [max_entities]c.Dirty = [_]c.Dirty{.{}} ** max_entities,
    /// Lazily attached (see buffsMut): most entities never carry a buff, and
    /// spawnBase resets mask[s] wholesale, so a stale set can never be read.
    buffs: [max_entities]c.BuffSet = [_]c.BuffSet{.{}} ** max_entities,
    /// Buff-side PhysicalDamageResist percent summed over the entity's active
    /// buffs (the passive-effects VM, assets/buffs.zig effectTotals), refreshed
    /// by the survival tick. Feeds armorMitigation like stock
    /// GetTotalPhysicalArmorRating sums the wearer's passive 41.
    buff_phys_resist: [max_entities]f32 = [_]f32{0} ** max_entities,

    /// Peer slots are bounded by the server's fixed client table. Keeping the
    /// reverse index here avoids a full entity scan in every C2S inventory,
    /// quest, movement, and replication lookup.
    peer_to_player: [max_entities]Slot = .{no_player_slot} ** max_entities,

    next_net_id: i32 = 100,
    /// Live entity slots (spawnBase ++, destroy --). Soft-warn path only.
    entity_count: u16 = 0,
    /// Per-slot reincarnation counter (generation-counted handles).
    slot_gen: [max_entities]u32 = .{0} ** max_entities,
    /// Cached per-kind dense slot lists (spawnBase inserts, destroy removes),
    /// kept slot-ascending so group iteration equals the open View scan. Owns
    /// the per-kind live count too, so countKind is O(1) off the same fact.
    kind_groups: group.Groups = .{},
    /// Once: soft warning when entity_count crosses entity_warn_at.
    entity_cap_warned: bool = false,
    /// Slots freed since the last beginTick. allocSlot avoids these so a slot
    /// is never recycled within one tick: per-client known_entities is keyed
    /// by slot and only reconciled against alive[] once per tick, so same-tick
    /// reuse (destroy then spawnLootBag) would suppress the EntitySpawn.
    freed_this_tick: [max_entities]bool = .{false} ** max_entities,
    /// True when any destroy() ran since beginTick. Replicate skips the
    /// known_entities reconcile when no slots were freed this tick.
    any_freed_this_tick: bool = false,
    /// Live slots as one word-packed set, mirroring `alive[]`. Replication
    /// walks set bits instead of probing every slot, so an idle server pays
    /// for the entities it has, not for the slot table it was sized with.
    /// Owned by spawnBase / destroy / reviveSlot; never written elsewhere.
    alive_bits: std.StaticBitSet(max_entities) = std.StaticBitSet(max_entities).initEmpty(),
    /// Slots with at least one dirty bit set, derived from `dirty[]`. Lets the
    /// per-tick replicate pass build its candidate set and clear the motion
    /// bits in O(changed) rather than O(max_entities).
    dirty_bits: AtomicBits = AtomicBits.initEmpty(),
    /// O(1) NetId → Slot (0xFFFF = empty).
    net_to_slot: std.AutoHashMapUnmanaged(i32, Slot) = .empty,
    net_map_allocator: std.mem.Allocator = undefined,
    net_map_init: bool = false,
    /// Set when a net_to_slot insert failed (OOM): the map may be missing
    /// entries, so slotOfNetId must fall back to the SoA scan on miss.
    net_map_degraded: bool = false,

    catalog: quest.Catalog = quest.Catalog.builtin(),
    power: electric.PowerGrid = .{},
    director: director.Director = .{},
    /// Deferred ops drained once per tick (end of tickAll / Game.step). Cap 64.
    commands: CommandBuffer = .{},
    /// Named tick scratch (interest ids, despawn lists). Cleared in beginTick.
    locals: TickLocals = .{},
    /// P4 inv cause ring (last N mutations). Hot path: fixed, no heap.
    inv_ledger: InvLedger = .{},
    /// Zombie chase/wander speed multiplier from ZombieMove* serverconfig, set by
    /// the director each tick per day/night/blood-moon state (1.0 = sim default).
    zombie_speed_scale: f32 = 1.0,
    completed_quests: u32 = 0,
    /// One quest completed per sim call, drained by the Game at tick end for
    /// item and exp payout (the wallet coin credit happens inside the sim).
    /// Fixed ring: a pathological multi-completion tick drops the oldest.
    completed_quests_ring: [4]struct { slot: Slot, def_id: u16 } = undefined,
    completed_quests_n: u8 = 0,
    /// Monotonic stock-like Quest.QuestCode allocator (starts above catalog ids).
    next_quest_code: i32 = 10000,
    /// Quest POI lockouts (stock PrefabInstance.lockInstance), driven by the
    /// rally-marker and Lock/UnlockPOI quest events.
    poi_locks: poi_lock.Table = .{},

    /// Optional terrain-height hook backing vehicle physics. Game sets these to
    /// the block store; unset (null) means no terrain data (headless / tests) so
    /// physics is skipped and no fake flat floor is invented.
    ground_ctx: ?*anyopaque = null,
    ground_fn: ?*const fn (?*anyopaque, i32, i32) f32 = null,
    /// Optional one-cell move predicate for AI pathing: returns the feet Y the
    /// body would stand at in the destination column, or null when the move is
    /// blocked. Unset → open grid (tests / headless). Game wires
    /// world.standableWorld, which models step-up, drop and headroom; a plain
    /// solid-cell bool cannot (see path.StepFn).
    step_ctx: ?*anyopaque = null,
    step_fn: ?path_mod.StepFn = null,
    /// Optional block-solid probe (x, y, z) -> solid, backing the AI sense
    /// LOS ray (stock CanSee's Voxel.Raycast). Game wires the block store;
    /// unset (null) means no terrain data (headless / tests) so sight is
    /// unblocked.
    solid_ctx: ?*anyopaque = null,
    solid_fn: ?*const fn (?*anyopaque, i32, i32, i32) bool = null,
    /// Falling-block landing callback (Fall-event debris drops): the ECS
    /// has no block/item tables, so the Game rolls the landed cells'
    /// `<drop event="Fall">` rows (systemFallingBlocks fires it at contact,
    /// before the entity destroy).
    fall_land_ctx: ?*anyopaque = null,
    fall_land_fn: ?*const fn (?*anyopaque, []const c.FallingCell) void = null,
    /// Water probe (Game wires the store): true when the cell holds water.
    /// Lets the AI swim physics detect submersion (stock inWaterPercent).
    water_ctx: ?*anyopaque = null,
    water_fn: ?*const fn (?*anyopaque, i32, i32, i32) bool = null,
    /// Optional per-player smell radius (RE PlayerStealth cSmellRadius*):
    /// (ctx, player_slot) -> effective radius, so stateful players (bleeding,
    /// dysentery) attract zombies from further through walls. Game wires the
    /// buff table; unset (null) uses the Rules `smell_radius`.
    smell_ctx: ?*anyopaque = null,
    smell_fn: ?*const fn (?*anyopaque, Slot) f32 = null,
    /// A* replans issued this tick. Atomic: the AI phase runs on parallel
    /// workers. Cleared by beginTick and surfaced as TickResult.path_replans
    /// (ecs must not import apm; see the note on commands_applied).
    path_replans: std.atomic.Value(u32) = .init(0),
    /// Replans refused this tick by the per-tick node budget. Same lifetime and
    /// clearing as path_replans.
    path_replans_denied: std.atomic.Value(u32) = .init(0),
    /// Admission stride for the per-tick A* budget: a zombie may replan only on
    /// ticks where `(slot + path_tick) % path_stride == 0`. Derived once per
    /// tick on the main thread from last tick's demand, never from a shared
    /// countdown: the AI phase runs on parallel ranges, so an atomic budget
    /// would make chase paths depend on which worker got there first.
    path_stride: u32 = 1,
    /// Monotonic tick counter rotating the admission window so every slot gets
    /// its turn instead of the same ones always winning.
    path_tick: u32 = 0,
    /// Optional item_id → placeable block id (AssignIds). Null → inventory offline map.
    place_ctx: ?*anyopaque = null,
    place_fn: ?*const fn (?*anyopaque, u16) u16 = null,
    /// Optional stock item name → ECS id (ItemTable.ecsIdByName). Null → the
    /// spawnPlayer starter kit uses the offline builtin ids (8/2/7/6).
    item_id_ctx: ?*anyopaque = null,
    item_id_fn: ?*const fn (?*anyopaque, []const u8) u16 = null,
    /// Optional item_id → items.xml FuelValue (0 = not fuel). Game wires ItemTable.
    fuel_value_ctx: ?*anyopaque = null,
    fuel_value_fn: ?*const fn (?*anyopaque, u16) f32 = null,
    /// Optional → autoTurret block RequiredPower (maxdamage; stock 15 W).
    turret_watts_ctx: ?*anyopaque = null,
    turret_watts_fn: ?*const fn (?*anyopaque) f32 = null,
    /// Optional → placed-turret combat stats (blocks.xml autoTurret family:
    /// MaxDistance/EntityDamage/BurstFireRate/BurstRoundCount). Null → the
    /// component defaults (rule 15: stock data from the block table).
    turret_stats_ctx: ?*anyopaque = null,
    turret_stats_fn: ?*const fn (?*anyopaque) ?c.TurretBlockStats = null,
    /// Optional kind → vehicles.xml fuelTank capacity (0 = unset → the
    /// `[rules.vehicle] fuel_cap` floor). Game wires the vehicle table.
    vehicle_tank_ctx: ?*anyopaque = null,
    vehicle_tank_fn: ?*const fn (?*anyopaque, c.VehicleKind) f32 = null,
    /// Optional item_id → max stack (items.xml Stacknumber). Null → builtin_defs.
    stack_ctx: ?*anyopaque = null,
    stack_fn: ?*const fn (?*anyopaque, u16) u16 = null,
    /// Optional item_id → held-item light (items.xml LightValue, 0 = none).
    /// Feeds the PlayerStealth selfLight blend (rule 15).
    held_light_ctx: ?*anyopaque = null,
    held_light_fn: ?*const fn (?*anyopaque, u16) f32 = null,
    /// Optional item_id → armor? (name prefix armor*). Null → offline pin.
    is_armor_ctx: ?*anyopaque = null,
    is_armor_fn: ?*const fn (?*anyopaque, u16) bool = null,
    /// Equipped-armor PDR percent at the slot's quality (Game wires this
    /// from the items table; stock GetTotalPhysicalArmorRating sums passive
    /// 41 on the wearer). 0 = the item carries no row / not an armor item.
    armor_pdr_ctx: ?*anyopaque = null,
    armor_pdr_fn: ?*const fn (?*anyopaque, u16, u8) f32 = null,
    /// Held-item DegradationPerUse (per-use durability wear) and TargetArmor
    /// (armor penetration fraction) lookups (Game wires from the items table;
    /// 0 = the item carries no row -> caller defaults).
    item_degradation_ctx: ?*anyopaque = null,
    item_degradation_fn: ?*const fn (?*anyopaque, u16) f32 = null,
    item_penetration_ctx: ?*anyopaque = null,
    /// `peer_slot` = the attacker's client slot (null for AI/environment):
    /// perk-tag-gated TargetArmor rows apply only when the attacker owns the
    /// tagged perk.
    item_penetration_fn: ?*const fn (?*anyopaque, u16, ?usize) f32 = null,
    /// Optional kill verdict hook (T15 / ADR 0021 decision 4): (ctx, kind,
    /// victim_id, attacker_id) -> i32. Below 0 denies the death: the victim
    /// survives at 1 hp and the fatal hit's side effects (loot, corpse,
    /// respawn flow) are skipped. Game wires this to the Wasm host; unset =
    /// no plugins, today's behaviour exactly.
    kill_verdict_ctx: ?*anyopaque = null,
    kill_verdict_fn: ?*const fn (?*anyopaque, Kind, i32, i32) i32 = null,
    /// on_player_damage verdict for the ECS damage path (zombie melee /
    /// deferred accumulator): (ctx, victim_net_id, amount) -> i32. Below 0
    /// denies the hit (victim keeps hp), above 0 scales the applied amount by
    /// percent. The attacker is not tracked by the accumulator, so it reads
    /// -1 (unknown), matching kill_verdict. Game wires this to the Wasm host;
    /// unset = no plugins, today's behaviour exactly.
    player_damage_verdict_ctx: ?*anyopaque = null,
    player_damage_verdict_fn: ?*const fn (?*anyopaque, i32, f32) i32 = null,
    /// Server chat broadcast for plugin announcements (`zdtd.queue say`):
    /// (ctx, msg) -> void. Game wires this to the stock chat broadcast; unset
    /// = announcements are dropped (today's behaviour).
    say_ctx: ?*anyopaque = null,
    say_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    /// Called immediately before drainCommands applies queued ops. Game wires
    /// this to plugin-effect withdrawal so a disabled module's pending
    /// commands never execute (ADR 0030). Unset = drain as today.
    pre_drain_ctx: ?*anyopaque = null,
    pre_drain_fn: ?*const fn (?*anyopaque) void = null,
    /// Pre-trade price verdict (on_trade_price): (ctx, player_net, item, unit)
    /// -> i32. <0 denies the trade, 0 keeps the price, >0 scales the unit
    /// price by percent. Game wires this to the plugin + wasm host; unset =
    /// no plugins, today's behaviour exactly.
    trade_price_verdict_ctx: ?*anyopaque = null,
    trade_price_verdict_fn: ?*const fn (?*anyopaque, i32, u16, u32) i32 = null,
    /// Optional host-side bot snap for the zombie AI (ADR 0026). Bots are NOT
    /// ECS entities, so the AI asks the Game through this hook instead of a
    /// slot: `exact >= 0` resolves that one net id (any range — revenge);
    /// `exact < 0` returns the nearest live bot within `range_sq` of (zx, zz)
    /// (proximity aggro). Null hook → no bots (pure ECS server).
    bot_snap_ctx: ?*anyopaque = null,
    bot_snap_fn: ?*const fn (?*anyopaque, zx: f32, zz: f32, range_sq: f32, exact: i32) BotSnap = null,
    /// Optional zombie melee damage to a host-side bot (ADR 0026). Returns
    /// false when the bot is gone (the melee whiffs). Bots attribute the
    /// attacker and emit a damage event for the guest's retaliation.
    bot_damage_ctx: ?*anyopaque = null,
    bot_damage_fn: ?*const fn (?*anyopaque, bot_net: i32, attacker_net: i32, amount: f32) bool = null,
    /// Optional quest-accept gate (AGENTS rule 29, Wasm-first): (ctx,
    /// peer_slot, def_id) -> i32, <0 denies the accept. Game wires the plugin
    /// on_quest_accept verdict; unset = no plugins, today's behaviour.
    quest_accept_ctx: ?*anyopaque = null,
    quest_accept_fn: ?*const fn (?*anyopaque, peer_slot: i32, def_id: u16) i32 = null,
    /// Optional POI footprint at a world XZ (Game wires the prefabs index).
    /// Unset → no POI data (tests / headless), so quests get no POI rect and
    /// their rally objectives stay scaffolding instead of stalling.
    poi_ctx: ?*anyopaque = null,
    poi_fn: ?*const fn (?*anyopaque, f32, f32) ?c.PoiRect = null,
    /// Optional DifficultyTier (1..6) of the POI at a world XZ (Game wires
    /// the prefabs index + its quest metadata cache). 0 = no POI / no tier;
    /// feeds GetLootStage's POITierMod/Bonus.
    poi_tier_ctx: ?*anyopaque = null,
    poi_tier_fn: ?*const fn (?*anyopaque, f32, f32) u8 = null,
    /// Nearest quest-eligible POI to a world XZ (Game wires the prefabs index).
    /// Used to place goto/POI quests that have no static def position (stock
    /// RandomPOIGoto picks the POI when the quest is handed out). Unset → no
    /// POI data, so those quests fall back to their def marker position.
    nearest_poi_ctx: ?*anyopaque = null,
    nearest_poi_fn: ?*const fn (?*anyopaque, f32, f32) ?c.PoiRect = null,
    /// Stock quest-POI selector (DynamicPrefabDecorator.GetRandomPOI* /
    /// GetClosestPOIToWorldPos; Game wires the prefabs index + biome map +
    /// lockout state). Unset → no selection, callers fall back to nearestPoi /
    /// static positions (test worlds with no POI data).
    quest_poi_ctx: ?*anyopaque = null,
    quest_poi_fn: ?*const fn (?*anyopaque, quest.QuestPoiParams) ?quest.PoiSelect = null,
    /// "Are two entity ids in the same party?" (Game wires the Party manager).
    /// Quest POI lockout exempts party members (stock CheckForPOILockouts:
    /// a party member inside the POI does not block the rally). Unset → no
    /// party data, every other player blocks (pre-party behaviour).
    party_same_ctx: ?*anyopaque = null,
    party_same_fn: ?*const fn (?*anyopaque, i32, i32) bool = null,
    /// Quest POI lockout home reasons (stock CheckForPOILockouts): returns a
    /// bitmask of whether the entity's bedroll (1) or land claim (2) overlaps
    /// the POI at (x, z). Unset -> neither reason ever fires.
    home_ctx: ?*anyopaque = null,
    home_fn: ?*const fn (?*anyopaque, i32, f32, f32) u8 = null,
    /// ClearSleepers completion suppression (stock QuestEvent_SleepersCleared
    /// removes the POI's sleeper data): the Game marks the sleeper store so a
    /// cleared POI does not re-arm, even across a restart. Unset = no
    /// suppression (test worlds without sleeper data).
    quest_clear_ctx: ?*anyopaque = null,
    quest_clear_fn: ?*const fn (?*anyopaque, c.PoiRect) void = null,
    /// ObjectiveClearSleepers target: the POI's live sleeper population
    /// (stock counts the volume spawns at quest start). The Game hook sums
    /// the sleeper volumes intersecting the bound rect; unset/0 falls back to
    /// the def's required count (audit B25).
    quest_sleeper_count_ctx: ?*anyopaque = null,
    quest_sleeper_count_fn: ?*const fn (?*anyopaque, c.PoiRect) u16 = null,
    /// QuestActionSpawnGSEnemy: the Game spawns `count` gamestage-scaled
    /// enemies around the player on phase entry (stock SpawnQuestEntity:
    /// player position + random direction × (12 + rand*12) metres). Unset =
    /// action recorded but not fired (test worlds without gamestage data).
    quest_spawn_ctx: ?*anyopaque = null,
    quest_spawn_fn: ?*const fn (?*anyopaque, c.PoiRect, []const u8, u8, u8, f32, f32) void = null,
    /// Unit sell price for an item the trader does NOT stock (stock lets you
    /// sell any item: EconomicValue x EconomicSellScale x SellMarkdown, RE
    /// GetSellPrice). The Game resolves the per-trader markup; 0 = cannot
    /// sell (unset hook keeps the stocked-only restriction in test worlds).
    sell_price_ctx: ?*anyopaque = null,
    sell_price_fn: ?*const fn (?*anyopaque, item_id: u16, trader_slot: u16) u32 = null,
    /// Root traders.xml quality_mod lerp bounds (QL1 -> min, QL6 -> max),
    /// wired by the Game next to sell_price_fn for the non-stocked sell path.
    trader_quality_min_mod: f32 = 1,
    trader_quality_max_mod: f32 = 1,
    /// Stock ItemValue.PercentUsesLeft for a sold stack (RE
    /// ItemValue.get_PercentUsesLeft IL=17): the durability fraction the
    /// trader charges, so worn items sell for less. Wired by the Game from
    /// the items table (DegradationMax -> MaxUseTimes); 1 = not wired.
    percent_uses_left_ctx: ?*anyopaque = null,
    percent_uses_left_fn: ?*const fn (?*anyopaque, item_id: u16, quality: u8, use_times: f32) f32 = null,

    // A10: offline defaults use stock loot container name (not item "scrap").
    // Game.setClassDef overwrites from entityclasses when game-dir loads.
    class_table: [16]EntityClass = [_]EntityClass{
        .{ .name = "player", .max_hp = 100, .kind = .player, .hash = 2001454542 },
        .{ .name = "zombie", .max_hp = 40, .kind = .zombie, .hash = 948863590, .loot_list = "EntityLootContainerRegular" },
        // A40: the old "zombieFeral" builtin row was an invented class (0 hits
        // in stock entityclasses.xml; no stock group names it). Repointed to
        // the real feral variant zombieBoeFeral (Unity hash computed; max_hp =
        // its stock HealthMax ^healthNormalFeral). Offline fallback only: live
        // spawns resolve per-class via the director class_resolve_fn hook (A35).
        .{ .name = "zombieBoeFeral", .max_hp = 550, .kind = .zombie, .hash = -272178566, .loot_list = "EntityLootContainerRegular" },
        .{ .name = "trader", .max_hp = 9999, .kind = .trader },
        .{ .name = "vehicle", .max_hp = 200, .kind = .vehicle },
        .{ .name = "turret", .max_hp = 150, .kind = .turret },
        .{ .name = "lootBag", .max_hp = 1, .kind = .loot_bag },
        .{ .name = "animal", .max_hp = 30, .kind = .animal },
    } ++ [_]EntityClass{.{}} ** 8,

    /// Catalog stack cap: `stack_fn` (items.xml Stacknumber) or offline builtins.
    /// Single source for deposit paths; do not hardcode 60000 at call sites.
    pub fn maxStack(self: *const World, item_id: u16) u16 {
        if (self.stack_fn) |f| return f(self.stack_ctx, item_id);
        return c.maxStackOffline(item_id);
    }

    /// Held-item light for the stealth selfLight blend (items.xml LightValue
    /// via the Game hook; 0 when unhooked or the item carries none).
    pub fn heldLightFor(self: *const World, player_slot: Slot) f32 {
        if (!self.mask[player_slot].inventory) return 0;
        const inv = &self.inventory[player_slot];
        if (inv.holding >= c.inv_toolbelt) return 0;
        const item_id = inv.slots[inv.holding].item_id;
        if (item_id == 0) return 0;
        if (self.held_light_fn) |f| return f(self.held_light_ctx, item_id);
        return 0;
    }

    /// Deposit into an entity inventory slot respecting catalog stack caps.
    pub fn depositItem(self: *World, s: Slot, item_id: u16, count: u16) bool {
        if (!self.mask[s].inventory) return false;
        return self.inventory[s].addItemStacked(item_id, count, self.maxStack(item_id));
    }

    pub fn ensureNetMap(self: *World, allocator: std.mem.Allocator) !void {
        if (self.net_map_init) return;
        self.net_map_allocator = allocator;
        self.net_to_slot = .empty;
        try self.net_to_slot.ensureTotalCapacity(allocator, max_entities);
        self.net_map_init = true;
    }

    pub fn deinit(self: *World) void {
        self.catalog.deinit();
        if (self.net_map_init) {
            self.net_to_slot.deinit(self.net_map_allocator);
            self.net_map_init = false;
        }
    }

    pub fn setCatalog(self: *World, cat: quest.Catalog) void {
        self.catalog.deinit();
        self.catalog = cat;
    }

    /// Buff set for a slot, attaching the column on first use. Zeroing here (not
    /// in spawnBase) keeps a 300-byte memset off every spawn while guaranteeing
    /// a reused slot never inherits the previous entity's buffs.
    pub fn buffsMut(self: *World, slot: Slot) *c.BuffSet {
        if (!self.mask[slot].buffs) {
            self.mask[slot].buffs = true;
            self.buffs[slot] = .{};
        }
        return &self.buffs[slot];
    }

    pub fn playerByPeer(self: *const World, peer_slot: usize) ?Slot {
        if (peer_slot < self.peer_to_player.len) {
            const slot = self.peer_to_player[peer_slot];
            if (slot != no_player_slot and self.alive[slot] and self.mask[slot].player and
                self.player[slot].peer_slot == @as(i32, @intCast(peer_slot)))
            {
                return slot;
            }
            // In-range index is maintained by spawnPlayer/destroy and is
            // authoritative: a miss means no player for this peer. The full
            // scan below is reserved for out-of-range synthetic peer ids;
            // running it on every miss cost O(max_entities) per call on the
            // per-tick packet/quest paths.
            return null;
        }
        // Preserve the standalone ECS API for callers using an out-of-range
        // synthetic peer id. The player group is slot-ascending, so the first
        // match is the same one the open scan returned.
        for (self.kind_groups.slice(.player)) |i| {
            if (self.alive[i] and self.mask[i].player and self.player[i].peer_slot == @as(i32, @intCast(peer_slot))) {
                return i;
            }
        }
        return null;
    }

    fn allocSlot(self: *World) ?Slot {
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (!self.alive[i] and !self.freed_this_tick[i]) return i;
        }
        // At capacity: fall back to just-freed slots rather than failing the spawn.
        i = 0;
        while (i < max_entities) : (i += 1) {
            if (!self.alive[i]) return i;
        }
        return null;
    }

    pub fn destroy(self: *World, slot: Slot) void {
        if (slot >= max_entities or !self.alive[slot]) return;
        // Capture kind before mask clear for the kind group.
        const had_kind = self.mask[slot].kind;
        const kind_val = self.kind[slot];
        // Mark dead before group removal so a concurrent kind-group walk
        // sees the same truth as alive[]: this slot is gone.
        self.alive[slot] = false;
        self.alive_bits.unset(slot);
        self.freed_this_tick[slot] = true;
        self.any_freed_this_tick = true;
        // Release the ambient spawn-rule budget (kill attrition, spawning.md
        // §3): a zombie spawned by the biome drip decrements its rule's count.
        if (self.mask[slot].zombie_ai and self.zombie_ai[slot].spawn_rule != 0xffff) {
            self.director.releaseRule(self.zombie_ai[slot].spawn_rule);
        }
        if (had_kind) self.kind_groups.remove(kind_val, slot);
        if (self.mask[slot].player) {
            const peer_slot = self.player[slot].peer_slot;
            if (peer_slot >= 0 and peer_slot < @as(i32, @intCast(self.peer_to_player.len)) and
                self.peer_to_player[@intCast(peer_slot)] == slot)
            {
                self.peer_to_player[@intCast(peer_slot)] = no_player_slot;
            }
        }
        if (self.mask[slot].network_id and self.net_map_init) {
            _ = self.net_to_slot.remove(self.network_id[slot].id);
        }
        // Turrets own a consumer power node; drop it or it draws load forever.
        // By id: two turrets can share a cell, and removeAt would take the wrong one.
        if (self.mask[slot].turret) _ = self.power.removeById(self.turret[slot].power_node);
        self.mask[slot] = .{};
        self.dirty[slot] = .{};
        self.dirty_bits.unset(slot);
        if (self.entity_count > 0) self.entity_count -= 1;
    }

    /// Un-kill a slot that is still populated (respawn of a dead player whose
    /// entity was never destroyed). The single sanctioned way to set alive[]
    /// back to true: raw writes would drift the kind group. Idempotent.
    pub fn reviveSlot(self: *World, slot: Slot) void {
        if (slot >= max_entities or !self.mask[slot].kind) return;
        if (!self.alive[slot]) {
            self.alive[slot] = true;
            self.alive_bits.set(slot);
            self.entity_count +%= 1;
        }
        self.kind_groups.insert(self.kind[slot], slot);
    }

    /// Teleport a live entity to a world position, keeping yaw. The sanctioned
    /// teleport funnel: raw transform[] writes from c2s would bypass the
    /// markDirty relay and delay the pos broadcast to observers.
    pub fn teleportTo(self: *World, slot: Slot, x: f32, y: f32, z: f32) void {
        if (slot >= max_entities or !self.mask[slot].transform) return;
        self.transform[slot] = .{ .x = x, .y = y, .z = z, .yaw = self.transform[slot].yaw };
        self.markDirty(slot, .{ .pos = true });
    }

    /// Respawn a dead player slot: un-kill (reviveSlot), full heal to the
    /// player default max (100, matching spawnPlayer), drop the death buffs,
    /// clear IsBloodMoonDead and place at (x, y, z) with yaw 0. The single
    /// sanctioned respawn funnel: c2s/join RequestToSpawn must not write
    /// alive[]/health/transform raw (reviveSlot keeps the kind group in sync).
    pub fn respawnPlayer(self: *World, slot: Slot, x: f32, y: f32, z: f32) void {
        if (slot >= max_entities or !self.mask[slot].kind) return;
        self.reviveSlot(slot);
        if (self.mask[slot].buffs) _ = buff.clearOnDeath(&self.buffs[slot]);
        var h = self.health[slot];
        h.hp = 100;
        h.max_hp = 100;
        h.base_max_hp = 100;
        // Keep food/water/stamina on respawn; stock does not zero them
        // (the bug did `Health{hp=100,max=100}` which zeroed food=0/water=0).
        if (h.food == 0 and h.food_max == 0) h.food_max = 100;
        if (h.water == 0 and h.water_max == 0) h.water_max = 100;
        if (h.stamina_max == 0) h.stamina_max = 100;
        if (h.stamina == 0) h.stamina = h.stamina_max;
        self.health[slot] = h;
        if (self.mask[slot].player) self.player[slot].is_blood_moon_dead = false;
        self.transform[slot] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
        self.markDirty(slot, .{ .pos = true, .hp = true });
    }

    /// Max A* replans admitted per tick. Each costs at most `path_max_expand`
    /// node expansions, so this is the tick's pathfinding node ceiling.
    pub const path_replans_per_tick: u32 = 16;
    /// Cap on the admission stride: a replan is delayed by at most this many
    /// ticks (0.4 s at 20 Hz) beyond its own cooldown, whatever the load.
    pub const path_stride_max: u32 = 8;

    /// Stride that spreads `want` replans over enough ticks to stay under the
    /// per-tick cap. 1 = admit everyone.
    fn pathStrideFor(want: u32) u32 {
        if (want <= path_replans_per_tick) return 1;
        const s = (want +| (path_replans_per_tick - 1)) / path_replans_per_tick;
        return @min(s, path_stride_max);
    }

    /// Clear tick locals at the start of each sim frame (schedule / tickAll).
    pub fn beginTick(self: *World) void {
        self.sim_tick +%= 1;
        @memset(&self.freed_this_tick, false);
        // Budget for this tick from last tick's demand (granted + refused).
        // Read on the main thread with the AI phase quiesced, so the sum is a
        // plain deterministic total, not a racy sample.
        const want = self.path_replans.load(.monotonic) + self.path_replans_denied.load(.monotonic);
        self.path_stride = pathStrideFor(want);
        self.path_tick +%= 1;
        self.path_replans.store(0, .monotonic);
        self.path_replans_denied.store(0, .monotonic);
        // any_freed_this_tick stays set until replicate reconciles known_entities:
        // net poll / admin may destroy before beginTick, sim after it.
        self.locals.clear();
    }

    /// Push a combat-noise event (stock NotifyNoise). Called from parallel AI
    /// workers (melee hits) and the net thread (ranged damage), so the ring
    /// index is an atomic RMW; events beyond the cap are dropped.
    pub fn pushNoise(self: *World, x: f32, y: f32, z: f32, radius: f32) void {
        const n = @atomicRmw(usize, &self.noise_n, .Add, 1, .monotonic);
        if (n >= c.noise_events_cap) return;
        self.noise_events[n] = .{ .x = x, .y = y, .z = z, .radius = radius };
    }

    /// Push a player movement-noise event (stock AIDirector.NotifyNoise from
    /// the sound relay). Called from the net thread, so the ring index is an
    /// atomic RMW; events beyond the cap are dropped.
    pub fn pushStealthNoise(
        self: *World,
        slot: Slot,
        x: f32,
        y: f32,
        z: f32,
        volume: f32,
        duration_ticks: i32,
        muffled_when_crouched: f32,
        heat_map_strength: f32,
        heat_map_time: f32,
    ) void {
        const n = @atomicRmw(usize, &self.stealth_noise_n, .Add, 1, .monotonic);
        if (n >= c.stealth_events_cap) return;
        self.stealth_noise_events[n] = .{
            .slot = @intCast(slot),
            .x = x,
            .y = y,
            .z = z,
            .volume = volume,
            .duration_ticks = duration_ticks,
            .muffled_when_crouched = muffled_when_crouched,
            .heat_map_strength = heat_map_strength,
            .heat_map_time = heat_map_time,
        };
    }

    /// Push a sleeper-volume wake by noise position (stock
    /// World.CheckSleeperVolumeNoise from PlayerStealth.NotifyNoise hitting
    /// the volume cap). The Game drains the ring after the tick.
    pub fn pushSleeperVolumeNoise(self: *World, x: f32, y: f32, z: f32) void {
        const n = @atomicRmw(usize, &self.sleeper_volume_noise_n, .Add, 1, .monotonic);
        if (n >= c.stealth_events_cap) return;
        self.sleeper_volume_noise[n] = .{ .x = x, .y = y, .z = z, .radius = 0 };
    }

    /// Push a Demolition explode request (RE entity-ai.md EntityZombieCop).
    /// Parallel AI workers push; the Game drains in step (consume-owns-drain).
    pub fn pushExplode(self: *World, slot: Slot) void {
        const n = @atomicRmw(usize, &self.explode_n, .Add, 1, .monotonic);
        if (n >= c.explode_cap) return;
        self.explode_reqs[n] = .{ .slot = @intCast(slot) };
    }

    /// Push a MoveHelper dig damage request (RE entity-ai.md DigUpdate).
    /// Parallel AI workers push; the Game drains in step (consume-owns-drain).
    pub fn pushDig(self: *World, slot: Slot, x: i32, y: i32, z: i32) void {
        const n = @atomicRmw(usize, &self.dig_n, .Add, 1, .monotonic);
        if (n >= c.dig_cap) return;
        self.dig_reqs[n] = .{ .slot = @intCast(slot), .x = x, .y = y, .z = z };
    }

    /// Push a sleeper wake request (RE entity-ai.md sleeper wake; stock sends
    /// NetPackageSleeperWakeup from EntityAlive.ConditionalTriggerSleeperWakeUp).
    /// Parallel AI workers push; the Game drains in step and broadcasts the
    /// wakeup so the client plays the wake animation.
    pub fn pushSleeperWake(self: *World, slot: Slot) void {
        const n = @atomicRmw(usize, &self.sleeper_wake_n, .Add, 1, .monotonic);
        if (n >= c.sleeper_wake_cap) return;
        self.sleeper_wake_reqs[n] = .{ .slot = @intCast(slot) };
    }

    /// Push a sleeper STIR request (RE EntityAlive.SetSleeperActive IL=26):
    /// an in-volume player that did not wake the sleeper clears its passive
    /// flag and the Game broadcasts NetPackageSleeperPassiveChange so the
    /// client plays the groan. One-shot per sleeper (groan_sent).
    pub fn pushSleeperGroan(self: *World, slot: Slot) void {
        const n = @atomicRmw(usize, &self.sleeper_wake_n, .Add, 1, .monotonic);
        if (n >= c.sleeper_wake_cap) return;
        self.sleeper_wake_reqs[n] = .{ .slot = @intCast(slot), .groan = true };
    }

    /// Resting terrain height at world (x,z) via the optional ground hook, or
    /// null when unset (no terrain data; caller skips physics).
    pub fn groundY(self: *const World, x: f32, z: f32) ?f32 {
        if (self.ground_fn) |f| return f(self.ground_ctx, @floor(x), @floor(z));
        return null;
    }

    /// POI footprint covering world (x,z) via the optional hook, or null when
    /// unset or the position sits outside every prefab.
    pub fn poiAt(self: *const World, x: f32, z: f32) ?c.PoiRect {
        const f = self.poi_fn orelse return null;
        const r = f(self.poi_ctx, x, z) orelse return null;
        return if (r.valid()) r else null;
    }

    /// Nearest quest-eligible POI rect to world (x,z), or null when unset.
    /// Quest placement uses this for defs without a static position.
    pub fn nearestPoi(self: *const World, x: f32, z: f32) ?c.PoiRect {
        const f = self.nearest_poi_fn orelse return null;
        const r = f(self.nearest_poi_ctx, x, z) orelse return null;
        return if (r.valid()) r else null;
    }

    /// Stock quest-POI selection (tag/tier/biome/distance + lockout), or null
    /// when the hook is unset or nothing qualifies. The Game hook mirrors
    /// DynamicPrefabDecorator.GetRandomPOINearWorldPos / GetRandomPOINearTrader
    /// / GetClosestPOIToWorldPos; null → the caller falls back (nearestPoi /
    /// static def position) so POI-less test worlds still complete quests.
    pub fn questSelectPoi(self: *const World, p: quest.QuestPoiParams) ?quest.PoiSelect {
        const f = self.quest_poi_fn orelse return null;
        const sel = f(self.quest_poi_ctx, p) orelse return null;
        return if (sel.valid()) sel else null;
    }

    /// Feet Y after one grid move, or null when blocked (optional hook).
    /// With no hook the grid is open and flat, so the body keeps its height.
    pub fn stepTo(self: *const World, fx: i32, fz: i32, fy: i32, tx: i32, tz: i32) ?i32 {
        if (self.step_fn) |f| return f(self.step_ctx, fx, fz, fy, tx, tz);
        return fy;
    }

    /// True when slot `s` may spend A* nodes this tick. Pure function of the
    /// slot and the tick-constant stride/phase, so the answer does not depend
    /// on which worker range the slot landed in.
    pub fn pathBudgetAdmits(self: *const World, s: Slot) bool {
        if (self.path_stride <= 1) return true;
        return (@as(u32, s) +% self.path_tick) % self.path_stride == 0;
    }

    /// True when handle still points at the same reincarnation of this slot.
    pub fn handleAlive(self: *const World, h: ent.EntityHandle) bool {
        if (h.slot >= max_entities or !self.alive[h.slot]) return false;
        if (!self.mask[h.slot].network_id) return false;
        return self.network_id[h.slot].gen == h.gen;
    }

    pub fn handleOfSlot(self: *const World, slot: Slot) ent.EntityHandle {
        if (slot >= max_entities or !self.alive[slot] or !self.mask[slot].network_id)
            return .invalid();
        return .{ .slot = slot, .gen = self.network_id[slot].gen };
    }

    pub fn slotOfNetId(self: *const World, id: NetId) ?Slot {
        if (self.net_map_init) {
            if (self.net_to_slot.get(id)) |slot| return slot;
            // A healthy map is authoritative: a miss means the id is gone.
            // Stale-target lookups are the common case on the per-tick AI
            // path, and the full scan below made every miss O(max_entities).
            if (!self.net_map_degraded) return null;
        }
        // The SoA columns are authoritative. The map is a derived index and
        // may miss after a failed insertion, so preserve correctness with the
        // bounded scan promised by registerNet's failure path.
        var i: Slot = 0;
        while (i < max_entities) : (i += 1) {
            if (self.alive[i] and self.mask[i].network_id and self.network_id[i].id == id) return i;
        }
        return null;
    }

    fn registerNet(self: *World, slot: Slot, id: NetId) void {
        if (!self.net_map_init) return;
        // Pre-sized at init; insert failure only if map allocator is exhausted.
        // Fall back: slotOfNetId still walks SoA when map misses.
        self.net_to_slot.put(self.net_map_allocator, id, slot) catch {
            self.net_map_degraded = true;
            std.debug.print(
                "zdtd: net_to_slot put failed id={d} slot={d} (OOM? using linear lookup)\n",
                .{ id, slot },
            );
        };
    }

    /// Highest net id the monotonic counter may hand out before wrap.
    /// Exhaustion needs 2^31 allocations and is unreachable under the
    /// max_entities cap, but a wrapped id would silently collide with a live
    /// entity's id (net_to_slot.put overwrites the old mapping), so allocation
    /// fails closed instead.
    const net_id_max = std.math.maxInt(i32);

    /// Reserve the next globally-unique net id, or null when the counter is
    /// exhausted (see net_id_max). Shared by ECS spawns and host-side bots so
    /// the two id spaces never collide.
    pub fn allocNetId(self: *World) ?i32 {
        const id = self.next_net_id;
        if (id >= net_id_max) return null;
        self.next_net_id = id + 1;
        return id;
    }

    fn spawnBase(self: *World, kind: Kind, x: f32, y: f32, z: f32, hp: f32) ?Slot {
        const nid = self.allocNetId() orelse return null;
        const s = self.allocSlot() orelse return null;
        self.alive[s] = true;
        self.alive_bits.set(s);
        self.entity_count +%= 1;
        self.kind_groups.insert(kind, s);
        if (!self.entity_cap_warned and self.entity_count >= entity_warn_at) {
            self.entity_cap_warned = true;
            std.debug.print(
                "zdtd: entity slots near capacity n={d}/{d} (warn>={d})\n",
                .{ self.entity_count, max_entities, entity_warn_at },
            );
        }
        self.mask[s] = .{
            .transform = true,
            .health = true,
            .network_id = true,
            .kind = true,
            .flags = true,
            .dirty = true,
            .class_id = true,
        };
        self.transform[s] = .{ .x = x, .y = y, .z = z, .yaw = 0 };
        self.health[s] = .{ .hp = hp, .max_hp = hp, .base_max_hp = hp };
        self.slot_gen[s] +%= 1;
        self.network_id[s] = .{ .id = nid, .gen = self.slot_gen[s] };
        self.kind[s] = kind;
        self.flags[s] = .{ .bits = c.flag_spawned };
        self.dirty[s] = .{ .spawn = true, .pos = true };
        self.dirty_bits.set(s);
        const cid: u16 = switch (kind) {
            .player => 0,
            .zombie => 1,
            .falling_block => 2,
            .trader => 3,
            .vehicle => 4,
            .turret => 5,
            .loot_bag => 6,
            .animal => 7,
        };
        const ct = self.class_table[cid];
        self.class_id[s] = .{
            .id = cid,
            .hash = ct.hash,
            .loot_list = ct.loot_list,
            .drop_prob = ct.drop_prob,
            .time_stay = ct.time_stay,
            .explode_threshold = ct.explode_threshold,
            .explode_delay_s = ct.explode_delay_s,
            .explosion_radius = ct.explosion_radius,
            .explosion_radius_e = ct.explosion_radius_e,
            .explosion_block_dmg = ct.explosion_block_dmg,
            .explosion_entity_dmg = ct.explosion_entity_dmg,
            .explosion_bonus_cat = ct.explosion_bonus_cat,
            .explosion_bonus_mult = ct.explosion_bonus_mult,
            .explosion_bonus_n = ct.explosion_bonus_n,
        };
        self.registerNet(s, nid);
        return s;
    }

    /// Apply entityclasses row onto class_table slot (keeps index stable for Kind).
    pub fn setClassDef(self: *World, index: u16, def: EntityClass) void {
        if (index >= self.class_table.len) return;
        self.class_table[index] = def;
    }

    pub fn spawnZombieClass(self: *World, x: f32, y: f32, z: f32, hp: f32, class_hash: i32, loot_list: []const u8) ?NetId {
        return self.spawnZombieDef(x, y, z, hp, .{
            .name = "zombie",
            .max_hp = hp,
            .kind = .zombie,
            .hash = class_hash,
            .loot_list = loot_list,
        });
    }

    /// Spawn a zombie carrying the full resolved class stats on the entity, so
    /// per-class speeds/damage reach the AI even when the class was not
    /// preloaded into the fixed class_table (A35). The class_table index stays
    /// the kind default; the per-entity stat fields win in the AI read.
    pub fn spawnZombieDef(self: *World, x: f32, y: f32, z: f32, hp: f32, def: EntityClass) ?NetId {
        const id = self.spawnZombie(x, y, z, hp) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.class_id[s].hash = def.hash;
            self.class_id[s].loot_list = def.loot_list;
            self.class_id[s].drop_prob = def.drop_prob;
            self.class_id[s].time_stay = def.time_stay;
            self.class_id[s].chase_speed = def.chase_speed;
            self.class_id[s].chase_speed_day = rollChaseDay(def, x, z);
            self.class_id[s].wander_speed = def.wander_speed;
            self.class_id[s].wander_speed_night = def.wander_speed_night;
            self.class_id[s].attack_damage = def.attack_damage;
            self.class_id[s].block_chew = def.block_chew;
            self.class_id[s].melee_range = def.melee_range;
            self.class_id[s].sight_range = def.sight_range;
            self.class_id[s].sight_light_min = def.sight_light_min;
            self.class_id[s].sight_light_max = def.sight_light_max;
            self.class_id[s].sleeper_wake_near_min = def.sleeper_wake_near_min;
            self.class_id[s].sleeper_wake_near_max = def.sleeper_wake_near_max;
            self.class_id[s].sleeper_wake_far_min = def.sleeper_wake_far_min;
            self.class_id[s].sleeper_wake_far_max = def.sleeper_wake_far_max;
            self.class_id[s].is_enemy = def.is_enemy;
            self.class_id[s].ai_attack = def.ai_attack;
            self.class_id[s].xp_gain = def.xp_gain;
            self.class_id[s].explode_threshold = def.explode_threshold;
            self.class_id[s].explode_delay_s = def.explode_delay_s;
            self.class_id[s].explosion_radius = def.explosion_radius;
            self.class_id[s].explosion_radius_e = def.explosion_radius_e;
            self.class_id[s].explosion_block_dmg = def.explosion_block_dmg;
            self.class_id[s].explosion_entity_dmg = def.explosion_entity_dmg;
            self.class_id[s].explosion_bonus_cat = def.explosion_bonus_cat;
            self.class_id[s].explosion_bonus_mult = def.explosion_bonus_mult;
            self.class_id[s].explosion_bonus_n = def.explosion_bonus_n;
        }
        return id;
    }

    /// Lookup class_table index by name (first match). Null if missing.
    pub fn findClassByName(self: *const World, class_name: []const u8) ?u16 {
        var i: u16 = 0;
        while (i < self.class_table.len) : (i += 1) {
            if (self.class_table[i].name.len == 0) continue;
            if (std.mem.eql(u8, self.class_table[i].name, class_name)) return i;
        }
        return null;
    }

    /// Prefab spawn: fill zombie from class_table[class_id] (hp/hash/loot).
    pub fn spawnZombieFromClassId(self: *World, class_id: u16, x: f32, y: f32, z: f32) ?NetId {
        if (class_id >= self.class_table.len) return null;
        const ct = self.class_table[class_id];
        if (ct.kind != .zombie) return null;
        const hp = if (ct.max_hp > 0) ct.max_hp else 40;
        const id = self.spawnZombie(x, y, z, hp) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.class_id[s] = .{
                .id = class_id,
                .hash = ct.hash,
                .loot_list = ct.loot_list,
                .ai_attack = ct.ai_attack,
            };
        }
        return id;
    }

    /// Prefab spawn by entityclasses name (class_table scan).
    pub fn spawnZombieFromClass(self: *World, class_name: []const u8, x: f32, y: f32, z: f32) ?NetId {
        const idx = self.findClassByName(class_name) orelse return null;
        return self.spawnZombieFromClassId(idx, x, y, z);
    }

    pub fn spawnAnimal(self: *World, x: f32, y: f32, z: f32, hp: f32, class_hash: i32, loot_list: []const u8) ?NetId {
        const s = self.spawnBase(.animal, x, y, z, hp) orelse return null;
        self.mask[s].zombie_ai = true; // reuse wander/flee AI
        self.zombie_ai[s] = .{
            .state = .wander,
            .wander_tx = x,
            .wander_tz = z,
        };
        self.class_id[s].hash = class_hash;
        self.class_id[s].loot_list = loot_list;

        return self.network_id[s].id;
    }

    /// Animal spawn carrying the full resolved class stats (A35), so a class
    /// not preloaded into the fixed class_table still wanders/flees/chases as
    /// itself. Prefer this over spawnAnimal + a manual post-spawn copy.
    pub fn spawnAnimalDef(self: *World, x: f32, y: f32, z: f32, def: EntityClass) ?NetId {
        const id = self.spawnAnimal(x, y, z, def.max_hp, def.hash, def.loot_list) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.class_id[s].drop_prob = def.drop_prob;
            self.class_id[s].time_stay = def.time_stay;
            self.class_id[s].chase_speed = def.chase_speed;
            self.class_id[s].chase_speed_day = rollChaseDay(def, x, z);
            self.class_id[s].wander_speed = def.wander_speed;
            self.class_id[s].wander_speed_night = def.wander_speed_night;
            self.class_id[s].attack_damage = def.attack_damage;
            self.class_id[s].block_chew = def.block_chew;
            self.class_id[s].melee_range = def.melee_range;
            self.class_id[s].sight_range = def.sight_range;
            self.class_id[s].sight_light_min = def.sight_light_min;
            self.class_id[s].sight_light_max = def.sight_light_max;
            self.class_id[s].sleeper_wake_near_min = def.sleeper_wake_near_min;
            self.class_id[s].sleeper_wake_near_max = def.sleeper_wake_near_max;
            self.class_id[s].sleeper_wake_far_min = def.sleeper_wake_far_min;
            self.class_id[s].sleeper_wake_far_max = def.sleeper_wake_far_max;
            self.class_id[s].is_enemy = def.is_enemy;
            self.class_id[s].ai_attack = def.ai_attack;
            self.class_id[s].xp_gain = def.xp_gain;
        }
        return id;
    }

    /// Sleeper spawn carrying the full resolved class stats on the entity (the
    /// same A35 path as spawnZombieDef): a sleeper class not preloaded into the
    /// fixed class_table still chases/bites as itself instead of the zombie row.
    /// `volume` links the entity to its SleeperVolume index (0 = none) for the
    /// re-arm alive-count recount (stock ClearedUpdate / Touch re-arm).
    pub fn spawnSleeperDef(self: *World, x: f32, y: f32, z: f32, def: EntityClass, volume: u16) ?NetId {
        const id = self.spawnZombieDef(x, y, z, def.max_hp, def) orelse return null;
        if (self.slotOfNetId(id)) |s| {
            self.mask[s].sleeper = true;
            self.sleeper[s] = .{ .awake = false, .home_x = x, .home_z = z, .volume_r = 20 };
            // RE entity-ai.md D8.6 step 5: each sleeping zombie rolls its
            // GetSleeperDisturbedLevel wake-threshold pair from the class
            // SleeperSightToWakeMin/Max ranges (stock zombieTemplateMale
            // "-40,5" / "340,480"). Deterministic per spawn: a hash of the
            // position + class seeds both rolls (the sim has no ad-hoc RNG).
            const near_min = if (def.sleeper_wake_near_min != 0 or def.sleeper_wake_near_max != 0)
                def.sleeper_wake_near_min
            else
                sleeper_wake_near_min_default;
            const near_max = if (def.sleeper_wake_near_min != 0 or def.sleeper_wake_near_max != 0)
                def.sleeper_wake_near_max
            else
                sleeper_wake_near_max_default;
            const far_min = if (def.sleeper_wake_far_min != 0 or def.sleeper_wake_far_max != 0)
                def.sleeper_wake_far_min
            else
                sleeper_wake_far_min_default;
            const far_max = if (def.sleeper_wake_far_min != 0 or def.sleeper_wake_far_max != 0)
                def.sleeper_wake_far_max
            else
                sleeper_wake_far_max_default;
            const h = std.hash.Wyhash.hash(0, std.mem.asBytes(&.{ x, z, @as(f32, @floatFromInt(def.hash)) }));
            const frac_a = @as(f32, @floatFromInt(h >> 32)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
            const frac_b = @as(f32, @floatFromInt(h & 0xffffffff)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
            self.sleeper[s].wake_light_near = near_min + (near_max - near_min) * frac_a;
            self.sleeper[s].wake_light_far = far_min + (far_max - far_min) * frac_b;
            self.zombie_ai[s].state = .sleep;
            self.sleeper_vol[s] = volume;
        }
        return id;
    }

    pub fn spawnPlayer(self: *World, x: f32, y: f32, z: f32, peer_slot: i32) ?NetId {
        // One live entity per peer slot. Without this a reconnect leaves the old
        // body alive and playerByPeer keeps returning it, so sim state (inventory,
        // quests) and net state (Client.entity_id) drift onto two entities.
        if (peer_slot >= 0) {
            if (self.playerByPeer(@intCast(peer_slot))) |old| self.destroy(old);
        }
        const s = self.spawnBase(.player, x, y, z, 100) orelse return null;
        self.mask[s].player = true;
        self.mask[s].journal = true;
        self.mask[s].wallet = true;
        self.mask[s].inventory = true;
        self.player[s] = .{ .peer_slot = peer_slot };
        // Fresh stealth-noise state (slot reuse must not carry a previous
        // occupant's noise list / sleeper volume into the new body).
        self.stealth[s] = .{};
        if (peer_slot >= 0 and peer_slot < @as(i32, @intCast(self.peer_to_player.len))) {
            self.peer_to_player[@intCast(peer_slot)] = s;
        }
        self.journal[s] = .{};
        self.wallet[s] = .{};
        self.inventory[s] = .{};
        // PlayerEntityStats defaults (stock full bar on fresh spawn).
        self.health[s].food = 100;
        self.health[s].food_max = 100;
        self.health[s].water = 100;
        self.health[s].water_max = 100;
        // Starter kit by stock item name. Production resolves via item_id_fn
        // (items.xml / AssignIds); missing names fail closed. Offline tests
        // without the hook keep the builtin ECS ids.
        const starter = [_]struct { []const u8, u16, u16 }{
            .{ "meleeToolRepairT0StoneAxe", 8, 1 },
            .{ "foodCanBeef", 2, 5 },
            .{ "resourceWood", 7, 20 },
            .{ "casinoCoin", 6, 50 },
        };
        for (starter) |it| {
            const id: u16 = if (self.item_id_fn) |f| f(self.item_id_ctx, it[0]) else it[1];
            if (id == 0) continue;
            _ = self.depositItem(s, id, it[2]);
        }

        return self.network_id[s].id;
    }

    pub fn spawnZombie(self: *World, x: f32, y: f32, z: f32, hp: f32) ?NetId {
        const s = self.spawnBase(.zombie, x, y, z, hp) orelse return null;
        self.mask[s].zombie_ai = true;
        self.zombie_ai[s] = .{
            .state = .wander,
            .wander_tx = x,
            .wander_tz = z,
            .home_x = x,
            .home_z = z,
            .has_home = true,
        };

        return self.network_id[s].id;
    }

    /// Deterministic per-entity loot drop roll, shared by player damage and
    /// turret kills. Stock uses the world GameRandom; the net id is stable
    /// within a run, so the same inputs give the same outcomes. drop_prob is
    /// clamped to [0,1] at load; >= 1 always drops.
    pub fn rollLootDrop(self: *const World, net_id: i32, drop_prob: f32) bool {
        _ = self;
        if (drop_prob >= 1.0) return true;
        var h: u64 = @intCast(net_id);
        h = h *% 1103515245 +% 12345;
        h = (h >> 16) ^ h;
        return h % 1000 < @as(u64, @trunc(drop_prob * 1000));
    }

    pub fn spawnLootBag(self: *World, x: f32, y: f32, z: f32, item_id: u16, count: u16) ?NetId {
        const s = self.spawnBase(.loot_bag, x, y, z, 1) orelse return null;
        self.mask[s].loot_bag = true;
        self.mask[s].inventory = true;
        self.loot_bag[s] = .{};
        self.inventory[s] = .{};
        _ = self.depositItem(s, item_id, count);

        return self.network_id[s].id;
    }

    /// Death bag (stock DropOnDeath): spawn a loot bag holding a slot range of
    /// a source inventory (mode 1 = toolbelt+backpack, 2 = toolbelt, 3 =
    /// backpack). The range is capped to max_inv_slots and copied into the bag
    /// so the dead player's actual inventory rides the death bag instead of a
    /// single placeholder unit.
    pub fn spawnLootBagFrom(self: *World, x: f32, y: f32, z: f32, src: *const c.Inventory, start: usize, end: usize) ?NetId {
        const s = self.spawnBase(.loot_bag, x, y, z, 1) orelse return null;
        self.mask[s].loot_bag = true;
        self.mask[s].inventory = true;
        self.loot_bag[s] = .{};
        var inv: c.Inventory = .{};
        const lo = @min(start, c.max_inv_slots);
        const hi = @min(end, c.max_inv_slots);
        var i: usize = lo;
        var out: usize = 0;
        while (i < hi and out < c.max_inv_slots) : (i += 1) {
            inv.slots[out] = src.slots[i];
            out += 1;
        }
        self.inventory[s] = inv;

        return self.network_id[s].id;
    }

    /// Spawn one falling-blocks group entity at the cells' centroid (RE
    /// entity-ai.md CreateFallingBlockGroup): the cells keep their world
    /// positions and raw block values; the group falls as a unit and dies on
    /// landing (no re-placement). `cells` beyond the group cap are dropped
    /// (stock GroupBounds.IsWithinSize clamps groups).
    pub fn spawnFallingBlocks(self: *World, cells: []const c.FallingCell) ?NetId {
        if (cells.len == 0) return null;
        const n = @min(cells.len, c.falling_group_cap);
        var cx: f32 = 0;
        var cy: f32 = 0;
        var cz: f32 = 0;
        for (cells[0..n]) |cell| {
            cx += @floatFromInt(cell.x);
            cy += @floatFromInt(cell.y);
            cz += @floatFromInt(cell.z);
        }
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(n));
        const s = self.spawnBase(.falling_block, cx * inv + 0.5, cy * inv, cz * inv + 0.5, 1) orelse return null;
        self.mask[s].falling = true;
        self.falling[s] = .{ .n = @intCast(n) };
        @memcpy(self.falling[s].cells[0..n], cells[0..n]);

        return self.network_id[s].id;
    }

    /// Spawn one singular fallingBlock entity (stock default path: group mode
    /// EntityFallingBlocks.Enabled is false, so each falling cell spawns its
    /// own entity - entity-ai.md LetBlocksFall 1256-1262). Position is the cell
    /// center plus the stock random Y offset (-0.1..0.1); the horizontal
    /// impulse is a small deterministic per-cell draw (seeded by world pos, so
    /// the same collapse reproduces the same scatter).
    pub fn spawnFallingBlock(self: *World, cell: c.FallingCell, mass_kg: f32) ?NetId {
        // Position-seeded stream through util.rng (the one sim PRNG policy);
        // the SplitMix64 fold in initFromU64 keeps distinct cells on distinct
        // streams so the same collapse reproduces the same scatter.
        var prng = rng_util.XorShift32.initFromU64(
            @as(u64, @bitCast(@as(i64, cell.x))) *% 0x9E37_79B1_7F4A_7C15 ^
                @as(u64, @bitCast(@as(i64, cell.y))) *% 0xBF58_476D_1CE4_E5B9 ^
                @as(u64, @bitCast(@as(i64, cell.z))) *% 0x94D0_49BB_1331_11EB,
        );
        const dy: f32 = (prng.nextFloat() - 0.5) * 0.2; // stock -0.1..0.1
        const s = self.spawnBase(
            .falling_block,
            @as(f32, @floatFromInt(cell.x)) + 0.5,
            @as(f32, @floatFromInt(cell.y)) + dy,
            @as(f32, @floatFromInt(cell.z)) + 0.5,
            1,
        ) orelse return null;
        self.mask[s].falling = true;
        self.falling[s] = .{
            .n = 1,
            .vx = (prng.nextFloat() - 0.5) * 1.0,
            .vz = (prng.nextFloat() - 0.5) * 1.0,
            .mass_kg = mass_kg,
        };
        self.falling[s].cells[0] = cell;

        return self.network_id[s].id;
    }

    pub fn spawnTrader(self: *World, name: []const u8, x: f32, y: f32, z: f32, trader_info_id: u16, wallet: i32) ?NetId {
        const s = self.spawnBase(.trader, x, y, z, 9999) orelse return null;
        self.mask[s].trader = true;
        self.mask[s].trader_stock = true;
        self.trader_stock[s] = .{ .name = name, .trader_info_id = trader_info_id, .wallet = wallet, .wallet_default = wallet };

        return self.network_id[s].id;
    }

    pub fn spawnVehicle(self: *World, kind: c.VehicleKind, x: f32, y: f32, z: f32) ?NetId {
        return self.spawnVehicleEx(kind, x, y, z, 200, 0, 1);
    }

    /// max_hp / max_speed / seat_count from vehicles.xml when known (0 speed →
    /// kind default). seat_count is clamped into 1..components.max_seats so a
    /// bad config can never produce a seatless or out-of-range vehicle.
    pub fn spawnVehicleEx(self: *World, kind: c.VehicleKind, x: f32, y: f32, z: f32, max_hp: f32, max_speed: f32, seat_count: u8) ?NetId {
        const hp = if (max_hp > 0) max_hp else 200;
        const s = self.spawnBase(.vehicle, x, y, z, hp) orelse return null;
        self.mask[s].vehicle = true;
        // Tank capacity: vehicles.xml fuelTank capacity via the Game hook when
        // known; else the `[rules.vehicle] fuel_cap` floor. Bicycles carry no
        // tank in stock (they burn nothing and cannot be refueled).
        var tank_cap: f32 = 0;
        if (self.vehicle_tank_fn) |f| {
            const cap = f(self.vehicle_tank_ctx, kind);
            if (cap > 0) tank_cap = cap;
        }
        if (tank_cap <= 0) tank_cap = self.rules.vehicle.fuel_cap;
        self.vehicle[s] = .{
            .kind = kind,
            .fuel = if (kind == .bicycle) 0 else tank_cap,
            .max_speed = max_speed,
            .seat_count = @max(1, @min(seat_count, @as(u8, c.max_seats))),
        };

        return self.network_id[s].id;
    }

    pub fn spawnTurret(self: *World, x: f32, y: f32, z: f32) ?NetId {
        const s = self.spawnBase(.turret, x, y, z, 150) orelse return null;
        // Turret draw: autoTurret block RequiredPower via the Game hook (stock
        // 15 W). 15 is the no-hook offline floor; a wired hook that returns 0
        // fails closed instead of inventing 15 W after a game-dir load miss.
        var watts: f32 = 15;
        if (self.turret_watts_fn) |f| {
            watts = f(self.turret_watts_ctx);
        }
        const nid = self.power.addNode(.consumer, @floor(x), @floor(y), @floor(z), watts) orelse {
            self.destroy(s);
            return null;
        };
        if (self.power.indexOfId(nid)) |ni| {
            self.power.nodes[ni].entity_id = self.network_id[s].id;
        }
        self.mask[s].turret = true;
        var t: c.Turret = .{ .power_node = nid };
        if (self.turret_stats_fn) |f| {
            // Rule 15: the placed turret's range/damage/fire interval come
            // from the autoTurret block data (blocks.xml), never hardcoded
            // sim defaults; zero fields keep the component defaults.
            if (f(self.turret_stats_ctx)) |ts| {
                if (ts.max_distance > 0) t.range = ts.max_distance;
                if (ts.entity_damage > 0) t.damage = ts.entity_damage;
                if (ts.burst_fire_rate > 0) t.fire_interval = ts.burst_fire_rate;
            }
        }
        self.turret[s] = t;
        self.power.resolve();

        return self.network_id[s].id;
    }

    pub const DamageResult = struct {
        killed: bool = false,
        /// DroppedLootContainer net id when a zombie drops a loot bag; -1 if none.
        loot_bag_id: i32 = -1,
        /// entityclasses LootListOnDeath name (valid for bag fill after kill).
        loot_list: []const u8 = "",
        /// True when the hit applied a knockback impulse to the victim (the
        /// caller broadcasts NetPackageEntityVelocity so peers animate it).
        knocked: bool = false,
        /// on_entity_killed verdict >0 percent (100 = keep): the kill-XP
        /// award scales by this (ADR 0020 verdict convention; the <0 deny
        /// branch already consumed the hit above).
        kill_scale_pct: u32 = 100,
    };

    pub fn damage(self: *World, net_id: NetId, amount: f32) DamageResult {
        return self.damageFrom(net_id, amount, -1);
    }

    /// Damage with the attacker's net id (-1 = unattributed). The attacker is
    /// EntityAlive.revengeTarget: EAISetAsTargetIfHurt (asm.il:435831) promotes
    /// it to the attack target, so a zombie shot from behind turns on the
    /// shooter instead of the nearest player.
    pub fn damageFrom(self: *World, net_id: NetId, amount: f32, attacker_net_id: NetId) DamageResult {
        const s = self.slotOfNetId(net_id) orelse return .{};
        if (attacker_net_id >= 0 and attacker_net_id != net_id and
            self.alive[s] and self.mask[s].zombie_ai and amount > 0)
        {
            self.zombie_ai[s].revenge_target = attacker_net_id;
            self.zombie_ai[s].revenge_time = self.rules.ai.revenge_window_s;
        }
        if (self.kind[s] == .trader) return .{};
        if (!self.mask[s].health) return .{};
        // Non-positive / NaN must not heal, mark dirty, or re-fire kill side effects.
        if (!(amount > 0)) return .{};
        // Damage wakes sleepers (stock EntityAlive.ProcessDamageResponseLocal:
        // any damage triggers ConditionalTriggerSleeperWakeUp, plus
        // CheckSleeperVolumeNoise when still passive). The wake also pushes
        // the SleeperWakeup wire event for the client (drained in step). The
        // revenge_target set above drives the chase.
        if (self.mask[s].sleeper and !self.sleeper[s].awake) {
            self.sleeper[s].awake = true;
            if (self.mask[s].zombie_ai) self.zombie_ai[s].state = .chase;
            self.pushSleeperWake(s);
        }
        // Already dead (hp<=0): players stay in-world; a second hit must not
        // report killed again (double DropOnDeath bags / quest XP / loot).
        if (self.health[s].hp <= 0) return .{};
        self.health[s].hp -= amount;
        self.markDirty(s, .{ .hp = true });
        if (self.health[s].hp <= 0) {
            // Kill verdict (T15): a plugin may deny the death; the victim
            // survives at 1 hp and the hit is consumed (no loot/corpse/flow).
            // A >0 verdict scales the kill-XP award (boundary extension
            // 2026-08-25): the scale rides the DamageResult to the award site.
            var kill_scale: u32 = 100;
            if (self.kill_verdict_fn) |vf| {
                const v = vf(self.kill_verdict_ctx, self.kind[s], self.network_id[s].id, attacker_net_id);
                if (v < 0) {
                    self.health[s].hp = 1;
                    return .{};
                }
                if (v > 0) kill_scale = @intCast(v);
            }
            // Drop loot bag for zombies/animals (caller must S2C stock ECD + Bag).
            if ((self.kind[s] == .zombie or self.kind[s] == .animal) and self.mask[s].transform) {
                const x = self.transform[s].x;
                const y = self.transform[s].y;
                const z = self.transform[s].z;
                const loot_name = if (self.mask[s].class_id) self.class_id[s].loot_list else "";
                const drop_prob = if (self.mask[s].class_id) self.class_id[s].drop_prob else 1.0;
                const nid = self.network_id[s].id;
                // Corpse dwell (EntityAlive::OnDeathUpdate, TimeStayAfterDeath):
                // keep the body in world at hp 0 so the client's ragdoll is not
                // yanked mid-animation; the tick sweep destroys it later. A
                // second hit must not re-fire kill side effects (hp <= 0 guard
                // above already returns).
                self.health[s].hp = 0; // clamp: the wire stat shows 0, not the overkill
                // Stock EntityAlive timeStayAfterDeath default = 5 s (RE
                // entity-ai.md; the XML values 30/300 flow via class_id.time_stay
                // when the class declares the property). 5 s fallback, not 300/30.
                const dwell: f32 = if (self.mask[s].class_id and self.class_id[s].time_stay > 0)
                    self.class_id[s].time_stay
                else
                    5.0;
                self.health[s].corpse_seconds = dwell;
                // The corpse does not act: stop its AI and any chase.
                if (self.mask[s].zombie_ai) {
                    self.zombie_ai[s].state = .idle;
                    self.zombie_ai[s].target_id = -1;
                    self.zombie_ai[s].alert = false;
                }
                if (!self.rollLootDrop(nid, drop_prob)) {
                    // zPackReg is a 4% bag: most kills drop nothing, like stock.
                    return .{ .killed = true, .loot_bag_id = -1, .loot_list = loot_name, .kill_scale_pct = kill_scale };
                }
                const loot = self.spawnLootBag(x, y, z, 1, 5);
                return .{
                    .killed = true,
                    .loot_bag_id = if (loot) |id| id else -1,
                    .loot_list = loot_name,
                    .kill_scale_pct = kill_scale,
                };
            }
            // Players stay in the world dead (stock death → respawn flow keeps
            // the entity; destroy() here silently desyncs the client and breaks
            // every later net-id lookup: give/kill/tele all "miss").
            if (self.kind[s] == .player) {
                self.health[s].hp = 0;
                // EntityPlayer death sets IsBloodMoonDead = BloodMoonActive
                // (asm.il 412541-412547); the horde then ignores this player.
                if (self.mask[s].player) {
                    self.player[s].is_blood_moon_dead = self.director.clock.isBloodMoonNight();
                }
                self.reviveSlot(s); // no-op here (slot was never removed), but
                // keeps every alive[] = true in the repo on one path.
                return .{ .killed = true };
            }
            self.destroy(s);
            return .{ .killed = true };
        }
        // Non-fatal zombie/animal hit: knock the victim away from the attacker
        // (melee/gun shove). Players are the client's own body (the client
        // plays the hit reaction locally); traders are immune.
        if (self.kind[s] == .zombie or self.kind[s] == .animal) {
            var kx: f32 = 0;
            var kz: f32 = 0;
            if (attacker_net_id >= 0 and self.mask[s].transform) {
                if (self.slotOfNetId(attacker_net_id)) |as_| {
                    if (self.mask[as_].transform) {
                        const dx = self.transform[s].x - self.transform[as_].x;
                        const dz = self.transform[s].z - self.transform[as_].z;
                        const d2 = dx * dx + dz * dz;
                        if (d2 > 0.0001) {
                            const inv = 1.0 / @sqrt(d2);
                            kx = dx * inv;
                            kz = dz * inv;
                        }
                    }
                }
            }
            if (kx != 0 or kz != 0) {
                if (self.mask[s].zombie_ai) {
                    const ai = &self.zombie_ai[s];
                    ai.kb_time = self.rules.combat.knockback_seconds;
                    ai.kb_dx = kx;
                    ai.kb_dz = kz;
                }
                return .{ .knocked = true };
            }
        }
        return .{};
    }

    pub fn setPos(self: *World, net_id: NetId, x: f32, y: f32, z: f32, yaw: f32) void {
        const s = self.slotOfNetId(net_id) orelse return;
        if (!self.mask[s].transform) return;
        self.transform[s] = .{ .x = x, .y = y, .z = z, .yaw = yaw };
        self.markDirty(s, .{ .pos = true, .rot = true });
    }

    pub fn countKind(self: *const World, kind: Kind) u32 {
        return self.kind_groups.count(kind);
    }

    /// Corpse sweep: decrement dwell timers; destroy expired corpses. Returns
    /// the count written to `out`, which the caller broadcasts as EntityRemove.
    pub fn sweepCorpses(self: *World, dt: f32, out: []NetId) usize {
        var n: usize = 0;
        // O(live): only living slots can hold a corpse timer. destroy() of the
        // current slot is safe for the bitset iterator (the bit is already
        // consumed); later corpses stay set and still tick this pass.
        var it = self.alive_bits.iterator(.{});
        while (it.next()) |idx| {
            const s: Slot = @intCast(idx);
            if (self.health[s].corpse_seconds <= 0) continue;
            // Report list full: stop before a removal nobody would be told
            // about (destroy without EntityRemove leaves a permanent client
            // ghost). The remaining corpses keep their dwell and expire on a
            // later tick, like systemTurrets' kill-report cap.
            if (n >= out.len) break;
            self.health[s].corpse_seconds -= dt;
            if (self.health[s].corpse_seconds > 0) continue;
            out[n] = self.network_id[s].id;
            n += 1;
            self.destroy(s);
        }
        return n;
    }

    /// Enqueue a deferred sim op (spawn/despawn/damage). Drops when full.
    pub fn pushCommand(self: *World, op: CommandOp) bool {
        return self.commands.push(op);
    }

    /// Apply and clear the ops queued at entry; ops pushed during drain stay for the next tick.
    /// `pre_drain_fn` runs first (plugin withdrawal) so a disabled module's
    /// still-pending commands are dropped before they apply.
    pub fn drainCommands(self: *World) command.DrainResult {
        if (self.pre_drain_fn) |f| f(self.pre_drain_ctx);
        return self.commands.drain(self);
    }

    pub fn netId(self: *const World, slot: Slot) NetId {
        return self.network_id[slot].id;
    }

    /// The single sanctioned way to raise a dirty bit: writing `dirty[]` behind
    /// this funnel drifts `dirty_bits`, and replication would then miss or
    /// re-visit the slot.
    pub fn markDirty(self: *World, slot: Slot, bits: c.Dirty) void {
        if (slot >= max_entities or !self.alive[slot]) return;
        self.mask[slot].dirty = true;
        if (bits.pos) self.dirty[slot].pos = true;
        if (bits.rot) self.dirty[slot].rot = true;
        if (bits.flags) self.dirty[slot].flags = true;
        if (bits.hp) self.dirty[slot].hp = true;
        if (bits.spawn) self.dirty[slot].spawn = true;
        if (bits.remove) self.dirty[slot].remove = true;
        if (bits.inv) self.dirty[slot].inv = true;
        if (bits.any()) self.dirty_bits.set(slot);
    }

    /// Resync `dirty_bits[slot]` after a caller cleared bits in `dirty[slot]`
    /// directly (the replicate post-pass). Lowering a bit has no funnel of its
    /// own because the clear set differs per caller.
    pub fn syncDirtyBit(self: *World, slot: Slot) void {
        if (slot >= max_entities) return;
        if (self.alive[slot] and self.dirty[slot].any()) {
            self.dirty_bits.set(slot);
        } else {
            self.dirty_bits.unset(slot);
        }
    }
};

test "spawnPlayer starter kit fails closed when name resolve returns 0" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const Ctx = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) u16 {
            if (std.mem.eql(u8, name, "foodCanBeef")) return 2;
            return 0;
        }
    };
    w.item_id_fn = &Ctx.lookup;
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    try std.testing.expect(w.inventory[ps].countItem(2) >= 1);
    try std.testing.expectEqual(@as(u32, 0), w.inventory[ps].countItem(8));
    try std.testing.expectEqual(@as(u32, 0), w.inventory[ps].countItem(7));
    try std.testing.expectEqual(@as(u32, 0), w.inventory[ps].countItem(6));
}

test "ecs spawn player zombie damage" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const z = w.spawnZombie(5, 70, 0, 50).?;
    try std.testing.expect(w.slotOfNetId(p) != null);
    try std.testing.expect(w.slotOfNetId(z) != null);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    const ps = w.playerByPeer(0).?;
    try std.testing.expect(w.mask[ps].inventory);
    try std.testing.expect(w.inventory[ps].countItem(8) >= 1);
    try std.testing.expect(w.damage(z, 100).killed);
    // Corpse dwell: the body stays at hp 0 until the sweep destroys it.
    const zs = w.slotOfNetId(z) orelse return error.TestUnexpectedResult;
    try std.testing.expect(w.health[zs].hp <= 0);
    try std.testing.expect(w.health[zs].corpse_seconds > 0);
    var out: [2]NetId = undefined;
    try std.testing.expectEqual(@as(usize, 1), w.sweepCorpses(1000, &out));
    try std.testing.expect(w.slotOfNetId(z) == null);
}

test "damage ignores non-positive amount and already-dead players" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    try std.testing.expect(!w.damage(p, 0).killed);
    try std.testing.expect(!w.damage(p, -10).killed);
    try std.testing.expect(w.damage(p, 9999).killed);
    // Second kill must not re-fire (DropOnDeath / quest side effects).
    try std.testing.expect(!w.damage(p, 1).killed);
    const ps = w.slotOfNetId(p).?;
    try std.testing.expectEqual(@as(f32, 0), w.health[ps].hp);
    try std.testing.expect(w.alive[ps]);
}

test "damageFrom records the attacker as the revenge target" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const p = w.spawnPlayer(5, 70, 0, 0).?;
    const zs = w.slotOfNetId(z).?;
    _ = w.damageFrom(z, 3, p);
    try std.testing.expectEqual(p, w.zombie_ai[zs].revenge_target);
    try std.testing.expectEqual(@as(f32, 20.0), w.zombie_ai[zs].revenge_time); // rules.ai default
    // Unattributed and self-inflicted damage leave the target alone.
    w.zombie_ai[zs] = .{};
    _ = w.damage(z, 3);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
    _ = w.damageFrom(z, 3, z);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
    // A zero-damage claim is not an attack.
    _ = w.damageFrom(z, 0, p);
    try std.testing.expectEqual(@as(i32, -1), w.zombie_ai[zs].revenge_target);
}

test "loot bag drops only on LootDropProb" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    // A 0-prob class never drops a bag (stock regular zombie is .04).
    w.setClassDef(1, .{ .name = "z", .kind = .zombie, .hash = 1, .drop_prob = 0 });
    const z = w.spawnZombie(0, 70, 0, 40).?;
    const r = w.damage(z, 100);
    try std.testing.expect(r.killed);
    try std.testing.expectEqual(@as(i32, -1), r.loot_bag_id);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.loot_bag));
    // A 1.0 class always drops (offline/builtin default keeps tests stable).
    w.setClassDef(1, .{ .name = "z", .kind = .zombie, .hash = 1, .drop_prob = 1 });
    const z2 = w.spawnZombie(0, 70, 0, 40).?;
    const r2 = w.damage(z2, 100);
    try std.testing.expect(r2.killed);
    try std.testing.expect(r2.loot_bag_id > 0);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.loot_bag));
}

test "spawnLootBagFrom copies a slot range into the death bag" {
    // DropOnDeath: the bag carries the victim's real inventory range (mode 1
    // toolbelt+backpack, 2 toolbelt, 3 backpack), not a placeholder unit.
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const p = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.slotOfNetId(p).?;
    // Seed the toolbelt and the backpack with distinct items.
    w.inventory[ps].slots[3] = .{ .item_id = 7, .count = 5 };
    w.inventory[ps].slots[10 + 4] = .{ .item_id = 9, .count = 2 };
    // Mode 2 (toolbelt only): the bag holds slot 3, not the backpack slot.
    const b2 = w.spawnLootBagFrom(0, 70, 2, &w.inventory[ps], 0, c.inv_toolbelt).?;
    const bs2 = w.slotOfNetId(b2).?;
    // Offsets are preserved (bag slot 3 = source slot 3).
    try std.testing.expectEqual(@as(u16, 7), w.inventory[bs2].slots[3].item_id);
    try std.testing.expectEqual(@as(u16, 5), w.inventory[bs2].slots[3].count);
    // The backpack item is outside the toolbelt range: not in the mode-2 bag.
    try std.testing.expectEqual(@as(u16, 0), w.inventory[bs2].slots[10 + 4].item_id);
    // Mode 3 (backpack only): the bag holds the backpack slot.
    const b3 = w.spawnLootBagFrom(0, 70, 3, &w.inventory[ps], c.inv_bag_start, c.inv_equip_start).?;
    const bs3 = w.slotOfNetId(b3).?;
    try std.testing.expectEqual(@as(u16, 9), w.inventory[bs3].slots[4].item_id); // 14-10
    try std.testing.expectEqual(@as(u16, 2), w.inventory[bs3].slots[4].count);
}

test "per-tick path budget stride is derived from last tick demand" {
    var w: World = .{};
    defer w.deinit();
    w.path_replans.store(4, .monotonic);
    w.beginTick();
    try std.testing.expectEqual(@as(u32, 1), w.path_stride);
    try std.testing.expectEqual(@as(u32, 0), w.path_replans.load(.monotonic));
    // Demand above the cap spreads over as many ticks as it takes, up to the
    // delay ceiling.
    w.path_replans.store(World.path_replans_per_tick, .monotonic);
    w.path_replans_denied.store(World.path_replans_per_tick, .monotonic);
    w.beginTick();
    try std.testing.expectEqual(@as(u32, 2), w.path_stride);
    // Every slot is admitted eventually: over `stride` consecutive ticks the
    // rotating phase covers all of them exactly once.
    var seen: u32 = 0;
    var k: u32 = 0;
    while (k < w.path_stride) : (k += 1) {
        if (w.pathBudgetAdmits(7)) seen += 1;
        w.path_tick +%= 1;
    }
    try std.testing.expectEqual(@as(u32, 1), seen);
}

test "net id lookup falls back to authoritative columns when index misses" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(1, 2, 3, 40).?;
    const expected = w.slotOfNetId(id).?;
    try std.testing.expect(w.net_to_slot.remove(id));
    // Healthy map: a miss is authoritative (no per-miss full scan).
    try std.testing.expectEqual(null, w.slotOfNetId(id));
    // Degraded map (failed insert): the SoA scan recovers the entry.
    w.net_map_degraded = true;
    try std.testing.expectEqual(expected, w.slotOfNetId(id).?);
}

test "player peer index follows replacement and destroy" {
    var w: World = .{};
    defer w.deinit();
    const first_id = w.spawnPlayer(0, 70, 0, 3).?;
    const first = w.slotOfNetId(first_id).?;
    try std.testing.expectEqual(first, w.playerByPeer(3).?);

    const second_id = w.spawnPlayer(1, 70, 0, 4).?;
    const second = w.slotOfNetId(second_id).?;
    try std.testing.expectEqual(second, w.playerByPeer(4).?);

    w.destroy(second);
    try std.testing.expect(w.playerByPeer(4) == null);
    try std.testing.expectEqual(first, w.playerByPeer(3).?);
}

test "entity_count tracks spawn destroy and soft warn flag" {
    var w: World = .{};
    defer w.deinit();
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    const z = w.spawnZombie(0, 70, 0, 40).?;
    try std.testing.expectEqual(@as(u16, 1), w.entity_count);
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.zombie));
    const zs = w.slotOfNetId(z).?;
    w.destroy(zs);
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
    try std.testing.expect(w.any_freed_this_tick);
    // Fill to soft threshold without allocating beyond max.
    var n: usize = 0;
    while (n < entity_warn_at) : (n += 1) {
        _ = w.spawnZombie(@floatFromInt(n), 70, 0, 40) orelse break;
    }
    try std.testing.expect(w.entity_count >= entity_warn_at);
    try std.testing.expect(w.entity_cap_warned);
    try std.testing.expectEqual(@as(u32, w.entity_count), w.countKind(.zombie));
}

test "spawnZombieFromClass fills from class_table" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    w.class_table[1].max_hp = 55;
    w.class_table[1].hash = 12345;
    w.class_table[1].loot_list = "EntityLootContainerStrong";
    const id = w.spawnZombieFromClass("zombie", 3, 70, 4).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 55), w.health[s].max_hp);
    try std.testing.expectEqual(@as(i32, 12345), w.class_id[s].hash);
    try std.testing.expectEqualStrings("EntityLootContainerStrong", w.class_id[s].loot_list);
    try std.testing.expect(w.spawnZombieFromClass("nope", 0, 0, 0) == null);
}

test "spawnSleeperDef carries per-entity class stats" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnSleeperDef(3, 70, 4, .{
        .name = "zombieFeral",
        .max_hp = 60,
        .kind = .zombie,
        .hash = 12345,
        .loot_list = "EntityLootContainerStrong",
        .chase_speed = 1.1,
        .wander_speed = 0.3,
        .attack_damage = 25,
    }, 0).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expect(w.mask[s].sleeper);
    try std.testing.expect(w.sleeper[s].volume_r > 0);
    try std.testing.expectEqual(c.AiState.sleep, w.zombie_ai[s].state);
    // The A35 per-entity layer: speeds/damage/hash/loot survive on the entity
    // so the AI reads them even though class_table has no feral row.
    try std.testing.expectEqual(@as(f32, 1.1), w.class_id[s].chase_speed);
    try std.testing.expectEqual(@as(f32, 0.3), w.class_id[s].wander_speed);
    try std.testing.expectEqual(@as(f32, 25), w.class_id[s].attack_damage);
    try std.testing.expectEqual(@as(f32, 60), w.health[s].max_hp);
    try std.testing.expectEqual(@as(i32, 12345), w.class_id[s].hash);
    try std.testing.expectEqualStrings("EntityLootContainerStrong", w.class_id[s].loot_list);
    // The wake-threshold roll: a class without SleeperSightToWake* uses the
    // stock default ranges (-40..5 / 340..480) and the roll is deterministic
    // per spawn (same position + class → same thresholds, inside the ranges).
    const near0 = w.sleeper[s].wake_light_near;
    const far0 = w.sleeper[s].wake_light_far;
    try std.testing.expect(near0 >= -40.0 and near0 <= 5.0);
    try std.testing.expect(far0 >= 340.0 and far0 <= 480.0);
    const id2 = w.spawnSleeperDef(3, 70, 4, .{
        .name = "zombieFeral",
        .max_hp = 60,
        .kind = .zombie,
        .hash = 12345,
        .loot_list = "EntityLootContainerStrong",
    }, 0).?;
    const s2 = w.slotOfNetId(id2).?;
    try std.testing.expectEqual(near0, w.sleeper[s2].wake_light_near);
    try std.testing.expectEqual(far0, w.sleeper[s2].wake_light_far);
    // A class carrying the ranges rolls inside them.
    const id3 = w.spawnSleeperDef(9, 70, 9, .{
        .name = "custom",
        .hash = 7,
        .kind = .zombie,
        .sleeper_wake_near_min = 0.0,
        .sleeper_wake_near_max = 0.0,
        .sleeper_wake_far_min = 10.0,
        .sleeper_wake_far_max = 20.0,
    }, 0).?;
    const s3 = w.slotOfNetId(id3).?;
    try std.testing.expect(w.sleeper[s3].wake_light_near >= -40.0 and w.sleeper[s3].wake_light_near <= 5.0);
    try std.testing.expect(w.sleeper[s3].wake_light_far >= 10.0 and w.sleeper[s3].wake_light_far <= 20.0);
}

test "MoveSpeedRand rolls the day chase per entity, deterministically" {
    // RE entity-ai.md 3318-3320: moveSpeedRand adds a per-entity roll to the
    // day chase when aggro < 1 (clamp min 0.1, cap at aggro max). The roll is
    // deterministic per spawn (position + class hash) and lands in
    // [0.1, aggroMax]; a class without the prop keeps the unrolled value.
    var w: World = .{};
    defer w.deinit();
    const def = EntityClass{
        .name = "zombieBoe",
        .hash = 1,
        .kind = .zombie,
        .chase_speed_day = 0.2,
        .chase_speed = 1.25,
        .move_speed_rand_min = -0.2,
        .move_speed_rand_max = 0.25,
    };
    const z = w.spawnZombieDef(0, 70, 0, 40, def).?;
    const s = w.slotOfNetId(z).?;
    const rolled = w.class_id[s].chase_speed_day;
    try std.testing.expect(rolled >= 0.1 and rolled <= 1.25);
    // Same position + class → same roll (deterministic); a different
    // position rolls differently in general.
    const z2 = w.spawnZombieDef(0, 70, 0, 40, def).?;
    const s2 = w.slotOfNetId(z2).?;
    try std.testing.expectEqual(rolled, w.class_id[s2].chase_speed_day);
    // No MoveSpeedRand prop: unrolled.
    const plain = w.spawnZombieDef(5, 70, 5, 40, .{
        .name = "zombieBoe",
        .hash = 1,
        .kind = .zombie,
        .chase_speed_day = 0.2,
        .chase_speed = 1.25,
    }).?;
    try std.testing.expectEqual(@as(f32, 0.2), w.class_id[w.slotOfNetId(plain).?].chase_speed_day);
    // An aggro >= 1 day value is not rolled (the stock `aggro < 1` gate).
    const dog = w.spawnZombieDef(7, 70, 7, 40, .{
        .name = "dog",
        .hash = 2,
        .kind = .zombie,
        .chase_speed_day = 1.2,
        .chase_speed = 1.3,
        .move_speed_rand_min = -0.2,
        .move_speed_rand_max = 0.25,
    }).?;
    try std.testing.expectEqual(@as(f32, 1.2), w.class_id[w.slotOfNetId(dog).?].chase_speed_day);
}

test "beginTick clears locals" {
    var w: World = .{};
    w.locals.interest_n = 9;
    w.beginTick();
    try std.testing.expectEqual(@as(u8, 0), w.locals.interest_n);
}

test "alive_bits and dirty_bits survive random spawn destroy churn" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    // Empty world: both sets start clear.
    try std.testing.expectEqual(@as(usize, 0), w.alive_bits.count());
    try std.testing.expectEqual(@as(usize, 0), w.dirty_bits.count());

    var prng = std.Random.DefaultPrng.init(0xb175e75);
    const rnd = prng.random();
    var op: usize = 0;
    while (op < 4000) : (op += 1) {
        switch (rnd.uintLessThan(u8, 4)) {
            0 => _ = w.spawnZombie(rnd.float(f32) * 100, 70, rnd.float(f32) * 100, 40),
            1 => w.destroy(rnd.uintLessThan(Slot, max_entities)),
            2 => w.markDirty(rnd.uintLessThan(Slot, max_entities), .{ .pos = true, .inv = true }),
            else => {
                const s = rnd.uintLessThan(Slot, max_entities);
                if (w.alive[s]) {
                    w.dirty[s] = .{};
                    w.syncDirtyBit(s);
                }
            },
        }
        // beginTick releases freed slots so allocSlot can recycle them.
        if (op % 37 == 0) w.beginTick();
    }
    // Fill to capacity so the full-table edge is covered too.
    while (w.spawnZombie(1, 70, 1, 40) != null) {}

    var s: Slot = 0;
    while (s < max_entities) : (s += 1) {
        try std.testing.expectEqual(w.alive[s], w.alive_bits.isSet(s));
        try std.testing.expectEqual(w.alive[s] and w.dirty[s].any(), w.dirty_bits.isSet(s));
    }
    try std.testing.expectEqual(@as(usize, max_entities), w.alive_bits.count());
}

test "slot recycle does not inherit the previous tenant's dirty bit" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(id).?;
    w.markDirty(s, .{ .hp = true, .inv = true });
    w.destroy(s);
    try std.testing.expect(!w.alive_bits.isSet(s));
    try std.testing.expect(!w.dirty_bits.isSet(s));
    // markDirty on a dead slot is a no-op, so a stale caller cannot resurrect it.
    w.markDirty(s, .{ .pos = true });
    try std.testing.expect(!w.dirty_bits.isSet(s));
    // Recycled slot starts from spawnBase's spawn|pos, nothing carried over.
    w.beginTick();
    const id2 = w.spawnZombie(1, 70, 1, 40).?;
    const s2 = w.slotOfNetId(id2).?;
    try std.testing.expectEqual(s, s2);
    try std.testing.expect(w.dirty_bits.isSet(s2));
    try std.testing.expect(!w.dirty[s2].hp and !w.dirty[s2].inv);
}

test "generation-counted handle invalidates after destroy" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    const id = w.spawnZombie(0, 70, 0, 40).?;
    const s = w.slotOfNetId(id).?;
    const h = w.handleOfSlot(s);
    try std.testing.expect(w.handleAlive(h));
    w.destroy(s);
    try std.testing.expect(!w.handleAlive(h));
    // Reuse slot: new gen must not match old handle.
    _ = w.spawnZombie(1, 70, 1, 40);
    try std.testing.expect(!w.handleAlive(h));
}

test "death during a blood moon sets IsBloodMoonDead, daytime death does not" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnPlayer(0, 70, 0, 0).?;
    const ps = w.playerByPeer(0).?;
    const nid = w.network_id[ps].id;
    // Blood-moon night: day 7, freq 7, after dusk.
    w.director.clock.day = 7;
    w.director.clock.hours = 22.0;
    w.director.clock.dawn = 6;
    w.director.clock.dusk = 18;
    w.director.clock.bloodmoon_frequency = 7;
    _ = w.damage(nid, 9999);
    try std.testing.expect(w.player[ps].is_blood_moon_dead);
    // Daytime death leaves the flag clear.
    w.player[ps].is_blood_moon_dead = false;
    w.director.clock.hours = 12.0;
    _ = w.damage(nid, 9999);
    try std.testing.expect(!w.player[ps].is_blood_moon_dead);
}

test "corpse dwell keeps the body at hp 0, then the sweep removes it" {
    var w: World = .{};
    defer w.deinit();
    const id = w.spawnZombie(0, 70, 0, 50).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 0), w.health[s].corpse_seconds);
    const killed = w.damage(id, 9999);
    try std.testing.expect(killed.killed);
    // The corpse stays in world (builtin class has no TimeStayAfterDeath, so
    // the stock EntityAlive default of 5 s applies) with its AI stopped.
    try std.testing.expect(w.alive[s]);
    try std.testing.expect(w.health[s].hp <= 0);
    try std.testing.expectEqual(@as(f32, 5), w.health[s].corpse_seconds);
    try std.testing.expect(w.zombie_ai[s].state == .idle);
    // A second hit must not re-fire kill side effects.
    const again = w.damage(id, 9999);
    try std.testing.expect(!again.killed);
    try std.testing.expect(w.alive[s]);
    // The sweep leaves the body until the dwell elapses, then destroys it.
    var out: [4]NetId = undefined;
    try std.testing.expectEqual(@as(usize, 0), w.sweepCorpses(2, &out));
    try std.testing.expect(w.alive[s]);
    try std.testing.expectEqual(@as(usize, 1), w.sweepCorpses(10, &out));
    try std.testing.expectEqual(id, out[0]);
    try std.testing.expect(!w.alive[s]);
}

test "sweepCorpses never destroys more than it reports" {
    var w: World = .{};
    defer w.deinit();
    try w.ensureNetMap(std.testing.allocator);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const id = w.spawnZombie(@floatFromInt(i), 70, 0, 10).?;
        try std.testing.expect(w.damage(id, 9999).killed);
    }
    // Buffer smaller than the expiring set: the overflow keeps its slot so the
    // caller never has to broadcast an EntityRemove it was not handed.
    var out: [2]NetId = undefined;
    try std.testing.expectEqual(@as(usize, 2), w.sweepCorpses(1000, &out));
    try std.testing.expectEqual(@as(u32, 3), w.countKind(.zombie));
    try std.testing.expectEqual(@as(usize, 2), w.sweepCorpses(1000, &out));
    try std.testing.expectEqual(@as(usize, 1), w.sweepCorpses(1000, &out));
    try std.testing.expectEqual(@as(u32, 0), w.countKind(.zombie));
}

test "AtomicBits concurrent set loses no bits" {
    const builtin = @import("builtin");
    if (builtin.single_threaded) return;
    // Ranges deliberately misaligned to the 64-slot word grid (the 3/5/6/7
    // worker splits in the parallel AI pass straddle words the same way), so
    // two threads write the same u64 word. A plain `|=` tears; the atomic
    // fetchOr must keep every bit.
    const ranges = [_][2]usize{ .{ 0, 70 }, .{ 70, 150 }, .{ 150, 300 }, .{ 300, 512 } };
    var bits = AtomicBits.initEmpty();
    const ThreadCtx = struct {
        bits: *AtomicBits,
        begin: usize,
        end: usize,
        fn run(ctx: *const @This()) void {
            var i = ctx.begin;
            while (i < ctx.end) : (i += 1) ctx.bits.set(i);
        }
    };
    var ctxs: [ranges.len]ThreadCtx = undefined;
    var threads: [ranges.len]std.Thread = undefined;
    var spawned: usize = 0;
    var spawn_err: ?anyerror = null;
    for (&threads, 0..) |*t, ti| {
        ctxs[ti] = .{ .bits = &bits, .begin = ranges[ti][0], .end = ranges[ti][1] };
        t.* = std.Thread.spawn(.{}, ThreadCtx.run, .{&ctxs[ti]}) catch |err| {
            spawn_err = err;
            break;
        };
        spawned += 1;
    }
    // ThreadCtx lives on this stack frame, so every thread that did start has
    // to be joined before returning, including on the spawn-failure path.
    for (threads[0..spawned]) |*t| t.join();
    if (spawn_err) |err| {
        std.debug.print("zdtd test: AtomicBits thread spawn failed: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    }
    var i: usize = 0;
    while (i < max_entities) : (i += 1) try std.testing.expect(bits.isSet(i));
    try std.testing.expectEqual(@as(usize, max_entities), bits.count());
}

test "spawnTurret applies the block-data combat stats through the hook" {
    // Rule 15: the placed turret's range/damage/fire interval come from the
    // autoTurret block data via the Game hook; zero fields keep the
    // component defaults.
    var w: World = .{};
    defer w.deinit();
    var stats: c.TurretBlockStats = .{ .max_distance = 30, .entity_damage = 32, .burst_fire_rate = 0.15 };
    w.turret_stats_fn = struct {
        fn f(ctx: ?*anyopaque) ?c.TurretBlockStats {
            const s: *c.TurretBlockStats = @ptrCast(@alignCast(ctx.?));
            return s.*;
        }
    }.f;
    w.turret_stats_ctx = &stats;
    const id = w.spawnTurret(5, 70, 5).?;
    const s = w.slotOfNetId(id).?;
    try std.testing.expectEqual(@as(f32, 30), w.turret[s].range);
    try std.testing.expectEqual(@as(f32, 32), w.turret[s].damage);
    try std.testing.expectEqual(@as(f32, 0.15), w.turret[s].fire_interval);
    // Without the hook the component defaults hold.
    var w2: World = .{};
    defer w2.deinit();
    const id2 = w2.spawnTurret(5, 70, 5).?;
    const s2 = w2.slotOfNetId(id2).?;
    try std.testing.expectEqual(@as(f32, 24), w2.turret[s2].range);
    try std.testing.expectEqual(@as(f32, 12), w2.turret[s2].damage);
}

test "spawnTurret honors a fail-closed turret_watts hook" {
    var w: World = .{};
    defer w.deinit();
    w.turret_watts_fn = struct {
        fn f(_: ?*anyopaque) f32 {
            return 0;
        }
    }.f;
    const id = w.spawnTurret(5, 70, 5).?;
    const s = w.slotOfNetId(id).?;
    const ni = w.power.indexOfId(w.turret[s].power_node).?;
    try std.testing.expectEqual(@as(f32, 0), w.power.nodes[ni].watts);
}
