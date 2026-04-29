#!/usr/bin/env bash
# u20-backup-data：在 purge 前备份 PostgreSQL cape 库 + Mongo
# - 服务已被 u10 停掉，这里要短暂临时启动 postgresql 来 dump

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "u20-backup-data"

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups"
PG_DUMP="$BACKUP_DIR/cape-uninstall-${TS}.sql"
MG_DUMP="$BACKUP_DIR/cape-uninstall-${TS}.mongo"

mkdir -p "$BACKUP_DIR"

# ---- PostgreSQL cape 库备份 ----
if dpkg -s postgresql-18 >/dev/null 2>&1 || dpkg -s postgresql >/dev/null 2>&1; then
  echo "[+] 临时启动 postgresql 做备份"
  run_or_warn systemctl start postgresql
  sleep 3
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
    echo "[~] 没有 cape 库，跳过备份"
  fi
  run_or_warn systemctl stop postgresql
else
  echo "[~] postgresql 未装，跳过备份"
fi

# ---- MongoDB 备份 ----
if dpkg -s mongodb-org >/dev/null 2>&1; then
  echo "[+] 临时启动 mongodb 做备份"
  run_or_warn systemctl start mongodb
  sleep 5
  if command -v mongodump >/dev/null 2>&1 && ss -tlnH 2>/dev/null | grep -q ':27017'; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "[DRY-RUN] mongodump --out=${MG_DUMP}/"
    else
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
  run_or_warn systemctl stop mongodb
else
  echo "[~] mongodb 未装，跳过备份"
fi

stage_done
