#!/usr/bin/env bash
# Stage c20-define-domain：渲染 libvirt domain XML 并 virsh define
# - 用 lib/common.sh 的 render_template + envsubst
# - 在 default 网络追加 MAC→IP DHCP reservation
#
# 失败原则：virsh define 失败 → 删半定义 domain 重试 1 次

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c20-define-domain"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"
GUEST_MAC="${GUEST_MAC:-52:54:00:CA:FE:01}"
GUEST_RAM_MB="${GUEST_RAM_MB:-4096}"
GUEST_VCPUS="${GUEST_VCPUS:-2}"

TMPL="$REPO_ROOT/scripts/guest/domain-cuckoo1.xml.tmpl"
RENDER=/tmp/${GUEST_NAME}.domain.xml

# ---- 幂等守卫 ----
if done_or_force virsh dominfo "$GUEST_NAME" >/dev/null 2>&1; then
  echo "[~] domain $GUEST_NAME 已定义，跳过（要重渲染用 make force-c20-define-domain）"
  stage_done
  exit 0
fi

# ---- 1. 渲染 XML ----
export GUEST_NAME GUEST_IP GUEST_MAC GUEST_RAM_MB GUEST_VCPUS
render_template "$TMPL" > "$RENDER"
xmllint --noout "$RENDER" || { echo "[-] 渲染后 XML 不合法: $RENDER"; exit 1; }
echo "[✓] 渲染 → $RENDER"

# ---- 2. virsh define（带 1 次重试 + 半成功清理）----
if ! virsh define "$RENDER"; then
  echo "[!] virsh define 失败，清理后重试 1 次"
  virsh undefine "$GUEST_NAME" 2>/dev/null || true
  virsh define "$RENDER"
fi
echo "[✓] domain $GUEST_NAME 已定义"

# ---- 3. DHCP reservation ----
existing=$(virsh net-dumpxml default \
  | grep -E "<host mac=['\"]${GUEST_MAC}['\"]" || true)
if [ -n "$existing" ]; then
  virsh net-update default delete ip-dhcp-host \
    "<host mac='${GUEST_MAC}' name='${GUEST_NAME}' ip='${GUEST_IP}'/>" \
    --live --config 2>/dev/null \
    || echo "[~] 旧 reservation 删除失败，继续 add"
fi

virsh net-update default add ip-dhcp-host \
  "<host mac='${GUEST_MAC}' name='${GUEST_NAME}' ip='${GUEST_IP}'/>" \
  --live --config

echo "[✓] DHCP reservation: $GUEST_MAC → $GUEST_IP"

stage_done
