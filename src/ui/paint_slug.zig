//! Analytic vector text (`Kind.vector_text`) emission, geometric transform
//! detection, and per-glyph bitmap fallback for `paint.zig`.
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const text_mod = @import("text.zig");
const native_windows = @import("dwrite.zig").enabled;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const Limit = struct { end: f32, fade: f32 = 0 };

pub const ResolvedColor = struct {
    color: [4]f32,
    tone: types.Color,
};

fn halfTowardZero(v: f32) f32 {
    return if (v >= 0) @ceil(v - 0.5) else @floor(v + 0.5);
}

/// Returns true when `n` applies a geometric scale, rotation, spin, 3D turn,
/// scale pulse, non-translation affine transform, or has an active/non-identity
/// motion channel on `scale`, `rotation`, or `turn`.
pub fn hasGeometricTransform(c: *const Context, n: *const ctx_mod.Node) bool {
    const st = &n.style;
    if (st.scale != 1.0 or st.rotation != 0.0 or st.spin != 0.0 or st.turn != 0.0) return true;
    if (!c.reduce_motion) {
        if (st.pulse) |p| if (p.period > 0 and p.scale_amp != 0) return true;
    }
    if (st.transform) |m| {
        if (m.a != 1.0 or m.b != 0.0 or m.c != 0.0 or m.d != 1.0) return true;
    }
    if (c.motion_store.map.getPtr(n.id)) |ms| {
        const checks = [_]struct { idx: u4, ident: f64 }{
            .{ .idx = 2, .ident = 1.0 }, // scale
            .{ .idx = 11, .ident = 0.0 }, // rotation
            .{ .idx = 12, .ident = 0.0 }, // turn
        };
        for (checks) |chk| {
            if ((ms.has & (@as(u16, 1) << chk.idx)) != 0) {
                const ch = ms.ch[chk.idx];
                if (ch.moving or ch.value != chk.ident) return true;
            }
        }
    }
    return false;
}

pub fn resolveGlyphColor(
    t: *const ctx_mod.Content.Text,
    span_i: *usize,
    at: usize,
    gx: f32,
    base: [4]f32,
    opacity: f32,
    inner_right: f32,
) ?ResolvedColor {
    var color = base;
    var tone = t.color;
    if (t.spans.len > 0) {
        while (span_i.* < t.spans.len and t.spans[span_i.*].end <= at) span_i.* += 1;
        // Glyphs of a run are mostly in order; a ligature or bidi may step back.
        if (span_i.* < t.spans.len and t.spans[span_i.*].start > at) {
            span_i.* = 0;
            while (span_i.* < t.spans.len and t.spans[span_i.*].end <= at) span_i.* += 1;
        }
        if (span_i.* < t.spans.len and t.spans[span_i.*].start <= at) if (t.spans[span_i.*].color) |sc| {
            color = gpu.color4(sc.alpha(opacity));
            tone = sc;
        };
    }
    if (t.style.fade) |fd| {
        color[3] *= std.math.clamp((inner_right - fd.clear - gx) / @max(fd.ramp, 0.001), 0, 1);
        if (color[3] <= 0) return null;
    }
    return .{ .color = color, .tone = tone };
}

pub fn emitBitmapGlyph(
    c: *Context,
    out: *std.ArrayList(gpu.Instance),
    g: text_mod.Glyph,
    x: f32,
    baseline: f32,
    color: [4]f32,
    tone: types.Color,
    clip4: [4]f32,
    limit: ?Limit,
) void {
    const scale = c.scale;
    const gpui_snap = c.text.glyph_snap == .half_toward_zero;
    const pen = (x + g.x) * scale;
    const positions: f32 = if (native_windows) @floatFromInt(c.text.positions(g)) else text_mod.subpixel_bins;
    const quantized = if (gpui_snap) halfTowardZero(pen * positions) / positions else if (native_windows) @round(pen * positions) / positions else pen;
    const px = @floor(quantized);
    const phase = (quantized - px) * text_mod.subpixel_bins;
    const bin: u8 = @intFromFloat(@min(text_mod.subpixel_bins - 1, if (native_windows) @round(phase) else @floor(phase + if (gpui_snap) @as(f32, 0.001) else 0)));
    const sp = c.text.glyph(g, bin, @TypeOf(c.text.*).dilationFor(tone.r, tone.g, tone.b)) orelse return;
    var uv = sp.uv;
    if (!text_mod.portable and 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2] < 0.5) {
        const du = uv[2] - uv[0];
        uv[0] += du;
        uv[2] += du;
    }
    out.append(c.gpa, .{
        .rect = .{ px / scale + sp.x, baseline - g.y + sp.y, sp.w, sp.h },
        .color = color,
        .uv = uv,
        .kind = gpu.Kind.text,
        .radius = if (limit) |l| l.end else 0,
        .border_width = if (limit) |l| l.fade else 0,
        .clip = if (limit) |l| .{ clip4[0], clip4[1], @min(clip4[2], l.end), clip4[3] } else clip4,
    }) catch {};
}

