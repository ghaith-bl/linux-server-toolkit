#!/usr/bin/env bash
#
# service-watch.sh — check a list of services and restart any that stopped.
# Tracks restart attempts across runs so a service stuck in a real crash
# loop gets flagged instead of restarted silently forever.
#
# A service that is inactive is not automatically broken: if a socket (or
# path/timer) unit is standing in for it, being idle is the intended state.
# Ubuntu 22.10+ ships ssh this way, so this script asks systemd for the
# trigger link before deciding anything.
#
# Usage:  sudo service-watch.sh
# Exit:   0  every service is running, idle-by-design, or restarted
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

# ---- socket/path/timer activation -------------------------------------------
# TriggeredBy= is systemd's reverse link: the units that start this service
# on demand. It is empty for an ordinary service like cron.
get_triggers() {
    local svc="$1"
    systemctl show "$svc" -p TriggeredBy --value
}

# Print the name of the first ACTIVE trigger and return 0; print nothing and
# return 1 when the service has no triggers at all, or has some but none are
# active. Those two cases are deliberately not distinguished here -- the
# caller separates them by counting the triggers itself.
# The NAME matters, not just yes/no: if the trigger is the thing that died,
# it is the trigger that has to be restarted, not the service.
active_trigger() {
    local svc="$1" t
    local -a triggers=()
    # `read` returns non-zero on input without a trailing newline, and an
    # empty value produces no fields at all -- guard it under set -e.
    read -ra triggers <<< "$(get_triggers "$svc")" || true

    for t in "${triggers[@]}"; do
        if systemctl is-active --quiet "$t"; then
            echo "$t"
            return 0
        fi
    done
    return 1
}

# ---- check + restart a single service ---------------------------------------
watch_service() {
    local svc="$1"

    # Case 1: the service itself is up. Nothing else matters.
    if systemctl is-active --quiet "$svc"; then
        log_ok "${svc} is running"
        # Service is healthy -- clear any past failure count so a single
        # old crash loop doesn't keep counting against it forever.
        set_restart_count "$svc" 0
        return 0
    fi

    # The service is down. That is only a fault if nothing is standing in
    # for it, so read the trigger list before judging.
    local -a triggers=()
    read -ra triggers <<< "$(get_triggers "$svc")" || true

    # Case 3: a trigger is active, so the service is idle by design, not
    # broken. Reset the counter -- it counts CONSECUTIVE failures, and a
    # healthy check breaks the streak just as a successful restart does.
    local trigger=""
    if trigger="$(active_trigger "$svc")"; then
        log_ok "${svc} is inactive but ${trigger} is listening -- idle by design"
        set_restart_count "$svc" 0
        return 0
    fi

    # Cases 2 and 4 are both real faults. They differ only in WHICH unit
    # gets restarted: the service itself, or the trigger that should have
    # been listening for it. Restarting a service whose socket is down
    # would not restore the listener.
    local target="$svc"
    if (( ${#triggers[@]} > 0 )); then
        target="${triggers[0]}"
    fi

    # The counter is always keyed on the SERVICE name, even when the target
    # is a trigger: SERVICES is this script's unit of accounting, and keying
    # on the trigger would leave orphan state files nothing ever reads.
    local count
    count="$(get_restart_count "$svc")"

    if (( count >= MAX_RESTARTS )); then
        log_error "${svc} has failed to stay up for ${MAX_RESTARTS} consecutive check(s) -- possible crash loop, not attempting another restart"
        return 1
    fi

    log_warn "${svc} is not running -- attempting restart of ${target}"
    systemctl restart "$target" || true

    # Judge by the service where there is no trigger, and by the trigger
    # where there is one: a socket-activated service stays inactive after
    # its socket comes back, and that is success, not failure.
    local verify="$target"
    if systemctl is-active --quiet "$verify"; then
        log_ok "${target} restarted successfully"
        set_restart_count "$svc" 0
        return 0
    else
        count=$(( count + 1 ))
        set_restart_count "$svc" "$count"
        log_error "${target} failed to restart (attempt ${count}/${MAX_RESTARTS})"
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
