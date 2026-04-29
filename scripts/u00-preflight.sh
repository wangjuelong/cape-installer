#!/usr/bin/env bash
# u00-preflight：卸载预检
# - 必须 root
# - 必须 Ubuntu noble
# - 显示将要做什么 + 二次确认（YES=1 跳过、DRY_RUN=1 仅预演）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "u00-preflight"

[ "$(id -u)" = "0" ] || { echo "[-] 必须 root"; exit 1; }

. /etc/os-release
[ "${VERSION_CODENAME:-}" = "noble" ] || echo "[!] 非 noble (当前 ${VERSION_CODENAME:-?})，仍尝试卸载"

if [ "${DRY_RUN:-0}" = "1" ]; then
  cat <<EOF

================================================================
       DRY-RUN 模式 — 仅打印将执行的命令，不会动任何东西
================================================================
EOF
fi

cat <<EOF

================================================================
                    !!!  危险操作警告  !!!
----------------------------------------------------------------
即将卸载 CAPEv2 + 所有相关组件，执行以下不可逆操作：

  1. 停止并禁用：cape*, mongodb, postgresql, suricata, libvirtd
  2. 备份 PostgreSQL 'cape' 库到 /var/backups/cape-uninstall-<TS>.sql
  3. apt purge: mongodb-org / postgresql-18 / suricata / yara /
     qemu* / libvirt* / tor （连同它们的 OS 数据）
  4. rm -rf：/opt/CAPEv2 /etc/poetry /data /opt/PolarProxy
              /opt/mitmproxy /var/lib/postgresql /var/lib/mongodb
  5. 删除 systemd unit、sysctl/limits/sudoers 修改、apt 镜像配置、
     git insteadOf、apt sources、GPG keyrings
  6. 删除用户：cape（连同 /home/cape）、mongodb
  7. 清理 root crontab 里 cape2.sh 加的条目

DRY-RUN 模式可预演："DRY_RUN=1 sudo make uninstall"
================================================================

EOF

if [ "${YES:-0}" != "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
  exec </dev/tty 2>/dev/null || { echo "[-] 无 tty 且未带 YES=1，拒绝执行"; exit 1; }
  read -rp '输入 "yes" 确认继续，其他任何输入将取消: ' ans
  [ "$ans" = "yes" ] || { echo "[~] 已取消"; exit 1; }
fi

echo "[✓] 已确认，开始卸载"
mkdir -p /var/backups
stage_done
