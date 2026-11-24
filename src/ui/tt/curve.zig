//! Quadratic Bezier curve extraction in normalized em-space (`y`-up, `1.0 == units_per_em`)
//! for Slug analytic vector glyph rendering. Converts lines, quadratics, and cubics
//! (via depth-3 De Casteljau midpoint subdivision) into watertight `Curve` contours,
//! with synthetic oblique `skew` and winding-aware contour-normal `embolden`.
const std = @import("std");
const font_mod = @import("font.zig");

pub const Font = font_mod.Font;
pub const Sink = font_mod.Sink;

pub const Curve = extern struct {
    p1: [2]f32,
    p2: [2]f32,
    p3: [2]f32,
};

comptime {
    std.debug.assert(@sizeOf(Curve) == 24);
}

pub const Collector = struct {
    inline_buf: [256]Curve = undefined,
    inline_len: usize = 0,
    extra: std.ArrayList(Curve) = .empty,
    allocator: std.mem.Allocator,
    start: [2]f32 = .{ 0, 0 },
    cur: [2]f32 = .{ 0, 0 },
    contour_start: usize = 0,
    has_point: bool = false,
    alloc_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Collector) void {
        self.extra.deinit(self.allocator);
        self.inline_len = 0;
        self.has_point = false;
    }

    pub fn reset(self: *Collector) void {
        self.inline_len = 0;
        self.extra.clearRetainingCapacity();
        self.start = .{ 0, 0 };
        self.cur = .{ 0, 0 };
        self.contour_start = 0;
        self.has_point = false;
        self.alloc_failed = false;
    }

    pub fn slice(self: *const Collector) []const Curve {
        return if (self.extra.items.len > 0) self.extra.items else self.inline_buf[0..self.inline_len];
    }

    pub fn itemsMut(self: *Collector) []Curve {
        return if (self.extra.items.len > 0) self.extra.items else self.inline_buf[0..self.inline_len];
    }

    fn appendCurve(self: *Collector, c: Curve) void {
        if (self.alloc_failed) return;
        if (self.extra.items.len > 0) {
            self.extra.append(self.allocator, c) catch {
                self.alloc_failed = true;
            };
            return;
        }
        if (self.inline_len < self.inline_buf.len) {
            self.inline_buf[self.inline_len] = c;
            self.inline_len += 1;
            return;
        }
        self.extra.ensureTotalCapacity(self.allocator, self.inline_buf.len * 2) catch {
            self.alloc_failed = true;
            return;
        };
        self.extra.appendSliceAssumeCapacity(&self.inline_buf);
        self.extra.appendAssumeCapacity(c);
    }

    pub fn move(self: *Collector, x: f32, y: f32) void {
        self.start = .{ x, y };
        self.cur = .{ x, y };
        self.contour_start = self.slice().len;
        self.has_point = true;
    }

    pub fn line(self: *Collector, x: f32, y: f32) void {
        if (!self.has_point) {
            self.move(x, y);
            return;
        }
        if (@abs(x - self.cur[0]) > 1e-7 or @abs(y - self.cur[1]) > 1e-7) {
            const next: [2]f32 = .{ x, y };
            self.appendCurve(.{
                .p1 = self.cur,
                .p2 = .{ (self.cur[0] + x) * 0.5, (self.cur[1] + y) * 0.5 },
                .p3 = next,
            });
            self.cur = next;
        }
    }

    pub fn quad(self: *Collector, cx: f32, cy: f32, x: f32, y: f32) void {
        if (!self.has_point) {
            self.move(x, y);
            return;
        }
        if (@abs(cx - self.cur[0]) <= 1e-7 and @abs(cy - self.cur[1]) <= 1e-7 and
            @abs(x - self.cur[0]) <= 1e-7 and @abs(y - self.cur[1]) <= 1e-7)
        {
            return;
        }
        const next: [2]f32 = .{ x, y };
        self.appendCurve(.{
            .p1 = self.cur,
            .p2 = .{ cx, cy },
            .p3 = next,
        });
        self.cur = next;
    }

    /// Splits a cubic Bezier into 8 sub-cubics (depth-3 De Casteljau midpoint
    /// subdivision) and approximates each non-degenerate sub-cubic with a quadratic.
    pub fn cubic(self: *Collector, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        if (!self.has_point) {
            self.move(x, y);
            return;
        }
        const before = self.slice().len;
        const p0 = self.cur;
        const p1: [2]f32 = .{ c1x, c1y };
        const p2: [2]f32 = .{ c2x, c2y };
        const p3: [2]f32 = .{ x, y };
        self.subdivideCubic(p0, p1, p2, p3, 3);
        const items = self.itemsMut();
        if (items.len > before) {
            items[items.len - 1].p3 = p3;
            self.cur = p3;
        }
    }

    fn subdivideCubic(self: *Collector, q0: [2]f32, q1: [2]f32, q2: [2]f32, q3: [2]f32, depth: u8) void {
        if (depth == 0) {
            const cx = ((3.0 * q1[0] - q0[0]) + (3.0 * q2[0] - q3[0])) * 0.25;
            const cy = ((3.0 * q1[1] - q0[1]) + (3.0 * q2[1] - q3[1])) * 0.25;
            self.quad(cx, cy, q3[0], q3[1]);
            return;
        }
        const m01 = midpoint(q0, q1);
        const m12 = midpoint(q1, q2);
        const m23 = midpoint(q2, q3);
        const m012 = midpoint(m01, m12);
        const m123 = midpoint(m12, m23);
        const mid = midpoint(m012, m123);
        self.subdivideCubic(q0, m01, m012, mid, depth - 1);
        self.subdivideCubic(mid, m123, m23, q3, depth - 1);
    }

    pub fn close(self: *Collector) void {
        if (!self.has_point) return;
        if (@abs(self.start[0] - self.cur[0]) > 1e-6 or @abs(self.start[1] - self.cur[1]) > 1e-6) {
            self.line(self.start[0], self.start[1]);
        } else {
            const items = self.itemsMut();
            if (items.len > self.contour_start) {
                items[items.len - 1].p3 = self.start;
            }
        }
        self.cur = self.start;
    }

    pub fn sink(self: *Collector) Sink {
        return .{
            .ctx = self,
            .move = sinkMove,
            .line = sinkLine,
            .quad = sinkQuad,
            .close = sinkClose,
        };
    }

    fn of(ctx: *anyopaque) *Collector {
        return @ptrCast(@alignCast(ctx));
    }
    fn sinkMove(ctx: *anyopaque, x: f32, y: f32) void {
        of(ctx).move(x, y);
    }
    fn sinkLine(ctx: *anyopaque, x: f32, y: f32) void {
        of(ctx).line(x, y);
    }
    fn sinkQuad(ctx: *anyopaque, cx: f32, cy: f32, x: f32, y: f32) void {
        of(ctx).quad(cx, cy, x, y);
    }
    fn sinkClose(ctx: *anyopaque) void {
        of(ctx).close();
    }
};

