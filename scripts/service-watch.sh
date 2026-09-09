#!/usr/bin/env bash
#
# service-watch.sh — check a list of services and restart any that stopped.
# Tracks restart attempts across runs so a service stuck in a real crash
# loop gets flagged instead of restarted silently forever.
#
# Usage:  sudo service-watch.sh
# Exit:   0  every service is running (restarted or already up)
#         1  at least one service could not be restarted, or hit the
#            crash-loop limit

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd systemctl
require_root

SERVICES=(ssh cron systemd-resolved)

# How many consecutive failed restarts before we stop trying and escalate
# instead. Each timer run is one hour apart, so 3 means "failing for 3
# hours straight" before we give up and just report it.
MAX_RESTARTS=3

# Where we remember restart counts BETWEEN runs. /var/lib is the standard
# place for a system service's own persistent state (this script always
# runs as root, via require_root above). We do NOT put this under the
# repo (~/linux-server-toolkit) -- writing root-owned files into a
# normal user's home directory is exactly the "sudo creates root-owned
# files" trap documented in NOTES.md.
STATE_DIR="/var/lib/linux-server-toolkit/service-watch"
mkdir -p "$STATE_DIR"

# ---- read/write the restart counter for one service -------------------------
# A missing state file means "0 failed attempts so far" -- this is the
# normal case for a healthy service, not an error.
get_restart_count() {
    local svc="$1" file="${STATE_DIR}/${svc}.count"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo 0
    fi
}

set_restart_count() {
    local svc="$1" count="$2"
    echo "$count" > "${STATE_DIR}/${svc}.count"
}

# ---- check + restart a single service ---------------------------------------
watch_service() {
    local svc="$1"

    if systemctl is-active --quiet "$svc"; then
        log_ok "${svc} is running"
        # Service is healthy -- clear any past failure count so a single
        # old crash loop doesn't keep counting against it forever.
        set_restart_count "$svc" 0
        return 0
    fi

    local count
    count="$(get_restart_count "$svc")"

    if (( count >= MAX_RESTARTS )); then
        log_error "${svc} has failed to stay up for ${MAX_RESTARTS} consecutive check(s) -- possible crash loop, not attempting another restart"
        return 1
    fi

    log_warn "${svc} is not running -- attempting restart"
    systemctl restart "$svc" || true

    if systemctl is-active --quiet "$svc"; then
        log_ok "${svc} restarted successfully"
        set_restart_count "$svc" 0
        return 0
    else
        count=$(( count + 1 ))
        set_restart_count "$svc" "$count"
        log_error "${svc} failed to restart (attempt ${count}/${MAX_RESTARTS})"
        return 1
    fi
}

log_info "watching ${#SERVICES[@]} service(s)..."

problems=0
for svc in "${SERVICES[@]}"; do
    watch_service "$svc" || problems=$(( problems + 1 ))
done

if (( problems == 0 )); then
    log_ok "all services are running"
    exit 0
else
    log_error "${problems} service(s) could not be restarted"
    exit 1
fi
