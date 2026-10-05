# Notes and Decisions

Why the lab is built the way it is, version by version, and the facts the
decisions rest on. The steps are in the build guide of each machine.

## v1: toolkit-lab and its checks

### Facts

- `/var/log/auth.log` is `syslog:adm`, mode `640`, and `ghaith` is in `adm`:
  `log-analyzer.sh` reads it without `sudo`.
- A user unit cannot set `SupplementaryGroups=` (`Operation not permitted`); the
  user manager already has `ghaith`'s groups, `adm` included.
- With `loginctl enable-linger` the user manager starts at boot, and it still
  gets `adm`. Checked after a reboot with no login:
  `grep '^Groups:' /proc/$(pgrep -u ghaith -x systemd)/status`.
- SSH is socket-activated (Ubuntu 22.10 and later): an inactive `ssh.service`
  behind a live `ssh.socket` is normal.
- `auditd` is not installed, so `hostaudit.sh` reports it inactive and
  `hostaudit.service` stays failed.
- The normal Ubuntu Server install, not "minimized": minimized drops `rsyslog`,
  and with it `/var/log/auth.log`.
- No featured snaps: every extra package is an assumption written down nowhere.
- The repo lives on `toolkit-lab`: the scripts read Ubuntu's logs and services,
  which the Fedora host does not have.

### Decisions

| Decision | Why |
|---|---|
| No shared config file | No value is used by more than one script, and sourcing a file runs its code. |
| `install.sh` renders the unit files into place instead of editing them | The repo stays clean after every install. |
| `install.sh` runs as the normal user | As root, `systemctl --user` and lingering would target root. |
| Unit files hold absolute paths, rewritten by `install.sh` | systemd runs units with no `PATH` and no working directory. |
| The `.service` files have no `[Install]` section | The `.timer` is what gets enabled. |
| `firewall-check.sh` is separate from `hostaudit.sh` | `ufw` needs root; every other check runs as a normal user. |
| `service-watch.sh` requires root for the whole script | Restarting services is its only job. |
| `service-watch.sh` checks `TriggeredBy` before calling a service broken | A service idle behind a live socket is not down. |
| When every trigger is down, only the first is restarted | A service with several triggers has not come up. |
| The restart counter is kept per service, in `/var/lib/linux-server-toolkit/service-watch/`, and reset when healthy | It counts consecutive failures only; root-owned files in a user's home are a trap ([PROBLEMS.md](PROBLEMS.md), v1, 4). |
| Success is checked on the unit that was restarted | A socket-activated service stays inactive after its socket comes back. |
| `hostaudit.sh` checks system units only | With `--user`, its own failed state would keep it failed forever. |
| A check that finds a problem exits `1` | `systemctl --failed` then lists every check that found something. |
| Timers: hourly to recover, every 4h to detect, daily for snapshots | Recovery and detection need a short window; snapshots do not. |
| `backup.sh` writes locally and deletes nothing | Sending and retention are separate jobs (`backup-push.sh`, the vault). |
| `backup.sh` builds its archive in the destination folder | The final `mv` is an atomic rename on the same filesystem. |
| `backup.sh` takes only `-s` and `-d`, no excludes | It stays a generic tool. |

### Known limits

- `log-analyzer.sh` reads only the current `auth.log`, and IPv4 only.
- `hostaudit.sh` cannot tell "auditd stopped" from "auditd not installed".
- The daily timers and `log-analyzer.sh` fire at 00:00 together with
  `logrotate`, which can rotate `auth.log` while it is being read.

## v2: the vault and the backup chain

### backup-lab

