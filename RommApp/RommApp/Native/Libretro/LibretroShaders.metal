#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut libretro_vertex(const device VertexIn *vertices [[buffer(0)]], uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

// Plain (the `.sharp` case), the default: a nearest-sampled passthrough with no
// filter, matching what the native player has always rendered.
fragment float4 libretro_fragment(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texCoord);
}

// Decodes a raw RGB565 frame straight from the GPU instead of the CPU
// scalar loop updateTexture used to run per pixel: NativePlayerRenderer
// uploads the packed 16-bit samples untouched into an r16Uint texture,
// and this runs as a blit pass into the real bgra8Unorm target so every
// existing shader downstream keeps sampling a normal float texture like
// before. Bit layout is libretro's own RETRO_PIXEL_FORMAT_RGB565: bits
// 15-11 red, 10-5 green, 4-0 blue.
fragment float4 shader_rgb565_unpack_fragment(VertexOut in [[stage_in]],
                                               texture2d<uint> tex [[texture(0)]],
                                               sampler samp [[sampler(0)]]) {
    uint2 size = uint2(tex.get_width(), tex.get_height());
    uint2 coord = uint2(in.texCoord * float2(size));
    coord = min(coord, size - 1);
    uint packed = tex.read(coord).r;
    float r = float((packed >> 11) & 0x1F) / 31.0;
    float g = float((packed >> 5) & 0x3F) / 63.0;
    float b = float(packed & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
}

// The RGB1555 twin of the pass above, for the cores that pick libretro's
// 0RGB1555 format instead. vecx is the first in this app to emit it, at
// 1320x1640 and 50fps thanks to its 4x vector resolution, which is
// exactly the scale where the old per-pixel CPU loop saturated the main
// thread (measured on the 565 path's history: 30fps and 50ms stalls
// before its decode moved here). Bit layout: bit 15 unused, 14-10 red,
// 9-5 green, 4-0 blue.
fragment float4 shader_rgb1555_unpack_fragment(VertexOut in [[stage_in]],
                                                texture2d<uint> tex [[texture(0)]],
                                                sampler samp [[sampler(0)]]) {
    uint2 size = uint2(tex.get_width(), tex.get_height());
    uint2 coord = uint2(in.texCoord * float2(size));
    coord = min(coord, size - 1);
    uint packed = tex.read(coord).r;
    float r = float((packed >> 10) & 0x1F) / 31.0;
    float g = float((packed >> 5) & 0x1F) / 31.0;
    float b = float(packed & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
}

// Every shader below this line takes the source texture's pixel size (in
// texels) as a second fragment buffer, needed to step to neighbouring
// texels for edge and scanline work. NativePlayerRenderer supplies it.

// SABR's character is edge-aware sharpening rather than smoothing: an
// unsharp mask whose strength backs off near a detected edge so it
// sharpens flat regions without ringing across sprite outlines.
fragment float4 shader_sabr_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler samp [[sampler(0)]],
                                      constant float2 &texelSize [[buffer(1)]]) {
    float4 center = tex.sample(samp, in.texCoord);
    float4 n = tex.sample(samp, in.texCoord + float2(0, -texelSize.y));
    float4 s = tex.sample(samp, in.texCoord + float2(0, texelSize.y));
    float4 e = tex.sample(samp, in.texCoord + float2(texelSize.x, 0));
    float4 w = tex.sample(samp, in.texCoord + float2(-texelSize.x, 0));

    float4 blur = (n + s + e + w) * 0.25;
    float edge = distance(n.rgb, s.rgb) + distance(e.rgb, w.rgb);
    float amount = 0.6 / (1.0 + edge * 4.0);
    return clamp(center + (center - blur) * amount, 0.0, 1.0);
}

// Shared scanline term: darkens rows between texels along the vertical
// axis, the trait every CRT variant below builds on.
static float scanlineFactor(float2 uv, float2 texelSize, float strength) {
    float line = fract(uv.y / texelSize.y);
    float beam = 1.0 - strength + strength * sin(line * M_PI_F);
    return beam;
}

// crt-aperture: a fine RGB aperture-grille mask over crisp scanlines,
// the sharpest and least softened of the CRT set.
fragment float4 shader_crt_aperture_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float scan = scanlineFactor(in.texCoord, texelSize, 0.35);
    float column = fract(in.texCoord.x / (texelSize.x / 3.0));
    float3 mask = float3(1.0);
    if (column < 0.333) mask = float3(1.15, 0.85, 0.85);
    else if (column < 0.667) mask = float3(0.85, 1.15, 0.85);
    else mask = float3(0.85, 0.85, 1.15);
    return float4(color.rgb * scan * mask, color.a);
}

