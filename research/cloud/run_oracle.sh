#!/bin/bash
# High-Scale Research Oracle Launcher
export GEMINI_API_KEY="AIzaSyA3hEM5Z5zF0-mt1tY9_bjZHOjfFYEQTI8"

# Crucial: Fix CuDNN Path for JAX
export LD_LIBRARY_PATH="/usr/local/lib/python3.12/dist-packages/nvidia/cudnn/lib:/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

export XLA_PYTHON_CLIENT_MEM_FRACTION=0.9
export JAX_PLATFORM_NAME=gpu
export PYTHONUNBUFFERED=1
export SCIPY_ARRAY_API=1

cd /home/ubuntu/pe
echo "[⚡] Initializing High-Scale Research Oracle..."
/home/ubuntu/research_env/bin/python3 -u research/cloud/orchestrator.py --all --trials 2000 --workers 16

echo "[⚡] ORACLE EXITED. Keeping shell open for debugging."
exec bash
