# linux-server-toolkit

A small set of Bash scripts that monitor and maintain a Linux server, scheduled
with systemd timers.

> Status: **v1 complete.** Six scripts, all wired to systemd timers and tested
> on the target machine. See the Roadmap for what is deliberately *not* in v1.
> I built it step by step and wrote down what I learned, including the parts
> where I was wrong.

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
  restarts any that stopped. Stops retrying after 3 consecutive failures and
  reports a likely crash loop instead. Needs root.
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

The unit files ship with absolute paths under `/home/ghaith` -- systemd runs
units in a clean environment, so absolute paths are required. Step 2 rewrites
them for your own checkout. There is no `install.sh` yet (see Roadmap).

**1. Clone and make the scripts executable:**

```bash
git clone git@github.com:ghaith-bl/linux-server-toolkit.git
cd linux-server-toolkit
chmod +x scripts/*.sh tests/*.sh
```

**2. Point the unit files at your own paths:**

```bash
sed -i "s|/home/ghaith/linux-server-toolkit|$PWD|g" systemd/*.service
sed -i "s|/home/ghaith/backups|$HOME/backups|g"     systemd/backup.service
```

**3. Install the two root units:**

```bash
sudo cp systemd/firewall-check.* systemd/service-watch.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now firewall-check.timer service-watch.timer
```

**4. Install the four user units:**

```bash
mkdir -p ~/.config/systemd/user
cp systemd/sysinfo.* systemd/hostaudit.* systemd/log-analyzer.* systemd/backup.* \
   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sysinfo.timer hostaudit.timer log-analyzer.timer backup.timer
```

**5. Keep the user timers alive without an active login:**

```bash
sudo loginctl enable-linger "$USER"
```

Without this the per-user systemd instance is killed when the last session
closes, and the user timers stop firing.

**6. Verify:**

```bash
systemctl list-timers                          # root units
systemctl --user list-timers                   # user units
sudo systemctl start firewall-check.service    # run one now, don't wait
journalctl -u firewall-check.service --no-pager
```

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

- `install.sh` -- replace the manual `sed`-and-copy installation above with a
  single script that resolves paths, deploys both unit sets, and verifies.
- A dedicated, isolated backup server (a second VM reachable only for backup
  transfer), with rotation and retention policy attached to it.
- A general `-e <pattern>` exclude flag for `backup.sh`.
- `secaudit.sh` -- file permission checks and real `auditd` rule/log analysis
  (`auditctl`, `ausearch`, `aureport`).
- Actual *automated* IP blocking via `ufw`, triggered by the repeat offenders
  `log-analyzer.sh` already detects.
- Move SSH off port 22, as an extra hardening layer.
- An expected-ports whitelist in `hostaudit.sh`'s `check_ports()`, once indexed
  arrays are covered.
- Feed `hostaudit.sh`'s results into Prometheus via node_exporter's textfile
  collector, if full metrics monitoring is ever worth the extra moving parts.

## License

MIT. See [LICENSE](LICENSE).


    
