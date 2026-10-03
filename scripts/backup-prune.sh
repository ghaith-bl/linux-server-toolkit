#!/usr/bin/env bash
#
# backup-prune.sh -- removes old local backups that were already sent.
#
# backup.sh makes each backup as a pair in the backup folder: <name>.tar.gz
# and <name>.tar.gz.sha256. backup-push.sh sends the pairs to backup-lab and
# leaves one empty marker file per archive it sent. This script removes a
# pair only when all three are true:
#   1. its marker exists (it was sent),
#   2. it is older than KEEP_DAYS days,
#   3. it is not one of the newest KEEP_MIN backups.
# A backup with no marker is never removed, however old it is.
#
# Run as the owner of the backups (ghaith), by backup-prune.service
# (backup-prune.timer, daily at 00:30, after the 00:15 send).
#
# Usage:  backup-prune.sh -d <backup_dir> -m <markers_dir> [-n]
#   -n    dry run: print what would be removed, remove nothing
# Exit:   0  done (also when there was nothing to remove)
#         1  a required step failed

# Stop on any error (-e), on an unset variable (-u), and when any command
# inside a pipe fails (pipefail).
set -euo pipefail

# Find the directory this script lives in, so we can locate lib/.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# --- Settings ---

KEEP_DAYS=15                                  # a sent backup older than this may go
KEEP_MIN=7                                    # the newest 7 always stay, whatever their age
NAME_RE='^backup-[A-Za-z0-9._-]+\.tar\.gz$'   # the names backup.sh makes; nothing else is touched

# --- Defaults ---

dir=""        # the backup folder (-d)
markers=""    # the folder of "sent" markers (-m)
dry_run=false # true with -n

usage() {
    echo "Usage: $0 -d <backup_dir> -m <markers_dir> [-n]" >&2
    exit 1
}

# --- Parse the command-line flags ---

while getopts ":d:m:n" opt; do
    case "$opt" in
        d) dir="$OPTARG" ;;
        m) markers="$OPTARG" ;;
        n) dry_run=true ;;
        \?)
            log_error "Unknown option: -$OPTARG"
            usage
            ;;
        :)
            log_error "Option -$OPTARG requires a value"
            usage
            ;;
    esac
done

if [[ -z "$dir" ]]; then
    log_error "Missing required -d <backup_dir>"
    usage
fi

if [[ -z "$markers" ]]; then
    log_error "Missing required -m <markers_dir>"
    usage
fi

# --- Checks ---

require_cmd find sort date rm

[[ -d "$dir" ]] || die "Backup folder does not exist: $dir"
[[ -w "$dir" ]] || die "Cannot remove files from $dir (run as its owner)"
# Without the markers, every backup would look "not sent" and nothing would
# ever be removed: stop instead, so the failed unit shows it.
[[ -d "$markers" ]] || die "Markers folder does not exist: $markers"
[[ -r "$markers" ]] || die "Cannot read the markers folder: $markers"

# --- One backup at a time, newest first ---

# The oldest time a backup may have and still stay for its age.
limit=$(( $(date +%s) - KEEP_DAYS * 86400 ))

count=0      # backups seen so far
removed=0    # pairs removed (or, with -n, that would be removed)
unsent=0     # old backups kept because they were not sent

# find prints "<time made, in seconds> <name>" per archive (%T@ is the
# modification time), and sort -rn puts the newest first.
while read -r made name; do
    # Only the names backup.sh makes.
    if ! [[ "$name" =~ $NAME_RE ]]; then
        continue
    fi

    count=$(( count + 1 ))
    made="${made%.*}"                         # whole seconds: drop the fraction

    # The newest KEEP_MIN stay, whatever their age.
    if [[ "$count" -le "$KEEP_MIN" ]]; then
        continue
    fi

    # Not older than KEEP_DAYS: stays.
    if [[ "$made" -ge "$limit" ]]; then
        continue
    fi

    # Old, but no marker: it was never sent, so it stays.
    if [[ ! -e "$markers/$name" ]]; then
        printf 'KEPT: %q is old but was not sent\n' "$name"
        unsent=$(( unsent + 1 ))
        continue
    fi

    # Old and sent: the pair goes.
    removed=$(( removed + 1 ))
    if [[ "$dry_run" == true ]]; then
        printf 'WOULD REMOVE: %q\n' "$name"
        continue
    fi
    # The checksum first: if this run is cut between the two, the archive is
    # still seen, and removed, by the next run.
    rm -f -- "$dir/$name.sha256" "$dir/$name"
    printf 'REMOVED: %q\n' "$name"
done < <(find "$dir" -maxdepth 1 -type f -name 'backup-*.tar.gz' -printf '%T@ %f\n' | sort -rn)

if [[ "$dry_run" == true ]]; then
    printf 'dry run: %d backup(s) checked, %d would be removed, %d old but not sent\n' "$count" "$removed" "$unsent"
else
    printf '%d backup(s) checked, %d removed, %d old but not sent\n' "$count" "$removed" "$unsent"
fi
