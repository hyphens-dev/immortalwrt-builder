#!/usr/bin/env bash
# clean-runner.sh — GitHub Actions runner 磁盘预清理脚本
# ---------------------------------------------------------------------------
# OpenWrt/ImmortalWrt 全量构建会产生 staging_dir / build_dir / image 等数十 GB
# 中间产物，而 ubuntu-latest runner 根分区只有 ~14GB（其中约 5-8GB 被用不到的
# 预装工具链占据：Android SDK/NDK、.NET SDK、PowerShell、GraalVM、Heroku、
# Codex CLI 以及巨大的 hostedtoolcache）。本脚本在构建开始前释放这些空间，
# 避免构建中途 "No space left on device" 或 make 反复重试拖满 6 小时。
#
# 用法：
#   bash scripts/clean-runner.sh            # 清理 + 打印前后 df -h 对比
#   KEEP_DOTNET=1 bash scripts/clean-runner.sh   # 保留某项（默认全部可删）
#
# 设计原则：
#   * 只删 OpenWrt 构建确定不需要的东西；gcc/g++/make/git/python3/node/ccache
#     等构建依赖一律不碰。
#   * 所有删除都 || true，任何一项不存在都不影响后续步骤（本地/self-hosted
#     runner 上大部分路径本来就不存在）。
# ---------------------------------------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"

show_df() {
  local label="$1"
  log_info "磁盘占用（${label}）:"
  df -h / | sed 's/^/        /' >&2
}

rm_safe() {
  # rm_safe <描述> <路径...>  —— 路径不存在则跳过，删除失败不中断
  local desc="$1"; shift
  local p
  for p in "$@"; do
    if [[ -e "$p" ]]; then
      local size
      size="$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
      log_info "删除 ${desc}: ${p} (${size:-?})"
      sudo rm -rf "$p" 2>/dev/null || rm -rf "$p" 2>/dev/null || \
        log_warn "删除 ${p} 失败（权限？），继续"
    fi
  done
}

main() {
  show_df "清理前"

  # ---------------------------------------------- 1. runner 预装工具链（大头）
  # Android SDK/NDK：~2.5-5GB，OpenWrt x86 构建完全不需要
  rm_safe "Android SDK/NDK" \
    /usr/local/android-sdk* /usr/local/lib/android /usr/lib/android-sdk \
    "${ANDROID_HOME:-}" "${ANDROID_NDK_PATH:-}" 2>/dev/null

  # .NET SDK 运行时缓存：~1-2GB（构建只需系统自带 dotnet 都没有用到）
  if [[ "${KEEP_DOTNET:-0}" != "1" ]]; then
    rm_safe ".NET SDK" /usr/share/dotnet /usr/local/share/dotnet
  fi

  # PowerShell：~200MB
  if [[ "${KEEP_POWERSHELL:-0}" != "1" ]]; then
    rm_safe "PowerShell" /usr/local/bin/pwsh /opt/microsoft/powershell
  fi

  # hostedtoolcache（Ruby/Python/Node 多版本缓存）：可达数 GB。
  # 注意：actions/setup-node@v4 会把 Node 安装到这里，因此必须在 setup-node
  # 之前执行本脚本；这里只删与本次构建无关的 Ruby 目录，保守处理。
  rm_safe "hostedtoolcache/Ruby" /opt/hostedtoolcache/Ruby

  # GraalVM / Heroku / Codex CLI：各数百 MB，均非构建依赖
  rm_safe "GraalVM" /usr/local/share/graal /opt/graalvm* /usr/local/graal*
  rm_safe "Heroku CLI" /opt/heroku /usr/local/heroku /usr/local/bin/heroku
  rm_safe "Codex CLI" /usr/local/bin/codex /opt/codex*

  # ---------------------------------------------- 2. apt 缓存与旧内核/文档
  log_info "清理 apt 缓存 ..."
  sudo apt-get clean 2>/dev/null || true
  sudo apt-get autoclean -y 2>/dev/null || true
  sudo apt-get autoremove --purge -y 2>/dev/null || true
  # man/docs/locale 瘦身（runner 镜像里能省 300MB-1GB）
  sudo rm -rf /usr/share/man /usr/share/doc 2>/dev/null || true

  # ---------------------------------------------- 3. Docker 镜像（若 runner 上有）
  # OpenWrt 在本 workflow 里是裸 make 构建，不用 docker build；但 runner 预装了
  # containerd 镜像会占数 GB。docker 本身要保留（qemu-utils/efi 工具可能用到），
  # 只清空未使用的镜像层。
  if command -v docker >/dev/null 2>&1; then
    log_info "清理 docker 未使用镜像 ..."
    docker system prune -af --volumes >/dev/null 2>&1 || true
  fi

  # ---------------------------------------------- 4. 其他杂项
  rm_safe "npm 缓存" ~/.npm /home/runner/.npm
  rm_safe "pip 缓存" ~/.cache/pip /home/runner/.cache/pip
  # runner 下载的二进制工具缓存（含 gh/awscli 等）与上一轮 _temp 半成品，构建不需要。
  # 注意：只删 work/_temp，绝不碰当前 job 正在使用的 workspace。
  rm_safe "工具缓存" "${HOME}/.cache" /home/runner/work/_temp

  show_df "清理后"
  log_info "预清理完成，可以开始构建。"
}

main "$@"
