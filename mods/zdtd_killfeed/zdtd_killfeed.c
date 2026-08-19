// zdtd_killfeed — a minimal event-observer plugin (AGENTS.md rule 29,
// "Wasm-first": anything that is discretionary behavior ships as a Wasm
// plugin). Reference module for announcements, kill-feeds, scoreboards and
// external integrations: it observes the event/verdict hooks, logs each event
// to the server log and always keeps the stock outcome (returns 0).
//
// Hooks used (see docs/PLUGIN_DEV.md "Hooks"):
//   on_player_join(slot: i32, entity_id: i32)
//   on_player_leave(slot: i32, entity_id: i32)
//   on_player_death(victim: i32) -> i32
//   on_entity_killed(killed: i32, killer: i32) -> i32
//   on_quest_complete(player: i32, quest_def: i32) -> i32
// Verdict convention: <0 deny, 0 keep, >0 adjust (per hook). A pure observer
// returns 0 everywhere. No imports beyond zdtd.log: this module neither reads
// the sim nor queues commands, so it is a zero-risk addition to any server.
//
// Build (clang, committed as mods/zdtd_killfeed/zdtd_killfeed.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_killfeed/zdtd_killfeed.wasm mods/zdtd_killfeed/zdtd_killfeed.c

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

#define OUT_CAP 160
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
  int i;
  for (i = n - 1; i >= 0; --i) {
    if (out_n < OUT_CAP - 1) out[out_n++] = t[i];
  }
}
static void flush(int level) {
  if (out_n > 0) {
    zdtd_log(level, (int)(long)&out[0], out_n);
    out_n = 0;
  }
}

void on_enable(void) {
  out_n = 0;
  e("zdtd_killfeed v1.0 enabled (observer: kill/death/quest hooks)");
  flush(1);
}

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_killfeed shutdown");
  flush(1);
}

void on_player_join(int slot, int entity_id) {
  out_n = 0;
  e("join: slot="); e_int(slot); e(" entity="); e_int(entity_id);
  flush(1);
}

void on_player_leave(int slot, int entity_id) {
  out_n = 0;
  e("leave: slot="); e_int(slot); e(" entity="); e_int(entity_id);
  flush(1);
}

int on_entity_killed(int killed, int killer) {
  out_n = 0;
  e("kill: killer="); e_int(killer); e(" killed="); e_int(killed);
  flush(1);
  return 0; // keep the stock outcome
}

int on_player_death(int victim) {
  out_n = 0;
  e("death: victim="); e_int(victim);
  flush(1);
  return 0;
}

int on_quest_complete(int player, int quest_def) {
  out_n = 0;
  e("quest complete: player="); e_int(player); e(" def="); e_int(quest_def);
  flush(1);
  return 0;
}
