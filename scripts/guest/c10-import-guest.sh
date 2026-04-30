#!/usr/bin/env bash
# Stage c10-import-guest：校验 + 安置 qcow2 到 libvirt 镜像目录
# - 校验 sha256（侧文件 ${GUEST_QCOW2}.sha256 必须存在且一致）
# - 拷贝到 /var/lib/libvirt/images/${GUEST_NAME}.qcow2
# - chown libvirt-qemu:kvm
#
# 失败原则：sha256 不匹配 → 硬失败，提示 Mac 侧重传

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c10-import-guest"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_QCOW2="${GUEST_QCOW2:?GUEST_QCOW2 未传，必须显式指定}"
TARGET_DIR=/var/lib/libvirt/images
TARGET="$TARGET_DIR/${GUEST_NAME}.qcow2"

# ---- 幂等守卫 ----
if done_or_force \
   [ -f "$TARGET" ] \
   && [ -f "${GUEST_QCOW2}.sha256" ] \
   && (cd "$(dirname "$GUEST_QCOW2")" && sha256sum -c "$(basename "${GUEST_QCOW2}.sha256")") >/dev/null 2>&1 \
   && cmp -s "$GUEST_QCOW2" "$TARGET"; then
  echo "[~] $TARGET 已就位且哈希匹配，跳过"
  stage_done
  exit 0
fi

# ---- 1. 输入校验 ----
[ -f "$GUEST_QCOW2" ] || { echo "[-] GUEST_QCOW2 不存在: $GUEST_QCOW2"; exit 1; }
[ -f "${GUEST_QCOW2}.sha256" ] || {
  echo "[-] sha256 sidecar 不存在: ${GUEST_QCOW2}.sha256"
  echo "    Mac 上重跑 c-host-export.sh 生成 sidecar"
  exit 1
}

# ---- 2. 校验 sha256 ----
echo "[+] 校验 sha256"
if ! (cd "$(dirname "$GUEST_QCOW2")" && sha256sum -c "$(basename "${GUEST_QCOW2}.sha256")"); then
  echo "[-] sha256 不匹配——可能 scp 传坏了"
  echo "    Mac 上重跑: bash scripts/guest/c-host-export.sh -q <qcow2> -s <server>"
  exit 1
fi
echo "[✓] sha256 通过"

# ---- 3. qemu-img info 验证是合法 qcow2 ----
qemu-img info "$GUEST_QCOW2" | grep -q 'file format: qcow2' \
  || { echo "[-] $GUEST_QCOW2 不是合法 qcow2 格式"; exit 1; }
echo "[✓] qcow2 格式校验通过"

# ---- 4. 磁盘空间检查 ----
need_kb=$(qemu-img info --output=json "$GUEST_QCOW2" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["virtual-size"]//1024)')
avail_kb=$(df --output=avail "$TARGET_DIR" | tail -1)
if [ "$avail_kb" -lt "$need_kb" ]; then
  echo "[-] $TARGET_DIR 可用 ${avail_kb}KB < 需要 ${need_kb}KB"
  exit 1
fi
echo "[✓] 磁盘空间足"

# ---- 5. 安置 + chown ----
mkdir -p "$TARGET_DIR"
cp -f "$GUEST_QCOW2" "$TARGET"
chown libvirt-qemu:kvm "$TARGET"
chmod 0600 "$TARGET"
echo "[✓] 已拷贝到 $TARGET"

stage_done
