//! Transform chain, backface visibility, inverse frame mapping, pixel bounds,
//! and incremental damage rectangles for the CPU renderer (`raster.zig`).
//! Matches `shader.metal` and `shader_shapes.wgsl` forward and inverse math.
const std = @import("std");
const gpu = @import("gpu.zig");

pub const LocalPoint = struct {
    world: [2]f32,
    unrot: [2]f32,
    landed: [2]f32,
};

pub const ForwardPoint = struct {
    world: [2]f32,
    landed: [2]f32,
    seen: [2]f32,
};

/// Backface culling matching `shader.metal` and `shader.wgsl`:
/// front face (`vel[2] == 1`) hides when `cos(turn.x) < 0`;
/// back face (`vel[2] == 2`) hides when `cos(turn.x) >= 0`.
pub inline fn isHidden(i: *const gpu.Instance) bool {
    if (i.vel[2] != 1.0 and i.vel[2] != 2.0) return false;
    const ct = @cos(i.turn[0]);
    return (i.vel[2] == 1.0 and ct < 0.0) or (i.vel[2] == 2.0 and ct >= 0.0);
}

/// Whether `i` moves pixels away from axis-aligned identity coordinates.
pub inline fn hasTransform(i: *const gpu.Instance) bool {
    return i.xf[0] != 0.0 or i.turn[0] != 0.0 or i.vel[2] == 2.0 or gpu.hasMatrix(i) or gpu.affine(i) != null;
}

/// Clips in `landed` (`screen`) space before perspective `turn`.
pub inline fn inClip(i: *const gpu.Instance, landed: [2]f32) bool {
    return landed[0] >= i.clip[0] and landed[1] >= i.clip[1] and landed[0] <= i.clip[2] and landed[1] <= i.clip[3];
}

/// Projects a `landed` (`screen`) point through 3D `turn` into viewport `seen` points.
pub inline fn turnPoint(landed: [2]f32, i: *const gpu.Instance) [2]f32 {
    var seen = landed;
    if (i.turn[0] != 0.0) {
        const ct = @cos(i.turn[0]);
        const dx = landed[0] - i.turn[2];
        const z = -dx * @sin(i.turn[0]);
        seen = .{ i.turn[2] + dx * ct, landed[1] };
        if (i.turn[1] > 0.0) {
            const w = @max(1.0 - z / i.turn[1], 0.1);
            seen = .{ i.turn[2] + (seen[0] - i.turn[2]) / w, i.turn[3] + (seen[1] - i.turn[3]) / w };
        }
    }
    return seen;
}

/// Forward vertex projection from unrotated local-world `p_unrot` to `world`, `landed`, and `seen`.
pub fn forwardPoint(p_unrot: [2]f32, i: *const gpu.Instance) ForwardPoint {
    var p = p_unrot;
    if (i.kind != gpu.Kind.segment and i.kind != gpu.Kind.triangle) {
        if (i.vel[2] == 2.0) p[0] = 2.0 * i.vel[3] - p[0];
        if (gpu.affine(i)) |m| {
            const dx = p[0] - i.xf[2];
            const dy = p[1] - i.xf[3];
            p = .{ i.xf[2] + m[0] * dx + m[1] * dy, i.xf[3] + m[2] * dx + m[3] * dy };
        } else if (i.xf[0] != 0.0) {
            const ca = @cos(i.xf[0]);
            const sa = @sin(i.xf[0]);
            const dx = p[0] - i.xf[2];
            const dy = p[1] - i.xf[3];
            p = .{ i.xf[2] + ca * dx - sa * dy, i.xf[3] + sa * dx + ca * dy };
        }
    }
    const landed: [2]f32 = if (gpu.hasMatrix(i))
        .{ i.m[0] * p[0] + i.m[2] * p[1] + i.mt[0], i.m[1] * p[0] + i.m[3] * p[1] + i.mt[1] }
    else
        p;
    return .{ .world = p, .landed = landed, .seen = turnPoint(landed, i) };
}

