// Well-behaved Wasm plugin fixture for the zdtd plugin runtime (ADR 0020,
// PLUGIN_DEV.md). Logs on enable, logs the tick number on each tick, and queues
// a spawn SimCommand on the first few ticks to prove the command lands in the
// sim. Built with clang (no libc, no WASI imports):
//
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_hello.wasm assets/fixtures/plugin_hello.c
//
// The zdtd host import table is module "zdtd" with the bare field names
// log(level, ptr, len), tick() -> i64 and queue(ptr, len) -> i32; the local C
// symbol below can be called anything, only import_module/import_name matter.

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);
__attribute__((import_module("zdtd"), import_name("tick")))
extern long long zdtd_tick(void);
__attribute__((import_module("zdtd"), import_name("queue")))
extern int zdtd_queue(int ptr, int len);

static char mem[512];
static int memlen;

static void emit(const char *s) {
  while (*s && memlen < 511) mem[memlen++] = *s++;
}

static void emit_int(long long v) {
  char t[24];
  int n = 0;
  if (v == 0) {
    t[n++] = '0';
  } else {
    if (v < 0) {
      emit("-");
      v = -v;
    }
    while (v > 0) {
      t[n++] = (char)('0' + v % 10);
      v /= 10;
    }
  }
  while (n > 0) emit(&t[--n]);
}

static void flush(int level) {
  zdtd_log(level, (int)(long)&mem[0], memlen);
  memlen = 0;
}

void on_enable(void) {
  emit("hello enabled");
  flush(1);
}

static int ticks = 0;

void on_tick(void) {
  long long t = zdtd_tick();
  ticks++;
  emit("tick ");
  emit_int(t);
  flush(1);
  // First three ticks: queue one spawn each. The host applies the queued
  // SimCommand on a later tick's drain, which the scenario asserts.
  if (ticks <= 3) {
    memlen = 0;
    emit("spawn 256 70 256 40");
    zdtd_queue((int)(long)&mem[0], memlen);
    memlen = 0;
  }
}

void on_player_join(int slot, int entity_id) {
  emit("join ");
  emit_int(entity_id);
  flush(1);
}

void on_shutdown(void) {
  emit("shutdown");
  flush(1);
}
