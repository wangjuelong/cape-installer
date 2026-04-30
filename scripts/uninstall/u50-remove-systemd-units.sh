#!/usr/bin/env bash
# u50-remove-systemd-units：删 cape2.sh / cape-installer 写入的 systemd unit
# apt purge 会带走自己的 unit（postgresql.service 等），但不会带走：
#   - cape*.service（cape2.sh 单独装的）
#   - mongodb.service（cape2.sh 自定义版，不是 apt 自带的 mongod.service）
#   - enable-transparent-huge-pages.service（cape2.sh 写的）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u50-remove-systemd-units"

# /lib/systemd/system 下 cape2.sh 写入的
LIB_UNITS=(
  cape.service cape-processor.service cape-rooter.service cape-web.service
  cape-dist.service cape-fstab.service
  mongodb.service                                    # cape2.sh 自定义版
  enable-transparent-huge-pages.service
  guacd.service guac-web.service                     # 没在 all 里但 cape2.sh 可能写过
)

# /etc/systemd/system 下 mask 留下的 → /dev/null 符号链接
ETC_UNITS=(
  cape.service cape-processor.service
)

remove_unit() {
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    run rm -f "$path"
    printf '  [removed] %s\n' "$path"
  fi
}

echo "==== /lib/systemd/system unit ===="
for u in "${LIB_UNITS[@]}"; do remove_unit "/lib/systemd/system/$u"; done
echo "==== /etc/systemd/system 下 mask 链接 ===="
for u in "${ETC_UNITS[@]}"; do remove_unit "/etc/systemd/system/$u"; done

# 任何遗留 systemd reset-failed
run_or_warn systemctl daemon-reload
run_or_warn systemctl reset-failed

stage_done