/// Inverse transform from viewport `seen` points back to `landed`, `world`, and `unrot`.
pub fn inverseFrame(seen: [2]f32, i: *const gpu.Instance) ?LocalPoint {
    var landed = seen;
    if (i.turn[0] != 0.0) {
        const ct = @cos(i.turn[0]);
        const st = @sin(i.turn[0]);
        const qx = seen[0] - i.turn[2];
        const qy = seen[1] - i.turn[3];
        const inv: f32 = if (i.turn[1] > 0.0) st / i.turn[1] else 0.0;
        const denom = ct - qx * inv;
        if (@abs(denom) < 1e-6) return null;
        const dx = qx / denom;
        const w = 1.0 + dx * inv;
        if (i.turn[1] > 0.0 and w < 0.1) return null;
        landed = .{ i.turn[2] + dx, if (i.turn[1] > 0.0) i.turn[3] + qy * w else seen[1] };
    }
    var world = landed;
    if (gpu.hasMatrix(i)) {
        const det = i.m[0] * i.m[3] - i.m[2] * i.m[1];
        if (@abs(det) < 1e-8) return null;
        const q0: [2]f32 = .{ landed[0] - i.mt[0], landed[1] - i.mt[1] };
        world = .{ (i.m[3] * q0[0] - i.m[2] * q0[1]) / det, (-i.m[1] * q0[0] + i.m[0] * q0[1]) / det };
    }
    var unrot = world;
    if (i.kind != gpu.Kind.segment and i.kind != gpu.Kind.triangle) {
        if (gpu.affine(i)) |m| {
            const det_a = m[0] * m[3] - m[1] * m[2];
            if (@abs(det_a) < 1e-9) return null;
            const d: [2]f32 = .{ world[0] - i.xf[2], world[1] - i.xf[3] };
            unrot = .{ i.xf[2] + (m[3] * d[0] - m[1] * d[1]) / det_a, i.xf[3] + (-m[2] * d[0] + m[0] * d[1]) / det_a };
        } else if (i.xf[0] != 0.0) {
            const d: [2]f32 = .{ world[0] - i.xf[2], world[1] - i.xf[3] };
            const ca = @cos(i.xf[0]);
            const sa = @sin(i.xf[0]);
            unrot = .{ i.xf[2] + ca * d[0] + sa * d[1], i.xf[3] - sa * d[0] + ca * d[1] };
        }
        if (i.vel[2] == 2.0) unrot[0] = 2.0 * i.vel[3] - unrot[0];
    }
    return .{ .world = world, .unrot = unrot, .landed = landed };
}

/// Where a pixel is before the instance's plane transform (`Instance.m`).
pub inline fn unmatrix(i: *const gpu.Instance, wx: f32, wy: f32) [2]f32 {
    if (i.turn[0] != 0.0) {
        const pt = inverseFrame(.{ wx, wy }, i) orelse return .{ -1e9, -1e9 };
        if (!inClip(i, pt.landed)) return .{ -1e9, -1e9 };
        return pt.world;
    }
    if (!gpu.hasMatrix(i)) return .{ wx, wy };
    const det = i.m[0] * i.m[3] - i.m[1] * i.m[2];
    if (@abs(det) < 1e-9) return .{ -1e9, -1e9 };
    const dx = wx - i.mt[0];
    const dy = wy - i.mt[1];
    return .{ (i.m[3] * dx - i.m[2] * dy) / det, (i.m[0] * dy - i.m[1] * dx) / det };
}

/// A pixel's size where a shape is worked out: what a `fwidth` of it finds.
pub inline fn pixelAt(i: *const gpu.Instance, inv: f32) f32 {
    if (!gpu.hasMatrix(i)) return inv;
    return inv / @max(@sqrt(@abs(i.m[0] * i.m[3] - i.m[1] * i.m[2])), 1e-3);
}

