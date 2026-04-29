#!/usr/bin/env bash
# u70-remove-users：删 cape2.sh 创建的系统用户/组
# - cape (system user, /home/cape)
# - mongodb (apt 自动建的；apt purge 一般会删，残留情况兜底)

source "${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/lib/common.sh"
stage_init "u70-remove-users"

remove_user() {
  local u=$1
  if id "$u" >/dev/null 2>&1; then
    # 先把所有该用户的进程杀掉，否则 userdel 会拒绝
    if pgrep -u "$u" >/dev/null 2>&1; then
      run_or_warn pkill -KILL -u "$u"
      sleep 1
    fi
    run_or_warn userdel -r "$u"            # -r 删 home + mailspool
    if id "$u" >/dev/null 2>&1; then
      printf '  [partial] %s 还存在（可能 home 被锁），尝试 userdel -f\n' "$u"
      run_or_warn userdel -fr "$u"
    fi
    if ! id "$u" >/dev/null 2>&1; then
      printf '  [removed] user %s\n' "$u"
    fi
  else
    printf '  [absent]  user %s\n' "$u"
  fi
  # 同名 group 兜底
  if getent group "$u" >/dev/null 2>&1; then
    run_or_warn groupdel "$u"
  fi
}

remove_user cape
remove_user mongodb

stage_done
