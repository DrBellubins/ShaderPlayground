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

// Out-of-focus blur controls (applies only inside droplets)
uniform float blur_radius_px = 2.0;      // 0 = sharp, try 1..6
uniform float blur_strength = 1.0;       // 0..1, how much the blur replaces sharp refraction

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

vec3 sample_screen_blur_9tap(vec2 uv, float radius_px)
{
    vec2 vp = viewport_size_px();
    vec2 texel = vec2(1.0) / vp;

    vec2 o = texel * radius_px;

    // 9-tap (center + cross + diagonals), Gaussian-ish weights
    vec3 c0 = texture(screen_tex, uv).rgb;

    vec3 c1 = texture(screen_tex, uv + vec2( o.x, 0.0)).rgb;
    vec3 c2 = texture(screen_tex, uv + vec2(-o.x, 0.0)).rgb;
    vec3 c3 = texture(screen_tex, uv + vec2(0.0,  o.y)).rgb;
    vec3 c4 = texture(screen_tex, uv + vec2(0.0, -o.y)).rgb;

    vec3 c5 = texture(screen_tex, uv + vec2( o.x,  o.y)).rgb;
    vec3 c6 = texture(screen_tex, uv + vec2(-o.x,  o.y)).rgb;
    vec3 c7 = texture(screen_tex, uv + vec2( o.x, -o.y)).rgb;
    vec3 c8 = texture(screen_tex, uv + vec2(-o.x, -o.y)).rgb;

    // Weights sum to 1.0
    // center: 0.25
    // cross:  0.125 * 4 = 0.5
    // diag:   0.0625 * 4 = 0.25
    vec3 sum = vec3(0.0);
    sum += c0 * 0.25;

    sum += (c1 + c2 + c3 + c4) * 0.125;
    sum += (c5 + c6 + c7 + c8) * 0.0625;

    return sum;
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

                vec2 refr_uv = screen_uv - offset;

                // Sharp refraction
                vec3 refr_sharp = texture(screen_tex, refr_uv).rgb;

                // Blurred refraction (only if radius > 0)
                float rpx = max(0.0, blur_radius_px);
                vec3 refr_blur = sample_screen_blur_9tap(refr_uv, rpx);

                vec3 refr_col = mix(refr_sharp, refr_blur, clamp(blur_strength, 0.0, 1.0));

                col = mix(col, refr_col, local_mask);
            }
        }
    }

    ALBEDO = col;

    float a = clamp(drop_mask * alpha_gain, 0.0, 1.0);
    a = max(a, min_alpha);

    ALPHA = a;
}