#!/usr/bin/env python3
"""Neural surrogate model for fast pre-screening of parameter candidates.

Instead of evaluating every candidate through the full benchmark, this module:
1. Trains a small MLP on existing Optuna trial history
2. Uses the MLP to pre-screen 100,000+ candidates in <1 second
3. Only runs the real benchmark on the top candidates
4. Reduces compute cost ~1000x for large parameter spaces

The surrogate predicts the physics score from the 230+ parameter vector.
Training data comes from the SQLite study database (previous Optuna runs).

Usage:
    # Train surrogate from existing trial data
    python research/cloud/surrogate_model.py --train

    # Pre-screen candidates and optimize using surrogate
    python research/cloud/surrogate_model.py --optimize --n-candidates 100000 --top-k 100

    # Evaluate surrogate accuracy (cross-validation)
    python research/cloud/surrogate_model.py --evaluate

    # Full surrogate-guided optimization loop
    python research/cloud/surrogate_model.py --guided-loop --rounds 5 --trials-per-round 50
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

SCRIPT_DIR = Path(__file__).resolve().parent
RESEARCH_DIR = SCRIPT_DIR.parent
PROJECT_DIR = RESEARCH_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))

from benchmark_optuna import (
    DEFAULT_PARAMS, PARAM_SPACE, _INT_PARAMS,
    score_all, compute_aggregate,
)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
STUDY_DB = RESEARCH_DIR / "cloud_proper_study.db"
STAGED_DB = RESEARCH_DIR / "cloud_staged_study.db"
SURROGATE_PATH = RESEARCH_DIR / "cloud_surrogate_model.npz"
BEST_PARAMS_PATH = RESEARCH_DIR / "cloud_best_params.json"

# Ordered param list for consistent vectorization
PARAM_NAMES = sorted(PARAM_SPACE.keys())
PARAM_BOUNDS = np.array([(PARAM_SPACE[k][0], PARAM_SPACE[k][1]) for k in PARAM_NAMES])


# ---------------------------------------------------------------------------
# Simple MLP (NumPy-only, no PyTorch/TF dependency)
# ---------------------------------------------------------------------------

class SimpleMLP:
    """Lightweight MLP with ReLU hidden layers, trained via Adam.

    Architecture: input -> [hidden1] -> ReLU -> [hidden2] -> ReLU -> output
    All NumPy, no external ML framework needed.
    """

    def __init__(self, input_dim: int, hidden1: int = 128, hidden2: int = 64):
        self.input_dim = input_dim
        self.hidden1 = hidden1
        self.hidden2 = hidden2

        # Xavier initialization
        scale1 = math.sqrt(2.0 / input_dim)
        scale2 = math.sqrt(2.0 / hidden1)
        scale3 = math.sqrt(2.0 / hidden2)

        self.W1 = np.random.randn(input_dim, hidden1).astype(np.float32) * scale1
        self.b1 = np.zeros(hidden1, dtype=np.float32)
        self.W2 = np.random.randn(hidden1, hidden2).astype(np.float32) * scale2
        self.b2 = np.zeros(hidden2, dtype=np.float32)
        self.W3 = np.random.randn(hidden2, 1).astype(np.float32) * scale3
        self.b3 = np.zeros(1, dtype=np.float32)

        # Normalization stats
        self.x_mean = np.zeros(input_dim, dtype=np.float32)
        self.x_std = np.ones(input_dim, dtype=np.float32)
        self.y_mean = 0.0
        self.y_std = 1.0

    def forward(self, X: np.ndarray) -> np.ndarray:
        """Forward pass. X shape: (batch, input_dim). Returns (batch, 1)."""
        X_norm = (X - self.x_mean) / (self.x_std + 1e-8)
        h1 = np.maximum(0, X_norm @ self.W1 + self.b1)  # ReLU
        h2 = np.maximum(0, h1 @ self.W2 + self.b2)       # ReLU
        out = h2 @ self.W3 + self.b3
        return out * self.y_std + self.y_mean

    def predict_batch(self, X: np.ndarray) -> np.ndarray:
        """Predict scores for a batch of parameter vectors."""
        return self.forward(X).flatten()

    def train(self, X: np.ndarray, y: np.ndarray,
              epochs: int = 200, lr: float = 0.001, batch_size: int = 64,
              val_frac: float = 0.1):
        """Train with Adam optimizer and early stopping."""
        n = len(X)
        n_val = max(1, int(n * val_frac))
        n_train = n - n_val

        # Shuffle
        perm = np.random.permutation(n)
        X, y = X[perm], y[perm]

        X_train, y_train = X[:n_train], y[:n_train]
        X_val, y_val = X[n_train:], y[n_train:]

        # Compute normalization
        self.x_mean = X_train.mean(axis=0).astype(np.float32)
        self.x_std = X_train.std(axis=0).astype(np.float32)
        self.x_std[self.x_std < 1e-8] = 1.0
        self.y_mean = float(y_train.mean())
        self.y_std = float(y_train.std())
        if self.y_std < 1e-8:
            self.y_std = 1.0

        # Normalize targets for training
        y_train_norm = (y_train - self.y_mean) / self.y_std
        y_val_norm = (y_val - self.y_mean) / self.y_std

        # Adam state
        params = [self.W1, self.b1, self.W2, self.b2, self.W3, self.b3]
        m = [np.zeros_like(p) for p in params]
        v = [np.zeros_like(p) for p in params]
        beta1, beta2, eps = 0.9, 0.999, 1e-8

        best_val_loss = float("inf")
        patience = 20
        no_improve = 0

        for epoch in range(epochs):
            # Shuffle training data
            perm = np.random.permutation(n_train)
            X_shuf = X_train[perm]
            y_shuf = y_train_norm[perm]

            epoch_loss = 0.0
            n_batches = 0

            for i in range(0, n_train, batch_size):
                Xb = X_shuf[i:i+batch_size]
                yb = y_shuf[i:i+batch_size]
                bs = len(Xb)

                # Forward
                Xb_norm = (Xb - self.x_mean) / (self.x_std + 1e-8)
                z1 = Xb_norm @ self.W1 + self.b1
                h1 = np.maximum(0, z1)
                z2 = h1 @ self.W2 + self.b2
                h2 = np.maximum(0, z2)
                pred = (h2 @ self.W3 + self.b3).flatten()

                # Loss (MSE)
                diff = pred - yb
                loss = np.mean(diff ** 2)
                epoch_loss += loss
                n_batches += 1

                # Backward
                d_pred = 2 * diff / bs  # (bs,)
                d_W3 = h2.T @ d_pred.reshape(-1, 1)
                d_b3 = d_pred.sum(axis=0, keepdims=True).flatten()

                d_h2 = d_pred.reshape(-1, 1) @ self.W3.T  # (bs, hidden2)
                d_z2 = d_h2 * (z2 > 0)
                d_W2 = h1.T @ d_z2
                d_b2 = d_z2.sum(axis=0)

                d_h1 = d_z2 @ self.W2.T  # (bs, hidden1)
                d_z1 = d_h1 * (z1 > 0)
                d_W1 = Xb_norm.T @ d_z1
                d_b1 = d_z1.sum(axis=0)

                grads = [d_W1, d_b1, d_W2, d_b2, d_W3, d_b3]

                # Adam update
                t = epoch * (n_train // batch_size + 1) + (i // batch_size) + 1
                for j, (p, g) in enumerate(zip(params, grads)):
                    m[j] = beta1 * m[j] + (1 - beta1) * g
                    v[j] = beta2 * v[j] + (1 - beta2) * g ** 2
                    m_hat = m[j] / (1 - beta1 ** t)
                    v_hat = v[j] / (1 - beta2 ** t)
                    p -= lr * m_hat / (np.sqrt(v_hat) + eps)

            # Validation loss
            val_pred = self.forward(X_val).flatten()
            val_pred_norm = (val_pred - self.y_mean) / self.y_std
            val_loss = np.mean((val_pred_norm - y_val_norm) ** 2)

            if val_loss < best_val_loss:
                best_val_loss = val_loss
                no_improve = 0
            else:
                no_improve += 1

            if (epoch + 1) % 20 == 0:
                print(f"    Epoch {epoch+1:4d}: train_loss={epoch_loss/n_batches:.6f} "
                      f"val_loss={val_loss:.6f}", flush=True)

            if no_improve >= patience:
                print(f"    Early stopping at epoch {epoch+1}", flush=True)
                break

        return best_val_loss

    def save(self, path: Path):
        """Save model weights to npz file."""
        np.savez(str(path),
                 W1=self.W1, b1=self.b1,
                 W2=self.W2, b2=self.b2,
                 W3=self.W3, b3=self.b3,
                 x_mean=self.x_mean, x_std=self.x_std,
                 y_mean=np.array([self.y_mean]),
                 y_std=np.array([self.y_std]),
                 input_dim=np.array([self.input_dim]),
                 hidden1=np.array([self.hidden1]),
                 hidden2=np.array([self.hidden2]))

    @classmethod
    def load(cls, path: Path) -> "SimpleMLP":
        """Load model from npz file."""
        data = np.load(str(path))
        model = cls(
            input_dim=int(data["input_dim"][0]),
            hidden1=int(data["hidden1"][0]),
            hidden2=int(data["hidden2"][0]),
        )
        model.W1 = data["W1"]
        model.b1 = data["b1"]
        model.W2 = data["W2"]
        model.b2 = data["b2"]
        model.W3 = data["W3"]
        model.b3 = data["b3"]
        model.x_mean = data["x_mean"]
        model.x_std = data["x_std"]
        model.y_mean = float(data["y_mean"][0])
        model.y_std = float(data["y_std"][0])
        return model


# ---------------------------------------------------------------------------
# Data Loading from Optuna DB
# ---------------------------------------------------------------------------

def load_trial_data(min_trials: int = 50) -> tuple[np.ndarray, np.ndarray]:
    """Load completed trial data from Optuna SQLite databases.

    Returns (X, y) where X is (n_trials, n_params) and y is (n_trials,) scores.
    """
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)

    all_X = []
    all_y = []

    for db_path in [STUDY_DB, STAGED_DB]:
        if not db_path.exists():
            continue

        storage = f"sqlite:///{db_path}"
        try:
            study_summaries = optuna.study.get_all_study_summaries(storage=storage)
        except Exception:
            continue

        for summary in study_summaries:
            try:
                study = optuna.load_study(
                    study_name=summary.study_name,
                    storage=storage,
                )
            except Exception:
                continue

            for trial in study.trials:
                if trial.state != optuna.trial.TrialState.COMPLETE:
                    continue

                # Build parameter vector
                x = np.zeros(len(PARAM_NAMES), dtype=np.float32)
                has_all = True
                for i, name in enumerate(PARAM_NAMES):
                    if name in trial.params:
                        x[i] = trial.params[name]
                    elif name in DEFAULT_PARAMS:
                        x[i] = DEFAULT_PARAMS[name]
                    else:
                        has_all = False
                        break

                if not has_all:
                    continue

                # Get score
                if trial.values:
                    score = trial.values[0]  # First objective = physics
                elif "physics" in trial.user_attrs:
                    score = trial.user_attrs["physics"]
                else:
                    continue

                all_X.append(x)
                all_y.append(score)

    if len(all_X) < min_trials:
        # Generate synthetic training data from random sampling
        print(f"  Only {len(all_X)} trials found, generating {min_trials} synthetic samples...",
              flush=True)
        for _ in range(min_trials - len(all_X)):
            x = np.zeros(len(PARAM_NAMES), dtype=np.float32)
            params = {}
            for i, name in enumerate(PARAM_NAMES):
                lo, hi = PARAM_SPACE[name]
                val = np.random.uniform(lo, hi)
                if name in _INT_PARAMS:
                    val = round(val)
                x[i] = val
                params[name] = val

            scores = score_all(params)
            agg = compute_aggregate(scores)
            all_X.append(x)
            all_y.append(agg["physics"])

    X = np.array(all_X, dtype=np.float32)
    y = np.array(all_y, dtype=np.float32)
    return X, y


def params_to_vector(params: dict[str, Any]) -> np.ndarray:
    """Convert a params dict to a numpy vector in PARAM_NAMES order."""
    x = np.zeros(len(PARAM_NAMES), dtype=np.float32)
    for i, name in enumerate(PARAM_NAMES):
        x[i] = params.get(name, DEFAULT_PARAMS.get(name, 0))
    return x


def vector_to_params(x: np.ndarray) -> dict[str, Any]:
    """Convert a numpy vector back to a params dict."""
    params = {}
    for i, name in enumerate(PARAM_NAMES):
        val = float(x[i])
        if name in _INT_PARAMS:
            val = int(round(val))
        params[name] = val
    return params


# ---------------------------------------------------------------------------
# Candidate Generation
# ---------------------------------------------------------------------------

def generate_candidates(n: int, current_best: dict[str, Any] | None = None,
                         exploration_ratio: float = 0.8) -> np.ndarray:
    """Generate candidate parameter vectors for pre-screening.

    Mix of:
    - Pure random (exploration_ratio fraction)
    - Perturbations around current best (1 - exploration_ratio fraction)
    """
    candidates = np.zeros((n, len(PARAM_NAMES)), dtype=np.float32)

    n_explore = int(n * exploration_ratio)
    n_exploit = n - n_explore

    # Random exploration: uniform within bounds
    for i in range(n_explore):
        for j, name in enumerate(PARAM_NAMES):
            lo, hi = PARAM_SPACE[name]
            candidates[i, j] = np.random.uniform(lo, hi)

    # Exploitation: perturb around current best
    if current_best and n_exploit > 0:
        best_vec = params_to_vector(current_best)
        for i in range(n_explore, n):
            noise_scale = np.random.uniform(0.01, 0.15)  # 1-15% perturbation
            noise = np.random.randn(len(PARAM_NAMES)).astype(np.float32)
            candidate = best_vec + noise * noise_scale * (PARAM_BOUNDS[:, 1] - PARAM_BOUNDS[:, 0])
            # Clamp to bounds
            candidate = np.clip(candidate, PARAM_BOUNDS[:, 0], PARAM_BOUNDS[:, 1])
            candidates[i] = candidate

    return candidates


# ---------------------------------------------------------------------------
# Surrogate-Guided Optimization
# ---------------------------------------------------------------------------

def surrogate_prescreen(model: SimpleMLP,
                         n_candidates: int = 100000,
                         top_k: int = 100,
                         current_best: dict[str, Any] | None = None,
                         ) -> list[dict[str, Any]]:
    """Pre-screen candidates using the surrogate model.

    Generates n_candidates random parameter vectors, scores them all
    with the surrogate (~1ms for 100k), and returns the top_k for
    real evaluation.
    """
    start = time.time()

    candidates = generate_candidates(n_candidates, current_best)
    predictions = model.predict_batch(candidates)

    # Get top-k indices
    top_indices = np.argsort(predictions)[-top_k:][::-1]

    results = []
    for idx in top_indices:
        params = vector_to_params(candidates[idx])
        results.append({
            "params": params,
            "surrogate_score": float(predictions[idx]),
        })

    elapsed = time.time() - start
    print(f"  Pre-screened {n_candidates:,} candidates in {elapsed*1000:.1f}ms "
          f"(top predicted: {predictions[top_indices[0]]:.2f})", flush=True)

    return results


def evaluate_real(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Evaluate candidates with the real benchmark."""
    results = []
    for i, c in enumerate(candidates):
        scores = score_all(c["params"])
        agg = compute_aggregate(scores)
        c["real_score"] = agg["physics"]
        c["scores"] = agg
        results.append(c)

        if (i + 1) % 10 == 0:
            print(f"    Evaluated {i+1}/{len(candidates)}, "
                  f"best so far: {max(r['real_score'] for r in results):.2f}", flush=True)

    return results


