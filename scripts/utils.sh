#!/usr/bin/env bash
# =============================================================================
# ImmortalWrt PVE Builder - Utility Functions
# =============================================================================
# Common functions for logging, config parsing, error handling,
# file operations, version detection, and manifest generation.
# =============================================================================

set -euo pipefail

# =============================================================================
# Global Constants
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly CONFIG_DEFAULT="${PROJECT_ROOT}/config.yml"
readonly COLOR_RESET="\033[0m"

# =============================================================================
# Color Support Detection
# =============================================================================
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    _COLOR_ENABLED=true
    readonly COLOR_RED="\033[0;31m"
    readonly COLOR_GREEN="\033[0;32m"
    readonly COLOR_YELLOW="\033[0;33m"
    readonly COLOR_BLUE="\033[0;34m"
    readonly COLOR_CYAN="\033[0;36m"
    readonly COLOR_BOLD="\033[1m"
    readonly COLOR_DIM="\033[2m"
else
    _COLOR_ENABLED=false
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    readonly COLOR_CYAN=""
    readonly COLOR_BOLD=""
    readonly COLOR_DIM=""
fi

# =============================================================================
# Logging Functions
# =============================================================================

# Print timestamp prefix
_log_timestamp() {
    printf "%(%Y-%m-%d %H:%M:%S)T" -1
}

# Log informational message
# Usage: log_info "message"
log_info() {
    local message="${1:-}"
    printf "${COLOR_GREEN}[INFO]${COLOR_RESET}  %s %b\n" "$(_log_timestamp)" "${message}"
}
export -f log_info

# Log warning message
# Usage: log_warn "message"
log_warn() {
    local message="${1:-}"
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s %b\n" "$(_log_timestamp)" "${message}" >&2
}
export -f log_warn

# Log error message
# Usage: log_error "message"
log_error() {
    local message="${1:-}"
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s %b\n" "$(_log_timestamp)" "${message}" >&2
}
export -f log_error

# Log debug message (only when VERBOSE=true)
# Usage: log_debug "message"
log_debug() {
    local message="${1:-}"
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        printf "${COLOR_CYAN}[DEBUG]${COLOR_RESET} %s %b\n" "$(_log_timestamp)" "${message}" >&2
    fi
}
export -f log_debug

# =============================================================================
# Error Handling
# =============================================================================

# Print error message and exit
# Usage: die "message" [exit_code]
die() {
    local message="${1:-"Fatal error"}"
    local exit_code="${2:-1}"
    log_error "${message}"
    exit "${exit_code}"
}
export -f die

# Trap handler for unexpected errors
# Usage: trap 'trap_error ${LINENO} ${BASH_LINENO[*]} ${FUNCNAME[*]}' ERR
trap_error() {
    local line_no="${1:-unknown}"
    local bash_lineno="${2:-unknown}"
    local func_name="${3:-main}"
    local command="${BASH_COMMAND:-unknown}"

    log_error "Unexpected error in ${func_name} at line ${line_no}"
    log_error "Failed command: ${command}"
    log_error "Call stack: ${func_name} -> line ${bash_lineno}"

    # Cleanup on error if function registered
    if declare -f _cleanup &>/dev/null; then
        _cleanup
    fi

    exit 1
}
export -f trap_error

# Set up error trap
# Usage: setup_error_trap
setup_error_trap() {
    trap 'trap_error ${LINENO} "${BASH_LINENO[*]}" "${FUNCNAME[*]}"' ERR
}
export -f setup_error_trap

# =============================================================================
# Config Parsing
# =============================================================================

# Detect if yq is available
_has_yq() {
    command -v yq &>/dev/null
}

# Parse config.yml and store values for quick lookup
# Usage: parse_config "config.yml"
# Sets _CONFIG_PARSED=true and populates _CONFIG_CACHE associative array
declare -gA _CONFIG_CACHE=()
declare -g _CONFIG_PARSED=false
declare -g _CONFIG_FILE=""

