#!/bin/bash
# smoke-test.sh — Phase B 部署完成后的健康检查
# 用法：sudo bash /opt/cape-deploy/smoke-test.sh
# 退出码：0 全 PASS / 1 有 FAIL

set -uo pipefail

CAPE_ROOT="${CAPE_ROOT:-/opt/cape-deploy/CAPEv2}"
CAPE_USER="${CAPE_USER:-cape}"
WEB_PORT="${WEB_PORT:-8090}"

PASS=0; FAIL=0
ok()   { echo "[✓] $*";  PASS=$((PASS+1)); }
no()   { echo "[✗] $*";  FAIL=$((FAIL+1)); }

echo "=== A. systemd services ==="
declare -A want=( [cape-rooter]=active [cape-web]=active [mongodb]=active [postgresql]=active [libvirtd]=active )
for s in "${!want[@]}"; do
  cur=$(systemctl is-active "$s" 2>&1)
  [ "$cur" = "${want[$s]}" ] && ok "$s ${want[$s]}" || no "$s expected ${want[$s]} got $cur"
done
# cape + cape-processor 期望 masked
for s in cape cape-processor; do
  en=$(systemctl is-enabled "$s" 2>&1)
  [ "$en" = "masked" ] && ok "$s masked (Phase B 惯例)" || no "$s expected masked got $en"
done

echo
echo "=== B. listening ports ==="
ss -tlnH 2>/dev/null | awk -v p=$WEB_PORT '
  $4 ~ ":"p"$"     {found_web=1}
  $4 ~ ":27017$"   {found_mongo=1}
  $4 ~ ":5432$"    {found_pg=1}
  END {
    print (found_web  ? "[✓] :"p" (cape-web)" : "[✗] :"p" (cape-web) NOT LISTENING")
    print (found_mongo? "[✓] :27017 (mongo)"  : "[✗] :27017 NOT LISTENING")
    print (found_pg   ? "[✓] :5432 (pg)"      : "[✗] :5432 NOT LISTENING")
  }'

echo
echo "=== C. HTTP self-test ==="
code=$(curl -m 5 -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:$WEB_PORT/ 2>/dev/null || echo 000)
[ "$code" = "200" ] && ok "GET / → 200" || no "GET / → $code"
code=$(curl -m 5 -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:$WEB_PORT/accounts/login/ 2>/dev/null || echo 000)
[ "$code" = "200" ] && ok "GET /accounts/login/ → 200" || no "GET /accounts/login/ → $code"

echo
echo "=== D. libvirt usable as $CAPE_USER ==="
if sudo -u "$CAPE_USER" -H virsh -c qemu:///system list --all >/dev/null 2>&1; then
  ok "$CAPE_USER → virsh list OK"
else
  no "$CAPE_USER → virsh failed (polkit / sock perm?)"
fi

echo
echo "=== E. virt-host-validate ==="
fails=$(virt-host-validate qemu 2>&1 | grep -c "FAIL")
if [ "$fails" -eq 0 ]; then
  ok "virt-host-validate qemu — no FAIL"
else
  no "virt-host-validate qemu — $fails FAILs"
  virt-host-validate qemu 2>&1 | grep FAIL | head -5
fi

echo
echo "=== F. venv imports ==="
sudo -u "$CAPE_USER" -H bash -c "
  cd $CAPE_ROOT
  /etc/poetry/bin/poetry run python -c \"
import sys, yara, libvirt, django, sqlalchemy, pymongo, psycopg2
print('py    :', sys.version.split()[0])
print('yara  :', yara.__version__)
print('django:', django.__version__)
print('sql   :', sqlalchemy.__version__)
print('mongo :', pymongo.__version__)
print('pg    :', psycopg2.__version__.split()[0])
\"" 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" -eq 0 ] && ok "all .venv imports OK" || no "some import failed"

echo
echo "===================="
echo "PASS: $PASS    FAIL: $FAIL"
echo "===================="
[ "$FAIL" -eq 0 ]
