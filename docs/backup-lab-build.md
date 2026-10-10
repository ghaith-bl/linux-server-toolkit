# backup-lab: build guide

How `backup-lab`, the vault, is built and rebuilt. The reasons are in
[NOTES.md](NOTES.md) (v2, v2.1, v2.2). Every step ran and was verified on the real
machines. Run on the host `DimenstionX` unless a step says otherwise.

## The 15 Steps of the First Build

`backup-lab` was first built by hand in 15 steps (2026-09-27). Since then
`bootstrap.sh` and `bootstrap/user-data.template` do most of them. Both files
point to these step numbers.

| Step | What | Done now by |
|---|---|---|
| 1 | Download the cloud image | Hand, once (below) |
| 2 | Verify the image: signature, then checksum | Hand, once (below); `bootstrap.sh` checks again |
| 3 | Protect the image (mode `444`) | Hand, once (below) |
| 4 | Create the disks | `bootstrap.sh` |
| 5 | The admin SSH key | Hand, once (below) |
| 6 | The cloud-init files | The template; `bootstrap.sh` writes them |
| 7 | Fill the placeholders | `bootstrap.sh` |
| 8 | The first boot | `bootstrap.sh` (`virt-install`) |
| 9 | Verify the machine | `bootstrap.sh` (final check) |
| 10 | First SSH login and failure tests | `bootstrap.sh` (host key, final check) |
| 11 | The data disk | The template |
| 12 | Power off and start | The template, and `virt-install --wait` |
| 13 | Fixed addresses | Hand, once (below) |
| 14 | The receive account and `incoming` | The template |
| 15 | The push key from `toolkit-lab` | Hand, to the host (below); the template installs it |

## Where the Secrets Live

| File | Location | Mode |
|---|---|---|
| `~/.ssh/backup-lab-admin` (passphrase) | `DimenstionX` only | `600` |
| `~/lab-images/backup-lab/user-data` (password hash) | `DimenstionX` only, never in git | `600` |
| `~/vault-keys/backup-vault-key.txt` and its copy `~/.vault-keys-copy/backup-vault-key.txt` (the key that opens the backups) | `DimenstionX` only | `600`, folders `700` |
| `/var/log/libvirt/qemu/<instance-id>-serial.log` | `DimenstionX` only | `600` root |
| Console / sudo password | Password manager only | - |

## The Host

KVM, libvirt and `virt-install`, and two packages more: libvirt's network
filters (`bootstrap.sh` stops at its checks without them) and `age`, which
opens the backups. On Fedora Silverblue:

```bash
rpm-ostree install libvirt-daemon-config-nwfilter age   # both work after the next restart of the host
sudo virsh nwfilter-dumpxml clean-traffic > /dev/null && echo "the filter is there"
```

## Step 1: Download the cloud image

```bash
mkdir -p ~/lab-images && cd ~/lab-images
curl -fLO https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img  # the image
curl -fLO https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS                               # its checksums
curl -fLO https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS.gpg                           # their signature
```

## Step 2: Verify the image

```bash
gpg --keyid-format long --keyserver hkps://keyserver.ubuntu.com \
    --recv-keys D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81      # Ubuntu's image key
gpg --fingerprint D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81    # compare with Ubuntu's page, not with this file
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS    # must say: Good signature
sha256sum --ignore-missing -c SHA256SUMS                      # must say: ...img: OK
gpg --export D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81 > ubuntu-cloudimage-keyring.gpg   # that one key, in a file of its own
chmod 444 ubuntu-cloudimage-keyring.gpg                       # never changed, like the image
gpgv --keyring ./ubuntu-cloudimage-keyring.gpg SHA256SUMS.gpg SHA256SUMS   # must say: Good signature; bootstrap.sh runs this check at every build
gpgconf --kill keyboxd                                        # gpg started its helper: stop it
```

