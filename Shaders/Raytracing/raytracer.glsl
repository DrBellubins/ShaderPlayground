#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D u_output;

// Pack everything into vec4 to match UBO alignment easily.
layout(set = 0, binding = 1) uniform Params
{
    vec4 ResolutionTime;    // xy = resolution, z = time, w = unused
    vec4 CameraPositionFov; // xyz = camera position, w = fov_y
    vec4 CameraForward;     // xyz = forward
    vec4 CameraRight;       // xyz = right
    vec4 CameraUp;          // xyz = up
    vec4 Runtime;           // x = JitterSpeed, yzw = reserved
    vec4 SunDirection;
} Parameters;

const float InfiniteDistance = 1e30;
const float Epsilon = 1e-4;

struct Hit
{
    float Distance;
    vec3 Position;
    vec3 Normal;
    vec3 Albedo;
};

struct Sphere
{
    vec3 Center;
    float Radius;
    vec3 Albedo;
};

struct Plane
{
    vec3 Normal;
    float Height; // plane: dot(Position, Normal) + Height = 0
    vec3 Albedo;
};

struct Box
{
    vec3 Center;
    vec3 HalfExtents;
    vec3 Albedo;
};

bool IntersectSphere(vec3 RayOrigin, vec3 RayDirection, Sphere SphereShape, out float HitDistance, out vec3 HitNormal)
{
    vec3 OriginToCenter = RayOrigin - SphereShape.Center;

    float HalfB = dot(OriginToCenter, RayDirection);
    float C = dot(OriginToCenter, OriginToCenter) - SphereShape.Radius * SphereShape.Radius;
    float Discriminant = HalfB * HalfB - C;

    if (Discriminant < 0.0)
    {
        return false;
    }

    float SqrtDiscriminant = sqrt(Discriminant);

    float T0 = -HalfB - SqrtDiscriminant;
    float T1 = -HalfB + SqrtDiscriminant;

    float CandidateDistance = T0;
    if (CandidateDistance < Epsilon)
    {
        CandidateDistance = T1;
    }

    if (CandidateDistance < Epsilon)
    {
        return false;
    }

    HitDistance = CandidateDistance;

    vec3 HitPosition = RayOrigin + RayDirection * HitDistance;
    HitNormal = normalize(HitPosition - SphereShape.Center);

    return true;
}

// Plane: dot(Position, Normal) + Height = 0
bool IntersectPlane(vec3 RayOrigin, vec3 RayDirection, Plane PlaneShape, out float HitDistance, out vec3 HitNormal)
{
    float Denominator = dot(RayDirection, PlaneShape.Normal);

    if (abs(Denominator) < 1e-6)
    {
        return false;
    }

    float CandidateDistance = -(dot(RayOrigin, PlaneShape.Normal) + PlaneShape.Height) / Denominator;

    if (CandidateDistance < Epsilon)
    {
        return false;
    }

    HitDistance = CandidateDistance;
    HitNormal = PlaneShape.Normal;

    if (dot(HitNormal, RayDirection) > 0.0)
    {
        HitNormal = -HitNormal;
    }

    return true;
}

// Axis-aligned box centered at Center with HalfExtents (slab method).
bool IntersectAabb(vec3 RayOrigin, vec3 RayDirection, Box BoxShape, out float HitDistance, out vec3 HitNormal)
{
    vec3 BoxMin = BoxShape.Center - BoxShape.HalfExtents;
    vec3 BoxMax = BoxShape.Center + BoxShape.HalfExtents;

    vec3 InverseRayDirection = 1.0 / RayDirection;
    vec3 T0Vector = (BoxMin - RayOrigin) * InverseRayDirection;
    vec3 T1Vector = (BoxMax - RayOrigin) * InverseRayDirection;

    vec3 TMinVector = min(T0Vector, T1Vector);
    vec3 TMaxVector = max(T0Vector, T1Vector);

    float TMin = max(max(TMinVector.x, TMinVector.y), TMinVector.z);
    float TMax = min(min(TMaxVector.x, TMaxVector.y), TMaxVector.z);

    if (TMax < max(TMin, Epsilon))
    {
        return false;
    }

    float CandidateDistance = TMin;
    if (CandidateDistance < Epsilon)
    {
        CandidateDistance = TMax;
    }

    if (CandidateDistance < Epsilon)
    {
        return false;
    }

    HitDistance = CandidateDistance;

    vec3 HitPosition = RayOrigin + RayDirection * HitDistance;

    vec3 LocalHitPosition = HitPosition - BoxShape.Center;
    vec3 AbsLocalHitPosition = abs(LocalHitPosition);

    if (AbsLocalHitPosition.x > AbsLocalHitPosition.y && AbsLocalHitPosition.x > AbsLocalHitPosition.z)
    {
        HitNormal = vec3(sign(LocalHitPosition.x), 0.0, 0.0);
    }
    else if (AbsLocalHitPosition.y > AbsLocalHitPosition.z)
    {
        HitNormal = vec3(0.0, sign(LocalHitPosition.y), 0.0);
    }
    else
    {
        HitNormal = vec3(0.0, 0.0, sign(LocalHitPosition.z));
    }

    if (dot(HitNormal, RayDirection) > 0.0)
    {
        HitNormal = -HitNormal;
    }

    return true;
}

