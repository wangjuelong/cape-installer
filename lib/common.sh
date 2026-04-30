#!/usr/bin/env bash
# lib/common.sh — 所有 stage 脚本的 source 入口
# 提供：日志、自动重试、stage 包装器（失败自动 tail 日志）、幂等探测 helper

set -eEuo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOGS_DIR="$REPO_ROOT/logs"
STATE_DIR="$REPO_ROOT/state"
mkdir -p "$LOGS_DIR" "$STATE_DIR"

# ===== 颜色 / 日志 =====
if [ -t 2 ]; then
  C_RST=$'\033[0m'; C_GRN=$'\033[32m'; C_RED=$'\033[31m'
  C_YLW=$'\033[33m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'
else
  C_RST=''; C_GRN=''; C_RED=''; C_YLW=''; C_CYN=''; C_BLD=''
fi

log_info() { printf '%s[+]%s %s\n' "$C_CYN" "$C_RST" "$*" >&2; }
log_ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
log_warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
log_err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

# ===== 自动重试（决策 Q6=B） =====
# 用法: retry <次数> <初始延迟秒> <命令...>
# 例:   retry 3 5 curl -fsSL https://x.com
retry() {
  local n=$1; shift
  local delay=$1; shift
  local i=0
  until "$@"; do
    i=$((i + 1))
    if [ "$i" -ge "$n" ]; then
      log_err "重试 $n 次仍失败: $*"
      return 1
    fi
    log_warn "命令失败（第 $i/$n 次），${delay}s 后重试: $*"
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# ===== Stage 包装器（决策 Q11=D） =====
# 每个 scripts/XX-foo.sh 顶部:
#   source "$REPO_ROOT/lib/common.sh"
#   stage_init "10-mirrors"
#   ... 业务 ...
#   stage_done

STAGE_NAME=""
STAGE_LOG=""

stage_init() {
  STAGE_NAME="$1"
  STAGE_LOG="$LOGS_DIR/${STAGE_NAME}.log"
  : > "$STAGE_LOG"
  log_info "${C_BLD}===== Stage $STAGE_NAME 开始 =====${C_RST}"
  exec 3>&1 4>&2                           # 保存原 stdout/stderr
  exec >>"$STAGE_LOG" 2>&1                 # 业务输出全部进 stage 日志
  trap 'stage_fail $?' ERR
  echo "===== $(date -Iseconds) start ====="
}

stage_done() {
  echo "===== $(date -Iseconds) done ====="
  exec 1>&3 2>&4                           # 还原
  trap - ERR
  log_ok "${C_BLD}===== Stage $STAGE_NAME 完成 =====${C_RST}"
}

stage_fail() {
  local code=${1:-1}
  exec 1>&3 2>&4                           # 还原后再打印
  log_err "Stage $STAGE_NAME 失败（exit=$code），最后 50 行日志："
  tail -n 50 "$STAGE_LOG" >&2 || true
  log_err "完整日志: $STAGE_LOG"
  exit "$code"
}

# ===== 幂等守卫 helper（决策 Q5=A） =====
# 通用语义：返回 0 表示「已经做完了，可以跳过」
pkg_installed()    { dpkg -s "$1" >/dev/null 2>&1; }
user_in_group()    { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }
service_active()   { systemctl is-active --quiet "$1"; }
service_enabled()  { systemctl is-enabled --quiet "$1"; }
venv_ready()       { [ -x "$1/.venv/bin/python" ]; }
file_sha_ok()      { [ -f "$1" ] && echo "$2  $1" | sha256sum --check --quiet >/dev/null 2>&1; }
net_active()       { virsh net-info "$1" 2>/dev/null | awk '/Active:/{print $2}' | grep -qx yes; }
listening_on()     { ss -tlnH 2>/dev/null | awk '{print $4}' | grep -q "[:.]$1\$"; }

# 当 FORCE=1 时返回非 0（跳守卫强制执行）
done_or_force() { [ "${FORCE:-0}" = "1" ] && return 1 || "$@"; }

# ===== GitHub 镜像处理（240 这种 github.com 被墙的环境）=====
# 由 00-preflight 决定，写入 state/github.env：
#   GH_PROXY=                          # 直连 OK
#   GH_PROXY=https://gh-proxy.com/     # 走代理
GH_ENV_FILE="$STATE_DIR/github.env"

load_github_env() {
  GH_PROXY=""
  if [ -f "$GH_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$GH_ENV_FILE"
  fi
}

# 把 https://github.com/... 改写成实际可达 URL（如 gh-proxy 前缀）
gh_url() {
  load_github_env
  if [ -n "$GH_PROXY" ]; then
    echo "${GH_PROXY%/}/$1"
  else
    echo "$1"
  fi
}

# ===== DRY_RUN 包装（卸载脚本用）=====
# DRY_RUN=1 时只打印不执行；否则正常执行。
# 用法: run rm -rf /opt/CAPEv2     ← 简单命令
#       run apt-get purge -y mongodb-org
# 注意：需要 shell 特性（管道 / heredoc / 重定向）的复杂命令请直接用
#       `if [ "$DRY_RUN" != "1" ]; then ... ; fi` 包裹，run 不替你做 eval。
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2
    return 0
  fi
  "$@"
}

# 同 run，但失败时不传播（卸载是 best-effort，单步失败不阻塞剩余清理）
run_or_warn() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2
    return 0
  fi
  if ! "$@"; then
    printf '%s[!]%s 命令失败但继续: %s\n' "$C_YLW" "$C_RST" "$*" >&2
    return 0
  fi
}

# ===== Phase C helpers（c-stage 用）=====

# render_template <template-file>
# 用 envsubst 渲染 ${VAR} 占位符到 stdout。只展开传入白名单变量名，
# 避免 $PATH / $HOME 被意外替换进 XML。
# 用法：render_template scripts/guest/domain-cuckoo1.xml.tmpl > /tmp/domain.xml
render_template() {
  local tmpl="$1"
  [ -f "$tmpl" ] || { log_err "模板不存在: $tmpl"; return 1; }
  local whitelist='${GUEST_NAME} ${GUEST_IP} ${GUEST_MAC} ${GUEST_RAM_MB} ${GUEST_VCPUS} ${SUBNET}'
  envsubst "$whitelist" < "$tmpl"
}

# virsh_wait_running <domain> <timeout-sec>
# 轮询直到 domain state == running，或超时返回 1。
virsh_wait_running() {
  local dom="$1" timeout="${2:-60}"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if [ "$(virsh domstate "$dom" 2>/dev/null)" = "running" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# agent_alive <ip> <port>
# 单次探测：HTTP GET http://ip:port/status 必须返回合法 JSON 且 status 字段存在。
# 返回 0 表示 agent 起来了。
agent_alive() {
  local ip="$1" port="${2:-8000}"
  curl -fsS --max-time 3 "http://${ip}:${port}/status" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "status" in d else 1)' \
      2>/dev/null
}

# kvm_conf_section_exists <conf-file> <section>
# 用 crudini 探测 INI 文件中是否已有某 section。
kvm_conf_section_exists() {
  local conf="$1" section="$2"
  [ -f "$conf" ] || return 1
  crudini --get "$conf" "$section" >/dev/null 2>&1
}