| Decision | Why |
|---|---|
| Ubuntu 24.04 cloud image + cloud-init | Boots ready and is set up from one file: no installer questions. |
| The image checked by signature, then by checksum | The checksum proves the download; the signature proves the checksum is Ubuntu's. |
| An independent disk copy (no backing file) | The vault depends on no other file. |
| Two disks: system 10G, data 20G | A rebuild replaces the system disk and keeps the backups. |
| The data disk mounted by label, without `nofail` | Its UUID does not exist when the file is written; without its disk the machine stops at boot. |
| 1 vCPU, 1 GiB RAM | The job is small. |
| Admin: its own SSH key, only from the host, plus a sudo password | A stolen key alone is not root. |
| Addresses reserved by MAC on the libvirt network | The `from=` limits need fixed addresses. |
| Receive account `backup-recv`, forced command `rrsync -wo -no-del` | The sender can write new files only: no reading, no deleting, no shell. |
| Shell `/bin/sh` for `backup-recv` | bash could run startup files before the forced command. |
| Push key with `restrict` and `from=` the sender's address | A stolen copy is useless anywhere else. |
| Its key file, home and `.ssh` owned by root | `backup-recv` cannot remove its own limits. |
| The mover checks each pair in `staging` (root only) | The sender cannot swap a file between the check and the store. |
| The sha256 computed on `backup-lab` | Nothing the sender wrote is trusted. |
| Vault files `root`, mode `400`, never overwritten | A stored backup cannot change. |
| A failed pair goes to `rejected`, and the unit fails | The evidence stays for a human. |
| Retention: 30 days by arrival time, the newest 7 always kept | Counted on `backup-lab`'s clock; the last copies stay if sending stops. |
| A timer every 15 minutes, not a path unit | A path unit loops while an archive waits for its checksum. |
| `bootstrap.sh` never deletes anything | Delete code next to the vault's disk is a risk; leftovers are removed by hand. |
| `DATA_DISK=new` or `reuse` | A wrong name never makes an empty disk in place of the vault's. |
| The new host key trusted only if it matches the console | Another machine could answer at the address. |
| A new `instance-id`, serial log and `known_hosts` per build | cloud-init runs once per id; each build keeps its own record. |
| Template changes tested on a throwaway VM first | cloud-init gets one chance per build. |
| Every command that changes something checks the hostname first | Disk commands once ran on the wrong VM. |

### toolkit-lab, the sender

| Decision | Why |
|---|---|
| A service account `backup-push` sends, not root or `ghaith` | A compromise reaches only the backups. Example: CVE-2024-12086 let a malicious rsync server read any file the sender could read. |
| Shell `nologin`, password locked | Nobody logs in as it, not even with `sudo -i`. |
| Its home, `.ssh`, `config` and `known_hosts` owned by root | It cannot change its settings or whom it trusts. |
| Push key without a passphrase | A service cannot type one; the limits live on `backup-lab`. |
| `backup-lab`'s host key pinned; `StrictHostKeyChecking yes`, `BatchMode yes` | It never asks and never learns a new key: a changed key stops the backups until a human checks it. |
| Local backups in `/var/backups/linux-server-toolkit`, `ghaith:backup-push`, mode `2750` | `backup-push` reads them and cannot change them; it cannot enter the home (`750`). |
| The archive and its `.sha256` are `640`; the checksum is moved in place last | The group can read both; a checksum file means its archive is complete. |
| A system unit with `User=backup-push` and `NoNewPrivileges=yes` | It runs as the limited account and can never gain privileges. |
| The script copied to `/usr/local/sbin`, owned by root | `backup-push` cannot change the code it runs. |
| Each archive checked against its `.sha256` before sending | A copy that changed after `backup.sh` made it is never sent. |
| One marker file per archive sent (`StateDirectory=`) | `incoming` empties after each mover run, so rsync cannot tell what was sent. |
| Hourly at :15, `Persistent=true` | `toolkit-lab` is not on every day: a missed run happens after the boot. |
| Not part of `install.sh` | It needs the `backup-push` account, made only by hand. |

## v2.1: finishing the backup chain

Decided at the start of v2.1. The work itself is listed in
[ROADMAP.md](ROADMAP.md).

### Facts

- `backup-lab` runs the cloud image's kernel (`6.8.0-146-generic`), and it has
  no `quota_v2` module (`modinfo quota_v2`): disk quotas do not work on it as
  built.
- `/var/lib/backup-push` and its `sent` folder are mode `755`: `ghaith` can
  read the markers.
