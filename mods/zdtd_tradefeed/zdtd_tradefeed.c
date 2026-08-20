// zdtd_tradefeed - a trader-event observer plugin (AGENTS.md rule 29,
// Wasm-first). Reference module for the on_trader_event hook: it logs trader
// window opens, buys and sells (kind 0/1/2). Announcements live in the
// module; the server only fires the event.
//
// Build (clang, committed as mods/zdtd_tradefeed/zdtd_tradefeed.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_tradefeed/zdtd_tradefeed.wasm mods/zdtd_tradefeed/zdtd_tradefeed.c

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
  e("zdtd_tradefeed v1.0 enabled (trader events)");
  flush(1);
}

void on_shutdown(void) {
  out_n = 0;
  e("zdtd_tradefeed shutdown");
  flush(1);
}

void on_trader_event(int player, int trader, int kind) {
  out_n = 0;
  e("trader event: player=");
  e_int(player);
  e(" trader=");
  e_int(trader);
  e(" kind=");
  switch (kind) {
    case 0: e("open"); break;
    case 1: e("buy"); break;
    case 2: e("sell"); break;
    default: e_int(kind); break;
  }
  flush(1);
}
