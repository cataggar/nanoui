//! CPU renderer for `gpu.Kind.vector_text` (`13`): evaluates analytic Slug
//! curve-band coverage (`slug_store.evalCoverage`) directly from `Mask.slug_words`
//! across axis-aligned, affine-transformed, mirrored, and 3D perspective-turned quads.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const xform = @import("raster_xform.zig");
const slug_store = @import("slug_store.zig");

inline fn hypot2(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

pub fn vectorGlyph(out: gpu.Pixels, i: *const gpu.Instance, mask: *const raster.Mask, scale: f32, b: [4]usize) void {
    if (!(i.border_color[0] >= 0.0 and i.border_color[1] >= 0.0)) return;
    const lo: u32 = @intFromFloat(@round(i.border_color[0]));
    const hi: u32 = @intFromFloat(@round(i.border_color[1]));
    const blob: u32 = (lo & 0xFFFF) | (hi << 16);
    if (blob == 0 or mask.slug_words.len == 0 or i.color[3] <= 0.0 or i.rect[2] <= 0.0 or i.rect[3] <= 0.0) return;
    if (xform.isHidden(i)) return;

    const inv_scale: f32 = 1.0 / @max(scale, 1e-4);
    const uv_scale_x: f32 = (i.uv[2] - i.uv[0]) / @max(i.rect[2], 1e-6);
    const uv_scale_y: f32 = (i.uv[3] - i.uv[1]) / @max(i.rect[3], 1e-6);
    const c = i.color;

    if (!xform.hasTransform(i)) {
        const ems_per_pixel: [2]f32 = .{ @abs(uv_scale_x) * inv_scale, @abs(uv_scale_y) * inv_scale };
        if (!(ems_per_pixel[0] > 0.0 and ems_per_pixel[1] > 0.0)) return;
        for (b[1]..b[3]) |py| {
            const sy = (@as(f32, @floatFromInt(py)) + 0.5) * inv_scale;
            if (sy < i.clip[1] or sy > i.clip[3]) continue;
            const ly = sy - i.rect[1];
            if (ly < 0.0 or ly > i.rect[3]) continue;
            const rc_y = i.uv[1] + ly * uv_scale_y;
            const row = py * out.width * 4;
            for (b[0]..b[2]) |px| {
                const sx = (@as(f32, @floatFromInt(px)) + 0.5) * inv_scale;
                if (sx < i.clip[0] or sx > i.clip[2]) continue;
                const lx = sx - i.rect[0];
                if (lx < 0.0 or lx > i.rect[2]) continue;
                if (i.border_width > 0.0 and sx >= i.radius) continue;
                const clip_cover = raster.clipCover(i, sx, sy, inv_scale);
                if (clip_cover <= 0.0) continue;
                const rc: [2]f32 = .{ i.uv[0] + lx * uv_scale_x, rc_y };
                var cov = slug_store.evalCoverage(mask.slug_words, blob, rc, ems_per_pixel);
                if (i.border_width > 0.0) cov *= std.math.clamp((i.radius - sx) / i.border_width, 0.0, 1.0);
                const a = c[3] * cov * clip_cover;
                if (a > 0.0) raster.blend(out.bytes, row + px * 4, c[0] * a, c[1] * a, c[2] * a, a);
            }
        }
        return;
    }

    const slack: f32 = if (gpu.hasMatrix(i)) 1e-4 else 0.0;
    var affine_epp: [2]f32 = .{ 0.0, 0.0 };
    if (i.turn[0] == 0.0) {
        const o0 = xform.inverseFrame(.{ 0.0, 0.0 }, i) orelse return;
        const ox = xform.inverseFrame(.{ inv_scale, 0.0 }, i) orelse return;
        const oy = xform.inverseFrame(.{ 0.0, inv_scale }, i) orelse return;
        const du_dx = (ox.unrot[0] - o0.unrot[0]) * uv_scale_x;
        const dv_dx = (ox.unrot[1] - o0.unrot[1]) * uv_scale_y;
        const du_dy = (oy.unrot[0] - o0.unrot[0]) * uv_scale_x;
        const dv_dy = (oy.unrot[1] - o0.unrot[1]) * uv_scale_y;
        affine_epp = .{ hypot2(du_dx, du_dy), hypot2(dv_dx, dv_dy) };
        if (!(affine_epp[0] > 0.0 and affine_epp[1] > 0.0)) return;
    }

    for (b[1]..b[3]) |py| {
        const sy = (@as(f32, @floatFromInt(py)) + 0.5) * inv_scale;
        const row = py * out.width * 4;
        for (b[0]..b[2]) |px| {
            const sx = (@as(f32, @floatFromInt(px)) + 0.5) * inv_scale;
            const p0 = xform.inverseFrame(.{ sx, sy }, i) orelse continue;
            if (!xform.inClip(i, p0.landed)) continue;
            const lx = p0.unrot[0] - i.rect[0];
            const ly = p0.unrot[1] - i.rect[1];
            if (lx < -slack or ly < -slack or lx > i.rect[2] + slack or ly > i.rect[3] + slack) continue;
            if (i.border_width > 0.0 and p0.world[0] >= i.radius) continue;
            const clip_cover = raster.clipCover(i, p0.landed[0], p0.landed[1], inv_scale);
            if (clip_cover <= 0.0) continue;

            const ems_per_pixel: [2]f32 = if (i.turn[0] == 0.0) affine_epp else blk: {
                const px1 = xform.inverseFrame(.{ sx + inv_scale, sy }, i) orelse continue;
                const py1 = xform.inverseFrame(.{ sx, sy + inv_scale }, i) orelse continue;
                const du_dx = (px1.unrot[0] - p0.unrot[0]) * uv_scale_x;
                const dv_dx = (px1.unrot[1] - p0.unrot[1]) * uv_scale_y;
                const du_dy = (py1.unrot[0] - p0.unrot[0]) * uv_scale_x;
                const dv_dy = (py1.unrot[1] - p0.unrot[1]) * uv_scale_y;
                break :blk .{ hypot2(du_dx, du_dy), hypot2(dv_dx, dv_dy) };
            };
            const rc: [2]f32 = .{ i.uv[0] + lx * uv_scale_x, i.uv[1] + ly * uv_scale_y };
            var cov = slug_store.evalCoverage(mask.slug_words, blob, rc, ems_per_pixel);
            if (i.border_width > 0.0) cov *= std.math.clamp((i.radius - p0.world[0]) / i.border_width, 0.0, 1.0);
            const a = c[3] * cov * clip_cover;
            if (a > 0.0) raster.blend(out.bytes, row + px * 4, c[0] * a, c[1] * a, c[2] * a, a);
        }
    }
}

test "vectorGlyph renders axis-aligned, truncated, affine-rotated, and perspective-turned Slug glyphs" {
    const gpa = std.testing.allocator;
    var store: slug_store.Store = .{};
    defer store.deinit(gpa);

    var col = slug_store.curve.Collector.init(gpa);
    defer col.deinit();
    col.move(0.1, 0.1);
    col.line(0.9, 0.1);
    col.line(0.9, 0.9);
    col.line(0.1, 0.9);
    col.close();

    const gb = slug_store.curve.bounds(col.slice()).?;
    const entry = try store.putCurves(gpa, .{ .face = 1, .glyph = 1 }, col.slice(), gb);
    const sv = store.view();
    const mask: raster.Mask = .{
        .pixels = &.{},
        .size = 0,
        .slug_words = sv.words,
        .slug_height = sv.height,
        .slug_generation = sv.generation,
    };

    const w: usize = 80;
    const h: usize = 80;
    const bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = w, .height = h };

    // 1. Axis-aligned red glyph on white background (`y`-up em UV: v0=1.0, v1=0.0).
    const inst = gpu.vectorGlyph(
        .{ 10, 10, 40, 40 },
        .{ 0.0, 1.0, 1.0, 0.0 },
        entry.blob,
        .{ .r = 1, .g = 0, .b = 0, .a = 1 },
        .{ 0, 0, 80, 80 },
    );
    raster.draw(out, &.{inst}, mask, .{}, 1.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    // Center (30, 30) is solid red (BGRA = 0, 0, 255, 255); exterior (5, 5) is white.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, bytes[(30 * w + 30) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, bytes[(5 * w + 5) * 4 ..][0..4]);

    // 2. Truncation fade from x=20..40 (`radius = 40`, `border_width = 20`): midpoint x=30.5 is ~50% red.
    var faded = inst;
    faded.radius = 40;
    faded.border_width = 20;
    raster.draw(out, &.{faded}, mask, .{}, 1.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    const mid_g = bytes[(30 * w + 30) * 4 + 1];
    try std.testing.expect(mid_g > 110 and mid_g < 150);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, bytes[(30 * w + 42) * 4 ..][0..4]);

    // 3. Perspective-turned + rotated + clipped in `landed` space.
    var turned = inst;
    turned.xf = .{ 0.25, 0, 30, 30 };
    turned.turn = .{ 0.6, 300, 30, 30 };
    turned.clip = .{ 0, 0, 30, 80 };
    raster.draw(out, &.{turned}, mask, .{}, 1.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    // Left half of `landed` (`x < 30`) draws red; right of pivot `x > 31` is clipped out!
    try std.testing.expectEqual(@as(u8, 255), bytes[(30 * w + 24) * 4 + 2]);
    try std.testing.expect(bytes[(30 * w + 24) * 4 + 0] < 40);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, bytes[(30 * w + 35) * 4 ..][0..4]);
}
