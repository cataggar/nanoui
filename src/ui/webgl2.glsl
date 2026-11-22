// WebGL2 (GLSL ES 3.00) UI shader; concatenated with webgl2_shapes.glsl and
// webgl2_glass.glsl. JS prepends #version 300 es, STAGE_VS/STAGE_FS, and ENTRY_*.
layout(std140) uniform ParamsBlock {
    vec2 u_viewport;
    float u_scale;
    float u_time;
    vec2 u_origin;
    vec2 u_size;
    ivec4 u_area;
    float u_down;
    float u_sigma;
    int u_radius;
    int u_frame_height;
    ivec2 u_dir;
    ivec2 u_pad;
    vec4 u_progressive;
};
uniform uint u_first_instance;
uniform highp sampler2D u_frame_tex;
uniform highp sampler2D u_instances;
uniform highp sampler2D u_gradients;
uniform highp sampler2D u_atlas;
uniform highp sampler2D u_images;

vec4 fetch_vec4(highp sampler2D tex, uint index) {
    return texelFetch(tex, ivec2(int(index & 1023u), int(index >> 10u)), 0);
}

struct Instance {
    vec4 rect;
    vec4 color;
    vec4 border_color;
    vec4 uv;
    vec4 clip;
    float radius;
    float border_width;
    float kind;
    float clip_round;
    vec4 xf;
    vec4 pulse;
    vec4 vel;
    vec4 turn;
    vec4 m;
    vec4 mt;
};

Instance load_instance(uint idx) {
    uint base = idx * 12u;
    vec4 meta = fetch_vec4(u_instances, base + 5u);
    Instance i;
    i.rect = fetch_vec4(u_instances, base + 0u);
    i.color = fetch_vec4(u_instances, base + 1u);
    i.border_color = fetch_vec4(u_instances, base + 2u);
    i.uv = fetch_vec4(u_instances, base + 3u);
    i.clip = fetch_vec4(u_instances, base + 4u);
    i.radius = meta.x;
    i.border_width = meta.y;
    i.kind = meta.z;
    i.clip_round = meta.w;
    i.xf = fetch_vec4(u_instances, base + 6u);
    i.pulse = fetch_vec4(u_instances, base + 7u);
    i.vel = fetch_vec4(u_instances, base + 8u);
    i.turn = fetch_vec4(u_instances, base + 9u);
    i.m = fetch_vec4(u_instances, base + 10u);
    i.mt = fetch_vec4(u_instances, base + 11u);
    return i;
}

float precise_sin(float x);
float precise_cos(float x);

#ifdef ENTRY_QUAD_VS
out vec2 v_local;
out vec2 v_world;
out vec2 v_uv;
out vec2 v_velocity;
out float v_pulse_alpha;
flat out uint v_idx;
out vec2 v_screen;