pub inline fn unrotate(i: *const gpu.Instance, wx_in: f32, wy_in: f32) [2]f32 {
    if (i.turn[0] != 0.0 or i.vel[2] == 2.0) {
        const pt = inverseFrame(.{ wx_in, wy_in }, i) orelse return .{ -1e9, -1e9 };
        if (i.turn[0] != 0.0 and !inClip(i, pt.landed)) return .{ -1e9, -1e9 };
        return pt.unrot;
    }
    const p = unmatrix(i, wx_in, wy_in);
    if (i.kind == gpu.Kind.texture) if (gpu.affine(i)) |m| {
        const det = m[0] * m[3] - m[1] * m[2];
        if (@abs(det) < 1e-9) return .{ -1e9, -1e9 };
        const dx = p[0] - i.xf[2];
        const dy = p[1] - i.xf[3];
        return .{ i.xf[2] + (m[3] * dx - m[1] * dy) / det, i.xf[3] + (-m[2] * dx + m[0] * dy) / det };
    };
    const a = i.xf[0];
    if (a == 0) return p;
    const dx = p[0] - i.xf[2];
    const dy = p[1] - i.xf[3];
    const ca = @cos(a);
    const sa = @sin(a);
    return .{ i.xf[2] + ca * dx + sa * dy, i.xf[3] - sa * dx + ca * dy };
}

