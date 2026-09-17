//! Weather S2C helpers - extracted verbatim from game.zig.
//! anyEnteredClient, the NetPackageWeather body builder and its send paths.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const assets_biome_layers = @import("../../assets/biome_layers.zig");
const world_weather = @import("../../world/weather.zig");

pub fn anyEnteredClient(self: *const Game) bool {
    for (self.clients) |cl| {
        if (cl.entered) return true;
    }
    return false;
}

/// Wire size of one NetPackageWeather entry: biomeId u8 + groupIndex u8 +
/// remainingSeconds u8 + five f32 params (RE weather-environment.md 3).
pub const weather_entry_bytes: usize = 3 + 5 * 4;
/// Entry count when no biomes.xml is loaded at all (the stock 5-biome layout),
/// so an unmodded client still reads a well-formed body.
const no_biomes_weather_count: usize = 5;

/// Build NetPackageWeather from the live weather state machine (omit if none).
pub fn buildWeatherBodyFromBiomes(self: *Game) ?[]const u8 {
    const bl = &self.world.biome_layers_table;
    const wm = &self.world.weather;
    // The stock client sizes its read from biomeWeather.Count, i.e. the loaded
    // biomes whose weatherGroups.Count > 0 (InitBiomeWeather, asm.il ~2050437)
    // - exactly the table's weather_n, which sizes the body on both ends. The
    // wire has no count prefix, so a pinned 5 produced a wrong-length body on
    // any install whose biomes.xml declares a different count (modlets).
    const wire_count: usize = if (bl.weather_n > 0) bl.weather_n else no_biomes_weather_count;
    var wb: [assets_biome_layers.max_weather_biomes]packages.WeatherBiome = undefined;
    var n: usize = 0;
    while (n < wm.n) : (n += 1) {
        const st = &wm.states[n];
        wb[n] = .{
            .biome_id = st.biome_id,
            .group_index = st.group_index,
            .group_count = world_weather.Manager.groupsFor(bl, st).n,
            .remaining_seconds = st.remaining_seconds,
            .params = st.params,
        };
    }
    // Pad or trim to wire_count so content_len matches the client's expected size.
    if (n == 0) {
        // No biomes.xml: mild pine-ish defaults on the raw 0..100 XML scale,
        // group 0 so an unmodded client still resolves a real group.
        var i: usize = 0;
        while (i < wire_count) : (i += 1) {
            wb[i] = .{
                .biome_id = @intCast(i + 1),
                .group_index = 0,
                .group_count = 1,
                .remaining_seconds = 0,
                .params = .{ 70, 0, 20, 10, 5 },
            };
        }
        n = wire_count;
    } else if (n < wire_count) {
        // Table has weather biomes the manager has no state for: keep the count
        // the client reads, but name the real biome ids rather than guessing.
        var i = n;
        while (i < wire_count) : (i += 1) {
            wb[i] = wb[n - 1];
            wb[i].biome_id = if (i < bl.weather_ids.len and bl.weather_ids[i] != 0) bl.weather_ids[i] else @intCast(i + 1);
        }
        n = wire_count;
    } else if (n > wire_count) {
        n = wire_count;
    }
    return packages.buildWeatherBody(&self.body_buf, wb[0..n]) catch null;
}

pub fn sendWeather(self: *Game, peer: *ln_peer.Peer) !void {
    const body = buildWeatherBodyFromBiomes(self) orelse return;
    // Body length is the loaded weather-biome count times the entry size.
    const bl = &self.world.biome_layers_table;
    const expect = (if (bl.weather_n > 0) @as(usize, bl.weather_n) else no_biomes_weather_count) * weather_entry_bytes;
    if (body.len != expect) {
        std.debug.print("zdtd: weather body len={d} expected={d}\n", .{ body.len, expect });
    }
    try self.sendGame(peer, "NetPackageWeather", body);
}

/// Stock: same throttle as WorldTime → NetPackageWeather from biomes.xml defaults.
pub fn broadcastWeather(self: *Game) !void {
    if (!anyEnteredClient(self)) return;
    const body = buildWeatherBodyFromBiomes(self) orelse return;
    try self.broadcast("NetPackageWeather", body);
}