void main() {
    uint vertex = uint(gl_VertexID);
    uint idx = u_first_instance + uint(gl_InstanceID);
    Instance i = load_instance(idx);
    vec2 corner = vec2(float(vertex & 1u), float(vertex >> 1u));
    float grow = (i.kind == 2.0 || i.kind == 5.0) ? i.border_width * 3.0 : 0.0;
    vec2 velocity = i.vel.xy;
    float vlen = length(velocity);
    if (vlen > 24.0) { velocity *= 24.0 / vlen; vlen = 24.0; }
    bool has_blur = vlen > 0.5 && (i.kind == 0.0 || i.kind == 1.0 || i.kind == 3.0);
    vec2 grow2 = vec2(grow);
    if (has_blur) { grow2 += abs(velocity) * 0.5; }
    if (any(notEqual(i.m, vec4(1.0, 0.0, 0.0, 1.0))) || any(notEqual(i.mt.xy, vec2(0.0))) || i.xf.x != 0.0 || i.xf.y != 0.0 || i.pulse.x > 0.0 || i.turn.x != 0.0 || (i.kind == 8.0 && any(notEqual(i.border_color, vec4(0.0))))) {
        grow2 += vec2(1.0 / u_scale);
    }
    vec2 unrot = i.rect.xy - grow2 + corner * (i.rect.zw + 2.0 * grow2);
    vec2 p = unrot;
    float alpha = 1.0;
    float angle = i.xf.x + i.xf.y * u_time;
    if (i.vel.z == 2.0) { p.x = 2.0 * i.vel.w - p.x; }
    if (i.kind == 6.0) {
        vec2 a = i.uv.xy;
        vec2 b = i.uv.zw;
        float len = length(b - a);
        vec2 u = len > 0.0 ? (b - a) / len : vec2(1.0, 0.0);
        vec2 n = vec2(-u.y, u.x);
        float e = i.border_width * 0.5 + 1.0;
        p = mix(a - u * e, b + u * e, corner.x) + n * (corner.y * 2.0 - 1.0) * e;
    } else if (i.kind == 7.0) {
        p = i.border_color.xy;
        if (vertex == 0u) { p = i.uv.xy; }
        if (vertex == 1u) { p = i.uv.zw; }
    } else if (angle != 0.0 || i.pulse.x > 0.0 || (i.kind == 8.0 && any(notEqual(i.border_color, vec4(0.0))))) {
        vec2 d = p - i.xf.zw;
        if (i.pulse.x > 0.0) {
            float s = 0.5 - 0.5 * precise_cos(6.28318530718 * u_time / i.pulse.x);
            d *= 1.0 + i.pulse.y * (2.0 * s - 1.0);
            alpha = mix(i.pulse.z, 1.0, s);
        }
        if (angle != 0.0) {
            float ca = precise_cos(angle);
            float sa = precise_sin(angle);
            d = vec2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
        }
        if (i.kind == 8.0 && any(notEqual(i.border_color, vec4(0.0)))) {
            vec4 m = i.border_color;
            d = vec2(m.x * d.x + m.y * d.y, m.z * d.x + m.w * d.y);
        }
        p = i.xf.zw + d;
    }
    vec2 landed = vec2(i.m.x * p.x + i.m.z * p.y + i.mt.x, i.m.y * p.x + i.m.w * p.y + i.mt.y);
    vec2 seen = landed;
    float w = 1.0;
    float ct = precise_cos(i.turn.x);
    bool hidden = (i.vel.z == 1.0 && ct < 0.0) || (i.vel.z == 2.0 && ct >= 0.0);
    if (i.turn.x != 0.0) {
        float dx = landed.x - i.turn.z;
        float z = -dx * precise_sin(i.turn.x);
        seen = vec2(i.turn.z + dx * ct, landed.y);
        if (i.turn.y > 0.0) {
            w = max(1.0 - z / i.turn.y, 0.1);
            seen = i.turn.zw + (seen - i.turn.zw) / w;
        }
    }
    gl_Position = vec4((seen / u_viewport * vec2(2.0, 2.0) + vec2(-1.0, -1.0)) * w, 0.0, w);
    if (hidden) { gl_Position = vec4(0.0, 0.0, 0.0, 1.0); }
    v_local = unrot - i.rect.xy;
    v_world = p;
    v_screen = landed;
    v_uv = mix(i.uv.xy, i.uv.zw, corner);
    v_velocity = vec2(0.0);
    if (has_blur) {
        v_uv = i.uv.xy + (unrot - i.rect.xy) / max(i.rect.zw, vec2(1e-4)) * (i.uv.zw - i.uv.xy);
        v_velocity = velocity;
    }
    v_pulse_alpha = alpha;
    v_idx = idx;
}
#endif

#ifdef STAGE_FS
layout(location = 0) out vec4 frag_color;

struct LocalPoint {
    vec2 world;
    vec2 local;
    vec2 screen;
};

vec2 rounded_box_aa(vec2 p, vec2 half_size, float r);
vec2 corner_sdf_aa(vec2 p, vec2 half_size, float r_in);
float shadow_dither(vec2 pos);
float shadow_alpha(vec2 p, vec2 half_size, float corner, float sigma);
float dash_cover(vec2 p, vec2 half_size, float r, float w);
vec4 line_color(vec2 world, Instance i);
vec4 triangle_color(vec2 world, Instance i);
bool has_transform(Instance i);
LocalPoint inverse_frame(vec2 screen, Instance i);

#if defined(ENTRY_QUAD_FS) || defined(ENTRY_GLASS_FS) || defined(ENTRY_EXTERNAL_FS)
in vec2 v_local;
in vec2 v_world;
in vec2 v_uv;
in vec2 v_velocity;
in float v_pulse_alpha;
flat in uint v_idx;
in vec2 v_screen;

struct Varyings {
    vec4 position;
    vec2 local;
    vec2 world;
    vec2 uv;
    vec2 velocity;
    float pulse_alpha;
    uint idx;
    vec2 screen;
};

Varyings load_varyings() {
    Varyings v;
    v.position = gl_FragCoord;
    v.local = v_local;
    v.world = v_world;
    v.uv = v_uv;
    v.velocity = v_velocity;
    v.pulse_alpha = v_pulse_alpha;
    v.idx = v_idx;
    v.screen = v_screen;
    return v;
}

