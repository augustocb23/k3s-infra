#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
TOTAL_STEPS=1

echo "[1/$TOTAL_STEPS] Installing K3s node..."
echo

curl -sfL https://get.k3s.io | K3S_URL="${k3s_url}" K3S_TOKEN="${k3s_token}" sh -s - \
  --node-label lifecycle=spot

echo "--- K3s installed ---"
echo
