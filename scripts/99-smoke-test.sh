#!/usr/bin/env bash
# Stage 99-smoke-test：装完最终自检（决策 Q13=C：service + 网络 + import + virt-host-validate）
# 不带幂等守卫——每次都跑（自检很快）。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "99-smoke-test"

SUBNET="${SUBNET:-192.168.122}"
FAIL=0

# ---- 1. systemd 服务状态 ----
echo "==== systemd services ===="
for s in postgresql mongodb cape-rooter cape-web suricata libvirtd; do
  if service_active "$s"; then
    printf '  [✓] %-15s active\n' "$s"
  else
    printf '  [✗] %-15s NOT active\n' "$s"
    FAIL=$((FAIL + 1))
  fi
done

# ---- 2. 端口监听 ----
echo "==== listening ports ===="
for spec in '5432 PostgreSQL' '27017 MongoDB' '8000 cape-web'; do
  read -r port name <<< "$spec"
  if listening_on "$port"; then
    printf '  [✓] %-15s :%s\n' "$name" "$port"
  else
    printf '  [✗] %-15s :%s NOT listening\n' "$name" "$port"
    FAIL=$((FAIL + 1))
  fi
done

# ---- 3. virbr0 ----
echo "==== libvirt virbr0 ===="
if ip a show virbr0 | grep -q "inet ${SUBNET}.1/"; then
  echo "  [✓] virbr0 = ${SUBNET}.1/24"
else
  echo "  [✗] virbr0 没有 ${SUBNET}.1"
  FAIL=$((FAIL + 1))
fi

# ---- 4. CAPE Web UI ----
echo "==== Web UI ===="
if curl -fsS -o /dev/null -w '  [✓] http://127.0.0.1:8000/ → HTTP %{http_code}\n' \
   --max-time 10 http://127.0.0.1:8000/; then
  :
else
  echo "  [✗] Web UI 不可达"
  FAIL=$((FAIL + 1))
fi

# ---- 5. CAPE venv import 测试 ----
echo "==== CAPE venv imports ===="
if sudo -u cape /opt/CAPEv2/.venv/bin/python -c \
     'import django, pymongo, libvirt, yara, capstone, pefile' 2>&1; then
  echo "  [✓] core imports OK"
else
  echo "  [✗] import 失败"
  FAIL=$((FAIL + 1))
fi

# ---- 6. virt-host-validate qemu ----
echo "==== virt-host-validate qemu ===="
virt-host-validate qemu 2>&1 | head -10 || true
if virt-host-validate qemu 2>&1 | head -7 | grep -q FAIL; then
  echo "  [✗] virt-host-validate 前 7 项有 FAIL"
  FAIL=$((FAIL + 1))
else
  echo "  [✓] 前 7 项均 PASS"
fi

# ---- 7. QEMU 反 VM 标记 ----
echo "==== QEMU anti-VM verification ===="
if dpkg -s qemu 2>/dev/null | grep -qi 'antivm'; then
  echo "  [✓] dpkg qemu 包描述含 antivm"
else
  echo "  [✗] qemu 不是 anti-VM 版本"
  FAIL=$((FAIL + 1))
fi

# ---- 总结 ----
echo
if [ "$FAIL" -eq 0 ]; then
  echo "[✓✓✓] smoke test PASSED"
else
  echo "[✗✗✗] smoke test FAILED ($FAIL 项)"
  exit 1
fi

stage_done
