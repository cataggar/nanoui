//! Anchored popovers, non-modal floating panels, and shared overlay placement,
//! pointer-scrim, and Escape-stack infrastructure.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;
const input_mod = @import("input.zig");
const div_mod = @import("div.zig");
const widgets = @import("widgets.zig");
const motion = @import("motion/motion.zig");

pub const layer_panel: u8 = 18;
pub const layer_popover_scrim: u8 = 19;
pub const layer_popover: u8 = 20;
pub const layer_menu_scrim: u8 = 21;
pub const layer_menu: u8 = 22;

pub const Placement = enum { bottom_start, bottom, bottom_end, top_start, top, top_end, left, right };

pub const ViewportCorner = enum { top_right, top_left, bottom_right, bottom_left, center };

pub const Anchor = union(enum) {
    node: struct { id: u64, fallback: ?types.Rect = null },
    rect: types.Rect,
    point: types.Point,
    viewport: ViewportCorner,

    pub fn from(ix: Interaction) Anchor {
        return .{ .node = .{ .id = ix.id, .fallback = ix.rect } };
    }
    pub fn fromId(id: u64) Anchor {
        return .{ .node = .{ .id = id } };
    }
    pub fn fromRect(r: types.Rect) Anchor {
        return .{ .rect = r };
    }
    pub fn fromPoint(p: types.Point) Anchor {
        return .{ .point = p };
    }
};

pub fn viewportBounds(c: *const Context) types.Rect {
    const left = if (c.safe_area.left > 0 and std.math.isFinite(c.safe_area.left)) c.safe_area.left else 0;
    const right = if (c.safe_area.right > 0 and std.math.isFinite(c.safe_area.right)) c.safe_area.right else 0;
    const top = if (c.safe_area.top > 0 and std.math.isFinite(c.safe_area.top)) c.safe_area.top else 0;
    const bottom = if (c.safe_area.bottom > 0 and std.math.isFinite(c.safe_area.bottom)) c.safe_area.bottom else 0;
    return .{ .x = left, .y = top, .w = @max(0, c.size.w - (left + right)), .h = @max(0, c.size.h - (top + bottom)) };
}

pub fn placeBounds(bounds: types.Rect, anchor: types.Rect, size: types.Size, placement: Placement, gap: f32, margin: f32) types.Point {
    const min_x = bounds.x + margin;
    const min_y = bounds.y + margin;
    const max_x = @max(min_x, bounds.x + bounds.w - size.w - margin);
    const max_y = @max(min_y, bounds.y + bounds.h - size.h - margin);
    const lim_x0 = bounds.x;
    const lim_y0 = bounds.y;
    const lim_x1 = bounds.x + bounds.w;
    const lim_y1 = bounds.y + bounds.h;
    const room_above = anchor.y - lim_y0;
    const room_below = lim_y1 - (anchor.y + anchor.h);
    const room_left = anchor.x - lim_x0;
    const room_right = lim_x1 - (anchor.x + anchor.w);

    var p = placement;
    switch (p) {
        .bottom_start, .bottom, .bottom_end => if (anchor.y + anchor.h + gap + size.h > lim_y1 and (anchor.y - gap - size.h >= lim_y0 or room_above > room_below)) {
            p = switch (p) {
                .bottom_start => .top_start,
                .bottom => .top,
                else => .top_end,
            };
        },
        .top_start, .top, .top_end => if (anchor.y - gap - size.h < lim_y0 and (anchor.y + anchor.h + gap + size.h <= lim_y1 or room_below > room_above)) {
            p = switch (p) {
                .top_start => .bottom_start,
                .top => .bottom,
                else => .bottom_end,
            };
        },
        .left => if (anchor.x - gap - size.w < lim_x0 and (anchor.x + anchor.w + gap + size.w <= lim_x1 or room_right > room_left)) {
            p = .right;
        },
        .right => if (anchor.x + anchor.w + gap + size.w > lim_x1 and (anchor.x - gap - size.w >= lim_x0 or room_left > room_right)) {
            p = .left;
        },
    }

    var x: f32 = switch (p) {
        .bottom_start, .top_start => anchor.x,
        .bottom, .top => anchor.x + (anchor.w - size.w) / 2,
        .bottom_end, .top_end => anchor.x + anchor.w - size.w,
        .left => anchor.x - gap - size.w,
        .right => anchor.x + anchor.w + gap,
    };
    var y: f32 = switch (p) {
        .bottom_start, .bottom, .bottom_end => anchor.y + anchor.h + gap,
        .top_start, .top, .top_end => anchor.y - gap - size.h,
        .left, .right => anchor.y + (anchor.h - size.h) / 2,
    };
    x = std.math.clamp(x, min_x, max_x);
    y = std.math.clamp(y, min_y, max_y);
    return .{ .x = x, .y = y };
}

