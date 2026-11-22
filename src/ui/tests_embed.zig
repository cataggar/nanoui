//! Unit and integration tests for `ui.embed` (`Host`, `contract`, and `pass.Cpu`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const embed = ui.embed;
const contract = embed.contract;

const dejavu_ttf = @embedFile("web_fonts/DejaVuSans.ttf");
const inline_svg = "<svg viewBox='0 0 16 16'><rect x='2' y='2' width='12' height='12' rx='3' fill='#30d158'/></svg>";

const PassScene = struct {
    fn view(_: *PassScene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(12).gap(8).bg(.hex(0x14161a));
        defer root.end();

        ui.div(c).w(80).h(24).rounded(4).bg(.hex(0x30d158)).end();

        // Liquid Glass barrier pane over the backdrop.
        _ = c.leaf(.{
            .width = .{ .px = 120 },
            .height = .{ .px = 36 },
            .radius = 8,
            .glass = .{ .style = .regular, .blur = 8 },
        }, .none, "glass-pane");

        // Unmasked opacity group barrier (`layer_begin` .. `layer_end`).
        var grp = ui.div(c).row().w(140).h(40).p(6).rounded(6).bg(.hex(0x2a6df4)).opacity(0.65);
        c.node(grp.index).style.group = true;
        defer grp.end();
        ui.icon(c, "sparkles", .{ .size = 14, .color = .white });
    }
};

test "embed contract ABI stride, effectiveClear, and iterPasses barriers" {
    try testing.expectEqual(@as(usize, 192), contract.instance_stride);
    try testing.expectEqual(@as(usize, 12), contract.instance_vec4_count);
    try testing.expectEqual(@as(usize, 4), contract.vertices_per_instance);
    try testing.expectEqual(contract.instance_stride, @sizeOf(gpu.Instance));

    var host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 240, .h = 160 },
        .scale = 1.0,
        .theme = .dark_theme,
        .scan_system_fonts = false,
    });
    defer host.deinit();

    var scene: PassScene = .{};
    const out = host.frame(ui.View.init(&scene, PassScene.view), 1.0 / 60.0, 0.0);
    try testing.expect(out.instances.len >= 4);

    // Opaque root quad is promoted into `effectiveClear`.
    const ec = contract.effectiveClear(out.instances, out.size, out.clear_color);
    try testing.expect(ec.first >= 1);
    try testing.expectApproxEqAbs(@as(f32, 1.0), ec.clear.a, 0.001);

    var saw_draw = false;
    var saw_glass = false;
    var saw_layer = false;
    var it = contract.iterPasses(out.instances, out.size);
    while (it.next()) |run| switch (run) {
        .draw => |r| {
            try testing.expect(r.end > r.start);
            saw_draw = true;
        },
        .glass => |idx| {
            try testing.expectEqual(gpu.Kind.glass, out.instances[idx].kind);
            saw_glass = true;
        },
        .layer => |grp| {
            try testing.expect(!grp.masked);
            try testing.expect(grp.end > grp.begin + 1);
            var inner = contract.iterSpan(out.instances, grp.begin + 1, grp.end);
            var inner_draws: usize = 0;
            while (inner.next()) |sub| if (sub == .draw) {
                inner_draws += 1;
            };
            try testing.expect(inner_draws >= 1);
            saw_layer = true;
        },
    };
    try testing.expect(saw_draw and saw_glass and saw_layer);

    // Transparent root preserves alpha=0 clear when no opaque cover quad exists.
    var trans_host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 120, .h = 80 },
        .scale = 1.0,
        .transparent_root = true,
        .scan_system_fonts = false,
    });
    defer trans_host.deinit();
    const Empty = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            ui.div(c).w(20).h(20).bg(.hex(0xff0000)).end();
        }
    };
    var empty: Empty = .{};
    const trans_out = trans_host.frame(ui.View.init(&empty, Empty.view), 1.0 / 60.0, 0.0);
    const trans_ec = contract.effectiveClear(trans_out.instances, trans_out.size, trans_out.clear_color);
    try testing.expectEqual(@as(usize, 0), trans_ec.first);
    try testing.expectEqual(@as(f32, 0.0), trans_ec.clear.a);
}

