#!/usr/bin/env bash
#
# firewall-apply.sh — make ufw match firewall/policy.conf on this machine.
# It replaces the firewall with exactly what the policy holds for this
# machine: no rule the policy does not have, none of its rules missing.
# Kept separate from firewall-check.sh on purpose: the check must never be
# able to change the firewall.
#
# Usage:  sudo firewall-apply.sh [-n] [-p policy]
#           -n  dry run: print the ufw commands, change nothing
#           -p  the policy file (default: firewall/policy.conf of this repo)
# Exit:   0  the firewall matches the policy (with -n: nothing was changed)
#         1  the policy has a mistake, or a ufw command failed

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/firewall-policy.sh
source "${SCRIPT_DIR}/../lib/firewall-policy.sh"

# The repo folder is one level above scripts/.
POLICY="$(cd -- "${SCRIPT_DIR}/.." && pwd)/firewall/policy.conf"
DRY_RUN=0

while getopts ":np:" opt; do
    case "$opt" in
        n) DRY_RUN=1 ;;
        p) POLICY="$OPTARG" ;;
        *) die "usage: sudo $0 [-n] [-p policy]" ;;
    esac
done

require_cmd ufw hostname
require_root

HOST="$(hostname)"

# ---- 1. Read the policy (nothing is changed here) --------------------------

log_info "reading $POLICY for $HOST..."
policy_load "$POLICY" "$HOST"

# Admin access stays over SSH (decided for v2.2): a policy that lets nothing
# in would leave a machine only its console can reach. That is a decision of
# its own, never the result of a forgotten line.
if [ "$POLICY_RULES_IN" -eq 0 ]; then
    die "the policy lets nothing in to $HOST: stopping before the firewall changes"
fi
log_ok "$HOST: $POLICY_RULES_IN rule(s) in, $POLICY_RULES_OUT out"

# ---- 2. Ask ufw to check every rule (nothing is changed here) --------------

# "ufw --dry-run" reads a rule and changes nothing. A value policy_load cannot
# judge (an address like 300.1.1.1) is refused here, while the old firewall
# is still in place.
for rule in "${POLICY_RULES[@]}"; do
    # The rule is written with quotes around its comment, the way ufw prints
    # it. A comment has no spaces (policy_load checked the tag), so the quotes
    # can go, and read splits the rest into words.
    read -r -a words <<< "${rule//\'/}"
    if ! ufw --dry-run "${words[@]}" > /dev/null; then
        die "ufw refuses this rule: ufw $rule"
    fi
done
log_ok "ufw accepts every rule"

# ---- 3. Dry run: print and stop ---------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    echo "ufw --force reset"
    echo "ufw default $POLICY_DEFAULT_INCOMING incoming"
    echo "ufw default $POLICY_DEFAULT_OUTGOING outgoing"
    echo "ufw default $POLICY_DEFAULT_ROUTED routed"
    echo "ufw logging $POLICY_LOGGING"
    for rule in "${POLICY_RULES[@]}"; do
        echo "ufw $rule"
    done
    echo "ufw --force enable"
    log_ok "dry run: nothing was changed"
    exit 0
fi

# ---- 4. Apply ---------------------------------------------------------------

# "ufw --force reset" turns the firewall off, saves the old rule files under
# /etc/ufw/ and starts from nothing. From here to the "enable" below the
# machine has no firewall: the price of a firewall that is exactly the
# policy. A connection that is already open (this SSH session) stays open.
#
# If a command fails on the way, the firewall is left off with part of the
# rules: say so, loudly.
trap 'log_error "stopped half way: the firewall may be OFF. Check: ufw status verbose"' ERR

log_info "applying..."
ufw --force reset > /dev/null
ufw default "$POLICY_DEFAULT_INCOMING" incoming > /dev/null
ufw default "$POLICY_DEFAULT_OUTGOING" outgoing > /dev/null
ufw default "$POLICY_DEFAULT_ROUTED" routed > /dev/null
ufw logging "$POLICY_LOGGING" > /dev/null
for rule in "${POLICY_RULES[@]}"; do
    read -r -a words <<< "${rule//\'/}"
    ufw "${words[@]}" > /dev/null
done
ufw --force enable > /dev/null

trap - ERR

log_ok "applied: ${#POLICY_RULES[@]} rule(s), firewall enabled"
ufw status verbose
