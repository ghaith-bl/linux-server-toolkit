#!/usr/bin/env bash
#
# checkfile.sh — validate that a path is a usable regular file.
# Each failure mode gets its own exit code so callers can branch on it.

set -euo pipefail                       # strict mode: this script's own choice

# resolve our own directory, then load the shared library
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {                               # help text -> stderr, never stdout
    cat >&2 <<'USAGE'
Usage: checkfile.sh PATH

Exit codes:
  0  file is present, regular, non-empty and readable
  2  wrong number of arguments
  3  path does not exist
  4  exists but is not a regular file
  5  regular file but empty
  6  not readable by the current user
USAGE
}

# ---- argument handling -----------------------------------------------------

(( $# == 1 )) || { usage; exit 2; }     # exactly one argument required

target="$1"                             # name it; "$1" alone is unreadable later

# ---- guard chain: general -> specific --------------------------------------
# Order matters. Each check assumes the previous one passed, so the error
# message that fires is always the most precise one available.

[[ -e "$target" ]] || {                 # does anything exist at this path?
    log_error "path does not exist: $target"
    exit 3
}

[[ -f "$target" ]] || {                 # is it a regular file (not a dir)?
    log_error "not a regular file: $target"
    exit 4
}

[[ -s "$target" ]] || {                 # size > 0 — the empty-file trap
    log_error "file is empty: $target"
    exit 5
}

[[ -r "$target" ]] || {                 # can *this* user read it?
    log_error "not readable: $target"
    exit 6
}

# ---- output ----------------------------------------------------------------

log_ok "file is usable: $target"        # log -> stderr

printf 'path=%s\n'     "$target"                    # data -> stdout
printf 'size_bytes=%s\n' "$(stat -c '%s' "$target")"  # %s = size in bytes
printf 'perms=%s\n'      "$(stat -c '%a' "$target")"  # %a = octal mode, e.g. 644
printf 'owner=%s\n'      "$(stat -c '%U' "$target")"  # %U = owner username
