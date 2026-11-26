#!/usr/bin/env bash
# build.sh — ImmortalWrt PVE/KVM (x86_64) 自动化构建主脚本
# ---------------------------------------------------------------------------
# 流程：
#   1. 校验 config.yml（scripts/utils.sh + yq-compatible.mjs）
#   2. 克隆/更新 ImmortalWrt 源码（浅克隆，可 pin tag）
#   3. 安装 feeds（官方 feeds + custom/feeds.conf 附加 feed）
#   4. 注入本仓库的自定义内核模块（fs-virtiofs.mk）与 files/ overlay
#   5. 依据 config.yml 生成 .config（内核选项 + 包选择）
#   6. make download / make -j / make install / make image
#   7. 输出 manifest.json 供 CI 归档
#
# 环境变量：
#   SKIP_CLONE=1   跳过源码克隆（假定 openwrt/ 已存在，CI 缓存场景）
#   OUT_DIR=<dir>  产物复制目标目录（默认 dist/）
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/utils.sh
source "${SCRIPT_DIR}/utils.sh"

SRC_DIR="${SRC_DIR:-${REPO_ROOT}/openwrt}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"

# 构建前检查可用空间：全量 x86_64 + LuCI 构建需要约 12-18GB，
# 空间不足时应在 30 秒内明确失败，而不是编译两小时后
# 在 make install/image 阶段报 "No space left on device"。
check_disk_space() {
  local need_gb="${1:-12}"
  local avail_gb
  avail_gb="$(df -BG --output=avail "${SRC_DIR:-${REPO_ROOT}}" 2>/dev/null | tail -1 | tr -dc '0-9')"
  [[ -n "${avail_gb}" ]] || { log_warn "无法读取磁盘可用空间，跳过检查"; return 0; }
  log_info "磁盘可用空间: ${avail_gb}G（建议 >= ${need_gb}G）"
  df -h "${SRC_DIR:-${REPO_ROOT}}" | sed 's/^/        /' >&2
  if (( avail_gb < need_gb )); then
    log_err "磁盘空间不足: 可用 ${avail_gb}G < 需要 ${need_gb}G"
    log_err "处理方法：减少选择的软件包 / 关闭 features.* 项 / 使用更大磁盘的 runner"
    exit 1
  fi
}

