// zdtd_bot — FPS bot addon (ADR 0026, docs/BOTS_SPEC.md / BOTS_PRD.md).
//
// A WebAssembly plugin that commands player-mesh FPS bots through the host's
// sense/act boundary. The servant (host) owns spawn/tick/replicate/kill/LOS
// and move caps; this module owns the *brain* — target selection, skill-scaled
// aim error and hit accuracy, lead-fire prediction, reaction gate, fire
// throttle, strafe/backpedal, low-health survival retreat, lost-sight combat
// memory and hit retaliation — distilled from the Quake 3 / Doom 3 bot model,
// cross-pollinated with the 7dtd-clanker C# port (docs/q3-inspiration-notes.md,
// BOTS_SPEC §5.1). All inference is deterministic (per-slot LCG, no wall-clock
// noise).
//
// Improvements cross-pollinated FROM 7dtd-clanker/mod (BotBrain/BotCombat/Bot):
//   - backpedal when an enemy is too close        (BotBrain.Backpedal)
//   - skill- and distance-scaled hit accuracy     (TryShootBurst spread/difficulty)
//   - low-health survival retreat / hold fire     (BotCharacter.WantsToRetreat)
//   - retaliation on being hit: aggro swap to the attacker + quicker reaction
//     and a bounded revenge memory (grudge)       (Bot.OnDamaged)
//   - per-bot personalities (aggression, self-preservation, vengefulness,
//     camper, alertness) rolled deterministically from skill + net id and
//     overridable via `bot cfg`                    (BotCharacter DB)
//   - weapon-aware tactics: the host's per-bot loadout (kind-4 bot-info sense
//     record) drives engagement range, burst size, lead scale and keep-range
//     backpedal                                (WeaponProfile parity)
//   - cover-seeking retreat: a retreating bot asks `zdtd.query` for a point
//     not visible from the threat and holds there                  (FindCover)
//   - ammo pacing: per-weapon magazines and reload pauses — an empty mag
//     starts a reload during which the bot holds fire and keeps strafing
//                                                      (Q3 bots managed ammo)
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
__attribute__((import_module("zdtd"), import_name("query")))
extern int zdtd_query(int req_ptr, int req_len, int out_ptr, int out_cap);

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

// Render a float with two decimals into a caller buffer (like e_flt but into
// any buffer, for host query requests).
static int f_to(char *b, int cap, float v) {
  int n = 0;
  if (v < 0.f) { if (n < cap) b[n++] = '-'; v = -v; }
  long long whole = (long long)v;
  int frac = (int)((v - (float)whole) * 100.0f + 0.5f);
  if (frac == 100) { whole += 1; frac = 0; }
  n += e_to(b + n, cap - n, whole);
  if (n < cap) b[n++] = '.';
  if (frac < 10 && n < cap) b[n++] = '0';
  n += e_to(b + n, cap - n, frac);
  return n;
}
// Parse a float (sign + digits + optional fraction); sets *end past it.
static float parse_f(const char *p, const char **end) {
  float acc = 0.f; int neg = 0; int frac = 0; float div = 1.f;
  if (*p == '-') { neg = 1; p++; }
  while (*p >= '0' && *p <= '9') { acc = acc * 10.f + (float)(*p - '0'); p++; }
  if (*p == '.') {
    p++;
    while (*p >= '0' && *p <= '9') { acc = acc * 10.f + (float)(*p - '0'); div *= 10.f; p++; }
    frac = 1;
  }
  if (frac) acc /= div;
  if (neg) acc = -acc;
  *end = p;
  return acc;
}

// ---------------------------------------------------------------------------
// Reverse-direction host queries (zdtd.query; BOTS_SPEC §3). The guest writes
// a text request, the host answers with a text response. Used for cover
// seeking (Doom 3 idAASFindCover / clanker BotBrain.FindCover port).
// ---------------------------------------------------------------------------

#define QRY_CAP 64
static char qry_buf[QRY_CAP];

static int st(char *b, int cap, const char *s); // (forward; body below)

