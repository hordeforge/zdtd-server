//! zdtd-native metrics + profiling harness.
//! Not 7dtd-apm (stock Mono). This is first-class instrumentation inside the Zig process.
//!
//! Dependency direction: metrics on util/clock only (no clock re-export). Must not
//! import server, wire, ecs, world, assets, or litenet. Time: `util/clock`.

pub const metrics = @import("metrics.zig");
pub const profiler = @import("profiler.zig");
pub const report = @import("report.zig");
/// Optional Tracy zone markers; no-op and zero-sized unless `-Dtracy=true`.
pub const tracy = @import("tracy.zig");

pub const Counters = metrics.Counters;
pub const CounterId = metrics.CounterId;
pub const LatencyHist = metrics.LatencyHist;
pub const Profiler = profiler.Profiler;
pub const Section = profiler.Section;
pub const Snapshot = report.Snapshot;
pub const OpsGauges = report.OpsGauges;

/// Process-wide handle used by tick/net once the server loop exists.
pub const Harness = struct {
    counters: Counters = .{},
    prof: Profiler = .{},

    pub fn snapshot(self: *const Harness) Snapshot {
        var s: Snapshot = .{
            .counters = self.counters,
            .profiler = self.prof,
        };
        s.captureWall();
        return s;
    }
};

test {
    _ = metrics;
    _ = profiler;
    _ = report;
    _ = tracy;
}
