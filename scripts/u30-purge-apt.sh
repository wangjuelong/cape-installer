#!/usr/bin/env bash
# u30-purge-apt：apt purge cape 装的所有 apt 包
# 包括用 dpkg/checkinstall 装的自定义包：
#   - qemu (Custom antivm)            ← 来自 stage 50 的 kvm-qemu.sh qemu
#   - de4dot                          ← cape2.sh dependencies
#   - passivedns（如有）              ← cape2.sh passivedns（不在 all 里）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "u30-purge-apt"

# 用一组 glob 模式而非字面包名，apt 会展开。
# 注意顺序：依赖被依赖关系反过来，先 purge 上层再 purge 底层。
declare -a PURGE_PATTERNS=(
  # CAPE 自定义 dpkg
  qemu                                  # Custom antivm 包
  de4dot

  # MongoDB
  'mongodb-org*' 'mongodb-database-tools' 'mongodb-mongosh'

  # PostgreSQL
  'postgresql-18*' 'postgresql-client-18' 'postgresql-common' postgresql

  # 网络监控
  suricata 'suricata-update'

  # Yara — 通常 dpkg/checkinstall 装的包名是 yara
  yara

  # Tor
  tor 'deb.torproject.org-keyring'

  # KVM/libvirt（apt 装的）
  qemu-kvm 'qemu-system*' 'qemu-utils' 'qemu-block-extra'
  'libvirt-daemon-system' 'libvirt-clients' 'libvirt-dev'
  'libvirt-daemon-driver-qemu' 'libvirt-daemon-driver*'
  bridge-utils virtinst dnsmasq

  # mitmproxy（cape2.sh install_mitmproxy）
  mitmproxy
)

echo "==== 待 purge 的包（已装的才会真正 purge）===="
for p in "${PURGE_PATTERNS[@]}"; do
  matches=$(dpkg-query -W -f='${Package}\n' "$p" 2>/dev/null | head -10)
  if [ -n "$matches" ]; then
    echo "  $p:"
    echo "$matches" | sed 's/^/    /'
  fi
done

# apt purge 一波（DEBIAN_FRONTEND=noninteractive 防 dialog 卡住）
run env DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove "${PURGE_PATTERNS[@]}" 2>&1 | tail -30

# 再一遍 autoremove + purge 残留（孤儿依赖）
run env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y 2>&1 | tail -10

# apt 缓存
run apt-get clean

stage_done
