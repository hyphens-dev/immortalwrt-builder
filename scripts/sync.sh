#!/usr/bin/env bash
# Local upstream-change detection.
#
# This script NEVER rebases or merges upstream into this repository: the two
# repositories share no history and the firmware source tree is multi-gigabyte.
# It only reports whether the configured upstream ref has moved past the commit
# recorded in .upstream-built.
#
# Usage:
#   scripts/sync.sh              # report only
#   scripts/sync.sh --record     # record current upstream HEAD as built
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

parse_config

STATE_FILE="${PROJECT_ROOT}/.upstream-built"
UPSTREAM_REPO="$(get_config_value 'source.repo' 'https://github.com/immortalwrt/immortalwrt.git')"
UPSTREAM_BRANCH="$(get_config_value 'source.branch' 'openwrt-24.10')"
UPSTREAM_TAG="$(get_config_value 'source.tag' '')"

resolve_ref() {
    if [[ -n "${UPSTREAM_TAG}" ]]; then
        printf 'refs/tags/%s' "${UPSTREAM_TAG}"
    else
        printf 'refs/heads/%s' "${UPSTREAM_BRANCH}"
    fi
}

main() {
    local record=false
    if [[ "${1:-}" == "--record" ]]; then
        record=true
    fi

    local ref upstream_commit last_built=""
    ref="$(resolve_ref)"

    log_info "Upstream: ${UPSTREAM_REPO} (${ref})"

    # Shallow, cheap resolution - no clone needed
    upstream_commit="$(git ls-remote "${UPSTREAM_REPO}" "${ref}" "refs/tags/${UPSTREAM_TAG:-none}^{}" 2>/dev/null \
                        | head -1 | cut -f1)"

    if [[ -z "${upstream_commit}" ]]; then
        die "Could not resolve upstream ref: ${ref}"
    fi

    if [[ -f "${STATE_FILE}" ]]; then
        last_built="$(tr -d '[:space:]' < "${STATE_FILE}")"
    fi

    log_info "Upstream HEAD : ${upstream_commit}"
    log_info "Last built    : ${last_built:-<none>}"

    if [[ "${record}" == "true" ]]; then
        printf '%s\n' "${upstream_commit}" > "${STATE_FILE}"
        log_info "Recorded ${upstream_commit} in .upstream-built"
        return 0
    fi

    if [[ "${upstream_commit}" == "${last_built}" ]]; then
        log_info "No new upstream commits since last build"
        return 1
    fi

    log_info "New upstream commits detected - a rebuild is warranted"
    return 0
}

main "$@"