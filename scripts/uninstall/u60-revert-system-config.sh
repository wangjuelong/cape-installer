#!/usr/bin/env bash
# u60-revert-system-config：还原 cape-installer + cape2.sh + kvm-qemu.sh 对系统的所有改动
# 涵盖：
#   - apt 镜像/keyrings/sources
#   - /etc/pip.conf / /etc/environment / /etc/sudoers.d
#   - /etc/sysctl.conf / /etc/security/limits.conf 注入
#   - /etc/iproute2/rt_tables 注入
#   - /etc/tor/torrc 注入
#   - git config --system url.gh-proxy.insteadOf
#   - /etc/modprobe.d/kvm.conf / /etc/udev/rules.d/50-qemu-kvm.rules
#   - /etc/sleep.target /etc/suspend.target etc 还原（kvm-qemu.sh 把这些 mask 到 /dev/null）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u60-revert-system-config"

remove() {
  if [ -e "$1" ] || [ -L "$1" ]; then run rm -f "$1"; printf '  [removed] %s\n' "$1"; fi
}

# ---- 1. apt 镜像 / keyrings / sources ----
echo "==== apt 镜像 + keyrings + sources ===="
remove /etc/apt/sources.list.d/mongodb.list
remove /etc/apt/sources.list.d/pgdg.list
remove /etc/apt/sources.list.d/tor.list
for f in /etc/apt/sources.list.d/oisf-ubuntu-suricata-*.list \
         /etc/apt/sources.list.d/oisf-ubuntu-suricata-*.sources; do
  [ -e "$f" ] && remove "$f"
done
remove /etc/apt/sources.list.d/docker.list

remove /etc/apt/keyrings/mongo.gpg
remove /etc/apt/keyrings/docker.gpg
remove /usr/share/keyrings/deb.torproject.org-keyring.gpg
remove /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg

# 还原 cloud-init 的 apt 代理（cape-installer 把它重命名为 .disabled）
if [ -f /etc/apt/apt.conf.d/90curtin-aptproxy.disabled ] \
   && [ ! -f /etc/apt/apt.conf.d/90curtin-aptproxy ]; then
  run mv /etc/apt/apt.conf.d/90curtin-aptproxy.disabled /etc/apt/apt.conf.d/90curtin-aptproxy
  echo "  [restored] /etc/apt/apt.conf.d/90curtin-aptproxy"
fi

# 还原 ubuntu.sources（10-mirrors 切到了 TUNA 镜像）
for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  if [ -f "${f}.bak" ] && [ -f "$f" ]; then
    run mv "${f}.bak" "$f"
    echo "  [restored] $f"
  fi
done

# 删 apt preferences pin（kvm-qemu.sh 写的）
remove /etc/apt/preferences.d/cape

# ---- 2. /etc/pip.conf ----
echo "==== pip 镜像 ===="
if [ -f /etc/pip.conf ] && grep -q 'tuna.tsinghua.edu.cn' /etc/pip.conf; then
  remove /etc/pip.conf
fi

# ---- 3. /etc/environment ----
if [ -f /etc/environment ] && grep -qE '^PIP_INDEX_URL=|^PIP_TRUSTED_HOST=' /etc/environment; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY-RUN] sed -i '/^PIP_INDEX_URL=/d;/^PIP_TRUSTED_HOST=/d' /etc/environment"
  else
    sed -i '/^PIP_INDEX_URL=/d;/^PIP_TRUSTED_HOST=/d' /etc/environment
    echo "  [edited]  /etc/environment 移除 PIP_*"
  fi
fi

# ---- 4. /etc/sudoers.d ----
echo "==== sudoers ===="
remove /etc/sudoers.d/cape
remove /etc/sudoers.d/ip_netns
remove /etc/sudoers.d/tcpdump
remove /etc/sudoers.d/99-cape-mirror
remove /etc/sudoers.d/99-cape-deploy