Ubuntu's page for the fingerprint:
[verify-image-checksum](https://ubuntu.com/docs/public-images/public-images-how-to/verify-image-checksum/).

## Step 3: Protect the image

```bash
chmod 444 ~/lab-images/ubuntu-24.04-server-cloudimg-amd64.img   # the checked image is never changed
```

## Step 5: The admin key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/backup-lab-admin -C "backup-lab-admin@DimenstionX"   # set a passphrase
```

In `~/.ssh/config` on the host. The key is never given to an SSH agent:
`ssh` asks for its passphrase at every login to the vault, by name or by
address.

```
Host backup-lab
    HostName 192.168.122.239
    User ghaith
    IdentityFile ~/.ssh/backup-lab-admin
    IdentitiesOnly yes

Host backup-lab 192.168.122.239
    IdentityAgent none
    AddKeysToAgent no
```

```bash
ssh -G backup-lab | grep -E '^(identityagent|addkeystoagent) '   # must say: none, false
```

## Step 13: Fixed addresses

Ran once, with both machines running. A reservation follows the MAC, and
`bootstrap.sh` keeps the MAC on every build.

```bash
sudo virsh net-dumpxml default --inactive > ~/lab-images/default-network.before-v2-step2.xml   # backup first
MAC_BL=$(sudo virsh domiflist backup-lab  | grep -oE '52:54:00(:[0-9a-f]{2}){3}')   # read the MACs, never type them
MAC_TL=$(sudo virsh domiflist toolkit-lab | grep -oE '52:54:00(:[0-9a-f]{2}){3}')
[ "$(hostname)" = "DimenstionX" ] && [ -n "$MAC_BL" ] && \
  sudo virsh net-update default add ip-dhcp-host \
  "<host mac='$MAC_BL' name='backup-lab' ip='192.168.122.239'/>" --live --config   # now and after restarts
[ "$(hostname)" = "DimenstionX" ] && [ -n "$MAC_TL" ] && \
  sudo virsh net-update default add ip-dhcp-host \
  "<host mac='$MAC_TL' name='toolkit-lab' ip='192.168.122.14'/>" --live --config
sudo virsh net-dumpxml default | grep '<host'   # the two reservations
```

## Step 15: The push key from toolkit-lab

The key is made on `toolkit-lab` ([toolkit-lab-build.md](toolkit-lab-build.md),
step 5). The public key travels through the host; its fingerprint is compared
at every stop.

```bash
# on toolkit-lab: only cat runs as root, so the copy is yours
sudo cat /home/backup-push/.ssh/backup-lab-push.pub > /home/ghaith/backup-lab-push.pub
# on DimenstionX
scp ghaith@192.168.122.14:backup-lab-push.pub ~/lab-images/backup-lab/backup-lab-push.pub
ssh-keygen -lf ~/lab-images/backup-lab/backup-lab-push.pub   # must show SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ
```

## The Vault Key

Made once, on the host. `toolkit-lab` encrypts every backup with its public
part ([toolkit-lab-build.md](toolkit-lab-build.md), step 18); the private
part never leaves the host, and is never printed.

```bash
mkdir -m 700 ~/vault-keys ~/.vault-keys-copy                                                # two folders, yours only
age-keygen -o ~/vault-keys/backup-vault-key.txt                                             # the key (mode 600); prints its public part
install -m 600 ~/vault-keys/backup-vault-key.txt ~/.vault-keys-copy/backup-vault-key.txt    # the second copy
age-keygen -y ~/vault-keys/backup-vault-key.txt                                             # the public part again: it goes to toolkit-lab
echo test | age -r "$(age-keygen -y ~/vault-keys/backup-vault-key.txt)" | age -d -i ~/.vault-keys-copy/backup-vault-key.txt   # must say: test (the copy opens what the public part closed)
```

## The Repo and the Settings File

```bash
git clone https://github.com/ghaith-bl/linux-server-toolkit.git ~/linux-server-toolkit   # a read-only copy
git -C ~/linux-server-toolkit remote set-url --push origin no-push                       # commits happen on toolkit-lab only
mkdir -p ~/lab-images/backup-lab && chmod 700 ~/lab-images/backup-lab                    # the machine folder: yours only
install -m 600 ~/linux-server-toolkit/bootstrap/example.conf ~/lab-images/backup-lab/backup-lab.conf
vim ~/lab-images/backup-lab/backup-lab.conf    # fill in the values; each one is explained in the file
```

## Check the Template (after any change)

On any machine with cloud-init (`toolkit-lab` here), in the repo:

```bash
grep -oE '<[A-Z_]+>' bootstrap/user-data.template | sort -u            # the five placeholders
cloud-init schema -c bootstrap/user-data.template --annotate           # must say: Valid schema
for i in 1 4; do   # write_files 1 and 4: the vault mover and the vault check (the CI checks both on every push)
    python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["write_files"][int(sys.argv[2])]["content"], end="")' \
        bootstrap/user-data.template "$i" | shellcheck -s bash -f gcc -
