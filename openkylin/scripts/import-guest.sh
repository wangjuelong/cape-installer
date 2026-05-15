#!/usr/bin/env bash
# import-guest.sh — 在 cape-openkylin-deploy 目标机（/opt/cape-deploy 布局）上"一键 import guest"
# 等价于 cape-installer 的 `sudo make import-guest GUEST_QCOW2=...`，但适配 OpenKylin / /opt/cape-deploy。
#
# 5 个 stage 顺序跑，全幂等：
#   c10  qcow2 sha256 校验 + 拷到 /var/lib/libvirt/images/<name>.qcow2
#   c20  渲染 libvirt domain XML + virsh define + DHCP reservation
#   c30  写 /opt/cape-deploy/CAPEv2/conf/kvm.conf（machines list + [<name>] section）
#   c40  virsh start + 轮询 agent.py :8000 上线（默认 120s timeout）
#   c50  拍 clean snapshot + unmask cape/cape-processor + restart cape*
#
# 用法（目标机以 root 跑；或 `sudo bash ...`）：
#   sudo bash /opt/cape-deploy/import-guest.sh \
#     --qcow2 /tmp/cuckoo2.qcow2 \
#     --name cuckoo2 \
#     --ip 192.168.122.106 \
#     --mac 52:54:00:CA:FE:02 \
#     --platform linux \
#     --arch x64 \
#     --tags ubuntu22,linux,x64 \
#     --ram-mb 2048 \
#     --vcpus 2
#
# 若 qcow2 文件名形如 cuckoo<N>.qcow2 且 --name 缺省，将自动从文件名推导 name。
# IP/MAC 缺省则按 name 末尾数字自动算（cuckoo2 → .106 / ...:02，cuckoo3 → .107 / ...:03，...）。

set -uo pipefail

# ---- 默认值 ----
DEPLOY_DIR="${DEPLOY_DIR:-/opt/cape-deploy}"
CAPE_ROOT="${CAPE_ROOT:-$DEPLOY_DIR/CAPEv2}"
IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"
TMPL="${TMPL:-$DEPLOY_DIR/scripts/domain.xml.tmpl}"
SUBNET_PREFIX="${SUBNET_PREFIX:-192.168.122}"
GATEWAY_IP="${GATEWAY_IP:-$SUBNET_PREFIX.1}"
NETWORK="${NETWORK:-default}"
AGENT_PORT="${AGENT_PORT:-8000}"
AGENT_TIMEOUT_SEC="${AGENT_TIMEOUT_SEC:-120}"
GUEST_RAM_MB_DEFAULT=2048
GUEST_VCPUS_DEFAULT=2
LOG="$DEPLOY_DIR/logs/import-guest-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$DEPLOY_DIR/logs"

# ---- 参数 ----
QCOW2=""; GUEST_NAME=""; GUEST_IP=""; GUEST_MAC=""
GUEST_PLATFORM="windows"; GUEST_ARCH="x64"; GUEST_TAGS=""
GUEST_RAM_MB=""; GUEST_VCPUS=""
SKIP_SMOKE=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --qcow2)     QCOW2="$2"; shift 2 ;;
    --name)      GUEST_NAME="$2"; shift 2 ;;
    --ip)        GUEST_IP="$2"; shift 2 ;;
    --mac)       GUEST_MAC="$2"; shift 2 ;;
    --platform)  GUEST_PLATFORM="$2"; shift 2 ;;
    --arch)      GUEST_ARCH="$2"; shift 2 ;;
    --tags)      GUEST_TAGS="$2"; shift 2 ;;
    --ram-mb)    GUEST_RAM_MB="$2"; shift 2 ;;
    --vcpus)     GUEST_VCPUS="$2"; shift 2 ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    --force|-f)  FORCE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "[-] 未知参数: $1"; exit 1 ;;
  esac
done

