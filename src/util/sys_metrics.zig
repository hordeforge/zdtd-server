//! Host OS metrics for the ops dashboard (Linux dedi host): system load, RAM
//! pressure, and process CPU/RSS. Two plain syscalls (sysinfo + getrusage),
//! no /proc file reads, so sampling from the run loop's periodic snapshot
//! path stays on the syscall batch, not the FS path.
//!
//! Non-goals: per-cgroup/container stats, disk I/O, per-nic counters (apm
//! owns the server's own net counters). Target is the Linux dedi; there is no
//! cross-platform backend.

const std = @import("std");

pub const Metrics = struct {
    /// 1 / 5 / 15 minute load averages (fractional).
    load_1: f32 = 0,
    load_5: f32 = 0,
    load_15: f32 = 0,
    /// Total usable RAM in MiB.
    mem_total_mb: u32 = 0,
    /// Free + buffer RAM in MiB (sysinfo has no MemAvailable; close enough
    /// for a pressure gauge).
    mem_avail_mb: u32 = 0,
    /// Process CPU (utime + stime) as a percentage of host uptime.
    proc_cpu_pct: f32 = 0,
    /// Process peak RSS in MiB (getrusage maxrss is KiB on Linux).
    proc_rss_mb: u32 = 0,
    /// Live process count.
    procs: u32 = 0,
    /// Host uptime in whole seconds.
    uptime_s: u64 = 0,
};

/// sysinfo load averages are fixed-point with a 16-bit fraction.
const load_scale: f32 = 65536.0;
const mib_bytes: u64 = 1024 * 1024;

fn miB(bytes: u64) u32 {
    return @intCast(@min(bytes / mib_bytes, std.math.maxInt(u32)));
}

/// CPU time in microseconds (getrusage timeval has no sub-second precision
/// guarantee, so keep both fields and add them up).
fn cpuMicros(tv: std.posix.timeval) f64 {
    return @as(f64, @floatFromInt(tv.sec)) * 1.0e6 + @as(f64, @floatFromInt(tv.usec));
}

pub fn sample() Metrics {
    var m: Metrics = .{};
    var info: std.os.linux.Sysinfo = undefined;
    const rc = std.os.linux.sysinfo(&info);
    if (@as(isize, @bitCast(rc)) < 0) return m;
    m.uptime_s = @intCast(@max(info.uptime, 0));
    m.load_1 = @as(f32, @floatFromInt(info.loads[0])) / load_scale;
    m.load_5 = @as(f32, @floatFromInt(info.loads[1])) / load_scale;
    m.load_15 = @as(f32, @floatFromInt(info.loads[2])) / load_scale;
    m.mem_total_mb = miB(info.totalram);
    m.mem_avail_mb = miB(info.freeram +% info.bufferram);
    m.procs = @intCast(info.procs);
    // posix.system: no Io getrusage; the medium posix wrapper is the 0.16
    // layer the changelog removed. Fail closed like sysinfo (leave CPU/RSS 0).
    var ru: std.posix.rusage = undefined;
    const ru_rc = std.posix.system.getrusage(std.posix.rusage.SELF, &ru);
    if (std.posix.errno(ru_rc) == .SUCCESS) {
        m.proc_rss_mb = @intCast(@max(ru.maxrss, 0) / 1024);
        if (m.uptime_s > 0) {
            const cpu_us = cpuMicros(ru.utime) + cpuMicros(ru.stime);
            m.proc_cpu_pct = @floatCast((cpu_us / 1.0e6) / @as(f64, @floatFromInt(m.uptime_s)) * 100.0);
        }
    }
    return m;
}

test "sys metrics sample reports a live host" {
    const m = sample();
    // Any booted Linux host reports usable RAM and non-negative derived
    // values; a CI container is still a host from sysinfo's point of view.
    try std.testing.expect(m.mem_total_mb > 0);
    try std.testing.expect(m.load_1 >= 0);
    try std.testing.expect(m.proc_cpu_pct >= 0);
}
