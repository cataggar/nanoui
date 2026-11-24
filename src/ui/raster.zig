//! The renderer on the CPU: the instances `shader.metal` draws, drawn to
//! the same pixels in memory (BGRA, premultiplied, sRGB-encoded values
//! blended as the GPU blends them). Windows present them where nanoui has
//! no GPU renderer, and the Tester renders with it there. A test proves it
//! matches the Metal renderer.
const std = @import("std");
pub const shapes = @import("raster_shapes.zig");
pub const xform = @import("raster_xform.zig");
const raster_slug = @import("raster_slug.zig");
const pictures_mod = @import("raster_picture.zig");
const picture = pictures_mod.picture;
const Source = pictures_mod.Source;
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");
const pic = @import("raster_picture.zig");
const group = @import("raster_group.zig");
pub const freeLayers = group.freeLayers;

/// The glyph atlas, as the shader samples it: one byte per texel.
pub const Mask = struct {
    pixels: []const u8,
    size: u32,
    native_pixels: []const u8 = &.{},
    text_params: @import("text_blend.zig").Params = .{},
    /// For glyphs tagged Classic (254, 127): DirectWrite blends GDI Classic
    /// analyses with their own gamma and contrast, not the system default's.
    classic_text_params: @import("text_blend.zig").Params = .{},
    classic_gray_params: @import("text_blend.zig").Params = .{},
    slug_words: []const u32 = &.{}, slug_height: u32 = 0, slug_used: u32 = 0, slug_resets: u64 = 0, slug_generation: u64 = 0,
};

/// The image atlas: BGRA premultiplied, `size` × `size` (empty: none).
pub const Pictures = struct {
    pixels: []const u8 = &.{},
    size: u32 = 0,
    /// The frame's textures (`ui.texture`): their `bgra` is drawn, or
    /// their pixel buffer's planes made display sRGB (`texture_cpu.zig`).
    textures: []const gpu.Texture = &.{},
    /// The frame's gradients of many stops (`Context.gradients`).
    gradients: []const [4]f32 = &.{},
};

/// Draws `instances` over `clear` into `out` (sized `out.width` ×
/// `out.height` pixels, `scale` pixels a point).
pub fn draw(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color) void {
    drawRegion(out, instances, mask, pictures, scale, clear, .{ 0, 0, out.width, out.height });
}

/// `draw`, only within `region` (pixels: x0, y0, x1, y1); the rest of
/// `out` is kept. Over the pixels of an earlier frame, with the `damage`
/// between the two, it makes the same pixels as drawing it all.
pub fn drawRegion(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color, region: [4]usize) void {
    drawRegionDepth(out, instances, mask, pictures, scale, clear, region, 0);
}

/// `drawRegion`, keeping nested group layers at `depth` and deeper so a
/// masked group does not reuse its own or an ancestor's layer buffer.
pub fn drawRegionDepth(out: gpu.Pixels, instances: []const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, clear: types.Color, region: [4]usize, depth: u16) void {
    drawRegionDepthPtr(out, instances, &mask, &pictures, scale, clear, region, depth);
}

pub fn drawRegionDepthPtr(out: gpu.Pixels, instances: []const gpu.Instance, mask: *const Mask, pictures: *const Pictures, scale: f32, clear: types.Color, region: [4]usize, depth: u16) void {
    // Opaque, but on the Mac and for a transparent window (a clear of nothing).
    const alpha = if (mask.native_pixels.len > 0 or clear.a == 0) clear.a else 1;
    const px: [4]u8 = .{ unit(clear.b * alpha), unit(clear.g * alpha), unit(clear.r * alpha), unit(alpha) };
    var job: Band = .{ .out = out, .instances = instances, .mask = mask, .pictures = pictures, .scale = scale, .clear = @bitCast(px), .region = region };
    // Glass reads what's drawn beyond its band, and a group is drawn whole
    // before it is composited: the bands meet before each, which one thread
    // draws.
    var start: usize = 0;
    while (true) {
        var end = start;
        while (end < instances.len and !barrier(instances[end].kind)) end += 1;
        job.instances = instances[start..end];
        if (job.instances.len > 0 or job.clear != null) job.share();
        job.clear = null;
        if (end == instances.len) break;
        if (instances[end].kind == gpu.Kind.glass) {
            drawOnePtr(out, &instances[end], mask, pictures, scale, region);
            start = end + 1;
            continue;
        }
        const end_at = gpu.groupEnd(instances, end) orelse instances.len;
        if (end_at > end + 1 and end_at < instances.len) {
            const span = instances[end + 1 .. end_at];
            group.draw(out, span, &instances[end], &instances[end_at], mask, pictures, scale, region, depth);
        }
        start = if (end_at < instances.len) end_at + 1 else instances.len;
    }
}

