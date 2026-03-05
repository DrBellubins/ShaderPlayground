layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D u_output;

layout(set = 0, binding = 1) uniform Params
{
    vec2  u_resolution;
    float u_time;

    vec3  u_cam_pos;
    vec3  u_cam_forward;
    vec3  u_cam_right;
    vec3  u_cam_up;
    float u_fov_y;
} params;

float SdSphere(vec3 p, float r)
{
    return length(p) - r;
}

float SdBox(vec3 p, vec3 b)
{
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Infinite cone along +Y, centered at origin.
// k = (sin(angle), cos(angle)) or just (radius/height normalized).
float SdConeY(vec3 p, vec2 k)
{
    vec2 q = vec2(length(p.xz), p.y);
    float d = dot(q, k);
    float e = dot(q, vec2(-k.y, k.x));
    return max(e, -d);
}

float SdPlane(vec3 p, vec3 n, float h)
{
    return dot(p, n) + h;
}

float OpUnion(float a, float b)
{
    return min(a, b);
}

float MapScene(vec3 p)
{
    // Ground plane y = -1
    float d = SdPlane(p, vec3(0.0, 1.0, 0.0), 1.0);

    // Sphere
    d = OpUnion(d, SdSphere(p - vec3(-1.2, -0.2, 3.5), 0.8));

    // Box (cube-ish)
    d = OpUnion(d, SdBox(p - vec3(1.2, -0.2, 3.0), vec3(0.7)));

    // Cone
    vec3 pc = p - vec3(0.0, -1.0, 5.0);
    float cone = SdConeY(pc, normalize(vec2(0.6, 1.0)));
    d = OpUnion(d, cone);

    return d;
}

vec3 EstimateNormal(vec3 p)
{
    float e = 0.001;
    vec2 h = vec2(e, 0.0);

    float dx = MapScene(p + vec3(h.x, h.y, h.y)) - MapScene(p - vec3(h.x, h.y, h.y));
    float dy = MapScene(p + vec3(h.y, h.x, h.y)) - MapScene(p - vec3(h.y, h.x, h.y));
    float dz = MapScene(p + vec3(h.y, h.y, h.x)) - MapScene(p - vec3(h.y, h.y, h.x));

    return normalize(vec3(dx, dy, dz));
}

bool RayMarch(vec3 ro, vec3 rd, out vec3 hitPos, out float t)
{
    t = 0.0;

    const float tMax = 80.0;
    const int steps = 128;
    const float hitEps = 0.001;

    for (int i = 0; i < steps; i++)
    {
        hitPos = ro + rd * t;
        float d = MapScene(hitPos);

        if (d < hitEps)
        {
            return true;
        }

        t += d;

        if (t > tMax)
        {
            break;
        }
    }

    return false;
}

vec3 Shade(vec3 ro, vec3 rd)
{
    vec3 p;
    float t;

    if (!RayMarch(ro, rd, p, t))
    {
        // Sky
        float k = 0.5 * (rd.y + 1.0);
        return mix(vec3(0.08, 0.10, 0.14), vec3(0.35, 0.45, 0.65), k);
    }

    vec3 n = EstimateNormal(p);

    vec3 lightDir = normalize(vec3(0.6, 0.9, -0.4));
    float ndl = max(dot(n, lightDir), 0.0);

    // Simple shadow
    vec3 sp;
    float st;
    bool shadowHit = RayMarch(p + n * 0.01, lightDir, sp, st);
    float shadow = shadowHit ? 0.2 : 1.0;

    float ao = clamp(1.0 - t * 0.02, 0.0, 1.0);

    vec3 base = vec3(0.85);
    vec3 col = base * (0.15 + ndl * 0.85) * shadow;
    col *= ao;

    return col;
}

void main()
{
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

    if (pixel.x >= int(params.u_resolution.x) || pixel.y >= int(params.u_resolution.y))
    {
        return;
    }

    // NDC in [-1, 1]
    vec2 uv = (vec2(pixel) + vec2(0.5)) / params.u_resolution;
    vec2 ndc = uv * 2.0 - 1.0;

    float aspect = params.u_resolution.x / params.u_resolution.y;
    float tanHalfFov = tan(params.u_fov_y * 0.5);

    vec3 ro = params.u_cam_pos;

    vec3 rd = normalize(
        params.u_cam_forward
        + params.u_cam_right * (ndc.x * aspect * tanHalfFov)
        + params.u_cam_up * (ndc.y * tanHalfFov)
    );

    vec3 col = Shade(ro, rd);

    imageStore(u_output, pixel, vec4(col, 1.0));
}
