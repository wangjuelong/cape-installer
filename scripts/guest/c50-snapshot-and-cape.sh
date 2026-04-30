#!/usr/bin/env bash
# Stage c50-snapshot-and-cape：拍 clean 快照 + 解 mask cape*
# - virsh snapshot-create-as --atomic clean
# - systemctl unmask cape cape-processor
# - systemctl restart cape cape-processor cape-rooter cape-web
# - 确认 cape.service active

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c50-snapshot-and-cape"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
SNAPSHOT_NAME=clean

# ---- 幂等守卫 ----
has_snapshot() {
  virsh snapshot-list "$GUEST_NAME" --name 2>/dev/null | grep -qx "$SNAPSHOT_NAME"
}
cape_unmasked() {
  ! systemctl is-enabled cape 2>/dev/null | grep -q masked
}
if done_or_force has_snapshot && cape_unmasked && service_active cape; then
  echo "[~] 快照 $SNAPSHOT_NAME 存在 + cape active，跳过"
  stage_done
  exit 0
fi

# ---- 1. 拍快照 ----
if ! has_snapshot; then
  echo "[+] 拍快照 $SNAPSHOT_NAME（atomic）"
  virsh snapshot-create-as "$GUEST_NAME" \
    --name "$SNAPSHOT_NAME" \
    --description "first clean state with CAPE agent" \
    --atomic
  echo "[✓] 快照已拍"
else
  echo "[~] 快照 $SNAPSHOT_NAME 已存在"
fi
virsh snapshot-list "$GUEST_NAME"

# ---- 2. 解 mask cape & cape-processor ----
echo "[+] unmask cape cape-processor"
systemctl unmask cape cape-processor 2>/dev/null || true
systemctl daemon-reload

# ---- 3. restart cape 全家 ----
echo "[+] restart cape 全家"
systemctl restart cape cape-processor cape-rooter cape-web

# ---- 4. 确认 active ----
sleep 3
for svc in cape cape-processor cape-rooter cape-web; do
  if systemctl is-active --quiet "$svc"; then
    echo "[✓] $svc active"
  else
    echo "[!] $svc 未 active"
    journalctl -u "$svc" -n 30 --no-pager
    exit 1
  fi
done

echo "[✓] Phase C 完成。浏览器访问 http://<TARGET>:8000/submit/ 提交样本测试。"
stage_done
