// Wasm login-gate fixture: deny the exact name "rejectme" with a reason,
// allow everyone else. Exercises the on_player_login join gate.
__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

int on_player_login(int peer_slot, int name_ptr, int name_len, int out_ptr, int out_cap) {
  (void)peer_slot;
  char *name = (char *)name_ptr;
  char *out = (char *)out_ptr;
  if (name_len == 8 && name[0] == 'r' && name[1] == 'e' && name[2] == 'j' &&
      name[3] == 'e' && name[4] == 'c' && name[5] == 't' && name[6] == 'm' &&
      name[7] == 'e') {
    if (out_cap < 4) return -4;
    out[0] = 'n'; out[1] = 'o'; out[2] = 'p'; out[3] = 'e';
    return -4;
  }
  return 0;
}
void on_enable(void) {}
void on_shutdown(void) {}
