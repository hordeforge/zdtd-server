// zdtd_bot — FPS bot addon (ADR 0026, docs/BOTS_SPEC.md / BOTS_PRD.md).
//
// A WebAssembly plugin that commands player-mesh FPS bots through the host's
// sense/act boundary. The servant (host) owns spawn/tick/replicate/kill/LOS
// and move caps; this module owns the *brain* — target selection, skill-scaled
// aim error and hit accuracy, lead-fire prediction, reaction gate, fire
// throttle, strafe/backpedal, low-health survival retreat and lost-sight
// combat memory — distilled from the Quake 3 / Doom 3 bot model, cross-
// pollinated with the 7dtd-clanker C# port (docs/q3-inspiration-notes.md,
// BOTS_SPEC §5.1). All inference is deterministic (per-slot LCG, no wall-clock
// noise).
//
// Improvements cross-pollinated FROM 7dtd-clanker/mod (BotBrain/BotCombat/Bot):
//   - backpedal when an enemy is too close        (BotBrain.Backpedal)
//   - skill- and distance-scaled hit accuracy     (TryShootBurst spread/difficulty)
//   - low-health survival retreat / hold fire     (BotCharacter.WantsToRetreat)
// Improvements this guest already carried that clanker borrowed back:
//   - per-slot LCG + deterministic burst cadence  (Bot.cs "zdtd_bot parity")
//
// Host imports (module "zdtd", bare field names — PLUGIN_DEV.md):
//   log(level, ptr, len)   write a log line
//   tick() -> i64          current server tick
//   queue(ptr, len)        queue a text SimCommand (spawn/move/look/shoot/...)
//   sense(ptr, len, token) fill a read-only world snapshot; returns bytes
//
// Exports: on_enable, on_tick, on_shutdown, on_admin_command.
// No libc, no WASI imports (freestanding wasm32).
//
// Build (clang, committed as mods/zdtd_bot/zdtd_bot.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_bot/zdtd_bot.wasm mods/zdtd_bot/zdtd_bot.c

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);
__attribute__((import_module("zdtd"), import_name("tick")))
extern long long zdtd_tick(void);
__attribute__((import_module("zdtd"), import_name("queue")))
extern int zdtd_queue(int ptr, int len);
__attribute__((import_module("zdtd"), import_name("sense")))
extern int zdtd_sense(int ptr, int len, int token);

// ---------------------------------------------------------------------------
// Output / log helpers (no libc: build bytes in a static buffer).
// ---------------------------------------------------------------------------

#define OUT_CAP 200
static char out[OUT_CAP];
static int out_n;

static void e(const char *s) {
  while (*s && out_n < OUT_CAP - 1) out[out_n++] = *s++;
}
static void e_int(long long v) {
  char t[24];
  int n = 0;
  if (v == 0) {
    t[n++] = '0';
  } else {
    if (v < 0) { if (out_n < OUT_CAP - 1) out[out_n++] = '-'; v = -v; }
    while (v > 0 && n < 23) { t[n++] = (char)('0' + (int)(v % 10)); v /= 10; }
  }
  // Copy exactly n reversed digits. Never via e(): t is a local buffer that is
  // NOT nul-terminated, so e() would read past it into stray stack bytes.
  int i;
  for (i = n - 1; i >= 0; --i) {
    if (out_n < OUT_CAP - 1) out[out_n++] = t[i];
  }
}
static void e_flt(float v) {
  // Two-decimal rendering; enough for debug and commands we send. Sign is
  // emitted first, then |v| is split: (long long) truncates toward zero, which
  // would silently drop the sign of -0.42 and mislead the host's parseFloat.
  if (v < 0.f) { if (out_n < OUT_CAP - 1) out[out_n++] = '-'; v = -v; }
  long long whole = (long long)v;
  int frac = (int)((v - (float)whole) * 100.0f + 0.5f);
  if (frac == 100) { whole += 1; frac = 0; }
  e_int(whole);
  e(".");
  if (frac < 10) e("0");
  e_int(frac);
}
static void flush(int level) {
  if (out_n > 0) {
    zdtd_log(level, (int)(long)&out[0], out_n);
    out_n = 0;
  }
}
// Intentional-but-unused helper surface (kept as documented API; -Wall clean).
static void reset_out(void) __attribute__((unused));
static void reset_out(void) { out_n = 0; }
static void queue_cmd(const char *s) __attribute__((unused));
static void queue_cmd(const char *s) {
  out_n = 0;
  e(s);
  zdtd_queue((int)(long)&out[0], out_n);
  out_n = 0;
}

// Render a signed integer into a caller buffer, returning bytes written.
static int e_to(char *b, int cap, long long v) {
  char t[24];
  int n = 0, w = 0;
  if (v == 0) { if (cap > 0) b[w++] = '0'; }
  else {
    if (v < 0) { if (w < cap) b[w++] = '-'; v = -v; }
    while (v > 0 && n < 23) { t[n++] = (char)('0' + v % 10); v /= 10; }
    while (n > 0 && w < cap) b[w++] = t[--n];
  }
  return w;
}

// ---------------------------------------------------------------------------
// Sense snapshot parsing.
//
// Layout (BOTS_SPEC §3, all little-endian): header 16 bytes then fixed-stride
// 32-byte records. Parsed by explicit offsets so a C struct can never drift
// from the Zig packed records.
//   hdr: magic u32@0, count u32@4, tick u32@8, self_net_id i32@12
//   rec stride 32: net_id i32@0, kind u8@4, is_self u8@5, alive u8@6, pad@7,
//                  x f32@8, y f32@12, z f32@16, hp f32@20, yaw f32@24,
//                  target_id i32@28
// ---------------------------------------------------------------------------

#define SENSE_CAP 2048
static char sense[SENSE_CAP];
static int sense_n = 0;

#define REC_STRIDE 32
#define KIND_PLAYER 0
#define KIND_ZOMBIE 1
#define KIND_BOT 2

