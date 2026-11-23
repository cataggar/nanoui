//! Immediate-mode anchored popup menus (`popupMenu`) and button-triggered
//! dropdown menus (`dropdownMenu`), with keyboard navigation shared by
//! `kit.menu`.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const input_mod = @import("input.zig");
const widgets = @import("widgets.zig");
const div_mod = @import("div.zig");
const popover = @import("popover.zig");

const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;
const Shortcut = input_mod.Shortcut;
const Color = types.Color;

pub const MenuItemOptions = struct {
    icon: []const u8 = "",
    shortcut: []const u8 = "",
    danger: bool = false,
    disabled: bool = false,
    close_on_select: bool = true,
};

pub const PopupMenuOptions = struct {
    placement: popover.Placement = .bottom_start,
    width: ?f32 = 220,
    min_width: f32 = 160,
    max_width: f32 = 340,
    max_height: ?f32 = null,
    gap: f32 = 6,
    margin: f32 = 6,
    consume_outside: bool = true,
    glass: bool = false,
};

pub const DropdownOptions = struct {
    variant: widgets.ButtonVariant = .secondary,
    width: types.Length = .auto,
    size: f32 = 14,
    disabled: bool = false,
    icon: []const u8 = "",
    chevron: bool = true,
    menu: PopupMenuOptions = .{},
};

pub const NavStep = struct {
    index: i32,
    moved: bool = false,
    activate: bool = false,
};

fn firstEnabled(enabled: []const bool) ?i32 {
    for (enabled, 0..) |ok, i| if (ok) return @intCast(i);
    return null;
}

fn lastEnabled(enabled: []const bool) ?i32 {
    var i = enabled.len;
    while (i > 0) {
        i -= 1;
        if (enabled[i]) return @intCast(i);
    }
    return null;
}

fn nextEnabled(enabled: []const bool, current: i32) ?i32 {
    const n = enabled.len;
    if (n == 0) return null;
    const start: usize = if (current < 0 or @as(usize, @intCast(current)) >= n) 0 else (@as(usize, @intCast(current)) + 1) % n;
    for (0..n) |step| {
        const k = (start + step) % n;
        if (enabled[k]) return @intCast(k);
    }
    return null;
}

fn prevEnabled(enabled: []const bool, current: i32) ?i32 {
    const n = enabled.len;
    if (n == 0) return null;
    const start: usize = if (current < 0 or @as(usize, @intCast(current)) >= n) n - 1 else (@as(usize, @intCast(current)) + n - 1) % n;
    for (0..n) |step| {
        const k = (start + n - step) % n;
        if (enabled[k]) return @intCast(k);
    }
    return null;
}

fn takeSpace(c: *Context) bool {
    if (popover.takeKey(c, ' ', null)) return true;
    if (!c.input.cmd and !c.input.ctrl and !c.input.alt and std.mem.eql(u8, c.input.chars, " ")) {
        c.input.chars = "";
        c.changed = true;
        return true;
    }
    return false;
}

/// Steps keyboard highlight (`Up`/`Down`/`Home`/`End` with wrap-around over
/// enabled items) and checks `Enter`/`Space` activation on the highlighted item.
pub fn stepMenuKeyboard(c: *Context, current: i32, enabled: []const bool) NavStep {
    if (popover.takeKey(c, Shortcut.down, .down)) {
        const idx = nextEnabled(enabled, current) orelse return .{ .index = -1 };
        c.changed = true;
        return .{ .index = idx, .moved = true };
    }
    if (popover.takeKey(c, Shortcut.up, .up)) {
        const idx = prevEnabled(enabled, current) orelse return .{ .index = -1 };
        c.changed = true;
        return .{ .index = idx, .moved = true };
    }
    if (popover.takeKey(c, Shortcut.home, .home)) {
        const idx = firstEnabled(enabled) orelse return .{ .index = -1 };
        c.changed = true;
        return .{ .index = idx, .moved = true };
    }
    if (popover.takeKey(c, Shortcut.end, .end)) {
        const idx = lastEnabled(enabled) orelse return .{ .index = -1 };
        c.changed = true;
        return .{ .index = idx, .moved = true };
    }
    if (current >= 0 and @as(usize, @intCast(current)) < enabled.len and enabled[@intCast(current)]) {
        if (popover.takeKey(c, Shortcut.enter, .enter) or takeSpace(c)) {
            c.changed = true;
            return .{ .index = current, .activate = true };
        }
    }
    return .{ .index = current };
}