pub fn emitVectorText(
    c: *Context,
    out: *std.ArrayList(gpu.Instance),
    t: *const ctx_mod.Content.Text,
    lay: text_mod.Layout,
    start: usize,
    x: f32,
    raw_baseline: f32,
    base: [4]f32,
    clip4: [4]f32,
    opacity: f32,
    limit: ?Limit,
    inner_right: f32,
) void {
    const style = t.style;
    var span_i: usize = 0;
    for (lay.glyphs) |g| {
        const gx = x + g.x;
        if (gx > clip4[2]) break;
        if (limit) |l| if (gx >= l.end) break;
        const resolved = resolveGlyphColor(t, &span_i, start + g.index, gx, base, opacity, inner_right) orelse continue;
        if (c.text.vectorGlyph(&lay, g.font, g.glyph)) |entry| {
            if (entry.blob == 0) continue;
            const pt_size = c.text.runFontSize(g.font, style.size * c.text.zoom);
            const pad_pt = @max(@as(f32, 2.0), pt_size * 0.08);
            const pad_em = pad_pt / @max(pt_size, 1e-3);
            const raw_x0 = gx + (entry.bounds[0] - pad_em) * pt_size;
            const raw_y0 = raw_baseline - g.y - (entry.bounds[3] + pad_em) * pt_size;
            const raw_x1 = gx + (entry.bounds[2] + pad_em) * pt_size;
            const raw_y1 = raw_baseline - g.y - (entry.bounds[1] - pad_em) * pt_size;
            const snap_s = @max(c.scale, 1e-4);
            const x0 = @floor(raw_x0 * snap_s) / snap_s;
            const y0 = @floor(raw_y0 * snap_s) / snap_s;
            const x1 = @ceil(raw_x1 * snap_s) / snap_s;
            const y1 = @ceil(raw_y1 * snap_s) / snap_s;
            const inv_pt = 1.0 / @max(pt_size, 1e-3);
            const em_u0 = (x0 - gx) * inv_pt;
            const em_v0 = (raw_baseline - g.y - y0) * inv_pt;
            const em_u1 = (x1 - gx) * inv_pt;
            const em_v1 = (raw_baseline - g.y - y1) * inv_pt;
            const rect: [4]f32 = .{ x0, y0, x1 - x0, y1 - y0 };
            const glyph_clip: [4]f32 = if (limit) |l| .{ clip4[0], clip4[1], @min(clip4[2], l.end), clip4[3] } else clip4;
            var inst = gpu.vectorGlyph(
                rect,
                .{ em_u0, em_v0, em_u1, em_v1 },
                entry.blob,
                .{ .r = resolved.color[0], .g = resolved.color[1], .b = resolved.color[2], .a = resolved.color[3] },
                glyph_clip,
            );
            if (limit) |l| if (l.fade > 0) {
                inst.radius = l.end;
                inst.border_width = l.fade;
            };
            out.append(c.gpa, inst) catch {};
        } else {
            emitBitmapGlyph(c, out, g, x, raw_baseline, resolved.color, resolved.tone, clip4, limit);
        }
    }
}

pub fn snapScaledVectorQuad(i: *gpu.Instance, scale: f32) void {
    if (i.kind != gpu.Kind.vector_text or i.rect[2] <= 0 or i.rect[3] <= 0) return;
    const snap_s = @max(scale, 1e-4);
    const sx0 = i.rect[0];
    const sy0 = i.rect[1];
    const du_dx = (i.uv[2] - i.uv[0]) / i.rect[2];
    const dv_dy = (i.uv[3] - i.uv[1]) / i.rect[3];
    const nx0 = @floor(sx0 * snap_s) / snap_s;
    const ny0 = @floor(sy0 * snap_s) / snap_s;
    const nx1 = @ceil((sx0 + i.rect[2]) * snap_s) / snap_s;
    const ny1 = @ceil((sy0 + i.rect[3]) * snap_s) / snap_s;
    i.uv = .{
        i.uv[0] + (nx0 - sx0) * du_dx,
        i.uv[1] + (ny0 - sy0) * dv_dy,
        i.uv[0] + (nx1 - sx0) * du_dx,
        i.uv[1] + (ny1 - sy0) * dv_dy,
    };
    i.rect = .{ nx0, ny0, nx1 - nx0, ny1 - ny0 };
}