// Ask the host for a point near (bx,bz) that is NOT visible from (tx,tz).
// Returns 1 with the point in *cx/*cz, or 0 when no cover exists.
static int query_cover(float bx, float bz, float tx, float tz, float *cx, float *cz) {
  char req[64];
  int rn = 0;
  rn += st(req, 64, "cover ");
  rn += f_to(req + rn, 64 - rn, bx); req[rn++] = ' ';
  rn += f_to(req + rn, 64 - rn, bz); req[rn++] = ' ';
  rn += f_to(req + rn, 64 - rn, tx); req[rn++] = ' ';
  rn += f_to(req + rn, 64 - rn, tz);
  const int qn = zdtd_query((int)(long)&req[0], rn, (int)(long)&qry_buf[0], QRY_CAP);
  if (qn < 3) return 0;
  const char *p = qry_buf;
  const char *e = qry_buf;
  *cx = parse_f(p, &e);
  while (*e == ' ') e++;
  if (!(*e >= '0' && *e <= '9') && *e != '-') return 0;
  *cz = parse_f(e, &e);
  return 1;
}

// ---------------------------------------------------------------------------
// Sense snapshot parsing.
//
// Layout (BOTS_SPEC §3, all little-endian): header 16 bytes, fixed-stride
// 32-byte entity records, then an optional 16-byte damage-event trailer.
// Parsed by explicit offsets so a C struct can never drift from the Zig
// packed records.
//   hdr: magic u32@0 ('ZBS2'), count u32@4, tick u32@8, self_net_id i32@12
//   rec stride 32: net_id i32@0, kind u8@4, is_self u8@5, alive u8@6, pad@7,
//                  x f32@8, y f32@12, z f32@16, hp f32@20, yaw f32@24,
//                  target_id i32@28
//   ev  stride 16: kind u8@0 (3 = damage), pad@1..3, attacker i32@4,
//                  victim i32@8, amount f32@12
// ---------------------------------------------------------------------------

#define SENSE_CAP 2048
static char sense[SENSE_CAP];
static int sense_n = 0;
static int sense_recs = 0; // record count from the header (event offsets base)

#define REC_STRIDE 32
#define EV_STRIDE 16
#define KIND_PLAYER 0
#define KIND_ZOMBIE 1
#define KIND_BOT 2
#define KIND_EV_DAMAGE 3

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

// Refresh the snapshot. Returns the number of entity records (0 on
// failure/empty). The header's count is authoritative; the event trailer is
// derived from the bytes that follow the records.
static int sense_refresh(void) {
  sense_n = zdtd_sense((int)(long)&sense[0], SENSE_CAP, 0);
  if (sense_n < 16) { sense_n = 0; sense_recs = 0; return 0; }
  if (s32(0) != 0x3253425a) { sense_n = 0; sense_recs = 0; return 0; } // 'ZBS2'
  const int n = s32(4);
  const int avail = (sense_n - 16) / REC_STRIDE;
  if (n > avail || n < 0) { sense_n = 0; sense_recs = 0; return 0; } // lies: drop
  sense_recs = n;
  return n;
}
// Number of damage-event records trailing the entity records.
static int sense_ev(void) {
  if (sense_n < 16) return 0;
  const int used = 16 + sense_recs * REC_STRIDE;
  if (sense_n - used < 0) return 0;
  return (sense_n - used) / EV_STRIDE;
}
#define EV_OFF(i) (16 + sense_recs * REC_STRIDE + (i) * EV_STRIDE)
static int ev_kind(int i)   { return s8(EV_OFF(i) + 0); }
static int ev_attacker(int i) { return s32(EV_OFF(i) + 4); }
static int ev_victim(int i)   { return s32(EV_OFF(i) + 8); }
static float ev_amount(int i) { return sf32(EV_OFF(i) + 12); }

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
// Retaliation (cross-pollinated FROM 7dtd-clanker Bot.OnDamaged): who last
// hit us and how long we hold the grudge (Q3 vengefulness).
static int   bot_grudge[MAX_BOTS];      // net id we want revenge on (-1 = none)
static int   bot_grudge_ticks[MAX_BOTS];// remaining ticks of the grudge
// Per-bot personality (Q3 BotCharacter subset, cross-pollinated FROM
// 7dtd-clanker BotCharacter): aggression, self-preservation, vengefulness,
// camper, alertness — rolled deterministically from (skill, net id) at slot
// alloc, overridable per-bot via `bot cfg` (negative value resets).
static float bot_agg[MAX_BOTS];
static float bot_selfpres[MAX_BOTS];
static float bot_venge[MAX_BOTS];
static float bot_camp[MAX_BOTS];
static float bot_alert[MAX_BOTS];
static int   bot_camp_ticks[MAX_BOTS];  // remaining ticks of a camp hold
// Host-assigned weapon (kind-4 bot-info sense record): the brain adapts
// engagement range, burst size and lead to the weapon (clanker WeaponProfile).
static int   bot_weapon_id[MAX_BOTS];
// Cover-seeking retreat (Doom 3 idAASFindCover / clanker BotBrain.FindCover
// port): the host-computed hide point (0,0 = none) and the re-query cooldown.
static float bot_cover_x[MAX_BOTS];
static float bot_cover_z[MAX_BOTS];
static int   bot_cover_cd[MAX_BOTS];
// Ammo / reload pacing (Q3 bots managed ammo). Purely guest-side: rounds left
// in the magazine and ticks of the current reload; the host never sees ammo.
static int   bot_ammo[MAX_BOTS];
static int   bot_reload_ticks[MAX_BOTS];
static int bot_count_static;        // our remembered `bot count` floor (host also enforces)

