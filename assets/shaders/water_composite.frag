#version 460 core

#include <flutter/runtime_effect.glsl>

// Water Composite pass.
// Inputs:
// - uScene: base scene color (already element-shaded)
// - uWaterData: RG=flow vector, B=depth proxy, A=water mask
// Applies:
// - flow-based refraction
// - depth tint absorption
// - edge fresnel highlight + foam accent

uniform vec2 uResolution;
uniform float uTime;
uniform float uRefractionStrength;
uniform float uFresnelStrength;
uniform float uFoamStrength;
uniform sampler2D uScene;
uniform sampler2D uWaterData;

out vec4 fragColor;

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    vec4 w = texture(uWaterData, uv);
    float mask = w.a;

    vec3 base = texture(uScene, uv).rgb;
    if (mask < 0.01) {
        fragColor = vec4(base, 1.0);
        return;
    }

    // Decode flow [-1, 1]
    vec2 flow = (w.rg * 2.0) - 1.0;
    float depth = w.b; // 0..1 pressure/depth proxy

    // Animated micro-ripple from time + cell position
    float ripple = sin((uv.x * 120.0 + uv.y * 90.0) + uTime * 2.2) * 0.5 +
                   sin((uv.x * 210.0 - uv.y * 160.0) - uTime * 1.7) * 0.5;
    vec2 rippleVec = vec2(ripple, ripple * 0.5);

    float refractAmp = mix(0.15, 1.0, depth) * uRefractionStrength;
    vec2 refractUv = uv + (flow * 0.004 + rippleVec * 0.0018) * refractAmp;
    refractUv = clamp(refractUv, vec2(0.0), vec2(1.0));

    vec3 refracted = texture(uScene, refractUv).rgb;

    // Neighbor mask sampling to estimate edge thickness (cheap fresnel proxy)
    vec2 texel = 1.0 / uResolution;
    float mL = texture(uWaterData, uv + vec2(-texel.x, 0.0)).a;
    float mR = texture(uWaterData, uv + vec2( texel.x, 0.0)).a;
    float mU = texture(uWaterData, uv + vec2(0.0, -texel.y)).a;
    float mD = texture(uWaterData, uv + vec2(0.0,  texel.y)).a;
    float interior = (mL + mR + mU + mD) * 0.25;
    float edge = clamp(mask - interior, 0.0, 1.0);

    // Absorption tint by depth (shallow cyan -> deep blue)
    vec3 shallowTint = vec3(0.78, 0.92, 1.0);
    vec3 deepTint = vec3(0.10, 0.36, 0.62);
    vec3 waterTint = mix(shallowTint, deepTint, depth);

    // Base mix: mostly refracted scene with subtle tinting
    vec3 waterColor = mix(refracted, refracted * waterTint, 0.24 + depth * 0.22);

    // Soft caustic modulation for shallow moving water.
    float caustic = sin((uv.x * 340.0 + uv.y * 180.0) + uTime * 2.8 + flow.x * 4.0) *
                    sin((uv.x * 170.0 - uv.y * 320.0) - uTime * 2.2 + flow.y * 4.0);
    caustic = caustic * 0.5 + 0.5;
    float shallow = (1.0 - depth);
    waterColor += vec3(0.08, 0.13, 0.16) * caustic * shallow * 0.45;

    // Fresnel/edge highlight
    float fresnel = pow(edge, 0.7) * (0.25 + 0.75 * uFresnelStrength);
    waterColor += vec3(0.25, 0.33, 0.40) * fresnel;

    // Foam from edge + velocity magnitude
    float speed = clamp(length(flow), 0.0, 1.0);
    float foam = clamp(edge * 1.6 + speed * 0.45 - 0.25, 0.0, 1.0);
    foam *= uFoamStrength;
    waterColor = mix(waterColor, vec3(0.90, 0.94, 0.98), foam * 0.55);

    // Directional glint for moving surface highlights.
    float flowFacing = clamp(dot(normalize(flow + vec2(0.001)), normalize(vec2(0.75, -0.35))), 0.0, 1.0);
    float glint = pow(max(0.0, ripple * 0.5 + 0.5), 6.0) * (0.15 + speed * 0.25) * flowFacing;
    waterColor += vec3(0.26, 0.32, 0.36) * glint;

    // Preserve local contrast a bit so water doesn't look muddy
    float baseLum = luma(base);
    float waterLum = luma(waterColor);
    waterColor += (baseLum - waterLum) * 0.10;

    // Blend by mask (future-proof if mask becomes soft)
    vec3 outColor = mix(base, waterColor, mask);
    fragColor = vec4(outColor, 1.0);
}
