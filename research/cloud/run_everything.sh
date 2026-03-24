#!/bin/bash
# ==========================================================================
# Master GPU pipeline for The Particle Engine
# Maximizes value-per-dollar on ThunderCompute instances
#
# Instance tiers and recommended workloads:
#   A100 80GB ($0.78/hr):  Creature training + full chemistry matrix + neural audio/textures
#   A6000 ($0.27/hr):      Optuna physics + shader optimization + style evolution
#   CPU-only (prototyping): Optuna physics only (no GPU needed)
#
# Usage:
#   # Full pipeline on A100 (~3 hours, ~$2.34)
#   bash research/cloud/run_everything.sh full
#
#   # Original 5 workloads (~2 hours on A100, ~$1.56)
#   bash research/cloud/run_everything.sh classic
#
#   # New V2 workloads only (~1 hour on A100, ~$0.78)
#   bash research/cloud/run_everything.sh v2
#
#   # Individual workloads:
#   bash research/cloud/run_everything.sh creatures
#   bash research/cloud/run_everything.sh physics
#   bash research/cloud/run_everything.sh shaders
#   bash research/cloud/run_everything.sh chemistry
#   bash research/cloud/run_everything.sh audio
#   bash research/cloud/run_everything.sh style
#   bash research/cloud/run_everything.sh worldgen
#   bash research/cloud/run_everything.sh regression
#   bash research/cloud/run_everything.sh textures
#
# All output goes to ~/pipeline.log and results to research/cloud/
# ==========================================================================
set +e  # Don't exit on error — one failed phase shouldn't kill the whole pipeline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="$HOME/pipeline.log"
RESULTS_DIR="$SCRIPT_DIR"

MODE="${1:-full}"
TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

# ==========================================================================
# Environment setup
# ==========================================================================

setup_environment() {
    log "Setting up environment..."

    # Check if we're on a fresh instance or have deps already
    if ! command -v python3 &> /dev/null; then
        error "Python3 not found. Run bootstrap.sh first."
        exit 1
    fi

    # Create/activate virtual environment
    if [ ! -d "$HOME/research_env" ]; then
        log "Creating virtual environment..."
        python3 -m venv "$HOME/research_env"
    fi
    source "$HOME/research_env/bin/activate"

    # Install dependencies based on what's available
    log "Installing Python dependencies..."
    pip install -q numpy scipy optuna 2>&1 | tail -1

    # Check for GPU
    if python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null | grep -q "True"; then
        log "CUDA GPU detected via PyTorch"
        GPU_TYPE="cuda"
    elif python3 -c "import cupy" 2>/dev/null; then
        log "GPU detected via CuPy"
        GPU_TYPE="cupy"
    else
        warn "No GPU detected. Installing CPU-only packages."
        GPU_TYPE="none"
    fi

    # Install GPU-specific packages
    if [ "$GPU_TYPE" != "none" ]; then
        pip install -q piqa torch 2>&1 | tail -1

        # Try CuPy
        pip install -q cupy-cuda12x 2>&1 | tail -1 || true

        # Try TensorNEAT (for creature training)
        pip install -q "jax[cuda12]" 2>&1 | tail -1 || true
        pip install -q git+https://github.com/EMI-Group/tensorneat.git 2>&1 | tail -1 || true
    fi

    # Fallback: neat-python for CPU creature training
    pip install -q neat-python 2>&1 | tail -1 || true

    # For shader optimizer + style evolver
    pip install -q scikit-image 2>&1 | tail -1 || true

    # For style evolver (CLIP scoring)
    if [ "$GPU_TYPE" != "none" ]; then
        pip install -q git+https://github.com/openai/CLIP.git 2>&1 | tail -1 || true
    fi

    # For texture atlas (Real-ESRGAN neural upscaling)
    if [ "$GPU_TYPE" != "none" ]; then
        pip install -q realesrgan basicsr 2>&1 | tail -1 || true
    fi

    # For image output (all visual scripts)
    pip install -q Pillow 2>&1 | tail -1 || true

    log "Environment ready. GPU: $GPU_TYPE"
}

