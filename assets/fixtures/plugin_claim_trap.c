// Claimant fixture for the reactive-claim scenario (paper 5.1.2): exports
// on_loot_roll and traps on the first call, so the host disables the module
// while its exclusive `loot.roll` claim is still in the table. The scenario
// proves the point then falls back to the ordinary composition loop instead of
// being routed to a provider that has stopped providing. Built with clang:
//
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_claim_trap.wasm assets/fixtures/plugin_claim_trap.c

int on_loot_roll(int list_name_ptr, int list_name_len, int rolled) {
  // Trap: undefined instruction. The host catches it, disables this module,
  // and the claim it holds must stop binding.
  (void)list_name_ptr;
  (void)list_name_len;
  (void)rolled;
  __builtin_trap();
}

// Declarative dependency spec (ADR 0030) in the host's packed i64 ABI (low 32
// bits pointer, high 32 bits length). This fixture is loaded as a discovered
// mod, where a module that exports hooks must declare them.
static const char zdtd_requires_spec[] = "log,on_loot_roll";
__attribute__((visibility("default"))) long long _zdtd_requires(void) {
    return (long long)((unsigned long long)(unsigned long)&zdtd_requires_spec[0] |
                       ((unsigned long long)(sizeof(zdtd_requires_spec) - 1) << 32));
}
