// Shared analytic AA, corner SDF, shadow, shape, and inverse-frame helpers for
// WebGL2 (GLSL ES 3.00). Keep coefficients synchronized (tests_shader_sync.zig).
vec2 precise_sincos(float angle) {
    float pi = 3.141592653589793;
    float x = angle - floor((angle + pi) / (2.0 * pi)) * (2.0 * pi);
    float sign_c = 1.0;
    if (x > pi * 0.5) { x = pi - x; sign_c = -1.0; }
    else if (x < -pi * 0.5) { x = -pi - x; sign_c = -1.0; }
    float q = x * x;
    float s = x * (1.0 + q * (-1.0 / 6.0 + q * (1.0 / 120.0 + q * (-1.0 / 5040.0 + q * (1.0 / 362880.0 + q * (-1.0 / 39916800.0 + q / 6227020800.0))))));
    float c = 1.0 + q * (-1.0 / 2.0 + q * (1.0 / 24.0 + q * (-1.0 / 720.0 + q * (1.0 / 40320.0 + q * (-1.0 / 3628800.0 + q / 479001600.0)))));
    return vec2(s, c * sign_c);
}
float precise_sin(float x) { return precise_sincos(x).x; }
float precise_cos(float x) { return precise_sincos(x).y; }

#ifdef STAGE_FS
vec2 rounded_box_aa(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    vec2 m = max(q, vec2(0.0));
    float len = length(m);
    float d = len + min(max(q.x, q.y), 0.0) - r;
    float grad = len > 0.0 ? (m.x + m.y) / len : 1.0;
    return vec2(d, max(grad / u_scale, 0.0001) * 0.5);
}

vec2 corner_sdf_aa(vec2 p, vec2 half_size, float r_in) {
    float r = min(abs(r_in), min(half_size.x, half_size.y));
    if (r <= 0.0 || r_in < 0.0) { return rounded_box_aa(p, half_size, r); }
    float dx = half_size.x - abs(p.x);
    float dy = half_size.y - abs(p.y);
    float a = min(dx, dy);
    float b_val = max(dx, dy);
    float half_long = (dy >= dx) ? half_size.y : half_size.x;
    float ext = min(1.52866495 * r, half_long);
    float d;
    float grad;
    if (b_val >= ext) {
        d = -a;
        grad = 1.0;
    } else if (b_val >= 0.63149399 * r && a > -0.25 * r) {
        float span = max(ext - 0.63149399 * r, 1e-5);
        float u = clamp((ext - b_val) / span, 0.0, 1.0);
        float uu = u * u;
        float uuu = uu * u;
        float c3 = 0.00759166;
        float c4 = 0.06728002;
        float c5 = 0.00003973;
        float indent = r * (c3 * uuu + c4 * uuu * u + c5 * uuu * uu);
        float slope = r * (3.0 * c3 * uu + 4.0 * c4 * uuu + 5.0 * c5 * uu * uu) / span;
        float inv_norm = 1.0 / sqrt(1.0 + slope * slope);
        d = (indent - a) * inv_norm;
        grad = (1.0 + slope) * inv_norm;
    } else {
        float cx = 0.950248 * r;
        float cr = 0.931599 * r;
        vec2 q = vec2(cx - dx, cx - dy);
        vec2 m = max(q, vec2(0.0));
        float len = length(m);
        d = len + min(max(q.x, q.y), 0.0) - cr;
        grad = len > 0.0 ? (m.x + m.y) / len : 1.0;
    }
    return vec2(d, max(grad / u_scale, 0.0001) * 0.5);
}

