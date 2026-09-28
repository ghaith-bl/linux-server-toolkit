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
# Stage 4 (this version): read the settings, run the checks and the guards.
# It changes nothing: it stops before the first change.

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
# line with a simple comment (a later stage puts it into the template).
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

# ---------------------------------------------------------------------------
# End of stage 4
# ---------------------------------------------------------------------------

echo
echo "All checks and guards passed. Nothing was changed."
echo "  machine:     $VM_NAME ($VM_MAC)"
echo "  system disk: $SYS_DISK (to be made)"
echo "  data disk:   $DATA_DISK_FILE ($DATA_DISK)"
echo "  admin key:   $ADMIN_FP, allowed from $ADMIN_FROM"
echo "  push key:    $PUSH_FP, allowed from $PUSH_FROM"
echo "Stage 4 ends here: the build itself comes in the next stages."
