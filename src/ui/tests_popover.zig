//! Headless `ui.Tester` suites for `ui.popover`, `ui.floatingPanel`,
//! `ui.place` and `ui.placeBounds`: placement and edge flipping, `safe_area`
//! clamping, zero-guess Frame 0 sizing, scroll tracking, click-through
//! prevention, LIFO `Escape` dismissal, and clamped panel header dragging.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

fn findCloseButton(t: *ui.Tester, panel_id: u64) ?ui.Rect {
    if (t.findText("✕")) |r| return r;
    if (t.findText("×")) |r| return r;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.indexOf(u8, ic.name, "xmark") != null) return n.rect,
        else => {},
    };
    for (t.ctx.a11y_items.items) |it| {
        if (std.ascii.eqlIgnoreCase(it.label, "close")) return t.ctx.nodes.items[it.node_index].rect;
    }
    const pr = t.ctx.rects.get(panel_id) orelse return null;
    for (t.ctx.nodes.items) |n| {
        if (n.interactive and n.id != panel_id and n.rect.w > 0 and n.rect.w <= 40 and
            n.rect.x >= pr.x + pr.w - 56 and n.rect.y <= pr.y + 48) return n.rect;
    }
    return null;
}

test "placeBounds placements, automatic side-flipping, and safe_area clamping" {
    const bounds: ui.Rect = .{ .x = 0, .y = 0, .w = 500, .h = 400 };
    const mid: ui.Rect = .{ .x = 200, .y = 160, .w = 80, .h = 30 };
    const sz: ui.Size = .{ .w = 100, .h = 60 };

    // All 8 placements when unobstructed.
    const bs = ui.placeBounds(bounds, mid, sz, .bottom_start, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 200), bs.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 196), bs.y, 0.01);

    const bc = ui.placeBounds(bounds, mid, sz, .bottom, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 190), bc.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 196), bc.y, 0.01);

    const be = ui.placeBounds(bounds, mid, sz, .bottom_end, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 180), be.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 196), be.y, 0.01);

    const ts = ui.placeBounds(bounds, mid, sz, .top_start, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 200), ts.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 94), ts.y, 0.01);

    const tc = ui.placeBounds(bounds, mid, sz, .top, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 190), tc.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 94), tc.y, 0.01);

    const te = ui.placeBounds(bounds, mid, sz, .top_end, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 180), te.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 94), te.y, 0.01);

    const pl = ui.placeBounds(bounds, mid, sz, .left, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 94), pl.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 145), pl.y, 0.01);

    const pr = ui.placeBounds(bounds, mid, sz, .right, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 286), pr.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 145), pr.y, 0.01);

    // Side-flipping: bottom -> top, top -> bottom, left -> right, right -> left.
    const flip_top = ui.placeBounds(bounds, .{ .x = 200, .y = 350, .w = 80, .h = 30 }, .{ .w = 100, .h = 80 }, .bottom_end, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 180), flip_top.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 264), flip_top.y, 0.01);

    const flip_bot = ui.placeBounds(bounds, .{ .x = 200, .y = 10, .w = 80, .h = 30 }, .{ .w = 100, .h = 80 }, .top, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 190), flip_bot.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 46), flip_bot.y, 0.01);

    const flip_right = ui.placeBounds(bounds, .{ .x = 20, .y = 160, .w = 40, .h = 30 }, sz, .left, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 66), flip_right.x, 0.01);

    const flip_left = ui.placeBounds(bounds, .{ .x = 440, .y = 160, .w = 40, .h = 30 }, sz, .right, 6, 6);
    try testing.expectApproxEqAbs(@as(f32, 334), flip_left.x, 0.01);

    // Viewport + safe_area clamping on live popover and floatingPanel.
    const SafeScene = struct {
        pop_tl: bool = true,
        pop_br: bool = true,
        panel: bool = true,
        tl_id: u64 = 0,
        br_id: u64 = 0,
        panel_id: u64 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            if (ui.popover(c, "tl", &s.pop_tl, .fromPoint(.{ .x = 2, .y = 2 }), .{ .placement = .top_start, .margin = 6 })) |p| {
                defer p.end();
                s.tl_id = p.panel_id;
                ui.div(c).w(90).h(40).end();
            }
            if (ui.popover(c, "br", &s.pop_br, .fromRect(.{ .x = 472, .y = 352, .w = 6, .h = 6 }), .{ .placement = .bottom_end, .margin = 6 })) |p| {
                defer p.end();
                s.br_id = p.panel_id;
                ui.div(c).w(110).h(50).end();
            }
            if (ui.floatingPanel(c, "fp", &s.panel, .{ .title = "Safe Panel", .width = 200, .margin = 12 })) |fp| {
                defer fp.end();
                s.panel_id = fp.panel_id;
                ui.text(c, "Inside safe area", .{});
            }
        }
    };

    var s: SafeScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SafeScene.view), .{ .width = 480, .height = 360, .scale = 1 });
    defer t.deinit();
    t.ctx.safe_area = .{ .top = 44, .bottom = 34, .left = 16, .right = 16 };
    t.ctx.reduced_motion = true;
    t.frame();

    const placed = ui.place(&t.ctx, .{ .x = 2, .y = 2, .w = 8, .h = 8 }, .{ .w = 100, .h = 50 }, .top_start, 6);
    try testing.expect(placed.x >= 16 - 0.01 and placed.y >= 44 - 0.01);

    for ([_]u64{ s.tl_id, s.br_id, s.panel_id }) |id| {
        const r = t.ctx.rects.get(id).?;
        try testing.expect(r.x >= 16 - 0.01);
        try testing.expect(r.x + r.w <= 480 - 16 + 0.01);
        try testing.expect(r.y >= 44 - 0.01);
        try testing.expect(r.y + r.h <= 360 - 34 + 0.01);
    }
}