step() { printf '\e[36m[+] %s\e[0m\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\e[32m[✓] %s\e[0m\n' "$*" | tee -a "$LOG"; }
warn() { printf '\e[33m[!] %s\e[0m\n' "$*" | tee -a "$LOG"; }
die()  { printf '\e[31m[-] %s\e[0m\n' "$*" | tee -a "$LOG" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "必须 root（sudo bash $0 ...）"
[ -n "$QCOW2" ] || die "缺 --qcow2"
[ -f "$QCOW2" ] || die "qcow2 不存在: $QCOW2"

# ---- 推导 name / ip / mac 缺省 ----
if [ -z "$GUEST_NAME" ]; then
  base=$(basename "$QCOW2" .qcow2)
  case "$base" in
    cuckoo[0-9]*) GUEST_NAME="$base" ;;
    *) die "无法从文件名推导 --name；明确给 --name" ;;
  esac
fi

# cuckoo<N> 末尾数字
NUM=$(echo "$GUEST_NAME" | grep -oE '[0-9]+$' || true)
if [ -z "$NUM" ]; then
  [ -n "$GUEST_IP" ] && [ -n "$GUEST_MAC" ] || die "GUEST_NAME 不含数字，必须明确给 --ip 和 --mac"
else
  if [ -z "$GUEST_IP" ]; then
    GUEST_IP="$SUBNET_PREFIX.$((104 + NUM))"   # cuckoo1=.105, cuckoo2=.106, ...
  fi
  if [ -z "$GUEST_MAC" ]; then
    GUEST_MAC=$(printf "52:54:00:CA:FE:%02d" "$NUM")
  fi
fi

[ -n "$GUEST_TAGS" ] || GUEST_TAGS="$GUEST_NAME,$GUEST_ARCH"
[ -n "$GUEST_RAM_MB" ] || GUEST_RAM_MB=$GUEST_RAM_MB_DEFAULT
[ -n "$GUEST_VCPUS" ]  || GUEST_VCPUS=$GUEST_VCPUS_DEFAULT

step "Phase C import-guest"
echo "  QCOW2:    $QCOW2"          | tee -a "$LOG"
echo "  NAME:     $GUEST_NAME"     | tee -a "$LOG"
echo "  IP:       $GUEST_IP"       | tee -a "$LOG"
echo "  MAC:      $GUEST_MAC"      | tee -a "$LOG"
echo "  PLATFORM: $GUEST_PLATFORM" | tee -a "$LOG"
echo "  ARCH:     $GUEST_ARCH"     | tee -a "$LOG"
echo "  TAGS:     $GUEST_TAGS"     | tee -a "$LOG"
echo "  RAM:      $GUEST_RAM_MB MB / vCPU $GUEST_VCPUS" | tee -a "$LOG"
echo "  LOG:      $LOG"            | tee -a "$LOG"

# ================================================================
# c10 qcow2 → /var/lib/libvirt/images/
# ================================================================
step "c10 qcow2 校验 + 拷到 $IMG_DIR/$GUEST_NAME.qcow2"
qemu-img info "$QCOW2" >/dev/null 2>&1 || die "c10 qcow2 不是合法 qemu image"
fmt=$(qemu-img info --output=json "$QCOW2" | grep -oE '"format": *"[a-z0-9]+"' | head -1 | cut -d'"' -f4)
[ "$fmt" = "qcow2" ] || warn "c10 image 格式 = $fmt（非 qcow2，可继续但 host 端 snapshot 行为可能不同）"
backing=$(qemu-img info "$QCOW2" 2>/dev/null | awk -F': ' '/backing file/ {print $2}')
[ -z "$backing" ] || die "c10 qcow2 有 backing file ($backing) —— 不是独立副本；先 qemu-img convert -O qcow2"
if [ -s "$QCOW2.sha256" ]; then
  (cd "$(dirname "$QCOW2")" && sha256sum -c "$(basename "$QCOW2.sha256")" 2>&1 | tee -a "$LOG") \
    || die "c10 sha256 校验失败"
fi

mkdir -p "$IMG_DIR"
DEST="$IMG_DIR/$GUEST_NAME.qcow2"
if [ -f "$DEST" ] && [ "$FORCE" -ne 1 ]; then
  src_size=$(stat -c '%s' "$QCOW2")
  dst_size=$(stat -c '%s' "$DEST")
  if [ "$src_size" = "$dst_size" ]; then
    ok "c10 已存在 $DEST（大小一致，跳过；--force 强制覆盖）"
  else
    warn "c10 $DEST 已存在但大小不同（${dst_size} vs ${src_size}），覆盖"
    cp -f "$QCOW2" "$DEST"
    ok "c10 覆盖完成"
  fi
