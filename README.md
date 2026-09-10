# linux-server-toolkit

A small set of Bash scripts that monitor and maintain a Linux server, scheduled
with systemd timers.

> Status: **v1 complete.** Six scripts, all wired to systemd timers and tested
> on the target machine, plus a one-command installer. See the Roadmap for what
> is deliberately *not* in v1. I built it step by step and wrote down what I
> learned, including the parts where I was wrong.

## The Problem This Solves

A small server does not tell you when something goes wrong. A disk fills up, a
service stops at 3 AM, or someone tries to brute force SSH, and nobody notices
until a user complains the next morning.

Tools like Prometheus or Nagios solve this well, but they are heavy for one or
two servers, and they hide the basics behind a dashboard. I wanted to understand
what is actually being checked.

This toolkit does the basic job with plain Bash and systemd, which are already
installed on every Linux server. No agent, no database, no extra packages.

## Architecture

```
                        systemd timers
                              |
        +---------------------+---------------------+
        |                                           |
  system units (root)                       user units (normal)
  firewall-check    every 4h                sysinfo         daily
  service-watch     hourly                  hostaudit       daily
                                            log-analyzer    every 4h
                                            backup          daily
        |                                           |
        +---------------------+---------------------+
                              v
                        lib/common.sh
            logging, colors, require_cmd, require_root
```

No script hardcodes a log path. Each one writes data to stdout and timestamped
messages to stderr; the caller decides where that goes. Wired to a timer,
systemd's own journal captures and rotates each script's output automatically
(`journalctl -u <unit>`).

`firewall-check.sh` and `service-watch.sh` are the only scripts that need root
(both use `require_root`) -- every other script runs as a normal user with no
elevated privileges at all.

No shared config file -- each script keeps its own defaults (see
[docs/NOTES.md](docs/NOTES.md)).

## Features

- **`sysinfo.sh`** -- machine summary: hostname, kernel, arch, uptime, cores,
  memory and root disk usage, as `key=value` lines on stdout.
- **`hostaudit.sh`** -- health & security snapshot: failed systemd services,
  `auditd` status, zombie processes, listening TCP/UDP ports, AppArmor status,
  and disk usage on `/`. Exits `1` if any check flags a problem.
- **`log-analyzer.sh`** -- parses `auth.log`, groups rejected SSH login attempts
  by source IP, and flags any IP crossing a repeat-attempt threshold.
- **`firewall-check.sh`** -- reports whether `ufw` is active and lists its
  current rules. Needs root.
- **`service-watch.sh`** -- checks `ssh`, `cron` and `systemd-resolved`, and
  restarts any that stopped. Understands socket activation: a service that is
  idle behind a live socket is not treated as broken, and when the socket
  itself is down it is the socket that gets restarted. Stops retrying after 3
  consecutive failures and reports a likely crash loop instead. Needs root.
- **`backup.sh`** -- `tar.gz` backup of any directory into any destination
  (`-s` / `-d`). Builds into a `mktemp` file next to the destination and moves
  it into place only on success, so a failed or interrupted run never leaves a
  half-written archive behind.

`scripts/checkfile.sh` and `scripts/checkmany.sh` predate the toolkit proper --
they are where the exit-code and loop patterns everything else uses were worked
out, kept here because the rest of the code still follows them.

## Requirements

Ubuntu 24.04 (developed and tested there). `bash`, `systemd`, `tar`, plus `ufw`
and `auditd`-aware tooling for the security checks. No third-party packages.

## Installation

```bash
git clone git@github.com:ghaith-bl/linux-server-toolkit.git
cd linux-server-toolkit
./install.sh
```

Run it as your normal user, **not** with `sudo` -- it calls `sudo` itself for
the two root units. Running the whole thing as root would aim
`systemctl --user` and `enable-linger` at root instead of you.

The installer sets the execute bits, rewrites the unit files' absolute paths
for your own checkout and username, installs the two root units into
`/etc/systemd/system` and the four user units into `~/.config/systemd/user`,
enables all six timers, turns on lingering so the user timers keep firing with
nobody logged in, and prints the resulting schedule.

The repo's own unit files are read as templates and never modified, so your
working tree stays clean.

## Usage

Every script runs standalone, independently of systemd:

```bash
$ sudo ./scripts/service-watch.sh
[2026-09-09 11:35:33] INFO  watching 3 service(s)...
[2026-09-09 11:35:33] OK    ssh is running
[2026-09-09 11:35:33] OK    cron is running
[2026-09-09 11:35:33] OK    systemd-resolved is running
[2026-09-09 11:35:33] OK    all services are running
$ echo $?
0

$ ./scripts/backup.sh -s ~/linux-server-toolkit -d ~/backups
[2026-09-09 15:43:42] INFO  Creating archive from /home/ghaith/linux-server-toolkit ...
[2026-09-09 15:43:42] OK    Backup created: /home/ghaith/backups/backup-linux-server-toolkit-20260909-154342.tar.gz
```

See each script's header comment for its exact usage and exit codes. `stdout`
carries data only; `stderr` carries the timestamped log lines.

A check that finds a real problem exits non-zero, so systemd marks its unit
failed on purpose -- `systemctl --failed` and `systemctl --user --failed` list
every check currently reporting something.

## Configuration

There is no shared config file, on purpose -- see [docs/NOTES.md](docs/NOTES.md)
for why. Each script keeps its own defaults near the top of its file (for
example `service-watch.sh`'s `SERVICES` array and `MAX_RESTARTS`, or
`log-analyzer.sh`'s `THRESHOLD`).

## Problems I Hit and How I Solved Them

Real problems, written down the day they happened -- see
[docs/PROBLEMS.md](docs/PROBLEMS.md).

## What I Learned

Facts about the environment and the decisions behind them -- see
[docs/NOTES.md](docs/NOTES.md).

## Roadmap

v1 is closed. These are deliberately out of scope for it:

- A dedicated, isolated backup server (a second VM reachable only for backup
  transfer), with rotation and retention policy attached to it.
- A general `-e <pattern>` exclude flag for `backup.sh`.
- `secaudit.sh` -- file permission checks and real `auditd` rule/log analysis
  (`auditctl`, `ausearch`, `aureport`), including telling "not installed" apart
  from "installed but stopped".
- Actual *automated* IP blocking via `ufw`, triggered by the repeat offenders
  `log-analyzer.sh` already detects.
- IPv6 support and rotated-log reading in `log-analyzer.sh`.
- `RandomizedDelaySec=` on the timers, so the three daily units stop firing at
  exactly 00:00 alongside the system's own logrotate.
- Move SSH off port 22, as an extra hardening layer.
- An expected-ports whitelist in `hostaudit.sh`'s `check_ports()`, once indexed
  arrays are covered.
- Feed `hostaudit.sh`'s results into Prometheus via node_exporter's textfile
  collector, if full metrics monitoring is ever worth the extra moving parts.

## License

MIT. See [LICENSE](LICENSE).
