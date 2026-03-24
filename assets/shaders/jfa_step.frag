#version 460 core

#include <flutter/runtime_effect.glsl>

// JFA Step: One iteration of the Jump Flooding Algorithm.
// Called repeatedly with decreasing step sizes (N/2, N/4, ..., 1).
// For each pixel, check 9 neighbors at the current step offset and keep
// the nearest seed coordinate.

uniform vec2 uResolution;   // Grid resolution (width, height)
uniform float uStepSize;    // Current JFA step size in pixels
uniform sampler2D uPrevJFA;  // Previous JFA pass result

out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;
    vec2 pixelSize = 1.0 / uResolution;

    float bestDist = 1e10;
    vec2 bestSeed = vec2(0.0);
    float bestValid = 0.0;

    // Sample 3x3 neighborhood at current step offset.
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 offset = vec2(float(dx), float(dy)) * uStepSize * pixelSize;
            vec2 sampleUV = uv + offset;

            // Clamp to texture bounds.
            sampleUV = clamp(sampleUV, vec2(0.0), vec2(1.0));

            vec4 data = texture(uPrevJFA, sampleUV);

            if (data.a > 0.5) {
                // This neighbor has a valid seed.
                vec2 seedUV = data.rg;
                vec2 diff = (uv - seedUV) * uResolution;
                float dist = dot(diff, diff);

                if (dist < bestDist) {
                    bestDist = dist;
                    bestSeed = seedUV;
                    bestValid = 1.0;
                }
            }
        }
    }

    fragColor = vec4(bestSeed, 0.0, bestValid);
}
