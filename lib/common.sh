#!/usr/bin/env bash
# lib/common.sh — shared helpers for linux-server-toolkit
#
# This file is SOURCED, not executed. It intentionally does NOT set shell
# options (set -e / -u / -o pipefail) — that is each script's own decision.

# ---- re-source guard -------------------------------------------------------
[[ -n "${COMMON_SH_LOADED:-}" ]] && return 0
COMMON_SH_LOADED=1

# ---- colors ----------------------------------------------------------------
# Logs go to stderr (fd 2), so we test whether *that* is a terminal.
if [[ -t 2 ]]; then
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[0;33m'
    C_GREEN=$'\033[0;32m'
    C_BLUE=$'\033[0;34m'
    C_RESET=$'\033[0m'
else
    C_RED='' C_YELLOW='' C_GREEN='' C_BLUE='' C_RESET=''
fi

# ---- logging ---------------------------------------------------------------
# Everything writes to stderr so stdout stays clean for real output.

_log() {
    local color="$1" level="$2"
    shift 2
    printf '%s[%s] %-5s %s%s\n' \
        "$color" "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*" "$C_RESET" >&2
}

log_info()  { _log "$C_BLUE"   "INFO"  "$@"; }
log_ok()    { _log "$C_GREEN"  "OK"    "$@"; }
log_warn()  { _log "$C_YELLOW" "WARN"  "$@"; }
log_error() { _log "$C_RED"    "ERROR" "$@"; }

die() {
    log_error "$@"
    exit 1
}

# ---- guards ----------------------------------------------------------------

require_cmd() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "missing required command(s): ${missing[*]}"
}

require_root() {
    (( EUID == 0 )) || die "must be run as root (try: sudo $0)"
}
