#!/usr/bin/env python3
"""
Visual Ground Truth Oracle
============================

Generates expected visual properties using colour-science and scikit-image
reference calculations. Output is JSON consumed by test_visuals.py for
comparison against our pixel renderer's actual output.

Run:
    pip install -r research/requirements.txt
    python research/visual_oracle.py

Output:
    research/visual_ground_truth.json
"""

import json
import numpy as np
from skimage.color import rgb2lab
import colour

# =============================================================================
# Element base colors (from element_registry.dart, 0xAARRGGBB format)
# =============================================================================

ELEMENT_COLORS = {
    "sand":      (0xFF, 0xD9, 0xC3, 0x90),
    "water":     (0xFF, 0x2E, 0x9A, 0xFF),
    "fire":      (0xFF, 0xFF, 0x88, 0x20),
    "stone":     (0xFF, 0x80, 0x80, 0x90),
    "dirt":      (0xFF, 0x8C, 0x68, 0x30),
    "lava":      (0xFF, 0xFF, 0x50, 0x10),
    "ice":       (0xFF, 0xBD, 0xE5, 0xFF),
    "wood":      (0xFF, 0xA0, 0x55, 0x30),
    "metal":     (0xFF, 0xA8, 0xA8, 0xB8),
    "oil":       (0xFF, 0x3A, 0x28, 0x20),
    "acid":      (0xFF, 0x30, 0xF0, 0x30),
    "glass":     (0xCC, 0xDD, 0xE8, 0xFF),
    "mud":       (0xFF, 0x7A, 0x50, 0x30),
    "snow":      (0xFF, 0xF0, 0xF4, 0xFF),
    "plant":     (0xFF, 0x28, 0xB0, 0x40),
    "smoke":     (0xB0, 0x9A, 0x9A, 0xA0),
    "steam":     (0x30, 0xC8, 0xD0, 0xE0),
    "ash":       (0xDD, 0xB0, 0xB0, 0xB8),
    "seed":      (0xFF, 0x8B, 0x73, 0x55),
    "tnt":       (0xFF, 0xCC, 0x22, 0x22),
    "rainbow":   (0xFF, 0xFF, 0x00, 0xFF),
    "bubble":    (0xA0, 0xC8, 0xE8, 0xFF),
    "lightning": (0xFF, 0xFF, 0xFF, 0xA0),
    "ant":       (0xFF, 0x22, 0x22, 0x22),
}

# =============================================================================
# Light emission properties (from element_registry.dart ElementProperties)
# =============================================================================

LIGHT_EMISSION = {
    "fire":      {"intensity": 180, "r": 255, "g": 120, "b": 20},
    "lava":      {"intensity": 220, "r": 255, "g": 80,  "b": 10},
    "lightning": {"intensity": 255, "r": 255, "g": 255, "b": 180},
    "rainbow":   {"intensity": 100, "r": 200, "g": 100, "b": 255},
    "acid":      {"intensity": 30,  "r": 20,  "g": 255, "b": 20},
}


