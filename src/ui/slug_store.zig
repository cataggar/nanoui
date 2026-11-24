//! Relocatable `u32` word store and reference CPU coverage evaluator for Slug
//! vector glyphs. Packs glyph headers, band directories, `u16` curve lists, and
//! endpoint-shared `u16` quantized Bezier points into a 1024-wide `R32_UINT`
//! texture layout (`words.len == tex_height * 1024`), growing up to `4 MiB`
//! before triggering a frame-boundary reset.
const std = @import("std");
pub const curve = @import("tt/curve.zig");
pub const band = @import("tt/band.zig");

pub const tex_width: u32 = 1024;
pub const log_tex_width: u5 = 10;
pub const initial_rows: u32 = 16;
pub const max_rows: u32 = 1024;
pub const max_words: usize = @as(usize, tex_width) * max_rows;
pub const sentinel_words: u32 = 9;

pub const Key = struct {
    face: u64,
    glyph: u16,
    skew_q8: i16 = 0,
    bold_q12: u16 = 0,
};

pub const Entry = struct {
    blob: u32,
    bounds: [4]f32,
};

pub const View = struct {
    words: []const u32,
    width: u32,
    height: u32,
    used_words: u32,
    generation: u64,
};

pub const Error = std.mem.Allocator.Error || error{GlyphTooComplex};

pub fn quantizeSkew(skew: f32) i16 {
    if (!std.math.isFinite(skew)) return 0;
    return @intFromFloat(std.math.clamp(@round(skew * 256.0), -32768.0, 32767.0));
}

pub fn quantizeBold(embolden_em: f32) u16 {
    if (!std.math.isFinite(embolden_em)) return 0;
    return @intFromFloat(std.math.clamp(@round(@max(0.0, embolden_em) * 4096.0), 0.0, 65535.0));
}

fn quantizePoint(p: [2]f32, min_x: f32, min_y: f32, inv_x: f32, inv_y: f32) u32 {
    const qx: u32 = @intFromFloat(std.math.clamp(@round((p[0] - min_x) * inv_x), 0.0, 65535.0));
    const qy: u32 = @intFromFloat(std.math.clamp(@round((p[1] - min_y) * inv_y), 0.0, 65535.0));
    return qx | (qy << 16);
}

fn dequantizePoint(w: u32, min_x: f32, min_y: f32, scale_x: f32, scale_y: f32) [2]f32 {
    const qx: f32 = @floatFromInt(w & 0xFFFF);
    const qy: f32 = @floatFromInt(w >> 16);
    return .{ min_x + qx * scale_x, min_y + qy * scale_y };
}

