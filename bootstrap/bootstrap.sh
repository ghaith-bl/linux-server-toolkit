#!/usr/bin/env bash
#
# bootstrap.sh: build a backup-lab machine on this KVM host with one command.
#
# Usage:   bootstrap/bootstrap.sh <settings file>
# Example: bootstrap/bootstrap.sh ~/lab-images/backup-lab/backup-lab.conf
#
# Run it as your normal user, not with sudo. It uses sudo inside, only for
# the commands that need root. The settings are explained in example.conf.
#
# Stage 7 (this version): read the settings, run the checks and the guards,
# write the cloud-init files, make the disks, run the first boot with
# virt-install (which logs the serial console into a file on this host),
# pin the machine's host key, and run the final read-only check.
# It never removes anything: a STOP after the disks leaves them in place.

# Stop on any error (-e), on an unset variable (-u),
# and when any command inside a pipe fails (pipefail).
set -euo pipefail

# ---------------------------------------------------------------------------
# Fixed values: the same for every machine this script builds
# ---------------------------------------------------------------------------

# The folder with the base image, and one folder per machine.
IMAGES_DIR="$HOME/lab-images"
# The verified Ubuntu cloud image (backup-lab guide, steps 1-3).
IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
BASE_IMAGE="$IMAGES_DIR/$IMAGE_NAME"
# The key that signs Ubuntu's SHA256SUMS (checked by hand once, guide step 2).
UBUNTU_KEY_FP="D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"
# Where libvirt keeps the machine disks.
DISK_DIR="/var/lib/libvirt/images"
# The libvirt network the machine joins.
NETWORK="default"
# The folder this script lives in: readlink -f gives the script's full path,
# dirname cuts the file name off.
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# The cloud-init template, from the same commit as this script.
TEMPLATE="$SCRIPT_DIR/user-data.template"
# Where libvirt keeps each machine's logs (root only, mode 700).
LOG_DIR="/var/log/libvirt/qemu"
# The machine's size (backup-lab guide, steps 4 and 8).
VM_OSINFO="ubuntu24.04"
VM_MEMORY=1024
VM_VCPUS=1
SYS_SIZE="10G"
DATA_SIZE="20G"
# How long virt-install waits for the first boot to power off, in minutes.
FIRST_BOOT_WAIT=30
# How long to wait for the SSH server after the restart, in seconds.
SSH_WAIT=30
# The admin account the template creates (user-data.template, users).
ADMIN_USER="ghaith"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# stop MESSAGE: print the message and end the script with exit code 1.
stop() {
    echo "STOP: $1" >&2
    exit 1
}

# ok MESSAGE: print one line for a check that passed.
ok() {
    echo "ok: $1"
}

# mode_of PATH: print the permission bits of PATH as numbers (like 600).
mode_of() {
    stat -c '%a' "$1"
}

# check_shape NAME VALUE PATTERN: stop unless the whole VALUE matches the
# regular expression PATTERN. NAME is only used in the message.
check_shape() {
    local name="$1"
    local value="$2"
    local pattern="$3"
    # grep -x: the pattern must match the whole value, not only a part of it.
    if ! echo "$value" | grep -qxE "$pattern"; then
        stop "$name has a wrong value: '$value'"
    fi
}

# check_pubkey FILE: stop unless FILE holds exactly one ed25519 public key
# line with a simple comment (stage 5 puts it into the template with sed).
check_pubkey() {
    local file="$1"
    # The file must exist.
    if [ ! -f "$file" ]; then
        stop "key file not found: $file"
    fi
    # It must hold exactly one line.
    if [ "$(wc -l < "$file")" -ne 1 ]; then
        stop "key file must hold exactly one line: $file"
    fi
    # Its shape: "ssh-ed25519 <key> <comment>", with no special characters.
    if ! grep -qxE 'ssh-ed25519 [A-Za-z0-9+/=]+ [A-Za-z0-9@._-]+' "$file"; then
        stop "not a simple ed25519 key line: $file"
    fi
    # ssh-keygen must be able to read it.
    if ! ssh-keygen -lf "$file" > /dev/null; then
        stop "ssh-keygen cannot read: $file"
    fi
}

# count_lines TEXT: print how many lines of TEXT are not empty.
# grep -c exits 1 when it counts 0: "|| true" keeps the script going.
count_lines() {
    echo "$1" | grep -c . || true
}

# check_log_count TEXT EXPECTED: stop unless TEXT is on exactly EXPECTED
# lines of the serial log. -F: TEXT is plain text, "[" has no meaning.
# The counts are compared as text, so an empty answer never passes.
check_log_count() {
    local text="$1"
    local expected="$2"
    local found
    found=$(sudo grep -cF "$text" "$SERIAL_LOG") || true
    if [ "$found" != "$expected" ]; then
        stop "serial log: '$text' is on $found lines, expected $expected"
    fi
    ok "serial log: '$text' on $expected line(s)"
}

