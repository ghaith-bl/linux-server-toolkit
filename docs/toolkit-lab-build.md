# toolkit-lab: build guide

How `toolkit-lab`, the workstation, is built: the base machine and the v1
scripts, the v2 sender, the v2.1 local retention, then the v2.2 firewall
policy and CIS report. The reasons are in [NOTES.md](NOTES.md). Every
step ran and was verified on the real machine. Run on `toolkit-lab` unless a
step says otherwise.

## Where the Secrets Live

| File | Location | Mode |
|---|---|---|
| `/home/backup-push/.ssh/backup-lab-push` (no passphrase) | `toolkit-lab` only | `600`, owner `backup-push` |

## v1: the machine and the checks

### Step 1: Install Ubuntu

Installed by hand on the host from the Ubuntu Server 24.04 ISO with
`virt-install`: the normal install (not "minimized"), no featured snaps, user
`ghaith`. The exact options were not recorded. Its address is reserved like
`backup-lab`'s ([backup-lab-build.md](backup-lab-build.md), step 13).

### Step 2: SSH by key only

A drop-in `/etc/ssh/sshd_config.d/10-hardening.conf` with
`PasswordAuthentication no`. Its name sorts before `50-cloud-init.conf`: the
first value read wins.

```bash
sudo sshd -T | grep -E '^passwordauthentication'   # must say: passwordauthentication no
# from the host: a password login must be refused
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ghaith@192.168.122.14
```

### Step 3: The firewall

```bash
sudo ufw show added       # the rules waiting, SSH allowed first
sudo ufw enable
sudo ufw status verbose   # then log in from a new SSH session before closing the old one
```

### Step 4: The repo and the v1 scripts

```bash
git clone git@github.com:ghaith-bl/linux-server-toolkit.git ~/linux-server-toolkit   # over SSH, with its own GitHub key
cd ~/linux-server-toolkit && ./install.sh   # as ghaith, not with sudo: the timers and lingering
```

## v2: the sender

### Step 5: The account and its key

```bash
[ "$(hostname)" = "toolkit-lab" ] && sudo useradd --system --user-group \
    --home-dir /home/backup-push --no-create-home \
    --shell /usr/sbin/nologin --comment "pushes backups to backup-lab" backup-push        # no password, no login
[ "$(hostname)" = "toolkit-lab" ] && sudo install -d -o root -g root -m 755 /home/backup-push /home/backup-push/.ssh   # owned by root
[ "$(hostname)" = "toolkit-lab" ] && sudo ssh-keygen -t ed25519 -N '' \
    -C "backup-push@toolkit-lab" -f /home/backup-push/.ssh/backup-lab-push                # no passphrase
[ "$(hostname)" = "toolkit-lab" ] && sudo chown backup-push:backup-push /home/backup-push/.ssh/backup-lab-push   # the only file it owns
```

The public key goes to the host next ([backup-lab-build.md](backup-lab-build.md), step 15).

### Step 6: Pin backup-lab's host key

```bash
ssh-keyscan -t ed25519 192.168.122.239 2>/dev/null > ~/backup-lab.hostkey   # ask backup-lab for its key
FP=$(ssh-keygen -lf ~/backup-lab.hostkey | awk '{print $2}'); echo "$FP"    # its fingerprint
[ "$(hostname)" = "toolkit-lab" ] && [ "$FP" = "<the fingerprint from backup-lab's console>" ] && \
    sudo install -o root -g root -m 644 ~/backup-lab.hostkey /home/backup-push/.ssh/known_hosts   # only on a match
rm ~/backup-lab.hostkey
```

### Step 7: The client settings

Written in your home first (`~/backup-push.ssh-config`):

```
# ssh client settings for the backup-push account on toolkit-lab.
# Owned by root: backup-push cannot change whom it trusts.
Host backup-lab
    # backup-lab's reserved address
    HostName 192.168.122.239
    # the receive account on backup-lab
    User backup-recv
    # offer only this key
    IdentityFile /home/backup-push/.ssh/backup-lab-push
    IdentitiesOnly yes
    # accept only the pinned host key: never ask, never learn a new one
    UserKnownHostsFile /home/backup-push/.ssh/known_hosts
    StrictHostKeyChecking yes
    UpdateHostKeys no
    # never wait for a human: fail instead of asking a question
    BatchMode yes
    # give up after 10 seconds if backup-lab is off
    ConnectTimeout 10
```

```bash
[ "$(hostname)" = "toolkit-lab" ] && sudo install -o root -g root -m 644 ~/backup-push.ssh-config /home/backup-push/.ssh/config
rm ~/backup-push.ssh-config
```

### Step 8: The shared backup folder

```bash
[ "$(hostname)" = "toolkit-lab" ] && getent group backup-push > /dev/null && ! sudo test -e /var/backups/linux-server-toolkit && \
    sudo install -d -o ghaith -g backup-push -m 2750 /var/backups/linux-server-toolkit   # ghaith writes, backup-push reads
[ "$(hostname)" = "toolkit-lab" ] && ~/linux-server-toolkit/install.sh                  # backup.service now writes there
```

### Step 9: The sending service

