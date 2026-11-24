// Analytic Slug quadratic Bezier coverage evaluator in GLSL ES 3.00 for WebGL2,
// matching slug_store.zig (evalCoverage) and shader_slug.wgsl.
#if defined(STAGE_FS) && defined(ENTRY_QUAD_FS)
uniform highp usampler2D u_slug;

uint slug_fetch(uint idx) {
    int y = int(idx >> 10u);
    return y < textureSize(u_slug, 0).y ? texelFetch(u_slug, ivec2(int(idx & 1023u), y), 0).r : 0u;
}

vec2 slug_dequant(uint w, vec2 min_p, vec2 scale_p) {
    return min_p + vec2(float(w & 0xFFFFu), float(w >> 16u)) * scale_p;
}

uint slug_calc_root_code(float y1, float y2, float y3) {
    uint s1 = floatBitsToUint(y1) >> 31u;
    uint s2 = floatBitsToUint(y2) >> 30u;
    uint s3 = floatBitsToUint(y3) >> 29u;
    uint shift = (s2 & 2u) | (s1 & ~2u);
    shift = (s3 & 4u) | (shift & ~4u);
    return (0x2E74u >> shift) & 0x0101u;
}

vec2 slug_solve_horiz_poly(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float t1, t2;
    if (abs(a.y) < 1.0 / 65536.0) {
        t1 = p12.y * (0.5 / b.y);
        t2 = t1;
    } else {
        float ra = 1.0 / a.y;
        float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
        t1 = (b.y - d) * ra;
        t2 = (b.y + d) * ra;
    }
    return vec2((a.x * t1 - b.x * 2.0) * t1 + p12.x, (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

vec2 slug_solve_vert_poly(vec4 p12, vec2 p3) {
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float t1, t2;
    if (abs(a.x) < 1.0 / 65536.0) {
        t1 = p12.x * (0.5 / b.x);
        t2 = t1;
    } else {
        float ra = 1.0 / a.x;
        float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
        t1 = (b.x - d) * ra;
        t2 = (b.x + d) * ra;
    }
    return vec2((a.y * t1 - b.y * 2.0) * t1 + p12.y, (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

float slug_calc_coverage(float xcov, float ycov, float xwgt, float ywgt) {
    float cov = max(
        abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
        min(abs(xcov), abs(ycov))
    );
    return clamp(cov, 0.0, 1.0);
}

float slug_coverage(uint blob, vec2 render_coord, vec2 ems_per_pixel) {
    if (blob == 0u) return 0.0;
    if (!(ems_per_pixel.x > 0.0 && ems_per_pixel.y > 0.0)) return 0.0;

    vec2 min_p = vec2(uintBitsToFloat(slug_fetch(blob + 0u)), uintBitsToFloat(slug_fetch(blob + 1u)));
    vec2 scale_p = vec2(uintBitsToFloat(slug_fetch(blob + 2u)), uintBitsToFloat(slug_fetch(blob + 3u)));
    vec2 band_scale = vec2(uintBitsToFloat(slug_fetch(blob + 4u)), uintBitsToFloat(slug_fetch(blob + 5u)));
    vec2 band_offset = vec2(uintBitsToFloat(slug_fetch(blob + 6u)), uintBitsToFloat(slug_fetch(blob + 7u)));
    uint meta = slug_fetch(blob + 8u);

    uint points_rel = meta & 0xFFFFu;
    uint band_max_x = (meta >> 16u) & 0xFFu;
    uint band_max_y = (meta >> 24u) & 0xFFu;
    uint h_count = band_max_y + 1u;
    uint points_base = blob + points_rel;
    vec2 pixels_per_em = vec2(1.0) / max(ems_per_pixel, vec2(1e-6));

    uint bx = uint(clamp(floor(render_coord.x * band_scale.x + band_offset.x), 0.0, float(band_max_x)));
    uint by = uint(clamp(floor(render_coord.y * band_scale.y + band_offset.y), 0.0, float(band_max_y)));

    float xcov = 0.0;
    float xwgt = 0.0;
    uint h_hdr = slug_fetch(blob + 9u + by);
    uint h_curve_count = min(h_hdr & 0xFFFFu, 1024u);
    uint h_list_word = blob + (h_hdr >> 16u);

    uint hk = 0u;
    while (hk < h_curve_count) {
        uint pair = slug_fetch(h_list_word + (hk >> 1u));
        uint p_idx = (pair >> ((hk & 1u) * 16u)) & 0xFFFFu;
        uint pb = points_base + p_idx;
        vec2 p1 = slug_dequant(slug_fetch(pb + 0u), min_p, scale_p) - render_coord;
        vec2 p2 = slug_dequant(slug_fetch(pb + 1u), min_p, scale_p) - render_coord;
        vec2 p3 = slug_dequant(slug_fetch(pb + 2u), min_p, scale_p) - render_coord;
        vec4 p12 = vec4(p1, p2);
        if (max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5) {
            hk = h_curve_count;
            continue;
        }
        uint code = slug_calc_root_code(p12.y, p12.w, p3.y);
        if (code != 0u) {
            vec2 r = slug_solve_horiz_poly(p12, p3);
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

    float ycov = 0.0;
    float ywgt = 0.0;
    uint v_hdr = slug_fetch(blob + 9u + h_count + bx);
    uint v_curve_count = min(v_hdr & 0xFFFFu, 1024u);
    uint v_list_word = blob + (v_hdr >> 16u);

    uint vk = 0u;
    while (vk < v_curve_count) {
        uint pair = slug_fetch(v_list_word + (vk >> 1u));
        uint p_idx = (pair >> ((vk & 1u) * 16u)) & 0xFFFFu;
        uint pb = points_base + p_idx;
        vec2 p1 = slug_dequant(slug_fetch(pb + 0u), min_p, scale_p) - render_coord;
        vec2 p2 = slug_dequant(slug_fetch(pb + 1u), min_p, scale_p) - render_coord;
        vec2 p3 = slug_dequant(slug_fetch(pb + 2u), min_p, scale_p) - render_coord;
        vec4 p12 = vec4(p1, p2);
        if (max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5) {
            vk = v_curve_count;
            continue;
        }
        uint code = slug_calc_root_code(p12.x, p12.z, p3.x);
        if (code != 0u) {
            vec2 r = slug_solve_vert_poly(p12, p3);
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
#endif
