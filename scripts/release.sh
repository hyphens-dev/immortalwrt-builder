#!/usr/bin/env bash
# Prepare release artifacts locally (used outside CI, e.g. after a local build).
# CI does not call this script - see .github/workflows/build.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

parse_config

OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"
RELEASE_DIR="${RELEASE_DIR:-${PROJECT_ROOT}/release}"

generate_changelog() {
    local output_file="$1"
    local repo_dir="${2:-${PROJECT_ROOT}}"
    local limit="${3:-50}"

    log_info "Generating changelog..."

    {
        echo "# Changelog"
        echo ""
        echo "## $(date '+%Y-%m-%d')"
        echo ""

        if git -C "${repo_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
            git -C "${repo_dir}" log --oneline -n "${limit}" --no-merges \
                --pretty=format:"- %h %s" 2>/dev/null || echo "- No commit history available"
        else
            echo "- Not a git repository"
        fi
        echo ""
    } > "${output_file}"

    log_info "Changelog saved to: ${output_file}"
}

prepare_release_artifacts() {
    log_info "Preparing release artifacts..."

    if [[ ! -d "${OUTPUT_DIR}" ]]; then
        die "Output directory not found: ${OUTPUT_DIR} (build first)"
    fi

    ensure_dir "${RELEASE_DIR}"

    # Glob the real (versioned) ImmortalWrt file names instead of hardcoding
    # names that never match.
    local pattern
    for pattern in '*squashfs-combined*img*' '*rootfs*' '*kernel.bin' '*.manifest'; do
        while IFS= read -r -d '' f; do
            log_info "Collecting: $(basename "${f}")"
            cp "${f}" "${RELEASE_DIR}/"
        done < <(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name "${pattern}" -print0)
    done

    if [[ -f "${OUTPUT_DIR}/sha256sums.txt" ]]; then
        cp "${OUTPUT_DIR}/sha256sums.txt" "${RELEASE_DIR}/"
    else
        generate_sha256 "${RELEASE_DIR}" "${RELEASE_DIR}/sha256sums.txt"
    fi

    generate_changelog "${RELEASE_DIR}/changelog.md"

    log_info "Release artifacts prepared:"
    ls -lh "${RELEASE_DIR}/"
}

get_release_tag() {
    printf 'v%s' "$(get_build_version)"
}

get_release_name() {
    printf 'ImmortalWrt PVE %s (%s)' "$(get_version)" "$(date '+%Y-%m-%d')"
}

create_release_notes() {
    local notes_file="${RELEASE_DIR}/release_notes.md"

    cat > "${notes_file}" <<EOF
# $(get_release_name)

## Build Information

- **Version**: $(get_version)
- **Kernel**: $(get_kernel_version)
- **Target**: $(get_config_value 'target.arch' 'x86_64')/$(get_config_value 'target.subtarget' 'generic')
- **Build Date**: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

## Features

- VirtIO devices (built into the x86/64 kernel)
- VirtIO-FS host share support
- 9p / virtio-9p host share support
- WireGuard, nftables firewall
- TCP BBR, Cake, fq_codel, irqbalance

## Artifacts

| File | Description |
|------|-------------|
| \`*squashfs-combined.img.gz\` | Combined firmware image (BIOS/UEFI) |
| \`*rootfs.tar.gz\` | Root filesystem tarball |
| \`*kernel.bin\` | Kernel binary |
| \`sha256sums.txt\` | SHA256 checksums |
| \`manifest.json\` | Build manifest |

## Verification

\`\`\`bash
sha256sum -c sha256sums.txt
\`\`\`

## Changelog

$(cat "${RELEASE_DIR}/changelog.md" 2>/dev/null || echo "No changelog available")
EOF

    log_info "Release notes generated: ${notes_file}"
}

main() {
    log_info "Preparing release..."

    prepare_release_artifacts
    create_release_notes

    log_info "Release tag: $(get_release_tag)"
    log_info "Release name: $(get_release_name)"
    log_info "Release preparation completed"
}

main "$@"