// crt-easymode: gentle scanlines, a soft vignette, no visible mask, the
// mildest of the set and closest to a plain screen with rounded edges.
fragment float4 shader_crt_easymode_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float scan = scanlineFactor(in.texCoord, texelSize, 0.18);
    float2 centered = in.texCoord - 0.5;
    float vignette = 1.0 - dot(centered, centered) * 0.35;
    return float4(color.rgb * scan * vignette, color.a);
}

// crt-mattias: thin, dark scanlines with the in-between rows left bright,
// a higher-contrast scanline than easymode without geom's curvature.
fragment float4 shader_crt_mattias_fragment(VertexOut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]],
                                             sampler samp [[sampler(0)]],
                                             constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float line = fract(in.texCoord.y / texelSize.y);
    float scan = line < 0.15 ? 0.4 : 1.0;
    return float4(color.rgb * scan, color.a);
}

// crt-beam: models a Gaussian electron-beam intensity profile per
// scanline instead of a hard on/off stripe, a softer falloff than
// mattias with no colour mask.
fragment float4 shader_crt_beam_fragment(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float line = fract(in.texCoord.y / texelSize.y) - 0.5;
    float beam = exp(-line * line * 8.0);
    float intensity = mix(0.55, 1.15, beam);
    return float4(color.rgb * intensity, color.a);
}

// crt-caligari: a soft, slightly desaturated scanline look, the gentlest
// and blurriest of the set, closer to a well worn CRT than a sharp one.
fragment float4 shader_crt_caligari_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float4 below = tex.sample(samp, in.texCoord + float2(0, texelSize.y));
    float4 blended = mix(color, below, 0.3);
    float scan = scanlineFactor(in.texCoord, texelSize, 0.22);
    float gray = dot(blended.rgb, float3(0.299, 0.587, 0.114));
    float3 desaturated = mix(blended.rgb, float3(gray), 0.08);
    return float4(desaturated * scan, blended.a);
}

// crt-geom: bows the image outward like a curved CRT tube instead of
// coloring/scanlining a flat rectangle, the one shader in this list that
// reshapes the screen's geometry rather than its color. Distorts texture
// coordinates with the same x-bends-by-y^2/y-bends-by-x^2 barrel
// curvature libretro/slang-shaders' crt-geom.slang uses, then clips to a
// rounded rectangle and darkens the corners, so the visible image reads
// as a convex tube face rather than a flat panel. An earlier six-shader
// pass on this list dropped a multi-pass crt-geom.slang port as looking
// bad on device; this is a different, single-pass geometry-only effect
// built from scratch, not that same shader revisited.
fragment float4 shader_crt_geom_fragment(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant float2 &texelSize [[buffer(1)]]) {
    float2 c = in.texCoord * 2.0 - 1.0;
    const float curvature = 6.0;
    float2 offset = c.yx / curvature;
    c += c * offset * offset;
    float2 uv = c * 0.5 + 0.5;

    // Rounded-rect clip in the same centered space: anything outside the
    // rounded box, corners included, is the tube's bezel, not the
    // picture. dist is the signed distance to that rounded boundary
    // (negative inside), reused below to fade brightness in before the
    // hard cutoff instead of ending in a flat, shadowless edge.
    const float cornerRadius = 0.08;
    float2 boxHalf = float2(1.0 - cornerRadius);
    float2 q = abs(c) - boxHalf;
    float dist = length(max(q, 0.0)) - cornerRadius;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || dist > 0.02) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float4 color = tex.sample(samp, uv);
    float scan = scanlineFactor(uv, texelSize, 0.35);
    // Corner/edge shadow: ramps from full brightness well inside the
    // rounded rect down to 45% right at its boundary, so the darkening
    // actually reads as a shadow cast by the tube's bezel rather than a
    // uniform tint or an invisible one-pixel edge. Layered under a mild
    // whole-screen vignette for the rest of the curvature.
    float edgeShadow = 1.0 - smoothstep(-0.16, 0.02, dist);
    float vignette = mix(0.45, 1.0, edgeShadow) * (1.0 - dot(c, c) * 0.12);
    return float4(color.rgb * scan * vignette, color.a);
}