# check_report LINE WHAT: stop unless the machine's report holds LINE as a
# whole line, exactly as written (-x: the whole line, -F: plain text).
check_report() {
    local line="$1"
    local what="$2"
    if ! echo "$report" | grep -qxF "$line"; then
        stop "final check: $what is not as expected (see the report above)"
    fi
    ok "$what"
}

# ---------------------------------------------------------------------------
# 1. Settings
# ---------------------------------------------------------------------------

echo "== 1. Settings"

# Never as root: the settings, the keys and the machine folder are in your home.
if [ "$(id -u)" -eq 0 ]; then
    stop "run this as your normal user, not as root or with sudo"
fi

# Exactly one argument: the settings file.
if [ "$#" -ne 1 ]; then
    stop "usage: $0 <settings file>"
fi
CONF="$1"

# The settings file: it must exist, be yours, and be closed to everyone else.
# source runs it as bash code, so nobody else may be able to change it.
if [ ! -f "$CONF" ]; then
    stop "settings file not found: $CONF"
fi
# -O: the file belongs to the user running the script.
if [ ! -O "$CONF" ]; then
    stop "settings file is not owned by you: $CONF"
fi
if [ "$(mode_of "$CONF")" != "600" ]; then
    stop "settings file must have mode 600 (now $(mode_of "$CONF")): $CONF"
fi

# Start every setting empty, then load the file over them.
VM_NAME=""
VM_MAC=""
ADMIN_FROM=""
PUSH_FROM=""
ADMIN_KEY=""
PUSH_KEY=""
PUSH_KEY_FP=""
DATA_DISK=""
# shellcheck source=/dev/null
source "$CONF"

# The shape of each setting (an empty setting fails here too).
check_shape VM_NAME "$VM_NAME" '[a-z][a-z0-9-]*'
check_shape VM_MAC "$VM_MAC" '52:54:00(:[0-9a-f]{2}){3}'
check_shape ADMIN_FROM "$ADMIN_FROM" '([0-9]{1,3}\.){3}[0-9]{1,3}'
check_shape PUSH_FROM "$PUSH_FROM" '([0-9]{1,3}\.){3}[0-9]{1,3}'
check_shape PUSH_KEY_FP "$PUSH_KEY_FP" 'SHA256:[A-Za-z0-9+/]{43}'
check_shape DATA_DISK "$DATA_DISK" 'new|reuse'
ok "settings loaded from $CONF"

# Paths that come from the machine's name.
MACHINE_DIR="$IMAGES_DIR/$VM_NAME"
SYS_DISK="$DISK_DIR/$VM_NAME.qcow2"
DATA_DISK_FILE="$DISK_DIR/$VM_NAME-data.qcow2"
# The cloud-init files, written into the machine folder.
USER_DATA="$MACHINE_DIR/user-data"
META_DATA="$MACHINE_DIR/meta-data"
# A helper file for the password hash, removed as soon as it is used.
HASH_FILE="$MACHINE_DIR/pw.hash"
# A new id at every build: cloud-init runs its first-boot setup once per id,
# and the date and time show which build a machine came from.
INSTANCE_ID="$VM_NAME-$(date +%Y%m%d-%H%M%S)"
# The serial console log of this build, written by libvirt (root only).
# The id in its name gives every build its own file: libvirt only appends.
SERIAL_LOG="$LOG_DIR/$INSTANCE_ID-serial.log"
# The host key of this build, pinned for the final check (one per build).
KNOWN_HOSTS="$MACHINE_DIR/known_hosts-$INSTANCE_ID"

# ---------------------------------------------------------------------------
# 2. Checks (read only)
# ---------------------------------------------------------------------------

echo "== 2. Checks"

# The tools this script needs.
for tool in sudo virsh virt-install qemu-img ssh ssh-keygen ssh-keyscan openssl gpg sha256sum; do
    if ! command -v "$tool" > /dev/null; then
        stop "missing tool: $tool"
    fi
done
ok "tools found"

# Ask for the sudo password now, once, before the checks that need root.
if ! sudo -v; then
    stop "sudo did not accept the password"
fi
ok "sudo works"

# The machine folder: it must exist, be yours, and be closed (mode 700).
if [ ! -d "$MACHINE_DIR" ]; then
    stop "machine folder not found: $MACHINE_DIR"
fi
if [ ! -O "$MACHINE_DIR" ]; then
    stop "machine folder is not owned by you: $MACHINE_DIR"