done
for f in lib/common.sh lib/firewall-policy.sh scripts/firewall-apply.sh scripts/firewall-check.sh scripts/harden.sh firewall/policy.conf $(find etc -type f); do   # the copies: each one in the template must be the same as its file (the CI checks this too)
    python3 -c 'import sys, yaml; print(next(w["content"] for w in yaml.safe_load(open(sys.argv[1]))["write_files"] if w["path"] in ("/usr/local/lib/linux-server-toolkit/" + sys.argv[2], "/" + sys.argv[2])), end="")' \
        bootstrap/user-data.template "$f" | cmp - "$f" && echo "same: $f"
done
```

## Build

```bash
~/linux-server-toolkit/bootstrap/bootstrap.sh ~/lab-images/backup-lab/backup-lab.conf   # asks the console password twice, the admin key's passphrase at the end
```

What it does, in order. Any failed check prints `STOP: ...` and ends it.

1. **Settings:** not as root; the settings file is yours, mode `600`; each value has the right shape.
2. **Checks:** the tools, `sudo`, the machine folder (`700`), the template's five placeholders, the image's signature (`gpgv`) and checksum, both public keys, the network, the host's address on it, and the network filter.
3. **Guards:** no machine with this name, no system disk, the data disk as `DATA_DISK` says, no other machine using these disks or this MAC, no old `user-data` or `meta-data`.
4. **cloud-init files:** the password hashed, `user-data` (`600`) filled from the template, `meta-data` with a new `instance-id`.
5. **Disks:** the system disk copied from the image and grown to 10G; a new 20G data disk only with `DATA_DISK=new`.
6. **First boot:** `virt-install` boots it with the serial console logged and the `clean-traffic` filter on its card; cloud-init runs `harden.sh`, applies the firewall policy as its last command, and powers the machine off. The script then removes the empty CD-ROM drive and starts the machine again.
7. **Address and host key:** the filter is on the card; exactly one lease (the reserved address); the host key `ssh-keyscan` returns must match the one the machine printed on its console; only then `known_hosts-<instance-id>` is written.
8. **Final check (read only):** the console log shows one clean first boot; SSH refuses logins without a key; one login with the admin key checks the hostname, cloud-init's result, the data disk, `backup-recv`, the owners and modes, the key line, and no `ubuntu` user. The SSH server gives a login 60 seconds: type the key's passphrase within them.

## Check the Vault Mover (inside backup-lab)

```bash
systemctl is-enabled backup-mover.timer                           # must say: enabled
sudo stat -c '%U %G %a %n' /srv/backup/staging /srv/backup/rejected /srv/backup/vault /srv/backup/vault/toolkit-lab   # root root 700, four times
sudo systemctl start backup-mover.service                         # run it now
systemctl show -p Result -p ExecMainStatus backup-mover.service   # Result=success, ExecMainStatus=0
sudo journalctl -u backup-mover.service --no-pager | grep -E 'STORED|REJECTED|EXPIRED|LOW SPACE'   # what it stored, rejected or aged out; LOW SPACE: under 2 GiB free, nothing taken
sudo lsattr /srv/backup/vault/toolkit-lab                         # an i in front of each stored file: immutable
```

## Check the Stored Backups (inside backup-lab)

```bash
systemctl is-enabled vault-verify.timer                           # must say: enabled
sudo systemctl start vault-verify.service                         # run it now (the timer runs it daily)
systemctl show -p Result -p ExecMainStatus vault-verify.service   # Result=success, ExecMainStatus=0
sudo journalctl -u vault-verify.service --no-pager | grep -E 'VERIFIED|FAILED'   # every backup against its checksum
```

## Check the Firewall (inside backup-lab)

The template carries a copy of `firewall/policy.conf`, the two firewall
scripts and their libraries, in `/usr/local/lib/linux-server-toolkit`. To
change the vault's rules: change the file, change its copy in the template,
then rebuild.

```bash
sudo ufw status verbose                                             # active; deny (incoming), deny (outgoing); the vault's rules, each with its pol: comment
systemctl is-enabled firewall-check.timer                           # must say: enabled
sudo systemctl start firewall-check.service                         # compare the firewall with the policy now (the timer does it every 4 hours)
systemctl show -p Result -p ExecMainStatus firewall-check.service   # Result=success, ExecMainStatus=0
sudo journalctl -u firewall-check.service --no-pager -o cat | grep -E 'matches|difference|missing rule|not in the policy'   # what the check found
timeout 5 bash -c 'echo > /dev/tcp/192.168.122.14/22' || echo "refused"   # must say: refused (the vault opens no SSH connection)
sudo journalctl -k --no-pager -o cat | grep 'UFW BLOCK' | tail -n 5   # the last refused packets, in (IN=enp1s0) and out (OUT=enp1s0)
```

## Check the Hardening (inside backup-lab)

The template carries copies of `harden.sh` and the ten settings files of
`etc/`; cloud-init runs `harden.sh` in the first boot.

```bash
sudo grep -F "harden.sh: every step done" /var/log/cloud-init-output.log   # the first boot ran it to its end
findmnt -n -o OPTIONS /srv/backup                                   # the data disk: nosuid, nodev, noexec
for u in backup-mover vault-verify firewall-check; do systemd-analyze security --no-pager "$u.service" | grep 'Overall exposure'; done   # the sandbox of each unit: 0 is closed, 10 is open
apt-config dump | grep -E '^(APT::Periodic::Unattended-Upgrade |Unattended-Upgrade::Automatic-Reboot)'   # the automatic security updates
lsblk -d -o NAME,TYPE                                               # two disks, no CD-ROM drive
```

## The CIS Report

The report only reads the machine. The content file is the one from Step 13
of the `toolkit-lab` guide, kept in `~/cis-reports` on the host. The scanner
is not in the template: it is gone after the next rebuild. The report at the
end of v2.2 says `after` instead of `before` in its names.

```bash
# on DimenstionX
scp ~/cis-reports/ssg-ubuntu2404-ds.xml backup-lab:

