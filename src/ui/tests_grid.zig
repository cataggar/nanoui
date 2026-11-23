//! Tests for 2D CSS-style Grid layout (`layout_grid.zig`, `div.zig`, `ui.grid`):
//! `fixed` / `fr` / `auto` track sizing, multi-track spans, explicit + cursor
//! auto-placement, nested wrapping text inside `fr` columns, `ui.motion`
//! track/span rect projection, scrollable grids, and pixel-snapped shared edges.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const motion = ui.motion;

test "grid fixed, fr, and auto tracks distribute remainder and gaps" {
    const View = struct {
        ids: [6]u64 = @splat(0),
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .{ .fixed = 120 }, .{ .fr = 1 }, .{ .fr = 2 } };
            const rows = [_]ui.Track{ .auto, .{ .fixed = 48 }, .{ .fr = 1 } };
            const g = ui.div(c).grid(&cols, &rows).sizeFull().gap(12);
            defer g.end();

            // Row 0 (auto height = max(24, 36) = 36):
            const a = ui.div(c).h(24);
            s.ids[0] = a.id();
            a.end();
            const b = ui.div(c).h(36);
            s.ids[1] = b.id();
            b.end();
            const d = ui.div(c).h(20);
            s.ids[2] = d.id();
            d.end();

            // Row 1 (fixed 48), spanning cols 1..3:
            const e = ui.div(c);
            s.ids[3] = e.id();
            e.end();
            const f = ui.div(c).colSpan(2);
            s.ids[4] = f.id();
            f.end();

            // Row 2 (fr = 1 -> remaining height), spanning all 3 cols:
            const foot = ui.div(c).gridArea(2, 0, 1, 3);
            s.ids[5] = foot.id();
            foot.end();
        }
    };

    var v: View = .{};
    var t: ui.Tester = undefined;
    // Width 444: 444 - 120 (fixed) - 24 (2 gaps) = 300 -> 1fr = 100, 2fr = 200.
    // Height 208: 208 - 36 (auto) - 48 (fixed) - 24 (2 gaps) = 100 -> 1fr = 100.
    try t.init(testing.allocator, .init(&v, View.build), .{ .width = 444, .height = 208, .scale = 1 });
    defer t.deinit();
    t.frame();

    const r0 = t.ctx.rects.get(v.ids[0]).?;
    const r1 = t.ctx.rects.get(v.ids[1]).?;
    const r2 = t.ctx.rects.get(v.ids[2]).?;
    const r3 = t.ctx.rects.get(v.ids[3]).?;
    const r4 = t.ctx.rects.get(v.ids[4]).?;
    const r5 = t.ctx.rects.get(v.ids[5]).?;

    // Default stretch fills full resolved cell height (36) even when child didn't set .fill:
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 120, .h = 24 }, r0);
    try testing.expectEqual(ui.Rect{ .x = 132, .y = 0, .w = 100, .h = 36 }, r1);
    try testing.expectEqual(ui.Rect{ .x = 244, .y = 0, .w = 200, .h = 20 }, r2);
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 48, .w = 120, .h = 48 }, r3);
    try testing.expectEqual(ui.Rect{ .x = 132, .y = 48, .w = 312, .h = 48 }, r4);
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 108, .w = 444, .h = 100 }, r5);
}

