const std = @import("std");
const io_fs = @import("src/util/io_fs.zig");
pub fn main() !void {
    const dir = ".zdtd_cfg_cache/iofs_probe";
    io_fs.mkdirPathSimple(dir);
    var data: [12]u8 = undefined;
    @memcpy(data[0..4], "ZCL1");
    std.mem.writeInt(u64, data[4..12], 108500, .little);
    try io_fs.writeFile(std.heap.page_allocator, dir ++ "/clock.zcl", &data);
    std.debug.print("exists={}\n", .{io_fs.fileExistsSimple(dir ++ "/clock.zcl")});
    var buf: [16]u8 = undefined;
    const bytes = io_fs.readFileInto(std.heap.page_allocator, dir ++ "/clock.zcl", &buf) catch |e| {
        std.debug.print("read failed: {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("read ok len={d} wt={d}\n", .{ bytes.len, std.mem.readInt(u64, bytes[4..12], .little) });
}
