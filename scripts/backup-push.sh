#!/usr/bin/env bash
#
# backup-push.sh -- encrypts new local backups on toolkit-lab and sends them
# to backup-lab.
#
# Installed as /usr/local/sbin/backup-push (root:root, 755) and run every hour
# by backup-push.service (backup-push.timer), as the account backup-push.
#
# backup.sh makes each backup as a pair in /var/backups/linux-server-toolkit:
# <name>.tar.gz and <name>.tar.gz.sha256. For each pair not sent yet, this
# script:
#   1. checks the archive against its checksum, and reads it to its end;
#   2. encrypts it with age (v2.2), to the public key in
#      /etc/linux-server-toolkit/backup-recipients.txt. The private key is
#      on neither machine: backup-lab stores backups it cannot open. The
#      local copy stays as it is, not encrypted;
#   3. sends the encrypted copy, <name>.tar.gz.age, and a checksum file made
#      for it, with rsync over SSH.
# On backup-lab, the push key can only write new files into incoming; a root
# mover there checks the pair again and moves it into the vault.
#
# An encrypted copy waits in the state folder (outgoing) until it is sent.
# If backup-lab is off, rsync fails, nothing is marked, and the next run
# sends the same encrypted copy again. It is not encrypted a second time:
# age gives a different result at each run, and the vault refuses a second
# file with the same name and another content.
#
# After a send that worked, one empty marker file per archive records it, so
# a pair is sent once.
#
# Exit:  0      every new pair sent, or nothing new to send
#        1      a pair was skipped (see the SKIPPED lines)
#        other  rsync failed, with rsync's own exit code; nothing marked
#
# Two settings come from the environment (the tests use them; the service
# sets neither by hand):
#   STATE_DIRECTORY  where the markers and the encrypted copies live. systemd
#                    sets it from StateDirectory=; without it:
#                    /var/lib/backup-push
#   RSYNC_RSH        the remote shell rsync uses. Without it: ssh, which
#                    reads /home/backup-push/.ssh/config (Host backup-lab)

# Stop on any error (-e), on an unset variable (-u), and when any command
# inside a pipe fails (pipefail).
set -euo pipefail

# --- Settings ---

SOURCE_DIR="/var/backups/linux-server-toolkit"           # backup.sh writes here; the backup-push group may read it
STATE_DIR="${STATE_DIRECTORY:-/var/lib/backup-push}"     # systemd sets STATE_DIRECTORY from StateDirectory=
SENT_DIR="${STATE_DIR}/sent"                             # one empty marker file per archive already sent
OUT_DIR="${STATE_DIR}/outgoing"                          # the encrypted copies wait here until they are sent
RECIPIENTS="/etc/linux-server-toolkit/backup-recipients.txt"   # the public key age encrypts to (root's file)
DESTINATION="backup-lab:"                                # the Host in the ssh config; no path: rrsync writes into incoming
NAME_RE='^backup-[A-Za-z0-9._-]+\.tar\.gz$'              # the names backup.sh makes (the mover accepts them with .age added)

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
command -v age > /dev/null || stop "age not found"
command -v tar > /dev/null || stop "tar not found"
[ -d "$SOURCE_DIR" ] || stop "folder not found: $SOURCE_DIR"
[ -r "$SOURCE_DIR" ] || stop "cannot read $SOURCE_DIR"
[ -x "$SOURCE_DIR" ] || stop "cannot enter $SOURCE_DIR"
[ -d "$STATE_DIR" ] || stop "state folder not found: $STATE_DIR (systemd makes it: StateDirectory=)"
mkdir -p "$SENT_DIR" "$OUT_DIR"                          # the first run makes the two folders
[ -w "$SENT_DIR" ] || stop "cannot write markers into $SENT_DIR"
[ -w "$OUT_DIR" ] || stop "cannot write encrypted copies into $OUT_DIR"

# The public key: the file must be there (-s: not empty), and this account
# must not be able to change it. Whoever can change it decides who can open
# the backups.
[ -s "$RECIPIENTS" ] || stop "public key file not found, or empty: $RECIPIENTS"
[ -r "$RECIPIENTS" ] || stop "cannot read $RECIPIENTS"
[ ! -w "$RECIPIENTS" ] || stop "this account can change $RECIPIENTS: it must be root's file"
# age must accept the key: encrypt nothing, to nowhere.
age -R "$RECIPIENTS" < /dev/null > /dev/null || stop "age cannot use the public key in $RECIPIENTS"

# --- Find the pairs not sent yet ---

failed=0      # 1 when a pair was skipped
to_send=()    # the files for rsync, each encrypted copy followed by its checksum
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

    out="$OUT_DIR/$name.age"                             # the encrypted copy
    out_sum="$out.sha256"                                # and its checksum file

    # Its checksum file is written last, so it means the encrypted copy is
    # complete: one left by an earlier run that could not send is sent as it
    # is. Without it, the archive is encrypted now.
    if [ ! -f "$out_sum" ]; then
        # backup-lab cannot open an encrypted archive, so the archive is read
        # to its end here, before it is encrypted. tar -t lists the files
        # inside; to list them it must read and decompress the whole archive,
        # so a damaged or cut one makes it fail. The list itself is not
        # needed (> /dev/null).
        if ! tar -tzf "$archive" > /dev/null; then
            skip "$name" "the archive cannot be read to its end"
            continue
        fi

        # -R: encrypt to the public key in that file. -o: write the encrypted
        # copy there (a cut one from an earlier run is replaced).
        if ! age -R "$RECIPIENTS" -o "$out" "$archive"; then
            skip "$name" "age could not encrypt it"
            continue
        fi

        # The checksum of the encrypted copy, as one line "<sha256>  <name>":
        # written under another name first, then moved in place.
        out_hash=$(sha256sum < "$out" | cut -d ' ' -f 1)
        printf '%s  %s\n' "$out_hash" "$name.age" > "$out_sum.new"
        mv "$out_sum.new" "$out_sum"
    fi

    to_send+=("$out" "$out_sum")
    names+=("$name")
done

# Nothing new: do not even connect.
if [ "${#names[@]}" -eq 0 ]; then
    echo "nothing new to send"
    exit "$failed"
fi

# --- Send ---

echo "sending ${#names[@]} encrypted pair(s)"
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

# The marker first, then the encrypted copy goes: it is on backup-lab now.
for name in "${names[@]}"; do
    touch "$SENT_DIR/$name"
    rm -f -- "$OUT_DIR/$name.age" "$OUT_DIR/$name.age.sha256"
    printf 'SENT: %q\n' "$name.age"
done

exit "$failed"