test "grid intrinsic auto tracks expand for multi-column and multi-row spans" {
    const View = struct {
        grid_id: u64 = 0,
        span_col_id: u64 = 0,
        span_row_id: u64 = 0,
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .auto, .auto };
            const rows = [_]ui.Track{ .auto, .auto };
            const g = ui.div(c).grid(&cols, &rows).colGap(10).rowGap(6);
            s.grid_id = g.id();
            defer g.end();

            // Single-cell items: explicit 30px (does not stretch) and minW(40) (stretches to 60px).
            const fixed_cell = ui.div(c).w(30).h(20);
            const fixed_cell_id = fixed_cell.id();
            fixed_cell.end();
            _ = fixed_cell_id;
            const tall = ui.div(c).minW(40).rowSpan(2).h(76);
            s.span_row_id = tall.id();
            tall.end();

            // Row 1 col 0: height 20 -> rows are [20, 20], sum = 20 + 6 + 20 = 46 < 76 -> +15 each -> [35, 35].
            ui.div(c).w(20).h(20).end();

            // Implicit row 2 spanning 2 auto columns with 120px width -> deficit 40 -> +20 each -> cols [50, 60].
            const wide = ui.div(c).colSpan(2).w(120).h(18);
            s.span_col_id = wide.id();
            wide.end();
        }
    };

    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&v, View.build), .{ .width = 400, .height = 300, .scale = 1 });
    defer t.deinit();
    t.frame();

    const gr = t.ctx.rects.get(v.grid_id).?;
    // Cols: 50 + 10 + 60 = 120. Rows: 35 + 6 + 35 + 6 + 18 = 100.
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 120, .h = 100 }, gr);
    try testing.expectEqual(ui.Rect{ .x = 60, .y = 0, .w = 60, .h = 76 }, t.ctx.rects.get(v.span_row_id).?);
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 82, .w = 120, .h = 18 }, t.ctx.rects.get(v.span_col_id).?);
}

test "grid explicit coordinates mix with sparse auto-placement cursor and procedural ui.grid" {
    const View = struct {
        ids: [4]u64 = @splat(0),
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .px(50), .px(50), .px(50) };
            ui.grid(c, &cols, &.{}, .{ .gap = 10, .align_items = .center });
            defer ui.end(c);

            // Placed explicitly at right column spanning 2 rows before auto items!
            const side = ui.div(c).gridArea(0, 2, 2, 1).h(90);
            s.ids[0] = side.id();
            side.end();

            // Auto-placed hero spanning 2 cols -> lands at (0, 0..2).
            const hero = ui.div(c).colSpan(2).h(40);
            s.ids[1] = hero.id();
            hero.end();

            // Next two auto items skip occupied (0, 2) and (1, 2), landing at (1, 0) and (1, 1).
            const c0 = ui.div(c).h(20);
            s.ids[2] = c0.id();
            c0.end();
            const c1 = ui.div(c).h(40);
            s.ids[3] = c1.id();
            c1.end();
        }
    };

    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&v, View.build), .{ .width = 300, .height = 200, .scale = 1 });
    defer t.deinit();
    t.frame();

    // Row 0 = 40, Row 1 = 40; gap = 10 -> side spans 40 + 10 + 40 = 90.
    try testing.expectEqual(ui.Rect{ .x = 120, .y = 0, .w = 50, .h = 90 }, t.ctx.rects.get(v.ids[0]).?);
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 110, .h = 40 }, t.ctx.rects.get(v.ids[1]).?);
    // align_items = .center vertically centers the 20px item in the 40px row (y = 50 + 10 = 60).
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 60, .w = 50, .h = 20 }, t.ctx.rects.get(v.ids[2]).?);
    try testing.expectEqual(ui.Rect{ .x = 60, .y = 50, .w = 50, .h = 40 }, t.ctx.rects.get(v.ids[3]).?);
}