# ==========================================================================
# Install Dart SDK if not present
# ==========================================================================

setup_dart() {
    if command -v dart &> /dev/null; then
        log "Dart SDK already installed: $(dart --version 2>&1)"
        return
    fi

    log "Installing Dart SDK..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq apt-transport-https wget gnupg2 2>/dev/null || true
    wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/dart.gpg 2>/dev/null || true
    echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/dart-archive/channels/stable/release/latest/linux_packages/debian stable main' | tee /etc/apt/sources.list.d/dart_stable.list > /dev/null 2>&1 || true
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq dart 2>/dev/null || true
    export PATH="$PATH:/usr/lib/dart/bin"
    log "Dart installed: $(dart --version 2>&1 || echo 'install failed')"
}

# ==========================================================================
# Workload runners
# ==========================================================================

run_physics_optimization() {
    log "=========================================="
    log "  PHASE 1: Physics Parameter Optimization"
    log "=========================================="
    log "  This is PURE PYTHON -- no Dart or GPU needed."
    log "  Uses gaussian scoring for continuous, sensitive benchmarks."
    log ""

    local TRIALS="${PHYSICS_TRIALS:-5000}"
    local WORKERS="${PHYSICS_WORKERS:-8}"

    # Detect available CPU cores
    local CORES=$(nproc 2>/dev/null || echo 8)
    WORKERS=$((CORES > WORKERS ? WORKERS : CORES))

    log "  Trials: $TRIALS, Workers: $WORKERS"

    cd "$PROJECT_DIR"
    python3 research/cloud/proper_benchmark.py \
        --optimize \
        --trials "$TRIALS" \
        --workers "$WORKERS" \
        2>&1 | tee -a "$LOG_FILE"

    success "Physics optimization complete"
}

run_creature_training() {
    log "=========================================="
    log "  PHASE 2: Creature Brain Training"
    log "=========================================="
    log "  Training ant, worm, and spider brains."
    log "  Uses TensorNEAT (GPU) or neat-python (CPU fallback)."
    log ""

    local GENS="${CREATURE_GENS:-500}"

    cd "$PROJECT_DIR"
    python3 research/cloud/creature_trainer.py \
        --species all \
        --generations "$GENS" \
        2>&1 | tee -a "$LOG_FILE"

    success "Creature training complete"
    log "  Genomes saved to: research/cloud/trained_genomes/"
}

run_shader_optimization() {
    log "=========================================="
    log "  PHASE 3: Shader Parameter Optimization"
    log "=========================================="
    log "  Optimizing bloom, exposure, radiance cascade params."
    log ""

    local TRIALS="${SHADER_TRIALS:-1000}"

    cd "$PROJECT_DIR"
    python3 research/cloud/shader_optimizer.py \
        --trials "$TRIALS" \
        --workers 4 \
        2>&1 | tee -a "$LOG_FILE"

    success "Shader optimization complete"
}

run_chemistry_validation() {
    log "=========================================="
    log "  PHASE 4: Chemistry Matrix Validation"
    log "=========================================="
    log "  Testing 41x41 element pairs at 5 temperatures."
    log "  Uses CuPy (GPU) or NumPy (CPU)."
    log ""

    cd "$PROJECT_DIR"

    # Run validation
    python3 research/cloud/chemistry_sim.py \
        --validate \
        2>&1 | tee -a "$LOG_FILE"

    # Run conservation tests
    python3 research/cloud/chemistry_sim.py \
        --conservation \
        --scenarios 2000 \
        2>&1 | tee -a "$LOG_FILE"

    # Run calibration if time allows
    python3 research/cloud/chemistry_sim.py \
        --calibrate \
        --trials 300 \
        2>&1 | tee -a "$LOG_FILE"

    success "Chemistry validation complete"
}

