shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float refraction_strength = 0.03; // try 0.01 - 0.08
uniform float uv_scale = 1.0;
uniform float time_scale = 1.0;

// "Resolution" equivalent: use viewport size (in pixels)
vec2 viewport_size_px()
{
    return vec2(textureSize(screen_tex, 0));
}

// --- Shadertoy functions, kept very close ---

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
    // Base UV on the plane (so the pattern sticks to the mesh).
    // If you want it to be purely screen-space, use SCREEN_UV instead.
    vec2 u = UV * uv_scale;

    vec2 vp = viewport_size_px();

    // Shadertoy's: v = (c*0.1)/iResolution; then noise(v*200)
    // Here we approximate using UVs and viewport size to keep a similar scale.
    vec2 v = (u * vp * 0.1) / vp;
    vec2 n = noise(v * 200.0);

    // Start with the background behind the plane
    vec2 screen_uv = SCREEN_UV;
    vec3 col = texture(screen_tex, screen_uv).rgb;

    float ttime = TIME * time_scale;

    // Loop through inverse sizes of drops (4..1)
    // Godot shaders require compile-time loop bounds; this is fine.
    for (float r = 4.0; r > 0.0; r -= 1.0)
    {
        // Shadertoy: x = iResolution.xy * r * .015
        // We'll interpret x as "grid density" relative to viewport.
        vec2 x = vp * r * 0.015;

        vec2 p = 6.28 * u * x + (n - 0.5) * 2.0;
        vec2 s = sin(p);

        // Per-cell stable coordinates (like the Shadertoy round())
        vec2 cell_uv = round(u * x - 0.25) / x;

        // Shadertoy used iChannel1; your file fakes it with noise()
        vec4 d = vec4(noise(cell_uv * 200.0), noise(cell_uv));

        // Drop shape + fading (same formula, minor cleanup)
        float fade = max(0.0, 1.0 - fract(ttime * (d.b + 0.1) + d.g) * 2.0);
        float t = (s.x + s.y) * fade;

        // Keep only a portion of drops depending on size bucket
        if (d.r < (5.0 - r) * 0.08 && t > 0.5)
        {
            // Approx "normal" / gradient direction
            vec3 drop_n = normalize(-vec3(cos(p), mix(0.2, 2.0, t - 0.5)));

            // Refract screen background
            vec2 offset = drop_n.xy * refraction_strength;
            col = texture(screen_tex, screen_uv - offset).rgb;
        }
    }

    //ALBEDO = col;
	//ALBEDO = vec3(SCREEN_UV, 0.0);
	ALBEDO = texture(screen_tex, SCREEN_UV).rgb;

    // Optional: make the plane itself invisible except for refracted color
    ALPHA = 1.0;
}