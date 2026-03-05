#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D u_output;

// Pack everything into vec4 to match UBO alignment easily.
layout(set = 0, binding = 1) uniform Params
{
    vec4 u_resolution_time;    // xy = resolution, z = time, w = unused
    vec4 u_cam_pos_fov;        // xyz = cam pos, w = fov_y
    vec4 u_cam_forward;        // xyz = forward
    vec4 u_cam_right;          // xyz = right
    vec4 u_cam_up;             // xyz = up
} params;

const float INF = 1e30;
const float EPS = 1e-4;

struct Hit
{
    float Distance;
    vec3 Position;
    vec3 Normal;
    vec3 Albedo;
};

struct Sphere
{
    vec3 center;
    float radius;
    vec3 albedo;
};

struct Plane
{
    vec3 n;
    float h;        // plane: dot(p, n) + h = 0
    vec3 albedo;
};

struct Box
{
    vec3 center;
    vec3 halfExtents;
    vec3 albedo;
};

bool IntersectSphere(vec3 ro, vec3 rd, Sphere s, out float t, out vec3 n)
{
    vec3 oc = ro - s.center;

    float b = dot(oc, rd);
    float c = dot(oc, oc) - s.radius * s.radius;
    float h = b * b - c;

    if (h < 0.0)
    {
        return false;
    }

    h = sqrt(h);

    float t0 = -b - h;
    float t1 = -b + h;

    float tt = t0;
    if (tt < EPS)
    {
        tt = t1;
    }

    if (tt < EPS)
    {
        return false;
    }

    t = tt;

    vec3 p = ro + rd * t;
    n = normalize(p - s.center);

    return true;
}

// Plane: dot(p, n) + h = 0
bool IntersectPlane(vec3 ro, vec3 rd, Plane pl, out float t, out vec3 n)
{
    float denom = dot(rd, pl.n);

    if (abs(denom) < 1e-6)
    {
        return false;
    }

    float tt = -(dot(ro, pl.n) + pl.h) / denom;

    if (tt < EPS)
    {
        return false;
    }

    t = tt;
    n = pl.n;

    // Ensure normal faces against the ray (optional, but nice for shading consistency)
    if (dot(n, rd) > 0.0)
    {
        n = -n;
    }

    return true;
}

// Axis-aligned box centered at center with halfExtents (slab method).
bool IntersectAabb(vec3 ro, vec3 rd, Box b, out float t, out vec3 n)
{
    vec3 minB = b.center - b.halfExtents;
    vec3 maxB = b.center + b.halfExtents;

    vec3 invD = 1.0 / rd;
    vec3 t0 = (minB - ro) * invD;
    vec3 t1 = (maxB - ro) * invD;

    vec3 tmin3 = min(t0, t1);
    vec3 tmax3 = max(t0, t1);

    float tmin = max(max(tmin3.x, tmin3.y), tmin3.z);
    float tmax = min(min(tmax3.x, tmax3.y), tmax3.z);

    if (tmax < max(tmin, EPS))
    {
        return false;
    }

    float tt = tmin;
    if (tt < EPS)
    {
        tt = tmax;
    }

    if (tt < EPS)
    {
        return false;
    }

    t = tt;

    vec3 p = ro + rd * t;

    // Compute normal by seeing which face we’re closest to.
    vec3 c = p - b.center;
    vec3 a = abs(c);
    vec3 he = b.halfExtents;

    // Pick dominant axis
    if (a.x > a.y && a.x > a.z)
    {
        n = vec3(sign(c.x), 0.0, 0.0);
    }
    else if (a.y > a.z)
    {
        n = vec3(0.0, sign(c.y), 0.0);
    }
    else
    {
        n = vec3(0.0, 0.0, sign(c.z));
    }

    // Face against ray (optional)
    if (dot(n, rd) > 0.0)
    {
        n = -n;
    }

    return true;
}

bool TraceScene(vec3 ro, vec3 rd, out Hit hit)
{
    hit.Distance = INF;

    // Scene definition (matches your previous placements roughly)
    Plane pl;
    pl.n = vec3(0.0, 1.0, 0.0);
    pl.h = 1.0; // y = -1
    pl.albedo = vec3(0.8, 0.8, 0.8);

    Sphere sp;
    sp.center = vec3(-1.2, -0.2, 3.5);
    sp.radius = 0.8;
    sp.albedo = vec3(0.9, 0.9, 0.95);

    Box bx;
    bx.center = vec3(1.2, -0.2, 3.0);
    bx.halfExtents = vec3(0.7, 0.7, 0.7);
    bx.albedo = vec3(0.85, 0.85, 0.85);

    // Intersect all and choose closest
    float t;
    vec3 n;

    if (IntersectPlane(ro, rd, pl, t, n))
    {
        if (t < hit.Distance)
        {
            hit.Distance = t;
            hit.Position = ro + rd * t;
            hit.n = n;
            hit.Albedo = pl.albedo;
        }
    }

    if (IntersectSphere(ro, rd, sp, t, n))
    {
        if (t < hit.Distance)
        {
            hit.Distance = t;
            hit.Position = ro + rd * t;
            hit.n = n;
            hit.Albedo = sp.albedo;
        }
    }

    if (IntersectAabb(ro, rd, bx, t, n))
    {
        if (t < hit.Distance)
        {
            hit.Distance = t;
            hit.Position = ro + rd * t;
            hit.n = n;
            hit.Albedo = bx.albedo;
        }
    }

    return hit.Distance < INF;
}

vec3 SkyColor(vec3 rd)
{
    float k = 0.5 * (rd.y + 1.0);
    return mix(vec3(0.08, 0.10, 0.14), vec3(0.35, 0.45, 0.65), k);
}

bool InShadow(vec3 p, vec3 n, vec3 lightDir)
{
    // Shadow ray: from a slightly offset point to avoid self-intersection
    vec3 ro = p + n * 0.01;
    vec3 rd = lightDir;

    Hit h;
    if (TraceScene(ro, rd, h))
    {
        return true;
    }

    return false;
}

vec3 Shade(vec3 ro, vec3 rd)
{
    Hit h;
    if (!TraceScene(ro, rd, h))
    {
        return SkyColor(rd);
    }

    vec3 lightDir = normalize(vec3(0.6, 0.9, -0.4));
    float ndl = max(dot(h.n, lightDir), 0.0);

    float shadow = InShadow(h.p, h.n, lightDir) ? 0.2 : 1.0;

    vec3 ambient = vec3(0.10);
    vec3 diffuse = h.albedo * ndl * shadow;

    return ambient + diffuse;
}

void main()
{
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    vec2 resolution = params.u_resolution_time.xy;

    if (pixel.x >= int(resolution.x) || pixel.y >= int(resolution.y))
    {
        return;
    }

    vec2 uv = (vec2(pixel) + vec2(0.5)) / resolution;
    vec2 ndc = uv * 2.0 - 1.0;

    float aspect = resolution.x / resolution.y;
    float tanHalfFov = tan(params.u_cam_pos_fov.w * 0.5);

    vec3 ro = params.u_cam_pos_fov.xyz;

    vec3 rd = normalize(
        params.u_cam_forward.xyz
        + params.u_cam_right.xyz * (ndc.x * aspect * tanHalfFov)
        + params.u_cam_up.xyz * (ndc.y * tanHalfFov)
    );

    vec3 col = Shade(ro, rd);

    imageStore(u_output, pixel, vec4(col, 1.0));
}