pub const Store = struct {
    words: []u32 = &.{},
    tex_height: u32 = 0,
    used_words: u32 = 0,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    generation: u64 = 0,
    resets: u32 = 0,
    reset_during_frame: bool = false,
    band_indices: std.ArrayList(u16) = .empty,
    point_words: std.ArrayList(u32) = .empty,
    curve_point_idx: std.ArrayList(u16) = .empty,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        if (self.words.len > 0) allocator.free(self.words);
        self.map.deinit(allocator);
        self.band_indices.deinit(allocator);
        self.point_words.deinit(allocator);
        self.curve_point_idx.deinit(allocator);
        self.* = .{};
    }

    pub fn get(self: *const Store, key: Key) ?Entry {
        return self.map.get(key);
    }

    pub fn view(self: *const Store) View {
        return .{
            .words = self.words,
            .width = tex_width,
            .height = self.tex_height,
            .used_words = self.used_words,
            .generation = self.generation,
        };
    }

    pub fn clearResetFlag(self: *Store) void {
        self.reset_during_frame = false;
    }

    pub fn reset(self: *Store) void {
        self.map.clearRetainingCapacity();
        @memset(self.words[0..self.used_words], 0);
        self.used_words = if (self.words.len > 0) sentinel_words else 0;
        self.generation += 1;
        self.resets += 1;
    }

    pub fn putEmpty(self: *Store, allocator: std.mem.Allocator, key: Key) std.mem.Allocator.Error!Entry {
        if (self.map.get(key)) |existing| return existing;
        const entry: Entry = .{ .blob = 0, .bounds = .{ 0, 0, 0, 0 } };
        try self.map.put(allocator, key, entry);
        return entry;
    }

    fn growWordsTo(self: *Store, allocator: std.mem.Allocator, min_words: usize) std.mem.Allocator.Error!void {
        if (min_words <= self.words.len) return;
        var new_rows: u32 = if (self.tex_height == 0) initial_rows else self.tex_height;
        while (@as(usize, new_rows) * tex_width < min_words) new_rows *= 2;
        const new_len = @as(usize, new_rows) * tex_width;
        const new_words = try allocator.alloc(u32, new_len);
        const keep: usize = self.used_words;
        if (self.words.len > 0) {
            @memcpy(new_words[0..keep], self.words[0..keep]);
            @memset(new_words[keep..], 0);
            allocator.free(self.words);
        } else {
            @memset(new_words, 0);
        }
        self.words = new_words;
        self.tex_height = new_rows;
    }

    pub fn putCurves(
        self: *Store,
        allocator: std.mem.Allocator,
        key: Key,
        curves: []const curve.Curve,
        glyph_bounds: [4]f32,
    ) Error!Entry {
        if (self.map.get(key)) |existing| return existing;
        if (curves.len == 0) return self.putEmpty(allocator, key);
        if (curves.len > 32767) return error.GlyphTooComplex;

        const part = band.partition(allocator, curves, glyph_bounds, &self.band_indices) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EmptyGlyph => return self.putEmpty(allocator, key),
            error.TooManyCurves, error.InvalidGlyphBounds => return error.GlyphTooComplex,
        };

        const min_x = glyph_bounds[0];
        const min_y = glyph_bounds[1];
        const extent_x = glyph_bounds[2] - min_x;
        const extent_y = glyph_bounds[3] - min_y;
        const inv_x = 65535.0 / extent_x;
        const inv_y = 65535.0 / extent_y;

        self.point_words.clearRetainingCapacity();
        try self.point_words.ensureTotalCapacity(allocator, curves.len * 3);
        try self.curve_point_idx.resize(allocator, curves.len);

        var has_prev = false;
        var prev_qw3: u32 = 0;
        var prev_p3_idx: usize = 0;

        for (curves, 0..) |c, idx| {
            const qw1 = quantizePoint(c.p1, min_x, min_y, inv_x, inv_y);
            const qw2 = quantizePoint(c.p2, min_x, min_y, inv_x, inv_y);
            const qw3 = quantizePoint(c.p3, min_x, min_y, inv_x, inv_y);

            if (has_prev and qw1 == prev_qw3) {
                if (self.point_words.items.len + 2 > 65535) return error.GlyphTooComplex;
                self.curve_point_idx.items[idx] = @intCast(prev_p3_idx);
                self.point_words.appendAssumeCapacity(qw2);
                self.point_words.appendAssumeCapacity(qw3);
            } else {
                if (self.point_words.items.len + 3 > 65535) return error.GlyphTooComplex;
                self.curve_point_idx.items[idx] = @intCast(self.point_words.items.len);
                self.point_words.appendAssumeCapacity(qw1);
                self.point_words.appendAssumeCapacity(qw2);
                self.point_words.appendAssumeCapacity(qw3);
                has_prev = true;
            }
            prev_p3_idx = self.point_words.items.len - 1;
            prev_qw3 = qw3;
        }

        const h_count: usize = @as(usize, part.band_max_y) + 1;
        const v_count: usize = @as(usize, part.band_max_x) + 1;
        var points_rel: usize = 9 + h_count + v_count;
        for (0..h_count) |b| points_rel += (@as(usize, part.h_bands[b].count) + 1) / 2;
        for (0..v_count) |b| points_rel += (@as(usize, part.v_bands[b].count) + 1) / 2;

        if (points_rel > 65535 or self.point_words.items.len > 65535) return error.GlyphTooComplex;
        const glyph_words = points_rel + self.point_words.items.len;
        if (sentinel_words + glyph_words > max_words) return error.GlyphTooComplex;

        const cur_used: usize = if (self.used_words == 0) sentinel_words else self.used_words;
        if (cur_used + glyph_words > max_words) {
            try self.growWordsTo(allocator, sentinel_words + glyph_words);
            self.reset();
            try self.map.ensureUnusedCapacity(allocator, 1);
            self.reset_during_frame = true;
        } else {
            try self.growWordsTo(allocator, cur_used + glyph_words);
            try self.map.ensureUnusedCapacity(allocator, 1);
            if (self.used_words == 0) self.used_words = sentinel_words;
        }

        const blob: u32 = self.used_words;
        const base: usize = blob;
        self.words[base + 0] = @bitCast(min_x);
        self.words[base + 1] = @bitCast(min_y);
        self.words[base + 2] = @bitCast(extent_x / 65535.0);
        self.words[base + 3] = @bitCast(extent_y / 65535.0);
        self.words[base + 4] = @bitCast(part.band_scale[0]);
        self.words[base + 5] = @bitCast(part.band_scale[1]);
        self.words[base + 6] = @bitCast(part.band_offset[0]);
        self.words[base + 7] = @bitCast(part.band_offset[1]);
        self.words[base + 8] = @as(u32, @intCast(points_rel)) |
            (@as(u32, part.band_max_x) << 16) |
            (@as(u32, part.band_max_y) << 24);

        var hdr_idx: usize = base + 9;
        var list_rel: usize = 9 + h_count + v_count;
        inline for (.{ .{ part.h_bands, h_count }, .{ part.v_bands, v_count } }) |group| {
            for (0..group[1]) |b| {
                const info = group[0][b];
                self.words[hdr_idx] = @as(u32, info.count) | (@as(u32, @intCast(list_rel)) << 16);
                hdr_idx += 1;
                const indices = self.band_indices.items[info.start .. info.start + info.count];
                var i: usize = 0;
                while (i < indices.len) : (i += 2) {
                    const lo: u32 = self.curve_point_idx.items[indices[i]];
                    const hi: u32 = if (i + 1 < indices.len) self.curve_point_idx.items[indices[i + 1]] else 0;
                    self.words[base + list_rel] = lo | (hi << 16);
                    list_rel += 1;
                }
            }
        }
        std.debug.assert(list_rel == points_rel);
        @memcpy(self.words[base + points_rel ..][0..self.point_words.items.len], self.point_words.items);

        self.used_words = @intCast(base + glyph_words);
        self.generation += 1;

        const entry: Entry = .{ .blob = blob, .bounds = glyph_bounds };
        self.map.putAssumeCapacity(key, entry);
        return entry;
    }
};