static int s8(int off)          { return (unsigned char)sense[off]; }
static int s32(int off) {
  unsigned char b0 = (unsigned char)sense[off];
  unsigned char b1 = (unsigned char)sense[off + 1];
  unsigned char b2 = (unsigned char)sense[off + 2];
  unsigned char b3 = (unsigned char)sense[off + 3];
  return (int)(b0 | (b1 << 8) | (b2 << 16) | ((unsigned)b3 << 24));
}
static float sf32(int off) {
  union { unsigned int u; float f; } conv;
  conv.u = (unsigned int)s32(off);
  return conv.f;
}

// Reparse the sense buffer into hosts (preserving its first `recs` records is
// not needed; we read offsets directly instead — see accessors below).
#define REC_OFF(i) (16 + (i) * REC_STRIDE)
static int rec_net(int i)        { return s32(REC_OFF(i) + 0); }
static int rec_kind(int i)       { return s8(REC_OFF(i) + 4); }
static float rec_x(int i)        { return sf32(REC_OFF(i) + 8); }
static float rec_y(int i)        { return sf32(REC_OFF(i) + 12); }
static float rec_z(int i)        { return sf32(REC_OFF(i) + 16); }
// Unused now, kept as documented sense-record accessors (rec_self/rec_target
// document the full record layout for future guest logic).
static int rec_self(int i) __attribute__((unused));
static int rec_self(int i)       { return s8(REC_OFF(i) + 5); }
static float rec_hp(int i)       { return sf32(REC_OFF(i) + 20); }
static float rec_yaw(int i)      { return sf32(REC_OFF(i) + 24); }
static float rec_target(int i) __attribute__((unused));
static float rec_target(int i)   { return s32(REC_OFF(i) + 28); }

// Refresh the snapshot. Returns the number of records (0 on failure/empty).
static int sense_refresh(void) {
  sense_n = zdtd_sense((int)(long)&sense[0], SENSE_CAP, 0);
  if (sense_n < 16) { sense_n = 0; return 0; }
  const int n = s32(4);
  const int avail = (sense_n - 16) / REC_STRIDE;
  return n < avail ? n : avail;
}

// ---------------------------------------------------------------------------
// Bot roster state (fixed-size; no heap). Each slot is keyed by net id.
// ---------------------------------------------------------------------------

#define MAX_BOTS 16
static int bot_net[MAX_BOTS];
static float bot_react[MAX_BOTS];   // seconds until a new target can be shot
static float bot_throttle[MAX_BOTS];// fire throttle flip-flop
static float bot_wander_x[MAX_BOTS];
static float bot_wander_z[MAX_BOTS];
static int bot_target[MAX_BOTS];
static int bot_skill[MAX_BOTS];     // default skill applied to spawned bot cfg ops
static float bot_vision[MAX_BOTS];  // per-bot vision override (0 = skill default)
static float bot_reaction[MAX_BOTS];// per-bot reaction override (0 = skill default)
// Brain-quality state (ADR 0026 / docs/q3-inspiration-notes.md).
static unsigned bot_rng[MAX_BOTS];  // deterministic per-slot LCG (no time noise)
static float bot_aimerr[MAX_BOTS];  // skill-scaled aim error, rolled per engagement
static float bot_last_yaw[MAX_BOTS];// last look we emitted (command gating)
static int   bot_look_sent[MAX_BOTS];
static float bot_last_mx[MAX_BOTS]; // last move destination we emitted
static float bot_last_mz[MAX_BOTS];
static int   bot_move_sent[MAX_BOTS];
static int   bot_engage[MAX_BOTS];  // ticks with the current target (aim/strafe cadence)
static float bot_tpx[MAX_BOTS];     // last seen target position + smoothed velocity
static float bot_tpz[MAX_BOTS];     // for lead-fire prediction
static float bot_tvx[MAX_BOTS];
static float bot_tvz[MAX_BOTS];
static int   bot_strafe_p[MAX_BOTS];// strafe phase flip latch (skill>=3)
static int   bot_lock[MAX_BOTS];    // net id of target pursued via memory (-1 = none)
static int   bot_memage[MAX_BOTS];  // ticks since we last saw the locked target
static float bot_last_hp[MAX_BOTS]; // own hp from the previous sense pass (hit detect)
static int   bot_dodge[MAX_BOTS];   // ticks left in an evasive dodge (0 = none)
static int   bot_seen[MAX_BOTS];    // scratch: roster slot present in this sense pass
static float bot_last_x[MAX_BOTS];  // own position from the previous pass (stuck detect)
static float bot_last_z[MAX_BOTS];
static int   bot_stuck_ticks[MAX_BOTS];
static int bot_count_static;        // our remembered `bot count` floor (host also enforces)

static void bot_init(void) {
  int i;
  for (i = 0; i < MAX_BOTS; ++i) {
    bot_net[i] = -1;
    bot_react[i] = 0.f;
    bot_throttle[i] = 0.f;
    bot_wander_x[i] = 0.f;
    bot_wander_z[i] = 0.f;
    bot_target[i] = -1;
    bot_skill[i] = 2;
    bot_vision[i] = 0.f;
    bot_reaction[i] = 0.f;
    bot_rng[i] = 0u;
    bot_aimerr[i] = 0.f;
    bot_last_yaw[i] = 0.f;
    bot_look_sent[i] = 0;
    bot_last_mx[i] = 0.f;
    bot_last_mz[i] = 0.f;
    bot_move_sent[i] = 0;
    bot_engage[i] = 0;
    bot_tpx[i] = 0.f;
    bot_tpz[i] = 0.f;
    bot_tvx[i] = 0.f;
    bot_tvz[i] = 0.f;
    bot_strafe_p[i] = 0;
    bot_lock[i] = -1;
    bot_memage[i] = 0;
    bot_last_hp[i] = 0.f;
    bot_dodge[i] = 0;
    bot_last_x[i] = 0.f;
    bot_last_z[i] = 0.f;
    bot_stuck_ticks[i] = 0;
  }
  bot_count_static = 0;
}

