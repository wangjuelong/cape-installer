#!/usr/bin/env bash
# Stage 10-mirrors：配国内镜像 + 禁用 cloud-init 默认 apt 代理
# - /etc/pip.conf → 清华 PyPI（global + install）
# - /etc/environment → PIP_INDEX_URL / PIP_TRUSTED_HOST（让 sudo 子进程也读）
# - /etc/sudoers.d/99-cape-mirror → env_keep 让 sudo 保留 PIP env
# - /etc/apt/apt.conf.d/90curtin-aptproxy → 重命名为 .disabled

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "10-mirrors"

# ---- 幂等守卫 ----
if done_or_force grep -q 'tuna.tsinghua' /etc/pip.conf 2>/dev/null \
   && [ ! -f /etc/apt/apt.conf.d/90curtin-aptproxy ]; then
  echo "[~] 镜像/代理已配置过，跳过"
  stage_done
  exit 0
fi

# ---- /etc/pip.conf ----
cat > /etc/pip.conf <<'EOF'
[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
timeout = 60
retries = 3

[install]
trusted-host = pypi.tuna.tsinghua.edu.cn
EOF
chmod 644 /etc/pip.conf
echo "[✓] /etc/pip.conf → 清华 PyPI"

# ---- /etc/environment ----
if ! grep -q '^PIP_INDEX_URL=' /etc/environment 2>/dev/null; then
  cat >> /etc/environment <<'EOF'
PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn
EOF
  echo "[✓] /etc/environment += PIP_*"
fi

# ---- sudoers env_keep ----
cat > /etc/sudoers.d/99-cape-mirror <<'EOF'
Defaults env_keep += "PIP_INDEX_URL PIP_TRUSTED_HOST PIP_TIMEOUT POETRY_HOME"
EOF
chmod 440 /etc/sudoers.d/99-cape-mirror
visudo -cf /etc/sudoers.d/99-cape-mirror
echo "[✓] sudoers env_keep 已加"

# ---- 禁用 cloud-init 默认 apt 代理（这次踩到 192.168.2.228:7890 502）----
if [ -f /etc/apt/apt.conf.d/90curtin-aptproxy ]; then
  mv /etc/apt/apt.conf.d/90curtin-aptproxy /etc/apt/apt.conf.d/90curtin-aptproxy.disabled
  echo "[✓] 禁用 90curtin-aptproxy"
fi

# ---- 切 OS apt 主仓库到 TUNA（240 实测：cn.archive 15 B/s vs TUNA 11.8 MB/s）----
# Ubuntu 24.04 用新版 deb822 格式：/etc/apt/sources.list.d/ubuntu.sources
UBUNTU_SOURCES=/etc/apt/sources.list.d/ubuntu.sources
if [ -f "$UBUNTU_SOURCES" ] && grep -qE 'cn\.archive\.ubuntu\.com|security\.ubuntu\.com' "$UBUNTU_SOURCES"; then
  cp "$UBUNTU_SOURCES" "${UBUNTU_SOURCES}.bak"
  sed -i \
    -e 's|http://cn\.archive\.ubuntu\.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    -e 's|http://archive\.ubuntu\.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    -e 's|http://security\.ubuntu\.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    "$UBUNTU_SOURCES"
  echo "[✓] /etc/apt/sources.list.d/ubuntu.sources → 清华 TUNA"
fi
# 旧版 sources.list 也兜底（cloud-init 不一定用新版）
if [ -f /etc/apt/sources.list ] && grep -qE 'cn\.archive\.ubuntu\.com|security\.ubuntu\.com' /etc/apt/sources.list; then
  cp /etc/apt/sources.list /etc/apt/sources.list.bak
  sed -i \
    -e 's|http://cn\.archive\.ubuntu\.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    -e 's|http://archive\.ubuntu\.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    -e 's|http://security\.ubuntu\.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
    /etc/apt/sources.list
  echo "[✓] /etc/apt/sources.list → 清华 TUNA"
fi

# ---- apt-get update（让新源生效；retry 3 次防瞬断）----
retry 3 5 apt-get update -qq

stage_done
