#!/usr/bin/env bash
# c-guest-prep-ubuntu22.sh — 在 Ubuntu 22.04 Server 客户机内以 root 跑
# 用途：
#   1. apt 源切 TUNA + 关 unattended-upgrades / apt-daily / motd-news
#   2. 关 ufw / cloud-init（避免覆盖 netplan）/ snap auto-refresh
#   3. 装 Python 3 + 拉 agent.py
#   4. systemd unit 自启动 agent.py
#   5. netplan 配静态 IP（默认 192.168.122.106 cuckoo2 网段）
#   6. getty@tty1 autologin → analyst（防止冷启时停在 console login）
#   7. shutdown -h now
#
# 用法（VM 内 root 或 sudo 跑）：
#   sudo bash c-guest-prep-ubuntu22.sh           # 用默认 cuckoo2 参数
#   sudo bash c-guest-prep-ubuntu22.sh \
#     --guest-ip 192.168.122.106 \
#     --user analyst
#
# 不同 cuckoo 用 --guest-ip 调整网段；Windows 客户机走 c-guest-prep[-win7].ps1。

set -euo pipefail

# ---- 默认参数 ----
GUEST_IP="${GUEST_IP:-192.168.122.106}"
GATEWAY_IP="${GATEWAY_IP:-192.168.122.1}"
PREFIX="${PREFIX:-24}"
DNS_SERVER="${DNS_SERVER:-192.168.122.1}"
AGENT_URL="${AGENT_URL:-https://gh-proxy.com/https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py}"
ANALYST_USER="${ANALYST_USER:-analyst}"
NO_SHUTDOWN="${NO_SHUTDOWN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --guest-ip)     GUEST_IP="$2"; shift 2 ;;
    --gateway)      GATEWAY_IP="$2"; shift 2 ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --dns)          DNS_SERVER="$2"; shift 2 ;;
    --user)         ANALYST_USER="$2"; shift 2 ;;
    --agent-url)    AGENT_URL="$2"; shift 2 ;;
    --no-shutdown)  NO_SHUTDOWN=1; shift ;;
    *) echo "[-] 未知参数: $1"; exit 1 ;;
  esac
done

