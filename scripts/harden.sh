#!/usr/bin/env bash
#
# harden.sh — the one-time changes of the CIS fixes (v2.2) that are not a
# settings file: permissions, services, packages, one mount.
# The settings files themselves are in etc/, and must be in place before
# this runs: install.sh copies them on toolkit-lab, the template on
# backup-lab. Every step can run again: one that is already done changes
# nothing. The reasons are in docs/NOTES.md (v2.2).
#
# Usage:  sudo harden.sh
# Exit:   0  every step done
#         1  a step failed: the steps after it did not run

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_cmd systemctl sysctl sshd apt-get dpkg-query update-grub findmnt \
            mount find chmod install grep awk tail mkdir
require_root

# apt never stops to ask a question. When another apt is at work (the
# automatic updates), it waits up to a minute for it to finish.
export DEBIAN_FRONTEND=noninteractive
APT_WAIT=(-o DPkg::Lock::Timeout=60)

# The settings files this script puts into effect.
SSHD_SETTINGS="/etc/ssh/sshd_config.d/10-linux-server-toolkit.conf"
SYSCTL_SETTINGS="/etc/sysctl.d/60-linux-server-toolkit.conf"
GRUB_SETTINGS="/etc/default/grub.d/linux-server-toolkit.cfg"

# Clients of two protocols that send passwords as plain text.
UNUSED_PACKAGES=(ftp tnftp telnet inetutils-telnet)

# The line that mounts /dev/shm (memory shared between programs): no
# devices, no setuid files, no programs run from it.
SHM_LINE="tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0"

# mask_unit UNIT: stop the unit now and make every later start impossible.
# A unit that is not installed needs nothing.
mask_unit() {
    local unit="$1"
    local state
    state="$(systemctl show -p LoadState --value "$unit")"
    if [ "$state" = "not-found" ]; then
        log_ok "$unit is not installed"
        return 0
    fi
    # systemctl reports the link it makes on its error output: not needed here.
    systemctl mask --now "$unit" > /dev/null 2>&1 || die "could not mask $unit"
    log_ok "$unit is stopped and masked"
}

# ---- the settings files must be there ----------------------------------------

for file in "$SSHD_SETTINGS" "$SYSCTL_SETTINGS" "$GRUB_SETTINGS"; do
    # -s: the file exists and is not empty.
    if [ ! -s "$file" ]; then
        die "settings file not found: $file (on toolkit-lab, run ./install.sh first)"
    fi
done

# ---- 1. SSH -------------------------------------------------------------------

log_info "ssh: the settings files, then the settings"

# Only root reads the SSH server's settings.
chmod 600 /etc/ssh/sshd_config
find /etc/ssh/sshd_config.d -maxdepth 1 -type f -exec chmod 600 {} +

# sshd -t reads every settings file and changes nothing. A mistake stops
# here, while the server still runs with its old settings. (It needs the
# folder /run/sshd: mkdir makes it when it is not there yet.)
mkdir -p /run/sshd
sshd -t || die "sshd refuses its settings: the server keeps the old ones"

# A running server reads its settings again; open sessions stay open. A
# server that is not running reads them at its next start.
systemctl try-reload-or-restart ssh.service
log_ok "the SSH server uses the new settings"

# ---- 2. Kernel settings -------------------------------------------------------

log_info "kernel settings"

# apport (Ubuntu's crash reporter) turns memory dumps of setuid programs
# back on at each of its starts: it goes first.
mask_unit apport.service

# The kernel takes the file's values now; at every later start it reads the
# file by itself. -e: a setting this kernel does not have is skipped (the
# IPv6 ones, on a machine where IPv6 is switched off).
sysctl -e -q -p "$SYSCTL_SETTINGS" || die "the kernel refuses a value of $SYSCTL_SETTINGS"
log_ok "the kernel uses $SYSCTL_SETTINGS"

# ---- 3. /dev/shm --------------------------------------------------------------

log_info "/dev/shm: no devices, no setuid files, no programs"

# One line in /etc/fstab, added once. Lines that start with # do not count.
if grep -qE '^[^#]*[[:space:]]/dev/shm[[:space:]]' /etc/fstab; then
    log_ok "/etc/fstab already has a line for /dev/shm"
else
    # A last line with no newline after it would swallow the new one.
    if [ -n "$(tail -c 1 /etc/fstab)" ]; then
        echo >> /etc/fstab
    fi
    printf '%s\n' "$SHM_LINE" >> /etc/fstab
    log_ok "added to /etc/fstab: $SHM_LINE"
fi

# systemd reads /etc/fstab again, and the mounted /dev/shm takes the line's
# options without being emptied.
systemctl daemon-reload
mount -o remount /dev/shm

