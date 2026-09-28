# backup-lab: build guide (v2)

How `backup-lab` was built on `DimenstionX`: every step, the expected output,
and why. Use it to rebuild the machine. It is also the spec that `bootstrap.sh`
(v2, step 4) will automate.

| Part | State |
|---|---|
| Steps 1-12: image, disks, keys, cloud-init, first boot, SSH, data disk | Done, all expected outputs matched (2026-09-27) |
| Step 13: fixed addresses (v2, step 2) | Done, all expected outputs matched (2026-09-27) |
| Step 14: receive user and incoming folder (v2, step 3) | Done, all expected outputs matched (2026-09-27) |
| Step 15: the push key from `toolkit-lab` (v2, step 3) | Done, all expected outputs matched (2026-09-28) |
| Automated build: cloud-init template (v2, step 4) | Schema valid (2026-09-28) |
| Automated build: first boot of the template on a test VM | Next |

---

## What backup-lab is

A dedicated backup server ("the vault"). Its only job is to receive backups
from `toolkit-lab` and keep them safe. `toolkit-lab` will only be able to
**write new files** into an incoming folder, never read, change or delete the
stored backups.

## Decisions

| Decision | Why |
|---|---|
| Ubuntu 24.04 | Same as `toolkit-lab`, and suitable for the project. |
| Cloud image + cloud-init, not the ISO | The ISO needs a human to answer questions. A cloud image boots ready, and a config file sets it up: rebuildable with one command. |
| Independent disk copy | The vault must not depend on another file. |
| Two disks: system 10G + data 20G | Backups survive a rebuild of the system disk. |
| 1 vCPU, 1 GiB RAM | The job is small. |
| Admin: SSH key + sudo password | The key logs you in, the password makes you root. A stolen key alone is not root. |
| A separate admin key for backup-lab | If it leaks, revoke it without touching `toolkit-lab`. |
| Two copies (local + vault) | Known limit: both sit on the same physical disk. Accepted: the repo also lives on GitHub. |
| Fixed addresses by reservation on the host network | All addresses live in one place; the VMs keep their default network settings, so a rebuild changes nothing inside them. |
| A receive user `backup-recv`, limited by `rrsync -wo -no-del` | `toolkit-lab` can only write into `incoming`: no reading, no deleting, no shell. |
| The push key works only from `toolkit-lab`'s address, with `restrict` | A stolen copy is useless from another machine, and the key gets no terminal and no forwarding. |

## Where the secrets live

| File | Location | Mode |
|---|---|---|
| `~/.ssh/backup-lab-admin` (passphrase) | `DimenstionX` only | `600` |
| `~/lab-images/backup-lab/user-data` (password hash) | `DimenstionX` only, **never in git** | `600` |
| Console / sudo password | Password manager only | - |

---

## Step 1: Download the cloud image

On `DimenstionX`, as your **normal user** (never download as root).

```bash
mkdir -p ~/lab-images && cd ~/lab-images
curl -fLO https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img
curl -fLO https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS
curl -fLO https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS.gpg
```

`-f` fails on a server error, `-L` follows redirects, `-O` keeps the file name.

## Step 2: Verify the image

```bash
gpg --keyid-format long --keyserver hkps://keyserver.ubuntu.com \
    --recv-keys D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81
gpg --fingerprint D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
```

