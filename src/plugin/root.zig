//! Native static plugin host (ADR 0005 skeleton).
//! No dynlib, no Wasm, no stock IModApi.

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