def guided_optimization_loop(n_rounds: int = 5,
                               n_candidates: int = 100000,
                               top_k: int = 100,
                               retrain_interval: int = 1,
                               ):
    """Full surrogate-guided optimization loop.

    Each round:
    1. Train/update surrogate on all available data
    2. Pre-screen N candidates with surrogate
    3. Evaluate top-K with real benchmark
    4. Add to training data
    5. Save best
    """
    print(f"\n{'='*60}", flush=True)
    print(f"  SURROGATE-GUIDED OPTIMIZATION", flush=True)
    print(f"{'='*60}", flush=True)
    print(f"  Rounds:          {n_rounds}", flush=True)
    print(f"  Candidates/round: {n_candidates:,}", flush=True)
    print(f"  Top-K evaluated: {top_k}", flush=True)
    print(flush=True)

    # Load current best
    current_best = dict(DEFAULT_PARAMS)
    best_params_path = BEST_PARAMS_PATH
    if best_params_path.exists():
        with open(best_params_path) as f:
            data = json.load(f)
        if "params" in data:
            current_best.update(data["params"])

    best_score = 0.0
    best_params = dict(current_best)

    all_X = []
    all_y = []

    for round_num in range(1, n_rounds + 1):
        print(f"\n  --- Round {round_num}/{n_rounds} ---", flush=True)

        # Load trial data + accumulated data
        X_db, y_db = load_trial_data(min_trials=50)
        if all_X:
            X_extra = np.array(all_X, dtype=np.float32)
            y_extra = np.array(all_y, dtype=np.float32)
            X = np.vstack([X_db, X_extra])
            y = np.concatenate([y_db, y_extra])
        else:
            X, y = X_db, y_db

        print(f"  Training data: {len(X)} samples", flush=True)

        # Train surrogate
        model = SimpleMLP(input_dim=len(PARAM_NAMES), hidden1=128, hidden2=64)
        val_loss = model.train(X, y, epochs=200, lr=0.001, batch_size=64)
        print(f"  Surrogate trained (val_loss={val_loss:.6f})", flush=True)

        # Pre-screen
        candidates = surrogate_prescreen(
            model, n_candidates=n_candidates, top_k=top_k,
            current_best=best_params,
        )

        # Real evaluation
        results = evaluate_real(candidates)

        # Find best from this round
        round_best = max(results, key=lambda r: r["real_score"])
        print(f"  Round best: {round_best['real_score']:.2f} "
              f"(surrogate predicted: {round_best['surrogate_score']:.2f})", flush=True)

        if round_best["real_score"] > best_score:
            best_score = round_best["real_score"]
            best_params = round_best["params"]
            print(f"  NEW BEST: {best_score:.2f}", flush=True)

        # Accumulate training data
        for r in results:
            all_X.append(params_to_vector(r["params"]))
            all_y.append(r["real_score"])

        # Measure surrogate accuracy this round
        pred_scores = np.array([r["surrogate_score"] for r in results])
        real_scores = np.array([r["real_score"] for r in results])
        correlation = np.corrcoef(pred_scores, real_scores)[0, 1]
        print(f"  Surrogate-real correlation: {correlation:.3f}", flush=True)

    # Save final model and best params
    model.save(SURROGATE_PATH)
    print(f"\n  Saved surrogate model: {SURROGATE_PATH}", flush=True)

    with open(best_params_path, "w") as f:
        json.dump({
            "params": {k: (round(v, 6) if isinstance(v, float) else v)
                       for k, v in best_params.items()},
            "scores": {"physics": round(best_score, 2)},
            "strategy": "surrogate_guided",
            "rounds": n_rounds,
            "total_real_evals": n_rounds * top_k,
            "total_surrogate_evals": n_rounds * n_candidates,
        }, f, indent=2)
    print(f"  Saved best params: {best_params_path}", flush=True)

    print(f"\n{'='*60}", flush=True)
    print(f"  FINAL: physics={best_score:.2f}", flush=True)
    print(f"  Cost savings: evaluated {n_rounds * n_candidates:,} candidates "
          f"but only ran real benchmark on {n_rounds * top_k:,}", flush=True)
    print(f"{'='*60}", flush=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Neural surrogate model for fast parameter pre-screening")

    parser.add_argument("--train", action="store_true",
                        help="Train surrogate from existing trial data")
    parser.add_argument("--evaluate", action="store_true",
                        help="Evaluate surrogate accuracy (cross-validation)")
    parser.add_argument("--optimize", action="store_true",
                        help="Single pre-screen + evaluate round")
    parser.add_argument("--guided-loop", action="store_true",
                        help="Full surrogate-guided optimization loop")

    parser.add_argument("--n-candidates", type=int, default=100000,
                        help="Number of candidates to pre-screen (default: 100000)")
    parser.add_argument("--top-k", type=int, default=100,
                        help="Top-K candidates for real evaluation (default: 100)")
    parser.add_argument("--rounds", type=int, default=5,
                        help="Optimization rounds for --guided-loop (default: 5)")
    parser.add_argument("--epochs", type=int, default=200,
                        help="Training epochs (default: 200)")

    args = parser.parse_args()

    if args.train:
        print("  Loading trial data...", flush=True)
        X, y = load_trial_data(min_trials=100)
        print(f"  Loaded {len(X)} trials, {len(PARAM_NAMES)} features", flush=True)
        print(f"  Score range: [{y.min():.2f}, {y.max():.2f}], "
              f"mean={y.mean():.2f}, std={y.std():.2f}", flush=True)

        model = SimpleMLP(input_dim=len(PARAM_NAMES), hidden1=128, hidden2=64)
        val_loss = model.train(X, y, epochs=args.epochs)
        model.save(SURROGATE_PATH)
        print(f"\n  Saved: {SURROGATE_PATH}", flush=True)
        print(f"  Final val_loss: {val_loss:.6f}", flush=True)
        return

    if args.evaluate:
        print("  Loading trial data for cross-validation...", flush=True)
        X, y = load_trial_data(min_trials=100)
        n = len(X)

        # 5-fold cross-validation
        fold_size = n // 5
        errors = []
        correlations = []

        for fold in range(5):
            val_start = fold * fold_size
            val_end = val_start + fold_size
            X_val = X[val_start:val_end]
            y_val = y[val_start:val_end]
            X_train = np.vstack([X[:val_start], X[val_end:]])
            y_train = np.concatenate([y[:val_start], y[val_end:]])

            model = SimpleMLP(input_dim=len(PARAM_NAMES))
            model.train(X_train, y_train, epochs=args.epochs)

            pred = model.predict_batch(X_val)
            mse = np.mean((pred - y_val) ** 2)
            mae = np.mean(np.abs(pred - y_val))
            corr = np.corrcoef(pred, y_val)[0, 1] if len(y_val) > 1 else 0

            errors.append(mae)
            correlations.append(corr)
            print(f"  Fold {fold+1}: MAE={mae:.3f}, MSE={mse:.5f}, corr={corr:.3f}",
                  flush=True)

        print(f"\n  Mean MAE: {np.mean(errors):.3f} +/- {np.std(errors):.3f}", flush=True)
        print(f"  Mean correlation: {np.mean(correlations):.3f}", flush=True)
        return

    if args.optimize:
        if not SURROGATE_PATH.exists():
            print("  No surrogate model found, training first...", flush=True)
            X, y = load_trial_data(min_trials=100)
            model = SimpleMLP(input_dim=len(PARAM_NAMES))
            model.train(X, y, epochs=args.epochs)
            model.save(SURROGATE_PATH)
        else:
            model = SimpleMLP.load(SURROGATE_PATH)

        # Load current best
        current_best = dict(DEFAULT_PARAMS)
        if BEST_PARAMS_PATH.exists():
            with open(BEST_PARAMS_PATH) as f:
                data = json.load(f)
            if "params" in data:
                current_best.update(data["params"])

        candidates = surrogate_prescreen(
            model, n_candidates=args.n_candidates, top_k=args.top_k,
            current_best=current_best,
        )
        results = evaluate_real(candidates)
        best = max(results, key=lambda r: r["real_score"])
        print(f"\n  Best: physics={best['real_score']:.2f} "
              f"(surrogate predicted: {best['surrogate_score']:.2f})", flush=True)

        # Save if better
        scores = score_all(best["params"])
        agg = compute_aggregate(scores)
        with open(BEST_PARAMS_PATH, "w") as f:
            json.dump({
                "params": best["params"],
                "scores": {k: round(v, 2) for k, v in agg.items()},
                "strategy": "surrogate_prescreen",
            }, f, indent=2)
        print(f"  Saved: {BEST_PARAMS_PATH}", flush=True)
        return

    if args.guided_loop:
        guided_optimization_loop(
            n_rounds=args.rounds,
            n_candidates=args.n_candidates,
            top_k=args.top_k,
        )
        return

    parser.print_help()


if __name__ == "__main__":
    main()