pub fn calcRootCode(y1: f32, y2: f32, y3: f32) u32 {
    const s1: u32 = @as(u32, @bitCast(y1)) >> 31;
    const s2: u32 = @as(u32, @bitCast(y2)) >> 30;
    const s3: u32 = @as(u32, @bitCast(y3)) >> 29;
    var shift: u32 = (s2 & 2) | (s1 & ~@as(u32, 2));
    shift = (s3 & 4) | (shift & ~@as(u32, 4));
    return (@as(u32, 0x2E74) >> @intCast(shift)) & 0x0101;
}

pub fn solveHorizPoly(p12: [4]f32, p3: [2]f32) [2]f32 {
    const ax = p12[0] - p12[2] * 2.0 + p3[0];
    const ay = p12[1] - p12[3] * 2.0 + p3[1];
    const bx = p12[0] - p12[2];
    const by = p12[1] - p12[3];
    var t1: f32 = 0.0;
    var t2: f32 = 0.0;
    if (@abs(ay) < 1.0 / 65536.0) {
        t1 = p12[1] * (0.5 / by);
        t2 = t1;
    } else {
        const ra = 1.0 / ay;
        const d = @sqrt(@max(by * by - ay * p12[1], 0.0));
        t1 = (by - d) * ra;
        t2 = (by + d) * ra;
    }
    return .{
        (ax * t1 - bx * 2.0) * t1 + p12[0],
        (ax * t2 - bx * 2.0) * t2 + p12[0],
    };
}

