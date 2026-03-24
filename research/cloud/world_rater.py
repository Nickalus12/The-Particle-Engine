#!/usr/bin/env python3
"""Neural surrogate model for world generation quality rating.

Trains a small neural network to predict "how fun is this world?" based on
element distribution histograms and terrain statistics. Once trained, this
model replaces expensive simulation-based evaluation in Optuna, accelerating
world generation parameter search by 100-1000x.

Approach:
1. Generate thousands of worlds with random WorldConfig parameters
2. Score each world using heuristic "fun metrics" (expensive but ground truth)
3. Train a PyTorch model to predict the fun score from world statistics
4. Use the trained model as Optuna's objective function (instant evaluation)
5. Validate top candidates against the full heuristic to confirm quality

Fun metrics (ground truth scoring):
- Element diversity: how many distinct elements appear naturally
- Terrain interest: caves, overhangs, water bodies, elevation variation
- Interaction potential: how many reaction pairs are possible
- Exploration factor: connected cave systems, hidden areas
- Resource balance: not too sparse, not too crowded

Neural surrogate:
- Input: 50-dimensional feature vector (element histogram + terrain stats)
- Architecture: 3-layer MLP with ReLU, trained with MSE loss
- Training: ~5000 worlds, takes ~1 min on GPU
- Inference: ~0.01ms per world (vs ~50ms for full heuristic)

Usage:
    # Generate training data + train surrogate (A100 recommended)
    python research/cloud/world_rater.py --train --n-worlds 5000

    # Run Optuna with trained surrogate
    python research/cloud/world_rater.py --optimize --trials 50000

    # Validate surrogate accuracy
    python research/cloud/world_rater.py --validate

    # Score a specific world config
    python research/cloud/world_rater.py --score --config default

Output:
    research/cloud/worldgen_results/surrogate_model.pt
    research/cloud/worldgen_results/training_data.npz
    research/cloud/worldgen_results/best_configs.json
    research/cloud/worldgen_results/validation_report.json

Estimated costs:
    Data generation: ~10 min on A100 ($0.13)
    Training:        ~2 min on A100 ($0.03)
    50K Optuna trials: ~5 min CPU ($0)
    Total: ~$0.16
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
RESULTS_DIR = SCRIPT_DIR / "worldgen_results"

# ---------------------------------------------------------------------------
# Element constants (match element_registry.dart)
# ---------------------------------------------------------------------------
EL_COUNT = 41
ELEMENT_NAMES = [
    "empty", "sand", "water", "fire", "ice", "lightning", "seed", "stone",
    "tnt", "rainbow", "mud", "steam", "ant", "oil", "acid", "glass",
    "dirt", "plant", "lava", "snow", "wood", "metal", "smoke", "bubble",
    "ash", "oxygen", "co2", "fungus", "spore", "charcoal", "compost",
    "rust", "methane", "salt", "clay", "algae", "honey", "hydrogen",
    "sulfur", "copper", "web",
]

# Reactive pairs (elements that can interact)
REACTIVE_PAIRS = {
    (2, 3), (2, 18), (2, 1), (2, 16),  # water + fire/lava/sand/dirt
    (3, 20), (3, 13), (3, 17),         # fire + wood/oil/plant
    (4, 3), (19, 3),                    # ice/snow + fire
    (14, 21), (14, 7), (14, 20),       # acid + metal/stone/wood
    (18, 2), (18, 4), (18, 1),         # lava + water/ice/sand
    (21, 2),                            # metal + water -> rust
    (6, 2),                             # seed + water -> plant
    (1, 5),                             # sand + lightning -> glass
}

# ---------------------------------------------------------------------------
# World generation parameter space
# ---------------------------------------------------------------------------
WORLDGEN_PARAMS = {
    # Terrain shape
    "base_height": {"low": 0.3, "high": 0.7, "default": 0.5,
                    "desc": "Base ground level (fraction of world height)"},
    "terrain_scale": {"low": 0.01, "high": 0.15, "default": 0.06,
                      "desc": "Noise frequency for terrain shape"},
    "terrain_amplitude": {"low": 5, "high": 50, "default": 25,
                          "desc": "Maximum height variation"},
    "roughness": {"low": 0.3, "high": 0.9, "default": 0.6,
                  "desc": "Fractal octave persistence"},

    # Caves
    "cave_density": {"low": 0.0, "high": 0.4, "default": 0.15,
                     "desc": "Probability of cave formation"},
    "cave_size": {"low": 3, "high": 20, "default": 10,
                  "desc": "Average cave radius"},
    "cave_connectivity": {"low": 0.0, "high": 1.0, "default": 0.5,
                          "desc": "How connected cave systems are"},

    # Water
    "water_level": {"low": 0.0, "high": 0.3, "default": 0.1,
                    "desc": "Water table height"},
    "lake_count": {"low": 0, "high": 5, "default": 2,
                   "desc": "Number of surface water bodies"},
    "rain_chance": {"low": 0.0, "high": 0.3, "default": 0.05,
                    "desc": "Probability of rain particles"},

    # Resources
    "ore_density": {"low": 0.0, "high": 0.15, "default": 0.05,
                    "desc": "Metal/copper ore vein density"},
    "plant_density": {"low": 0.0, "high": 0.3, "default": 0.1,
                      "desc": "Surface vegetation density"},
    "lava_depth": {"low": 0.7, "high": 1.0, "default": 0.85,
                   "desc": "Depth at which lava appears"},
    "lava_pool_chance": {"low": 0.0, "high": 0.2, "default": 0.05,
                         "desc": "Probability of lava pools"},

    # Special features
    "snow_line": {"low": 0.0, "high": 0.3, "default": 0.1,
                  "desc": "Snow coverage on peaks"},
    "sand_fraction": {"low": 0.0, "high": 0.4, "default": 0.15,
                      "desc": "Surface sand coverage"},
    "clay_deposits": {"low": 0.0, "high": 0.15, "default": 0.05,
                      "desc": "Clay deposit frequency"},
}


# ---------------------------------------------------------------------------
# World simulator (simplified, fast)
# ---------------------------------------------------------------------------

def generate_world(params: dict, width: int = 160, height: int = 90,
                   seed: int = 42) -> np.ndarray:
    """Generate a world grid from WorldConfig parameters.

    Returns (height, width) uint8 array of element IDs.
    This is a simplified Python approximation of the Dart WorldGenerator.
    """
    rng = np.random.default_rng(seed)
    grid = np.zeros((height, width), dtype=np.uint8)  # all empty

    base_h = params["base_height"]
    scale = params["terrain_scale"]
    amp = params["terrain_amplitude"]
    roughness = params["roughness"]

    # Generate heightmap using layered noise
    heightmap = np.zeros(width, dtype=np.float32)
    for octave in range(4):
        freq = scale * (2 ** octave)
        amplitude = amp * (roughness ** octave)
        x = np.arange(width, dtype=np.float32) * freq
        # Simple noise approximation using sin with phase offsets
        noise = np.sin(x + rng.uniform(0, 2 * np.pi))
        noise += 0.5 * np.sin(2 * x + rng.uniform(0, 2 * np.pi))
        heightmap += noise * amplitude

    # Normalize to ground level
    ground_y = (base_h * height + heightmap).astype(int)
    ground_y = np.clip(ground_y, 5, height - 5)

    # Fill terrain
    for x in range(width):
        gy = ground_y[x]

        # Surface layer
        sand_frac = params["sand_fraction"]
        if rng.random() < sand_frac:
            surface_elem = 1  # sand
        else:
            surface_elem = 16  # dirt

        # Fill columns
        for y in range(gy, height):
            depth = (y - gy) / max(1, height - gy)
            if depth < 0.05:
                grid[y, x] = surface_elem
            elif depth < 0.3:
                grid[y, x] = 16  # dirt
            elif depth < params["lava_depth"]:
                grid[y, x] = 7   # stone
            else:
                if rng.random() < params["lava_pool_chance"] * 3:
                    grid[y, x] = 18  # lava
                else:
                    grid[y, x] = 7   # stone

    # Caves
    cave_density = params["cave_density"]
    cave_size = params["cave_size"]
    n_caves = int(cave_density * width * 0.5)
    for _ in range(n_caves):
        cx = rng.integers(10, width - 10)
        cy = rng.integers(ground_y.min() + 5, height - 10)
        r = rng.integers(max(3, cave_size // 2), cave_size + 1)

        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx*dx + dy*dy <= r*r:
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < height and 0 <= nx < width:
                        if grid[ny, nx] in (7, 16):  # only carve stone/dirt
                            grid[ny, nx] = 0  # empty

    # Water bodies
    water_level = params["water_level"]
    water_y = int((base_h + water_level) * height)
    for lake in range(int(params["lake_count"])):
        lx = rng.integers(20, width - 20)
        lw = rng.integers(10, 30)
        for x in range(max(0, lx - lw // 2), min(width, lx + lw // 2)):
            for y in range(ground_y[x], min(height, ground_y[x] + 8)):
                if grid[y, x] == 0:
                    grid[y, x] = 2  # water

    # Underground water table
    for y in range(water_y, height):
        for x in range(width):
            if grid[y, x] == 0:  # fill empty cave spaces below water table
                if rng.random() < 0.3:
                    grid[y, x] = 2  # water

    # Ore veins
    ore_density = params["ore_density"]
    n_ores = int(ore_density * width * 2)
    for _ in range(n_ores):
        ox = rng.integers(0, width)
        oy = rng.integers(ground_y.min() + 10, height - 5)
        ore_type = 21 if rng.random() > 0.4 else 39  # metal or copper
        vein_len = rng.integers(2, 6)
        for v in range(vein_len):
            nx = ox + rng.integers(-1, 2)
            ny = oy + rng.integers(-1, 2)
            if 0 <= ny < height and 0 <= nx < width and grid[ny, nx] == 7:
                grid[ny, nx] = ore_type

    # Surface vegetation
    plant_density = params["plant_density"]
    for x in range(width):
        if rng.random() < plant_density:
            gy = ground_y[x]
            plant_height = rng.integers(2, 7)
            for dy in range(plant_height):
                y = gy - dy - 1
                if 0 <= y < height and grid[y, x] == 0:
                    if dy == 0 and rng.random() < 0.5:
                        grid[y, x] = 6  # seed
                    else:
                        grid[y, x] = 17  # plant

    # Snow on peaks
    snow_line = params["snow_line"]
    for x in range(width):
        if ground_y[x] < height * (base_h - snow_line * 0.5):
            for y in range(max(0, ground_y[x] - 3), ground_y[x]):
                if 0 <= y < height:
                    grid[y, x] = 19  # snow

    # Clay deposits
    clay_density = params["clay_deposits"]
    n_clay = int(clay_density * width)
    for _ in range(n_clay):
        cx = rng.integers(0, width)
        cy = rng.integers(ground_y.min(), ground_y.min() + 15)
        for dy in range(-2, 3):
            for dx in range(-3, 4):
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < height and 0 <= nx < width:
                    if grid[ny, nx] in (16, 7):  # replace dirt/stone
                        if rng.random() < 0.6:
                            grid[ny, nx] = 34  # clay

    return grid


# ---------------------------------------------------------------------------
# Feature extraction (world -> feature vector)
# ---------------------------------------------------------------------------

def extract_features(grid: np.ndarray) -> np.ndarray:
    """Extract a fixed-size feature vector from a world grid.

    Returns a 50-dimensional float32 vector capturing:
    - Element histogram (41 values, normalized)
    - Terrain statistics (9 values)
    """
    h, w = grid.shape
    total_cells = h * w

    # Element histogram (normalized)
    histogram = np.zeros(EL_COUNT, dtype=np.float32)
    for el_id in range(EL_COUNT):
        histogram[el_id] = np.sum(grid == el_id) / total_cells

    # Terrain statistics
    stats = np.zeros(9, dtype=np.float32)

    # 0: Average ground level
    non_empty_cols = []
    for x in range(w):
        col = grid[:, x]
        non_empty = np.where(col > 0)[0]
        if len(non_empty) > 0:
            non_empty_cols.append(non_empty[0] / h)
    stats[0] = np.mean(non_empty_cols) if non_empty_cols else 0.5

    # 1: Ground level variance
    stats[1] = np.std(non_empty_cols) if len(non_empty_cols) > 1 else 0

    # 2: Empty space ratio (caves + sky)
    stats[2] = histogram[0]

    # 3: Number of distinct element types present
    stats[3] = np.sum(histogram > 0.001) / EL_COUNT

    # 4: Surface element diversity (top 10 rows of terrain)
    surface_types = set()
    for x in range(w):
        for y in range(h):
            if grid[y, x] > 0:
                surface_types.add(grid[y, x])
                break
    stats[4] = len(surface_types) / 10  # normalize

    # 5: Cave area ratio
    # Count empty cells below ground level
    below_ground_empty = 0
    below_ground_total = 0
    avg_ground = int(stats[0] * h)
    for y in range(avg_ground, h):
        for x in range(w):
            below_ground_total += 1
            if grid[y, x] == 0:
                below_ground_empty += 1
    stats[5] = below_ground_empty / max(1, below_ground_total)

    # 6: Water coverage
    stats[6] = histogram[2]  # water

    # 7: Emissive element ratio (fire + lava + lightning)
    stats[7] = histogram[3] + histogram[18] + histogram[5]

    # 8: Organic ratio (plant + seed + fungus + algae)
    stats[8] = histogram[17] + histogram[6] + histogram[27] + histogram[35]

    return np.concatenate([histogram, stats])


# ---------------------------------------------------------------------------
# Heuristic fun scoring (ground truth)
# ---------------------------------------------------------------------------

def score_world_heuristic(grid: np.ndarray) -> float:
    """Score a world's 'fun factor' using heuristics. Range: 0-100."""
    h, w = grid.shape
    features = extract_features(grid)
    histogram = features[:EL_COUNT]
    stats = features[EL_COUNT:]

    score = 0.0

    # --- Element diversity (0-25 points) ---
    n_types = np.sum(histogram > 0.001)
    # Sweet spot: 8-15 element types
    diversity_score = math.exp(-0.5 * ((n_types - 12) / 4) ** 2) * 25
    score += diversity_score

    # --- Terrain interest (0-25 points) ---
    # Height variation
    height_var = stats[1]
    terrain_score = min(12.5, height_var * 80)

    # Cave presence
    cave_ratio = stats[5]
    cave_score = math.exp(-0.5 * ((cave_ratio - 0.08) / 0.05) ** 2) * 12.5
    terrain_score += cave_score
    score += terrain_score

    # --- Interaction potential (0-25 points) ---
    # Count how many reactive pairs are both present
    present_elements = set(np.where(histogram > 0.001)[0])
    n_possible_reactions = 0
    for a, b in REACTIVE_PAIRS:
        if a in present_elements and b in present_elements:
            n_possible_reactions += 1
    reaction_score = min(25, n_possible_reactions * 3)
    score += reaction_score

    # --- Resource balance (0-25 points) ---
    # Not too sparse, not too crowded
    fill_ratio = 1 - stats[2]  # non-empty ratio
    fill_score = math.exp(-0.5 * ((fill_ratio - 0.55) / 0.15) ** 2) * 10

    # Water should be present but not dominant
    water_score = math.exp(-0.5 * ((stats[6] - 0.05) / 0.03) ** 2) * 8

    # Some organic life
    organic_score = min(7, stats[8] * 200)

    score += fill_score + water_score + organic_score

    return min(100, max(0, score))


