#!/usr/bin/env python3
"""Vertex AI (Gemini) Art Director for Particle Engine.

Takes the best output from the CLIP-based Style Evolver,
analyzes the image visually, and produces a highly-refined
color palette JSON using Google's Gemini 2.5 Pro.
"""

import json
import os
import sys
from pathlib import Path
from PIL import Image

try:
    from google import genai
    from google.genai import types
except ImportError:
    print("Error: google-genai library is required.")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "style_results"

PROMPT = """You are an expert Art Director for a 2D pixel-art sandbox falling-sand game.
We use a custom color palette for our elements, glow radii for emissive materials, and sky gradients.

Attached is a screenshot (best_render.png) of the CURRENT best palette from our evolutionary algorithm.
Also attached is the JSON configuration that generated it.

Your job is to CRITIQUE this image and IMPROVE the JSON configuration.

Goals:
1. Improve contrast and readability (elements shouldn't blend together in a muddy way).
2. Make emissive elements (lava, fire, lightning, acid) pop. Adjust their glow intensity or colors.
3. Make the sky gradient complement the ground scene.
4. Ensure colors match the material (water should look like water, sand like sand, dirt like dirt).

CRITICAL: Return ONLY valid JSON matching the exact schema of the input JSON (containing "palette", "glow", "sky" keys). No markdown blocks, no conversational text.
"""

def main():
    print("=== Starting Vertex AI Art Director ===")
    
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("Error: GEMINI_API_KEY environment variable is not set.")
        sys.exit(1)
        
    client = genai.Client(api_key=api_key)
    
    img_path = RESULTS_DIR / "best_render.png"
    json_path = RESULTS_DIR / "best_palette.json"
    out_path = RESULTS_DIR / "director_palette.json"
    
    if not img_path.exists() or not json_path.exists():
        print(f"Error: Missing inputs. Need {img_path.name} and {json_path.name}")
        sys.exit(1)
        
    print("Loading current palette and render...")
    with open(json_path, "r") as f:
        current_palette_text = f.read()
        
    img = Image.open(img_path)
    
    print("Uploading to Gemini 2.5 Pro for critique...")
    
    # We ask the model to act as the art director and output JSON
    response = client.models.generate_content(
        model='gemini-2.5-pro',
        contents=[
            PROMPT,
            "CURRENT CONFIGURATION JSON:\n" + current_palette_text,
            img
        ],
        config=types.GenerateContentConfig(
            temperature=0.4,
            response_mime_type="application/json"
        )
    )
    
    result_text = response.text.strip()
    
    # Clean up if the model still returns markdown despite instructions
    if result_text.startswith("```json"):
        result_text = result_text[7:]
    if result_text.endswith("```"):
        result_text = result_text[:-3]
        
    print("Critique complete. Parsing new palette...")
    try:
        new_palette = json.loads(result_text)
        with open(out_path, "w") as f:
            json.dump(new_palette, f, indent=2)
        print(f"Success! Art Director's refined palette saved to {out_path}")
    except Exception as e:
        print(f"Failed to parse JSON from model: {e}")
        print("Raw output:")
        print(result_text)
        sys.exit(1)

if __name__ == "__main__":
    main()
