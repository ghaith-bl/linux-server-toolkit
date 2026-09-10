#!/usr/bin/env bash
#
# sysinfo.sh — print a machine summary.
# Logs go to stderr, data goes to stdout, so this is pipeable:
#   ./sysinfo.sh > snapshot.txt

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd uname hostname df free awk nproc uptime

log_info "collecting system info"

printf 'hostname=%s\n'  "$(hostname)"
printf 'kernel=%s\n'    "$(uname -r)"
printf 'arch=%s\n'      "$(uname -m)"
printf 'uptime=%s\n'    "$(uptime -p 2>/dev/null || echo unknown)"
printf 'cpu_cores=%s\n' "$(nproc)"

# free -m prints a header line; NR==2 is the memory row.
printf 'mem_total_mb=%s\n' "$(free -m | awk 'NR==2 {print $2}')"
printf 'mem_used_mb=%s\n'  "$(free -m | awk 'NR==2 {print $3}')"

# -P forces one line per filesystem, so awk's columns stay aligned.
printf 'root_disk_use=%s\n' "$(df -Pkh / | awk 'NR==2 {print $5}')"

log_ok "done"
