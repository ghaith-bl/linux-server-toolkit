# Notes and Decisions

Facts about this environment and decisions about the project's direction,
as opposed to [PROBLEMS.md](PROBLEMS.md), which is about things that went
wrong and how they were fixed.

## Environment

- `/var/log/auth.log` is owned by `syslog:adm` with mode `640`. My user is in the
  `adm` group, so scripts can read it without `sudo`. Least privilege by default.
  This will matter when I write the systemd unit: running as a normal user will
  need `SupplementaryGroups=adm`.
- I chose the normal Ubuntu Server install over "minimized". The minimized image
  drops packages meant for automated images, including `rsyslog`. Without
  `rsyslog` there is no `/var/log/auth.log` at all, which would have broken the
  whole log analyzer before I wrote a line of it.
- I installed none of the featured snaps. Every package added by the installer is
  a hidden assumption that is written down nowhere. The goal is that `install.sh`
  sets up everything on a clean system.
- The repo lives on the VM, not on my laptop. These scripts read
  `/var/log/auth.log` and call `systemctl` on Ubuntu services. My laptop runs
  Fedora Silverblue, so none of them could actually be tested there. The VM is
  disposable because every commit is pushed to GitHub.

## Project decisions

- **No shared `config/toolkit.conf`.** The only candidate values so far
  (`hostaudit.sh`'s 80% disk threshold, and whichever services
  `service-watch.sh` ends up watching) are each used by exactly one script --
  there is nothing to actually share yet. A shared file would mean either
  `source`-ing arbitrary code into every script or writing a parser, for no
  real benefit. Closed, not just deferred; revisit only if a value is
  genuinely needed by more than one script.
- **v1 scope is fixed.** `hostaudit.sh` (done), `log-analyzer.sh`,
  `service-watch.sh`, `backup.sh`, all four wired to systemd timers, plus the
  `getopts` / `mktemp`+`trap` / `set -euo pipefail`-limits study session that
  `backup.sh` needs along the way. Everything else raised while planning
  (`secaudit.sh`, real IP blocking via `ufw`, Prometheus integration, a ports
  whitelist) is a v2 idea -- tracked in the README Roadmap, not built until
  v1 is finished.
