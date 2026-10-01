#!/usr/bin/env bash
#
# backup-push.sh -- sends new local backups from toolkit-lab to backup-lab.
#
# Installed as /usr/local/sbin/backup-push (root:root, 755) and run every hour
# by backup-push.service (backup-push.timer), as the account backup-push.
#
# backup.sh makes each backup as a pair in /var/backups/linux-server-toolkit:
# <name>.tar.gz and <name>.tar.gz.sha256. This script checks each archive
# against its checksum and sends the pairs not sent yet with rsync over SSH.
# On backup-lab, the push key can only write new files into incoming; a root
# mover there checks the pair again and moves it into the vault.
#
# After a send that worked, one empty marker file per archive records it, so
# a pair is sent once. If backup-lab is off, rsync fails, nothing is marked,
# and the next run sends the same pairs again.
#
# Exit:  0      every new pair sent, or nothing new to send
#        1      a pair was skipped (see the SKIPPED lines)
#        other  rsync failed, with rsync's own exit code; nothing marked
#
# Two settings come from the environment (the tests use them; the service
# sets neither by hand):
#   STATE_DIRECTORY  where the markers live. systemd sets it from
#                    StateDirectory=; without it: /var/lib/backup-push
#   RSYNC_RSH        the remote shell rsync uses. Without it: ssh, which
#                    reads /home/backup-push/.ssh/config (Host backup-lab)

# Stop on any error (-e), on an unset variable (-u), and when any command
# inside a pipe fails (pipefail).
set -euo pipefail

# --- Settings ---

SOURCE_DIR="/var/backups/linux-server-toolkit"           # backup.sh writes here; the backup-push group may read it
STATE_DIR="${STATE_DIRECTORY:-/var/lib/backup-push}"     # systemd sets STATE_DIRECTORY from StateDirectory=
SENT_DIR="${STATE_DIR}/sent"                             # one empty marker file per archive already sent
DESTINATION="backup-lab:"                                # the Host in the ssh config; no path: rrsync writes into incoming
NAME_RE='^backup-[A-Za-z0-9._-]+\.tar\.gz$'              # the names backup.sh makes (the mover accepts the same)

# stop MESSAGE: print the message and end with exit code 1.
stop() {
    echo "STOP: $1" >&2
    exit 1
}

# skip NAME REASON: report a pair that is not sent, and remember the failure.
skip() {
    printf 'SKIPPED: %q: %s\n' "$1" "$2"
    failed=1
}

# --- Checks ---

# Never as root: root could read every file, backup-push reads only the backups.
[ "$(id -u)" != "0" ] || stop "do not run this as root: it runs as backup-push"
command -v rsync > /dev/null || stop "rsync not found"
[ -d "$SOURCE_DIR" ] || stop "folder not found: $SOURCE_DIR"
[ -r "$SOURCE_DIR" ] || stop "cannot read $SOURCE_DIR"
[ -x "$SOURCE_DIR" ] || stop "cannot enter $SOURCE_DIR"
[ -d "$STATE_DIR" ] || stop "state folder not found: $STATE_DIR (systemd makes it: StateDirectory=)"
mkdir -p "$SENT_DIR"                                     # the first run makes the markers folder
[ -w "$SENT_DIR" ] || stop "cannot write markers into $SENT_DIR"

# --- Find the pairs not sent yet ---

failed=0      # 1 when a pair was skipped
to_send=()    # the files for rsync, each archive followed by its checksum
names=()      # the archive names, for the markers after the send

# A pattern with no match gives nothing, not the pattern itself.
shopt -s nullglob

# backup.sh moves the checksum in place after its archive, so a checksum
# file means its archive is complete.
for sum_path in "$SOURCE_DIR"/*.tar.gz.sha256; do
    sum_file=$(basename "$sum_path")                     # backup-...tar.gz.sha256
    name="${sum_file%.sha256}"                           # backup-...tar.gz
    archive="$SOURCE_DIR/$name"                          # the archive next to it

    # Sent before: nothing to do.
    if [ -e "$SENT_DIR/$name" ]; then
        continue
    fi

    # Only the names backup.sh makes.
    if ! [[ "$name" =~ $NAME_RE ]]; then
        skip "$sum_file" "unexpected name"
        continue
    fi

    # Both must be plain files (-L first: -f follows symlinks).
    if [ -L "$archive" ] || [ ! -f "$archive" ] || [ -L "$sum_path" ] || [ ! -f "$sum_path" ]; then
        skip "$name" "the archive is missing, or a file of the pair is not a regular file"
        continue
    fi

    # The checksum file: one line "<sha256>  <name>".
    if [ "$(wc -l < "$sum_path")" != "1" ]; then
        skip "$name" "the checksum file is not one line"
        continue
    fi
    line=$(cat "$sum_path")                              # the line, without its newline
    expected="${line%%  *}"                              # before the two spaces
    listed="${line#*  }"                                 # after the two spaces
    if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$listed" != "$name" ]; then
        skip "$name" "the checksum file is not '<sha256>  <name>'"
        continue
    fi

    # The archive must still match: never send a copy that changed.
    actual=$(sha256sum < "$archive" | cut -d ' ' -f 1)
    if [ "$actual" != "$expected" ]; then
        skip "$name" "checksum mismatch: the local copy changed after backup.sh made it"
        continue
    fi

    to_send+=("$archive" "$sum_path")
    names+=("$name")
done

# Nothing new: do not even connect.
if [ "${#names[@]}" -eq 0 ]; then
    echo "nothing new to send"
    exit "$failed"
fi

# --- Send ---

echo "sending ${#names[@]} pair(s)"
# No -a, -t or -p: backup-lab sets the owner, the mode and the time itself.
# --timeout: give up when no data moves for 60 seconds (ssh's ConnectTimeout
# covers a machine that is off).
rc=0
rsync --timeout=60 "${to_send[@]}" "$DESTINATION" || rc=$?
if [ "$rc" != "0" ]; then
    echo "STOP: rsync failed (exit $rc): nothing marked as sent, the next run sends again" >&2
    exit "$rc"
fi

# --- Mark what was sent ---

for name in "${names[@]}"; do
    touch "$SENT_DIR/$name"
    printf 'SENT: %q\n' "$name"
done

exit "$failed"