float shadow_dither(vec2 pos) {
    uint x = uint(pos.x);
    uint y = uint(pos.y);
    uint h1 = (x * 1664525u + y * 1013904223u) ^ 0x68bc21ebu;
    h1 ^= h1 >> 15u;
    h1 *= 0x85ebca6bu;
    h1 ^= h1 >> 13u;
    uint h2 = (x * 22695477u + y * 2891336453u) ^ 0x02e5be93u;
    h2 ^= h2 >> 15u;
    h2 *= 0xc2b2ae35u;
    h2 ^= h2 >> 13u;
    float u1 = float(h1 & 0xffffu) / 65535.0;
    float u2 = float(h2 & 0xffffu) / 65535.0;
    return (u1 + u2 - 1.0) * (0.5 / 255.0);
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265358979) * sigma);
}

vec2 erf2(vec2 val) {
    vec2 s = sign(val);
    vec2 a = abs(val);
    vec2 x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float blur_along_x(float x, float y, float sigma, float corner, vec2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    vec2 integral = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

float shadow_alpha(vec2 p, vec2 half_size, float corner, float sigma) {
    float c = abs(corner);
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step_y = (end - start) / 8.0;
    float y = start + step_y * 0.5;
    float alpha = 0.0;
    for (int k = 0; k < 8; k++) {
        alpha += blur_along_x(p.x, p.y - y, sigma, c, half_size) * gaussian(y, sigma) * step_y;
        y += step_y;
    }
    return alpha;
}

float dash_cover(vec2 p, vec2 half_size, float r, float w) {
    float PI = 3.14159265;
    float dv = 1.0 / (3.0 * w);
    float sx = (2.0 * half_size.x - 2.0 * r) * dv;
    float sy = (2.0 * half_size.y - 2.0 * r) * dv;
    float cq = r * PI * 0.5 * dv;
    vec2 q = abs(p) - (half_size - r);
    float t;
    if (r > 0.0 && q.x > 0.0 && q.y > 0.0) {
        vec2 v = p - sign(p) * (half_size - r);
        float ang = atan(v.y, v.x);
        if (p.x >= 0.0 && p.y < 0.0) { t = sx + (ang + PI * 0.5) * r * dv; }
        else if (p.x >= 0.0) { t = sx + cq + sy + ang * r * dv; }
        else if (p.y >= 0.0) { t = 2.0 * sx + 2.0 * cq + sy + (ang - PI * 0.5) * r * dv; }
        else { t = 2.0 * sx + 3.0 * cq + 2.0 * sy + (ang + PI) * r * dv; }
    } else if ((half_size.y - abs(p.y)) < (half_size.x - abs(p.x))) {
        t = p.y < 0.0 ? (p.x + half_size.x - r) * dv : sx + 2.0 * cq + sy + (half_size.x - r - p.x) * dv;
    } else {
        t = p.x > 0.0 ? sx + cq + (p.y + half_size.y - r) * dv : 2.0 * sx + 3.0 * cq + sy + (half_size.y - r - p.y) * dv;
    }
    float max_t = 2.0 * (sx + sy) + 4.0 * cq;
    if (max_t < 1.0) { return 1.0; }
    float period = max_t / floor(max_t);
    float len = 2.0 / 3.0;
    float u = t + period * 0.5 - len * 0.5;
    float centered = u - period * floor(u / period) - period * 0.5;
    float sd = (abs(centered) - len * 0.5) / dv;
    return clamp(0.5 - sd / max(1.0 / u_scale, 0.0001), 0.0, 1.0);
}

vec4 line_color(vec2 world, Instance i) {
    vec2 a = i.uv.xy;
    vec2 ab = i.uv.zw - a;
    float len2 = dot(ab, ab);
    float t = len2 > 0.0 ? clamp(dot(world - a, ab) / len2, 0.0, 1.0) : 0.0;
    vec2 off = world - (a + ab * t);
    float d = length(off);
    float grad = d > 0.0 ? (abs(off.x) + abs(off.y)) / d : 1.0;
    float aa = max(grad / u_scale, 0.0001) * 0.5;
    float hw = i.border_width * 0.5;
    float cover = 1.0 - smoothstep(hw - aa, hw + aa, d);
    float on = i.border_color.x;
    float gap = i.border_color.y;
    if (on > 0.0 && gap > 0.0) {
        float len = sqrt(len2);
        float along = i.border_color.z;
        float ug = 0.0;
        if (len > 0.0) {
            along += dot(world - a, ab) / len;
            ug = (abs(ab.x) + abs(ab.y)) / len;
        }
        float m = along - (on + gap) * floor(along / (on + gap));
        float e = min(m, on - m);
        float ea = max(ug / u_scale, 0.0001) * 0.5;
        cover *= smoothstep(-ea, ea, e);
    }
    float alpha = i.color.a * cover;
    return vec4(i.color.rgb * alpha, alpha);
}

vec4 triangle_color(vec2 world, Instance i) {
    vec2 v[3] = vec2[3](i.uv.xy, i.uv.zw, i.border_color.xy);
    float area = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x);
    float side = area < 0.0 ? -1.0 : 1.0;
    uint edges = uint(i.border_color.z);
    float cover = 1.0;
    for (int k = 0; k < 3; k++) {
        if ((edges & (1u << uint(k))) == 0u) { continue; }
        vec2 p = v[k];
        vec2 e = v[(k + 1) % 3] - p;
        float len = max(length(e), 0.0001);
        float d = side * (e.x * (world.y - p.y) - e.y * (world.x - p.x)) / len;
        float aa = max((abs(e.x) + abs(e.y)) / len / u_scale, 0.0001) * 0.5;
        cover *= smoothstep(-aa, aa, d);
    }
    float alpha = i.color.a * cover;
    return vec4(i.color.rgb * alpha, alpha);
}

bool has_transform(Instance i) {
    return any(notEqual(i.m, vec4(1.0, 0.0, 0.0, 1.0))) || any(notEqual(i.mt.xy, vec2(0.0))) || i.xf.x != 0.0 || i.xf.y != 0.0 || i.pulse.x > 0.0 || i.turn.x != 0.0 || i.vel.z == 2.0 || (i.kind == 8.0 && any(notEqual(i.border_color, vec4(0.0))));
}

LocalPoint inverse_frame(vec2 screen, Instance i) {
    vec2 landed = screen;
    if (i.turn.x != 0.0) {
        float ct = precise_cos(i.turn.x);
        float st = precise_sin(i.turn.x);
        vec2 q = screen - i.turn.zw;
        float inv = i.turn.y > 0.0 ? st / i.turn.y : 0.0;
        float dx = q.x / (ct - q.x * inv);
        float w = 1.0 + dx * inv;
        landed = i.turn.zw + vec2(dx, q.y * w);
    }
    float determinant_m = i.m.x * i.m.w - i.m.z * i.m.y;
    vec2 q0 = landed - i.mt.xy;
    vec2 p = vec2(i.m.w * q0.x - i.m.z * q0.y, -i.m.y * q0.x + i.m.x * q0.y) / determinant_m;
    vec2 d = p - i.xf.zw;
    if (i.kind == 8.0 && any(notEqual(i.border_color, vec4(0.0)))) {
        vec4 m = i.border_color;
        float det = m.x * m.w - m.y * m.z;
        if (abs(det) < 1e-9) { return LocalPoint(p, vec2(-1e9), landed); }
        d = vec2(m.w * d.x - m.y * d.y, -m.z * d.x + m.x * d.y) / det;
    }
    float angle = i.xf.x + i.xf.y * u_time;
    float ca = precise_cos(angle);
    float sa = precise_sin(angle);
    float k = 1.0;
    if (i.pulse.x > 0.0) {
        float s = 0.5 - 0.5 * precise_cos(6.28318530718 * u_time / i.pulse.x);
        k = 1.0 + i.pulse.y * (2.0 * s - 1.0);
    }
    vec2 local = vec2(i.xf.z + (ca * d.x + sa * d.y) / k, i.xf.w + (-sa * d.x + ca * d.y) / k);
    if (i.vel.z == 2.0) { local.x = 2.0 * i.vel.w - local.x; }
    return LocalPoint(p, local, landed);
}
#endif