else
  cp -f "$QCOW2" "$DEST"
  ok "c10 拷贝完成 ($(du -h "$DEST" | cut -f1))"
fi
chown libvirt-qemu:kvm "$DEST" 2>/dev/null || chown root:kvm "$DEST" 2>/dev/null || true
chmod 0660 "$DEST"

# ================================================================
# c20 virsh define + DHCP reservation
# ================================================================
step "c20 渲染 domain XML + virsh define"
[ -f "$TMPL" ] || die "c20 template 缺失: $TMPL"
RENDER="/tmp/$GUEST_NAME.domain.xml"
export GUEST_NAME GUEST_IP GUEST_MAC GUEST_RAM_MB GUEST_VCPUS
envsubst < "$TMPL" > "$RENDER"
xmllint --noout "$RENDER" 2>&1 | tee -a "$LOG" || die "c20 渲染 XML 不合法"

if virsh dominfo "$GUEST_NAME" >/dev/null 2>&1; then
  if [ "$FORCE" -eq 1 ]; then
    warn "c20 domain $GUEST_NAME 已存在，--force → undefine 后重 define"
    virsh destroy "$GUEST_NAME" 2>/dev/null || true
    virsh undefine "$GUEST_NAME" --nvram 2>/dev/null || virsh undefine "$GUEST_NAME" 2>/dev/null || true
    virsh define "$RENDER" | tee -a "$LOG"
  else
    ok "c20 domain $GUEST_NAME 已定义，跳过（--force 重做）"
  fi
else
  virsh define "$RENDER" | tee -a "$LOG"
  ok "c20 domain $GUEST_NAME 已定义"
fi

# DHCP reservation
existing=$(virsh net-dumpxml "$NETWORK" | grep -E "<host mac='${GUEST_MAC}'" || true)
if [ -n "$existing" ]; then
  virsh net-update "$NETWORK" delete ip-dhcp-host \
    "<host mac='${GUEST_MAC}' name='${GUEST_NAME}' ip='${GUEST_IP}'/>" \
    --live --config 2>&1 | tee -a "$LOG" || true
fi
virsh net-update "$NETWORK" add ip-dhcp-host \
  "<host mac='${GUEST_MAC}' name='${GUEST_NAME}' ip='${GUEST_IP}'/>" \
  --live --config 2>&1 | tee -a "$LOG" \
  || warn "c20 DHCP reservation add 失败（可能已存在），忽略"
ok "c20 DHCP: $GUEST_MAC → $GUEST_IP"

# ================================================================
# c30 kvm.conf 写入
# ================================================================
step "c30 写 $CAPE_ROOT/conf/kvm.conf"
KVM_CONF="$CAPE_ROOT/conf/kvm.conf"
[ -f "$KVM_CONF" ] || die "c30 $KVM_CONF 不存在 —— CAPE Phase B 还没装好"

command -v crudini >/dev/null 2>&1 || apt-get install -y crudini 2>&1 | tail -3

# machines list 追加（不覆盖）
current=$(crudini --get "$KVM_CONF" kvm machines 2>/dev/null || echo "")
if echo ",$current," | grep -q ",$GUEST_NAME,"; then
  ok "c30 machines list 已含 $GUEST_NAME"
else
  if [ -z "$current" ]; then
    crudini --set "$KVM_CONF" kvm machines "$GUEST_NAME"
  else
    crudini --set "$KVM_CONF" kvm machines "$current,$GUEST_NAME"
  fi
  ok "c30 machines list += $GUEST_NAME"
fi

# [<name>] section
crudini --set "$KVM_CONF" "$GUEST_NAME" label    "$GUEST_NAME"
crudini --set "$KVM_CONF" "$GUEST_NAME" platform "$GUEST_PLATFORM"
crudini --set "$KVM_CONF" "$GUEST_NAME" arch     "$GUEST_ARCH"
crudini --set "$KVM_CONF" "$GUEST_NAME" ip       "$GUEST_IP"
crudini --set "$KVM_CONF" "$GUEST_NAME" tags     "$GUEST_TAGS"
crudini --set "$KVM_CONF" "$GUEST_NAME" snapshot clean
crudini --set "$KVM_CONF" "$GUEST_NAME" interface virbr0
crudini --set "$KVM_CONF" "$GUEST_NAME" resultserver_ip   "$GATEWAY_IP"
crudini --set "$KVM_CONF" "$GUEST_NAME" resultserver_port 2042
chown cape:cape "$KVM_CONF" 2>/dev/null || true
ok "c30 [$GUEST_NAME] section 写入完成"

