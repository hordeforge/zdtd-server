//! Weather S2C helpers — extracted verbatim from game.zig.
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

/// Build NetPackageWeather from the live weather state machine (omit if none).
pub fn buildWeatherBodyFromBiomes(self: *Game) ?[]const u8 {
    const bl = &self.world.biome_layers_table;
    const wm = &self.world.weather;
    // Stock client InitPackages sizes from biomeWeather.Count (Navezgane / stock
    // biomes with weather groups → 5). Wire has no count prefix, so body length
    // must be exactly Count * 23 (3 u8 + 5 f32).
    const stock_count: usize = 5;
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
    // Pad or trim to stock_count so content_len matches client expected size.
    if (n == 0) {
        // No biomes.xml: mild pine-ish defaults on the raw 0..100 XML scale,
        // group 0 so an unmodded client still resolves a real group.
        var i: usize = 0;
        while (i < stock_count) : (i += 1) {
            wb[i] = .{
                .biome_id = @intCast(i + 1),
                .group_index = 0,
                .group_count = 1,
                .remaining_seconds = 0,
                .params = .{ 70, 0, 20, 10, 5 },
            };
        }
        n = stock_count;
    } else if (n < stock_count) {
        var i = n;
        while (i < stock_count) : (i += 1) {
            wb[i] = wb[n - 1];
            wb[i].biome_id = @intCast(i + 1);
        }
        n = stock_count;
    } else if (n > stock_count) {
        n = stock_count;
    }
    return packages.buildWeatherBody(&self.body_buf, wb[0..n]) catch null;
}

pub fn sendWeather(self: *Game, peer: *ln_peer.Peer) !void {
    const body = buildWeatherBodyFromBiomes(self) orelse return;
    // Stock client sizes read from biomeWeather.Count (usually 5 → 115 body / 117 content).
    if (body.len != 115 and body.len != 0) {
        std.debug.print("zdtd: weather body len={d} (stock often 115 for 5 biomes)\n", .{body.len});
    }
    try self.sendGame(peer, "NetPackageWeather", body);
}

/// Stock: same throttle as WorldTime → NetPackageWeather from biomes.xml defaults.
pub fn broadcastWeather(self: *Game) !void {
    if (!anyEnteredClient(self)) return;
    const body = buildWeatherBodyFromBiomes(self) orelse return;
    try self.broadcast("NetPackageWeather", body);
}
