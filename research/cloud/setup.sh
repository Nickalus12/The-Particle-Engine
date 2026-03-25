#!/bin/bash
# Thunder Compute instance setup for Particle Engine optimization
# Run this once after connecting to the instance
set -e

echo "=== Particle Engine Cloud Optimizer Setup ==="

FLUTTER_DIR="$HOME/flutter"

# Install Dart SDK
echo "Installing Dart SDK..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    apt-transport-https wget gnupg2 git curl \
    unzip xz-utils zip libglu1-mesa clang cmake ninja-build pkg-config libgtk-3-dev
wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/dart.gpg
echo 'deb [signed-by=/usr/share/keyrings/dart.gpg arch=amd64] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main' | sudo tee /etc/apt/sources.list.d/dart_stable.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq dart
export PATH="$PATH:/usr/lib/dart/bin"
grep -qxF 'export PATH="$PATH:/usr/lib/dart/bin"' ~/.bashrc || echo 'export PATH="$PATH:/usr/lib/dart/bin"' >> ~/.bashrc

echo "Installing Flutter SDK..."
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
    rm -rf "$FLUTTER_DIR"
    git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
export PATH="$PATH:$FLUTTER_DIR/bin"
grep -qxF 'export PATH="$PATH:$HOME/flutter/bin"' ~/.bashrc || echo 'export PATH="$PATH:$HOME/flutter/bin"' >> ~/.bashrc

# Install Python deps
echo "Installing Python dependencies..."
sudo apt-get install -y -qq python3-pip python3-venv
python3 -m venv ~/optenv
source ~/optenv/bin/activate
pip install -q numpy scipy scikit-image colour-science optuna pytest scikit-learn cmaes

# Clone the repo
echo "Cloning repository..."
if [ ! -d ~/particle-engine ]; then
    git clone https://github.com/Nickalus12/The-Particle-Engine.git ~/particle-engine
fi
cd ~/particle-engine

# Verify Dart works
echo "Verifying Dart..."
dart --version
flutter --version

# Pre-compile the benchmark
echo "Pre-compiling benchmark..."
dart run research/export_frame.dart 10 2>/dev/null || true

echo ""
echo "=== Setup Complete ==="
echo "To run optimization: cd ~/particle-engine && source ~/optenv/bin/activate && python3 research/cloud/training_system.py"
