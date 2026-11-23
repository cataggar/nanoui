//! Interactive canvas + Layer 1 `web.js` + Layer 2 `web.rpc` demo app for Playwright E2E.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const schema = @import("rpc_schema.zig");

var demo_svc: schema.DemoService = .{};

export fn counter_value() i64 {
    return demo_svc.counter;
}

export fn demo_color() u32 {
    return demo_svc.color_hex;
}

fn view(s: *schema.DemoService, c: *ui.Context) void {
    const root = ui.div(c).sizeFull().column().center().gap(12).p(20);
    defer root.end();
    {
        const card = ui.div(c).w(340).h(140).rounded(16).bg(ui.Color.hex(s.color_hex)).column().center().gap(8);
        defer card.end();
        ui.textf(c, .{ .size = 24, .weight = .bold, .color = .white }, "RPC #{d}", .{s.counter});
        ui.textf(c, .{ .size = 14, .color = .white }, "clicks={d} http={d}", .{ s.clicks, s.fetch_status });
    }
    if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.counter += 1;
}

pub fn main(_: std.process.Init) !void {
    _ = nanoui.web.registerBundledFonts();
    try nanoui.web.rpc.bind(&demo_svc);
    _ = try nanoui.web.mount(.init(&demo_svc, view), .{});
    nanoui.web.run();
}
