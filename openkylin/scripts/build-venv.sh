#!/bin/bash
# /opt/cape-deploy/build-venv.sh
# After cape2.sh.patched base completes, build CAPE's .venv via poetry.
# (cape2.sh's `pip install -r pyproject.toml` was patched out as it doesn't work.)
set -euo pipefail

CAPE_ROOT="${CAPE_ROOT:-/opt/cape-deploy/CAPEv2}"
LOG=/opt/cape-deploy/logs/build-venv-$(date +%Y%m%d-%H%M%S).log

mkdir -p /opt/cape-deploy/logs

[ -f "$CAPE_ROOT/pyproject.toml" ] || { echo "[-] $CAPE_ROOT/pyproject.toml not found"; exit 1; }
[ -x /etc/poetry/bin/poetry ] || { echo "[-] /etc/poetry/bin/poetry not found — cape2.sh dependencies() didn't run yet?"; exit 1; }

echo "[+] building venv at $CAPE_ROOT/.venv | log: $LOG"
cd "$CAPE_ROOT"

# Force poetry to put venv inside the project (matches what CAPE systemd services expect)
sudo -u cape -H bash -c "
  set -e
  export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring
  export CRYPTOGRAPHY_DONT_BUILD_RUST=1
  export PATH=/etc/poetry/bin:\$PATH
  cd $CAPE_ROOT
  /etc/poetry/bin/poetry config virtualenvs.in-project true --local
  /etc/poetry/bin/poetry install --no-interaction --no-root --no-ansi
" 2>&1 | tee "$LOG"

RC=${PIPESTATUS[0]}
echo "[+] poetry install exit code: $RC"
[ -x "$CAPE_ROOT/.venv/bin/python" ] && echo "[✓] venv ready at $CAPE_ROOT/.venv" || echo "[!] .venv not built — check $LOG"
exit "$RC"