fn barrier(kind: f32) bool {
    return kind == gpu.Kind.glass or kind == gpu.Kind.layer_begin;
}

/// The most threads a region is drawn on; 1 draws it on the caller's
/// alone (tests compare the two).
pub var threads: usize = Band.thread_limit;

/// Instances drawn into some of a region's rows. A pixel's color depends
/// only on the instances over it, so bands of rows drawn on threads of
/// their own make the pixels one thread would.
const Band = struct {
    out: gpu.Pixels,
    instances: []const gpu.Instance,
    mask: *const Mask,
    pictures: *const Pictures,
    scale: f32,
    /// The pixel the rows are cleared to first, if they are.
    clear: ?u32,
    region: [4]usize,

    const thread_limit = 16;
    /// Fewer pixels than this a thread: not worth starting one.
    const min_pixels = 1 << 17;

    fn rows(job: *const Band, y0: usize, y1: usize) void {
        const r: [4]usize = .{ job.region[0], y0, job.region[2], y1 };
        if (job.clear) |px| {
            const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, job.out.bytes[0 .. job.out.width * job.out.height * 4]));
            for (y0..y1) |y| @memset(words[y * job.out.width + r[0] .. y * job.out.width + r[2]], px);
        }
        for (job.instances) |*i| drawOnePtr(job.out, i, job.mask, job.pictures, job.scale, r);
    }

    /// About how many pixels the band's instances cover in its region (all
    /// of it when the rows are cleared): a few small instances between
    /// groups or glass are not worth a thread.
    fn work(job: *const Band) usize {
        const r = job.region;
        const whole = (r[2] - r[0]) * (r[3] - r[1]);
        if (job.clear != null) return whole;
        var sum: usize = 0;
        for (job.instances) |*i| {
            const b = bounds(job.out, i, job.scale) orelse continue;
            const w = @min(b[2], r[2]) -| @max(b[0], r[0]);
            const h = @min(b[3], r[3]) -| @max(b[1], r[1]);
            sum += w * h;
            if (sum >= whole) return whole;
        }
        return sum;
    }

    /// Draws the region's rows, shared among threads when there are many.
    fn share(job: *const Band) void {
        if (@import("builtin").single_threaded or @import("builtin").os.tag == .freestanding) return job.rows(job.region[1], job.region[3]);
        const height = job.region[3] - job.region[1];
        const cpus = std.Thread.getCpuCount() catch 1;
        const n = @max(1, @min(threads, thread_limit, cpus, job.work() / min_pixels));
        var started: [thread_limit]?std.Thread = @splat(null);
        for (1..n) |k| {
            const y0 = job.region[1] + height * k / n;
            const y1 = job.region[1] + height * (k + 1) / n;
            started[k] = std.Thread.spawn(.{}, Band.rows, .{ job, y0, y1 }) catch blk: {
                job.rows(y0, y1);
                break :blk null;
            };
        }
        job.rows(job.region[1], job.region[1] + height / n);
        for (started[1..n]) |t| if (t) |th| th.join();
    }
};

pub const damage = xform.damage;
pub const unmatrix = xform.unmatrix;
pub const pixelAt = xform.pixelAt;
pub const unrotate = xform.unrotate;
pub const bounds = xform.bounds;