// Index of the roster entry for a net id, or -1.
static int bot_find(int net_id) {
  int i;
  for (i = 0; i < MAX_BOTS; ++i) if (bot_net[i] == net_id) return i;
  return -1;
}
static int bot_slot_alloc(void) {
  int i;
  for (i = 0; i < MAX_BOTS; ++i) if (bot_net[i] < 0) return i;
  return -1;
}

// ---------------------------------------------------------------------------
// Brain (Q3 / Doom 3 inspired, distilled; cross-pollinated with 7dtd-clanker).
// ---------------------------------------------------------------------------

#define TICK_DT 0.05f            // one tick in seconds

// Forward declarations (freestanding C needs them before use).
static float sqrtf_impl(float x);
static float atan2f_impl(float y, float x);
static int rec_kind_alive(int i);
static int st(char *b, int cap, const char *s);
static int eq(char *s, int slen, const char *w, int wlen);
static long strtol_impl(const char *s);

// Build and queue "bot move id x y z speed".
static void queue_move(int id, float x, float y, float z, float speed) {
  out_n = 0;
  e("bot move "); e_int(id);
  e(" "); e_flt(x); e(" "); e_flt(y); e(" "); e_flt(z); e(" "); e_flt(speed);
  zdtd_queue((int)(long)&out[0], out_n);
  out_n = 0;
}
static void queue_look(int id, float yaw) {
  out_n = 0;
  e("bot look "); e_int(id); e(" "); e_flt(yaw);
  zdtd_queue((int)(long)&out[0], out_n);
  out_n = 0;
}
static void queue_shoot(int id, int target) {
  out_n = 0;
  e("bot shoot "); e_int(id); e(" "); e_int(target);
  zdtd_queue((int)(long)&out[0], out_n);
  out_n = 0;
}
// Headshot variant: "bot shoot <id> <target> head" (cross-pollinated from
// clanker TryShootBurst HeadshotChance/HeadshotMultiplier). The host applies
// the headshot multiplier when the trailing token is present.
static void queue_shoot_head(int id, int target) {
  out_n = 0;
  e("bot shoot "); e_int(id); e(" "); e_int(target); e(" head");
  zdtd_queue((int)(long)&out[0], out_n);
  out_n = 0;
}

// Skill-scaled reaction and vision (Q3 skill 0..4).
static float skill_vision(int skill) { return 25.f + 8.f * (float)skill; }
static float skill_reaction(int skill) {
  float r = 0.6f - 0.11f * (float)skill;
  return r < 0.08f ? 0.08f : r;
}
// Skill-scaled one-sided aim error in radians: low skill sprays (~0.28 rad),
// high skill is near-deadly (~0.06 rad). The error is rolled per engagement
// and held, so a bot "settles" its aim rather than jittering every frame.
static float skill_aimerr(int skill) { return 0.28f - 0.055f * (float)skill; }

// Deterministic 32-bit LCG (Q3 bot uses per-bot state; we keep it seeded from
// the slot/net id and never drive it with wall-clock noise, AZ 22).
static unsigned rng_next(unsigned *s) {
  *s = *s * 1103515245u + 12345u;
  return *s;
}
static float rng_f01(unsigned *s) {
  return (float)((rng_next(s) >> 8) & 0x00ffffffu) / 16777216.0f; // [0,1)
}
static float rng_sym(unsigned *s) { return 2.f * rng_f01(s) - 1.f; } // [-1,1)

// Command gating (AD 20 / AZ 20: stream under caps). Only re-send a bot
// look/move when the value changed beyond a deadband, or never yet sent (the
// first emission always goes out so the first tick is visible/tests).
static int look_dirty(int bslot, float yaw) {
  if (!bot_look_sent[bslot]) return 1;
  float d = yaw - bot_last_yaw[bslot];
  while (d > 3.14159265f) d -= 6.2831853f;
  while (d < -3.14159265f) d += 6.2831853f;
  return d > 0.015f || d < -0.015f;
}
static int move_dirty(int bslot, float mx, float mz) {
  if (!bot_move_sent[bslot]) return 1;
  float dx = mx - bot_last_mx[bslot], dz = mz - bot_last_mz[bslot];
  return dx * dx + dz * dz > 0.25f; // > ~half a block of change
}
// Assumed muzzle velocity (blocks/s) used for lead-fire. Tune to the weapon; a
// stationary target always yields lead == 0 regardless of this value.
#define BULLET_SPEED 40.f
// How many ticks (20 TPS) a bot keeps pursuing a target's last-known position
// after it leaves the host LOS-filtered sense view (5 s) before giving up and
// reverting to wander. Q3 combat memory, distilled.
#define BOT_MEMORY_TICKS 100
// Cross-pollinated from 7dtd-clanker BotBrain.Backpedal: when an enemy closes
// within this many blocks the bot backs away / circles instead of planting.
#define BACKPEDAL_RANGE 6.f
// Cross-pollinated from 7dtd-clanker BotCharacter.WantsToRetreat: below this
// health fraction a low-skill bot retreats and holds fire (self-preservation).
#define HP_RETREAT_FRAC 0.35f
// Any bot below this health fraction flees regardless of skill (clanker's
// WantsToRetreat has no skill gate; only its self-preservation personality).
#define HP_FLEE_FRAC 0.20f
// Cross-pollinated from 7dtd-clanker Bot.OnDamaged (dodge-on-hit): ticks of an
// evasive dodge after the bot's own hp drops; the first `DODGE_BACK_TICKS` are
// a backpedal, the rest a direction-flipped strafe. 10 ticks = 0.5 s.
#define DODGE_TICKS 10
#define DODGE_BACK_TICKS 4
// Ticks without any movement before a patrol bot re-picks its wander point
// (or jukes a memory-pursue destination) — cross-pollinated from clanker's
// stuck timer (`_stuckSince` + JumpOrStrafe). 20 ticks = 1 s.
#define STUCK_TICKS 20
// Bot spawn health used to normalize the hurt fraction (host spawns ~100 hp).
#define BOT_MAX_HP 100.f

