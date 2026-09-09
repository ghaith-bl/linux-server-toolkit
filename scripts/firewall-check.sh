#!/usr/bin/env bash
#
# firewall-check.sh — report whether ufw is active and what it allows.
# Kept separate from hostaudit.sh on purpose: this is the only script in
# the toolkit that genuinely needs root, so only it should ever need sudo.
#
# Usage:  sudo firewall-check.sh
# Exit:   0  ufw is active
#         1  ufw is inactive

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd ufw
require_root

log_info "checking firewall status..."

if ufw status | grep -q '^Status: active'; then
    log_ok "ufw is active"
    ufw status verbose
    exit 0
else
    log_warn "ufw is not active"
    exit 1
fi