float clip_coverage(Varyings v, Instance i) {
    if (any(lessThan(v.screen, i.clip.xy)) || any(greaterThan(v.screen, i.clip.zw))) { discard; }
    float cover = 1.0;
    if (i.clip_round != 0.0) {
        float corners = floor(abs(i.clip_round) / 4096.0);
        float rad = (i.clip_round < 0.0 ? -1.0 : 1.0) * (abs(i.clip_round) - corners * 4096.0);
        vec2 half_size = (i.clip.zw - i.clip.xy) * 0.5;
        vec2 q = v.screen - i.clip.xy - half_size;
        vec2 cd = corner_sdf_aa(q, half_size, sign(rad) * min(abs(rad), min(half_size.x, half_size.y)));
        uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
        if ((uint(corners) & bit) != 0u) { cover = 1.0 - smoothstep(-cd.y, cd.y, cd.x); }
        if (cover <= 0.0) { discard; }
    }
    return cover;
}
#endif

#ifdef ENTRY_QUAD_FS
vec4 gradient_stops(vec4 uv, float y) {
    uint at = uint(uv.z);
    vec4 h = fetch_vec4(u_gradients, at);
    uint n = uint(h.z);
    if (n == 0u) { return vec4(0.0); }
    float t = (y - h.x) / max(h.y, 1e-4);
    if (t <= fetch_vec4(u_gradients, at + 1u).x) { return fetch_vec4(u_gradients, at + 2u); }
    for (uint k = 1u; k < n; k++) {
        float p0 = fetch_vec4(u_gradients, at + 1u + 2u * (k - 1u)).x;
        float p1 = fetch_vec4(u_gradients, at + 1u + 2u * k).x;
        if (t <= p1) {
            return mix(fetch_vec4(u_gradients, at + 2u + 2u * (k - 1u)), fetch_vec4(u_gradients, at + 2u + 2u * k), (t - p0) / max(p1 - p0, 1e-6));
        }
    }
    return fetch_vec4(u_gradients, at + 2u * n);
}

vec4 shade(Varyings v, Instance i) {
    if (i.kind == 10.0 || i.kind == 11.0) {
        float fade = 1.0;
        if (i.border_color.z > 0.0) { fade = min(fade, clamp((v.world.y - i.border_color.x) / i.border_color.z, 0.0, 1.0)); }
        if (i.border_color.w > 0.0) { fade = min(fade, clamp((i.border_color.y - v.world.y) / i.border_color.w, 0.0, 1.0)); }
        return texelFetch(u_frame_tex, ivec2(v.position.xy), 0) * (i.color.a * fade);
    }
    if (i.kind == 6.0) { return line_color(v.world, i); }
    if (i.kind == 7.0) { return triangle_color(v.world, i); }
    if (i.kind == 1.0) {
        float a = 0.0;
        if (length(v.velocity) > 0.5) {
            vec2 duv = v.velocity / max(i.rect.zw, vec2(1e-4)) * (i.uv.zw - i.uv.xy);
            for (int k = 0; k < 5; k++) {
                vec2 uvk = v.uv - duv * (float(k) * 0.25 - 0.5);
                if (all(greaterThanEqual(uvk, i.uv.xy)) && all(lessThanEqual(uvk, i.uv.zw))) {
                    a += textureLod(u_atlas, uvk, 0.0).r;
                }
            }
            a *= 0.2 * i.color.a;
        } else {
            a = textureLod(u_atlas, v.uv, 0.0).r * i.color.a;
        }
        if (i.border_width > 0.0) { a *= clamp((i.radius - v.world.x) / i.border_width, 0.0, 1.0); }
        return vec4(i.color.rgb * a, a);
    }
    vec2 half_size = i.rect.zw * 0.5;
    vec2 p = v.local - half_size;
    float r_abs = min(abs(i.radius), min(half_size.x, half_size.y));
    float r = i.radius < 0.0 ? -r_abs : r_abs;
    vec2 da = corner_sdf_aa(p, half_size, r);
    float d = da.x;
    float aa = da.y / max(sqrt(abs(i.m.x * i.m.w - i.m.y * i.m.z)), 0.001);
    float coverage = 0.0;
    if (length(v.velocity) > 0.5) {
        for (int k = 0; k < 5; k++) {
            float dk = corner_sdf_aa(p - v.velocity * (float(k) * 0.25 - 0.5), half_size, r).x;
            coverage += 1.0 - smoothstep(-aa, aa, dk);
        }
        coverage *= 0.2;
    } else {
        coverage = 1.0 - smoothstep(-aa, aa, d);
    }
    if (i.kind == 8.0) { return textureLod(u_frame_tex, v.uv, 0.0) * (coverage * i.color.a); }
    if (i.kind == 3.0) {
        vec4 px = textureLod(u_images, v.uv, 0.0);
        if (i.border_color.a > 0.0) {
            float a = px.a * i.border_color.a * coverage * i.color.a;
            return vec4(i.border_color.rgb * a, a);
        }
        return px * (coverage * i.color.a);
    }
    if (i.kind == 2.0 || i.kind == 5.0) {
        float sigma = max(i.border_width, 0.25);
        float a = shadow_alpha(p, half_size, r, sigma) * i.color.a;
        if (i.kind == 5.0) {
            float rb = r < 0.0 ? -max(-r - i.uv.z, 0.0) : max(r - i.uv.z, 0.0);
            a *= clamp(corner_sdf_aa(p - i.uv.xy, max(half_size - i.uv.z, vec2(0.0)), rb).x + 0.5, 0.0, 1.0);
        }
        if (a > 0.0) { a = clamp(a + shadow_dither(v.world * u_scale), 0.0, 1.0); }
        return vec4(i.color.rgb * a, a);
    }
    vec4 fill = i.color;
    if (i.uv.y > 1.5) {
        fill = gradient_stops(i.uv, v.local.y);
    } else if (i.uv.y > 0.5 && i.uv.y < 1.5) {
        float gr = floor(i.uv.z / 256.0);
        float gb = floor(i.uv.w / 256.0);
        vec4 bottom = vec4(gr, i.uv.z - gr * 256.0, gb, i.uv.w - gb * 256.0) / 255.0;
        fill = mix(fill, bottom, clamp(v.local.y / max(i.rect.w, 1e-4), 0.0, 1.0));
    }
    vec4 c = vec4(fill.rgb * fill.a, fill.a);
    float bw = i.border_width;
    if (bw > 0.0 && i.border_color.a > 0.0) {
        float inner = smoothstep(-bw - aa, -bw + aa, d);
        vec4 b = vec4(i.border_color.rgb * i.border_color.a, i.border_color.a);
        if (i.uv.x > 0.5) { b *= dash_cover(p, half_size, r_abs, bw); }
        c = mix(c, b + c * (1.0 - b.a), inner);
    }
    return c * coverage;
}