// Skill- and distance-scaled hit probability (cross-pollinated from
// 7dtd-clanker TryShootBurst: spread / AimJitterDegrees scaled down by skill).
// Skill 0 ~34%, skill 4 ~94% at point blank; accuracy falls off with range.
static float skill_hit_chance(int skill, float dist) {
  float base = 0.34f + 0.15f * (float)skill;
  if (base > 0.95f) base = 0.95f;
  float dscale = 1.f - dist / 90.f;
  if (dscale < 0.2f) dscale = 0.2f;
  return base * dscale;
}
// Skill-scaled headshot chance (cross-pollinated from clanker TryShootBurst:
// cfg.HeadshotChance). Skill 0 ~5%, skill 4 ~25%.
static float skill_headshot(int skill) { return 0.05f + 0.05f * (float)skill; }
// Skill-scaled vision cone in radians (cross-pollinated from clanker
// BotBrain.FindTarget VisionAngle): skill 0 ~90 deg, skill 4 ~170 deg. The
// guest reads its own yaw from the sense record; a candidate beyond the cone
// is not acquired unless it is within CLOSE_SPOT_RANGE blocks.
static float skill_fov(int skill) { return 1.57f + 0.35f * (float)skill; }
#define CLOSE_SPOT_RANGE 7.f

