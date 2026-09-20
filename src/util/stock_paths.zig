//! Operator Steam install paths for offline stock-XML/prefab tests.
//!
//! Built from `$HOME` at compile time so committed sources never embed a
//! personal home directory. Tests that need the install skip when the path
//! is missing (`io_fs.dirExists` / `fileExists`).

const build_options = @import("build_options");

/// `$HOME` captured by build.zig (empty string when unset).
pub const home_dir: []const u8 = build_options.home_dir;

/// Stock dedicated-server install under the Steam library.
pub const dedicated_server: []const u8 =
    home_dir ++ "/.local/share/Steam/steamapps/common/7 Days to Die Dedicated Server";

/// Stock client install (separate Steam app; note capital "To").
pub const steam_client: []const u8 =
    home_dir ++ "/.local/share/Steam/steamapps/common/7 Days To Die";

/// Navezgane world under the dedicated install.
pub const navezgane: []const u8 = dedicated_server ++ "/Data/Worlds/Navezgane";

/// Prefab root under the dedicated install.
pub const prefabs: []const u8 = dedicated_server ++ "/Data/Prefabs";

/// Data/Config root under the dedicated install.
pub const config_dir: []const u8 = dedicated_server ++ "/Data/Config";

/// Local RE scratch tree (IL dumps and similar, not shipped).
pub const scratch_dir: []const u8 = home_dir ++ "/.cache/zdtd-scratch";

/// Comptime join of `dedicated_server` with a slash-prefixed relative path.
pub fn dedicated(comptime rel: []const u8) []const u8 {
    return dedicated_server ++ rel;
}

/// Comptime join of `config_dir` with a filename (`blocks.xml`, …).
pub fn configFile(comptime name: []const u8) []const u8 {
    return config_dir ++ "/" ++ name;
}

/// Comptime join of `scratch_dir` with a slash-prefixed relative path.
pub fn scratch(comptime rel: []const u8) []const u8 {
    return scratch_dir ++ rel;
}
