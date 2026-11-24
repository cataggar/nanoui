// Liquid Glass backdrop sampling, downsampling, blur, and tint passes for D3D11.
// Concatenated after `shader.hlsl` and `corner_sdf.hlsl` in `d3d11.zig`.

// A pane of glass reads the backdrop d3d11.zig averaged and blurred for it:
// its area's corner `origin`, its size in texels `size`, the averaging
// `down`, and the frame's pixels a point `scale`.
Texture2D<float4> backdrop : register(t3);
SamplerState sampler_backdrop : register(s3);

float3 glass_texel(int2 p) {
    return backdrop.Load(int3(clamp(p, int2(0.0, 0.0), int2(size) - 1), 0)).rgb;
}

// The backdrop at pixel q of the frame, bilinear from its texels.
float3 glass_sample(float2 q) {
    float2 u = (q - origin) / down - 0.5;
    float2 f = floor(u);
    float2 w = u - f;
    int2 p = int2(f);
    float3 top = glass_texel(p) * (1.0 - w.x) + glass_texel(p + int2(1, 0)) * w.x;
    float3 bot = glass_texel(p + int2(0, 1)) * (1.0 - w.x) + glass_texel(p + int2(1, 1)) * w.x;
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

float2 glass_normal(float2 q, float2 h, float radius) {
    float r = min(radius * 1.5, min(h.x, h.y));
    float2 a = abs(q) - (h - r);
    if (a.x > 0.0 || a.y > 0.0) {
        float2 m = max(a, float2(0.0, 0.0));
        return sign(q) * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? float2(sign(q.x), 0.0) : float2(0.0, sign(q.y));
}

float3 glass_tone(float3 c, float4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0, 1.0);
}

Pixel glass_ps(Varyings v) {
    float clip_cover = clip_coverage(v);
    // The pane's edge, antialiased as a quad's.
    float2 hp = v.i_rect.zw * 0.5;
    float2 da = rounded_box_aa(v.v_local - hp, hp, min(v.i_misc.x, min(hp.x, hp.y)));
    float coverage = (1.0 - smoothstep(-da.y, da.y, da.x)) * clip_cover * v.i_uv.z;

    // The optics, in the frame's pixels.
    float s = scale;
    float2 p = v.v_world * s;
    float2 h = hp * s;
    float2 q = p - v.i_rect.xy * s - h;
    float rr = min(v.i_misc.x * s, min(h.x, h.y));
    float t = max(-rounded_box(q, h, rr), 0.0);
    float bezel = v.i_uv.x * s;
    bool sidebar = v.i_uv.x < 0.0;
    float rim_width = sidebar ? 0.0 : v.i_uv.w * s;
    float2 n = float2(0.0, 0.0);
    if (t < bezel || t < 3.0 * rim_width) n = glass_normal(q, h, rr);
    float2 at = p;
    if (t < bezel) at -= n * (v.i_uv.y * s * glass_lens(t, bezel));
    float3 back_color = glass_sample(at);
    if (sidebar && v.i_uv.w > 0.0) {
        float right = (v.i_rect.x + v.i_rect.z) * s;
        float u = clamp((p.x - v.i_rect.x * s) / (2.0 * h.x), 0.0, 1.0);
        back_color = lerp(back_color, glass_sample(float2(2.0 * right - p.x, p.y)), v.i_uv.w * u * u);
    }
    float3 c = glass_tone(back_color, v.i_border_color);
    c += (v.i_color.rgb - c) * v.i_color.a;
    if (t < 3.0 * rim_width) {
        float r = t / rim_width;
        float a = 0.35 * exp(-r * r);
        // Light from above and below: the more the edge faces it, the lighter.
        c += (abs(n.y) - c) * a;
    }
    return scalar_pixel(float4(c, 1.0) * coverage);
}

// One triangle over the whole target: a pass computes each texel.
float4 pass_vs(uint vid : SV_VertexID) : SV_Position {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}

// The frame the down and blur passes read, rebound to t0 per pass: GLSL's
// `frame` and `src` are one texture there, as here.
Texture2D<float4> source : register(t0);

// A pane's backdrop (glass.zig's Backdrop): the frame's pixels of area
// (x0, y0, x1, y1), averaged over squares of down pixels into size texels.
float4 down_ps(float4 pos : SV_Position) : SV_Target {
    int2 gid = int2(pos.xy);
    int d = int(down);
    int x0 = area.x + gid.x * d;
    int y0 = area.y + gid.y * d;
    int x1 = min(x0 + d, area.z);
    int y1 = min(y0 + d, area.w);
    float3 sum = float3(0.0, 0.0, 0.0);
    // Rows are top down here: shader.glsl reads `frame_height - 1 - y`.
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) sum += source.Load(int3(x, y, 0)).rgb;
    return float4(sum / float((x1 - x0) * (y1 - y0)), 1.0);
}

// The backdrop blurred by sigma texels out to radius each way, along `dir`.
float4 blur_ps(float4 pos : SV_Position) : SV_Target {
    int2 gid = int2(pos.xy);
    int2 sz = int2(size);
    float3 sum = float3(0.0, 0.0, 0.0);
    float wsum = 0.0;
    float sigma_at = sigma;
    if (progressive.z > 0.0) {
        float y = float(gid.y) + 0.5;
        float t = clamp(min(y - progressive.x, progressive.y - y) / progressive.z, 0.0, 1.0);
        sigma_at *= 1.0 - 0.65 * t * t * (3.0 - 2.0 * t);
    }
    for (int k = -radius; k <= radius; k++) {
        int2 p = clamp(gid + dir * k, int2(0, 0), sz - 1);
        float w = exp(-float(k * k) / (2.0 * sigma_at * sigma_at));
        sum += source.Load(int3(p, 0)).rgb * w;
        wsum += w;
    }
    return float4(sum / wsum, 1.0);
}
