#!/bin/bash
# BULLETPROOF RESEARCH ORACLE BOOTSTRAPPER v4
echo "[⚡] Purging previous sessions..."
sudo pkill -9 -f python
sleep 2

mkdir -p ~/logs ~/telemetry ~/pe
cd ~/pe

tmux kill-session -t oracle 2>/dev/null

# Clean up stale telemetry state to ensure fresh dashboard
rm -f ~/telemetry/current_state.json ~/telemetry/runner_status.json

echo "[⚡] Deploying Research Oracle inside persistent tmux..."
chmod +x /home/ubuntu/pe/research/cloud/run_oracle.sh
tmux new-session -d -s oracle '/home/ubuntu/pe/research/cloud/run_oracle.sh'

# Launch Aesthetic Bridge in a split pane
sleep 2
tmux split-window -t oracle -v 'export LD_LIBRARY_PATH="/usr/local/lib/python3.12/dist-packages/nvidia/cudnn/lib:/usr/local/cuda/lib64:$LD_LIBRARY_PATH"; /home/ubuntu/research_env/bin/python3 -u /home/ubuntu/pe/research/cloud/aesthetic_rater.py'

echo "[⚡] Deployment COMPLETE."
echo "View Live Dashboard: /home/ubuntu/research_env/bin/python3 ~/pe/research/cloud/dashboard.py"
echo "View Oracle Console: tmux attach-session -t oracle"