// (forward; bodies with the other weapon tables below — bot_init reads them)
static int weapon_mag(int w);
static float weapon_reload(int w);

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
    bot_grudge[i] = -1;
    bot_grudge_ticks[i] = 0;
    bot_agg[i] = 0.f;
    bot_selfpres[i] = 0.f;
    bot_venge[i] = 0.f;
    bot_camp[i] = 0.f;
    bot_alert[i] = 0.f;
    bot_camp_ticks[i] = 0;
    bot_weapon_id[i] = 0; // pistol until the first bot-info record arrives
    bot_cover_x[i] = 0.f;
    bot_cover_z[i] = 0.f;
    bot_cover_cd[i] = 0;
    bot_ammo[i] = weapon_mag(0);   // pistol until the first info record lands
    bot_reload_ticks[i] = 0;
  }
  bot_count_static = 0;
}

// Weapon profiles (pool index matches the host's `bot_loadout_pool` order in
// src/server/game/bot.zig: pistol 0, shotgun 1, ak 2, sniper 3, auto 4, smg 5).
// Engagement range stays under the host-enforced weapon range (+2) so a shot
// the brain orders is not rejected as out-of-range (clanker WeaponProfile).
static float weapon_range(int w) {
  switch (w) {
    case 1: return 20.f;  // shotgun
    case 4: return 20.f;  // auto
    case 5: return 30.f;  // smg
    case 0: return 36.f;  // pistol
    case 2: return 50.f;  // ak
    default: return 75.f; // sniper
  }
}
// Burst size by weapon (clanker WeaponProfile BurstMin/BurstMax).
static int weapon_burst(int w) {
  switch (w) {
    case 3: return 1; // sniper: one shot, big damage
    case 1: return 1; // shotgun: one shell (host applies pellets)
    case 0: return 2; // pistol
    case 2: return 3; // ak
    default: return 4; // smg / auto
  }
}
// Lead scale by weapon: precision weapons lead fully, spread weapons lead
// little (clanker LeadAimPoint leadScale: longer-ranged weapons lead more).
static float weapon_lead(int w) {
  switch (w) {
    case 1: return 0.2f; // shotgun (spread)
    case 4: return 0.5f; // auto
    case 5: return 0.6f; // smg
    case 0: return 0.8f; // pistol
    default: return 1.f; // ak / sniper
  }
}
// Magazine size and reload seconds by weapon (Q3 bots managed ammo; a visible
// reload pause makes fights feel real — cross-pollinated to clanker
// WeaponProfile MagSize/ReloadSec). The guest tracks per-bot ammo purely as
// pacing: the host applies damage per accepted `bot shoot` and never sees a
// magazine, so a bot "clicking empty" simply stops ordering shots.
static int weapon_mag(int w) {
  // magazine sizes aligned to game Data/Config/items.xml MagazineSize base_set
  // (R13 parity audit): sniper 12, shotgun 2, pistol 15, ak 30, smg 30, auto 16
  switch (w) {
    case 3: return 12;  // sniper
    case 1: return 2;   // shotgun shells
    case 0: return 15;  // pistol
    case 2: return 30;  // ak
    case 5: return 30;  // smg
    default: return 16; // auto
  }
}
static float weapon_reload(int w) {
  switch (w) {
    case 0: return 1.2f; // pistol
    case 5: return 1.8f; // smg
    case 2: return 2.0f; // ak
    case 4: return 2.2f; // auto
    case 1: return 2.6f; // shotgun
    default: return 2.5f; // sniper
  }
}