# inside backup-lab
sha256sum ~/ssg-ubuntu2404-ds.xml   # must be: e311189ac70ff73be54121311fca324d6188f8c12ab53416090f595ff00e070c
sudo apt-get update -q && sudo apt-get install -y openscap-scanner
mkdir -p ~/cis && chmod 700 ~/cis && cd ~/cis
sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_level1_server --results cis-before-backup-lab.xml --report cis-before-backup-lab.html ~/ssg-ubuntu2404-ds.xml > cis-before-backup-lab.txt   # exit status 2: some rules failed
sudo chown ghaith: cis-before-backup-lab.* && chmod 600 cis-before-backup-lab.*
tr -d '\r' < cis-before-backup-lab.txt | grep '^Result' | sort | uniq -c   # how many passed, failed, not applicable

# on DimenstionX: the reports are kept here, never in the repo
cd ~/cis-reports && scp 'backup-lab:cis/cis-before-backup-lab.*' . && chmod 600 cis-before-*
```

## Rebuild (keeps the data disk)

`DATA_DISK=reuse` in the settings file. The old system disk is renamed, not
deleted, until the new machine passes.

```bash
sudo virsh shutdown backup-lab                               # the old machine off first
sudo virsh net-dhcp-leases default --mac 52:54:00:41:84:3a   # the old lease stays listed; bootstrap.sh stops if the new machine gets a second one
[ "$(hostname)" = "DimenstionX" ] && [ "$(sudo virsh domstate backup-lab)" = "shut off" ] && \
  sudo virsh dumpxml backup-lab > ~/lab-images/backup-lab/backup-lab-old.xml && \
  sudo virsh undefine backup-lab && \
  sudo mv -n /var/lib/libvirt/images/backup-lab.qcow2 /var/lib/libvirt/images/backup-lab-old.qcow2 && \
  rm ~/lab-images/backup-lab/user-data ~/lab-images/backup-lab/meta-data && echo "ready for the rebuild"
