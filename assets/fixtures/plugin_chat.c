// Wasm chat-filter fixture: suppress "bad", rewrite "hello" -> "hi".
__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

int on_chat(int sender, int msg_ptr, int msg_len, int out_ptr, int out_cap) {
  (void)sender;
  char *msg = (char *)msg_ptr;
  char *out = (char *)out_ptr;
  // exact deny: message equals "bad"
  if (msg_len == 3 && msg[0] == 'b' && msg[1] == 'a' && msg[2] == 'd') return -1;
  // exact rewrite: "hello" -> "hi"
  if (msg_len == 5 && msg[0] == 'h' && msg[1] == 'e' && msg[2] == 'l' && msg[3] == 'l' && msg[4] == 'o') {
    if (out_cap < 2) return 0;
    out[0] = 'h'; out[1] = 'i';
    return 2;
  }
  return 0;
}
void on_enable(void) {}
void on_shutdown(void) {}