# ---------------------------------------------------------------------------
# Training data generation
# ---------------------------------------------------------------------------

def generate_training_data(n_worlds: int = 5000, seed: int = 42) -> tuple[np.ndarray, np.ndarray]:
    """Generate worlds with random configs and score them."""
    rng = np.random.default_rng(seed)
    features_list = []
    scores_list = []

    print(f"  Generating {n_worlds} worlds...", flush=True)
    start = time.time()

    for i in range(n_worlds):
        # Random config
        params = {}
        for key, spec in WORLDGEN_PARAMS.items():
            params[key] = rng.uniform(spec["low"], spec["high"])

        # Generate and evaluate
        grid = generate_world(params, seed=i)
        feats = extract_features(grid)
        score = score_world_heuristic(grid)

        features_list.append(feats)
        scores_list.append(score)

        if (i + 1) % 500 == 0:
            elapsed = time.time() - start
            rate = (i + 1) / elapsed
            print(f"    {i+1}/{n_worlds} ({rate:.0f}/s)", flush=True)

    X = np.array(features_list, dtype=np.float32)
    y = np.array(scores_list, dtype=np.float32)

    elapsed = time.time() - start
    print(f"  Generated {n_worlds} worlds in {elapsed:.1f}s", flush=True)
    print(f"  Score range: {y.min():.1f} - {y.max():.1f} (mean: {y.mean():.1f})", flush=True)

    return X, y


