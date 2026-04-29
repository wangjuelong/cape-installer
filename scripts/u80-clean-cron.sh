#!/usr/bin/env bash
# u80-clean-cron：清掉 cape2.sh 加进 root crontab 的条目
# cape2.sh 加过的（按 install_CAPE / install_mongo / install_yara 等）：
#   - @reboot ... mkdir -p /data/{config,}db && chown mongodb /data
#   - @reboot ... smtp_sinkhole.sh
#   - @reboot ... socksproxies.sh
#   - 5 0 */1 * * cd /opt/CAPEv2/utils/ && ... community.py -waf -cr
#   - 30 1 * * 0 ... cleaners.py --delete-unused-file-data-in-mongo
#   - 00 */1 * * * (echo authenticate '...' ; signal newnym) | nc localhost 9051

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "u80-clean-cron"

# 用 grep -v 删；保留每条不含关键词的原行
PATTERNS=(
  'community.py -waf -cr'
  'smtp_sinkhole.sh'
  'socksproxies.sh'
  'delete-unused-file-data-in-mongo'
  'mkdir -p /data/'
  'signal newnym'
  '/usr/local/bin/noip2'
)

if crontab -l 2>/dev/null | grep -qE "$(IFS='|'; echo "${PATTERNS[*]}")"; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "[DRY-RUN] 会从 root crontab 删除以下条目："
    crontab -l 2>/dev/null | grep -E "$(IFS='|'; echo "${PATTERNS[*]}")" | sed 's/^/    /'
  else
    crontab -l 2>/dev/null \
      | grep -vE "$(IFS='|'; echo "${PATTERNS[*]}")" \
      | crontab -
    echo "[✓] 清理完成"
  fi
else
  echo "[~] root crontab 没有 cape 相关条目"
fi

stage_done
