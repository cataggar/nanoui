//! Standalone embeddable UI host (`-Dbackend=none` or caller-driven render targets):
//! owns a `TextSystem`, `Context`, and per-frame arenas without `App`, `Window`,
//! WebViews, swapchains, `libc`, or external Zig packages.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const input = @import("input.zig");
const text = @import("text.zig");
const images = @import("images.zig");
const font_registry = @import("font_registry.zig");
const textfield_keys = @import("textfield_keys.zig");
const frames = @import("frame.zig");
const raster = @import("raster.zig");
const ctx_mod = @import("context.zig");
const Theme = @import("theme.zig").Theme;
const ui = @import("ui.zig");

pub const contract = @import("contract.zig");
pub const pass = @import("embed_pass.zig");
pub const FrameOutput = contract.FrameOutput;
pub const DirtyRect = contract.DirtyRect;
pub const GlyphAtlas = contract.GlyphAtlas;
pub const ImageAtlas = contract.ImageAtlas;
pub const CursorState = contract.CursorState;
pub const ImeState = contract.ImeState;
pub const Waker = ctx_mod.Waker;

pub const Options = struct {
    size: types.Size = .{ .w = 800, .h = 600 },
    scale: f32 = 1.0,
    theme: Theme = .dark_theme,
    transparent_root: bool = false,
    pixel_snap: bool = false,
    renderer_name: []const u8 = "Embedded",
    scan_system_fonts: bool = false,
    image_limits: images.Limits = .{},
};

pub const KeyEvent = struct {
    key: ?input.Key = null,
    codepoint: u21 = 0,
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    repeat: bool = false,
};

