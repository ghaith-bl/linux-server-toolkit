# shellcheck shell=sh
#
# linux-server-toolkit: what every login shell starts with (CIS, v2.2).
#
# install.sh copies this file to /etc/profile.d/. /etc/profile reads that
# folder when someone logs in: over SSH, on the console, with "sudo -i".
# A command sent over SSH (scp, rsync, "ssh machine command") does not
# read it. The reasons are in docs/NOTES.md (v2.2).

# New files are made with no rights for "others" (640, folders 750).
umask 027