// One on_tick pass: sense, then drive every bot we see.
static void brain_tick(void) {
  const int n = sense_refresh();
  if (n <= 0) return;

  // Roster hygiene: a slot whose bot is no longer in the sense view (died or
  // was despawned) is freed so `bot list`/`status` never show stale entries.
  int ri;
  for (ri = 0; ri < MAX_BOTS; ++ri) bot_seen[ri] = 0;
  for (ri = 0; ri < n; ++ri) {
    if (rec_kind(ri) != KIND_BOT) continue;
    const int s2 = bot_find(rec_net(ri));
    if (s2 >= 0) bot_seen[s2] = 1;
  }
  for (ri = 0; ri < MAX_BOTS; ++ri) {
    if (bot_net[ri] >= 0 && !bot_seen[ri]) bot_net[ri] = -1;
  }

  int bi;
  for (bi = 0; bi < n; ++bi) {
    if (rec_kind(bi) != KIND_BOT) continue;
    const int net = rec_net(bi);
    const float bx = rec_x(bi), by = rec_y(bi), bz = rec_z(bi);
    int bslot = bot_find(net);
    if (bslot < 0) {
      bslot = bot_slot_alloc();
      if (bslot < 0) continue;
      bot_net[bslot] = net;
      bot_react[bslot] = 0.f;
      bot_throttle[bslot] = 0.f;
      bot_target[bslot] = -1;
      bot_wander_x[bslot] = bx;
      bot_wander_z[bslot] = bz;
      // Deterministic per-slot RNG seed (no wall-clock noise).
      bot_rng[bslot] = (unsigned)net * 2654435761u + (unsigned)bslot * 97u + 1u;
      bot_aimerr[bslot] = 0.f;
      bot_look_sent[bslot] = 0;
      bot_move_sent[bslot] = 0;
      bot_engage[bslot] = 0;
      bot_tpx[bslot] = bx; bot_tpz[bslot] = bz;
      bot_tvx[bslot] = 0.f; bot_tvz[bslot] = 0.f;
      bot_strafe_p[bslot] = 0;
      bot_lock[bslot] = -1;
      bot_memage[bslot] = 0;
      bot_last_hp[bslot] = rec_hp(bi);
      bot_dodge[bslot] = 0;
    }
    const int skill = bot_skill[bslot];
    // Per-bot `bot cfg` overrides win over the skill-derived defaults.
    const float vision = bot_vision[bslot] > 0.f ? bot_vision[bslot] : skill_vision(skill);
    const float reaction = bot_reaction[bslot] > 0.f ? bot_reaction[bslot] : skill_reaction(skill);

    // Dodge-on-hit (cross-pollinated from 7dtd-clanker Bot.OnDamaged): if our
    // own hp dropped since the last sense pass we were damaged, trigger a short
    // evasive dodge and randomize the strafe direction. Pure guest-side: the
    // sense record already carries our hp, so no host/spec change is needed.
    if (bot_last_hp[bslot] > rec_hp(bi)) {
      bot_dodge[bslot] = DODGE_TICKS;
      bot_strafe_p[bslot] = rng_f01(&bot_rng[bslot]) < 0.5f ? 0 : 1;
    }
    bot_last_hp[bslot] = rec_hp(bi);

    // Stuck detection: if our position hasn't changed for STUCK_TICKS, the
    // wander/pursue branches re-pick (below) instead of grinding against an
    // obstacle forever (clanker `_stuckSince` + JumpOrStrafe parity).
    const float self_x = rec_x(bi), self_z = rec_z(bi);
    const float moved2 = (self_x - bot_last_x[bslot]) * (self_x - bot_last_x[bslot]) +
                         (self_z - bot_last_z[bslot]) * (self_z - bot_last_z[bslot]);
    bot_last_x[bslot] = self_x;
    bot_last_z[bslot] = self_z;
    if (moved2 < 0.0001f) {
      bot_stuck_ticks[bslot]++;
    } else {
      bot_stuck_ticks[bslot] = 0;
    }

    // Pick the nearest hostile candidate within vision (players/zombies/other
    // bots, not ourselves). Players are preferred over zombies/bots at equal
    // distance (cross-pollinated from clanker BotBrain.FindTarget: EntityPlayer
    // score * 0.82, other bots * 0.9 — squared here since we compare d2).
    // A candidate beyond the skill-scaled FOV cone is not acquired unless it
    // is very close (clanker: close targets always spotted).
    const float fov_half = skill_fov(skill) * 0.5f;
    const float face = rec_yaw(bi) - 1.570796f; // yaw zero faces +X (same as atan2)
    const float close2 = CLOSE_SPOT_RANGE * CLOSE_SPOT_RANGE;
    int ti = -1;
    float best_s = vision * vision;
    int j;
    for (j = 0; j < n; ++j) {
      if (j == bi) continue;
      if (!rec_kind_alive(j)) continue;
      const float dx = rec_x(j) - bx, dy = rec_y(j) - by, dz = rec_z(j) - bz;
      // 3D distance (clanker FindTarget uses Vector3.Distance): a target far
      // above/below the bot is outside vision just like one far horizontally.
      const float d2 = dx * dx + dy * dy + dz * dz;
      if (d2 > close2) {
        // Cone check: angular offset between facing and the candidate.
        float ang = atan2f_impl(dz, dx) - face;
        while (ang > 3.14159265f) ang -= 6.2831853f;
        while (ang < -3.14159265f) ang += 6.2831853f;
        if (ang < 0.f) ang = -ang;
        if (ang > fov_half) continue;
      }
      float score = d2;
      if (rec_kind(j) == KIND_PLAYER) score *= 0.67f;   // 0.82^2
      else if (rec_kind(j) == KIND_BOT) score *= 0.81f; // 0.9^2
      if (score < best_s) { best_s = score; ti = j; }
    }

    if (ti < 0) {
      // No host-visible threat. Prefer pursuing the last-known position of a
      // recently-seen target (Q3 combat memory): the host hides entities behind
      // LOS, so we keep closing on where it was instead of instantly forgetting
      // and wandering.
      float want_x, want_z;   // destination we head for
      float spd;              // move speed
      int pursue = (bot_lock[bslot] >= 0 && bot_memage[bslot] < BOT_MEMORY_TICKS);
      if (pursue) {
        bot_memage[bslot]++;
        want_x = bot_tpx[bslot]; want_z = bot_tpz[bslot];
        if (bot_stuck_ticks[bslot] >= STUCK_TICKS) {
          // Juke around the obstacle: offset the memory point perpendicularly
          // so the bot tries to go around instead of grinding (clanker
          // JumpOrStrafe parity).
          float pdx = want_x - bx, pdz = want_z - bz;
          float pl = sqrtf_impl(pdx * pdx + pdz * pdz);
          if (pl > 0.1f) {
            float ox2 = -pdz / pl, oz2 = pdx / pl;
            float jd = (bi & 1) ? 3.f : -3.f;
            want_x += ox2 * jd;
            want_z += oz2 * jd;
          }
          bot_stuck_ticks[bslot] = 0;
        }
        spd = (skill >= 2) ? 4.2f : 3.2f; // hunt speed
      } else {
        if (bot_lock[bslot] >= 0) { bot_lock[bslot] = -1; bot_memage[bslot] = 0; }
        if (bot_wander_x[bslot] == 0.f && bot_wander_z[bslot] == 0.f) {
          bot_wander_x[bslot] = bx + 10.f;
          bot_wander_z[bslot] = bz + 8.f;
        }
        if (bot_stuck_ticks[bslot] >= STUCK_TICKS) {
          // Stuck patrol: pick a fresh wander point instead of grinding.
          bot_wander_x[bslot] = bx + ((bi % 5) - 2) * 6.f;
          bot_wander_z[bslot] = bz + 6.f;
          bot_stuck_ticks[bslot] = 0;
        }
        want_x = bot_wander_x[bslot]; want_z = bot_wander_z[bslot];
        spd = 1.4f; // slow patrol
      }
      float wdx = want_x - bx, wdz = want_z - bz;
      if (!pursue && wdx * wdx + wdz * wdz < 2.f) {
        // Reached the wander point: pick a new one.
        bot_wander_x[bslot] = bx + ((bi % 5) - 2) * 6.f;
        bot_wander_z[bslot] = bz + 6.f;
        want_x = bot_wander_x[bslot]; want_z = bot_wander_z[bslot];
        wdx = want_x - bx; wdz = want_z - bz;
      }
      float wyaw = atan2f_impl(wdz, wdx) + 1.570796f;
      if (look_dirty(bslot, wyaw)) {
        queue_look(net, wyaw);
        bot_last_yaw[bslot] = wyaw; bot_look_sent[bslot] = 1;
      }
      if (move_dirty(bslot, want_x, want_z)) {
        queue_move(net, want_x, by, want_z, spd);
        bot_last_mx[bslot] = want_x;
        bot_last_mz[bslot] = want_z;
        bot_move_sent[bslot] = 1;
      }
      // Drop a stale combat lock (a new engagement resets motion history).
      if (bot_target[bslot] != -1) {
        bot_target[bslot] = -1;
        bot_react[bslot] = 0.f;
      }
      continue;
    }

    const int target_net = rec_net(ti);
    const float tx = rec_x(ti), tz = rec_z(ti);
    if (bot_target[bslot] != target_net) {
      // New target: reset reaction, aim error and motion history.
      bot_target[bslot] = target_net;
      bot_react[bslot] = reaction;
      bot_engage[bslot] = 0;
      bot_tpx[bslot] = tx; bot_tpz[bslot] = tz;
      bot_tvx[bslot] = 0.f; bot_tvz[bslot] = 0.f;
      bot_aimerr[bslot] = skill_aimerr(skill) * rng_sym(&bot_rng[bslot]);
    } else {
      // Same target: estimate its velocity from our own observation history
      // (lead-fire). Kept entirely in the guest, so no host/spec change.
      float vx = (tx - bot_tpx[bslot]) / TICK_DT;
      float vz = (tz - bot_tpz[bslot]) / TICK_DT;
      bot_tvx[bslot] = bot_tvx[bslot] * 0.7f + vx * 0.3f;
      bot_tvz[bslot] = bot_tvz[bslot] * 0.7f + vz * 0.3f;
      bot_tpx[bslot] = tx; bot_tpz[bslot] = tz;
      bot_engage[bslot]++;
    }
    // This target is currently visible: keep it locked in memory so the bot can
    // pursue the last-known position if it later leaves the LOS-filtered sense
    // view (see the wander branch).
    bot_lock[bslot] = target_net;
    bot_memage[bslot] = 0;
    if (bot_react[bslot] > 0.f) bot_react[bslot] -= TICK_DT;

    const float dx = tx - bx, dz = tz - bz;
    const float dist = sqrtf_impl(dx * dx + dz * dz);
    // Safely-unitized toward / perpendicular vectors (guard dist -> 0).
    const float inv = dist > 0.001f ? 1.f / dist : 0.f;
    const float txn = dx * inv, tzn = dz * inv;   // toward (unit)
    const float oxn = -tzn, ozn = txn;            // perpendicular (unit)

    // Lead the target: predict where it will be when the shot arrives.
    float lead = dist / BULLET_SPEED;
    float lx = tx + bot_tvx[bslot] * lead;
    float lz = tz + bot_tvz[bslot] * lead;

    // Face the predicted point plus our skill-scaled, per-engagement aim error.
    float yaw = atan2f_impl(lz - bz, lx - bx) + 1.570796f + bot_aimerr[bslot];
    if (look_dirty(bslot, yaw)) {
      queue_look(net, yaw);
      bot_last_yaw[bslot] = yaw; bot_look_sent[bslot] = 1;
    }

    const float attack_range = (float)(skill >= 3 ? 30 : skill >= 1 ? 22 : 15);
    // Cross-pollinated from 7dtd-clanker: low-health + low-skill bots retreat
    // (self-preservation, BotCharacter.WantsToRetreat) — hold fire and back off.
    const float hp_frac = rec_hp(bi) / BOT_MAX_HP;
    // Retreat: nearly-dead bots of ANY skill flee and hold fire; low-skill
    // bots also retreat at the softer HP_RETREAT_FRAC threshold (clanker
    // WantsToRetreat parity).
    const int retreating = (hp_frac < HP_FLEE_FRAC) || (hp_frac < HP_RETREAT_FRAC && skill < 2);
    float mdest_x, mdest_z, mspd;
    if (dist < attack_range) {
      int sdir;
      if (skill >= 3) {
        // Higher-skill bots flip strafe direction on a deterministic cadence
        // rather than fixed parity, so they are less trivially predictable.
        if (bot_engage[bslot] % 16 == 0) bot_strafe_p[bslot] = !bot_strafe_p[bslot];
        sdir = bot_strafe_p[bslot] ? 1 : -1;
      } else {
        sdir = (bi & 1) ? 1 : -1;
      }
      const float s = (float)sdir;
      const int dodging = bot_dodge[bslot] > 0;
      if (dodging) {
        // Dodge-on-hit: forced evasive move that bypasses command gating so the
        // host always sees the burst. First DODGE_BACK_TICKS backpedal, then a
        // hard strafe on the randomized direction (cross-pollinated from
        // clanker Bot.OnDamaged).
        if (bot_dodge[bslot] > DODGE_TICKS - DODGE_BACK_TICKS) {
          mdest_x = bx - txn * 2.2f + oxn * s * 1.6f;
          mdest_z = bz - tzn * 2.2f + ozn * s * 1.6f;
        } else {
          mdest_x = bx + (tx - bx) * 0.2f + oxn * s * 2.0f;
          mdest_z = bz + (tz - bz) * 0.2f + ozn * s * 2.0f;
        }
        mspd = 4.f;
        queue_move(net, mdest_x, by, mdest_z, mspd);
        bot_last_mx[bslot] = mdest_x; bot_last_mz[bslot] = mdest_z;
        bot_move_sent[bslot] = 1;
      } else {
        if (retreating || dist < BACKPEDAL_RANGE) {
          // Cross-pollinated from clanker BotBrain.Backpedal: back away + circle.
          mdest_x = bx - txn * 1.7f + oxn * s * 1.1f;
          mdest_z = bz - tzn * 1.7f + ozn * s * 1.1f;
          mspd = 3.f;
        } else {
          // Strafe-orbit: mix toward the target and step perpendicular.
          mdest_x = bx + (tx - bx) * 0.3f + oxn * s * 1.0f;
          mdest_z = bz + (tz - bz) * 0.3f + ozn * s * 1.0f;
          mspd = 3.f;
        }
        if (move_dirty(bslot, mdest_x, mdest_z)) {
          queue_move(net, mdest_x, by, mdest_z, mspd);
          bot_last_mx[bslot] = mdest_x; bot_last_mz[bslot] = mdest_z;
          bot_move_sent[bslot] = 1;
        }
      }
      // Cross-pollinated from clanker TryShootBurst: a burst volley (2 shots at
      // skill < 3, 3 at skill >= 3), each with its own skill/distance hit roll
      // and a skill-scaled headshot roll — low-skill bots miss a lot, high-skill
      // bots land burst damage. The host applies damage per `bot shoot`.
      if (!retreating && bot_react[bslot] <= 0.f && bot_throttle[bslot] <= 0.f) {
        const int burst = (skill >= 3) ? 3 : 2;
        int k;
        for (k = 0; k < burst; ++k) {
          const float hc = skill_hit_chance(skill, dist);
          if (rng_f01(&bot_rng[bslot]) < hc) {
            if (rng_f01(&bot_rng[bslot]) < skill_headshot(skill)) {
              queue_shoot_head(net, target_net);
            } else {
              queue_shoot(net, target_net);
            }
          }
        }
        bot_throttle[bslot] = 0.25f + 0.2f * (float)(skill % 2); // burst pause
      }
    } else {
      // Chase toward the target's current ground position (lead is for aim).
      mdest_x = bx + dx * 0.4f;
      mdest_z = bz + dz * 0.4f;
      mspd = (skill >= 2) ? 4.2f : 3.2f;
      if (move_dirty(bslot, mdest_x, mdest_z)) {
        queue_move(net, mdest_x, by, mdest_z, mspd);
        bot_last_mx[bslot] = mdest_x; bot_last_mz[bslot] = mdest_z;
        bot_move_sent[bslot] = 1;
      }
    }
    if (bot_throttle[bslot] > 0.f) bot_throttle[bslot] -= TICK_DT;
    if (bot_dodge[bslot] > 0) bot_dodge[bslot]--;
  }
}

