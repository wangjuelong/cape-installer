#!/usr/bin/env bash
# Stage 50-anti-vm-qemu：源码编 QEMU 9.2.2 + 反 VM 检测补丁
# - 上游 download.qemu.org 在中国连接 reset → 改用 GitLab archive
# - GitLab archive 的 top-level 目录是 qemu-v9.2.2-<sha>/，需重命名为 qemu-9.2.2/
# - 重打包成 qemu-9.2.2.tar.xz 让 kvm-qemu.sh 找到
# - 跑 kvm-qemu.sh.patched qemu（应用 anti-VM clue 补丁，编译，dpkg 装）

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
source "$REPO_ROOT/vendor/checksums.sh"
stage_init "50-anti-vm-qemu"

# ---- 幂等守卫 ----
if done_or_force \
   dpkg -s qemu 2>/dev/null | grep -q '^Description:.*[Aa]ntivm' \
   && [ -x /usr/bin/qemu-system-x86_64 ] \
   && /usr/bin/qemu-system-x86_64 --version 2>/dev/null | grep -q "version $QEMU_VERSION"; then
  echo "[~] QEMU $QEMU_VERSION (Custom antivm) 已装，跳过"
  stage_done
  exit 0
fi

cd /tmp

# ---- 1. 拉 GitLab archive（带 sha256 校验 + 重试）----
TARGZ="qemu-${QEMU_VERSION}.tar.gz"
if ! file_sha_ok "$TARGZ" "$QEMU_TARBALL_SHA256"; then
  echo "[+] 下载 QEMU 源码 from GitLab"
  retry 3 5 curl -fL --max-time 600 -o "$TARGZ" "$QEMU_TARBALL_URL"
  if ! file_sha_ok "$TARGZ" "$QEMU_TARBALL_SHA256"; then
    echo "[-] sha256 校验失败"; exit 1
  fi
fi
echo "[✓] $TARGZ 已就位（sha256 OK）"

# ---- 2. 解压 + 重命名顶级目录 ----
rm -rf qemu-${QEMU_VERSION} qemu-v${QEMU_VERSION}-*
tar xzf "$TARGZ"
mv qemu-v${QEMU_VERSION}-* qemu-${QEMU_VERSION}
echo "[✓] 解压 + 重命名为 qemu-${QEMU_VERSION}/"

# ---- 3. 重打包成 .tar.xz（kvm-qemu.sh 期望此命名）----
# 注意：tar xf 自动识别压缩格式（不看扩展名），所以用 gzip 也 OK；为加速选 xz -1
echo "[+] 重打包为 qemu-${QEMU_VERSION}.tar.xz（多核 xz -1）"
tar c qemu-${QEMU_VERSION} | xz -T0 -1 > qemu-${QEMU_VERSION}.tar.xz
rm -rf qemu-${QEMU_VERSION}
echo "[✓] qemu-${QEMU_VERSION}.tar.xz 就位"

# ---- 4. 跑 kvm-qemu.sh qemu ----
# kvm-qemu.sh 的 install_qemu 会：发现 .tar.xz 已存在 → 跳过 wget → tar xf → patch → configure → make → dpkg 装
cp -f "$REPO_ROOT/vendor/kvm-qemu.sh.patched" /tmp/kvm-qemu.sh
chmod +x /tmp/kvm-qemu.sh
echo "[+] 跑 kvm-qemu.sh qemu（编译 ~30 min）"
sudo -E bash /tmp/kvm-qemu.sh qemu

# ---- 5. sanity ----
/usr/bin/qemu-system-x86_64 --version | head -1
dpkg -l | awk '$2=="qemu"{print "[✓] dpkg: "$0}'

stage_done
