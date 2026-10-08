# Roadmap

What each version builds, how it is tested, and why it comes in that order.
The README holds the short table; this page is the reference.

```mermaid
flowchart LR
    v1["v1<br/>checks in Bash<br/>toolkit-lab"]:::done
    v20["v2.0<br/>the vault<br/>backup-lab"]:::done
    v21["v2.1<br/>finish the<br/>backup chain"]:::done
    v22["v2.2<br/>harden both<br/>servers"]:::next
    v3["v3<br/>Terraform +<br/>monitoring<br/>monitor-lab"]
    v4["v4<br/>first real service<br/>app-lab"]
    v5["v5<br/>CI/CD"]
    v6["v6<br/>Kubernetes +<br/>control panel<br/>k8s-lab"]
    v1 --> v20 --> v21 --> v22 --> v3 --> v4 --> v5 --> v6
    classDef done fill:#d8f0dc,stroke:#2e7d32,color:#000
    classDef next fill:#fff1c2,stroke:#a66f00,color:#000
```

Green: done. Yellow: next.

## How a Version Is Decided

1. **One goal**, in one sentence.
2. **One exit gate**: a test on the real machines that proves the goal.
3. **Order by need**: a version comes after everything it depends on.
4. **An item joins a version only if it serves that goal** and fixes a real
   problem in this lab. Anything else waits as a later improvement, or is
   dropped.

## v2.1: Finish the backup chain

Done on 2026-10-03: the exit gate passed on the real machines.

**Goal:** every backup can be restored, and no part of the chain can fill up or
break unseen.

- Retention for the local copy on `toolkit-lab`: 15 days, the newest 7 always
  kept. It never removes a backup that was not sent yet.
- The vault mover checked by the CI, like the other scripts.
- The mover stops taking backups, and fails, when the data disk is low on
  space.
- A daily check of the vault: every backup compared with its checksum, the
  newest one read to its end.
- The restore steps written in the build guide and run once: a backup brought
  back from the vault to `toolkit-lab`.

**Exit gate:** a backup restored from the vault to `toolkit-lab` matches its
checksum; the daily check passes on the real vault; the local retention removes
an old backup that was sent and keeps one that was not; the CI checks the
mover. The low-space stop and a damaged backup are tested on a throwaway
machine, never on the vault.

**Why first:** v2.2 changes the chain (encryption, an immutable vault). The
daily check and the restore steps of v2.1 are what prove those changes broke
nothing.

## v2.2: Harden both servers

**Goal:** each server accepts only what it needs, and every change is measured
against a standard.

- A firewall policy written in the repo: who may connect in, and where each
  machine may connect out; everything else refused, both ways.
- The policy applied when a machine is built (the template for `backup-lab`, a
  setup step for `toolkit-lab`).
- `firewall-check.sh` compares the live rules with the policy, and checks that
  `ufw` is enabled and running. It reports; it never changes the firewall.
- The code that root runs moved out of `/home/ghaith` to
  `/usr/local/lib/linux-server-toolkit`, the same folder as on the vault:
  before, `ghaith` could edit the three scripts that root runs
  (`firewall-check.sh` and `service-watch.sh` on timers, `firewall-apply.sh` by
  hand), their two libraries and the policy file.
- systemd sandboxing on the system units, measured with
  `systemd-analyze security`: first on `toolkit-lab`, then on `backup-lab` with
  the template.
- Encryption before sending; the vault made immutable (`chattr +i`).
- `noexec,nodev,nosuid` on `/srv/backup`.
- Automatic security updates, with a restart when an update needs one: first
  on `toolkit-lab`, then on `backup-lab` with the template.
- Smaller items: the empty CD-ROM drive removed, the image checked with
  `gpgv`, the libvirt `clean-traffic` filter, a time limit on the unlocked
  admin key.
- A CIS audit report before and after (Level 1 - Server).
- The failed rules of the first report that a file of the lab's own fixes
  (`etc/`), with one script for the changes that are not a file
  (`harden.sh`): the SSH server's settings, kernel settings, unused kernel
  modules, `/dev/shm`, core dumps, `cron`, `sudo`, the umask of the login
  shells. Done on `toolkit-lab` (60 rules); then carried to `backup-lab` by
  the template. The rules that stay failed are listed, with their reasons, in
  [NOTES.md](NOTES.md).

