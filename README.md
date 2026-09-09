# linux-server-toolkit

A small set of Bash scripts that monitor and maintain a Linux server, scheduled with systemd timers.

> Status: work in progress. I am building this step by step and writing down what I learn, including the parts where I was wrong.

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
themselves. All settings live in one config file.

## Architecture

<!-- TODO: update this diagram as the scripts get written -->

```
        systemd timers (planned)
              |
              v
    +----------------------------+
    |          scripts/          |
    |  hostaudit.sh   -- done    |
    |  service-watch.sh -- TODO  |
    |  log-analyzer.sh  -- TODO  |
    |  backup.sh         -- TODO |
    +--------------+-------------+
                   |
                   v
             lib/common.sh
      logging, colors, require_cmd, require_root

No script hardcodes a log path. Each one writes data to stdout and
timestamped messages to stderr; the caller decides where that goes.
Once a script is wired to a systemd timer, systemd's own journal
captures and rotates its output automatically (journalctl -u <unit>).

config/toolkit.conf is still just an idea -- see Roadmap.
```

Nothing runs on a schedule by itself yet. Scripts are run by hand for now;
systemd timers will start them once more of the toolkit exists.

## Features

- **`hostaudit.sh`** -- a quick host health & security snapshot: failed
  systemd services, `auditd` status, zombie processes, listening TCP/UDP
  ports, AppArmor status, and disk usage on `/`. Each check logs OK or
  WARN, and the script's own exit code (`0`/`1`) reflects whether anything
  needs attention.

## Installation

<!-- TODO: after install.sh is written -->

## Usage

```bash
$ ./scripts/hostaudit.sh
[2026-09-09 07:06:22] INFO  starting host audit...
[2026-09-09 07:06:22] OK    no failed services
[2026-09-09 07:06:22] WARN  auditd is not active
[2026-09-09 07:06:22] OK    no zombie processes
[2026-09-09 07:06:22] INFO  found 7 listening port(s):
tcp    LISTEN    0    4096    0.0.0.0:22    0.0.0.0:*
...
[2026-09-09 07:06:22] OK    AppArmor is enabled with policy loaded
[2026-09-09 07:06:22] OK    disk usage on / is at 45%
[2026-09-09 07:06:22] ERROR 1 check(s) reported a problem

$ echo $?
1
```

`stdout` carries data only (like the port list); `stderr` carries the
timestamped log lines. Redirect them separately if you only want one,
e.g. `./scripts/hostaudit.sh > report.txt` keeps just the data.

## Configuration

<!-- TODO: explain every option in config/toolkit.conf, once it exists -->

## Problems I Hit and How I Solved Them

Real problems, written down the day they happened -- see [docs/PROBLEMS.md](docs/PROBLEMS.md).

## What I Learned

Facts about the environment and decisions behind them -- see [docs/NOTES.md](docs/NOTES.md).

## Roadmap

<!-- TODO: any idea that is out of scope goes here, not into the code -->

- Hook `hostaudit.sh` up to a systemd timer once the rest of the toolkit scripts
  are ready.
- `secaudit.sh` -- a separate, deeper security-audit script: file permission
  checks, failed SSH login attempts from the logs, and real `auditd` rule/log
  analysis (`auditctl`, `ausearch`, `aureport`) -- too big a topic to fold into
  `hostaudit.sh`.
- Add an expected-ports whitelist to `check_ports()` once indexed arrays are
  covered.
- Decide whether `config/toolkit.conf` is worth building, or whether each
  script's own hardcoded defaults (like `hostaudit.sh`'s 80% disk threshold)
  are good enough for a one- or two-server setup.
- Longer term: feed `hostaudit.sh`'s results into Prometheus via node_exporter's
  textfile collector, if full metrics monitoring is ever worth the extra moving
  parts.

## License

MIT. See [LICENSE](LICENSE).