pub fn unit(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

pub fn drawOne(out: gpu.Pixels, i: *const gpu.Instance, mask: Mask, pictures: Pictures, scale: f32, region: [4]usize) void {
    drawOnePtr(out, i, &mask, &pictures, scale, region);
}

pub fn drawOnePtr(out: gpu.Pixels, i: *const gpu.Instance, mask: *const Mask, pictures: *const Pictures, scale: f32, region: [4]usize) void {
    if (i.kind == gpu.Kind.layer_begin or i.kind == gpu.Kind.layer_end or i.kind == gpu.Kind.layer_composite) return;
    const all = bounds(out, i, scale) orelse return;
    const b: [4]usize = .{ @max(all[0], region[0]), @max(all[1], region[1]), @min(all[2], region[2]), @min(all[3], region[3]) };
    if (b[2] <= b[0] or b[3] <= b[1]) return;
    if (i.kind == gpu.Kind.text) return @import("raster_glyph.zig").glyph(out, i, mask, scale, b);
    if (i.kind == gpu.Kind.vector_text) return raster_slug.vectorGlyph(out, i, mask, scale, b);
    if (i.kind == gpu.Kind.image) {
        const src = Source.atlas(pictures);
        return pic.picture(out, i, &src, scale, b);
    }
    if (i.kind == gpu.Kind.texture) {
        const slot: usize = @intFromFloat(i.border_width);
        if (slot < pictures.textures.len) pic.texture(out, i, pictures.textures[slot], scale, b);
        return;
    }
    if (i.kind == gpu.Kind.shadow or i.kind == gpu.Kind.shadow_out) return shadow(out, i, scale, b);
    if (i.kind == gpu.Kind.glass) return pane(out, i, scale, b);
    if (i.kind == gpu.Kind.segment or i.kind == gpu.Kind.triangle or i.kind == gpu.Kind.hole) return shapes.draw(out, i, scale, b);
    quad(out, i, pictures.gradients, scale, b);
}

/// Blends a premultiplied color over the pixel at byte `at`.
pub inline fn blend(bytes: []u8, at: usize, r: f32, g: f32, bl: f32, a: f32) void {
    if (a <= 0) return;
    const inv = 1 - a;
    const d = bytes[at..][0..4];
    d[0] = @intFromFloat(@min(255, bl * 255 + @as(f32, @floatFromInt(d[0])) * inv + 0.5));
    d[1] = @intFromFloat(@min(255, g * 255 + @as(f32, @floatFromInt(d[1])) * inv + 0.5));
    d[2] = @intFromFloat(@min(255, r * 255 + @as(f32, @floatFromInt(d[2])) * inv + 0.5));
    d[3] = @intFromFloat(@min(255, a * 255 + @as(f32, @floatFromInt(d[3])) * inv + 0.5));
}

pub fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

/// The signed distance to a rounded box centered at 0, and the sum of the
/// absolute values of its gradient (what `fwidth` measures per pixel).
pub fn roundedBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) [2]f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const len = @sqrt(mx * mx + my * my);
    const d = len + @min(@max(qx, qy), 0) - r;
    const grad: f32 = if (len > 0) (mx + my) / len else 1;
    return .{ d, grad };
}

pub fn cornerSdf(px: f32, py: f32, hw: f32, hh: f32, r_in: f32) [2]f32 {
    const r = @min(@abs(r_in), @min(hw, hh));
    if (r <= 0 or r_in < 0) return roundedBox(px, py, hw, hh, r);
    const dx = hw - @abs(px);
    const dy = hh - @abs(py);
    const a = @min(dx, dy);
    const b_val = @max(dx, dy);
    const half_long = if (dy >= dx) hh else hw;
    const ext = @min(1.52866495 * r, half_long);
    if (b_val >= ext) return .{ -a, 1 };
    if (b_val >= 0.63149399 * r and a > -0.25 * r) {
        const span = @max(ext - 0.63149399 * r, 1e-5);
        const u = std.math.clamp((ext - b_val) / span, 0, 1);
        const uu = u * u;
        const uuu = uu * u;
        const c3: f32 = 0.00759166;
        const c4: f32 = 0.06728002;
        const c5: f32 = 0.00003973;
        const indent = r * (c3 * uuu + c4 * uuu * u + c5 * uuu * uu);
        const slope = r * (3 * c3 * uu + 4 * c4 * uuu + 5 * c5 * uu * uu) / span;
        const inv_norm = 1 / @sqrt(1 + slope * slope);
        return .{ (indent - a) * inv_norm, (1 + slope) * inv_norm };
    }
    const cx = 0.950248 * r;
    const cr = 0.931599 * r;
    const qx = cx - dx;
    const qy = cx - dy;
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const len = @sqrt(mx * mx + my * my);
    const d = len + @min(@max(qx, qy), 0) - cr;
    const grad: f32 = if (len > 0) (mx + my) / len else 1;
    return .{ d, grad };
}

