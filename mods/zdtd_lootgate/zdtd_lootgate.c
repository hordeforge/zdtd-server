// zdtd_lootgate — a loot-roll policy plugin (AGENTS.md rule 29, Wasm-first).
// Reference module for the on_loot_roll verdict: it scales every rolled loot
// stack count to 50% (a "half loot" server policy) and logs each roll. The
// policy is the module: enable it via [plugin] modules, no native code.
//
// Verdict semantics: <0 empty the roll, 0 keep, >0 scale the rolled stack
// count by percent. This module returns 50 for every loot list.
//
// Build (clang, committed as mods/zdtd_lootgate/zdtd_lootgate.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_lootgate/zdtd_lootgate.wasm mods/zdtd_lootgate/zdtd_lootgate.c

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
  e("zdtd_lootgate v1.0 enabled (loot scaled to 50%)");
  flush(1);
}

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_lootgate shutdown");
  flush(1);
}

int on_loot_roll(int list_ptr, int list_len, int rolled) {
  const char *list = (const char *)list_ptr;
  out_n = 0;
  e("loot roll: list=");
  int i;
  for (i = 0; i < list_len && out_n < OUT_CAP - 1; ++i) out[out_n++] = list[i];
  e(" rolled="); e_int(rolled); e(" -> 50%");
  flush(1);
  return 50; // scale every roll to 50%
}

// Declarative dependency check (paper: reactive coeffects).
long long _zdtd_requires(void) {
  static const char spec[] = "on_loot_roll,log";
  return (long long)(unsigned long)spec | ((long long)(unsigned long)(sizeof(spec) - 1) << 32);
}