static float clampf01(float v) {
  return v < 0.f ? 0.f : (v > 1.f ? 1.f : v);
}

// Deterministic per-bot personality default from (skill, net id) — the same
// call shape is used at slot alloc and on `bot cfg` reset, so no RNG state is
// consumed. Mirrors the clanker BotCharacter DB (Aggression/SelfPreservation/
// Vengefulness/Camper/Alertness) with skill scaling + a stable per-id jitter.
static float pers_default(int skill, int net, int which) {
  unsigned h = (unsigned)net * 2654435761u + (unsigned)which * 97u + 1u;
  h = h * 1103515245u + 12345u;
  const float r = (float)((h >> 8) & 0x00ffffffu) / 16777216.0f;
  const float s = (float)skill;
  switch (which) {
    case 0: return clampf01(0.35f + 0.10f * s + (r - 0.5f) * 0.4f);
    case 1: return clampf01(0.55f - 0.07f * s + (r - 0.5f) * 0.3f);
    case 2: return clampf01(0.40f + 0.10f * s + (r - 0.5f) * 0.4f);
    case 3: return clampf01(0.15f + 0.08f * s + (r - 0.5f) * 0.4f);
    default: return clampf01(0.40f + 0.12f * s + (r - 0.5f) * 0.3f);
  }
}
static void pers_apply_default(int bslot, int skill, int net) {
  bot_agg[bslot] = pers_default(skill, net, 0);
  bot_selfpres[bslot] = pers_default(skill, net, 1);
  bot_venge[bslot] = pers_default(skill, net, 2);
  bot_camp[bslot] = pers_default(skill, net, 3);
  bot_alert[bslot] = pers_default(skill, net, 4);
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
static int weapon_mag(int w);
static float weapon_reload(int w);

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
// health fraction a careful bot retreats and holds fire (self-preservation).
// The mid-point personality threshold (self-preservation 0.5) lands here; the
// per-bot formula is `0.20 + selfpres * 0.25`, gated by aggression < 0.7.
#define HP_RETREAT_FRAC 0.35f
// Any bot below this health fraction flees regardless of skill or personality
// (clanker's WantsToRetreat has no skill gate; only its self-preservation
// personality).
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
// Retaliation (cross-pollinated from 7dtd-clanker Bot.OnDamaged): how many
// ticks we remember who shot us (300 ticks = 15 s at vengefulness 0.5, the
// mid-point personality; per-bot ticks = GRUDGE_TICKS * (0.5 + venge)) and the
// mid-point target-selection score multiplier for the grudged net id
// (per-bot score = 0.85 - 0.35 * venge). Vengefulness is the clanker
// BotCharacter.Vengefulness personality.
#define GRUDGE_TICKS 300
#define GRUDGE_SCORE 0.67f

// Skill- and distance-scaled hit probability (cross-pollinated from
// 7dtd-clanker TryShootBurst: spread / AimJitterDegrees scaled down by skill).
// A tiny per-bot trait jitter (net-id hash, ~±3 %) so two skill-2 bots don't
// behave identically — mirrors clanker BotCharacter Camper/Aggression spread.
static float bot_trait_jitter(int net) {
  unsigned h = (unsigned)net * 2654435761u;
  h = h * 1103515245u + 12345u;
  return ((h >> 8 & 0x00ffffffu) / 16777216.f - 0.5f) * 0.06f;
}
static float skill_hit_chance(int skill, float dist, int net) {
  float base = 0.34f + 0.15f * (float)skill + bot_trait_jitter(net);
  if (base > 0.95f) base = 0.95f;
  if (base < 0.28f) base = 0.28f;
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

  // Weapon map: kind-4 bot-info records pair each bot's net id with its
  // host-assigned loadout (BOTS_SPEC §3); the per-bot loop adapts
  // range/burst/lead to it (clanker WeaponProfile parity). A weapon change
  // (including the first record after spawn) re-seats the magazine.
  {
    int ei;
    for (ei = 0; ei < sense_ev(); ++ei) {
      if (ev_kind(ei) != 4) continue;
      const int wid_net = s32(EV_OFF(ei) + 4);
      const int wid = s8(EV_OFF(ei) + 1);
      const int s3 = bot_find(wid_net);
      if (s3 >= 0 && bot_weapon_id[s3] != wid) {
        bot_weapon_id[s3] = wid;
        bot_ammo[s3] = weapon_mag(wid);
        bot_reload_ticks[s3] = 0;
      }
    }
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
      bot_grudge[bslot] = -1;
      bot_grudge_ticks[bslot] = 0;
      // Per-bot personality defaults (skill + net id; deterministic).
      pers_apply_default(bslot, bot_skill[bslot], net);
      bot_ammo[bslot] = weapon_mag(0); // pistol until the info record lands
      bot_reload_ticks[bslot] = 0;
    }
    const int skill = bot_skill[bslot];
    // Per-bot `bot cfg` overrides win over the skill-derived defaults. The
    // alertness personality scales both: alert bots see farther and react
    // faster (clanker BotCharacter.Alertness parity).
    const float vision = bot_vision[bslot] > 0.f ? bot_vision[bslot]
                        : skill_vision(skill) * (0.8f + 0.4f * bot_alert[bslot]);
    const float reaction = bot_reaction[bslot] > 0.f ? bot_reaction[bslot]
                          : skill_reaction(skill) * (1.2f - 0.4f * bot_alert[bslot]);

    // Dodge-on-hit (cross-pollinated from 7dtd-clanker Bot.OnDamaged): if our
    // own hp dropped since the last sense pass we were damaged, trigger a short
    // evasive dodge and randomize the strafe direction. Pure guest-side: the
    // sense record already carries our hp, so no host/spec change is needed.
    if (bot_last_hp[bslot] > rec_hp(bi)) {
      bot_dodge[bslot] = DODGE_TICKS;
      bot_strafe_p[bslot] = rng_f01(&bot_rng[bslot]) < 0.5f ? 0 : 1;
    }
    bot_last_hp[bslot] = rec_hp(bi);

    // Retaliation (cross-pollinated FROM 7dtd-clanker Bot.OnDamaged: aggro
    // swap on being hit — quicker reaction when shot). Damage events ride the
    // sense trailer (BOTS_SPEC §3); a victim that is this bot sets a grudge on
    // the attacker. The grudge biases target selection below (GRUDGE_SCORE)
    // and decays after GRUDGE_TICKS. The dodge itself already fires from the
    // hp drop above; this adds *who* to hit back, and a heavy hit (sniper,
    // headshot) staggers the dodge longer.
    {
      int ek;
      for (ek = 0; ek < sense_ev(); ++ek) {
        if (ev_kind(ek) != KIND_EV_DAMAGE) continue;
        if (ev_victim(ek) != net) continue; // only events about me
        const int att = ev_attacker(ek);
        if (att >= 0 && att != net) {
          bot_grudge[bslot] = att;
          // Vengefulness scales how long the grudge lasts (clanker
          // BotCharacter.Vengefulness; mid-point = GRUDGE_TICKS).
          bot_grudge_ticks[bslot] = (int)(GRUDGE_TICKS * (0.5f + bot_venge[bslot]));
          // Quicker reaction when shot (clanker: ReactionTime * 0.5).
          if (bot_react[bslot] > 0.f) bot_react[bslot] *= 0.5f;
          // Stagger: a hit above ~2x the pistol floor dazes longer.
          if (ev_amount(ek) > 25.f) bot_dodge[bslot] += 5;
        }
      }
    }

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

    // Grudge decay: forget who shot us once the memory expires.
    if (bot_grudge_ticks[bslot] > 0) {
      bot_grudge_ticks[bslot]--;
      if (bot_grudge_ticks[bslot] == 0) bot_grudge[bslot] = -1;
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
      // Aggression gates how far a bot will chase (clanker ShouldChase:
      // Aggression < 0.35 => don't chase far). A grudged target is always
      // chased — vengeance overrides caution.
      if (rec_net(j) != bot_grudge[bslot]) {
        const float chase_max = 26.f + bot_agg[bslot] * 30.f;
        if (d2 > chase_max * chase_max) continue;
      }
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
      // Wounded preference (cross-pollinated from clanker BotBrain.FindTarget:
      // `score -= (health/100) * -2f`): a hurt candidate out-scores a healthy
      // one at the same range, so bots finish off the wounded instead of
      // flitting to a fresh target (Q3 "finish the job").
      score += rec_hp(j) * 0.02f;
      // Retaliation bias: the grudged net id out-scores equally-distant
      // threats so the bot turns on whoever shot it (clanker aggro swap).
      // Vengefulness scales how strongly it out-scores (0.85 at venge 0 up
      // to 0.50 at venge 1; mid-point ~GRUDGE_SCORE).
      if (rec_net(j) == bot_grudge[bslot]) score *= (0.85f - 0.35f * bot_venge[bslot]);
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
        // Drop a stale combat lock while idle (a new engagement resets motion
        // history); hoisted before the camp hold so a lingering reaction gate
        // cannot delay the next shot after a camp.
        if (bot_target[bslot] != -1) {
          bot_target[bslot] = -1;
          bot_react[bslot] = 0.f;
        }
        // Q3 camper / clanker WantsToCamp: a camper personality at healthy hp
        // periodically holds position and sweeps the facing instead of roaming.
        const float hp0 = rec_hp(bi) / BOT_MAX_HP;
        if (bot_camp_ticks[bslot] <= 0 && bot_camp[bslot] > 0.45f && hp0 > 0.55f &&
            rng_f01(&bot_rng[bslot]) < bot_camp[bslot] * 0.4f) {
          bot_camp_ticks[bslot] = 100; // hold ~5 s
        }
        if (bot_camp_ticks[bslot] > 0) {
          bot_camp_ticks[bslot]--;
          const float cyaw = bot_last_yaw[bslot] + 0.05f; // slow sweep
          if (look_dirty(bslot, cyaw)) {
            queue_look(net, cyaw);
            bot_last_yaw[bslot] = cyaw; bot_look_sent[bslot] = 1;
          }
          continue; // hold position; no move emission during the camp
        }
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
      bot_camp_ticks[bslot] = 0; // contact ends a camp hold
      bot_cover_x[bslot] = 0.f;  // a fresh engagement forgets the old hide point
      bot_cover_z[bslot] = 0.f;
      bot_cover_cd[bslot] = 0;
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

    // Lead the target: predict where it will be when the shot arrives. The
    // weapon scales the lead: precision weapons lead fully, spread weapons
    // lead little (clanker LeadAimPoint leadScale).
    const int w = bot_weapon_id[bslot];
    float lead = dist / BULLET_SPEED * weapon_lead(w);
    float lx = tx + bot_tvx[bslot] * lead;
    float lz = tz + bot_tvz[bslot] * lead;

    // Face the predicted point plus our skill-scaled, per-engagement aim error.
    float yaw = atan2f_impl(lz - bz, lx - bx) + 1.570796f + bot_aimerr[bslot];
    if (look_dirty(bslot, yaw)) {
      queue_look(net, yaw);
      bot_last_yaw[bslot] = yaw; bot_look_sent[bslot] = 1;
    }

    // Weapon-aware engagement range (clanker WeaponProfile.Range parity): the
    // bot engages at the weapon's comfortable range (mildly skill-scaled)
    // instead of a skill-only constant — a sniper bot keeps ~70 m, a shotgun
    // bot closes to ~18 m. Stays under the host's enforced weapon range + 2 so
    // an ordered shot is never rejected as out-of-range.
    const float attack_range = weapon_range(w) * (0.85f + 0.05f * (float)skill);
    // Long-range weapons keep their distance: below half the weapon range the
    // bot backpedals instead of letting the target close (sniper/magnum tact).
    const int keep_range = weapon_range(w) > 40.f && dist < weapon_range(w) * 0.5f;
    // Cross-pollinated from 7dtd-clanker: low-health bots retreat
    // (self-preservation, BotCharacter.WantsToRetreat) — hold fire and back
    // off. Fleeing at HP_FLEE_FRAC is skill/personality-independent survival.
    const float hp_frac = rec_hp(bi) / BOT_MAX_HP;
    // Retreat threshold from self-preservation + aggression (clanker
    // WantsToRetreat: `hp < 0.35 + SelfPreservation*0.18` for careful bots;
    // high aggression fights on while hurt). Mid-point personality lands on
    // the old skill<2 threshold (~0.35).
    const float retreat_frac = 0.20f + bot_selfpres[bslot] * 0.25f;
    const int retreating = (hp_frac < HP_FLEE_FRAC) || (hp_frac < retreat_frac && bot_agg[bslot] < 0.7f);
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
        if (retreating || dist < BACKPEDAL_RANGE || keep_range) {
          // A RETREATING bot first tries to break LOS at a host-computed cover
          // point (Doom 3 idAASFindCover / clanker BotBrain.FindCover port):
          // ask `zdtd.query` for a spot near us that is not visible from the
          // threat, then head there and hold. No cover -> plain backpedal.
          int has_cover = 0;
          float cdx = 0.f, cdz = 0.f;
          if (retreating) {
            if (bot_cover_cd[bslot] > 0) bot_cover_cd[bslot]--;
            if (bot_cover_cd[bslot] == 0) {
              bot_cover_cd[bslot] = 8; // re-query every ~0.4 s
              float qx, qz;
              if (query_cover(bx, bz, tx, tz, &qx, &qz)) {
                bot_cover_x[bslot] = qx;
                bot_cover_z[bslot] = qz;
              }
            }
            if (bot_cover_x[bslot] != 0.f || bot_cover_z[bslot] != 0.f) {
              cdx = bot_cover_x[bslot] - bx;
              cdz = bot_cover_z[bslot] - bz;
              if (cdx * cdx + cdz * cdz > 1.5f) has_cover = 1;
              else { bot_cover_x[bslot] = 0.f; bot_cover_z[bslot] = 0.f; } // arrived: hold
            }
          }
          if (has_cover) {
            mdest_x = bx + cdx * 0.6f;
            mdest_z = bz + cdz * 0.6f;
            mspd = 3.6f; // purposeful move to cover
          } else {
            // Cross-pollinated from clanker BotBrain.Backpedal: back away + circle.
            mdest_x = bx - txn * 1.7f + oxn * s * 1.1f;
            mdest_z = bz - tzn * 1.7f + ozn * s * 1.1f;
            mspd = 3.f;
          }
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
      // Cross-pollinated from clanker TryShootBurst: a burst volley whose size
      // follows the weapon profile (clanker WeaponProfile BurstMin/BurstMax:
      // sniper/shotgun 1, pistol 2, ak 3, smg/auto 4), each shot with its own
      // skill/distance hit roll and a skill-scaled headshot roll — low-skill
      // bots miss a lot, high-skill bots land burst damage. The host applies
      // damage per `bot shoot`.
      //
      // Ammo pacing (Q3 bots managed ammo): every trigger pull consumes a
      // round whether it hits or misses; an empty magazine starts a reload
      // (weapon_reload seconds) during which the bot holds fire and keeps
      // strafing. Purely guest-side — the host never sees ammo.
      if (!retreating && bot_react[bslot] <= 0.f && bot_throttle[bslot] <= 0.f) {
        if (bot_reload_ticks[bslot] > 0) {
          // Reloading: hold fire (movement continues via the branch above).
        } else if (bot_ammo[bslot] <= 0) {
          bot_reload_ticks[bslot] = (int)(weapon_reload(w) / TICK_DT);
        } else {
          const int burst = weapon_burst(w);
          int k;
          for (k = 0; k < burst; ++k) {
            if (bot_ammo[bslot] <= 0) break; // empty mid-burst: reload next window
            bot_ammo[bslot]--;
            const float hc = skill_hit_chance(skill, dist, net);
            if (rng_f01(&bot_rng[bslot]) < hc) {
              if (rng_f01(&bot_rng[bslot]) < skill_headshot(skill)) {
                queue_shoot_head(net, target_net);
              } else {
                queue_shoot(net, target_net);
              }
            }
          }
          // Burst pause: snipers re-chamber slowly, SMGs/autos cycle fast, the
          // rest land on the skill cadence.
          bot_throttle[bslot] = (w == 3) ? 0.6f
                            : (w >= 4 ? 0.2f : 0.25f + 0.2f * (float)(skill % 2));
        }
      }
      // Reload progress ticks down every engaged tick; on completion the
      // magazine is re-seated (firing resumes at the next fire window).
      if (bot_reload_ticks[bslot] > 0) {
        bot_reload_ticks[bslot]--;
        if (bot_reload_ticks[bslot] == 0) bot_ammo[bslot] = weapon_mag(w);
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
  e("zdtd_bot v2.5 enabled");
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
      // keys: vision | reaction | agg | selfpres | venge | camp | alert.
      // vision/reaction: 0 resets to the skill-derived default. Personality
      // keys (agg/selfpres/venge/camp/alert, 0..1): a negative value resets
      // to the skill/net-derived default (pers_default).
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
        } else if (keylen == 3 && key[0]=='a' && key[1]=='g' && key[2]=='g') {
          // Personality keys (clanker BotCharacter): 0..1, negative resets to
          // the skill/net-derived default.
          bot_agg[si] = val < 0.f ? pers_default(bot_skill[si], (int)id, 0) : clampf01(val);
        } else if (keylen == 8 && key[0]=='s' && key[1]=='e' && key[2]=='l' && key[3]=='f' && key[4]=='p' && key[5]=='r' && key[6]=='e' && key[7]=='s') {
          bot_selfpres[si] = val < 0.f ? pers_default(bot_skill[si], (int)id, 1) : clampf01(val);
        } else if (keylen == 5 && key[0]=='v' && key[1]=='e' && key[2]=='n' && key[3]=='g' && key[4]=='e') {
          bot_venge[si] = val < 0.f ? pers_default(bot_skill[si], (int)id, 2) : clampf01(val);
        } else if (keylen == 4 && key[0]=='c' && key[1]=='a' && key[2]=='m' && key[3]=='p') {
          bot_camp[si] = val < 0.f ? pers_default(bot_skill[si], (int)id, 3) : clampf01(val);
        } else if (keylen == 5 && key[0]=='a' && key[1]=='l' && key[2]=='e' && key[3]=='r' && key[4]=='t') {
          bot_alert[si] = val < 0.f ? pers_default(bot_skill[si], (int)id, 4) : clampf01(val);
        } else {
          cfg_ok = 0;
        }
      }
      if (cfg_ok) rn += st(reply_buf + rn, 599 - rn, "bot cfg set\n");
      else rn += st(reply_buf + rn, 599 - rn, "bot cfg: unknown key (vision|reaction|agg|selfpres|venge|camp|alert)\n");
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