run_dart_benchmark() {
    log "=========================================="
    log "  PHASE 5: Dart Engine Benchmark (optional)"
    log "=========================================="

    if ! command -v dart &> /dev/null; then
        warn "Dart not installed, skipping engine benchmark"
        return
    fi

    cd "$PROJECT_DIR"
    dart run research/cloud/fast_benchmark.dart 2>&1 | tee -a "$LOG_FILE" || true

    success "Dart benchmark complete"
}

# ==========================================================================
# V2 Workload runners (new innovative pipelines)
# ==========================================================================

run_audio_generation() {
    log "=========================================="
    log "  PHASE 6: Procedural Audio Generation"
    log "=========================================="
    log "  Generating element sound library."
    log "  DSP mode (CPU) or neural mode (GPU)."
    log ""

    local AUDIO_MODE="${AUDIO_MODE:-dsp}"
    local AUDIO_EPOCHS="${AUDIO_EPOCHS:-200}"

    if [ "$GPU_TYPE" = "cuda" ]; then
        AUDIO_MODE="neural"
    fi

    cd "$PROJECT_DIR"
    python3 research/cloud/audio_generator.py \
        --mode "$AUDIO_MODE" \
        --epochs "$AUDIO_EPOCHS" \
        2>&1 | tee -a "$LOG_FILE"

    success "Audio generation complete"
    log "  Sounds saved to: research/cloud/audio_output/"
}

run_style_evolution() {
    log "=========================================="
    log "  PHASE 7: Visual Style Evolution"
    log "=========================================="
    log "  Evolving color palettes with aesthetic scoring."
    log ""

    local STYLE_MODE="${STYLE_MODE:-heuristic}"
    local STYLE_GENS="${STYLE_GENS:-200}"
    local STYLE_POP="${STYLE_POP:-32}"

    if [ "$GPU_TYPE" = "cuda" ]; then
        STYLE_MODE="clip"
        STYLE_POP=64
    fi

    cd "$PROJECT_DIR"
    python3 research/cloud/style_evolver.py \
        --mode "$STYLE_MODE" \
        --generations "$STYLE_GENS" \
        --population "$STYLE_POP" \
        2>&1 | tee -a "$LOG_FILE"

    success "Style evolution complete"
    log "  Results saved to: research/cloud/style_results/"
}

run_worldgen_surrogate() {
    log "=========================================="
    log "  PHASE 8: World Generation Surrogate"
    log "=========================================="
    log "  Training neural world rater + Optuna search."
    log ""

    local WORLDGEN_WORLDS="${WORLDGEN_WORLDS:-5000}"
    local WORLDGEN_TRIALS="${WORLDGEN_TRIALS:-50000}"

    cd "$PROJECT_DIR"
    python3 research/cloud/world_rater.py \
        --train \
        --optimize \
        --n-worlds "$WORLDGEN_WORLDS" \
        --trials "$WORLDGEN_TRIALS" \
        2>&1 | tee -a "$LOG_FILE"

    # Validate surrogate accuracy
    python3 research/cloud/world_rater.py \
        --validate \
        2>&1 | tee -a "$LOG_FILE"

    success "World generation surrogate complete"
    log "  Results saved to: research/cloud/worldgen_results/"
}

run_physics_regression() {
    log "=========================================="
    log "  PHASE 9: Physics Regression Testing"
    log "=========================================="
    log "  Recording golden frames + diffing."
    log "  Uses CuPy (GPU) or NumPy (CPU)."
    log ""

    cd "$PROJECT_DIR"
    python3 research/cloud/physics_regression.py \
        --ci \
        2>&1 | tee -a "$LOG_FILE"

    success "Physics regression testing complete"
    log "  Results saved to: research/cloud/regression_results/"
}

