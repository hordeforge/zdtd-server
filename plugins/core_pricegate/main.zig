// Build wrapper (see mods/BUILDING.md): zig build-exe needs an entry point;
// zwasm only runs a start section when the module declares one (we never do),
// so _start is a plain export that is never invoked. The plugin root module
// is referenced at comptime so its exports land in the wasm.
comptime {
    _ = @import("plugin_root");
}
export fn _start() void {}
