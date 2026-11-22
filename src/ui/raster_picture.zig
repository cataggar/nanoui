//! Pictures and textures drawn by the CPU renderer (`raster.zig`), as
//! `shader.metal` draws kinds 3 and 8: sampled bilinear, their corners
//! rounded. A texture is first made BGRA at its own size
//! (`texture_cpu.zig`): a pixel buffer's planes converted as the colour
//! stage converts them on the GPU.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const can_resolve_gpu = switch (builtin.os.tag) {
    .macos, .ios => backend.current == .auto or backend.current == .metal,
    .windows => backend.current == .auto or backend.current == .d3d11,
    else => true,
};
const texture_cpu = if (can_resolve_gpu) @import("texture_cpu.zig") else void;

/// A texture the app gave the frame, drawn as `picture` draws the atlas.
pub fn texture(out: gpu.Pixels, i: *const gpu.Instance, t: gpu.Texture, scale: f32, b: [4]usize) void {
    const page_gpa = backend.page_or_wasm_allocator;
    if (comptime !can_resolve_gpu) {
        if (t.bgra.len == 0 or t.width == 0 or t.height == 0) return;
        const stride = if (t.stride > 0) t.stride else @as(usize, t.width) * 4;
        if (t.bgra.len < stride * t.height) return;
        if (!t.needsPost()) {
            const src: Source = .{ .pixels = t.bgra, .w = t.width, .h = t.height, .stride = stride };
            picture(out, i, &src, scale, b);
            return;
        }
        const color = @import("color.zig");
        const u = color.uniforms(t, color.stage(t, 0, false).mode);
        const conv = page_gpa.alloc(u8, @as(usize, t.width) * t.height * 4) catch return;
        defer page_gpa.free(conv);
        for (0..t.height) |y| for (0..t.width) |x| {
            const row = t.bgra[y * stride + x * 4 ..][0..4];
            var c: [4]f32 = .{ @as(f32, @floatFromInt(row[2])) / 255, @as(f32, @floatFromInt(row[1])) / 255, @as(f32, @floatFromInt(row[0])) / 255, @as(f32, @floatFromInt(row[3])) / 255 };
            if (u.source_mode == 3) {
                const rgb = color.linearToDisplay(.{ c[0], c[1], c[2] }, u);
                c = .{ rgb[0], rgb[1], rgb[2], 1 };
            } else if (u.source_mode == 4) {
                const rgb = color.surfaceLinearToSdr(.{ c[0], c[1], c[2] });
                c = .{ rgb[0], rgb[1], rgb[2], c[3] };
            }
            const graded = color.applyLuts(t, .{ c[0], c[1], c[2] });
            conv[(y * t.width + x) * 4 ..][0..4].* = .{ color.unorm8(graded[2]), color.unorm8(graded[1]), color.unorm8(graded[0]), color.unorm8(c[3]) };
        };
        const src: Source = .{ .pixels = conv, .w = t.width, .h = t.height, .stride = @as(usize, t.width) * 4 };
        picture(out, i, &src, scale, b);
        return;
    }
    var held = texture_cpu.resolve(page_gpa, t) orelse return;
    defer held.deinit(page_gpa);
    const src = Source.bgra(held.bgra);
    picture(out, i, &src, scale, b);
}

/// Pixels to sample: the image atlas, or a texture's rows.
pub const Source = struct {
    pixels: []const u8,
    w: usize,
    h: usize,
    stride: usize,

    pub fn atlas(p: *const raster.Pictures) Source {
        return .{ .pixels = p.pixels, .w = p.size, .h = p.size, .stride = @as(usize, p.size) * 4 };
    }

    fn bgra(b: anytype) Source {
        return .{ .pixels = b.pixels, .w = b.width, .h = b.height, .stride = b.stride };
    }
};

/// A BGRA texel, bilinear as Metal's sampler.
fn samplePicture(p: *const Source, u: f32, v: f32) [4]f32 {
    const wf: f32 = @floatFromInt(p.w);
    const hf: f32 = @floatFromInt(p.h);
    const fx = u * wf - 0.5;
    const fy = v * hf - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const mx: i32 = @as(i32, @intCast(p.w)) - 1;
    const my: i32 = @as(i32, @intCast(p.h)) - 1;
    const ix: i32 = @intFromFloat(std.math.clamp(x0f, -1, wf));
    const iy: i32 = @intFromFloat(std.math.clamp(y0f, -1, hf));
    const xs = [2]usize{ @intCast(std.math.clamp(ix, 0, mx)), @intCast(std.math.clamp(ix + 1, 0, mx)) };
    const ys = [2]usize{ @intCast(std.math.clamp(iy, 0, my)), @intCast(std.math.clamp(iy + 1, 0, my)) };
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const weights = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    for (0..4) |k| {
        const t = p.pixels[ys[k / 2] * p.stride + xs[k % 2] * 4 ..][0..4];
        for (0..4) |ch| out[ch] += @as(f32, @floatFromInt(t[ch])) / 255 * weights[k];
    }
    return out;
}

pub fn picture(out: gpu.Pixels, i: *const gpu.Instance, p: *const Source, scale: f32, b: [4]usize) void {
    if (p.w == 0 or p.h == 0 or p.pixels.len < p.stride * p.h) return;
    const inv = 1 / scale;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    const r_abs = @min(@abs(i.radius), @min(hw, hh));
    const r: f32 = if (i.radius < 0) -r_abs else r_abs;
    // Turned, mapped (`gpu.affine`) or under a plane transform
    // (`Instance.m`): the box's own coordinates decide
    // what is inside it, not the pixel's.
    const rot = i.xf[0] != 0 or gpu.affine(i) != null or gpu.hasMatrix(i);
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const up = raster.unrotate(i, wx, wy);
            if (rot and (up[0] < i.rect[0] or up[1] < i.rect[1] or up[0] > i.rect[0] + i.rect[2] or up[1] > i.rect[1] + i.rect[3])) continue;
            const tx = (up[0] - i.rect[0]) / i.rect[2];
            const ty = (up[1] - i.rect[1]) / i.rect[3];
            const v = i.uv[1] + (i.uv[3] - i.uv[1]) * ty;
            const sd = raster.cornerSdf(up[0] - i.rect[0] - hw, up[1] - i.rect[1] - hh, hw, hh, r);
            const aa = @max(sd[1] * raster.pixelAt(i, inv), 0.0001) * 0.5;
            const k = (1 - raster.smoothstep(-aa, aa, sd[0])) * i.color[3] * raster.clipCover(i, wx, wy, inv);
            if (k <= 0) continue;
            const t = samplePicture(p, i.uv[0] + (i.uv[2] - i.uv[0]) * tx, v);
            // A picture's tint; a texture's border colour is its map (`gpu.affine`).
            if (i.kind != gpu.Kind.texture and i.border_color[3] > 0) {
                const a = t[3] * i.border_color[3] * k;
                raster.blend(out.bytes, row + x * 4, i.border_color[0] * a, i.border_color[1] * a, i.border_color[2] * a, a);
                continue;
            }
            raster.blend(out.bytes, row + x * 4, t[2] * k, t[1] * k, t[0] * k, t[3] * k);
        }
    }
}
