#!/usr/bin/env bash
# =============================================================================
# Physics Oracle Pipeline
# =============================================================================
# 1. Install Python dependencies
# 2. Generate ground truth from real physics (Python + scipy/numpy)
# 3. Run Dart benchmark comparing simulation against ground truth
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "=== Step 1: Install Python dependencies ==="
pip install -r research/requirements.txt

echo ""
echo "=== Step 2: Generate physics ground truth ==="
python research/physics_oracle.py

echo ""
echo "=== Step 3: Run Dart physics benchmark ==="
dart run research/physics_accuracy.dart
