#!/usr/bin/env bash
#
# checkmany.sh — run checkfile.sh against several paths and summarise.
#
# Usage:  checkmany.sh PATH [PATH...]
# Exit:   0  all paths passed
#         1  one or more paths failed
#         2  usage error / checkfile.sh not usable

set -euo pipefail

# Find the directory this script lives in, so we can locate lib/ and
# checkfile.sh regardless of where the user runs us from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Absolute path to the script we delegate the real work to.
CHECKFILE="${SCRIPT_DIR}/checkfile.sh"

usage() {
    echo "Usage: $(basename "$0") PATH [PATH...]" >&2
}

# ---- argument handling -----------------------------------------------------

# Safe inside an `if` condition: set -e is disabled there.
if (( $# == 0 )); then
    usage
    exit 2
fi

# Fail fast if our dependency is missing or not executable.
[[ -f "$CHECKFILE" ]] || die "checkfile.sh not found at: $CHECKFILE"
[[ -x "$CHECKFILE" ]] || die "checkfile.sh is not executable: $CHECKFILE"

# ---- counters --------------------------------------------------------------

ok_count=0
fail_count=0

# ---- main loop -------------------------------------------------------------

log_info "checking $# path(s)"

for path in "$@"; do
    # checkfile.sh returning non-zero is expected, not an error on our side.
    rc=0
    "$CHECKFILE" "$path" >/dev/null || rc=$?

    # Translate checkfile.sh's exit code into a human-readable reason.
    case "$rc" in
        0) status="ok"   ; reason="usable"              ;;
        3) status="FAIL" ; reason="does not exist"      ;;
        4) status="FAIL" ; reason="not a regular file"  ;;
        5) status="FAIL" ; reason="empty"               ;;
        6) status="FAIL" ; reason="not readable"        ;;
        *) status="FAIL" ; reason="unexpected code $rc" ;;
    esac

    # Plain assignment always succeeds, unlike (( n++ )) when n is 0.
    if [[ "$rc" -eq 0 ]]; then
        ok_count=$(( ok_count + 1 ))
    else
        fail_count=$(( fail_count + 1 ))
    fi

    # Status lines are data -> stdout.
    echo "${status}: ${path} (${reason})"
done

# ---- summary ---------------------------------------------------------------

log_info "checked $#, passed ${ok_count}, failed ${fail_count}"

# Machine-readable summary -> stdout.
echo "checked=$#"
echo "passed=${ok_count}"
echo "failed=${fail_count}"

if (( fail_count == 0 )); then
    exit 0
else
    exit 1
fi