test "zero-guess Frame 0 sizing with reduced_motion and immediate scroll tracking" {
    const FrameZeroScene = struct {
        open: bool = false,
        anchor_id: u64 = 0,
        be_id: u64 = 0,
        ts_id: u64 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            const trig = ui.div(c).fixed().offset(200, 170).w(80).h(32).control();
            const ix = trig.interaction();
            s.anchor_id = ix.id;
            trig.end();

            if (ui.popover(c, "be", &s.open, .from(ix), .{ .placement = .bottom_end, .padding = 10, .gap = 6 })) |p| {
                defer p.end();
                s.be_id = p.panel_id;
                ui.div(c).w(130).h(48).end();
            }
            if (ui.popover(c, "ts", &s.open, .fromId(s.anchor_id), .{ .placement = .top_start, .padding = 8, .gap = 7, .consume_outside = false })) |p| {
                defer p.end();
                s.ts_id = p.panel_id;
                ui.div(c).w(94).h(42).end();
            }
        }
    };

    var s: FrameZeroScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, FrameZeroScene.view), .{ .width = 480, .height = 360, .scale = 1 });
    defer t.deinit();

    // Open with reduced_motion and run a SINGLE frame: no prior entry in rects!
    t.ctx.reduced_motion = true;
    s.open = true;
    t.frame();

    const anchor_r = t.ctx.rects.get(s.anchor_id).?;
    const be_r = t.ctx.rects.get(s.be_id).?;
    const ts_r = t.ctx.rects.get(s.ts_id).?;

    try testing.expectApproxEqAbs(@as(f32, 150), be_r.w, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 68), be_r.h, 0.5);
    try testing.expectApproxEqAbs(anchor_r.x + anchor_r.w - be_r.w, be_r.x, 0.5);
    try testing.expectApproxEqAbs(anchor_r.y + anchor_r.h + 6, be_r.y, 0.5);

    try testing.expectApproxEqAbs(@as(f32, 110), ts_r.w, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 58), ts_r.h, 0.5);
    try testing.expectApproxEqAbs(anchor_r.x, ts_r.x, 0.5);
    try testing.expectApproxEqAbs(anchor_r.y - 7 - ts_r.h, ts_r.y, 0.5);

    // Scroll tracking: active overlay disables retained scroll so y updates at once.
    const ScrollScene = struct {
        open: bool = true,
        row_id: u64 = 0,
        pop_id: u64 = 0,

        fn view(sc: *@This(), c: *ui.Context) void {
            ui.scroll(c, .{ .width = .fill, .height = .fill });
            for (0..20) |i| {
                ui.keyInt(c, i);
                const r = ui.div(c).wFull().h(36);
                if (i == 3) sc.row_id = r.id();
                r.end();
            }
            ui.end(c);

            if (ui.popover(c, "row-pop", &sc.open, .fromId(sc.row_id), .{ .placement = .bottom_start, .padding = 8, .gap = 4, .consume_outside = false })) |p| {
                defer p.end();
                sc.pop_id = p.panel_id;
                ui.div(c).w(80).h(28).end();
            }
        }
    };

    var sc: ScrollScene = .{};
    var ts_tester: ui.Tester = undefined;
    try ts_tester.init(testing.allocator, .init(&sc, ScrollScene.view), .{ .width = 320, .height = 240, .scale = 1 });
    defer ts_tester.deinit();
    ts_tester.settle(1);

    const y0 = ts_tester.ctx.rects.get(sc.pop_id).?.y;
    ts_tester.scroll(280, 220, -40);
    try testing.expect(!ts_tester.ctx.stats.retained);
    try testing.expectApproxEqAbs(y0 - 40, ts_tester.ctx.rects.get(sc.pop_id).?.y, 0.5);
}

