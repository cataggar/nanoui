//! Slug-style analytic GPU quadratic Bezier vector text (`Kind.vector_text = 13`):
//! shared cross-renderer parity scene (`360 x 300`), auto-promotion & opt-out,
//! multi-scale coverage (`0.5x..16x`), backface culling & mirror, rounded clip &
//! horizontal fade, `PixelCanvas` incremental damage + reset invalidation, and
//! `SlugStore` 4 MiB cap / mid-frame reset replay.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const paint = @import("paint.zig");
const raster = @import("raster.zig");
const slug_store = @import("slug_store.zig");
const portable = @import("text.zig").portable or @import("../backend.zig").is_embed;

/// Shared `360 x 300` scene exercising `Kind.vector_text = 13` across explicit
/// regular/bold/italic vector text, rotation, minification & magnification,
/// 2x2 affine shear, 3D perspective `turn` (front, mirrored back, hidden culled),
/// and rounded-clipped + horizontally faded single-line vector text.
pub const Scene = struct {
    pub fn view(_: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(12).gap(6).bg(.hex(0x10141d));
        defer root.end();

        ui.text(c, "Slug Vector 0123", .{ .size = 14, .vector = true, .color = .hex(0xe8eefc) });

        const row1 = ui.div(c).row().gap(14).itemsCenter();
        ui.text(c, "Bold", .{ .size = 34, .weight = .bold, .vector = true, .color = .hex(0x63b3ff) });
        ui.text(c, "Bold & Oblique", .{ .size = 17, .italic = true, .vector = true, .color = .hex(0xffb86c) });
        row1.end();

        const row2 = ui.div(c).row().wFull().h(54).itemsCenter();
        {
            const s0 = ui.div(c).w(96).h(44).itemsCenter().justifyCenter();
            const mini = ui.div(c).scale(0.65);
            ui.text(c, "Mini 0.65x", .{ .size = 16, .color = .hex(0x9be9a8) });
            mini.end();
            s0.end();

            const s1 = ui.div(c).w(140).h(54).itemsCenter().justifyCenter();
            const mag = ui.div(c).scale(2.6);
            ui.text(c, "2.6x", .{ .size = 13, .weight = .semibold, .color = .hex(0xff79c6) });
            mag.end();
            s1.end();

            const s2 = ui.div(c).w(96).h(54).itemsCenter().justifyCenter();
            const rot = ui.div(c).rotate(0.41);
            ui.text(c, "Rot 0.41", .{ .size = 15, .color = .hex(0xf1fa8c) });
            rot.end();
            s2.end();
        }
        row2.end();

        const row3 = ui.div(c).row().wFull().h(46).itemsCenter();
        {
            const a0 = ui.div(c).w(122).h(44).justifyCenter();
            _ = c.open(.{ .transform = .{ .a = 1.08, .b = 0.16, .c = -0.2, .d = 0.94 } }, null);
            ui.text(c, "Shear 2x2", .{ .size = 16, .color = .hex(0x8be9fd) });
            c.end();
            a0.end();

            const a1 = ui.div(c).w(108).h(44).itemsCenter().justifyCenter();
            const t3d = ui.div(c).turn(0.62, 420);
            ui.text(c, "Turn 3D", .{ .size = 18, .weight = .bold, .color = .hex(0xbd93f9) });
            t3d.end();
            a1.end();

            const a2 = ui.div(c).w(102).h(44).itemsCenter().justifyCenter();
            const back = ui.div(c).turn(2.45, 420).face(.back);
            ui.text(c, "Mirror", .{ .size = 18, .weight = .bold, .color = .hex(0x50fa7b) });
            back.end();
            const culled = ui.div(c).turn(2.45, 420).face(.front);
            ui.text(c, "Culled", .{ .size = 18, .weight = .bold, .color = .hex(0xff5555) });
            culled.end();
            a2.end();
        }
        row3.end();

        const pill = ui.div(c).row().w(284).h(36).px(10).itemsCenter().rounded(14).clip().bg(.hex(0x1d2638));
        {
            const corner = ui.div(c).absolute().offset(-4, -3);
            ui.text(c, "O", .{ .size = 24, .weight = .bold, .vector = true, .color = .hex(0xffd166) });
            corner.end();

            const inner = ui.div(c).row().w(246).pl(16).itemsCenter();
            ui.text(c, "Clipped fade text that runs past the edge", .{
                .size = 14,
                .vector = true,
                .max_lines = 1,
                .truncate = .fade,
                .fade_width = 28,
                .color = .hex(0xf8f8f2),
            });
            inner.end();
        }
        pill.end();
    }
};

