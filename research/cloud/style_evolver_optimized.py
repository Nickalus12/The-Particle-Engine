#!/usr/bin/env python3
"""GPU-optimized visual style evolution using CLIP aesthetic scoring.

Refactored to pre-load CLIP models and optimize the rendering pipeline
for the A100.
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
try:
    import torch
    import clip
    from PIL import Image
    from scipy.ndimage import distance_transform_edt, gaussian_filter
    HAS_CLIP = True
except ImportError:
    HAS_CLIP = False

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "style_results"
RENDERS_DIR = RESULTS_DIR / "renders"

# ---------------------------------------------------------------------------
# Constants -- Synced with element_registry.dart and visual_oracle.py
# ---------------------------------------------------------------------------
DEFAULT_PALETTE = {
    "sand":      (217, 195, 144),
    "water":     (46, 154, 255),
    "fire":      (255, 136, 32),
    "ice":       (189, 229, 255),
    "lightning": (255, 255, 160),
    "seed":      (139, 115, 85),
    "stone":     (128, 128, 144),
    "tnt":       (204, 34, 34),
    "rainbow":   (255, 0, 255),
    "mud":       (122, 80, 48),
    "steam":     (200, 208, 224),
    "oil":       (58, 40, 32),
    "acid":      (48, 240, 48),
    "glass":     (221, 232, 255),
    "dirt":      (140, 104, 48),
    "plant":     (40, 176, 64),
    "lava":      (255, 80, 16),
    "snow":      (240, 244, 255),
    "wood":      (160, 85, 48),
    "metal":     (168, 168, 184),
    "smoke":     (154, 154, 160),
    "bubble":    (200, 232, 255),
    "ash":       (176, 176, 184),
    "oxygen":    (192, 224, 255),
    "co2":       (160, 160, 176),
}

EMISSIVE_ELEMENTS = {"fire", "lava", "lightning", "acid", "rainbow"}

# ---------------------------------------------------------------------------
# High-Fidelity Synthetic Rendering
# ---------------------------------------------------------------------------

def apply_bloom(img: np.ndarray, threshold: float = 0.8, strength: float = 0.3) -> np.ndarray:
    """Python-side approximation of Dual Kawase Bloom shader."""
    img_f = img.astype(np.float32) / 255.0
    # Extract bright parts
    bright = np.maximum(0, img_f - threshold)
    
    # Blur passes
    bloom = gaussian_filter(bright, sigma=2.0) * 0.5
    bloom += gaussian_filter(bright, sigma=4.0) * 0.3
    bloom += gaussian_filter(bright, sigma=8.0) * 0.2
    
    result = img_f + bloom * strength
    return np.clip(result * 255, 0, 255).astype(np.uint8)

def render_scene(
    palette: dict[str, tuple[int, int, int]],
    glow_params: dict[str, dict],
    sky_params: dict[str, float],
    width: int = 160,
    height: int = 90,
    scene: str = "mixed",
) -> np.ndarray:
    """Render a high-fidelity synthetic scene mimicking the game engine's look."""
    img = np.zeros((height, width, 3), dtype=np.uint8)
    rng = np.random.default_rng(42)

    # 1. Sky with Atmospheric Gradient
    sky_top = np.array([sky_params.get("sky_top_r", 50), sky_params.get("sky_top_g", 100), sky_params.get("sky_top_b", 200)])
    sky_bottom = np.array([sky_params.get("sky_bottom_r", 130), sky_params.get("sky_bottom_g", 170), sky_params.get("sky_bottom_b", 220)])
    ground_level = int(height * 0.45)

    Y, X = np.ogrid[:height, :width]
    if scene != "cave":
        t = (Y[:ground_level] / max(1, ground_level - 1))
        # Ensure t is (H, 1, 1) for broadcasting
        t_3d = t[:, :, None]
        img[:ground_level, :, :] = (sky_top[None, None, :] * (1 - t_3d) + sky_bottom[None, None, :] * t_3d).astype(np.uint8)
    else:
        img[:] = 15 # Dark cave base

    # 2. Structured Element Placement (Matching World Gen)
    element_grid = np.full((height, width), "", dtype=object)
    if scene == "mixed":
        for y in range(ground_level, height):
            depth = (y - ground_level) / (height - ground_level)
            element_grid[y, :] = "dirt" if depth < 0.25 else "stone"
        # Features
        element_grid[ground_level-4:ground_level+6, 20:50] = "sand"
        element_grid[ground_level+2:ground_level+15, 60:110] = "water"
        element_grid[ground_level-10:ground_level, 120:130] = "plant"
        element_grid[ground_level-12:ground_level, 140:155] = "fire"
        element_grid[height-15:height-5, 30:60] = "lava"
    elif scene == "cave":
        element_grid[:] = "stone"
        mask = (X-80)**2 + (Y-45)**2 < 35**2
        element_grid[mask] = ""
        element_grid[(Y > 60) & mask] = "lava"
        element_grid[(Y < 30) & mask] = "acid"
    elif scene == "night":
        img[:ground_level] = 5 # Dark night sky
        for _ in range(40): img[rng.integers(0, ground_level), rng.integers(0, width)] = 200
        element_grid[ground_level:, :] = "stone"
        element_grid[ground_level-5:ground_level, 75:85] = "fire"

    # 3. Apply Palette with Pixel-Level Noise (Entropy)
    noise = (rng.standard_normal((height, width)) * 12).astype(np.int16)
    for elem, (r, g, b) in palette.items():
        mask = element_grid == elem
        if not np.any(mask): continue
        # Explicit vectorized assignment: (N, 3) = (N, 1) + (3,)
        img[mask] = np.clip(np.array([r, g, b]) + noise[mask][:, None], 0, 255).astype(np.uint8)

    # 4. Global Illumination & Glow (Distance Field Approximation)
    glow_layer = np.zeros((height, width, 3), dtype=np.float32)
    for elem in EMISSIVE_ELEMENTS:
        mask = element_grid == elem
        if not np.any(mask): continue
        gp = glow_params.get(elem, {"radius": 10, "intensity": 0.6})
        dist = distance_transform_edt(~mask)
        falloff = np.maximum(0, 1.0 - dist / gp["radius"]) ** 2
        r, g, b = palette.get(elem, (255, 255, 255))
        for i, val in enumerate([r, g, b]):
            glow_layer[:, :, i] += falloff * (val / 255.0) * gp["intensity"]

    # Composite Glow
    img = np.clip(img.astype(np.float32) / 255.0 + glow_layer, 0, 1)
    
    # 5. Post-Processing: Bloom & Tone Mapping
    img_uint8 = (img * 255).astype(np.uint8)
    result = apply_bloom(img_uint8)
    
    return result

# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def score_heuristic(img: np.ndarray) -> dict[str, float]:
    img_f = img.astype(np.float32) / 255.0
    r, g, b = img_f[:,:,0], img_f[:,:,1], img_f[:,:,2]
    max_c = np.maximum(np.maximum(r, g), b)
    min_c = np.minimum(np.minimum(r, g), b)
    chroma = max_c - min_c
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    
    metrics = {
        "color_variety": min(100, np.mean(chroma > 0.05) * 200),
        "contrast": math.exp(-2 * ((np.percentile(lum, 95) - np.percentile(lum, 5) - 0.5) / 0.25) ** 2) * 100,
        "saturation_balance": math.exp(-2 * ((np.mean(np.where(max_c > 0, chroma / max_c, 0)) - 0.35) / 0.15) ** 2) * 100,
        "distinguishability": min(100, (np.abs(np.diff(img_f, axis=1)).mean() + np.abs(np.diff(img_f, axis=0)).mean()) * 500),
    }
    metrics["glow_quality"] = 50 # simplified
    weights = {"color_variety": 0.2, "contrast": 0.25, "saturation_balance": 0.2, "distinguishability": 0.15, "glow_quality": 0.2}
    metrics["overall"] = sum(metrics[k] * w for k, w in weights.items())
    return metrics

def score_clip_optimized(img, model, preprocess, pos_features, neg_features, device):
    pil_img = Image.fromarray(img)
    image_input = preprocess(pil_img).unsqueeze(0).to(device)
    
    with torch.no_grad():
        image_features = model.encode_image(image_input)
        image_features /= image_features.norm(dim=-1, keepdim=True)
        
        pos_sim = (image_features @ pos_features.T).mean().item()
        neg_sim = (image_features @ neg_features.T).mean().item()

    heuristic = score_heuristic(img)
    clip_score = max(0, min(100, (pos_sim - neg_sim + 0.5) * 100))
    heuristic["clip_aesthetic"] = clip_score
    heuristic["overall"] = 0.4 * clip_score + 0.6 * heuristic["overall"]
    return heuristic

# ---------------------------------------------------------------------------
# Evolution
# ---------------------------------------------------------------------------

def palette_to_vector(palette, glow_params, sky_params):
    vec = []
    for name in sorted(DEFAULT_PALETTE.keys()):
        r, g, b = palette.get(name, DEFAULT_PALETTE[name])
        vec.extend([r / 255.0, g / 255.0, b / 255.0])
    for elem in sorted(EMISSIVE_ELEMENTS):
        gp = glow_params.get(elem, {"radius": 10, "intensity": 0.6})
        vec.extend([gp["radius"] / 20.0, gp["intensity"]])
    for key in sorted(sky_params.keys()):
        vec.append(sky_params[key] / 255.0)
    return np.array(vec)