pub fn place(c: *const Context, anchor: types.Rect, size: types.Size, placement: Placement, gap: f32) types.Point {
    return placeBounds(viewportBounds(c), anchor, size, placement, gap, 6);
}

pub fn takeKey(c: *Context, shortcut_key: u21, plain_key: ?input_mod.Key) bool {
    if (c.input.cmd or c.input.ctrl or c.input.alt or c.input.shift) return false;
    const matched_shortcut = !c.shortcut_taken and if (c.input.shortcut) |s|
        (!s.cmd and !s.ctrl and !s.alt and !s.shift and s.key == shortcut_key)
    else
        false;
    const matched_plain = if (plain_key) |pk| c.input.key == pk else false;
    if (!matched_shortcut and !matched_plain) return false;
    c.shortcut_taken = true;
    if (matched_shortcut) c.input.shortcut = null;
    if (plain_key) |pk| if (c.input.key == pk) {
        c.input.key = null;
    };
    c.changed = true;
    return true;
}

pub const DeferredOverlay = struct {
    node_index: u32,
    anchor: Anchor,
    placement: Placement,
    gap: f32 = 6,
    margin: f32 = 6,
    drag_state_id: u64 = 0,
};

pub const MenuSlice = struct { start: u32, len: u32 };

pub const Frame = struct {
    deferred: std.ArrayList(DeferredOverlay) = .empty,
    panel_offsets: std.AutoHashMapUnmanaged(u64, types.Point) = .empty,
    prev_layers: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    next_layers: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    prev_menus: std.AutoHashMapUnmanaged(u64, MenuSlice) = .empty,
    next_menus: std.AutoHashMapUnmanaged(u64, MenuSlice) = .empty,
    prev_menu_items: std.ArrayList(bool) = .empty,
    next_menu_items: std.ArrayList(bool) = .empty,
    escape_id: u64 = 0,
    escape_layer: u8 = 0,
    dismissed_id: u64 = 0,

    pub fn beginPass(f: *Frame) void {
        f.deferred.clearRetainingCapacity();
        f.next_layers.clearRetainingCapacity();
        f.next_menus.clearRetainingCapacity();
        f.next_menu_items.clearRetainingCapacity();
        f.escape_id = 0;
        f.escape_layer = 0;
    }
    pub fn resetFrame(f: *Frame) void {
        std.mem.swap(std.AutoHashMapUnmanaged(u64, u8), &f.prev_layers, &f.next_layers);
        std.mem.swap(std.AutoHashMapUnmanaged(u64, MenuSlice), &f.prev_menus, &f.next_menus);
        std.mem.swap(std.ArrayList(bool), &f.prev_menu_items, &f.next_menu_items);
        f.dismissed_id = 0;
    }
    pub fn deinit(f: *Frame, gpa: std.mem.Allocator) void {
        f.deferred.deinit(gpa);
        f.panel_offsets.deinit(gpa);
        f.prev_layers.deinit(gpa);
        f.next_layers.deinit(gpa);
        f.prev_menus.deinit(gpa);
        f.next_menus.deinit(gpa);
        f.prev_menu_items.deinit(gpa);
        f.next_menu_items.deinit(gpa);
    }
    pub fn noteLayer(f: *Frame, gpa: std.mem.Allocator, id: u64, layer: u8) void {
        f.next_layers.put(gpa, id, layer) catch {};
    }
    pub fn hotLayer(f: *const Frame, c: *const Context) u8 {
        var best: u8 = if (c.hot != 0) (f.prev_layers.get(c.hot) orelse 0) else 0;
        for (c.hot_path.items) |anc| if (f.prev_layers.get(anc)) |l| {
            best = @max(best, l);
        };
        return best;
    }
    pub fn prevMenuEnabled(f: *const Frame, menu_id: u64) []const bool {
        const s = f.prev_menus.get(menu_id) orelse return &.{};
        const end_idx: usize = @as(usize, s.start) + @as(usize, s.len);
        if (end_idx > f.prev_menu_items.items.len) return &.{};
        return f.prev_menu_items.items[s.start..end_idx];
    }
    pub fn recordMenuEnabled(f: *Frame, gpa: std.mem.Allocator, menu_id: u64, items: []const bool) void {
        const start: u32 = @intCast(f.next_menu_items.items.len);
        f.next_menu_items.appendSlice(gpa, items) catch return;
        f.next_menus.put(gpa, menu_id, .{ .start = start, .len = @intCast(items.len) }) catch {};
    }
    pub fn hasActive(f: *const Frame) bool {
        return f.deferred.items.len > 0;
    }
    pub fn offerEscape(f: *Frame, id: u64, layer: u8) void {
        if (f.escape_id == 0 or layer >= f.escape_layer) {
            f.escape_id = id;
            f.escape_layer = layer;
        }
    }
    pub fn takeDismissed(f: *Frame, id: u64) bool {
        if (f.dismissed_id != 0 and f.dismissed_id == id) {
            f.dismissed_id = 0;
            return true;
        }
        return false;
    }
    pub fn deferArrange(f: *Frame, gpa: std.mem.Allocator, item: DeferredOverlay) void {
        f.deferred.append(gpa, item) catch {};
    }
};

