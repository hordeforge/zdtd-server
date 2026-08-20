// zdtd_pvp — a player-damage policy plugin (AGENTS.md rule 29, Wasm-first).
// Reference module for the on_player_damage verdict + the "kind" query verb:
// it denies ALL player-vs-player damage (a strict no-PvP policy) while
// leaving player-vs-zombie and zombie-vs-player damage untouched. The policy
// is the module: an operator enables it by adding it to [plugin] modules, no
// native code or serverconfig change.
//
// Query used (docs/PLUGIN_DEV.md "Host imports"): "kind <net_id>" -> "0"
// player, "1" zombie/animal, "2" bot, "" unknown.
//
// Build (clang, committed as mods/zdtd_pvp/zdtd_pvp.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_pvp/zdtd_pvp.wasm mods/zdtd_pvp/zdtd_pvp.c

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);
__attribute__((import_module("zdtd"), import_name("query")))
extern int zdtd_query(int req_ptr, int req_len, int out_ptr, int out_cap);

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

static char qbuf[8];

// "kind <net_id>" -> -1 unknown, else 0 player / 1 zombie-animal / 2 bot.
static int query_kind(long net_id) {
  char req[24];
  int rn = 0;
  const char *k = "kind ";
  while (*k && rn < 23) req[rn++] = *k++;
  char t[16];
  int n = 0;
  if (net_id == 0) {
    t[n++] = '0';
  } else {
    if (net_id < 0) { req[rn++] = '-'; net_id = -net_id; }
    while (net_id > 0 && n < 15) { t[n++] = (char)('0' + (int)(net_id % 10)); net_id /= 10; }
    int i;
    for (i = n - 1; i >= 0; --i) req[rn++] = t[i];
  }
  const int qn = zdtd_query((int)(long)&req[0], rn, (int)(long)&qbuf[0], 8);
  if (qn != 1) return -1;
  return qbuf[0] - '0';
}

void on_enable(void) {
  out_n = 0;
  e("zdtd_pvp v1.0 enabled (deny player-vs-player damage)");
  flush(1);
}

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_pvp shutdown");
  flush(1);
}

int on_player_damage(int attacker, int victim, int amount) {
  (void)amount;
  const int ak = query_kind(attacker);
  const int vk = query_kind(victim);
  if (ak == 0 && vk == 0) {
    out_n = 0;
    e("pvp deny: "); e_int(attacker); e(" -> "); e_int(victim);
    flush(1);
    return -1; // deny the hit
  }
  return 0; // keep everything else
}
