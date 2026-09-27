# backup-lab: build guide (v2, step 1)

How `backup-lab` was built on `DimenstionX`: every step, the expected output,
and why. Use it to rebuild the machine. It is also the spec that `bootstrap.sh`
(v2, step 4) will automate.

| Part | State |
|---|---|
| Steps 1-10: image, disks, keys, cloud-init, first boot, SSH | Done, all expected outputs matched (2026-09-27) |
| Step 11: data disk | Next |
| Fixed IP address | v2, step 2 |

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
  --network network=default,model=virtio \
  --cloud-init "user-data=$HOME/lab-images/backup-lab/user-data,meta-data=$HOME/lab-images/backup-lab/meta-data" \
  --graphics none \
  --console pty,target_type=serial
```

- `--import`: no installer, boot the disk directly.
- First disk = `vda` (system), second = `vdb` (data).
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

_To be added after it is tested._

---

## Recorded on the first build

| Item | Value |
|---|---|
| Image build | 2026-09-11 (Ubuntu 24.04.5) |
| Host key (ED25519) | `SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc` (a rebuild makes a new one) |
| IP address | `192.168.122.239`, dynamic until step 2 of v2 |

## Lessons

- `qemu-img` as root creates `644` files: always `chmod 600` VM disks.
- `qemu-img create`/`convert` overwrite without asking: guard first.
- In a `711` folder your shell cannot expand `*` before `sudo` runs: use
  explicit file names.
- `~` is not expanded inside `key=~/path`: use `$HOME`.
- Never share the password hash, never commit `user-data`.
- After a rebuild, SSH warns `REMOTE HOST IDENTIFICATION HAS CHANGED`. Check
  the new fingerprint at the console first, then `ssh-keygen -R <VM_IP>`.
