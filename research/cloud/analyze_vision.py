#!/usr/bin/env python3
from PIL import Image
import numpy as np

img = Image.open("research/cloud/latest_vision.png")
data = np.array(img)

# Basic Analysis
brightness = np.mean(data)
std_dev = np.std(data) # High std dev = high contrast/vibrancy
unique_colors = len(np.unique(data.reshape(-1, data.shape[-1]), axis=0))

print(f"--- VISION ANALYSIS ---")
print(f"Brightness: {brightness:.1f}/255")
print(f"Contrast (StdDev): {std_dev:.1f}")
print(f"Unique Colors: {unique_colors}")

if std_dev > 50:
    print("Verdict: High-vibrancy, stylized render detected. Style Evolver is working!")
else:
    print("Verdict: Low-contrast detected. Engine is currently in 'Functional/Subdued' mode.")