const AtlasScene = struct {
    label: []const u8 = "Hello",
    show_media: bool = false,
    swatch: [4 * 4 * 4]u8 = @splat(0xcc),

    fn view(s: *AtlasScene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10).gap(6);
        defer root.end();
        ui.text(c, s.label, .{ .size = 18, .family = "DejaVu Sans" });
        if (s.show_media) {
            _ = ui.svg(c, .{ .key = "embed-svg", .bytes = inline_svg, .size = 16 });
            _ = ui.image(c, .{
                .key = "embed-px",
                .source = .{ .pixels = .{ .bgra = &s.swatch, .width = 4, .height = 4 } },
                .box = .{ .w = 8, .h = 8 },
            });
        }
    }
};

test "hermetic host tracks incremental glyph and image atlas DirtyRects" {
    var th = ui.Theme.dark_theme;
    th.font = "DejaVu Sans";

    var host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 320, .h = 160 },
        .scale = 2.0,
        .theme = th,
        .scan_system_fonts = false,
    });
    defer host.deinit();
    try host.registerFont(dejavu_ttf);

    var scene: AtlasScene = .{};
    const view = ui.View.init(&scene, AtlasScene.view);

    // Frame 1: "Hello" populates glyph atlas with a non-empty dirty rect.
    const out1 = host.frame(view, 1.0 / 60.0, 0.0);
    try testing.expect(out1.glyph_atlas.generation > 0);
    const d1 = out1.glyph_atlas.dirty orelse return error.ExpectedGlyphDirtyRect;
    try testing.expect(!d1.isEmpty());
    try testing.expect(d1.x + d1.width <= out1.glyph_atlas.width);
    try testing.expect(d1.y + d1.height <= out1.glyph_atlas.height);
    const gen1 = out1.glyph_atlas.generation;
    const resets1 = out1.glyph_atlas.resets;

    // Frame 2: identical "Hello" uploads nothing and keeps generation unchanged.
    const out2 = host.frame(view, 1.0 / 60.0, 1.0 / 60.0);
    try testing.expect(out2.glyph_atlas.dirty == null);
    try testing.expectEqual(gen1, out2.glyph_atlas.generation);
    try testing.expectEqual(resets1, out2.glyph_atlas.resets);

    // Frame 3: new glyphs (" World!") + SVG & pixel image dirty both atlases.
    scene.label = "Hello World!";
    scene.show_media = true;
    const out3 = host.frame(view, 1.0 / 60.0, 2.0 / 60.0);
    try testing.expect(out3.glyph_atlas.generation > gen1);
    const d3 = out3.glyph_atlas.dirty orelse return error.ExpectedIncrementalGlyphDirtyRect;
    try testing.expect(!d3.isEmpty());
    try testing.expect(d3.x + d3.width <= out3.glyph_atlas.width);
    try testing.expect(d3.y + d3.height <= out3.glyph_atlas.height);

    try testing.expect(out3.image_atlas.generation > 0);
    const im_dirty = out3.image_atlas.dirty orelse return error.ExpectedImageDirtyRect;
    try testing.expect(!im_dirty.isEmpty());
    try testing.expect(im_dirty.x + im_dirty.width <= out3.image_atlas.width);
    try testing.expect(im_dirty.y + im_dirty.height <= out3.image_atlas.height);
}

const InteractiveScene = struct {
    clicks: u32 = 0,
    notes: ui.TextBuffer = .{},
    btn_rect: ui.Rect = .{},
    field_rect: ui.Rect = .{},

    fn view(s: *InteractiveScene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(16).gap(12);
        defer root.end();

        const hdr = c.leaf(.{}, .{ .text = .{
            .str = "Plugin Controls",
            .style = .{ .size = 16, .weight = .bold },
            .color = c.theme.text,
        } }, "hdr");
        ui.access.describe(c, hdr, .{ .role = .static_text, .label = "Plugin Controls", .header = true });

        var btn = ui.div(c).row().w(120).h(32).px(12).itemsCenter().justifyCenter().rounded(6).bg(c.theme.accent).control();
        const it = btn.interaction();
        c.help(btn.index, "Increment counter");
        _ = btn.tooltip("Increment counter", .{ .delay = 0 });
        c.addA11y(btn.index, .button, "Increment", "", false, true);
        if (it.rect) |r| s.btn_rect = r;
        if (it.clicked) {
            s.clicks += 1;
            c.changed = true;
        }
        ui.textf(c, .{ .size = 13, .color = .white }, "Count: {d}", .{s.clicks});
        btn.end();

        const field_wrap = ui.div(c).row();
        defer field_wrap.end();
        _ = ui.textField(c, &s.notes, .{ .placeholder = "Notes", .width = .{ .px = 180 }, .bare = true });
        s.field_rect = c.node(field_wrap.index).rect;
    }
};