test "grid re-measures nested wrapping text inside fr columns and Flexbox grow rows" {
    const View = struct {
        grid_id: u64 = 0,
        narrow_id: u64 = 0,
        wide_id: u64 = 0,
        sibling_id: u64 = 0,
        fn build(s: *@This(), c: *ui.Context) void {
            const row = ui.div(c).row().wFull().gap(20);
            defer row.end();

            const cols = [_]ui.Track{ .{ .fr = 1 }, .{ .fr = 3 } };
            const g = ui.div(c).gridCols(&cols).grow().gap(10);
            s.grid_id = g.id();
            {
                defer g.end();
                const narrow = ui.div(c).column();
                s.narrow_id = narrow.id();
                ui.text(c, "Wrapping text inside a narrow fractional grid column expands the row height", .{ .size = 14, .wrap = true });
                narrow.end();

                const wide = ui.div(c).column();
                s.wide_id = wide.id();
                ui.text(c, "Wrapping text inside a narrow fractional grid column expands the row height", .{ .size = 14, .wrap = true });
                wide.end();
            }

            const sib = ui.div(c).grow().h(20);
            s.sibling_id = sib.id();
            sib.end();
        }
    };

    var v: View = .{};
    var t: ui.Tester = undefined;
    // Width 630, parent gap 20, grid internal col_gap 10 -> 600px free space split 300 + 300:
    // grid gets 10 + 300 = 310px (300px after col_gap -> col 0 1fr = 75px, col 1 3fr = 225px),
    // sibling gets 0 + 300 = 300px!
    try t.init(testing.allocator, .init(&v, View.build), .{ .width = 630, .height = 400, .scale = 1 });
    defer t.deinit();
    t.frame();

    const gr = t.ctx.rects.get(v.grid_id).?;
    const sib = t.ctx.rects.get(v.sibling_id).?;
    const narrow = t.ctx.rects.get(v.narrow_id).?;
    const wide = t.ctx.rects.get(v.wide_id).?;

    try testing.expectApproxEqAbs(@as(f32, 310), gr.w, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 300), sib.w, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 75), narrow.w, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 225), wide.w, 0.5);

    // Narrow 1fr column wraps onto multiple lines (> 2x single line height), and both stretched
    // cells + parent grid adopt the wrapped multi-line height!
    const single_lh = t.ctx.text.lineHeight(.{ .size = 14 });
    try testing.expect(gr.h >= single_lh * 3);
    try testing.expectApproxEqAbs(gr.h, narrow.h, 0.5);
    try testing.expectApproxEqAbs(gr.h, wide.h, 0.5);
}

test "grid pixel_snap eliminates 1px seams across fractional tracks and spans" {
    const SeamView = struct {
        ids: [5]u64 = @splat(0),
        fn build(s: *@This(), c: *ui.Context) void {
            // Bright red backdrop: any 1px seam between adjacent/spanning cells would show red!
            const root = ui.div(c).sizeFull().bg(.hex(0xff0000));
            defer root.end();

            const cols = [_]ui.Track{ .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } };
            const rows = [_]ui.Track{ .{ .fr = 1 }, .{ .fr = 1 } };
            const g = ui.div(c).grid(&cols, &rows).sizeFull().gap(0);
            defer g.end();

            const c0 = ui.div(c).colSpan(2).bg(.hex(0x1e293b));
            s.ids[0] = c0.id();
            c0.end();
            const c1 = ui.div(c).bg(.hex(0x1e293b));
            s.ids[1] = c1.id();
            c1.end();
            for (0..3) |i| {
                const cell = ui.div(c).bg(.hex(0x1e293b));
                s.ids[2 + i] = cell.id();
                cell.end();
            }
        }
    };

    for ([_]f32{ 1, 1.5, 2, 3 }) |sc| {
        var v: SeamView = .{};
        var t: ui.Tester = undefined;
        // Prime dimensions (101 x 67) force non-integer 1/3 and 1/2 track divisions!
        try t.init(testing.allocator, .init(&v, SeamView.build), .{ .width = 101, .height = 67, .scale = sc });
        defer t.deinit();
        t.ctx.pixel_snap = true;
        t.frame();

        const span2 = t.ctx.rects.get(v.ids[0]).?;
        const top_r = t.ctx.rects.get(v.ids[1]).?;
        const bot0 = t.ctx.rects.get(v.ids[2]).?;
        const bot1 = t.ctx.rects.get(v.ids[3]).?;
        const bot2 = t.ctx.rects.get(v.ids[4]).?;

        // Spanned cell's right edge matches bot1's right edge and top_r's left edge identically.
        try testing.expectApproxEqAbs(span2.x + span2.w, top_r.x, 1e-5);
        try testing.expectApproxEqAbs(span2.x + span2.w, bot1.x + bot1.w, 1e-5);
        try testing.expectApproxEqAbs(bot0.x + bot0.w, bot1.x, 1e-5);
        try testing.expectApproxEqAbs(bot1.x + bot1.w, bot2.x, 1e-5);
        try testing.expectApproxEqAbs(span2.y + span2.h, bot0.y, 1e-5);
    }

    // Offscreen raster check at 1x and 2x: zero red pixels anywhere inside the snapped grid.
    for ([_]f32{ 1, 2 }) |sc| {
        var v: SeamView = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&v, SeamView.build), .{ .width = 101, .height = 67, .scale = sc });
        defer t.deinit();
        t.ctx.pixel_snap = true;
        t.frame();

        const pixels = try t.render(testing.allocator);
        defer pixels.deinit(testing.allocator);
        for (0..pixels.height) |y| {
            for (0..pixels.width) |x| {
                const off = (y * pixels.width + x) * 4;
                // BGRA: bytes[2] is red; cells are solid blue (0x1a2b4c, R=0x1a=26) over 0xff0000 red.
                try testing.expect(pixels.bytes[off + 2] < 80);
            }
        }
    }
}