/// How much of the pixel at `wx`, `wy` the instance's clip lets through:
/// all of it, but in the clip's rounded corners (as the shader's
/// `clip_cover`).
pub inline fn clipCover(i: *const gpu.Instance, wx: f32, wy: f32, inv: f32) f32 {
    if (i.clip_round == 0) return 1;
    const round = gpu.clipCorners(i.clip_round);
    const c = i.clip;
    const hw = (c[2] - c[0]) * 0.5;
    const hh = (c[3] - c[1]) * 0.5;
    const r = @min(@abs(round.radius), @min(hw, hh));
    const reach = @min(1.52866495 * r, @max(hw, hh));
    // Between the corners, nothing is cut.
    if ((wx > c[0] + reach and wx < c[2] - reach) or (wy > c[1] + reach and wy < c[3] - reach)) return 1;
    const qx = wx - c[0] - hw;
    const qy = wy - c[1] - hh;
    const bit: u4 = if (qy < 0) (if (qx < 0) 1 else 2) else (if (qx < 0) 8 else 4);
    if (round.corners & bit == 0) return 1;
    const sd = cornerSdf(qx, qy, hw, hh, if (round.radius < 0) -r else r);
    const aa = @max(sd[1] * inv, 0.0001) * 0.5;
    return 1 - smoothstep(-aa, aa, sd[0]);
}
fn mixColor(a: [4]f32, b: [4]f32, t_in: f32) [4]f32 {
    const t = std.math.clamp(t_in, 0, 1);
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t };
}

fn innerSpanX(b: [4]usize, cx: f32, lim: f32, scale: f32, inv: f32) [2]usize {
    if (lim <= 0) return .{ b[2], b[2] };
    const bf0: f32 = @floatFromInt(b[0]);
    const bf2: f32 = @floatFromInt(b[2]);
    var x0: usize = @intFromFloat(std.math.clamp(@ceil((cx - lim) * scale - 0.5), bf0, bf2));
    var x1: usize = @intFromFloat(std.math.clamp(@floor((cx + lim) * scale - 0.5) + 1, bf0, bf2));
    while (x0 < x1 and !(@abs((@as(f32, @floatFromInt(x0)) + 0.5) * inv - cx) < lim)) x0 += 1;
    while (x1 > x0 and !(@abs((@as(f32, @floatFromInt(x1 - 1)) + 0.5) * inv - cx) < lim)) x1 -= 1;
    return .{ x0, x1 };
}

