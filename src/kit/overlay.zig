//! What opens over the page, on a layer: tooltips after the pointer rests
//! on something, popovers anchored to what opened them (placed where they
//! fit, closed by Escape or a click elsewhere), and menus made of them.
//! Each comes and goes with `ui.motion` presence.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const popover_mod = @import("../ui/popover.zig");
const menu_popup = @import("../ui/menu_popup.zig");
const kit = @import("kit.zig");
const motion = ui.motion;

/// Layers: popovers and menus, then tooltips over them.
pub const layer_popover = 20;
pub const layer_tooltip = 30;

pub const Placement = ui.Placement;

/// Where a panel `size` goes beside `anchor` at `placement`, turned to the
/// other side and kept in the window when it would leave it.
pub fn place(c: *ui.Context, anchor: ui.Rect, size: ui.Size, placement: Placement, gap: f32) ui.Point {
    return ui.placeBounds(.{ .x = 0, .y = 0, .w = c.size.w, .h = c.size.h }, anchor, size, placement, gap, 6);
}

/// A label that appears over `trigger` once the pointer has rested on it
/// for half a second, and goes when it leaves.
pub fn tooltip(c: *ui.Context, trigger: ui.Interaction, text: []const u8, opts: struct { placement: Placement = .top, delay: f32 = 0.5 }) void {
    const t = kit.tokens(c);
    const key = c.print("tip-{x}", .{trigger.id});
    // How long the pointer has rested, as a number climbing to 1.
    const rested = motion.number(c, key, if (trigger.hovered and !trigger.pressed) 1 else 0, if (trigger.hovered) .{ .tween = .{ .duration = opts.delay, .ease = .linear } } else .instant);
    const anchor = trigger.rect orelse return;
    const show = trigger.hovered and rested >= 0.999;
    const f = motion.present(c, key, show, .{ .initial = .{ .opacity = 0, .scale = 0.96 }, .exit = .{ .opacity = 0 }, .transition = .{ .tween = .{ .duration = 0.12 } } }) orelse return;
    const id = c.peekId(null);
    const size = if (c.rects.get(id)) |r| ui.Size{ .w = r.w, .h = r.h } else ui.Size{ .w = 8 * @as(f32, @floatFromInt(text.len)), .h = 24 };
    const at = place(c, anchor, size, opts.placement, 6);
    const d = ui.div(c).fixed().offset(at.x, at.y).layer(layer_tooltip).px(8).py(4).rounded(6).bg(t.foreground).shadow(.{ .color = t.shadow.alpha(0.5), .blur = 8, .y = 2 }).motion(f);
    defer d.end();
    ui.text(c, text, .{ .size = 11.5, .color = t.background });
}

pub const PopoverOptions = struct {
    placement: Placement = .bottom_start,
    width: ?f32 = null,
    /// Space around what's in it.
    padding: f32 = 12,
    gap: f32 = 6,
    /// A click outside closes it.
    dismissable: bool = true,
    /// A pane of Liquid Glass, as macOS 26's menus are.
    glass: bool = false,
};

/// An open popover: draw what's in it, then `end`.
pub const Popover = struct {
    div: ui.Div,
    pub fn end(p: Popover) void {
        p.div.end();
    }
};

/// A panel by `anchor` while `open.*`: Escape or a click outside it sets
/// `open.*` false; it fades out from there.
pub fn popover(c: *ui.Context, id: []const u8, open: *bool, anchor: ?ui.Rect, opts: PopoverOptions) ?Popover {
    const t = kit.tokens(c);
    c.next_key = id;
    const panel_id = c.peekId(null);
    c.next_key = null;
    if (c.overlay.takeDismissed(panel_id)) {
        open.* = false;
        c.changed = true;
    }
    if (open.* and opts.dismissable) {
        c.overlay.offerEscape(panel_id, layer_popover);
        _ = popover_mod.outsideScrim(c, c.print("kit:scrim:{s}", .{id}), popover_mod.layer_popover_scrim, open);
    }
    const f = motion.present(c, id, open.*, .{
        .initial = .{ .opacity = 0, .scale = 0.97, .y = -4 },
        .exit = .{ .opacity = 0, .scale = 0.98 },
        .transition = .{ .spring = motion.Spring.snappy },
    }) orelse return null;
    const bounds = popover_mod.viewportBounds(c);
    const max_h = @max(48, bounds.h - 12);
    c.next_key = id;
    var d = ui.div(c).fixed().offset(0, 0).layer(layer_popover).column().gap(2).p(opts.padding).maxH(max_h).scrollY().rounded(t.radius + 2).shadow(.{ .color = t.shadow.alpha(0.9), .blur = 24, .y = 8 });
    d = if (opts.glass) d.rounded(t.radius + 8).glass(.{}) else d.bg(t.popover).border(t.border);
    if (opts.width) |w| d = d.w(w);
    if (open.*) {
        d = d.occlude();
        c.overlay.noteLayer(c.gpa, panel_id, layer_popover);
    }
    const anc: ui.Anchor = if (anchor) |r| ui.Anchor.fromRect(r) else ui.Anchor.fromPoint(.{ .x = c.size.w / 2, .y = c.size.h / 2 });
    c.overlay.deferArrange(c.gpa, .{
        .node_index = d.index,
        .anchor = anc,
        .placement = opts.placement,
        .gap = opts.gap,
        .margin = 6,
    });
    return .{ .div = d.motion(f) };
}