test "pointer cursor shapes, tooltip, single-frame click rebuild, and accessibility items" {
    var host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 320, .h = 220 },
        .scale = 1.0,
        .theme = .dark_theme,
        .scan_system_fonts = false,
    });
    defer host.deinit();
    try host.registerFont(dejavu_ttf);

    var scene: InteractiveScene = .{};
    defer scene.notes.deinit();
    const view = ui.View.init(&scene, InteractiveScene.view);

    // Warm layout rects across initial frames.
    _ = host.frame(view, 1.0 / 60.0, 0.0);
    host.pointerMove(.{ .x = 300, .y = 200 });
    const out_idle = host.frame(view, 1.0 / 60.0, 0.02);
    try testing.expectEqual(ui.Cursor.arrow, out_idle.cursor.shape);
    try testing.expect(out_idle.cursor.tooltip == null);

    // Hover button -> hand cursor + tooltip.
    const btn_pt: ui.Point = .{
        .x = scene.btn_rect.x + scene.btn_rect.w * 0.5,
        .y = scene.btn_rect.y + scene.btn_rect.h * 0.5,
    };
    host.pointerMove(btn_pt);
    const out_btn = host.frame(view, 1.0 / 60.0, 0.04);
    try testing.expectEqual(ui.Cursor.hand, out_btn.cursor.shape);
    try testing.expectEqualStrings("Increment counter", out_btn.cursor.tooltip orelse return error.MissingTooltip);

    // Click button -> increments state and rebuilds in the same frame.
    host.pointerDown(btn_pt, .left, 1);
    host.pointerUp(btn_pt, .left);
    const out_click = host.frame(view, 1.0 / 60.0, 0.06);
    try testing.expectEqual(@as(u32, 1), scene.clicks);
    try testing.expect(out_click.stats.passes >= 2);

    // Hover text field -> I-beam text cursor.
    const field_pt: ui.Point = .{ .x = 28, .y = scene.btn_rect.y + scene.btn_rect.h + 18 };
    host.pointerMove(field_pt);
    const out_field = host.frame(view, 1.0 / 60.0, 0.08);
    try testing.expectEqual(ui.Cursor.text, out_field.cursor.shape);

    // Verify a11y items expose header, button, and text_field.
    var has_header = false;
    var has_button = false;
    var has_field = false;
    for (out_field.a11y) |item| {
        if (item.header and std.mem.eql(u8, item.label, "Plugin Controls")) has_header = true;
        if (item.role == .button and std.mem.eql(u8, item.label, "Increment")) has_button = true;
        if (item.role == .text_field and std.mem.eql(u8, item.label, "Notes")) has_field = true;
    }
    try testing.expect(has_header and has_button and has_field);
}

test "IME composition geometry and one-shot clipboard outbox" {
    var host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 320, .h = 140 },
        .scale = 1.0,
        .theme = .dark_theme,
        .scan_system_fonts = false,
    });
    defer host.deinit();
    try host.registerFont(dejavu_ttf);

    const ImeView = struct {
        buf: ui.TextBuffer = .{},
        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(16);
            defer root.end();
            _ = ui.textField(c, &s.buf, .{ .placeholder = "IME", .width = .{ .px = 220 }, .bare = true });
        }
    };
    var state: ImeView = .{};
    defer state.buf.deinit();
    const view = ui.View.init(&state, ImeView.view);

    _ = host.frame(view, 1.0 / 60.0, 0.0);
    state.buf.focus();
    const out_focus = host.frame(view, 1.0 / 60.0, 0.02);
    const ime0 = out_focus.ime orelse return error.ExpectedFocusedIme;
    try testing.expect(ime0.rect.w > 0);
    try testing.expect(ime0.caret_rect.h > 0);
    try testing.expect(ime0.marked == null);

    try host.imeSetMarked("かん", 0, 6);
    const out_marked = host.frame(view, 1.0 / 60.0, 0.04);
    const ime1 = out_marked.ime orelse return error.ExpectedMarkedIme;
    try testing.expectEqual([2]usize{ 0, 6 }, ime1.marked orelse return error.ExpectedMarkedRange);
    try testing.expect(ime1.clause_rect != null);

    try host.imeCommit("漢字");
    const out_commit = host.frame(view, 1.0 / 60.0, 0.06);
    try testing.expectEqualStrings("漢字", state.buf.text());
    try testing.expect((out_commit.ime orelse return error.ExpectedImeAfterCommit).marked == null);

    try host.pushTextOp(.{ .command = .select_all });
    try host.pushTextOp(.{ .command = .copy });
    const out_copy = host.frame(view, 1.0 / 60.0, 0.08);
    try testing.expectEqualStrings("漢字", out_copy.clipboard_write orelse return error.ExpectedClipboardWrite);

    // One-shot side effect resets to null on the next frame.
    const out_next = host.frame(view, 1.0 / 60.0, 0.10);
    try testing.expect(out_next.clipboard_write == null);
}