fi
if [ "$(mode_of "$MACHINE_DIR")" != "700" ]; then
    stop "machine folder must have mode 700 (now $(mode_of "$MACHINE_DIR")): $MACHINE_DIR"
fi
ok "machine folder $MACHINE_DIR"

# The template: it must exist and hold the five placeholders, and no others.
if [ ! -f "$TEMPLATE" ]; then
    stop "template not found: $TEMPLATE"
fi
for placeholder in ADMIN_FROM ADMIN_PUBLIC_KEY CONSOLE_PASSWORD_HASH PUSH_FROM PUSH_PUBLIC_KEY; do
    if ! grep -qF "<$placeholder>" "$TEMPLATE"; then
        stop "template: placeholder <$placeholder> is missing"
    fi
done
# Count the different placeholders (sort -u keeps each one once).
count=$(grep -oE '<[A-Z_]+>' "$TEMPLATE" | sort -u | wc -l)
if [ "$count" -ne 5 ]; then
    stop "template: expected 5 placeholders, found $count"
fi
ok "template $TEMPLATE"

# The base image: it must exist and be read-only (444).
if [ ! -f "$BASE_IMAGE" ]; then
    stop "base image not found: $BASE_IMAGE (backup-lab guide, steps 1-3)"
fi
if [ "$(mode_of "$BASE_IMAGE")" != "444" ]; then
    stop "base image must have mode 444 (now $(mode_of "$BASE_IMAGE")): $BASE_IMAGE"
fi
# SHA256SUMS must be signed by Ubuntu's image key.
# --status-fd 1: gpg also prints short lines made for scripts; the VALIDSIG
# line holds the full fingerprint of the key that made the signature.
# If gpg fails, the script only says so: run the guide's step 2 command by
# hand to see gpg's own message.
sig_status=$(gpg --status-fd 1 --verify "$IMAGES_DIR/SHA256SUMS.gpg" "$IMAGES_DIR/SHA256SUMS" 2> /dev/null) \
    || stop "SHA256SUMS: the signature check failed (see guide, step 2)"
if ! echo "$sig_status" | grep -qE "VALIDSIG .*$UBUNTU_KEY_FP"; then
    stop "SHA256SUMS: not signed by Ubuntu's image key $UBUNTU_KEY_FP"
fi
# The image must match its line in SHA256SUMS (the guide's command, step 2).
# $( ) runs in its own copy of the shell: the cd stays inside it,
# the script itself does not change folder.
sums_result=$(cd "$IMAGES_DIR" && sha256sum --ignore-missing -c SHA256SUMS 2>&1) \
    || stop "base image: the checksum check failed (see guide, step 2)"
if ! echo "$sums_result" | grep -qxF "$IMAGE_NAME: OK"; then
    stop "base image: not listed in SHA256SUMS"
fi
ok "base image $BASE_IMAGE (signature and checksum)"

# The admin key: the private part only has to exist (it is used at the end,
# for the read-only SSH check); the public part (.pub) is checked.
if [ ! -f "$ADMIN_KEY" ]; then
    stop "admin private key not found: $ADMIN_KEY"
fi
check_pubkey "$ADMIN_KEY.pub"
# The fingerprint is the second word of ssh-keygen -lf.
ADMIN_FP=$(ssh-keygen -lf "$ADMIN_KEY.pub" | awk '{print $2}')
ok "admin key $ADMIN_KEY.pub ($ADMIN_FP)"

# The push key came from another machine: compare its fingerprint.
check_pubkey "$PUSH_KEY"
PUSH_FP=$(ssh-keygen -lf "$PUSH_KEY" | awk '{print $2}')
if [ "$PUSH_FP" != "$PUSH_KEY_FP" ]; then
    stop "push key fingerprint $PUSH_FP does not match the settings ($PUSH_KEY_FP)"
fi
ok "push key $PUSH_KEY ($PUSH_FP, matches the settings)"

# One key per job: the admin key and the push key must be different keys.
if [ "$ADMIN_FP" = "$PUSH_FP" ]; then
    stop "the admin key and the push key are the same key"
fi
ok "admin key and push key are different"

# The network must be active.
net_info=$(sudo virsh net-info "$NETWORK")
if ! echo "$net_info" | grep -qE '^Active:[[:space:]]+yes$'; then
    stop "network $NETWORK is not active"
fi
# ADMIN_FROM must be the host's own address on that network:
# the admin key works only from there, a wrong value locks you out.
net_xml=$(sudo virsh net-dumpxml "$NETWORK")
if ! echo "$net_xml" | grep -qF "<ip address='$ADMIN_FROM'"; then
    stop "ADMIN_FROM $ADMIN_FROM is not the host's address on network $NETWORK"
