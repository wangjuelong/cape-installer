#!/bin/bash
# deploy-guest.sh — Mac 一键把 guest qcow2 推到 cape-openkylin-deploy 服务器并自动 import
#
# 用法：
#   bash deploy-guest.sh <user>@<host> --qcow2 /Users/foo/cuckoo2.qcow2 [--name cuckoo2 ...]
#
# 3 步：
#   1. SCP scripts/import-guest.sh + scripts/domain.xml.tmpl → target:/opt/cape-deploy/
#   2. SCP qcow2 → target:/tmp/<basename>.qcow2
#   3. SSH: sudo bash /opt/cape-deploy/import-guest.sh --qcow2 ... + 转发所有其他参数

set -euo pipefail

TARGET="${1:-}"
SSH_PASS="${SSH_PASS:-12345678}"
[ -n "$TARGET" ] || { echo "Usage: $0 <user>@<host> --qcow2 /path/to.qcow2 [--name ...] [--ip ...] [...]"; exit 1; }
shift

# 提取 --qcow2 路径（本地路径），其他参数原封不动转发给 import-guest.sh
LOCAL_QCOW2=""
FORWARD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --qcow2)
      LOCAL_QCOW2="$2"; shift 2 ;;
    --name|--ip|--mac|--platform|--arch|--tags|--ram-mb|--vcpus)
      FORWARD_ARGS+=("$1" "$2"); shift 2 ;;
    --skip-smoke|--force|-f)
      FORWARD_ARGS+=("$1"); shift ;;
    *)
      echo "[-] 未知参数: $1"; exit 1 ;;
  esac
done

[ -n "$LOCAL_QCOW2" ] || { echo "[-] 缺 --qcow2"; exit 1; }
[ -f "$LOCAL_QCOW2" ] || { echo "[-] 本地 qcow2 不存在: $LOCAL_QCOW2"; exit 1; }

REMOTE_QCOW2="/tmp/$(basename "$LOCAL_QCOW2")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ssh_run()  { sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$TARGET" "$@"; }
# -O 强制旧 SCP 协议（避开 OpenSSH ≥9.0 默认 SFTP 在某些 non-tty/long-transfer 场景下静默失败的坑）。
scp_to()   { sshpass -p "$SSH_PASS" scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }

log() { echo; echo "================================================================"; echo "[+] $*"; echo "================================================================"; }

# 校验远端文件大小与本地一致 —— scp 假成功的兜底
verify_remote_size() {
  local local_path="$1" remote_path="$2"
  local local_size remote_size
  local_size=$(stat -f '%z' "$local_path" 2>/dev/null || stat -c '%s' "$local_path")
  remote_size=$(ssh_run "stat -c '%s' '$remote_path' 2>/dev/null || echo 0")
  if [ "$local_size" != "$remote_size" ]; then
    echo "[-] scp 假成功！local=$local_size remote=$remote_size $remote_path" >&2
    return 1
  fi
  echo "[✓] scp 校验通过: $remote_path ($local_size bytes)"
}

log "Step 1/3: scp import-guest.sh + domain.xml.tmpl → $TARGET:/opt/cape-deploy/"
ssh_run "mkdir -p /opt/cape-deploy/scripts /opt/cape-deploy/logs"
scp_to "$SCRIPT_DIR/scripts/import-guest.sh"    "$TARGET:/opt/cape-deploy/"
scp_to "$SCRIPT_DIR/scripts/domain.xml.tmpl"    "$TARGET:/opt/cape-deploy/scripts/"
ssh_run "chmod +x /opt/cape-deploy/import-guest.sh"

log "Step 2/3: scp qcow2 → $TARGET:$REMOTE_QCOW2  ($(du -h "$LOCAL_QCOW2" | cut -f1))"
scp_to "$LOCAL_QCOW2" "$TARGET:$REMOTE_QCOW2"
verify_remote_size "$LOCAL_QCOW2" "$REMOTE_QCOW2" || {
  echo "[-] qcow2 传输不完整，aborting。手工诊断：sshpass scp -O -v ..." >&2
  exit 2
}
# 如果本地有 .sha256 配套文件，一并推送（小文件，不强校验）
[ -s "$LOCAL_QCOW2.sha256" ] && scp_to "$LOCAL_QCOW2.sha256" "$TARGET:$REMOTE_QCOW2.sha256" || true

log "Step 3/3: ssh sudo bash /opt/cape-deploy/import-guest.sh"
# 用 here-string 把密码喂给 sudo -S
CMD="echo '$SSH_PASS' | sudo -S bash /opt/cape-deploy/import-guest.sh --qcow2 $REMOTE_QCOW2"
for a in "${FORWARD_ARGS[@]}"; do
  CMD="$CMD $(printf '%q' "$a")"
done
ssh_run "$CMD"

echo
echo "[✓] guest deploy 完成。验证："
echo "    sshpass -p '$SSH_PASS' ssh $TARGET 'sudo virsh list --all && curl -m 3 -s http://<guest-ip>:8000/status'"
