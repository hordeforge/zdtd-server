// zdtd_bot — FPS bot addon (ADR 0026, docs/BOTS_SPEC.md / BOTS_PRD.md).
//
// A WebAssembly plugin that commands player-mesh FPS bots through the host's
// sense/act boundary. The servant (host) owns spawn/tick/replicate/kill/LOS
// and move caps; this module owns the *brain* — target selection, aim/reaction,
// fire throttling and strafe — distilled from the Quake 3 / Doom 3 bot model
// as the 7dtd-clanker reference does (docs/q3-inspiration-notes.md).
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
  // Two-decimal rendering; enough for debug and commands we send.
  long long whole = (long long)v;
  int frac = (int)((v - (float)whole) * 100.0f + (v < 0 ? -0.5f : 0.5f));
  if (frac == 100) { whole += 1; frac = 0; }
  e_int(whole);
  e(".");
  if (frac < 0) frac = -frac;
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
// Unused now, kept as documented sense-record accessors (rec_self/rec_hp/
// rec_target document the full record layout for future guest logic).
static int rec_self(int i) __attribute__((unused));
static int rec_self(int i)       { return s8(REC_OFF(i) + 5); }
static float rec_hp(int i) __attribute__((unused));
static float rec_hp(int i)       { return sf32(REC_OFF(i) + 20); }
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
// Brain (Q3 / Doom 3 inspired, distilled).
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

// Skill-scaled reaction and vision (Q3 skill 0..4).
static float skill_vision(int skill) { return 25.f + 8.f * (float)skill; }
static float skill_reaction(int skill) {
  float r = 0.6f - 0.11f * (float)skill;
  return r < 0.08f ? 0.08f : r;
}

// One on_tick pass: sense, then drive every bot we see.
static void brain_tick(void) {
  const int n = sense_refresh();
  if (n <= 0) return;

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
    }
    const int skill = bot_skill[bslot];
    const float vision = skill_vision(skill);

    // Pick the nearest hostile candidate within vision (players/zombies/other
    // bots, not ourselves).
    int ti = -1;
    float best_d = vision * vision;
    int j;
    for (j = 0; j < n; ++j) {
      if (j == bi) continue;
      if (!rec_kind_alive(j)) continue;
      const float dx = rec_x(j) - bx, dz = rec_z(j) - bz;
      const float d2 = dx * dx + dz * dz;
      if (d2 < best_d) { best_d = d2; ti = j; }
    }

    if (ti < 0) {
      // Wander slowly toward a stored point (avoid standing dead still).
      if (bot_wander_x[bslot] == 0.f && bot_wander_z[bslot] == 0.f) {
        bot_wander_x[bslot] = bx + 10.f;
        bot_wander_z[bslot] = bz + 8.f;
      }
      float dx = bot_wander_x[bslot] - bx, dz = bot_wander_z[bslot] - bz;
      if (dx * dx + dz * dz < 2.f) {
        bot_wander_x[bslot] = bx + ((bi % 5) - 2) * 6.f;
        bot_wander_z[bslot] = bz + 6.f;
      }
      queue_move(net, bot_wander_x[bslot], by, bot_wander_z[bslot], 1.4f);
      bot_target[bslot] = -1;
      continue;
    }

    const int target_net = rec_net(ti);
    if (bot_target[bslot] != target_net) {
      bot_target[bslot] = target_net;
      bot_react[bslot] = skill_reaction(skill);
    }
    if (bot_react[bslot] > 0.f) bot_react[bslot] -= TICK_DT;

    const float tx = rec_x(ti), tz = rec_z(ti);
    const float dx = tx - bx, dz = tz - bz;
    const float dist = sqrtf_impl(dx * dx + dz * dz);

    // Face the target (host clamps look; we just send yaw).
    float yaw = atan2f_impl(dz, dx) + 1.570796f; // +90°: yaw zero faces +X
    queue_look(net, yaw);

    // Strafe (perpendicular orbit) when close enough to attack.
    const float attack_range = (float)(skill >= 3 ? 30 : skill >= 1 ? 22 : 15);
    if (dist < attack_range) {
      // Simple alternating strafe direction by slot parity.
      float ox = -dz, oz = dx; // perpendicular
      float s = (bi & 1) ? 1.f : -1.f;
      float mx = bx + ox * 1.2f, mz = bz + oz * 1.2f;
      // Stay close to target: mix toward target to avoid orbiting away.
      mx = bx + (tx - bx) * 0.3f + s * ox * 1.0f;
      mz = bz + (tz - bz) * 0.3f + s * oz * 1.0f;
      queue_move(net, mx, by, mz, 3.f);
      // Fire if reaction elapsed and throttle open.
      if (bot_react[bslot] <= 0.f && bot_throttle[bslot] <= 0.f) {
        queue_shoot(net, target_net);
        bot_throttle[bslot] = 0.25f + 0.2f * (float)(skill % 2); // burst-ish cadence
      }
    } else {
      // Chase toward target.
      float mx = bx + dx * 0.4f, mz = bz + dz * 0.4f;
      queue_move(net, mx, by, mz, (skill >= 2) ? 4.2f : 3.2f);
    }
    if (bot_throttle[bslot] > 0.f) bot_throttle[bslot] -= TICK_DT;
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
  float a = (ax < ay) ? (3.14159265f * 0.25f) - 0.5f : 0.5f; // not exact
  (void)a;
  // Use a simple approximation: atan(y/x) within +/- pi/4, then quadrant.
  float base;
  if (ax < 1e-6f) {
    return (y >= 0.f) ? 1.570796f : -1.570796f;
  }
  base = (ay / ax) * 0.785398f; // linear approx of atan for 0..1
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
  e("zdtd_bot v1.0 enabled");
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
        "bot count <n>\nbot skill <0-4>\n";
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
        while (*p && out_n < 250) out[out_n++] = *p++;
        while (*arg && out_n < 250) out[out_n++] = *arg++;
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
      while (*pp && out_n < 250) out[out_n++] = *pp++;
      while (*arg && out_n < 250) out[out_n++] = *arg++;
      out[out_n] = 0;
      zdtd_queue((int)(long)&out[0], out_n);
      out_n = 0;
      rn += st(reply_buf + rn, 599 - rn, "spawned\n");
    } else if (slen == 6 && sub[0]=='r' && sub[1]=='e' && sub[2]=='m' && sub[3]=='o' && sub[4]=='v' && sub[5]=='e') {
      static const char *rp = "bot remove ";
      const char *pp = rp;
      out_n = 0;
      while (*pp && out_n < 250) out[out_n++] = *pp++;
      while (*arg && out_n < 250) out[out_n++] = *arg++;
      out[out_n] = 0;
      zdtd_queue((int)(long)&out[0], out_n);
      out_n = 0;
      rn += st(reply_buf + rn, 599 - rn, "removed\n");
    } else if (slen == 5 && sub[0]=='s' && sub[1]=='k' && sub[2]=='i' && sub[3]=='l' && sub[4]=='l') {
      int v = (int)strtol_impl(arg);
      if (v < 0) v = 0; if (v > 4) v = 4;
      int i2;
      for (i2 = 0; i2 < MAX_BOTS; ++i2) bot_skill[i2] = v; // affects new bots
      rn += st(reply_buf + rn, 599 - rn, "bot skill ");
      rn += e_to(reply_buf + rn, 599 - rn, v);
      rn += st(reply_buf + rn, 599 - rn, "\n");
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
