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
- **`firewall-check.sh` is a separate script, not a function inside
  `hostaudit.sh`.** It is the only script in the toolkit that genuinely
  needs root (`ufw status` fails without it), so it is the only one that
  uses `common.sh`'s `require_root()`. Keeping it separate means every
  other script stays runnable -- and eventually schedulable via systemd --
  as a normal user with no elevated privileges at all.
- **`service-watch.sh` requires root for the whole script**, via
  `require_root()`, unlike `hostaudit.sh` which only guarded one check
  with `sudo -n`. Restarting a service is this script's entire purpose,
  not an occasional extra, so requiring root up front (like
  `firewall-check.sh`) is more honest than trying to run most of it
  unprivileged.


- **`backup.sh` writes to a local destination only (`~/backups`), no network
  transfer.** A dedicated, isolated backup server reachable only over a
  restricted connection is a stronger design, but it pulls in SSH key
  management, retry/timeout handling, and a second VM -- real scope, not a
  small addition. Tracked as a v2 idea in the README Roadmap.
- **No rotation/retention in v1, even though the systemd timer runs
  `backup.sh` daily.** Each run just adds a new archive; nothing deletes old
  ones. Accepted deliberately for v1: the timer only runs once a day, so the
  exposure window before v2 (which pairs rotation with the move to a
  dedicated backup server) is short, and retention policy is easier to design
  correctly once the final storage location is settled, not before.
- **`backup.sh`'s temp file lives in the destination directory, not `/tmp`.**
  `mktemp` still guarantees a unique, non-guessable name, but placing it
  alongside the final archive means the closing `mv` is an atomic rename on
  the same filesystem, not a cross-filesystem copy. `/tmp` was ruled out for
  the same reason it was ruled out for test fixtures earlier: it does not
  survive a reboot.
- **`backup.sh` does not exclude `.git/` or any other pattern from the
  archive.** It stays a fully generic tool (`-s`/`-d` only) with no assumption
  about what kind of directory it is backing up. A general `-e <pattern>`
  exclude flag is a v2 idea, not a Git-specific one -- tracked in the README
  Roadmap.