fn countKind(instances: []const gpu.Instance, kind: f32) usize {
    var n: usize = 0;
    for (instances) |inst| if (inst.kind == kind) {
        n += 1;
    };
    return n;
}

fn nonBlackPixels(px: gpu.Pixels) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < px.bytes.len) : (i += 4) {
        if (px.bytes[i] != 0 or px.bytes[i + 1] != 0 or px.bytes[i + 2] != 0) n += 1;
    }
    return n;
}

test "slug: static axis-aligned text stays bitmap Kind.text with zero SlugStore usage" {
    const V = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(12).bg(.hex(0xffffff));
            defer root.end();
            ui.text(c, "Static copy", .{ .size = 15, .color = .hex(0x111111) });
        }
    };
    var v: V = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&v, V.view), .{ .width = 200, .height = 60 });
    defer t.deinit();

    try testing.expect(t.ctx.auto_vector_text);
    try testing.expect(countKind(t.instances.items, gpu.Kind.text) > 0);
    try testing.expectEqual(@as(usize, 0), countKind(t.instances.items, gpu.Kind.vector_text));
    try testing.expectEqual(@as(u32, 0), t.text.slug.tex_height);
    try testing.expectEqual(@as(u32, 0), t.text.slug.used_words);
}

test "slug: explicit vector text skips whitespace, caches outlines across sizes, and renders 0.5x..16x" {
    const Sized = struct {
        pt: f32 = 12,
        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(4).bg(.hex(0x000000));
            defer root.end();
            ui.text(c, "A B", .{ .size = s.pt, .vector = true, .color = .hex(0xffffff) });
        }
    };
    var s: Sized = .{ .pt = 12 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Sized.view), .{ .width = 320, .height = 200 });
    defer t.deinit();

    // 'A' and 'B' emit Kind.vector_text; ' ' whitespace emits no instance.
    try testing.expectEqual(@as(usize, 2), countKind(t.instances.items, gpu.Kind.vector_text));
    try testing.expectEqual(@as(usize, 0), countKind(t.instances.items, gpu.Kind.text));
    const used_12 = t.text.slug.used_words;
    try testing.expect(used_12 > slug_store.sentinel_words);
    try testing.expect(t.text.slug.tex_height > 0);

    for ([_]f32{ 24, 64, 128 }) |pt| {
        s.pt = pt;
        t.frame();
        try testing.expectEqual(@as(usize, 2), countKind(t.instances.items, gpu.Kind.vector_text));
        try testing.expectEqual(used_12, t.text.slug.used_words);
    }

    const Tiny = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(2).bg(.hex(0x000000));
            defer root.end();
            ui.text(c, "Hi", .{ .size = 16, .vector = true, .color = .hex(0xffffff) });
        }
    };
    var tiny: Tiny = .{};
    for ([_]f32{ 0.5, 1.0, 2.0, 8.0, 16.0 }) |sc| {
        var ts: ui.Tester = undefined;
        try ts.init(testing.allocator, .init(&tiny, Tiny.view), .{ .width = 48, .height = 32, .scale = sc });
        defer ts.deinit();
        const px = try ts.render(testing.allocator);
        defer px.deinit(testing.allocator);

        var solid: usize = 0;
        var edge_aa: usize = 0;
        var i: usize = 0;
        while (i + 3 < px.bytes.len) : (i += 4) {
            const g = px.bytes[i + 1];
            if (g >= 200) solid += 1 else if (g > 0) edge_aa += 1;
        }
        if (sc >= 1.0) try testing.expect(solid > 0);
        try testing.expect(solid + edge_aa > 0);
        try testing.expect(edge_aa > 0);
    }
}

