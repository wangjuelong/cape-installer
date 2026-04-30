#!/usr/bin/env bash
# u99-verify：卸载完成后清单核对，列出仍存在的残留（如有）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u99-verify"

LEFT=0
note() {
  echo "  [✗] $*"
  LEFT=$((LEFT + 1))
}
ok()  { echo "  [✓] $*"; }

echo "==== 残留检查 ===="

# ---- 1. 用户（UID >= 1000 是登录用户，u70 守卫故意保护，不算残留）----
check_user() {
  local u=$1
  if ! id "$u" >/dev/null 2>&1; then
    ok "用户 $u 已删"
    return
  fi
  local uid
  uid=$(id -u "$u")
  if [ "$uid" -lt 1000 ]; then
    note "系统用户 $u (UID=$uid) 仍存在 — u70 应当删而没删"
  else
    ok "用户 $u 保留 (UID=$uid 登录用户，u70 守卫保护)"
  fi
}
check_user cape
check_user mongodb

# ---- 2. 关键路径 ----
for p in /opt/CAPEv2 /etc/poetry /data/db /data/configdb /var/lib/postgresql /var/lib/mongodb; do
  [ -e "$p" ] && note "$p 仍存在" || ok "$p 已删"
done

# ---- 3. 关键 apt 包 ----
for pkg in mongodb-org postgresql-18 suricata yara qemu libvirt-daemon-system tor; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then note "apt 包 $pkg 仍装着"; else ok "apt 包 $pkg 已 purge"; fi
done

# ---- 4. systemd unit ----
for u in cape.service cape-processor.service cape-rooter.service cape-web.service \
         mongodb.service enable-transparent-huge-pages.service; do
  if [ -f "/lib/systemd/system/$u" ] || [ -L "/etc/systemd/system/$u" ]; then
    note "/lib(/etc)/systemd/system/$u 仍存在"
  else
    ok "$u 已删"
  fi
done

# ---- 5. 服务运行状态 ----
for s in cape cape-processor cape-rooter cape-web mongodb postgresql suricata libvirtd; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    note "服务 $s 仍 active"
  fi
done

# ---- 6. apt sources / keyrings ----
for f in /etc/apt/sources.list.d/mongodb.list /etc/apt/sources.list.d/pgdg.list \
         /etc/apt/sources.list.d/tor.list /etc/apt/keyrings/mongo.gpg \
         /etc/sudoers.d/cape /etc/sudoers.d/ip_netns /etc/sudoers.d/tcpdump \
         /etc/sudoers.d/99-cape-mirror; do
  [ -e "$f" ] && note "$f 仍存在"
done

# ---- 7. /etc/pip.conf 我们的镜像 ----
if [ -f /etc/pip.conf ] && grep -q tuna.tsinghua /etc/pip.conf; then
  note "/etc/pip.conf 仍含清华镜像配置"
fi

# ---- 8. cron 残留 ----
if crontab -l 2>/dev/null | grep -qE 'community.py|smtp_sinkhole|cleaners.py|signal newnym|/data/'; then
  note "root crontab 仍有 cape2.sh 写的条目"
fi

# ---- 9. 备份位置 ----
echo ""
echo "==== 备份文件位置 ===="
ls -lh /var/backups/cape-uninstall-* 2>/dev/null | head -10 || echo "  (无备份；u20 跳过或备份失败)"

echo ""
if [ "$LEFT" -eq 0 ]; then
  echo "[✓✓✓] 卸载完成，无残留"
else
  echo "[!] 仍有 $LEFT 项残留 — 见上方 [✗] 行；可能需要手动清理或重启系统"
fi

# ---- stage 用时统计 ----
echo ""
echo "==== 各 stage 实际耗时 ===="
total=0
for f in "$LOGS_DIR"/u*.log; do
  [ -f "$f" ] || continue
  start=$(grep -oE '^=====[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$f" | head -1 | awk '{print $2}')
  end=$(grep -oE '^=====[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$f" | tail -1 | awk '{print $2}')
  if [ -n "$start" ] && [ -n "$end" ]; then
    s=$(date -d "$start" +%s 2>/dev/null || echo 0)
    e=$(date -d "$end" +%s 2>/dev/null || echo 0)
    diff=$((e - s))
    total=$((total + diff))
    printf '  %-32s %3ds\n' "$(basename "$f" .log)" "$diff"
  fi
done
printf '  %-32s %3ds\n' "(合计)" "$total"

# 提示重启
echo ""
echo "建议：sudo reboot   # 让 sysctl 改动彻底失效"

stage_done