def generate_visual_truth():
    """Generate all visual ground truth data."""
    results = {}

    # -----------------------------------------------------------------
    # 1. CIE LAB colors for each element
    # -----------------------------------------------------------------
    lab_colors = {}
    for name, (a, r, g, b) in ELEMENT_COLORS.items():
        rgb_normalized = np.array([[[r / 255.0, g / 255.0, b / 255.0]]])
        lab = rgb2lab(rgb_normalized)[0, 0]
        lab_colors[name] = {
            "L": round(float(lab[0]), 2),
            "a": round(float(lab[1]), 2),
            "b": round(float(lab[2]), 2),
        }
    results["element_lab_colors"] = lab_colors

    # -----------------------------------------------------------------
    # 2. Delta E matrix -- perceptual distance between all pairs
    # -----------------------------------------------------------------
    delta_e_matrix = {}
    names = list(lab_colors.keys())
    for i, n1 in enumerate(names):
        for n2 in names[i + 1 :]:
            lab1 = np.array(
                [lab_colors[n1]["L"], lab_colors[n1]["a"], lab_colors[n1]["b"]]
            )
            lab2 = np.array(
                [lab_colors[n2]["L"], lab_colors[n2]["a"], lab_colors[n2]["b"]]
            )
            de = float(colour.delta_E(lab1, lab2, method="CIE 2000"))
            delta_e_matrix[f"{n1}_{n2}"] = round(de, 2)
    results["delta_e_pairs"] = delta_e_matrix
    results["min_delta_e_threshold"] = 5.0  # perceptually distinguishable

    # -----------------------------------------------------------------
    # 3. Expected texture entropy ranges per element type
    # -----------------------------------------------------------------
    results["texture_entropy"] = {
        "sand":  {"min": 1.5, "max": 6.5, "desc": "grainy, moderate variation"},
        "water": {"min": 0.5, "max": 6.5, "desc": "smooth with shimmer"},
        "stone": {"min": 1.5, "max": 12.0, "desc": "layered strata with depth variation"},
        "dirt":  {"min": 1.5, "max": 9.0, "desc": "organic texture with depth variation"},
        "lava":  {"min": 2.0, "max": 6.5, "desc": "dynamic, pulsing"},
        "fire":  {"min": 2.0, "max": 6.5, "desc": "highly dynamic"},
        "ice":   {"min": 0.5, "max": 4.5, "desc": "crystalline, sparkle"},
        "snow":  {"min": 0.3, "max": 4.0, "desc": "uniform with glitter"},
        "metal": {"min": 0.5, "max": 4.5, "desc": "smooth sheen"},
        "wood":  {"min": 1.5, "max": 6.5, "desc": "grain texture"},
        "oil":   {"min": 1.0, "max": 6.5, "desc": "iridescent"},
        "glass": {"min": 0.3, "max": 3.5, "desc": "nearly transparent"},
    }

    # -----------------------------------------------------------------
    # 4. Sky color gradient expectations
    # -----------------------------------------------------------------
    results["sky_gradient"] = {
        "top_L_range": [55, 75],
        "bottom_L_range": [60, 85],
        "max_second_derivative": 25,
        "night_top_L_range": [5, 25],
    }

    # -----------------------------------------------------------------
    # 5. Underground brightness constraints
    # -----------------------------------------------------------------
    results["underground"] = {
        "max_avg_brightness": 120,
        "max_brightness_std": 40,
    }

    # -----------------------------------------------------------------
    # 6. Steam/smoke alpha constraints
    # -----------------------------------------------------------------
    results["transparency"] = {
        "steam":  {"max_alpha": 80,  "min_alpha": 5},
        "smoke":  {"max_alpha": 210, "min_alpha": 30},
        "glass":  {"max_alpha": 220, "min_alpha": 120},
        "bubble": {"max_alpha": 180, "min_alpha": 60},
    }

    # -----------------------------------------------------------------
    # 7. Glow falloff expectations
    # -----------------------------------------------------------------
    results["glow"] = {
        "max_radius": 6,
        "falloff_type": "quadratic",
        "no_black_halos": True,
    }

    # -----------------------------------------------------------------
    # 8. Water depth gradient
    # -----------------------------------------------------------------
    results["water_depth"] = {
        "surface_brightness_min": 120,
        "deep_brightness_max": 80,
        "gradient_direction": "darker_with_depth",
    }

    # -----------------------------------------------------------------
    # 9. Contrast ratios (WCAG-inspired)
    # -----------------------------------------------------------------
    results["contrast"] = {
        "min_contrast_ratio": 1.3,
        "critical_pairs": [
            ["fire", "lava"],
            ["sand", "dirt"],
            ["stone", "metal"],
            ["smoke", "steam"],
        ],
    }

    # Known similar pairs -- elements intentionally close in appearance
    # (e.g. ice/bubble are both translucent blue-white, metal/ash both gray)
    results["known_similar_pairs"] = [
        "ice_bubble",
        "metal_ash",
    ]

    # -----------------------------------------------------------------
    # 10. Light emission data
    # -----------------------------------------------------------------
    results["light_emission"] = LIGHT_EMISSION

    # -----------------------------------------------------------------
    # 11. Alpha values from base colors (for transparency tests)
    # -----------------------------------------------------------------
    results["base_alphas"] = {
        name: a for name, (a, r, g, b) in ELEMENT_COLORS.items()
    }

    # -----------------------------------------------------------------
    # 12. RGB base colors (for color drift tests)
    # -----------------------------------------------------------------
    results["base_rgb"] = {
        name: {"r": r, "g": g, "b": b}
        for name, (a, r, g, b) in ELEMENT_COLORS.items()
    }

    # -----------------------------------------------------------------
    # 13. Underground advanced (cave proximity lighting)
    # -----------------------------------------------------------------
    results["underground_advanced"] = {
        "near_opening_min_brightness": 30,
        "deep_cave_max_brightness": 45,
        "min_brightness_std": 2,
        "rock_tint_near_dirt_r_boost": 3,
        "moisture_near_water_b_boost": 4,
    }

    # -----------------------------------------------------------------
    # 14. Sky advanced (atmospheric rendering)
    # -----------------------------------------------------------------
    results["sky_advanced"] = {
        "top_10pct_b_minus_r_min": 40,
        "horizon_warmer_than_zenith": True,
        "min_inflection_points": 1,
    }

    # -----------------------------------------------------------------
    # 15. Texture detail (micro-variation within elements)
    # -----------------------------------------------------------------
    results["texture_detail"] = {
        "fire_r_std_min": 20,
        "water_caustic_std_min": 3,
        "stone_strata_brightness_diff_min": 3,
        "lava_brightness_std_min": 5,
    }

    # -----------------------------------------------------------------
    # 16. Micro particles (spark / ember overlay effects)
    # -----------------------------------------------------------------
    results["micro_particles"] = {
        "fire_spark_brightness_threshold": 200,
        "lava_ember_brightness_threshold": 180,
    }

    return results


if __name__ == "__main__":
    truth = generate_visual_truth()
    with open("research/visual_ground_truth.json", "w") as f:
        json.dump(truth, f, indent=2)
    print(f"Generated visual ground truth with {len(truth)} categories")
    for key in truth:
        if isinstance(truth[key], dict):
            print(f"  {key}: {len(truth[key])} entries")
        else:
            print(f"  {key}: {truth[key]}")
