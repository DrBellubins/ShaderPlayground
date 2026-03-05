shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float refraction_strength = 0.03;
uniform float uv_scale = 1.0;
uniform float time_scale = 1.0;

// Controls for droplet alpha
uniform float alpha_gain = 1.0;
uniform float alpha_softness = 0.15;
uniform float min_alpha = 0.0;

// Refraction blur (inside droplet)
uniform float blur_radius_px = 2.0;
uniform float blur_strength = 1.0;

// Silhouette blur (blurs the whole droplet, including outer edge)
uniform float droplet_blur_radius_px = 1.5;    // try 0..6
uniform float droplet_blur_strength = 1.0;    // 0..1

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

    vec3 c0 = texture(screen_tex, uv).rgb;

    vec3 c1 = texture(screen_tex, uv + vec2( o.x, 0.0)).rgb;
    vec3 c2 = texture(screen_tex, uv + vec2(-o.x, 0.0)).rgb;
    vec3 c3 = texture(screen_tex, uv + vec2(0.0,  o.y)).rgb;
    vec3 c4 = texture(screen_tex, uv + vec2(0.0, -o.y)).rgb;

    vec3 c5 = texture(screen_tex, uv + vec2( o.x,  o.y)).rgb;
    vec3 c6 = texture(screen_tex, uv + vec2(-o.x,  o.y)).rgb;
    vec3 c7 = texture(screen_tex, uv + vec2( o.x, -o.y)).rgb;
    vec3 c8 = texture(screen_tex, uv + vec2(-o.x, -o.y)).rgb;

    vec3 sum = vec3(0.0);
    sum += c0 * 0.25;
    sum += (c1 + c2 + c3 + c4) * 0.125;
    sum += (c5 + c6 + c7 + c8) * 0.0625;

    return sum;
}

float compute_drop_mask_at_uv(vec2 u, vec2 vp, float ttime)
{
    // Matches your original structure: computes the MAX mask across all drop sizes
    vec2 v = (u * vp * 0.1) / vp;
    vec2 n = noise(v * 200.0);

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
        }
    }

    return drop_mask;
}

float blur_mask_9tap(vec2 u, float radius_px, vec2 vp, float ttime)
{
    vec2 texel = vec2(1.0) / vp;
    vec2 o = texel * radius_px;

    float m0 = compute_drop_mask_at_uv(u, vp, ttime);

    float m1 = compute_drop_mask_at_uv(u + vec2( o.x, 0.0), vp, ttime);
    float m2 = compute_drop_mask_at_uv(u + vec2(-o.x, 0.0), vp, ttime);
    float m3 = compute_drop_mask_at_uv(u + vec2(0.0,  o.y), vp, ttime);
    float m4 = compute_drop_mask_at_uv(u + vec2(0.0, -o.y), vp, ttime);

    float m5 = compute_drop_mask_at_uv(u + vec2( o.x,  o.y), vp, ttime);
    float m6 = compute_drop_mask_at_uv(u + vec2(-o.x,  o.y), vp, ttime);
    float m7 = compute_drop_mask_at_uv(u + vec2( o.x, -o.y), vp, ttime);
    float m8 = compute_drop_mask_at_uv(u + vec2(-o.x, -o.y), vp, ttime);

    float sum = 0.0;
    sum += m0 * 0.25;
    sum += (m1 + m2 + m3 + m4) * 0.125;
    sum += (m5 + m6 + m7 + m8) * 0.0625;

    return sum;
}

void fragment()
{
    vec2 vp = viewport_size_px();

    vec2 u = UV * uv_scale;

    float ttime = TIME * time_scale;

    // Compute sharp + blurred droplet mask (this blurs the OUTER EDGE too)
    float mask_sharp = compute_drop_mask_at_uv(u, vp, ttime);

    float mask_blur = mask_sharp;

    if (droplet_blur_radius_px > 0.0 && droplet_blur_strength > 0.0)
    {
        mask_blur = blur_mask_9tap(u, droplet_blur_radius_px, vp, ttime);
    }

    float drop_mask = mix(mask_sharp, mask_blur, clamp(droplet_blur_strength, 0.0, 1.0));
    drop_mask = clamp(drop_mask, 0.0, 1.0);

    // Color: base screen + (blurred) refraction, blended by *blurred* mask
    vec2 screen_uv = SCREEN_UV;

    vec3 base_col = texture(screen_tex, screen_uv).rgb;

    // We still need a refraction offset; use your original “one-pass” loop to pick it.
    // (This keeps cost reasonable while still having the blurred silhouette.)
    vec3 col = base_col;

    // Rebuild the same n used by the refraction calculation
    vec2 v = (u * vp * 0.1) / vp;
    vec2 n = noise(v * 200.0);

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

            if (local_mask > 0.001)
            {
                vec3 drop_n = normalize(-vec3(cos(p), mix(0.2, 2.0, t - 0.5)));
                vec2 offset = drop_n.xy * refraction_strength;

                vec2 refr_uv = screen_uv - offset;

                vec3 refr_sharp = texture(screen_tex, refr_uv).rgb;

                float rpx = max(0.0, blur_radius_px);
                vec3 refr_blur = sample_screen_blur_9tap(refr_uv, rpx);

                vec3 refr_col = mix(refr_sharp, refr_blur, clamp(blur_strength, 0.0, 1.0));

                // Instead of blending by the sharp local_mask, blend by the blurred drop_mask.
                // This is what makes the whole droplet (including edge) appear out-of-focus.
                col = mix(base_col, refr_col, drop_mask);
                break;
            }
        }
    }

    ALBEDO = col;

    float a = clamp(drop_mask * alpha_gain, 0.0, 1.0);
    a = max(a, min_alpha);
    ALPHA = a;
}