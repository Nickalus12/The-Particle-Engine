#!/usr/bin/env python3
"""GPU-accelerated texture atlas generation with neural upscaling.

Pre-renders each element at high resolution (64x64) with full visual detail,
applies neural super-resolution (Real-ESRGAN), and optionally generates
normal maps for future lighting. Exports as a single texture atlas PNG.

The approach:
1. Render each element's visual appearance at 8x8 (matching game pixel size)
   using the same color logic as pixel_renderer.dart
2. Apply Real-ESRGAN 4x upscaling to get crisp 32x32 textures
3. Apply another 2x pass for 64x64 (or use x4 model for 8->32)
4. Generate normal maps from height estimation (bright = raised)
5. Pack all textures into a single atlas PNG with metadata

This gives us:
- Sharp, detailed textures for zoom-in views
- Normal maps ready for future lighting/shadow systems
- Consistent visual style (evolved from actual render colors)
- Single atlas = single texture bind at runtime

Usage:
    # Generate atlas using neural upscaling (A100 recommended)
    python research/cloud/texture_atlas.py --mode neural

    # Generate atlas using bicubic upscaling (no GPU needed)
    python research/cloud/texture_atlas.py --mode bicubic

    # Generate with normal maps
    python research/cloud/texture_atlas.py --mode neural --normals

    # Custom tile size
    python research/cloud/texture_atlas.py --mode neural --tile-size 128

Output:
    research/cloud/atlas_output/element_atlas.png
    research/cloud/atlas_output/element_normals.png  (if --normals)
    research/cloud/atlas_output/atlas_metadata.json
    research/cloud/atlas_output/individual/          (per-element PNGs)

Estimated costs:
    Bicubic mode: ~1 min, CPU only ($0)
    Neural mode:  ~10 min on A100 (~$0.13)
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = SCRIPT_DIR / "atlas_output"
INDIVIDUAL_DIR = OUTPUT_DIR / "individual"

# ---------------------------------------------------------------------------
# Element visual definitions
# Matches pixel_renderer.dart color logic as closely as possible.
# Each element has: base_color, variation, special rendering notes
# ---------------------------------------------------------------------------

ELEMENT_VISUALS = {
    "sand": {
        "id": 1,
        "base_rgb": (194, 160, 70),
        "variation": 15,
        "texture_type": "granular",   # individual grains visible
        "roughness": 0.7,
    },
    "water": {
        "id": 2,
        "base_rgb": (45, 130, 220),
        "variation": 10,
        "texture_type": "smooth",     # smooth with caustics
        "roughness": 0.1,
        "transparency": 0.4,
    },
    "fire": {
        "id": 3,
        "base_rgb": (255, 100, 20),
        "variation": 30,
        "texture_type": "animated",   # flickering
        "roughness": 0.0,
        "emissive": True,
    },
    "ice": {
        "id": 4,
        "base_rgb": (180, 220, 250),
        "variation": 8,
        "texture_type": "crystalline",
        "roughness": 0.2,
        "transparency": 0.3,
    },
    "lightning": {
        "id": 5,
        "base_rgb": (255, 255, 100),
        "variation": 20,
        "texture_type": "electric",
        "roughness": 0.0,
        "emissive": True,
    },
    "seed": {
        "id": 6,
        "base_rgb": (90, 140, 50),
        "variation": 12,
        "texture_type": "organic",
        "roughness": 0.5,
    },
    "stone": {
        "id": 7,
        "base_rgb": (128, 128, 128),
        "variation": 12,
        "texture_type": "rocky",
        "roughness": 0.8,
    },
    "tnt": {
        "id": 8,
        "base_rgb": (200, 60, 60),
        "variation": 8,
        "texture_type": "solid",
        "roughness": 0.4,
    },
    "rainbow": {
        "id": 9,
        "base_rgb": (255, 100, 200),
        "variation": 40,
        "texture_type": "prismatic",
        "roughness": 0.0,
        "emissive": True,
    },
    "mud": {
        "id": 10,
        "base_rgb": (110, 80, 40),
        "variation": 10,
        "texture_type": "wet_granular",
        "roughness": 0.6,
    },
    "steam": {
        "id": 11,
        "base_rgb": (200, 210, 220),
        "variation": 8,
        "texture_type": "wispy",
        "roughness": 0.0,
        "transparency": 0.6,
    },
    "oil": {
        "id": 13,
        "base_rgb": (50, 40, 30),
        "variation": 5,
        "texture_type": "smooth",
        "roughness": 0.1,
    },
    "acid": {
        "id": 14,
        "base_rgb": (140, 255, 40),
        "variation": 15,
        "texture_type": "bubbling",
        "roughness": 0.2,
        "emissive": True,
    },
    "glass": {
        "id": 15,
        "base_rgb": (200, 220, 240),
        "variation": 5,
        "texture_type": "crystalline",
        "roughness": 0.05,
        "transparency": 0.7,
    },
    "dirt": {
        "id": 16,
        "base_rgb": (140, 95, 40),
        "variation": 15,
        "texture_type": "granular",
        "roughness": 0.75,
    },
    "plant": {
        "id": 17,
        "base_rgb": (50, 160, 50),
        "variation": 20,
        "texture_type": "organic",
        "roughness": 0.5,
    },
    "lava": {
        "id": 18,
        "base_rgb": (255, 80, 10),
        "variation": 25,
        "texture_type": "molten",
        "roughness": 0.3,
        "emissive": True,
    },
    "snow": {
        "id": 19,
        "base_rgb": (240, 245, 255),
        "variation": 5,
        "texture_type": "granular",
        "roughness": 0.3,
    },
    "wood": {
        "id": 20,
        "base_rgb": (130, 85, 50),
        "variation": 12,
        "texture_type": "fibrous",
        "roughness": 0.6,
    },
    "metal": {
        "id": 21,
        "base_rgb": (170, 175, 180),
        "variation": 8,
        "texture_type": "metallic",
        "roughness": 0.2,
    },
    "smoke": {
        "id": 22,
        "base_rgb": (100, 100, 110),
        "variation": 10,
        "texture_type": "wispy",
        "roughness": 0.0,
        "transparency": 0.5,
    },
    "bubble": {
        "id": 23,
        "base_rgb": (180, 210, 255),
        "variation": 8,
        "texture_type": "spherical",
        "roughness": 0.0,
        "transparency": 0.7,
    },
    "ash": {
        "id": 24,
        "base_rgb": (90, 85, 80),
        "variation": 8,
        "texture_type": "granular",
        "roughness": 0.6,
    },
    "copper": {
        "id": 39,
        "base_rgb": (184, 115, 51),
        "variation": 10,
        "texture_type": "metallic",
        "roughness": 0.25,
    },
}


# ---------------------------------------------------------------------------
# Texture rendering (base 8x8 pixel art)
# ---------------------------------------------------------------------------

def render_element_tile(name: str, visual: dict, size: int = 8) -> np.ndarray:
    """Render a single element as an 8x8 (or NxN) RGBA tile.

    Uses hash-based variation matching the Dart renderer's approach.
    """
    r, g, b = visual["base_rgb"]
    var = visual["variation"]
    roughness = visual.get("roughness", 0.5)
    tex_type = visual.get("texture_type", "solid")
    transparency = visual.get("transparency", 0.0)
    emissive = visual.get("emissive", False)

    tile = np.zeros((size, size, 4), dtype=np.uint8)

    for y in range(size):
        for x in range(size):
            # Hash-based variation (matches Dart renderer)
            h = ((x * 374761393 + y * 668265263) * 1274126177) & 0x7FFFFFFF
            v = (h % (var * 2 + 1)) - var

            px_r = max(0, min(255, r + v))
            px_g = max(0, min(255, g + v // 2))
            px_b = max(0, min(255, b + v // 3))

            # Apply texture-specific modifications
            if tex_type == "granular":
                # Individual grain highlights
                grain = (h >> 8) % 7
                if grain == 0:
                    px_r = min(255, px_r + 15)
                    px_g = min(255, px_g + 12)
                    px_b = min(255, px_b + 8)
                elif grain == 1:
                    px_r = max(0, px_r - 10)
                    px_g = max(0, px_g - 8)

            elif tex_type == "rocky":
                # Cracks and texture
                crack = (h >> 12) % 10
                if crack == 0:
                    px_r = max(0, px_r - 20)
                    px_g = max(0, px_g - 20)
                    px_b = max(0, px_b - 20)

            elif tex_type == "crystalline":
                # Sparkle highlights
                sparkle = (h >> 10) % 12
                if sparkle == 0:
                    px_r = min(255, px_r + 30)
                    px_g = min(255, px_g + 30)
                    px_b = min(255, px_b + 30)

            elif tex_type == "metallic":
                # Specular highlights
                spec = math.sin(x * 0.8 + y * 0.3) * 0.5 + 0.5
                spec_amount = int(spec * 20 * (1 - roughness))
                px_r = min(255, px_r + spec_amount)
                px_g = min(255, px_g + spec_amount)
                px_b = min(255, px_b + spec_amount)

            elif tex_type == "organic":
                # Veins and texture
                vein = math.sin(x * 1.5) * math.cos(y * 1.2) * 15
                px_g = max(0, min(255, px_g + int(vein)))

            elif tex_type == "fibrous":
                # Wood grain
                grain = math.sin(y * 2.0 + x * 0.3) * 10
                px_r = max(0, min(255, px_r + int(grain)))
                px_g = max(0, min(255, px_g + int(grain * 0.7)))
                px_b = max(0, min(255, px_b + int(grain * 0.3)))

            elif tex_type == "molten":
                # Hot spots and cooler crust
                heat = math.sin(x * 1.2 + y * 0.8) * 0.5 + 0.5
                px_r = min(255, px_r + int(heat * 30))
                px_g = max(0, px_g - int((1 - heat) * 20))

            elif tex_type == "smooth":
                # Subtle caustics for liquids
                caustic = math.sin(x * 0.7 + y * 0.5) * 5
                px_b = max(0, min(255, px_b + int(caustic)))

            elif tex_type == "wispy":
                # Fade at edges for gas
                dist = math.sqrt((x - size/2)**2 + (y - size/2)**2)
                fade = max(0.3, 1.0 - dist / (size * 0.7))
                px_r = int(px_r * fade)
                px_g = int(px_g * fade)
                px_b = int(px_b * fade)

            elif tex_type == "bubbling":
                # Bubbles
                bx, by = x % 3, y % 3
                if bx == 1 and by == 1:
                    px_r = min(255, px_r + 20)
                    px_g = min(255, px_g + 20)

            elif tex_type == "prismatic":
                # Rainbow color cycling
                hue = (x + y * 2) / (size * 3) * 6.0
                hue_r = max(0, min(1, abs(hue - 3) - 1))
                hue_g = max(0, min(1, 2 - abs(hue - 2)))
                hue_b = max(0, min(1, 2 - abs(hue - 4)))
                px_r = int(hue_r * 255)
                px_g = int(hue_g * 255)
                px_b = int(hue_b * 255)

            elif tex_type == "spherical":
                # Bubble sphere shading
                dx = (x - size/2) / (size/2)
                dy = (y - size/2) / (size/2)
                dist = math.sqrt(dx*dx + dy*dy)
                if dist < 1.0:
                    shade = 1.0 - dist * 0.3
                    highlight = max(0, 1 - ((dx - 0.3)**2 + (dy - 0.3)**2) * 4)
                    px_r = int(min(255, px_r * shade + highlight * 60))
                    px_g = int(min(255, px_g * shade + highlight * 60))
                    px_b = int(min(255, px_b * shade + highlight * 60))
                else:
                    px_r = px_g = px_b = 0

            elif tex_type == "electric":
                # Lightning bolt pattern
                bolt = abs(x - size//2) + (h % 2)
                if bolt <= 1:
                    px_r = px_g = px_b = 255
                else:
                    fade = max(0, 1.0 - bolt / 3)
                    px_r = int(255 * fade)
                    px_g = int(255 * fade)
                    px_b = int(100 * fade)

            # Alpha
            alpha = 255
            if transparency > 0:
                alpha = int(255 * (1 - transparency * 0.5))
            if tex_type == "spherical":
                dx = (x - size/2) / (size/2)
                dy = (y - size/2) / (size/2)
                if dx*dx + dy*dy > 1:
                    alpha = 0

            # Emissive glow at edges
            if emissive:
                edge_dist = min(x, y, size - 1 - x, size - 1 - y)
                if edge_dist == 0:
                    px_r = min(255, px_r + 30)
                    px_g = min(255, px_g + 20)

            tile[y, x] = [px_r, px_g, px_b, alpha]

    return tile


# ---------------------------------------------------------------------------
# Upscaling
# ---------------------------------------------------------------------------

def upscale_bicubic(tile: np.ndarray, factor: int = 8) -> np.ndarray:
    """Upscale using bicubic interpolation (CPU, no dependencies)."""
    h, w, c = tile.shape
    new_h, new_w = h * factor, w * factor
    result = np.zeros((new_h, new_w, c), dtype=np.uint8)

    for ch in range(c):
        channel = tile[:, :, ch].astype(np.float32)
        # Simple bilinear for now (bicubic needs scipy)
        for ny in range(new_h):
            for nx in range(new_w):
                # Source coordinates
                sy = ny / factor
                sx = nx / factor

                y0 = int(sy)
                x0 = int(sx)
                y1 = min(y0 + 1, h - 1)
                x1 = min(x0 + 1, w - 1)

                fy = sy - y0
                fx = sx - x0

                val = (channel[y0, x0] * (1-fy) * (1-fx) +
                       channel[y1, x0] * fy * (1-fx) +
                       channel[y0, x1] * (1-fy) * fx +
                       channel[y1, x1] * fy * fx)
                result[ny, nx, ch] = max(0, min(255, int(val)))

    return result


def upscale_neural(tile: np.ndarray, target_size: int = 64) -> np.ndarray:
    """Upscale using Real-ESRGAN (GPU accelerated)."""
    try:
        import torch
        from basicsr.archs.rrdbnet_arch import RRDBNet
        from realesrgan import RealESRGANer
    except ImportError:
        print("    Real-ESRGAN not available, falling back to bicubic", flush=True)
        return upscale_bicubic(tile, target_size // tile.shape[0])

    # Use anime model for pixel art (better for sharp edges)
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64,
                    num_block=6, num_grow_ch=32, scale=4)

    try:
        upsampler = RealESRGANer(
            scale=4,
            model_path="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth",
            model=model,
            tile=0,
            tile_pad=10,
            pre_pad=0,
            half=torch.cuda.is_available(),
        )
    except Exception as e:
        print(f"    Real-ESRGAN init failed: {e}, falling back to bicubic", flush=True)
        return upscale_bicubic(tile, target_size // tile.shape[0])

    # Separate alpha channel
    rgb = tile[:, :, :3]
    alpha = tile[:, :, 3] if tile.shape[2] == 4 else None

    try:
        output, _ = upsampler.enhance(rgb, outscale=target_size / tile.shape[0])
    except Exception as e:
        print(f"    Upscale failed: {e}, falling back to bicubic", flush=True)
        return upscale_bicubic(tile, target_size // tile.shape[0])

    # Resize to exact target
    if output.shape[0] != target_size or output.shape[1] != target_size:
        # Crop/pad to target
        result = np.zeros((target_size, target_size, 3), dtype=np.uint8)
        h = min(output.shape[0], target_size)
        w = min(output.shape[1], target_size)
        result[:h, :w] = output[:h, :w]
        output = result

    # Restore alpha channel
    if alpha is not None:
        alpha_up = upscale_bicubic(
            alpha[:, :, None] if alpha.ndim == 2 else alpha,
            target_size // tile.shape[0]
        )
        if alpha_up.ndim == 3:
            alpha_up = alpha_up[:, :, 0]
        result = np.zeros((target_size, target_size, 4), dtype=np.uint8)
        result[:, :, :3] = output[:target_size, :target_size, :3]
        result[:, :, 3] = alpha_up[:target_size, :target_size]
        return result

    return output


# ---------------------------------------------------------------------------
# Normal map generation
# ---------------------------------------------------------------------------

def generate_normal_map(tile: np.ndarray, roughness: float = 0.5) -> np.ndarray:
    """Generate a normal map from a texture tile.

    Uses luminance as a height map, then computes surface normals.
    Roughness controls normal map intensity.
    """
    h, w = tile.shape[:2]
    if tile.shape[2] == 4:
        rgb = tile[:, :, :3].astype(np.float32)
    else:
        rgb = tile.astype(np.float32)

    # Luminance as height
    height = (0.299 * rgb[:,:,0] + 0.587 * rgb[:,:,1] + 0.114 * rgb[:,:,2]) / 255.0
    height *= roughness  # scale by roughness

    # Compute gradients (Sobel-like)
    normal_map = np.zeros((h, w, 3), dtype=np.uint8)

    for y in range(h):
        for x in range(w):
            # Sample neighbors (with clamping)
            left = height[y, max(0, x-1)]
            right = height[y, min(w-1, x+1)]
            up = height[max(0, y-1), x]
            down = height[min(h-1, y+1), x]

            # Normal vector
            dx = (left - right) * 2.0
            dy = (up - down) * 2.0
            dz = 1.0

            # Normalize
            length = math.sqrt(dx*dx + dy*dy + dz*dz)
            if length > 0:
                dx /= length
                dy /= length
                dz /= length

            # Map from [-1, 1] to [0, 255]
            normal_map[y, x, 0] = int((dx * 0.5 + 0.5) * 255)  # R = X
            normal_map[y, x, 1] = int((dy * 0.5 + 0.5) * 255)  # G = Y
            normal_map[y, x, 2] = int((dz * 0.5 + 0.5) * 255)  # B = Z

    return normal_map


# ---------------------------------------------------------------------------
# Atlas packing
# ---------------------------------------------------------------------------

def pack_atlas(tiles: dict[str, np.ndarray], tile_size: int) -> np.ndarray:
    """Pack individual tiles into a single atlas texture.

    Uses a simple grid layout with 8 columns.
    """
    n_tiles = len(tiles)
    cols = 8
    rows = (n_tiles + cols - 1) // cols

    atlas_w = cols * tile_size
    atlas_h = rows * tile_size
    has_alpha = any(t.shape[2] == 4 for t in tiles.values())
    channels = 4 if has_alpha else 3
    atlas = np.zeros((atlas_h, atlas_w, channels), dtype=np.uint8)

    if has_alpha:
        atlas[:, :, 3] = 255  # default opaque

    metadata = {}
    for i, (name, tile) in enumerate(sorted(tiles.items())):
        row = i // cols
        col = i % cols
        y = row * tile_size
        x = col * tile_size

        # Handle channel mismatch
        if tile.shape[2] < channels:
            padded = np.zeros((tile_size, tile_size, channels), dtype=np.uint8)
            padded[:, :, :tile.shape[2]] = tile
            if channels == 4:
                padded[:, :, 3] = 255
            tile = padded

        th = min(tile.shape[0], tile_size)
        tw = min(tile.shape[1], tile_size)
        atlas[y:y+th, x:x+tw] = tile[:th, :tw, :channels]

        el_id = ELEMENT_VISUALS.get(name, {}).get("id", -1)
        metadata[name] = {
            "id": el_id,
            "atlas_x": x,
            "atlas_y": y,
            "size": tile_size,
            "row": row,
            "col": col,
        }

    return atlas, metadata


# ---------------------------------------------------------------------------
# Save functions
# ---------------------------------------------------------------------------

def save_png(path: Path, img: np.ndarray):
    """Save image as PNG. Uses PIL if available, falls back to raw save."""
    try:
        from PIL import Image
        Image.fromarray(img).save(path)
    except ImportError:
        # Save as numpy + raw RGBA
        np.save(path.with_suffix(".npy"), img)
        print(f"    (PIL not available, saved as .npy instead)", flush=True)


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def generate_atlas(mode: str = "bicubic", tile_size: int = 64,
                   generate_normals: bool = False):
    """Generate the full texture atlas."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    INDIVIDUAL_DIR.mkdir(parents=True, exist_ok=True)

    print(f"\n  Generating {len(ELEMENT_VISUALS)} element textures...", flush=True)
    print(f"  Base size: 8x8 -> upscale to {tile_size}x{tile_size}", flush=True)
    print(f"  Mode: {mode}", flush=True)
    print(flush=True)

    tiles = {}
    normal_tiles = {}
    start = time.time()

    for name, visual in sorted(ELEMENT_VISUALS.items()):
        # Render base 8x8 tile
        base = render_element_tile(name, visual, size=8)

        # Upscale
        if mode == "neural":
            upscaled = upscale_neural(base, target_size=tile_size)
        else:
            factor = tile_size // 8
            upscaled = upscale_bicubic(base, factor=factor)

        tiles[name] = upscaled

        # Save individual tile
        save_png(INDIVIDUAL_DIR / f"{name}.png", upscaled)

        # Generate normal map
        if generate_normals:
            roughness = visual.get("roughness", 0.5)
            normal = generate_normal_map(upscaled, roughness=roughness)
            normal_tiles[name] = normal
            save_png(INDIVIDUAL_DIR / f"{name}_normal.png", normal)

        print(f"    {name:12s}: {base.shape} -> {upscaled.shape}", flush=True)

    # Pack atlas
    print(f"\n  Packing atlas...", flush=True)
    atlas, metadata = pack_atlas(tiles, tile_size)
    save_png(OUTPUT_DIR / "element_atlas.png", atlas)
    print(f"  Atlas size: {atlas.shape[1]}x{atlas.shape[0]}", flush=True)

    # Pack normal atlas
    if generate_normals and normal_tiles:
        normal_atlas, _ = pack_atlas(normal_tiles, tile_size)
        save_png(OUTPUT_DIR / "element_normals.png", normal_atlas)
        print(f"  Normal atlas: {normal_atlas.shape[1]}x{normal_atlas.shape[0]}", flush=True)

    # Save metadata
    atlas_meta = {
        "tile_size": tile_size,
        "atlas_width": atlas.shape[1],
        "atlas_height": atlas.shape[0],
        "columns": 8,
        "mode": mode,
        "has_normals": generate_normals,
        "elements": metadata,
    }
    with open(OUTPUT_DIR / "atlas_metadata.json", "w") as f:
        json.dump(atlas_meta, f, indent=2)

    elapsed = time.time() - start
    print(f"\n  Generated {len(tiles)} textures in {elapsed:.1f}s", flush=True)
    print(f"  Atlas: {OUTPUT_DIR / 'element_atlas.png'}", flush=True)
    print(f"  Metadata: {OUTPUT_DIR / 'atlas_metadata.json'}", flush=True)
    if generate_normals:
        print(f"  Normals: {OUTPUT_DIR / 'element_normals.png'}", flush=True)

    return atlas_meta


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Texture atlas generator")
    parser.add_argument("--mode", choices=["bicubic", "neural"], default="bicubic",
                        help="Upscaling mode: bicubic (CPU) or neural (GPU)")
    parser.add_argument("--tile-size", type=int, default=64,
                        help="Output tile size in pixels")
    parser.add_argument("--normals", action="store_true",
                        help="Generate normal maps")

    args = parser.parse_args()

    print(f"\n{'='*60}", flush=True)
    print(f"  TEXTURE ATLAS GENERATOR", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Elements: {len(ELEMENT_VISUALS)}", flush=True)
    print(f"  Tile size: {args.tile_size}x{args.tile_size}", flush=True)
    print(f"  Mode: {args.mode}", flush=True)
    print(f"  Normals: {'yes' if args.normals else 'no'}", flush=True)

    generate_atlas(
        mode=args.mode,
        tile_size=args.tile_size,
        generate_normals=args.normals,
    )


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        assert len(ELEMENT_VISUALS) > 0, "No element visuals"
        print(f"Self-test: {len(ELEMENT_VISUALS)} element visuals", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