def vector_to_palette(vec):
    idx = 0
    palette = {}
    for name in sorted(DEFAULT_PALETTE.keys()):
        palette[name] = tuple(np.clip(vec[idx:idx+3] * 255, 0, 255).astype(int))
        idx += 3
    glow_params = {}
    for elem in sorted(EMISSIVE_ELEMENTS):
        glow_params[elem] = {"radius": max(2, min(20, int(vec[idx] * 20))), "intensity": float(np.clip(vec[idx+1], 0.05, 1.0))}
        idx += 2
    sky_keys = ["sky_top_r", "sky_top_g", "sky_top_b", "sky_bottom_r", "sky_bottom_g", "sky_bottom_b"]
    sky_params = {k: float(np.clip(vec[idx+i] * 255, 0, 255)) for i, k in enumerate(sky_keys)}
    return palette, glow_params, sky_params

def evolve(args):
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model, preprocess, pos_f, neg_f = None, None, None, None
    
    if args.mode == "clip":
        print(f"Loading CLIP on {device}...", flush=True)
        model, preprocess = clip.load("ViT-B/32", device=device)
        pos_prompts = ["beautiful pixel art vibrant colors", "visually stunning sandbox game detail", "colorful atmospheric pixel simulation"]
        neg_prompts = ["ugly flat colors no contrast", "washed out bland pixel art", "muddy dark unappealing graphics"]
        with torch.no_grad():
            pos_f = model.encode_text(clip.tokenize(pos_prompts).to(device))
            pos_f /= pos_f.norm(dim=-1, keepdim=True)
            neg_f = model.encode_text(clip.tokenize(neg_prompts).to(device))
            neg_f /= neg_f.norm(dim=-1, keepdim=True)

    scenes = ["mixed", "night", "cave"]
    mean = palette_to_vector(DEFAULT_PALETTE, {e: {"radius": 10, "intensity": 0.6} for e in EMISSIVE_ELEMENTS}, 
                             {"sky_top_r": 50, "sky_top_g": 100, "sky_top_b": 200, "sky_bottom_r": 130, "sky_bottom_g": 170, "sky_bottom_b": 220})
    dim = len(mean)
    cov = np.eye(dim) * (0.08 ** 2)
    best_score, best_vec = -1, mean.copy()
    
    start = time.time()
    for gen in range(args.generations):
        samples = np.random.default_rng(gen).multivariate_normal(mean, cov, size=args.population)
        scores = []
        for vec in samples:
            p, g, s = vector_to_palette(vec)
            total = 0
            for sc in scenes:
                img = render_scene(p, g, s, scene=sc)
                if args.mode == "clip":
                    total += score_clip_optimized(img, model, preprocess, pos_f, neg_f, device)["overall"]
                else:
                    total += score_heuristic(img)["overall"]
            scores.append((total / len(scenes), vec))
        
        scores.sort(key=lambda x: -x[0])
        if scores[0][0] > best_score:
            best_score, best_vec = scores[0][0], scores[0][1].copy()
            
        elite = np.array([s[1] for s in scores[:max(2, args.population//4)]])
        mean = np.mean(elite, axis=0)
        cov = np.cov(elite, rowvar=False) + np.eye(dim) * 1e-5
        
        if gen % 10 == 0:
            print(f"Gen {gen:3d}: best={scores[0][0]:.1f} global={best_score:.1f} [{time.time()-start:.0f}s]", flush=True)

    # Save logic (optimized for JSON serializability)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    p, g, s = vector_to_palette(best_vec)
    
    def cast_to_python(obj):
        if isinstance(obj, np.integer): return int(obj)
        if isinstance(obj, np.floating): return float(obj)
        if isinstance(obj, np.ndarray): return obj.tolist()
        if isinstance(obj, dict): return {k: cast_to_python(v) for k, v in obj.items()}
        if isinstance(obj, (list, tuple)): return [cast_to_python(x) for x in obj]
        return obj

    palette_data = cast_to_python({
        "palette": p,
        "glow": g,
        "sky": s,
        "score": best_score
    })
    
    with open(RESULTS_DIR / "best_palette.json", "w") as f:
        json.dump(palette_data, f, indent=2)
    print(f"Saved to {RESULTS_DIR / 'best_palette.json'}")

    # Render a final combined image of the best palette for the Art Director
    best_img = render_scene(p, g, s, scene="mixed")
    Image.fromarray(best_img).save(RESULTS_DIR / "best_render.png")
    print(f"Saved render to {RESULTS_DIR / 'best_render.png'}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["heuristic", "clip"], default="heuristic")
    parser.add_argument("--generations", type=int, default=100)
    parser.add_argument("--population", type=int, default=32)
    evolve(parser.parse_args())

if __name__ == "__main__":
    main()
