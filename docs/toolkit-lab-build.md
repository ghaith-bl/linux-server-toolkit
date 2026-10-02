# toolkit-lab: build guide

How `toolkit-lab`, the workstation, is built: the base machine and the v1
scripts, then the v2 sender. The reasons are in [NOTES.md](NOTES.md). Every
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
cd ~/linux-server-toolkit && ./install.sh   # as ghaith, not with sudo: the six v1 timers and lingering
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

## Recorded Values

| Item | Value |
|---|---|
| MAC / IP address | `52:54:00:ae:58:55` / `192.168.122.14`, reserved |
| `backup-push` | uid `999`, gid `988` |
| Push key (ED25519) | `SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ` |
| Pinned backup-lab host key | `SHA256:ZXt3EQtt9YgiaLH40yNORJ9ihQxGRTfKSgWSeC83Cu0` (since the rebuild on 2026-10-01) |
| rsync | `3.2.7-1ubuntu1.5` |
| Local backup folder | `/var/backups/linux-server-toolkit`, `ghaith backup-push`, mode `2750` |
| Sending service | `/usr/local/sbin/backup-push`, `backup-push.service` (`User=backup-push`), `backup-push.timer` (hourly at :15) |
