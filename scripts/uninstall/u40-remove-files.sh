#!/usr/bin/env bash
# u40-remove-files：删 cape 安装的所有非 apt 文件
# - /opt/CAPEv2 (主仓库 + venv)
# - /etc/poetry (poetry 安装器目录)
# - /data/db /data/configdb (mongo 数据；apt purge 后 mongo 没了，目录里数据已无意义)
# - /opt/PolarProxy /opt/mitmproxy (cape2.sh 部分附件目录)
# - /var/lib/{postgresql,mongodb} (apt purge 不一定带走的数据目录残留)
# - /tmp 残留

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u40-remove-files"

remove() {
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    run rm -rf "$path"
    printf '  [removed] %s\n' "$path"
  else
    printf '  [absent]  %s\n' "$path"
  fi
}

echo "==== /opt 及 CAPE 主体 ===="
remove /opt/CAPEv2
remove /etc/poetry
remove /opt/PolarProxy
remove /opt/mitmproxy

echo "==== mongo 数据目录 ===="
remove /data/db
remove /data/configdb
# 仅当 /data 此时为空（cape 用过的两个子目录已删）才删 /data 本身
if [ -d /data ] && [ -z "$(ls -A /data 2>/dev/null)" ]; then
  remove /data
else
  if [ -d /data ]; then
    echo "  [keep]    /data 还有别的内容（不是 cape 的，跳过）"
  fi
fi

echo "==== apt purge 后可能残留的数据目录 ===="
remove /var/lib/postgresql
remove /var/lib/mongodb
remove /var/log/mongodb
remove /var/log/postgresql
remove /var/log/suricata
remove /var/lib/suricata

echo "==== /tmp 缓存 ===="
for f in /tmp/cape*.sh /tmp/cape*.log /tmp/cape-config.sh \
         /tmp/cape2_install.log /tmp/kvm_qemu.log /tmp/kvm_seabios.log \
         /tmp/kvm-qemu.sh /tmp/qemu-9.2.2* /tmp/seabios* /tmp/yara* \
         /tmp/passivedns /tmp/poetry-installer* /tmp/libvirt-* \
         /tmp/de4dot* /tmp/DIE.deb /tmp/capa /tmp/v0.14.0.zip /tmp/libvmi*; do
  for g in $f; do remove "$g"; done
done

stage_done
