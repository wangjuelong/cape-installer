#!/usr/bin/env bash
# u70-remove-users：删 cape2.sh 创建的系统用户/组
#
# !!! 关键安全约束（240 验证踩过的坑）!!!
# 仅删 UID < 1000 的系统用户。UID ≥ 1000 是 OS 安装时创建的常规登录用户
# （包括运维 SSH 进来这台机的同名 cape 用户），删了会**永久切断 SSH 接入**。
#
# cape2.sh 用 `useradd --system` 创建 cape 时 UID 自动分配为 < 1000；
# 所以 UID 阈值是判断"该不该删"的黄金标准。

source "${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/lib/common.sh"
stage_init "u70-remove-users"

UID_THRESHOLD=1000

remove_user() {
  local u=$1
  if ! id "$u" >/dev/null 2>&1; then
    printf '  [absent]  user %s\n' "$u"
    return 0
  fi

  local uid
  uid=$(id -u "$u")

  # 安全门：UID >= 1000 拒绝删（保护登录用户）
  if [ "$uid" -ge "$UID_THRESHOLD" ]; then
    printf '  [SKIP]    user %s (UID=%d ≥ %d) — 看起来是常规登录用户而非 cape2.sh 系统用户，拒绝删除\n' \
      "$u" "$uid" "$UID_THRESHOLD"
    printf '            如果确定是要删，手动: sudo userdel -r %s\n' "$u"
    # 同名 group 也别动
    return 0
  fi

  printf '  [system]  user %s (UID=%d)\n' "$u" "$uid"
  # 先把所有该用户的进程杀掉，否则 userdel 拒绝
  if pgrep -u "$u" >/dev/null 2>&1; then
    run_or_warn pkill -KILL -u "$u"
    sleep 1
  fi
  run_or_warn userdel -r "$u"
  if id "$u" >/dev/null 2>&1; then
    printf '  [partial] %s 还存在（home 可能被锁），尝试 userdel -f\n' "$u"
    run_or_warn userdel -fr "$u"
  fi
  if ! id "$u" >/dev/null 2>&1; then
    printf '  [removed] user %s\n' "$u"
  fi
  # 同名 group 兜底（仅在用户已被删时）
  if getent group "$u" >/dev/null 2>&1; then
    run_or_warn groupdel "$u"
  fi
}

remove_user cape
remove_user mongodb

stage_done