run_texture_atlas() {
    log "=========================================="
    log "  PHASE 10: Texture Atlas Generation"
    log "=========================================="
    log "  Pre-rendering element textures with neural upscaling."
    log ""

    local ATLAS_MODE="${ATLAS_MODE:-bicubic}"

    if [ "$GPU_TYPE" = "cuda" ]; then
        ATLAS_MODE="neural"
    fi

    cd "$PROJECT_DIR"
    python3 research/cloud/texture_atlas.py \
        --mode "$ATLAS_MODE" \
        --tile-size 64 \
        --normals \
        2>&1 | tee -a "$LOG_FILE"

    success "Texture atlas generation complete"
    log "  Results saved to: research/cloud/atlas_output/"
}

run_field_tests() {
    log "=========================================="
    log "  PHASE 11: Per-Cell Field Tests (257 tests)"
    log "=========================================="
    log "  Testing all 29 per-cell physics fields."
    log "  Conservation laws, cross-field interactions, multi-field scenarios."
    log ""

    local CORES=$(nproc 2>/dev/null || echo 4)
    local WORKERS=$((CORES > 18 ? 18 : CORES))

    cd "$PROJECT_DIR"
    python3 -m pytest research/tests/test_fields.py \
        research/tests/test_field_conservation.py \
        research/tests/test_field_interactions.py \
        -n "$WORKERS" --dist worksteal -v --tb=short \
        2>&1 | tee -a "$LOG_FILE"

    success "Field tests complete"
}

run_mega_benchmark() {
    log "=========================================="
    log "  PHASE 12: Mega Benchmark (8 categories)"
    log "=========================================="
    log "  Physics, Chemistry, Creatures, WorldGen, Visual,"
    log "  Performance, Integration, Fields"
    log ""

    cd "$PROJECT_DIR"
    python3 research/cloud/mega_benchmark.py --score --quick \
        2>&1 | tee -a "$LOG_FILE"

    # Save baseline
    python3 research/cloud/mega_benchmark.py --save-baseline \
        2>&1 | tee -a "$LOG_FILE"

    success "Mega benchmark complete"
}

run_ecosystem_training() {
    log "=========================================="
    log "  PHASE 13: Ecosystem Co-Evolution"
    log "=========================================="
    log "  5-phase multi-species co-evolutionary training."
    log "  Lotka-Volterra population balance."
    log ""

    local GENS="${ECOSYSTEM_GENS:-200}"

    cd "$PROJECT_DIR"
    python3 research/cloud/ecosystem_trainer.py \
        --full \
        --generations "$GENS" \
        2>&1 | tee -a "$LOG_FILE"

    success "Ecosystem training complete"
    log "  Genomes saved to: research/cloud/trained_genomes/"
}

# ==========================================================================
# Pipeline modes
# ==========================================================================

echo ""
echo "=========================================="
echo "  THE PARTICLE ENGINE -- GPU PIPELINE"
echo "  Mode: $MODE"
echo "  Started: $TIMESTAMP"
echo "=========================================="
echo "" | tee "$LOG_FILE"

PIPELINE_START=$(date +%s)

