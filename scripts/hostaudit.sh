#!/usr/bin/env bash
#
# hostaudit.sh — quick health & security snapshot for this server.
#
# Usage:  hostaudit.sh   (no arguments)
# Exit:   0  every check passed
#         1  one or more checks reported a problem, or a required
#            command was missing

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd systemctl ss aa-status ps df awk

log_info "starting host audit..."

# ---- check: failed systemd services + auditd status -------------------------
check_failed_services() {
    local failed_count
    local auditd_rc=0
    local problem=0

    failed_count=$(systemctl --failed --no-legend | wc -l)

    if (( failed_count == 0 )); then
        log_ok "no failed services"
    else
        log_warn "found ${failed_count} failed service(s)"
        systemctl --failed --no-legend
        problem=1
    fi

    systemctl is-active --quiet auditd || auditd_rc=$?
    if (( auditd_rc == 0 )); then
        log_ok "auditd is active"
    else
        log_warn "auditd is not active"
        problem=1
    fi

    return "$problem"
}

# ---- check: zombie processes ------------------------------------------------
check_zombies() {
    local zombie_count

    zombie_count=$(ps -eo stat | grep -c '^Z' || true)

    if (( zombie_count == 0 )); then
        log_ok "no zombie processes"
        return 0
    else
        log_warn "found ${zombie_count} zombie process(es)"
        ps -eo pid,ppid,stat,comm | awk '$3 ~ /^Z/'
        return 1
    fi
}

# ---- check: listening network ports (informational only) --------------------
check_ports() {
    local port_count

    port_count=$(ss -tnulp --no-header | wc -l)

    log_info "found ${port_count} listening port(s):"
    ss -tnulp --no-header
    return 0
}

# ---- check: AppArmor status -------------------------------------------------
check_apparmor() {
    local rc=0
    aa-status --enabled || rc=$?

    case "$rc" in
        0) log_ok "AppArmor is enabled with policy loaded"; return 0 ;;
        1) log_warn "AppArmor is not enabled"; return 1 ;;
        4) log_warn "need root to read AppArmor status (try: sudo $0)"; return 1 ;;
        *) log_warn "AppArmor check returned unexpected code: $rc"; return 1 ;;
    esac
}

# ---- check: disk usage on / -------------------------------------------------
check_disk_usage() {
    local usage_pct

    usage_pct=$(df -h --output=pcent / | tail -n +2 | tr -d '% ')

    if (( usage_pct >= 80 )); then
        log_warn "disk usage on / is at ${usage_pct}%"
        return 1
    else
        log_ok "disk usage on / is at ${usage_pct}%"
        return 0
    fi
}

# ---- run all checks and track the overall result ----------------------------
problems=0

check_failed_services || problems=$(( problems + 1 ))
check_zombies         || problems=$(( problems + 1 ))
check_ports
check_apparmor        || problems=$(( problems + 1 ))
check_disk_usage      || problems=$(( problems + 1 ))

if (( problems == 0 )); then
    log_ok "all checks passed"
    exit 0
else
    log_error "${problems} check(s) reported a problem"
    exit 1
fi