const PersistState = struct {
    hot: i32 = -1,
    was_open: bool = false,
    has_checks: bool = false,
};

comptime {
    std.debug.assert(@sizeOf(PersistState) <= 16);
}

const DeferredNav = enum { none, down, up, home, end };

const BuildState = struct {
    enabled: std.ArrayList(bool) = .empty,
    count: u32 = 0,
    sep_count: u32 = 0,
    activate_idx: i32 = -1,
    deferred_nav: DeferredNav = .none,
    has_checks: bool = false,
    close_after: bool = false,
};

/// An open popup menu: emit items, separators, and section labels, then `end`.
pub const PopupMenu = struct {
    c: *Context,
    pop: popover.Popover,
    open: *bool,
    live: bool,
    menu_key: u64,
    persist: *PersistState,
    build: *BuildState,

    pub fn item(m: PopupMenu, title: []const u8, opts: MenuItemOptions) bool {
        return m.rowItem(title, null, opts);
    }

    pub fn checkboxItem(m: PopupMenu, title: []const u8, checked: *bool, opts: MenuItemOptions) bool {
        return m.rowItem(title, checked, opts);
    }

    fn rowItem(m: PopupMenu, title: []const u8, checked: ?*bool, opts: MenuItemOptions) bool {
        const idx = m.build.count;
        m.build.count +|= 1;
        m.build.enabled.append(m.c.alloc(), !opts.disabled) catch {};
        const is_checkbox = checked != null;
        if (is_checkbox) m.build.has_checks = true;

        widgets.key(m.c, m.c.print("mi-{d}", .{idx}));
        const row = div_mod.div(m.c).row().wFull().gap(8).px(8).h(30).itemsCenter().rounded(6).control();
        const ix: Interaction = if (m.live) row.interaction() else .{
            .id = m.c.node(row.index).id,
            .rect = null,
            .hovered = false,
            .pressed = false,
            .clicked = false,
            .focused = false,
        };

        const idx_i32: i32 = @intCast(@min(idx, @as(u32, std.math.maxInt(i32))));
        const fired = m.live and !opts.disabled and (ix.clicked or m.build.activate_idx == idx_i32);
        if (fired) {
            if (checked) |p| p.* = !p.*;
            if (opts.close_on_select) m.build.close_after = true;
            m.c.changed = true;
        }
        const checked_val = if (checked) |p| p.* else false;
        if (m.live) m.c.addA11y(row.index, .button, title, opts.shortcut, checked_val, !opts.disabled);

        if (m.live and !opts.disabled and !m.c.keyboard_modality and ix.hovered) m.persist.hot = idx_i32;
        const is_hot = m.live and !opts.disabled and (m.persist.hot == idx_i32 or (!m.c.keyboard_modality and ix.hovered));
        if (is_hot) m.c.node(row.index).style.background = if (opts.danger) m.c.theme.danger.alpha(0.14) else m.c.theme.surface_hover;
        if (opts.disabled) m.c.node(row.index).style.opacity = 0.45;

        const fg = if (opts.danger) m.c.theme.danger else m.c.theme.text;
        if (m.persist.has_checks or m.build.has_checks or is_checkbox) {
            const box = div_mod.div(m.c).w(14).center();
            if (checked_val) widgets.icon(m.c, "checkmark", .{ .size = 11, .weight = .semibold, .color = fg });
            box.end();
        }
        if (opts.icon.len > 0) widgets.icon(m.c, opts.icon, .{ .size = 13, .frame = 16, .color = if (opts.danger) m.c.theme.danger else m.c.theme.muted });
        widgets.text(m.c, title, .{ .size = 13, .color = fg });
        widgets.spacer(m.c);
        if (opts.shortcut.len > 0) widgets.text(m.c, opts.shortcut, .{ .size = 11.5, .color = m.c.theme.muted });
        row.end();
        return fired;
    }

    pub fn separator(m: PopupMenu) void {
        widgets.key(m.c, m.c.print("ms-{d}", .{m.build.sep_count}));
        m.build.sep_count +|= 1;
        const s = div_mod.div(m.c).wFull().py(4);
        defer s.end();
        _ = m.c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = m.c.theme.border }, .none, null);
    }

    pub fn label(m: PopupMenu, heading: []const u8) void {
        widgets.key(m.c, m.c.print("ml-{d}", .{m.build.sep_count}));
        m.build.sep_count +|= 1;
        const r = div_mod.div(m.c).row().wFull().px(8).py(4).itemsCenter();
        defer r.end();
        widgets.text(m.c, heading, .{ .size = 11, .weight = .semibold, .color = m.c.theme.muted });
    }

    pub fn end(m: PopupMenu) void {
        if (m.persist.has_checks != m.build.has_checks) {
            m.persist.has_checks = m.build.has_checks;
            m.c.changed = true;
        }
        const items = m.build.enabled.items;
        if (m.live and !m.build.close_after) {
            m.c.overlay.recordMenuEnabled(m.c.gpa, m.menu_key, items);
        }

        if (m.build.deferred_nav != .none and items.len > 0) {
            const next: ?i32 = switch (m.build.deferred_nav) {
                .none => null,
                .down => nextEnabled(items, m.persist.hot),
                .up => prevEnabled(items, m.persist.hot),
                .home => firstEnabled(items),
                .end => lastEnabled(items),
            };
            m.persist.hot = next orelse -1;
            m.c.keyboard_modality = true;
            m.c.changed = true;
        }

        if (m.persist.hot < 0 or @as(usize, @intCast(m.persist.hot)) >= items.len or !items[@intCast(m.persist.hot)]) {
            m.persist.hot = -1;
        }

        if (m.build.close_after) {
            m.open.* = false;
            m.persist.was_open = false;
            m.persist.hot = -1;
            m.c.changed = true;
        }
        m.pop.end();
    }
};