test "slug: transforms and active motion auto-promote text, and auto_vector_text=false opts out" {
    const Mode = enum { scale, rotation, turn, affine, pulse, motion_scale, motion_rot, opt_out };
    const View = struct {
        mode: Mode = .scale,
        fn view(s: *@This(), c: *ui.Context) void {
            c.auto_vector_text = s.mode != .opt_out;
            const root = ui.div(c).column().sizeFull().p(8);
            defer root.end();
            switch (s.mode) {
                .scale => {
                    const b = ui.div(c).scale(1.35);
                    defer b.end();
                    ui.text(c, "Scale", .{ .size = 14 });
                },
                .rotation => {
                    const b = ui.div(c).rotate(0.28);
                    defer b.end();
                    ui.text(c, "Rot", .{ .size = 14 });
                },
                .turn => {
                    const b = ui.div(c).turn(0.42, 360);
                    defer b.end();
                    ui.text(c, "Turn", .{ .size = 14 });
                },
                .affine => {
                    _ = c.open(.{ .transform = .{ .a = 1.1, .b = 0.12, .c = -0.1, .d = 0.95 } }, null);
                    defer c.end();
                    ui.text(c, "Shear", .{ .size = 14 });
                },
                .pulse => {
                    _ = c.open(.{ .pulse = .{ .period = 1.2, .scale_amp = 0.1, .alpha_low = 0.9 } }, null);
                    defer c.end();
                    ui.text(c, "Pulse", .{ .size = 14 });
                },
                .motion_scale => {
                    const f = ui.motion.frame(c, .{
                        .initial = .{ .scale = 1.0 },
                        .target = .{ .scale = 1.4 },
                        .transition = .{ .spring = .{} },
                    });
                    const b = ui.div(c).motion(f);
                    defer b.end();
                    ui.text(c, "MotS", .{ .size = 14 });
                },
                .motion_rot => {
                    const f = ui.motion.frame(c, .{
                        .initial = .{ .rotation = 0.0 },
                        .target = .{ .rotation = 0.45 },
                        .transition = .{ .spring = .{} },
                    });
                    const b = ui.div(c).motion(f);
                    defer b.end();
                    ui.text(c, "MotR", .{ .size = 14 });
                },
                .opt_out => {
                    const b1 = ui.div(c).scale(1.5).rotate(0.3);
                    ui.text(c, "Bitmap", .{ .size = 14 });
                    b1.end();
                    const b2 = ui.div(c).turn(0.4, 320);
                    ui.text(c, "Forced", .{ .size = 14, .vector = true });
                    b2.end();
                },
            }
        }
    };

    var st: View = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&st, View.view), .{ .width = 220, .height = 120 });
    defer t.deinit();

    for ([_]Mode{ .scale, .rotation, .turn, .affine, .pulse, .motion_scale, .motion_rot }) |m| {
        st.mode = m;
        t.frame();
        try testing.expect(countKind(t.instances.items, gpu.Kind.vector_text) > 0);
        try testing.expectEqual(@as(usize, 0), countKind(t.instances.items, gpu.Kind.text));
    }

    st.mode = .opt_out;
    t.frame();
    try testing.expectEqual(@as(usize, 6), countKind(t.instances.items, gpu.Kind.text));
    try testing.expectEqual(@as(usize, 6), countKind(t.instances.items, gpu.Kind.vector_text));
}

