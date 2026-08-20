// Deliberately broken declarative-dependency fixture: `_zdtd_requires` names a
// capability that does not exist (typo'd hook), so the host must reject the
// module at load with a loud error instead of silently never firing the hook.
// Built with clang:
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_requires_bad.wasm assets/fixtures/plugin_requires_bad.c

void on_enable(void) {}

long long _zdtd_requires(void) {
  static const char spec[] = "on_trader_event,on_typo_hook";
  return (long long)(unsigned long)spec | ((long long)(unsigned long)(sizeof(spec) - 1) << 32);
}
