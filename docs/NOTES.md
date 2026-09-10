# Notes and Decisions

Facts about this environment and decisions about the project's direction,
as opposed to [PROBLEMS.md](PROBLEMS.md), which is about things that went
wrong and how they were fixed.

## Environment

- `/var/log/auth.log` is owned by `syslog:adm` with mode `640`. My user is in the
  `adm` group, so scripts can read it without `sudo`. Least privilege by default.
  I originally assumed the systemd unit would need `SupplementaryGroups=adm` to
  match. It does not, and it could not: `log-analyzer.sh` ended up as a *user*
  unit, and an unprivileged user service manager has no permission to change
  group credentials -- `User=`, `Group=` and `SupplementaryGroups=` all fail
  there with `Operation not permitted`. It works because the per-user systemd
  instance already inherits my own groups, `adm` included.
- **Untested:** `loginctl enable-linger` means the user manager now starts at
  boot instead of at login. Whether `adm` is still inherited on that path has
  only been verified while logged in. Reboot without logging in and check that
  `log-analyzer.service` still reads `auth.log` -- this is the one assumption
  in v1 that has not been checked against reality.
- I chose the normal Ubuntu Server install over "minimized". The minimized image
  drops packages meant for automated images, including `rsyslog`. Without
  `rsyslog` there is no `/var/log/auth.log` at all, which would have broken the
  whole log analyzer before I wrote a line of it.
- I installed none of the featured snaps. Every package added by the installer is
  a hidden assumption that is written down nowhere.
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
- **v1 scope, as actually delivered:** `sysinfo.sh`, `hostaudit.sh`,
  `log-analyzer.sh`, `firewall-check.sh`, `service-watch.sh` and `backup.sh`,
  all six wired to systemd timers, plus the `getopts` / `mktemp`+`trap` /
  `set -euo pipefail`-limits study session that `backup.sh` needed along the
  way. `checkfile.sh` and `checkmany.sh` predate the toolkit proper -- they are
  where the exit-code and loop patterns everything else uses were worked out.
  Everything else raised while planning is a v2 idea, tracked in the README
  Roadmap.
- **`firewall-check.sh` is a separate script, not a function inside
  `hostaudit.sh`.** `ufw status` fails without root, so keeping it separate
  means every other script stays runnable -- and schedulable -- as a normal
  user with no elevated privileges at all.
- **`service-watch.sh` requires root for the whole script**, via
  `require_root()`, unlike `hostaudit.sh` which only guarded one check
  with `sudo -n`. Restarting a service is this script's entire purpose,
  not an occasional extra, so requiring root up front is more honest than
  trying to run most of it unprivileged.
- **`backup.sh` writes to a local destination only (`~/backups`), no network
  transfer.** A dedicated, isolated backup server reachable only over a
  restricted connection is a stronger design, but it pulls in SSH key
  management, retry/timeout handling, and a second VM -- real scope, not a
  small addition. Tracked as a v2 idea in the README Roadmap.
- **No rotation/retention in v1, even though the timer runs `backup.sh`
  daily.** Each run just adds a new archive; nothing deletes old ones.
  Accepted deliberately: the timer only runs once a day, so the exposure
  window before v2 (which pairs rotation with the move to a dedicated backup
  server) is short, and a retention policy is easier to design correctly once
  the final storage location is settled, not before.
- **`backup.sh`'s temp file lives in the destination directory, not `/tmp`.**
  `mktemp` still guarantees a unique, non-guessable name, but placing it
  alongside the final archive means the closing `mv` is an atomic rename on
  the same filesystem, not a cross-filesystem copy. `/tmp` was ruled out for
  the same reason it was ruled out for test fixtures earlier: it does not
  survive a reboot.
- **`backup.sh` does not exclude `.git/` or any other pattern from the
  archive.** It stays a fully generic tool (`-s`/`-d` only) with no assumption
  about what kind of directory it is backing up. A general `-e <pattern>`
  exclude flag is a v2 idea, not a Git-specific one.
- **`hostaudit.sh` and `log-analyzer.sh` showing "failed" under `systemctl
  status` when they find a real problem is intentional, not a bug.** Both exit
  1 when a check finds something worth flagging (`auditd` inactive, an IP
  crossing the SSH-attempt threshold) -- the same exit-code-as-signal pattern
  used since `checkfile.sh`. systemd reads any non-zero exit as a failed unit,
  so a "failed" `.service` doubles as a visible signal: `systemctl --failed`
  surfaces every check that found a problem, without opening individual logs.
- **Timer intervals are not uniform.** `service-watch.sh` (auto-recovery) runs
  hourly; `log-analyzer.sh` and `firewall-check.sh` (security-relevant
  detection) run every 4 hours; `hostaudit.sh`, `sysinfo.sh` and `backup.sh`
  (snapshot/backup, no recovery role) run daily. Scripts that detect or recover
  from a problem benefit from a short exposure window; scripts that just record
  a snapshot don't. Each `.timer` carries its own `OnCalendar` -- not a shared
  config, consistent with the decision against `config/toolkit.conf`.
- **The `.service` files carry no `[Install]` section.** For a timer-driven
  unit it is the `.timer` that gets enabled, not the `.service`; systemd's own
  documentation and the Arch wiki both note the service does not need one.
  Leaving a stray `[Install]` on `backup.service` was why it reported
  `disabled` while every sibling reported `static`.
- **`service-watch.sh`'s restart-attempt state lives in
  `/var/lib/linux-server-toolkit/service-watch/`, not under the repo.**
  The script always runs as root (`require_root`), so any state file it writes
  would end up root-owned. Writing root-owned files into a normal user's
  directory is the same "sudo silently creates root-owned files" trap noted
  above. `/var/lib` is the standard location for a service's persistent state.
- **The restart-attempt counter resets to 0 the moment a service is seen
  running again**, whether a restart succeeded or it recovered on its own. The
  counter only tracks *consecutive* failures -- an intermittently flapping
  service and a hard crash loop are treated the same by design; telling them
  apart needs timestamps, not just a count, which was more precision than v1
  needed.
- **Unit files hard-code absolute paths under `/home/ghaith`.** systemd runs
  units in a clean environment with no shell `PATH` or working directory to
  fall back on, so absolute paths are required. Installing under a different
  user means rewriting them -- the README's Installation section does this with
  `sed`. A real `install.sh` is a v2 item.