test "slug: backface culling, mirror, rounded clip, fade, and PixelCanvas damage/reset parity" {
    const Card = struct {
        face: ui.Face = .front,
        turn: f32 = 2.4,
        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().bg(.hex(0x000000));
            defer root.end();
            const card = ui.div(c).w(120).h(50).itemsCenter().justifyCenter().turn(s.turn, 400).face(s.face);
            defer card.end();
            ui.text(c, "L", .{ .size = 28, .weight = .bold, .vector = true, .color = .hex(0xffffff) });
        }
    };
    var card: Card = .{ .face = .front, .turn = 2.4 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&card, Card.view), .{ .width = 160, .height = 80 });
    defer t.deinit();

    const culled_px = try t.render(testing.allocator);
    defer culled_px.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), nonBlackPixels(culled_px));

    card.face = .back;
    t.frame();
    const back_px = try t.render(testing.allocator);
    defer back_px.deinit(testing.allocator);
    try testing.expect(nonBlackPixels(back_px) > 20);

    // Rounded clip cuts corner ink of vector glyphs while preserving interior ink.
    const ClipView = struct {
        round: f32 = 16,
        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().bg(.hex(0x000000));
            defer root.end();
            const box = ui.div(c).w(80).h(44).rounded(s.round).clip().bg(.hex(0x000000));
            defer box.end();
            const shift = ui.div(c).absolute().offset(-3, -6);
            defer shift.end();
            ui.text(c, "H", .{ .size = 36, .weight = .bold, .vector = true, .color = .hex(0xffffff) });
        }
    };
    var cv_state: ClipView = .{ .round = 0 };
    var tc: ui.Tester = undefined;
    try tc.init(testing.allocator, .init(&cv_state, ClipView.view), .{ .width = 100, .height = 60 });
    defer tc.deinit();
    const unrounded = try tc.render(testing.allocator);
    defer unrounded.deinit(testing.allocator);

    cv_state.round = 16;
    tc.frame();
    const rounded = try tc.render(testing.allocator);
    defer rounded.deinit(testing.allocator);

    // Top-left corner square [0..9, 0..9) is outside r=16pt*2=32px circle corner.
    var corner_unrounded: usize = 0;
    var corner_rounded: usize = 0;
    for (0..9) |y| for (0..9) |x| {
        const idx = (y * rounded.width + x) * 4 + 1;
        if (unrounded.bytes[idx] > 0) corner_unrounded += 1;
        if (rounded.bytes[idx] > 0) corner_rounded += 1;
    };
    try testing.expect(corner_unrounded > 0);
    try testing.expectEqual(@as(usize, 0), corner_rounded);
    try testing.expect(nonBlackPixels(rounded) > 40);
    try testing.expect(nonBlackPixels(unrounded) > nonBlackPixels(rounded));

    // Horizontal truncation fade attenuates ink near the right edge of the box.
    const FadeView = struct {
        x: f32 = 8,
        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(8).bg(.hex(0xffffff));
            defer root.end();
            const row = ui.div(c).row().w(140).offset(s.x, 0).itemsCenter();
            defer row.end();
            ui.text(c, "Vector fade line that runs well past its narrow container", .{
                .size = 14,
                .vector = true,
                .max_lines = 1,
                .truncate = .fade,
                .fade_width = 24,
                .color = .hex(0x000000),
            });
        }
    };
    var fv: FadeView = .{};
    var tf: ui.Tester = undefined;
    try tf.init(testing.allocator, .init(&fv, FadeView.view), .{ .width = 220, .height = 56 });
    defer tf.deinit();
    tf.settle(0.2);

    const fade_px = try tf.render(testing.allocator);
    defer fade_px.deinit(testing.allocator);
    var left_ink: u8 = 0;
    var tail_ink: u8 = 0;
    for (0..fade_px.height) |y| {
        for (40..90) |x| left_ink = @max(left_ink, 255 - fade_px.bytes[(y * fade_px.width + x) * 4 + 1]);
        for (306..312) |x| tail_ink = @max(tail_ink, 255 - fade_px.bytes[(y * fade_px.width + x) * 4 + 1]);
    }
    try testing.expect(left_ink > 150);
    try testing.expect(tail_ink < 90);

    // PixelCanvas incremental damage + slug_resets full-frame invalidation matches whole-frame raster.draw byte-for-byte.
    if (portable) {
        const gpa = testing.allocator;
        var canvas: ui.PixelCanvas = .{};
        defer canvas.deinit(gpa);

        const steps = [_]struct { x: f32, reset_slug: bool }{
            .{ .x = 8, .reset_slug = false },
            .{ .x = 26, .reset_slug = false },
            .{ .x = 26, .reset_slug = true },
        };
        for (steps) |step| {
            fv.x = step.x;
            if (step.reset_slug) tf.text.slug.reset();
            tf.frame();
            canvas.draw(gpa, .{
                .instances = tf.instances.items,
                .text = &tf.text,
                .clear = tf.theme.background,
                .size = tf.size,
                .scale = tf.scale,
            });
            const fresh = try tf.render(gpa);
            defer fresh.deinit(gpa);
            try testing.expectEqualSlices(u8, fresh.bytes, canvas.bytes[0 .. canvas.width * canvas.height * 4]);
        }
    }
}

