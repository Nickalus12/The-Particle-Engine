#version 460 core

#include <flutter/runtime_effect.glsl>

// Radiance Cascades 2D Global Illumination — one cascade level.
// Each cascade level traces rays at a different scale. Coarse cascades
// capture long-range light transport, fine cascades capture local detail.
// Results are merged from coarse to fine in successive passes.

uniform vec2 uResolution;       // Grid resolution (width, height)
uniform float uCascadeLevel;    // Current cascade level (0 = finest)
uniform float uMaxCascades;     // Total number of cascade levels
uniform float uMaxDistance;     // Maximum ray distance for this level
uniform sampler2D uDistField;   // Signed distance field
uniform sampler2D uEmitterMap;  // Emitter map (RGB = light color, A = intensity)
uniform sampler2D uPrevCascade; // Previous (coarser) cascade result, or black

out vec4 fragColor;

// Number of angular directions to trace per pixel per cascade level.
const int NUM_DIRECTIONS = 8;

// Step along a ray through the distance field, accumulating light from emitters.
vec3 traceRay(vec2 origin, vec2 dir, float maxDist, vec2 pixelSize) {
    vec3 radiance = vec3(0.0);
    float t = 1.0; // Start 1 pixel out to avoid self-intersection.

    for (int step = 0; step < 32; step++) {
        if (t >= maxDist) break;

        vec2 pos = origin + dir * t;
        vec2 sampleUV = pos * pixelSize;

        // Out of bounds check.
        if (sampleUV.x < 0.0 || sampleUV.x > 1.0 ||
            sampleUV.y < 0.0 || sampleUV.y > 1.0) {
            break;
        }

        // Sample distance field for ray marching acceleration.
        vec4 dfSample = texture(uDistField, sampleUV);
        float dist = dfSample.g * uMaxDistance; // Un-normalize raw distance.

        // Check for emitter at this position.
        vec4 emitter = texture(uEmitterMap, sampleUV);
        if (emitter.a > 0.01) {
            // Hit an emitter. Accumulate its light with distance falloff.
            float falloff = 1.0 / (1.0 + t * t * 0.01);
            radiance += emitter.rgb * emitter.a * falloff;
            break; // Opaque emitter blocks further travel.
        }

        // Check occlusion. B channel carries opacity (0 = clear, 1 = opaque).
        // Partial occluders (glass, water) attenuate rather than block.
        float opacity = dfSample.b;
        if (dfSample.r < 0.49) {
            if (opacity > 0.9) {
                break; // Fully opaque — ray blocked.
            }
            // Partial occluder — attenuate radiance and continue.
            radiance *= (1.0 - opacity);
        }

        // Advance by the distance field value (sphere tracing).
        t += max(dist * 0.8, 0.5);
    }

    return radiance;
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 pixelSize = 1.0 / uResolution;

    // Cascade spacing: coarser levels sample at lower resolution.
    float cascadeScale = pow(2.0, uCascadeLevel);
    vec2 cellSize = vec2(cascadeScale);

    // Snap to cascade grid cell center.
    vec2 cellCenter = (floor(fragCoord / cellSize) + 0.5) * cellSize;

    float rayMaxDist = uMaxDistance * cascadeScale;

    vec3 totalRadiance = vec3(0.0);

    // Trace rays in NUM_DIRECTIONS evenly-spaced angular directions.
    float angleOffset = uCascadeLevel * 0.3927; // Golden angle offset per level.
    for (int i = 0; i < NUM_DIRECTIONS; i++) {
        float angle = (float(i) / float(NUM_DIRECTIONS)) * 6.28318530718 + angleOffset;
        vec2 dir = vec2(cos(angle), sin(angle));

        vec3 rayRadiance = traceRay(cellCenter, dir, rayMaxDist, pixelSize);
        totalRadiance += rayRadiance;
    }

    totalRadiance /= float(NUM_DIRECTIONS);

    // Merge with coarser cascade result (interval merging).
    // Clamp and check for NaNs to prevent "white-out" artifacts
    totalRadiance = clamp(totalRadiance, 0.0, 50.0);
    if (any(isnan(totalRadiance))) totalRadiance = vec3(0.0);

    // Damped blend factor (0.3) prevents compounding brightness across 4 levels.
    vec4 coarseRadiance = texture(uPrevCascade, fragCoord * pixelSize);

    // Smooth blending and limit accumulation
    vec3 coarse = clamp(coarseRadiance.rgb, 0.0, 50.0);
    if (any(isnan(coarse))) coarse = vec3(0.0);

    vec3 merged = totalRadiance + coarse * 0.3;

    fragColor = vec4(merged, 1.0);
    }
