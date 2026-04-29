#!/usr/bin/env bash
# u10-stop-services：停所有 cape 相关服务
# 顺序：先停应用层（cape*）→ 再停存储/网络（db、libvirt、suricata）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "u10-stop-services"

# 应用层 + Cuckoo 衍生服务
APP_SERVICES=(
  cape cape-processor cape-rooter cape-web cape-dist cape-fstab
  guacd guac-web
)

# 数据 / 网络 / 监控
INFRA_SERVICES=(
  mongodb mongod                 # cape2.sh 自定义的是 mongodb（多一个 b），原版是 mongod，全停
  postgresql
  suricata
  libvirtd virtlogd.socket
  enable-transparent-huge-pages
)

stop_one() {
  local svc=$1
  if systemctl list-unit-files "${svc}.service" "${svc}.socket" 2>/dev/null | grep -qE "^${svc}\."; then
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      run_or_warn systemctl stop "$svc"
      printf '  [stopped] %s\n' "$svc"
    else
      printf '  [skip]    %s（非 active）\n' "$svc"
    fi
    run_or_warn systemctl disable "$svc"
    run_or_warn systemctl unmask "$svc"   # mask 过的也解掉，避免之后 systemd state 混乱
  else
    printf '  [absent]  %s\n' "$svc"
  fi
}

echo "==== 停应用服务 ===="
for s in "${APP_SERVICES[@]}"; do stop_one "$s"; done

echo "==== 停基础服务 ===="
for s in "${INFRA_SERVICES[@]}"; do stop_one "$s"; done

# tcpdump / dnsmasq 进程可能由 libvirtd 拉起，停 libvirtd 后会自动消失，不强杀

stage_done
