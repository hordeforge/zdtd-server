// zdtd_damagegate — incoming-player-damage scaling via the on_player_damage
// verdict (AGENTS.md rule 29, Wasm-first). The verdict is wired in the C2S
// melee path (c2s/misc.zig), the ECS zombie-melee path (applyDeferredDamage
// via World.player_damage_verdict_fn), the survival tick (drowning, radiation,
// starvation, game/tick.zig) and the explosion path (c2s/blocks.zig), so a
// module shapes ALL damage directed at players without touching the sim
// directly.
//
// Verdict convention (docs/PLUGIN_DEV.md "Hooks"):
//   on_player_damage(attacker: i32, victim: i32, amount: i32) -> i32
//     <0  deny the hit entirely (victim keeps hp)
//      0  keep stock damage
//     >0  apply that percent of the damage (50 = half)
//
// Default policy: 50 (half incoming player damage). attacker == -1 means the
// attacker is unknown or environmental (zombie melee via the ECS deferred
// path, drowning, radiation, starvation) — those are scaled too.
//
// Build (clang, committed as mods/zdtd_damagegate/zdtd_damagegate.wasm):
//   clang --target=wasm32 -nostdlib -O2 -Wl,--no-entry -Wl,--export-all \
//     -o mods/zdtd_damagegate/zdtd_damagegate.wasm mods/zdtd_damagegate/zdtd_damagegate.c
// Enable via zdtd.toml: [plugin] modules = "mods/zdtd_damagegate/zdtd_damagegate.wasm"

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
  log_msg("zdtd_damagegate v1.0 enabled (0.5x incoming player damage)");
}

__attribute__((export_name("on_shutdown")))
void on_shutdown(void) {
  log_msg("zdtd_damagegate shutdown");
}

__attribute__((export_name("on_player_damage")))
int on_player_damage(int attacker, int victim, int amount) {
  (void)attacker;
  (void)victim;
  (void)amount;
  return 50; // half incoming player damage
}
