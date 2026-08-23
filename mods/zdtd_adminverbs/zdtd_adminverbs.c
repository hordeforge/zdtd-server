// zdtd_adminverbs — custom operator verbs via the on_admin_command hook
// (AGENTS.md rule 29, Wasm-first; the hook is otherwise only used by
// zdtd_bot). Demonstrates shipping operator tooling as a module instead of a
// native console arm.
//
// Verb: `wave <n>` — queues <n> zombie spawns at the seed pad (256,70,256)
// via zdtd.queue and replies "wave: spawning <n>".
//
// Convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_admin_command(cmd_ptr, cmd_len, out_ptr, out_cap) -> i32
//     write the reply at out_ptr, return its length (0 = not handled; the
//     next plugin / core console handles it).
//
// Build (clang, committed as mods/zdtd_adminverbs/zdtd_adminverbs.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_adminverbs/zdtd_adminverbs.wasm mods/zdtd_adminverbs/zdtd_adminverbs.c
// Enable via zdtd.toml: [plugin] modules = "mods/zdtd_adminverbs/zdtd_adminverbs.wasm"

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

__attribute__((import_module("zdtd"), import_name("queue")))
extern int zdtd_queue(int ptr, int len);

#define OUT_CAP 160
static char out[OUT_CAP];
static int out_n;

static void e(const char *s) {
  while (*s && out_n < OUT_CAP - 1) out[out_n++] = *s++;
}

static void log_msg(const char *s) {
  out_n = 0;
  e(s);
  zdtd_log(0, (int)(long)out, out_n);
}

__attribute__((export_name("on_enable")))
void on_enable(void) {
  log_msg("zdtd_adminverbs v1.0 enabled (verb: wave <n>)");
}

__attribute__((export_name("on_shutdown")))
void on_shutdown(void) {
  log_msg("zdtd_adminverbs shutdown");
}

// Queue `count` zombies at the seed pad; replies "wave: spawning N".
static int queue_wave(int count, char *reply, int cap) {
  if (count < 1) count = 1;
  if (count > 16) count = 16;
  int i;
  for (i = 0; i < count; ++i) {
    out_n = 0;
    e("spawn 256 70 256 100"); // x y z hp
    zdtd_queue((int)(long)out, out_n);
  }
  int n = 0;
  if (n < cap) reply[n++] = 'w';
  if (n < cap) reply[n++] = 'a';
  if (n < cap) reply[n++] = 'v';
  if (n < cap) reply[n++] = 'e';
  if (n < cap) reply[n++] = ':';
  if (n < cap) reply[n++] = ' ';
  char t[8];
  int tn = 0;
  int v = count;
  if (v == 0) { t[tn++] = '0'; }
  while (v > 0 && tn < 7) { t[tn++] = (char)('0' + (v % 10)); v /= 10; }
  int j;
  for (j = tn - 1; j >= 0; j--) if (n < cap) reply[n++] = t[j];
  return n;
}

// Parse "wave <n>"; anything else falls through (return 0 = not handled).
__attribute__((export_name("on_admin_command")))
int on_admin_command(int cmd_ptr, int cmd_len, int out_ptr, int out_cap) {
  char *cmd = (char *)(long)cmd_ptr;
  char copy[160];
  int cl = cmd_len < 159 ? cmd_len : 159;
  int i;
  for (i = 0; i < cl; ++i) copy[i] = cmd[i];
  copy[cl] = 0;
  char *tok = copy;
  char *sp = tok;
  while (*sp && *sp != ' ' && *sp != '\t') sp++;
  int first_len = (int)(sp - tok);
  if (first_len == 4 && tok[0] == 'w' && tok[1] == 'a' && tok[2] == 'v' && tok[3] == 'e') {
    while (*sp == ' ' || *sp == '\t') sp++;
    int count = 1;
    if (*sp) {
      int n = 0;
      while (sp[n] >= '0' && sp[n] <= '9') { count = count * 10 + (sp[n] - '0'); n++; }
    }
    return queue_wave(count, (char *)(long)out_ptr, out_cap);
  }
  return 0; // not handled
}