const MacAtlasMirror = if (text.portable) struct {} else struct {
    buf: std.ArrayList(u8) = .empty,
    shelf: [3]u32 = .{ 0, 0, 0 },
    size: u32 = 0,
    tex: usize = 0,
    gen: u64 = 0,
    resets: u64 = 0,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    text: text.TextSystem,
    ctx: ctx_mod.Context,
    instances: std.ArrayList(gpu.Instance) = .empty,
    size: types.Size,
    scale: f32,
    theme: Theme,
    woke: std.atomic.Value(bool) = .init(false),
    clipboard_buf: std.ArrayList(u8) = .empty,
    clipboard_wrote: bool = false,
    pending_chars: std.ArrayList(u8) = .empty,
    pending_ops: std.ArrayList(input.TextOp) = .empty,
    op_strings: std.ArrayList([]u8) = .empty,
    registered_faces: std.ArrayList(*font_registry.Face) = .empty,
    last_glyph_gen: u64 = 0,
    last_image_gen: u64 = 0,
    scrolled: bool = false,
    mac_atlas: MacAtlasMirror = .{},

    pub fn init(gpa: std.mem.Allocator, options: Options) !*Host {
        const self = try gpa.create(Host);
        errdefer gpa.destroy(self);
        const scale = if (options.scale > 0 and std.math.isFinite(options.scale)) options.scale else 1.0;
        var ts: text.TextSystem = if (comptime text.portable)
            .initOptions(gpa, .{ .scan_system_fonts = options.scan_system_fonts })
        else blk: {
            const dev = @import("metal_app.zig").metalDevice() orelse return error.NoMetalDevice;
            break :blk .init(gpa, @ptrCast(dev));
        };
        ts.setScale(scale);
        ts.images.limits = options.image_limits;
        self.* = .{ .gpa = gpa, .text = ts, .ctx = undefined, .size = options.size, .scale = scale, .theme = options.theme };
        self.ctx = .init(gpa, &self.text);
        self.ctx.size = options.size;
        self.ctx.scale = scale;
        self.ctx.theme = options.theme;
        self.ctx.transparent_root = options.transparent_root;
        self.ctx.pixel_snap = options.pixel_snap;
        self.ctx.renderer = options.renderer_name;
        self.ctx.clipboard = .{ .ctx = self, .write = onClipboardWrite };
        self.ctx.waker = .{ .ctx = self, .wake = onWake };
        return self;
    }

    pub fn deinit(self: *Host) void {
        const gpa = self.gpa;
        raster.freeLayers();
        self.clearPendingInput();
        self.op_strings.deinit(gpa);
        self.pending_ops.deinit(gpa);
        self.pending_chars.deinit(gpa);
        self.clipboard_buf.deinit(gpa);
        self.instances.deinit(gpa);
        if (comptime !text.portable) self.mac_atlas.buf.deinit(gpa);
        self.ctx.deinit();
        self.text.deinit();
        for (self.registered_faces.items) |f| font_registry.unregisterFace(f);
        self.registered_faces.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn context(self: *Host) *ctx_mod.Context {
        return &self.ctx;
    }

    pub fn waker(self: *Host) ctx_mod.Waker {
        return .{ .ctx = self, .wake = onWake };
    }

    pub fn takeWake(self: *Host) bool {
        return self.woke.swap(false, .acq_rel);
    }

    pub fn registerFont(self: *Host, bytes: []const u8) error{InvalidFont}!void {
        if (bytes.len == 0) return error.InvalidFont;
        if (comptime text.portable) {
            const before = self.text.db.faces.items.len;
            self.text.db.addMemory(bytes);
            if (self.text.db.faces.items.len == before) return error.InvalidFont;
            self.text.db.found.clearRetainingCapacity();
            self.text.dropCaches();
            return;
        }
        var seen = false;
        for (font_registry.registered()) |prev| if (prev.ptr == bytes.ptr and prev.len == bytes.len) {
            seen = true;
            break;
        };
        if (!seen and !font_registry.register(bytes)) return error.InvalidFont;
    }

    pub fn registerFontFace(self: *Host, opts: font_registry.FaceOptions) (font_registry.RegisterError || error{OutOfMemory})!void {
        const f = try font_registry.registerFaceOwned(self.gpa, opts);
        errdefer font_registry.unregisterFace(f);
        try self.registered_faces.append(self.gpa, f);
    }

    pub fn resize(self: *Host, size: types.Size, scale: f32) void {
        self.size = size;
        if (scale > 0 and std.math.isFinite(scale)) self.scale = scale;
        self.ctx.size = size;
        self.ctx.scale = self.scale;
        self.text.setScale(self.scale);
    }

    pub fn setTheme(self: *Host, theme: Theme) void {
        self.theme = theme;
        self.ctx.theme = theme;
    }

    pub fn setWindowActive(self: *Host, active: bool) void {
        self.ctx.input.window_active = active;
        self.ctx.window_focused = active;
        if (!active and self.ctx.key_up_supported) self.ctx.input.keys_released = true;
    }

    pub fn pointerMove(self: *Host, pos: types.Point) void {
        self.ctx.input.mouse = pos;
        if (!self.ctx.input.down) self.ctx.updateHot();
    }

    pub fn pointerDown(self: *Host, pos: types.Point, button: input.Button, clicks: u32) void {
        self.ctx.input.mouse = pos;
        self.ctx.input.button = button;
        self.ctx.input.click_count = @max(clicks, 1);
        if (button == .right) self.ctx.secondaryDown();
        self.ctx.pointerDown();
    }

    pub fn pointerUp(self: *Host, pos: types.Point, button: input.Button) void {
        self.ctx.input.mouse = pos;
        self.ctx.input.button = button;
        self.ctx.updateHot();
        if (button != .right or self.ctx.input.down) self.ctx.pointerUp();
    }

    pub fn pointerLeave(self: *Host) void {
        self.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
        if (!self.ctx.input.down) self.ctx.updateHot();
    }

    pub fn scroll(self: *Host, delta: types.Point, phase: input.ScrollPhase, precise: bool) void {
        self.ctx.input.precise = precise;
        self.ctx.input.scroll_phase = phase;
        self.ctx.scroll_holding = precise and (phase == .began or phase == .changed);
        self.ctx.input.scroll.x += delta.x;
        if (delta.y != 0 and self.ctx.applyScroll(delta.y)) {
            self.scrolled = true;
        } else {
            self.ctx.input.scroll.y += delta.y;
        }
    }

    pub fn keyDown(self: *Host, ev: KeyEvent) void {
        self.flushPendingToOps() catch {};
        self.ctx.input.shift = ev.shift;
        self.ctx.input.ctrl = ev.ctrl;
        self.ctx.input.alt = ev.alt;
        self.ctx.input.cmd = ev.cmd;
        self.ctx.input.repeat = ev.repeat;
        var key_for_field = ev.key;
        if (ev.key) |k| if (specialKeyCommand(k, ev.cmd, ev.ctrl, ev.alt, ev.shift)) |cmd| {
            self.pending_ops.append(self.gpa, .{ .command = cmd }) catch {};
            key_for_field = null;
        };
        self.ctx.input.key = key_for_field;
        const sc_key: ?u21 = if (ev.codepoint != 0 and (ev.cmd or ev.ctrl or ev.alt or ev.codepoint >= 0xF700 or ev.codepoint < 0x20 or ev.codepoint == 0x7f))
            input.Shortcut.keyOf(ev.codepoint)
        else if (ev.key) |k|
            shortcutKeyOf(k)
        else
            null;
        if (sc_key) |sk| {
            const sc: input.Shortcut = .{ .key = sk, .shift = ev.shift, .ctrl = ev.ctrl, .alt = ev.alt, .cmd = ev.cmd };
            self.ctx.input.shortcut = sc;
            self.applyStandardShortcut(sc);
        }
    }

    pub fn keyUp(self: *Host, sc: input.Shortcut) void {
        self.ctx.key_up_supported = true;
        self.ctx.input.queueKeyUp(self.gpa, sc);
    }

    pub fn shortcut(self: *Host, sc: input.Shortcut) void {
        self.flushPendingToOps() catch {};
        self.ctx.input.shift = sc.shift;
        self.ctx.input.ctrl = sc.ctrl;
        self.ctx.input.alt = sc.alt;
        self.ctx.input.cmd = sc.cmd;
        self.ctx.input.shortcut = sc;
        self.applyStandardShortcut(sc);
    }

    pub fn textInput(self: *Host, utf8: []const u8) !void {
        if (utf8.len == 0) return;
        if (self.ctx.input.key != null) try self.flushPendingToOps();
        if (self.pending_ops.items.len > 0) {
            try self.pending_ops.append(self.gpa, .{ .insert = try self.dupeOpString(utf8) });
        } else {
            try self.pending_chars.appendSlice(self.gpa, utf8);
        }
    }

    pub fn imeSetMarked(self: *Host, utf8: []const u8, sel_start: usize, sel_len: usize) !void {
        try self.flushPendingToOps();
        try self.pending_ops.append(self.gpa, .{ .set_marked = .{ .text = try self.dupeOpString(utf8), .sel_start = sel_start, .sel_len = sel_len } });
    }

    pub fn imeCommit(self: *Host, utf8: []const u8) !void {
        try self.flushPendingToOps();
        try self.pending_ops.append(self.gpa, .{ .insert = try self.dupeOpString(utf8) });
    }

    pub fn paste(self: *Host, utf8: []const u8) !void {
        try self.flushPendingToOps();
        self.ctx.paste_op = true;
        try self.pending_ops.append(self.gpa, .{ .insert = try self.dupeOpString(utf8) });
    }

    pub fn pushTextOp(self: *Host, op: input.TextOp) !void {
        try self.flushPendingToOps();
        const owned: input.TextOp = switch (op) {
            .insert => |s| .{ .insert = try self.dupeOpString(s) },
            .set_marked => |m| .{ .set_marked = .{ .text = try self.dupeOpString(m.text), .sel_start = m.sel_start, .sel_len = m.sel_len } },
            else => op,
        };
        try self.pending_ops.append(self.gpa, owned);
    }

    pub fn frame(self: *Host, view: ui.View, dt: f32, time: f64) contract.FrameOutput {
        self.clipboard_wrote = false;
        self.clipboard_buf.clearRetainingCapacity();
        self.ctx.close_request = false;
        self.ctx.frame_time = dt;
        self.ctx.input.chars = self.pending_chars.items;
        self.ctx.input.ops = self.pending_ops.items;
        self.text.setScale(self.scale);

        const glyph_gen_before = self.last_glyph_gen;
        const img_gen_before = self.last_image_gen;
        const theme_before = self.ctx.theme_chosen orelse self.theme;
        const res = frames.run(&self.ctx, view, &self.text, &self.instances, self.size, self.scale, theme_before, dt, time);
        if (self.scrolled) {
            self.scrolled = false;
            self.ctx.updateHot();
        }
        self.clearPendingInput();

        const active_theme = self.ctx.theme_chosen orelse self.theme;
        const theme_changed = !std.meta.eql(theme_before, active_theme);
        const woke = self.takeWake();
        const wants_frame = woke or self.ctx.animating or res.hot_changed or self.ctx.time_driven == .fast or theme_changed;
        const next_frame_in: ?f32 = if (wants_frame) 0 else if (self.ctx.frame_in) |d| d else if (self.ctx.time_driven == .slow) (1.0 / 24.0) else null;

        const over_text = self.ctx.cursor_text or self.ctx.pointerOverText();
        const cur_shape: ctx_mod.Cursor = self.ctx.cursor orelse if (over_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
        const cursor: contract.CursorState = .{
            .shape = cur_shape,
            .custom = if (cur_shape == .custom) self.ctx.custom_cursor else null,
            .tooltip = self.ctx.hotHelp(),
        };
        const ime: ?contract.ImeState = if (self.ctx.focused_text) |ft| .{
            .id = ft.id,
            .rect = self.ctx.rects.get(ft.id) orelse ft.caret_rect,
            .caret_rect = ft.caret_rect,
            .clause_rect = ft.clause_rect,
            .text = ft.text,
            .caret = ft.caret,
            .anchor = ft.anchor,
            .marked = ft.marked,
            .multiline = self.ctx.focused_multiline,
            .password = self.ctx.focused_password,
        } else null;

        const glyph_atlas: contract.GlyphAtlas = if (comptime text.portable) .{
            .pixels = self.text.atlas.pixels,
            .width = self.text.atlas.size,
            .height = self.text.atlas.size,
            .generation = self.text.atlas.generation,
            .resets = self.text.atlas.resets,
            .dirty_from_generation = glyph_gen_before,
            .dirty = if (self.text.atlas.takeDirtyRect()) |r| DirtyRect.fromArray(r) else null,
        } else self.syncMacGlyphAtlas(glyph_gen_before);
        self.last_glyph_gen = glyph_atlas.generation;

        const img_side = if (self.text.images.pixels.len > 0) self.text.images.side else 0;
        const image_atlas: contract.ImageAtlas = .{
            .pixels = self.text.images.pixels,
            .width = img_side,
            .height = img_side,
            .generation = self.text.images.generation,
            .resets = self.text.images.resets,
            .dirty_from_generation = img_gen_before,
            .dirty = if (self.text.images.takeDirtyRect()) |r| DirtyRect.fromArray(r) else null,
        };
        self.last_image_gen = image_atlas.generation;
        const pixel_size: [2]u32 = .{
            if (self.size.w > 0) @intFromFloat(@max(1, @round(self.size.w * self.scale))) else 0,
            if (self.size.h > 0) @intFromFloat(@max(1, @round(self.size.h * self.scale))) else 0,
        };

        return .{
            .size = self.size,
            .scale = self.scale,
            .pixel_size = pixel_size,
            .clear_color = if (self.ctx.transparent_root) types.Color.transparent else active_theme.background,
            .time = time,
            .instances = self.instances.items,
            .gradients = self.ctx.gradients.items,
            .textures = self.ctx.textures.items,
            .glyph_atlas = glyph_atlas,
            .image_atlas = image_atlas,
            .cursor = cursor,
            .clipboard_write = if (self.clipboard_wrote) self.clipboard_buf.items else null,
            .ime = ime,
            .a11y = self.ctx.a11y_items.items,
            .stage_rects = self.ctx.stage_rects[0..self.ctx.stage_count],
            .wants_frame = wants_frame,
            .next_frame_in = next_frame_in,
            .close_requested = self.ctx.close_request,
            .stats = self.ctx.stats,
        };
    }

    pub fn drawPixels(_: *const Host, out: contract.FrameOutput, target: gpu.Pixels) void {
        pass.Cpu.draw(out, target);
    }

    fn syncMacGlyphAtlas(self: *Host, prev_gen: u64) contract.GlyphAtlas {
        const objc = @import("../objc.zig");
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        const a = &self.text.atlas;
        const m = &self.mac_atlas;
        const side = a.size;
        const shelf: [3]u32 = .{ a.shelf_x, a.shelf_y, a.shelf_h };
        const tex = @intFromPtr(a.texture);
        if (shelf[0] == 0 and shelf[1] == 0 and shelf[2] == 0) {
            return .{ .pixels = m.buf.items, .width = side, .height = side, .generation = m.gen, .resets = m.resets, .dirty_from_generation = prev_gen };
        }
        if (std.meta.eql(shelf, m.shelf) and side == m.size and tex == m.tex) {
            return .{ .pixels = m.buf.items, .width = side, .height = side, .generation = m.gen, .resets = m.resets, .dirty_from_generation = prev_gen };
        }
        const reset = (m.tex != 0 and (tex != m.tex or side != m.size)) or
            shelf[1] < m.shelf[1] or (shelf[1] == m.shelf[1] and shelf[0] < m.shelf[0]);
        if (reset) m.resets += 1;
        m.gen += 1;
        const total = @as(usize, side) * side;
        if (m.buf.items.len != total) {
            m.buf.resize(self.gpa, total) catch return .{};
            @memset(m.buf.items, 0);
        } else if (reset) {
            @memset(m.buf.items, 0);
        }
        const y0: u32 = if (reset or m.size == 0) 0 else m.shelf[1];
        const y1: u32 = @min(side, shelf[1] + shelf[2]);
        if (y1 > y0) {
            objc.msg(void, a.texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
                @as(*anyopaque, m.buf.items[@as(usize, y0) * side ..].ptr),
                @as(objc.NSUInteger, side),
                Region{ .x = 0, .y = y0, .z = 0, .w = side, .h = y1 - y0, .d = 1 },
                @as(objc.NSUInteger, 0),
            });
        }
        const dirty: DirtyRect = if (reset or m.size == 0 or shelf[1] != m.shelf[1])
            .{ .x = 0, .y = y0, .width = side, .height = y1 - y0 }
        else
            .{ .x = m.shelf[0], .y = shelf[1], .width = shelf[0] - m.shelf[0], .height = @min(side - shelf[1], shelf[2]) };
        m.shelf = shelf;
        m.size = side;
        m.tex = tex;
        return .{ .pixels = m.buf.items, .width = side, .height = side, .generation = m.gen, .resets = m.resets, .dirty_from_generation = prev_gen, .dirty = dirty };
    }

    fn onClipboardWrite(ctx: ?*anyopaque, s: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx orelse return));
        self.clipboard_buf.clearRetainingCapacity();
        self.clipboard_buf.appendSlice(self.gpa, s) catch return;
        self.clipboard_wrote = true;
    }

    fn onWake(ctx: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.woke.store(true, .release);
    }

    fn dupeOpString(self: *Host, s: []const u8) ![]u8 {
        const dup = try self.gpa.dupe(u8, s);
        errdefer self.gpa.free(dup);
        try self.op_strings.append(self.gpa, dup);
        return dup;
    }

    fn flushPendingToOps(self: *Host) !void {
        if (self.pending_chars.items.len > 0) {
            try self.pending_ops.append(self.gpa, .{ .insert = try self.dupeOpString(self.pending_chars.items) });
            self.pending_chars.clearRetainingCapacity();
        }
        if (self.ctx.input.key) |k| {
            const in = self.ctx.input;
            const cmd: ?input.Command = textfield_keys.commandOf(k, in.shift, in.ctrl or in.alt) orelse switch (k) {
                .home => .move_line_start,
                .end => .move_line_end,
                .up => if (in.shift) .select_up else .move_up,
                .down => if (in.shift) .select_down else .move_down,
                .enter => if (in.shift or in.alt) .insert_line_break else .insert_newline,
                .tab => .insert_tab,
                .escape => .cancel,
                else => null,
            };
            if (cmd) |c| {
                try self.pending_ops.append(self.gpa, .{ .command = c });
                self.ctx.input.key = null;
            }
        }
    }

    fn clearPendingInput(self: *Host) void {
        for (self.op_strings.items) |s| self.gpa.free(s);
        self.op_strings.clearRetainingCapacity();
        self.pending_ops.clearRetainingCapacity();
        self.pending_chars.clearRetainingCapacity();
    }

    fn applyStandardShortcut(self: *Host, sc: input.Shortcut) void {
        if (!(sc.cmd or sc.ctrl) or sc.alt) return;
        switch (sc.key) {
            'c' => if (!sc.shift) self.pending_ops.append(self.gpa, .{ .command = .copy }) catch {},
            'x' => if (!sc.shift) self.pending_ops.append(self.gpa, .{ .command = .cut }) catch {},
            'a' => if (!sc.shift) self.pending_ops.append(self.gpa, .{ .command = .select_all }) catch {},
            'z' => self.ctx.undo_op = if (sc.shift) .redo else .undo,
            'y' => if (!sc.shift) {
                self.ctx.undo_op = .redo;
            },
            else => {},
        }
    }
};