pub fn flushInput(c: *Context) void {
    if (c.overlay.escape_id != 0 and takeKey(c, input_mod.Shortcut.escape, .escape)) {
        c.overlay.dismissed_id = c.overlay.escape_id;
    }
}

fn shiftSubtree(c: *Context, index: u32, dx: f32, dy: f32) void {
    const n = c.node(index);
    n.rect.x += dx;
    n.rect.y += dy;
    var child = n.first_child;
    while (child != ctx_mod.none) : (child = c.node(child).next) {
        if (c.node(child).style.fixed) continue;
        shiftSubtree(c, child, dx, dy);
    }
}

pub fn arrangeAnchored(c: *Context) void {
    const bounds = viewportBounds(c);
    for (c.overlay.deferred.items) |item| {
        if (item.node_index >= c.nodes.items.len) continue;
        const root = c.node(item.node_index);
        const panel_size: types.Size = .{ .w = root.rect.w, .h = root.rect.h };
        const min_x = bounds.x + item.margin;
        const min_y = bounds.y + item.margin;
        const max_x = @max(min_x, bounds.x + bounds.w - panel_size.w - item.margin);
        const max_y = @max(min_y, bounds.y + bounds.h - panel_size.h - item.margin);

        var at: types.Point = switch (item.anchor) {
            .viewport => |vc| switch (vc) {
                .top_right => .{ .x = max_x, .y = min_y },
                .top_left => .{ .x = min_x, .y = min_y },
                .bottom_right => .{ .x = max_x, .y = max_y },
                .bottom_left => .{ .x = min_x, .y = max_y },
                .center => .{
                    .x = std.math.clamp(bounds.x + (bounds.w - panel_size.w) / 2, min_x, max_x),
                    .y = std.math.clamp(bounds.y + (bounds.h - panel_size.h) / 2, min_y, max_y),
                },
            },
            .rect => |r| placeBounds(bounds, r, panel_size, item.placement, item.gap, item.margin),
            .point => |p| placeBounds(bounds, .{ .x = p.x, .y = p.y, .w = 0, .h = 0 }, panel_size, item.placement, item.gap, item.margin),
            .node => |na| blk: {
                const found: ?types.Rect = for (c.nodes.items) |n| {
                    if (n.id == na.id) break n.rect;
                } else null;
                const ar = found orelse na.fallback orelse c.rects.get(na.id) orelse c.prev_rects.get(na.id) orelse
                    types.Rect{ .x = bounds.x + bounds.w / 2, .y = bounds.y + bounds.h / 2, .w = 0, .h = 0 };
                break :blk placeBounds(bounds, ar, panel_size, item.placement, item.gap, item.margin);
            },
        };

        if (item.drag_state_id != 0) if (c.overlay.panel_offsets.getPtr(item.drag_state_id)) |delta| {
            const clamped_x = std.math.clamp(at.x + delta.x, min_x, max_x);
            const clamped_y = std.math.clamp(at.y + delta.y, min_y, max_y);
            delta.* = .{ .x = clamped_x - at.x, .y = clamped_y - at.y };
            at = .{ .x = clamped_x, .y = clamped_y };
        };

        shiftSubtree(c, item.node_index, at.x, at.y);
    }
}

