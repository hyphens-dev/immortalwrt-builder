#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

PATCHES_DIR="${PATCHES_DIR:-${PROJECT_ROOT}/patches}"
DRY_RUN="${DRY_RUN:-false}"

apply_patch_dir() {
    local patch_dir="$1"
    local target_dir="$2"
    local patch_name
    patch_name="$(basename "${patch_dir}")"

    if [[ ! -d "${patch_dir}" ]]; then
        log_debug "No patches found for: ${patch_name}"
        return 0
    fi

    local patch_count
    patch_count=$(find "${patch_dir}" -name "*.patch" -type f 2>/dev/null | wc -l)

    if [[ "${patch_count}" -eq 0 ]]; then
        log_debug "No .patch files in: ${patch_dir}"
        return 0
    fi

    log_info "Applying ${patch_count} patches from: ${patch_name}/"

    find "${patch_dir}" -name "*.patch" -type f | sort | while read -r patch_file; do
        local patch_basename
        patch_basename="$(basename "${patch_file}")"

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Would apply: ${patch_basename}"
            continue
        fi

        log_info "Applying: ${patch_basename}"

        if git -C "${target_dir}" apply --check "${patch_file}" 2>/dev/null; then
            git -C "${target_dir}" apply "${patch_file}"
            log_info "Applied: ${patch_basename}"
        elif patch -d "${target_dir}" -p1 --dry-run < "${patch_file}" > /dev/null 2>&1; then
            patch -d "${target_dir}" -p1 < "${patch_file}"
            log_info "Applied (patch): ${patch_basename}"
        else
            log_error "Failed to apply: ${patch_basename}"
            return 1
        fi
    done
}

main() {
    local openwrt_dir="${OPENWRT_DIR:-${PROJECT_ROOT}/openwrt}"

    if [[ ! -d "${openwrt_dir}" ]]; then
        die "OpenWrt directory not found: ${openwrt_dir}"
    fi

    log_info "Applying patches from: ${PATCHES_DIR}"

    apply_patch_dir "${PATCHES_DIR}/kernel" "${openwrt_dir}/target/linux/x86"
    apply_patch_dir "${PATCHES_DIR}/target" "${openwrt_dir}/target"
    apply_patch_dir "${PATCHES_DIR}/pve" "${openwrt_dir}"

    log_info "All patches applied successfully"
}

main "$@"