~/linux-server-toolkit/bootstrap/bootstrap.sh ~/lab-images/backup-lab/backup-lab.conf   # the build, as above
KH=~/lab-images/backup-lab/known_hosts-<instance-id>              # the file bootstrap.sh wrote
ssh-keygen -lf "$KH"                                              # the fingerprint bootstrap.sh printed
ssh-keygen -R 192.168.122.239 && cat "$KH" >> ~/.ssh/known_hosts  # the host trusts the new key
```

Then pin the new key on `toolkit-lab` ([toolkit-lab-build.md](toolkit-lab-build.md),
step 10). Once backups arrive in the new vault:

```bash
[ "$(hostname)" = "DimenstionX" ] && sudo rm /var/lib/libvirt/images/backup-lab-old.qcow2 && \
  rm ~/lab-images/backup-lab/backup-lab-old.xml
```

## Restore a Backup

Only the admin can read the vault, and only the host holds the key that opens
a backup, so a restore goes through the host. Ran on 2026-10-10: the newest
backup came back to `toolkit-lab`, opened with the vault key on the host, and
matched the local copy.

```bash
# inside backup-lab: a copy of the newest pair for the admin; the vault keeps its own
N=$(sudo ls -t /srv/backup/vault/toolkit-lab | grep -E '\.tar\.gz\.age$' | head -n 1); echo "$N"
[ "$(hostname)" = "backup-lab" ] && mkdir -m 700 ~/restore-out && sudo install -o ghaith -g ghaith -m 600 \
    "/srv/backup/vault/toolkit-lab/$N" "/srv/backup/vault/toolkit-lab/$N.sha256" ~/restore-out/
