// texture_post.wgsl in GLSL ES 3.00 for WebGL2. color.zig is the CPU reference.
// JS prepends #version 300 es, STAGE_VS/STAGE_FS, and ENTRY_*.
layout(std140) uniform PostBlock {
    vec4 u_domain_min;
    vec4 u_domain_max;
    vec4 u_source_domain_min;
    vec4 u_source_domain_max;
    float u_lut_size;
    uint u_lut_enabled;
    float u_source_lut_size;
    uint u_source_lut_enabled;
    uint u_source_mode;
    uint u_range_mode;
    uint u_matrix_mode;
    uint u_transfer_mode;
    uint u_hdr_tone_map;
    uint u_post_pad0;
    uint u_post_pad1;
    uint u_post_pad2;
};
uniform highp sampler2D u_external_source;
uniform highp sampler2D u_source0;
uniform highp sampler2D u_source1;
uniform highp sampler3D u_lut;
uniform highp sampler3D u_source_lut;

#ifdef ENTRY_PASS_VS
void main() {
    uint vertex = uint(gl_VertexID);
    vec2 p = vec2(float((vertex << 1u) & 2u), float(vertex & 2u));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
#endif

#ifdef STAGE_FS
layout(location = 0) out vec4 frag_color;

vec3 cube_lut(vec3 rgb) {
    vec3 n = clamp((rgb - u_domain_min.rgb) / max(u_domain_max.rgb - u_domain_min.rgb, vec3(1e-6)), vec3(0.0), vec3(1.0));
    return textureLod(u_lut, n * ((u_lut_size - 1.0) / u_lut_size) + 0.5 / u_lut_size, 0.0).rgb;
}

vec3 cube_source(vec3 rgb) {
    vec3 n = clamp((rgb - u_source_domain_min.rgb) / max(u_source_domain_max.rgb - u_source_domain_min.rgb, vec3(1e-6)), vec3(0.0), vec3(1.0));
    return textureLod(u_source_lut, n * ((u_source_lut_size - 1.0) / u_source_lut_size) + 0.5 / u_source_lut_size, 0.0).rgb;
}

vec3 rec709_linear(vec3 v) {
    return mix(pow(abs((v + 0.099) / 1.099), vec3(1.0 / 0.45)), v / 4.5, lessThan(v, vec3(0.081)));
}

vec3 srgb_linear(vec3 v) {
    return mix(pow(abs((v + 0.055) / 1.055), vec3(2.4)), v / 12.92, lessThanEqual(v, vec3(0.04045)));
}

vec3 linear_srgb(vec3 val) {
    vec3 v = max(val, vec3(0.0));
    return mix(1.055 * pow(max(v, vec3(0.0031308)), vec3(1.0 / 2.4)) - 0.055, 12.92 * v, lessThanEqual(v, vec3(0.0031308)));
}

vec3 pq_linear(vec3 v) {
    float m1 = 2610.0 / 16384.0;
    float m2 = 2523.0 / 32.0;
    float c1 = 3424.0 / 4096.0;
    float c2 = 2413.0 / 128.0;
    float c3 = 2392.0 / 128.0;
    vec3 p = pow(max(v, vec3(0.0)), vec3(1.0 / m2));
    return pow(max((p - c1) / (c2 - c3 * p), vec3(0.0)), vec3(1.0 / m1));
}

vec3 hlg_linear(vec3 v) {
    return mix((exp((v - 0.55991073) / 0.17883277) + 0.28466892) / 12.0, v * v / 3.0, lessThanEqual(v, vec3(0.5)));
}

vec3 hdr_sdr(vec3 lin) {
    float peak = (u_transfer_mode == 3u) ? 10000.0 : 1000.0;
    vec3 nits = lin * peak;
    if (u_hdr_tone_map == 0u) { return clamp(nits / 100.0, vec3(0.0), vec3(1.0)); }
    float l = max(dot(nits, vec3(0.2627, 0.6780, 0.0593)), 0.0);
    if (l <= 0.000001) { return vec3(0.0); }
    return clamp(nits * ((l / (l + 100.0)) / l), vec3(0.0), vec3(1.0));
}

vec3 ycbcr_rgb(float y, vec2 cbcr) {
    bool ten = u_source_mode == 2u;
    float code_max = ten ? 1023.0 : 255.0;
    float y_min = ten ? 64.0 : 16.0;
    float y_range = ten ? 876.0 : 219.0;
    float c_mid = ten ? 512.0 : 128.0;
    float c_range = ten ? 896.0 : 224.0;
    float Y = y;
    vec2 C = cbcr - 0.5;
    if (u_range_mode == 0u) {
        Y = (y - y_min / code_max) * (code_max / y_range);
        C = (cbcr - c_mid / code_max) * (code_max / c_range);
    }
    vec3 rgb = vec3(Y + 1.5748 * C.y, Y - 0.187324 * C.x - 0.468124 * C.y, Y + 1.8556 * C.x);
    if (u_matrix_mode == 1u) { rgb = vec3(Y + 1.402 * C.y, Y - 0.344136 * C.x - 0.714136 * C.y, Y + 1.772 * C.x); }
    if (u_matrix_mode == 2u) { rgb = vec3(Y + 1.4746 * C.y, Y - 0.164553 * C.x - 0.571353 * C.y, Y + 1.8814 * C.x); }
    return clamp(rgb, vec3(0.0), vec3(1.0));
}

vec4 grade(vec4 val) {
    vec4 color = val;
    if (u_source_mode == 3u) {
        vec3 lin = max(color.rgb, vec3(0.0));
        if (u_hdr_tone_map == 1u) { lin = lin / (1.0 + lin); }
        color = vec4(linear_srgb(clamp(lin, vec3(0.0), vec3(1.0))), 1.0);
    }
    if (u_source_mode == 4u) {
        color = vec4(linear_srgb(clamp(color.rgb, vec3(0.0), vec3(1.0))), color.a);
    }
    if (u_source_lut_enabled == 1u) { color = vec4(cube_source(color.rgb), color.a); }
    if (u_lut_enabled == 1u) { color = vec4(cube_lut(color.rgb), color.a); }
    return color;
}

#ifdef ENTRY_POST_FS
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(textureSize(u_source0, 0));
    vec4 color = textureLod(u_source0, uv, 0.0);
    if (u_source_mode == 1u || u_source_mode == 2u) {
        float ten = (u_source_mode == 2u) ? (65535.0 / 65472.0) : 1.0;
        vec3 encoded = ycbcr_rgb(color.r * ten, textureLod(u_source1, uv, 0.0).rg * ten);
        vec3 lin = rec709_linear(encoded);
        if (u_transfer_mode == 1u) { lin = srgb_linear(encoded); }
        else if (u_transfer_mode == 2u) { lin = encoded; }
        else if (u_transfer_mode == 3u) { lin = pq_linear(encoded); }
        else if (u_transfer_mode == 4u) { lin = hlg_linear(encoded); }
        if (u_transfer_mode == 3u || u_transfer_mode == 4u) { lin = hdr_sdr(lin); }
        color = vec4(linear_srgb(lin), 1.0);
    }
    frag_color = grade(color);
}
#endif

#ifdef ENTRY_POST_EXTERNAL_FS
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(textureSize(u_external_source, 0));
    frag_color = grade(clamp(textureLod(u_external_source, uv, 0.0), vec4(0.0), vec4(1.0)));
}
#endif
#endif
