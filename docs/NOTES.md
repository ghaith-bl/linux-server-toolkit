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
- `loginctl enable-linger` starts the user manager at boot rather than at login,
  so that inheritance had to be re-checked on the boot path. It holds. Group
  membership comes from the system's user and group database, not from the login
  session: systemd initialises the supplementary group list from the user's
  entry when it spawns the per-user manager, so the same groups apply whether or
  not anyone logs in. Verified by rebooting, confirming the manager's start
  timestamp preceded any login (`uptime -s` against the `user@UID.service`
  `ActiveEnterTimestamp`), then reading the manager's own credentials with
  `grep '^Groups:' /proc/$(pgrep -u ghaith -x systemd)/status` -- `adm` (gid 4)
  was present. A manual run of the unit on that boot read `auth.log` and
  produced real findings, with no permission error. That same command re-checks
  the whole thing later without needing another reboot.
- **SSH is socket-activated here.** `ssh.service` is `disabled`, `ssh.socket` is
  `enabled` and holds port 22 with `Accept=no`. Ubuntu has shipped OpenSSH this
  way since 22.10. An inactive `ssh.service` is therefore the normal state on an
  idle box, not a fault -- see PROBLEMS.md #14 for what that cost me.
- `auditd` is not installed on this machine at all (`systemctl status auditd`
  returns "could not be found"). `hostaudit.sh` reports it as "not active",
  which is technically true but does not distinguish "installed and stopped"
  from "never installed". Since the check exits 1 either way,
  `hostaudit.service` is permanently in the failed state, which weakens the
  failed-unit-as-signal design below. Left as-is for v1; `secaudit.sh` in v2 is
  where auditd is actually dealt with.
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
  all six wired to systemd timers, plus `install.sh`. `checkfile.sh` and
  `checkmany.sh` predate the toolkit proper -- they are where the exit-code and
  loop patterns everything else uses were worked out. Everything else raised
  while planning is a v2 idea, tracked in the README Roadmap.
- **`install.sh` was pulled forward from v2 into v1.** The manual installation
  steps told the reader to `sed -i` the tracked unit files, which leaves every
  checkout permanently dirty and conflicting on the next `git pull`. The
  installer reads those files as templates and writes the rendered copies to
  the install directories instead, so the repo is never modified. It must be
  run as a normal user, not with `sudo`: running it as root would aim
  `systemctl --user` and `enable-linger` at root rather than at the operator.
- **`firewall-check.sh` is a separate script, not a function inside
  `hostaudit.sh`.** `ufw status` fails without root, so keeping it separate
  means every other script stays runnable -- and schedulable -- as a normal
  user with no elevated privileges at all.
- **`service-watch.sh` requires root for the whole script**, via
  `require_root()`, unlike `hostaudit.sh` which only guarded one check
  with `sudo -n`. Restarting a service is this script's entire purpose,
  not an occasional extra, so requiring root up front is more honest than
  trying to run most of it unprivileged.
- **`service-watch.sh` asks systemd whether a service is socket-activated
  before calling it broken.** `systemctl show <svc> -p TriggeredBy --value`
  lists the units that start a service on demand and is empty for an ordinary
  service, so an inactive service with a live trigger is idle by design. Three
  smaller decisions fall out of that:
  - Only the **first** trigger is restarted when every trigger is down. A
    service activated by both a socket and a path unit would leave the second
    one stopped. Accepted for v1; the case has not come up.
  - The restart counter is keyed on the **service** name even when the unit
    being restarted is a trigger. `SERVICES` is this script's unit of
    accounting, and keying on the trigger would create state files nothing
    ever reads.
  - Success is verified against the unit that was **restarted**, not against
    the service. A socket-activated service stays inactive after its socket
    comes back, and that is a success -- checking the service there would
    record a false failure and climb the counter.
- **`hostaudit.sh` checks system units only, not user units.**
  `systemctl --failed` without `--user` never sees the four user timers. Adding
  `--user` would be self-defeating: `hostaudit.service` is itself a user unit,
  so its own exit-1 from the previous run would keep it failed forever without
  a manual `reset-failed`. Reporting only system units is the lesser problem.
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
  archive, and does not check whether the destination sits inside the
  source.** It stays a fully generic tool (`-s`/`-d` only) with no assumption
  about what it is backing up. A general `-e <pattern>` exclude flag is a v2
  idea, not a Git-specific one.
- **`log-analyzer.sh` reads only the current `auth.log`, and only IPv4.**
  Rotation resets the counts, `auth.log.1` is never read, and an IPv6 source
  address does not match the extraction pattern so the line is skipped
  silently. Known v1 limitations rather than oversights -- writing them down is
  the point, since a silently skipped attacker is exactly the failure this
  script exists to prevent.
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
- **No `RandomizedDelaySec=` on the daily timers.** All three fire at 00:00,
  alongside the system's own `logrotate.timer` and `dpkg-db-backup.timer`. On a
  one-VM setup the load does not matter, but `logrotate` rotating `auth.log` at
  the same moment `log-analyzer.sh` reads it is a real race. Noted rather than
  fixed; the fix belongs with the wider timer review in v2.
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
  healthy again** -- whether a restart succeeded, it recovered on its own, or
  it turned out to be idle behind a live socket. The counter tracks
  *consecutive* failures only; leaving it set would mean the next real outage
  is reported as a crash loop without a single restart being attempted.
- **Unit files hard-code absolute paths under `/home/ghaith`.** systemd runs
  units in a clean environment with no shell `PATH` or working directory to
  fall back on, so absolute paths are required. `install.sh` rewrites them at
  install time for whatever checkout location and username it finds.
