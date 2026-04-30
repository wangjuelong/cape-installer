#!/usr/bin/env bash
# u30-purge-apt：apt purge cape 装的所有 apt 包
# 包括用 dpkg/checkinstall 装的自定义包：
#   - qemu (Custom antivm)            ← 来自 stage 50 的 kvm-qemu.sh qemu
#   - de4dot                          ← cape2.sh dependencies
#   - passivedns（如有）              ← cape2.sh passivedns（不在 all 里）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
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

# !!! 240 验证踩到的坑 !!!
# 直接 `apt-get purge -y pat1 pat2 ...` 在任何一个 pat 不存在时**整批拒绝**。
# 比如 deb.torproject.org-keyring 没装 → 全部 22 个包都跳过 → mongodb 等仍在系统里。
# 解决：先用 dpkg-query 把每个 pattern 实际装着的具体包名展开成 TO_PURGE 数组，
# 再一次性 apt-get purge —— 全是真包，不会触发 "Unable to locate package" 整批失败。

list_installed() {
  dpkg-query -W -f='${Package}\n' "$1" 2>/dev/null || true
}

declare -a TO_PURGE=()
echo "==== 收集已装的目标包 ===="
for p in "${PURGE_PATTERNS[@]}"; do
  while IFS= read -r pkg; do
    [ -n "$pkg" ] && TO_PURGE+=("$pkg")
  done < <(list_installed "$p")
done

# 去重（同一个包可能被多个 pattern 匹中）
if [ ${#TO_PURGE[@]} -gt 0 ]; then
  readarray -t TO_PURGE < <(printf '%s\n' "${TO_PURGE[@]}" | sort -u)
  echo "  实际待 purge ${#TO_PURGE[@]} 个包："
  printf '    %s\n' "${TO_PURGE[@]}"
else
  echo "  没有任何 cape 相关 apt 包仍在系统中"
fi

if [ ${#TO_PURGE[@]} -gt 0 ]; then
  run_or_warn env DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove "${TO_PURGE[@]}"
fi

# 再一遍 autoremove + purge 残留（孤儿依赖）
run_or_warn env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y

# apt 缓存
run_or_warn apt-get clean

stage_done
