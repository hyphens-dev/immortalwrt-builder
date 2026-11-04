#!/usr/bin/env bash
# build.sh — ImmortalWrt PVE/KVM (x86_64) 自动化构建主脚本
# ---------------------------------------------------------------------------
# 流程：
#   1. 校验 config.yml（scripts/utils.sh + yq-compatible.mjs）
#   2. 克隆/更新 ImmortalWrt 源码（浅克隆，可 pin tag）
#   3. 安装 feeds（官方 feeds + custom/feeds.conf 附加 feed）
#   4. 注入本仓库的自定义包（kmod-fs-virtiofs）与 files/ overlay
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

main() {
  log_info "=== ImmortalWrt PVE Builder ==="
  validate_config

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
  if [[ -f "${REPO_ROOT}/custom/feeds.conf" ]]; then
    cp "${REPO_ROOT}/custom/feeds.conf" feeds.conf.default
  fi
  ./scripts/feeds update -a
  ./scripts/feeds install -a

  # -------------------------------------------------- 3. 自定义包 & overlay
  log_info "注入自定义包与文件 overlay ..."
  mkdir -p package/kernel
  cp -r "${REPO_ROOT}/package/kernel/kmod-fs-virtiofs" package/kernel/
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
  # NOTE: OpenWrt 的 make 命令行本身携带数千个 CONFIG_* 环境变量，
  # 并行度过高时子进程 execve 会触发 "Argument list too long"（E2BIG），
  # 因此对 jobs 设上限。
  if (( jobs > 8 )); then
    log_warn "并行度 ${jobs} 过高，限制为 8（避免 E2BIG: Argument list too long）"
    jobs=8
  fi

  log_info "开始编译 (make -j${jobs}, W=0) ..."
  make -j"${jobs}" W=0 || { log_warn "并行编译失败，回退单线程定位错误"; make -j1 W=0 V=s; }

  log_info "安装打包根目录并生成镜像 ..."
  make install
  # 镜像阶段并行度降低：rootfs 组装会 fork 大量 cp/rsync，argv+env 超限即 E2BIG
  make image -j"$( (( jobs > 4 )) && echo 4 || echo "${jobs}" )"
  cfg_bool features.luci.enabled && make package/luci/compile || true

  # ------------------------------------------------------------ 6. dist
  local tdir
  tdir="$(target_dir)"
  if [[ ! -d "${tdir}" ]]; then
    log_err "找不到产物目录 ${SRC_DIR}/${tdir}（检查 target.board/subtarget）"
    exit 1
  fi
  mkdir -p "${OUT_DIR}"
  cp -f "${tdir}"/*.img.gz "${tdir}"/*.bin "${tdir}"/*.manifest "${tdir}/config.buildinfo" "${OUT_DIR}/" 2>/dev/null || \
    cp -rf "${tdir}/." "${OUT_DIR}/"

  write_manifest "${OUT_DIR}/manifest.json" "${board}" "${subtarget}" "${profile}"
  log_info "完成！产物位于 ${OUT_DIR}/"
  ls -lh "${OUT_DIR}" | sed 's/^/  /'
}

generate_dotconfig() {
  local board subtarget
  board="$(cfg_required target.board)"
  subtarget="$(cfg_required target.subtarget)"
  # 基础：默认配置 + 关闭 initramfs-kernel（PVE 用不到），开启 gzip 镜像
  cat > .config <<EOF
CONFIG_TARGET_${board}=y
CONFIG_TARGET_${board}_${subtarget}=y
CONFIG_TARGET_PROFILE="DEVICE_generic"
CONFIG_USE_IMAGELIST=y
EOF

  # 通用优化项
  cat >> .config <<'EOF'
# 基础体验
CONFIG_ALL_KMODS=y
CONFIG_DEVEL=y
CONFIG_CCACHE=y
CONFIG_COLLECT_KERNEL_DEBUG=n
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
EOF

  cfg_bool kernel.lto && echo 'CONFIG_USE_LTO=y' >> .config

  # ------------------------------------------------------------- virtio
  # x86/64 目标内核已 built-in virtio-net/-blk/-scsi/-balloon/-rng，
  # 这里只补充少量 kmod 以覆盖非 built-in 场景（如 PCI hotplug）。
  if cfg_bool features.virtio.enabled; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-virtio-console=y
CONFIG_PACKAGE_kmod-virtio-balloon=y
CONFIG_PACKAGE_kmod-virtio-rng=y
EOF
  fi

  # ---------------------------------------------------------- virtiofs
  if cfg_bool features.virtiofs.enabled; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-fs-virtiofs=y
CONFIG_PACKAGE_virtiofsd=n
EOF
    cfg_bool features.virtiofs.fuse && \
      echo 'CONFIG_PACKAGE_fuse-utils=y' >> .config
  fi

  # -------------------------------------------------------------- p9fs
  if cfg_bool features.p9fs.enabled; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_kmod-fs-9p=y
CONFIG_PACKAGE_kmod-virtio-9p=y
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
CONFIG_PACKAGE_kmod-nft-bridge=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-nft-nat=y
EOF
  cfg_bool features.network.iptables_nft && cat >> .config <<'EOF'
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_ip6tables-nft=y
CONFIG_PACKAGE_kmod-nft-iptables=y
EOF
  if cfg_bool features.network.bridge; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_bridge-utils=y
CONFIG_PACKAGE_kmod-bridge=y
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
CONFIG_PACKAGE_kmod-sched-fq-codel=y
CONFIG_PACKAGE_kmod-sched-cake-virtual=n
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

  # 让 olddefconfig 补齐所有缺省值
  make defconfig
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