test "wake and idle timer contract for springs, blinking caret, static idle, and waker" {
    var host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 240, .h = 120 },
        .scale = 1.0,
        .theme = .dark_theme,
        .scan_system_fonts = false,
    });
    defer host.deinit();

    const WakeScene = struct {
        mode: enum { static, spring, caret } = .static,
        target: f32 = 0,
        buf: ui.TextBuffer = .{},

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(12);
            defer root.end();
            switch (s.mode) {
                .static => {
                    ui.div(c).w(40).h(20).bg(.hex(0x3a3a3c)).end();
                },
                .spring => {
                    const x = ui.motion.number(c, "slide", s.target, .{ .spring = ui.motion.Spring.snappy });
                    ui.div(c).w(40 + x).h(20).bg(.hex(0x0a84ff)).end();
                },
                .caret => {
                    c.focus = c.peekId(null);
                    _ = ui.textField(c, &s.buf, .{ .bare = true, .width = .{ .px = 160 } });
                },
            }
        }
    };
    var scene: WakeScene = .{};
    defer scene.buf.deinit();
    const view = ui.View.init(&scene, WakeScene.view);

    // 1. Unfocused static scene sleeps indefinitely.
    const out_static = host.frame(view, 1.0 / 60.0, 0.0);
    try testing.expect(!out_static.wants_frame);
    try testing.expect(out_static.next_frame_in == null);

    // 2. Thread-safe Waker requests an immediate frame.
    const waker = host.waker();
    waker.wake(waker.ctx);
    const out_woken = host.frame(view, 1.0 / 60.0, 0.02);
    try testing.expect(out_woken.wants_frame);

    // 3. Active spring requests an immediate vblank frame (`next_frame_in == 0`).
    scene.mode = .spring;
    _ = host.frame(view, 1.0 / 60.0, 0.04);
    scene.target = 80;
    const out_spring = host.frame(view, 1.0 / 60.0, 0.06);
    try testing.expect(out_spring.wants_frame);
    try testing.expectEqual(@as(?f32, 0), out_spring.next_frame_in);

    // 4. Focused steady/blinking caret while otherwise idle arms ~0.5s timer without polling.
    scene.mode = .caret;
    const out_caret = host.frame(view, 1.0 / 60.0, 1.0);
    try testing.expect(!out_caret.wants_frame);
    const delay = out_caret.next_frame_in orelse return error.ExpectedCaretTimer;
    try testing.expectApproxEqAbs(@as(f32, 0.5), delay, 0.05);
}

