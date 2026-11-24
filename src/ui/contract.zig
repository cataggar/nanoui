//! The host-facing render packet contract for embedded nanoui (`ui.embed`):
//! comptime-checked `gpu.Instance` binary layout, incremental atlas views,
//! one-shot host side effects, `FrameOutput`, and zero-allocation barrier
//! splitting across glass panes and offscreen opacity/mask layers.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const ctx_mod = @import("context.zig");
const access = @import("access.zig");

pub const Instance = gpu.Instance;
pub const Kind = gpu.Kind;

pub const instance_stride: usize = 192;
pub const instance_vec4_count: usize = 12;
pub const vertices_per_instance: u32 = 4;

pub const BlendMode = enum {
    /// `out = src * 1 + dst * (1 - src.a)` (fragment outputs premultiplied sRGB).
    premultiplied_over,
    /// `out = src * 0 + dst * (1 - src.a)` (`Kind.hole` alpha cutout).
    punch_out_hole,
};

pub fn blendModeFor(kind: f32) BlendMode {
    return if (kind == gpu.Kind.hole) .punch_out_hole else .premultiplied_over;
}

comptime {
    std.debug.assert(@sizeOf(gpu.Instance) == instance_stride);
    std.debug.assert(@sizeOf(gpu.Instance) == instance_vec4_count * 16);
    std.debug.assert(@alignOf(gpu.Instance) == 4);
    std.debug.assert(@typeInfo(gpu.Instance).@"struct".field_names.len == 15);
    std.debug.assert(@offsetOf(gpu.Instance, "rect") == 0);
    std.debug.assert(@offsetOf(gpu.Instance, "color") == 16);
    std.debug.assert(@offsetOf(gpu.Instance, "border_color") == 32);
    std.debug.assert(@offsetOf(gpu.Instance, "uv") == 48);
    std.debug.assert(@offsetOf(gpu.Instance, "clip") == 64);
    std.debug.assert(@offsetOf(gpu.Instance, "radius") == 80);
    std.debug.assert(@offsetOf(gpu.Instance, "border_width") == 84);
    std.debug.assert(@offsetOf(gpu.Instance, "kind") == 88);
    std.debug.assert(@offsetOf(gpu.Instance, "clip_round") == 92);
    std.debug.assert(@offsetOf(gpu.Instance, "xf") == 96);
    std.debug.assert(@offsetOf(gpu.Instance, "pulse") == 112);
    std.debug.assert(@offsetOf(gpu.Instance, "vel") == 128);
    std.debug.assert(@offsetOf(gpu.Instance, "turn") == 144);
    std.debug.assert(@offsetOf(gpu.Instance, "m") == 160);
    std.debug.assert(@offsetOf(gpu.Instance, "mt") == 176);
    std.debug.assert(Kind.vector_text == 13);
}

/// Sub-rectangle modified in an atlas since the previous `Host.frame` call.
pub const DirtyRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn fromArray(r: [4]u32) DirtyRect {
        return .{ .x = r[0], .y = r[1], .width = r[2], .height = r[3] };
    }

    pub fn isEmpty(r: DirtyRect) bool {
        return r.width == 0 or r.height == 0;
    }
};

/// Single-channel `R8_UNORM` coverage mask (`width * height` bytes, top row first).
/// `dirty` covers every modification made between `dirty_from_generation` and `generation`.
pub const GlyphAtlas = struct {
    pixels: []const u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    generation: u64 = 0,
    resets: u64 = 0,
    dirty_from_generation: u64 = 0,
    dirty: ?DirtyRect = null,
};

/// Premultiplied sRGB `BGRA8_UNORM` picture atlas (`width * height * 4` bytes, top row first).
/// `dirty` covers every modification made between `dirty_from_generation` and `generation`.
pub const ImageAtlas = struct {
    pixels: []const u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    generation: u64 = 0,
    resets: u64 = 0,
    dirty_from_generation: u64 = 0,
    dirty: ?DirtyRect = null,
};

/// Packed 1024-wide `R32_UINT` Slug vector glyph word table (`slug_store.zig`).
pub const VectorGlyphTable = struct {
    words: []const u32 = &.{},
    width: u32 = 1024,
    height: u32 = 0,
    used_words: u32 = 0,
    generation: u64 = 0,
    resets: u64 = 0,
};

pub const CursorState = struct {
    shape: ctx_mod.Cursor = .arrow,
    custom: ?*anyopaque = null,
    tooltip: ?[]const u8 = null,
};

