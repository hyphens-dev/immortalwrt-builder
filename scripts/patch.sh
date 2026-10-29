#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Patch roots that are scanned, in order. Both the classic layout
# (patches/{kernel,target,pve}) and the custom overlay (custom/patches/...)
# are supported; missing directories are skipped.
PATCH_ROOTS=(
    "${PATCHES_DIR:-${PROJECT_ROOT}/patches}"
    "${CUSTOM_PATCHES_DIR:-${PROJECT_ROOT}/custom/patches}"
)

OPENWRT_DIR="${OPENWRT_DIR:-${PROJECT_ROOT}/openwrt}"
DRY_RUN="${DRY_RUN:-false}"

# Where each patch category is applied, relative to the source tree
declare -A PATCH_TARGETS=(
    [kernel]="target/linux/x86"
    [target]="target"
    [pve]="."
)

# Apply a single patch file. Returns:
#   0 - applied (or already applied / skipped on purpose)
#   1 - failed to apply
apply_one_patch() {
    local patch_file="$1"
    local target_dir="$2"
    local patch_name
    patch_name="$(basename "${patch_file}")"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would apply: ${patch_name} -> ${target_dir}"
        return 0
    fi

    log_info "Applying: ${patch_name}"

    # Already applied? (git repos only) -> treat as success so that the
    # script is idempotent and safe to run twice.
    if git -C "${target_dir}" apply --reverse --check "${patch_file}" &>/dev/null; then
        log_info "Already applied, skipping: ${patch_name}"
        return 0
    fi

    if git -C "${target_dir}" apply --check "${patch_file}" &>/dev/null; then
        git -C "${target_dir}" apply "${patch_file}"
        log_info "Applied: ${patch_name}"
        return 0
    fi

    # Fall back to patch(1) for non-git trees
    if patch -d "${target_dir}" -p1 --dry-run < "${patch_file}" &>/dev/null; then
        patch -d "${target_dir}" -p1 < "${patch_file}"
        log_info "Applied (patch): ${patch_name}"
        return 0
    fi

    log_error "Failed to apply: ${patch_name}"
    return 1
}

apply_patch_dir() {
    local patch_dir="$1"
    local category
    category="$(basename "${patch_dir}")"

    if [[ ! -d "${patch_dir}" ]]; then
        log_debug "No patches directory for: ${category}"
        return 0
    fi

    local target_rel="${PATCH_TARGETS[${category}]:-.}"
    local target_dir="${OPENWRT_DIR}/${target_rel}"

    if [[ ! -d "${target_dir}" ]]; then
        log_warn "Patch target directory not found: ${target_dir} (skipping ${category})"
        return 0
    fi

    local patch_count
    patch_count="$(find "${patch_dir}" -maxdepth 1 -name '*.patch' -type f | wc -l)"
    if [[ "${patch_count}" -eq 0 ]]; then
        log_debug "No .patch files in: ${patch_dir}"
        return 0
    fi

    log_info "Applying ${patch_count} patch(es) from ${category}/ -> ${target_rel}"

    local failed=0
    local patch_file
    # Process substitution keeps the loop in the current shell so that a
    # failure can actually abort the script.
    while IFS= read -r patch_file; do
        apply_one_patch "${patch_file}" "${target_dir}" || failed=1
    done < <(find "${patch_dir}" -maxdepth 1 -name '*.patch' -type f | sort)

    if (( failed )); then
        log_error "One or more patches from ${category}/ failed to apply"
        return 1
    fi

    return 0
}

main() {
    if [[ ! -d "${OPENWRT_DIR}" ]]; then
        die "Source directory not found: ${OPENWRT_DIR}"
    fi

    log_info "Applying patches to: ${OPENWRT_DIR}"

    local root category
    local failed=0

    for root in "${PATCH_ROOTS[@]}"; do
        if [[ ! -d "${root}" ]]; then
            log_debug "Patch root not present: ${root}"
            continue
        fi
        for category in kernel target pve; do
            apply_patch_dir "${root}/${category}" || failed=1
        done
    done

    if (( failed )); then
        die "Patch application failed"
    fi

    log_info "All patches applied successfully"
}

main "$@"
