// zdtd_rewardgate — quest-reward scaling via the on_quest_complete verdict
// (AGENTS.md rule 29, Wasm-first). Demonstrates the reward-scaling affordance:
// a module decides what a completed quest pays out, per quest.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_quest_complete(player: i32, quest_def: i32) -> i32
//     <0  deny the rewards entirely
//      0  keep stock rewards (100%)
//     >0  pay rewards at that percent (150 = 1.5x)
//
// The host applies the verdict at the single reward-payout choke point
// (server/game/step.zig: reward loop), so a module never touches inventory
// directly — it only shapes the payout the server already makes.
//
// Default policy: 150 (1.5x) on every quest. Specialize per quest_def (the
// catalog def id) for per-quest rules, e.g.:
//   if (quest_def == 7) return 200;   // double the trader fetch chain
//   if (quest_def == 3) return 0;     // no rewards on the tutorial
//
// Build (clang, committed as mods/zdtd_rewardgate/zdtd_rewardgate.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_rewardgate/zdtd_rewardgate.wasm mods/zdtd_rewardgate/zdtd_rewardgate.c
// Enable via zdtd.toml: [plugin] modules = "mods/zdtd_rewardgate/zdtd_rewardgate.wasm"

__attribute__((import_module("zdtd"), import_name("log")))
extern void zdtd_log(int level, int ptr, int len);

#define OUT_CAP 160
static char out[OUT_CAP];
static int out_n;

static void log_msg(const char *s) {
  out_n = 0;
  const char *p = s;
  while (*p && out_n < OUT_CAP - 1) out[out_n++] = *p++;
  zdtd_log(0, (int)(long)out, out_n);
}

__attribute__((export_name("on_enable")))
void on_enable(void) {
  log_msg("zdtd_rewardgate v1.0 enabled (1.5x quest rewards)");

}

__attribute__((export_name("on_shutdown")))
void on_shutdown(void) {
  log_msg("zdtd_rewardgate shutdown");

}

__attribute__((export_name("on_quest_complete")))
int on_quest_complete(int player, int quest_def) {
  (void)player;
  (void)quest_def;
  return 150; // 1.5x rewards on every quest
}
