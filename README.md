# linux-server-toolkit

A small set of Bash scripts that monitor and maintain a Linux server, scheduled with systemd timers.

> Status: work in progress on v1. v1 is `hostaudit.sh` (done), `log-analyzer.sh`
> (done), `firewall-check.sh` (done, small addition -- see Roadmap), `service-watch.sh`,
> and `backup.sh`, all wired to systemd timers -- see Roadmap below for exactly
> what is (and is not) in scope. I am building it step by step and writing down
> what I learn, including the parts where I was wrong.

## The Problem This Solves

A small server does not tell you when something goes wrong. A disk fills up, a
service stops at 3 AM, or someone tries to brute force SSH, and nobody notices
until a user complains the next morning.

Tools like Prometheus or Nagios solve this well, but they are heavy for one or
two servers, and they hide the basics behind a dashboard. I wanted to understand
what is actually being checked.

This toolkit does the basic job with plain Bash and systemd, which are already
installed on every Linux server. No agent, no database, no extra packages.

It checks system health, watches services and restarts them if they stop, reads
`auth.log` for failed SSH logins, and takes backups that clean up after
themselves. Each script keeps its own defaults; nothing here needs a shared
config file to run.

## Architecture

<!-- TODO: update this diagram as the scripts get written -->

```
        systemd timers (v1 -- wired once all scripts exist)
              |
              v
    +------------------------------+
    |           scripts/           |
    |  hostaudit.sh      -- done   |
    |  log-analyzer.sh   -- done   |
    |  firewall-check.sh -- done   |
    |  service-watch.sh  -- next   |
    |  backup.sh          -- TODO  |
    +--------------+---------------+
                   |
                   v
             lib/common.sh
      logging, colors, require_cmd, require_root

No script hardcodes a log path. Each one writes data to stdout and
timestamped messages to stderr; the caller decides where that goes.
Once wired to a systemd timer, systemd's own journal captures and
rotates each script's output automatically (journalctl -u <unit>).

firewall-check.sh is the only script that needs root (it uses
require_root and must be run with sudo) -- every other script runs
as a normal user with no elevated privileges at all.

No shared config file -- each script keeps its own defaults (see NOTES.md).
```

## Features

- **`hostaudit.sh`** -- a quick host health & security snapshot: failed
  systemd services, `auditd` status, zombie processes, listening TCP/UDP
  ports, AppArmor status, and disk usage on `/`. Each check logs OK or
  WARN, and the script's own exit code (`0`/`1`) reflects whether anything
  needs attention.
- **`log-analyzer.sh`** -- parses `auth.log`, groups rejected SSH login
  attempts by source IP, and flags any IP that crosses a repeat-attempt
  threshold.
- **`firewall-check.sh`** -- reports whether `ufw` is active and lists its
  current rules. The only script here that needs root.

## Installation

<!-- TODO: after install.sh is written -->

## Usage

```bash
$ ./scripts/hostaudit.sh
[2026-09-09 07:06:22] INFO  starting host audit...
[2026-09-09 07:06:22] OK    no failed services
[2026-09-09 07:06:22] WARN  auditd is not active
...
[2026-09-09 07:06:22] ERROR 1 check(s) reported a problem
$ echo $?
1
```

```bash
$ ./scripts/log-analyzer.sh
[2026-09-09 10:34:40] INFO  scanning /var/log/auth.log for SSH login attempts...
[2026-09-09 10:34:40] INFO  192.168.122.1: 2 attempt(s)
[2026-09-09 10:34:40] WARN  192.168.122.14: 3 attempt(s) -- repeat offender
[2026-09-09 10:34:40] ERROR at least one IP crossed the threshold (3)
$ echo $?
1
```

```bash
$ sudo ./scripts/firewall-check.sh
[2026-09-09 11:05:32] INFO  checking firewall status...
[2026-09-09 11:05:32] OK    ufw is active
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp (OpenSSH)           ALLOW IN    Anywhere
22/tcp (v6)                ALLOW IN    Anywhere (v6)
```

`stdout` carries data only; `stderr` carries the timestamped log lines.
Redirect them separately if you only want one, e.g.
`./scripts/hostaudit.sh > report.txt` keeps just the data.

## Configuration

There is no shared config file, on purpose -- see [docs/NOTES.md](docs/NOTES.md)
for why. Each script keeps its own defaults near the top of its file.

## Problems I Hit and How I Solved Them

Real problems, written down the day they happened -- see [docs/PROBLEMS.md](docs/PROBLEMS.md).

## What I Learned

Facts about the environment and decisions behind them -- see [docs/NOTES.md](docs/NOTES.md).

## Roadmap

**Remaining for v1:**

- `service-watch.sh` -- watch a list of services and restart them if they
  stop. (Next script.)
- `backup.sh` -- `tar`/`rsync`, timestamped filenames, and a retention
  policy that deletes old copies.
- A short study session on `getopts`, `mktemp` + `trap`, and the real
  limits of `set -euo pipefail` -- needed before/while writing `backup.sh`.
- Wire all five scripts to systemd timers. `firewall-check.sh` will need
  its own unit running as root; everything else runs as the normal user.

**v2 ideas (deliberately out of scope until v1 is done):**

- `secaudit.sh` -- file permission checks and real `auditd` rule/log
  analysis (`auditctl`, `ausearch`, `aureport`).
- Actual *automated* IP blocking via `ufw`, triggered by the repeat
  offenders `log-analyzer.sh` already detects in v1. (Static, hand-reviewed
  `ufw` rules are done as of `firewall-check.sh`; this item is specifically
  about a script writing new rules on its own from log data.)
- Move SSH off port 22 to a random port, as an extra hardening layer.
- Add an expected-ports whitelist to `hostaudit.sh`'s `check_ports()`
  once indexed arrays are covered.
- Feed `hostaudit.sh`'s results into Prometheus via node_exporter's
  textfile collector, if full metrics monitoring is ever worth the extra
  moving parts.

## License

MIT. See [LICENSE](LICENSE).