- One backup pair is about 550 KiB.
- A rebuild right after the power-off got the reserved address with one
  lease: the new machine took over the old lease (seen once, 2026-10-03).

### Decisions

| Decision | Why |
|---|---|
| Local retention reads the markers that `backup-push.sh` writes | They already record what was sent; the vault is receive-only, so nothing can ask it. |
| Local retention is its own script and timer, run as `ghaith` | `ghaith` owns the files; `backup.sh` deletes nothing, and `backup-push` cannot change the folder. |
| Local: 15 days, the newest 7 always kept, an unsent backup never removed | The local copy is the short one; the vault keeps 30 days. |
| The CI takes the mover out of the template with `yq` | The template stays the only copy of the mover, and `bootstrap.sh` does not change. |
| The size limit on `incoming` waits for v4 | With one sender, a full disk only stops new backups, and the failed send shows it. A limit needs quotas (no kernel module) or a third disk (a change to `bootstrap.sh`); v4 changes both files for a second sender anyway. |
| The mover stops taking backups under 2 GiB free, and fails | A filling disk is seen on `backup-lab` itself; retention still runs and frees space. |
| The daily check reads the backups; it does not unpack them | Unpacking would make root write files the sender chose, on the vault. Reading to the end finds a damaged or cut archive. |
| The real restore is run by hand, to `toolkit-lab` | Only the admin key can read the vault. |

### Known limits

- A marker means "sent", not "stored": the local retention cannot know that the
  mover accepted a backup. The 15 days are the time to notice a failed mover.
- Until v4, a compromised `toolkit-lab` can fill the data disk: new backups
  stop, stored ones stay.
- The marker files are never removed: one empty file per backup.

## v2.2: hardening both servers

Decided at the start of v2.2. The work itself is listed in
[ROADMAP.md](ROADMAP.md).

### Facts

- Both machines get their address by DHCP (a reservation, not a static
  address), and `ufw` starts before the network (`Before=network-pre.target`):
  the DHCP request of every boot passes through the firewall.
- `ufw` stores an address, never a name: a rule written with a host name keeps
  the address that name had on the day the rule was added.
- GitHub publishes the ranges it serves git from (the `git` list of
  `https://api.github.com/meta`). On 2026-10-04 `github.com` answered from
  `140.82.112.0/20`.
- A rule to "any" is added for IPv4 and IPv6; a rule with an IPv4 address
  exists for IPv4 only.
- `ufw show added` prints each rule as the command that makes it
  (`get_command` in `src/parser.py`, ufw 0.36.2).
- `ufw status` prints `disabled (routed)` while the machine forwards no
  packets (`net.ipv4.ip_forward` is 0).
- `ufw --force reset` turns the firewall off and keeps a dated copy of the old
  rule files in `/etc/ufw/`. A connection that is already open stays open.
- Refused packets go to `/var/log/ufw.log` (`syslog:adm`, mode `640`, like
  `auth.log`).
- `backup-lab` had no firewall until v2.2: `ufw` was installed and its service
  enabled, and `ufw status` said `inactive`.
- cloud-init runs `runcmd` after the package updates of the first boot.
- The CIS reports are made with OpenSCAP (`openscap-scanner` 1.3.9, from
  Ubuntu) and the content of the ComplianceAsCode project, release 0.1.82: the
  profile "CIS Ubuntu Linux 24.04 LTS Benchmark v1.0.0, Level 1 - Server", 408
  rules. Ubuntu's own content package (`ssg-debderived` 0.1.71) has no profile
  for 24.04.
