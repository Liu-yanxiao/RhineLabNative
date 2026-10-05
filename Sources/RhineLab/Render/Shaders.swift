/// Metal shading language source, compiled at launch.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265;

struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4x4 proj;
    float4x4 lightViewProj;
    float4 camPos;
    float4 params;      // x exposure, y fogNear, z fogFar, w envScale
    float4 screen;      // xy size in pixels, z shadows enabled, w time
    float4 fogColor;
    float4 keyDir;  float4 keyColor;
    float4 fillDir; float4 fillColor;
    float4 hemiSky; float4 hemiGround;
    float4 post;        // x focusDistance, y dof strength
    float4 clip;        // near, far, aperture, max blur
    float4 ao;          // radius, strength, bias, tap count
};

struct Inst { float4 posTilt; float4 yawQR; };   // pos+tilt, yaw/quality/reveal

struct SurfaceMat {
    float4 colorLow;    // rgb, a = roughness (array look)
    float4 colorHigh;   // rgb, a = roughness (extracted look)
    float4 p0;          // metalLow, metalHigh, transmissionLow, transmissionHigh
    float4 p1;          // thickness, attenuationDistance, ior, kind
    float4 atten;       // attenuation colour
    float4 dark;        // albedo under the dark theme
    float4 p2;          // clearcoat, clearcoat roughness
};

struct VIn {
    float3 pos [[attribute(0)]];
    float3 nrm [[attribute(1)]];
    float2 uv  [[attribute(2)]];
};

struct VOut {
    float4 position [[position]];
    float3 wpos;
    float3 wn;
    float2 uv;
    float h;
    float q [[flat]];
    float rev [[flat]];
    float theme [[flat]];
    float2 axis;
};

float3x3 rotXY(float tilt, float yaw) {
    float cx = cos(tilt), sx = sin(tilt), cy = cos(yaw), sy = sin(yaw);
    float3x3 rx = float3x3(float3(1, 0, 0), float3(0, cx, sx), float3(0, -sx, cx));
    float3x3 ry = float3x3(float3(cy, 0, -sy), float3(0, 1, 0), float3(sy, 0, cy));
    return rx * ry;
}

vertex VOut vs_main(VIn v [[stage_in]], uint iid [[instance_id]],
                    constant Frame &f [[buffer(1)]], constant Inst *insts [[buffer(2)]]) {
    Inst inst = insts[iid];
    float3x3 R = rotXY(inst.posTilt.w, inst.yawQR.x);
    float3 world = inst.posTilt.xyz + R * v.pos;
    VOut o;
    o.position = f.viewProj * float4(world, 1);
    o.wpos = world;
    o.wn = R * v.nrm;
    o.uv = v.uv;
    o.h = v.pos.y / 3.7;
    o.q = inst.yawQR.y;
    o.rev = inst.yawQR.z;
    o.theme = inst.yawQR.w;
    float3 up = R * float3(0, 1, 0);
    float3 mvUp = (f.view * float4(up, 0)).xyz;
    float viewZ = max(0.0001, abs((f.view * float4(world, 1)).z));
    o.axis = 1.85 * float2(f.proj[0][0] * mvUp.x, f.proj[1][1] * mvUp.y) / viewZ;
    return o;
}

vertex float4 vs_shadow(VIn v [[stage_in]], uint iid [[instance_id]],
                        constant Frame &f [[buffer(1)]], constant Inst *insts [[buffer(2)]]) {
    Inst inst = insts[iid];
    float3x3 R = rotXY(inst.posTilt.w, inst.yawQR.x);
    return f.lightViewProj * float4(inst.posTilt.xyz + R * v.pos, 1);
}

// ---- Lighting -------------------------------------------------------------

