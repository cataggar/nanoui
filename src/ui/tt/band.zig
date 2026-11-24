//! Spatial band partitioning for Slug quadratic Bezier glyphs.
//! Slices a glyph's em-space bounding box into `1..16` horizontal and vertical bands
//! and sorts curve indices by descending `max_x` (horizontal) and `max_y` (vertical)
//! so fragment rays can terminate as soon as remaining curves lie behind the sample.
const std = @import("std");
const curve_mod = @import("curve.zig");

pub const Curve = curve_mod.Curve;

pub const max_bands: usize = 16;
pub const band_epsilon: f32 = 1.0 / 65536.0;

pub const Band = struct {
    start: u32 = 0,
    count: u16 = 0,
};

pub const Partition = struct {
    bounds: [4]f32,
    band_max_x: u8,
    band_max_y: u8,
    band_scale: [2]f32,
    band_offset: [2]f32,
    h_bands: [max_bands]Band,
    v_bands: [max_bands]Band,
};

pub const Error = std.mem.Allocator.Error || error{
    EmptyGlyph,
    TooManyCurves,
    InvalidGlyphBounds,
};

fn bandRange(c_min: f32, c_max: f32, eps: f32, scale: f32, offset: f32, max_b_f: f32) [2]usize {
    const f0 = @floor((c_min - eps) * scale + offset);
    const f1 = @floor((c_max + eps) * scale + offset);
    const b0: usize = @intFromFloat(std.math.clamp(f0, 0.0, max_b_f));
    const b1: usize = @intFromFloat(std.math.clamp(f1, 0.0, max_b_f));
    return .{ b0, @max(b0, b1) };
}

fn horizDescMaxX(curves: []const Curve, a: u16, b: u16) bool {
    const ca = curves[a];
    const cb = curves[b];
    const ma = @max(ca.p1[0], @max(ca.p2[0], ca.p3[0]));
    const mb = @max(cb.p1[0], @max(cb.p2[0], cb.p3[0]));
    if (ma != mb) return ma > mb;
    return a < b;
}

fn vertDescMaxY(curves: []const Curve, a: u16, b: u16) bool {
    const ca = curves[a];
    const cb = curves[b];
    const ma = @max(ca.p1[1], @max(ca.p2[1], ca.p3[1]));
    const mb = @max(cb.p1[1], @max(cb.p2[1], cb.p3[1]));
    if (ma != mb) return ma > mb;
    return a < b;
}