step() { printf '\e[36m[+] %s\e[0m\n' "$*"; }
ok()   { printf '\e[32m[✓] %s\e[0m\n' "$*"; }
warn() { printf '\e[33m[!] %s\e[0m\n' "$*"; }
die()  { printf '\e[31m[-] %s\e[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "必须 root（sudo bash $0）"

# ---- 0. 校验 OS 是 22.04 ----
if ! grep -q "VERSION_ID=\"22.04\"" /etc/os-release 2>/dev/null; then
  warn "OS 不是 Ubuntu 22.04（$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)） —— 继续，但脚本是为 22.04 写的"
fi
ok "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2-)"

# ---- 1. apt 源切 TUNA ----
step "切 apt 源 → TUNA"
SOURCES=/etc/apt/sources.list
if ! grep -q "mirrors.tuna.tsinghua.edu.cn" "$SOURCES" 2>/dev/null; then
  cp "$SOURCES" "$SOURCES.bak.$(date +%s)"
  cat > "$SOURCES" <<'EOF'
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ jammy-security main restricted universe multiverse
EOF
  apt-get update -y 2>&1 | tail -3
  ok "apt 源 = TUNA + apt-get update OK"
else
  ok "apt 源已是 TUNA"
fi

# ---- 2. 关 unattended-upgrades / apt-daily / motd-news ----
step "关自动更新机制（unattended-upgrades / apt-daily / motd-news）"
systemctl disable --now apt-daily.timer apt-daily.service \
  apt-daily-upgrade.timer apt-daily-upgrade.service \
  unattended-upgrades.service \
  motd-news.timer motd-news.service 2>/dev/null || true
# 也禁用 apt 配置层
cat > /etc/apt/apt.conf.d/99cape-disable-auto <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
ok "自动更新已关"

# ---- 3. 关 ufw / iptables（sandbox 内任意出网保留给 sample）----
step "关 ufw"
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable 2>/dev/null || true
  systemctl disable --now ufw 2>/dev/null || true
fi
ok "ufw off"

# ---- 4. 禁用 cloud-init（防止下次启动覆盖 netplan）----
step "禁用 cloud-init"
if [ -d /etc/cloud ]; then
  touch /etc/cloud/cloud-init.disabled
  systemctl disable cloud-init.service cloud-init-local.service \
    cloud-config.service cloud-final.service 2>/dev/null || true
  ok "cloud-init disabled（/etc/cloud/cloud-init.disabled flag）"
else
  ok "cloud-init 未装，跳过"
fi

# ---- 5. 关 snap auto-refresh（如装了）----
step "关 snap auto-refresh"
if command -v snap >/dev/null 2>&1; then
  snap set system refresh.timer=fri,sat,sun02:00-04:00 2>/dev/null || true
  snap set system refresh.hold=forever 2>/dev/null || true
  ok "snap refresh held"
else
  ok "snap 未装，跳过"
fi

# ---- 6. 装 Python 3 + curl + 必要工具 ----
step "装 Python3 + curl + strace（Linux analyzer 用）"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-pip curl ca-certificates strace 2>&1 | tail -3
ok "Python: $(python3 --version) | curl: $(curl --version | head -1 | awk '{print $2}')"

# ---- 7. 建 analyst 用户（如果不存在）----
step "确认 analyst 用户存在"
if ! id "$ANALYST_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$ANALYST_USER"
  echo "${ANALYST_USER}:cape123" | chpasswd
  ok "用户 $ANALYST_USER 创建（默认密码 cape123，OOBE 时建议改）"
else
  ok "用户 $ANALYST_USER 已存在"
fi

# ---- 8. 拉 agent.py 到 /home/analyst/ ----
step "拉 agent.py → /home/$ANALYST_USER/agent.py"
AGENT_PATH="/home/$ANALYST_USER/agent.py"
if [ ! -s "$AGENT_PATH" ]; then
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 30 -o "$AGENT_PATH" "$AGENT_URL"; then
      break
    fi
    warn "agent.py 拉取失败 (attempt $i)，重试"
    sleep 5
  done
fi
[ -s "$AGENT_PATH" ] || die "agent.py 拉取最终失败 - 检查网络 / AGENT_URL"
chown "$ANALYST_USER:$ANALYST_USER" "$AGENT_PATH"
chmod 0644 "$AGENT_PATH"
ok "agent.py: $(wc -c < "$AGENT_PATH") bytes"

# ---- 9. systemd unit 自启动 agent.py ----
step "systemd: cape-agent.service"
cat > /etc/systemd/system/cape-agent.service <<EOF
[Unit]
Description=CAPE Sandbox Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ANALYST_USER
WorkingDirectory=/home/$ANALYST_USER
ExecStart=/usr/bin/python3 /home/$ANALYST_USER/agent.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cape-agent.service
ok "cape-agent.service enabled（重启后自启）"

# ---- 10. netplan 静态 IP ----
step "netplan 静态 IP $GUEST_IP/$PREFIX gw=$GATEWAY_IP"
# 先清理 /etc/netplan/*.yaml 里的 DHCP 配置
ls /etc/netplan/*.yaml >/dev/null 2>&1 && {
  mkdir -p /etc/netplan/backup
  mv /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
}
# 探测 NIC 名（22.04 server 通常是 enp1s0 / ens3 / eth0）
NIC=$(ip -o link show | awk -F': ' '!/lo|virbr|docker/{print $2; exit}' | sed 's/@.*//')
[ -n "$NIC" ] || die "没找到非 loopback 网卡"
cat > /etc/netplan/01-cape.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $NIC:
      dhcp4: no
      addresses: [$GUEST_IP/$PREFIX]
      routes:
        - to: default
          via: $GATEWAY_IP
      nameservers:
        addresses: [$DNS_SERVER]
EOF
chmod 0600 /etc/netplan/01-cape.yaml
netplan apply 2>&1 | head -5 || warn "netplan apply 报错，重启后再生效"
ok "netplan written（NIC=$NIC）"

# ---- 11. autologin on tty1（agent.py 走 systemd，autologin 是为冷启便利不强必需）----
step "autologin tty1 → $ANALYST_USER"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $ANALYST_USER --noclear %I \$TERM
EOF
systemctl daemon-reload
ok "tty1 autologin 配好"

# ---- 12. 验证（不联网，纯本地检查）----
step "本地验证"
[ -x /usr/bin/python3 ] && ok "python3: /usr/bin/python3"
[ -f /etc/systemd/system/cape-agent.service ] && ok "cape-agent.service exists"
[ -f /etc/netplan/01-cape.yaml ] && ok "netplan 01-cape.yaml exists"
systemctl is-enabled cape-agent.service 2>&1 | grep -q enabled && ok "cape-agent enabled"

echo
echo "================================================================"
echo "              c-guest-prep-ubuntu22.sh 全部完成"
echo "================================================================"
echo

if [ "$NO_SHUTDOWN" = "1" ]; then
  warn "NO_SHUTDOWN=1 → 不自动关机，你自己 shutdown -h now 后再 host 端拍快照"
else
  step "60s 后关机（Ctrl+C 取消）"
  sleep 60
  shutdown -h now
fi
