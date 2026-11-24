//! Vector glyph extraction and `SlugStore` population for both portable
//! TrueType (`text_tt.zig`) and Apple CoreText (`text_mac.zig`).
const std = @import("std");
const slug_store = @import("slug_store.zig");
const curve = slug_store.curve;
const cf = if (!@import("text.zig").portable) @import("cf.zig") else struct {};

pub fn runFontSizeTt(ts: anytype, run_idx: usize, fallback: f32) f32 {
    if (run_idx >= ts.run_fonts.items.len) return fallback;
    const sz = ts.run_fonts.items[run_idx].size;
    return if (sz > 0) sz else fallback;
}

pub fn vectorGlyphTt(ts: anytype, run_idx: usize, glyph_id: u16) ?slug_store.Entry {
    if (run_idx >= ts.run_fonts.items.len or run_idx >= ts.run_faces.items.len) return null;
    const rf = ts.run_fonts.items[run_idx];
    const face_idx = ts.run_faces.items[run_idx];
    const is_private = face_idx < ts.db.faces.items.len and ts.db.faces.items[face_idx].private;
    const gen: u64 = if (is_private) (ts.fonts_seen + 1) else 0;
    const face_key: u64 = (gen << 32) | @as(u64, face_idx);
    const key: slug_store.Key = .{
        .face = face_key,
        .glyph = glyph_id,
        .skew_q8 = slug_store.quantizeSkew(rf.skew),
        .bold_q12 = slug_store.quantizeBold(rf.embolden),
    };
    if (ts.slug.get(key)) |hit| return hit;

    var col = curve.Collector.init(ts.gpa);
    defer col.deinit();
    const maybe_bounds = curve.extractFontGlyph(ts.gpa, rf.font, glyph_id, rf.skew, rf.embolden, &col);
    if (col.alloc_failed) return null;
    const gb = maybe_bounds orelse return ts.slug.putEmpty(ts.gpa, key) catch null;
    return ts.slug.putCurves(ts.gpa, key, col.slice(), gb) catch null;
}

pub fn runFontSizeMac(ts: anytype, run_idx: usize, fallback: f32) f32 {
    if (run_idx >= ts.run_fonts.items.len) return fallback;
    const sz: f32 = @floatCast(cf.CTFontGetSize(ts.run_fonts.items[run_idx]));
    return if (sz > 0) sz else fallback;
}

pub fn vectorGlyphMac(ts: anytype, run_idx: usize, glyph_id: u16) ?slug_store.Entry {
    if (run_idx >= ts.run_fonts.items.len) return null;
    const ct_font = ts.run_fonts.items[run_idx];
    const pt_size = @max(cf.CTFontGetSize(ct_font), 1e-3);
    const stroke_pt: f32 = if (run_idx < ts.run_strokes.items.len) ts.run_strokes.items[run_idx] else 0;
    const embolden_em: f32 = stroke_pt / @as(f32, @floatCast(pt_size));
    const face_key = ensureMacFaceKey(ts, run_idx, ct_font);
    const mat = cf.CTFontGetMatrix(ct_font);
    const key: slug_store.Key = .{
        .face = face_key,
        .glyph = glyph_id,
        .skew_q8 = slug_store.quantizeSkew(@floatCast(mat.c)),
        .bold_q12 = slug_store.quantizeBold(embolden_em),
    };
    if (ts.slug.get(key)) |hit| return hit;

    const inv_pt = 1.0 / pt_size;
    const unscale: cf.CGAffineTransform = .{ .a = inv_pt, .b = 0, .c = 0, .d = inv_pt, .tx = 0, .ty = 0 };
    const path = cf.CTFontCreatePathForGlyph(ct_font, glyph_id, &unscale) orelse {
        const color_glyphs_trait: u32 = 1 << 13;
        if ((cf.CTFontGetSymbolicTraits(ct_font) & color_glyphs_trait) != 0) return null;
        return ts.slug.putEmpty(ts.gpa, key) catch null;
    };
    defer cf.CFRelease(path);

    var col = curve.Collector.init(ts.gpa);
    defer col.deinit();
    cf.CGPathApply(path, &col, macPathCb);
    if (col.alloc_failed) return null;
    if (embolden_em > 0) curve.embolden(col.itemsMut(), embolden_em);
    const gb = curve.bounds(col.slice()) orelse return ts.slug.putEmpty(ts.gpa, key) catch null;
    return ts.slug.putCurves(ts.gpa, key, col.slice(), gb) catch null;
}

