#!/usr/bin/env bash
# Stage 40-kvm-libvirt：装 KVM/libvirt（apt 路线）+ 启动 default 网络 + 装 libvirt-python 进 cape venv
# - apt 装 qemu-kvm（占位，后面 stage 50 会换源码版）/ libvirt-daemon-system / libvirt-dev / bridge-utils / virtinst / dnsmasq
# - 把 cape 加入 kvm + libvirt 组
# - virsh net-autostart default + net-start default → virbr0 = ${SUBNET}.1/24
# - 跑 vendor/cape2.sh.patched libvirt（pip install libvirt-python==11.9.0 进 cape venv）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "40-kvm-libvirt"

SUBNET="${SUBNET:-192.168.122}"

# ---- 幂等守卫 ----
if done_or_force \
   pkg_installed libvirt-daemon-system \
   && pkg_installed libvirt-dev \
   && user_in_group cape libvirt \
   && user_in_group cape kvm \
   && net_active default \
   && sudo -u cape /opt/CAPEv2/.venv/bin/python -c 'import libvirt' >/dev/null 2>&1; then
  echo "[~] libvirt + virbr0 + libvirt-python 都已就绪，跳过"
  stage_done
  exit 0
fi

# ---- 1. apt 装 KVM/libvirt 全栈 ----
echo "[+] apt install qemu-kvm libvirt 全栈"
retry 3 5 apt-get install -y -qq \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  libvirt-dev \
  bridge-utils \
  virtinst \
  dnsmasq

# ---- 2. 起 libvirtd ----
systemctl enable --now libvirtd virtlogd.socket
echo "[✓] libvirtd active"

# ---- 3. cape 入 kvm + libvirt 组 ----
usermod -aG kvm,libvirt cape
echo "[✓] cape ∈ {kvm,libvirt}"

# ---- 4. default 网络 → virbr0 ${SUBNET}.1/24 ----
# default 网络默认就是 192.168.122.0/24（决策 Q3：用户选了 192.168.122.1）。
# 若 SUBNET 改成别的，需重定义 default。Phase 当前默认 192.168.122 走"什么也不改"路径。
if [ "$SUBNET" != "192.168.122" ]; then
  echo "[!] SUBNET=$SUBNET 不是 libvirt 默认 192.168.122 — 重定义 default 网络"
  cat > /tmp/default-net.xml <<EOF
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='${SUBNET}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${SUBNET}.2' end='${SUBNET}.254'/>
    </dhcp>
  </ip>
</network>
EOF
  virsh net-destroy default 2>/dev/null || true
  virsh net-undefine default 2>/dev/null || true
  virsh net-define /tmp/default-net.xml
fi
virsh net-autostart default 2>/dev/null || true
virsh net-start default 2>/dev/null || true
ip a show virbr0 | grep "inet "

# ---- 5. 装 libvirt-python 进 cape venv ----
echo "[+] 跑 cape2.sh libvirt（装 libvirt-python==11.9.0 进 venv）"
cp -f "$REPO_ROOT/vendor/cape2.sh.patched" /tmp/cape2.sh
chmod +x /tmp/cape2.sh
cd /tmp && sudo -E bash ./cape2.sh libvirt "${SUBNET}.1"

# ---- 6. sanity ----
sudo -u cape /opt/CAPEv2/.venv/bin/python -c \
  'import libvirt; print("libvirt-python ok, version:", libvirt.getVersion())'

stage_done