static int rec_kind_alive(int i) { return s8(REC_OFF(i) + 6); }

static float sqrtf_impl(float x) {
  // Newton approx on [0,~big]; good enough for range checks.
  if (x <= 0.f) return 0.f;
  float y = x > 1.f ? x * 0.5f : 1.f;
  int i;
  for (i = 0; i < 6; ++i) y = 0.5f * (y + x / y);
  return y;
}
static float atan2f_impl(float y, float x) {
  // Coarse atan2 via a scaled octant approach; only used for facing (visual).
  float ax = x < 0.f ? -x : x;
  float ay = y < 0.f ? -y : y;
  // Linear approx of atan(y/x) within +/- pi/4, then quadrant.
  float base;
  if (ax < 1e-6f) {
    return (y >= 0.f) ? 1.570796f : -1.570796f;
  }
  base = (ay / ax) * 0.785398f;
  if (x < 0.f) base = 3.14159265f - base;
  if (y < 0.f) base = -base;
  return base;
}

// ---------------------------------------------------------------------------
// Lifecycle hooks.
// ---------------------------------------------------------------------------

void on_enable(void) {
  bot_init();
  out_n = 0;
  e("zdtd_bot v2.0 enabled");
  flush(1);
}

void on_tick(void) { brain_tick(); }

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_bot shutdown");
  flush(1);
}