**Exit gate:** the CIS report shows the change; `firewall-check.sh` passes on
both servers; a connection the policy does not allow is refused, in and out;
SSH works from the allowed machines; only the expected ports listen; the v2.1
daily check and restore steps still pass.

**Decided at the start** ([NOTES.md](NOTES.md)): SSH stays on port 22; the
outgoing allow list of each machine is in `firewall/policy.conf`; admin access
stays over SSH, from the host only.

## v3: Infrastructure as code and monitoring

**Goal:** new machines are built from code, and every machine is watched.

- Terraform (libvirt provider) builds `monitor-lab`. `backup-lab` stays with
  `bootstrap.sh`: no tool that can delete gets near the vault's disk.
- Prometheus on `monitor-lab`, `node_exporter` on every machine, Grafana and
  alerts; Grafana opened from the host's browser, its port open to the host only.
- File integrity checking (AIDE) on every machine, its findings sent through
  the alerts.
- The results compared with what the v1 checks report.

**Exit gate:** `monitor-lab` destroyed and rebuilt from code; a stopped service
raises an alert; Grafana shows every machine.

**Decided at the start:** where Terraform's state lives, and where alerts go.

**Why here:** the next machines are built with Terraform, and are watched from
the day they start.

## v4: The first real service

**Goal:** a service that is used every day runs in containers, and its data is
protected by the vault.

- `app-lab` built by Terraform.
- Readeck with PostgreSQL in Docker Compose.
- A database backup sent to the vault; the vault accepts more than one sender
  (`bootstrap.sh` and the template change for this).
- A size limit on `incoming` for each sender, so one sender cannot fill the
  data disk or block another.
- A copy of Terraform's state sent to the vault.

**Exit gate:** `app-lab` deleted, rebuilt from code, its data restored from the
vault, the saved articles back; a sender past its limit is refused.

**Decided at the start:** how `incoming` is limited: a filesystem of its own,
or disk quotas (the cloud image's kernel has no quota module).

## v5: CI/CD

**Goal:** a change pushed to GitHub is tested and deployed to the lab with no
manual step.

- A pipeline: test, build, deploy to `app-lab`.

**Exit gate:** a commit changes the running service on its own; a failing test
stops the deploy.

**Decided at the start:** how GitHub reaches a lab behind NAT.

## v6: Kubernetes and the control panel

**Goal:** the service runs on a cluster, managed from one place.

- A cluster: `k8s-lab` (control plane) and `app-lab` (worker).
- Readeck moved to the cluster, its data restored from the vault.
- The v5 pipeline deploys to the cluster.
- A control panel inside the lab, opened from the host's browser.

**Exit gate:** Readeck runs on the cluster with its old articles; a commit
reaches it through the pipeline.

**Decided at the start:** kubeadm or k3s (the host has 15 GiB of RAM).

## After v6

Improvements come as v6.x releases. A cloud version (v7) comes once the lab is
complete.

## Not on the Roadmap, and Why

| Item | Why not |
|---|---|
| `secaudit.sh` | The CIS audit of v2.2 checks file permissions and settings with a standard tool. |
| SSH off port 22 | Another port hides nothing from a port scan and refuses nothing: key-only logins, `from=` and the firewall do. Dropped from v2.2. |
| Automatic IP blocking with `ufw` | After v2.2 only known machines reach SSH: nothing is left to block. |
| An expected-ports list in `hostaudit.sh` | The v2.2 exit gate checks the listening ports. |
| An exclude flag for `backup.sh` | The backup is meant to hold the whole repo, `.git` included. |
| IPv6 and rotated logs in `log-analyzer.sh`, a random delay on the timers | Known v1 limits ([NOTES.md](NOTES.md)); small fixes, made when those scripts are next touched. |
| An offline USB copy | A later improvement; the shared disk stays a known limit. |
| A RHEL-family machine, Ubuntu 26.04 | To be discussed on their own, later. |
