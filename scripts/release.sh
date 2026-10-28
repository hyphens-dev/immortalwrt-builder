#!/usr/bin/env bash
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

        if git -C "${repo_dir}" log --oneline -n "${limit}" --no-merges 2>/dev/null; then
            git -C "${repo_dir}" log --oneline -n "${limit}" --no-merges | while read -r line; do
                echo "- ${line}"
            done
        else
            echo "- No commit history available"
        fi
    } > "${output_file}"

    log_info "Changelog saved to: ${output_file}"
}

prepare_release_artifacts() {
    log_info "Preparing release artifacts..."

    ensure_dir "${RELEASE_DIR}"

    if [[ -d "${OUTPUT_DIR}" ]]; then
        cp -v "${OUTPUT_DIR}"/*.img.gz "${RELEASE_DIR}/" 2>/dev/null || true
        cp -v "${OUTPUT_DIR}"/*.tar.gz "${RELEASE_DIR}/" 2>/dev/null || true
        cp -v "${OUTPUT_DIR}"/*.bin "${RELEASE_DIR}/" 2>/dev/null || true
        cp -v "${OUTPUT_DIR}/sha256sums.txt" "${RELEASE_DIR}/" 2>/dev/null || true
        cp -v "${OUTPUT_DIR}/manifest.json" "${RELEASE_DIR}/" 2>/dev/null || true
    fi

    generate_changelog "${RELEASE_DIR}/changelog.md"

    log_info "Release artifacts prepared:"
    ls -lh "${RELEASE_DIR}/"
}

get_release_tag() {
    local version
    version="$(get_build_version)"
    echo "v${version}"
}

get_release_name() {
    local version
    version="$(get_version)"
    local date
    date="$(date '+%Y-%m-%d')"
    echo "ImmortalWrt PVE ${version} (${date})"
}

create_release_notes() {
    local notes_file="${RELEASE_DIR}/release_notes.md"

    cat > "${notes_file}" << EOF
# $(get_release_name)

## Build Information

- **Version**: $(get_version)
- **Kernel**: $(get_kernel_version)
- **Target**: x86_64
- **Build Date**: $(date '+%Y-%m-%d %H:%M:%S UTC')

## Features

- VirtIO support (net, block, scsi, balloon, rng, console, input, mmio)
- VirtIO-FS support
- PVE/KVM optimized
- WireGuard VPN
- nftables firewall
- BBR congestion control
- x86-64-v3 CPU optimization

## Artifacts

| File | Description |
|------|-------------|
| *.img.gz | Firmware image (gzip compressed) |
| *.tar.gz | Root filesystem |
| *.bin | Kernel binary |
| sha256sums.txt | SHA256 checksums |
| manifest.json | Build manifest |

## Installation

See [README.md](README.md) for installation instructions.

## Changelog

$(cat "${RELEASE_DIR}/changelog.md" 2>/dev/null || echo "No changelog available")
EOF

    log_info "Release notes generated: ${notes_file}"
}

main() {
    log_info "Preparing release..."

    prepare_release_artifacts
    create_release_notes

    local tag
    tag="$(get_release_tag)"
    log_info "Release tag: ${tag}"
    log_info "Release name: $(get_release_name)"
    log_info "Release preparation completed"
}

main "$@"