pub fn absorbPointer(d: div_mod.Div) Interaction {
    const was_hand = d.c.cursor_hand;
    const ix = d.wheel().interaction();
    if (d.c.hot == ix.id) d.c.cursor_hand = was_hand;
    return ix;
}

pub fn outsideScrim(c: *Context, key_str: []const u8, scrim_layer: u8, open: *bool) bool {
    c.next_key = key_str;
    const sc = div_mod.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(scrim_layer);
    const ix = absorbPointer(sc);
    const sc_id = ix.id;
    c.overlay.noteLayer(c.gpa, sc_id, scrim_layer);
    sc.end();
    if (ix.pressed or ix.secondary_clicked or ((c.input.pressed or c.input.secondary) and c.hot == sc_id)) {
        open.* = false;
        c.changed = true;
        return true;
    }
    return false;
}

pub fn anchorHintRect(c: *const Context, anchor: Anchor) ?types.Rect {
    return switch (anchor) {
        .node => |na| na.fallback orelse c.rects.get(na.id),
        .rect => |r| r,
        .point => |p| .{ .x = p.x, .y = p.y, .w = 0, .h = 0 },
        .viewport => null,
    };
}

pub const PopoverOptions = struct {
    placement: Placement = .bottom_start,
    width: ?f32 = null,
    min_width: f32 = 0,
    max_width: f32 = 360,
    max_height: ?f32 = null,
    padding: f32 = 12,
    radius: f32 = 10,
    gap: f32 = 6,
    margin: f32 = 6,
    layer: u8 = layer_popover,
    scrim_layer: ?u8 = null,
    dismiss_on_outside: bool = true,
    consume_outside: bool = true,
    dismiss_on_escape: bool = true,
    glass: bool = false,
    background: ?types.Color = null,
    border: ?types.Color = null,
};

pub const Popover = struct {
    div: div_mod.Div,
    panel_id: u64,

    pub fn end(p: Popover) void {
        p.div.end();
    }
};

fn handleDismiss(c: *Context, id: []const u8, panel_id: u64, open: *bool, anchor: Anchor, layer: u8, scrim_layer: u8, dismiss_outside: bool, consume_outside: bool, dismiss_escape: bool, dragging: bool) void {
    if (c.overlay.takeDismissed(panel_id)) {
        open.* = false;
        c.changed = true;
    }
    const was_open = if (c.motion_store.map.get(panel_id)) |ms| ms.mounted and !ms.exiting else c.rects.contains(panel_id);
    if (!open.*) return;
    if (dismiss_outside) {
        if (consume_outside) {
            _ = outsideScrim(c, c.print("nanoui:scrim:{s}", .{id}), scrim_layer, open);
        } else if (was_open) {
            const inside = dragging or c.hot == panel_id or std.mem.indexOfScalar(u64, c.hot_path.items, panel_id) != null;
            const on_anchor = if (anchorHintRect(c, anchor)) |ar| ar.contains(c.input.mouse) else false;
            const above = c.overlay.hotLayer(c) > layer;
            if ((c.input.pressed or c.input.secondary) and !inside and !on_anchor and !above) {
                open.* = false;
                c.changed = true;
            }
        }
    }
    if (open.* and dismiss_escape) c.overlay.offerEscape(panel_id, layer);
}

fn presentOverlay(c: *Context, id: []const u8, show: bool) ?motion.Frame {
    return motion.present(c, id, show, .{
        .initial = .{ .opacity = 0, .scale = 0.97, .y = -4 },
        .exit = .{ .opacity = 0, .scale = 0.98 },
        .transition = .{ .spring = motion.Spring.snappy },
    });
}

