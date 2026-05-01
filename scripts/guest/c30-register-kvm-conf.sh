#!/usr/bin/env bash
# Stage c30-register-kvm-conf：把 cuckoo1 注册到 /opt/CAPEv2/conf/kvm.conf
# - [kvm] machines 追加（不覆盖，保留可能已有的 cuckoo2/3...）
# - 写 [${GUEST_NAME}] section 全部字段
# - 改之前先备份到 kvm.conf.bak.<TS>
#
# 用 crudini，与 stage 31-cape-config 一致

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c30-register-kvm-conf"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"
GUEST_TAGS="${GUEST_TAGS:-win10ltsc,x64,cape}"
GUEST_ARCH="${GUEST_ARCH:-x64}"
GUEST_PLATFORM="${GUEST_PLATFORM:-windows}"
SUBNET="${SUBNET:-192.168.122}"

CONF=/opt/CAPEv2/conf/kvm.conf
CRUDINI=$(command -v crudini)

[ -f "$CONF" ] || { echo "[-] $CONF 不存在——CAPE 还没装好"; exit 1; }

# ---- 幂等守卫 ----
# 仅检查 section 存在不够：upstream 默认 kvm.conf 自带示例 [cuckoo1] section，
# 但内容不对（arch=x86，无 snapshot=clean），且 [kvm] machines 仍是空。
# 必须同时验证：(1) cuckoo1 在 [kvm] machines 列表里 + (2) snapshot=clean 已设。
guard_check() {
  local current_machines current_snapshot
  current_machines=$(sudo -u cape "$CRUDINI" --get "$CONF" kvm machines 2>/dev/null || echo "")
  current_snapshot=$(sudo -u cape "$CRUDINI" --get "$CONF" "$GUEST_NAME" snapshot 2>/dev/null || echo "")
  echo ",$current_machines," | grep -q ",${GUEST_NAME}," \
    && [ "$current_snapshot" = "clean" ]
}
if done_or_force guard_check; then
  echo "[~] $GUEST_NAME 已注册到 [kvm] machines + snapshot=clean 已设，跳过"
  stage_done
  exit 0
fi

# ---- 1. 备份 ----
ts=$(date +%Y%m%d-%H%M%S)
cp "$CONF" "${CONF}.bak.${ts}"
echo "[✓] 备份 → ${CONF}.bak.${ts}"

# ---- 2. [kvm] machines 追加 ----
current=$(sudo -u cape "$CRUDINI" --get "$CONF" kvm machines 2>/dev/null || echo "")
if [ -z "$current" ]; then
  new="$GUEST_NAME"
else
  if echo ",$current," | grep -q ",${GUEST_NAME},"; then
    new="$current"
  else
    new="${current},${GUEST_NAME}"
  fi
fi
sudo -u cape "$CRUDINI" --set "$CONF" kvm machines "$new"
sudo -u cape "$CRUDINI" --set "$CONF" kvm interface virbr0
echo "[✓] [kvm] machines = $new"

# ---- 3. 写 [GUEST_NAME] section ----
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" label "$GUEST_NAME"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" platform "$GUEST_PLATFORM"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" ip "$GUEST_IP"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" snapshot clean
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" arch "$GUEST_ARCH"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" tags "$GUEST_TAGS"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" resultserver_ip "${SUBNET}.1"
sudo -u cape "$CRUDINI" --set "$CONF" "$GUEST_NAME" resultserver_port 2042
echo "[✓] [$GUEST_NAME] section 写入完成（tags=$GUEST_TAGS, arch=$GUEST_ARCH）"

stage_done
