#!/usr/bin/env bash
# u00-preflight：卸载预检
# - 必须 root
# - 必须 Ubuntu noble
# - 显示将要做什么 + 二次确认（YES=1 跳过、DRY_RUN=1 仅预演）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
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
即将卸载 CAPEv2 + 所有相关组件（预计耗时 ~30s），执行以下不可逆操作：

  1. 停应用服务（cape*/suricata/libvirtd）；mongo/pg 留给 u20 备份
  2. 备份 PostgreSQL 'cape' 库 + MongoDB 用户库到
     /var/backups/cape-uninstall-<TS>.{sql,mongo}
  3. apt purge: mongodb-org / postgresql-18 / suricata / yara /
     qemu* / libvirt* / tor / mitmproxy（连同 OS 数据）
  4. rm -rf：/opt/CAPEv2 /etc/poetry /data /opt/PolarProxy
              /opt/mitmproxy /var/lib/{postgresql,mongodb,suricata}
  5. 删 systemd unit、sysctl/limits/sudoers 修改、apt 镜像配置、
     git insteadOf、apt sources、GPG keyrings
  6. 删用户：cape (UID<1000 守卫保护登录用户)、mongodb
  7. 清理 root crontab 里 cape2.sh 加的条目

DRY-RUN 模式可预演："DRY_RUN=1 sudo make uninstall"
================================================================

EOF

# ---- 自删用户预警（240 验证踩过的坑）----
# 如果 sudo 调用者就是即将被 u70 处理的用户，提示一下。
# u70 已加了 UID >= 1000 的安全门，但仍要让用户知晓。
if [ -n "${SUDO_USER:-}" ]; then
  for u in cape mongodb; do
    if [ "$SUDO_USER" = "$u" ]; then
      uid=$(id -u "$u" 2>/dev/null || echo 99999)
      if [ "$uid" -lt 1000 ]; then
        cat <<WARN

[!!!] 当前 sudo 调用者 = '$u' (UID=$uid) 是 cape2.sh 系统用户。
      u70 会删它 → SSH 会话可能在卸载途中断开 → 你可能进不来这台机器！
      建议先以 root 或另一个 sudoer 身份登录再跑卸载。

WARN
      else
        printf "[~] 当前 sudo 调用者 = '%s' (UID=%d) 是 OS 登录用户，u70 守卫将保护它不被删。\n\n" "$u" "$uid"
      fi
    fi
  done
fi

if [ "${YES:-0}" != "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
  exec </dev/tty 2>/dev/null || { echo "[-] 无 tty 且未带 YES=1，拒绝执行"; exit 1; }
  read -rp '输入 "yes" 确认继续，其他任何输入将取消: ' ans
  [ "$ans" = "yes" ] || { echo "[~] 已取消"; exit 1; }
fi

echo "[✓] 已确认，开始卸载"
mkdir -p /var/backups
stage_done
