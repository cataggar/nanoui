// Analytic Slug quadratic Bezier coverage evaluator in WGSL, matching
// slug_store.zig (evalCoverage). Zero screen-space derivatives; uses while
// loops without break to avoid Mesa Lavapipe SPIR-V loop-lowering bugs.
@group(0) @binding(6) var slug_tex: texture_2d<u32>;

fn slug_fetch(idx: u32) -> u32 {
    let y = idx >> 10u;
    if (y >= textureDimensions(slug_tex).y) { return 0u; }
    return textureLoad(slug_tex, vec2i(i32(idx & 1023u), i32(y)), 0).r;
}

fn slug_dequant(w: u32, min_p: vec2f, scale_p: vec2f) -> vec2f {
    return min_p + vec2f(f32(w & 0xFFFFu), f32(w >> 16u)) * scale_p;
}

fn slug_calc_root_code(y1: f32, y2: f32, y3: f32) -> u32 {
    let s1 = bitcast<u32>(y1) >> 31u;
    let s2 = bitcast<u32>(y2) >> 30u;
    let s3 = bitcast<u32>(y3) >> 29u;
    var shift = (s2 & 2u) | (s1 & ~2u);
    shift = (s3 & 4u) | (shift & ~4u);
    return (0x2E74u >> shift) & 0x0101u;
}

fn slug_solve_horiz_poly(p12: vec4f, p3: vec2f) -> vec2f {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    var t1 = 0.0;
    var t2 = 0.0;
    if (abs(a.y) < 1.0 / 65536.0) {
        t1 = p12.y * (0.5 / b.y);
        t2 = t1;
    } else {
        let ra = 1.0 / a.y;
        let d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
        t1 = (b.y - d) * ra;
        t2 = (b.y + d) * ra;
    }
    return vec2f((a.x * t1 - b.x * 2.0) * t1 + p12.x, (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

fn slug_solve_vert_poly(p12: vec4f, p3: vec2f) -> vec2f {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    var t1 = 0.0;
    var t2 = 0.0;
    if (abs(a.x) < 1.0 / 65536.0) {
        t1 = p12.x * (0.5 / b.x);
        t2 = t1;
    } else {
        let ra = 1.0 / a.x;
        let d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
        t1 = (b.x - d) * ra;
        t2 = (b.x + d) * ra;
    }
    return vec2f((a.y * t1 - b.y * 2.0) * t1 + p12.y, (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

fn slug_calc_coverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) -> f32 {
    let cov = max(
        abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
        min(abs(xcov), abs(ycov)),
    );
    return clamp(cov, 0.0, 1.0);
}

fn slug_coverage(blob: u32, render_coord: vec2f, ems_per_pixel: vec2f) -> f32 {
    if (blob == 0u) { return 0.0; }
    if (!(ems_per_pixel.x > 0.0 && ems_per_pixel.y > 0.0)) { return 0.0; }

    let min_p = vec2f(bitcast<f32>(slug_fetch(blob + 0u)), bitcast<f32>(slug_fetch(blob + 1u)));
    let scale_p = vec2f(bitcast<f32>(slug_fetch(blob + 2u)), bitcast<f32>(slug_fetch(blob + 3u)));
    let band_scale = vec2f(bitcast<f32>(slug_fetch(blob + 4u)), bitcast<f32>(slug_fetch(blob + 5u)));
    let band_offset = vec2f(bitcast<f32>(slug_fetch(blob + 6u)), bitcast<f32>(slug_fetch(blob + 7u)));
    let hdr_meta = slug_fetch(blob + 8u);

    let points_rel = hdr_meta & 0xFFFFu;
    let band_max_x = (hdr_meta >> 16u) & 0xFFu;
    let band_max_y = (hdr_meta >> 24u) & 0xFFu;
    let h_count = band_max_y + 1u;
    let points_base = blob + points_rel;
    let pixels_per_em = vec2f(1.0) / max(ems_per_pixel, vec2f(1e-6));

    let bx = u32(clamp(floor(render_coord.x * band_scale.x + band_offset.x), 0.0, f32(band_max_x)));
    let by = u32(clamp(floor(render_coord.y * band_scale.y + band_offset.y), 0.0, f32(band_max_y)));

    var xcov = 0.0;
    var xwgt = 0.0;
    let h_hdr = slug_fetch(blob + 9u + by);
    let h_curve_count = min(h_hdr & 0xFFFFu, 1024u);
    let h_list_word = blob + (h_hdr >> 16u);

    var hk = 0u;
    while (hk < h_curve_count) {
        let pair = slug_fetch(h_list_word + (hk >> 1u));
        let p_idx = (pair >> ((hk & 1u) * 16u)) & 0xFFFFu;
        let pb = points_base + p_idx;
        let p1 = slug_dequant(slug_fetch(pb + 0u), min_p, scale_p) - render_coord;
        let p2 = slug_dequant(slug_fetch(pb + 1u), min_p, scale_p) - render_coord;
        let p3 = slug_dequant(slug_fetch(pb + 2u), min_p, scale_p) - render_coord;
        let p12 = vec4f(p1, p2);
        if (max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5) {
            hk = h_curve_count;
            continue;
        }
        let code = slug_calc_root_code(p12.y, p12.w, p3.y);
        if (code != 0u) {
            let r = slug_solve_horiz_poly(p12, p3);
            if ((code & 1u) != 0u) {
                xcov += clamp(r.x * pixels_per_em.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x * pixels_per_em.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                xcov -= clamp(r.y * pixels_per_em.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y * pixels_per_em.x) * 2.0, 0.0, 1.0));
            }
        }
        hk += 1u;
    }

    var ycov = 0.0;
    var ywgt = 0.0;
    let v_hdr = slug_fetch(blob + 9u + h_count + bx);
    let v_curve_count = min(v_hdr & 0xFFFFu, 1024u);
    let v_list_word = blob + (v_hdr >> 16u);

    var vk = 0u;
    while (vk < v_curve_count) {
        let pair = slug_fetch(v_list_word + (vk >> 1u));
        let p_idx = (pair >> ((vk & 1u) * 16u)) & 0xFFFFu;
        let pb = points_base + p_idx;
        let p1 = slug_dequant(slug_fetch(pb + 0u), min_p, scale_p) - render_coord;
        let p2 = slug_dequant(slug_fetch(pb + 1u), min_p, scale_p) - render_coord;
        let p3 = slug_dequant(slug_fetch(pb + 2u), min_p, scale_p) - render_coord;
        let p12 = vec4f(p1, p2);
        if (max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5) {
            vk = v_curve_count;
            continue;
        }
        let code = slug_calc_root_code(p12.x, p12.z, p3.x);
        if (code != 0u) {
            let r = slug_solve_vert_poly(p12, p3);
            if ((code & 1u) != 0u) {
                ycov -= clamp(r.x * pixels_per_em.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x * pixels_per_em.y) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                ycov += clamp(r.y * pixels_per_em.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y * pixels_per_em.y) * 2.0, 0.0, 1.0));
            }
        }
        vk += 1u;
    }

    return slug_calc_coverage(xcov, ycov, xwgt, ywgt);
}