bool TraceScene(vec3 RayOrigin, vec3 RayDirection, out Hit SceneHit)
{
    SceneHit.Distance = InfiniteDistance;

    Plane GroundPlane;
    GroundPlane.Normal = vec3(0.0, 1.0, 0.0);
    GroundPlane.Height = 1.0; // y = -1
    GroundPlane.Albedo = vec3(0.8, 0.8, 0.8);

    Sphere LeftSphere;
    LeftSphere.Center = vec3(-1.2, -0.2, 3.5);
    LeftSphere.Radius = 0.8;
    LeftSphere.Albedo = vec3(0.9, 0.9, 0.95);

    Box RightBox;
    RightBox.Center = vec3(1.2, -0.2, 3.0);
    RightBox.HalfExtents = vec3(0.7, 0.7, 0.7);
    RightBox.Albedo = vec3(0.85, 0.85, 0.85);

    float ShapeHitDistance;
    vec3 ShapeHitNormal;

    if (IntersectPlane(RayOrigin, RayDirection, GroundPlane, ShapeHitDistance, ShapeHitNormal))
    {
        if (ShapeHitDistance < SceneHit.Distance)
        {
            SceneHit.Distance = ShapeHitDistance;
            SceneHit.Position = RayOrigin + RayDirection * ShapeHitDistance;
            SceneHit.Normal = ShapeHitNormal;
            SceneHit.Albedo = GroundPlane.Albedo;
        }
    }

    if (IntersectSphere(RayOrigin, RayDirection, LeftSphere, ShapeHitDistance, ShapeHitNormal))
    {
        if (ShapeHitDistance < SceneHit.Distance)
        {
            SceneHit.Distance = ShapeHitDistance;
            SceneHit.Position = RayOrigin + RayDirection * ShapeHitDistance;
            SceneHit.Normal = ShapeHitNormal;
            SceneHit.Albedo = LeftSphere.Albedo;
        }
    }

    if (IntersectAabb(RayOrigin, RayDirection, RightBox, ShapeHitDistance, ShapeHitNormal))
    {
        if (ShapeHitDistance < SceneHit.Distance)
        {
            SceneHit.Distance = ShapeHitDistance;
            SceneHit.Position = RayOrigin + RayDirection * ShapeHitDistance;
            SceneHit.Normal = ShapeHitNormal;
            SceneHit.Albedo = RightBox.Albedo;
        }
    }

    return SceneHit.Distance < InfiniteDistance;
}

vec3 SkyColor(vec3 RayDirection)
{
    float InterpolationFactor = 0.5 * (RayDirection.y + 1.0);
    vec3 HorizonColor = vec3(0.08, 0.10, 0.14);
    vec3 ZenithColor = vec3(0.35, 0.45, 0.65);

    return mix(HorizonColor, ZenithColor, InterpolationFactor);
}

bool IsInShadow(vec3 SurfacePosition, vec3 SurfaceNormal, vec3 LightDirection)
{
    vec3 ShadowRayOrigin = SurfacePosition + SurfaceNormal * 0.01;
    vec3 ShadowRayDirection = LightDirection;

    Hit ShadowHit;
    if (TraceScene(ShadowRayOrigin, ShadowRayDirection, ShadowHit))
    {
        return true;
    }

    return false;
}