// lcd: "LCD 3x", CabinetOS's handheld look, offered on every handheld
// screen. lcd3x (Author: Gigaherz, public domain) as libretro/glsl-shaders
// has it at the commit CabinetOS draws from (435612fe), its own defaults
// (brighten_scanlines 16.0, brighten_lcd 4.0): a soft sine-based scanline
// darkening plus a per-channel horizontal subpixel-fringe term, phase
// offset 2/3 of a cycle per channel to fake an RGB stripe mask without
// sampling neighbouring texels. The same maths as that file's fragment
// stage, line for line; the texture here is the frame's own size, so its
// TextureSize / InputSize is 1.
fragment float4 shader_lcd_fragment(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler samp [[sampler(0)]],
                                     constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    const float brightenScanlines = 16.0;
    const float brightenLCD = 4.0;
    float2 omega = (2.0 * M_PI_F) / texelSize;
    float2 angle = in.texCoord * omega;
    float yFactor = (brightenScanlines + sin(angle.y)) / (brightenScanlines + 1.0);
    float3 offsets = M_PI_F * float3(0.5, 0.5 - 2.0 / 3.0, 0.5 - 4.0 / 3.0);
    float3 xFactors = (brightenLCD + sin(angle.x + offsets)) / (brightenLCD + 1.0);
    float3 shaped = yFactor * xFactors * color.rgb;
    return float4(shaped, color.a);
}

// vmu: the VMU minigame player's sunken grey-green LCD, never offered in
// any shader menu; VMUPlayerView sets it directly and nothing else ever
// does. The core hands over pure 1-bit frames (white paper, black ink)
// and this maps them onto the skin's sage face with exactly the stamped
// mock's math (spikes/vmu/vmu-skin-mock2.html: the frame multiplied over
// the face at 0.85 opacity, so ink lands at 0.15 x paper and paper passes
// through). Paper is the face's own top-to-bottom gradient, #c3cdb4 to
// #b3bfa6; the 0.1154..0.8846 remap is the picture's fixed vertical
// placement inside the face (160 of 208 units, centred), kept in lock
// step with VMULCDScreen's layout constants so the picture's paper meets
// the face around it without a seam.
fragment float4 shader_vmu_lcd_fragment(VertexOut in [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         sampler samp [[sampler(0)]],
                                         constant float2 &texelSize [[buffer(1)]]) {
    float lum = tex.sample(samp, in.texCoord).r;
    float faceY = mix(0.1154, 0.8846, in.texCoord.y);
    float3 paper = mix(float3(0.765, 0.804, 0.706), float3(0.702, 0.749, 0.651), faceY);
    return float4(paper * (0.15 + 0.85 * lum), 1.0);
}

// THE DOT MATRIX LOOKS, CabinetOS's three Game Boy screens by their TV
// names: "Dot matrix" (the original Game Boy's green), "Dot matrix Pocket"
// (the Pocket's grey) and, for Game Boy Color, "Dot matrix" keeping the
// game's own colours. On the TV they are multi-pass GPL shaders
// (libretro/glsl-shaders `handheld/gameboy.glslp`, `gameboy-pocket.glslp`,
// `gbc-dot-matrix-white.glslp`); this app is MIT and draws one pass, so
// these are written here from what the screen looks like, not translated
// from those files. Taken from them only as plain values: each screen's
// two colours (their palette images) and the presets' own settings named
// below. Left out: the previous frames' ghosting (no frame history here)
// and the paper texture.
//
// One square dot per game pixel with a gap around it, the dot's darkness
// from how dark the pixel is, and a faint dot even where the pixel is
// blank (the "off" dot a real screen shows), over the screen's light
// shade. The dots cast a soft shadow down and to the right onto the
// screen behind them. Edges are softened over one screen pixel, so the
// grid stays even at any size the picture is drawn.

// How much of a dot's cell the gap takes, and the shadow's offset and
// strength, in cells.
constant float kDotGap = 0.14;
constant float2 kDotShadowOffset = float2(0.22, 0.28);
constant float kDotShadowStrength = 0.30;

// 1 inside the dot whose cell holds `p` (in game pixels), 0 in the gap.
static float dotCover(float2 p, float2 aa) {
    float2 edge = abs(fract(p) - 0.5) - (0.5 - kDotGap * 0.5);
    float2 soft = smoothstep(-aa * 0.5, aa * 0.5, edge);
    return (1.0 - soft.x) * (1.0 - soft.y);
}

// The game pixel whose cell holds `p`, sampled at its centre.
static float3 dotSource(texture2d<float> tex, sampler samp, float2 p, float2 texelSize) {
    return tex.sample(samp, (floor(p) + 0.5) * texelSize).rgb;
}

static float dotDarkness(float3 c) {
    return 1.0 - dot(c, float3(0.299, 0.587, 0.114));
}

// A mono screen: dots in `ink` over `paper`, as dark as the pixel is,
// never fainter than `baseline` (the presets' baseline_alpha, 0.10).
static float4 monoDotMatrix(float2 uv, texture2d<float> tex, sampler samp,
                            float2 texelSize, float3 paper, float3 ink) {
    const float baseline = 0.10;
    float2 p = uv / texelSize;
    float2 aa = fwidth(p);
    float cover = dotCover(p, aa);
    float alpha = baseline + (1.0 - baseline) * dotDarkness(dotSource(tex, samp, p, texelSize));
    float2 sp = p - kDotShadowOffset;
    float shadowAlpha = baseline + (1.0 - baseline) * dotDarkness(dotSource(tex, samp, sp, texelSize));
    float shadow = kDotShadowStrength * shadowAlpha * dotCover(sp, aa);
    float3 screen = paper * (1.0 - shadow);
    return float4(mix(screen, ink, alpha * cover), 1.0);
}

// "Dot matrix": the original Game Boy's yellow-green screen and its dark
// teal-green dots (gameboy.glslp's palette.png, #A0AA06 and #1D6A6B).
fragment float4 shader_dot_matrix_fragment(VertexOut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]],
                                           sampler samp [[sampler(0)]],
                                           constant float2 &texelSize [[buffer(1)]]) {
    return monoDotMatrix(in.texCoord, tex, samp, texelSize,
                         float3(0xA0, 0xAA, 0x06) / 255.0, float3(0x1D, 0x6A, 0x6B) / 255.0);
}

