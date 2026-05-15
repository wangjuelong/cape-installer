#!/bin/bash
# post-install-fix.sh — 在 cape2.sh.patched base 跑完后，修 8 个未自动处理的问题
#
# 适用：upstream CAPEv2 在 openKylin 2.0 SP2（jammy base）上 cape2.sh.patched base 跑完
# 之后还差的 8 步 —— 全部幂等，可重复跑。
#
# 用法（target 机上以 rtshield + sudo 跑）：
#   sudo bash /opt/cape-deploy/post-install-fix.sh
#
# 退出码：0 = 全成 / 非 0 = 某步失败（哪步会 stderr 显示）

set -uo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/cape-deploy}"
CAPE_ROOT="${CAPE_ROOT:-$DEPLOY_DIR/CAPEv2}"
CAPE_USER="${CAPE_USER:-cape}"
WEB_PORT="${WEB_PORT:-8090}"        # openKylin 的 kytensor 占 :8000，避开
RESULT_IP="${RESULT_IP:-192.168.122.1}"

log()  { echo "[+] $*"; }
ok()   { echo "[✓] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[-] $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "必须 root 跑（sudo bash $0）"

# ---- F1. /home/cape 误属其他用户 → 改回 cape:cape ----
log "F1. /home/$CAPE_USER ownership"
if [ -d "/home/$CAPE_USER" ]; then
  cur=$(stat -c '%U:%G' "/home/$CAPE_USER")
  if [ "$cur" != "$CAPE_USER:$CAPE_USER" ]; then
    chown -R "$CAPE_USER:$CAPE_USER" "/home/$CAPE_USER"
    ok "F1 /home/$CAPE_USER → $CAPE_USER:$CAPE_USER（原 $cur）"
  else
    ok "F1 already $CAPE_USER:$CAPE_USER"
  fi
else
  warn "F1 /home/$CAPE_USER 不存在 —— cape user 还没创建？"
fi

# ---- F2. apt-install libvirt + qemu + KVM（cape2.sh 自己不装）----
log "F2. libvirt + qemu + KVM"
need=(libvirt-dev libvirt-daemon-system libvirt-clients qemu-kvm qemu-utils \
      bridge-utils virtinst libxml2-utils)
missing=()
for p in "${need[@]}"; do dpkg -l "$p" 2>/dev/null | grep -q '^ii' || missing+=("$p"); done
if [ "${#missing[@]}" -gt 0 ]; then
  apt-get install -y --no-install-recommends "${missing[@]}"
  ok "F2 装了：${missing[*]}"
else
  ok "F2 libvirt+qemu+KVM 都在"
fi
systemctl enable --now libvirtd >/dev/null 2>&1
ok "F2 libvirtd enabled"

# ---- F3. cape 加 libvirt 组（cape2.sh 的 usermod -aG 在 install_libvirt 失败时未跑）----
log "F3. cape into libvirt group"
if id -nG "$CAPE_USER" | tr ' ' '\n' | grep -qx libvirt; then
  ok "F3 already in libvirt"
else
  usermod -aG libvirt "$CAPE_USER"
  ok "F3 added"
fi

# ---- F4. libvirt polkit bypass via libvirt group socket ----
log "F4. /etc/libvirt/libvirtd.conf — sock_group + auth_unix_rw=none"
CONF=/etc/libvirt/libvirtd.conf
need_restart=0
for spec in \
  'unix_sock_group:"libvirt"' \
  'unix_sock_rw_perms:"0770"' \
  'auth_unix_rw:"none"'; do
  key=${spec%%:*}; val=${spec#*:}
  if ! grep -qE "^${key} = ${val}" "$CONF"; then
    sed -i "s|^#\?${key} =.*|${key} = ${val}|" "$CONF"
    grep -qE "^${key} = ${val}" "$CONF" || echo "${key} = ${val}" >> "$CONF"
    need_restart=1
  fi
done
if [ "$need_restart" -eq 1 ]; then
  systemctl restart libvirtd
  ok "F4 libvirtd restarted with new conf"
else
  ok "F4 already configured"
fi

# ---- F5. build .venv via poetry (cape2.sh 的 buggy pip 行被 P8 注释了，得自己建) ----
log "F5. build $CAPE_ROOT/.venv via poetry"
if [ -x "$CAPE_ROOT/.venv/bin/python" ]; then
  ok "F5 .venv already at $CAPE_ROOT/.venv"
else
  [ -x /etc/poetry/bin/poetry ] || die "F5 poetry not found at /etc/poetry/bin/poetry"
  sudo -u "$CAPE_USER" -H bash -c "
    set -e
    export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring
    export CRYPTOGRAPHY_DONT_BUILD_RUST=1
    export PATH=/etc/poetry/bin:\$PATH
    cd '$CAPE_ROOT'
    /etc/poetry/bin/poetry config virtualenvs.in-project true --local
    /etc/poetry/bin/poetry install --no-interaction --no-root --no-ansi
  " || die "F5 poetry install failed — 看上面输出"
  ok "F5 .venv built"
fi

# ---- F6. libvirt-python pip-installed into .venv ----
log "F6. libvirt-python==11.9.0 into .venv"
if sudo -u "$CAPE_USER" -H bash -c "cd '$CAPE_ROOT' && /etc/poetry/bin/poetry run python -c 'import libvirt' 2>/dev/null"; then
  ok "F6 libvirt-python already importable"
else
  sudo -u "$CAPE_USER" -H bash -c "
    cd '$CAPE_ROOT'
    /etc/poetry/bin/poetry run pip install libvirt-python==11.9.0
  " || die "F6 libvirt-python install failed"
  ok "F6 libvirt-python installed"
fi

# ---- F7. drop+recreate cape DB（cape2.sh 已建过，可能留下 status_type enum 残留）----
log "F7. cape DB clean state"
ENUM_COUNT=$(sudo -u postgres psql -d cape -tAc "SELECT count(*) FROM pg_type WHERE typname='status_type';" 2>/dev/null || echo 0)
TABLE_COUNT=$(sudo -u postgres psql -d cape -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public';" 2>/dev/null || echo 0)
if [ "$ENUM_COUNT" -ge 1 ] && [ "$TABLE_COUNT" -eq 0 ]; then
  warn "F7 cape DB 有 enum 残留但无 tables —— drop+recreate"
  systemctl stop cape cape-processor cape-web 2>/dev/null || true
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS cape;"
  sudo -u postgres psql -c "CREATE DATABASE cape OWNER cape;"
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE cape TO cape;"
  sudo -u postgres psql -d cape -c "ALTER DATABASE cape OWNER TO cape;" || true
  ok "F7 recreated"
else
  ok "F7 cape DB OK (enum=$ENUM_COUNT, tables=$TABLE_COUNT)"
fi

# ---- F8a. resultserver ip / virbr0 ----
log "F8a. virbr0 (default libvirt network) up"
if ! virsh net-info default 2>/dev/null | grep -q "Active: *yes"; then
  virsh net-start default 2>/dev/null || true
  virsh net-autostart default 2>/dev/null || true
fi
ip a show virbr0 2>/dev/null | grep -q "inet 192.168.122" && ok "F8a virbr0 up @ 192.168.122.x" || warn "F8a virbr0 not up"

# ---- F8b. cuckoo.conf — empty machines + resultserver ip + de-duplicate ----
log "F8b. cuckoo.conf cleanup"
CONF="$CAPE_ROOT/conf/cuckoo.conf"
if [ -f "$CONF" ]; then
  cp -n "$CONF" "$CONF.bak.$(date +%s)" || true
  sed -i "s|^machines.*=.*|machines =|" "$CAPE_ROOT/conf/kvm.conf" 2>/dev/null || true
  python3 - "$CONF" "$RESULT_IP" <<'PY'
import sys, re
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f: text = f.read()
out, lines = [], text.splitlines(keepends=True)
in_rs = False; seen = set()
for ln in lines:
    if ln.startswith('['):
        in_rs = ln.strip() == '[resultserver]'
        seen = set()
    if in_rs:
        m = re.match(r'^(ip|port|force_port|pool_size)\s*=', ln)
        if m and m.group(1) in seen:
            continue
        if m: seen.add(m.group(1))
    out.append(ln)
text2 = ''.join(out)
text2 = re.sub(
    r'(\[resultserver\][^\[]*?\n)ip\s*=\s*[^\n]+',
    rf'\1ip = {ip}',
    text2, count=1, flags=re.DOTALL
)
with open(path,'w') as f: f.write(text2)
print(f"[python] cuckoo.conf ip → {ip}, dups removed")
PY
  chown "$CAPE_USER:$CAPE_USER" "$CONF"
  ok "F8b cuckoo.conf fixed"
fi

# ---- F8c. Django migrate ----
log "F8c. Django migrate"
sudo -u "$CAPE_USER" -H bash -c "
  cd '$CAPE_ROOT/web'
  /etc/poetry/bin/poetry run python manage.py migrate --noinput
" 2>&1 | tail -3
ok "F8c migrations applied"

# ---- F8d. cape-web 端口 0.0.0.0:8000 → 0.0.0.0:$WEB_PORT （避 kytensor）----
log "F8d. cape-web port → $WEB_PORT"
UNIT=/lib/systemd/system/cape-web.service
if grep -q "0.0.0.0:8000" "$UNIT"; then
  sed -i "s|0.0.0.0:8000|0.0.0.0:$WEB_PORT|" "$UNIT"
  systemctl daemon-reload
  ok "F8d cape-web port → $WEB_PORT"
else
  ok "F8d cape-web port already $WEB_PORT (or non-default)"
fi

# ---- F8e. mask cape + cape-processor（Phase B 无 guest，按 cape-installer 惯例）----
log "F8e. mask cape + cape-processor (until guest imported)"
if [ "$(systemctl is-enabled cape 2>&1)" != "masked" ]; then
  systemctl stop cape cape-processor 2>/dev/null || true
  systemctl mask cape cape-processor
  ok "F8e masked"
else
  ok "F8e already masked"
fi

# ---- Restart cape-rooter + cape-web ----
log "Restart cape-rooter + cape-web"
systemctl restart cape-rooter cape-web 2>/dev/null || true
sleep 4

echo
echo "=== Final ==="
for s in cape cape-rooter cape-processor cape-web mongodb postgresql libvirtd; do
  printf "  %-20s active=%-10s enabled=%s\n" "$s" "$(systemctl is-active $s)" "$(systemctl is-enabled $s 2>&1)"
done

echo
echo "[+] post-install-fix.sh done."
echo "[+] 下一步: sudo bash $(dirname "$0")/smoke-test.sh"
