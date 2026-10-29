#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

parse_config

OPENWRT_DIR="${OPENWRT_DIR:-${PROJECT_ROOT}/openwrt}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"
CONFIG_DIR="${PROJECT_ROOT}/config"
PATCHES_DIR="${PATCHES_DIR:-${PROJECT_ROOT}/patches}"
CUSTOM_DIR="${PROJECT_ROOT}/custom"

# The CI workflow performs feeds/patches/.config generation itself before
# calling this script. Set BUILDER_SKIP_PREP=true in that case so the .config
# prepared by the workflow is not regenerated (and not overwritten).
BUILDER_SKIP_PREP="${BUILDER_SKIP_PREP:-false}"

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    local cmd
    for cmd in make git; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required commands: ${missing[*]}"
    fi
    log_debug "Build dependencies satisfied"
}

setup_build_environment() {
    log_info "Setting up build environment..."
    ensure_dir "${OPENWRT_DIR}"
    ensure_dir "${OUTPUT_DIR}"
    check_dependencies
}

# -----------------------------------------------------------------------------
# Custom overlay files (custom/files -> <source>/files)
# -----------------------------------------------------------------------------
install_custom_overlay() {
    local files_dir="${CUSTOM_DIR}/files"

    if [[ -d "${files_dir}" ]] && [[ -n "$(ls -A "${files_dir}" 2>/dev/null)" ]]; then
        log_info "Installing custom files overlay from: ${files_dir}"
        ensure_dir "${OPENWRT_DIR}/files"
        cp -a "${files_dir}/." "${OPENWRT_DIR}/files/"
    else
        log_debug "No custom files to install"
    fi

    # In-tree kernel module packages from this repository (e.g. fs-virtiofs)
    local mod_dir="${PROJECT_ROOT}/package/kernel/linux/modules"
    if [[ -d "${mod_dir}" ]] && [[ -n "$(ls -A "${mod_dir}" 2>/dev/null)" ]]; then
        log_info "Installing custom kernel module packages from: ${mod_dir}"
        ensure_dir "${OPENWRT_DIR}/package/kernel/linux/modules"
        cp -a "${mod_dir}/." "${OPENWRT_DIR}/package/kernel/linux/modules/"
    fi

    # Extra packages from custom/packages
    local pkg_dir="${CUSTOM_DIR}/packages"
    if [[ -d "${pkg_dir}" ]] && [[ -n "$(ls -A "${pkg_dir}" 2>/dev/null)" ]]; then
        log_info "Installing custom packages from: ${pkg_dir}"
        ensure_dir "${OPENWRT_DIR}/package/custom"
        cp -a "${pkg_dir}/." "${OPENWRT_DIR}/package/custom/"
    fi
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Feature toggles are translated into OpenWrt *package* symbols. Raw kernel
# Kconfig symbols (CONFIG_VIRTIO, CONFIG_TCP_CONG_BBR, ...) are NOT valid in
# the OpenWrt top level .config - they are silently dropped by make defconfig.
#
# VirtIO device drivers are already built into the x86/64 target kernel, so the
# virtio toggles only control the auxiliary packages (virtiofs / 9p).
append_feature_config() {
    local target_config="${OPENWRT_DIR}/.config"
    local virtiofs p9fs wireguard nftables bbr mihomo smartdns luci docker cake fq irq

    virtiofs="$(to_bool "$(get_config_value 'features.virtiofs.enabled' 'true')")"
    p9fs="$(to_bool "$(get_config_value 'features.p9fs.enabled' 'true')")"
    wireguard="$(to_bool "$(get_config_value 'features.network.wireguard' 'true')")"
    nftables="$(to_bool "$(get_config_value 'features.network.nftables' 'true')")"
    bbr="$(to_bool "$(get_config_value 'features.performance.bbr' 'true')")"
    cake="$(to_bool "$(get_config_value 'features.performance.cake' 'true')")"
    fq="$(to_bool "$(get_config_value 'features.performance.fq_codel' 'true')")"
    irq="$(to_bool "$(get_config_value 'features.performance.irq_balance' 'true')")"
    mihomo="$(to_bool "$(get_config_value 'features.proxy.mihomo' 'false')")"
    smartdns="$(to_bool "$(get_config_value 'features.proxy.smartdns' 'true')")"
    luci="$(to_bool "$(get_config_value 'features.system.luci' 'true')")"
    docker="$(to_bool "$(get_config_value 'features.system.docker' 'false')")"

    {
        echo ""
        echo "# --- generated from config.yml feature toggles ---"

        if [[ "${virtiofs}" == "true" ]]; then
            echo "# VirtIO-FS (mount PVE host directories in the guest)"
            echo "CONFIG_PACKAGE_kmod-fs-virtiofs=y"
            echo "CONFIG_PACKAGE_kmod-fuse=y"
        fi

        if [[ "${p9fs}" == "true" ]]; then
            echo "# 9p / virtio-9p (alternative host-guest sharing)"
            echo "CONFIG_PACKAGE_kmod-fs-9p=y"
            echo "CONFIG_PACKAGE_kmod-9pnet=y"
            echo "CONFIG_PACKAGE_kmod-9pvirtio=y"
        fi

        if [[ "${wireguard}" == "true" ]]; then
            echo "# WireGuard"
            echo "CONFIG_PACKAGE_kmod-wireguard=y"
            echo "CONFIG_PACKAGE_wireguard-tools=y"
            [[ "${luci}" == "true" ]] && echo "CONFIG_PACKAGE_luci-proto-wireguard=y"
        fi

        if [[ "${nftables}" == "true" ]]; then
            echo "# nftables firewall"
            echo "CONFIG_PACKAGE_kmod-nft-core=y"
            echo "CONFIG_PACKAGE_kmod-nft-nat=y"
            echo "CONFIG_PACKAGE_kmod-nft-fib=y"
            echo "CONFIG_PACKAGE_nftables-json=y"
            echo "CONFIG_PACKAGE_iptables-nft=y"
        fi

        if [[ "${bbr}" == "true" ]]; then
            echo "# TCP BBR"
            echo "CONFIG_PACKAGE_kmod-tcp-bbr=y"
        fi
        if [[ "${fq}" == "true" || "${cake}" == "true" ]]; then
            echo "# QoS schedulers (fq_codel lives in kmod-sched-core)"
            echo "CONFIG_PACKAGE_kmod-sched-core=y"
        fi
        if [[ "${cake}" == "true" ]]; then
            echo "CONFIG_PACKAGE_kmod-sched-cake=y"
        fi
        if [[ "${irq}" == "true" ]]; then
            echo "CONFIG_PACKAGE_irqbalance=y"
        fi

        if [[ "${mihomo}" == "true" ]]; then
            # mihomo is not part of the official 24.10 feeds; it must come from
            # an external feed added via custom/feeds.conf.
            if [[ -f "${CUSTOM_DIR}/feeds.conf" ]] && grep -q 'mihomo\|nikki' "${CUSTOM_DIR}/feeds.conf"; then
                echo "CONFIG_PACKAGE_mihomo=y"
            else
                log_warn "features.proxy.mihomo=true but no mihomo feed is configured"
                log_warn "Add a feed to custom/feeds.conf (e.g. nikki) or disable the toggle"
            fi
        fi
        if [[ "${smartdns}" == "true" ]]; then
            echo "CONFIG_PACKAGE_smartdns=y"
            [[ "${luci}" == "true" ]] && echo "CONFIG_PACKAGE_luci-app-smartdns=y"
        fi

        if [[ "${docker}" == "true" ]]; then
            echo "# Docker / containerd"
            echo "CONFIG_PACKAGE_dockerd=y"
            echo "CONFIG_PACKAGE_docker=y"
        fi
    } >> "${target_config}"
}

generate_config() {
    log_info "Generating build configuration..."

    local base_config="${CONFIG_DIR}/x86_64.config"
    local kernel_config="${CONFIG_DIR}/kernel.config"
    local packages_config="${CONFIG_DIR}/packages.config"
    local target_config="${OPENWRT_DIR}/.config"
    local config_file

    if [[ -f "${target_config}" ]]; then
        log_info "Removing stale .config (regenerating from config/)"
        rm -f "${target_config}"
    fi

    if [[ -f "${base_config}" ]]; then
        cp "${base_config}" "${target_config}"
    else
        log_warn "Base config not found: ${base_config} (using minimal defaults)"
        cat > "${target_config}" <<'EOF'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
EOF
    fi

    # config/kernel.config holds the CONFIG_KERNEL_* options OpenWrt exposes;
    # config/packages.config holds the CONFIG_PACKAGE_* selections.
    for config_file in "${kernel_config}" "${packages_config}"; do
        if [[ -f "${config_file}" ]]; then
            log_debug "Merging ${config_file}"
            cat "${config_file}" >> "${target_config}"
        else
            log_warn "Config file not found: ${config_file}"
        fi
    done

    append_feature_config

    # cpu_opt / optimization have no OpenWrt x86 Kconfig symbol (CONFIG_CPU_TYPE
    # does not exist for this target), so they cannot be applied through
    # .config. Say so instead of emitting a symbol make defconfig would drop.
    local cpu_opt optimization
    cpu_opt="$(get_config_value 'kernel.cpu_opt' 'none')"
    optimization="$(get_config_value 'kernel.optimization' 'default')"
    if [[ "${cpu_opt}" != "none" ]]; then
        log_warn "kernel.cpu_opt='${cpu_opt}' is NOT applied: OpenWrt x86_64 has no"
        log_warn "Kconfig symbol for -march tuning (see docs/cpu-tuning.md)."
    fi
    if [[ "${optimization}" != "default" ]]; then
        log_warn "kernel.optimization='${optimization}' is NOT applied for the same reason."
    fi

    # packages.include / packages.exclude from config.yml
    local pkg include_pkgs exclude_pkgs
    include_pkgs="$(get_config_value 'packages.include' '')"
    exclude_pkgs="$(get_config_value 'packages.exclude' '')"

    if [[ -n "${include_pkgs}" ]]; then
        log_info "Adding packages from config.yml: ${include_pkgs}"
        for pkg in ${include_pkgs}; do
            echo "CONFIG_PACKAGE_${pkg}=y" >> "${target_config}"
        done
    fi

    if [[ -n "${exclude_pkgs}" ]]; then
        log_info "Excluding packages from config.yml: ${exclude_pkgs}"
        for pkg in ${exclude_pkgs}; do
            echo "# CONFIG_PACKAGE_${pkg} is not set" >> "${target_config}"
        done
    fi

    # Link-time optimisation -> CONFIG_USE_LTO (the only LTO knob OpenWrt has)
    if [[ "$(to_bool "$(get_config_value 'kernel.lto' 'off')")" == "true" ]]; then
        log_info "Enabling LTO (CONFIG_USE_LTO=y)"
        echo "CONFIG_USE_LTO=y" >> "${target_config}"
    fi

    # defconfig must run after the feeds are available so that package
    # symbols coming from feeds (luci, smartdns, ...) resolve correctly.
    pushd "${OPENWRT_DIR}" > /dev/null
    make defconfig
    popd > /dev/null

    log_info "Configuration generated: ${target_config}"
}

# -----------------------------------------------------------------------------
# Feeds
# -----------------------------------------------------------------------------
setup_extra_feeds() {
    local extra="${CUSTOM_DIR}/feeds.conf"

    if [[ ! -f "${extra}" ]]; then
        log_debug "No custom/feeds.conf, using upstream feeds only"
        return 0
    fi

    log_info "Merging extra feeds from: ${extra}"
    local line
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        if grep -qxF "${line}" "${OPENWRT_DIR}/feeds.conf.default" 2>/dev/null; then
            log_debug "Feed already present: ${line}"
        else
            printf '%s\n' "${line}" >> "${OPENWRT_DIR}/feeds.conf.default"
            log_info "Added feed: ${line}"
        fi
    done < "${extra}"
}

download_feeds() {
    log_info "Updating package feeds..."
    pushd "${OPENWRT_DIR}" > /dev/null
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    popd > /dev/null
}

# -----------------------------------------------------------------------------
# Compile
# -----------------------------------------------------------------------------
compile_firmware() {
    log_info "Starting firmware compilation..."

    local jobs timeout_minutes attempts max_attempts
    jobs="$(get_config_value 'build.jobs' '0')"
    if [[ "${jobs}" == "0" || -z "${jobs}" ]]; then
        jobs="$(get_cpu_count)"
    fi

    timeout_minutes="$(get_config_value 'build.timeout' '360')"
    max_attempts="$(get_config_value 'build.max_retries' '1')"
    if [[ "$(to_bool "$(get_config_value 'build.retry' 'false')")" != "true" ]]; then
        max_attempts=1
    fi
    [[ "${max_attempts}" -lt 1 ]] && max_attempts=1

    local verbose_flag=""
    [[ "$(to_bool "$(get_config_value 'build.verbose' 'false')")" == "true" ]] && verbose_flag="V=s"

    pushd "${OPENWRT_DIR}" > /dev/null

    log_info "Building with ${jobs} jobs (timeout: ${timeout_minutes}m, attempts: ${max_attempts})"

    local attempt=1
    while (( attempt <= max_attempts )); do
        log_info "Compile attempt ${attempt}/${max_attempts}"
        if timeout "$((timeout_minutes * 60))" make -j"${jobs}" ${verbose_flag} world; then
            popd > /dev/null
            log_info "Firmware compilation completed"
            return 0
        fi
        log_warn "Compile attempt ${attempt} failed"
        attempt=$(( attempt + 1 ))
    done

    popd > /dev/null
    die "Firmware compilation failed after ${max_attempts} attempt(s)"
}

# -----------------------------------------------------------------------------
# Artifacts
# -----------------------------------------------------------------------------
collect_artifacts() {
    log_info "Collecting build artifacts..."

    ensure_dir "${OUTPUT_DIR}"

    # OpenWrt output lives under bin/targets/<board>/<subtarget>, i.e.
    # bin/targets/x86/64 for this project - not bin/targets/x86_64/generic.
    local board subtarget
    board="$(get_config_value 'target.board' 'x86')"
    subtarget="$(get_config_value 'target.subtarget' '64')"
    local bin_dir="${OPENWRT_DIR}/bin/targets/${board}/${subtarget}"

    if [[ ! -d "${bin_dir}" ]]; then
        log_warn "Build output directory not found: ${bin_dir}"
        return 0
    fi

    # Patterns come from config.yml (output.*) and are globs. ImmortalWrt
    # prefixes image names with the version, e.g.
    #   openwrt-24.10.0-x86-64-generic-squashfs-combined.img.gz
    local pattern
    local patterns=()
    patterns+=("$(get_config_value 'output.firmware' '*squashfs-combined*img*')")
    patterns+=("$(get_config_value 'output.rootfs' '*rootfs*')")
    patterns+=("$(get_config_value 'output.kernel' '*kernel.bin')")
    patterns+=('*.manifest' 'config.buildinfo')

    for pattern in "${patterns[@]}"; do
        while IFS= read -r -d '' artifact; do
            log_info "Collecting: $(basename "${artifact}")"
            cp "${artifact}" "${OUTPUT_DIR}/"
        done < <(find "${bin_dir}" -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null)
    done

    if [[ "$(to_bool "$(get_config_value 'output.sha256sum' 'true')")" == "true" ]]; then
        generate_sha256 "${OUTPUT_DIR}" "${OUTPUT_DIR}/sha256sums.txt"
    fi

    if [[ "$(to_bool "$(get_config_value 'output.manifest' 'true')")" == "true" ]]; then
        generate_manifest "${OUTPUT_DIR}/manifest.json"
    fi

    log_info "Artifacts collected in: ${OUTPUT_DIR}"
    ls -lh "${OUTPUT_DIR}/"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local start_time
    start_time=$(date +%s)

    log_info "Starting ImmortalWrt PVE Builder"
    log_info "Version: $(get_build_version)"
    log_info "Source directory: ${OPENWRT_DIR}"

    setup_build_environment

    if [[ "${BUILDER_SKIP_PREP}" == "true" ]]; then
        log_info "BUILDER_SKIP_PREP=true - skipping patches/feeds/config generation"
    else
        install_custom_overlay
        apply_patches
        setup_extra_feeds
        download_feeds
        generate_config
    fi

    compile_firmware
    collect_artifacts

    local end_time duration
    end_time=$(date +%s)
    duration=$(( end_time - start_time ))

    log_info "Build completed in $((duration / 60))m $((duration % 60))s"
}

apply_patches() {
    log_info "Applying patches..."
    "${SCRIPT_DIR}/patch.sh"
}

main "$@"
