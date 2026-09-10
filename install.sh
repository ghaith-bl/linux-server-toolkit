#!/usr/bin/env bash
#
# install.sh — deploy the whole toolkit on this machine in one run.
#
# Run this as your NORMAL user. Do not run it with sudo: the script calls
# sudo itself for the two root units. Running the whole thing as root would
# aim `systemctl --user` and `enable-linger` at root instead of you.
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

require_cmd systemctl loginctl sudo sed chmod mkdir

# The mirror image of require_root: this script must NOT be root.
if (( EUID == 0 )); then
    die "run this as your normal user, not with sudo (see the header comment)"
fi

# ---- what goes where --------------------------------------------------------

REPO_DIR="$SCRIPT_DIR"
BACKUP_DIR="${HOME}/backups"
USER_UNIT_DIR="${HOME}/.config/systemd/user"
SYSTEM_UNIT_DIR="/etc/systemd/system"

# firewall-check.sh and service-watch.sh call require_root, so their units
# belong to the system manager. Everything else runs unprivileged.
ROOT_UNITS=(firewall-check service-watch)
USER_UNITS=(sysinfo hostaudit log-analyzer backup)

# ---- render a unit file with this machine's paths ---------------------------
# The shipped units hard-code /home/ghaith. systemd runs units with no shell
# PATH and no working directory, so absolute paths are required -- they
# cannot be made relative, only rewritten at install time.
render_unit() {
    local src="$1"
    sed -e "s|/home/ghaith/linux-server-toolkit|${REPO_DIR}|g" \
        -e "s|/home/ghaith/backups|${BACKUP_DIR}|g" \
        "$src"
}

# ---- 1. make the scripts executable -----------------------------------------
# A missing execute bit shows up under systemd as 203/EXEC, which looks
# nothing like a script error. Set it here instead of relying on the clone.

log_info "making scripts executable"
chmod +x "${REPO_DIR}"/scripts/*.sh "${REPO_DIR}"/tests/*.sh "${REPO_DIR}/install.sh"

# ---- 2. install the two root units ------------------------------------------

log_info "installing root units (sudo required)"
sudo -v || die "sudo is required for the two root units"

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

# ---- 3. install the four user units -----------------------------------------

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
                              log-analyzer.timer backup.timer
log_ok "user timers enabled"

# ---- 4. keep the user manager alive without a login -------------------------
# Without linger the per-user systemd instance dies with the last session
# and the four user timers stop firing on an unattended server.

log_info "enabling linger for ${USER}"
sudo loginctl enable-linger "$USER"
log_ok "linger enabled"

# ---- 5. verify --------------------------------------------------------------
# Report what is actually scheduled, not what we think we installed.

log_info "verifying"

echo "--- root timers"
systemctl list-timers --no-pager firewall-check.timer service-watch.timer

echo "--- user timers"
systemctl --user list-timers --no-pager \
    sysinfo.timer hostaudit.timer log-analyzer.timer backup.timer

echo "--- linger"
loginctl show-user "$USER" -p Linger

log_ok "installation complete"
log_info "run one now without waiting:  sudo systemctl start firewall-check.service"
log_info "read its output with:         journalctl -u firewall-check.service --no-pager"
