#!/usr/bin/env bash
#
# firewall-check.sh — report whether ufw is active, starts at boot, and holds
# exactly the rules of firewall/policy.conf. It only reads: it never changes
# the firewall (firewall-apply.sh does that).
# Kept separate from hostaudit.sh on purpose: ufw needs root, so the checks
# in hostaudit.sh stay runnable as a normal user.
#
# Usage:  sudo firewall-check.sh [-p policy]
#           -p  the policy file (default: firewall/policy.conf of this repo)
# Exit:   0  ufw is active, enabled at boot, and matches the policy
#         1  ufw is inactive, or something differs from the policy

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/firewall-policy.sh
source "${SCRIPT_DIR}/../lib/firewall-policy.sh"

# The repo folder is one level above scripts/.
POLICY="$(cd -- "${SCRIPT_DIR}/.." && pwd)/firewall/policy.conf"

while getopts ":p:" opt; do
    case "$opt" in
        p) POLICY="$OPTARG" ;;
        *) die "usage: sudo $0 [-p policy]" ;;
    esac
done

require_cmd ufw systemctl hostname
require_root

# ufw translates its messages; the checks below read the English text.
export LC_ALL=C

HOST="$(hostname)"

# How many things differ from the policy.
problems=0

# problem MESSAGE: report one difference and count it.
problem() {
    log_warn "$1"
    problems=$(( problems + 1 ))
}

# live_default NAME: print the word ufw shows in front of "(NAME)" on its
# "Default:" line, for example "deny" for NAME=incoming.
live_default() {
    local name="$1"
    # grep finds nothing when the line is not there: "|| true" keeps going,
    # and the empty answer then fails the comparison.
    grep -oE "[a-z]+ \($name\)" <<< "$default_line" | cut -d ' ' -f 1 || true
}

# ---- 1. Is ufw active? -----------------------------------------------------

log_info "checking firewall status..."

status="$(ufw status verbose)"

if ! grep -q '^Status: active' <<< "$status"; then
    log_warn "ufw is not active"
    exit 1
fi
log_ok "ufw is active"
echo "$status"

# ---- 2. Does it start at boot? ---------------------------------------------

# is-enabled exits 1 for "disabled": "|| true" keeps its answer.
boot_state="$(systemctl is-enabled ufw.service 2> /dev/null || true)"
if [ "$boot_state" = "enabled" ]; then
    log_ok "ufw.service is enabled at boot"
else
    problem "ufw.service is '$boot_state' at boot, expected 'enabled'"
fi

# ---- 3. The policy ----------------------------------------------------------

log_info "comparing with $POLICY for $HOST..."
policy_load "$POLICY" "$HOST"

# The defaults: "Default: deny (incoming), deny (outgoing), disabled (routed)"
default_line="$(grep '^Default:' <<< "$status" || true)"

live="$(live_default incoming)"
if [ "$live" = "$POLICY_DEFAULT_INCOMING" ]; then
    log_ok "default incoming: $live"
else
    problem "default incoming is '$live', the policy says '$POLICY_DEFAULT_INCOMING'"
fi

live="$(live_default outgoing)"
if [ "$live" = "$POLICY_DEFAULT_OUTGOING" ]; then
    log_ok "default outgoing: $live"
else
    problem "default outgoing is '$live', the policy says '$POLICY_DEFAULT_OUTGOING'"
fi

# ufw prints "disabled" for routed when the machine forwards no packets at
# all (net.ipv4.ip_forward is 0): nothing is routed, so a policy of deny or
# reject holds.
live="$(live_default routed)"
if [ "$live" = "$POLICY_DEFAULT_ROUTED" ]; then
    log_ok "default routed: $live"
elif [ "$live" = "disabled" ] && [ "$POLICY_DEFAULT_ROUTED" != "allow" ]; then
    log_ok "default routed: disabled (this machine forwards nothing)"
else
    problem "default routed is '$live', the policy says '$POLICY_DEFAULT_ROUTED'"
fi

# The logging level: "Logging: on (low)" or "Logging: off".
logging_line="$(grep '^Logging:' <<< "$status" || true)"
if [ "$logging_line" = "Logging: off" ]; then
    live="off"
else
    live="$(grep -oE '\([a-z]+\)' <<< "$logging_line" | tr -d '()' || true)"
fi
if [ "$live" = "$POLICY_LOGGING" ]; then
    log_ok "logging: $live"
else
    problem "logging is '$live', the policy says '$POLICY_LOGGING'"
fi

# The rules. "ufw show added" prints every rule as the command that makes it,
# one line "ufw ..." per rule; a rule that exists for IPv4 and IPv6 is printed
# once. policy_load wrote the policy's rules in that same spelling, so the two
# lists are compared as text, whole lines.
live_rules="$(ufw show added | grep '^ufw ' | sed 's/^ufw //' || true)"
policy_rules="$(printf '%s\n' "${POLICY_RULES[@]}")"

# In the policy, not in the firewall.
while read -r rule; do
    # -x: the whole line, -F: plain text, --: the rule is not an option.
    if ! grep -qxF -- "$rule" <<< "$live_rules"; then
        problem "missing rule: ufw $rule"
    fi
done <<< "$policy_rules"

# In the firewall, not in the policy.
while read -r rule; do
    if [ -z "$rule" ]; then
        continue
    fi
    if ! grep -qxF -- "$rule" <<< "$policy_rules"; then
        problem "rule not in the policy: ufw $rule"
    fi
done <<< "$live_rules"

# ---- Result -----------------------------------------------------------------

if [ "$problems" -eq 0 ]; then
    log_ok "the firewall matches the policy (${#POLICY_RULES[@]} rules)"
    exit 0
fi
log_warn "$problems difference(s) from the policy"
exit 1