parse_config() {
    local config_file="${1:-${CONFIG_DEFAULT}}"

    if [[ ! -f "${config_file}" ]]; then
        die "Config file not found: ${config_file}"
    fi

    _CONFIG_FILE="${config_file}"
    _CONFIG_CACHE=()

    if _has_yq; then
        # Use yq for reliable YAML parsing
        # Extract all leaf key paths and their values
        while IFS= read -r line; do
            local key="${line%%=*}"
            local value="${line#*=}"
            _CONFIG_CACHE["${key}"]="${value}"
        done < <(yq -r '.. | select(tag == "!!str" or tag == "!!int" or tag == "!!bool" or tag == "!!float") | (path | join(".")) + "=" + . ' "${config_file}" 2>/dev/null)
    else
        # Fallback: indentation-aware parser for the YAML subset used by this
        # project (nested maps + flat lists of scalars). Requires bash 4.2+.
        #
        # A stack of "<indent>:<key>" entries tracks the current path so that
        # arbitrarily deep keys resolve to full dot-paths, e.g.
        # "features.virtiofs.enabled" and "packages.include".
        local _stack=""
        local line stripped indent key value item full_key existing

        # Drop every stack entry at the same or deeper indentation
        _cfg_pop() {
            local entry last_indent
            while [[ -n "${_stack}" ]]; do
                entry="${_stack##*|}"
                last_indent="${entry%%:*}"
                if (( last_indent >= $1 )); then
                    if [[ "${_stack}" == *"|"* ]]; then
                        _stack="${_stack%|*}"
                    else
                        _stack=""
                    fi
                else
                    break
                fi
            done
        }

        # Full dot-path of the current stack
        _cfg_path() {
            local out="" entry
            local IFS='|'
            for entry in ${_stack}; do
                out="${out:+${out}.}${entry#*:}"
            done
            printf '%s' "${out}"
        }

        # Trim surrounding whitespace and one layer of quotes from a scalar
        _cfg_scalar() {
            local v="$1"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            if (( ${#v} >= 2 )) && [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
                v="${v:1:${#v}-2}"
            elif (( ${#v} >= 2 )) && [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
                v="${v:1:${#v}-2}"
            fi
            printf '%s' "${v}"
        }

        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%$'\r'}"

            # Skip comments and blank lines
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ "${line}" =~ ^[[:space:]]*$ ]] && continue

            stripped="${line#"${line%%[![:space:]]*}"}"
            indent=$(( ${#line} - ${#stripped} ))

            # List item: "- value"
            if [[ "${stripped}" =~ ^-[[:space:]]*(.*)$ ]]; then
                item="$(_cfg_scalar "${BASH_REMATCH[1]}")"
                _cfg_pop "${indent}"
                full_key="$(_cfg_path)"
                if [[ -n "${full_key}" && -n "${item}" ]]; then
                    existing="${_CONFIG_CACHE["${full_key}"]:-}"
                    if [[ -n "${existing}" ]]; then
                        _CONFIG_CACHE["${full_key}"]="${existing} ${item}"
                    else
                        _CONFIG_CACHE["${full_key}"]="${item}"
                    fi
                fi
                continue
            fi

            # "key: value" (scalar) or "key:" (nested map header)
            if [[ "${stripped}" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="$(_cfg_scalar "${BASH_REMATCH[2]}")"

                _cfg_pop "${indent}"

                if [[ -n "${value}" ]]; then
                    full_key="$(_cfg_path)"
                    full_key="${full_key:+${full_key}.}${key}"
                    _CONFIG_CACHE["${full_key}"]="${value}"
                    log_debug "config: ${full_key}=${value}"
                else
                    _stack="${_stack:+${_stack}|}${indent}:${key}"
                    log_debug "config: section -> $(_cfg_path)"
                fi
                continue
            fi

            log_debug "config: unparsed line: ${line}"
        done < "${config_file}"
    fi

    _CONFIG_PARSED=true
    log_debug "Parsed config: ${config_file} (${#_CONFIG_CACHE[@]} keys)"
}
export -f parse_config

# Get a config value by dot-notation key
# Usage: get_config_value "key.path" ["default_value"]
get_config_value() {
    local key="${1:-}"
    local default="${2:-}"

    if [[ -z "${key}" ]]; then
        die "get_config_value: key argument required"
    fi

    # Auto-parse if not done yet
    if [[ "${_CONFIG_PARSED}" != "true" ]]; then
        parse_config
    fi

    # Try yq first for nested lookups if available.
    # Sequences are joined with spaces so callers always get a scalar back.
    if _has_yq && [[ -n "${_CONFIG_FILE}" ]]; then
        local value yq_prog
        yq_prog=".${key} | if type == \"array\" then join(\" \") else . end"
        value="$(yq -r "${yq_prog}" "${_CONFIG_FILE}" 2>/dev/null)" || true
        if [[ -n "${value}" && "${value}" != "null" ]]; then
            printf "%s" "${value}"
            return 0
        fi
    fi

    # Check cache
    if [[ -n "${_CONFIG_CACHE["${key}"]+_}" ]]; then
        printf "%s" "${_CONFIG_CACHE["${key}"]}"
        return 0
    fi

    # Return default
    if [[ -n "${default}" ]]; then
        printf "%s" "${default}"
        return 0
    fi

    return 1
}
export -f get_config_value

# =============================================================================
# File Operations
# =============================================================================

# Create directory with parents, exit on failure
# Usage: ensure_dir "/path/to/dir"
ensure_dir() {
    local dir="${1:-}"
    if [[ -z "${dir}" ]]; then
        die "ensure_dir: directory argument required"
    fi
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}" || die "Failed to create directory: ${dir}"
        log_debug "Created directory: ${dir}"
    fi
}
export -f ensure_dir

# Backup a file with timestamp suffix
# Usage: backup_file "/path/to/file"
# Returns: path to backup file
backup_file() {
    local file="${1:-}"
    if [[ -z "${file}" ]]; then
        die "backup_file: file argument required"
    fi
    if [[ ! -f "${file}" ]]; then
        log_debug "backup_file: ${file} does not exist, skipping"
        return 0
    fi

    local backup_path="${file}.$(date +%Y%m%d%H%M%S).bak"
    cp -a "${file}" "${backup_path}" || die "Failed to backup: ${file}"
    log_info "Backed up: ${file} -> ${backup_path}"
    printf "%s" "${backup_path}"
}
export -f backup_file

# Safely remove a file or directory
# Usage: safe_remove "/path/to/target"
safe_remove() {
    local target="${1:-}"
    if [[ -z "${target}" || "${target}" == "/" ]]; then
        die "safe_remove: invalid target"
    fi
    if [[ -e "${target}" ]]; then
        rm -rf "${target}" || die "Failed to remove: ${target}"
        log_debug "Removed: ${target}"
    fi
}
export -f safe_remove

# =============================================================================
# Version Detection
# =============================================================================

# Get ImmortalWrt version from git tag or config
# Usage: get_version
# Returns: version string (e.g. "v25.12.0" or "openwrt-24.10")
get_version() {
    local version=""

    # Try git tag first
    if git -C "${PROJECT_ROOT}" describe --tags --exact-match 2>/dev/null; then
        return 0
    fi

    # Try git tag with abbrev
    version="$(git -C "${PROJECT_ROOT}" describe --tags 2>/dev/null)" || true
    if [[ -n "${version}" ]]; then
        printf "%s" "${version}"
        return 0
    fi

    # Try config file
    version="$(get_config_value "source.tag" "")" || true
    if [[ -n "${version}" ]]; then
        printf "%s" "${version}"
        return 0
    fi

    # Fallback to branch name
    version="$(get_config_value "source.branch" "")" || true
    if [[ -n "${version}" ]]; then
        printf "%s" "${version}"
        return 0
    fi

    # Last resort
    printf "unknown"
}
export -f get_version

# Get kernel version from config
# Usage: get_kernel_version
# Returns: kernel version string (e.g. "6.12")
get_kernel_version() {
    local version
    version="$(get_config_value "kernel.version" "6.12")" || true
    printf "%s" "${version}"
}
export -f get_kernel_version

# Get build version string (version + kernel + date)
# Usage: get_build_version
# Returns: e.g. "openwrt-24.10_k6.12_20260701"
get_build_version() {
    local version
    local kernel
    local date

    version="$(get_version)"
    kernel="$(get_kernel_version)"
    date="$(date +%Y%m%d)"

    # Sanitize version for filename use
    version="${version//\//_}"
    printf "%s_k%s_%s" "${version}" "${kernel}" "${date}"
}
export -f get_build_version

# =============================================================================
# SHA256 Generation
# =============================================================================

# Generate SHA256 checksums for files in a directory or specific files
# Usage: generate_sha256 "/path/to/files" ["output_file"]
# If output_file omitted, prints to stdout
generate_sha256() {
    local path="${1:-}"
    local output_file="${2:-}"

    if [[ -z "${path}" ]]; then
        die "generate_sha256: path argument required"
    fi

    if [[ ! -e "${path}" ]]; then
        die "generate_sha256: path does not exist: ${path}"
    fi

    local sha256_cmd
    if command -v sha256sum &>/dev/null; then
        sha256_cmd="sha256sum"
    elif command -v shasum &>/dev/null; then
        sha256_cmd="shasum -a 256"
    else
        die "generate_sha256: no sha256sum or shasum command found"
    fi

    local out_name=""
    if [[ -n "${output_file}" ]]; then
        out_name="$(basename "${output_file}")"
    fi

    log_debug "Generating SHA256 checksums for: ${path}"

    if [[ -d "${path}" ]]; then
        # Find all regular files in directory, excluding the checksum file
        # itself (it would otherwise contain a hash of its own empty state).
        # Paths are written relative to the directory so that
        # `sha256sum -c sha256sums.txt` works after download.
        local find_args=()
        find_args+=("." -type f -not -name "*.sha256" -not -name "*.bak" -not -name ".*")
        if [[ -n "${out_name}" ]]; then
            find_args+=(-not -name "${out_name}")
        fi
        if [[ -n "${output_file}" ]]; then
            ( cd "${path}" && find "${find_args[@]}" -print0 | sort -z \
                | xargs -0 -r ${sha256_cmd} | sed 's|  \./|  |' ) > "${output_file}"
            log_info "SHA256 checksums written to: ${output_file}"
        else
            ( cd "${path}" && find "${find_args[@]}" -print0 | sort -z \
                | xargs -0 -r ${sha256_cmd} | sed 's|  \./|  |' )
        fi
    elif [[ -f "${path}" ]]; then
        if [[ -n "${output_file}" ]]; then
            ( cd "$(dirname "${path}")" && ${sha256_cmd} "$(basename "${path}")" ) > "${output_file}"
            log_info "SHA256 checksum written to: ${output_file}"
        else
            ${sha256_cmd} "${path}"
        fi
    else
        die "generate_sha256: unsupported path type: ${path}"
    fi
}
export -f generate_sha256

# =============================================================================
# Manifest Generation
# =============================================================================

# Escape a string for safe embedding in a JSON document
# Usage: json_escape "some \"string\""
json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf "%s" "${s}"
}
export -f json_escape

# Convert a space separated list into a JSON array literal
# Usage: to_json_array "a b c" -> ["a", "b", "c"]
to_json_array() {
    local list="${1:-}" item out=""
    for item in ${list}; do
        out+="${out:+, }\"$(json_escape "${item}")\""
    done
    printf "[%s]" "${out}"
}
export -f to_json_array

# Normalise a config value into a JSON boolean literal
# Usage: to_json_bool "true" -> true
to_json_bool() {
    if [[ "$(to_bool "${1:-false}")" == "true" ]]; then
        printf "true"
    else
        printf "false"
    fi
}
export -f to_json_bool

# Generate a JSON manifest for build artifacts
# Usage: generate_manifest "/path/to/output.json"
# Reads config and build info to produce a manifest
generate_manifest() {
    local output_file="${1:-}"

    if [[ -z "${output_file}" ]]; then
        die "generate_manifest: output file argument required"
    fi

    # Ensure output directory exists
    ensure_dir "$(dirname "${output_file}")"

    # Gather build information
    local version kernel_version build_date arch subtarget profile
    version="$(get_version)"
    kernel_version="$(get_kernel_version)"
    build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    arch="$(get_config_value "target.arch" "x86_64")"
    subtarget="$(get_config_value "target.subtarget" "generic")"
    profile="$(get_config_value "target.profile" "generic")"

    # Gather package lists (get_config_value joins YAML sequences with spaces)
    local include_packages exclude_packages
    include_packages="$(get_config_value "packages.include" "")"
    exclude_packages="$(get_config_value "packages.exclude" "")"

    # Gather feature flags
    local virtio_enabled virtiofs_enabled p9fs_enabled docker_enabled
    virtio_enabled="$(to_json_bool "$(get_config_value "features.virtio.enabled" "false")")"
    virtiofs_enabled="$(to_json_bool "$(get_config_value "features.virtiofs.enabled" "false")")"
    p9fs_enabled="$(to_json_bool "$(get_config_value "features.p9fs.enabled" "false")")"
    docker_enabled="$(to_json_bool "$(get_config_value "features.system.docker" "false")")"

    # Get git info if available
    local git_commit="unknown" git_branch="unknown"
    if git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
        git_commit="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null)" || git_commit="unknown"
        git_branch="$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null)" || git_branch="unknown"
    fi

    # Build JSON (no jq dependency - use heredoc). Every interpolated value is
    # escaped and booleans are normalised so the result is always valid JSON.
    cat > "${output_file}" <<MANIFEST_EOF
{
  "version": "$(json_escape "${version}")",
  "kernel": "$(json_escape "${kernel_version}")",
  "date": "${build_date}",
  "target": {
    "arch": "$(json_escape "${arch}")",
    "subtarget": "$(json_escape "${subtarget}")",
    "profile": "$(json_escape "${profile}")"
  },
  "features": {
    "virtio": ${virtio_enabled},
    "virtiofs": ${virtiofs_enabled},
    "p9fs": ${p9fs_enabled},
    "docker": ${docker_enabled}
  },
  "packages": {
    "include": $(to_json_array "${include_packages}"),
    "exclude": $(to_json_array "${exclude_packages}")
  },
  "source": {
    "commit": "$(json_escape "${git_commit}")",
    "branch": "$(json_escape "${git_branch}")"
  }
}
MANIFEST_EOF

    log_info "Manifest written to: ${output_file}"
}
export -f generate_manifest

# =============================================================================
# Utility Helpers
# =============================================================================

# Check if a command exists
# Usage: has_command "command_name"
has_command() {
    command -v "${1:-}" &>/dev/null
}
export -f has_command

# Require a command to be available, die if not
# Usage: require_command "yq" "Install yq: https://github.com/mikefarah/yq"
require_command() {
    local cmd="${1:-}"
    local hint="${2:-"Install ${cmd}"}"
    if ! has_command "${cmd}"; then
        die "Required command not found: ${cmd}\n  ${hint}"
    fi
}
export -f require_command

# Get number of CPU cores for parallel builds
# Usage: get_cpu_count
get_cpu_count() {
    local count
    count="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    printf "%s" "${count}"
}
export -f get_cpu_count

# Convert boolean-like string to true/false
# Usage: to_bool "yes" -> "true"
to_bool() {
    local value="${1:-false}"
    case "${value,,}" in
        true|yes|y|1|on|enabled)  printf "true"  ;;
        false|no|n|0|off|disabled) printf "false" ;;
        *) printf "false" ;;
    esac
}
export -f to_bool

# Print a separator line
# Usage: print_separator "title"
print_separator() {
    local title="${1:-}"
    if [[ -n "${title}" ]]; then
        printf "${COLOR_BOLD}--- %s %s${COLOR_RESET}\n" "${title}" "$(printf '%0.s-' $(seq 1 $((60 - ${#title}))))"
    else
        printf "${COLOR_BOLD}------------------------------------------------------------${COLOR_RESET}\n"
    fi
}
export -f print_separator

# =============================================================================
# Initialization
# =============================================================================
log_debug "utils.sh loaded (PROJECT_ROOT=${PROJECT_ROOT})"
