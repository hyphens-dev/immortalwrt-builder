#!/usr/bin/env bash
# utils.sh — 公共函数库（被 build.sh / sync.sh 等 source，不单独执行）
# ---------------------------------------------------------------------------
# 约定：
#   - 所有 config.yml 读取统一走 scripts/yq-compatible.mjs（不用裸 yq）。
#   - cfg <dotted.key>        读取标量/数组（数组按行输出）
#   - cfg_bool <key>          "true" -> 返回 0，其余返回 1
#   - log_info/log_warn/log_err 带时间戳的日志
# ---------------------------------------------------------------------------

set -euo pipefail

UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${UTILS_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/config.yml}"
YQ_READER="${UTILS_DIR}/yq-compatible.mjs"

log_info() { echo "[INFO ] $(date -u +%H:%M:%SZ) $*" >&2; }
log_warn() { echo "[WARN ] $(date -u +%H:%M:%SZ) $*" >&2; }
log_err()  { echo "[ERROR] $(date -u +%H:%M:%SZ) $*" >&2; }

# cfg <dotted.key> [默认值] — key 不存在时返回默认值（而不是失败）
cfg() {
  local key="$1" def="${2-}" val
  if val="$(node "${YQ_READER}" "${key}" "${CONFIG_FILE}" 2>/dev/null)"; then
    echo "${val}"
  else
    echo "${def}"
  fi
}

# cfg_required <dotted.key> — key 必须存在，否则报错退出
cfg_required() {
  local key="$1"
  if ! node "${YQ_READER}" "${key}" "${CONFIG_FILE}" >/dev/null 2>&1; then
    log_err "config.yml 缺少必需键: ${key}"
    exit 1
  fi
  node "${YQ_READER}" "${key}" "${CONFIG_FILE}"
}

# cfg_bool <dotted.key> — 值为 true 返回 0，false/缺失返回 1
cfg_bool() {
  local v
  v="$(cfg "$1" "false")"
  [[ "${v}" == "true" ]]
}

# cfg_list <dotted.key> — 每行一个元素输出 mapping 的键或数组元素
cfg_list() {
  node "${YQ_READER}" --list "$1" "${CONFIG_FILE}" 2>/dev/null || true
}

# target_dir — OpenWrt 构建产物目录（x86/64，注意不是 x86_64/generic）
target_dir() {
  local board subtarget
  board="$(cfg_required target.board)"
  subtarget="$(cfg_required target.subtarget)"
  echo "bin/targets/${board}/${subtarget}"
}

# jobs_count — 并行任务数，0/auto 时取 nproc
jobs_count() {
  local j
  j="$(cfg build.jobs 0)"
  if [[ "${j}" == "0" || "${j}" == "auto" ]]; then
    nproc
  else
    echo "${j}"
  fi
}

# validate_config — 在构建前对 config.yml 做结构性校验
validate_config() {
  local ok=0
  for key in source.repo source.branch target.board target.subtarget \
             features.virtio.enabled features.network.wireguard \
             features.performance.bbr features.luci.enabled build.hostname; do
    if ! node "${YQ_READER}" "${key}" "${CONFIG_FILE}" >/dev/null 2>&1; then
      log_err "配置校验失败: 缺少 ${key}"
      ok=1
    fi
  done
  # 一致性检查：virtiofs 开启时必须启用 fuse
  if cfg_bool features.virtiofs.enabled && ! cfg_bool features.virtiofs.fuse; then
    log_warn "virtiofs.enabled=true 但 fuse=false：virtiofs 挂载需要 FUSE 支持"
  fi
  # nikki/mihomo 打开但 feed 未提供时给出明确警告
  if cfg_bool features.proxy.nikki || cfg_bool features.proxy.mihomo; then
    if [[ ! -f "${REPO_ROOT}/custom/feeds.conf" ]] || \
       ! grep -Eq 'nikki|mihomo' "${REPO_ROOT}/custom/feeds.conf"; then
      log_warn "proxy.nikki/mihomo=true，但 custom/feeds.conf 未包含提供该包的 feed；"
      log_warn "请在 custom/feeds.conf 中添加对应 src-git 行，否则包安装会静默跳过。"
    fi
  fi
  return "${ok}"
}
