# linux-server-toolkit

A homelab that I build in layers on one KVM host: Linux servers with real
jobs, built by hand first, then automated, then run with the tools teams use
in production (Terraform, Prometheus, Grafana, Docker, Kubernetes).

> **Status: v2.1 complete.** Two servers run today. `toolkit-lab` checks its
> own health and backs itself up. `backup-lab` is a receive-only backup
> server, built with one command, that keeps every backup out of reach of the
> machine that sent it and checks its stored backups every day. Next: v2.2.
> The [roadmap](#roadmap) grows the lab to five servers by v6.

## The Goal

To run Linux servers the way a real team does: know their state, protect
their data, rebuild them from code, and give every process only the access it
needs.

Each layer is built by hand before the standard tool replaces it: the v1
scripts check with Bash what Prometheus will measure, and `bootstrap.sh` does
step by step what Terraform will do.

## How It Works

All machines are KVM virtual machines on one host (`DimenstionX`, Fedora
Silverblue), each with a reserved address on libvirt's network.

| Machine | Job | Since |
|---|---|---|
| `toolkit-lab` | Workstation: the code, the checks, makes and sends backups | v1 |
| `backup-lab` | The vault: receives backups and keeps them | v2.0 |
| `monitor-lab` | Prometheus, Grafana and alerts | v3, planned |
| `app-lab` | Runs Readeck, a self-hosted article library, with PostgreSQL | v4, planned |
| `k8s-lab` | Kubernetes control plane; `app-lab` joins it as a worker | v6, planned |

```
 toolkit-lab                                   backup-lab
 backup.sh       daily:  archive + checksum
 backup-push.sh  hourly: send new pairs  --->  incoming      (write-only)
 backup-prune.sh daily:  remove old pairs      backup-mover  every 15 min:
                   that were sent                check, then store or reject
                                               vault         30 days,
                                                 the newest 7 always kept
                                               vault-verify  daily: check
                                                 every stored backup
```

Every script also runs on a systemd timer; these commands run them by hand.
`toolkit-lab` runs Ubuntu 24.04; the host needs KVM and libvirt.

```bash
# --- toolkit-lab, from the repo, as your normal user ---
./install.sh                                  # install the seven timers; the scripts root runs are copied to /usr/local/lib/linux-server-toolkit
./scripts/sysinfo.sh                          # short summary of the machine (daily)
./scripts/hostaudit.sh                        # health and security checks; exit 1 on a problem (daily)
./scripts/log-analyzer.sh                     # addresses that keep failing SSH logins (every 4h)
sudo systemctl start firewall-check.service   # is the firewall on, and does it match firewall/policy.conf (every 4h)
sudo systemctl start service-watch.service    # restart watched services that stopped (hourly)
sudo /usr/local/lib/linux-server-toolkit/scripts/firewall-apply.sh -n   # dry run: the ufw commands that make the firewall match the policy (by hand, without -n)
./scripts/backup.sh -s <folder> -d <dest>     # archive a folder, with a checksum file (daily)
./scripts/backup-prune.sh -d <dest> -m <markers> -n   # dry run: the old, sent backups it would remove (daily, without -n)
sudo systemctl start backup-push.service      # send new backups to backup-lab now (hourly)
systemctl --failed; systemctl --user --failed # every check that found a problem

# --- the host ---
bootstrap/bootstrap.sh <settings file>        # build backup-lab with one command

# --- backup-lab ---
sudo systemctl start backup-mover.service     # check what arrived and store it now (every 15 min)
sudo journalctl -u backup-mover.service | grep -E 'STORED|REJECTED|EXPIRED|LOW SPACE'   # what the vault did
sudo systemctl start vault-verify.service     # compare every stored backup with its checksum now (daily)
sudo journalctl -u vault-verify.service | grep -E 'VERIFIED|READ|FAILED'      # what the check found
sudo systemctl start firewall-check.service   # compare the firewall with the policy now (every 4h)
```

Rules the lab follows:

- **Least privilege.** The account that sends backups can only write new files
  into one folder. It cannot read, change or delete what is stored.
- **A human decides when trust changes.** A changed host key or a failed check
  stops the work; nothing accepts the change on its own.
- **Git holds the code, the vault holds the data.** What lives in the repo is
  rebuilt from the repo. The vault keeps only data that exists nowhere else.

## Roadmap

Each version has one goal and one exit gate, tested on the real machines. The
work, the tests and the reasons for the order are in
[docs/ROADMAP.md](docs/ROADMAP.md).

| Version | What it adds | State |
|---|---|---|
| v1 | Health, security and log checks in Bash, local backups, systemd timers, a one-command installer, shellcheck in CI | Done (v1.0-v1.2) |
| v2.0 | `backup-lab`: a receive-only backup server built with one command, and automatic sending from `toolkit-lab` | Done |
| v2.1 | Finish the backup chain: local retention, the mover checked in CI, a stop when the vault's disk is low on space, a daily check of the vault, tested restore steps | Done |
| v2.2 | Harden both servers: a firewall policy for incoming and outgoing connections, root's code out of the home, encryption before sending, an immutable vault, a CIS audit before and after | Next |
| v3 | Terraform builds `monitor-lab`; Prometheus, Grafana and alerts watch every machine | Planned |
| v4 | Readeck with PostgreSQL in Docker Compose on `app-lab`; its data goes into the vault | Planned |
| v5 | A CI/CD pipeline from GitHub to the lab | Planned |
| v6 | A Kubernetes cluster (`k8s-lab`, `app-lab`): Readeck moves to it with its data restored from the vault; a control panel opened from the host's browser | Planned |

After v6, improvements come as v6.x releases. A cloud version (v7) comes once
the lab is complete.

## Known Limits

- Both backup copies (on `toolkit-lab` and in the vault) sit on the same
  physical disk of the host. Accepted for now: the repo itself also lives on
  GitHub.
- `toolkit-lab` is not powered on every day; on days it is off, no backup is
  made.
- Nothing limits how much `toolkit-lab` can write into `incoming` until v4: if
  it were compromised it could fill the vault's disk. New backups would stop;
  the stored ones stay.

## Documentation

Each file answers one question, with a section per version:

- [docs/ROADMAP.md](docs/ROADMAP.md) -- what comes next: each version's goal,
  work and exit gate.
- [docs/NOTES.md](docs/NOTES.md) -- why: the decisions of each version, and the
  facts behind them.
- [docs/toolkit-lab-build.md](docs/toolkit-lab-build.md) and
  [docs/backup-lab-build.md](docs/backup-lab-build.md) -- how: the steps that
  build each machine.
- [docs/PROBLEMS.md](docs/PROBLEMS.md) -- what went wrong: one line per problem,
  with the fix.

## How This Was Built

I build this lab with Claude (an AI assistant) helping me draft code and
documentation. I base each decision on the official documentation, predict
the result of every change, run and test it on the lab's machines, and commit
only after it works.

## License

MIT. See [LICENSE](LICENSE).