test "ui.motion layout projection animates both position and size across grid tracks and spans" {
    const MotionGrid = struct {
        expanded: bool = false,
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .px(60), .px(80), .px(100) };
            const rows = [_]ui.Track{ .px(40), .px(60) };
            const g = ui.div(c).grid(&cols, &rows).sizeFull().gap(10).bg(.white);
            defer g.end();

            ui.key(c, "card");
            const f = motion.frame(c, .{
                .layout = true,
                .transition = .{ .tween = .{ .duration = 0.4, .ease = .linear } },
            });
            const area = if (s.expanded)
                ui.div(c).gridArea(1, 1, 1, 2) // x=70, y=50, w=190, h=60
            else
                ui.div(c).gridArea(0, 0, 1, 1); // x=0, y=0, w=60, h=40
            area.bg(.hex(0x00ff00)).motion(f).end();
        }
    };

    var s: MotionGrid = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, MotionGrid.build), .{ .width = 260, .height = 110, .scale = 1 });
    defer t.deinit();
    t.frame();

    const findGreen = struct {
        fn get(tester: *ui.Tester) ![4]f32 {
            for (tester.instances.items) |it| {
                if (it.color[1] > 0.9 and it.color[0] < 0.1 and it.color[2] < 0.1) return it.rect;
            }
            return error.MissingCard;
        }
    }.get;

    try testing.expectEqual([4]f32{ 0, 0, 60, 40 }, try findGreen(&t));
    try testing.expect(!t.ctx.animating);

    s.expanded = true;
    t.frame();
    // On the exact trigger frame (dt=0), drawn rect starts smoothly from [0, 0, 60, 40].
    try testing.expectEqual([4]f32{ 0, 0, 60, 40 }, try findGreen(&t));
    try testing.expect(t.ctx.animating);

    t.advance(0.2); // halfway through 0.4s linear tween -> [35, 25, 125, 50]
    const mid = try findGreen(&t);
    try testing.expectApproxEqAbs(@as(f32, 35), mid[0], 1.0);
    try testing.expectApproxEqAbs(@as(f32, 25), mid[1], 1.0);
    try testing.expectApproxEqAbs(@as(f32, 125), mid[2], 1.0);
    try testing.expectApproxEqAbs(@as(f32, 50), mid[3], 1.0);

    t.settle(2);
    try testing.expectEqual([4]f32{ 70, 50, 190, 60 }, try findGreen(&t));
    try testing.expect(!t.ctx.animating and t.ctx.frame_in == null);
}

test "scrollable grid computes accurate scroll_max and scrollbar geometry" {
    const ScrollGrid = struct {
        scroll_id: u64 = 0,
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .{ .fr = 1 }, .{ .fr = 1 } };
            const g = ui.div(c).gridCols(&cols).sizeFull().gap(10).p(10).scrollY();
            s.scroll_id = g.id();
            defer g.end();
            for (0..10) |i| {
                ui.keyInt(c, i);
                ui.div(c).h(40).bg(.hex(0x334155)).end();
            }
        }
    };

    var v: ScrollGrid = .{};
    var t: ui.Tester = undefined;
    // 10 items in 2 cols -> 5 rows of 40px + 4 gaps of 10px = 240px; padding 20px -> 260px content in 120px view -> max_scroll = 140.
    try t.init(testing.allocator, .init(&v, ScrollGrid.build), .{ .width = 200, .height = 120, .scale = 1 });
    defer t.deinit();
    t.frame();

    try testing.expectApproxEqAbs(@as(f32, 140), t.ctx.scroll_max.get(v.scroll_id).?, 0.5);
    const geom = t.ctx.scrollbars.get(v.scroll_id).?;
    try testing.expectApproxEqAbs(@as(f32, 140), geom.max_scroll, 0.5);

    t.scroll(100, 60, -50);
    try testing.expectApproxEqAbs(@as(f32, 50), t.ctx.scroll.get(v.scroll_id).?, 0.5);
}

