shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float refraction_strength = 0.03;
uniform float uv_scale = 1.0;
uniform float time_scale = 1.0;

// Controls for droplet alpha
uniform float alpha_gain = 1.0;          // overall opacity multiplier for droplets
uniform float alpha_softness = 0.15;     // 0..0.5-ish, higher = softer edges
uniform float min_alpha = 0.0;           // keep at 0 for fully invisible background

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

        // This is your original "t"
        float t = (s.x + s.y) * fade;

        // Decide if a drop exists in this cell (same logic as before)
        bool has_drop = (d.r < (5.0 - r) * 0.08);

        if (has_drop)
        {
            // Turn your old hard cutoff (t > 0.5) into a soft mask.
            // When t == 0.5 => center threshold, softness defines edge width.
            float local_mask = smoothstep(0.5 - alpha_softness, 0.5 + alpha_softness, t);

            // Accumulate coverage. Max is simplest and looks good for “either a drop is here or not”.
            drop_mask = max(drop_mask, local_mask);

            // Only refract where this drop is active (prevents random refraction outside droplets)
            if (local_mask > 0.001)
            {
                vec3 drop_n = normalize(-vec3(cos(p), mix(0.2, 2.0, t - 0.5)));
                vec2 offset = drop_n.xy * refraction_strength;

                vec3 refr_col = texture(screen_tex, screen_uv - offset).rgb;

                // Blend refraction by mask (so edges are softer)
                col = mix(col, refr_col, local_mask);
            }
        }
    }

    // Output
    ALBEDO = col;

    // Droplets-only alpha
    float a = clamp(drop_mask * alpha_gain, 0.0, 1.0);
    a = max(a, min_alpha);

    ALPHA = a;
}