fn specialKeyCommand(k: input.Key, cmd: bool, ctrl: bool, alt: bool, shift: bool) ?input.Command {
    if (cmd and !ctrl and !alt) return switch (k) {
        .left => if (shift) .select_line_start else .move_line_start,
        .right => if (shift) .select_line_end else .move_line_end,
        .up => if (shift) .select_doc_start else .move_doc_start,
        .down => if (shift) .select_doc_end else .move_doc_end,
        .backspace => .delete_to_line_start,
        .delete => .delete_to_line_end,
        else => null,
    };
    return switch (k) {
        .home => if (cmd or ctrl) (if (shift) .select_doc_start else .move_doc_start) else if (shift) .select_line_start else null,
        .end => if (cmd or ctrl) (if (shift) .select_doc_end else .move_doc_end) else if (shift) .select_line_end else null,
        else => null,
    };
}

fn shortcutKeyOf(k: input.Key) ?u21 {
    return switch (k) {
        .enter => input.Shortcut.enter,
        .escape => input.Shortcut.escape,
        .tab => input.Shortcut.tab,
        .backspace => input.Shortcut.backspace,
        .delete => input.Shortcut.forward_delete,
        .up => input.Shortcut.up,
        .down => input.Shortcut.down,
        .left => input.Shortcut.left,
        .right => input.Shortcut.right,
        .home => input.Shortcut.home,
        .end => input.Shortcut.end,
        .page_up => input.Shortcut.page_up,
        .page_down => input.Shortcut.page_down,
        .space => ' ',
    };
}