fi
ok "network $NETWORK is active, host address $ADMIN_FROM"

# libvirt's log folder: the serial log is written there.
if ! sudo test -d "$LOG_DIR"; then
    stop "libvirt's log folder not found: $LOG_DIR"
fi
ok "log folder $LOG_DIR"

# ---------------------------------------------------------------------------
# 3. Guards (read only): nothing may be overwritten
# ---------------------------------------------------------------------------

echo "== 3. Guards"

# Every machine libvirt knows, running or not (one name per line).
all_machines=$(sudo virsh list --all --name)

# No machine with this name yet.
if echo "$all_machines" | grep -qxF "$VM_NAME"; then
    stop "a machine named $VM_NAME already exists"
fi
ok "no machine named $VM_NAME"

# The system disk must not exist: qemu-img overwrites without asking.
if sudo test -e "$SYS_DISK"; then
    stop "system disk already exists: $SYS_DISK"
fi
ok "no system disk $SYS_DISK"

# The data disk must match DATA_DISK: "new" = absent, "reuse" = present.
if [ "$DATA_DISK" = "new" ]; then
    if sudo test -e "$DATA_DISK_FILE"; then
        stop "DATA_DISK is new, but the data disk exists: $DATA_DISK_FILE"
    fi
    ok "no data disk $DATA_DISK_FILE (it will be made)"
else
    if ! sudo test -e "$DATA_DISK_FILE"; then
        stop "DATA_DISK is reuse, but there is no data disk: $DATA_DISK_FILE"
    fi
    ok "data disk $DATA_DISK_FILE exists (it will be kept)"
fi

# No other machine may use these disk files or this network card address.
for machine in $all_machines; do
    # This machine's disks: the second column of domblklist is the file.
    disks=$(sudo virsh domblklist "$machine" | awk '{print $2}')
    if echo "$disks" | grep -qxF -e "$SYS_DISK" -e "$DATA_DISK_FILE"; then
        stop "machine $machine uses a disk of $VM_NAME"
    fi
    # This machine's network cards (-i: upper or lower case).
    cards=$(sudo virsh domiflist "$machine")
    if echo "$cards" | grep -qiF "$VM_MAC"; then
        stop "machine $machine already uses the network card address $VM_MAC"
    fi
done
ok "no other machine uses these disks or $VM_MAC"

# No cloud-init files from an earlier build: the script never overwrites or
# deletes them (user-data holds an old password hash). Remove them by hand
# before a rebuild.
for file in "$USER_DATA" "$META_DATA"; do
    if [ -e "$file" ]; then
        stop "$file already exists (from an earlier build): remove it by hand first"
    fi
done
ok "no cloud-init files in $MACHINE_DIR"

# No serial log for this build yet: libvirt would append to an old file.
if sudo test -e "$SERIAL_LOG"; then
    stop "serial log already exists: $SERIAL_LOG"
fi
ok "no serial log $SERIAL_LOG"

# No known_hosts file for this build yet: the host key check writes it.
if [ -e "$KNOWN_HOSTS" ]; then
    stop "known_hosts file already exists: $KNOWN_HOSTS"
fi
ok "no known_hosts file $KNOWN_HOSTS"

# ---------------------------------------------------------------------------
# 4. Password and cloud-init files: the first changes, in the machine folder
# ---------------------------------------------------------------------------

echo "== 4. Password and cloud-init files"

# The console password, typed twice. read -s: nothing shows on screen;
# -r: backslashes stay as typed; -p: print the question first.
if ! read -rsp "Console password for $VM_NAME: " password; then
    stop "no password was given"
fi
echo
if ! read -rsp "The same password again: " password_again; then
    stop "no password was given"
fi
echo
if [ -z "$password" ]; then
    stop "the password is empty"
fi
if [ "$password" != "$password_again" ]; then
    stop "the two passwords are different"
fi

# From here on, remove the hash helper file whenever the script ends,
# even after a STOP: the EXIT trap runs on every exit.
trap 'rm -f "$HASH_FILE"' EXIT

# Make the helper file empty and closed (600) before the hash goes in.
install -m 600 /dev/null "$HASH_FILE"
# printf is built into bash, so the password never shows in the process list.
# openssl passwd -6 -stdin: read the password from the pipe, print its hash.
if ! printf '%s\n' "$password" | openssl passwd -6 -stdin > "$HASH_FILE"; then
    stop "openssl could not hash the password"
fi
# The password itself is no longer needed.
unset password password_again

# The hash must be one line shaped like $6$<salt>$<hash>. It is checked
# inside the file, so a wrong hash is never printed on screen.
# In the pattern, [$] means one real "$" character.
if [ "$(wc -l < "$HASH_FILE")" -ne 1 ]; then
    stop "the password hash must be one line"
