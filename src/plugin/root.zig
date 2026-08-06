//! Static plugin host, in-tree test scaffolding (ADR 0020; no native ABI).
//! No dynlib, no Wasm, no stock IModApi.
//!
//! Dependency direction: leaf layer below server (server imports plugin, never
//! the reverse). Currently std-only; must not import server, ecs, wire, world,
//! assets, litenet, or apm.

pub const api = @import("api.zig");
pub const host = @import("host.zig");
pub const sample_hello = @import("sample_hello.zig");

pub const PLUGIN_API_VERSION = api.PLUGIN_API_VERSION;
pub const Host = api.Host;
pub const PluginVTable = api.PluginVTable;
pub const PluginHost = host.PluginHost;
pub const max_plugins = host.max_plugins;

test {
    _ = api;
    _ = host;
    _ = sample_hello;
}
