#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

parse_config

OPENWRT_DIR="${OPENWRT_DIR:-${PROJECT_ROOT}/openwrt}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"
CONFIG_DIR="${PROJECT_ROOT}/config"
PATCHES_DIR="${PROJECT_ROOT}/patches"

setup_build_environment() {
    log_info "Setting up build environment..."
    ensure_dir "${OPENWRT_DIR}"
    ensure_dir "${OUTPUT_DIR}"
    check_dependencies
}

generate_config() {
    log_info "Generating build configuration..."

    local base_config="${CONFIG_DIR}/x86_64.config"
    local kernel_config="${CONFIG_DIR}/kernel.config"
    local packages_config="${CONFIG_DIR}/packages.config"
    local target_config="${OPENWRT_DIR}/.config"

    if [[ -f "${base_config}" ]]; then
        cp "${base_config}" "${target_config}"
    else
        cat > "${target_config}" << 'EOF'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
EOF
    fi

    for config_file in "${kernel_config}" "${packages_config}"; do
        if [[ -f "${config_file}" ]]; then
            cat "${config_file}" >> "${target_config}"
        fi
    done

    local virtio_enabled virtiofs_enabled wireguard_enabled nftables_enabled bbr_enabled mihomo_enabled
    virtio_enabled="$(get_config_value 'features.virtio.enabled' 'true')"
    virtiofs_enabled="$(get_config_value 'features.virtiofs.enabled' 'true')"
    wireguard_enabled="$(get_config_value 'features.network.wireguard' 'true')"
    nftables_enabled="$(get_config_value 'features.network.nftables' 'true')"
    bbr_enabled="$(get_config_value 'features.performance.bbr' 'true')"
    mihomo_enabled="$(get_config_value 'features.proxy.mihomo' 'true')"

    if [[ "${virtio_enabled}" == "true" ]]; then
        cat >> "${target_config}" << 'EOF'
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_SCSI=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_RNG=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_MMIO=y
EOF
    fi

    if [[ "${virtiofs_enabled}" == "true" ]]; then
        cat >> "${target_config}" << 'EOF'
CONFIG_VIRTIO_FS=y
CONFIG_FUSE_FS=y
CONFIG_KMOD_FS_VIRTIOFS=y
EOF
    fi

    if [[ "${wireguard_enabled}" == "true" ]]; then
        cat >> "${target_config}" << 'EOF'
CONFIG_PACKAGE_kmod-wireguard=y
CONFIG_PACKAGE_wireguard-tools=y
CONFIG_PACKAGE_luci-proto-wireguard=y
EOF
    fi

    if [[ "${nftables_enabled}" == "true" ]]; then
        cat >> "${target_config}" << 'EOF'
CONFIG_PACKAGE_kmod-nftables=y
CONFIG_PACKAGE_nftables=y
CONFIG_PACKAGE_iptables-nft=y
EOF
    fi

    if [[ "${bbr_enabled}" == "true" ]]; then
        cat >> "${target_config}" << 'EOF'
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
EOF
    fi

    if [[ "${mihomo_enabled}" == "true" ]]; then
        cat >> "${target_config}" << 'EOF'
CONFIG_PACKAGE_mihomo=y
EOF
    fi

    local cpu_opt
    cpu_opt="$(get_config_value 'kernel.cpu_opt' 'x86-64-v3')"
    if [[ "${cpu_opt}" != "none" ]]; then
        cat >> "${target_config}" << EOF
CONFIG_TARGET_OPTIONS=y
CONFIG_CPU_TYPE="${cpu_opt}"
EOF
    fi

    pushd "${OPENWRT_DIR}" > /dev/null
    make defconfig
    popd > /dev/null

    log_info "Configuration generated successfully"
}

apply_patches() {
    log_info "Applying patches..."
    "${SCRIPT_DIR}/patch.sh"
}

download_feeds() {
    log_info "Downloading feeds..."
    pushd "${OPENWRT_DIR}" > /dev/null
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    popd > /dev/null
}

compile_firmware() {
    log_info "Starting firmware compilation..."

    local jobs
    jobs="$(get_config_value 'build.jobs' '0')"
    if [[ "${jobs}" == "0" ]]; then
        jobs="$(get_cpu_count)"
    fi

    local timeout_minutes
    timeout_minutes="$(get_config_value 'build.timeout' '120')"

    pushd "${OPENWRT_DIR}" > /dev/null

    log_info "Building with ${jobs} jobs (timeout: ${timeout_minutes}m)"
    timeout "$((timeout_minutes * 60))" make -j"${jobs}" || {
        log_warn "Parallel build failed, retrying with single job..."
        make -j1 V=s
    }

    popd > /dev/null

    log_info "Firmware compilation completed"
}

collect_artifacts() {
    log_info "Collecting build artifacts..."

    ensure_dir "${OUTPUT_DIR}"

    local firmware_pattern rootfs_pattern kernel_pattern
    firmware_pattern="$(get_config_value 'output.firmware' 'openwrt-x86-64-generic-squashfs-combined*')"
    rootfs_pattern="$(get_config_value 'output.rootfs' 'openwrt-x86-64-generic-rootfs*')"
    kernel_pattern="$(get_config_value 'output.kernel' 'openwrt-x86-64-generic-kernel*')"

    local bin_dir="${OPENWRT_DIR}/bin/targets/x86/64"

    if [[ -d "${bin_dir}" ]]; then
        find "${bin_dir}" -name "${firmware_pattern}" -exec cp {} "${OUTPUT_DIR}/" \;
        find "${bin_dir}" -name "${rootfs_pattern}" -exec cp {} "${OUTPUT_DIR}/" \;
        find "${bin_dir}" -name "${kernel_pattern}" -exec cp {} "${OUTPUT_DIR}/" \;
        find "${bin_dir}" -name "*.manifest" -exec cp {} "${OUTPUT_DIR}/manifest.build" \;
    fi

    local version
    version="$(get_build_version)"

    if [[ "$(get_config_value 'output.sha256sum' 'true')" == "true" ]]; then
        generate_sha256 "${OUTPUT_DIR}" "${OUTPUT_DIR}/sha256sums.txt"
    fi

    if [[ "$(get_config_value 'output.manifest' 'true')" == "true" ]]; then
        generate_manifest "${OUTPUT_DIR}/manifest.json"
    fi

    log_info "Artifacts collected in: ${OUTPUT_DIR}"
    ls -lh "${OUTPUT_DIR}/"
}

main() {
    local start_time
    start_time=$(date +%s)

    log_info "Starting ImmortalWrt PVE Builder"
    log_info "Version: $(get_build_version)"

    setup_build_environment
    generate_config
    apply_patches
    download_feeds
    compile_firmware
    collect_artifacts

    local end_time duration
    end_time=$(date +%s)
    duration=$(( end_time - start_time ))

    log_info "Build completed in $((duration / 60))m $((duration % 60))s"
}

main "$@"
