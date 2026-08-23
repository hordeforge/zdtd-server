// zdtd_announce — server chat announcements via the `zdtd.queue say` verb
// (AGENTS.md rule 29, Wasm-first). v2 adds clock announcements from the
// zdtd.sense header (v3: world_time + blood_moon): day rolls and blood-moon
// start/end, alongside the join/leave broadcasts.
//
// Hooks used (docs/PLUGIN_DEV.md "Hooks"):
//   on_enable / on_shutdown / on_tick
//   on_player_join(slot: i32, entity_id: i32)
//   on_player_leave(slot: i32, entity_id: i32)
// Verdict convention: this module is a pure announcer, so it returns 0
// everywhere (keep the stock outcome).
//
// Imports: zdtd.log, zdtd.queue with the `say` verb, zdtd.sense (header only:
// magic 'ZBS3' @0, world_time u32 @16, blood_moon u32 @20 — see
// docs/rfc/0001-fps-bot-spec.md).
//
// Build (clang, committed as mods/zdtd_announce/zdtd_announce.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_announce/zdtd_announce.wasm mods/zdtd_announce/zdtd_announce.c
// Enable via zdtd.toml: [plugin] modules = "mods/zdtd_announce/zdtd_announce.wasm"

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

__attribute__((import_module("zdtd"), import_name("queue")))
extern int zdtd_queue(int ptr, int len);

__attribute__((import_module("zdtd"), import_name("sense")))
extern int zdtd_sense(int ptr, int len, int reserved);

#define OUT_CAP 160
static char out[OUT_CAP];
static int out_n;

#define SENSE_CAP 64
static char sense[SENSE_CAP];

static void e(const char *s) {
  while (*s && out_n < OUT_CAP - 1) out[out_n++] = *s++;
}
static void e_int(long long v) {
  char t[24];
  int n = 0;
  if (v == 0) {
    t[n++] = '0';
  } else {
    while (v > 0 && n < 23) { t[n++] = (char)('0' + (int)(v % 10)); v /= 10; }
  }
  int i;
  for (i = n - 1; i >= 0; i--) if (out_n < OUT_CAP - 1) out[out_n++] = t[i];
}

static void log_msg(const char *s) {
  out_n = 0;
  e(s);
  zdtd_log(0, (int)(long)out, out_n);
}

static void say(const char *s) {
  out_n = 0;
  e("say ");
  e(s);
  zdtd_queue((int)(long)out, out_n);
}

// Last-seen clock state (the instance persists across on_tick calls).
static int last_day = -1;
static int last_blood_moon = -1;

// Read the v3 sense header; returns 1 on success, 0 if the snapshot is
// unavailable/mismatched (nothing to announce that tick).
static int clock_state(int *day, int *blood_moon) {
  int n = zdtd_sense((int)(long)&sense[0], SENSE_CAP, 0);
  if (n < 24) return 0;
  unsigned char *h = (unsigned char *)&sense[0];
  if (h[0] != 'Z' || h[1] != 'B' || h[2] != 'S' || h[3] != '3') return 0;
  unsigned wt = (unsigned)h[16] | ((unsigned)h[17] << 8) |
                ((unsigned)h[18] << 16) | ((unsigned)h[19] << 24);
  unsigned bm = (unsigned)h[20] | ((unsigned)h[21] << 8) |
                ((unsigned)h[22] << 16) | ((unsigned)h[23] << 24);
  *day = (int)(wt / 24000);
  *blood_moon = (bm != 0) ? 1 : 0;
  return 1;
}

__attribute__((export_name("on_enable")))
void on_enable(void) {
  log_msg("zdtd_announce v2.0 enabled (day + blood-moon announcements)");
}

__attribute__((export_name("on_shutdown")))
void on_shutdown(void) {
  log_msg("zdtd_announce shutdown");
}

__attribute__((export_name("on_tick")))
void on_tick(void) {
  int day, bm;
  if (!clock_state(&day, &bm)) return;
  if (last_day >= 0 && day != last_day) {
    // Day roll: announce every day (a mode can gate this).
    out_n = 0;
    e("say Day ");
    e_int(day);
    zdtd_queue((int)(long)out, out_n);
  }
  if (last_blood_moon >= 0 && bm != last_blood_moon) {
    say(bm ? "The blood moon rises!" : "The blood moon fades.");
  }
  last_day = day;
  last_blood_moon = bm;

}

// Pure announcer: never touches the outcome.
__attribute__((export_name("on_player_join")))
void on_player_join(int slot, int entity_id) {
  (void)slot;
  (void)entity_id;
  say("A new survivor has joined the wasteland.");
}

__attribute__((export_name("on_player_leave")))
void on_player_leave(int slot, int entity_id) {
  (void)slot;
  (void)entity_id;
  say("A survivor has left the wasteland.");
}
