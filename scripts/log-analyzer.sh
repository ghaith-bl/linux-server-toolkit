#!/usr/bin/env bash
#
# log-analyzer.sh — count rejected SSH login attempts per source IP.
#
# Usage:  log-analyzer.sh
# Exit:   0  no repeat offenders (or no attempts at all)
#         1  at least one IP hit the repeat-attempt threshold

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd grep

AUTH_LOG="/var/log/auth.log"
THRESHOLD=3

[[ -r "$AUTH_LOG" ]] || die "cannot read ${AUTH_LOG}"

log_info "scanning ${AUTH_LOG} for SSH login attempts..."

# ---- check: repeat SSH login attempts per IP --------------------------------
check_ssh_attempts() {
    local -A attempts
    local ip count problem=0

    # `< <(...)` keeps this loop in the current shell (not a subshell),
    # so changes to the `attempts` array actually survive after the loop.
    # `cmd | while read ...` would lose them all when the loop ends.
    while read -r line; do
        ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$line" || true)
        [[ -n "$ip" ]] || continue
        attempts["$ip"]=$(( ${attempts["$ip"]:-0} + 1 ))
    done < <(grep 'Connection closed by' "$AUTH_LOG" | grep '\[preauth\]')

    if (( ${#attempts[@]} == 0 )); then
        log_ok "no SSH login attempts found"
        return 0
    fi

    for ip in "${!attempts[@]}"; do
        count=${attempts[$ip]}
        if (( count >= THRESHOLD )); then
            log_warn "${ip}: ${count} attempt(s) -- repeat offender"
            problem=1
        else
            log_info "${ip}: ${count} attempt(s)"
        fi
    done

    return "$problem"
}

if check_ssh_attempts; then
    log_ok "no repeat offenders"
    exit 0
else
    log_error "at least one IP crossed the threshold (${THRESHOLD})"
    exit 1
fi