/// The pixels an instance covers: its quad (grown for a shadow's blur),
/// within its clip and the frame.
pub fn bounds(out: gpu.Pixels, i: *const gpu.Instance, scale: f32) ?[4]usize {
    if (isHidden(i)) return null;
    if (i.kind == gpu.Kind.vector_text and (i.rect[2] <= 0 or i.rect[3] <= 0)) return null;
    const grow: f32 = if (i.kind == gpu.Kind.shadow or i.kind == gpu.Kind.shadow_out) i.border_width * 3 else 0;
    var rx0 = i.rect[0] - grow;
    var ry0 = i.rect[1] - grow;
    var rx1 = i.rect[0] + i.rect[2] + grow;
    var ry1 = i.rect[1] + i.rect[3] + grow;
    const w: f32 = @floatFromInt(out.width);
    const h: f32 = @floatFromInt(out.height);

    if (i.turn[0] != 0.0) {
        if (i.clip[2] <= i.clip[0] or i.clip[3] <= i.clip[1]) return null;
        const corners = [4][2]f32{ .{ rx0, ry0 }, .{ rx1, ry0 }, .{ rx0, ry1 }, .{ rx1, ry1 } };
        var lx0: f32 = std.math.inf(f32);
        var ly0: f32 = std.math.inf(f32);
        var lx1: f32 = -std.math.inf(f32);
        var ly1: f32 = -std.math.inf(f32);
        for (corners) |c| {
            const fp = forwardPoint(c, i);
            lx0 = @min(lx0, fp.landed[0]);
            ly0 = @min(ly0, fp.landed[1]);
            lx1 = @max(lx1, fp.landed[0]);
            ly1 = @max(ly1, fp.landed[1]);
        }
        lx0 = @max(lx0, i.clip[0]);
        ly0 = @max(ly0, i.clip[1]);
        lx1 = @min(lx1, i.clip[2]);
        ly1 = @min(ly1, i.clip[3]);
        if (lx1 <= lx0 or ly1 <= ly0) return null;

        const landed_corners = [4][2]f32{ .{ lx0, ly0 }, .{ lx1, ly0 }, .{ lx0, ly1 }, .{ lx1, ly1 } };
        var sx0: f32 = std.math.inf(f32);
        var sy0: f32 = std.math.inf(f32);
        var sx1: f32 = -std.math.inf(f32);
        var sy1: f32 = -std.math.inf(f32);
        for (landed_corners) |lc| {
            const seen = turnPoint(lc, i);
            sx0 = @min(sx0, seen[0]);
            sy0 = @min(sy0, seen[1]);
            sx1 = @max(sx1, seen[0]);
            sy1 = @max(sy1, seen[1]);
        }
        if (sx1 <= sx0 or sy1 <= sy0) return null;
        const px0 = std.math.clamp(@floor(sx0 * scale), 0, w);
        const py0 = std.math.clamp(@floor(sy0 * scale), 0, h);
        const px1 = std.math.clamp(@ceil(sx1 * scale), 0, w);
        const py1 = std.math.clamp(@ceil(sy1 * scale), 0, h);
        if (px1 <= px0 or py1 <= py0) return null;
        return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
    }

    const map = gpu.affine(i);
    if (i.xf[0] != 0 or map != null) {
        const ca = @cos(i.xf[0]);
        const sa = @sin(i.xf[0]);
        const m = map orelse [4]f32{ ca, -sa, sa, ca };
        const px = i.xf[2];
        const py = i.xf[3];
        const xs = [4]f32{ rx0, rx1, rx0, rx1 };
        const ys = [4]f32{ ry0, ry0, ry1, ry1 };
        rx0 = 1e9;
        ry0 = 1e9;
        rx1 = -1e9;
        ry1 = -1e9;
        for (0..4) |k| {
            const dx = xs[k] - px;
            const dy = ys[k] - py;
            const tx = px + m[0] * dx + m[1] * dy;
            const ty = py + m[2] * dx + m[3] * dy;
            rx0 = @min(rx0, tx);
            ry0 = @min(ry0, ty);
            rx1 = @max(rx1, tx);
            ry1 = @max(ry1, ty);
        }
    }
    if (gpu.hasMatrix(i)) {
        const xs = [4]f32{ rx0, rx1, rx0, rx1 };
        const ys = [4]f32{ ry0, ry0, ry1, ry1 };
        rx0 = 1e9;
        ry0 = 1e9;
        rx1 = -1e9;
        ry1 = -1e9;
        for (xs, ys) |x, y| {
            const tx = i.m[0] * x + i.m[2] * y + i.mt[0];
            const ty = i.m[1] * x + i.m[3] * y + i.mt[1];
            rx0 = @min(rx0, tx);
            ry0 = @min(ry0, ty);
            rx1 = @max(rx1, tx);
            ry1 = @max(ry1, ty);
        }
    }
    const x0 = @max(rx0, i.clip[0]);
    const y0 = @max(ry0, i.clip[1]);
    const x1 = @min(rx1, i.clip[2]);
    const y1 = @min(ry1, i.clip[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    // A pixel is drawn when its center is inside, as the GPU rasterizes.
    const px0 = std.math.clamp(@round(x0 * scale), 0, w);
    const py0 = std.math.clamp(@round(y0 * scale), 0, h);
    const px1 = std.math.clamp(@round(x1 * scale), 0, w);
    const py1 = std.math.clamp(@round(y1 * scale), 0, h);
    if (px1 <= px0 or py1 <= py0) return null;
    return .{ @intFromFloat(px0), @intFromFloat(py0), @intFromFloat(px1), @intFromFloat(py1) };
}

/// The pixels (x0, y0, x1, y1) in which a frame of `new` instances differs
/// from one of `old`, both drawn `width` x `height` with the same atlases;
/// null when none do.
pub fn damage(width: usize, height: usize, old: []const gpu.Instance, new: []const gpu.Instance, scale: f32) ?[4]usize {
    const out: gpu.Pixels = .{ .bytes = &.{}, .width = width, .height = height };
    for (new) |*i| if (i.kind == gpu.Kind.glass) return .{ 0, 0, width, height };
    var start: usize = 0;
    while (start < old.len and start < new.len and same(&old[start], &new[start])) start += 1;
    var old_end = old.len;
    var new_end = new.len;
    while (old_end > start and new_end > start and same(&old[old_end - 1], &new[new_end - 1])) {
        old_end -= 1;
        new_end -= 1;
    }
    const before = old[start..old_end];
    const after = new[start..new_end];
    var region: ?[4]usize = null;
    if (before.len == after.len) {
        for (before, after) |*a, *b| if (!same(a, b)) {
            cover(&region, bounds(out, a, scale));
            cover(&region, bounds(out, b, scale));
        };
    } else {
        for (before) |*a| cover(&region, bounds(out, a, scale));
        for (after) |*b| cover(&region, bounds(out, b, scale));
    }
    return region;
}

fn same(a: *const gpu.Instance, b: *const gpu.Instance) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn cover(region: *?[4]usize, b: ?[4]usize) void {
    const add = b orelse return;
    region.* = if (region.*) |r| .{ @min(r[0], add[0]), @min(r[1], add[1]), @max(r[2], add[2]), @max(r[3], add[3]) } else add;
}

test "forwardPoint and inverseFrame roundtrip mirror, rotation, affine, and perspective turn" {
    const inst: gpu.Instance = .{
        .rect = .{ 40, 60, 80, 50 },
        .color = .{ 1, 1, 1, 1 },
        .kind = gpu.Kind.vector_text,
        .xf = .{ 0.37, 0, 80, 85 },
        .vel = .{ 0, 0, 2.0, 80 },
        .turn = .{ 2.35, 500, 90, 90 },
        .m = .{ 1.25, 0.15, -0.2, 1.1 },
        .mt = .{ 12, -8, 0, 0 },
    };
    const pts = [_][2]f32{ .{ 40, 60 }, .{ 120, 60 }, .{ 65.5, 92.25 }, .{ 120, 110 } };
    for (pts) |p| {
        const fwd = forwardPoint(p, &inst);
        const inv = inverseFrame(fwd.seen, &inst).?;
        try std.testing.expectApproxEqAbs(fwd.landed[0], inv.landed[0], 1e-3);
        try std.testing.expectApproxEqAbs(fwd.landed[1], inv.landed[1], 1e-3);
        try std.testing.expectApproxEqAbs(fwd.world[0], inv.world[0], 1e-3);
        try std.testing.expectApproxEqAbs(fwd.world[1], inv.world[1], 1e-3);
        try std.testing.expectApproxEqAbs(p[0], inv.unrot[0], 1e-3);
        try std.testing.expectApproxEqAbs(p[1], inv.unrot[1], 1e-3);
    }
}

test "backface culling hides turned-away faces and damage tracks vector_text bounds" {
    const out: gpu.Pixels = .{ .bytes = &.{}, .width = 400, .height = 300 };
    var front = gpu.vectorGlyph(.{ 50, 40, 30, 20 }, .{ 0, 1, 1, 0 }, 9, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, .{ 0, 0, 400, 300 });
    front.vel = .{ 0, 0, 1.0, 65 };
    front.turn = .{ 0.4, 400, 65, 50 };
    try std.testing.expect(!isHidden(&front));
    try std.testing.expect(bounds(out, &front, 2.0) != null);

    front.turn[0] = 2.4;
    try std.testing.expect(isHidden(&front));
    try std.testing.expectEqual(@as(?[4]usize, null), bounds(out, &front, 2.0));

    var back = front;
    back.vel[2] = 2.0;
    try std.testing.expect(!isHidden(&back));
    try std.testing.expect(bounds(out, &back, 2.0) != null);
    back.turn[0] = 0.0;
    try std.testing.expect(isHidden(&back));
    try std.testing.expectEqual(@as(?[4]usize, null), bounds(out, &back, 2.0));

    const g1 = gpu.vectorGlyph(.{ 10, 20, 15, 18 }, .{ 0, 1, 1, 0 }, 9, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, .{ 0, 0, 400, 300 });
    const g2 = gpu.vectorGlyph(.{ 40, 20, 15, 18 }, .{ 0, 1, 1, 0 }, 9, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, .{ 0, 0, 400, 300 });
    try std.testing.expectEqual(@as(?[4]usize, .{ 20, 40, 110, 76 }), damage(400, 300, &.{g1}, &.{g2}, 2.0));
}
