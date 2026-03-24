#version 460 core

#include <flutter/runtime_effect.glsl>

// Bloom Downsample: Dual Kawase downsample filter.
// Reads from a higher-resolution texture and writes a blurred, downsampled
// version. This is the first half of the Kawase bloom pipeline.

uniform vec2 uResolution;     // Output (half) resolution
uniform vec2 uTexelSize;      // 1.0 / source resolution
uniform float uThreshold;     // Brightness threshold for bloom extraction (first pass only)
uniform float uIsFirstPass;   // 1.0 = extract bright pixels, 0.0 = just downsample
uniform sampler2D uSource;    // Source texture (scene or previous downsample)

out vec4 fragColor;

vec3 thresholdColor(vec3 color, float threshold) {
    float brightness = max(color.r, max(color.g, color.b));
    float contribution = max(brightness - threshold, 0.0) / max(brightness, 0.001);
    return color * contribution;
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    // Dual Kawase downsample: 5-tap filter pattern.
    // Center sample + 4 diagonal half-texel offsets.
    vec2 halfTexel = uTexelSize * 0.5;

    vec3 sum = texture(uSource, uv).rgb * 4.0;
    sum += texture(uSource, uv + vec2(-halfTexel.x, -halfTexel.y)).rgb;
    sum += texture(uSource, uv + vec2( halfTexel.x, -halfTexel.y)).rgb;
    sum += texture(uSource, uv + vec2(-halfTexel.x,  halfTexel.y)).rgb;
    sum += texture(uSource, uv + vec2( halfTexel.x,  halfTexel.y)).rgb;
    sum /= 8.0;

    // On the first downsample pass, extract only bright pixels.
    if (uIsFirstPass > 0.5) {
        sum = thresholdColor(sum, max(uThreshold, 0.85));
    }

    fragColor = vec4(sum, 1.0);
}