# ---- 5. /etc/sysctl.conf 注入项 ----
# cape2.sh 加的几行；用 sed 删（精确匹配）
echo "==== sysctl ===="
SYSCTL_KEYS=(
  '^fs.file-max'
  '^net.ipv6.conf.all.disable_ipv6'
  '^net.ipv6.conf.default.disable_ipv6'
  '^net.ipv6.conf.lo.disable_ipv6'
  '^net.bridge.bridge-nf-call-ip6tables'
  '^net.bridge.bridge-nf-call-iptables'
  '^net.bridge.bridge-nf-call-arptables'
  '^net.ipv4.ip_forward='
)
for k in "${SYSCTL_KEYS[@]}"; do
  if grep -qE "$k" /etc/sysctl.conf 2>/dev/null; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY-RUN] sed -i '/${k}/d' /etc/sysctl.conf"
    else
      sed -i "/${k}/d" /etc/sysctl.conf
    fi
    printf '  [edited]  /etc/sysctl.conf 移除 %s\n' "${k#^}"
  fi
done

# ---- 6. /etc/security/limits.conf ----
echo "==== limits ===="
LIMIT_LINES=(
  '^\* soft nofile 1048576'
  '^\* hard nofile 1048576'
  '^root soft nofile 1048576'
  '^root soft hard 1048576'
)
for k in "${LIMIT_LINES[@]}"; do
  if grep -qE "$k" /etc/security/limits.conf 2>/dev/null; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY-RUN] sed -i '/${k}/d' /etc/security/limits.conf"
    else
      sed -i "/${k}/d" /etc/security/limits.conf
    fi
    printf '  [edited]  /etc/security/limits.conf 移除 %s\n' "${k#^}"
  fi
done

# ---- 7. /etc/iproute2/rt_tables ----
if [ -f /etc/iproute2/rt_tables ] && grep -q '^400 ' /etc/iproute2/rt_tables; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY-RUN] sed -i '/^400 /d' /etc/iproute2/rt_tables"
  else
    sed -i '/^400 /d' /etc/iproute2/rt_tables
    echo "  [edited]  /etc/iproute2/rt_tables 移除 400 路由表"
  fi
fi

# ---- 8. /etc/tor/torrc ----
echo "==== tor 配置 ===="
if [ -f /etc/tor/torrc ]; then
  TOR_KEYS=('^TransPort' '^DNSPort' '^NumCPUs' '^SocksTimeout' '^ControlPort' '^HashedControlPassword')
  for k in "${TOR_KEYS[@]}"; do
    if grep -qE "$k" /etc/tor/torrc; then
      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[DRY-RUN] sed -i '/${k}/d' /etc/tor/torrc"
      else
        sed -i "/${k}/d" /etc/tor/torrc
      fi
    fi
  done
fi

# ---- 9. KVM 模块/udev 配置 ----
echo "==== KVM 模块/udev ===="
remove /etc/modprobe.d/kvm.conf
remove /etc/udev/rules.d/50-qemu-kvm.rules

# ---- 10. kvm-qemu.sh 把 sleep/suspend 等 mask 到 /dev/null，还原 ----
echo "==== sleep/suspend targets 还原 ===="
for tgt in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  l="/etc/systemd/system/$tgt"
  if [ -L "$l" ] && [ "$(readlink "$l")" = "/dev/null" ]; then
    run rm -f "$l"
    printf '  [restored] %s\n' "$l"
  fi
done

# ---- 11. git config --system insteadOf ----
echo "==== git config --system url.gh-proxy.insteadOf ===="
if git config --system --get-all url.https://gh-proxy.com/https://github.com/.insteadOf >/dev/null 2>&1; then
  run git config --system --unset-all url.https://gh-proxy.com/https://github.com/.insteadOf
  echo "  [removed] system git insteadOf"
fi

# ---- 12. needrestart 配置（kvm-qemu.sh 改为自动重启）----
if [ -f /etc/needrestart/needrestart.conf ] \
   && grep -q "^\$nrconf{restart} = 'a';" /etc/needrestart/needrestart.conf; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY-RUN] needrestart 还原为默认（注释 'a'）"
  else
    sed -i "s/^\\\$nrconf{restart} = 'a';/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf || true
    echo "  [edited]  needrestart 还原"
  fi
fi

# ---- 13. apparmor tcpdump complain/disable 状态（cape2.sh 用 aa-disable）----
# 不强行恢复（aa-enforce 可能影响 cape 残留进程，让用户手动决定）

stage_done