void main() {
    Varyings v = load_varyings();
    Instance i = load_instance(v.idx);
    if (i.kind != 6.0 && i.kind != 7.0 && has_transform(i)) {
        LocalPoint point = inverse_frame(v.position.xy / u_scale, i);
        v.screen = point.screen;
        v.world = point.world;
        v.local = point.local - i.rect.xy;
        float edge_slack = (any(notEqual(i.m, vec4(1.0, 0.0, 0.0, 1.0))) || any(notEqual(i.mt.xy, vec2(0.0)))) ? 0.0001 : 0.0;
        if (length(i.vel.xy) <= 0.5 && (i.kind == 0.0 || i.kind == 1.0 || i.kind == 3.0 || i.kind == 8.0 || i.kind == 12.0)) {
            if (any(lessThan(point.local, i.rect.xy - vec2(edge_slack))) || any(greaterThan(point.local, i.rect.xy + i.rect.zw + vec2(edge_slack)))) { discard; }
        }
        if (i.kind == 1.0 || i.kind == 3.0 || i.kind == 8.0) {
            v.uv = i.uv.xy + v.local / i.rect.zw * (i.uv.zw - i.uv.xy);
        }
    }
    float clip = clip_coverage(v, i);
    frag_color = shade(v, i) * (clip * v.pulse_alpha);
}
#endif

#ifdef ENTRY_EXTERNAL_FS
void main() {
    Varyings v = load_varyings();
    Instance i = load_instance(v.idx);
    vec2 v_uv_work = v.uv;
    if (has_transform(i)) {
        LocalPoint point = inverse_frame(v.position.xy / u_scale, i);
        v.screen = point.screen;
        v.world = point.world;
        v.local = point.local - i.rect.xy;
        if (any(lessThan(point.local, i.rect.xy)) || any(greaterThan(point.local, i.rect.xy + i.rect.zw))) { discard; }
        v_uv_work = i.uv.xy + v.local / i.rect.zw * (i.uv.zw - i.uv.xy);
    }
    float clip = clip_coverage(v, i);
    vec2 h = i.rect.zw * 0.5;
    float r = min(abs(i.radius), min(h.x, h.y));
    vec2 da = corner_sdf_aa(v.local - h, h, i.radius < 0.0 ? -r : r);
    float aa = da.y / max(sqrt(abs(i.m.x * i.m.w - i.m.y * i.m.z)), 0.001);
    float coverage = 1.0 - smoothstep(-aa, aa, da.x);
    vec4 pixel = clamp(textureLod(u_frame_tex, v_uv_work, 0.0), vec4(0.0), vec4(1.0));
    frag_color = pixel * (coverage * clip * i.color.a * v.pulse_alpha);
}
#endif
#endif
