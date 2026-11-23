//! A single canvas surface, driven by the JavaScript event loop. This does
//! not implement App/Window or the rest of the desktop platform interface.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const gpu = @import("../ui/gpu.zig");
const text = @import("../ui/text.zig");
const frames = @import("../ui/frame.zig");
const webgpu = @import("../ui/webgpu.zig");
pub const Renderer = webgpu.Renderer;
pub const Target = webgpu.Target;

const host = if (@import("builtin").is_test) struct {
    pub fn request_frame() void {}
    pub fn request_after(_: f64) void {}
    pub fn now_ms() f64 {
        return 0;
    }
    pub fn clipboard_write(_: [*]const u8, _: usize) void {}
    pub fn run_forever() noreturn {
        unreachable;
    }
} else struct {
    pub extern "nanoui_web" fn request_frame() void;
    pub extern "nanoui_web" fn request_after(ms: f64) void;
    pub extern "nanoui_web" fn now_ms() f64;
    pub extern "nanoui_web" fn clipboard_write(ptr: [*]const u8, len: usize) void;
    pub extern "nanoui_web" fn run_forever() noreturn;
};

pub const request_frame = host.request_frame;
pub const request_after = host.request_after;
pub const now_ms = host.now_ms;
pub const clipboard_write = host.clipboard_write;
const run_forever = host.run_forever;

const image_cache_host = @import("image_cache_host.zig");
pub const image_cache = @import("image_cache.zig");
pub const ImageCache = image_cache.ImageCache;

pub var active: ?*Surface = null;
comptime {
    _ = @import("exports.zig");
    _ = @import("exports_input.zig");
    _ = &image_cache_host.exports.nanoui_web_image_complete;
}

/// Optional fallback fonts shipped with the web examples. Applications may
/// instead register their own embedded fonts with ui.registerFont.
pub fn registerBundledFonts() bool {
    return ui.registerFont(@embedFile("../ui/web_fonts/DejaVuSans.ttf")) and
        ui.registerFont(@embedFile("../ui/web_fonts/DejaVuSans-Bold.ttf"));
}

pub const Options = struct {
    allocator: std.mem.Allocator = std.heap.wasm_allocator,
    width: f32 = 420,
    height: f32 = 300,
    scale: f32 = 1,
    theme: ui.Theme = .light,
};