Expected:
- Fingerprint `D2EB 4462 6FDD C30B 513D  5BB7 1A5D 6C4C 7DB8 7C81`. Compare it
  with the [official page](https://ubuntu.com/docs/public-images/public-images-how-to/verify-image-checksum/), not with this file.
- `Good signature`, plus a `WARNING: ... not certified` line (normal: your
  fingerprint check replaces that trust).
- `ubuntu-24.04-server-cloudimg-amd64.img: OK`

Failure test (must print `BAD signature`):

```bash
{ cat SHA256SUMS; echo "tampered"; } > SHA256SUMS.bad
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS.bad
rm SHA256SUMS.bad
```

**Why two checks:** the checksum proves the download is not corrupted. The
signature proves the checksum file really comes from Ubuntu.

## Step 3: Protect the base image

```bash
chmod 444 ~/lab-images/ubuntu-24.04-server-cloudimg-amd64.img
```

The verified image is never edited. Keep `SHA256SUMS*` next to it to re-check.

## Step 4: Create the disks

**Guard first.** `qemu-img` overwrites existing files without asking: on a live
vault this wipes every backup. This must print nothing:

```bash
for f in backup-lab.qcow2 backup-lab-data.qcow2; do
    sudo test -e "/var/lib/libvirt/images/$f" && echo "STOP: $f already exists"
done
```

```bash
sudo qemu-img convert -p -O qcow2 ~/lab-images/ubuntu-24.04-server-cloudimg-amd64.img /var/lib/libvirt/images/backup-lab.qcow2
sudo qemu-img resize /var/lib/libvirt/images/backup-lab.qcow2 10G
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/backup-lab-data.qcow2 20G
sudo chmod 600 /var/lib/libvirt/images/backup-lab.qcow2 /var/lib/libvirt/images/backup-lab-data.qcow2
```

- `convert`: an independent copy (and uncompressed, so faster).
- `resize`: cloud-init grows the root partition to 10G on first boot.
- `create`: the empty data disk, formatted inside the VM (step 11).
- `chmod 600`: `qemu-img` as root makes `644` files, readable by your normal user.

Verify:

```bash
sudo qemu-img info /var/lib/libvirt/images/backup-lab.qcow2
sudo ls -lZ /var/lib/libvirt/images/
head -c 3 /var/lib/libvirt/images/backup-lab-data.qcow2; echo
```

Expected: `virtual size: 10 GiB` and **no `backing file` line**; both disks
`-rw-------. root root` with type `virt_image_t`; `head`: `Permission denied`.

## Step 5: Create the admin SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/backup-lab-admin -C "backup-lab-admin@DimenstionX"
```

Set a passphrase. Check with `ls -l ~/.ssh/` before and after: only two new
files appear, the other keys are untouched.

## Step 6: Write the cloud-init files

```bash
mkdir -p ~/lab-images/backup-lab
```

The blocks below are **file contents, not commands**. Paste each one into vim
(`:set paste`, `i`, paste, `Esc`, `:set nopaste`, `:wq`).

**`~/lab-images/backup-lab/meta-data`**

```yaml
# meta-data: the machine's identity for cloud-init.
# instance-id: cloud-init runs its first-boot setup ONCE per id.
#              Change the id and the setup runs again.
instance-id: backup-lab-01
# local-hostname: the machine's name (you will see it in the prompt: ghaith@backup-lab).
local-hostname: backup-lab
```

**`~/lab-images/backup-lab/user-data`** (the two `<...>` are filled in step 7)

```yaml
#cloud-config
# ^ Line 1 MUST be exactly "#cloud-config", or cloud-init ignores the file.
#
# cloud-init reads this file on the FIRST boot and applies it.
# It lives on DimenstionX only. NEVER commit it: it holds the password hash.

# Write the hostname into /etc/hosts, so sudo does not print
# "unable to resolve host".
manage_etc_hosts: true

# Only "ghaith" is created: the image's default "ubuntu" user is NOT.
users:
  - name: ghaith                        # the admin account on backup-lab
    shell: /bin/bash                    # login shell
    groups: [sudo]                      # may use sudo, and sudo ASKS for the password
    lock_passwd: false                  # false = the password below is active
    passwd: "<CONSOLE_PASSWORD_HASH>"   # a HASH of the password, not the password itself
    ssh_authorized_keys:                # public keys allowed to log in over SSH
      # from="..." = this key works ONLY from DimenstionX (192.168.122.1).
      - 'from="192.168.122.1" <ADMIN_PUBLIC_KEY>'

# SSH never accepts passwords, only keys. The password is for the
# local console and for sudo only.
ssh_pwauth: false

# No direct root login. Admin work goes through "ghaith" + sudo.
disable_root: true

# On first boot: refresh the package lists, then install all pending
# security fixes. The image is always older than today.
package_update: true
package_upgrade: true
```

## Step 7: Fill the placeholders

The hash never appears on screen, and nothing is copied by hand.

```bash
cd ~/lab-images/backup-lab
openssl passwd -6 > pw.hash          # asks for the new password; the hash goes into the file
chmod 600 pw.hash
sed -i "s|<CONSOLE_PASSWORD_HASH>|$(cat pw.hash)|" user-data
sed -i "s|<ADMIN_PUBLIC_KEY>|$(cat ~/.ssh/backup-lab-admin.pub)|" user-data
rm pw.hash
chmod 600 user-data
```

`sed -i "s|A|B|" file` replaces `A` with `B` inside the file. `|` is the
separator because a hash can contain `/`.

Verify (safe to share, the hash is hidden):

```bash
grep -n '<' user-data
cat -n user-data | sed 's/\$6\$[^"]*/$6$<hidden>/'
```

Expected: `grep` prints nothing; `passwd: "$6$<hidden>"`; the key line starts
with `'from="192.168.122.1" ssh-ed25519`.

## Step 8: First boot

```bash
sudo virt-install \
  --connect qemu:///system \
  --name backup-lab \
  --osinfo ubuntu24.04 \
  --memory 1024 \
  --vcpus 1 \
  --import \
  --disk path=/var/lib/libvirt/images/backup-lab.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/backup-lab-data.qcow2,format=qcow2,bus=virtio \
  --network network=default,model=virtio,mac=52:54:00:41:84:3a \
  --cloud-init "user-data=$HOME/lab-images/backup-lab/user-data,meta-data=$HOME/lab-images/backup-lab/meta-data" \
  --graphics none \
  --console pty,target_type=serial
```

- `--import`: no installer, boot the disk directly.
- First disk = `vda` (system), second = `vdb` (data).
- `mac=`: keeps the network card address, so the address reservation
  (step 13) still applies after a rebuild. The first build ran without it:
  libvirt picked this value, and it is now fixed.
- `--cloud-init`: packs the two files into a small ISO, attached for the first
  boot only. Use `$HOME`, not `~`: `~` is not expanded inside `user-data=~/...`.

You land on the VM's console. Wait for `Cloud-init v. ... finished`, then log
in as `ghaith`. Leave the console with `Ctrl+]`.

## Step 9: Verify

Inside the VM (console):

```bash
cloud-init status --wait --long
sudo cloud-init schema --system
lsblk
getent passwd ubuntu; echo "exit=$?"
ip -4 addr show
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Expected: `status: done` with `errors: []`; sudo asks for the password, then
`Valid schema user-data`; `vda` 10G with `vda1` on `/`, `vdb` 20G empty;
`exit=2` (no `ubuntu` user); an address `192.168.122.x`; the host key
fingerprint (write it down: step 10 needs it).

From `DimenstionX`:

```bash
sudo ls -lZ /var/lib/libvirt/images/ | grep -E 'backup-lab|toolkit-lab'
```

Expected: `backup-lab` disks owned by `qemu qemu`, still `-rw-------`, label
`svirt_image_t:s0:cX,cY` with a pair **different** from `toolkit-lab`. SELinux
uses that pair to stop one VM from touching another VM's disks.

## Step 10: First SSH login and failure tests

```bash
ssh -i ~/.ssh/backup-lab-admin -o IdentitiesOnly=yes ghaith@<VM_IP>
```

`IdentitiesOnly=yes` = offer only this key. At `Are you sure...?`, **paste the
fingerprint** from step 9: SSH compares it and refuses on a mismatch.

Failure tests, both must print `Permission denied (publickey).`:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive ghaith@<VM_IP>
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes ghaith@<VM_IP>
```

The first proves SSH passwords are off (no password prompt at all). The second
proves another machine's key does not open backup-lab.

## Step 11: Data disk

Run **inside backup-lab** (SSH from `DimenstionX`). The prompt must say
`ghaith@backup-lab`.

| Choice | Why |
|---|---|
| GPT + one partition | Tools see the disk as used: nobody mistakes it for an empty disk |
| `ext4` | Same as the system disk, familiar tools |
| Mounted on `/srv/backup` | `/srv` is the usual place for a server's data |
| Mounted by `UUID` | Names like `vdb` can change; the UUID does not |
| No `nofail` | If the disk is missing, boot stops at the console instead of running without its storage |
| `defaults` options | Hardening options (`noexec,nodev,nosuid`) come in v3 |

**Guard.** Any output other than the expected one means **stop**.

```bash
hostname                 # must print: backup-lab
lsblk -f /dev/vdb        # vdb: no FSTYPE, no partitions
sudo wipefs /dev/vdb     # must print NOTHING (no old filesystem)
```

**Partition and format.** Each destructive command checks the machine name
itself: `&&` runs the command only if the check passes.

```bash
[ "$(hostname)" = "backup-lab" ] && sudo parted --script /dev/vdb mklabel gpt mkpart backup-data ext4 0% 100%
sudo udevadm settle      # wait until /dev/vdb1 exists
lsblk /dev/vdb
[ "$(hostname)" = "backup-lab" ] && sudo mkfs.ext4 -L backup-data /dev/vdb1
```

Expected: `vdb1` is `20G`; `mkfs` prints a `Filesystem UUID` and ends with
`done`.

**Mount point and fstab.**

```bash
sudo mkdir -p /srv/backup
[ "$(hostname)" = "backup-lab" ] && sudo cp /etc/fstab /etc/fstab.bak
UUID=$(sudo blkid -s UUID -o value /dev/vdb1)
echo "UUID is: $UUID"
[ "$(hostname)" = "backup-lab" ] && [ -n "$UUID" ] && echo "UUID=$UUID  /srv/backup  ext4  defaults  0  2" | sudo tee -a /etc/fstab
cat -n /etc/fstab
```

- `| sudo tee -a`, not `sudo echo ... >>`: your shell opens the file for `>>`
  **before** `sudo` runs, as your normal user, and fails.
- `[ -n "$UUID" ]`: never write an empty UUID (the VM would not boot).
- The last `2`: check this disk at boot, after the root disk.

Expected: the UUID is the one `mkfs` printed; our line is at the end, once.

**Verify before any reboot.**

```bash
sudo systemctl daemon-reload     # systemd turns fstab into mount units: reload after editing
sudo findmnt --verify
sudo mount -a                    # a mistake in fstab shows here, not at boot
findmnt /srv/backup
df -h /srv/backup
ls -la /srv/backup
```

Expected: `0 errors`; `mount -a` prints nothing; `/srv/backup` from
`/dev/vdb1`, `ext4`; size `20G`, available `19G` (ext4 keeps 5% for root);
only `lost+found` inside (proof you see the new disk, not the empty folder on
the system disk).

## Step 12: Power off and start (the end of the "install")

Inside backup-lab:

```bash
sudo poweroff
```

**What happens:** `virt-install` is still waiting in its terminal. For it, the
first boot is the "install". At the first power-off it removes the cloud-init
ISO and **starts the VM again by itself** (the `--noreboot` option would stop
this). So `virsh start` now answers `Domain is already active`: that is normal.

On `DimenstionX`:

```bash
sudo virsh list --all
sudo virsh domblklist backup-lab --details --inactive
sudo ls -lZ /var/lib/libvirt/images/ | grep backup-lab
sudo ls -l /var/lib/libvirt/boot/
```

Expected:
- `backup-lab` is `running`, with a new Id.
- `vda`, `vdb`, and `cdrom sda -`: the ISO is ejected, the empty drive stays.
- A **new** random sVirt pair (it changes at every start).
- `/var/lib/libvirt/boot/` is empty: the ISO, which held the password hash, is
  deleted.

Inside backup-lab again (SSH):

```bash
findmnt /srv/backup
lsblk
```

Expected: `/srv/backup` is mounted by itself; `sr0` is now an empty `1024M`
drive (it was `370K` with the ISO).

## Step 13: Fixed addresses (v2, step 2)

Run on `DimenstionX`, with both VMs running. Reserves each VM's address on
the `default` network, so the `from=` restrictions (v2, step 3) stay valid.

**Why:** the network lends addresses (DHCP leases). A machine usually gets the
same address back, but that is a habit, not a promise: while a VM is off,
nothing holds its address, and a rebuilt VM has a new MAC. A reservation ties
one MAC to one address, and the network never gives that address to anyone
else.

| Machine | MAC | Address |
|---|---|---|
| `backup-lab` | `52:54:00:41:84:3a` | `192.168.122.239` |
| `toolkit-lab` | `52:54:00:ae:58:55` | `192.168.122.14` |

`toolkit-lab` is included because backup-lab's receive key will accept it
only from its address. The existing addresses were kept: no restart, nothing
changes for the running VMs.

**Backup of the network definition.**

```bash
sudo virsh net-dumpxml default --inactive > ~/lab-images/default-network.before-v2-step2.xml
cat -n ~/lab-images/default-network.before-v2-step2.xml
```

`>` works here without `tee`: the file is in your own home folder. Expected:
12 lines plus one empty line (`virsh` adds it), no `<host` line.

**Read the MACs from libvirt.**

```bash
hostname      # must print: DimenstionX
MAC_BL=$(sudo virsh domiflist backup-lab  | grep -oE '52:54:00(:[0-9a-f]{2}){3}')
MAC_TL=$(sudo virsh domiflist toolkit-lab | grep -oE '52:54:00(:[0-9a-f]{2}){3}')
echo "backup-lab MAC:  $MAC_BL"
echo "toolkit-lab MAC: $MAC_TL"
```

Never type a MAC by hand: a wrong MAC reserves the address for a machine that
does not exist, and the real machine is refused it. Expected: the two MACs in
the table. Run the rest of this step in the same terminal (the variables live
there only).

**Reserve.**

```bash
[ "$(hostname)" = "DimenstionX" ] && [ -n "$MAC_BL" ] && \
  sudo virsh net-update default add ip-dhcp-host \
  "<host mac='$MAC_BL' name='backup-lab' ip='192.168.122.239'/>" \
  --live --config
[ "$(hostname)" = "DimenstionX" ] && [ -n "$MAC_TL" ] && \
  sudo virsh net-update default add ip-dhcp-host \
  "<host mac='$MAC_TL' name='toolkit-lab' ip='192.168.122.14'/>" \
  --live --config
```

- `--live`: the running network uses it now. `--config`: saved, so it survives
  a network or host restart. Always both.
- The network is not restarted; running VMs notice nothing.
- Undo: the same command with `delete` instead of `add`.

Expected, twice: `Updated network default persistent config and live state`.

**Verify.**

```bash
diff ~/lab-images/default-network.before-v2-step2.xml <(sudo virsh net-dumpxml default --inactive)
sudo virsh net-dumpxml default | grep '<host'
sudo cat /var/lib/libvirt/dnsmasq/default.hostsfile
```

Expected: `9a10,11` and two `>` lines with the reservations, nothing else;
the same two lines in the live definition; the file the address server reads
holds `MAC,address,name` for both machines.

**Failure tests.** Both must print `there is an existing dhcp host entry` and
`exit=1`:

```bash
# Another machine asks for backup-lab's address
sudo virsh net-update default add ip-dhcp-host \
  "<host mac='52:54:00:00:00:01' name='intruder' ip='192.168.122.239'/>" \
  --live --config; echo "exit=$?"
# backup-lab's own MAC asks for a second address
sudo virsh net-update default add ip-dhcp-host \
  "<host mac='$MAC_BL' name='backup-lab-2' ip='192.168.122.50'/>" \
  --live --config; echo "exit=$?"
```

Then run the `diff` again: still the same two lines (the tests left no trace).

**Full cycle.** Run it in three parts, never as one pasted block:
`virsh shutdown` only asks the VM to power off and returns at once.

```bash
sudo virsh shutdown backup-lab
sudo virsh shutdown toolkit-lab
```

Repeat this until both are `shut off` (about a minute):

```bash
sudo virsh list --all
```

Then start them, wait about 30 seconds, and check:

```bash
sudo virsh start toolkit-lab
sudo virsh start backup-lab
```

```bash
sudo virsh net-dhcp-leases default
ssh -i ~/.ssh/backup-lab-admin -o IdentitiesOnly=yes ghaith@192.168.122.239
uptime       # inside backup-lab
```

Expected: `toolkit-lab` on `192.168.122.14/24` and `backup-lab` on
`192.168.122.239/24`, with the MACs from the table and expiry times later than
before the shutdown (new leases); SSH logs in with no host key warning and no
first-connect question; `uptime` shows a few minutes. `No route to host`
means the VM is not on the network yet (still off or booting): wait and retry.

The full cycle proves nothing broke. It cannot prove the reservation on its
own (the habit would give the same address): the address server's file and
the refused tests prove that.

**SSH shortcut on `DimenstionX`.** With the address fixed, `ssh backup-lab`
can replace the long command. In `~/.ssh/config` (mode `600`):

```
Host backup-lab
    HostName 192.168.122.239
    User ghaith
    IdentityFile ~/.ssh/backup-lab-admin
    IdentitiesOnly yes
```

`IdentitiesOnly yes` keeps the rule from step 10: offer only this key.

## Step 14: Receive user and incoming folder (v2, step 3)

Run inside backup-lab (`ssh backup-lab`). Prepares the account that
`toolkit-lab`'s backup key will log in to, and the only folder it can write
to. The key itself comes next.

**How the restriction works:** a key line in `authorized_keys` that starts
with `command="..."` never runs what the client asks for. sshd runs the forced
command instead and puts the client's request in `SSH_ORIGINAL_COMMAND`.
`rrsync` reads that variable and allows only an rsync transfer inside one
folder.

| Choice | Why |
|---|---|
| User `backup-recv`, system account (uid below 1000) | A service, not a person |
| Its own group only | Not in `sudo` or any other group |
| No password (locked) | No console login, no `su`. Key login still works: Ubuntu's sshd uses PAM (`usepam yes`) |
| Shell `/bin/sh` (`dash`) | With `bash`, startup files in the home can run before the forced command (`man rrsync`: BASH SECURITY ISSUE) |
| Home and `.ssh` owned by root, mode `755` | The user cannot change its own keys or restrictions |
| `/srv/backup/incoming`, owner `backup-recv`, mode `700` | Only it writes there; root reads it later |
| Forced command `/usr/bin/rrsync -wo -no-del /srv/backup/incoming` | Full path: no `PATH` lookup. `-wo` blocks reading, `-no-del` blocks deleting |

**Check rrsync and sshd.** `rrsync` ships inside the `rsync` package.

```bash
hostname                          # must print: backup-lab
apt-cache policy rsync | head -3
dpkg -L rsync | grep rrsync
ls -l /usr/bin/rrsync
readlink -f /bin/sh
rrsync -help
sudo sshd -T | grep -E '^(pubkeyauthentication|passwordauthentication|authorizedkeysfile|permituserenvironment|allowusers|allowgroups) '
```

Expected:
- `Installed` equals `Candidate` (`3.2.7-1ubuntu1.5` on the first build).
- `/usr/bin/rrsync` and `/usr/share/man/man1/rrsync.1.gz`.
- `-rwxr-xr-x root root`: nobody but root can edit the script that enforces
  the restriction.
- `/usr/bin/dash`.
- The options `-ro`, `-wo`, `-munge`, `-no-del`, `-no-lock`, `-help`.
- `pubkeyauthentication yes`, `passwordauthentication no`,
  `authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2`,
  `permituserenvironment no` (a key line cannot set variables such as `PATH`);
  no `allowusers` or `allowgroups` line (it would refuse the new user).

Notes:
- `-wo` alone still lets the client delete (`--delete`): hence `-no-del`.
- This version has no option to stop overwriting a file with the same name in
  `incoming`. That protection comes from the mover (v2, step 5).
- The `man rrsync` synopsis says `-rw`: a typo. `rrsync -help` comes from the
  program itself.

**Guard.** `install -d` on an existing folder changes its owner and mode
without asking. This must print `exit=2` twice and nothing else:

```bash
getent passwd backup-recv; echo "exit=$?"
getent group backup-recv; echo "exit=$?"
for d in /home/backup-recv /srv/backup/incoming; do
    sudo test -e "$d" && echo "STOP: $d already exists"
done
```

**Create.**

```bash
[ "$(hostname)" = "backup-lab" ] && sudo useradd --system --user-group \
    --home-dir /home/backup-recv --no-create-home \
    --shell /bin/sh --comment "receives backups from toolkit-lab" backup-recv
[ "$(hostname)" = "backup-lab" ] && sudo install -d -o root -g root -m 755 /home/backup-recv /home/backup-recv/.ssh
[ "$(hostname)" = "backup-lab" ] && sudo install -d -o backup-recv -g backup-recv -m 700 /srv/backup/incoming
```

- `--no-create-home`: otherwise `useradd` makes the home owned by the user and
  copies startup files (`.bashrc`, `.profile`) into it.
- `useradd` leaves the password locked by itself.
- `install -d`: creates the folder with owner and mode in one step (instead of
  `mkdir` + `chown` + `chmod`).

Expected: all three print nothing.

**Verify.**

```bash
getent passwd backup-recv
id backup-recv
sudo passwd -S backup-recv
sudo sshd -T | grep -x 'usepam yes'
ls -ld /home/backup-recv /home/backup-recv/.ssh /srv/backup/incoming
```

Expected: uid below 1000, home `/home/backup-recv`, shell `/bin/sh`; one
group only (uid and gid may differ); `L` (locked) as the second word;
`usepam yes`; home and `.ssh` `drwxr-xr-x root root`, `incoming`
`drwx------ backup-recv backup-recv`.

**Failure tests.** `sudo -u backup-recv` runs a command as that user, without
its password.

```bash
sudo -u backup-recv touch /home/backup-recv/probe; echo "exit=$?"
sudo -u backup-recv touch /home/backup-recv/.ssh/authorized_keys; echo "exit=$?"
ls /srv/backup/incoming; echo "exit=$?"
sudo -l -U backup-recv
```

Expected: `Permission denied` and `exit=1` twice (it cannot write in its own
home or `.ssh`); `Permission denied` and `exit=2` (`ghaith` cannot look
inside `incoming`); `User backup-recv is not allowed to run sudo on
backup-lab.`

**Success test.**

```bash
sudo -u backup-recv touch /srv/backup/incoming/probe; echo "exit=$?"
sudo ls -l /srv/backup/incoming
[ "$(hostname)" = "backup-lab" ] && sudo -u backup-recv rm /srv/backup/incoming/probe
sudo ls -la /srv/backup/incoming
```

Expected: `exit=0`; `probe` owned by `backup-recv backup-recv`, mode
`-rw-rw-r--`; after `rm`, only `.` and `..`.

The group can write (`rw-` twice) because PAM gives umask `002` to a user
whose name matches its group (`USERGROUPS_ENAB yes` in `/etc/login.defs`).
Harmless: the group `backup-recv` has one member. Check:
`sudo -u backup-recv sh -c umask` prints `0002`.

**Rehearsal of the forced command.** The exact line, as the real user, on the
real folder. `sudo` clears most variables, so `env` passes the request.

```bash
sudo -u backup-recv env SSH_ORIGINAL_COMMAND='rsync --server --sender -vlogDtpre.iLsfxCIvu . .' \
    /usr/bin/rrsync -wo -no-del /srv/backup/incoming </dev/null; echo "exit=$?"
sudo -u backup-recv env SSH_ORIGINAL_COMMAND='rsync --server -vlogDtpre.iLsfxCIvu --delete . .' \
    /usr/bin/rrsync -wo -no-del /srv/backup/incoming </dev/null; echo "exit=$?"
```

- The first is what rsync sends to download (`--sender`: the server sends).
  The second is an upload that also asks to delete.
- `</dev/null`: with no terminal on its input, rrsync prints only the error
  line, not its full help.

Expected, each followed by `exit=1`:
- `/usr/bin/rrsync error: reading from write-only server is not allowed`
- `/usr/bin/rrsync error: option --delete has been disabled on this server.`

## Step 15: The push key from toolkit-lab (v2, step 3)

Installs the push key made on `toolkit-lab` (toolkit-lab guide, step 1) for
`backup-recv`, with its limits. A public key is not a secret, but it must
arrive unchanged: its fingerprint is compared at every stop with the one
recorded on `toolkit-lab`.

The line that goes into `/home/backup-recv/.ssh/authorized_keys`:

```
restrict,from="192.168.122.14",command="/usr/bin/rrsync -wo -no-del /srv/backup/incoming" ssh-ed25519 AAAA... backup-push@toolkit-lab
```

| Part | What it does |
|---|---|
| `restrict` | Turns off every extra at once: no terminal, no port forwarding, no agent forwarding |
| `from="192.168.122.14"` | The key works only from `toolkit-lab`'s reserved address (step 13) |
| `command="..."` | Whatever the client asks, sshd runs this instead (step 14) |
| File owned by root, mode `644` | `backup-recv` can read its key line, but cannot remove the limits |

**Copy the public key out (on `toolkit-lab`).**

```bash
hostname      # must print: toolkit-lab
FP='SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ'
sudo cat /home/backup-push/.ssh/backup-lab-push.pub > /home/ghaith/backup-lab-push.pub
ssh-keygen -lf /home/ghaith/backup-lab-push.pub | grep -qF "$FP" && echo MATCH || echo "STOP: different key"
```

Only `cat` runs as root: the `>` runs as you, so the copy lands in your home,
owned by you. Expected: `MATCH`.

**Carry it through `DimenstionX`.** `toolkit-lab` has no admin path to
backup-lab, and must never get one.

```bash
hostname      # must print: DimenstionX
FP='SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ'
scp ghaith@192.168.122.14:backup-lab-push.pub ~/lab-images/backup-lab/backup-lab-push.pub
ssh-keygen -lf ~/lab-images/backup-lab/backup-lab-push.pub | grep -qF "$FP" && echo MATCH || echo "STOP: different key"
scp ~/lab-images/backup-lab/backup-lab-push.pub backup-lab:
```

Expected: `MATCH`, and both copies finish with no error. The copy in
`~/lab-images/backup-lab/` stays: it is public, and a rebuild of backup-lab
needs it.

**Guard (inside backup-lab).**

```bash
hostname                                  # must print: backup-lab
FP='SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ'
ssh-keygen -lf ~/backup-lab-push.pub | grep -qF "$FP" && echo MATCH || echo "STOP: different key"
wc -l < ~/backup-lab-push.pub             # must print: 1
command -v rrsync                         # must print: /usr/bin/rrsync
sudo namei -l /home/backup-recv/.ssh
sudo ls -la /home/backup-recv/.ssh/
sudo test -e /home/backup-recv/.ssh/authorized_keys && echo "STOP: authorized_keys already exists"
```

Expected: `MATCH`, `1`, `/usr/bin/rrsync`; every `namei` line
`drwxr-xr-x root root`; only `.` and `..` in `.ssh`; the last line prints
nothing.

**Why `namei`:** sshd reads `authorized_keys` as `backup-recv`, not as root.
A folder closed to it (for example `drwx------ root root`) makes the login
fail although everything looks right. sshd also refuses the file if anyone
other than root or the user can change a folder on its path.

**Build the line in a temporary file.**

```bash
# Single quotes keep the double quotes inside the options exactly as written
OPTS='restrict,from="192.168.122.14",command="/usr/bin/rrsync -wo -no-del /srv/backup/incoming"'
printf '%s %s\n' "$OPTS" "$(cat ~/backup-lab-push.pub)" > ~/authorized_keys.new
cat -n ~/authorized_keys.new
ssh-keygen -lf ~/authorized_keys.new | grep -qF "$FP" && echo MATCH || echo "STOP: line is broken"
```

`ssh-keygen -lf` reads `authorized_keys` lines too: the same fingerprint
proves the options parse and the key is intact. Expected: one numbered line,
shaped like the line above; `MATCH`.

**Install.**

```bash
[ "$(hostname)" = "backup-lab" ] && ! sudo test -e /home/backup-recv/.ssh/authorized_keys && \
  sudo install -o root -g root -m 644 ~/authorized_keys.new /home/backup-recv/.ssh/authorized_keys
```

`install` copies the file with its owner and mode in one step. It also
overwrites without asking: hence the `! sudo test -e` guard. Expected:
nothing.

**Verify.**

```bash
sudo ls -l /home/backup-recv/.ssh/
sudo ssh-keygen -lf /home/backup-recv/.ssh/authorized_keys
sudo diff ~/authorized_keys.new /home/backup-recv/.ssh/authorized_keys && echo SAME
sudo -u backup-recv test -r /home/backup-recv/.ssh/authorized_keys && echo "backup-recv: can read"
sudo -u backup-recv test -w /home/backup-recv/.ssh/authorized_keys && echo "STOP: backup-recv can write"
```

Expected: `-rw-r--r-- 1 root root 195 ... authorized_keys`; the push key
fingerprint with `backup-push@toolkit-lab (ED25519)`; `SAME`;
`backup-recv: can read`; the last line prints nothing.

**Clean up.**

```bash
rm /home/ghaith/backup-lab-push.pub /home/ghaith/authorized_keys.new   # on backup-lab
rm /home/ghaith/backup-lab-push.pub                                    # on toolkit-lab
```

Full paths: the original key files in `/home/backup-push/.ssh` on
`toolkit-lab` are never touched.

All the steps above were verified on the first build: from `toolkit-lab`,
`backup-push` can write a new file into `incoming`, and every other request
is refused.

---

## Automated build (v2, step 4)

`bootstrap.sh` (in progress) will build backup-lab with one command on
`DimenstionX`. The work inside the VM moves into cloud-init: the template
`bootstrap/user-data.template` carries steps 6-7 and replaces steps 11, 14
and 15. The script fills its `<...>` placeholders and writes the filled copy
to `~/lab-images/backup-lab/` (never committed: it holds the password hash).

### How cloud-init runs (seen on the first build)

- It runs in stages during boot: local, network, config, final. Each stage
  runs a fixed list of modules from `/etc/cloud/cloud.cfg`, in that order.
  The order of sections in `user-data` does not matter.
- A module with no section in `user-data` is skipped.
- Most modules run once per instance: a marker file in
  `/var/lib/cloud/instance/sem/` records each one. A new `instance-id` means a
  new, empty folder, so everything runs again.
- Here the seed disk is removed after the first boot, so on later boots
  `ds-identify` finds no data source and cloud-init stays off
  (`cloud-init status` says `disabled`). Everything must be right at the
  first boot.
- With a local seed (`dsmode=local`), the network stage's modules already run
  in the local stage.
- Ubuntu 24.04 keeps the name `cloud-init.service` for the network stage.
- The files in `/var/lib/cloud/instance/` that hold the user-data are
  root-only (`600`): list them, never print them (they contain the hash).

The modules the template uses, in the order they run:

| Stage | Modules |
|---|---|
| Network (local here) | `write_files` → `disk_setup` → `mounts` → `users_groups` → `ssh` → `set_passwords` |
| Config | `runcmd` (only writes its script) |
| Final | `package_update_upgrade_install` → `scripts_user` (runs the `runcmd` script) |

### Decisions

| Decision | Why |
|---|---|
| Mount by `LABEL=backup-data`, not UUID | The filesystem is made inside the VM at first boot: its UUID does not exist yet when the file is written. The label is chosen in the same file. A block copy of a disk duplicates a UUID too, so a UUID adds no safety here. |
| Mount options written out (`defaults`) | cloud-init's default options add `nofail`; the vault must not run without its disk (step 11). |
| `overwrite: false` and `partition: auto` | In cloud-init 26.1, a partition number skips only a filesystem with the same label and type, and formats over any other. `auto` formats only a partition with no filesystem. Never change the label after the first build. |
| `incoming` made in `runcmd`, after `findmnt /srv/backup` | It needs `backup-recv` and the mounted disk. If the disk is not mounted, the script stops instead of making `incoming` on the system disk. |
| `set -e` as the first `runcmd` line | `runcmd` becomes a `/bin/sh` script with no `set -e` of its own. |
| The key file written by `write_files`, owned by root | `write_files` runs before users exist, and gives any folder it creates the file's owner: the home and `.ssh` of `backup-recv` stay root's. |

Differences from the manual build: the `fstab` line also gets
`comment=cloudconfig` (cloud-init's mark on its own lines); the GPT partition
has no name (the filesystem label is what counts); the system picks the uid of
`backup-recv`.

### Check the template

On any machine with cloud-init (`toolkit-lab` here), in the repo:

```bash
cloud-init --version
grep -oE '<[A-Z_]+>' bootstrap/user-data.template | sort -u
cloud-init schema -c bootstrap/user-data.template --annotate
```

Expected: `26.1-0ubuntu1~24.04.1` (the same as backup-lab); five placeholders
(`<ADMIN_FROM>`, `<ADMIN_PUBLIC_KEY>`, `<CONSOLE_PASSWORD_HASH>`,
`<PUSH_FROM>`, `<PUSH_PUBLIC_KEY>`); `Valid schema
bootstrap/user-data.template`. A schema check reads the file only; the first
real boot of the template is the next test.

---

## Recorded on the first build

| Item | Value |
|---|---|
| Image build | 2026-09-11 (Ubuntu 24.04.5) |
| Host key (ED25519) | `SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc` (a rebuild makes a new one) |
| Data disk UUID | `6bd0eb4f-7e7f-42af-91c3-2120f4d0156e` |
| MAC address | `52:54:00:41:84:3a` (kept on rebuild, step 8) |
| IP address | `192.168.122.239`, reserved (step 13) |
| Receive user | `backup-recv`, uid `999`, gid `988` (step 14) |
| rsync / rrsync | `3.2.7-1ubuntu1.5` (step 14) |
| Push key accepted | `SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ`, only from `192.168.122.14` (step 15) |
| cloud-init | `26.1-0ubuntu1~24.04.1` (installed by the first boot's upgrade) |

## Lessons

- **Check which machine you are on before any destructive command.** Put the
  check inside the command: `[ "$(hostname)" = "backup-lab" ] && ...`.
- **"Stop" means any output that is not the expected one**, not only the case
  you were warned about.
- `qemu-img` as root creates `644` files: always `chmod 600` VM disks.
- `qemu-img create`/`convert` overwrite without asking: guard first.
- Your shell handles `*` and `>>` **before** `sudo` runs: in a `711` folder
  `*` matches nothing, and `sudo cmd >> file` fails. Use explicit file names
  and `| sudo tee -a file`.
- `~` is not expanded inside `key=~/path`: use `$HOME`.
- After editing `/etc/fstab`: `systemctl daemon-reload`, then `mount -a`,
  before any reboot.
- `virt-install --cloud-init` restarts the VM by itself at the first power-off.
- Never share the password hash, never commit `user-data`.
- After a rebuild, SSH warns `REMOTE HOST IDENTIFICATION HAS CHANGED`. Check
  the new fingerprint at the console first, then `ssh-keygen -R <VM_IP>`.
- A lease is a habit, not a promise: while a VM is off, nothing holds its
  address. A reservation makes it a promise.
- The reservation follows the MAC: a rebuild must reuse it (`mac=` in
  `virt-install`), or the machine gets a new address.
- Read values from the system (`MAC=$(...)`), never type them by hand.
- `virsh shutdown` only asks: it returns before the VM is off. Wait for
  `shut off` before `start`. A "repeat until" comment inside a pasted block
  does not wait.
- `No route to host` = the machine is not on the network (off or still
  booting), not a key problem.
- `install -d` on an existing folder changes its owner and mode without
  asking: guard first, like `qemu-img`.
- `rrsync -wo` blocks reading, not deleting: add `-no-del`.
- For a forced command, the user's shell matters: `bash` can run startup files
  from the home first. Use `/bin/sh` and a home owned by root.
- Trust the program over one line of its manual: the `man rrsync` synopsis
  says `-rw`, `rrsync -help` says `-wo`.
- `sudo` clears most environment variables: `sudo -u user env VAR=value cmd`.
- A user whose name matches its group gets umask `002` from PAM: its new files
  are group-writable.
- A public key is not a secret, but compare its fingerprint at every stop.
- sshd reads `authorized_keys` as the user, not as root: every folder on the
  path must let the user in. `namei -l` shows the whole path at once.
- `ssh-keygen -lf` reads `authorized_keys` lines too: check a key line before
  installing it.
- cloud-init gets one chance here: after the seed disk is removed it stays
  off. Test a template on a throwaway VM first.
- When the documentation is vague, read the code of the installed version:
  what `overwrite: false` protects in `fs_setup` depends on `partition`.
- The machine is the reference: the service name on Ubuntu 24.04 differs from
  the upstream documentation.

## Left for v3

- Remove the empty CD-ROM drive (fewer virtual devices).
- Mount options `noexec,nodev,nosuid` on `/srv/backup`.
- Limit how long the admin key stays unlocked in the desktop's SSH agent.
- Stop a VM from using an address that is not its own (libvirt
  `clean-traffic` filter): `from=` trusts the source address, and a
  reservation only controls what the network hands out.