fi
if ! grep -qxE '[$]6[$][./A-Za-z0-9]+[$][./A-Za-z0-9]+' "$HASH_FILE"; then
    stop "the password hash has a wrong shape"
fi
ok "password hashed (the hash never shows on screen)"

# Read the three values into variables first. Under set -e, a failed $( )
# stops the script only in an assignment like these: inside a sed argument
# it would silently give an empty value.
password_hash=$(cat "$HASH_FILE")
admin_public_key=$(cat "$ADMIN_KEY.pub")
push_public_key=$(cat "$PUSH_KEY")

# user-data: a copy of the template, closed (600) before any secret goes in.
install -m 600 "$TEMPLATE" "$USER_DATA"
# Fill each placeholder. "|" separates the parts of the sed command, because
# keys and the hash contain "/". The values were checked above: none of them
# holds "|", "&" or "\", which have a special meaning for sed.
sed -i "s|<CONSOLE_PASSWORD_HASH>|$password_hash|" "$USER_DATA"
sed -i "s|<ADMIN_FROM>|$ADMIN_FROM|" "$USER_DATA"
sed -i "s|<ADMIN_PUBLIC_KEY>|$admin_public_key|" "$USER_DATA"
sed -i "s|<PUSH_FROM>|$PUSH_FROM|" "$USER_DATA"
sed -i "s|<PUSH_PUBLIC_KEY>|$push_public_key|" "$USER_DATA"
# The hash is inside user-data now: remove the helper file and the variable.
rm "$HASH_FILE"
unset password_hash

# No placeholder may be left, and the file must still be closed (600).
if grep -qE '<[A-Z_]+>' "$USER_DATA"; then
    stop "user-data: a placeholder was not filled: $USER_DATA"
fi
if [ "$(mode_of "$USER_DATA")" != "600" ]; then
    stop "user-data must have mode 600 (now $(mode_of "$USER_DATA")): $USER_DATA"
fi
ok "user-data $USER_DATA (mode 600, all five placeholders filled)"

# meta-data: the machine's id and name for cloud-init (no secret inside).
printf 'instance-id: %s\nlocal-hostname: %s\n' "$INSTANCE_ID" "$VM_NAME" > "$META_DATA"
ok "meta-data $META_DATA (instance-id $INSTANCE_ID)"

# ---------------------------------------------------------------------------
# 5. Disks: from here on, a STOP leaves what was made in place
# ---------------------------------------------------------------------------

echo "== 5. Disks"
echo "From here on, a STOP removes nothing: see the build guide,"
echo "'If bootstrap.sh stops after the disks'."

# The system disk: an independent copy of the base image (guide, step 4).
# The guards checked that it does not exist: qemu-img overwrites without asking.
if ! sudo qemu-img convert -O qcow2 "$BASE_IMAGE" "$SYS_DISK"; then
    stop "qemu-img could not copy the base image to $SYS_DISK"
fi
# qemu-img as root makes 644 files: close the disk at once.
if ! sudo chmod 600 "$SYS_DISK"; then
    stop "could not set mode 600 on $SYS_DISK"
fi
# Grow it: cloud-init grows the root partition to fill it at first boot.
if ! sudo qemu-img resize "$SYS_DISK" "$SYS_SIZE"; then
    stop "qemu-img could not resize $SYS_DISK"
fi
ok "system disk $SYS_DISK ($SYS_SIZE, mode 600)"

# The data disk: made only when DATA_DISK is new; with reuse it is kept as it
# is, backups included (cloud-init formats only an empty partition).
if [ "$DATA_DISK" = "new" ]; then
    if ! sudo qemu-img create -f qcow2 "$DATA_DISK_FILE" "$DATA_SIZE"; then
        stop "qemu-img could not make $DATA_DISK_FILE"
    fi
    if ! sudo chmod 600 "$DATA_DISK_FILE"; then
        stop "could not set mode 600 on $DATA_DISK_FILE"
    fi
    ok "data disk $DATA_DISK_FILE made ($DATA_SIZE, mode 600)"
else
    ok "data disk $DATA_DISK_FILE kept as it is"
fi

# ---------------------------------------------------------------------------
# 6. First boot
# ---------------------------------------------------------------------------

echo "== 6. First boot"