vec3 SpiralOffset(vec3 direction, vec3 position, float distance, bool isSin)
{
    //vec3 dir = position /*normalize(direction)*/;
    vec3 dir = normalize(direction);

    // Stable perpendicular frame around dir.
    vec3 up = (abs(dir.y) < 0.99) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, dir));
    vec3 bitangent = cross(dir, tangent);

    // Deterministic helix parameters (no animation).
    // "distance" is your parameter that moves along the helix.
    float angularFrequency = 12.0; // radians per world unit (tweak)
    float angle = distance + ((Parameters.ResolutionTime.z * Parameters.Runtime.x));

    // Radius can be constant, or can grow with distance.
    // If you want it to start at exactly 0 radius at distance==0, use clamp(distance,...).
    float baseRadius = 3.141592 * 0.01;       // tweak: overall offset scale
    float radiusGrowth = 0.0;     // tweak: set >0 to widen with distance
    float radius = baseRadius + (distance * radiusGrowth);

    float a;
    float b;

    if (isSin)
    {
        a = sin(angle);
        b = cos(angle);
    }
    else
    {
        a = cos(angle);
        b = sin(angle);
    }

    // Offset stays perpendicular to dir (a helix around the axis).
    vec3 offset = (tangent * a + bitangent * b) * radius;
    return offset;
}

vec3 Shade(vec3 RayOrigin, vec3 RayDirection)
{
    Hit SurfaceHit;
    if (!TraceScene(RayOrigin, RayDirection, SurfaceHit))
    {
        return SkyColor(RayDirection);
    }

    //vec3 lightDirection = normalize(vec3(0.6, 0.9, -0.4));
    vec3 lightDirection = normalize(Parameters.SunDirection);
    float NdotL = max(dot(SurfaceHit.Normal, lightDirection), 0.0);

    vec3 shadowOrigin = SurfaceHit.Position + SurfaceHit.Normal * 0.01;

    float dist = SurfaceHit.Distance;

    const int ShadowSamples = 8;

    float visibility = 0.0;

    for (int i = 0; i < ShadowSamples; i++)
    {
        float sampleDist = float(i);

        vec3 sinSpiral = SpiralOffset(lightDirection, SurfaceHit.Position, sampleDist, true);
        vec3 cosSpiral = SpiralOffset(lightDirection, SurfaceHit.Position, sampleDist, false);

        vec3 shadowDirSin = normalize(lightDirection + sinSpiral);
        vec3 shadowDirCos = normalize(lightDirection + cosSpiral);

        bool inShadowSin = IsInShadow(shadowOrigin, vec3(0.0), shadowDirSin);
        bool inShadowCos = IsInShadow(shadowOrigin, vec3(0.0), shadowDirCos);

        float visSin = inShadowSin ? 0.0 : 1.0;
        float visCos = inShadowCos ? 0.0 : 1.0;

        visibility += 0.5 * (visSin + visCos);
    }

    visibility /= float(ShadowSamples);

    float ShadowMultiplier = mix(0.2, 1.0, visibility);

    vec3 AmbientLight = vec3(0.10);
    vec3 DiffuseLight = SurfaceHit.Albedo * NdotL * ShadowMultiplier;

    return AmbientLight + DiffuseLight;
}

void main()
{
    ivec2 PixelCoordinates = ivec2(gl_GlobalInvocationID.xy);
    vec2 Resolution = Parameters.ResolutionTime.xy;

    if (PixelCoordinates.x >= int(Resolution.x) || PixelCoordinates.y >= int(Resolution.y))
    {
        return;
    }

    vec2 PixelUv = (vec2(PixelCoordinates) + vec2(0.5)) / Resolution;
    vec2 NormalizedDeviceCoordinates = PixelUv * 2.0 - 1.0;

    float AspectRatio = Resolution.x / Resolution.y;
    float TanHalfFovY = tan(Parameters.CameraPositionFov.w * 0.5);

    vec3 RayOrigin = Parameters.CameraPositionFov.xyz;

    vec3 RayDirection = normalize(
        Parameters.CameraForward.xyz
        + Parameters.CameraRight.xyz * (NormalizedDeviceCoordinates.x * AspectRatio * TanHalfFovY)
        + Parameters.CameraUp.xyz * (NormalizedDeviceCoordinates.y * TanHalfFovY)
    );

    vec3 OutputColor = Shade(RayOrigin, RayDirection);

    imageStore(u_output, PixelCoordinates, vec4(OutputColor, 1.0));
}