/// Focused text-input state and candidate-window anchor geometry in view points.
/// Byte offsets (`caret`, `anchor`, `marked`) index UTF-8 `text`.
pub const ImeState = struct {
    id: u64,
    rect: types.Rect,
    caret_rect: types.Rect,
    clause_rect: ?types.Rect = null,
    text: []const u8,
    caret: usize,
    anchor: usize,
    marked: ?[2]usize = null,
    multiline: bool = false,
    password: bool = false,
};

/// Borrowed output of one `Host.frame` evaluation. All slices remain valid
/// until the next `Host.frame` or `Host.deinit` call on the same host.
pub const FrameOutput = struct {
    size: types.Size,
    scale: f32,
    pixel_size: [2]u32,
    clear_color: types.Color,
    time: f64,
    instances: []const gpu.Instance,
    gradients: []const [4]f32,
    textures: []const gpu.Texture,
    glyph_atlas: GlyphAtlas,
    image_atlas: ImageAtlas,
    vector_glyphs: VectorGlyphTable = .{},
    cursor: CursorState,
    clipboard_write: ?[]const u8,
    ime: ?ImeState,
    a11y: []const access.Item,
    stage_rects: []const types.Rect,
    wants_frame: bool,
    next_frame_in: ?f32,
    close_requested: bool,
    stats: ctx_mod.FrameStats,
};

pub const PassRun = union(enum) {
    draw: struct { start: usize, end: usize },
    glass: usize,
    layer: struct { begin: usize, end: usize, bounds: types.Rect, masked: bool },
};

pub const EffectiveClear = struct {
    first: usize,
    clear: types.Color,
};

/// Promotes the last full-viewport opaque background quad (`gpu.lastCover`) to
/// the render pass clear color and skips everything hidden behind it.
pub fn effectiveClear(instances: []const gpu.Instance, viewport: types.Size, fallback: types.Color) EffectiveClear {
    const cover = if (viewport.w > 0 and viewport.h > 0) gpu.lastCover(instances, viewport) else null;
    if (cover) |k| {
        const c = instances[k].color;
        return .{ .first = k + 1, .clear = .{ .r = c[0], .g = c[1], .b = c[2], .a = 1 } };
    }
    return .{ .first = 0, .clear = fallback };
}

/// Zero-allocation iterator over top-level or nested layer barrier runs.
pub const PassIterator = struct {
    instances: []const gpu.Instance,
    cursor: usize,
    limit: usize,

    pub fn next(it: *PassIterator) ?PassRun {
        while (it.cursor < it.limit) {
            const k = it.instances[it.cursor].kind;
            if (k == gpu.Kind.glass) {
                const idx = it.cursor;
                it.cursor += 1;
                return .{ .glass = idx };
            }
            if (k == gpu.Kind.layer_begin) {
                const begin = it.cursor;
                const end = gpu.groupEnd(it.instances[0..it.limit], begin) orelse {
                    it.cursor += 1;
                    continue;
                };
                const r = it.instances[begin].rect;
                const end_bc = it.instances[end].border_color;
                it.cursor = end + 1;
                return .{ .layer = .{
                    .begin = begin,
                    .end = end,
                    .bounds = .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] },
                    .masked = end_bc[2] > 0 or end_bc[3] > 0,
                } };
            }
            if (k == gpu.Kind.layer_end) {
                it.cursor += 1;
                continue;
            }
            const start = it.cursor;
            var end = start + 1;
            while (end < it.limit) : (end += 1) {
                const nk = it.instances[end].kind;
                if (nk == gpu.Kind.glass or nk == gpu.Kind.layer_begin or nk == gpu.Kind.layer_end) break;
            }
            it.cursor = end;
            return .{ .draw = .{ .start = start, .end = end } };
        }
        return null;
    }
};

/// Walks `instances` in barrier order starting after any `gpu.lastCover` quad.
pub fn iterPasses(instances: []const gpu.Instance, viewport: types.Size) PassIterator {
    const first = effectiveClear(instances, viewport, .{}).first;
    return .{ .instances = instances, .cursor = first, .limit = instances.len };
}

/// Walks a sub-span `instances[start..end]` (such as `layer.begin + 1 .. layer.end`)
/// while preserving indices into the full `instances` buffer.
pub fn iterSpan(instances: []const gpu.Instance, start: usize, end: usize) PassIterator {
    const clamped_end = @min(end, instances.len);
    return .{ .instances = instances, .cursor = @min(start, clamped_end), .limit = clamped_end };
}

