#version 460 core

#include <flutter/runtime_effect.glsl>

// Bloom Upsample: Dual Kawase upsample filter.
// Reads from a lower-resolution bloom texture and blends it additively
// with the next higher-resolution level. This is the second half of the
// Kawase bloom pipeline.

uniform vec2 uResolution;     // Output (larger) resolution
uniform vec2 uTexelSize;      // 1.0 / source (smaller) resolution
uniform float uIntensity;     // Bloom intensity multiplier
uniform sampler2D uSource;    // Lower-resolution bloom texture
uniform sampler2D uDestination; // Higher-resolution texture to blend with

out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    // Dual Kawase upsample: 9-tap tent filter.
    vec2 t = uTexelSize;

    vec3 sum = vec3(0.0);
    sum += texture(uSource, uv + vec2(-t.x,  0.0)).rgb * 2.0;
    sum += texture(uSource, uv + vec2( t.x,  0.0)).rgb * 2.0;
    sum += texture(uSource, uv + vec2( 0.0, -t.y)).rgb * 2.0;
    sum += texture(uSource, uv + vec2( 0.0,  t.y)).rgb * 2.0;
    sum += texture(uSource, uv + vec2(-t.x, -t.y)).rgb;
    sum += texture(uSource, uv + vec2( t.x, -t.y)).rgb;
    sum += texture(uSource, uv + vec2(-t.x,  t.y)).rgb;
    sum += texture(uSource, uv + vec2( t.x,  t.y)).rgb;
    sum /= 12.0;

    // Blend with the destination (higher-res) texture.
    vec3 dest = texture(uDestination, uv).rgb;
    vec3 result = dest + sum * uIntensity;

    fragColor = vec4(result, 1.0);
}
