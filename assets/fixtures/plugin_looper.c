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

// Declarative dependency spec (ADR 0030) in the host's packed i64 ABI (low 32
// bits pointer, high 32 bits length). This fixture is loaded as a discovered
// mod by tests, where a module that exports hooks must declare them.
static const char zdtd_requires_spec[] = "log,on_enable,on_tick,on_shutdown";
__attribute__((visibility("default"))) long long _zdtd_requires(void) {
    return (long long)((unsigned long long)(unsigned long)&zdtd_requires_spec[0] |
                       ((unsigned long long)(sizeof(zdtd_requires_spec) - 1) << 32));
}
