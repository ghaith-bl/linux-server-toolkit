#!/usr/bin/env bash
#
# install.sh — deploy the whole toolkit on this machine in one run.
#
# Run this as your NORMAL user. Do not run it with sudo: the script calls
# sudo itself for root's code, the apt settings and the two root units.
# Running the whole thing as root would aim `systemctl --user` and
# `enable-linger` at root instead of you.
#
# Paths are taken from wherever this file lives, so any checkout location
# and any username works. The unit files in the repo are never modified --
# they are read as templates and the rendered copies are written to the
# install directories.
#
# Usage:  ./install.sh
# Exit:   0  installed and verified
#         1  a required step failed

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---- guards -----------------------------------------------------------------

require_cmd systemctl loginctl sudo sed chmod mkdir install apt-config

# The mirror image of require_root: this script must NOT be root.
if (( EUID == 0 )); then
    die "run this as your normal user, not with sudo (see the header comment)"
fi

# ---- what goes where --------------------------------------------------------

REPO_DIR="$SCRIPT_DIR"
# backup.service writes here. The path holds no user name, so it is not
# rewritten; the folder is made by hand (docs/toolkit-lab-build.md).
BACKUP_DIR="/var/backups/linux-server-toolkit"
USER_UNIT_DIR="${HOME}/.config/systemd/user"
SYSTEM_UNIT_DIR="/etc/systemd/system"
# Root runs its scripts from here, never from the repo (step 2). The same
# folder, with the same layout, holds them on backup-lab.
ROOT_CODE_DIR="/usr/local/lib/linux-server-toolkit"
# What root runs or reads: three scripts, their two libraries, the policy.
ROOT_CODE_FILES=(
    lib/common.sh
    lib/firewall-policy.sh
    scripts/firewall-apply.sh
    scripts/firewall-check.sh
    scripts/service-watch.sh
    firewall/policy.conf
)
# The settings of the automatic security updates (step 3). The file sits in
# the repo at the path it has on the machine: etc/apt/... goes to /etc/apt/...
APT_SETTINGS="etc/apt/apt.conf.d/52unattended-upgrades-local"

# firewall-check.sh and service-watch.sh call require_root, so their units
# belong to the system manager. Everything else runs unprivileged.
ROOT_UNITS=(firewall-check service-watch)
USER_UNITS=(sysinfo hostaudit log-analyzer backup backup-prune)

# ---- render a unit file with this machine's paths ---------------------------
# The shipped user units hard-code /home/ghaith. systemd runs units with no
# shell PATH and no working directory, so absolute paths are required -- they
# cannot be made relative, only rewritten at install time. The two root units
# point to ROOT_CODE_DIR, which holds no user name: they pass through unchanged.
render_unit() {
    local src="$1"
    sed -e "s|/home/ghaith/linux-server-toolkit|${REPO_DIR}|g" "$src"
}

# ---- 1. make the scripts executable -----------------------------------------
# A missing execute bit shows up under systemd as 203/EXEC, which looks
# nothing like a script error. Set it here instead of relying on the clone.