/// Opens an anchored popup menu while `open.*` (fading out on close).
pub fn popupMenu(c: *Context, id: []const u8, open: *bool, anchor: popover.Anchor, opts: PopupMenuOptions) ?PopupMenu {
    const menu_key = std.hash.Wyhash.hash(0x706d656e75, id);
    const saved_key = c.next_key;
    c.next_key = id;
    const persist = c.state(PersistState, c.print("nanoui:pmenu:{s}", .{id}));
    c.next_key = saved_key;

    const pop = popover.popover(c, id, open, anchor, .{
        .placement = opts.placement,
        .width = opts.width,
        .min_width = opts.min_width,
        .max_width = opts.max_width,
        .max_height = opts.max_height,
        .padding = if (opts.glass) 7 else 5,
        .radius = if (opts.glass) 14 else 10,
        .gap = opts.gap,
        .margin = opts.margin,
        .layer = popover.layer_menu,
        .scrim_layer = popover.layer_menu_scrim,
        .dismiss_on_outside = true,
        .consume_outside = opts.consume_outside,
        .dismiss_on_escape = true,
        .glass = opts.glass,
    }) orelse {
        persist.was_open = false;
        persist.hot = -1;
        return null;
    };
    c.node(pop.div.index).style.gap = 2;

    const live = open.*;
    const just_opened = live and !persist.was_open;
    if (just_opened) {
        persist.was_open = true;
        persist.hot = -1;
    } else if (!live) {
        persist.was_open = false;
        persist.hot = -1;
    }

    const build = c.alloc().create(BuildState) catch @panic("OOM");
    build.* = .{};

    if (live) {
        const prev_enabled: []const bool = if (just_opened) &.{} else c.overlay.prevMenuEnabled(menu_key);
        if (prev_enabled.len > 0) {
            const nav = stepMenuKeyboard(c, persist.hot, prev_enabled);
            persist.hot = nav.index;
            if (nav.moved) c.keyboard_modality = true;
            if (nav.activate) build.activate_idx = nav.index;
        } else if (popover.takeKey(c, Shortcut.down, .down)) {
            build.deferred_nav = .down;
        } else if (popover.takeKey(c, Shortcut.up, .up)) {
            build.deferred_nav = .up;
        } else if (popover.takeKey(c, Shortcut.home, .home)) {
            build.deferred_nav = .home;
        } else if (popover.takeKey(c, Shortcut.end, .end)) {
            build.deferred_nav = .end;
        }
        if (!c.keyboard_modality and build.deferred_nav == .none) persist.hot = -1;
    }

    return .{ .c = c, .pop = pop, .open = open, .live = live, .menu_key = menu_key, .persist = persist, .build = build };
}