fn quad(out: gpu.Pixels, i: *const gpu.Instance, gradients: []const [4]f32, scale: f32, b: [4]usize) void {
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const cx = i.rect[0] + hw;
    const cy = i.rect[1] + hh;
    const r_abs = @min(@abs(i.radius), @min(hw, hh));
    const r: f32 = if (i.radius < 0) -r_abs else r_abs;
    const bw = i.border_width;
    const has_border = bw > 0 and i.border_color[3] > 0;
    // A gradient of many stops (uv's y 2), or of two (1).
    const stops = i.uv[1] > 1.5;
    const grad = i.uv[1] > 0.5 and !stops;
    const bottom = if (grad) gpu.gradientBottom(i.uv) else i.color;
    var c = i.color;
    const bc = i.border_color;
    const inv = 1 / scale;
    const local_px = pixelAt(i, inv);
    // Inside this, a pixel is wholly the fill: no edge, corner or border.
    const corner_ext: f32 = if (r > 0) 1.52866495 * r else r_abs;
    const edge_pad = (if (has_border) bw else 0) + 2 * @max(local_px, 0.0001);
    const solid = @max(corner_ext, edge_pad);
    const rot = xform.hasTransform(i);
    const span_narrow = if (!rot and i.clip_round == 0) innerSpanX(b, cx, hw - solid, scale, inv) else [2]usize{ b[2], b[2] };
    const span_wide = if (!rot and i.clip_round == 0) innerSpanX(b, cx, hw - edge_pad, scale, inv) else [2]usize{ b[2], b[2] };
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        const dy_abs = @abs(wy - cy);
        const inner_y = !rot and dy_abs < hh - solid;
        const edge_inner_y = !rot and dy_abs < hh - edge_pad;
        if (grad and !rot) c = mixColor(i.color, bottom, (wy - i.rect[1]) / @max(i.rect[3], 1e-4));
        if (stops and !rot) c = gpu.gradientAt(gradients, i.uv, wy - i.rect[1]);
        const sp = if (inner_y) span_wide else if (edge_inner_y) span_narrow else [2]usize{ b[2], b[2] };
        const has_span = sp[0] < sp[1];
        var seg: usize = 0;
        while (seg < (if (has_span) @as(usize, 2) else @as(usize, 1))) : (seg += 1) {
            if (has_span and seg == 1) {
                if (c[3] == 1) {
                    const px4: [4]u8 = .{
                        @intFromFloat(@min(255, c[2] * 255 + 0.5)),
                        @intFromFloat(@min(255, c[1] * 255 + 0.5)),
                        @intFromFloat(@min(255, c[0] * 255 + 0.5)),
                        255,
                    };
                    if (@intFromPtr(out.bytes.ptr) & 3 == 0) {
                        const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out.bytes[row + sp[0] * 4 .. row + sp[1] * 4]));
                        @memset(words, @bitCast(px4));
                    } else for (sp[0]..sp[1]) |sx| out.bytes[row + sx * 4 ..][0..4].* = px4;
                } else if (c[3] > 0) {
                    const ca = c[3];
                    const cr = c[0] * ca;
                    const cg = c[1] * ca;
                    const cb = c[2] * ca;
                    for (sp[0]..sp[1]) |sx| blend(out.bytes, row + sx * 4, cr, cg, cb, ca);
                }
            }
            const x_start = if (has_span and seg == 1) sp[1] else b[0];
            const x_end = if (has_span and seg == 0) sp[0] else b[2];
            for (x_start..x_end) |x| {
                const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
                var u: [2]f32 = .{ wx, wy };
                var landed: [2]f32 = .{ wx, wy };
                if (rot) {
                    if (i.turn[0] != 0 or i.vel[2] == 2.0) {
                        const pt = xform.inverseFrame(.{ wx, wy }, i) orelse continue;
                        if (!xform.inClip(i, pt.landed)) continue;
                        u = pt.unrot;
                        landed = pt.landed;
                    } else {
                        u = unrotate(i, wx, wy);
                    }
                    if (u[0] < i.rect[0] or u[1] < i.rect[1] or u[0] > i.rect[0] + i.rect[2] or u[1] > i.rect[1] + i.rect[3]) continue;
                    if (grad) c = mixColor(i.color, bottom, (u[1] - i.rect[1]) / @max(i.rect[3], 1e-4));
                    if (stops) c = gpu.gradientAt(gradients, i.uv, u[1] - i.rect[1]);
                }
                const pxl = u[0] - cx;
                const py = u[1] - cy;
                const cut = clipCover(i, landed[0], landed[1], inv);
                if ((inner_y and @abs(pxl) < hw - edge_pad) or (edge_inner_y and @abs(pxl) < hw - solid)) {
                    const a = c[3] * cut;
                    blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
                    continue;
                }
                const sd = cornerSdf(pxl, py, hw, hh, r);
                const aa = @max(sd[1] * local_px, 0.0001) * 0.5;
                const coverage = 1 - smoothstep(-aa, aa, sd[0]);
                if (coverage <= 0) continue;
                // Premultiplied: the border is laid over the fill (shader.metal).
                var col: [4]f32 = .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
                if (has_border) {
                    const t = smoothstep(-bw - aa, -bw + aa, sd[0]);
                    var edge: [4]f32 = .{ bc[0] * bc[3], bc[1] * bc[3], bc[2] * bc[3], bc[3] };
                    if (i.uv[0] > 0.5) {
                        const dc = shapes.dashCover(pxl, py, hw, hh, r, bw, inv);
                        for (&edge) |*e| e.* *= dc;
                    }
                    for (0..4) |k| col[k] += (edge[k] + col[k] * (1 - edge[3]) - col[k]) * t;
                }
                const m = coverage * cut;
                blend(out.bytes, row + x * 4, col[0] * m, col[1] * m, col[2] * m, col[3] * m);
            }
        }
    }
}