test "popover click-through prevention, exiting pass-through, and non-consumptive trigger toggle" {
    const ClickScene = struct {
        open: bool = false,
        consume_outside: bool = true,
        behind_clicks: u32 = 0,
        inner_clicks: u32 = 0,
        pop_id: u64 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            const trig = ui.button(c, "Trigger", .{});
            if (trig.clicked) s.open = !s.open;

            const behind = ui.div(c).wFull().grow().center().control();
            if (behind.clicked()) s.behind_clicks += 1;
            ui.text(c, "Behind", .{});
            behind.end();

            if (ui.popover(c, "pop", &s.open, .from(trig), .{
                .consume_outside = s.consume_outside,
                .dismiss_on_outside = true,
                .padding = 16,
            })) |p| {
                defer p.end();
                s.pop_id = p.panel_id;
                ui.text(c, "Popover Body", .{});
                if (ui.button(c, "Inner Action", .{}).clicked) s.inner_clicks += 1;
            }
        }
    };

    var s: ClickScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ClickScene.view), .{ .width = 420, .height = 320, .scale = 1 });
    defer t.deinit();

    s.open = true;
    t.settle(1);

    // Clicking inside popover padding/body and button keeps it open and never hits Behind.
    const pop_r = t.ctx.rects.get(s.pop_id).?;
    t.click(pop_r.x + 6, pop_r.y + 6);
    try t.clickText("Inner Action");
    try testing.expect(s.open);
    try testing.expectEqual(@as(u32, 1), s.inner_clicks);
    try testing.expectEqual(@as(u32, 0), s.behind_clicks);

    // Clicking outside right over "Behind" closes open == false AND consumes press + release.
    t.click(300, 260);
    try testing.expect(!s.open);
    try testing.expectEqual(@as(u32, 0), s.behind_clicks);
    try testing.expect(t.hasText("Popover Body")); // still mid-exit animation

    // Immediate click while fading out passes straight through to "Behind".
    t.click(300, 260);
    try testing.expectEqual(@as(u32, 1), s.behind_clicks);
    t.settle(1);
    try testing.expect(!t.hasText("Popover Body"));

    // With consume_outside = false, re-clicking Trigger closes cleanly without reopening.
    s.consume_outside = false;
    try t.clickText("Trigger");
    t.settle(1);
    try testing.expect(s.open);
    try t.clickText("Trigger");
    t.settle(1);
    try testing.expect(!s.open);
}