pub fn partition(
    allocator: std.mem.Allocator,
    curves: []const Curve,
    glyph_bounds: [4]f32,
    indices_out: *std.ArrayList(u16),
) Error!Partition {
    indices_out.clearRetainingCapacity();
    if (curves.len == 0) return error.EmptyGlyph;
    if (curves.len > 32767) return error.TooManyCurves;

    const span_x = glyph_bounds[2] - glyph_bounds[0];
    const span_y = glyph_bounds[3] - glyph_bounds[1];
    if (!(span_x > 0.0 and span_y > 0.0) or !std.math.isFinite(span_x) or !std.math.isFinite(span_y)) {
        return error.InvalidGlyphBounds;
    }

    const n_bands_f = std.math.clamp(
        @round(@as(f32, @floatFromInt(curves.len)) / 4.0),
        1.0,
        @as(f32, @floatFromInt(max_bands)),
    );
    const n_bands: usize = @intFromFloat(n_bands_f);
    const max_b_f: f32 = @floatFromInt(n_bands - 1);

    const band_scale: [2]f32 = .{ n_bands_f / span_x, n_bands_f / span_y };
    const band_offset: [2]f32 = .{ -glyph_bounds[0] * band_scale[0], -glyph_bounds[1] * band_scale[1] };

    // Pad curve extents by at least `band_epsilon` (and >= half a u16 quantization step).
    const eps_x = @max(band_epsilon, span_x * (0.75 / 65535.0));
    const eps_y = @max(band_epsilon, span_y * (0.75 / 65535.0));

    var h_counts: [max_bands]u32 = @splat(0);
    var v_counts: [max_bands]u32 = @splat(0);

    for (curves) |c| {
        const min_y = @min(c.p1[1], @min(c.p2[1], c.p3[1]));
        const max_y = @max(c.p1[1], @max(c.p2[1], c.p3[1]));
        const hr = bandRange(min_y, max_y, eps_y, band_scale[1], band_offset[1], max_b_f);
        for (hr[0]..hr[1] + 1) |b| h_counts[b] += 1;

        const min_x = @min(c.p1[0], @min(c.p2[0], c.p3[0]));
        const max_x = @max(c.p1[0], @max(c.p2[0], c.p3[0]));
        const vr = bandRange(min_x, max_x, eps_x, band_scale[0], band_offset[0], max_b_f);
        for (vr[0]..vr[1] + 1) |b| v_counts[b] += 1;
    }

    var p: Partition = .{
        .bounds = glyph_bounds,
        .band_max_x = @intCast(n_bands - 1),
        .band_max_y = @intCast(n_bands - 1),
        .band_scale = band_scale,
        .band_offset = band_offset,
        .h_bands = @splat(.{}),
        .v_bands = @splat(.{}),
    };

    var h_write: [max_bands]u32 = @splat(0);
    var v_write: [max_bands]u32 = @splat(0);
    var total: usize = 0;

    for (0..n_bands) |b| {
        if (h_counts[b] > 65535) return error.TooManyCurves;
        p.h_bands[b] = .{ .start = @intCast(total), .count = @intCast(h_counts[b]) };
        h_write[b] = @intCast(total);
        total += h_counts[b];
    }
    for (0..n_bands) |b| {
        if (v_counts[b] > 65535) return error.TooManyCurves;
        p.v_bands[b] = .{ .start = @intCast(total), .count = @intCast(v_counts[b]) };
        v_write[b] = @intCast(total);
        total += v_counts[b];
    }

    try indices_out.resize(allocator, total);
    const out = indices_out.items;

    for (curves, 0..) |c, idx| {
        const idx_u16: u16 = @intCast(idx);
        const min_y = @min(c.p1[1], @min(c.p2[1], c.p3[1]));
        const max_y = @max(c.p1[1], @max(c.p2[1], c.p3[1]));
        const hr = bandRange(min_y, max_y, eps_y, band_scale[1], band_offset[1], max_b_f);
        for (hr[0]..hr[1] + 1) |b| {
            out[h_write[b]] = idx_u16;
            h_write[b] += 1;
        }

        const min_x = @min(c.p1[0], @min(c.p2[0], c.p3[0]));
        const max_x = @max(c.p1[0], @max(c.p2[0], c.p3[0]));
        const vr = bandRange(min_x, max_x, eps_x, band_scale[0], band_offset[0], max_b_f);
        for (vr[0]..vr[1] + 1) |b| {
            out[v_write[b]] = idx_u16;
            v_write[b] += 1;
        }
    }

    for (0..n_bands) |b| {
        const hb = p.h_bands[b];
        std.mem.sort(u16, out[hb.start .. hb.start + hb.count], curves, horizDescMaxX);
        const vb = p.v_bands[b];
        std.mem.sort(u16, out[vb.start .. vb.start + vb.count], curves, vertDescMaxY);
    }

    return p;
}

test "single-band partition on 4-curve square sorts descending max_x and max_y" {
    const curves = [_]Curve{
        .{ .p1 = .{ 0, 0 }, .p2 = .{ 0.5, 0 }, .p3 = .{ 1, 0 } }, // 0: max_x=1, max_y=0
        .{ .p1 = .{ 1, 0 }, .p2 = .{ 1, 0.5 }, .p3 = .{ 1, 1 } }, // 1: max_x=1, max_y=1
        .{ .p1 = .{ 1, 1 }, .p2 = .{ 0.5, 1 }, .p3 = .{ 0, 1 } }, // 2: max_x=1, max_y=1
        .{ .p1 = .{ 0, 1 }, .p2 = .{ 0, 0.5 }, .p3 = .{ 0, 0 } }, // 3: max_x=0, max_y=1
    };
    var idx: std.ArrayList(u16) = .empty;
    defer idx.deinit(std.testing.allocator);

    const p = try partition(std.testing.allocator, &curves, .{ 0, 0, 1, 1 }, &idx);
    try std.testing.expectEqual(@as(u8, 0), p.band_max_x);
    try std.testing.expectEqual(@as(u8, 0), p.band_max_y);
    try std.testing.expectEqual(@as(u16, 4), p.h_bands[0].count);
    try std.testing.expectEqual(@as(u16, 4), p.v_bands[0].count);

    // Horizontal band: curves 0, 1, 2 tie at max_x = 1.0 (ascending index), then curve 3 (max_x = 0.0).
    const h0 = idx.items[p.h_bands[0].start .. p.h_bands[0].start + p.h_bands[0].count];
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, h0);

    // Vertical band: curves 1, 2, 3 tie at max_y = 1.0 (ascending index), then curve 0 (max_y = 0.0).
    const v0 = idx.items[p.v_bands[0].start .. p.v_bands[0].start + p.v_bands[0].count];
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3, 0 }, v0);
}

