#!/usr/bin/env bash
# Stage 31-cape-config：CAPE conf 文件矫正
# - cuckoo.conf [resultserver] ip = ${SUBNET}.1（默认 192.168.1.1 与 virbr0 不符）
# - kvm.conf machines = （空，Phase B 范围内不含 guest，cape 服务 mask）
# - mask cape & cape-processor（无 guest 时它们必败重启刷日志）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "31-cape-config"

CAPE_ROOT=/opt/CAPEv2
SUBNET="${SUBNET:-192.168.122}"
EXPECTED_IP="${SUBNET}.1"

CRUDINI=$(command -v crudini)

# ---- 幂等守卫 ----
current_ip=$(sudo -u cape "$CRUDINI" --get "$CAPE_ROOT/conf/cuckoo.conf" resultserver ip 2>/dev/null || echo "")
current_machines=$(sudo -u cape "$CRUDINI" --get "$CAPE_ROOT/conf/kvm.conf" kvm machines 2>/dev/null || echo "?")
if done_or_force [ "$current_ip" = "$EXPECTED_IP" ] \
   && [ -z "$current_machines" ] \
   && [ -L /etc/systemd/system/cape.service ] \
   && [ -L /etc/systemd/system/cape-processor.service ]; then
  echo "[~] CAPE conf 已正、cape services 已 mask，跳过"
  stage_done
  exit 0
fi

# ---- 1. 改 resultserver_ip ----
sudo -u cape "$CRUDINI" --set "$CAPE_ROOT/conf/cuckoo.conf" resultserver ip "$EXPECTED_IP"
echo "[✓] cuckoo.conf [resultserver] ip = $EXPECTED_IP"

# ---- 2. machinery=kvm 确认 ----
sudo -u cape "$CRUDINI" --set "$CAPE_ROOT/conf/cuckoo.conf" cuckoo machinery kvm
echo "[✓] cuckoo.conf machinery = kvm"

# ---- 3. 清空 kvm.conf machines ----
sudo -u cape "$CRUDINI" --set "$CAPE_ROOT/conf/kvm.conf" kvm machines ""
echo "[✓] kvm.conf machines = (空) — Phase B 范围内无 guest VM"

# ---- 4. mask cape + cape-processor ----
# 这两个服务在没 guest 时必失败 + restart loop。等用户加完客户机再 unmask。
systemctl stop cape cape-processor 2>/dev/null || true
systemctl mask cape cape-processor 2>/dev/null || true
echo "[✓] cape & cape-processor 已 mask（待 Phase C 加客户机后 unmask）"

stage_done
