#!/usr/bin/env python3
"""GPU-accelerated procedural audio generation for The Particle Engine.

Uses neural audio synthesis (WaveGAN-style) and DSP techniques to pre-generate
element interaction sounds that ship with the game. The A100 trains a small
conditional audio model on synthetic waveforms, then generates a full sound
library covering every element and interaction type.

Approach:
1. Synthesize training data using DSP primitives (no external audio files needed)
2. Train a conditional WaveGAN to learn element-specific audio textures
3. Generate a library of .wav files covering all element interactions
4. Also produces a Dart-compatible manifest for runtime sound selection

Sound categories:
- Ambient loops: water flow, fire crackle, wind, lava bubbling, rain
- Impact sounds: sand hit, stone clank, metal clang, glass break, ice crack
- Reaction sounds: steam hiss, acid sizzle, explosion, combustion whoosh
- Movement sounds: sand shifting, water splash, gravel slide, mud squelch
- Colony sounds: ant footsteps, digging, building, communication chirps

Two modes:
1. DSP-only (fast, no GPU): generates sounds from pure math (additive synthesis,
   filtered noise, granular techniques). Good enough for prototyping.
2. Neural (A100): trains a small WaveGAN on DSP seeds, then generates smoother,
   more natural variants. Better quality but needs GPU.

Usage:
    # Generate full sound library using DSP (no GPU needed)
    python research/cloud/audio_generator.py --mode dsp

    # Train neural model and generate (A100 recommended)
    python research/cloud/audio_generator.py --mode neural --epochs 200

    # Generate specific category only
    python research/cloud/audio_generator.py --mode dsp --category impacts

Output:
    research/cloud/audio_output/sounds/     (.wav files)
    research/cloud/audio_output/manifest.json
    research/cloud/audio_output/model.pt    (trained neural model)

Estimated costs:
    DSP mode:    ~2 min, $0 (CPU only)
    Neural mode: ~30 min on A100, ~$0.39
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = SCRIPT_DIR / "audio_output"
SOUNDS_DIR = OUTPUT_DIR / "sounds"

SAMPLE_RATE = 22050  # 22kHz -- good balance of quality and file size
CHANNELS = 1         # mono (spatial mixing happens at runtime in Flame)

# ---------------------------------------------------------------------------
# Element sound profiles
# ---------------------------------------------------------------------------
# Maps each element to its characteristic sound parameters.
# These drive both DSP synthesis and neural conditioning.

SOUND_PROFILES = {
    # --- Ambient loops (1-2 second loopable) ---
    "water_flow": {
        "category": "ambient",
        "duration": 2.0,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "bandpass",
            "center_freq": 400,
            "bandwidth": 200,
            "modulation_rate": 2.0,  # gentle undulation
            "modulation_depth": 0.3,
            "amplitude": 0.4,
        },
    },
    "fire_crackle": {
        "category": "ambient",
        "duration": 2.0,
        "technique": "granular",
        "params": {
            "grain_rate": 15,       # crackles per second
            "grain_duration": 0.02,
            "freq_range": (800, 4000),
            "amplitude_variation": 0.7,
            "amplitude": 0.5,
        },
    },
    "lava_bubble": {
        "category": "ambient",
        "duration": 2.0,
        "technique": "bubble_synthesis",
        "params": {
            "bubble_rate": 3,       # bubbles per second
            "freq_range": (60, 200),
            "decay_time": 0.3,
            "amplitude": 0.6,
        },
    },
    "wind": {
        "category": "ambient",
        "duration": 2.0,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "bandpass",
            "center_freq": 250,
            "bandwidth": 150,
            "modulation_rate": 0.5,
            "modulation_depth": 0.5,
            "amplitude": 0.3,
        },
    },
    "rain": {
        "category": "ambient",
        "duration": 2.0,
        "technique": "granular",
        "params": {
            "grain_rate": 40,
            "grain_duration": 0.005,
            "freq_range": (2000, 8000),
            "amplitude_variation": 0.5,
            "amplitude": 0.3,
        },
    },
    "steam_ambient": {
        "category": "ambient",
        "duration": 1.5,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "highpass",
            "center_freq": 2000,
            "bandwidth": 3000,
            "modulation_rate": 3.0,
            "modulation_depth": 0.2,
            "amplitude": 0.35,
        },
    },

    # --- Impact sounds (short, one-shot) ---
    "sand_impact": {
        "category": "impact",
        "duration": 0.15,
        "technique": "noise_burst",
        "params": {
            "attack": 0.001,
            "decay": 0.12,
            "filter_freq": 3000,
            "filter_q": 1.0,
            "amplitude": 0.6,
        },
    },
    "stone_clank": {
        "category": "impact",
        "duration": 0.25,
        "technique": "modal_synthesis",
        "params": {
            "frequencies": [800, 1600, 2400, 3200],
            "decay_rates": [15, 20, 30, 40],
            "amplitudes": [1.0, 0.5, 0.3, 0.15],
            "amplitude": 0.7,
        },
    },
    "metal_clang": {
        "category": "impact",
        "duration": 0.5,
        "technique": "modal_synthesis",
        "params": {
            "frequencies": [440, 880, 1320, 2200, 3520],
            "decay_rates": [5, 8, 12, 18, 25],
            "amplitudes": [1.0, 0.7, 0.4, 0.25, 0.1],
            "amplitude": 0.8,
        },
    },
    "glass_break": {
        "category": "impact",
        "duration": 0.4,
        "technique": "glass_synthesis",
        "params": {
            "shatter_grains": 30,
            "freq_range": (2000, 10000),
            "initial_ring_freq": 3000,
            "ring_decay": 10,
            "amplitude": 0.7,
        },
    },
    "ice_crack": {
        "category": "impact",
        "duration": 0.3,
        "technique": "crack_synthesis",
        "params": {
            "crack_freq": 1500,
            "crack_bandwidth": 2000,
            "tail_duration": 0.2,
            "amplitude": 0.65,
        },
    },
    "wood_thud": {
        "category": "impact",
        "duration": 0.2,
        "technique": "modal_synthesis",
        "params": {
            "frequencies": [200, 350, 600],
            "decay_rates": [12, 18, 25],
            "amplitudes": [1.0, 0.6, 0.2],
            "amplitude": 0.55,
        },
    },

    # --- Reaction sounds ---
    "steam_hiss": {
        "category": "reaction",
        "duration": 0.5,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "highpass",
            "center_freq": 3000,
            "bandwidth": 4000,
            "modulation_rate": 0,
            "modulation_depth": 0,
            "attack": 0.01,
            "decay": 0.4,
            "amplitude": 0.6,
        },
    },
    "acid_sizzle": {
        "category": "reaction",
        "duration": 0.6,
        "technique": "granular",
        "params": {
            "grain_rate": 50,
            "grain_duration": 0.008,
            "freq_range": (3000, 9000),
            "amplitude_variation": 0.8,
            "amplitude": 0.5,
            "attack": 0.005,
            "decay": 0.5,
        },
    },
    "explosion": {
        "category": "reaction",
        "duration": 0.8,
        "technique": "explosion_synthesis",
        "params": {
            "initial_freq": 60,
            "noise_amount": 0.8,
            "decay_time": 0.6,
            "amplitude": 0.9,
        },
    },
    "combustion_whoosh": {
        "category": "reaction",
        "duration": 0.4,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "bandpass",
            "center_freq": 500,
            "bandwidth": 400,
            "modulation_rate": 0,
            "modulation_depth": 0,
            "attack": 0.01,
            "decay": 0.35,
            "amplitude": 0.65,
        },
    },
    "lightning_strike": {
        "category": "reaction",
        "duration": 0.5,
        "technique": "crack_synthesis",
        "params": {
            "crack_freq": 4000,
            "crack_bandwidth": 6000,
            "tail_duration": 0.35,
            "amplitude": 0.85,
        },
    },

    # --- Movement sounds ---
    "sand_shift": {
        "category": "movement",
        "duration": 0.3,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "bandpass",
            "center_freq": 5000,
            "bandwidth": 2000,
            "modulation_rate": 8,
            "modulation_depth": 0.4,
            "amplitude": 0.25,
        },
    },
    "water_splash": {
        "category": "movement",
        "duration": 0.3,
        "technique": "splash_synthesis",
        "params": {
            "droplet_count": 8,
            "freq_range": (200, 2000),
            "decay_time": 0.15,
            "amplitude": 0.5,
        },
    },
    "mud_squelch": {
        "category": "movement",
        "duration": 0.25,
        "technique": "filtered_noise",
        "params": {
            "filter_type": "lowpass",
            "center_freq": 400,
            "bandwidth": 200,
            "modulation_rate": 10,
            "modulation_depth": 0.6,
            "amplitude": 0.4,
        },
    },

    # --- Colony sounds ---
    "ant_footstep": {
        "category": "colony",
        "duration": 0.05,
        "technique": "noise_burst",
        "params": {
            "attack": 0.001,
            "decay": 0.03,
            "filter_freq": 6000,
            "filter_q": 2.0,
            "amplitude": 0.15,
        },
    },
    "ant_digging": {
        "category": "colony",
        "duration": 0.2,
        "technique": "granular",
        "params": {
            "grain_rate": 20,
            "grain_duration": 0.01,
            "freq_range": (1000, 4000),
            "amplitude_variation": 0.6,
            "amplitude": 0.3,
        },
    },
    "ant_chirp": {
        "category": "colony",
        "duration": 0.1,
        "technique": "modal_synthesis",
        "params": {
            "frequencies": [4000, 5500, 7000],
            "decay_rates": [30, 40, 50],
            "amplitudes": [1.0, 0.5, 0.2],
            "amplitude": 0.2,
        },
    },
}


# ---------------------------------------------------------------------------
# DSP synthesis functions
# ---------------------------------------------------------------------------

def _envelope(n_samples: int, attack: float, decay: float, sr: int = SAMPLE_RATE) -> np.ndarray:
    """Generate an attack-decay envelope."""
    env = np.ones(n_samples, dtype=np.float32)
    attack_samples = max(1, int(attack * sr))
    decay_samples = max(1, int(decay * sr))

    # Attack ramp
    if attack_samples < n_samples:
        env[:attack_samples] = np.linspace(0, 1, attack_samples, dtype=np.float32)

    # Decay (exponential)
    decay_start = attack_samples
    if decay_start < n_samples:
        remaining = n_samples - decay_start
        t = np.arange(remaining, dtype=np.float32) / sr
        decay_curve = np.exp(-t / max(0.001, decay))
        env[decay_start:decay_start + remaining] = decay_curve[:remaining]

    return env


def _bandpass_filter(signal: np.ndarray, center: float, bw: float,
                     sr: int = SAMPLE_RATE) -> np.ndarray:
    """Simple bandpass via FFT."""
    n = len(signal)
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    fft = np.fft.rfft(signal)

    # Gaussian bandpass
    response = np.exp(-0.5 * ((freqs - center) / max(1, bw / 2)) ** 2)
    fft *= response

    return np.fft.irfft(fft, n=n).astype(np.float32)


def _lowpass_filter(signal: np.ndarray, cutoff: float,
                    sr: int = SAMPLE_RATE) -> np.ndarray:
    """Simple lowpass via FFT."""
    n = len(signal)
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    fft = np.fft.rfft(signal)
    response = 1.0 / (1.0 + (freqs / max(1, cutoff)) ** 4)
    fft *= response
    return np.fft.irfft(fft, n=n).astype(np.float32)


def _highpass_filter(signal: np.ndarray, cutoff: float,
                     sr: int = SAMPLE_RATE) -> np.ndarray:
    """Simple highpass via FFT."""
    n = len(signal)
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    fft = np.fft.rfft(signal)
    response = 1.0 - 1.0 / (1.0 + (freqs / max(1, cutoff)) ** 4)
    fft *= response
    return np.fft.irfft(fft, n=n).astype(np.float32)


def synth_filtered_noise(params: dict, duration: float) -> np.ndarray:
    """Filtered noise with optional modulation. Used for wind, water, steam."""
    n = int(duration * SAMPLE_RATE)
    rng = np.random.default_rng(42)
    noise = rng.standard_normal(n).astype(np.float32)

    center = params["center_freq"]
    bw = params["bandwidth"]
    ftype = params.get("filter_type", "bandpass")

    if ftype == "bandpass":
        signal = _bandpass_filter(noise, center, bw)
    elif ftype == "lowpass":
        signal = _lowpass_filter(noise, center)
    elif ftype == "highpass":
        signal = _highpass_filter(noise, center)
    else:
        signal = noise

    # Amplitude modulation
    mod_rate = params.get("modulation_rate", 0)
    mod_depth = params.get("modulation_depth", 0)
    if mod_rate > 0 and mod_depth > 0:
        t = np.arange(n, dtype=np.float32) / SAMPLE_RATE
        mod = 1.0 - mod_depth + mod_depth * np.sin(2 * np.pi * mod_rate * t)
        signal *= mod

    # Envelope if specified
    attack = params.get("attack", 0.01)
    decay = params.get("decay", duration * 0.9)
    signal *= _envelope(n, attack, decay)

    signal *= params.get("amplitude", 0.5)
    return signal


def synth_granular(params: dict, duration: float) -> np.ndarray:
    """Granular synthesis for crackle, sizzle, rain sounds."""
    n = int(duration * SAMPLE_RATE)
    signal = np.zeros(n, dtype=np.float32)
    rng = np.random.default_rng(42)

    grain_rate = params["grain_rate"]
    grain_dur = params["grain_duration"]
    freq_lo, freq_hi = params["freq_range"]
    amp_var = params.get("amplitude_variation", 0.5)

    n_grains = int(duration * grain_rate)
    grain_samples = int(grain_dur * SAMPLE_RATE)

    for i in range(n_grains):
        # Random position with slight jitter
        pos = int(n * i / n_grains + rng.integers(-grain_samples, grain_samples))
        pos = max(0, min(pos, n - grain_samples - 1))

        freq = rng.uniform(freq_lo, freq_hi)
        amp = 1.0 - amp_var * rng.random()

        t = np.arange(grain_samples, dtype=np.float32) / SAMPLE_RATE
        grain = amp * np.sin(2 * np.pi * freq * t)
        # Hann window
        grain *= 0.5 * (1 - np.cos(2 * np.pi * np.arange(grain_samples) / grain_samples))

        end = min(pos + grain_samples, n)
        signal[pos:end] += grain[:end - pos]

    # Overall envelope
    attack = params.get("attack", 0.01)
    decay = params.get("decay", duration * 0.8)
    signal *= _envelope(n, attack, decay)

    signal *= params.get("amplitude", 0.5)
    return signal


def synth_modal(params: dict, duration: float) -> np.ndarray:
    """Modal synthesis for metallic/stone/wood impacts."""
    n = int(duration * SAMPLE_RATE)
    signal = np.zeros(n, dtype=np.float32)
    t = np.arange(n, dtype=np.float32) / SAMPLE_RATE

    freqs = params["frequencies"]
    decays = params["decay_rates"]
    amps = params["amplitudes"]

    for freq, decay, amp in zip(freqs, decays, amps):
        mode = amp * np.sin(2 * np.pi * freq * t) * np.exp(-decay * t)
        signal += mode

    signal *= params.get("amplitude", 0.5)
    # Normalize
    peak = np.max(np.abs(signal))
    if peak > 0:
        signal = signal / peak * params.get("amplitude", 0.5)
    return signal


def synth_noise_burst(params: dict, duration: float) -> np.ndarray:
    """Short noise burst for tiny impacts (sand grains, ant footsteps)."""
    n = int(duration * SAMPLE_RATE)
    rng = np.random.default_rng(42)
    noise = rng.standard_normal(n).astype(np.float32)

    # Filter
    signal = _lowpass_filter(noise, params.get("filter_freq", 5000))

    # Tight envelope
    signal *= _envelope(n, params.get("attack", 0.001), params.get("decay", 0.05))
    signal *= params.get("amplitude", 0.5)
    return signal


def synth_bubble(params: dict, duration: float) -> np.ndarray:
    """Bubble synthesis for lava/water bubble sounds."""
    n = int(duration * SAMPLE_RATE)
    signal = np.zeros(n, dtype=np.float32)
    rng = np.random.default_rng(42)

    bubble_rate = params["bubble_rate"]
    freq_lo, freq_hi = params["freq_range"]
    decay_time = params["decay_time"]

    n_bubbles = int(duration * bubble_rate)
    for i in range(n_bubbles):
        pos = int(n * i / n_bubbles + rng.integers(0, max(1, n // (n_bubbles + 1))))
        pos = min(pos, n - 1)

        freq = rng.uniform(freq_lo, freq_hi)
        bubble_len = int(decay_time * SAMPLE_RATE)
        bubble_len = min(bubble_len, n - pos)

        t = np.arange(bubble_len, dtype=np.float32) / SAMPLE_RATE
        # Frequency glide (bubbles pitch-shift as they rise)
        freq_glide = freq * (1 + 0.5 * t / decay_time)
        phase = 2 * np.pi * np.cumsum(freq_glide) / SAMPLE_RATE
        bubble = np.sin(phase) * np.exp(-t / decay_time * 3)

        signal[pos:pos + bubble_len] += bubble

    signal *= params.get("amplitude", 0.5)
    peak = np.max(np.abs(signal))
    if peak > 0:
        signal = signal / peak * params.get("amplitude", 0.5)
    return signal


def synth_explosion(params: dict, duration: float) -> np.ndarray:
    """Explosion synthesis: low boom + noise tail."""
    n = int(duration * SAMPLE_RATE)
    t = np.arange(n, dtype=np.float32) / SAMPLE_RATE
    rng = np.random.default_rng(42)

    # Low frequency boom (pitch drops)
    freq = params["initial_freq"]
    freq_sweep = freq * np.exp(-t * 3)
    phase = 2 * np.pi * np.cumsum(freq_sweep) / SAMPLE_RATE
    boom = np.sin(phase) * np.exp(-t / params["decay_time"] * 2)

    # Noise component
    noise = rng.standard_normal(n).astype(np.float32)
    noise = _lowpass_filter(noise, 2000)
    noise *= np.exp(-t / params["decay_time"] * 3)

    mix = params.get("noise_amount", 0.5)
    signal = (1 - mix) * boom + mix * noise
    signal *= _envelope(n, 0.002, params["decay_time"])
    signal *= params.get("amplitude", 0.8)

    peak = np.max(np.abs(signal))
    if peak > 0:
        signal = signal / peak * params.get("amplitude", 0.8)
    return signal


def synth_glass(params: dict, duration: float) -> np.ndarray:
    """Glass break: initial ring + shatter grains."""
    n = int(duration * SAMPLE_RATE)
    signal = np.zeros(n, dtype=np.float32)
    t = np.arange(n, dtype=np.float32) / SAMPLE_RATE
    rng = np.random.default_rng(42)

    # Initial ring
    ring_freq = params["initial_ring_freq"]
    ring_decay = params["ring_decay"]
    ring = np.sin(2 * np.pi * ring_freq * t) * np.exp(-ring_decay * t)
    signal += ring * 0.5

    # Shatter grains (high-frequency noise bursts)
    n_grains = params["shatter_grains"]
    freq_lo, freq_hi = params["freq_range"]
    for i in range(n_grains):
        pos = int(rng.uniform(0, n * 0.3))  # shatter happens early
        grain_len = int(rng.uniform(0.002, 0.015) * SAMPLE_RATE)
        grain_len = min(grain_len, n - pos)

        freq = rng.uniform(freq_lo, freq_hi)
        gt = np.arange(grain_len, dtype=np.float32) / SAMPLE_RATE
        grain = np.sin(2 * np.pi * freq * gt)
        grain *= np.exp(-gt * 100)  # very fast decay
        signal[pos:pos + grain_len] += grain * rng.uniform(0.2, 0.8)

    signal *= params.get("amplitude", 0.7)
    peak = np.max(np.abs(signal))
    if peak > 0:
        signal = signal / peak * params.get("amplitude", 0.7)
    return signal


def synth_crack(params: dict, duration: float) -> np.ndarray:
    """Crack/snap synthesis for ice cracking, lightning."""
    n = int(duration * SAMPLE_RATE)
    rng = np.random.default_rng(42)

    # Initial transient (very short, wide-band)
    transient_len = int(0.005 * SAMPLE_RATE)
    transient = rng.standard_normal(transient_len).astype(np.float32) * 2.0
    transient *= np.exp(-np.arange(transient_len, dtype=np.float32) / transient_len * 5)

    # Resonant tail
    tail_len = int(params["tail_duration"] * SAMPLE_RATE)
    tail = rng.standard_normal(tail_len).astype(np.float32)
    tail = _bandpass_filter(tail, params["crack_freq"], params["crack_bandwidth"])
    tail *= np.exp(-np.arange(tail_len, dtype=np.float32) / SAMPLE_RATE * 8)

    signal = np.zeros(n, dtype=np.float32)
    signal[:min(transient_len, n)] += transient[:min(transient_len, n)]
    end = min(transient_len + tail_len, n)
    signal[transient_len:end] += tail[:end - transient_len]

    signal *= params.get("amplitude", 0.7)
    peak = np.max(np.abs(signal))
    if peak > 0:
        signal = signal / peak * params.get("amplitude", 0.7)
    return signal


def synth_splash(params: dict, duration: float) -> np.ndarray:
    """Water splash: multiple droplet impacts + spray noise."""
    n = int(duration * SAMPLE_RATE)
    signal = np.zeros(n, dtype=np.float32)
    rng = np.random.default_rng(42)

    n_drops = params["droplet_count"]
    freq_lo, freq_hi = params["freq_range"]
    decay = params["decay_time"]

    for i in range(n_drops):
        pos = int(rng.uniform(0, n * 0.2))
        freq = rng.uniform(freq_lo, freq_hi)
        drop_len = int(decay * SAMPLE_RATE)
        drop_len = min(drop_len, n - pos)

        t = np.arange(drop_len, dtype=np.float32) / SAMPLE_RATE
        drop = np.sin(2 * np.pi * freq * t) * np.exp(-t / decay * 5)
        signal[pos:pos + drop_len] += drop * rng.uniform(0.3, 1.0)

    # Spray noise
    spray = rng.standard_normal(n).astype(np.float32) * 0.2
    spray = _highpass_filter(spray, 3000)
    spray *= _envelope(n, 0.001, duration * 0.5)
    signal += spray

    signal *= params.get("amplitude", 0.5)
    peak = np.max(np.abs(signal))
    if peak > 0:
        signal = signal / peak * params.get("amplitude", 0.5)
    return signal


# Technique dispatcher
SYNTH_FUNCTIONS = {
    "filtered_noise": synth_filtered_noise,
    "granular": synth_granular,
    "modal_synthesis": synth_modal,
    "noise_burst": synth_noise_burst,
    "bubble_synthesis": synth_bubble,
    "explosion_synthesis": synth_explosion,
    "glass_synthesis": synth_glass,
    "crack_synthesis": synth_crack,
    "splash_synthesis": synth_splash,
}


def synthesize_sound(name: str, profile: dict) -> np.ndarray:
    """Synthesize a single sound from its profile."""
    technique = profile["technique"]
    synth_fn = SYNTH_FUNCTIONS.get(technique)
    if synth_fn is None:
        print(f"  WARNING: Unknown technique '{technique}' for '{name}', using noise", flush=True)
        n = int(profile["duration"] * SAMPLE_RATE)
        return np.random.default_rng(42).standard_normal(n).astype(np.float32) * 0.1

    return synth_fn(profile["params"], profile["duration"])


# ---------------------------------------------------------------------------
# WAV file writer (pure Python, no external deps)
# ---------------------------------------------------------------------------

def write_wav(path: Path, samples: np.ndarray, sr: int = SAMPLE_RATE):
    """Write a mono WAV file (16-bit PCM)."""
    # Normalize to [-1, 1] then scale to int16
    peak = np.max(np.abs(samples))
    if peak > 0:
        samples = samples / peak * 0.95  # leave headroom

    int_samples = (samples * 32767).astype(np.int16)
    n_samples = len(int_samples)
    data_size = n_samples * 2  # 16-bit = 2 bytes per sample

    with open(path, "wb") as f:
        # RIFF header
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))
        f.write(b"WAVE")
        # fmt chunk
        f.write(b"fmt ")
        f.write(struct.pack("<I", 16))        # chunk size
        f.write(struct.pack("<H", 1))          # PCM format
        f.write(struct.pack("<H", 1))          # mono
        f.write(struct.pack("<I", sr))         # sample rate
        f.write(struct.pack("<I", sr * 2))     # byte rate
        f.write(struct.pack("<H", 2))          # block align
        f.write(struct.pack("<H", 16))         # bits per sample
        # data chunk
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        f.write(int_samples.tobytes())


# ---------------------------------------------------------------------------
# Variation generation (multiple variants per sound)
# ---------------------------------------------------------------------------

def generate_variants(base: np.ndarray, n_variants: int = 3) -> list[np.ndarray]:
    """Generate pitch/speed/amplitude variants from a base sound."""
    variants = [base]
    rng = np.random.default_rng(123)

    for i in range(n_variants - 1):
        # Pitch shift via resampling
        pitch_factor = rng.uniform(0.85, 1.15)
        new_len = int(len(base) / pitch_factor)
        indices = np.linspace(0, len(base) - 1, new_len).astype(np.float32)
        int_indices = indices.astype(int)
        frac = indices - int_indices
        int_indices = np.clip(int_indices, 0, len(base) - 2)
        variant = base[int_indices] * (1 - frac) + base[int_indices + 1] * frac

        # Slight amplitude variation
        variant *= rng.uniform(0.8, 1.0)

        variants.append(variant.astype(np.float32))

    return variants


# ---------------------------------------------------------------------------
# Neural audio model (conditional WaveGAN-style, simplified)
# ---------------------------------------------------------------------------

def train_neural_model(sounds: dict[str, np.ndarray], epochs: int = 200):
    """Train a small conditional generator on DSP-synthesized sounds.

    Uses PyTorch when available. The model learns to map:
        (noise_vector, condition_embedding) -> waveform

    This produces smoother, more natural-sounding variants than
    pure DSP, especially for ambient loops.
    """
    try:
        import torch
        import torch.nn as nn
        import torch.optim as optim
    except ImportError:
        print("  PyTorch not available, skipping neural training", flush=True)
        return None

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"  Training neural audio model on {device}", flush=True)
    print(f"  {len(sounds)} sound categories, {epochs} epochs", flush=True)

    # Fixed waveform length for training (0.5s at 22kHz = 11025 samples)
    WAVE_LEN = 11025
    N_CONDITIONS = len(sounds)

    # Prepare training data: pad/truncate all sounds to WAVE_LEN
    condition_map = {}
    train_waves = []
    train_conditions = []

    for i, (name, wave) in enumerate(sounds.items()):
        condition_map[name] = i
        # Pad or truncate
        if len(wave) >= WAVE_LEN:
            w = wave[:WAVE_LEN]
        else:
            w = np.pad(wave, (0, WAVE_LEN - len(wave)))
        train_waves.append(w)
        train_conditions.append(i)

    train_waves = torch.tensor(np.array(train_waves), dtype=torch.float32).to(device)
    train_conditions = torch.tensor(train_conditions, dtype=torch.long).to(device)

    # --- Generator (1D transposed conv) ---
    LATENT_DIM = 64
    COND_DIM = 32

    class Generator(nn.Module):
        def __init__(self):
            super().__init__()
            self.cond_embed = nn.Embedding(N_CONDITIONS, COND_DIM)
            self.fc = nn.Linear(LATENT_DIM + COND_DIM, 256 * 43)
            self.net = nn.Sequential(
                nn.ConvTranspose1d(256, 128, 8, stride=4, padding=2),
                nn.BatchNorm1d(128),
                nn.ReLU(),
                nn.ConvTranspose1d(128, 64, 8, stride=4, padding=2),
                nn.BatchNorm1d(64),
                nn.ReLU(),
                nn.ConvTranspose1d(64, 32, 8, stride=4, padding=2),
                nn.BatchNorm1d(32),
                nn.ReLU(),
                nn.ConvTranspose1d(32, 1, 8, stride=4, padding=2),
                nn.Tanh(),
            )

        def forward(self, z, cond):
            c = self.cond_embed(cond)
            x = torch.cat([z, c], dim=1)
            x = self.fc(x).view(-1, 256, 43)
            x = self.net(x)
            # Truncate to exact length
            return x[:, 0, :WAVE_LEN]

    # --- Discriminator ---
    class Discriminator(nn.Module):
        def __init__(self):
            super().__init__()
            self.cond_embed = nn.Embedding(N_CONDITIONS, COND_DIM)
            self.net = nn.Sequential(
                nn.Conv1d(1, 32, 8, stride=4, padding=2),
                nn.LeakyReLU(0.2),
                nn.Conv1d(32, 64, 8, stride=4, padding=2),
                nn.LeakyReLU(0.2),
                nn.Conv1d(64, 128, 8, stride=4, padding=2),
                nn.LeakyReLU(0.2),
                nn.Conv1d(128, 256, 8, stride=4, padding=2),
                nn.LeakyReLU(0.2),
            )
            self.fc = nn.Linear(256 * 43 + COND_DIM, 1)

        def forward(self, wave, cond):
            c = self.cond_embed(cond)
            x = wave.unsqueeze(1)  # (B, 1, T)
            x = self.net(x)
            x = x.view(x.size(0), -1)
            x = torch.cat([x, c], dim=1)
            return self.fc(x)

    gen = Generator().to(device)
    disc = Discriminator().to(device)
    opt_g = optim.Adam(gen.parameters(), lr=1e-4, betas=(0.5, 0.9))
    opt_d = optim.Adam(disc.parameters(), lr=1e-4, betas=(0.5, 0.9))

    # Training loop (WGAN-GP style)
    batch_size = min(len(train_waves), 16)
    n_batches = max(1, len(train_waves) // batch_size)

    start = time.time()
    for epoch in range(epochs):
        g_loss_sum = 0
        d_loss_sum = 0

        for b in range(n_batches):
            idx = torch.randint(0, len(train_waves), (batch_size,))
            real = train_waves[idx].to(device)
            conds = train_conditions[idx % len(train_conditions)].to(device)

            # --- Discriminator ---
            z = torch.randn(batch_size, LATENT_DIM, device=device)
            fake = gen(z, conds).detach()

            d_real = disc(real, conds).mean()
            d_fake = disc(fake, conds).mean()
            d_loss = d_fake - d_real

            # Gradient penalty
            alpha = torch.rand(batch_size, 1, device=device)
            interp = (alpha * real + (1 - alpha) * fake).requires_grad_(True)
            d_interp = disc(interp, conds)
            grads = torch.autograd.grad(
                d_interp, interp, torch.ones_like(d_interp),
                create_graph=True, retain_graph=True
            )[0]
            gp = ((grads.norm(2, dim=1) - 1) ** 2).mean() * 10

            opt_d.zero_grad()
            (d_loss + gp).backward()
            opt_d.step()
            d_loss_sum += d_loss.item()

            # --- Generator (every 5 disc steps) ---
            if b % 5 == 0:
                z = torch.randn(batch_size, LATENT_DIM, device=device)
                fake = gen(z, conds)
                g_loss = -disc(fake, conds).mean()

                opt_g.zero_grad()
                g_loss.backward()
                opt_g.step()
                g_loss_sum += g_loss.item()

        if epoch % 50 == 0 or epoch == epochs - 1:
            elapsed = time.time() - start
            print(f"    Epoch {epoch:4d}/{epochs}: D_loss={d_loss_sum/n_batches:.3f} "
                  f"G_loss={g_loss_sum/max(1,n_batches//5):.3f} [{elapsed:.0f}s]", flush=True)

    # Save model
    model_path = OUTPUT_DIR / "model.pt"
    torch.save({
        "generator": gen.state_dict(),
        "condition_map": condition_map,
        "config": {"latent_dim": LATENT_DIM, "n_conditions": N_CONDITIONS,
                   "wave_len": WAVE_LEN, "sample_rate": SAMPLE_RATE},
    }, model_path)
    print(f"  Saved neural model: {model_path}", flush=True)

    return gen, condition_map


def generate_neural_sounds(gen, condition_map: dict, n_variants: int = 5) -> dict[str, list[np.ndarray]]:
    """Generate sound variants using the trained neural model."""
    import torch

    device = next(gen.parameters()).device
    LATENT_DIM = 64
    results = {}

    gen.eval()
    with torch.no_grad():
        for name, cond_id in condition_map.items():
            variants = []
            for v in range(n_variants):
                z = torch.randn(1, LATENT_DIM, device=device)
                cond = torch.tensor([cond_id], device=device)
                wave = gen(z, cond).cpu().numpy()[0]
                variants.append(wave)
            results[name] = variants

    return results


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def generate_dsp_library() -> dict[str, np.ndarray]:
    """Generate the full sound library using DSP synthesis."""
    sounds = {}
    for name, profile in SOUND_PROFILES.items():
        wave = synthesize_sound(name, profile)
        sounds[name] = wave
    return sounds


def save_sound_library(sounds: dict[str, list[np.ndarray] | np.ndarray]):
    """Save all sounds as .wav files with manifest."""
    SOUNDS_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {"sample_rate": SAMPLE_RATE, "sounds": {}}

    total_files = 0
    for name, wave_data in sounds.items():
        profile = SOUND_PROFILES.get(name, {})
        category = profile.get("category", "misc")

        cat_dir = SOUNDS_DIR / category
        cat_dir.mkdir(exist_ok=True)

        if isinstance(wave_data, np.ndarray):
            # Single sound -> generate variants
            variants = generate_variants(wave_data, n_variants=3)
        elif isinstance(wave_data, list):
            variants = wave_data
        else:
            continue

        variant_files = []
        for i, variant in enumerate(variants):
            filename = f"{name}_v{i}.wav"
            filepath = cat_dir / filename
            write_wav(filepath, variant)
            variant_files.append(f"{category}/{filename}")
            total_files += 1

        manifest["sounds"][name] = {
            "category": category,
            "variants": variant_files,
            "duration": profile.get("duration", len(variants[0]) / SAMPLE_RATE),
            "loopable": category == "ambient",
        }

    # Write manifest
    manifest_path = OUTPUT_DIR / "manifest.json"
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"  Saved {total_files} .wav files to {SOUNDS_DIR}", flush=True)
    print(f"  Manifest: {manifest_path}", flush=True)
    return manifest


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Procedural audio generator")
    parser.add_argument("--mode", choices=["dsp", "neural"], default="dsp",
                        help="DSP (fast, no GPU) or neural (A100 recommended)")
    parser.add_argument("--epochs", type=int, default=200,
                        help="Neural training epochs")
    parser.add_argument("--category", type=str, default=None,
                        help="Generate only this category (ambient/impact/reaction/movement/colony)")
    parser.add_argument("--variants", type=int, default=3,
                        help="Number of variants per sound")

    args = parser.parse_args()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}", flush=True)
    print(f"  PROCEDURAL AUDIO GENERATOR", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Mode: {args.mode}", flush=True)
    print(f"  Sample rate: {SAMPLE_RATE} Hz", flush=True)
    print(f"  Sounds: {len(SOUND_PROFILES)} profiles", flush=True)
    print(flush=True)

    start = time.time()

    # Filter by category if specified
    if args.category:
        filtered = {k: v for k, v in SOUND_PROFILES.items()
                    if v["category"] == args.category}
        if not filtered:
            print(f"  ERROR: No sounds in category '{args.category}'", flush=True)
            print(f"  Available: {set(v['category'] for v in SOUND_PROFILES.values())}", flush=True)
            sys.exit(1)
        # Temporarily replace
        global SOUND_PROFILES
        orig_profiles = SOUND_PROFILES
        SOUND_PROFILES = filtered
        print(f"  Filtered to {len(filtered)} sounds in '{args.category}'", flush=True)

    # Phase 1: DSP synthesis
    print("  Phase 1: DSP synthesis...", flush=True)
    dsp_sounds = generate_dsp_library()
    print(f"  Generated {len(dsp_sounds)} base sounds", flush=True)

    if args.mode == "neural":
        # Phase 2: Train neural model on DSP seeds
        print("\n  Phase 2: Neural model training...", flush=True)
        result = train_neural_model(dsp_sounds, epochs=args.epochs)
        if result is not None:
            gen, cond_map = result
            # Phase 3: Generate neural variants
            print("\n  Phase 3: Generating neural variants...", flush=True)
            neural_sounds = generate_neural_sounds(gen, cond_map, n_variants=args.variants)
            # Merge: use neural variants where available, DSP as fallback
            all_sounds = {}
            for name in SOUND_PROFILES:
                if name in neural_sounds:
                    all_sounds[name] = neural_sounds[name]
                else:
                    all_sounds[name] = dsp_sounds[name]
            save_sound_library(all_sounds)
        else:
            save_sound_library(dsp_sounds)
    else:
        save_sound_library(dsp_sounds)

    elapsed = time.time() - start
    print(f"\n  Done in {elapsed:.1f}s", flush=True)

    # Restore if filtered
    if args.category:
        SOUND_PROFILES = orig_profiles


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        assert len(SOUND_PROFILES) > 0, "No sound profiles"
        print(f"Self-test: {len(SOUND_PROFILES)} sound profiles loaded", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
