# backup-lab: build guide (v2, steps 1-2)

How `backup-lab` was built on `DimenstionX`: every step, the expected output,
and why. Use it to rebuild the machine. It is also the spec that `bootstrap.sh`
(v2, step 4) will automate.

| Part | State |
|---|---|
| Steps 1-12: image, disks, keys, cloud-init, first boot, SSH, data disk | Done, all expected outputs matched (2026-09-27) |
| Step 13: fixed addresses (v2, step 2) | Done, all expected outputs matched (2026-09-27) |

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

---

## Recorded on the first build

| Item | Value |
|---|---|
| Image build | 2026-09-11 (Ubuntu 24.04.5) |
| Host key (ED25519) | `SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc` (a rebuild makes a new one) |
| Data disk UUID | `6bd0eb4f-7e7f-42af-91c3-2120f4d0156e` |
| MAC address | `52:54:00:41:84:3a` (kept on rebuild, step 8) |
| IP address | `192.168.122.239`, reserved (step 13) |

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

## Left for v3

- Remove the empty CD-ROM drive (fewer virtual devices).
- Mount options `noexec,nodev,nosuid` on `/srv/backup`.
- Limit how long the admin key stays unlocked in the desktop's SSH agent.
- Stop a VM from using an address that is not its own (libvirt
  `clean-traffic` filter): `from=` trusts the source address, and a
  reservation only controls what the network hands out.
