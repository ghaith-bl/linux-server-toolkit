# linux-server-toolkit

A small set of Bash scripts that monitor and maintain a Linux server, scheduled with systemd timers.

> Status: work in progress on v1. Done: `hostaudit.sh`, `log-analyzer.sh`,
> `firewall-check.sh`, `service-watch.sh`. Left: `backup.sh`, then wiring
> everything to systemd timers -- see Roadmap for exactly what is (and is
> not) in scope. I am building it step by step and writing down what I
> learn, including the parts where I was wrong.

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
    |  service-watch.sh  -- done   |
    |  backup.sh          -- next  |
    +--------------+---------------+
                   |
                   v
             lib/common.sh
      logging, colors, require_cmd, require_root

No script hardcodes a log path. Each one writes data to stdout and
timestamped messages to stderr; the caller decides where that goes.
Once wired to a systemd timer, systemd's own journal captures and
rotates each script's output automatically (journalctl -u <unit>).

firewall-check.sh and service-watch.sh are the only scripts that need
root (both use require_root) -- every other script runs as a normal
user with no elevated privileges at all.

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
  current rules. Needs root.
- **`service-watch.sh`** -- checks a list of services (`ssh`, `cron`,
  `systemd-resolved`) and restarts any that stopped. Needs root.

## Installation

<!-- TODO: after install.sh is written -->

## Usage

```bash
$ sudo ./scripts/service-watch.sh
[2026-09-09 11:35:33] INFO  watching 3 service(s)...
[2026-09-09 11:35:33] OK    ssh is running
[2026-09-09 11:35:33] OK    cron is running
[2026-09-09 11:35:33] OK    systemd-resolved is running
[2026-09-09 11:35:33] OK    all services are running
$ echo $?
0
```

See each script's own header comment for its exact usage and exit codes.
`stdout` carries data only; `stderr` carries the timestamped log lines.

## Configuration

There is no shared config file, on purpose -- see [docs/NOTES.md](docs/NOTES.md)
for why. Each script keeps its own defaults near the top of its file
(for example, `service-watch.sh`'s `SERVICES` array).

## Problems I Hit and How I Solved Them

Real problems, written down the day they happened -- see [docs/PROBLEMS.md](docs/PROBLEMS.md).

## What I Learned

Facts about the environment and decisions behind them -- see [docs/NOTES.md](docs/NOTES.md).

## Roadmap

**Remaining for v1:**

- `backup.sh` -- `tar`/`rsync`, timestamped filenames, and a retention
  policy that deletes old copies. (Next script.)
- A short study session on `getopts`, `mktemp` + `trap`, and the real
  limits of `set -euo pipefail` -- needed before/while writing `backup.sh`.
- Wire all five scripts to systemd timers. `firewall-check.sh` and
  `service-watch.sh` need units running as root; the rest run as the
  normal user.
- `service-watch.sh` has no limit on restart attempts and no memory
  between runs -- a service stuck in a real crash loop gets restarted
  silently forever, with no escalation. Needs state between runs (a
  marker file, most likely), which fits naturally with the `mktemp`
  session above.

**v2 ideas (deliberately out of scope until v1 is done):**

- `secaudit.sh` -- file permission checks and real `auditd` rule/log
  analysis (`auditctl`, `ausearch`, `aureport`).
- Actual *automated* IP blocking via `ufw`, triggered by the repeat
  offenders `log-analyzer.sh` already detects in v1.
- Move SSH off port 22 to a random port, as an extra hardening layer.
- Add an expected-ports whitelist to `hostaudit.sh`'s `check_ports()`
  once indexed arrays are covered.
- Feed `hostaudit.sh`'s results into Prometheus via node_exporter's
  textfile collector, if full metrics monitoring is ever worth the extra
  moving parts.

## License

MIT. See [LICENSE](LICENSE).