// "Dot matrix Pocket": the Game Boy Pocket's grey-green screen and its
// near-black dots (gameboy-pocket.glslp's gbp-palette.png, #A6AC84 and
// #121923).
fragment float4 shader_dot_matrix_pocket_fragment(VertexOut in [[stage_in]],
                                                  texture2d<float> tex [[texture(0)]],
                                                  sampler samp [[sampler(0)]],
                                                  constant float2 &texelSize [[buffer(1)]]) {
    return monoDotMatrix(in.texCoord, tex, samp, texelSize,
                         float3(0xA6, 0xAC, 0x84) / 255.0, float3(0x12, 0x19, 0x23) / 255.0);
}

// "Dot matrix" on Game Boy Color: each dot in the game's own colour, a
// little desaturated (the preset's desaturate_toggle, 0.4), fully opaque
// (its baseline_alpha, 1.0), over a white screen (b-w-palette.png), so a
// colour game keeps its colours and only the grid and the shadow show.
fragment float4 shader_dot_matrix_color_fragment(VertexOut in [[stage_in]],
                                                 texture2d<float> tex [[texture(0)]],
                                                 sampler samp [[sampler(0)]],
                                                 constant float2 &texelSize [[buffer(1)]]) {
    const float3 paper = float3(1.0);
    float2 p = in.texCoord / texelSize;
    float2 aa = fwidth(p);
    float cover = dotCover(p, aa);
    float3 c = dotSource(tex, samp, p, texelSize);
    float3 dotColour = mix(c, float3(dot(c, float3(0.299, 0.587, 0.114))), 0.4);
    float2 sp = p - kDotShadowOffset;
    float shadow = kDotShadowStrength * dotDarkness(dotSource(tex, samp, sp, texelSize)) * dotCover(sp, aa);
    float3 screen = paper * (1.0 - shadow);
    return float4(mix(screen, dotColour, cover), 1.0);
}
