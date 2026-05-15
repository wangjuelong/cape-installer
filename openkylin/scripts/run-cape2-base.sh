#!/bin/bash
# /opt/cape-deploy/run-cape2-base.sh
# Wraps cape2.sh.patched with: log redirect, CAPE_ROOT override, exit code surface.
# Stays in /opt/cape-deploy/ as a single deploy dir.
set -uo pipefail

DEPLOY_DIR=/opt/cape-deploy
LOG_DIR="$DEPLOY_DIR/logs"
CAPE_INSTALLER="$DEPLOY_DIR/CAPEv2/installer/cape2.sh.patched"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/install-base-$TS.log"

mkdir -p "$LOG_DIR"
[ -x "$CAPE_INSTALLER" ] || chmod +x "$CAPE_INSTALLER" 2>/dev/null || true
[ -f "$CAPE_INSTALLER" ] || { echo "[-] missing $CAPE_INSTALLER"; exit 1; }

# Make cape2.sh install CAPE into our deploy dir (keeps everything under /opt/cape-deploy/).
export CAPE_ROOT="$DEPLOY_DIR/CAPEv2"

echo "[+] cape2.sh.patched base | log: $LOG"
echo "[+] CAPE_ROOT=$CAPE_ROOT"
echo "[+] start: $(date -Iseconds)"

cd "$DEPLOY_DIR/CAPEv2/installer"
sudo CAPE_ROOT="$CAPE_ROOT" bash "$CAPE_INSTALLER" base 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

echo "[+] cape2.sh exit code: $RC"
echo "[+] end:   $(date -Iseconds)"
exit "$RC"