# ================================================================
# c40 virsh start + 轮询 agent.py :8000
# ================================================================
if [ "$SKIP_SMOKE" -eq 1 ]; then
  warn "c40 --skip-smoke 跳过启动验证"
else
  step "c40 启动 + 轮询 agent.py http://$GUEST_IP:$AGENT_PORT/status"
  if virsh domstate "$GUEST_NAME" | grep -qE "running"; then
    ok "c40 $GUEST_NAME 已 running"
  else
    virsh start "$GUEST_NAME" 2>&1 | tee -a "$LOG" \
      || die "c40 virsh start 失败"
  fi

  start_ts=$(date +%s)
  while :; do
    code=$(curl -m 3 -sS -o /dev/null -w "%{http_code}" "http://$GUEST_IP:$AGENT_PORT/status" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then
      ok "c40 agent.py 上线 ($GUEST_IP:$AGENT_PORT, $(($(date +%s) - start_ts))s)"
      break
    fi
    elapsed=$(($(date +%s) - start_ts))
    if [ "$elapsed" -ge "$AGENT_TIMEOUT_SEC" ]; then
      die "c40 agent.py 未上线（超时 ${AGENT_TIMEOUT_SEC}s）。检查 guest 内 cape-agent.service / 静态 IP"
    fi
    printf "."
    sleep 4
  done
fi

# ================================================================
# c50 snapshot clean + unmask cape*
# ================================================================
step "c50 snapshot clean + unmask cape services"
if ! virsh snapshot-list "$GUEST_NAME" --name 2>/dev/null | grep -q '^clean$'; then
  # 先关 VM（如运行）才能拍 internal snapshot
  if virsh domstate "$GUEST_NAME" | grep -qE "running"; then
    warn "c50 $GUEST_NAME 还在 running，先 shutdown + destroy"
    virsh shutdown "$GUEST_NAME" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8; do
      virsh domstate "$GUEST_NAME" | grep -qE "shut off" && break
      sleep 1
    done
    virsh destroy "$GUEST_NAME" 2>/dev/null || true
  fi
  virsh snapshot-create-as "$GUEST_NAME" clean "CAPE clean snapshot $(date -Iseconds)" 2>&1 | tee -a "$LOG" \
    || die "c50 snapshot-create-as 失败"
  ok "c50 snapshot 'clean' 已创建"
else
  ok "c50 snapshot 'clean' 已存在，跳过"
fi

# unmask cape + cape-processor（post-install-fix.sh 在 Phase B 阶段 mask 了它们）
for svc in cape cape-processor; do
  state=$(systemctl is-enabled "$svc" 2>&1 || true)
  if [ "$state" = "masked" ]; then
    systemctl unmask "$svc" 2>&1 | tee -a "$LOG"
    systemctl enable "$svc" 2>&1 | tee -a "$LOG"
    ok "c50 $svc unmask + enable"
  else
    ok "c50 $svc 状态 $state（未 masked）"
  fi
done

systemctl daemon-reload
systemctl restart cape-rooter cape-processor cape cape-web 2>&1 | tee -a "$LOG"
sleep 5
for svc in cape cape-rooter cape-processor cape-web; do
  active=$(systemctl is-active "$svc" 2>&1 || true)
  if [ "$active" = "active" ] || [ "$active" = "activating" ]; then
    ok "c50 $svc → $active"
  else
    warn "c50 $svc → $active (查 journalctl -u $svc -n 30)"
  fi
done

echo
echo "================================================================"
echo "  ✓ import-guest 完成: $GUEST_NAME @ $GUEST_IP"
echo "================================================================"
echo "下一步: 浏览器开 http://<host>:8090/submit/ 提交样本，Options 填 tags=$GUEST_TAGS 中的一个"
echo "日志: $LOG"
