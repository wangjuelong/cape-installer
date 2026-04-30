#!/usr/bin/env bash
# Stage 30-poetry-fix：建 CAPE Python venv + 装所有 deps
# 上游 cape2.sh 那行 `poetry pip install -r pyproject.toml` 是 buggy 的（不存在的子命令）
# silent fail 不建 venv。我们已在 vendor/cape2.sh.patched 注释掉了。
# 这里用 `poetry install --no-root` 接管。
# 同时修复 /home/cape/.cache 和 .config 的 root-owner 问题（cape2.sh 早期阶段以 root 写过）。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "30-poetry-fix"

CAPE_ROOT=/opt/CAPEv2

# ---- 幂等守卫 ----
if done_or_force venv_ready "$CAPE_ROOT" \
   && sudo -u cape "$CAPE_ROOT/.venv/bin/python" -c \
        'import django, pymongo, pefile, yara, capstone' >/dev/null 2>&1; then
  echo "[~] CAPE venv + 核心 deps 都齐了，跳过"
  stage_done
  exit 0
fi

# ---- 1. 修 cape 用户 home 下被 root 占的目录 ----
[ -d /home/cape ] || { echo "[-] 用户 cape 不存在，stage 20 没装好"; exit 1; }
chown -R cape:cape /home/cape/.cache /home/cape/.config 2>/dev/null || true
sudo -u cape mkdir -p /home/cape/.cache/pypoetry /home/cape/.config/pypoetry
echo "[✓] /home/cape/.cache + .config 权限修好"

# ---- 2. 让 poetry 在 /opt/CAPEv2/.venv 内建 venv（in-project）----
sudo -u cape /etc/poetry/bin/poetry config virtualenvs.in-project true

# ---- 3. poetry lock（pyproject 改过，lock 失效）----
echo "[+] poetry lock（解析依赖，~3 min）"
sudo -u cape bash -lc "cd $CAPE_ROOT && /etc/poetry/bin/poetry lock --no-interaction"

# ---- 4. poetry install（装所有 CAPE Python deps，~10 min）----
echo "[+] poetry install --no-root（~10 min）"
sudo -u cape bash -lc \
  "cd $CAPE_ROOT && PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring \
   /etc/poetry/bin/poetry install --no-interaction --no-root"

# ---- 5. 确保 venv 在 $CAPE_ROOT/.venv（symlink 兜底）----
# `poetry config virtualenvs.in-project true` 在某些环境下不生效（poetry 检测到
# cwd 不可读时 silent fail），venv 落到 /home/cape/.cache/pypoetry/virtualenvs/...。
# 这里检测真实路径并 symlink，确保后续 stage（40-kvm-libvirt 等）能用 .venv 路径。
if [ ! -e "$CAPE_ROOT/.venv" ]; then
  actual_venv=$(sudo -u cape bash -lc "cd $CAPE_ROOT && /etc/poetry/bin/poetry env info --path" 2>/dev/null)
  if [ -n "$actual_venv" ] && [ -d "$actual_venv" ]; then
    ln -sf "$actual_venv" "$CAPE_ROOT/.venv"
    echo "[✓] symlink $CAPE_ROOT/.venv → $actual_venv"
  else
    echo "[-] 找不到 poetry venv 真实路径（poetry env info 失败）"
    exit 1
  fi
fi

# ---- 6. sanity ----
sudo -u cape "$CAPE_ROOT/.venv/bin/python" -c \
  'import django, pymongo, pefile, yara, capstone, sqlalchemy; print("core deps OK")'

stage_done