test "gridRow with auto column past unallocated rows and auto-column wrapping text shrink" {
    const View = struct {
        jumped_id: u64 = 0,
        label_id: u64 = 0,
        para_id: u64 = 0,
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .auto, .auto };
            const g = ui.div(c).gridCols(&cols).wFull().gap(10);
            defer g.end();

            // Definite row 2 with auto column when 0 rows have been allocated yet!
            const jumped = ui.div(c).gridRow(2).colSpan(2).h(24);
            s.jumped_id = jumped.id();
            jumped.end();

            // Rigid auto column 0 (80px) + wrapping paragraph in auto column 1 inside 300px grid.
            const lbl = ui.div(c).w(80).h(20);
            s.label_id = lbl.id();
            lbl.end();

            const para = ui.div(c).column();
            s.para_id = para.id();
            ui.text(c, "A long wrapping description inside an auto column shrinks cleanly to fit remaining grid width without overflowing", .{ .size = 14, .wrap = true });
            para.end();
        }
    };

    var v: View = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&v, View.build), .{ .width = 300, .height = 240, .scale = 1 });
    defer t.deinit();
    t.frame();

    const lbl = t.ctx.rects.get(v.label_id).?;
    const para = t.ctx.rects.get(v.para_id).?;
    const jumped = t.ctx.rects.get(v.jumped_id).?;

    // Rigid label stays 80px; wrapping auto column shrinks to 300 - 80 - 10 = 210px (zero overflow!).
    try testing.expectEqual(@as(f32, 80), lbl.w);
    try testing.expectApproxEqAbs(@as(f32, 210), para.w, 0.5);
    try testing.expect(para.x + para.w <= 300.5);
    // Row 1 is an empty auto row (0px), so row 2 starts at para.h + 10 + 0 + 10.
    try testing.expectApproxEqAbs(para.h + 20, jumped.y, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 300), jumped.w, 0.5);
}

test "canvas inside layout-projected grid cell is not culled mid-glide" {
    const CanvasGrid = struct {
        moved: bool = false,
        fn build(s: *@This(), c: *ui.Context) void {
            const cols = [_]ui.Track{ .px(50), .{ .fr = 1 }, .px(50) };
            const g = ui.div(c).gridCols(&cols).sizeFull();
            defer g.end();

            ui.key(c, "gliding-canvas");
            const f = motion.frame(c, .{
                .layout = true,
                .transition = .{ .tween = .{ .duration = 0.4, .ease = .linear } },
            });
            const cell = ui.div(c).gridCell(0, if (s.moved) 2 else 0).h(50).motion(f);
            defer cell.end();
            const cv = ui.canvas(c, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } });
            cv.rect(.{ .x = 5, .y = 5, .w = 40, .h = 40 }, .hex(0x0000ff), 0);
        }
    };

    var s: CanvasGrid = .{};
    var t: ui.Tester = undefined;
    // Width 400 -> col 0 is x=0..50, col 2 is x=350..400 (displacement 350pt > 50pt width!).
    try t.init(testing.allocator, .init(&s, CanvasGrid.build), .{ .width = 400, .height = 80, .scale = 1 });
    defer t.deinit();
    t.dt = 0.05;
    t.settle(2);

    s.moved = true;
    t.frame(); // Trigger frame (dt=0): visual x = 5, layout x = 350 (displacement 350pt > 50pt width).
    t.advance(0.1); // 25% into 0.4s linear glide: visual x ≈ 5 + 87.5 = 92.5.
    var found_blue = false;
    for (t.instances.items) |inst| {
        if (inst.color[2] > 0.9 and inst.color[0] < 0.1) {
            found_blue = true;
            try testing.expectApproxEqAbs(@as(f32, 92.5), inst.rect[0], 2.0);
        }
    }
    try testing.expect(found_blue);
}