fn midpoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

/// Control-point hull `[min_x, min_y, max_x, max_y]`; `null` if empty, degenerate, or non-finite.
pub fn bounds(curves: []const Curve) ?[4]f32 {
    if (curves.len == 0) return null;
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (curves) |c| {
        inline for (.{ c.p1, c.p2, c.p3 }) |p| {
            if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return null;
            min_x = @min(min_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_x = @max(max_x, p[0]);
            max_y = @max(max_y, p[1]);
        }
    }
    if (!(max_x > min_x and max_y > min_y)) return null;
    return .{ min_x, min_y, max_x, max_y };
}

fn near(a: [2]f32, b: [2]f32, tol: f32) bool {
    return @abs(a[0] - b[0]) <= tol and @abs(a[1] - b[1]) <= tol;
}

fn curveSignedArea(c: Curve) f32 {
    const c12 = (c.p1[0] * c.p2[1] - c.p1[1] * c.p2[0]) * 2.0;
    const c23 = (c.p2[0] * c.p3[1] - c.p2[1] * c.p3[0]) * 2.0;
    const c13 = c.p1[0] * c.p3[1] - c.p1[1] * c.p3[0];
    return (c12 + c23 + c13) / 6.0;
}

fn unitTangent(dx: f32, dy: f32, fbx: f32, fby: f32) [2]f32 {
    const len = std.math.hypot(dx, dy);
    if (len > 1e-7) return .{ dx / len, dy / len };
    const flen = std.math.hypot(fbx, fby);
    if (flen > 1e-7) return .{ fbx / flen, fby / flen };
    return .{ 1.0, 0.0 };
}

fn outwardNormal(t: [2]f32, outward_sign: f32) [2]f32 {
    return .{ t[1] * outward_sign, -t[0] * outward_sign };
}

fn startTangent(c: Curve) [2]f32 {
    return unitTangent(c.p2[0] - c.p1[0], c.p2[1] - c.p1[1], c.p3[0] - c.p1[0], c.p3[1] - c.p1[1]);
}

fn endTangent(c: Curve) [2]f32 {
    return unitTangent(c.p3[0] - c.p2[0], c.p3[1] - c.p2[1], c.p3[0] - c.p1[0], c.p3[1] - c.p1[1]);
}

fn miterShift(n_in: [2]f32, n_out: [2]f32, half: f32) [2]f32 {
    const sx = n_in[0] + n_out[0];
    const sy = n_in[1] + n_out[1];
    const slen = std.math.hypot(sx, sy);
    if (slen <= 1e-5) return .{ n_out[0] * half, n_out[1] * half };
    const bx = sx / slen;
    const by = sy / slen;
    const cos_half = bx * n_out[0] + by * n_out[1];
    const factor = std.math.clamp(1.0 / @max(cos_half, 0.25), 0.5, 2.0);
    return .{ bx * half * factor, by * half * factor };
}

/// Offsets closed contours along their outward miter normals by `0.5 * delta_em`
/// on each side (`delta_em` total stem thickening), keeping vertices watertight.
pub fn embolden(curves: []Curve, delta_em: f32) void {
    if (!(delta_em > 1e-6) or !std.math.isFinite(delta_em) or curves.len == 0) return;

    var total_area: f32 = 0.0;
    var scan: usize = 0;
    while (scan < curves.len) {
        var end = scan + 1;
        while (end < curves.len and near(curves[end].p1, curves[end - 1].p3, 1e-5)) : (end += 1) {}
        if (near(curves[end - 1].p3, curves[scan].p1, 1e-4)) {
            for (curves[scan..end]) |c| total_area += curveSignedArea(c);
        }
        scan = end;
    }

    const outward_sign: f32 = if (total_area >= 0.0) 1.0 else -1.0;
    const half = delta_em * 0.5;

    var c_start: usize = 0;
    while (c_start < curves.len) {
        var c_end = c_start + 1;
        while (c_end < curves.len and near(curves[c_end].p1, curves[c_end - 1].p3, 1e-5)) : (c_end += 1) {}
        if (near(curves[c_end - 1].p3, curves[c_start].p1, 1e-4)) {
            const m = c_end - c_start;
            const first_orig_p1 = curves[c_start].p1;
            const last_ne = outwardNormal(endTangent(curves[c_end - 1]), outward_sign);
            const first_ns = outwardNormal(startTangent(curves[c_start]), outward_sign);
            const shift_0 = miterShift(last_ne, first_ns, half);
            const first_new_p1: [2]f32 = .{ first_orig_p1[0] + shift_0[0], first_orig_p1[1] + shift_0[1] };

            var cur_shift = shift_0;
            var cur_new_p1 = first_new_p1;
            for (0..m) |j| {
                const c = curves[c_start + j];
                const t0 = startTangent(c);
                const t1 = endTangent(c);
                const ns = outwardNormal(t0, outward_sign);
                const ne = outwardNormal(t1, outward_sign);

                var next_shift = shift_0;
                var next_new_p3 = first_new_p1;
                if (j + 1 < m) {
                    const next_c = curves[c_start + j + 1];
                    const next_ns = outwardNormal(startTangent(next_c), outward_sign);
                    next_shift = miterShift(ne, next_ns, half);
                    next_new_p3 = .{ next_c.p1[0] + next_shift[0], next_c.p1[1] + next_shift[1] };
                }

                const cross = t0[0] * t1[1] - t0[1] * t1[0];
                const shift_p2: [2]f32 = if (@abs(cross) < 1e-5)
                    .{ (cur_shift[0] + next_shift[0]) * 0.5, (cur_shift[1] + next_shift[1]) * 0.5 }
                else
                    miterShift(ns, ne, half);

                curves[c_start + j] = .{
                    .p1 = cur_new_p1,
                    .p2 = .{ c.p2[0] + shift_p2[0], c.p2[1] + shift_p2[1] },
                    .p3 = next_new_p3,
                };
                cur_shift = next_shift;
                cur_new_p1 = next_new_p3;
            }
        }
        c_start = c_end;
    }
}

pub fn extractFontGlyph(
    allocator: std.mem.Allocator,
    f: *const Font,
    glyph: u16,
    skew: f32,
    embolden_em: f32,
    out: *Collector,
) ?[4]f32 {
    out.allocator = allocator;
    out.reset();
    if (!(f.units_per_em > 0.0) or !std.math.isFinite(f.units_per_em)) return null;
    const s = 1.0 / f.units_per_em;
    const aff: [6]f32 = .{ s, 0.0, skew * s, s, 0.0, 0.0 };
    f.outline(glyph, aff, out.sink());
    if (out.alloc_failed) return null;
    embolden(out.itemsMut(), embolden_em);
    return bounds(out.slice());
}

fn signedAreaOf(curves: []const Curve) f32 {
    var sum: f32 = 0.0;
    for (curves) |c| sum += curveSignedArea(c);
    return sum;
}

test "Collector extracts closed triangles and rectangles with zero heap allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var col = Collector.init(failing.allocator());
    defer col.deinit();

    col.move(0.1, 0.2);
    col.line(0.9, 0.2);
    col.line(0.5, 0.8);
    col.close(); // auto-closes back to (0.1, 0.2)

    const s = col.slice();
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(s[0].p1, s[2].p3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s[0].p2[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), s[0].p2[1], 1e-6);

    const b = bounds(s).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), b[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), b[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), b[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), b[3], 1e-6);
}