case "$MODE" in
    full)
        log "Running FULL pipeline (all 13 workloads)"
        log ""
        log "Estimated time:"
        log "  A100:  ~5 hours  (~\$8.95)"
        log "  A6000: ~7 hours  (~\$1.89)"
        log "  CPU:   ~12 hours (prototyping)"
        log ""

        setup_environment

        # Phase 1: Physics (pure Python, no deps needed)
        PHYSICS_TRIALS=5000 PHYSICS_WORKERS=8 run_physics_optimization

        # Phase 2: Creatures (uses GPU if available)
        CREATURE_GENS=500 run_creature_training

        # Phase 3: Shaders (CPU-bound, minimal GPU)
        SHADER_TRIALS=1000 run_shader_optimization

        # Phase 4: Chemistry (uses CuPy GPU if available)
        run_chemistry_validation

        # Phase 5: Dart benchmark (optional, needs Dart SDK)
        setup_dart
        run_dart_benchmark

        # Phase 6: Procedural audio (GPU for neural, CPU for DSP)
        run_audio_generation

        # Phase 7: Style evolution (GPU for CLIP, CPU for heuristic)
        run_style_evolution

        # Phase 8: World generation surrogate
        run_worldgen_surrogate

        # Phase 9: Physics regression testing
        run_physics_regression

        # Phase 10: Texture atlas generation
        run_texture_atlas

        # Phase 11: Field tests (257 tests on 18 cores)
        run_field_tests

        # Phase 12: Mega benchmark (8 categories, save baseline)
        run_mega_benchmark

        # Phase 13: Ecosystem co-evolution (multi-species training)
        ECOSYSTEM_GENS=200 run_ecosystem_training
        ;;

    classic)
        log "Running CLASSIC pipeline (original 5 workloads)"
        log ""
        log "Estimated time:"
        log "  A100:  ~2 hours  (~\$1.56)"
        log "  A6000: ~3 hours  (~\$0.81)"
        log ""

        setup_environment
        PHYSICS_TRIALS=5000 PHYSICS_WORKERS=8 run_physics_optimization
        CREATURE_GENS=500 run_creature_training
        SHADER_TRIALS=1000 run_shader_optimization
        run_chemistry_validation
        setup_dart
        run_dart_benchmark
        ;;

    v2)
        log "Running V2 pipeline (5 new innovative workloads)"
        log ""
        log "Estimated time:"
        log "  A100:  ~1 hour  (~\$0.78)"
        log "  CPU:   ~2 hours (reduced quality)"
        log ""

        setup_environment
        run_audio_generation
        run_style_evolution
        run_worldgen_surrogate
        run_physics_regression
        run_texture_atlas
        ;;

    creatures)
        log "Running CREATURE TRAINING only"
        setup_environment
        CREATURE_GENS="${2:-500}" run_creature_training
        ;;

    physics)
        log "Running PHYSICS OPTIMIZATION only"
        setup_environment
        PHYSICS_TRIALS="${2:-5000}" PHYSICS_WORKERS="${3:-8}" run_physics_optimization
        ;;

    shaders)
        log "Running SHADER OPTIMIZATION only"
        setup_environment
        SHADER_TRIALS="${2:-1000}" run_shader_optimization
        ;;

    chemistry)
        log "Running CHEMISTRY VALIDATION only"
        setup_environment
        run_chemistry_validation
        ;;

    audio)
        log "Running AUDIO GENERATION only"
        setup_environment
        run_audio_generation
        ;;

    style)
        log "Running STYLE EVOLUTION only"
        setup_environment
        run_style_evolution
        ;;

    worldgen)
        log "Running WORLDGEN SURROGATE only"
        setup_environment
        run_worldgen_surrogate
        ;;

    regression)
        log "Running PHYSICS REGRESSION TESTING only"
        setup_environment
        run_physics_regression
        ;;

    textures)
        log "Running TEXTURE ATLAS GENERATION only"
        setup_environment
        run_texture_atlas
        ;;

    fieldtests)
        log "Running FIELD TESTS only (257 tests, all 29 per-cell fields)"
        setup_environment
        run_field_tests
        ;;

    benchmark)
        log "Running MEGA BENCHMARK only (8 categories)"
        setup_environment
        run_mega_benchmark
        ;;

    ecosystem)
        log "Running ECOSYSTEM CO-EVOLUTION only"
        setup_environment
        ECOSYSTEM_GENS="${ECOSYSTEM_GENS:-200}" run_ecosystem_training
        ;;

    quick)
        log "Running QUICK pipeline (reduced trials for testing)"
        setup_environment
        PHYSICS_TRIALS=100 PHYSICS_WORKERS=4 run_physics_optimization
        CREATURE_GENS=50 run_creature_training
        SHADER_TRIALS=50 run_shader_optimization
        WORLDGEN_WORLDS=500 WORLDGEN_TRIALS=1000 run_worldgen_surrogate
        run_physics_regression
        AUDIO_MODE=dsp run_audio_generation
        ATLAS_MODE=bicubic run_texture_atlas
        run_field_tests
        run_mega_benchmark
        ;;

    *)
        echo "Usage: $0 {full|classic|v2|creatures|physics|shaders|chemistry|audio|style|worldgen|regression|textures|fieldtests|benchmark|ecosystem|quick}"
        echo ""
        echo "Pipeline modes:"
        echo "  full       - All 13 workloads (~5hr on A100, ~\$8.95)"
        echo "  classic    - Original 5 workloads (~2hr on A100, ~\$1.56)"
        echo "  v2         - New 5 workloads (~1hr on A100, ~\$0.78)"
        echo "  quick      - Quick test run (~15min)"
        echo ""
        echo "Individual workloads:"
        echo "  creatures  - NEAT creature brain training (~1.5hr on A100)"
        echo "  physics    - Physics param optimization (~30min, CPU OK)"
        echo "  shaders    - Shader param optimization (~20min)"
        echo "  chemistry  - Chemistry matrix validation (~15min with GPU)"
        echo "  audio      - Procedural sound generation (~30min neural, ~2min DSP)"
        echo "  style      - Visual palette evolution (~20min with CLIP)"
        echo "  worldgen   - Neural world rating + Optuna search (~15min)"
        echo "  regression - Physics regression test suite (~5min)"
        echo "  textures   - Texture atlas + neural upscaling (~10min)"
        echo ""
        echo "Environment variables:"
        echo "  PHYSICS_TRIALS=5000    Optuna physics trials"
        echo "  PHYSICS_WORKERS=8      Parallel Optuna workers"
        echo "  CREATURE_GENS=500      NEAT training generations"
        echo "  SHADER_TRIALS=1000     Shader optimization trials"
        echo "  AUDIO_MODE=dsp|neural  Audio synthesis mode"
        echo "  AUDIO_EPOCHS=200       Neural audio training epochs"
        echo "  STYLE_MODE=heuristic|clip  Style scoring mode"
        echo "  STYLE_GENS=200         Evolution generations"
        echo "  WORLDGEN_WORLDS=5000   Training worlds to generate"
        echo "  WORLDGEN_TRIALS=50000  Optuna surrogate trials"
        echo "  ATLAS_MODE=bicubic|neural  Texture upscaling mode"
        exit 0
        ;;