pub fn popover(c: *Context, id: []const u8, open: *bool, anchor: Anchor, opts: PopoverOptions) ?Popover {
    c.next_key = id;
    const panel_id = c.peekId(null);
    c.next_key = null;
    const sl = opts.scrim_layer orelse (opts.layer -| 1);
    handleDismiss(c, id, panel_id, open, anchor, opts.layer, sl, opts.dismiss_on_outside, opts.consume_outside, opts.dismiss_on_escape, false);
    const f = presentOverlay(c, id, open.*) orelse return null;

    const vp_max_h = @max(48, viewportBounds(c).h - 2 * opts.margin);
    const eff_max_h = if (opts.max_height) |mh| @min(mh, vp_max_h) else vp_max_h;

    c.next_key = id;
    var d = div_mod.div(c).fixed().offset(0, 0).layer(opts.layer).column().gap(4).p(opts.padding).rounded(opts.radius)
        .minW(opts.min_width).maxW(opts.max_width).maxH(eff_max_h).scrollY()
        .shadow(.{ .color = c.theme.shadow.alpha(0.9), .blur = 24, .y = 8 });
    d = if (opts.glass) d.glass(.{}) else d.bg(opts.background orelse c.theme.surface).border(opts.border orelse c.theme.border);
    if (opts.width) |w| d = d.w(w);
    if (open.*) {
        _ = absorbPointer(d);
        c.overlay.noteLayer(c.gpa, panel_id, opts.layer);
    }
    c.overlay.deferArrange(c.gpa, .{ .node_index = d.index, .anchor = anchor, .placement = opts.placement, .gap = opts.gap, .margin = opts.margin });
    return .{ .div = d.motion(f), .panel_id = panel_id };
}

pub const FloatingPanelOptions = struct {
    title: []const u8 = "",
    anchor: Anchor = .{ .viewport = .top_right },
    placement: Placement = .bottom_end,
    width: ?f32 = 280,
    min_width: f32 = 180,
    max_width: f32 = 420,
    max_height: ?f32 = null,
    padding: f32 = 12,
    radius: f32 = 12,
    gap: f32 = 8,
    margin: f32 = 12,
    layer: u8 = layer_panel,
    close_button: bool = true,
    draggable: bool = true,
    dismiss_on_escape: bool = true,
    dismiss_on_outside: bool = false,
    consume_outside: bool = false,
    glass: bool = false,
};

pub const FloatingPanel = struct {
    div: div_mod.Div,
    body: div_mod.Div,
    panel_id: u64,

    pub fn end(p: FloatingPanel) void {
        p.body.end();
        p.div.end();
    }
};

const DragTrack = struct {
    start_mouse: types.Point = .{},
    start_delta: types.Point = .{},
    dragging: bool = false,
};

fn panelDragId(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0x667064726167, id);
}

pub fn resetFloatingPanelOffset(c: *Context, id: []const u8) void {
    if (c.overlay.panel_offsets.remove(panelDragId(id))) c.changed = true;
}

