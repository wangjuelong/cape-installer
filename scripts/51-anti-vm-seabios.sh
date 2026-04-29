#!/usr/bin/env bash
# Stage 51-anti-vm-seabios：源码编 SeaBios 1.16.3 + 反 VM 检测补丁
# - GitHub archive 在中国可达
# - 跑 kvm-qemu.sh.patched seabios（patch + 编 + 替换 /usr/share/qemu/bios.bin）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
source "$REPO_ROOT/vendor/checksums.sh"
stage_init "51-anti-vm-seabios"

cd /tmp

# ---- 幂等守卫 ----
# 简单判据：bios.bin 存在 + 大小匹配 256K（apt 自带也是 256K，靠精确 sha 区分太脆弱）
# 退而求其次：看上次本 stage 是否成功（用 stage_done 的副作用判断 — 看 logs/51-anti-vm-seabios.log 里有 [+] Patched bios.bin placed）
SEABIOS_DONE_MARKER="$STATE_DIR/51-seabios.done"
if done_or_force [ -f "$SEABIOS_DONE_MARKER" ] && [ -f /usr/share/qemu/bios.bin ]; then
  echo "[~] seabios 反 VM 版已装（marker 在 $SEABIOS_DONE_MARKER），跳过"
  stage_done
  exit 0
fi

# ---- 1. 下载 + sha256（github.com 不通时走 gh-proxy）----
TARGZ="seabios_${SEABIOS_VERSION}.tar.gz"
SEABIOS_URL="$(gh_url "$SEABIOS_TARBALL_URL")"
if ! file_sha_ok "$TARGZ" "$SEABIOS_TARBALL_SHA256"; then
  echo "[+] 下载 SeaBios 源码: $SEABIOS_URL"
  retry 3 5 curl -fL --max-time 120 -o "$TARGZ" "$SEABIOS_URL"
  if ! file_sha_ok "$TARGZ" "$SEABIOS_TARBALL_SHA256"; then
    echo "[-] sha256 校验失败"; exit 1
  fi
fi
echo "[✓] $TARGZ 已就位（sha256 OK）"

# ---- 2. 跑 kvm-qemu.sh seabios ----
cp -f "$REPO_ROOT/vendor/kvm-qemu.sh.patched" /tmp/kvm-qemu.sh
chmod +x /tmp/kvm-qemu.sh
echo "[+] 跑 kvm-qemu.sh seabios（编译 ~3 min）"
sudo -E bash /tmp/kvm-qemu.sh seabios

# ---- 3. 写 done marker ----
ls -la /usr/share/qemu/bios.bin /usr/share/qemu/bios-256k.bin
touch "$SEABIOS_DONE_MARKER"
echo "[✓] marker 写入 $SEABIOS_DONE_MARKER"

# ---- 4. 重启 libvirtd 让新 bios 生效 ----
systemctl restart libvirtd

stage_done
