// Metal shaders, compiled at runtime so the package builds with plain `swift build`.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Globals {
    float4x4 viewProj;
    float4 eye;
    float2 viewport;
    uint hoverId;
    uint selCount;
    float4 lightDir;
    uint pickMode;
    uint orthographic;
    uint pad1;
    uint pad2;
    float4 hoverColor;
    float4 selectColor;
    float4 forward;
};

struct DrawU {
    float4 color;
    float width;
    float depthBias;
    uint flags;
    uint pad;
};

static bool isSelected(uint id, constant uint *sel, uint n) {
    if (id == 0) return false;
    for (uint i = 0; i < n; i++) if (sel[i] == id) return true;
    return false;
}

// ---------------------------------------------------------------- Meshes

struct MeshV { packed_float3 pos; packed_float3 nrm; uint id; };
struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    uint id [[flat]];
};

vertex MeshOut mesh_vs(uint vid [[vertex_id]],
                       const device MeshV *v [[buffer(0)]],
                       constant Globals &g [[buffer(1)]],
                       constant DrawU &d [[buffer(2)]]) {
    MeshV in = v[vid];
    MeshOut o;
    float3 p = float3(in.pos);
    o.position = g.viewProj * float4(p, 1);
    o.position.z += d.depthBias * o.position.w;
    o.world = p;
    o.normal = float3(in.nrm);
    o.id = in.id;
    return o;
}

fragment float4 mesh_fs(MeshOut in [[stage_in]],
                        constant Globals &g [[buffer(1)]],
                        constant DrawU &d [[buffer(2)]],
                        constant uint *sel [[buffer(3)]]) {
    float3 n = normalize(in.normal);
    float3 V = g.orthographic != 0 ? -g.forward.xyz : normalize(g.eye.xyz - in.world);
    if (dot(n, V) < 0) n = -n;
    float3 L = normalize(g.lightDir.xyz);
    float3 L2 = normalize(float3(-L.x, -L.y, 0.4));
    float diff = max(dot(n, L), 0.0);
    float fill = max(dot(n, L2), 0.0) * 0.18;
    float3 H = normalize(L + V);
    float spec = pow(max(dot(n, H), 0.0), 60.0) * 0.22;
    float hemi = 0.5 + 0.5 * n.z;
    float3 base = d.color.rgb;
    if (isSelected(in.id, sel, g.selCount)) base = mix(base, g.selectColor.rgb, 0.6);
    else if (in.id == g.hoverId && in.id != 0) base = mix(base, g.hoverColor.rgb, 0.45);
    float3 c = base * (0.34 + 0.16 * hemi + 0.52 * diff + fill) + spec;
    float rim = pow(1.0 - max(dot(n, V), 0.0), 3.0) * 0.10;
    c += rim;
    return float4(c, d.color.a);
}

fragment uint mesh_pick_fs(MeshOut in [[stage_in]]) { return in.id; }

// ---------------------------------------------------------------- Thick lines

struct LineI { packed_float3 p0; packed_float3 p1; uint id; uint color; uint flags; };
struct LineOut {
    float4 position [[position]];
    float4 color;
    float along [[center_no_perspective]];
    uint id [[flat]];
    uint flags [[flat]];
};

vertex LineOut line_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device LineI *lines [[buffer(0)]],
                       constant Globals &g [[buffer(1)]],
                       constant DrawU &d [[buffer(2)]]) {
    LineI l = lines[iid];
    float4 c0 = g.viewProj * float4(float3(l.p0), 1);
    float4 c1 = g.viewProj * float4(float3(l.p1), 1);
    c0.w = max(c0.w, 1e-4);
    c1.w = max(c1.w, 1e-4);
    float2 half_vp = g.viewport * 0.5;
    float2 s0 = c0.xy / c0.w * half_vp;
    float2 s1 = c1.xy / c1.w * half_vp;
    float2 dir = s1 - s0;
    float len = length(dir);
    dir = len > 1e-5 ? dir / len : float2(1, 0);
    float2 nrm = float2(-dir.y, dir.x);
    float t = (vid == 1 || vid == 3 || vid == 4) ? 1.0 : 0.0;
    float side = (vid == 2 || vid == 4 || vid == 5) ? 1.0 : -1.0;
    float w = d.width * (g.pickMode != 0 ? 3.0 : 1.0);
    if ((l.flags & 2u) != 0) w *= 1.6;   // emphasized
    float4 c = t < 0.5 ? c0 : c1;
    float2 off = nrm * side * w * 0.5 + dir * (t < 0.5 ? -1.0 : 1.0) * w * 0.35;
    c.xy += off / half_vp * c.w;
    c.z -= d.depthBias * c.w;
    LineOut o;
    o.position = c;
    o.color = l.color == 0 ? d.color : unpack_unorm4x8_to_float(l.color);
    o.along = t * len;
    o.id = l.id;
    o.flags = l.flags;
    return o;
}

