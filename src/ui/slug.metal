// Slug GPU quadratic Bezier vector glyph evaluation (`Kind.vector_text`, 13).
// Matches `src/ui/slug_store.zig` (`evalCoverage`) and `src/ui/slug.hlsl`.

static uint slug_fetch(texture2d<uint, access::read> slug_tex, uint idx) {
    uint y = idx >> 10u;
    return y < slug_tex.get_height() ? slug_tex.read(uint2(idx & 1023u, y), 0).x : 0u;
}

static float2 slug_dequant(uint w, float min_x, float min_y, float scale_x, float scale_y) {
    return float2(min_x + float(w & 0xFFFFu) * scale_x, min_y + float(w >> 16u) * scale_y);
}

static uint slug_root_code(float y1, float y2, float y3) {
    uint s1 = as_type<uint>(y1) >> 31u;
    uint s2 = as_type<uint>(y2) >> 30u;
    uint s3 = as_type<uint>(y3) >> 29u;
    uint shift = (s2 & 2u) | (s1 & ~2u);
    shift = (s3 & 4u) | (shift & ~4u);
    return (0x2E74u >> shift) & 0x0101u;
}

static float2 slug_solve_horiz(float4 p12, float2 p3) {
    float2 a = p12.xy - p12.zw * 2.0 + p3;
    float2 b = p12.xy - p12.zw;
    float t1 = 0.0;
    float t2 = 0.0;
    if (abs(a.y) < (1.0 / 65536.0)) {
        t1 = p12.y * (0.5 / b.y);
        t2 = t1;
    } else {
        float ra = 1.0 / a.y;
        float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
        t1 = (b.y - d) * ra;
        t2 = (b.y + d) * ra;
    }
    return float2((a.x * t1 - b.x * 2.0) * t1 + p12.x, (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

static float2 slug_solve_vert(float4 p12, float2 p3) {
    float2 a = p12.xy - p12.zw * 2.0 + p3;
    float2 b = p12.xy - p12.zw;
    float t1 = 0.0;
    float t2 = 0.0;
    if (abs(a.x) < (1.0 / 65536.0)) {
        t1 = p12.x * (0.5 / b.x);
        t2 = t1;
    } else {
        float ra = 1.0 / a.x;
        float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
        t1 = (b.x - d) * ra;
        t2 = (b.x + d) * ra;
    }
    return float2((a.y * t1 - b.y * 2.0) * t1 + p12.y, (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

static float slug_calc_coverage(float xcov, float ycov, float xwgt, float ywgt) {
    float cov = max(
        abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
        min(abs(xcov), abs(ycov))
    );
    return clamp(cov, 0.0, 1.0);
}

static float slug_coverage(texture2d<uint, access::read> slug_tex, uint blob, float2 render_coord, float2 ems_per_pixel) {
    if (blob == 0u || !(ems_per_pixel.x > 0.0 && ems_per_pixel.y > 0.0)) return 0.0;
    uint tex_words = slug_tex.get_height() << 10u;
    if ((blob + 8u) >= tex_words) return 0.0;

    float min_x = as_type<float>(slug_fetch(slug_tex, blob + 0u));
    float min_y = as_type<float>(slug_fetch(slug_tex, blob + 1u));
    float scale_x = as_type<float>(slug_fetch(slug_tex, blob + 2u));
    float scale_y = as_type<float>(slug_fetch(slug_tex, blob + 3u));
    float band_scale_x = as_type<float>(slug_fetch(slug_tex, blob + 4u));
    float band_scale_y = as_type<float>(slug_fetch(slug_tex, blob + 5u));
    float band_offset_x = as_type<float>(slug_fetch(slug_tex, blob + 6u));
    float band_offset_y = as_type<float>(slug_fetch(slug_tex, blob + 7u));
    uint meta = slug_fetch(slug_tex, blob + 8u);

    uint points_rel = meta & 0xFFFFu;
    uint band_max_x = (meta >> 16u) & 0xFFu;
    uint band_max_y = (meta >> 24u) & 0xFFu;
    uint h_count = band_max_y + 1u;
    uint points_base = blob + points_rel;

    float2 pixels_per_em = 1.0 / max(ems_per_pixel, float2(1e-6, 1e-6));
    uint bx = uint(clamp(floor(render_coord.x * band_scale_x + band_offset_x), 0.0, float(band_max_x)));
    uint by = uint(clamp(floor(render_coord.y * band_scale_y + band_offset_y), 0.0, float(band_max_y)));

    float xcov = 0.0;
    float xwgt = 0.0;
    uint h_hdr = slug_fetch(slug_tex, blob + 9u + by);
    uint h_curve_count = min(h_hdr & 0xFFFFu, 1024u);
    uint h_list_word = blob + (h_hdr >> 16u);
    for (uint hk = 0u; hk < h_curve_count; hk++) {
        uint pair = slug_fetch(slug_tex, h_list_word + (hk >> 1u));
        uint p_idx = (pair >> ((hk & 1u) * 16u)) & 0xFFFFu;
        uint pb = points_base + p_idx;
        float2 p1 = slug_dequant(slug_fetch(slug_tex, pb + 0u), min_x, min_y, scale_x, scale_y) - render_coord;
        float2 p2 = slug_dequant(slug_fetch(slug_tex, pb + 1u), min_x, min_y, scale_x, scale_y) - render_coord;
        float2 p3 = slug_dequant(slug_fetch(slug_tex, pb + 2u), min_x, min_y, scale_x, scale_y) - render_coord;
        float4 p12 = float4(p1, p2);
        if (max(max(p12.x, p12.z), p3.x) * pixels_per_em.x < -0.5) break;
        uint code = slug_root_code(p12.y, p12.w, p3.y);
        if (code != 0u) {
            float2 r = slug_solve_horiz(p12, p3);
            if ((code & 1u) != 0u) {
                xcov += clamp(r.x * pixels_per_em.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x * pixels_per_em.x) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                xcov -= clamp(r.y * pixels_per_em.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y * pixels_per_em.x) * 2.0, 0.0, 1.0));
            }
        }
    }

    float ycov = 0.0;
    float ywgt = 0.0;
    uint v_hdr = slug_fetch(slug_tex, blob + 9u + h_count + bx);
    uint v_curve_count = min(v_hdr & 0xFFFFu, 1024u);
    uint v_list_word = blob + (v_hdr >> 16u);
    for (uint vk = 0u; vk < v_curve_count; vk++) {
        uint pair = slug_fetch(slug_tex, v_list_word + (vk >> 1u));
        uint p_idx = (pair >> ((vk & 1u) * 16u)) & 0xFFFFu;
        uint pb = points_base + p_idx;
        float2 p1 = slug_dequant(slug_fetch(slug_tex, pb + 0u), min_x, min_y, scale_x, scale_y) - render_coord;
        float2 p2 = slug_dequant(slug_fetch(slug_tex, pb + 1u), min_x, min_y, scale_x, scale_y) - render_coord;
        float2 p3 = slug_dequant(slug_fetch(slug_tex, pb + 2u), min_x, min_y, scale_x, scale_y) - render_coord;
        float4 p12 = float4(p1, p2);
        if (max(max(p12.y, p12.w), p3.y) * pixels_per_em.y < -0.5) break;
        uint code = slug_root_code(p12.x, p12.z, p3.x);
        if (code != 0u) {
            float2 r = slug_solve_vert(p12, p3);
            if ((code & 1u) != 0u) {
                ycov -= clamp(r.x * pixels_per_em.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x * pixels_per_em.y) * 2.0, 0.0, 1.0));
            }
            if (code > 1u) {
                ycov += clamp(r.y * pixels_per_em.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y * pixels_per_em.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    return slug_calc_coverage(xcov, ycov, xwgt, ywgt);
}
