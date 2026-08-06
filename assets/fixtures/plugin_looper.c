// Deliberately hostile Wasm plugin fixture for the zdtd plugin runtime
// (ADR 0020, PLUGIN_DEV.md): on_tick never returns. The runtime's fuel budget
// must cut the call off, disable this module, and leave the server ticking.
// Built with clang (no libc, no WASI imports):
//
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_looper.wasm assets/fixtures/plugin_looper.c
//
// The volatile sink keeps LLVM from compiling the loop to `unreachable`;
// it burns real instructions so the fuel budget is what stops it.

void on_enable(void) {}

void on_tick(void) {
  for (;;) {
    volatile int sink = 0;
  }
}

void on_shutdown(void) {}