test "LIFO topmost Escape dismissal across floatingPanel, popover, and popupMenu" {
    const StackScene = struct {
        panel_open: bool = true,
        pop_open: bool = true,
        menu_open: bool = true,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            if (ui.floatingPanel(c, "panel", &s.panel_open, .{ .title = "Inspector" })) |fp| {
                defer fp.end();
                ui.text(c, "Panel Body", .{});
            }
            if (ui.popover(c, "pop", &s.pop_open, .fromPoint(.{ .x = 60, .y = 60 }), .{})) |p| {
                defer p.end();
                ui.text(c, "Popover Layer", .{});
            }
            if (ui.popupMenu(c, "menu", &s.menu_open, .fromPoint(.{ .x = 120, .y = 90 }), .{})) |m| {
                defer m.end();
                _ = m.item("Top Action", .{});
            }
        }
    };

    var s: StackScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, StackScene.view), .{ .width = 480, .height = 360, .scale = 1 });
    defer t.deinit();
    t.settle(1);

    // 1st Escape (Shortcut): only topmost popupMenu (layer 22) closes.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try testing.expect(!s.menu_open);
    try testing.expect(s.pop_open);
    try testing.expect(s.panel_open);

    // 2nd Escape (Shortcut): popover (layer 20) closes; floatingPanel (layer 18) stays open.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try testing.expect(!s.pop_open);
    try testing.expect(s.panel_open);

    // 3rd Escape (plain Key.escape path): floatingPanel closes.
    t.key(.escape);
    try testing.expect(!s.panel_open);
}

test "floatingPanel pass-through, clamped header drag with zero overshoot, reset, and close button" {
    const PanelScene = struct {
        panel_open: bool = true,
        behind_clicks: u32 = 0,
        panel_id: u64 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const behind = ui.div(c).sizeFull().control();
            if (behind.clicked()) s.behind_clicks += 1;
            behind.end();

            if (ui.floatingPanel(c, "inspector", &s.panel_open, .{
                .title = "Inspector",
                .width = 220,
                .margin = 12,
            })) |fp| {
                defer fp.end();
                s.panel_id = fp.panel_id;
                ui.text(c, "Opacity: 100%", .{});
            }
        }
    };

    var s: PanelScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, PanelScene.view), .{ .width = 640, .height = 420, .scale = 1 });
    defer t.deinit();
    t.ctx.safe_area = .{ .top = 44, .bottom = 34, .left = 16, .right = 16 };
    t.settle(1);

    // Outside click passes through to Behind while keeping floatingPanel open.
    t.click(60, 200);
    try testing.expectEqual(@as(u32, 1), s.behind_clicks);
    try testing.expect(s.panel_open);

    // Clicking inside the panel does NOT hit Behind.
    try t.clickText("Opacity: 100%");
    try testing.expectEqual(@as(u32, 1), s.behind_clicks);
    try testing.expect(s.panel_open);

    // Drag header by (-120, 90).
    const r0 = t.ctx.rects.get(s.panel_id).?;
    const h0 = t.findText("Inspector").?;
    t.drag(h0.x + 12, h0.y + h0.h / 2, h0.x + 12 - 120, h0.y + h0.h / 2 + 90);
    t.settle(0.3);
    const r1 = t.ctx.rects.get(s.panel_id).?;
    try testing.expectApproxEqAbs(r0.x - 120, r1.x, 1.0);
    try testing.expectApproxEqAbs(r0.y + 90, r1.y, 1.0);

    // Drag far past top-left safe_area + margin, then drag (+30, +20) with zero dead travel.
    const h1 = t.findText("Inspector").?;
    t.drag(h1.x + 12, h1.y + h1.h / 2, h1.x - 2000, h1.y - 2000);
    t.settle(0.2);
    const r_tl = t.ctx.rects.get(s.panel_id).?;
    try testing.expectApproxEqAbs(@as(f32, 16 + 12), r_tl.x, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 44 + 12), r_tl.y, 1.0);

    const h2 = t.findText("Inspector").?;
    t.drag(h2.x + 12, h2.y + h2.h / 2, h2.x + 12 + 30, h2.y + h2.h / 2 + 20);
    t.settle(0.2);
    const r_tl_back = t.ctx.rects.get(s.panel_id).?;
    try testing.expectApproxEqAbs(r_tl.x + 30, r_tl_back.x, 1.0);
    try testing.expectApproxEqAbs(r_tl.y + 20, r_tl_back.y, 1.0);

    // Drag far past bottom-right safe_area + margin, then back (-30, -20).
    const h3 = t.findText("Inspector").?;
    t.drag(h3.x + 12, h3.y + h3.h / 2, h3.x + 2000, h3.y + 2000);
    t.settle(0.2);
    const r_br = t.ctx.rects.get(s.panel_id).?;
    try testing.expectApproxEqAbs(640 - 16 - 12 - r_br.w, r_br.x, 1.0);
    try testing.expectApproxEqAbs(420 - 34 - 12 - r_br.h, r_br.y, 1.0);

    const h4 = t.findText("Inspector").?;
    t.drag(h4.x + 12, h4.y + h4.h / 2, h4.x + 12 - 30, h4.y + h4.h / 2 - 20);
    t.settle(0.2);
    const r_br_back = t.ctx.rects.get(s.panel_id).?;
    try testing.expectApproxEqAbs(r_br.x - 30, r_br_back.x, 1.0);
    try testing.expectApproxEqAbs(r_br.y - 20, r_br_back.y, 1.0);

    // Reset offset restores initial corner placement.
    ui.resetFloatingPanelOffset(&t.ctx, "inspector");
    t.settle(0.2);
    const r_reset = t.ctx.rects.get(s.panel_id).?;
    try testing.expectApproxEqAbs(r0.x, r_reset.x, 1.0);
    try testing.expectApproxEqAbs(r0.y, r_reset.y, 1.0);

    // Clicking the header close button dismisses the panel.
    const close_r = findCloseButton(&t, s.panel_id).?;
    t.click(close_r.x + close_r.w / 2, close_r.y + close_r.h / 2);
    try testing.expect(!s.panel_open);
    try testing.expectEqual(@as(u32, 1), s.behind_clicks);
}