- 16 of those rules are checked by a script that `oscap` runs as root (the
  firewall's default policy is one); the others by reading files and settings.
- The first report was taken on 2026-10-04, after the firewall step, so the
  firewall is already inside its numbers. `toolkit-lab`: 238 passed, 105
  failed, 65 not applicable. `backup-lab`: 236, 107, 65. No rule was left
  unchecked.
- `ufw` takes a lock before it does anything, `ufw status` included:
  `/run/ufw.lock`.
- Ubuntu 24.04 restricts user namespaces for programs without root rights
  (`kernel.apparmor_restrict_unprivileged_userns` is 1).
- `systemd-analyze security` gives a unit a number from 0 (closed) to 10
  (open). Measured on `toolkit-lab` itself, before the sandbox (2026-10-04)
  and after it (2026-10-05): `firewall-check.service` 9.6 and 7.7,
  `service-watch.service` 9.6 and 7.7, `backup-push.service` 9.0 and 7.5.

### Decisions

| Decision | Why |
|---|---|
| SSH stays on port 22 | Another port hides nothing from a port scan and refuses nothing: key-only logins, `from=` and the firewall do. |
| Outgoing connections are refused by default, like incoming ones | A program running on a machine cannot fetch tools or send data out, except through the few openings of the policy. |
| `backup-lab` never opens an SSH connection | The vault only receives. |
| Admin access stays over SSH, from the host only | The final check of `bootstrap.sh` logs in with the admin key; the console stays the way back in. |
| `git push` stays on SSH, to one range GitHub publishes | HTTPS needs a token stored on `toolkit-lab`; a rule with the name `github.com` keeps one address only. |
| One file holds the policy of every machine (`firewall/policy.conf`) | One place says what each machine may accept and reach. |
| `firewall-apply.sh` and `firewall-check.sh` read it through one reader (`lib/firewall-policy.sh`) | The two can never understand the policy in different ways. |
| `firewall-apply.sh` is separate from `firewall-check.sh` | The check must never be able to change the firewall. |
| `firewall-apply.sh` resets `ufw`, then adds the policy's rules | The firewall is exactly the policy: a rule added by hand does not stay. |
| Before it changes anything, it checks the whole policy and asks `ufw --dry-run` about every rule | A wrong line never leaves half a firewall. |
| It stops when the policy lets nothing in | Console-only access is a decision, not a forgotten line. |
| Every rule carries the comment `pol:<host>:<dir>:<tag>` | `ufw status` shows which line of the policy a rule comes from. |
| `firewall-check.sh` compares whole rules, as text, with `ufw show added` | A rule with the right name and the wrong address is found too. |
| Refused packets are logged (`logging low`) | A refused connection can be seen, not guessed. |
| No outgoing rules per user | `ufw` cannot write them. |
| The template carries a copy of the policy, the two scripts and their two libraries | `backup-lab` has no repo. `bootstrap.sh` does not change, and what reaches the vault is one reviewed, committed file. |
| The CI compares each copy with its file | A copy never differs from the repo unseen. |
| On `backup-lab` the copies sit in `/usr/local/lib/linux-server-toolkit`, in the repo's layout, owned by root | The scripts find their libraries and the policy with no change. |
| Both scripts take `-m <machine>`; the template uses `-m backup-lab` | A test machine has another name, and must get the vault's rules. |
| The policy is applied last in the first boot | The package updates run before outgoing connections are limited. A wrong policy is saved as a cloud-init error, and the final check of `bootstrap.sh` reads it. |
| `backup-lab` rebuilt right after the template change, not at the exit gate | The vault had no firewall: it does not wait for the end of v2.2. |
| The CIS reports are made with OpenSCAP and the ComplianceAsCode content | No account and no secret. Canonical's own tool (USG) needs an Ubuntu Pro token on every machine, and attaching it changes the machine before it is measured. |
| The measure is Level 1 - Server | It is the level meant for every server. Level 2 asks for another disk layout and for `auditd` rules. |
| One content file, checked by its sha256, measures before and after | The two reports can be compared rule by rule. |
| The reports stay on the host, outside the repo | They list the accounts and settings of each machine. Only the numbers are written here. |
| A failed rule is fixed when a config file fixes it; it stays failed, with its reason, when it goes against how the lab works | The score is not the goal: a rule is followed where it protects something here. |
| On `toolkit-lab`, root runs its scripts from `/usr/local/lib/linux-server-toolkit`, never from the repo | A file in a home folder can be changed by its owner, and a root timer would run that change as root, with no password asked. |
| The same folder and layout as on `backup-lab` | Root's code has one place on every machine, and the scripts find their libraries and the policy with no change. |
| `install.sh` makes the copies, with `sudo` | Changing what root runs asks for the password. |
| The three system units of `toolkit-lab` run in a systemd sandbox: a read-only file system and read-only kernel settings, no home folders (read-only for `backup-push`), their own `/tmp`, no disks | They run on timers with no one watching, two of them as root. A mistake in one of their scripts can write only where the unit's job needs it. |
| `firewall-check.service` may write in `/run` | `ufw` takes its lock there, even to read the rules. |
| `service-watch.service` gets its counters folder from `StateDirectory=` | systemd makes the folder and leaves only it writable. |
| The two root units get `IPAddressDeny=any`, not `PrivateNetwork=` | Neither sends a packet. In a network of its own, `ufw` would read an empty firewall, not the machine's. |
| `backup-push.service` may talk to the address of `backup-lab` only | `ufw` cannot write a rule for one account; systemd can, for one service. |
| The sandbox is measured with `systemd-analyze security`, on the machine | The number comes from systemd itself, before and after, like the CIS reports. |
| No capability list and no system call filter | Each needs a list found by trial for every script, and a wrong list breaks a unit: left out to keep the units simple. |
| The user units are not sandboxed | They run as `ghaith`, with no root rights. For a user unit these settings need a user namespace, which Ubuntu 24.04 restricts. |

### Known limits

- Ports 80 and 443 are open to anywhere on both machines, for package
  updates: a program on the machine can still send data out through them.
  Closing them needs a package proxy on the host.
- NTP (udp 123) is open to anywhere.
- The GitHub rule holds a range: if GitHub moves `github.com` out of it,
  `git push` fails until the policy is changed.
- While `firewall-apply.sh` runs, the machine has no firewall for about a
  second.
- `firewall-check.sh` reads the rules `ufw` holds; a rule added with
  `iptables` directly is not seen.
- The five firewall files exist twice, in the repo and in the template: a
  change is made in both, and the CI fails until they match.
- A change to the policy reaches `backup-lab` only with a rebuild.
- On `toolkit-lab`, a change to the policy or to a script that root runs takes
  effect only after `./install.sh`: until then root runs the old copy, and the
  check compares the firewall with the old policy.
- `systemd-analyze security` still rates the three units `EXPOSED`: none has a
  capability list or a system call filter, and two of them run as root.
- The two root units keep every capability, and `systemd.exec` says a
  privileged process may undo the read-only file system: their sandbox stops a
  mistake in a script, not code that sets out to break it.
  `backup-push.service` runs without root rights, and cannot.
- The address of `backup-lab` is written in three places on `toolkit-lab`: the
  policy, the ssh settings of `backup-push`, and `backup-push.service`.

### Failed CIS rules that are not fixed in v2.2

From the first report: 27 rules on `toolkit-lab`, 28 on `backup-lab`, and 2
moved to v3.

| Rules | Why |
|---|---|
| `nftables` in use, `ufw` removed (5) | The benchmark has rules for three firewalls, and a machine uses one: this lab uses `ufw`. |
| Loopback rules written in `ufw` (1) | `ufw` already accepts loopback traffic in its built-in rules (`/etc/ufw/before.rules`). The policy file has no rule on an interface. |
| A `ufw` rule for every listening port (1) | Looked at with the listening ports, at the exit gate. |
| `rsync` is installed (1) | The backups travel with it. Its daemon is never used. |
| Password quality, history, lockout and expiry (13) | No password crosses the network: SSH takes keys only. The password serves `sudo` and the console, and a wrong PAM change locks the only way back in. |
| A bootloader password (2) | Whoever reaches a machine's console already holds the host and its disks. |
| Login banners (3) | A legal notice: it protects nothing in this lab. |
| `/tmp` on its own partition (1) | It needs another disk layout. |
| `backup-recv` has a shell (1, `backup-lab` only) | Its key runs one forced command, and that needs `/bin/sh`. |
| File integrity checking, AIDE (2) | Its findings need a reader: it comes with the alerts of v3. |