/// A pane of glass over what was drawn before it, as `glass.metal` draws
/// it: its backdrop read from the pixels so far, then its color at each
/// pixel, by its rounded edge's coverage.
fn pane(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const page_gpa = @import("../backend.zig").page_or_wasm_allocator;
    const plan = glass.backdropFor(i.*, scale, out.width, out.height) orelse return;
    const im = glass.readBackdrop(page_gpa, out, plan) catch return;
    defer page_gpa.free(im.pix);
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r = @min(@abs(i.radius), @min(hw, hh));
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const sd = roundedBox(wx - i.rect[0] - hw, wy - i.rect[1] - hh, hw, hh, r);
            const aa = @max(sd[1] * inv, 0.0001) * 0.5;
            const k = (1 - smoothstep(-aa, aa, sd[0])) * clipCover(i, wx, wy, inv) * i.uv[2];
            if (k <= 0) continue;
            const c = glass.color(i, im, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, scale);
            blend(out.bytes, row + x * 4, c[0] * k, c[1] * k, c[2] * k, k);
        }
    }
}
fn shadow(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, b: [4]usize) void {
    const c = i.color;
    if (c[3] <= 0) return;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const cx = i.rect[0] + hw;
    const cy = i.rect[1] + hh;
    const r_abs = @min(@abs(i.radius), @min(hw, hh));
    const r: f32 = if (i.radius < 0) -r_abs else r_abs;
    const sigma = @max(i.border_width, 0.25);
    const inv = 1 / scale;
    const rot = xform.hasTransform(i);
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        var sr: shapes.ShadowRow = undefined;
        if (!rot) {
            sr = shapes.shadowRow(wy - cy, hw, hh, r, sigma);
            if (sr.step == 0) continue;
        }
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            var landed: [2]f32 = .{ wx, wy };
            var pxl: f32 = wx - cx;
            var py: f32 = wy - cy;
            var sa: f32 = undefined;
            if (rot) {
                var up: [2]f32 = undefined;
                if (i.turn[0] != 0 or i.vel[2] == 2.0) {
                    const pt = xform.inverseFrame(.{ wx, wy }, i) orelse continue;
                    if (!xform.inClip(i, pt.landed)) continue;
                    up = pt.unrot;
                    landed = pt.landed;
                } else {
                    up = unrotate(i, wx, wy);
                }
                pxl = up[0] - cx;
                py = up[1] - cy;
                sa = shapes.shadowAlpha(pxl, py, hw, hh, r, sigma);
            } else {
                sa = shapes.shadowRowAlpha(&sr, pxl);
            }
            const cut = clipCover(i, landed[0], landed[1], inv);
            if (cut <= 0) continue;
            var a = sa * c[3] * cut;
            // Knocked out: nothing inside the box (`uv` its offset from the shadow's rect).
            if (i.kind == gpu.Kind.shadow_out) {
                const s = i.uv[2];
                const rb: f32 = if (r < 0) -@max(-r - s, 0) else @max(r - s, 0);
                a *= std.math.clamp(cornerSdf(pxl - i.uv[0], py - i.uv[1], @max(hw - s, 0), @max(hh - s, 0), rb)[0] + 0.5, 0, 1);
            }
            if (a <= 0) continue;
            a = std.math.clamp(a + shapes.shadowDither(x, y), 0, 1);
            if (a > 0) blend(out.bytes, row + x * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

test {
    _ = xform;
    _ = raster_slug;
}
