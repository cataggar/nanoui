// Liquid Glass passes in GLSL ES 3.00 for WebGL2, matching glass.wgsl.
#ifdef ENTRY_PASS_VS
void main() {
    uint vertex = uint(gl_VertexID);
    vec2 p = vec2(float((vertex << 1u) & 2u), float(vertex & 2u));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
#endif

#ifdef ENTRY_DOWN_FS
void main() {
    int down_i = int(u_down);
    ivec2 start = u_area.xy + ivec2(gl_FragCoord.xy) * down_i;
    ivec2 end = min(start + ivec2(down_i), u_area.zw);
    vec3 sum = vec3(0.0);
    for (int y = start.y; y < end.y; y++) {
        for (int x = start.x; x < end.x; x++) {
            sum += texelFetch(u_frame_tex, ivec2(x, y), 0).rgb;
        }
    }
    frag_color = vec4(sum / float((end.x - start.x) * (end.y - start.y)), 1.0);
}
#endif

#ifdef ENTRY_BLUR_FS
void main() {
    vec3 sum = vec3(0.0);
    float weight = 0.0;
    float sigma = u_sigma;
    if (u_progressive.z > 0.0) {
        float t = clamp(min(gl_FragCoord.y - u_progressive.x, u_progressive.y - gl_FragCoord.y) / u_progressive.z, 0.0, 1.0);
        sigma *= 1.0 - 0.65 * t * t * (3.0 - 2.0 * t);
    }
    ivec2 limit = ivec2(u_size) - ivec2(1);
    for (int k = -u_radius; k <= u_radius; k++) {
        ivec2 p = clamp(ivec2(gl_FragCoord.xy) + u_dir * k, ivec2(0), limit);
        float w = exp(-float(k * k) / (2.0 * sigma * sigma));
        sum += texelFetch(u_frame_tex, p, 0).rgb * w;
        weight += w;
    }
    frag_color = vec4(sum / weight, 1.0);
}
#endif

#ifdef ENTRY_GLASS_FS
vec3 glass_texel(ivec2 p) {
    return texelFetch(u_frame_tex, clamp(p, ivec2(0), ivec2(u_size) - ivec2(1)), 0).rgb;
}

vec3 glass_sample(vec2 q) {
    vec2 u = (q - u_origin) / u_down - 0.5;
    vec2 f = floor(u);
    vec2 w = u - f;
    ivec2 p = ivec2(f);
    return mix(mix(glass_texel(p), glass_texel(p + ivec2(1, 0)), w.x),
               mix(glass_texel(p + ivec2(0, 1)), glass_texel(p + ivec2(1, 1)), w.x), w.y);
}

float glass_lens(float t, float bezel) {
    if (bezel <= 0.0 || t >= bezel) { return 0.0; }
    float u = 1.0 - max(t, 0.0) / bezel;
    float v = 1.0 - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n;
    float c = a / n;
    float st = s / 1.5;
    float ct = sqrt(1.0 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

vec2 glass_normal(vec2 q, vec2 h, float radius) {
    float r = min(radius * 1.5, min(h.x, h.y));
    vec2 a = abs(q) - (h - r);
    if (a.x > 0.0 || a.y > 0.0) {
        vec2 m = max(a, vec2(0.0));
        return sign(q) * m / length(m);
    }
    if (a.x > a.y) { return vec2(sign(q.x), 0.0); }
    return vec2(0.0, sign(q.y));
}

vec3 glass_tone(vec3 c, vec4 tone) {
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    return clamp(t + (c - l) * ((tone.y - tone.x) * tone.w), vec3(0.0), vec3(1.0));
}

void main() {
    Varyings v = load_varyings();
    Instance i = load_instance(v.idx);
    float clip = clip_coverage(v, i);
    vec2 hp = i.rect.zw * 0.5;
    vec2 da = rounded_box_aa(v.local - hp, hp, min(i.radius, min(hp.x, hp.y)));
    float coverage = (1.0 - smoothstep(-da.y, da.y, da.x)) * clip * i.uv.z;
    float s = u_scale;
    vec2 p = v.world * s;
    vec2 h = hp * s;
    vec2 q = p - i.rect.xy * s - h;
    float rr = min(i.radius * s, min(h.x, h.y));
    float t = max(-rounded_box_aa(q, h, rr).x, 0.0);
    float bezel = i.uv.x * s;
    bool sidebar = i.uv.x < 0.0;
    float rim = sidebar ? 0.0 : i.uv.w * s;
    vec2 n = vec2(0.0);
    if (t < bezel || t < 3.0 * rim) { n = glass_normal(q, h, rr); }
    vec2 at = p;
    if (t < bezel) { at -= n * (i.uv.y * s * glass_lens(t, bezel)); }
    vec3 back = glass_sample(at);
    if (sidebar && i.uv.w > 0.0) {
        float right = (i.rect.x + i.rect.z) * s;
        float u = clamp((p.x - i.rect.x * s) / (2.0 * h.x), 0.0, 1.0);
        back = mix(back, glass_sample(vec2(2.0 * right - p.x, p.y)), i.uv.w * u * u);
    }
    vec3 c = glass_tone(back, i.border_color);
    c += (i.color.rgb - c) * i.color.a;
    if (t < 3.0 * rim) {
        float r = t / rim;
        float a = 0.35 * exp(-r * r);
        c += (abs(n.y) - c) * a;
    }
    frag_color = vec4(c, 1.0) * coverage;
}
#endif