test "slug: SlugStore 4 MiB cap and frame-boundary reset replay" {
    const gpa = testing.allocator;

    // 1. Direct SlugStore 4 MiB (max_words = 1024 * 1024) overflow + explicit reset().
    var store: slug_store.Store = .{};
    defer store.deinit(gpa);

    var curves: [384]slug_store.curve.Curve = undefined;
    for (&curves, 0..) |*cv, idx| {
        const fi: f32 = @floatFromInt(idx);
        const x0 = @mod(fi, 16.0) * 0.05;
        const y0 = @floor(fi / 16.0) * 0.03;
        cv.* = .{
            .p1 = .{ x0, y0 },
            .p2 = .{ x0 + 0.02, y0 + 0.04 },
            .p3 = .{ x0 + 0.04, y0 + 0.01 },
        };
    }
    const gb: [4]f32 = .{ 0, 0, 1, 1 };
    const first_key: slug_store.Key = .{ .face = 1, .glyph = 0, .skew_q8 = 0, .bold_q12 = 0 };
    const first_entry = try store.putCurves(gpa, first_key, &curves, gb);
    try testing.expectEqual(slug_store.sentinel_words, first_entry.blob);
    const one_glyph_words = store.used_words - slug_store.sentinel_words;
    try testing.expect(one_glyph_words > 800);

    var g: u16 = 1;
    while (!store.reset_during_frame) : (g += 1) {
        _ = try store.putCurves(gpa, .{ .face = 1, .glyph = g, .skew_q8 = 0, .bold_q12 = 0 }, &curves, gb);
        try testing.expect(g < 4000);
    }
    const overflow_key: slug_store.Key = .{ .face = 1, .glyph = g - 1, .skew_q8 = 0, .bold_q12 = 0 };
    try testing.expect(store.reset_during_frame);
    try testing.expectEqual(@as(u32, 1), store.resets);
    try testing.expectEqual(slug_store.sentinel_words + one_glyph_words, store.used_words);
    try testing.expect(store.get(first_key) == null);
    try testing.expect(store.get(overflow_key) != null);

    store.clearResetFlag();
    try testing.expect(!store.reset_during_frame);
    store.reset();
    try testing.expectEqual(@as(u32, 2), store.resets);
    try testing.expectEqual(slug_store.sentinel_words, store.used_words);
    try testing.expect(store.get(overflow_key) == null);
    const reencoded = try store.putCurves(gpa, first_key, &curves, gb);
    try testing.expectEqual(slug_store.sentinel_words, reencoded.blob);

    // 2. Mid-frame overflow replay through frame.run / Tester:
    // Leave room for just ~1 glyph before max_words, then draw "ABCD" in one frame.
    const ReplayView = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(8).bg(.hex(0x000000));
            defer root.end();
            ui.text(c, "ABCD", .{ .size = 24, .vector = true, .color = .hex(0xffffff) });
        }
    };
    var rv: ReplayView = .{};
    var ref_t: ui.Tester = undefined;
    try ref_t.init(gpa, .init(&rv, ReplayView.view), .{ .width = 140, .height = 60 });
    defer ref_t.deinit();
    const ref_px = try ref_t.render(gpa);
    defer ref_px.deinit(gpa);

    var replay_t: ui.Tester = undefined;
    try replay_t.init(gpa, .init(&rv, ReplayView.view), .{ .width = 140, .height = 60 });
    defer replay_t.deinit();

    // Fill replay_t.text.slug with synthetic glyphs until less than 150 words remain before max_words,
    // so 'A' fits on the first paint pass and 'B'/'C'/'D' trigger mid-frame reset + replay!
    var fill_id: u16 = 1;
    while (slug_store.max_words - replay_t.text.slug.used_words > 1200) : (fill_id += 1) {
        _ = try replay_t.text.slug.putCurves(gpa, .{ .face = 99, .glyph = fill_id, .skew_q8 = 0, .bold_q12 = 0 }, &curves, gb);
    }
    const tiny_curves = curves[0..12];
    while (slug_store.max_words - replay_t.text.slug.used_words > 90) : (fill_id += 1) {
        _ = try replay_t.text.slug.putCurves(gpa, .{ .face = 98, .glyph = fill_id, .skew_q8 = 0, .bold_q12 = 0 }, tiny_curves, gb);
    }
    replay_t.text.slug.map.clearRetainingCapacity();
    replay_t.text.slug.clearResetFlag();
    const resets_before = replay_t.text.slug.resets;

    replay_t.frame();
    // Preserved after frame.run so GPU Surface presenters see mid-frame resets!
    try testing.expect(replay_t.text.slug.reset_during_frame);
    try testing.expectEqual(resets_before + 1, replay_t.text.slug.resets);
    try testing.expectEqual(@as(usize, 4), countKind(replay_t.instances.items, gpu.Kind.vector_text));

    const replay_px = try replay_t.render(gpa);
    defer replay_px.deinit(gpa);
    try testing.expectEqualSlices(u8, ref_px.bytes, replay_px.bytes);

    // Cleared at the start of the subsequent frame when no reset occurs:
    replay_t.frame();
    try testing.expect(!replay_t.text.slug.reset_during_frame);

    // 3. Single-frame >4 MiB burst fallback: if slug_overflow_fallback is set,
    // vector text cleanly degrades to bitmap Kind.text instead of reading overwritten blobs.
    replay_t.ctx.slug_overflow_fallback = true;
    defer replay_t.ctx.slug_overflow_fallback = false;
    replay_t.ctx.next_hits.clearRetainingCapacity();
    paint.paint(&replay_t.ctx, &replay_t.instances);
    try testing.expectEqual(@as(usize, 0), countKind(replay_t.instances.items, gpu.Kind.vector_text));
    try testing.expectEqual(@as(usize, 4), countKind(replay_t.instances.items, gpu.Kind.text));
}

