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

    const exe = b.addExecutable(.{
        .name = "zdtd",
        .root_module = root_mod,
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
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    wireApmOptions(fuzz_mod, build_opts, tracy_cpp);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
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
