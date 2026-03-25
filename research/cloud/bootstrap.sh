#!/bin/bash
# ==========================================================================
# One-command A100/GPU instance setup for The Particle Engine
#
# Sets up a fresh ThunderCompute (or any Ubuntu) instance with EVERYTHING
# needed for the full research pipeline: Python ML stack, Dart SDK, GPU libs.
#
# Usage:
#   # From local machine — pipe directly into remote shell:
#   ssh ubuntu@IP -p PORT 'bash -s' < research/cloud/bootstrap.sh
#
#   # Or copy and run on the instance:
#   scp research/cloud/bootstrap.sh ubuntu@IP:~/bootstrap.sh
#   ssh ubuntu@IP 'bash ~/bootstrap.sh'
#
# Duration: ~5-8 minutes on a fresh instance
# ==========================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

VENV_DIR="$HOME/research_env"
PROJECT_DIR="$HOME/pe"
REPO_URL="https://github.com/Nickalus12/The-Particle-Engine.git"
FLUTTER_DIR="$HOME/flutter"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[bootstrap]${NC} $1"; }
success() { echo -e "${GREEN}[bootstrap] OK:${NC} $1"; }
warn() { echo -e "${YELLOW}[bootstrap] WARN:${NC} $1"; }
fail() { echo -e "${RED}[bootstrap] FAIL:${NC} $1"; exit 1; }

BOOT_START=$(date +%s)

# ==========================================================================
# 1. System packages
# ==========================================================================
log "Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    python3 python3-pip python3-venv \
    apt-transport-https wget gnupg2 git curl \
    unzip xz-utils zip libglu1-mesa clang cmake ninja-build pkg-config libgtk-3-dev \
    build-essential libffi-dev libssl-dev \
    bc jq \
    2>&1 | tail -3

success "System packages installed"

# ==========================================================================
# 2. Python virtual environment + all dependencies
# ==========================================================================
log "Creating Python virtual environment at $VENV_DIR..."
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

log "Installing core Python packages..."
pip install --upgrade pip -q
pip install -q \
    numpy scipy \
    optuna \
    cmaes \
    neat-python \
    hypothesis \
    "pytest>=7.0" pytest-xdist \
    Pillow \
    scikit-image \
    scikit-learn \
    colour-science \
    2>&1 | tail -3

success "Core Python packages installed"

# GPU packages — install what we can, skip gracefully
log "Installing GPU packages (failures are OK on CPU instances)..."

# CuPy (GPU-accelerated NumPy)
pip install -q cupy-cuda12x 2>&1 | tail -1 || warn "CuPy not installed (no CUDA?)"

# JAX with CUDA (for TensorNEAT creature training)
pip install -q "jax[cuda12]" 2>&1 | tail -1 || warn "JAX CUDA not installed"

# PyTorch (for style evolver CLIP, texture atlas Real-ESRGAN)
pip install -q torch torchvision --index-url https://download.pytorch.org/whl/cu121 \
    2>&1 | tail -1 || pip install -q torch torchvision 2>&1 | tail -1 || warn "PyTorch not installed"

# PIQA (perceptual image quality)
pip install -q piqa 2>&1 | tail -1 || true

# TensorNEAT from GitHub
pip install -q git+https://github.com/EMI-Group/tensorneat.git 2>&1 | tail -1 || warn "TensorNEAT not installed"

# CLIP for style evolution scoring
pip install -q git+https://github.com/openai/CLIP.git 2>&1 | tail -1 || warn "CLIP not installed"

# Real-ESRGAN for neural texture upscaling
pip install -q realesrgan basicsr 2>&1 | tail -1 || warn "Real-ESRGAN not installed"

success "GPU packages installed (check warnings above)"

# -- CUDA library paths (ThunderCompute nvidia pip packages need this) --
log "Setting up CUDA library paths..."
NVIDIA_BASE="/usr/local/lib/python3.12/dist-packages/nvidia"
CUDA_LIBS=""
if [ -d "$NVIDIA_BASE" ]; then
    for dir in "$NVIDIA_BASE"/*/lib; do
        [ -d "$dir" ] && CUDA_LIBS="$CUDA_LIBS:$dir"
    done
fi
# Also check in venv
VENV_NVIDIA="$VENV_DIR/lib/python3.12/site-packages/nvidia"
if [ -d "$VENV_NVIDIA" ]; then
    for dir in "$VENV_NVIDIA"/*/lib; do
        [ -d "$dir" ] && CUDA_LIBS="$CUDA_LIBS:$dir"
    done
fi
if [ -n "$CUDA_LIBS" ]; then
    echo "export LD_LIBRARY_PATH=\"$CUDA_LIBS:\$LD_LIBRARY_PATH\"" >> "$VENV_DIR/bin/activate"
    echo "export LD_LIBRARY_PATH=\"$CUDA_LIBS:\$LD_LIBRARY_PATH\"" >> ~/.bashrc
    export LD_LIBRARY_PATH="$CUDA_LIBS:$LD_LIBRARY_PATH"
    success "CUDA library paths configured"
