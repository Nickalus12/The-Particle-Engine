#version 460 core

#include <flutter/runtime_effect.glsl>

// Distance Field: Convert the final JFA result into a signed distance field.
// The output R channel stores the distance to the nearest occluder in pixels,
// normalized by a maximum distance. Used by Radiance Cascades for ray marching.

uniform vec2 uResolution;    // Grid resolution (width, height)
uniform float uMaxDistance;   // Maximum distance to normalize (e.g., 64.0)
uniform sampler2D uJFA;       // Final JFA result
uniform sampler2D uOccluder;  // Original occluder map for sign determination

out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    vec4 jfaData = texture(uJFA, uv);
    vec4 occData = texture(uOccluder, uv);

    float dist = 0.0;

    if (jfaData.a > 0.5) {
        // Valid seed found — compute distance to nearest occluder.
        vec2 seedUV = jfaData.rg;
        vec2 diff = (uv - seedUV) * uResolution;
        dist = length(diff);
    } else {
        // No seed found — treat as maximum distance.
        dist = uMaxDistance;
    }

    // Sign: negative inside occluders, positive outside.
    float sign = occData.a > 0.5 ? -1.0 : 1.0;
    float signedDist = sign * dist;

    // Normalize to [0, 1] range where 0.5 = surface, >0.5 = outside, <0.5 = inside.
    float normalizedDist = clamp(signedDist / uMaxDistance * 0.5 + 0.5, 0.0, 1.0);

    // Store raw distance in G for radiance cascade ray marching.
    float rawDistNorm = clamp(dist / uMaxDistance, 0.0, 1.0);

    // B channel: occluder opacity (0 = transparent, 1 = fully opaque).
    // Used by radiance cascade for partial light transmission (e.g., glass, water).
    float opacity = occData.a; // Already 0-1 from texture sampling.

    fragColor = vec4(normalizedDist, rawDistNorm, opacity, 1.0);
}