log_info "making scripts executable"
chmod +x "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}"/tests/*.sh "${REPO_DIR}/install.sh"

# ---- 2. install root's code -------------------------------------------------
# A file in a home folder can be changed by its owner, and a root timer would
# then run that change as root, with no password asked. So root gets its own
# copies, owned by root. Only this step replaces them, and it needs sudo: a
# change to one of these files takes effect when install.sh runs again.

log_info "installing root's code in ${ROOT_CODE_DIR} (sudo required)"
sudo -v || die "sudo is required for root's code, the apt settings and the two root units"

# The folders, in the repo's layout: the scripts find their libraries and the
# policy the same way as in the repo.
sudo install -d -o root -g root -m 755 "$ROOT_CODE_DIR" \
    "${ROOT_CODE_DIR}/lib" "${ROOT_CODE_DIR}/scripts" "${ROOT_CODE_DIR}/firewall"

for f in "${ROOT_CODE_FILES[@]}"; do
    # Scripts are run (755); the libraries and the policy are only read (644).
    if [[ "$f" == scripts/* ]]; then
        mode=755
    else
        mode=644
    fi
    sudo install -o root -g root -m "$mode" "${REPO_DIR}/${f}" "${ROOT_CODE_DIR}/${f}"
done
log_ok "installed ${#ROOT_CODE_FILES[@]} files, owned by root"

# ---- 3. install the apt settings --------------------------------------------
# Ubuntu installs security updates by itself, every day; this file holds the
# lab's settings for it (the reasons are in docs/NOTES.md, v2.2). apt reads
# every file in that folder, and a file with a mistake stops apt itself: so
# apt-config reads the repo's file first, and nothing is copied when it
# finds one.

log_info "installing the apt settings (automatic security updates)"
apt-config -c "${REPO_DIR}/${APT_SETTINGS}" dump >/dev/null \
    || die "apt cannot read ${APT_SETTINGS}: nothing was copied"
sudo install -o root -g root -m 644 "${REPO_DIR}/${APT_SETTINGS}" "/${APT_SETTINGS}"
log_ok "installed /${APT_SETTINGS}"

# ---- 4. install the two root units ------------------------------------------

log_info "installing root units"

for u in "${ROOT_UNITS[@]}"; do
    for ext in service timer; do
        render_unit "${REPO_DIR}/systemd/${u}.${ext}" \
            | sudo tee "${SYSTEM_UNIT_DIR}/${u}.${ext}" >/dev/null
    done
    log_ok "installed ${u}.service and ${u}.timer"
done

sudo systemctl daemon-reload
sudo systemctl enable --now firewall-check.timer service-watch.timer
log_ok "root timers enabled"

# ---- 5. install the five user units -----------------------------------------

log_info "installing user units"
mkdir -p "$USER_UNIT_DIR"

for u in "${USER_UNITS[@]}"; do
    for ext in service timer; do
        render_unit "${REPO_DIR}/systemd/${u}.${ext}" \
            > "${USER_UNIT_DIR}/${u}.${ext}"
    done
    log_ok "installed ${u}.service and ${u}.timer"
done

systemctl --user daemon-reload
systemctl --user enable --now sysinfo.timer hostaudit.timer \
                              log-analyzer.timer backup.timer \
                              backup-prune.timer
log_ok "user timers enabled"

# ---- 6. keep the user manager alive without a login -------------------------
# Without linger the per-user systemd instance dies with the last session
# and the five user timers stop firing on an unattended server.

log_info "enabling linger for ${USER}"
sudo loginctl enable-linger "$USER"
log_ok "linger enabled"

# ---- 7. verify --------------------------------------------------------------
# Report what is actually scheduled, not what we think we installed.

log_info "verifying"

echo "--- what the root units run"
grep -H '^ExecStart=' "${SYSTEM_UNIT_DIR}/firewall-check.service" \
                      "${SYSTEM_UNIT_DIR}/service-watch.service"

echo "--- root timers"
systemctl list-timers --no-pager firewall-check.timer service-watch.timer

echo "--- user timers"
systemctl --user list-timers --no-pager \
    sysinfo.timer hostaudit.timer log-analyzer.timer backup.timer \
    backup-prune.timer

echo "--- linger"
loginctl show-user "$USER" -p Linger

# What apt reads from all its files together, not only from ours.
echo "--- automatic updates"
apt-config dump | grep -E '^(APT::Periodic::Unattended-Upgrade |Unattended-Upgrade::Automatic-Reboot)' \
    || die "the settings of the automatic updates are not in effect"

# The backup folder is not made here: it needs the backup-push group.
if [[ ! -d "$BACKUP_DIR" ]]; then
    log_warn "backup folder $BACKUP_DIR is missing: backup.service and backup-prune.service fail until it exists"
fi

log_ok "installation complete"
log_info "run one now without waiting:  sudo systemctl start firewall-check.service"
log_info "read its output with:         journalctl -u firewall-check.service --no-pager"
