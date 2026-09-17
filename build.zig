const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Strip release binaries by default so Debug stays inspectable and
    // Release{Safe,Fast,Small} do not ship full debug info unless asked.
    const strip = b.option(bool, "strip", "Strip debug info from the installed binary") orelse
        (optimize != .Debug);

    // Optional Tracy zones over the apm profiler sections. Tracy is not
    // vendored and is not a Zig package dependency: the operator supplies a
    // checkout path. See docs/APM.md.
    const tracy = b.option(
        bool,
        "tracy",
        "Emit Tracy zone markers from apm profiler sections (requires -Dtracy-src)",
    ) orelse false;
    const tracy_src = b.option(
        []const u8,
        "tracy-src",
        "Path to a Tracy checkout containing public/TracyClient.cpp (Tracy is not vendored)",
    );

    // The markers are only compiled in when a client is actually linked, so the
    // misconfigured case reports the one actionable message below instead of a
    // wall of undefined-symbol errors from the same mistake.
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "tracy_enabled", tracy and tracy_src != null);

    // Loud failure beats a silent shim: a no-op -Dtracy build would let an
    // operator believe they were profiling when they were not.
    const tracy_missing_src: ?*std.Build.Step.Fail = if (tracy and tracy_src == null)
        b.addFail(
            "-Dtracy=true requires -Dtracy-src=PATH (a Tracy checkout with " ++
                "public/TracyClient.cpp). Tracy is not vendored and is not a Zig " ++
                "package dependency; see docs/APM.md.",
        )
    else
        null;
    const tracy_cpp: ?std.Build.LazyPath = if (tracy and tracy_src != null)
        .{ .cwd_relative = b.pathJoin(&.{ tracy_src.?, "public", "TracyClient.cpp" }) }
    else
        null;

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    wireApmOptions(root_mod, build_opts, tracy_cpp);

    // Wasm plugin runtime (ADR 0020, zwasm v2). Anything linking it needs
    // .use_llvm = true: Zig 0.16's self-hosted x86 backend fails on
    // R_X86_64_PC64 (PLUGIN_API.md "Known constraint").
    const zwasm_dep = b.dependency("zwasm", .{
        .target = target,
        .optimize = optimize,
        .wasi = .none,
        .engine = .interp,
    });
    root_mod.addImport("zwasm", zwasm_dep.module("zwasm"));

    const exe = b.addExecutable(.{
        .name = "zdtd",
        .root_module = root_mod,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zdtd dedicated server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests keep symbols for better failure context regardless of -Dstrip.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    wireApmOptions(test_mod, build_opts, tracy_cpp);
    test_mod.addImport("zwasm", zwasm_dep.module("zwasm"));
    // Substring filter over test names, for tools that re-run one test many
    // times: tools/wire_order_mutants.py rebuilds the suite once per mutant,
    // and running all of it per mutant makes a full audit take a day.
    // `make check` never passes this, so the gate always runs everything.
    // Repeatable: no single substring covers every test touching one wire
    // file (stock_te.zig alone needs "te ", "trigger", "workstation" and
    // more), and a filter that misses the covering test makes the mutant look
    // like a test gap it is not.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose name contains this substring; repeatable (audit tooling; not used by make check)",
    ) orelse &.{};
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const cli_test_step = b.step("test-cli", "Check CLI output and exit codes without starting the server");
    test_step.dependOn(cli_test_step);
    const collision_cases = .{
        .{ "--admin-port", "--port" },
        .{ "--webui-port", "--port" },
        .{ "--webui-port", "--admin-port" },
        .{ "--mcp-port", "--port" },
        .{ "--mcp-port", "--admin-port" },
        .{ "--mcp-port", "--webui-port" },
    };
    inline for (collision_cases) |flags| {
        const collision = b.addRunArtifact(exe);
        collision.addArgs(&.{ flags[0], "27111", flags[1], "27111" });
        collision.setEnvironmentVariable("ZDTD_WEBUI_SECRET", "test-only-secret");
        collision.expectExitCode(2);
        collision.expectStdOutEqual("");
        collision.expectStdErrEqual("zdtd: options '" ++ flags[0] ++ "' and '" ++ flags[1] ++
            "' cannot use the same TCP port (27111)\nzdtd: try 'zdtd --help'\n");
        cli_test_step.dependOn(&collision.step);
    }
    const default_collision = b.addRunArtifact(exe);
    default_collision.addArgs(&.{ "--admin-port", "26902" });
    default_collision.expectExitCode(1);
    default_collision.expectStdOutEqual("");
    default_collision.expectStdErrEqual("zdtd: AdminPort/TelnetPort 26902 collides with ServerPort (TCP GameServerInfo)\n");
    cli_test_step.dependOn(&default_collision.step);

    // mods/plugin_common.zig is the shared guest helper (Buf, Config) that the
    // core plugins compile against for wasm32-freestanding. It is not part of
    // the server's import graph, so its tests would never run under the unit
    // suite. Build it as its own host-target test binary: the tests touch only
    // the pure helpers, never the `extern "zdtd"` imports, so it links fine.
    const guest_common_mod = b.createModule(.{
        .root_source_file = b.path("mods/plugin_common.zig"),
        .target = target,
        .optimize = optimize,
    });
    const guest_common_tests = b.addTest(.{ .root_module = guest_common_mod });
    test_step.dependOn(&b.addRunArtifact(guest_common_tests).step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    wireApmOptions(fuzz_mod, build_opts, tracy_cpp);
    // fuzz.zig imports server/persist.zig -> game.zig -> plugin/root.zig ->
    // wasm.zig, which needs the zwasm import (and use_llvm, per PLUGIN_API.md
    // "Known constraint": self-hosted x86 backend fails on R_X86_64_PC64).
    fuzz_mod.addImport("zwasm", zwasm_dep.module("zwasm"));
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .use_llvm = true,
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run wire-parser fuzz targets");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    // Every entry point stops on the one-line message, not a stack trace.
    if (tracy_missing_src) |fail| {
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        fuzz_step.dependOn(&fail.step);
        run_step.dependOn(&fail.step);
    }
}

/// Give a module the `build_options` import that `src/apm/tracy.zig` needs, and
/// compile the operator-supplied Tracy client into it when enabled.
///
/// TRACY_ON_DEMAND is deliberately NOT defined: it appends a field to
/// `___tracy_c_zone_context`, which src/apm/tracy.zig mirrors as an extern
/// struct returned by value. These flags are the ABI contract.
fn wireApmOptions(m: *std.Build.Module, opts: *std.Build.Step.Options, cpp: ?std.Build.LazyPath) void {
    m.addOptions("build_options", opts);
    const file = cpp orelse return;
    m.addCSourceFile(.{
        .file = file,
        .flags = &.{ "-DTRACY_ENABLE", "-fno-sanitize=undefined" },
        .language = .cpp,
    });
    m.link_libcpp = true;
}