# The virt-install options (guide, step 8), one per line with its reason.
# An array keeps each option as one word, even a value with a space in it.
install_options=(
    --connect qemu:///system                                  # libvirt's system instance
    --name "$VM_NAME"                                         # the machine's name in libvirt
    --osinfo "$VM_OSINFO"                                     # the guest system: libvirt picks fitting defaults
    --memory "$VM_MEMORY"                                     # memory in MiB
    --vcpus "$VM_VCPUS"                                       # virtual CPUs
    --import                                                  # no installer: boot the system disk directly
    --disk "path=$SYS_DISK,format=qcow2,bus=virtio"           # first disk = vda, the system
    --disk "path=$DATA_DISK_FILE,format=qcow2,bus=virtio"     # second disk = vdb, the data
    --network "network=$NETWORK,model=virtio,mac=$VM_MAC"     # the same MAC at every build
    --cloud-init "user-data=$USER_DATA,meta-data=$META_DATA"  # a small disk, attached for the first boot only
    --graphics none                                           # no screen: the serial port is the console
    --serial "pty,log.file=$SERIAL_LOG,log.append=on"         # the console, also written into the serial log
    --noautoconsole                                           # do not open the console in this terminal
    --wait "$FIRST_BOOT_WAIT"                                 # wait (minutes) for the first power-off
)

# virt-install starts the machine, waits until cloud-init powers it off
# (power_state in user-data), then starts it again without the cloud-init
# disk. If the wait runs out, it exits with an error and leaves the machine
# as it is.
echo "Waiting up to $FIRST_BOOT_WAIT minutes for the first boot to power off."
if ! sudo virt-install "${install_options[@]}"; then
    stop "virt-install did not finish; nothing was removed (build guide: 'If bootstrap.sh stops after the disks')"
fi

# After the first power-off, virt-install started the machine again.
state=$(sudo virsh domstate "$VM_NAME") \
    || stop "virsh cannot read the state of $VM_NAME"
if [ "$state" != "running" ]; then
    stop "$VM_NAME is not running after the first boot (state: $state)"
fi
ok "first boot done, $VM_NAME started again"

# The serial log must exist and hold something (-s: size above zero).
if ! sudo test -s "$SERIAL_LOG"; then
    stop "the serial log is missing or empty: $SERIAL_LOG"
fi
ok "serial log $SERIAL_LOG"

# ---------------------------------------------------------------------------
# 7. Address and host key: only the known_hosts file of this build is written
# ---------------------------------------------------------------------------

echo "== 7. Address and host key"

# The running machine must have the network card address of the settings.
cards=$(sudo virsh domiflist "$VM_NAME")
if ! echo "$cards" | grep -qiF "$VM_MAC"; then
    stop "$VM_NAME does not have the network card address $VM_MAC"
fi
ok "$VM_NAME has the network card address $VM_MAC"

# Its address, from the network's lease table, for this card only: every
# IPv4 address in the table, one per line, with the "/24" cut off.
# The machine may have given its first lease back at the power-off, so wait
# for an address: every 2 seconds, for at most SSH_WAIT seconds. SECONDS is
# bash's own counter of the seconds since the script started.
wait_start=$SECONDS
addresses=""
while [ -z "$addresses" ]; do
    if [ $((SECONDS - wait_start)) -ge "$SSH_WAIT" ]; then
        stop "no address for $VM_MAC in the lease table after $SSH_WAIT seconds (the machine keeps running)"
    fi
    leases=$(sudo virsh net-dhcp-leases "$NETWORK" --mac "$VM_MAC")
    # No address yet is not an error here: "|| true".
    addresses=$(echo "$leases" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | cut -d/ -f1) || true
    if [ -z "$addresses" ]; then
        sleep 2
    fi
done
# Exactly one address. An old machine's lease stays in the table until it
# expires (one hour on the default network): then there are two, and the
# script stops.
address_count=$(count_lines "$addresses")
if [ "$address_count" != "1" ]; then
    stop "the lease table holds $address_count addresses for $VM_MAC, expected 1"
fi
VM_IP="$addresses"
ok "one lease for $VM_MAC, about $((SECONDS - wait_start)) seconds after the wait started"

# If the network reserves an address for this card, it must be that one.
# net_xml was read in the checks; a reservation line looks like
# <host mac='52:54:00:..:..:..' name='...' ip='192.168.122.x'/>.
reserved=$(echo "$net_xml" | grep -F "<host mac='$VM_MAC'" | grep -oE "ip='[0-9.]+'" | cut -d"'" -f2) || true
if [ -n "$reserved" ]; then
    if [ "$VM_IP" != "$reserved" ]; then
        stop "$VM_NAME got $VM_IP, but the network reserves $reserved for $VM_MAC"
    fi
    ok "address $VM_IP (the address reserved for $VM_MAC)"
else
    ok "address $VM_IP (no reservation for $VM_MAC)"
fi

