//! Foundations page for 2D CSS-style Grid layout: fractional (`fr`), `fixed`
//! and `auto` tracks, multi-track `rowSpan` / `colSpan` bento layouts with
//! `ui.motion` rect projection, inspector form alignment, and seam-free
//! pixel-snapped shared borders.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const page = @import("page.zig");
const phone = @import("phone.zig");

pub const Demo = struct {
    wide_hero: bool = true,
    swap_lead: bool = false,
    dense_gap: bool = false,

    pub fn view(d: *Demo, c: *ui.Context) void {
        page.begin(c, "Grid", "ui.div(c).grid(cols, rows) · .gridArea(r, c, rs, cs)  ·  src/ui/layout_grid.zig", .of(d, headerActions));
        defer page.end(c);

        d.bentoSection(c);
        d.inspectorSection(c);
        d.sharedBorderSection(c);
    }

    fn headerActions(d: *Demo, c: *ui.Context) void {
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        if (kit.button(c, if (d.wide_hero) "Span 2×2" else "Span 1×1", .{ .variant = .secondary, .size = .sm }).clicked) {
            d.wide_hero = !d.wide_hero;
            c.changed = true;
        }
        if (kit.button(c, "Swap tracks", .{ .variant = .secondary, .size = .sm }).clicked) {
            d.swap_lead = !d.swap_lead;
            c.changed = true;
        }
    }

    fn bentoSection(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const sec = page.section(c, "Bento spans & motion projection");
        defer sec.end();
        page.note(c, "Toggle Span 2×2 or Swap tracks: ui.motion projects both position and spanned track size.");

        const compact = phone.compact(c);
        const gap: f32 = if (d.dense_gap) 6 else 12;
        const cols: []const ui.Track = if (compact)
            &.{ .{ .fr = 1 }, .{ .fr = 1 } }
        else
            &.{ .{ .fr = 1.2 }, .{ .fr = 1 }, .{ .fr = 1 } };
        const rows: []const ui.Track = &.{ .{ .fixed = 86 }, .{ .fixed = 86 } };

        const g = ui.div(c).grid(cols, rows).wFull().gap(gap);
        defer g.end();

        {
            ui.key(c, "bento-hero");
            const f = motion.frame(c, .{ .layout = true });
            const cs: u16 = if (d.wide_hero) 2 else 1;
            const rs: u16 = if (d.wide_hero and !compact) 2 else 1;
            var card = ui.div(c).column().p(14).gap(6).rounded(12).bg(th.accent.alpha(0.14)).border(th.accent.alpha(0.45)).rowSpan(rs).colSpan(cs);
            if (d.swap_lead and !compact) {
                card = if (d.wide_hero) card.gridCell(0, 1) else card.gridCell(1, 2);
            }
            card = card.motion(f);
            defer card.end();
            ui.text(c, "Throughput", .{ .size = 12, .weight = .semibold, .color = th.accent });
            ui.text(c, "1.42M ops/s", .{ .size = 20, .weight = .bold });
            ui.text(c, "Spans fractional tracks and glides smoothly when resized.", .{ .size = 12, .color = th.muted, .wrap = true });
        }

        const metrics = [_]struct { key: []const u8, label: []const u8, val: []const u8 }{
            .{ .key = "bento-lat", .label = "Frame p95", .val = "0.18 ms" },
            .{ .key = "bento-mem", .label = "Arena", .val = "24 KB" },
            .{ .key = "bento-gpu", .label = "Batches", .val = "1 pass" },
            .{ .key = "bento-hit", .label = "Cache hit", .val = "99.4%" },
            .{ .key = "bento-idl", .label = "Idle CPU", .val = "0.0%" },
        };
        for (metrics) |m| {
            ui.key(c, m.key);
            const f = motion.frame(c, .{ .layout = true });
            const tile = ui.div(c).column().p(14).justifyBetween().rounded(12).bg(th.surface).border(th.border).motion(f);
            defer tile.end();
            ui.text(c, m.label, .{ .size = 12, .color = th.muted });
            ui.text(c, m.val, .{ .size = 17, .weight = .semibold, .mono = true });
        }
    }

    fn inspectorSection(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const sec = page.section(c, "Synchronized fixed + fr + auto tracks");
        defer sec.end();
        page.note(c, "Labels share an intrinsic auto column, descriptions wrap in 1fr, and controls align in a trailing auto column.");

        const cols = [_]ui.Track{ .auto, .{ .fr = 1 }, .auto };
        const card = ui.div(c).gridCols(&cols).wFull().p(16).colGap(16).rowGap(12).itemsCenter().rounded(12).bg(th.surface).border(th.border);
        defer card.end();

        ui.text(c, "Compact gutters", .{ .weight = .medium });
        ui.text(c, "Tighten inter-track spacing across the bento preview above.", .{ .size = 12.5, .color = th.muted, .wrap = true });
        _ = ui.toggle(c, "", &d.dense_gap);

        ui.text(c, "Hero span", .{ .weight = .medium });
        ui.text(c, "Expand the primary metric across two columns and two rows.", .{ .size = 12.5, .color = th.muted, .wrap = true });
        _ = ui.toggle(c, "", &d.wide_hero);
    }

    fn sharedBorderSection(_: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const sec = page.section(c, "Zero-gap shared track edges");
        defer sec.end();
        page.note(c, "Cumulative track boundaries snap together so spanning headers and cells share exact edges.");

        const cols = [_]ui.Track{ .{ .fixed = 96 }, .{ .fr = 1 }, .{ .fr = 1 }, .{ .fr = 1 } };
        const outer = ui.div(c).wFull().rounded(10).clip().border(th.border);
        defer outer.end();

        const g = ui.div(c).gridCols(&cols).wFull().gap(0);
        defer g.end();

        cell(c, "Region", true, 1, th.surface_hover);
        cell(c, "Q1 – Q3 Window (colSpan 3)", true, 3, th.surface_hover);

        const rows = [_][4][]const u8{
            .{ "us-west", "0.14 ms", "0.15 ms", "0.13 ms" },
            .{ "eu-central", "0.19 ms", "0.18 ms", "0.17 ms" },
        };
        for (rows) |r| {
            for (r, 0..) |txt, i| cell(c, txt, i == 0, 1, th.surface);
        }
    }

    fn cell(c: *ui.Context, txt: []const u8, bold: bool, span: u16, bg: ui.Color) void {
        const th = c.theme;
        const box = ui.div(c).colSpan(span).px(12).py(9).bg(bg).border(th.border);
        defer box.end();
        ui.text(c, txt, .{
            .size = 12.5,
            .weight = if (bold) .semibold else .regular,
            .mono = !bold,
        });
    }
};
