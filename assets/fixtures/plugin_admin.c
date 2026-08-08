// Wasm admin-command fixture: handles "ping" -> "pong\n", otherwise not handled.
// Built with: clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all -o assets/fixtures/plugin_admin.wasm assets/fixtures/plugin_admin.c
// The host calls on_admin_command(cmd_ptr, cmd_len, out_ptr, out_cap) -> i32 (bytes written, 0 not handled).
// Memory is the guest's linear memory; pointers are byte offsets.
__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

static int mem_eq(const char *a, int alen, const char *b) {
  int blen = 0; while (b[blen]) blen++;
  if (alen < blen) return 0;
  for (int i = 0; i < blen; i++) if (a[i] != b[i]) return 0;
  // Require exact verb or verb + space prefix: "ping" matches "ping" and "ping args".
  if (alen == blen) return 1;
  return a[blen] == ' ' || a[blen] == '\t';
}

int on_admin_command(int cmd_ptr, int cmd_len, int out_ptr, int out_cap) {
  char *cmd = (char *)cmd_ptr;
  char *out = (char *)out_ptr;
  // Trim leading spaces like the host does.
  int off = 0; while (off < cmd_len && (cmd[off] == ' ' || cmd[off] == '\t')) off++;
  cmd += off; cmd_len -= off;
  if (mem_eq(cmd, cmd_len, "ping")) {
    const char *rep = "pong\n"; int n = 5;
    if (n > out_cap) n = out_cap;
    for (int i = 0; i < n; i++) out[i] = rep[i];
    return n;
  }
  if (mem_eq(cmd, cmd_len, "echo")) {
    // Echo args after "echo ".
    int verb = 4; while (verb < cmd_len && cmd[verb] != ' ' && cmd[verb] != '\t') verb++;
    while (verb < cmd_len && (cmd[verb] == ' ' || cmd[verb] == '\t')) verb++;
    int n = cmd_len - verb;
    if (n > out_cap) n = out_cap;
    for (int i = 0; i < n; i++) out[i] = cmd[verb + i];
    if (n < out_cap) { out[n++] = '\n'; }
    return n;
  }
  return 0;
}

void on_enable(void) { const char *m = "admin fixture enabled"; zdtd_log(1, (int)(long)m, 21); }
void on_shutdown(void) {}