test "Collector spills past 256 inline curves and cubic approximates circle and S-curve" {
    var col = Collector.init(std.testing.allocator);
    defer col.deinit();

    const k: f32 = 0.5522847498;
    col.move(1.0, 0.0);
    col.cubic(1.0, k, k, 1.0, 0.0, 1.0);
    col.cubic(-k, 1.0, -1.0, k, -1.0, 0.0);
    col.cubic(-1.0, -k, -k, -1.0, 0.0, -1.0);
    col.cubic(k, -1.0, 1.0, -k, 1.0, 0.0);
    col.close();

    try std.testing.expectEqual(@as(usize, 32), col.slice().len);
    // Unit circle area is pi ~= 3.14159265.
    try std.testing.expectApproxEqAbs(std.math.pi, signedAreaOf(col.slice()), 2e-3);

    // S-curve midpoint accuracy at t = 0.5: cubic (0,0), (0,1), (1,-1), (1,0) passes through (0.5, 0).
    col.reset();
    col.move(0.0, 0.0);
    col.cubic(0.0, 1.0, 1.0, -1.0, 1.0, 0.0);
    try std.testing.expectEqual(@as(usize, 8), col.slice().len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), col.slice()[3].p3[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), col.slice()[3].p3[1], 1e-6);

    // Spill past 256 curves (35 cubics * 8 = 280 curves).
    col.reset();
    col.move(0.0, 0.0);
    for (0..35) |i| {
        const x0: f32 = @floatFromInt(i);
        col.cubic(x0 + 0.3, 0.2, x0 + 0.7, -0.2, x0 + 1.0, 0.0);
    }
    try std.testing.expectEqual(@as(usize, 280), col.slice().len);
}