fragment float4 line_fs(LineOut in [[stage_in]],
                        constant Globals &g [[buffer(1)]],
                        constant uint *sel [[buffer(3)]]) {
    if ((in.flags & 1u) != 0 && fmod(in.along, 9.0) > 5.0) discard_fragment();
    float4 c = in.color;
    if (isSelected(in.id, sel, g.selCount)) c = float4(g.selectColor.rgb, 1);
    else if (in.id == g.hoverId && in.id != 0) c = float4(g.hoverColor.rgb, 1);
    return c;
}

fragment uint line_pick_fs(LineOut in [[stage_in]]) { return in.id; }

// ---------------------------------------------------------------- Points

struct PointI { packed_float3 p; uint id; uint color; float size; };
struct PointOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint id [[flat]];
};

vertex PointOut point_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device PointI *pts [[buffer(0)]],
                         constant Globals &g [[buffer(1)]],
                         constant DrawU &d [[buffer(2)]]) {
    PointI p = pts[iid];
    float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,-1), float2(1,1), float2(-1,1) };
    float2 uv = corners[vid];
    float4 c = g.viewProj * float4(float3(p.p), 1);
    float size = p.size * (g.pickMode != 0 ? 1.8 : 1.0);
    c.xy += uv * size * 0.5 / (g.viewport * 0.5) * c.w;
    c.z -= d.depthBias * c.w;
    PointOut o;
    o.position = c;
    o.uv = uv;
    o.color = unpack_unorm4x8_to_float(p.color);
    o.id = p.id;
    return o;
}

fragment float4 point_fs(PointOut in [[stage_in]],
                         constant Globals &g [[buffer(1)]],
                         constant uint *sel [[buffer(3)]]) {
    float r = length(in.uv);
    if (r > 1.0) discard_fragment();
    float4 c = in.color;
    if (isSelected(in.id, sel, g.selCount)) c = float4(g.selectColor.rgb, 1);
    else if (in.id == g.hoverId && in.id != 0) c = float4(g.hoverColor.rgb, 1);
    float4 inner = float4(1, 1, 1, 1);
    float aa = smoothstep(0.55, 0.65, r);
    float edge = 1.0 - smoothstep(0.85, 1.0, r);
    float4 o = mix(inner, c, aa);
    o.a *= edge;
    return o;
}

fragment uint point_pick_fs(PointOut in [[stage_in]]) {
    if (length(in.uv) > 1.0) discard_fragment();
    return in.id;
}

// ---------------------------------------------------------------- Flat fills

struct FillV { packed_float3 p; uint id; uint color; };
struct FillOut {
    float4 position [[position]];
    float4 color;
    uint id [[flat]];
};

vertex FillOut fill_vs(uint vid [[vertex_id]],
                       const device FillV *v [[buffer(0)]],
                       constant Globals &g [[buffer(1)]],
                       constant DrawU &d [[buffer(2)]]) {
    FillV f = v[vid];
    FillOut o;
    o.position = g.viewProj * float4(float3(f.p), 1);
    o.position.z -= d.depthBias * o.position.w;
    o.color = unpack_unorm4x8_to_float(f.color);
    o.id = f.id;
    return o;
}

fragment float4 fill_fs(FillOut in [[stage_in]],
                        constant Globals &g [[buffer(1)]],
                        constant uint *sel [[buffer(3)]]) {
    float4 c = in.color;
    if (isSelected(in.id, sel, g.selCount)) c = float4(g.selectColor.rgb, max(c.a, 0.45));
    else if (in.id == g.hoverId && in.id != 0) c = float4(mix(c.rgb, g.hoverColor.rgb, 0.6), max(c.a, 0.35));
    return c;
}

fragment uint fill_pick_fs(FillOut in [[stage_in]]) { return in.id; }

// ---------------------------------------------------------------- Background

struct BgOut { float4 position [[position]]; float t; };

vertex BgOut bg_vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    BgOut o;
    o.position = float4(p[vid], 1, 1);
    o.t = (p[vid].y + 1) * 0.5;
    return o;
}

fragment float4 bg_fs(BgOut in [[stage_in]], constant float4 *colors [[buffer(0)]]) {
    return mix(colors[1], colors[0], saturate(in.t));
}
"""
