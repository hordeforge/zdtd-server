// Override-point Wasm fixture for PRD 0005: exports on_loot_roll (scales the
// rolled stack count to 300%) and on_craft_request (denies every craft).
// Used by the scenario that proves an exclusive core override point routes
// only to the claiming mod and skips the native default. Built with clang:
//
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_override.wasm assets/fixtures/plugin_override.c

// Verdicts the host reads as i32 returns (PLUGIN_DEV.md).
int on_loot_roll(int list_name_ptr, int list_name_len, int rolled) {
  // Adjust: the claiming mod decides 300% of the proposed count.
  (void)list_name_ptr;
  (void)list_name_len;
  return 300;
}

int on_craft_request(int player, int recipe_ptr, int recipe_len, int times) {
  // Deny every craft request: the claiming mod is the only decision maker.
  (void)player;
  (void)recipe_ptr;
  (void)recipe_len;
  (void)times;
  return -1;
}