test "embolden expands outer contour and shrinks inner counter hole for both CCW and CW" {
    inline for (.{ false, true }) |cw_outer| {
        var col = Collector.init(std.testing.allocator);
        defer col.deinit();

        // Outer square [0, 0]..[1, 1]
        if (!cw_outer) {
            col.move(0, 0);
            col.line(1, 0);
            col.line(1, 1);
            col.line(0, 1);
            col.close();
            // Inner CW hole [0.25, 0.25]..[0.75, 0.75]
            col.move(0.25, 0.25);
            col.line(0.25, 0.75);
            col.line(0.75, 0.75);
            col.line(0.75, 0.25);
            col.close();
        } else {
            col.move(0, 0);
            col.line(0, 1);
            col.line(1, 1);
            col.line(1, 0);
            col.close();
            // Inner CCW hole [0.25, 0.25]..[0.75, 0.75]
            col.move(0.25, 0.25);
            col.line(0.75, 0.25);
            col.line(0.75, 0.75);
            col.line(0.25, 0.75);
            col.close();
        }

        embolden(col.itemsMut(), 0.1); // half = 0.05 on each side
        const s = col.slice();
        const outer_b = bounds(s[0..4]).?;
        const inner_b = bounds(s[4..8]).?;

        try std.testing.expectApproxEqAbs(@as(f32, -0.05), outer_b[0], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, -0.05), outer_b[1], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1.05), outer_b[2], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1.05), outer_b[3], 1e-5);

        try std.testing.expectApproxEqAbs(@as(f32, 0.30), inner_b[0], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.30), inner_b[1], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.70), inner_b[2], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.70), inner_b[3], 1e-5);

        // Contours stay watertight.
        for (0..4) |k| try std.testing.expectEqual(s[k].p3, s[(k + 1) % 4].p1);
        for (0..4) |k| try std.testing.expectEqual(s[4 + k].p3, s[4 + (k + 1) % 4].p1);
    }
}

