#!/usr/bin/env bash
# Stage 20-host-stack：CAPE 主体 + 依赖（apt + cape2.sh.patched all）
# - 预克隆 /opt/CAPEv2（避免 cape2.sh 内部 clone，方便我们追加 pyproject 镜像）
# - 追加 [[tool.poetry.source]] tuna 到 pyproject.toml
# - 跑 vendor/cape2.sh.patched all <SUBNET>.1
#   该脚本内部会装：postgres、mongo（已 patch 走 tuna）、yara、suricata、systemd
#   注意：上游 buggy 的 `poetry pip install -r pyproject.toml` 已被我们注释掉，
#         真正的 venv 由 stage 30 用 `poetry install` 接管。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "20-host-stack"

CAPE_ROOT=/opt/CAPEv2
SUBNET="${SUBNET:-192.168.122}"
DB_PASSWORD="${DB_PASSWORD:-SuperPuperSecret}"

# ---- 幂等守卫：cape2.sh 装的关键东西齐 ----
if done_or_force \
   pkg_installed mongodb-org \
   && pkg_installed postgresql-18 \
   && pkg_installed suricata \
   && [ -d "$CAPE_ROOT/.git" ] \
   && [ -f "$CAPE_ROOT/conf/cuckoo.conf" ] \
   && grep -q 'name = "tuna"' "$CAPE_ROOT/pyproject.toml" 2>/dev/null; then
  echo "[~] host stack 已装好，跳过"
  stage_done
  exit 0
fi

# ---- 1. 预克隆 CAPEv2 到 /opt/CAPEv2 ----
if [ ! -d "$CAPE_ROOT/.git" ]; then
  retry 3 10 git clone --depth 1 https://github.com/kevoreilly/CAPEv2.git "$CAPE_ROOT"
  echo "[✓] git clone $CAPE_ROOT"
fi

# ---- 2. 追加 [[tool.poetry.source]] tuna 到 pyproject.toml ----
if ! grep -q 'name = "tuna"' "$CAPE_ROOT/pyproject.toml"; then
  cat "$REPO_ROOT/vendor/pyproject-tuna-source.toml" >> "$CAPE_ROOT/pyproject.toml"
  echo "[✓] pyproject.toml += [[tool.poetry.source]] tuna"
fi

# ---- 3. 准备 cape-config.sh（被 cape2.sh source 读取）----
cat > /tmp/cape-config.sh <<EOF
NETWORK_IFACE=virbr0
IFACE_IP=${SUBNET}.1
PASSWD="${DB_PASSWORD}"
USER=cape
MONGO_ENABLE=1
clamav_enable=0
librenms_enable=0
EOF
echo "[✓] /tmp/cape-config.sh"

# ---- 4. 拷 patched cape2.sh + cape-config.sh 到 /tmp（cape2.sh 期望 ./cape-config.sh）----
cp -f "$REPO_ROOT/vendor/cape2.sh.patched" /tmp/cape2.sh
chmod +x /tmp/cape2.sh

# ---- 5. 跑 cape2.sh all ----
# 重要：sudo -E 保留 PIP_* env vars
echo "[+] 跑 cape2.sh all（约 30 min，日志在 stage log）"
cd /tmp
sudo -E bash ./cape2.sh all "${SUBNET}.1"

# ---- 6. 补做 cape2.sh 漏掉的 mongo /data 初始化 ----
# cape2.sh 把 `chown /data` 写进 @reboot crontab，但部署当下没重启 → mongodb 用户写不了 /data/db。
# 这里立刻补做，避免 smoke test 时 mongod status=100。
if pkg_installed mongodb-org-server && id mongodb >/dev/null 2>&1; then
  mkdir -p /data/db /data/configdb
  chown -R mongodb:mongodb /data
  systemctl daemon-reload
  systemctl reset-failed mongodb 2>/dev/null || true
  systemctl restart mongodb
  echo "[✓] /data chown mongodb + mongod restart"
else
  echo "[!] mongodb-org-server 没装上 — 检查 vendor/mongodb-server-8.0.asc 和上游 keyring"
fi

stage_done