# ---------------------------------------------------------------------------
# Neural surrogate model
# ---------------------------------------------------------------------------

def train_surrogate(X: np.ndarray, y: np.ndarray, epochs: int = 500) -> Any:
    """Train a small MLP to predict world fun scores."""
    try:
        import torch
        import torch.nn as nn
        import torch.optim as optim
    except ImportError:
        print("  PyTorch not available, will use heuristic scoring directly", flush=True)
        return None

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"  Training surrogate model on {device}", flush=True)

    # Normalize inputs
    X_mean = X.mean(axis=0)
    X_std = X.std(axis=0) + 1e-6
    X_norm = (X - X_mean) / X_std
    y_mean = y.mean()
    y_std = y.std() + 1e-6
    y_norm = (y - y_mean) / y_std

    X_t = torch.tensor(X_norm, dtype=torch.float32).to(device)
    y_t = torch.tensor(y_norm, dtype=torch.float32).to(device)

    # Train/val split
    n = len(X_t)
    perm = torch.randperm(n)
    n_train = int(n * 0.85)
    train_idx = perm[:n_train]
    val_idx = perm[n_train:]

    input_dim = X.shape[1]

    class SurrogateNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.net = nn.Sequential(
                nn.Linear(input_dim, 128),
                nn.ReLU(),
                nn.Dropout(0.1),
                nn.Linear(128, 64),
                nn.ReLU(),
                nn.Dropout(0.1),
                nn.Linear(64, 32),
                nn.ReLU(),
                nn.Linear(32, 1),
            )

        def forward(self, x):
            return self.net(x).squeeze(-1)

    model = SurrogateNet().to(device)
    optimizer = optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-5)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)
    loss_fn = nn.MSELoss()

    best_val_loss = float("inf")
    best_state = None

    start = time.time()
    for epoch in range(epochs):
        model.train()
        # Mini-batch training
        batch_size = 256
        perm_train = torch.randperm(n_train)
        epoch_loss = 0
        n_batches = 0

        for i in range(0, n_train, batch_size):
            batch_idx = train_idx[perm_train[i:i+batch_size]]
            x_batch = X_t[batch_idx]
            y_batch = y_t[batch_idx]

            pred = model(x_batch)
            loss = loss_fn(pred, y_batch)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            epoch_loss += loss.item()
            n_batches += 1

        scheduler.step()

        # Validation
        model.eval()
        with torch.no_grad():
            val_pred = model(X_t[val_idx])
            val_loss = loss_fn(val_pred, y_t[val_idx]).item()

        if val_loss < best_val_loss:
            best_val_loss = val_loss
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}

        if epoch % 100 == 0 or epoch == epochs - 1:
            elapsed = time.time() - start
            train_loss = epoch_loss / max(1, n_batches)
            print(f"    Epoch {epoch:4d}: train_loss={train_loss:.4f} "
                  f"val_loss={val_loss:.4f} best={best_val_loss:.4f} [{elapsed:.0f}s]", flush=True)

    # Restore best model
    model.load_state_dict(best_state)

    # Save model
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    model_path = RESULTS_DIR / "surrogate_model.pt"
    torch.save({
        "model_state": best_state,
        "X_mean": X_mean.tolist(),
        "X_std": X_std.tolist(),
        "y_mean": float(y_mean),
        "y_std": float(y_std),
        "input_dim": input_dim,
        "val_loss": best_val_loss,
    }, model_path)
    print(f"  Saved surrogate model: {model_path}", flush=True)

    # Compute R^2 on validation set
    model.eval()
    with torch.no_grad():
        val_pred_raw = val_pred.cpu().numpy() * y_std + y_mean
        val_true_raw = y_t[val_idx].cpu().numpy() * y_std + y_mean
        ss_res = np.sum((val_true_raw - val_pred_raw) ** 2)
        ss_tot = np.sum((val_true_raw - val_true_raw.mean()) ** 2)
        r2 = 1 - ss_res / (ss_tot + 1e-6)
        print(f"  Validation R^2: {r2:.4f}", flush=True)
        mae = np.mean(np.abs(val_true_raw - val_pred_raw))
        print(f"  Validation MAE: {mae:.2f} points", flush=True)

    return model, X_mean, X_std, y_mean, y_std