test "extractFontGlyph normalizes em-space, skews ascenders right, and emboldens stems" {
    const gpa = std.testing.allocator;
    const testfont = @import("testfont.zig");
    const sfnt_bytes = try testfont.build(gpa, .{});
    defer gpa.free(sfnt_bytes);

    const f = try Font.init(sfnt_bytes, 0);
    const g = f.glyphIndex('A');
    var col = Collector.init(gpa);
    defer col.deinit();

    // testfont boxGlyph: [50, 0, 450, 700] at 1000 upem -> [0.05, 0.0, 0.45, 0.70]
    const b0 = extractFontGlyph(gpa, &f, g, 0.0, 0.0, &col).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), b0[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.00), b0[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), b0[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70), b0[3], 1e-5);

    // Positive skew leans top (y = 0.70 > 0) right by +0.2 * 0.70 = +0.14.
    const b_skew = extractFontGlyph(gpa, &f, g, 0.2, 0.0, &col).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), b_skew[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.59), b_skew[2], 1e-5);

    // Embolden widens both sides by half = 0.02.
    const b_bold = extractFontGlyph(gpa, &f, g, 0.0, 0.04, &col).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.03), b_bold[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.47), b_bold[2], 1e-5);

    // CFF outlines and real WOFF2 TrueType splines ('o' and whitespace ' ').
    const cff_bytes = try testfont.build(gpa, .{ .cff = true });
    defer gpa.free(cff_bytes);
    const f_cff = try Font.init(cff_bytes, 0);
    const b_cff = extractFontGlyph(gpa, &f_cff, f_cff.glyphIndex('A'), 0.0, 0.0, &col).?;
    try std.testing.expect(b_cff[2] > b_cff[0] and b_cff[3] > b_cff[1]);

    const sfnt = @import("sfnt.zig");
    const lato_bytes = try sfnt.decode(gpa, @embedFile("data/lato-subset.woff2"));
    defer gpa.free(lato_bytes);
    const lato = try Font.init(lato_bytes, 0);
    try std.testing.expectEqual(@as(?[4]f32, null), extractFontGlyph(gpa, &lato, lato.glyphIndex(' '), 0.0, 0.0, &col));

    const bo = extractFontGlyph(gpa, &lato, lato.glyphIndex('o'), 0.0, 0.0, &col).?;
    const n_curves = col.slice().len;
    try std.testing.expect(n_curves >= 8);
    const bo_bold = extractFontGlyph(gpa, &lato, lato.glyphIndex('o'), 0.0, 0.04, &col).?;
    try std.testing.expectEqual(n_curves, col.slice().len);
    try std.testing.expectApproxEqAbs(bo[0] - 0.02, bo_bold[0], 2e-3);
    try std.testing.expectApproxEqAbs(bo[2] + 0.02, bo_bold[2], 2e-3);
}