test "multi-band partition includes boundary-epsilon curves in both adjacent bands and sorts" {
    // 8 curves -> round(8 / 4) = 2 bands, boundary at x = 0.5 and y = 0.5 on [0, 0, 1, 1].
    const curves = [_]Curve{
        // Curve 0 sits right at y = 0.5 + 0.25 * band_epsilon -> must appear in BOTH h_bands[0] and h_bands[1].
        .{ .p1 = .{ 0.1, 0.5 + 0.25 * band_epsilon }, .p2 = .{ 0.2, 0.5 + 0.25 * band_epsilon }, .p3 = .{ 0.3, 0.5 + 0.25 * band_epsilon } },
        .{ .p1 = .{ 0.0, 0.1 }, .p2 = .{ 0.4, 0.1 }, .p3 = .{ 0.8, 0.1 } }, // h_band 0 only, max_x = 0.8
        .{ .p1 = .{ 0.2, 0.1 }, .p2 = .{ 0.5, 0.2 }, .p3 = .{ 0.9, 0.2 } }, // h_band 0 only, max_x = 0.9
        .{ .p1 = .{ 0.0, 0.8 }, .p2 = .{ 0.3, 0.9 }, .p3 = .{ 0.6, 1.0 } }, // h_band 1 only, max_x = 0.6
        .{ .p1 = .{ 0.5 - 0.25 * band_epsilon, 0.1 }, .p2 = .{ 0.5 - 0.25 * band_epsilon, 0.2 }, .p3 = .{ 0.5 - 0.25 * band_epsilon, 0.3 } }, // both v_bands
        .{ .p1 = .{ 0.7, 0.0 }, .p2 = .{ 0.8, 0.3 }, .p3 = .{ 1.0, 0.4 } },
        .{ .p1 = .{ 0.1, 0.6 }, .p2 = .{ 0.2, 0.7 }, .p3 = .{ 0.4, 0.95 } },
        .{ .p1 = .{ 0.6, 0.6 }, .p2 = .{ 0.7, 0.7 }, .p3 = .{ 0.95, 0.85 } },
    };

    var idx: std.ArrayList(u16) = .empty;
    defer idx.deinit(std.testing.allocator);

    const p = try partition(std.testing.allocator, &curves, .{ 0, 0, 1, 1 }, &idx);
    try std.testing.expectEqual(@as(u8, 1), p.band_max_x);
    try std.testing.expectEqual(@as(u8, 1), p.band_max_y);

    const h0 = idx.items[p.h_bands[0].start .. p.h_bands[0].start + p.h_bands[0].count];
    const h1 = idx.items[p.h_bands[1].start .. p.h_bands[1].start + p.h_bands[1].count];
    try std.testing.expect(std.mem.indexOfScalar(u16, h0, 0) != null);
    try std.testing.expect(std.mem.indexOfScalar(u16, h1, 0) != null);

    const v0 = idx.items[p.v_bands[0].start .. p.v_bands[0].start + p.v_bands[0].count];
    const v1 = idx.items[p.v_bands[1].start .. p.v_bands[1].start + p.v_bands[1].count];
    try std.testing.expect(std.mem.indexOfScalar(u16, v0, 4) != null);
    try std.testing.expect(std.mem.indexOfScalar(u16, v1, 4) != null);

    // Verify descending sort order in every horizontal and vertical band.
    for (0..2) |b| {
        const hs = idx.items[p.h_bands[b].start .. p.h_bands[b].start + p.h_bands[b].count];
        for (1..hs.len) |k| {
            const prev_c = curves[hs[k - 1]];
            const cur_c = curves[hs[k]];
            const prev_m = @max(prev_c.p1[0], @max(prev_c.p2[0], prev_c.p3[0]));
            const cur_m = @max(cur_c.p1[0], @max(cur_c.p2[0], cur_c.p3[0]));
            try std.testing.expect(prev_m >= cur_m);
        }
        const vs = idx.items[p.v_bands[b].start .. p.v_bands[b].start + p.v_bands[b].count];
        for (1..vs.len) |k| {
            const prev_c = curves[vs[k - 1]];
            const cur_c = curves[vs[k]];
            const prev_m = @max(prev_c.p1[1], @max(prev_c.p2[1], prev_c.p3[1]));
            const cur_m = @max(cur_c.p1[1], @max(cur_c.p2[1], cur_c.p3[1]));
            try std.testing.expect(prev_m >= cur_m);
        }
    }
}