test "effectiveClear and iterPasses split cover quads, glass, and nested opacity/masked layers" {
    const vp: types.Size = .{ .w = 200, .h = 100 };
    const fallback: types.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const hidden_quad: gpu.Instance = .{ .rect = .{ 4, 4, 12, 12 }, .color = .{ 1, 0, 0, 1 } };
    const cover_quad: gpu.Instance = .{ .rect = .{ 0, 0, 200, 100 }, .color = .{ 0.1, 0.2, 0.3, 1 } };
    const card: gpu.Instance = .{ .rect = .{ 10, 10, 40, 20 }, .color = .{ 1, 1, 1, 1 } };
    const glyph: gpu.Instance = .{ .rect = .{ 12, 14, 8, 10 }, .color = .{ 0, 0, 0, 1 }, .kind = gpu.Kind.text };
    const pane: gpu.Instance = .{ .rect = .{ 20, 20, 60, 40 }, .color = .{ 1, 1, 1, 0.5 }, .kind = gpu.Kind.glass };
    const outer_begin: gpu.Instance = .{ .rect = .{ 8, 16, 120, 70 }, .color = .{ 1, 1, 1, 1 }, .kind = gpu.Kind.layer_begin };
    const inner_begin: gpu.Instance = .{ .rect = .{ 12, 20, 100, 50 }, .color = .{ 1, 1, 1, 1 }, .kind = gpu.Kind.layer_begin };
    const inner_end: gpu.Instance = .{
        .rect = .{ 12, 20, 100, 50 },
        .color = .{ 1, 1, 1, 1 },
        .border_color = .{ 20, 70, 12, 12 },
        .kind = gpu.Kind.layer_end,
    };
    const outer_end: gpu.Instance = .{ .rect = .{ 8, 16, 120, 70 }, .color = .{ 1, 1, 1, 0.6 }, .kind = gpu.Kind.layer_end };
    const hole: gpu.Instance = .{ .rect = .{ 150, 10, 30, 30 }, .color = .{ 0, 0, 0, 1 }, .kind = gpu.Kind.hole };

    const stream = [_]gpu.Instance{
        hidden_quad, // 0 (culled by cover_quad)
        cover_quad, // 1 (becomes clear_color)
        card, // 2
        glyph, // 3
        pane, // 4
        outer_begin, // 5
        card, // 6
        inner_begin, // 7
        glyph, // 8
        inner_end, // 9
        outer_end, // 10
        hole, // 11
    };

    const ec = effectiveClear(&stream, vp, fallback);
    try std.testing.expectEqual(@as(usize, 2), ec.first);
    try std.testing.expectEqual(types.Color{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1 }, ec.clear);
    try std.testing.expectEqual(BlendMode.premultiplied_over, blendModeFor(gpu.Kind.quad));
    try std.testing.expectEqual(BlendMode.punch_out_hole, blendModeFor(gpu.Kind.hole));

    const dirty = DirtyRect.fromArray(.{ 4, 8, 32, 16 });
    try std.testing.expect(!dirty.isEmpty());
    try std.testing.expect((DirtyRect{ .x = 0, .y = 0, .width = 0, .height = 10 }).isEmpty());

    var it = iterPasses(&stream, vp);
    try std.testing.expectEqual(PassRun{ .draw = .{ .start = 2, .end = 4 } }, it.next().?);
    try std.testing.expectEqual(PassRun{ .glass = 4 }, it.next().?);
    const outer = it.next().?;
    try std.testing.expectEqual(PassRun{ .layer = .{
        .begin = 5,
        .end = 10,
        .bounds = .{ .x = 8, .y = 16, .w = 120, .h = 70 },
        .masked = false,
    } }, outer);
    try std.testing.expectEqual(PassRun{ .draw = .{ .start = 11, .end = 12 } }, it.next().?);
    try std.testing.expect(it.next() == null);

    var outer_it = iterSpan(&stream, outer.layer.begin + 1, outer.layer.end);
    try std.testing.expectEqual(PassRun{ .draw = .{ .start = 6, .end = 7 } }, outer_it.next().?);
    const inner = outer_it.next().?;
    try std.testing.expectEqual(PassRun{ .layer = .{
        .begin = 7,
        .end = 9,
        .bounds = .{ .x = 12, .y = 20, .w = 100, .h = 50 },
        .masked = true,
    } }, inner);
    try std.testing.expect(outer_it.next() == null);

    var inner_it = iterSpan(&stream, inner.layer.begin + 1, inner.layer.end);
    try std.testing.expectEqual(PassRun{ .draw = .{ .start = 8, .end = 9 } }, inner_it.next().?);
    try std.testing.expect(inner_it.next() == null);
}