test "higher-layer sibling popupMenu and its scrim do not prematurely close non-consumptive floatingPanel" {
    const SiblingScene = struct {
        panel_open: bool = true,
        menu_open: bool = true,
        picked: u32 = 0,
        behind_clicks: u32 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const behind = ui.div(c).sizeFull().control();
            if (behind.clicked()) s.behind_clicks += 1;
            behind.end();

            if (ui.floatingPanel(c, "inspector", &s.panel_open, .{
                .title = "Inspector",
                .width = 200,
                .dismiss_on_outside = true,
                .consume_outside = false,
            })) |panel| {
                defer panel.end();
                ui.text(c, "Panel Body", .{});
            }

            if (ui.popupMenu(c, "sibling-menu", &s.menu_open, .fromPoint(.{ .x = 32, .y = 32 }), .{})) |m| {
                defer m.end();
                if (m.item("Menu Action", .{})) s.picked += 1;
            }
        }
    };

    var s: SiblingScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SiblingScene.view), .{ .width = 520, .height = 360, .scale = 1 });
    defer t.deinit();
    t.settle(1);

    // Clicking an item in the sibling popupMenu (layer 22) selects it and closes
    // popupMenu while keeping the lower-layer floatingPanel (layer 18) open.
    try t.clickText("Menu Action");
    t.settle(1);
    try testing.expectEqual(@as(u32, 1), s.picked);
    try testing.expect(!s.menu_open);
    try testing.expect(s.panel_open);
    try testing.expectEqual(@as(u32, 0), s.behind_clicks);

    // Reopen popupMenu and click outside both overlays: popupMenu's scrim (layer 21)
    // closes popupMenu first without closing floatingPanel or clicking Behind.
    s.menu_open = true;
    t.settle(1);
    t.click(40, 320);
    t.settle(1);
    try testing.expect(!s.menu_open);
    try testing.expect(s.panel_open);
    try testing.expectEqual(@as(u32, 0), s.behind_clicks);

    // Clicking outside again with popupMenu closed now dismisses floatingPanel.
    t.click(40, 320);
    try testing.expect(!s.panel_open);
    try testing.expectEqual(@as(u32, 1), s.behind_clicks);
}