else
    warn "No nvidia pip packages found — CUDA may not work"
fi

# -- Thunder compute token --
log "Writing Thunder token..."
mkdir -p ~/.thunder
if [ -n "$THUNDER_TOKEN" ]; then
    echo "$THUNDER_TOKEN" > ~/.thunder/token
    success "Thunder token written from env"
else
    warn "No THUNDER_TOKEN env var — set manually: echo TOKEN > ~/.thunder/token"
fi

# ==========================================================================
# 3. Dart SDK
# ==========================================================================
log "Installing Dart SDK..."
if command -v dart &> /dev/null; then
    success "Dart already installed: $(dart --version 2>&1)"
else
    wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg 2>/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' \
        | sudo tee /etc/apt/sources.list.d/dart_stable.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq dart
    export PATH="$PATH:/usr/lib/dart/bin"
    grep -qxF 'export PATH="$PATH:/usr/lib/dart/bin"' ~/.bashrc || echo 'export PATH="$PATH:/usr/lib/dart/bin"' >> ~/.bashrc
    success "Dart installed: $(dart --version 2>&1)"
fi

# ==========================================================================
# 3b. Flutter SDK
# ==========================================================================
log "Installing Flutter SDK..."
if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
    success "Flutter already installed: $("$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | head -1)"
else
    rm -rf "$FLUTTER_DIR"
    git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
    grep -qxF 'export PATH="$PATH:$HOME/flutter/bin"' ~/.bashrc || echo 'export PATH="$PATH:$HOME/flutter/bin"' >> ~/.bashrc
    export PATH="$PATH:$FLUTTER_DIR/bin"
    success "Flutter installed"
fi

# ==========================================================================
# 4. Clone project
# ==========================================================================
log "Setting up project at $PROJECT_DIR..."
if [ -d "$PROJECT_DIR/.git" ]; then
    log "Project exists, pulling latest..."
    cd "$PROJECT_DIR" && git pull --ff-only 2>&1 | tail -1
else
    log "Cloning from $REPO_URL..."
    rm -rf "$PROJECT_DIR"
    git clone "$REPO_URL" "$PROJECT_DIR"
fi
cd "$PROJECT_DIR"

success "Project ready at $PROJECT_DIR"

# ==========================================================================
# 5. Pre-compile Dart benchmark
# ==========================================================================
log "Pre-compiling Dart benchmark..."
dart run research/cloud/fast_benchmark.dart 2>/dev/null || warn "Dart benchmark pre-compile skipped"

# ==========================================================================
# 6. GPU verification
# ==========================================================================
log "Verifying GPU access..."

GPU_OK=false

# Test with CuPy
if python3 -c "
import cupy as cp
x = cp.ones(1000)
y = cp.sum(x)
print(f'CuPy OK: {cp.cuda.runtime.getDeviceCount()} GPU(s), computed sum={float(y)}')
print(f'GPU: {cp.cuda.runtime.getDeviceProperties(0)[\"name\"].decode()}')
" 2>/dev/null; then
    GPU_OK=true
    success "CuPy GPU access verified"
fi

# Test with PyTorch
if python3 -c "
import torch
if torch.cuda.is_available():
    print(f'PyTorch CUDA OK: {torch.cuda.device_count()} GPU(s)')
    print(f'GPU: {torch.cuda.get_device_name(0)}')
else:
    print('PyTorch: No CUDA')
" 2>/dev/null; then
    GPU_OK=true
fi

# Test with JAX
if python3 -c "
import jax
devs = jax.devices()
print(f'JAX devices: {[str(d) for d in devs]}')
" 2>/dev/null; then
    GPU_OK=true
fi

if [ "$GPU_OK" = false ]; then
    warn "No GPU detected. Pipeline will run in CPU mode (slower)."
fi

# ==========================================================================
# 7. Activate instructions
# ==========================================================================
BOOT_END=$(date +%s)
ELAPSED=$((BOOT_END - BOOT_START))

echo ""
echo "=========================================="
echo "  BOOTSTRAP COMPLETE (${ELAPSED}s)"
echo "=========================================="
echo ""
echo "  To activate the environment:"
echo "    source $VENV_DIR/bin/activate"
echo "    cd $PROJECT_DIR"
echo ""
echo "  To run the full pipeline:"
echo "    bash research/cloud/run_everything.sh full"
echo ""
echo "  To run a quick test:"
echo "    bash research/cloud/run_everything.sh quick"
echo ""
echo "  To run just creature training:"
echo "    bash research/cloud/run_everything.sh creatures"
echo ""
echo "=========================================="

# Write a marker so deploy_and_run.py knows bootstrap succeeded
echo "{\"bootstrapped\": true, \"elapsed_s\": $ELAPSED, \"gpu\": $GPU_OK, \"timestamp\": \"$(date -Iseconds)\"}" \
    > "$HOME/.bootstrap_status.json"