pub fn solveVertPoly(p12: [4]f32, p3: [2]f32) [2]f32 {
    const ax = p12[0] - p12[2] * 2.0 + p3[0];
    const ay = p12[1] - p12[3] * 2.0 + p3[1];
    const bx = p12[0] - p12[2];
    const by = p12[1] - p12[3];
    var t1: f32 = 0.0;
    var t2: f32 = 0.0;
    if (@abs(ax) < 1.0 / 65536.0) {
        t1 = p12[0] * (0.5 / bx);
        t2 = t1;
    } else {
        const ra = 1.0 / ax;
        const d = @sqrt(@max(bx * bx - ax * p12[0], 0.0));
        t1 = (bx - d) * ra;
        t2 = (bx + d) * ra;
    }
    return .{
        (ay * t1 - by * 2.0) * t1 + p12[1],
        (ay * t2 - by * 2.0) * t2 + p12[1],
    };
}

pub fn calcCoverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) f32 {
    const cov = @max(
        @abs(xcov * xwgt + ycov * ywgt) / @max(xwgt + ywgt, 1.0 / 65536.0),
        @min(@abs(xcov), @abs(ycov)),
    );
    return std.math.clamp(cov, 0.0, 1.0);
}

/// Evaluates analytic Slug coverage at `render_coord` (em-space `y`-up) given
/// filter footprint `ems_per_pixel` along glyph X and Y.
pub fn evalCoverage(words: []const u32, blob: u32, render_coord: [2]f32, ems_per_pixel: [2]f32) f32 {
    if (blob == 0) return 0.0;
    const base: usize = blob;
    if (base + 9 > words.len) return 0.0;
    if (!(ems_per_pixel[0] > 0.0 and ems_per_pixel[1] > 0.0)) return 0.0;

    const min_x: f32 = @bitCast(words[base + 0]);
    const min_y: f32 = @bitCast(words[base + 1]);
    const scale_x: f32 = @bitCast(words[base + 2]);
    const scale_y: f32 = @bitCast(words[base + 3]);
    const band_scale_x: f32 = @bitCast(words[base + 4]);
    const band_scale_y: f32 = @bitCast(words[base + 5]);
    const band_offset_x: f32 = @bitCast(words[base + 6]);
    const band_offset_y: f32 = @bitCast(words[base + 7]);
    const meta = words[base + 8];

    const points_rel: usize = meta & 0xFFFF;
    const band_max_x: usize = (meta >> 16) & 0xFF;
    const band_max_y: usize = (meta >> 24) & 0xFF;
    const h_count = band_max_y + 1;
    const v_count = band_max_x + 1;
    if (base + 9 + h_count + v_count > words.len) return 0.0;

    const points_base = base + points_rel;
    const pixels_per_em_x = 1.0 / @max(ems_per_pixel[0], 1e-6);
    const pixels_per_em_y = 1.0 / @max(ems_per_pixel[1], 1e-6);

    const bx_f = @floor(render_coord[0] * band_scale_x + band_offset_x);
    const by_f = @floor(render_coord[1] * band_scale_y + band_offset_y);
    const band_x: usize = @intFromFloat(std.math.clamp(bx_f, 0.0, @as(f32, @floatFromInt(band_max_x))));
    const band_y: usize = @intFromFloat(std.math.clamp(by_f, 0.0, @as(f32, @floatFromInt(band_max_y))));

    var xcov: f32 = 0.0;
    var xwgt: f32 = 0.0;
    const h_hdr = words[base + 9 + band_y];
    const h_curves: usize = @min(h_hdr & 0xFFFF, 1024);
    const h_list = base + (h_hdr >> 16);
    if (h_list + ((h_curves + 1) >> 1) > words.len) return 0.0;

    for (0..h_curves) |i| {
        const pair = words[h_list + (i >> 1)];
        const pt_idx: usize = (pair >> @intCast((i & 1) * 16)) & 0xFFFF;
        const pb = points_base + pt_idx;
        if (pb + 3 > words.len) break;
        const p1 = dequantizePoint(words[pb + 0], min_x, min_y, scale_x, scale_y);
        const p2 = dequantizePoint(words[pb + 1], min_x, min_y, scale_x, scale_y);
        const p3 = dequantizePoint(words[pb + 2], min_x, min_y, scale_x, scale_y);

        const p12: [4]f32 = .{ p1[0] - render_coord[0], p1[1] - render_coord[1], p2[0] - render_coord[0], p2[1] - render_coord[1] };
        const p3r: [2]f32 = .{ p3[0] - render_coord[0], p3[1] - render_coord[1] };
        if (@max(@max(p12[0], p12[2]), p3r[0]) * pixels_per_em_x < -0.5) break;

        const code = calcRootCode(p12[1], p12[3], p3r[1]);
        if (code != 0) {
            const r = solveHorizPoly(p12, p3r);
            if ((code & 1) != 0) {
                xcov += std.math.clamp(r[0] * pixels_per_em_x + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, std.math.clamp(1.0 - @abs(r[0] * pixels_per_em_x) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                xcov -= std.math.clamp(r[1] * pixels_per_em_x + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, std.math.clamp(1.0 - @abs(r[1] * pixels_per_em_x) * 2.0, 0.0, 1.0));
            }
        }
    }

    var ycov: f32 = 0.0;
    var ywgt: f32 = 0.0;
    const v_hdr = words[base + 9 + h_count + band_x];
    const v_curves: usize = @min(v_hdr & 0xFFFF, 1024);
    const v_list = base + (v_hdr >> 16);
    if (v_list + ((v_curves + 1) >> 1) > words.len) return 0.0;

    for (0..v_curves) |i| {
        const pair = words[v_list + (i >> 1)];
        const pt_idx: usize = (pair >> @intCast((i & 1) * 16)) & 0xFFFF;
        const pb = points_base + pt_idx;
        if (pb + 3 > words.len) break;
        const p1 = dequantizePoint(words[pb + 0], min_x, min_y, scale_x, scale_y);
        const p2 = dequantizePoint(words[pb + 1], min_x, min_y, scale_x, scale_y);
        const p3 = dequantizePoint(words[pb + 2], min_x, min_y, scale_x, scale_y);

        const p12: [4]f32 = .{ p1[0] - render_coord[0], p1[1] - render_coord[1], p2[0] - render_coord[0], p2[1] - render_coord[1] };
        const p3r: [2]f32 = .{ p3[0] - render_coord[0], p3[1] - render_coord[1] };
        if (@max(@max(p12[1], p12[3]), p3r[1]) * pixels_per_em_y < -0.5) break;

        const code = calcRootCode(p12[0], p12[2], p3r[0]);
        if (code != 0) {
            const r = solveVertPoly(p12, p3r);
            if ((code & 1) != 0) {
                ycov -= std.math.clamp(r[0] * pixels_per_em_y + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, std.math.clamp(1.0 - @abs(r[0] * pixels_per_em_y) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                ycov += std.math.clamp(r[1] * pixels_per_em_y + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, std.math.clamp(1.0 - @abs(r[1] * pixels_per_em_y) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calcCoverage(xcov, ycov, xwgt, ywgt);
}

test "square endpoint sharing uses 9 point words and evalCoverage hits interior, edges, and exterior" {
    const gpa = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // Lazy before first glyph.
    try std.testing.expectEqual(@as(usize, 0), store.view().words.len);
    const empty = try store.putEmpty(gpa, .{ .face = 1, .glyph = 0 });
    try std.testing.expectEqual(@as(u32, 0), empty.blob);
    try std.testing.expectEqual(@as(usize, 0), store.view().words.len);

    var col = curve.Collector.init(gpa);
    defer col.deinit();
    col.move(0.1, 0.1);
    col.line(0.9, 0.1);
    col.line(0.9, 0.9);
    col.line(0.1, 0.9);
    col.close();

    const gb = curve.bounds(col.slice()).?;
    const entry = try store.putCurves(gpa, .{ .face = 1, .glyph = 1 }, col.slice(), gb);
    try std.testing.expectEqual(@as(u32, 9), entry.blob);

    // 4-line closed square: 9 header + 2 band headers + 2*2 band list words = points_rel 15;
    // endpoint sharing emits 1 + 4*2 = 9 point words (instead of 12) -> used_words = 9 + 15 + 9 = 33.
    const points_rel = store.words[entry.blob + 8] & 0xFFFF;
    const point_words = store.used_words - (entry.blob + points_rel);
    try std.testing.expectEqual(@as(u32, 9), point_words);

    const v = store.view();
    try std.testing.expectEqual(@as(usize, initial_rows * tex_width), v.words.len);
    const epp: [2]f32 = .{ 0.02, 0.02 }; // 50 px/em

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), evalCoverage(v.words, entry.blob, .{ 0.5, 0.5 }, epp), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), evalCoverage(v.words, entry.blob, .{ 0.0, 0.5 }, epp), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), evalCoverage(v.words, entry.blob, .{ 1.0, 0.5 }, epp), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), evalCoverage(v.words, entry.blob, .{ 0.1, 0.5 }, epp), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), evalCoverage(v.words, entry.blob, .{ 0.9, 0.5 }, epp), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), evalCoverage(v.words, entry.blob, .{ 0.5, 0.1 }, epp), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), evalCoverage(v.words, entry.blob, .{ 0.5, 0.9 }, epp), 1e-3);
}

test "square-with-hole ('O' glyph) evaluates stem=1, hole=0, outside=0, edge=0.5 for both windings" {
    const gpa = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    inline for (.{ false, true }, 0..) |cw_outer, idx| {
        var col = curve.Collector.init(gpa);
        defer col.deinit();

        if (!cw_outer) {
            col.move(0.0, 0.0);
            col.line(1.0, 0.0);
            col.line(1.0, 1.0);
            col.line(0.0, 1.0);
            col.close();
            col.move(0.3, 0.3);
            col.line(0.3, 0.7);
            col.line(0.7, 0.7);
            col.line(0.7, 0.3);
            col.close();
        } else {
            col.move(0.0, 0.0);
            col.line(0.0, 1.0);
            col.line(1.0, 1.0);
            col.line(1.0, 0.0);
            col.close();
            col.move(0.3, 0.3);
            col.line(0.7, 0.3);
            col.line(0.7, 0.7);
            col.line(0.3, 0.7);
            col.close();
        }

        const gb = curve.bounds(col.slice()).?;
        const e = try store.putCurves(gpa, .{ .face = 2, .glyph = @intCast(idx + 1) }, col.slice(), gb);
        const w = store.view().words;
        const epp: [2]f32 = .{ 0.01, 0.01 };

        // Stems (left, right, bottom, top)
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), evalCoverage(w, e.blob, .{ 0.15, 0.5 }, epp), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), evalCoverage(w, e.blob, .{ 0.85, 0.5 }, epp), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), evalCoverage(w, e.blob, .{ 0.5, 0.15 }, epp), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), evalCoverage(w, e.blob, .{ 0.5, 0.85 }, epp), 1e-4);
        // Center of hole and outside bbox
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), evalCoverage(w, e.blob, .{ 0.5, 0.5 }, epp), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), evalCoverage(w, e.blob, .{ -0.2, 0.5 }, epp), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), evalCoverage(w, e.blob, .{ 1.2, 0.5 }, epp), 1e-4);
        // Outer and inner edges
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), evalCoverage(w, e.blob, .{ 0.0, 0.5 }, epp), 1e-3);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), evalCoverage(w, e.blob, .{ 0.3, 0.5 }, epp), 1e-3);
    }
}

