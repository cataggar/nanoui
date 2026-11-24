// Liquid Glass backdrop downsample, blur, and pane shaders in GLSL 3.30 /
// GLSL ES 3.00, concatenated after shader.glsl by opengl.zig.

#if defined(GLASS_FS)
// Where the pane's backdrop lies: its area's corner in the frame's pixels,
// its size in texels, the averaging, and the frame's pixels a point.
uniform sampler2D backdrop;
uniform vec2 origin;
uniform vec2 size;
uniform float down;

vec3 glass_texel(ivec2 p) {
    return texelFetch(backdrop, clamp(p, ivec2(0), ivec2(size) - 1), 0).rgb;
}

// The backdrop at pixel q of the frame, bilinear from its texels.
vec3 glass_sample(vec2 q) {
    vec2 u = (q - origin) / down - 0.5;
    vec2 f = floor(u);
    vec2 w = u - f;
    ivec2 p = ivec2(f);
    vec3 top = glass_texel(p) * (1.0 - w.x) + glass_texel(p + ivec2(1, 0)) * w.x;
    vec3 bot = glass_texel(p + ivec2(0, 1)) * (1.0 - w.x) + glass_texel(p + ivec2(1, 1)) * w.x;
    return top * (1.0 - w.y) + bot * w.y;
}

float glass_lens(float t, float bezel) {
    if (bezel <= 0.0 || t >= bezel) return 0.0;
    float u = 1.0 - max(t, 0.0) / bezel;
    float v = 1.0 - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n, c = a / n;
    float st = s / 1.5;
    float ct = sqrt(1.0 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

vec2 glass_normal(vec2 q, vec2 h, float radius) {
    float r = min(radius * 1.5, min(h.x, h.y));
    vec2 a = abs(q) - (h - r);
    if (a.x > 0.0 || a.y > 0.0) {
        vec2 m = max(a, vec2(0.0));
        return sign(q) * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? vec2(sign(q.x), 0.0) : vec2(0.0, sign(q.y));
}

vec3 glass_tone(vec3 c, vec4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0, 1.0);
}

void main() {
    float clip_cover = clip_coverage();
    // The pane's edge, antialiased as a quad's.
    vec2 hp = i_rect.zw * 0.5;
    vec2 da = rounded_box_aa(v_local - hp, hp, min(i_misc.x, min(hp.x, hp.y)));
    float coverage = (1.0 - smoothstep(-da.y, da.y, da.x)) * clip_cover * i_uv.z;

    // The optics, in the frame's pixels.
    float s = scale;
    vec2 p = v_world * s;
    vec2 h = hp * s;
    vec2 q = p - i_rect.xy * s - h;
    float rr = min(i_misc.x * s, min(h.x, h.y));
    float t = max(-rounded_box(q, h, rr), 0.0);
    float bezel = i_uv.x * s;
    bool sidebar = i_uv.x < 0.0;
    float rim_width = sidebar ? 0.0 : i_uv.w * s;
    vec2 n = vec2(0.0);
    if (t < bezel || t < 3.0 * rim_width) n = glass_normal(q, h, rr);
    vec2 at = p;
    if (t < bezel) at -= n * (i_uv.y * s * glass_lens(t, bezel));
    vec3 back_color = glass_sample(at);
    if (sidebar && i_uv.w > 0.0) {
        float right = (i_rect.x + i_rect.z) * s;
        float u = clamp((p.x - i_rect.x * s) / (2.0 * h.x), 0.0, 1.0);
        back_color = mix(back_color, glass_sample(vec2(2.0 * right - p.x, p.y)), i_uv.w * u * u);
    }
    vec3 c = glass_tone(back_color, i_border_color);
    c += (i_color.rgb - c) * i_color.a;
    if (t < 3.0 * rim_width) {
        float r = t / rim_width;
        float a = 0.35 * exp(-r * r);
        // Light from above and below: the more the edge faces it, the lighter.
        c += (abs(n.y) - c) * a;
    }
    frag = vec4(c, 1.0) * coverage;
}
#endif

#if defined(PASS_VS)
// One triangle over the whole target: a pass computes each texel.
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
#endif

#if defined(DOWN_FS) || defined(BLUR_FS)
// A pane's backdrop (glass.zig's Backdrop): the frame's pixels of area
// (x0, y0, x1, y1), averaged over squares of down pixels into size texels,
// blurred by sigma texels out to radius each way.
uniform ivec2 size;
out vec4 frag;
#endif

#if defined(DOWN_FS)
uniform sampler2D frame;
uniform ivec4 area;
uniform int down;
uniform int frame_height;

void main() {
    ivec2 gid = ivec2(gl_FragCoord.xy);
    int x0 = area.x + gid.x * down;
    int y0 = area.y + gid.y * down;
    int x1 = min(x0 + down, area.z);
    int y1 = min(y0 + down, area.w);
    vec3 sum = vec3(0.0);
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) sum += texelFetch(frame, ivec2(x, frame_height - 1 - y), 0).rgb;
    frag = vec4(sum / float((x1 - x0) * (y1 - y0)), 1.0);
}
#endif

#if defined(BLUR_FS)
uniform sampler2D src;
uniform int radius;
uniform float sigma;
uniform vec4 progressive;
uniform ivec2 dir;

void main() {
    ivec2 gid = ivec2(gl_FragCoord.xy);
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    float sigma_at = sigma;
    if (progressive.z > 0.0) {
        float y = float(gid.y) + 0.5;
        float t = clamp(min(y - progressive.x, progressive.y - y) / progressive.z, 0.0, 1.0);
        sigma_at *= 1.0 - 0.65 * t * t * (3.0 - 2.0 * t);
    }
    for (int k = -radius; k <= radius; k++) {
        ivec2 p = clamp(gid + dir * k, ivec2(0), size - 1);
        float w = exp(-float(k * k) / (2.0 * sigma_at * sigma_at));
        sum += texelFetch(src, p, 0).rgb * w;
        wsum += w;
    }
    frag = vec4(sum / wsum, 1.0);
}
#endif