pub fn floatingPanel(c: *Context, id: []const u8, open: *bool, opts: FloatingPanelOptions) ?FloatingPanel {
    const drag_id = panelDragId(id);
    c.next_key = id;
    const panel_id = c.peekId(null);
    const dt = c.state(DragTrack, c.print("nanoui:fp-drag:{s}", .{id}));
    c.next_key = null;

    handleDismiss(c, id, panel_id, open, opts.anchor, opts.layer, opts.layer -| 1, opts.dismiss_on_outside, opts.consume_outside, opts.dismiss_on_escape, dt.dragging);
    if (!open.*) dt.dragging = false;
    const f = presentOverlay(c, id, open.*) orelse return null;

    const vp_max_h = @max(64, viewportBounds(c).h - 2 * opts.margin);
    const eff_max_h = if (opts.max_height) |mh| @min(mh, vp_max_h) else vp_max_h;

    c.next_key = id;
    var d = div_mod.div(c).fixed().offset(0, 0).layer(opts.layer).column().rounded(opts.radius)
        .minW(opts.min_width).maxW(opts.max_width)
        .shadow(.{ .color = c.theme.shadow.alpha(0.95), .blur = 28, .y = 10 });
    d = if (opts.glass) d.glass(.{}) else d.bg(c.theme.surface).border(c.theme.border);
    if (opts.width) |w| d = d.w(w);
    if (open.*) {
        _ = absorbPointer(d);
        c.overlay.noteLayer(c.gpa, panel_id, opts.layer);
    }
    d = d.motion(f);
    c.overlay.deferArrange(c.gpa, .{ .node_index = d.index, .anchor = opts.anchor, .placement = opts.placement, .gap = opts.gap, .margin = opts.margin, .drag_state_id = drag_id });

    const has_header = opts.title.len > 0 or opts.close_button or opts.draggable;
    if (has_header) {
        const hdr = div_mod.div(c).row().wFull().itemsCenter().gap(6).px(opts.padding).py(8);
        c.next_key = "nanoui:fp-grip";
        const grip = div_mod.div(c).row().grow().itemsCenter().minW(24).h(24).control();
        if (opts.title.len > 0) {
            widgets.text(c, opts.title, .{ .size = 13, .weight = .semibold, .color = c.theme.text });
        }
        if (open.* and opts.draggable) {
            const gix = absorbPointer(grip);
            if (gix.hovered and !dt.dragging) c.cursor = .open_hand;
            if (gix.pressed and !dt.dragging) {
                dt.dragging = true;
                dt.start_mouse = c.input.mouse;
                dt.start_delta = c.overlay.panel_offsets.get(drag_id) orelse .{};
            }
            if (dt.dragging) {
                if (c.input.down) {
                    c.wants_moves = true;
                    c.cursor = .closed_hand;
                    const nx = dt.start_delta.x + (c.input.mouse.x - dt.start_mouse.x);
                    const ny = dt.start_delta.y + (c.input.mouse.y - dt.start_mouse.y);
                    const prev: types.Point = c.overlay.panel_offsets.get(drag_id) orelse .{};
                    if (nx != prev.x or ny != prev.y) {
                        c.overlay.panel_offsets.put(c.gpa, drag_id, .{ .x = nx, .y = ny }) catch {};
                        c.changed = true;
                    }
                } else {
                    dt.dragging = false;
                }
            }
        } else {
            dt.dragging = false;
        }
        grip.end();

        if (opts.close_button) {
            c.next_key = "nanoui:fp-close";
            const cb = div_mod.div(c).size(24, 24).rounded(6).center().control();
            if (open.*) {
                const cix = cb.interaction();
                c.addA11y(cb.index, .button, "Close", "", false, true);
                if (cix.hovered) c.node(cb.index).style.background = c.theme.surface_hover;
                if (cix.clicked) {
                    open.* = false;
                    c.changed = true;
                }
            }
            widgets.icon(c, "xmark", .{ .size = 12, .weight = .semibold, .color = c.theme.muted });
            cb.end();
        }
        hdr.end();
        if (opts.title.len > 0) {
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = c.theme.border }, .none, null);
        }
    }

    const header_h: f32 = if (has_header) 41 else 0;
    const body = div_mod.div(c).column().wFull().gap(8).p(opts.padding).maxH(@max(32, eff_max_h - header_h)).scrollY();
    return .{ .div = d, .body = body, .panel_id = panel_id };
}

test "placeBounds flips across overflowing edges and clamps within safe area" {
    const testing = std.testing;
    const vp: types.Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    try testing.expectEqual(types.Point{ .x = 10, .y = 46 }, placeBounds(vp, .{ .x = 10, .y = 10, .w = 80, .h = 30 }, .{ .w = 120, .h = 100 }, .bottom_start, 6, 6));
    try testing.expectEqual(@as(f32, 144), placeBounds(vp, .{ .x = 10, .y = 250, .w = 80, .h = 30 }, .{ .w = 120, .h = 100 }, .bottom_start, 6, 6).y);
    try testing.expectEqual(@as(f32, 274), placeBounds(vp, .{ .x = 380, .y = 10, .w = 20, .h = 20 }, .{ .w = 120, .h = 40 }, .bottom_start, 6, 6).x);

    const safe_vp: types.Rect = .{ .x = 0, .y = 44, .w = 390, .h = 766 };
    const top_clamped = placeBounds(safe_vp, .{ .x = 20, .y = 50, .w = 60, .h = 24 }, .{ .w = 140, .h = 80 }, .top_start, 6, 6);
    try testing.expectEqual(@as(f32, 80), top_clamped.y);
}