// ---------------------------------------------------------------------------
// Admin commands (route via the existing plugin admin hook; falls through to
// core `unknown` when not handled).
// ---------------------------------------------------------------------------

// The host calls on_admin_command(cmd_ptr, cmd_len, out_ptr, out_cap). We write
// the reply at out_ptr and return its length (0 = not handled).
static char *a_cmd; static int a_cmd_n;

int on_admin_command(int cmd_ptr, int cmd_len, int out_ptr, int out_cap) {
  a_cmd = (char*)(long)cmd_ptr;
  a_cmd_n = cmd_len;
  // We build the reply in `reply_buf` then copy to out.
  static char reply_buf[600];
  int rn = 0;

  // Tokenize a_cmd (length-limited) — we copy into a local nul-terminated
  // shadow to avoid touching guest memory past the call bounds.
  char copy[160];
  int cl = cmd_len < 159 ? cmd_len : 159;
  int i;
  for (i = 0; i < cl; ++i) copy[i] = a_cmd[i];
  copy[cl] = 0;

  // First token.
  char *tok = copy;
  char *sp = tok;
  while (*sp && *sp != ' ' && *sp != '\t') sp++;
  int first_len = (int)(sp - tok);
  if (first_len == 3 &&
      tok[0] == 'b' && tok[1] == 'o' && tok[2] == 't') {
    // bot <subcommand>
    while (*sp == ' ' || *sp == '\t') sp++;
    char *sub = sp;
    char *sp2 = sub;
    while (*sp2 && *sp2 != ' ' && *sp2 != '\t') sp2++;
    int slen = (int)(sp2 - sub);
    while (*sp2 == ' ' || *sp2 == '\t') sp2++;
    char *arg = sp2;

    if (slen == 4 && sub[0]=='h' && sub[1]=='e' && sub[2]=='l' && sub[3]=='p') {
      static const char *usage =
        "bot help\nbot status\nbot list\n"
        "bot spawn [name] [x z]\nbot remove <id|all>\n"
        "bot count <n>\nbot skill <0-4> [id]\nbot cfg <id> <key> <val>\n";
      const char *u = usage;
      while (*u && rn < 599) reply_buf[rn++] = *u++;
    } else if (eq(sub, slen, "status", 6)) {
      int nb = 0;
      int ii;
      for (ii = 0; ii < MAX_BOTS; ++ii) if (bot_net[ii] >= 0) nb++;
      rn += st(reply_buf + rn, 599 - rn, "zdtd_bot: bots_known=");
      rn += e_to(reply_buf + rn, 599 - rn, nb);
      rn += st(reply_buf + rn, 599 - rn, " floor=");
      rn += e_to(reply_buf + rn, 599 - rn, bot_count_static);
      rn += st(reply_buf + rn, 599 - rn, " skill_default=");
      rn += e_to(reply_buf + rn, 599 - rn, bot_skill[0] < 0 ? 2 : bot_skill[0]);
      rn += st(reply_buf + rn, 599 - rn, "\n");
    } else if (eq(sub, slen, "list", 4)) {
      int ii;
      for (ii = 0; ii < MAX_BOTS; ++ii) {
        if (bot_net[ii] < 0) continue;
        rn += st(reply_buf + rn, 599 - rn, "  id=");
        rn += e_to(reply_buf + rn, 599 - rn, bot_net[ii]);
        rn += st(reply_buf + rn, 599 - rn, " target=");
        rn += e_to(reply_buf + rn, 599 - rn, bot_target[ii]);
        rn += st(reply_buf + rn, 599 - rn, "\n");
      }
      if (rn == 0) rn += st(reply_buf + rn, 599 - rn, "no bots\n");
    } else if (slen == 5 && sub[0]=='c' && sub[1]=='o' && sub[2]=='u' && sub[3]=='n' && sub[4]=='t') {
      // bot count <n> -> re-queue a bot count SimCommand (host enforces floor).
      bot_count_static = (int)strtol_impl(arg);
      {
        const char *p = "bot count ";
        out_n = 0;
        while (*p && out_n < OUT_CAP - 1) out[out_n++] = *p++;
        while (*arg && out_n < OUT_CAP - 1) out[out_n++] = *arg++;
        out[out_n] = 0;
        zdtd_queue((int)(long)&out[0], out_n);
        out_n = 0;
      }
      rn += st(reply_buf + rn, 599 - rn, "bot count set\n");
    } else if (slen == 5 && sub[0]=='s' && sub[1]=='p') {
      // spawn
      static const char *sp = "bot spawn ";
      const char *pp = sp;
      out_n = 0;
      while (*pp && out_n < OUT_CAP - 1) out[out_n++] = *pp++;
      while (*arg && out_n < OUT_CAP - 1) out[out_n++] = *arg++;
      out[out_n] = 0;
      zdtd_queue((int)(long)&out[0], out_n);
      out_n = 0;
      rn += st(reply_buf + rn, 599 - rn, "spawned\n");
    } else if (slen == 6 && sub[0]=='r' && sub[1]=='e' && sub[2]=='m' && sub[3]=='o' && sub[4]=='v' && sub[5]=='e') {
      static const char *rp = "bot remove ";
      const char *pp = rp;
      out_n = 0;
      while (*pp && out_n < OUT_CAP - 1) out[out_n++] = *pp++;
      while (*arg && out_n < OUT_CAP - 1) out[out_n++] = *arg++;
      out[out_n] = 0;
      zdtd_queue((int)(long)&out[0], out_n);
      out_n = 0;
      rn += st(reply_buf + rn, 599 - rn, "removed\n");
    } else if (slen == 5 && sub[0]=='s' && sub[1]=='k' && sub[2]=='i' && sub[3]=='l' && sub[4]=='l') {
      // bot skill <0-4> [id]: set the default skill for future bots, or, with
      // an id, only that bot (per-bot override, BOTS_SPEC `bot cfg` spirit).
      char *sp3 = arg;
      while (*sp3 == ' ' || *sp3 == '\t') sp3++;
      long v = strtol_impl(sp3);
      if (v < 0) v = 0; if (v > 4) v = 4;
      while (*sp3 && *sp3 != ' ' && *sp3 != '\t') sp3++;
      while (*sp3 == ' ' || *sp3 == '\t') sp3++;
      if (*sp3) {
        long id = strtol_impl(sp3);
        int i2;
        for (i2 = 0; i2 < MAX_BOTS; ++i2) {
          if (bot_net[i2] == (int)id) bot_skill[i2] = (int)v;
        }
        rn += st(reply_buf + rn, 599 - rn, "bot skill ");
        rn += e_to(reply_buf + rn, 599 - rn, v);
        rn += st(reply_buf + rn, 599 - rn, " id=");
        rn += e_to(reply_buf + rn, 599 - rn, id);
        rn += st(reply_buf + rn, 599 - rn, "\n");
      } else {
        int i2;
        for (i2 = 0; i2 < MAX_BOTS; ++i2) bot_skill[i2] = (int)v; // new bots
        rn += st(reply_buf + rn, 599 - rn, "bot skill ");
        rn += e_to(reply_buf + rn, 599 - rn, v);
        rn += st(reply_buf + rn, 599 - rn, "\n");
      }
    } else if (slen == 3 && sub[0]=='c' && sub[1]=='f' && sub[2]=='g') {
      // bot cfg <id> <key> <val> — per-bot overrides (BOTS_SPEC `bot cfg`).
      // keys: vision | reaction (0 resets to the skill-derived default).
      char *sp4 = arg;
      while (*sp4 == ' ' || *sp4 == '\t') sp4++;
      long id = strtol_impl(sp4);
      while (*sp4 && *sp4 != ' ' && *sp4 != '\t') sp4++;
      while (*sp4 == ' ' || *sp4 == '\t') sp4++;
      char *key = sp4;
      while (*sp4 && *sp4 != ' ' && *sp4 != '\t') sp4++;
      int keylen = (int)(sp4 - key);
      while (*sp4 == ' ' || *sp4 == '\t') sp4++;
      float val = 0.f;
      {
        // parse float from sp4 (simple sign+digits+dot).
        const char *p2 = sp4;
        float acc = 0.f; int neg = 0; int frac = 0; float div = 1.f;
        if (*p2 == '-') { neg = 1; p2++; }
        while (*p2 >= '0' && *p2 <= '9') { acc = acc * 10.f + (float)(*p2 - '0'); p2++; }
        if (*p2 == '.') { p2++; while (*p2 >= '0' && *p2 <= '9') { acc = acc * 10.f + (float)(*p2 - '0'); div *= 10.f; p2++; } frac = 1; }
        val = acc / (frac ? div : 1.f);
        if (neg) val = -val;
      }
      int si;
      int cfg_ok = 1;
      for (si = 0; si < MAX_BOTS; ++si) {
        if (bot_net[si] != (int)id) continue;
        if (keylen == 6 && key[0]=='v' && key[1]=='i' && key[2]=='s' && key[3]=='i' && key[4]=='o' && key[5]=='n') {
          bot_vision[si] = val < 0.f ? 0.f : val;
        } else if (keylen == 8 && key[0]=='r' && key[1]=='e' && key[2]=='a' && key[3]=='c' && key[4]=='t' && key[5]=='i' && key[6]=='o' && key[7]=='n') {
          bot_reaction[si] = val < 0.f ? 0.f : val;
        } else {
          cfg_ok = 0;
        }
      }
      if (cfg_ok) rn += st(reply_buf + rn, 599 - rn, "bot cfg set\n");
      else rn += st(reply_buf + rn, 599 - rn, "bot cfg: unknown key (vision|reaction)\n");
    } else {
      rn += st(reply_buf + rn, 599 - rn, "bot: unknown subcommand (try 'bot help')\n");
    }

    // Copy reply to guest out buffer.
    int rcopy = rn < out_cap ? rn : out_cap;
    char *dst = (char*)(long)out_ptr;
    for (i = 0; i < rcopy; ++i) dst[i] = reply_buf[i];
    return rcopy;
  }
  return 0; // not handled -> fall through
}

static int st(char *b, int cap, const char *s) {
  int n = 0;
  while (*s && n < cap - 1) b[n++] = *s++;
  b[n] = 0;
  return n;
}
static int strcmp_impl(const char *a, const char *b) __attribute__((unused));
static int strcmp_impl(const char *a, const char *b) {
  while (*a && *b && *a == *b) { a++; b++; }
  return (unsigned char)*a - (unsigned char)*b;
}
static int eq(char *s, int slen, const char *w, int wlen) {
  if (slen != wlen) return 0;
  int i;
  for (i = 0; i < wlen; ++i) if (s[i] != w[i]) return 0;
  return 1;
}
static long strtol_impl(const char *s) {
  long v = 0; int neg = 0;
  if (*s == '-') { neg = 1; s++; }
  while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
  return neg ? -v : v;
}