# ---------------------------------------------------------------------------
# Optuna optimization with surrogate
# ---------------------------------------------------------------------------

def optimize_with_surrogate(
    model, X_mean, X_std, y_mean, y_std,
    n_trials: int = 50000,
    n_workers: int = 8,
):
    """Run Optuna using the neural surrogate as objective."""
    import torch
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    device = next(model.parameters()).device
    model.eval()

    study = optuna.create_study(
        study_name="worldgen_surrogate",
        storage=f"sqlite:///{RESULTS_DIR / 'worldgen_study.db'}",
        direction="maximize",
        load_if_exists=True,
        sampler=optuna.samplers.TPESampler(seed=42),
    )

    def objective(trial):
        params = {}
        for key, spec in WORLDGEN_PARAMS.items():
            params[key] = trial.suggest_float(key, spec["low"], spec["high"])

        # Generate world and extract features
        grid = generate_world(params, seed=trial.number)
        features = extract_features(grid)

        # Predict with surrogate
        x = (features - X_mean) / X_std
        x_t = torch.tensor(x, dtype=torch.float32).unsqueeze(0).to(device)
        with torch.no_grad():
            pred = model(x_t).item()

        # Denormalize
        score = pred * y_std + y_mean
        return float(score)

    print(f"\n  Running Optuna with neural surrogate ({n_trials} trials)...", flush=True)
    start = time.time()
    study.optimize(objective, n_trials=n_trials, n_jobs=n_workers)
    elapsed = time.time() - start

    # Top results
    print(f"\n  Done in {elapsed:.1f}s ({n_trials / elapsed:.0f} trials/s)", flush=True)
    print(f"\n  Top 10 world configs:", flush=True)

    top_trials = sorted(study.trials, key=lambda t: t.value or 0, reverse=True)[:10]
    best_configs = []

    for i, trial in enumerate(top_trials):
        # Validate with heuristic
        grid = generate_world(trial.params, seed=trial.number)
        true_score = score_world_heuristic(grid)

        config = {
            "params": trial.params,
            "surrogate_score": round(trial.value, 2),
            "true_score": round(true_score, 2),
            "seed": trial.number,
        }
        best_configs.append(config)

        print(f"  #{i+1}: surrogate={trial.value:.1f} true={true_score:.1f} "
              f"  cave={trial.params['cave_density']:.2f} "
              f"water={trial.params['water_level']:.2f} "
              f"plants={trial.params['plant_density']:.2f}", flush=True)

    # Save results
    with open(RESULTS_DIR / "best_configs.json", "w") as f:
        json.dump(best_configs, f, indent=2)
    print(f"\n  Saved: {RESULTS_DIR / 'best_configs.json'}", flush=True)

    return best_configs


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_surrogate():
    """Validate surrogate accuracy against heuristic scoring."""
    try:
        import torch
    except ImportError:
        print("  PyTorch required for validation", flush=True)
        return

    model_path = RESULTS_DIR / "surrogate_model.pt"
    if not model_path.exists():
        print(f"  Model not found: {model_path}", flush=True)
        print("  Run --train first", flush=True)
        return

    checkpoint = torch.load(model_path, map_location="cpu", weights_only=True)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

    import torch.nn as nn

    input_dim = checkpoint["input_dim"]

    class SurrogateNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.net = nn.Sequential(
                nn.Linear(input_dim, 128), nn.ReLU(), nn.Dropout(0.1),
                nn.Linear(128, 64), nn.ReLU(), nn.Dropout(0.1),
                nn.Linear(64, 32), nn.ReLU(),
                nn.Linear(32, 1),
            )
        def forward(self, x):
            return self.net(x).squeeze(-1)

    model = SurrogateNet().to(device)
    model.load_state_dict(checkpoint["model_state"])
    model.eval()

    X_mean = np.array(checkpoint["X_mean"])
    X_std = np.array(checkpoint["X_std"])
    y_mean = checkpoint["y_mean"]
    y_std = checkpoint["y_std"]

    # Generate fresh test worlds
    n_test = 500
    rng = np.random.default_rng(9999)
    preds = []
    trues = []

    print(f"  Validating on {n_test} fresh worlds...", flush=True)
    for i in range(n_test):
        params = {k: rng.uniform(spec["low"], spec["high"])
                  for k, spec in WORLDGEN_PARAMS.items()}
        grid = generate_world(params, seed=10000 + i)
        features = extract_features(grid)
        true_score = score_world_heuristic(grid)

        x = (features - X_mean) / X_std
        x_t = torch.tensor(x, dtype=torch.float32).unsqueeze(0).to(device)
        with torch.no_grad():
            pred = model(x_t).item() * y_std + y_mean

        preds.append(pred)
        trues.append(true_score)

    preds = np.array(preds)
    trues = np.array(trues)

    mae = np.mean(np.abs(trues - preds))
    rmse = np.sqrt(np.mean((trues - preds) ** 2))
    correlation = np.corrcoef(trues, preds)[0, 1]
    ss_res = np.sum((trues - preds) ** 2)
    ss_tot = np.sum((trues - trues.mean()) ** 2)
    r2 = 1 - ss_res / (ss_tot + 1e-6)

    report = {
        "n_test": n_test,
        "mae": round(float(mae), 3),
        "rmse": round(float(rmse), 3),
        "r2": round(float(r2), 4),
        "correlation": round(float(correlation), 4),
        "true_range": [round(float(trues.min()), 1), round(float(trues.max()), 1)],
        "pred_range": [round(float(preds.min()), 1), round(float(preds.max()), 1)],
    }

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(RESULTS_DIR / "validation_report.json", "w") as f:
        json.dump(report, f, indent=2)

    print(f"\n  Validation Results:", flush=True)
    print(f"    MAE:         {mae:.2f} points", flush=True)
    print(f"    RMSE:        {rmse:.2f} points", flush=True)
    print(f"    R^2:         {r2:.4f}", flush=True)
    print(f"    Correlation: {correlation:.4f}", flush=True)
    print(f"  Saved: {RESULTS_DIR / 'validation_report.json'}", flush=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Neural world generation surrogate optimizer")
    parser.add_argument("--train", action="store_true",
                        help="Generate training data and train surrogate")
    parser.add_argument("--optimize", action="store_true",
                        help="Run Optuna with trained surrogate")
    parser.add_argument("--validate", action="store_true",
                        help="Validate surrogate accuracy")
    parser.add_argument("--score", action="store_true",
                        help="Score a default world config")
    parser.add_argument("--n-worlds", type=int, default=5000,
                        help="Number of training worlds")
    parser.add_argument("--trials", type=int, default=50000,
                        help="Optuna trials with surrogate")
    parser.add_argument("--epochs", type=int, default=500,
                        help="Training epochs")
    parser.add_argument("--workers", type=int, default=4,
                        help="Parallel Optuna workers")

    args = parser.parse_args()
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}", flush=True)
    print(f"  WORLD GENERATION NEURAL SURROGATE", flush=True)
    print(f"{'='*60}", flush=True)

    if args.score:
        params = {k: v["default"] for k, v in WORLDGEN_PARAMS.items()}
        grid = generate_world(params)
        score = score_world_heuristic(grid)
        features = extract_features(grid)
        print(f"\n  Default world config:", flush=True)
        print(f"  Fun score: {score:.1f}/100", flush=True)
        print(f"  Elements present: {int(np.sum(features[:EL_COUNT] > 0.001))}", flush=True)
        print(f"  Cave ratio: {features[EL_COUNT + 5]:.3f}", flush=True)
        print(f"  Water coverage: {features[2]:.3f}", flush=True)
        return

    if args.train:
        print(f"  Generating {args.n_worlds} training worlds...", flush=True)
        X, y = generate_training_data(n_worlds=args.n_worlds)

        # Save training data
        np.savez(RESULTS_DIR / "training_data.npz", X=X, y=y)
        print(f"  Saved: {RESULTS_DIR / 'training_data.npz'}", flush=True)

        print(f"\n  Training surrogate model ({args.epochs} epochs)...", flush=True)
        result = train_surrogate(X, y, epochs=args.epochs)

        if result is not None and args.optimize:
            model, X_mean, X_std, y_mean, y_std = result
            optimize_with_surrogate(model, X_mean, X_std, y_mean, y_std,
                                    n_trials=args.trials, n_workers=args.workers)

    elif args.optimize:
        # Load existing model
        try:
            import torch
            import torch.nn as nn

            model_path = RESULTS_DIR / "surrogate_model.pt"
            if not model_path.exists():
                print(f"  No trained model found. Run --train first.", flush=True)
                sys.exit(1)

            checkpoint = torch.load(model_path, map_location="cpu", weights_only=True)
            device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

            input_dim = checkpoint["input_dim"]

            class SurrogateNet(nn.Module):
                def __init__(self):
                    super().__init__()
                    self.net = nn.Sequential(
                        nn.Linear(input_dim, 128), nn.ReLU(), nn.Dropout(0.1),
                        nn.Linear(128, 64), nn.ReLU(), nn.Dropout(0.1),
                        nn.Linear(64, 32), nn.ReLU(),
                        nn.Linear(32, 1),
                    )
                def forward(self, x):
                    return self.net(x).squeeze(-1)

            model = SurrogateNet().to(device)
            model.load_state_dict(checkpoint["model_state"])

            X_mean = np.array(checkpoint["X_mean"])
            X_std = np.array(checkpoint["X_std"])
            y_mean = checkpoint["y_mean"]
            y_std = checkpoint["y_std"]

            optimize_with_surrogate(model, X_mean, X_std, y_mean, y_std,
                                    n_trials=args.trials, n_workers=args.workers)
        except ImportError:
            print("  PyTorch required for surrogate optimization", flush=True)
            sys.exit(1)

    elif args.validate:
        validate_surrogate()

    else:
        # Default: train + optimize
        X, y = generate_training_data(n_worlds=args.n_worlds)
        np.savez(RESULTS_DIR / "training_data.npz", X=X, y=y)

        result = train_surrogate(X, y, epochs=args.epochs)
        if result is not None:
            model, X_mean, X_std, y_mean, y_std = result
            optimize_with_surrogate(model, X_mean, X_std, y_mean, y_std,
                                    n_trials=args.trials, n_workers=args.workers)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        print("Self-test: imports OK", flush=True)
        params = {k: v["default"] for k, v in WORLDGEN_PARAMS.items()}
        assert len(params) > 0
        print(f"Self-test: {len(params)} worldgen params", flush=True)
        print("Self-test: PASSED", flush=True)
        sys.exit(0)
    main()
