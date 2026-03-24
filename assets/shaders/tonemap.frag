#version 460 core

#include <flutter/runtime_effect.glsl>

// Tone Mapping: ACES filmic tone mapping with day/night color grading.
// Composites the base scene, GI radiance, and bloom into the final output.

uniform vec2 uResolution;       // Output resolution
uniform float uExposure;        // Exposure multiplier (1.0 = neutral)
uniform float uDayNightT;       // Day/night transition [0.0 = day, 1.0 = night]
uniform float uBloomStrength;   // Bloom blend strength [0.0 - 1.0]
uniform float uGIStrength;      // GI blend strength [0.0 - 1.0]
uniform sampler2D uScene;       // Base rendered scene (pixel grid)
uniform sampler2D uGI;          // Radiance Cascades GI result
uniform sampler2D uBloom;       // Final bloom texture

out vec4 fragColor;

// ACES filmic tone mapping curve (fitted approximation by Krzysztof Narkowicz).
vec3 acesTonemap(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution;

    // Sample all input textures.
    vec3 scene = texture(uScene, uv).rgb;
    vec3 gi = texture(uGI, uv).rgb;
    vec3 bloom = texture(uBloom, uv).rgb;

    // Composite GI onto scene using multiplicative blend.
    // GI modulates the scene as indirect illumination, not additive light.
    // Ambient provides base visibility; GI adds on top of that.
    float ambient = mix(0.3, 0.05, uDayNightT); // Day: 0.3, Night: 0.05
    vec3 lit = scene * (ambient + gi.rgb * uGIStrength);

    // Add bloom.
    lit += bloom * uBloomStrength;

    // Apply exposure.
    lit *= uExposure;

    // Day/night color grading before tone mapping.
    // Night: shift toward cool blue tones, reduce saturation slightly.
    // Day: warm, natural colors.
    vec3 nightTint = vec3(0.7, 0.8, 1.2);       // Cool blue shift
    vec3 dayTint = vec3(1.0, 1.0, 1.0);          // Neutral
    vec3 tint = mix(dayTint, nightTint, uDayNightT);
    lit *= tint;

    // Night: slightly reduce overall brightness and increase contrast.
    float nightDarken = mix(1.0, 0.75, uDayNightT);
    lit *= nightDarken;

    // ACES filmic tone mapping.
    vec3 mapped = acesTonemap(lit);

    // Night: subtle desaturation for moonlit look.
    float luma = dot(mapped, vec3(0.2126, 0.7152, 0.0722));
    float desatAmount = uDayNightT * 0.15;
    mapped = mix(mapped, vec3(luma), desatAmount);

    fragColor = vec4(mapped, 1.0);
}
