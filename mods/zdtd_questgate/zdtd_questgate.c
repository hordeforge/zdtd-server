// zdtd_questgate — a quest-acceptance policy plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for the on_quest_accept verdict + the "quest"
// query verb: it denies accepting any quest whose name starts with
// "forbidden_" (a strict whitelist-by-naming policy) and logs every
// acceptance. The policy is the module: an operator enables it by adding it
// to [plugin] modules, no native code or serverconfig change.
//
// Query used (docs/PLUGIN_DEV.md "Host imports"): "quest <def_id>" -> the
// quest def's name (the stable key; numeric def ids vary across versions).
//
// Build (clang, committed as mods/zdtd_questgate/zdtd_questgate.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_questgate/zdtd_questgate.wasm mods/zdtd_questgate/zdtd_questgate.c

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

// "quest <def_id>" -> bytes written of the quest name, or 0 when unknown.
static int query_quest_name(long def_id, char *buf, int cap) {
  char req[24];
  int rn = 0;
  const char *k = "quest ";
  while (*k && rn < 23) req[rn++] = *k++;
  char t[16];
  int n = 0;
  if (def_id == 0) {
    t[n++] = '0';
  } else {
    while (def_id > 0 && n < 15) { t[n++] = (char)('0' + (int)(def_id % 10)); def_id /= 10; }
    int i;
    for (i = n - 1; i >= 0; --i) req[rn++] = t[i];
  }
  return zdtd_query((int)(long)&req[0], rn, (int)(long)buf, cap);
}

static int name_starts_forbidden(const char *s, int len) {
  static const char prefix[10] = { 'f','o','r','b','i','d','d','e','n','_' };
  if (len < 10) return 0;
  int i;
  for (i = 0; i < 10; ++i) if (s[i] != prefix[i]) return 0;
  return 1;
}

void on_enable(void) {
  out_n = 0;
  e("zdtd_questgate v1.0 enabled (deny quests named forbidden_*)");
  flush(1);
}

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_questgate shutdown");
  flush(1);
}

int on_quest_accept(int player, int def_id) {
  char name[64];
  const int nn = query_quest_name(def_id, name, 64);
  const int forb = name_starts_forbidden(name, nn);
  out_n = 0;
  e("quest accept: player="); e_int(player); e(" def="); e_int(def_id); e(" name=");
  int i;
  for (i = 0; i < nn && out_n < OUT_CAP - 1; ++i) out[out_n++] = name[i];
  if (forb) {
    e(" DENIED");
    flush(1);
    return -1; // deny the accept
  }
  flush(1);
  return 0; // keep everything else
}
