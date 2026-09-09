#!/usr/bin/env bash
#
# service-watch.sh — check a list of services and restart any that stopped.
#
# Usage:  sudo service-watch.sh
# Exit:   0  every service is running (restarted or already up)
#         1  at least one service could not be restarted

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd systemctl
require_root

SERVICES=(ssh cron systemd-resolved)

# ---- check + restart a single service ---------------------------------------
watch_service() {
    local svc="$1"

    if systemctl is-active --quiet "$svc"; then
        log_ok "${svc} is running"
        return 0
    fi

    log_warn "${svc} is not running -- attempting restart"
    systemctl restart "$svc" || true

    if systemctl is-active --quiet "$svc"; then
        log_ok "${svc} restarted successfully"
        return 0
    else
        log_error "${svc} failed to restart"
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
