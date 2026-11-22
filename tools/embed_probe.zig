//! Freestanding and WASI reactor probe for zero-dependency embeddable UI (`test-embed`).
//! Exports `nanoui_embed_probe` with zero host imports on `wasm32-freestanding`.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const embed = nanoui.embed;

var cached_font: ?[]const u8 = null;

const ProbeState = struct {
    input: ui.TextBuffer = .{},
    clicks: u32 = 0,

    fn view(s: *ProbeState, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(12).gap(8).bg(c.theme.background);
        defer root.end();

        const header = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer header.end();
        ui.icon(c, "sparkles", .{ .size = 14, .color = c.theme.accent });
        ui.text(c, "Embedded Probe", .{ .size = 15, .weight = .semibold });
        ui.spacer(c);
        if (kit.button(c, "Apply", .{ .variant = .primary, .size = .sm }).clicked) s.clicks += 1;

        var grp = ui.div(c).row().wFull().p(8).gap(8).rounded(8).bg(c.theme.surface).opacity(0.88).itemsCenter();
        c.node(grp.index).style.group = true;
        defer grp.end();

        _ = ui.textField(c, &s.input, .{
            .placeholder = "Gain",
            .width = .{ .px = 140 },
            .bare = true,
        });
        if (ui.button(c, "Bypass", .{ .variant = .secondary, .size = 12 }).clicked) s.clicks += 1;
    }
};

export fn nanoui_embed_probe(width: u32, height: u32) u32 {
    const gpa = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;
    const w = @max(width, 64);
    const h = @max(height, 64);

    const font_bytes = cached_font orelse blk: {
        const built = ui.test_font.build(gpa, .{ .family = "Probe Sans" }) catch return 0;
        cached_font = built;
        break :blk built;
    };

    var th = ui.Theme.dark_theme;
    th.font = "Probe Sans";

    var host = embed.Host.init(gpa, .{
        .size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) },
        .scale = 1.0,
        .theme = th,
        .scan_system_fonts = false,
    }) catch return 0;
    defer host.deinit();

    host.registerFont(font_bytes) catch return 0;

    var state: ProbeState = .{};
    defer state.input.deinit();

    const f1 = host.frame(ui.View.init(&state, ProbeState.view), 1.0 / 60.0, 0.0);
    std.mem.doNotOptimizeAway(f1.instances.len);

    state.input.focus();
    host.pointerMove(.{ .x = 24, .y = 24 });
    host.pointerDown(.{ .x = 24, .y = 24 }, .left, 1);
    host.pointerUp(.{ .x = 24, .y = 24 }, .left);
    host.textInput("ok") catch return 0;
    host.imeCommit("!") catch return 0;

    const out = host.frame(ui.View.init(&state, ProbeState.view), 1.0 / 60.0, 1.0 / 60.0);
    const pw: usize = @intCast(out.pixel_size[0]);
    const ph: usize = @intCast(out.pixel_size[1]);
    const px_bytes = gpa.alloc(u8, pw * ph * 4) catch return 0;
    defer gpa.free(px_bytes);

    embed.pass.Cpu.draw(out, .{ .bytes = px_bytes, .width = pw, .height = ph });
    embed.pass.Cpu.freeLayers();
    std.mem.doNotOptimizeAway(px_bytes.ptr);
    return @intCast(out.instances.len);
}