pub const Surface = struct {
    gpa: std.mem.Allocator,
    ctx: ui.Context,
    text: text.TextSystem,
    view: ui.View,
    renderer: webgpu.Renderer,
    instances: std.ArrayList(gpu.Instance) = .empty,
    size: ui.Size,
    scale: f32,
    theme: ui.Theme,
    dirty: bool = true,
    lost: bool = false,
    last_time: f64 = 0,
    start_time: f64 = 0,
    before_encode: ?gpu.BeforeEncode = null,
    after_frame_ctx: ?*anyopaque = null,
    after_frame: ?*const fn (?*anyopaque, *Surface) bool = null,
    frame_count: u32 = 0,
    pending_chars: std.ArrayList(u8) = .empty,
    pending_ops: std.ArrayList(ui.TextOp) = .empty,
    op_strings: std.ArrayList([]u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    pending_text: std.ArrayList(u8) = .empty,
    pending_caret: usize = 0,
    pending_anchor: usize = 0,
    pending_marked: ?[2]usize = null,
    pending_text_valid: bool = false,
    clipboard_wrote: bool = false,
    ime_state: [8]f32 = @splat(0),
    frame_log: ?ui.FrameLog = null,
    last_record: u32 = 0xffffffff,

    pub fn clearPendingInput(s: *Surface) void {
        for (s.op_strings.items) |str| s.gpa.free(str);
        s.op_strings.clearRetainingCapacity();
        s.pending_ops.clearRetainingCapacity();
        s.pending_chars.clearRetainingCapacity();
        s.pending_text.clearRetainingCapacity();
        s.pending_marked = null;
        s.pending_text_valid = false;
    }

    pub fn recordFrames(s: *Surface, allocator: std.mem.Allocator) !*ui.FrameLog {
        if (s.frame_log == null) s.frame_log = try ui.FrameLog.init(allocator, null);
        return &s.frame_log.?;
    }

    pub fn requestFrame(s: *Surface) void {
        s.dirty = true;
        if (!s.lost) request_frame();
    }

    pub fn frame(s: *Surface, milliseconds: f64) bool {
        if (s.lost or s.size.w <= 0 or s.size.h <= 0) return false;
        const time = milliseconds / 1000;
        const dt: f32 = if (s.last_time > 0) @floatCast(std.math.clamp(time - s.last_time, 0, 0.5)) else 1.0 / 60.0;
        s.last_time = time;
        s.text.setScale(s.scale);
        s.dirty = false;
        s.ctx.frame_time = dt;
        s.ctx.renderer = if (webgpu.api.backend() == 1) "WebGL2" else "WebGPU";
        if (s.pending_chars.items.len > 0 and s.ctx.input.chars.len == 0) s.ctx.input.chars = s.pending_chars.items;
        if (s.pending_ops.items.len > 0) s.ctx.input.ops = s.pending_ops.items;
        const theme = s.ctx.theme_chosen orelse s.theme;
        const result = frames.run(&s.ctx, s.view, &s.text, &s.instances, s.size, s.scale, theme, dt, time - s.start_time);
        s.clearPendingInput();
        if (!std.meta.eql(theme, s.ctx.theme_chosen orelse s.theme)) s.dirty = true;
        const after_start = now_ms();
        if (s.after_frame) |f| if (f(s.after_frame_ctx, s)) {
            s.dirty = true;
        };
        const after_ms = now_ms() - after_start;
        s.renderer.before_encode = s.before_encode;
        s.renderer.gradients = s.ctx.gradients.items;
        s.renderer.textures = s.ctx.textures.items;
        s.renderer.sync(s.text.atlas.mask(), s.text.atlas.generation, s.text.images.pictures(), s.text.images.generation);
        const width: u32 = @intFromFloat(@round(s.size.w * s.scale));
        const height: u32 = @intFromFloat(@round(s.size.h * s.scale));
        const encode_start = now_ms();
        s.renderer.drawCanvas(s.instances.items, s.size, s.scale, s.ctx.theme.background, width, height, time - s.start_time);
        if (s.frame_log) |*log| s.last_record = @intCast(log.append(.{
            .t = time,
            .kind = .input,
            .interval_ms = dt * 1000,
            .duration = dt,
            .dt = dt,
            .build_ms = s.ctx.stats.build_ms,
            .layout_ms = s.ctx.stats.layout_ms,
            .paint_ms = s.ctx.stats.paint_ms,
            .after_frame_ms = after_ms,
            .drawable_wait_ms = 0,
            .encode_ms = now_ms() - encode_start,
            .sync = false,
            .nodes = s.ctx.stats.nodes,
            .instances = s.ctx.stats.instances,
            .atlas_reset = s.text.atlas.reset_during_frame,
            .animating = s.ctx.animating,
        }));
        s.frame_count +%= 1;
        const more = s.dirty or s.ctx.animating or result.hot_changed or s.ctx.time_driven == .fast;
        if (!more) {
            s.last_time = 0;
            if (s.ctx.frame_in) |delay| request_after(delay * 1000) else if (s.ctx.time_driven == .slow) request_after(1000.0 / 24.0);
        }
        return more;
    }

    pub fn setDevice(s: *Surface) !void {
        s.renderer.deinit();
        s.renderer = try .init();
        s.text.images.invalidateAtlas();
        s.lost = false;
        s.requestFrame();
    }

    pub fn deinit(s: *Surface) void {
        if (active == s) active = null;
        if (s.frame_log) |*log| log.deinit();
        s.clearPendingInput();
        s.op_strings.deinit(s.gpa);
        s.pending_ops.deinit(s.gpa);
        s.pending_chars.deinit(s.gpa);
        s.pending_text.deinit(s.gpa);
        s.scratch.deinit(s.gpa);
        s.renderer.deinit();
        s.instances.deinit(s.gpa);
        s.ctx.deinit();
        s.text.deinit();
        s.gpa.destroy(s);
    }
};

/// Mount one view. Its state must outlive the surface; `run` preserves main's
/// stack by unwinding to JavaScript without running Zig's deferred teardown.
pub fn mount(view: ui.View, options: Options) !*Surface {
    if (active != null) return error.AlreadyMounted;
    const s = try options.allocator.create(Surface);
    errdefer options.allocator.destroy(s);
    s.* = .{
        .gpa = options.allocator,
        .ctx = undefined,
        .text = .init(options.allocator),
        .view = view,
        .renderer = try .init(),
        .size = .{ .w = options.width, .h = options.height },
        .scale = options.scale,
        .theme = options.theme,
        .start_time = now_ms() / 1000,
    };
    s.ctx = .init(s.gpa, &s.text);
    s.text.images.sink = .{ .ctx = &s.renderer, .upload = webgpu.Renderer.uploadImage };
    s.ctx.waker = .{ .ctx = s, .wake = wake };
    s.ctx.clipboard = .{ .ctx = s, .write = writeClipboard };
    active = s;
    s.requestFrame();
    return s;
}

fn writeClipboard(ctx: ?*anyopaque, text_bytes: []const u8) void {
    if (ctx) |p| {
        const s: *Surface = @ptrCast(@alignCast(p));
        s.clipboard_wrote = true;
    }
    clipboard_write(text_bytes.ptr, text_bytes.len);
}

fn wake(ctx: *anyopaque) void {
    const s: *Surface = @ptrCast(@alignCast(ctx));
    s.requestFrame();
}

pub fn run() noreturn {
    request_frame();
    run_forever();
}

test "web surface mounts, handles pointer and IME exports, and snapshots on WASI" {
    if (@import("builtin").os.tag != .wasi) return error.SkipZigTest;
    const ext = struct {
        extern fn nanoui_web_frame(time: f64) u32;
        extern fn nanoui_web_pointer(kind: u32, x: f32, y: f32, button: u32, mods: u32, clicks: u32) void;
        extern fn nanoui_web_input_ptr(len: usize) usize;
        extern fn nanoui_web_ime_set_marked(len: usize, sel_start_utf16: u32, sel_end_utf16: u32) void;
        extern fn nanoui_web_ime_commit(len: usize) void;
        extern fn nanoui_web_ime_info(out_ptr: [*]u32) u32;
        extern fn nanoui_web_snapshot() usize;
        extern fn nanoui_web_frames() u32;
        extern fn nanoui_web_destroy() void;
    };
    const Demo = struct {
        buf: ui.TextBuffer = .{},
        clicks: u32 = 0,
        fn view(d: *@This(), c: *ui.Context) void {
            const col = ui.div(c).column().sizeFull().p(8).gap(6);
            defer col.end();
            _ = ui.textField(c, &d.buf, .{});
            if (ui.button(c, "Tap", .{}).clicked) d.clicks += 1;
        }
    };
    var demo: Demo = .{};
    defer demo.buf.deinit();
    demo.buf.focus();
    _ = try mount(.init(&demo, Demo.view), .{ .allocator = std.testing.allocator, .width = 200, .height = 120 });
    defer ext.nanoui_web_destroy();

    _ = ext.nanoui_web_frame(16);
    try std.testing.expectEqual(@as(u32, 1), ext.nanoui_web_frames());

    const composing = "かな";
    const scratch: [*]u8 = @ptrFromInt(ext.nanoui_web_input_ptr(composing.len));
    @memcpy(scratch[0..composing.len], composing);
    ext.nanoui_web_ime_set_marked(composing.len, 0, 2);
    _ = ext.nanoui_web_frame(32);
    var ime_out: [10]u32 = undefined;
    try std.testing.expectEqual(@as(u32, 1), ext.nanoui_web_ime_info(&ime_out));
    try std.testing.expect(ime_out[8] & 4 != 0);

    @memcpy(scratch[0..composing.len], composing);
    ext.nanoui_web_ime_commit(composing.len);
    _ = ext.nanoui_web_frame(48);
    try std.testing.expectEqualStrings("かな", demo.buf.text());
    ext.nanoui_web_pointer(0, 20, 60, 0, 0, 0);
    _ = ext.nanoui_web_frame(64);
    try std.testing.expect(ext.nanoui_web_snapshot() != 0);
}