test "slug: Scene matches CPU rasterizer" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);

    try testing.expect(countKind(t.instances.items, gpu.Kind.vector_text) > 30);
    try testing.expectEqual(@as(usize, 0), countKind(t.instances.items, gpu.Kind.text));

    if (portable) return;

    const metal_px = try t.render(gpa);
    defer metal_px.deinit(gpa);
    const cpu_bytes = try gpa.alloc(u8, metal_px.width * metal_px.height * 4);
    defer gpa.free(cpu_bytes);
    const cpu_px: gpu.Pixels = .{ .bytes = cpu_bytes, .width = metal_px.width, .height = metal_px.height };
    const sv = t.text.slugView();
    const mask: raster.Mask = .{
        .pixels = &.{},
        .size = 0,
        .slug_words = sv.words,
        .slug_height = sv.height,
        .slug_generation = sv.generation,
    };
    raster.draw(cpu_px, t.instances.items, mask, t.text.images.pictures(), t.scale, t.theme.background);

    var total: u64 = 0;
    var worst: u8 = 0;
    var off: usize = 0;
    for (metal_px.bytes, cpu_px.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu_px.bytes.len));
    try testing.expect(mean < 0.08);
    try testing.expect(worst <= 32);
    try testing.expect(off * 500 < cpu_px.bytes.len);
}