```bash
cd ~/linux-server-toolkit
[ "$(hostname)" = "toolkit-lab" ] && sudo install -o root -g root -m 755 scripts/backup-push.sh /usr/local/sbin/backup-push && \
    sudo install -o root -g root -m 644 systemd/backup-push.service systemd/backup-push.timer /etc/systemd/system/ && \
    sudo systemctl daemon-reload                                                        # root owns the code and the units
```

### Step 10: After each backup-lab rebuild

A rebuild gives `backup-lab` a new host key, and `backup-push` refuses it until
the pinned file is replaced. Copy the `known_hosts-<instance-id>` file that
`bootstrap.sh` wrote on the host to `~` first.

```bash
FP=$(ssh-keygen -lf ~/known_hosts-<instance-id> | awk '{print $2}'); echo "$FP"   # must be the fingerprint bootstrap.sh printed
[ "$(hostname)" = "toolkit-lab" ] && [ "$FP" = "<the fingerprint bootstrap.sh printed>" ] && \
    sudo install -o root -g root -m 644 ~/known_hosts-<instance-id> /home/backup-push/.ssh/known_hosts && echo "pinned"
sudo systemctl start backup-push.service                                           # send now
journalctl -u backup-push.service --since -2min --no-pager -o cat | grep -E 'SENT|SKIPPED|STOP'   # one SENT line per pair
[ "$(hostname)" = "toolkit-lab" ] && sudo systemctl enable --now backup-push.timer  # once; it stays enabled
```

## v2.1: local retention

### Step 11: The retention timer

```bash
cd ~/linux-server-toolkit && ./install.sh   # as ghaith: adds backup-prune.timer (daily at 00:30)
./scripts/backup-prune.sh -d /var/backups/linux-server-toolkit -m /var/lib/backup-push/sent -n   # dry run: what it would remove
```

## v2.2: hardening

### Step 12: The firewall policy

The policy is `firewall/policy.conf`. From here on, the firewall is changed in
that file and applied with the script, never with `ufw` by hand.

```bash
cd ~/linux-server-toolkit
sudo ./scripts/firewall-apply.sh -n                                     # dry run: the ufw commands, nothing is changed
[ "$(hostname)" = "toolkit-lab" ] && sudo ./scripts/firewall-apply.sh   # replaces the firewall with the policy
sudo ./scripts/firewall-check.sh                                        # must end with: the firewall matches the policy
```

### Step 13: The CIS report

The report only reads the machine. The content file is kept on the host, in
`~/cis-reports`, so the report at the end of v2.2 is measured with the same
file (its names say `after` instead of `before`).

```bash
# on DimenstionX: the content file, once
mkdir -p ~/cis-reports && chmod 700 ~/cis-reports && cd ~/cis-reports
curl -fL -o ssg.zip https://github.com/ComplianceAsCode/content/releases/download/v0.1.82/scap-security-guide-0.1.82.zip
python3 -c 'import sys,zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' ssg.zip scap-security-guide-0.1.82/ssg-ubuntu2404-ds.xml > ssg-ubuntu2404-ds.xml   # only the Ubuntu 24.04 file
sha256sum ssg-ubuntu2404-ds.xml   # must be: e311189ac70ff73be54121311fca324d6188f8c12ab53416090f595ff00e070c
rm ssg.zip
scp ssg-ubuntu2404-ds.xml ghaith@192.168.122.14:

# on toolkit-lab
sudo apt-get update -q && sudo apt-get install -y openscap-scanner
mkdir -p ~/cis && chmod 700 ~/cis && cd ~/cis
sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_level1_server --results cis-before-toolkit-lab.xml --report cis-before-toolkit-lab.html ~/ssg-ubuntu2404-ds.xml > cis-before-toolkit-lab.txt   # exit status 2: some rules failed
sudo chown ghaith: cis-before-toolkit-lab.* && chmod 600 cis-before-toolkit-lab.*
tr -d '\r' < cis-before-toolkit-lab.txt | grep '^Result' | sort | uniq -c   # how many passed, failed, not applicable

# on DimenstionX: the reports are kept here, never in the repo
cd ~/cis-reports && scp 'ghaith@192.168.122.14:cis/cis-before-toolkit-lab.*' . && chmod 600 cis-before-*
```

## Recorded Values

| Item | Value |
|---|---|
| MAC / IP address | `52:54:00:ae:58:55` / `192.168.122.14`, reserved |
| `backup-push` | uid `999`, gid `988` |
| Push key (ED25519) | `SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ` |
| Pinned backup-lab host key | `SHA256:kHKDfiiTkhdOUzwyqR52M6IDDON4Y3V4DSvEvt3PbUk` (since the rebuild on 2026-10-04) |
| rsync | `3.2.7-1ubuntu1.5` |
| Local backup folder | `/var/backups/linux-server-toolkit`, `ghaith backup-push`, mode `2750` |
| Sending service | `/usr/local/sbin/backup-push`, `backup-push.service` (`User=backup-push`), `backup-push.timer` (hourly at :15) |
| Local retention | `backup-prune.timer` (user unit, daily at 00:30): sent backups older than 15 days are removed, the newest 7 always kept |
| Firewall | `firewall/policy.conf`: 1 rule in, 8 out, everything else refused both ways; refused packets in `/var/log/ufw.log`; `firewall-check.timer` compares every 4 hours |
| First CIS report | 2026-10-04, after the firewall step: 238 passed, 105 failed, 65 not applicable (Level 1 - Server, 408 rules) |
