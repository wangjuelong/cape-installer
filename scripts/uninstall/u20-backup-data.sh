#!/usr/bin/env bash
# u20-backup-data：apt purge 前备份 PostgreSQL cape 库 + Mongo
# 优化（v2）：u10 不再停 mongo/postgres → 此阶段服务通常已经 active →
# 不需要 start/stop（节省 ~8 秒）。仅当服务确实不在跑时才临时启动。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u20-backup-data"

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups"
PG_DUMP="$BACKUP_DIR/cape-uninstall-${TS}.sql"
MG_DUMP="$BACKUP_DIR/cape-uninstall-${TS}.mongo"

mkdir -p "$BACKUP_DIR"

# ---- 通用：确保服务 active（仅在必要时 start，结束不再 stop） ----
ensure_active() {
  local svc=$1 wait=${2:-3}
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    return 0
  fi
  echo "  [start] $svc 临时启动用于备份"
  run_or_warn systemctl start "$svc"
  sleep "$wait"
}

# ---- PostgreSQL cape 库备份 ----
if dpkg -s postgresql-18 >/dev/null 2>&1 || dpkg -s postgresql >/dev/null 2>&1; then
  ensure_active postgresql 2
  if sudo -u postgres psql -lqt 2>/dev/null | cut -d\| -f1 | grep -qw cape; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY-RUN] sudo -u postgres pg_dump cape > $PG_DUMP"
    else
      if sudo -u postgres pg_dump cape > "$PG_DUMP" 2>>"$STAGE_LOG"; then
        echo "[✓] PostgreSQL cape 库备份: $PG_DUMP ($(stat -c%s "$PG_DUMP") bytes)"
      else
        echo "[!] pg_dump cape 失败（库可能为空 or 已损坏），继续"
        rm -f "$PG_DUMP"
      fi
    fi
  else
    echo "[~] 没有 cape 库，跳过 pg_dump"
  fi
else
  echo "[~] postgresql 未装，跳过备份"
fi

# ---- MongoDB 备份 ----
if dpkg -s mongodb-org >/dev/null 2>&1 || dpkg -s mongodb-org-server >/dev/null 2>&1; then
  ensure_active mongodb 3
  if command -v mongodump >/dev/null 2>&1 && ss -tlnH 2>/dev/null | grep -q ':27017'; then
    # 检测是否有非系统库（admin/config/local 之外）— 没的话跳过备份省时间
    user_dbs=$(mongosh --quiet --eval \
      'db.adminCommand("listDatabases").databases.filter(d=>!["admin","config","local"].includes(d.name)).map(d=>d.name).join(" ")' \
      2>/dev/null || echo "")
    if [ -z "$user_dbs" ] && [ "${DRY_RUN:-0}" != "1" ]; then
      echo "[~] MongoDB 无用户库，跳过 mongodump（仅有 admin/config/local 系统库）"
    elif [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY-RUN] mongodump --out=${MG_DUMP}/"
    else
      echo "[+] 备份 MongoDB 用户库: $user_dbs"
      if mongodump --quiet --out="${MG_DUMP}/" 2>>"$STAGE_LOG"; then
        echo "[✓] MongoDB 备份: ${MG_DUMP}/"
      else
        echo "[!] mongodump 失败，继续"
        rm -rf "${MG_DUMP}"
      fi
    fi
  else
    echo "[~] mongodump 不可用 / 27017 没监听，跳过"
  fi
else
  echo "[~] mongodb 未装，跳过备份"
fi

# 不主动 stop —— 让 u30 apt purge 接手（避免反复 start/stop）

stage_done