float2 envBRDF(float rough, float NoV) {
    const float4 c0 = float4(-1, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = rough * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

float shadowFactor(constant Frame &f, depth2d<float> map, float3 wpos, float3 N, float2 pixel) {
    if (f.screen.z < 0.5) return 1.0;
    constexpr sampler cmp(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float4 lp = f.lightViewProj * float4(wpos + N * 0.03, 1);
    float3 s = lp.xyz / lp.w;
    float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
    if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 || s.z > 1) return 1;
    float texel = 1.0 / float(map.get_width());
    // Rotated Vogel disc: soft, even penumbra without banding.
    float noise = fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
    float angle0 = noise * 6.2831853;
    const int taps = 8;
    float sum = 0;
    for (int i = 0; i < taps; i++) {
        float r = sqrt((float(i) + 0.5) / float(taps));
        float a = angle0 + float(i) * 2.39996323;
        sum += map.sample_compare(cmp, uv + float2(cos(a), sin(a)) * r * texel * 5.0, s.z - 0.0003);
    }
    return sum / float(taps);
}

struct Lit { float3 diffuse; float3 spec; };

Lit lightSurface(constant Frame &f, float3 albedo, float metal, float rough, float3 N, float3 V, float shadow,
                 texturecube<float> envSpec, texturecube<float> envIrr, float clearcoat = 0.0, float ccRough = 0.25) {
    constexpr sampler cubeS(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 diffC = albedo * (1 - metal);
    float3 F0 = mix(float3(0.04), albedo, metal);
    float a = max(rough * rough, 0.002);
    float NoV = saturate(dot(N, V)) + 1e-4;
    Lit L; L.diffuse = float3(0); L.spec = float3(0);
    for (int i = 0; i < 2; i++) {
        float3 Ld = i == 0 ? f.keyDir.xyz : f.fillDir.xyz;
        float3 col = (i == 0 ? f.keyColor.rgb : f.fillColor.rgb) * (i == 0 ? shadow : 1.0);
        float NoL = saturate(dot(N, Ld));
        if (NoL <= 0) continue;
        float3 H = normalize(Ld + V);
        float NoH = saturate(dot(N, H)), VoH = saturate(dot(V, H));
        float d2 = NoH * NoH * (a * a - 1) + 1;
        float D = a * a / (PI * d2 * d2);
        float gv = NoL * sqrt(NoV * NoV * (1 - a * a) + a * a);
        float gl = NoV * sqrt(NoL * NoL * (1 - a * a) + a * a);
        float Vis = 0.5 / max(gv + gl, 1e-4);
        float3 F = F0 + (1 - F0) * pow(1 - VoH, 5.0);
        L.spec += col * NoL * D * Vis * F;
        L.diffuse += col * NoL * diffC / PI;
        if (clearcoat > 0) {
            // Thin dielectric coat over the frosted body (three.js clearcoat lobe, F0 = 0.04).
            float ca = max(ccRough * ccRough, 0.002);
            float cd2 = NoH * NoH * (ca * ca - 1) + 1;
            float cD = ca * ca / (PI * cd2 * cd2);
            float cgv = NoL * sqrt(NoV * NoV * (1 - ca * ca) + ca * ca);
            float cgl = NoV * sqrt(NoL * NoL * (1 - ca * ca) + ca * ca);
            float cF = 0.04 + 0.96 * pow(1 - VoH, 5.0);
            L.spec += col * NoL * cD * (0.5 / max(cgv + cgl, 1e-4)) * cF * clearcoat;
        }
    }
    float3 hemi = mix(f.hemiGround.rgb, f.hemiSky.rgb, N.y * 0.5 + 0.5);
    L.diffuse += hemi * diffC / PI;
    float envScale = f.params.w;
    L.diffuse += envIrr.sample(cubeS, N).rgb * envScale * diffC;
    float2 ab = envBRDF(rough, NoV);
    L.spec += envSpec.sample(cubeS, reflect(-V, N), level(rough * 5.0)).rgb * envScale * (F0 * ab.x + ab.y);
    if (clearcoat > 0) {
        float2 cab = envBRDF(ccRough, NoV);
        float ccF = (0.04 * cab.x + cab.y) * clearcoat;
        L.spec += envSpec.sample(cubeS, reflect(-V, N), level(ccRough * 5.0)).rgb * envScale * ccF;
        L.diffuse *= 1.0 - ccF;
    }
    return L;
}

float3 applyFog(constant Frame &f, float3 color, float3 wpos) {
    float depth = abs((f.view * float4(wpos, 1)).z);
    float t = smoothstep(f.params.y, f.params.z, depth);
    return mix(color, f.fogColor.rgb, t);
}

// ---- Opaque surfaces ------------------------------------------------------

fragment float4 fs_surface(VOut in [[stage_in]], bool front [[front_facing]],
                           constant Frame &f [[buffer(1)]], constant SurfaceMat &m [[buffer(3)]],
                           depth2d<float> shadowMap [[texture(1)]],
                           texturecube<float> envSpec [[texture(4)]], texturecube<float> envIrr [[texture(5)]]) {
    float q = in.q;
    float kind = m.p1.w;
    if (kind > 1.5 && kind < 2.5) {
        // Internal parts fade in with stable screen-space coverage.
        float coverage = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
        if (q <= coverage) discard_fragment();
    }
    float3 albedo = mix(mix(m.colorLow.rgb, m.colorHigh.rgb, q), m.dark.rgb, in.theme);
    float rough = mix(m.colorLow.a, m.colorHigh.a, q);
    float metal = mix(m.p0.x, m.p0.y, q);
    float3 N = normalize(in.wn);
    if (!front) N = -N;
    float3 V = normalize(f.camPos.xyz - in.wpos);
    float shadow = shadowFactor(f, shadowMap, in.wpos, N, in.position.xy);
    Lit L = lightSurface(f, albedo, metal, rough, N, V, shadow, envSpec, envIrr);
    float3 color = applyFog(f, L.diffuse + L.spec, in.wpos);
    return float4(color, 1);
}

// ---- Transmissive surfaces (frosted cover, extracted ivory edge) -----------

float glassReveal(float progress, float h) {
    float edge = 1.0 - 1.24 * clamp(progress, 0.0, 1.0);
    return smoothstep(edge, edge + 0.24, clamp(h, 0.0, 1.0));
}

fragment float4 fs_trans(VOut in [[stage_in]], bool front [[front_facing]],
                         constant Frame &f [[buffer(1)]], constant SurfaceMat &m [[buffer(3)]],
                         depth2d<float> shadowMap [[texture(1)]], texture2d<float> sceneT [[texture(0)]],
                         texturecube<float> envSpec [[texture(4)]], texturecube<float> envIrr [[texture(5)]]) {
    constexpr sampler tri(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float q = in.q;
    bool frost = m.p1.w > 0.5 && m.p1.w < 1.5;
    float clearing = frost ? glassReveal(in.rev, in.h) : 0.0;
    float3 albedo = mix(m.colorLow.rgb, m.colorHigh.rgb, q);
    float tintAmount = frost ? 1.0 - q : 0.0;
    float g = smoothstep(0.1, 1.0, clamp(in.h, 0.0, 1.0));
    float3 gradient = mix(float3(0.40, 0.30, 0.20), float3(1.0, 0.98, 0.94), g);
    albedo *= mix(float3(1.0), gradient, tintAmount);
    // Dark theme: smoke-grey shell; the cleared cover tends towards a cool near-white tint.
    float3 darkAlbedo = frost ? mix(m.dark.rgb, float3(0.92, 0.96, 0.97), clearing) : m.dark.rgb;
    albedo = mix(albedo, darkAlbedo, in.theme);

    float rough;
    float transmission = mix(m.p0.z, m.p0.w, q);
    float thickness = m.p1.x;
    float attDist = m.p1.y;
    if (frost) {
        rough = mix(mix(0.28, 0.42, q), 0.025, clearing);
        transmission = mix(transmission, 0.985, clearing);
        thickness = mix(thickness, 0.018, clearing);
        attDist = mix(attDist, 8.0, clearing);
    } else {
        rough = mix(m.colorLow.a, m.colorHigh.a, q);
    }
    float ior = m.p1.z;
    float3 N = normalize(in.wn);
    if (!front) N = -N;
    float3 V = normalize(f.camPos.xyz - in.wpos);
    float shadow = shadowFactor(f, shadowMap, in.wpos, N, in.position.xy);
    float clearcoat = m.p2.x * (1.0 - q) * (1.0 - clearing);
    Lit L = lightSurface(f, albedo, mix(m.p0.x, m.p0.y, q), rough, N, V, shadow, envSpec, envIrr, clearcoat, m.p2.y);

    // Refraction: where the view ray leaves the slab, read the blurred opaque capture.
    float3 rv = refract(-V, N, 1.0 / ior);
    float3 exitPoint = in.wpos + normalize(rv) * thickness;
    float4 clip = f.viewProj * float4(exitPoint, 1);
    float2 uv = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    float width = float(sceneT.get_width());
    float iorRough = clamp(ior * 2.0 - 2.0, 0.0, 1.0);
    float nativeLod = log2(width) * rough * iorRough;
    float lod = nativeLod;
    if (frost) {
        // Bound the frosted blur to ~1.6% of the projected panel height.
        float strength = clamp((rough - 0.025) / (0.42 - 0.025), 0.0, 1.0);
        float panelPixels = length(in.axis * float2(sceneT.get_width(), sceneT.get_height()));
        float clearLod = log2(width) * 0.025 * iorRough;
        float bounded = log2(max(exp2(clearLod), panelPixels * 0.016 * pow(strength, 1.15)));
        lod = mix(nativeLod, min(nativeLod, bounded), q);
    }
    lod = clamp(lod, 0.0, float(sceneT.get_num_mip_levels() - 1));
    float3 transmitted = sceneT.sample(tri, uv, level(lod)).rgb;
    float3 atten = float3(1.0);
    if (attDist < 1000.0) {
        float3 coeff = -log(max(m.atten.rgb, 0.001)) / attDist;
        atten = exp(-coeff * length(rv * thickness));
    }
    float NoV = saturate(dot(N, V)) + 1e-4;
    float2 ab = envBRDF(rough, NoV);
    float3 F = mix(float3(0.04), albedo, mix(m.p0.x, m.p0.y, q)) * ab.x + ab.y;
    transmitted = (1.0 - F) * transmitted * atten * albedo;

    float3 color = mix(L.diffuse, transmitted, transmission) + L.spec;
    color = applyFog(f, color, in.wpos);
    return float4(color, 1);
}

// ---- Printed label ----------------------------------------------------------

fragment float4 fs_label(VOut in [[stage_in]], constant Frame &f [[buffer(1)]], texture2d<float> tex [[texture(2)]],
                         sampler s [[sampler(0)]]) {
    float4 c = tex.sample(s, in.uv);
    // Dark theme inverts the print: dark paper, light ink.
    float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 inverted = mix(float3(0.023, 0.032, 0.037), float3(0.78, 0.78, 0.71), 1.0 - smoothstep(0.12, 0.65, lum));
    c.rgb = mix(c.rgb, inverted, in.theme);
    return float4(c.rgb, c.a * in.q);
}

// ---- Composite --------------------------------------------------------------

struct FSOut { float4 position [[position]]; float2 uv; };

vertex FSOut vs_full(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

float3 acesFilmic(float3 c, float exposure) {
    c *= exposure / 0.6;
    const float3x3 inM = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383), float3(0.04823, 0.01566, 0.83777));
    const float3x3 outM = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276), float3(-0.07367, -0.00605, 1.07602));
    c = inM * c;
    float3 a = c * (c + 0.0245786) - 0.000090537;
    float3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
    c = outM * (a / b);
    return saturate(c);
}

float3 srgbEncode(float3 c) {
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

float viewDistance(constant Frame &f, float z) {
    float n = f.clip.x, fa = f.clip.y;
    float A = fa / (n - fa), B = n * fa / (n - fa);
    return B / (z + A);
}

float3 viewPosition(constant Frame &f, float2 uv, float depth) {
    float dist = viewDistance(f, depth);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    return float3(ndc.x * dist / f.proj[0][0], ndc.y * dist / f.proj[1][1], -dist);
}

/// Screen-space ambient occlusion from the resolved depth (half resolution).
fragment float fs_ao(FSOut in [[stage_in]], constant Frame &f [[buffer(1)]], depth2d<float> depthTex [[texture(1)]]) {
    constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
    float2 size = float2(depthTex.get_width(), depthTex.get_height());
    float2 texel = 1.0 / size;
    float d = depthTex.sample(nearest, in.uv);
    if (d >= 0.99999) return 1.0;
    float3 P = viewPosition(f, in.uv, d);
    float dl = depthTex.sample(nearest, in.uv - float2(texel.x, 0)), dr = depthTex.sample(nearest, in.uv + float2(texel.x, 0));
    float du = depthTex.sample(nearest, in.uv - float2(0, texel.y)), dd = depthTex.sample(nearest, in.uv + float2(0, texel.y));
    float3 Pl = viewPosition(f, in.uv - float2(texel.x, 0), dl), Pr = viewPosition(f, in.uv + float2(texel.x, 0), dr);
    float3 Pu = viewPosition(f, in.uv - float2(0, texel.y), du), Pd = viewPosition(f, in.uv + float2(0, texel.y), dd);
    float3 dx = abs(Pr.z - P.z) < abs(Pl.z - P.z) ? Pr - P : P - Pl;
    float3 dy = abs(Pd.z - P.z) < abs(Pu.z - P.z) ? Pd - P : P - Pu;
    float3 N = normalize(cross(dx, dy));
    if (N.z < 0) N = -N;
    float R = f.ao.x;
    float screenRadius = R * f.proj[1][1] / max(-P.z, 0.001) * 0.5;
    float2 aspect = float2(size.y / size.x, 1.0);
    float noise = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
    int taps = clamp(int(f.ao.w), 1, 64);
    float occ = 0;
    for (int i = 0; i < 64; i++) {
        if (i >= taps) break;
        float r = (float(i) + 0.5) / float(taps);
        float a = float(i) * 2.39996323;
        float2 uv = in.uv + float2(cos(a), sin(a)) * (0.15 + 0.85 * r) * screenRadius * aspect;
        float3 v = viewPosition(f, uv, depthTex.sample(nearest, uv)) - P;
        float len = length(v);
        if (len < R * 0.2 || len > R * 1.4) continue;
        occ += max(0.0, dot(N, v) / len - f.ao.z) * (1.0 - saturate(len / (R * 1.4)));
    }
    return saturate(1.0 - f.ao.y * occ / float(taps));
}

// Blur radius in pixels for a given scene depth (same model as three's BokehPass).
float cocRadius(constant Frame &f, float dist, float width) {
    float blur = clamp((dist - f.post.x) * f.clip.z, -f.clip.w, f.clip.w);
    return abs(blur) * width * 0.9;
}

fragment float4 fs_composite(FSOut in [[stage_in]], constant Frame &f [[buffer(1)]],
                             texture2d<float> color [[texture(0)]], depth2d<float> depthTex [[texture(1)]],
                             texture2d<float> aoTex [[texture(2)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
    float width = float(color.get_width());
    float2 texel = 1.0 / float2(color.get_width(), color.get_height());
    float centerDepth = depthTex.sample(nearest, in.uv);
    float R = cocRadius(f, viewDistance(f, centerDepth), width);
    float3 c = color.sample(s, in.uv).rgb;
    if (R > 0.6 && f.post.y > 0.0 && !(int(f.post.z) & 4)) {
        float3 sum = c; float wsum = 1.0;
        const int taps = 16;
        for (int i = 0; i < taps; i++) {
            float r = sqrt((float(i) + 0.5) / float(taps));
            float a = float(i) * 2.39996323;
            float2 o = float2(cos(a), sin(a)) * r * R;
            float2 uv = in.uv + o * texel;
            float sd = depthTex.sample(nearest, uv);
            float sr = cocRadius(f, viewDistance(f, sd), width);
            // A tap contributes only if its own blur reaches this pixel.
            float w = saturate(sr - length(o) + 1.0);
            sum += color.sample(s, uv).rgb * w;
            wsum += w;
        }
        c = sum / wsum;
    }
    if (!(int(f.post.z) & 2)) {
        float2 aoTexel = 1.0 / float2(aoTex.get_width(), aoTex.get_height());
        // 5 × 5 box over the half-resolution occlusion: wide enough to hide the sampling pattern
        // on large flat faces seen at grazing angles.
        float ao = 0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) { ao += aoTex.sample(s, in.uv + float2(x, y) * aoTexel).r; }
        }
        c *= ao / 25.0;
    }
    c = acesFilmic(c, f.params.x);
    c = srgbEncode(c);
    // Hash dither hides banding in the soft gradients.
    float n = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
    c += (n - 0.5) / 255.0;
    return float4(c, 1);
}

// ---- Environment: analytic "photo room" (same layout as three.js RoomEnvironment) ----------

struct EnvParams { uint face; float roughness; uint mode; float res; };

float3 cubeDirection(uint face, float2 uv) {
    float u = uv.x * 2.0 - 1.0, v = uv.y * 2.0 - 1.0;
    switch (face) {
        case 0: return float3(1, -v, -u);
        case 1: return float3(-1, -v, u);
        case 2: return float3(u, 1, v);
        case 3: return float3(u, -1, -v);
        case 4: return float3(u, -v, 1);
        default: return float3(-u, -v, -1);
    }
}

// Ray against a box rotated about Y. Returns (tNear, tFar); `n` is the entry normal.
float2 hitBox(float3 o, float3 d, float3 c, float3 halfSize, float rot, thread float3 &n) {
    float cs = cos(rot), sn = sin(rot);
    float3 lo = o - c, ld = d;
    float3 po = float3(lo.x * cs - lo.z * sn, lo.y, lo.x * sn + lo.z * cs);
    float3 pd = float3(ld.x * cs - ld.z * sn, ld.y, ld.x * sn + ld.z * cs);
    float3 inv = 1.0 / (pd + float3(1e-8));
    float3 t0 = (-halfSize - po) * inv, t1 = (halfSize - po) * inv;
    float3 tmin = min(t0, t1), tmax = max(t0, t1);
    float tn = max(max(tmin.x, tmin.y), tmin.z), tf = min(min(tmax.x, tmax.y), tmax.z);
    float3 ln = tmin.x >= tmin.y && tmin.x >= tmin.z ? float3(-sign(pd.x), 0, 0)
              : (tmin.y >= tmin.z ? float3(0, -sign(pd.y), 0) : float3(0, 0, -sign(pd.z)));
    n = float3(ln.x * cs + ln.z * sn, ln.y, -ln.x * sn + ln.z * cs);
    return float2(tn, tf);
}

float3 roomRadiance(float3 d) {
    const float3 O = float3(0);
    const float3 lightPos = float3(0.418, 16.199, 0.300);
    float bestT = 1e9; float3 bestN = float3(0, 1, 0); float3 emissive = float3(0); bool isLight = false;
    float3 n;
    // Room (seen from inside): exit point.
    float2 r = hitBox(O, d, float3(-0.757, 13.219, 0.717), float3(31.713, 28.305, 28.591) * 0.5, 0.0, n);
    float tRoom = r.y;
    float3 roomN = float3(0);
    {
        float3 p = O + d * tRoom - float3(-0.757, 13.219, 0.717);
        float3 h = float3(31.713, 28.305, 28.591) * 0.5;
        float3 a = abs(p) / h;
        roomN = a.x > a.y && a.x > a.z ? float3(-sign(p.x), 0, 0) : (a.y > a.z ? float3(0, -sign(p.y), 0) : float3(0, 0, -sign(p.z)));
    }
    bestT = tRoom; bestN = roomN;
    // Boxes
    const float4 boxA[6] = { float4(-10.906, 2.009, 1.846, -0.195), float4(-5.607, -0.754, -0.758, 0.994), float4(6.167, 0.857, 7.803, 0.561),
                             float4(-2.017, 0.018, 6.124, 0.333), float4(2.291, -0.756, -2.621, -0.286), float4(-2.193, -0.369, -5.547, 0.516) };
    const float3 boxS[6] = { float3(2.328, 7.905, 4.651), float3(1.970, 1.534, 3.955), float3(3.927, 6.285, 3.687),
                             float3(2.002, 4.566, 2.064), float3(1.546, 1.552, 1.496), float3(3.875, 3.487, 2.986) };
    for (int i = 0; i < 6; i++) {
        float2 t = hitBox(O, d, boxA[i].xyz, boxS[i] * 0.5, boxA[i].w, n);
        if (t.x > 0 && t.x < t.y && t.x < bestT) { bestT = t.x; bestN = n; }
    }
    // Emissive area lights
    const float3 lc[6] = { float3(-16.116, 14.37, 8.208), float3(-16.109, 18.021, -8.207), float3(14.904, 12.198, -1.832),
                           float3(-0.462, 8.89, 14.520), float3(3.235, 11.486, -12.541), float3(0.0, 20.0, 0.0) };
    const float3 ls[6] = { float3(0.1, 2.428, 2.739), float3(0.1, 2.425, 2.751), float3(0.15, 4.265, 6.331),
                           float3(4.38, 5.441, 0.088), float3(2.5, 2.0, 0.1), float3(1.0, 0.1, 1.0) };
    const float li[6] = { 50, 50, 17, 43, 20, 100 };
    for (int i = 0; i < 6; i++) {
        float2 t = hitBox(O, d, lc[i], ls[i] * 0.5, 0.0, n);
        if (t.x > 0 && t.x < t.y && t.x < bestT) { bestT = t.x; isLight = true; emissive = float3(li[i]); }
    }
    if (isLight) return emissive;
    float3 P = O + d * bestT;
    float3 toL = lightPos - P;
    float d2 = dot(toL, toL), dist = sqrt(d2);
    float window = saturate(1.0 - pow(dist / 28.0, 4.0)); window *= window;
    float irr = 900.0 / max(d2, 0.01) * window * saturate(dot(bestN, toL / dist));
    return float3(irr / PI);
}

fragment float4 fs_env_generate(FSOut in [[stage_in]], constant EnvParams &p [[buffer(0)]]) {
    return float4(roomRadiance(normalize(cubeDirection(p.face, in.uv))), 1);
}

float radicalInverse(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

fragment float4 fs_env_filter(FSOut in [[stage_in]], constant EnvParams &p [[buffer(0)]], texturecube<float> src [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 N = normalize(cubeDirection(p.face, in.uv));
    float3 up = abs(N.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 T = normalize(cross(up, N)), B = cross(N, T);
    const uint samples = 192;
    float3 sum = float3(0); float wsum = 0;
    float texelSolid = 4.0 * PI / (6.0 * 256.0 * 256.0);
    for (uint i = 0; i < samples; i++) {
        float2 xi = float2(float(i) / float(samples), radicalInverse(i));
        float3 L; float weight; float pdf;
        if (p.mode == 1) {
            // Cosine-weighted hemisphere (diffuse irradiance).
            float phi = 2.0 * PI * xi.x, cosT = sqrt(1.0 - xi.y), sinT = sqrt(xi.y);
            L = T * (sinT * cos(phi)) + B * (sinT * sin(phi)) + N * cosT;
            weight = 1.0; pdf = cosT / PI;
        } else {
            float a = p.roughness * p.roughness;
            float phi = 2.0 * PI * xi.x;
            float cosT = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y)), sinT = sqrt(1.0 - cosT * cosT);
            float3 H = T * (sinT * cos(phi)) + B * (sinT * sin(phi)) + N * cosT;
            L = 2.0 * dot(N, H) * H - N;
            float NoL = dot(N, L);
            if (NoL <= 0) continue;
            float d2 = cosT * cosT * (a * a - 1.0) + 1.0;
            float D = a * a / (PI * d2 * d2);
            pdf = D / 4.0 + 1e-4;
            weight = NoL;
        }
        float lod = max(0.0, 0.5 * log2(1.0 / (float(samples) * pdf + 1e-4) / texelSolid) + 1.0);
        sum += src.sample(s, L, level(lod)).rgb * weight;
        wsum += weight;
    }
    return float4(sum / max(wsum, 1e-4), 1);
}
"""
