#!/usr/bin/env bash
# Stage 00-preflight：环境校验
# - 必须 Ubuntu 24.04 noble
# - 必须 x86_64
# - 必须支持嵌套虚拟化（vmx）
# - 磁盘 ≥ 50G、内存 ≥ 16G
# - GitHub / GitLab / 清华镜像都可达

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "00-preflight"

# ---- OS 校验 ----
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { echo "[-] 非 Ubuntu (ID=$ID)"; exit 1; }
[ "${VERSION_CODENAME:-}" = "noble" ] || { echo "[-] 仅支持 24.04 noble (当前 $VERSION_CODENAME)"; exit 1; }
echo "[✓] OS = Ubuntu $VERSION_ID ($VERSION_CODENAME)"

# ---- 架构 ----
[ "$(uname -m)" = "x86_64" ] || { echo "[-] 仅支持 x86_64"; exit 1; }
echo "[✓] arch = x86_64"

# ---- VT-x ----
grep -q '^flags.*\bvmx\b' /proc/cpuinfo \
  || { echo "[-] 缺 vmx flag — 嵌套虚拟化未启用"; exit 1; }
echo "[✓] vmx 可用"

# ---- 资源 ----
mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
[ "$mem_gb" -ge 14 ] || { echo "[-] 内存 ${mem_gb}G < 16G"; exit 1; }
echo "[✓] 内存 ${mem_gb}G"

disk_gb=$(df --output=avail -BG / | tail -1 | tr -d 'G ')
[ "$disk_gb" -ge 45 ] || { echo "[-] / 可用 ${disk_gb}G < 50G"; exit 1; }
echo "[✓] / 可用 ${disk_gb}G"

# ---- 必备命令 ----
for cmd in curl wget git apt-get systemctl dpkg sudo; do
  command -v "$cmd" >/dev/null || { echo "[-] 缺命令: $cmd"; exit 1; }
done
echo "[✓] 必备命令齐"

# ---- 网络可达性（决策 Q1=D：允许中国网络硬假设）----
probe() {
  local url=$1 name=$2
  if curl -fsSI --max-time 10 "$url" >/dev/null 2>&1; then
    echo "[✓] $name 可达"
  else
    echo "[!] $name 不可达 ($url)"
    return 1
  fi
}
probe https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ "清华 Ubuntu"
probe https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/ubuntu/ "清华 MongoDB"
probe https://pypi.tuna.tsinghua.edu.cn/simple/ "清华 PyPI"
probe https://gitlab.com/ "GitLab"

# ---- GitHub 访问通道决策（240 这种 github.com HTTPS 被墙的环境会走 gh-proxy） ----
# state/github.env 内容供后续 stage source：GH_PROXY="" 或 "https://gh-proxy.com/"
if curl -fsSI --max-time 10 https://github.com/ >/dev/null 2>&1; then
  echo "[✓] GitHub 直连可达"
  echo 'GH_PROXY=' > "$STATE_DIR/github.env"
  # 清掉历史 insteadOf 设置（如果之前在不同环境配过）
  git config --system --unset-all url."https://gh-proxy.com/https://github.com/".insteadOf 2>/dev/null || true
else
  echo "[!] GitHub 直连不通，尝试 gh-proxy.com 镜像"
  if curl -fsSI --max-time 10 https://gh-proxy.com/ >/dev/null 2>&1; then
    echo "[✓] gh-proxy.com 可达"
    echo 'GH_PROXY=https://gh-proxy.com/' > "$STATE_DIR/github.env"
    # 全局 git insteadOf — cape2.sh 里所有 git clone github.com/... 自动重写
    git config --system url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"
    echo "[✓] 已配 git config --system url.<gh-proxy>.insteadOf"
  else
    echo "[-] github.com 和 gh-proxy.com 都不通，无法继续"
    exit 1
  fi
fi

# 这些「中国不可达」是已知的，仅 warn 不挂
probe https://raw.githubusercontent.com/ "GitHub raw（社区签名要走这里，挂了不影响主流程）" || true
probe https://download.qemu.org/ "qemu.org（已被 stage 50 用 GitLab 替代，挂了不影响）" || true

stage_done
