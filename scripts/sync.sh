#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

parse_config

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="$(get_config_value 'source.repo' 'https://github.com/immortalwrt/immortalwrt.git')"
UPSTREAM_BRANCH="$(get_config_value 'source.branch' 'openwrt-24.10')"
SYNC_METHOD="$(get_config_value 'sync.method' 'rebase')"
CHECK_ONLY="${CHECK_ONLY:-false}"
FORCE_SYNC="${FORCE_SYNC:-false}"

setup_upstream() {
    local repo_dir="${1:-.}"

    if ! git -C "${repo_dir}" remote get-url "${UPSTREAM_REMOTE}" &>/dev/null; then
        log_info "Adding upstream remote: ${UPSTREAM_URL}"
        git -C "${repo_dir}" remote add "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
    else
        local current_url
        current_url="$(git -C "${repo_dir}" remote get-url "${UPSTREAM_REMOTE}")"
        if [[ "${current_url}" != "${UPSTREAM_URL}" ]]; then
            log_info "Updating upstream URL: ${UPSTREAM_URL}"
            git -C "${repo_dir}" remote set-url "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
        fi
    fi
}

fetch_upstream() {
    local repo_dir="${1:-.}"

    log_info "Fetching upstream changes..."
    git -C "${repo_dir}" fetch "${UPSTREAM_REMOTE}" --tags --prune
}

check_updates() {
    local repo_dir="${1:-.}"

    local local_commit upstream_commit
    local_commit="$(git -C "${repo_dir}" rev-parse HEAD)"
    upstream_commit="$(git -C "${repo_dir}" rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || echo "unknown")"

    if [[ "${local_commit}" == "${upstream_commit}" ]]; then
        log_info "Already up-to-date with upstream"
        return 1
    fi

    local behind ahead
    behind="$(git -C "${repo_dir}" rev-list --count HEAD..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH} 2>/dev/null || echo 0)"
    ahead="$(git -C "${repo_dir}" rev-list --count ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}..HEAD 2>/dev/null || echo 0)"

    log_info "Local is ${behind} commits behind, ${ahead} commits ahead of upstream"
    return 0
}

sync_rebase() {
    local repo_dir="${1:-.}"

    log_info "Syncing with upstream using rebase..."

    local current_branch
    current_branch="$(git -C "${repo_dir}" rev-parse --abbrev-ref HEAD)"

    if ! git -C "${repo_dir}" rebase "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"; then
        log_error "Rebase failed. Aborting..."
        git -C "${repo_dir}" rebase --abort
        return 1
    fi

    log_info "Rebase completed successfully"
}

sync_merge() {
    local repo_dir="${1:-.}"

    log_info "Syncing with upstream using merge..."

    if ! git -C "${repo_dir}" merge "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" --no-edit; then
        log_error "Merge conflict detected. Please resolve manually."
        return 1
    fi

    log_info "Merge completed successfully"
}

sync_reset() {
    local repo_dir="${1:-.}"

    log_warn "Syncing with upstream using reset (destructive!)"

    if [[ "${FORCE_SYNC}" != "true" ]]; then
        log_error "Reset sync requires --force flag"
        return 1
    fi

    git -C "${repo_dir}" reset --hard "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
    log_info "Reset completed"
}

sync_changes() {
    local repo_dir="${1:-.}"

    case "${SYNC_METHOD}" in
        rebase) sync_rebase "${repo_dir}" ;;
        merge)  sync_merge "${repo_dir}" ;;
        reset)  sync_reset "${repo_dir}" ;;
        *)      die "Unknown sync method: ${SYNC_METHOD}" ;;
    esac
}

main() {
    local repo_dir="${1:-.}"

    log_info "Starting upstream sync..."
    log_info "Upstream: ${UPSTREAM_URL} (${UPSTREAM_BRANCH})"
    log_info "Method: ${SYNC_METHOD}"

    setup_upstream "${repo_dir}"
    fetch_upstream "${repo_dir}"

    if ! check_updates "${repo_dir}"; then
        exit 1
    fi

    if [[ "${CHECK_ONLY}" == "true" ]]; then
        log_info "Updates available (check-only mode)"
        exit 0
    fi

    sync_changes "${repo_dir}"

    log_info "Upstream sync completed successfully"
}

main "$@"