const DropState = struct {
    open: bool = false,
    suppress_toggle: bool = false,
};

fn drawTrigger(c: *Context, key_str: []const u8, title: []const u8, open: bool, opts: DropdownOptions) Interaction {
    const th = c.theme;
    c.next_key = key_str;
    const i = c.open(.{
        .direction = .row,
        .width = opts.width,
        .padding = .xy(opts.size, opts.size * 0.5),
        .gap = opts.size * 0.4,
        .radius = 8,
        .align_items = .center,
        .justify = .center,
        .opacity = if (opts.disabled) 0.45 else 1,
        .control = true,
    }, null);
    defer c.end();
    var it = c.interact(i, .{ .focusable = !opts.disabled and !open });
    if (!opts.disabled and open) c.focusable_ids.append(c.gpa, it.id) catch {};
    c.addA11y(i, .button, if (title.len > 0) title else opts.icon, "", open, !opts.disabled);
    if (opts.disabled) {
        it.clicked = false;
        it.hovered = false;
        it.pressed = false;
    }
    const hover = c.animate(it.id, 0, if (it.hovered or open) 1 else 0, 20);
    const press = c.animate(it.id, 1, if (it.pressed) 1 else 0, 30);
    const n = c.node(i);
    var fg = th.text;
    switch (opts.variant) {
        .primary, .danger => {
            const base = if (opts.variant == .primary) th.accent else th.danger;
            n.style.background = base.mix(th.accent_hover, hover * 0.6).mix(Color.black, press * 0.15);
            fg = th.accent_text;
        },
        .secondary => {
            n.style.background = th.surface.mix(th.surface_hover, hover).mix(th.border, press * 0.5);
            n.style.border = th.border;
            n.style.shadow = .{ .color = th.shadow.alpha(0.5), .blur = 2, .y = 1 };
        },
        .ghost => {
            n.style.background = th.surface_hover.alpha(hover).mix(th.border, press * 0.5);
        },
    }
    if (!opts.disabled and open and c.focus == it.id) if (c.focus_ring) |ring| {
        n.style.border = ring.color;
        n.style.border_width = ring.width;
    };
    n.style.offset.y = press * 0.5;
    if (opts.icon.len > 0) widgets.icon(c, opts.icon, .{ .size = opts.size, .weight = .medium, .color = fg });
    if (title.len > 0) widgets.text(c, title, .{ .size = opts.size, .weight = .medium, .color = fg });
    if (opts.chevron) widgets.icon(c, "chevron.down", .{
        .size = @max(10, opts.size * 0.78),
        .weight = .semibold,
        .color = if (opts.variant == .primary or opts.variant == .danger) fg else th.muted,
    });
    return it;
}

/// Draws a trigger button with optional icon and chevron, managing open/close
/// state internally and returning the open `PopupMenu` when active.
pub fn dropdownMenu(c: *Context, id: []const u8, title: []const u8, opts: DropdownOptions) ?PopupMenu {
    const saved_key = c.next_key;
    c.next_key = id;
    const st = c.state(DropState, c.print("nanoui:dd:{s}", .{id}));
    c.next_key = saved_key;

    if (opts.disabled) {
        st.open = false;
        st.suppress_toggle = false;
    }
    if (!c.input.down and !c.input.released) {
        st.suppress_toggle = false;
    }

    const trig_ix = drawTrigger(c, c.print("{s}:trigger", .{id}), title, st.open, opts);
    if (!opts.disabled) {
        if (trig_ix.clicked) {
            if (st.suppress_toggle) {
                st.suppress_toggle = false;
            } else {
                st.open = !st.open;
                c.changed = true;
            }
        } else if (c.focus == trig_ix.id and !st.open) {
            if (popover.takeKey(c, Shortcut.down, .down)) {
                st.open = true;
                c.changed = true;
            }
        }
    }

    const was_open = st.open;
    const m = popupMenu(c, id, &st.open, popover.Anchor.from(trig_ix), opts.menu);
    if (was_open and !st.open and trig_ix.pressed) {
        st.suppress_toggle = true;
    }
    return m;
}