test "bundled Cpu pass encoder renders quads and glyphs and matches partial drawRegion" {
    try testing.expect(embed.pass.Cpu.available);

    var th = ui.Theme.dark_theme;
    th.font = "DejaVu Sans";
    th.background = .hex(0x101216);

    var host = try embed.Host.init(testing.allocator, .{
        .size = .{ .w = 160, .h = 96 },
        .scale = 1.0,
        .theme = th,
        .scan_system_fonts = false,
    });
    defer host.deinit();
    try host.registerFont(dejavu_ttf);

    const RenderScene = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(12).gap(8).bg(c.theme.background);
            defer root.end();
            ui.div(c).w(80).h(28).bg(.hex(0x00c853)).end();
            ui.text(c, "HI", .{ .size = 22, .color = .white, .family = "DejaVu Sans" });
        }
    };
    var scene: RenderScene = .{};
    const out = host.frame(ui.View.init(&scene, RenderScene.view), 1.0 / 60.0, 0.0);

    const pw: usize = @intCast(out.pixel_size[0]);
    const ph: usize = @intCast(out.pixel_size[1]);
    const full_buf = try testing.allocator.alloc(u8, pw * ph * 4);
    defer testing.allocator.free(full_buf);
    const full: gpu.Pixels = .{ .bytes = full_buf, .width = pw, .height = ph };
    embed.pass.Cpu.draw(out, full);
    defer embed.pass.Cpu.freeLayers();

    // Inside green box `(24, 24)` -> BGRA of `0x00c853` (`B=0x53, G=0xc8, R=0x00, A=0xff`).
    const green_off = (24 * pw + 24) * 4;
    try testing.expectEqualSlices(u8, &.{ 0x53, 0xc8, 0x00, 0xff }, full.bytes[green_off .. green_off + 4]);

    // Verify rendered glyph region below the green box has lit non-background ink pixels.
    var lit_glyph_px: usize = 0;
    for (44..84) |y| {
        for (10..90) |x| {
            const off = (y * pw + x) * 4;
            if (full.bytes[off + 2] > 0x40) lit_glyph_px += 1;
        }
    }
    try testing.expect(lit_glyph_px > 10);

    // Partial `drawRegion` produces identical pixels within the damaged region.
    const reg_buf = try testing.allocator.alloc(u8, pw * ph * 4);
    defer testing.allocator.free(reg_buf);
    @memset(reg_buf, 0);
    const partial: gpu.Pixels = .{ .bytes = reg_buf, .width = pw, .height = ph };
    const region = [4]usize{ 12, 12, 96, 84 };
    embed.pass.Cpu.drawRegion(out, partial, region);

    for (region[1]..region[3]) |y| {
        const row_start = (y * pw + region[0]) * 4;
        const row_end = (y * pw + region[2]) * 4;
        try testing.expectEqualSlices(u8, full.bytes[row_start..row_end], partial.bytes[row_start..row_end]);
    }
}

test "registerFontFace cleans up on Host.deinit and dirty_from_generation detects skipped frames" {
    const font_registry = @import("font_registry.zig");
    {
        var host = try embed.Host.init(testing.allocator, .{
            .size = .{ .w = 240, .h = 96 },
            .scale = 1.0,
            .theme = .dark_theme,
            .scan_system_fonts = false,
        });
        defer host.deinit();

        try host.registerFontFace(.{
            .family = "EmbedFaceScoped",
            .weight = .{ 400, 400 },
            .bytes = dejavu_ttf,
        });
        try testing.expect(font_registry.hasFamily("EmbedFaceScoped"));

        const StepScene = struct {
            text: []const u8 = "AB",
            fn view(s: *@This(), c: *ui.Context) void {
                const root = ui.div(c).column().sizeFull().p(8);
                defer root.end();
                ui.text(c, s.text, .{ .size = 18, .color = .white, .family = "EmbedFaceScoped" });
            }
        };
        var scene: StepScene = .{};
        const view = ui.View.init(&scene, StepScene.view);

        const out1 = host.frame(view, 1.0 / 60.0, 0.0);
        const gen1 = out1.glyph_atlas.generation;
        try testing.expect(gen1 > 0);
        try testing.expectEqual(@as(u64, 0), out1.glyph_atlas.dirty_from_generation);
        try testing.expect(out1.glyph_atlas.dirty != null);

        // Frame 2 packs new glyphs (simulating a frame evaluated while minimized / skipped by encoder).
        scene.text = "CD";
        const out2 = host.frame(view, 1.0 / 60.0, 0.02);
        const gen2 = out2.glyph_atlas.generation;
        try testing.expect(gen2 > gen1);
        try testing.expectEqual(gen1, out2.glyph_atlas.dirty_from_generation);

        // Frame 3 packs more glyphs: an encoder still cached at `gen1` sees `dirty_from_generation == gen2 != gen1`.
        scene.text = "EF";
        const out3 = host.frame(view, 1.0 / 60.0, 0.04);
        try testing.expect(out3.glyph_atlas.generation > gen2);
        try testing.expectEqual(gen2, out3.glyph_atlas.dirty_from_generation);
        try testing.expect(out3.glyph_atlas.dirty_from_generation != gen1);
    }
    try testing.expect(!font_registry.hasFamily("EmbedFaceScoped"));
}
