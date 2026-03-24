#version 460 core

#include <flutter/runtime_effect.glsl>

// JFA Seed Pass: Initialize the Jump Flooding Algorithm from the occluder map.
// For each pixel, if it is an occluder (alpha > 0.5 in the occluder texture),
// store its own coordinate as the nearest seed. Otherwise, store a sentinel
// value (-1, -1) encoded as (0, 0) in normalized coords with alpha = 0.

uniform vec2 uResolution;   // Grid resolution (width, height)
uniform sampler2D uOccluder; // Occluder map: alpha > 0.5 = solid

out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    vec4 occ = texture(uOccluder, uv);

    if (occ.a > 0.5) {
        // This pixel is an occluder — seed with its own UV position.
        // Store UV in RG channels, 1.0 in alpha to mark as valid seed.
        fragColor = vec4(uv, 0.0, 1.0);
    } else {
        // Not an occluder — mark as unseeded (alpha = 0).
        fragColor = vec4(0.0, 0.0, 0.0, 0.0);
    }
}