esac

# ==========================================================================
# Summary
# ==========================================================================

PIPELINE_END=$(date +%s)
ELAPSED=$((PIPELINE_END - PIPELINE_START))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo ""
echo "=========================================="
echo "  PIPELINE COMPLETE"
echo "=========================================="
echo "  Mode:     $MODE"
echo "  Duration: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo ""
echo "  Cost estimates:"
echo "    A100 (\$0.78/hr):  \$$(echo "scale=2; $ELAPSED * 0.78 / 3600" | bc)"
echo "    A6000 (\$0.27/hr): \$$(echo "scale=2; $ELAPSED * 0.27 / 3600" | bc)"
echo ""
echo "  Results:"
echo "    Physics:    research/cloud_proper_study.db"
echo "    Creatures:  research/cloud/trained_genomes/"
echo "    Shaders:    research/cloud/shader_results/"
echo "    Chemistry:  research/cloud/chemistry_results/"
echo "    Audio:      research/cloud/audio_output/"
echo "    Style:      research/cloud/style_results/"
echo "    WorldGen:   research/cloud/worldgen_results/"
echo "    Regression: research/cloud/regression_results/"
echo "    Textures:   research/cloud/atlas_output/"
echo ""
echo "  Log: $LOG_FILE"
echo "=========================================="
