//! Build-time generator emitting `rpc_schema.dts` to stdout for `nanoui.web.installWithOptions`.
const std = @import("std");
const schema = @import("rpc_schema");

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try w.interface.writeAll(schema.dts);
    try w.interface.flush();
}
