// Trapping Wasm fixture for the T15 hook surface: on_entity_killed executes
// `unreachable`, so the host must disable only this module and keep the server
// ticking (same budget/trap handling as the existing hooks). Built with clang:
//
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_trap.wasm assets/fixtures/plugin_trap.c

int on_entity_killed(int killed, int killer) {
  // Trap: undefined instruction. The host catches the trap, disables this
  // module, and logs the hook + module name.
  __builtin_trap();
}
