shader_type spatial;

// Opaque-ish + depth writing via cutout (alpha scissor). No blending.
render_mode unshaded, cull_back;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

uniform float refraction_strength = 0.03;
uniform float uv_scale = 1.0;
uniform float time_scale = 1.0;

// Controls for droplet coverage (same idea as before)
uniform float alpha_gain = 1.0;          // overall coverage multiplier for droplets
uniform float alpha_softness = 0.15;     // 0..0.5-ish, higher = softer edges
uniform float min_alpha = 0.0;           // keep at 0 (background = no droplets)

// Dither / cutout controls
uniform float dither_strength = 1.0;     // 0..1, 1 = full Bayer dither, 0 = hard scissor
uniform float alpha_scissor_bias = 0.0;  // shifts cutoff (- = more droplets, + = fewer)

vec2 viewport_size_px()
{
    return vec2(textureSize(screen_tex, 0));
}

vec2 rand(vec2 c)
{
    mat2 m = mat2(vec2(12.9898, 78.233), vec2(0.16180, 0.31415));
    return fract(sin(m * c) * vec2(43758.5453, 14142.1));
}

vec2 noise(vec2 p)
{
    vec2 co = floor(p);
    vec2 mu = fract(p);
    mu = 3.0 * mu * mu - 2.0 * mu * mu * mu;

    vec2 a = rand((co + vec2(0.0, 0.0)));
    vec2 b = rand((co + vec2(1.0, 0.0)));
    vec2 c = rand((co + vec2(0.0, 1.0)));
    vec2 d = rand((co + vec2(1.0, 1.0)));

    return mix(mix(a, b, mu.x), mix(c, d, mu.x), mu.y);
}

// 4x4 Bayer matrix threshold in [0..1).
// This is stable and cheap (no random noise shimmer).
float bayer4(vec2 fragcoord)
{
    // Using integer-ish math via floor/mod
    vec2 p = mod(floor(fragcoord), 4.0);

    float x = p.x;
    float y = p.y;

    // 4x4 Bayer thresholds (0..15) / 16
    // Row-major:
    //  0  8  2 10
    // 12  4 14  6
    //  3 11  1  9
    // 15  7 13  5
    float v = 0.0;

    if (y < 1.0)
    {
        if (x < 1.0) { v = 0.0; }
        else if (x < 2.0) { v = 8.0; }
        else if (x < 3.0) { v = 2.0; }
        else { v = 10.0; }
    }
    else if (y < 2.0)
    {
        if (x < 1.0) { v = 12.0; }
        else if (x < 2.0) { v = 4.0; }
        else if (x < 3.0) { v = 14.0; }
        else { v = 6.0; }
    }
    else if (y < 3.0)
    {
        if (x < 1.0) { v = 3.0; }
        else if (x < 2.0) { v = 11.0; }
        else if (x < 3.0) { v = 1.0; }
        else { v = 9.0; }
    }
    else
    {
        if (x < 1.0) { v = 15.0; }
        else if (x < 2.0) { v = 7.0; }
        else if (x < 3.0) { v = 13.0; }
        else { v = 5.0; }
    }

    return (v + 0.5) / 16.0;
}

void fragment()
{
    vec2 u = UV * uv_scale;
    vec2 vp = viewport_size_px();

    vec2 v = (u * vp * 0.1) / vp;
    vec2 n = noise(v * 200.0);

    vec2 screen_uv = SCREEN_UV;

    vec3 base_col = texture(screen_tex, screen_uv).rgb;
    vec3 col = base_col;

    float ttime = TIME * time_scale;

    float drop_mask = 0.0;

    for (float r = 4.0; r > 0.0; r -= 1.0)
    {
        vec2 x = vp * r * 0.015;

        vec2 p = 6.28 * u * x + (n - 0.5) * 2.0;
        vec2 s = sin(p);

        vec2 cell_uv = round(u * x - 0.25) / x;

        vec4 d = vec4(noise(cell_uv * 200.0), noise(cell_uv));

        float fade = max(0.0, 1.0 - fract(ttime * (d.b + 0.1) + d.g) * 2.0);
        float t = (s.x + s.y) * fade;

        bool has_drop = (d.r < (5.0 - r) * 0.08);

        if (has_drop)
        {
            float local_mask = smoothstep(0.5 - alpha_softness, 0.5 + alpha_softness, t);

            drop_mask = max(drop_mask, local_mask);

            if (local_mask > 0.001)
            {
                vec3 drop_n = normalize(-vec3(cos(p), mix(0.2, 2.0, t - 0.5)));
                vec2 offset = drop_n.xy * refraction_strength;

                vec3 refr_col = texture(screen_tex, screen_uv - offset).rgb;

                col = mix(col, refr_col, local_mask);
            }
        }
    }

    // Compute coverage and apply gain
    float a = clamp(drop_mask * alpha_gain, 0.0, 1.0);
    a = max(a, min_alpha);

    // Dithered alpha scissor:
    // Convert smooth alpha into a binary cutout using Bayer threshold.
    // If dither_strength == 0, behaves like a plain scissor at 0.5 (+bias).
    float threshold = bayer4(FRAGCOORD.xy);
    float hard_cut = step(threshold, a);

    // Blend between hard scissor (plain) and Bayer dithered scissor
    float plain_cut = step(0.5 + alpha_scissor_bias, a);
    float dither_cut = hard_cut;

    float cut = mix(plain_cut, dither_cut, clamp(dither_strength, 0.0, 1.0));

    // Force cutout + depth write behavior
    //ALPHA_SCISSOR = cut;

    // Output as opaque pixels where kept
    ALBEDO = col;
    ALPHA = cut;
}