# Wait for the SSH server: ask it for its ed25519 host key every 2 seconds,
# within the same SSH_WAIT seconds, counted from the start of the wait for
# the address. No answer yet is not an error here ("|| true").
# ssh-keyscan also prints a comment line with the server's version, starting
# with "#": on stderr before OpenSSH 9.8, on stdout since then. 2> /dev/null
# drops the first kind, grep -v '^#' the second: both give only the key line.
scanned=""
while [ -z "$scanned" ]; do
    if [ $((SECONDS - wait_start)) -ge "$SSH_WAIT" ]; then
        stop "no SSH answer from $VM_IP after $SSH_WAIT seconds (the machine keeps running)"
    fi
    sleep 2
    scanned=$(ssh-keyscan -T 2 -t ed25519 "$VM_IP" 2> /dev/null | grep -v '^#') || true
done
ok "SSH answered about $((SECONDS - wait_start)) seconds after the wait started"

# The answer must be one line: "<address> ssh-ed25519 <key>".
if [ "$(count_lines "$scanned")" != "1" ]; then
    stop "ssh-keyscan returned more than one line for $VM_IP"
fi
check_shape "the scanned host key" "$scanned" "$VM_IP ssh-ed25519 [A-Za-z0-9+/=]+"
# Its fingerprint: <( ) hands the line to ssh-keygen as a file.
scanned_fp=$(ssh-keygen -lf <(echo "$scanned") | awk '{print $2}') \
    || stop "ssh-keygen cannot read the scanned host key"

