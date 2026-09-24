//! Test-only tmp-root helper: one static path buffer shared by the serial
//! test run, so each tmpDir site is one line instead of a buffer declaration
//! plus the realPath dance. The returned slice is valid until the next call,
//! which is why a test that needs two roots keeps its own buffer (the audit
//! excluded those sites). Only test files import this, so the server binary
//! never links it.

const std = @import("std");

var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

/// Absolute path of `t`'s root, written into the shared buffer.
pub fn rootOf(t: *std.testing.TmpDir) ![]const u8 {
    const n = try t.dir.realPath(std.testing.io, &path_buf);
    return path_buf[0..n];
}
