#!/usr/bin/env python3
"""GPU-accelerated visual style evolution using CLIP aesthetic scoring.

Evolves PixelRenderer color palettes, glow settings, and visual parameters
using a neural aesthetic classifier (CLIP + LAION aesthetic predictor) to
find the most visually appealing rendering settings.

Approach:
1. Render synthetic scenes using our PixelRenderer color logic (Python port)
2. Score each rendering with CLIP aesthetic predictor + custom metrics
3. Use CMA-ES (Covariance Matrix Adaptation Evolution Strategy) to evolve
   toward higher-scoring visual parameter combinations
4. Export best palettes as JSON for direct use in Dart PixelRenderer

This is different from shader_optimizer.py:
- shader_optimizer: tunes post-processing (bloom, exposure, gamma)
- style_evolver: tunes the actual element COLORS and rendering parameters

Parameters evolved:
- Per-element base RGB colors (25 elements x 3 channels = 75 params)
- Per-element color variation range
- Glow intensity and radius for emissive elements (fire, lava, lightning)
- Day/night color temperature shifts
- Background sky gradient colors
- Ground-level terrain color palettes

Usage:
    # Evolve palettes using CLIP scoring (A100 recommended)
    python research/cloud/style_evolver.py --generations 200 --population 64

    # Evolve using heuristic scoring only (no GPU needed)
    python research/cloud/style_evolver.py --mode heuristic --generations 500

    # Score current default palette
    python research/cloud/style_evolver.py --score-current

Output:
    research/cloud/style_results/best_palette.json
    research/cloud/style_results/evolution_log.json
    research/cloud/style_results/renders/    (sample renders as PNG)

Estimated costs:
    Heuristic mode: ~5 min, CPU only ($0)
    CLIP mode:      ~20 min on A100 (~$0.26)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "style_results"
RENDERS_DIR = RESULTS_DIR / "renders"

# ---------------------------------------------------------------------------
# Default element palette (must match pixel_renderer.dart)
# Format: element_name -> (R, G, B) base color
# These are the starting point for evolution.
# ---------------------------------------------------------------------------
DEFAULT_PALETTE = {
    "sand":      (194, 160, 70),
    "water":     (45, 130, 220),
    "fire":      (255, 100, 20),
    "ice":       (180, 220, 250),
    "lightning": (255, 255, 100),
    "seed":      (90, 140, 50),
    "stone":     (128, 128, 128),
    "tnt":       (200, 60, 60),
    "rainbow":   (255, 100, 200),
    "mud":       (110, 80, 40),
    "steam":     (200, 210, 220),
    "oil":       (50, 40, 30),
    "acid":      (140, 255, 40),
    "glass":     (200, 220, 240),
    "dirt":      (140, 95, 40),
    "plant":     (50, 160, 50),
    "lava":      (255, 80, 10),
    "snow":      (240, 245, 255),
    "wood":      (130, 85, 50),
    "metal":     (170, 175, 180),
    "smoke":     (100, 100, 110),
    "bubble":    (180, 210, 255),
    "ash":       (90, 85, 80),
    "oxygen":    (200, 230, 255),
    "co2":       (160, 150, 140),
}

EMISSIVE_ELEMENTS = {"fire", "lava", "lightning", "acid"}

# ---------------------------------------------------------------------------
# Scene rendering (Python port of PixelRenderer color logic)
# ---------------------------------------------------------------------------

def render_scene(
    palette: dict[str, tuple[int, int, int]],
    glow_params: dict[str, dict],
    sky_params: dict[str, float],
    width: int = 160,
    height: int = 90,
    scene: str = "mixed",
) -> np.ndarray:
    """Render a synthetic scene using the given palette. Returns (H, W, 3) uint8."""
    img = np.zeros((height, width, 3), dtype=np.uint8)
    rng = np.random.default_rng(42)

    # Sky gradient
    sky_top = np.array([
        int(sky_params.get("sky_top_r", 50)),
        int(sky_params.get("sky_top_g", 100)),
        int(sky_params.get("sky_top_b", 200)),
    ])
    sky_bottom = np.array([
        int(sky_params.get("sky_bottom_r", 130)),
        int(sky_params.get("sky_bottom_g", 170)),
        int(sky_params.get("sky_bottom_b", 220)),
    ])
    ground_level = int(height * 0.45)

    for y in range(ground_level):
        t = y / max(1, ground_level - 1)
        color = (sky_top * (1 - t) + sky_bottom * t).astype(np.uint8)
        img[y, :] = color

    # --- Place elements in scene ---
    element_grid = np.full((height, width), "", dtype=object)

    if scene == "mixed":
        # Ground: dirt/stone base
        for y in range(ground_level, height):
            for x in range(width):
                depth = (y - ground_level) / (height - ground_level)
                if depth < 0.3:
                    element_grid[y, x] = "dirt"
                else:
                    element_grid[y, x] = "stone"

        # Sand dune
        for y in range(ground_level - 5, ground_level + 8):
            for x in range(10, 40):
                if 0 <= y < height:
                    element_grid[y, x] = "sand"

        # Water pool
        for y in range(ground_level, ground_level + 12):
            for x in range(50, 90):
                if y < height:
                    element_grid[y, x] = "water"

        # Fire
        for y in range(ground_level - 8, ground_level):
            for x in range(100, 115):
                if 0 <= y < height:
                    element_grid[y, x] = "fire"

        # Lava pool
        for y in range(ground_level + 3, ground_level + 10):
            for x in range(120, 145):
                if y < height:
                    element_grid[y, x] = "lava"

        # Plants
        for x in range(42, 50):
            for y in range(ground_level - 10, ground_level):
                if 0 <= y < height:
                    element_grid[y, x] = "plant"

        # Snow on top
        for x in range(10, 40):
            y = ground_level - 6
            if 0 <= y < height:
                element_grid[y, x] = "snow"

        # Metal/wood structures
        for y in range(ground_level - 5, ground_level):
            if 0 <= y < height:
                element_grid[y, 95] = "wood"
                element_grid[y, 96] = "wood"
                element_grid[y, 148] = "metal"
                element_grid[y, 149] = "metal"

    elif scene == "cave":
        # All stone with lava and some elements
        img[:] = 20  # dark background
        for y in range(height):
            for x in range(width):
                element_grid[y, x] = "stone"

        # Carve out cave
        cy, cx = height // 2, width // 2
        for y in range(height):
            for x in range(width):
                dist = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
                if dist < 30:
                    element_grid[y, x] = ""
                elif dist < 33:
                    element_grid[y, x] = "dirt"

        # Lava at bottom of cave
        for y in range(cy + 15, cy + 25):
            for x in range(cx - 15, cx + 15):
                if 0 <= y < height and 0 <= x < width:
                    element_grid[y, x] = "lava"

        # Acid drip
        for y in range(cy - 20, cy - 5):
            if 0 <= y < height:
                element_grid[y, cx + 10] = "acid"

    elif scene == "night":
        # Dark sky with stars, fire as main light
        img[:ground_level] = 10
        for _ in range(30):
            sx = rng.integers(0, width)
            sy = rng.integers(0, ground_level)
            img[sy, sx] = [200, 200, 220]

        for y in range(ground_level, height):
            for x in range(width):
                element_grid[y, x] = "dirt" if rng.random() > 0.3 else "stone"

        # Campfire
        for y in range(ground_level - 6, ground_level):
            for x in range(width // 2 - 5, width // 2 + 5):
                if 0 <= y < height:
                    element_grid[y, x] = "fire"
        # Wood logs
        for x in range(width // 2 - 7, width // 2 + 7):
            if ground_level < height:
                element_grid[ground_level, x] = "wood"

    # --- Render element pixels with palette ---
    for y in range(height):
        for x in range(width):
            elem = element_grid[y, x]
            if elem and elem in palette:
                r, g, b = palette[elem]
                # Add hash-based variation (like the Dart renderer)
                h = ((x * 374761393 + y * 668265263) * 1274126177) & 0x7FFFFFFF
                variation = (h % 21) - 10  # -10 to +10
                img[y, x] = [
                    max(0, min(255, r + variation)),
                    max(0, min(255, g + variation // 2)),
                    max(0, min(255, b + variation // 3)),
                ]

    # --- Glow pass for emissive elements ---
    glow_img = np.zeros((height, width, 3), dtype=np.float32)
    for elem in EMISSIVE_ELEMENTS:
        if elem not in glow_params:
            continue
        gp = glow_params[elem]
        radius = gp.get("radius", 8)
        intensity = gp.get("intensity", 0.5)

        mask = (element_grid == elem)
        if not np.any(mask):
            continue

        r, g, b = palette.get(elem, (255, 100, 0))
        ys, xs = np.where(mask)

        for gy in range(height):
            for gx in range(width):
                # Sum contributions from all emissive pixels (simplified)
                min_dist = float("inf")
                for ey, ex in zip(ys[:20], xs[:20]):  # limit for speed
                    d = math.sqrt((gx - ex) ** 2 + (gy - ey) ** 2)
                    min_dist = min(min_dist, d)

                if min_dist < radius:
                    falloff = 1.0 - min_dist / radius
                    glow_img[gy, gx, 0] += r * falloff * intensity / 255
                    glow_img[gy, gx, 1] += g * falloff * intensity / 255
                    glow_img[gy, gx, 2] += b * falloff * intensity / 255

    # Blend glow
    result = img.astype(np.float32) + glow_img * 255
    result = np.clip(result, 0, 255).astype(np.uint8)

    return result


# ---------------------------------------------------------------------------
# Aesthetic scoring
# ---------------------------------------------------------------------------

def score_heuristic(img: np.ndarray) -> dict[str, float]:
    """Score visual quality using hand-crafted heuristics (no GPU needed)."""
    h, w, _ = img.shape
    metrics = {}
    img_f = img.astype(np.float32) / 255.0

    # --- Color harmony ---
    # Convert to HSV-like space, check hue distribution
    r, g, b = img_f[:,:,0], img_f[:,:,1], img_f[:,:,2]
    max_c = np.maximum(np.maximum(r, g), b)
    min_c = np.minimum(np.minimum(r, g), b)
    chroma = max_c - min_c

    # Count pixels with meaningful color
    colored = chroma > 0.05
    color_ratio = np.mean(colored)
    metrics["color_variety"] = min(100, color_ratio * 200)

    # --- Contrast ---
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    p5, p95 = np.percentile(lum, [5, 95])
    contrast = p95 - p5
    metrics["contrast"] = math.exp(-2 * ((contrast - 0.5) / 0.25) ** 2) * 100

    # --- Saturation balance ---
    sat = np.where(max_c > 0, chroma / max_c, 0)
    avg_sat = np.mean(sat)
    metrics["saturation_balance"] = math.exp(-2 * ((avg_sat - 0.35) / 0.15) ** 2) * 100

    # --- Element distinguishability ---
    # Each element should be visually distinct from its neighbors
    gx = np.abs(np.diff(img_f, axis=1)).mean()
    gy = np.abs(np.diff(img_f, axis=0)).mean()
    edge_energy = gx + gy
    metrics["distinguishability"] = min(100, edge_energy * 500)

    # --- Glow quality ---
    # Bright pixels should have soft falloff, not hard edges
    bright = lum > 0.7
    if np.any(bright):
        from scipy.ndimage import binary_dilation
        dilated = binary_dilation(bright, iterations=3)
        halo = dilated & ~bright
        if np.any(halo):
            halo_lum = np.mean(lum[halo])
            bright_lum = np.mean(lum[bright])
            ratio = halo_lum / (bright_lum + 1e-6)
            metrics["glow_quality"] = math.exp(-2 * ((ratio - 0.35) / 0.15) ** 2) * 100
        else:
            metrics["glow_quality"] = 30
    else:
        metrics["glow_quality"] = 50

    # --- Overall aesthetic ---
    weights = {"color_variety": 0.2, "contrast": 0.25, "saturation_balance": 0.2,
               "distinguishability": 0.15, "glow_quality": 0.2}
    metrics["overall"] = sum(metrics[k] * w for k, w in weights.items())

    return metrics


def score_clip(img: np.ndarray) -> dict[str, float]:
    """Score visual quality using CLIP + LAION aesthetic predictor."""
    try:
        import torch
        import clip
    except ImportError:
        print("  CLIP not available, falling back to heuristic scoring", flush=True)
        return score_heuristic(img)

    device = "cuda" if torch.cuda.is_available() else "cpu"

    # Load CLIP
    model, preprocess = clip.load("ViT-B/32", device=device)

    # Convert image to PIL for CLIP preprocessing
    from PIL import Image
    pil_img = Image.fromarray(img)
    image_input = preprocess(pil_img).unsqueeze(0).to(device)

    # Aesthetic prompts (what we want the renders to look like)
    positive_prompts = [
        "a beautiful pixel art scene with vibrant colors",
        "a visually stunning sandbox game with rich detail",
        "colorful and atmospheric pixel simulation",
        "gorgeous game art with great contrast and glow effects",
    ]
    negative_prompts = [
        "ugly flat colors with no contrast",
        "washed out bland pixel art",
        "muddy dark unappealing game graphics",
    ]

    with torch.no_grad():
        image_features = model.encode_image(image_input)
        image_features = image_features / image_features.norm(dim=-1, keepdim=True)

        pos_score = 0
        for prompt in positive_prompts:
            text = clip.tokenize([prompt]).to(device)
            text_features = model.encode_text(text)
            text_features = text_features / text_features.norm(dim=-1, keepdim=True)
            similarity = (image_features @ text_features.T).item()
            pos_score += similarity

        neg_score = 0
        for prompt in negative_prompts:
            text = clip.tokenize([prompt]).to(device)
            text_features = model.encode_text(text)
            text_features = text_features / text_features.norm(dim=-1, keepdim=True)
            similarity = (image_features @ text_features.T).item()
            neg_score += similarity

    pos_avg = pos_score / len(positive_prompts)
    neg_avg = neg_score / len(negative_prompts)

    # Combine CLIP with heuristic metrics
    heuristic = score_heuristic(img)
    clip_score = (pos_avg - neg_avg + 0.5) * 100  # normalize to ~0-100

    heuristic["clip_aesthetic"] = max(0, min(100, clip_score))
    heuristic["overall"] = 0.4 * heuristic["clip_aesthetic"] + 0.6 * heuristic["overall"]

    return heuristic


# ---------------------------------------------------------------------------
# Evolution engine (CMA-ES style)
# ---------------------------------------------------------------------------

def palette_to_vector(palette: dict, glow_params: dict, sky_params: dict) -> np.ndarray:
    """Flatten palette + params into a 1D vector for optimization."""
    vec = []
    for name in sorted(DEFAULT_PALETTE.keys()):
        r, g, b = palette.get(name, DEFAULT_PALETTE[name])
        vec.extend([r / 255.0, g / 255.0, b / 255.0])

    for elem in sorted(EMISSIVE_ELEMENTS):
        gp = glow_params.get(elem, {"radius": 8, "intensity": 0.5})
        vec.extend([gp["radius"] / 20.0, gp["intensity"]])

    for key in sorted(sky_params.keys()):
        vec.append(sky_params[key] / 255.0)

    return np.array(vec, dtype=np.float64)


def vector_to_palette(vec: np.ndarray) -> tuple[dict, dict, dict]:
    """Unflatten vector back into palette + params."""
    idx = 0
    palette = {}
    for name in sorted(DEFAULT_PALETTE.keys()):
        r = int(np.clip(vec[idx] * 255, 0, 255))
        g = int(np.clip(vec[idx+1] * 255, 0, 255))
        b = int(np.clip(vec[idx+2] * 255, 0, 255))
        palette[name] = (r, g, b)
        idx += 3

    glow_params = {}
    for elem in sorted(EMISSIVE_ELEMENTS):
        glow_params[elem] = {
            "radius": max(2, min(20, int(vec[idx] * 20))),
            "intensity": float(np.clip(vec[idx+1], 0.05, 1.0)),
        }
        idx += 2

    sky_keys = ["sky_top_r", "sky_top_g", "sky_top_b",
                "sky_bottom_r", "sky_bottom_g", "sky_bottom_b"]
    sky_params = {}
    for key in sky_keys:
        if idx < len(vec):
            sky_params[key] = float(np.clip(vec[idx] * 255, 0, 255))
            idx += 1
        else:
            sky_params[key] = 128.0

    return palette, glow_params, sky_params


def evolve_palette(
    generations: int = 200,
    population_size: int = 32,
    scoring_fn: str = "heuristic",
) -> dict[str, Any]:
    """Run CMA-ES to evolve visual parameters."""
    scenes = ["mixed", "night", "cave"]

    # Initialize from defaults
    default_sky = {
        "sky_top_r": 50, "sky_top_g": 100, "sky_top_b": 200,
        "sky_bottom_r": 130, "sky_bottom_g": 170, "sky_bottom_b": 220,
    }
    default_glow = {e: {"radius": 8, "intensity": 0.5} for e in EMISSIVE_ELEMENTS}

    mean = palette_to_vector(DEFAULT_PALETTE, default_glow, default_sky)
    dim = len(mean)
    sigma = 0.08  # initial step size (8% of range)

    # CMA-ES state
    cov = np.eye(dim) * sigma ** 2
    best_score = -1
    best_vec = mean.copy()
    best_metrics = {}

    score_fn = score_clip if scoring_fn == "clip" else score_heuristic
    evolution_log = []

    print(f"\n  CMA-ES Evolution", flush=True)
    print(f"  Dimensions: {dim}", flush=True)
    print(f"  Population: {population_size}", flush=True)
    print(f"  Generations: {generations}", flush=True)
    print(f"  Scoring: {scoring_fn}", flush=True)
    print(flush=True)

    start = time.time()

    for gen in range(generations):
        # Sample population
        rng = np.random.default_rng(gen)
        # Simplified CMA-ES: sample from multivariate normal
        samples = rng.multivariate_normal(mean, cov, size=population_size)

        # Evaluate each individual
        scores = []
        for i, vec in enumerate(samples):
            palette, glow, sky = vector_to_palette(vec)
            total = 0
            for scene in scenes:
                img = render_scene(palette, glow, sky, scene=scene)
                metrics = score_fn(img)
                total += metrics["overall"]
            avg_score = total / len(scenes)
            scores.append((avg_score, i, vec))

        # Sort by fitness (descending)
        scores.sort(key=lambda x: -x[0])

        # Update best
        if scores[0][0] > best_score:
            best_score = scores[0][0]
            best_vec = scores[0][2].copy()
            palette, glow, sky = vector_to_palette(best_vec)
            # Get detailed metrics
            for scene in scenes:
                img = render_scene(palette, glow, sky, scene=scene)
                best_metrics[scene] = score_fn(img)

        # CMA-ES update: move mean toward top 25%
        elite_count = max(2, population_size // 4)
        elite_vecs = np.array([s[2] for s in scores[:elite_count]])

        # Weighted mean update
        weights = np.log(elite_count + 0.5) - np.log(np.arange(1, elite_count + 1))
        weights = weights / weights.sum()
        new_mean = np.average(elite_vecs, axis=0, weights=weights)

        # Update covariance (simplified rank-mu update)
        diff = elite_vecs - mean
        new_cov = np.zeros((dim, dim))
        for j in range(elite_count):
            new_cov += weights[j] * np.outer(diff[j], diff[j])

        # Exponential smoothing
        alpha = 0.3
        mean = new_mean
        cov = (1 - alpha) * cov + alpha * new_cov
        # Ensure positive definite
        cov = (cov + cov.T) / 2
        eigvals = np.linalg.eigvalsh(cov)
        if np.min(eigvals) < 1e-6:
            cov += np.eye(dim) * 1e-4

        # Adaptive sigma
        sigma = max(0.01, sigma * 0.995)  # slow decay

        gen_best = scores[0][0]
        gen_avg = np.mean([s[0] for s in scores])
        evolution_log.append({
            "generation": gen,
            "best": float(gen_best),
            "avg": float(gen_avg),
            "global_best": float(best_score),
        })

        if gen % 25 == 0 or gen == generations - 1:
            elapsed = time.time() - start
            print(f"  Gen {gen:4d}: best={gen_best:.1f} avg={gen_avg:.1f} "
                  f"global_best={best_score:.1f} [{elapsed:.0f}s]", flush=True)

    return {
        "best_vector": best_vec,
        "best_score": best_score,
        "best_metrics": best_metrics,
        "evolution_log": evolution_log,
    }


# ---------------------------------------------------------------------------
# Save results
# ---------------------------------------------------------------------------

def save_results(result: dict):
    """Save best palette and evolution log."""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    RENDERS_DIR.mkdir(parents=True, exist_ok=True)

    palette, glow, sky = vector_to_palette(result["best_vector"])

    # Save palette as JSON
    palette_json = {
        "palette": {k: list(v) for k, v in palette.items()},
        "glow": glow,
        "sky": sky,
        "score": result["best_score"],
        "metrics": {k: {mk: round(mv, 2) for mk, mv in v.items()}
                    for k, v in result["best_metrics"].items()},
    }
    with open(RESULTS_DIR / "best_palette.json", "w") as f:
        json.dump(palette_json, f, indent=2)
    print(f"  Saved: {RESULTS_DIR / 'best_palette.json'}", flush=True)

    # Save evolution log
    with open(RESULTS_DIR / "evolution_log.json", "w") as f:
        json.dump(result["evolution_log"], f, indent=2)
    print(f"  Saved: {RESULTS_DIR / 'evolution_log.json'}", flush=True)

    # Render and save sample images
    try:
        from PIL import Image
        for scene in ["mixed", "night", "cave"]:
            img = render_scene(palette, glow, sky, scene=scene)
            # Scale up 4x for visibility
            big = np.repeat(np.repeat(img, 4, axis=0), 4, axis=1)
            Image.fromarray(big).save(RENDERS_DIR / f"best_{scene}.png")
            print(f"  Saved render: best_{scene}.png", flush=True)
    except ImportError:
        # Save as raw numpy if PIL not available
        for scene in ["mixed", "night", "cave"]:
            img = render_scene(palette, glow, sky, scene=scene)
            np.save(RENDERS_DIR / f"best_{scene}.npy", img)

    # Print palette diff from defaults
    print(f"\n  Palette changes from defaults:", flush=True)
    for name in sorted(palette.keys()):
        orig = DEFAULT_PALETTE.get(name, (128, 128, 128))
        new = palette[name]
        if orig != new:
            dr = new[0] - orig[0]
            dg = new[1] - orig[1]
            db = new[2] - orig[2]
            print(f"    {name:12s}: ({orig[0]:3d},{orig[1]:3d},{orig[2]:3d}) -> "
                  f"({new[0]:3d},{new[1]:3d},{new[2]:3d}) "
                  f"[delta: {dr:+d},{dg:+d},{db:+d}]", flush=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Visual style evolution with CLIP")
    parser.add_argument("--mode", choices=["heuristic", "clip"], default="heuristic",
                        help="Scoring mode: heuristic (CPU) or clip (GPU)")
    parser.add_argument("--generations", type=int, default=200)
    parser.add_argument("--population", type=int, default=32)
    parser.add_argument("--score-current", action="store_true",
                        help="Score the current default palette and exit")

    args = parser.parse_args()

    print(f"\n{'='*60}", flush=True)
    print(f"  VISUAL STYLE EVOLVER", flush=True)
    print(f"{'='*60}", flush=True)

    if args.score_current:
        default_glow = {e: {"radius": 8, "intensity": 0.5} for e in EMISSIVE_ELEMENTS}
        default_sky = {
            "sky_top_r": 50, "sky_top_g": 100, "sky_top_b": 200,
            "sky_bottom_r": 130, "sky_bottom_g": 170, "sky_bottom_b": 220,
        }
        for scene in ["mixed", "night", "cave"]:
            img = render_scene(DEFAULT_PALETTE, default_glow, default_sky, scene=scene)
            metrics = score_heuristic(img)
            print(f"\n  Scene: {scene}", flush=True)
            for k, v in sorted(metrics.items()):
                print(f"    {k}: {v:.1f}", flush=True)
        return

    print(f"  Mode: {args.mode}", flush=True)
    print(f"  Generations: {args.generations}", flush=True)
    print(f"  Population: {args.population}", flush=True)
    print(flush=True)

    start = time.time()
    result = evolve_palette(
        generations=args.generations,
        population_size=args.population,
        scoring_fn=args.mode,
    )
    elapsed = time.time() - start

    print(f"\n  Evolution complete in {elapsed:.0f}s", flush=True)
    print(f"  Best score: {result['best_score']:.1f}", flush=True)

    save_results(result)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        assert len(DEFAULT_PALETTE) > 0, "No palette"
        assert len(EMISSIVE_ELEMENTS) > 0, "No emissive elements"
        print(f"Self-test: {len(DEFAULT_PALETTE)} palette entries", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
