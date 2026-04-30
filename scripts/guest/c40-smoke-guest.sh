#!/usr/bin/env bash
# Stage c40-smoke-guest：启 VM + 验证 agent.py 8000 端口可达
# - virsh start
# - virsh_wait_running 60s
# - agent_alive 轮询 120s（24 次 × 5s）
# - 失败 → dump XML + 提示 VNC 5901
#
# 管线内置的"真"验证关卡。失败要中止 import-guest。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "c40-smoke-guest"

GUEST_NAME="${GUEST_NAME:-cuckoo1}"
GUEST_IP="${GUEST_IP:-192.168.122.105}"

# ---- 幂等守卫 ----
if done_or_force \
   [ "$(virsh domstate "$GUEST_NAME" 2>/dev/null)" = "running" ] \
   && agent_alive "$GUEST_IP" 8000; then
  echo "[~] $GUEST_NAME running 且 agent.py:8000 可达，跳过"
  stage_done
  exit 0
fi

# ---- 1. 启动 ----
state=$(virsh domstate "$GUEST_NAME" 2>/dev/null || echo "undefined")
case "$state" in
  running) echo "[✓] domain 已 running" ;;
  "shut off"|paused) virsh start "$GUEST_NAME"; echo "[✓] virsh start" ;;
  *) echo "[-] domain 状态异常: $state"; exit 1 ;;
esac

# ---- 2. 等 domain running ----
if ! virsh_wait_running "$GUEST_NAME" 60; then
  echo "[-] 等 60s 仍不是 running 状态："
  virsh domstate "$GUEST_NAME"
  echo "[!] 当前 XML：" && virsh dumpxml "$GUEST_NAME"
  exit 1
fi
echo "[✓] domain running"

# ---- 3. 轮询 agent.py（120s = 24 × 5s） ----
echo "[+] 轮询 agent.py（最长 120s）"
for i in $(seq 1 24); do
  if agent_alive "$GUEST_IP" 8000; then
    echo "[✓] agent.py 已就绪（第 $((i*5))s）"
    stage_done
    exit 0
  fi
  printf '.'
  sleep 5
done
echo

# ---- 失败 ----
echo "[-] 120s 内 agent.py 未响应 http://${GUEST_IP}:8000/status"
echo "[!] 排查清单："
echo "    1. VNC 连 <TARGET>:5901 看 Win10 是否登录到桌面"
echo "    2. 客户机内 'tasklist | findstr pyw' 看 agent 进程"
echo "    3. 客户机内 'ipconfig' 看 IP 是不是 ${GUEST_IP}"
echo "    4. 客户机内 'curl http://${GUEST_IP}:8000/' 自测 agent"
exit 1
