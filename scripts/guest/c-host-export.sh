#!/usr/bin/env bash
# c-host-export.sh — 在 Intel Mac 上跑：校验 UTM qcow2 + 推送 CAPE 服务器
# 用途：UTM 客户机关机后，把 qcow2 文件 + sha256 sidecar 推到服务器
# 前置：
#   - UTM 客户机内已跑过 c-guest-prep.ps1 + 已关机
#   - Mac 上装了 qemu-img: brew install qemu
#   - Mac 上 ssh 能免密连服务器（或交互输入密码）

set -eEuo pipefail

# Defaults
SERVER=
SERVER_USER=cape
SERVER_PATH=/tmp/cuckoo1.qcow2
QCOW2=
SCP_RETRIES=3

usage() {
  cat <<EOF
用法: bash c-host-export.sh -q <qcow2> -s <server> [-u <user>] [-p <remote-path>]

参数:
  -q  本地 qcow2 路径（UTM VM 的磁盘文件）
  -s  CAPE 服务器地址（必填）
  -u  服务器用户（默认 cape）
  -p  服务器目标路径（默认 /tmp/cuckoo1.qcow2）

定位 UTM qcow2:
  默认 UTM 把 VM 存在
  ~/Library/Containers/com.utmapp.UTM/Data/Documents/<VM>.utm/Data/<disk>.qcow2

  Finder 中右键 .utm 文件 → "显示包内容" 进入 Data 目录定位 qcow2
EOF
}

while getopts "q:s:u:p:h" opt; do
  case "$opt" in
    q) QCOW2=$OPTARG ;;
    s) SERVER=$OPTARG ;;
    u) SERVER_USER=$OPTARG ;;
    p) SERVER_PATH=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Color logging
C_CYN=$'\033[36m'; C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YLW=$'\033[33m'; C_RST=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$C_CYN" "$C_RST" "$*" >&2; }
ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[-]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---- 1. 参数校验 ----
[ -n "$QCOW2"  ] || { usage; die '缺 -q <qcow2>'; }
[ -n "$SERVER" ] || { usage; die '缺 -s <server>'; }
[ -f "$QCOW2"  ] || die "qcow2 不存在: $QCOW2"

# ---- 2. qemu-img 必须存在 ----
command -v qemu-img >/dev/null \
  || die "找不到 qemu-img。装：brew install qemu"
ok "qemu-img: $(qemu-img --version | head -1)"

# ---- 3. 检查 qcow2 合法格式 ----
log '校验 qcow2 格式'
qemu-img info "$QCOW2" | grep -q 'file format: qcow2' \
  || die "$QCOW2 不是合法 qcow2"
ok 'qcow2 格式 OK'

# ---- 4. 检查无 backing file ----
if qemu-img info "$QCOW2" | grep -q '^backing file:'; then
  die "$QCOW2 有 backing file（来自 UTM 快照）。在 UTM 删除快照让镜像 standalone 后重试"
fi
ok '无 backing file 依赖'

# ---- 5. 检查 VM 没在跑 ----
if pgrep -f "qemu-system-x86_64.*$(basename "$QCOW2")" >/dev/null; then
  die 'VM 仍在运行——UTM 里关闭客户机后重试'
fi
ok 'VM 未运行'

# ---- 6. 算 sha256 sidecar ----
log '算 sha256'
sha256_file="${QCOW2}.sha256"
shasum -a 256 "$QCOW2" \
  | awk -v f="$(basename "$QCOW2")" '{print $1"  "f}' \
  > "$sha256_file"
hash=$(awk '{print $1}' "$sha256_file")
ok "sha256: $hash"

# ---- 7. scp + retry ----
remote_qcow2="${SERVER_USER}@${SERVER}:${SERVER_PATH}"
remote_sha="${SERVER_USER}@${SERVER}:${SERVER_PATH}.sha256"

scp_with_retry() {
  local src=$1 dst=$2 delay=5
  local i
  for i in $(seq 1 "$SCP_RETRIES"); do
    log "scp $src → $dst （第 $i/$SCP_RETRIES 次）"
    if scp "$src" "$dst"; then
      return 0
    fi
    if [ "$i" -lt "$SCP_RETRIES" ]; then
      warn "scp 失败，${delay}s 后重试"
      sleep "$delay"
      delay=$((delay * 3))
    fi
  done
  return 1
}

scp_with_retry "$QCOW2"      "$remote_qcow2" || die 'scp qcow2 失败'
scp_with_retry "$sha256_file" "$remote_sha"  || die 'scp sha256 失败'
ok '推送完成'

# ---- 8. 总结 ----
cat <<EOF

================================================================
              c-host-export.sh 完成
================================================================

下一步在服务器上跑：
  ssh ${SERVER_USER}@${SERVER}
  cd /opt/cape-installer
  sudo make import-guest GUEST_QCOW2=${SERVER_PATH}
EOF