# on DimenstionX: fetch the pair, check it, open it with the vault key, hand the archive to toolkit-lab
mkdir -m 700 ~/restore && scp 'backup-lab:restore-out/backup-linux-server-toolkit-*.tar.gz.age*' ~/restore/
cd ~/restore && A=$(ls backup-linux-server-toolkit-*.tar.gz.age) && sha256sum -c "$A.sha256"   # must say: OK
age -d -i ~/vault-keys/backup-vault-key.txt -o "${A%.age}" "$A" && tar -tzf "${A%.age}" > /dev/null && echo "opened, and whole"
ssh ghaith@192.168.122.14 'mkdir -m 700 restore-test' && scp "${A%.age}" ghaith@192.168.122.14:restore-test/
# on toolkit-lab: compare with the local copy, unpack, compare
cd ~/restore-test && A=$(ls backup-linux-server-toolkit-*.tar.gz) && cmp "$A" "/var/backups/linux-server-toolkit/$A" && echo "same as the local copy"
tar -xzf "$A"                                                                     # unpacks into ./linux-server-toolkit
git -C linux-server-toolkit fsck --no-progress                                   # the repo inside is whole
cmp linux-server-toolkit/docs/journal.md ~/linux-server-toolkit/docs/journal.md  # a file that is not on GitHub came back
```

Afterwards remove the three copies: `~/restore-out` in the admin's home on
`backup-lab`, `~/restore` on the host (it holds the opened archive),
`~/restore-test` on `toolkit-lab`.

## If bootstrap.sh stops after the disks

From its fifth part on (the disks), a `STOP` removes nothing, and the next run
stops at the guards until the leftovers are gone. Remove them by hand, each
name written out (here the test machine `backup-test`):

```bash
sudo virsh list --all; sudo ls -l /var/lib/libvirt/images/; ls -la ~/lab-images/backup-test/   # look first
[ "$(hostname)" = "DimenstionX" ] && sudo virsh destroy backup-test     # only if it is running
[ "$(hostname)" = "DimenstionX" ] && sudo virsh undefine backup-test    # never --remove-all-storage: it deletes the disks
[ "$(hostname)" = "DimenstionX" ] && sudo rm /var/lib/libvirt/images/backup-test.qcow2
[ "$(hostname)" = "DimenstionX" ] && sudo rm /var/lib/libvirt/images/backup-test-data.qcow2   # DATA_DISK=new only; with reuse it is the vault
rm ~/lab-images/backup-test/user-data ~/lab-images/backup-test/meta-data   # and known_hosts-<instance-id>, if written
sudo virsh net-dhcp-leases default --mac 52:54:00:7e:57:01   # wait until no lease is listed before the next run
```

## Recorded Values

| Item | Value |
|---|---|
| MAC address | `52:54:00:41:84:3a` (kept on every build) |
| IP address | `192.168.122.239`, reserved |
| Receive user | `backup-recv`, uid `999`, gid `988` (first build; the system picks them) |
| rsync / rrsync | `3.2.7-1ubuntu1.5` |
| cloud-init | `26.1-0ubuntu1~24.04.1` (already in the image) |
| Push key accepted | `SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ`, only from `192.168.122.14` |
| First build (by hand) | 2026-09-27; host key `SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc` |
| Rebuild with `bootstrap.sh` | 2026-10-01, instance-id `backup-lab-20261001-105217`; host key `SHA256:ZXt3EQtt9YgiaLH40yNORJ9ihQxGRTfKSgWSeC83Cu0` |
| Rebuild for v2.1 | 2026-10-03, instance-id `backup-lab-20261003-134933`; host key `SHA256:SLZZCPL1wgBq9e2yt9mgwtnuFMCghuXQmcbFSzEDQaU` |
| Rebuild for v2.2, with the firewall | 2026-10-04, instance-id `backup-lab-20261004-113055`; host key `SHA256:kHKDfiiTkhdOUzwyqR52M6IDDON4Y3V4DSvEvt3PbUk` |
| Rebuild for v2.2, hardened (current) | 2026-10-10, instance-id `backup-lab-20261010-134847`; host key `SHA256:4xjtminFDL0QMinhiI2sFeTQhs4q9bmILkikMAmRppk` |
| Firewall | `firewall/policy.conf`, the lines of `backup-lab`: 2 rules in, 6 out, everything else refused both ways; `firewall-check.timer` compares every 4 hours |
| First CIS report | 2026-10-04, after the firewall step: 236 passed, 107 failed, 65 not applicable (Level 1 - Server, 408 rules) |
| Last CIS report | 2026-10-10: 298 passed, 45 failed, 65 not applicable (62 rules fixed since the first report) |
| Exit gate of v2.2 | 2026-10-10: the firewall matches the policy (8 rules); a connection out (to `toolkit-lab`, port 22) and a connection in (from `toolkit-lab`, port 80) refused, both in the kernel log; listening: port 22 and the DHCP client (UDP 68), port 53 on loopback only; no failed system unit; the daily check passed |
| Admin logins | from the host only, with no SSH agent: the passphrase is asked at every login (since 2026-10-10) |
| Sandbox of the three units | `systemd-analyze security`, before the rebuild of 2026-10-10 and after it: `backup-mover.service` 9.6 and 7.4, `vault-verify.service` 9.6 and 7.4, `firewall-check.service` 9.6 and 7.4 |
| Data disk | mounted `nosuid,nodev,noexec` |
| Stored backups | encrypted only, each pair immutable; the first one stored on 2026-10-10 (`backup-linux-server-toolkit-20261010-105952.tar.gz.age`); the 13 backups of before, not encrypted, were removed by hand |
| Vault key | made on the host on 2026-10-10 with `age` `1.3.1`; two copies, in `~/vault-keys` and `~/.vault-keys-copy` |
| Network card | libvirt's `clean-traffic` filter; no CD-ROM drive |
| Automatic updates | `unattended-upgrades` `2.9.1+nmu4ubuntu1`, already in the image: security updates only, every day; the machine restarts itself after an update that needs it, never while someone is logged in |
