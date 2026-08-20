// zdtd_craftgate — a craft-request policy plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for the on_craft_request verdict: it denies
// crafting any recipe whose name starts with "forbidden_" (a blacklist-by-
// naming policy, the same shape as zdtd_questgate) and logs every request.
// The policy is the module: enable it via [plugin] modules, no native code.
//
// Build (clang, committed as mods/zdtd_craftgate/zdtd_craftgate.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_craftgate/zdtd_craftgate.wasm mods/zdtd_craftgate/zdtd_craftgate.c

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

static int name_starts_forbidden(const char *s, int len) {
  static const char prefix[10] = { 'f','o','r','b','i','d','d','e','n','_' };
  if (len < 10) return 0;
  int i;
  for (i = 0; i < 10; ++i) if (s[i] != prefix[i]) return 0;
  return 1;
}

void on_enable(void) {
  out_n = 0;
  e("zdtd_craftgate v1.0 enabled (deny recipes named forbidden_*)");
  flush(1);
}

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_craftgate shutdown");
  flush(1);
}

int on_craft_request(int player, int name_ptr, int name_len, int times) {
  const char *name = (const char *)name_ptr;
  const int forb = name_starts_forbidden(name, name_len);
  out_n = 0;
  e("craft request: player="); e_int(player); e(" times="); e_int(times); e(" recipe=");
  int i;
  for (i = 0; i < name_len && out_n < OUT_CAP - 1; ++i) out[out_n++] = name[i];
  if (forb) {
    e(" DENIED");
    flush(1);
    return -1; // deny the craft
  }
  flush(1);
  return 0; // keep everything else
}