# What counts is the mount itself, whoever wrote the line.
shm_options="$(findmnt -n -o OPTIONS /dev/shm)"
for option in nodev nosuid noexec; do
    case ",$shm_options," in
        *",$option,"*) ;;
        *) die "/dev/shm is mounted without $option (its options: $shm_options)" ;;
    esac
done
log_ok "/dev/shm is mounted with nodev, nosuid and noexec"

# ---- 4. Packages and services -------------------------------------------------

log_info "packages and services"

# Only the ones that are installed are removed.
installed=()
for package in "${UNUSED_PACKAGES[@]}"; do
    status="$(dpkg-query -W -f '${db:Status-Status}' "$package" 2> /dev/null || true)"
    if [ "$status" = "installed" ]; then
        installed+=("$package")
    fi
done

if [ "${#installed[@]}" -eq 0 ]; then
    log_ok "not installed: ${UNUSED_PACKAGES[*]}"
else
    # "apt-get -s" only says what it would do: one "Purg" (or "Remv") line
    # per package. A name on those lines that is not in the list is a package
    # that needs one of them: then nothing is removed, and the CIS report
    # keeps showing these packages.
    others="$(apt-get -s purge "${installed[@]}" \
        | awk '$1 == "Purg" || $1 == "Remv" { print $2 }' \
        | grep -vxF -f <(printf '%s\n' "${UNUSED_PACKAGES[@]}") || true)"
    if [ -n "$others" ]; then
        # The names come one per line: tr puts them on one line.
        log_warn "not removed: ${installed[*]} (it would also remove: $(tr '\n' ' ' <<< "$others"))"
    else
        apt-get -y -q "${APT_WAIT[@]}" purge "${installed[@]}" > /dev/null
        log_ok "removed: ${installed[*]}"
    fi
fi

# aa-status and its companions: the tools that show what AppArmor does.
if [ "$(dpkg-query -W -f '${db:Status-Status}' apparmor-utils 2> /dev/null || true)" = "installed" ]; then
    log_ok "apparmor-utils is installed"
else
    apt-get -q "${APT_WAIT[@]}" update > /dev/null
    apt-get -y -q "${APT_WAIT[@]}" install apparmor-utils > /dev/null
    log_ok "installed: apparmor-utils"
fi

# rsync stays: the backups travel with it, over SSH. Its own network
# service is never used.
mask_unit rsync.service

# ---- 5. cron and at -----------------------------------------------------------

log_info "cron and at"

# Only root reads the scheduled jobs of the system.
chmod 700 /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
chmod 600 /etc/crontab

# Once these two files exist, only the users named in them may schedule
# jobs. Both are empty: root only. (/dev/null as the source makes an empty
# file with the right owner and mode in one step.)
if [ ! -e /etc/cron.allow ]; then
    install -o root -g crontab -m 640 /dev/null /etc/cron.allow
fi
if [ ! -e /etc/at.allow ]; then
    install -o root -g root -m 640 /dev/null /etc/at.allow
fi
log_ok "cron's folders are root's only; cron.allow and at.allow exist"

# ---- 6. The users' own start-up files -----------------------------------------

log_info "the users' start-up files"

# /etc/passwd, one account per line: name, x, uid, gid, comment, home, shell.
# The accounts a person logs in with: a uid from 1000 up and a real shell.
while IFS=: read -r name _ uid _ _ home shell; do
    if [ "$uid" -lt 1000 ] || [ ! -d "$home" ]; then
        continue
    fi
    case "$shell" in
        */nologin | */false) continue ;;
    esac
    # The names that start with a dot, in the home folder itself (.bashrc,
    # .profile...): nothing for "others", no write and no run for the group.
    # A link is left alone: its target has its own mode.
    find "$home" -mindepth 1 -maxdepth 1 -name '.*' ! -type l \
        -exec chmod g-wx,o-rwx {} +
    log_ok "$name: the dot files of $home are closed to others"
done < /etc/passwd

# ---- 7. The kernel's command line ---------------------------------------------

log_info "the kernel's command line"

# update-grub reads /etc/default/grub and the folder grub.d, and writes
# /boot/grub/grub.cfg again. The new line is used from the next start on.
update-grub > /dev/null 2>&1 || die "update-grub failed: /boot/grub/grub.cfg is unchanged"
if ! grep -q 'apparmor=1 security=apparmor' /boot/grub/grub.cfg; then
    die "/boot/grub/grub.cfg does not hold the words of $GRUB_SETTINGS"
fi
log_ok "/boot/grub/grub.cfg holds apparmor=1 security=apparmor"

# ---- 8. The clock -------------------------------------------------------------

log_info "the clock"

# The time service reads its settings at its start.
systemctl try-restart systemd-timesyncd.service
log_ok "systemd-timesyncd uses the servers of its settings file"

log_ok "harden.sh: every step done"
