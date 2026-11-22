//! Headless zero-dependency embedded UI example (`zig build run-embedded`).
//! Steps an embedded DSP channel-strip panel across deterministic frames and
//! renders `FrameOutput` through `embed.pass.Cpu` without `App` or `Window`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const embed = nanoui.embed;

const meter_stops = [_]ui.GradientStop{
    .{ .at = 0.0, .color = .hex(0xff453a) },
    .{ .at = 0.35, .color = .hex(0xffd60a) },
    .{ .at = 1.0, .color = .hex(0x30d158) },
};

const ChannelPanel = struct {
    gain_buf: ui.TextBuffer = .{},
    bypassed: bool = false,
    muted: bool = false,
    bypass_rect: ui.Rect = .{},

    fn view(p: *ChannelPanel, c: *ui.Context) void {
        if (c.shortcut(.{ .key = 'm', .cmd = true })) p.muted = !p.muted;

        const root = ui.div(c).column().sizeFull().p(20).gap(14).bg(c.theme.background);
        defer root.end();

        const top = ui.div(c).row().wFull().itemsCenter().gap(10);
        defer top.end();
        ui.icon(c, "waveform", .{ .size = 18, .color = c.theme.accent });
        const title_idx = c.leaf(.{}, .{ .text = .{
            .str = "Embedded Channel Strip",
            .style = .{ .size = 18, .weight = .bold },
            .color = c.theme.text,
        } }, "heading");
        ui.access.describe(c, title_idx, .{
            .role = .static_text,
            .label = "Embedded Channel Strip",
            .header = true,
        });
        ui.spacer(c);
        ui.badge(c, if (p.muted) "MUTED" else "LIVE", if (p.muted) .hex(0xff453a) else .hex(0x30d158));
        _ = kit.button(c, "Preset A", .{ .variant = .secondary, .size = .sm });

        var body = ui.div(c).row().wFull().grow().gap(14).p(14).rounded(12).bg(c.theme.surface).border(c.theme.border).opacity(0.94);
        c.node(body.index).style.group = true;
        defer body.end();

        // Multi-stop vertical level meter on the left.
        const meter_wrap = ui.div(c).column().w(26).hFull().p(4).rounded(8).bg(c.theme.background).justifyEnd();
        defer meter_wrap.end();
        _ = c.leaf(.{
            .width = .fill,
            .height = .{ .px = if (p.bypassed) 48 else 168 },
            .radius = 4,
            .background = .hex(0x30d158),
            .gradient_stops = &meter_stops,
        }, .none, "meter-fill");

        const controls = ui.div(c).column().grow().gap(12);
        defer controls.end();
        ui.label(c, "Output trim & IME command entry");

        _ = ui.textField(c, &p.gain_buf, .{
            .placeholder = "Enter trim (e.g. gain +3dB)",
            .width = .{ .px = 280 },
        });

        const actions = ui.div(c).row().itemsCenter().gap(10);
        defer actions.end();
        const bypass_btn = ui.button(c, if (p.bypassed) "Bypassed" else "Active", .{
            .variant = if (p.bypassed) .secondary else .primary,
            .icon = "bolt",
        });
        if (bypass_btn.rect) |r| p.bypass_rect = r;
        if (bypass_btn.clicked) p.bypassed = !p.bypassed;

        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "Buffer: \"{s}\"", .{p.gain_buf.text()});
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_png: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--out=")) {
            out_png = arg["--out=".len..];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_png = args[i];
        }
    }

    const font_bytes = try ui.test_font.build(arena, .{ .family = "Embedded Sans" });
    var th = ui.Theme.dark_theme;
    th.font = "Embedded Sans";

    var host = try embed.Host.init(gpa, .{
        .size = .{ .w = 640, .h = 400 },
        .scale = 2.0,
        .theme = th,
        .scan_system_fonts = false,
    });
    defer host.deinit();
    try host.registerFont(font_bytes);

    var panel: ChannelPanel = .{};
    defer panel.gain_buf.deinit();
    const view = ui.View.init(&panel, ChannelPanel.view);

    // Frame 1: initial layout & render packet inspection (second build populates hit rects).
    const out1 = host.frame(view, 1.0 / 60.0, 0.0);
    const f1_instances = out1.instances.len;
    const f1_a11y = out1.a11y.len;
    _ = host.frame(view, 1.0 / 60.0, 0.5 / 60.0);

    // Frame 2: click bypass button, then focus text field and compose marked IME text.
    const click_pt: ui.Point = .{
        .x = panel.bypass_rect.x + panel.bypass_rect.w * 0.5,
        .y = panel.bypass_rect.y + panel.bypass_rect.h * 0.5,
    };
    host.pointerMove(click_pt);
    host.pointerDown(click_pt, .left, 1);
    _ = host.frame(view, 1.0 / 60.0, 1.0 / 60.0);
    host.pointerUp(click_pt, .left);
    _ = host.frame(view, 1.0 / 60.0, 1.5 / 60.0);

    panel.gain_buf.focus();
    try host.textInput("gain +3dB");
    try host.imeSetMarked("...", 0, 3);
    const out2 = host.frame(view, 1.0 / 60.0, 2.0 / 60.0);
    const ime_w: f32 = if (out2.ime) |ime| ime.rect.w else 0;
    const marked_len: usize = if (out2.ime) |ime| (if (ime.marked) |m| m[1] - m[0] else 0) else 0;

    // Frame 3: clear marked composition, select all + copy to host clipboard outbox, toggle mute shortcut.
    try host.imeCommit("");
    try host.pushTextOp(.{ .command = .select_all });
    try host.pushTextOp(.{ .command = .copy });
    host.shortcut(.{ .key = 'm', .cmd = true });
    const out3 = host.frame(view, 1.0 / 60.0, 3.0 / 60.0);
    const copied = if (out3.clipboard_write) |clip| try arena.dupe(u8, clip) else "";

    // Rasterize final FrameOutput into a caller-owned premultiplied BGRA8 buffer.
    const pw: usize = @intCast(out3.pixel_size[0]);
    const ph: usize = @intCast(out3.pixel_size[1]);
    const px_bytes = try gpa.alloc(u8, pw * ph * 4);
    defer gpa.free(px_bytes);
    const pixels: embed.pass.Cpu.Pixels = .{ .bytes = px_bytes, .width = pw, .height = ph };
    embed.pass.Cpu.draw(out3, pixels);
    defer embed.pass.Cpu.freeLayers();

    if (out_png) |path| {
        try ui.png.writePng(gpa, init.io, path, pixels);
    }

    var stdout_buf: [512]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    try stdout_w.interface.print(
        "embedded: f1(instances={d}, a11y={d}) f2(ime_w={d:.0}, marked={d}, bypassed={}) f3(clipboard=\"{s}\", muted={}, target={d}x{d})\n",
        .{ f1_instances, f1_a11y, ime_w, marked_len, panel.bypassed, copied, panel.muted, pw, ph },
    );
    if (out_png) |path| {
        try stdout_w.interface.print("embedded: wrote {s}\n", .{path});
    }
    try stdout_w.interface.flush();
}
