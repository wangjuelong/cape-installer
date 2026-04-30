#!/usr/bin/env bash
# u10-stop-services：停所有 cape 相关 *应用* 服务
#
# 设计：**不停 mongodb / postgresql** —— 留给 u20 直接备份（不用再 start），
# 让 u30 apt purge 时自动 stop。这避免一来回 8 秒的 start/stop 浪费。
#
# suricata / libvirtd 没数据要备份，这里直接停。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u10-stop-services"

# 把不会被 u20 用到的服务一次性 stop + disable + unmask。
# 批量调用：systemctl 接受多个 unit name 参数，一次比 N 次系统调用快很多。
SERVICES=(
  cape cape-processor cape-rooter cape-web cape-dist cape-fstab
  guacd guac-web
  suricata
  libvirtd virtlogd.socket
  enable-transparent-huge-pages
)

# 过滤出实际存在的 unit（避免对 absent unit 调 systemctl 浪费时间）
declare -a EXISTING=()
for s in "${SERVICES[@]}"; do
  if systemctl list-unit-files "${s}.service" "${s}.socket" 2>/dev/null | grep -qE "^${s}\."; then
    EXISTING+=("$s")
  else
    printf '  [absent]  %s\n' "$s"
  fi
done

if [ ${#EXISTING[@]} -gt 0 ]; then
  echo "==== 批量 stop ${#EXISTING[@]} 个服务 ===="
  printf '  %s\n' "${EXISTING[@]}"
  run_or_warn systemctl stop "${EXISTING[@]}"
  run_or_warn systemctl disable "${EXISTING[@]}"
  run_or_warn systemctl unmask "${EXISTING[@]}"
fi

# 显式说明数据库的处理时机
cat <<EOF

[~] mongodb / postgresql 此阶段不停 — u20 直接用它们备份后，u30 apt purge 时会自动 stop。
EOF

stage_done
