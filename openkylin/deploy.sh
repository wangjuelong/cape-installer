#!/bin/bash
# deploy.sh — Mac 一键部署 upstream CAPEv2 (Phase B) → openKylin 2.0 SP2 target
#
# 用法：
#   bash deploy.sh <ssh-user>@<host>
#   bash deploy.sh rtshield@192.168.1.6
#
# 需要 sshpass（如果用密码登录）。如果用 SSH key 改 SSH_PASS= 留空。
#
# 6 步：
#   1. SCP 这一整个 cape-openkylin-deploy/ 到 target:/opt/cape-deploy/
#   2. SSH: 装 git + apt update
#   3. SSH: clone upstream CAPEv2 via gh-proxy
#   4. SSH: 跑 patches/apply-patches.py
#   5. SSH: 跑 cape2.sh.patched base（30-60 min；脚本内部 nohup detached）
#   6. SSH: 跑 post-install-fix.sh + smoke-test.sh

set -euo pipefail

TARGET="${1:-}"
SSH_PASS="${SSH_PASS:-12345678}"

[ -n "$TARGET" ] || { echo "Usage: $0 <user>@<host>"; exit 1; }
SSH_USER="${TARGET%%@*}"
SSH_HOST="${TARGET#*@}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ssh_run()  { sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TARGET" "$@"; }
scp_to()   { sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }

log() { echo; echo "================================================================"; echo "[+] $*"; echo "================================================================"; }

log "Step 1/6: 创建 /opt/cape-deploy + scp scripts/patches/vendor"
ssh_run "
  echo '$SSH_PASS' | sudo -S mkdir -p /opt/cape-deploy
  echo '$SSH_PASS' | sudo -S chown $SSH_USER:$SSH_USER /opt/cape-deploy
  mkdir -p /opt/cape-deploy/{patches,scripts,vendor,logs}
"
scp_to "$SCRIPT_DIR/patches/apply-patches.py"      "$TARGET:/opt/cape-deploy/patches/"
scp_to "$SCRIPT_DIR/scripts/run-cape2-base.sh"     "$TARGET:/opt/cape-deploy/"
scp_to "$SCRIPT_DIR/scripts/build-venv.sh"         "$TARGET:/opt/cape-deploy/"
scp_to "$SCRIPT_DIR/scripts/post-install-fix.sh"   "$TARGET:/opt/cape-deploy/"
scp_to "$SCRIPT_DIR/scripts/smoke-test.sh"         "$TARGET:/opt/cape-deploy/"
scp_to "$SCRIPT_DIR/vendor/mongodb-server-8.0.asc" "$TARGET:/opt/cape-deploy/vendor/"
ssh_run "chmod +x /opt/cape-deploy/*.sh"

log "Step 2/6: 确保 git 已装"
ssh_run "
  which git >/dev/null || echo '$SSH_PASS' | sudo -S apt-get install -y git
  git --version
"

log "Step 3/6: clone upstream CAPEv2 via gh-proxy（如已存在跳过）"
ssh_run "
  if [ ! -d /opt/cape-deploy/CAPEv2/.git ]; then
    cd /opt/cape-deploy
    git clone --depth 50 https://gh-proxy.com/https://github.com/kevoreilly/CAPEv2.git
  fi
  cd /opt/cape-deploy/CAPEv2 && git rev-parse HEAD
"

log "Step 4/6: 跑 patches/apply-patches.py"
ssh_run "cd /opt/cape-deploy && python3 patches/apply-patches.py"

log "Step 5/6: 跑 cape2.sh.patched base（detached，30-60 min）"
ssh_run "
  LOG=/opt/cape-deploy/logs/install-base.log
  > \"\$LOG\"
  echo '=== launch '\$(date -Iseconds)' ===' > \"\$LOG\"
  echo '$SSH_PASS' | sudo -S bash -c \"
    cd /opt/cape-deploy/CAPEv2/installer
    setsid env CAPE_ROOT=/opt/cape-deploy/CAPEv2 nohup bash cape2.sh.patched base >> /opt/cape-deploy/logs/install-base.log 2>&1 < /dev/null &
    echo installer PID=\\\$!
  \"
  sleep 3
  pgrep -af cape2.sh.patched | head -3
"

echo
echo "[+] cape2.sh.patched 后台跑中。监控："
echo "    sshpass -p $SSH_PASS ssh $TARGET 'tail -f /opt/cape-deploy/logs/install-base.log'"
echo
echo "[+] 等它退出后跑："
echo "    sshpass -p $SSH_PASS ssh $TARGET 'echo $SSH_PASS | sudo -S bash /opt/cape-deploy/post-install-fix.sh'"
echo "    sshpass -p $SSH_PASS ssh $TARGET 'echo $SSH_PASS | sudo -S bash /opt/cape-deploy/smoke-test.sh'"
echo
echo "[+] 或者一行命令 wait + 跑 post-install + smoke："
echo "    bash $SCRIPT_DIR/deploy.sh $TARGET --wait-and-finalize"

# --wait-and-finalize：阻塞等 cape2.sh 退出，跑后续两步
if [ "${2:-}" = "--wait-and-finalize" ]; then
  log "Step 5b: wait for cape2.sh.patched to exit"
  ssh_run "while pgrep -f cape2.sh.patched >/dev/null; do sleep 60; done; echo done"

  log "Step 6/6: post-install-fix.sh + smoke-test.sh"
  ssh_run "echo '$SSH_PASS' | sudo -S bash /opt/cape-deploy/post-install-fix.sh"
  ssh_run "echo '$SSH_PASS' | sudo -S bash /opt/cape-deploy/smoke-test.sh"
fi
