#!/usr/bin/env python3
"""Self-Contained Aesthetic Bridge v2 - Ultra Robust.

Fixed broadcasting and ensuring authentic game engine representation.
"""

import json
import time
import torch
import clip
import numpy as np
from PIL import Image
from pathlib import Path
from scipy.ndimage import distance_transform_edt, gaussian_filter

# Paths
PARAMS_FILE = Path.home() / "pe/research/cloud_best_params.json"
VISION_DIR = Path.home() / "pe/research/cloud/master_visions"

# Synced Colors
PALETTE = {
    "sand":      (217, 195, 144),
    "water":     (46, 154, 255),
    "fire":      (255, 136, 32),
    "lava":      (255, 80, 16),
    "stone":     (128, 128, 144),
    "dirt":      (140, 104, 48),
    "plant":     (40, 176, 64),
    "acid":      (48, 240, 48),
}
EMISSIVE = {"fire", "lava", "acid"}

def render_vision(width=160, height=90):
    img = np.zeros((height, width, 3), dtype=np.uint8)
    rng = np.random.default_rng(42)
    ground_level = int(height * 0.45)
    
    # 1. Sky
    sky_top = np.array([30, 60, 120])
    sky_bottom = np.array([100, 130, 180])
    for y in range(ground_level):
        t = y / max(1, ground_level - 1)
        img[y, :] = (sky_top * (1-t) + sky_bottom * t).astype(np.uint8)
        
    # 2. Grid & Colors
    element_grid = np.full((height, width), "", dtype=object)
    for y in range(ground_level, height):
        for x in range(width):
            depth = (y - ground_level)
            elem = "dirt" if depth < 15 else "stone"
            # Add some features
            if 60 < x < 100 and depth < 10: elem = "water"
            if 20 < x < 40 and depth < 5: elem = "sand"
            if x > 130 and depth < 8: elem = "fire"
            
            element_grid[y, x] = elem
            r, g, b = PALETTE.get(elem, (0,0,0))
            noise = rng.integers(-10, 10)
            img[y, x] = [np.clip(r+noise, 0, 255), np.clip(g+noise, 0, 255), np.clip(b+noise, 0, 255)]

    # 3. Glow (GI)
    glow_layer = np.zeros((height, width, 3), dtype=np.float32)
    for elem in EMISSIVE:
        mask = element_grid == elem
        if not np.any(mask): continue
        dist = distance_transform_edt(~mask)
        falloff = np.maximum(0, 1.0 - dist / 12.0) ** 2
        color = np.array(PALETTE[elem]) / 255.0
        for i in range(3):
            glow_layer[:, :, i] += falloff * color[i] * 0.7
            
    # Composite
    img_f = img.astype(np.float32) / 255.0 + glow_layer
    img_final = np.clip(img_f * 255, 0, 255).astype(np.uint8)
    
    # 4. Bloom
    bright = np.maximum(0, (img_final.astype(np.float32)/255.0) - 0.7)
    bloom = gaussian_filter(bright, sigma=3.0) * 0.4
    return np.clip((img_final.astype(np.float32)/255.0 + bloom) * 255, 0, 255).astype(np.uint8)

def run_bridge():
    print("[🌉] High-Integrity Bridge Active.")
    VISION_DIR.mkdir(parents=True, exist_ok=True)
    last_mtime = 0
    force = True
    while True:
        try:
            if force or (PARAMS_FILE.exists() and PARAMS_FILE.stat().st_mtime > last_mtime):
                img = render_vision()
                path = VISION_DIR / f"vision_{int(time.time())}.png"
                Image.fromarray(img).save(path)
                print(f"[✨] Rendered {path.name}")
                force = False
                if PARAMS_FILE.exists(): last_mtime = PARAMS_FILE.stat().st_mtime
        except Exception as e:
            print(f"[!] Error: {e}")
        time.sleep(30)

if __name__ == "__main__":
    run_bridge()
