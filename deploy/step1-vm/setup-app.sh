#!/bin/bash
# ------------------------------------------------------------
# setup-app.sh — Post-boot app setup for the eShopLite RHEL 8 VM
#
# Run ONCE via SSH after VM boot (Option A — manual post-boot steps).
# Requires RHSM credentials passed as environment variables (not hardcoded).
#
# Usage (from repo root, after `source .env`):
#   virtctl port-forward vmi/eshoplite-vm -n eshoplite-vm 2222:22 &
#   scp -i ~/.ssh/aro-demo-vm -P 2222 deploy/step1-vm/setup-app.sh cloud-user@127.0.0.1:~/
#   ssh -i ~/.ssh/aro-demo-vm -p 2222 cloud-user@127.0.0.1 \
#     "RHSM_USERNAME=$RHSM_USERNAME RHSM_PASSWORD=$RHSM_PASSWORD bash ~/setup-app.sh"
#
# This script is safe to commit — no credentials are stored in it.
# ------------------------------------------------------------
set -euo pipefail

LOG=/var/log/eshoplite-setup.log
DONE=/var/log/eshoplite-setup-done

exec > >(tee -a "$LOG") 2>&1

echo "[$(date)] ===== eshoplite setup-app.sh started ====="

# ---- Preflight: RHSM credentials ---------------------------
if [[ -z "${RHSM_USERNAME:-}" || -z "${RHSM_PASSWORD:-}" ]]; then
  echo "ERROR: RHSM_USERNAME and RHSM_PASSWORD must be set in the environment."
  echo "  Pass them inline:"
  echo "    RHSM_USERNAME=you@example.com RHSM_PASSWORD=secret bash ~/setup-app.sh"
  echo "FAILED: missing RHSM credentials" > "$DONE"
  exit 1
fi

trap 'echo "FAILED: exit $?" > "$DONE"' ERR

# ---- Step 1: Register with RHSM (idempotent) ---------------
echo "[$(date)] Checking RHSM registration..."
if subscription-manager status &>/dev/null; then
  echo "[$(date)] Already registered — skipping subscription-manager register."
else
  echo "[$(date)] Registering with Red Hat Subscription Manager..."
  sudo subscription-manager register \
    --username="${RHSM_USERNAME}" \
    --password="${RHSM_PASSWORD}" \
    --auto-attach
  echo "[$(date)] RHSM registration complete."
fi

# ---- Step 2: Install base packages -------------------------
echo "[$(date)] Installing git, tar, curl..."
sudo dnf install -y git tar curl
echo "[$(date)] Base packages installed."

# ---- Step 3: Install .NET 9 SDK via dotnet-install.sh ------
# rpm-based dotnet-sdk-9.0 does not resolve cleanly even with RHSM on RHEL 8;
# use the official Microsoft install script instead.
if [[ -f /usr/bin/dotnet ]]; then
  echo "[$(date)] dotnet already installed at /usr/bin/dotnet — skipping."
else
  echo "[$(date)] Installing .NET 9 SDK via dotnet-install.sh..."
  curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  sudo bash /tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/local/dotnet
  sudo ln -sf /usr/local/dotnet/dotnet /usr/bin/dotnet
  dotnet --version
  echo "[$(date)] .NET 9 SDK installed."
fi

# ---- Step 4: Clone workshop repo (idempotent) --------------
if [[ -d /opt/workshop ]]; then
  echo "[$(date)] /opt/workshop already exists — skipping clone."
else
  echo "[$(date)] Cloning modernize-monolith-workshop..."
  sudo git clone --depth 1 \
    https://github.com/Azure-Samples/modernize-monolith-workshop.git \
    /opt/workshop
  echo "[$(date)] Repo cloned."
fi

# ---- Step 5: Publish app -----------------------------------
echo "[$(date)] Publishing eShopLite.StoreCore to /opt/eshoplite..."
sudo dotnet publish \
  /opt/workshop/3-modernize-with-github-copilot/StartSample/src/eShopLite.StoreCore \
  -c Release -o /opt/eshoplite
echo "[$(date)] App published."

# ---- Step 6: Write systemd unit ----------------------------
echo "[$(date)] Writing systemd unit..."
sudo tee /etc/systemd/system/eshoplite.service > /dev/null <<'UNIT'
[Unit]
Description=eShopLite Monolith (.NET 9 / ASP.NET Core)
After=network.target

[Service]
WorkingDirectory=/opt/eshoplite
ExecStart=/usr/bin/dotnet eShopLite.StoreCore.dll
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_CLI_HOME=/tmp/dotnet-cli-home
Environment=HOME=/root
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# ---- Step 7: Enable and start service ----------------------
echo "[$(date)] Enabling and starting eshoplite.service..."
sudo systemctl daemon-reload
sudo systemctl enable eshoplite.service
sudo systemctl start eshoplite.service
echo "[$(date)] Service started."

# ---- Step 8: Open firewall port 5000 -----------------------
echo "[$(date)] Opening firewall port 5000/tcp..."
sudo firewall-cmd --permanent --add-port=5000/tcp || true
sudo firewall-cmd --reload || true
echo "[$(date)] Firewall updated."

# ---- Done --------------------------------------------------
echo "[$(date)] ===== Setup complete ====="
echo "SUCCESS" | sudo tee "$DONE" > /dev/null
echo ""
echo "App is running on port 5000. Check:"
echo "  sudo systemctl status eshoplite.service"
echo "  curl http://127.0.0.1:5000"
