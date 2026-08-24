// Build wrapper. zig build-exe needs an entry point; zwasm only runs a start
// section when the module declares one (we never do), so _start is a plain
// export that is never invoked. The plugin root module (wired by
// -Mplugin_root=... in the build command) is referenced at comptime so its
// exported functions land in the wasm.
comptime {
    _ = @import("plugin_root");
}
export fn _start() void {}
