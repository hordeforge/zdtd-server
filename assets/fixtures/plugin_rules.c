// Rule-module Wasm fixture for the T15 hook surface (ADR 0021 decision 4):
// exports the four event hooks with a deny/adjust return convention:
//   < 0 deny the outcome, 0 keep behaviour, > 0 adjust (percent).
// on_player_death denies every death; on_block_damage doubles the damage;
// on_quest_complete doubles the reward. Built with clang (no libc, no WASI):
//
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o assets/fixtures/plugin_rules.wasm assets/fixtures/plugin_rules.c

// Verdicts the host reads as i32 returns (PLUGIN_DEV.md).
int on_player_death(int victim) {
  // Deny every player death: the sim keeps the victim at 1 hp.
  return -1;
}

int on_entity_killed(int killed, int killer) {
  // Observe only: keep the kill.
  return 0;
}

int on_block_damage(int x, int y, int z, int dmg) {
  // Adjust: apply 200% of the proposed damage.
  return 200;
}

int on_quest_complete(int player, int quest_def) {
  // Adjust: double the reward payout.
  return 200;
}