main() {
  log_info "=== ImmortalWrt PVE Builder ==="
  validate_config
  check_disk_space "${BUILD_MIN_DISK_GB:-12}"

  local repo branch tag board subtarget profile hostname lan_ip
  repo="$(cfg_required source.repo)"
  branch="$(cfg_required source.branch)"
  tag="$(cfg source.tag "")"
  board="$(cfg_required target.board)"
  subtarget="$(cfg_required target.subtarget)"
  profile="$(cfg target.profile generic)"
  hostname="$(cfg build.hostname immortalwrt-pve)"
  lan_ip="$(cfg build.lan_ip 192.168.100.1)"

  # --------------------------------------------------------------- 1. clone
  if [[ "${SKIP_CLONE:-0}" != "1" ]]; then
    if [[ ! -d "${SRC_DIR}/.git" ]]; then
      log_info "克隆源码 ${repo} (${tag:-${branch}}) ..."
      git clone --depth=1 --branch "${tag:-${branch}}" "${repo}" "${SRC_DIR}"
    else
      log_info "复用已有源码树: ${SRC_DIR}"
    fi
  fi
  cd "${SRC_DIR}"

  # --------------------------------------------------------------- 2. feeds
  log_info "安装 feeds ..."
  # 追加而不是覆盖 custom/feeds.conf。
  # 上游 feeds.conf.default 在不同版本里格式不同：24.10 用 `;<branch>`，
  # 25.12 用 `^<commit>` 并多一个 video feed。整体覆盖会把旧版本的 feed
  # 塞进新源码树，导致 luci/packages 与内核不匹配。
  if [[ -f "${REPO_ROOT}/custom/feeds.conf" ]]; then
    log_info "追加自定义 feeds: ${REPO_ROOT}/custom/feeds.conf"
    while IFS= read -r line; do
      # 跳过空行与注释
      [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
      if grep -qxF "${line}" feeds.conf.default 2>/dev/null; then
        log_info "  feed 已存在，跳过: ${line}"
        continue
      fi
      printf '%s\n' "${line}" >> feeds.conf.default
      log_info "  已追加: ${line}"
    done < "${REPO_ROOT}/custom/feeds.conf"
  fi
  ./scripts/feeds update -a
  ./scripts/feeds install -a

  # -------------------------------------------------- 3. 自定义包 & overlay
  log_info "注入自定义包与文件 overlay ..."
  # 内核模块包必须放到 package/kernel/linux/modules/（OpenWrt 的
  # SCAN_DEPS=modules/*.mk 就是相对这个目录扫描的）。放到 package/kernel/
  # 下不会被扫描到，包静默不存在，.config 里的 CONFIG_PACKAGE_* 会被丢弃。
  mkdir -p package/kernel/linux/modules
  cp -f "${REPO_ROOT}"/package/kernel/linux/modules/*.mk         package/kernel/linux/modules/ 2>/dev/null || true
  # files overlay（sysctl、network、hotplug 等直接进 rootfs）
  rm -rf files
  cp -r "${REPO_ROOT}/custom/files" files

  # 用 config 中的 LAN IP / hostname 渲染 overlay（sed 就地替换占位符）
  sed -i "s/@LAN_IP@/${lan_ip}/g; s/@HOSTNAME@/${hostname}/g" \
    files/etc/config/network

  # --------------------------------------------------------- 4. dotconfig
  log_info "生成 .config ..."
  generate_dotconfig

  # ------------------------------------------------------------ 5. build
  local jobs
  jobs="$(jobs_count)"
  log_info "下载构建依赖源码 (make download, -j${jobs}) ..."
  make download -j"${jobs}" || { log_warn "部分源码下载失败，重试一轮 ..."; make download -j1; }

  # NOTE: 不要使用 -k/-kB。-k（keep-going）会让某个包失败后继续调度其余所有
  # 目标，在 CI 上表现为海量 "Failed to remake makefile 'Makefile'" 噪音，
  # 并且失败的依赖会连锁拖垮后续阶段、白白耗尽 6 小时限时。
  # ccache 目录对齐：.config 里 CONFIG_CCACHE_DIR 留空时 OpenWrt 用
  # ~/.ccache，而 CI 缓存的是 ~/openwrt/.ccache，必须显式设置
  # CCACHE_DIR，否则缓存目录对不上、每次全量重编。
  if [[ -d "${SRC_DIR}/.ccache" ]]; then
    export CCACHE_DIR="${SRC_DIR}/.ccache"
    log_info "使用 ccache 目录: ${CCACHE_DIR}"
  fi

  # NOTE: OpenWrt 的 make 命令行本身携带数千个 CONFIG_* 环境变量，
  # 并行度过高时子进程 execve 会触发 "Argument list too long"（E2BIG），
  # 因此对 jobs 设上限。
  if (( jobs > 8 )); then
    log_warn "并行度 ${jobs} 过高，限制为 8（避免 E2BIG: Argument list too long）"
    jobs=8
  fi

  # 注意：OpenWrt 的详细度开关是 V=s（不是内核的 W=0）。这里不加 V，
  # 让默认的 -s 静默子 make 生效；失败时再回退到 V=s 单线程定位。
  log_info "开始编译 (make -j${jobs}) ..."
  if ! make -j"${jobs}" 2>&1 | tee "${SRC_DIR}/make.log"; then
    diagnose_build_failure "${SRC_DIR}/make.log"
    log_err "编译失败，详见上方的定位输出与 ${SRC_DIR}/make.log"
    exit 1
  fi

  # 不要再调用 `make install` 或 `make image`：OpenWrt 没有这两个顶层目标。
  # 裸 make 的默认目标就是 world（见仓库根 Makefile:133），而 world 已经包含
  #   target/stamp-compile package/stamp-compile
  #   package/stamp-install target/stamp-install   <- 这一步就在生成镜像
  #   package/index json_overview_image_info checksum
  # 所以上面 make 成功后镜像已经躺在 bin/targets/<board>/<subtarget>/ 里了。
  # 之前多出来的 `make install` 正是本次失败的根因：
  #   make -r install: build failed ... Error 1
  log_info "编译与镜像生成完成（world 已包含 target/stamp-install）"

  # ------------------------------------------------------------ 6. dist
  local tdir
  tdir="$(target_dir)"
  if [[ ! -d "${tdir}" ]]; then
    log_err "找不到产物目录 ${SRC_DIR}/${tdir}（检查 target.board/subtarget）"
    exit 1
  fi
  mkdir -p "${OUT_DIR}"

  # 逐类复制并统计，缺哪类就明确报错。之前用的是
  #   cp -f A/*.img.gz B/*.bin ... || cp -rf "${tdir}/." ...
  # 只要任一通配符没匹配到，整个 cp 就失败并退回"全目录复制"，
  # 于是 manifest/config.buildinfo 之外的东西也会混进 dist/，
  # 而且"镜像没生成"这种致命问题会被静默掩盖。
  local copied=0 pattern f
  for pattern in '*.img.gz' '*.bin' '*.manifest' 'config.buildinfo' 'sha256sums' '*.iso'; do
    # 用 find 而不是 glob：glob 在无匹配时会原样返回模式串，
    # 且必须不加引号才能展开（会触发 shellcheck SC2066）。
    while IFS= read -r -d '' f; do
      cp -f "${f}" "${OUT_DIR}/"
      copied=$((copied + 1))
    done < <(find "${tdir}" -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null)
  done

  if (( copied == 0 )); then
    log_err "产物目录 ${SRC_DIR}/${tdir} 存在但为空——镜像未生成"
    log_err "请检查上面的 make 输出是否真的产出了 x86/64 镜像"
    exit 1
  fi
  log_info "已收集 ${copied} 个产物文件"

  write_manifest "${OUT_DIR}/manifest.json" "${board}" "${subtarget}" "${profile}"
  log_info "完成！产物位于 ${OUT_DIR}/"
  find "${OUT_DIR}" -maxdepth 1 -type f -printf '  %f %s bytes\n'
}

# 并行 make 失败后，OpenWrt 只会打印一句
#   "make -r world: build failed. Please re-run make with -j1 V=s ..."
# 真正的错误被静默子 make 吞掉。这里从日志里找出失败的具体包，
# 再用 V=s 单独重编它，把真实错误暴露出来——比整体 -j1 重编快几个数量级。
diagnose_build_failure() {
  local logfile="$1"

  log_warn "==== 构建失败诊断 ===="
  if [[ ! -f "${logfile}" ]]; then
    log_warn "找不到 ${logfile}，跳过诊断"
    return 0
  fi

  # 1) 直接打印日志尾部，这是信息量最大的一段
  log_warn "---- 日志最后 60 行 ----"
  tail -60 "${logfile}" >&2 || true

  # 2) 找出明确报错的包（多种日志格式都存在）
  local failed_pkg=""
  failed_pkg="$(grep -oE 'ERROR: package/[a-zA-Z0-9._/-]+ failed to build' "${logfile}" \
                 | tail -1 | sed -E 's|ERROR: ||; s| failed to build||')"
  if [[ -z "${failed_pkg}" ]]; then
    failed_pkg="$(grep -oE 'make\[[0-9]+\]: \*\*\* \[[^]]*: package/[a-zA-Z0-9._/-]+\]' "${logfile}" \
                   | tail -1 | sed -E 's|.*: (package/[a-zA-Z0-9._/-]+)\]|\1|')"
  fi
  if [[ -z "${failed_pkg}" ]]; then
    failed_pkg="$(grep -oE '^make\[[0-9]+\]: \*\*\* .*Error' "${logfile}" | tail -1)"
  fi

  if [[ -z "${failed_pkg}" ]]; then
    log_warn "未能从日志中识别失败目标，请查看上面的日志尾部"
    return 0
  fi

  log_warn "识别到失败目标: ${failed_pkg}"

  # 3) 单独用 V=s 重编该目标，真实错误会直接打印出来
  if [[ "${failed_pkg}" == package/* ]]; then
    log_warn "---- 单独重编 ${failed_pkg} (V=s) 以显示真实错误 ----"
    make "${failed_pkg}/compile" V=s 2>&1 | tail -80 >&2 || true
  fi

  # 4) 该包自己的 build log 通常有最详细的记录
  local f
  local found=0
  while IFS= read -r -d '' f; do
    found=1
    log_warn "---- ${f} (最后 40 行) ----"
    tail -40 "${f}" >&2 || true
  done < <(find "${SRC_DIR}/logs" -name '*.txt' -newermt '-2 hours' -print0 2>/dev/null)
  if (( found == 0 )); then
    log_warn "未找到包级日志（logs/*.txt）"
  fi
  log_warn "==== 诊断结束 ===="
}

generate_dotconfig() {
  local board subtarget
  board="$(cfg_required target.board)"
  subtarget="$(cfg_required target.subtarget)"
  # 基础：默认配置 + 关闭 initramfs-kernel（PVE 用不到），开启 gzip 镜像
  # 注意：不要写 CONFIG_USE_IMAGELIST —— 该符号在 openwrt-24.10 中不存在
  # （config/Config-build.in 里 0 处命中），会被 kconfig 静默丢弃。
  # CONFIG_TARGET_PROFILE 的取值来自 target/linux/x86/image/generic.mk 里的
  # `define Device/generic`。
  cat > .config <<EOF
CONFIG_TARGET_${board}=y
CONFIG_TARGET_${board}_${subtarget}=y
CONFIG_TARGET_PROFILE="DEVICE_generic"
EOF

  # 通用选项
  #
  # 刻意不开 CONFIG_ALL_KMODS：它会编译上游全部数千个内核模块（无线、ARM
  # 板级、各类 GPU/网卡），在 4 核 runner 上要 1.5h+ 且占用十几 GB 磁盘，
  # 是构建失败/超时的首要原因。PVE 场景只需要下面按 feature 选中的那些 kmod。
  # 同理不开 CONFIG_DEVEL：它会打开调试信息，staging/build_dir 体积翻倍。
  # rootfs 512MB 对路由器固件足够，1024MB 会让镜像组装多占一倍空间。
  cat >> .config <<'EOF'
CONFIG_CCACHE=y
CONFIG_COLLECT_KERNEL_DEBUG=n
CONFIG_TARGET_ROOTFS_PARTSIZE=512
CONFIG_TARGET_KERNEL_PARTSIZE=16
EOF

  cfg_bool kernel.lto && echo 'CONFIG_USE_LTO=y' >> .config

  # ------------------------------------------------------------- virtio
  # x86/64 目标内核已 built-in virtio-net/-blk/-scsi/-balloon/-rng/-console
  # （target/linux/x86/64/config-6.6 里均为 =y），上游也没有对应的
  # kmod-virtio-* 包。这里不需要选任何包，virtiofs 见下一节。
  if cfg_bool features.virtio.enabled; then
    log_info "virtio 设备驱动已 built-in 于 x86/64 内核，无需选择 kmod"
  fi

  # ---------------------------------------------------------- virtiofs
  if cfg_bool features.virtiofs.enabled; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-fs-virtiofs=y
CONFIG_PACKAGE_kmod-fuse=y
EOF
    cfg_bool features.virtiofs.fuse && \
      echo 'CONFIG_PACKAGE_fuse-utils=y' >> .config
  fi

  # -------------------------------------------------------------- p9fs
  if cfg_bool features.p9fs.enabled; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-fs-9p=y
CONFIG_PACKAGE_kmod-9pnet=y
CONFIG_PACKAGE_kmod-9pvirtio=y
EOF
  fi

  # ----------------------------------------------------------- network
  cfg_bool features.network.wireguard && cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-wireguard=y
CONFIG_PACKAGE_wireguard-tools=y
CONFIG_PACKAGE_luci-app-wireguard=y
EOF
  cfg_bool features.network.nftables && cat >> .config <<'EOF'
CONFIG_PACKAGE_nftables-json=y
CONFIG_PACKAGE_kmod-nft-core=y
CONFIG_PACKAGE_kmod-nft-bridge=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-nat=y
CONFIG_PACKAGE_kmod-nft-fib=y
EOF
  cfg_bool features.network.iptables_nft && cat >> .config <<'EOF'
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_ip6tables-nft=y
CONFIG_PACKAGE_kmod-ipt-nat=y
EOF
  if cfg_bool features.network.bridge; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_bridge-utils=y
EOF
    cfg_bool features.network.veth && echo 'CONFIG_PACKAGE_kmod-veth=y' >> .config
    cfg_bool features.network.tun  && cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_openssh-sftp-server=y
EOF
  fi

  # ------------------------------------------------------------- proxy
  cfg_bool features.proxy.smartdns  && cat >> .config <<'EOF'
CONFIG_PACKAGE_smartdns=y
CONFIG_PACKAGE_luci-app-smartdns=y
EOF
  cfg_bool features.proxy.adguardhome && cat >> .config <<'EOF'
CONFIG_PACKAGE_adguardhome=y
CONFIG_PACKAGE_luci-app-adguardhome=y
EOF
  # nikki/mihomo 只有在 feed 提供时才会安装成功；缺失时不阻塞整体构建。
  if cfg_bool features.proxy.nikki || cfg_bool features.proxy.mihomo; then
    if ./scripts/feeds list 2>/dev/null | grep -Eq 'luci-app-nikki|mihomo'; then
      cat >> .config <<'EOF'
CONFIG_PACKAGE_mihomo=y
CONFIG_PACKAGE_luci-app-nikki=y
EOF
    else
      log_warn "feed 中未找到 mihomo/luci-app-nikki，跳过安装（见 docs/nikki.md）"
    fi
  fi

  # -------------------------------------------------------- performance
  # BBR: 6.6 内核 TCP_CONG_BBR 为模块 CONFIG_TCP_CONG_BBR，OpenWrt 通过
  # kmod-tcp-bbr 暴露；同时内置 fq/fq_codel/cake 调度器。
  cfg_bool features.performance.bbr && cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-tcp-bbr=y
EOF
  cfg_bool features.performance.cake && cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-sched-cake=y
EOF
  cfg_bool features.performance.fq_codel && cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-sched-core=y
EOF
  cfg_bool features.performance.irqbalance && cat >> .config <<'EOF'
CONFIG_PACKAGE_irqbalance=y
EOF
  cfg_bool features.performance.sqm && cat >> .config <<'EOF'
CONFIG_PACKAGE_sqm-scripts=y
CONFIG_PACKAGE_luci-app-sqm=y
EOF

  # --------------------------------------------------------------- luci
  if cfg_bool features.luci.enabled; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_luci=y
EOF
    case "$(cfg features.luci.theme bootstrap)" in
      material) echo 'CONFIG_PACKAGE_luci-theme-material=y' ;;
      editor)   echo 'CONFIG_PACKAGE_luci-theme-editor=y' ;;
      *)        echo 'CONFIG_PACKAGE_luci-theme-bootstrap=y' ;;  # 浅色主题
    esac >> .config
    if cfg_bool features.luci.translations; then
      cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_default-settings-chn=y
EOF
    fi
    cfg_bool features.luci.statistics && cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-statistics=y
CONFIG_PACKAGE_collectd-mod-interface=y
CONFIG_PACKAGE_collectd-mod-iwinfo=n
CONFIG_PACKAGE_collectd-mod-load=y
CONFIG_PACKAGE_collectd-mod-memory=y
CONFIG_PACKAGE_collectd-mod-network=y
CONFIG_PACKAGE_collectd-mod-traffic=y
CONFIG_PACKAGE_luci-i18n-statistics-zh-cn=y
EOF
    cfg_bool features.luci.firewall && cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_firewall4=y
EOF
  fi

  # 让 defconfig 补齐所有缺省值。
  # 失败时不要静默：OpenWrt 的静默子 make 会把真正的编译错误吞掉
  # （只剩 "make -s -C scripts/config conf: build failed"），因此这里显式
  # 失败重跑一次并打开 V=s，把真实错误暴露出来。
  if ! make defconfig; then
    log_err "make defconfig 失败，用 V=s 重跑以显示真实错误 ..."
    make defconfig V=s
  fi
  log_info ".config 生成完毕（$(grep -c '^CONFIG_' .config) 个符号）"
}

write_manifest() {
  local out="$1" board="$2" subtarget="$3" profile="$4"
  local commit
  commit="$(git -C "${SRC_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  cat > "${out}" <<EOF
{
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "upstream_commit": "${commit}",
  "target": "${board}/${subtarget}/${profile}",
  "kernel_version_metadata": "$(cfg kernel.version 6.6)",
  "features": {
    "virtio": $(cfg_bool features.virtio.enabled && echo true || echo false),
    "virtiofs": $(cfg_bool features.virtiofs.enabled && echo true || echo false),
    "wireguard": $(cfg_bool features.network.wireguard && echo true || echo false),
    "nftables": $(cfg_bool features.network.nftables && echo true || echo false),
    "bbr": $(cfg_bool features.performance.bbr && echo true || echo false),
    "cake": $(cfg_bool features.performance.cake && echo true || echo false),
    "fq_codel": $(cfg_bool features.performance.fq_codel && echo true || echo false),
    "irqbalance": $(cfg_bool features.performance.irqbalance && echo true || echo false),
    "nikki": $(cfg_bool features.proxy.nikki && echo true || echo false),
    "luci_zh_cn": $(cfg_bool features.luci.translations && echo true || echo false)
  }
}
EOF
}

main "$@"
