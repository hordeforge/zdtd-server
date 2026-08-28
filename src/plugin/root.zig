//! Plugin package: Wasm guest runtime (ADR 0020) plus in-tree static host as
//! test scaffolding only (`api` / `host` / `sample_hello`). Shipping plugins
//! are `.wasm` modules via `wasm.zig`. No native plugin ABI, no dynlib, no
//! stock IModApi.
//!
//! Dependency direction: leaf layer below server (server imports plugin, never
//! the reverse). Must not import server, ecs, wire, world, assets, litenet, or
//! apm. Wasm runtime may use util (io_fs) only.

pub const api = @import("api.zig");
pub const host = @import("host.zig");
pub const wasm = @import("wasm.zig");
pub const sample_hello = @import("sample_hello.zig");
pub const manifest = @import("manifest.zig");
pub const resolver = @import("resolver.zig");

pub const plugin_api_version = api.plugin_api_version;
pub const Host = api.Host;
pub const PluginVTable = api.PluginVTable;
pub const PluginHost = host.PluginHost;
pub const max_plugins = host.max_plugins;

test {
    _ = api;
    _ = host;
    _ = wasm;
    _ = sample_hello;
    _ = manifest;
    _ = resolver;
}