# The host key the machine itself printed on its console at the first boot:
# cloud-init's fingerprint block (one per build), one line per key type,
# like "256 SHA256:<43 characters> root@<name> (ED25519)".
check_log_count "BEGIN SSH HOST KEY FINGERPRINTS" 1
block=$(sudo sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END SSH HOST KEY FINGERPRINTS/p' "$SERIAL_LOG") \
    || stop "cannot read the serial log: $SERIAL_LOG"
ed25519_lines=$(echo "$block" | grep -F '(ED25519)') || true
if [ "$(count_lines "$ed25519_lines")" != "1" ]; then
    stop "serial log: expected one ED25519 line in the fingerprint block"
fi
# grep -o keeps only "SHA256:" and the 43 characters after it: what comes
# before it on the line, and the "\r" at the line's end, do not matter.
LOG_FP=$(echo "$ed25519_lines" | grep -oE 'SHA256:[A-Za-z0-9+/]{43}') || true
if [ "$(count_lines "$LOG_FP")" != "1" ]; then
    stop "serial log: no ED25519 fingerprint in the fingerprint block"
fi

# The network's answer is trusted only if it matches the console.
if [ "$scanned_fp" != "$LOG_FP" ]; then
    stop "host key mismatch: $VM_IP answered $scanned_fp, the console printed $LOG_FP"
fi
ok "host key $LOG_FP (the console and the network agree)"

# Only now write the known_hosts file of this build: the one line that
# ssh-keyscan returned. The final check trusts this file only.
printf '%s\n' "$scanned" > "$KNOWN_HOSTS"
ok "known_hosts $KNOWN_HOSTS"

# ---------------------------------------------------------------------------
# 8. Final check (read only)
# ---------------------------------------------------------------------------

echo "== 8. Final check"

# The first boot on the console, checked on this host with no login: one
# power-off, two kernel starts (the first boot and the restart), and no
# warning or error line from cloud-init.
check_log_count "reboot: Power down" 1
check_log_count "Linux version" 2
check_log_count "[WARNING]" 0
check_log_count "[ERROR]" 0

# The ssh options of both connections below, one per line with its reason.
ssh_options=(
    -o UserKnownHostsFile="$KNOWN_HOSTS"   # trust only the host key of this build
    -o GlobalKnownHostsFile=/dev/null      # and no host key from the system's list
    -o StrictHostKeyChecking=yes           # an unknown or changed host key: refuse, never ask
    -o UpdateHostKeys=no                   # never add keys to that file
    -o ConnectTimeout=10                   # give up after 10 seconds without an answer
)

# SSH must refuse passwords. With keys turned off and no questions allowed
# (BatchMode), the server's refusal lists the only methods it accepts:
# "publickey" must be the only one. Failing is the expected result here.
refusal=$(ssh "${ssh_options[@]}" -o BatchMode=yes -o PubkeyAuthentication=no \
    "$ADMIN_USER@$VM_IP" true 2>&1) || true
if ! echo "$refusal" | grep -qF "Permission denied (publickey)."; then
    stop "SSH did not refuse a login without a key the expected way: $refusal"
fi
ok "SSH refuses logins without a key (publickey only)"

# The line the push key must have on the machine: the same line as in the
# template's write_files, with this build's values.
expected_key_line="restrict,from=\"$PUSH_FROM\",command=\"/usr/bin/rrsync -wo -no-del /srv/backup/incoming\" $push_public_key"

# The read-only commands that run inside the machine, one per line, all in
# one login as the admin account. No sudo: the check sees only what the
# admin account may read. The key file's lines get the prefix "key file: ",
# and "report-end" comes last, to prove the report arrived whole.
remote_report="hostname
grep -F errors /var/lib/cloud/data/result.json
findmnt -n -r -o SOURCE,FSTYPE,LABEL /srv/backup
getent passwd backup-recv
stat -c '%U %G %a %n' /home/backup-recv /home/backup-recv/.ssh /home/backup-recv/.ssh/authorized_keys /srv/backup/incoming
sed 's/^/key file: /' /home/backup-recv/.ssh/authorized_keys
getent passwd ubuntu || echo 'no ubuntu user'
echo report-end"

# The login options, one per line with its reason.
login_options=(
    -i "$ADMIN_KEY"                         # the admin key
    -o IdentitiesOnly=yes                   # offer only this key
    -o IdentityAgent=none                   # no agent: ssh reads the key file and asks its passphrase here
    -o AddKeysToAgent=no                    # and never adds the key to an agent
    -o PasswordAuthentication=no            # never fall back to a password
    -o KbdInteractiveAuthentication=no      # nor to any other question from the server
)

# One login: ssh asks for the admin key's passphrase (up to 3 tries).
# SC2029: shellcheck warns that "$remote_report" is filled in on this host.
# That is the point: the commands are written here and only run there.
echo "The final check logs in once as $ADMIN_USER with $ADMIN_KEY."
# shellcheck disable=SC2029
report=$(ssh "${ssh_options[@]}" "${login_options[@]}" "$ADMIN_USER@$VM_IP" "$remote_report") \
    || stop "the SSH login with the admin key failed (the machine keeps running)"
echo "The machine's report:"
echo "$report"

# Each line the report must hold. First its last line: without it, the
# login ended early and the rest of the report cannot be trusted.
if ! echo "$report" | grep -qxF "report-end"; then
    stop "final check: the report did not arrive whole (see the report above)"
fi
ok "the report arrived whole"
check_report "$VM_NAME" "hostname $VM_NAME"
# result.json: cloud-init's saved result of the first boot. An empty error
# list fits on one line; any error would start a list on the next lines.
if ! echo "$report" | grep -qxE ' *"errors": \[\]'; then
    stop "final check: cloud-init saved errors from the first boot (see the report above)"
fi
ok "cloud-init saved no error from the first boot (result.json)"
check_report "/dev/vdb1 ext4 backup-data" "/srv/backup is the data disk (vdb1, ext4, label backup-data)"
# backup-recv: a system account (a uid of 3 digits, below 1000), with its
# home and /bin/sh.
if ! echo "$report" | grep -qxE 'backup-recv:x:[0-9]{3}:[0-9]+:[^:]*:/home/backup-recv:/bin/sh'; then
    stop "final check: the account backup-recv is not as expected (see the report above)"
fi
ok "backup-recv: system account, home /home/backup-recv, shell /bin/sh"
check_report "root root 755 /home/backup-recv" "/home/backup-recv: root root 755"
check_report "root root 755 /home/backup-recv/.ssh" "/home/backup-recv/.ssh: root root 755"
check_report "root root 644 /home/backup-recv/.ssh/authorized_keys" "authorized_keys: root root 644"
check_report "backup-recv backup-recv 700 /srv/backup/incoming" "/srv/backup/incoming: backup-recv backup-recv 700"
# The key file: exactly one line, and exactly the expected one.
key_file_lines=$(echo "$report" | grep -F 'key file: ') || true
if [ "$(count_lines "$key_file_lines")" != "1" ]; then
    stop "final check: authorized_keys must hold exactly one line"
fi
check_report "key file: $expected_key_line" "authorized_keys: the push key, with its limits"
check_report "no ubuntu user" "no ubuntu user"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
echo "The machine is built, running, and passed the final check."
echo "  machine:     $VM_NAME ($VM_MAC), instance-id $INSTANCE_ID"
echo "  address:     $VM_IP"
echo "  host key:    $LOG_FP"
echo "  known_hosts: $KNOWN_HOSTS"
echo "  cloud-init:  $USER_DATA and $META_DATA"
echo "  system disk: $SYS_DISK"
echo "  data disk:   $DATA_DISK_FILE ($DATA_DISK)"
echo "  serial log:  $SERIAL_LOG"
echo "  admin key:   $ADMIN_FP, allowed from $ADMIN_FROM"
echo "  push key:    $PUSH_FP, allowed from $PUSH_FROM"
echo "A new build has a new host key: update the key pinned on the sending"
echo "machine by hand, after comparing it with the host key above."
