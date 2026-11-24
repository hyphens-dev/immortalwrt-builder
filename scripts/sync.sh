#!/usr/bin/env bash
# sync.sh — 检测 ImmortalWrt 上游新提交，供 CI / cron 触发重建。
# ---------------------------------------------------------------------------
# 用法：
#   scripts/sync.sh            # 比较远端 HEAD 与 .upstream-built 记录
#   scripts/sync.sh --record   # 构建成功后把当前上游 commit 记入 .upstream-built
#
# 退出码：0 = 有更新（或记录成功）；10 = 无更新。
# 注意：本脚本绝不 rebase 本仓库到 ImmortalWrt 之上（两仓库无共同历史，
# 且源码树数 GB）。每次构建由 build.sh 全新浅克隆上游。
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"

MARKER="${REPO_ROOT}/.upstream-built"

main() {
  local repo branch remote_head recorded
  repo="$(cfg_required source.repo)"
  branch="$(cfg_required source.branch)"

  if [[ "${1:-}" == "--record" ]]; then
    remote_head="$(git ls-remote "${repo}" "refs/heads/${branch}" | awk '{print $1}')"
    [[ -n "${remote_head}" ]] || { log_err "无法读取远端 HEAD"; exit 1; }
    echo "${remote_head}" > "${MARKER}"
    log_info "已记录上游提交 ${remote_head:0:12} -> ${MARKER}"
    exit 0
  fi

  remote_head="$(git ls-remote "${repo}" "refs/heads/${branch}" | awk '{print $1}')"
  [[ -n "${remote_head}" ]] || { log_err "无法读取远端 HEAD"; exit 1; }

  recorded=""
  [[ -f "${MARKER}" ]] && recorded="$(cat "${MARKER}")"

  if [[ "${recorded}" == "${remote_head}" ]]; then
    log_info "无更新：${remote_head:0:12} 已构建过"
    exit 10
  fi
  # ${var:0:12:-none} 是非法展开（切片与 :- 默认值不能混用），
  # 当 .upstream-built 不存在、recorded 为空串时会直接报
  # "syntax error in expression"，set -e 使脚本以非 10 退出，导致
  # Sync upstream 工作流每次都失败。这里先算好显示值。
  local recorded_short="none"
  [[ -n "${recorded}" ]] && recorded_short="${recorded:0:12}"
  log_info "发现上游更新: ${recorded_short} -> ${remote_head:0:12}"
  echo "${remote_head}"
}

main "$@"