test "grow-until-reset doubles rows up to max_rows and resets cleanly when full" {
    const gpa = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);

    // Build a dense synthetic glyph (~10,000 disconnected curves -> ~30,000+ words per glyph).
    const heavy = try gpa.alloc(curve.Curve, 10_000);
    defer gpa.free(heavy);
    for (heavy, 0..) |*c, i| {
        const y: f32 = @as(f32, @floatFromInt(i % 1000)) * 0.001;
        const x: f32 = @as(f32, @floatFromInt(i / 1000)) * 0.09;
        c.* = .{ .p1 = .{ x, y }, .p2 = .{ x + 0.02, y + 0.0004 }, .p3 = .{ x + 0.04, y + 0.0008 } };
    }
    const gb: [4]f32 = .{ 0.0, 0.0, 1.0, 1.0 };

    var g: u16 = 1;
    while (!store.reset_during_frame) : (g += 1) {
        const e = try store.putCurves(gpa, .{ .face = 9, .glyph = g }, heavy, gb);
        const v = store.view();
        try std.testing.expectEqual(@as(usize, v.height) * v.width, v.words.len);
        if (store.reset_during_frame) {
            try std.testing.expectEqual(@as(u32, 1), store.resets);
            try std.testing.expectEqual(@as(u32, sentinel_words), e.blob);
            try std.testing.expectEqual(max_rows, v.height);
            try std.testing.expectEqual(@as(?Entry, null), store.get(.{ .face = 9, .glyph = 1 }));
            try std.testing.expect(store.get(.{ .face = 9, .glyph = g }) != null);
            break;
        }
        try std.testing.expect(g < 64);
    }
    store.clearResetFlag();
    try std.testing.expect(!store.reset_during_frame);
}