fn ensureMacFaceKey(ts: anytype, run_idx: usize, ct_font: cf.CTFontRef) u64 {
    if (run_idx < ts.run_face_keys.items.len and ts.run_face_keys.items[run_idx] != 0) {
        return ts.run_face_keys.items[run_idx];
    }
    const fk = computeMacFaceKey(ct_font, ts.fonts_seen);
    if (ts.run_face_keys.items.len <= run_idx) {
        const old_len = ts.run_face_keys.items.len;
        if (ts.run_face_keys.resize(ts.gpa, run_idx + 1)) |_| {
            @memset(ts.run_face_keys.items[old_len..], 0);
            ts.run_face_keys.items[run_idx] = fk;
        } else |_| {}
    } else {
        ts.run_face_keys.items[run_idx] = fk;
    }
    return fk;
}

fn computeMacFaceKey(ct_font: cf.CTFontRef, fonts_seen: u64) u64 {
    const c_hash = struct {
        extern "c" fn CFHash(ref: *anyopaque) usize;
    };
    var h = std.hash.Wyhash.init(0x534c_5547_4d41_4331 ^ fonts_seen);
    const traits = cf.CTFontGetSymbolicTraits(ct_font);
    h.update(std.mem.asBytes(&traits));
    const mat = cf.CTFontGetMatrix(ct_font);
    const qmat = [4]i32{
        @intFromFloat(std.math.clamp(@round(mat.a * 65536.0), -2e9, 2e9)),
        @intFromFloat(std.math.clamp(@round(mat.b * 65536.0), -2e9, 2e9)),
        @intFromFloat(std.math.clamp(@round(mat.c * 65536.0), -2e9, 2e9)),
        @intFromFloat(std.math.clamp(@round(mat.d * 65536.0), -2e9, 2e9)),
    };
    h.update(std.mem.asBytes(&qmat));
    if (cf.CTFontCopyPostScriptName(ct_font)) |ps| {
        defer cf.CFRelease(ps);
        var buf: [256]u8 = undefined;
        if (cf.CFStringGetCString(ps, &buf, buf.len, cf.utf8_encoding)) {
            h.update(std.mem.sliceTo(&buf, 0));
        }
    }
    if (cf.CTFontCopyGraphicsFont(ct_font, null)) |cg| {
        defer cf.CFRelease(cg);
        const cgh: u64 = @intCast(c_hash.CFHash(cg));
        h.update(std.mem.asBytes(&cgh));
    }
    if (cf.CTFontCopyVariation(ct_font)) |var_dict| {
        defer cf.CFRelease(var_dict);
        var var_mix: u64 = 0;
        cf.CFDictionaryApplyFunction(var_dict, macVariationCb, &var_mix);
        h.update(std.mem.asBytes(&var_mix));
    }
    return h.final() | 1;
}

const MacCbs = if (!@import("text.zig").portable) struct {
    fn path(info: ?*anyopaque, elem: *const cf.CGPathElement) callconv(.c) void {
        const col: *curve.Collector = @ptrCast(@alignCast(info.?));
        const pts = elem.points;
        switch (elem.type) {
            .move_to_point => col.move(@floatCast(pts[0].x), @floatCast(pts[0].y)),
            .add_line_to_point => col.line(@floatCast(pts[0].x), @floatCast(pts[0].y)),
            .add_quad_curve_to_point => col.quad(@floatCast(pts[0].x), @floatCast(pts[0].y), @floatCast(pts[1].x), @floatCast(pts[1].y)),
            .add_curve_to_point => col.cubic(
                @floatCast(pts[0].x),
                @floatCast(pts[0].y),
                @floatCast(pts[1].x),
                @floatCast(pts[1].y),
                @floatCast(pts[2].x),
                @floatCast(pts[2].y),
            ),
            .close_subpath => col.close(),
        }
    }

    fn variation(k: ?*const anyopaque, v: ?*const anyopaque, ctx: ?*anyopaque) callconv(.c) void {
        const acc: *u64 = @ptrCast(@alignCast(ctx.?));
        const key_ref = k orelse return;
        const val_ref = v orelse return;
        var axis_tag: i64 = 0;
        var axis_val: f64 = 0;
        const number_float64: cf.CFIndex = 6;
        if (!cf.CFNumberGetValue(@constCast(key_ref), cf.number_sint64, &axis_tag)) return;
        if (!cf.CFNumberGetValue(@constCast(val_ref), number_float64, &axis_val)) return;
        const qv: i64 = @intFromFloat(std.math.clamp(@round(axis_val * 4096.0), -1e12, 1e12));
        var pair: [16]u8 = undefined;
        pair[0..8].* = std.mem.asBytes(&axis_tag).*;
        pair[8..16].* = std.mem.asBytes(&qv).*;
        acc.* ^= std.hash.Wyhash.hash(0x76617230, &pair);
    }
} else struct {};

const macPathCb = if (!@import("text.zig").portable) MacCbs.path else {};
const macVariationCb = if (!@import("text.zig").portable) MacCbs.variation else {};