pub const MenuItem = struct {
    label: []const u8 = "",
    icon: []const u8 = "",
    /// A shortcut's text, shown at the right ("⌘C").
    shortcut: []const u8 = "",
    danger: bool = false,
    disabled: bool = false,
    /// A checkmark when true; room for one when false.
    checked: ?bool = null,
    /// A line between groups (the rest is ignored).
    separator: bool = false,
};

const KitMenuState = struct {
    hot: i16 = -1,
    was_open: bool = false,
};

/// A menu by `anchor` while `open.*`; the index of the item chosen (and
/// then it closes).
pub fn menu(c: *ui.Context, id: []const u8, open: *bool, anchor: ?ui.Rect, items: []const MenuItem, opts: struct { placement: Placement = .bottom_start, width: f32 = 220, glass: bool = false }) ?usize {
    const t = kit.tokens(c);
    const saved_key = c.next_key;
    c.next_key = id;
    const st = c.state(KitMenuState, c.print("kit:menu:{s}", .{id}));
    c.next_key = saved_key;
    const p = popover(c, id, open, anchor, .{ .placement = opts.placement, .width = opts.width, .padding = if (opts.glass) 7 else 5, .glass = opts.glass }) orelse {
        st.was_open = false;
        st.hot = -1;
        return null;
    };
    defer p.end();
    const live = open.*;
    if (live and !st.was_open) {
        st.was_open = true;
        st.hot = -1;
    } else if (!live) {
        st.was_open = false;
        st.hot = -1;
    }
    const enabled = c.alloc().alloc(bool, items.len) catch @panic("OOM");
    for (items, 0..) |it, i| {
        enabled[i] = !it.separator and !it.disabled;
    }
    var nav_activate: ?usize = null;
    if (live) {
        const nav = menu_popup.stepMenuKeyboard(c, st.hot, enabled);
        st.hot = @intCast(nav.index);
        if (nav.moved) {
            c.keyboard_modality = true;
            c.changed = true;
        }
        if (nav.activate and nav.index >= 0) nav_activate = @intCast(nav.index);
        if (!c.keyboard_modality) st.hot = -1;
    }
    var chosen: ?usize = null;
    const checks = for (items) |it| {
        if (it.checked != null) break true;
    } else false;
    for (items, 0..) |it, i| {
        ui.key(c, c.print("mi-{d}", .{i}));
        if (it.separator) {
            const s = ui.div(c).wFull().py(4);
            defer s.end();
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
            continue;
        }
        const row = ui.div(c).row().wFull().gap(8).px(8).h(30).itemsCenter().rounded(t.radius - 2).control();
        const ix: ui.Interaction = if (live) blk: {
            const inter = row.interaction();
            c.addA11y(row.index, .button, it.label, it.shortcut, it.checked orelse false, !it.disabled);
            break :blk inter;
        } else .{
            .id = c.node(row.index).id,
            .rect = null,
            .hovered = false,
            .pressed = false,
            .clicked = false,
            .focused = false,
        };
        if (live and !it.disabled and !c.keyboard_modality and ix.hovered) st.hot = @intCast(i);
        const is_hot = live and !it.disabled and (st.hot == @as(i16, @intCast(i)) or (!c.keyboard_modality and ix.hovered));
        if (is_hot) c.node(row.index).style.background = if (it.danger) t.danger.alpha(0.12) else t.surface_hover;
        if (it.disabled) c.node(row.index).style.opacity = 0.45;
        defer row.end();
        const fg = if (it.danger) t.danger else t.foreground;
        if (checks) {
            const box = ui.div(c).w(14).center();
            defer box.end();
            if (it.checked orelse false) ui.icon(c, "checkmark", .{ .size = 11, .weight = .semibold, .color = fg });
        }
        if (it.icon.len > 0) ui.icon(c, it.icon, .{ .size = 13, .frame = 16, .color = if (it.danger) t.danger else t.muted });
        ui.text(c, it.label, .{ .size = 13, .color = fg });
        ui.spacer(c);
        if (it.shortcut.len > 0) ui.text(c, it.shortcut, .{ .size = 11.5, .color = t.muted });
        if (live and !it.disabled and (ix.clicked or nav_activate == i)) chosen = i;
    }
    if (st.hot >= @as(i16, @intCast(items.len)) or (st.hot >= 0 and !enabled[@intCast(st.hot)])) {
        st.hot = -1;
    }
    if (chosen != null) {
        open.* = false;
        st.was_open = false;
        st.hot = -1;
        c.changed = true;
    }
    return chosen;
}

test "a panel goes where it fits" {
    var ctx: ui.Context = undefined;
    ctx.size = .{ .w = 400, .h = 300 };
    const below = place(&ctx, .{ .x = 10, .y = 10, .w = 80, .h = 30 }, .{ .w = 120, .h = 100 }, .bottom_start, 6);
    try std.testing.expectEqual(ui.Point{ .x = 10, .y = 46 }, below);
    // Near the bottom: above instead.
    const above = place(&ctx, .{ .x = 10, .y = 250, .w = 80, .h = 30 }, .{ .w = 120, .h = 100 }, .bottom_start, 6);
    try std.testing.expectEqual(@as(f32, 144), above.y);
    // Near the right edge: kept in the window.
    const kept = place(&ctx, .{ .x = 380, .y = 10, .w = 20, .h = 20 }, .{ .w = 120, .h = 40 }, .bottom_start, 6);
    try std.testing.expectEqual(@as(f32, 274), kept.x);
}