test "real curved Lato 'o' matches tt/raster analytic coverage across 48px grid" {
    const gpa = std.testing.allocator;
    const sfnt = @import("tt/sfnt.zig");
    const tt_raster = @import("tt/raster.zig");

    const lato_bytes = try sfnt.decode(gpa, @embedFile("tt/data/lato-subset.woff2"));
    defer gpa.free(lato_bytes);
    const f = try curve.Font.init(lato_bytes, 0);
    const g = f.glyphIndex('o');

    var col = curve.Collector.init(gpa);
    defer col.deinit();
    const gb = curve.extractFontGlyph(gpa, &f, g, 0.0, 0.0, &col).?;

    var store: Store = .{};
    defer store.deinit(gpa);
    const entry = try store.putCurves(gpa, .{ .face = 42, .glyph = g }, col.slice(), gb);

    const px_per_em: f32 = 48.0;
    const epp: [2]f32 = .{ 1.0 / px_per_em, 1.0 / px_per_em };
    const w: usize = 36;
    const h: usize = 36;
    var rast = try tt_raster.Raster.init(gpa, w, h);
    defer rast.deinit(gpa);

    const s = px_per_em / f.units_per_em;
    const ox: f32 = 2.0 - gb[0] * px_per_em;
    const oy: f32 = 2.0 + gb[3] * px_per_em;
    f.outline(g, .{ s, 0, 0, -s, ox, oy }, rast.sink());
    const ref_px = try gpa.alloc(u8, w * h);
    defer gpa.free(ref_px);
    rast.coverage(ref_px);

    var diff_sum: f32 = 0.0;
    const words = store.view().words;
    for (0..h) |py| {
        for (0..w) |px| {
            const em_x = (@as(f32, @floatFromInt(px)) + 0.5 - ox) / px_per_em;
            const em_y = (oy - (@as(f32, @floatFromInt(py)) + 0.5)) / px_per_em;
            const slug_cov = evalCoverage(words, entry.blob, .{ em_x, em_y }, epp);
            const ref_cov = @as(f32, @floatFromInt(ref_px[py * w + px])) / 255.0;
            diff_sum += @abs(slug_cov - ref_cov);
        }
    }
    const mean_diff = diff_sum / @as(f32, @floatFromInt(w * h));
    try std.testing.expect(mean_diff < 0.025);
}
