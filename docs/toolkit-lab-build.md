# toolkit-lab: build guide (v2)

`toolkit-lab` was built in v1 from the Ubuntu installer. This guide records
the v2 changes on it: every step, the expected output, and why. Its partner
is `docs/backup-lab-build.md`.

| Part | State |
|---|---|
| Step 1: push account and key (v2, step 3) | Done, all expected outputs matched (2026-09-27) |
| The key installed on backup-lab (v2, step 3) | Next, in `docs/backup-lab-build.md` |

---

## What changes on toolkit-lab

`toolkit-lab` sends its backups to `backup-lab`. A dedicated account,
`backup-push`, owns the key and does the sending: not root, not `ghaith`.

## Decisions

| Decision | Why |
|---|---|
| A dedicated service account `backup-push` | A compromise reaches only what the sending account can read. Example: CVE-2024-12086 (fixed in Ubuntu) let a malicious rsync server read any file the sending process could read, while files were copied to it. As root: every file. As `ghaith`: his files, including the GitHub key. As `backup-push`: only the backups, which backup-lab receives anyway. |
| No passphrase on the push key | A service cannot type one. The limits live on backup-lab: the key can only write into `incoming`, and only from this machine's address. |
| backup-lab's host key pinned in a root-owned file | The service never asks a question and never learns a new host key. |
| Everything that decides trust is owned by root | `backup-push` cannot change its settings or whom it trusts. |

**Consequence:** rebuilding `backup-lab` makes a new host key. Backups stop
with `Host key verification failed` until the pinned file is updated by hand,
after checking the new fingerprint at the console. This is intended: a changed
host key needs a human.

## Where the secrets live

| File | Location | Mode |
|---|---|---|
| `/home/backup-push/.ssh/backup-lab-push` (no passphrase) | `toolkit-lab` only | `600`, owner `backup-push` |

---

## Step 1: Push account and key (v2, step 3)

Run on `toolkit-lab`, all in **one terminal** (the host key check keeps a
value in a variable).

| Choice | Why |
|---|---|
| `backup-push`: system account, its own group, no password | Same idea as `backup-recv` on backup-lab |
| Shell `/usr/sbin/nologin` | Nobody logs in as it, not even with `sudo -i`. A systemd unit does not need a shell |
| Home and `.ssh` owned by root, mode `755` | The account cannot change its own settings |
| Only the private key owned by `backup-push`, mode `600` | The one file it must read |
| `ed25519` key `backup-lab-push`, no passphrase | Named like `backup-lab-admin`: target, then role |
| Client settings in `/home/backup-push/.ssh/config`, owned by root | All limits in one place: `ssh backup-lab` is enough |

**Check.**

```bash
hostname                          # must print: toolkit-lab
apt-cache policy rsync | head -3
```

Expected: `Installed` equals `Candidate` (`3.2.7-1ubuntu1.5` on the first
build). The sending side needs rsync too.

**Guard.** Must print `exit=2` twice and nothing else:

```bash
getent passwd backup-push; echo "exit=$?"
getent group backup-push; echo "exit=$?"
sudo test -e /home/backup-push && echo "STOP: /home/backup-push already exists"
```

**Account.**

```bash
[ "$(hostname)" = "toolkit-lab" ] && sudo useradd --system --user-group \
    --home-dir /home/backup-push --no-create-home \
    --shell /usr/sbin/nologin --comment "pushes backups to backup-lab" backup-push
[ "$(hostname)" = "toolkit-lab" ] && sudo install -d -o root -g root -m 755 /home/backup-push /home/backup-push/.ssh
```

Expected: both print nothing.

**Key.**

```bash
[ "$(hostname)" = "toolkit-lab" ] && sudo ssh-keygen -t ed25519 -N '' \
    -C "backup-push@toolkit-lab" -f /home/backup-push/.ssh/backup-lab-push
[ "$(hostname)" = "toolkit-lab" ] && sudo chown backup-push:backup-push /home/backup-push/.ssh/backup-lab-push
```

- `-N ''`: an empty passphrase.
- `-C`: a comment at the end of the public key, to recognise its line in
  `authorized_keys` on backup-lab.
- Made as root, so both files start owned by root: only the private key is
  given to `backup-push`.

Expected: `ssh-keygen` prints the two saved files, the fingerprint with
`backup-push@toolkit-lab`, and a randomart picture. Write the fingerprint
down: it is checked again on backup-lab.

**Pin backup-lab's host key.**

```bash
ssh-keyscan -t ed25519 192.168.122.239 2>/dev/null > ~/backup-lab.hostkey
cat ~/backup-lab.hostkey
FP=$(ssh-keygen -lf ~/backup-lab.hostkey | awk '{print $2}')
echo "scanned: $FP"
[ "$FP" = "SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc" ] && echo "MATCH" || echo "STOP: MISMATCH"
```

- `ssh-keyscan` asks the server for its public key, without logging in.
- The network's answer is not trusted alone: it is compared with the
  fingerprint taken at backup-lab's console (backup-lab guide, step 9 and
  "Recorded on the first build").

Expected: one line `192.168.122.239 ssh-ed25519 AAAA...`; the recorded
fingerprint; `MATCH`. `STOP: MISMATCH` means another machine answered at that
address, or the scan failed: stop.

```bash
[ "$(hostname)" = "toolkit-lab" ] && [ "$FP" = "SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc" ] && \
    sudo install -o root -g root -m 644 ~/backup-lab.hostkey /home/backup-push/.ssh/known_hosts
rm ~/backup-lab.hostkey
```

The fingerprint check sits inside the install command, like the hostname
guard. `install` copies the file with its owner and mode in one step.

**Client settings.** Write this file in your own home first
(`vim ~/backup-push.ssh-config`, `:set paste`, `i`, paste, `Esc`,
`:set nopaste`, `:wq`). File contents, not commands:

```
# ssh client settings for the backup-push account on toolkit-lab.
# Owned by root: backup-push cannot change whom it trusts.
Host backup-lab
    # backup-lab's reserved address (build guide, step 13)
    HostName 192.168.122.239
    # the receive account on backup-lab (build guide, step 14)
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
cat -n ~/backup-push.ssh-config
[ "$(hostname)" = "toolkit-lab" ] && sudo install -o root -g root -m 644 ~/backup-push.ssh-config /home/backup-push/.ssh/config
rm ~/backup-push.ssh-config
```

Expected: the file, numbered, exactly as above; then nothing.

**Verify.**

```bash
getent passwd backup-push
id backup-push
sudo passwd -S backup-push
ls -ld /home/backup-push
ls -la /home/backup-push/.ssh
ssh-keygen -lf /home/backup-push/.ssh/backup-lab-push.pub
```

Expected:
- uid below 1000, home `/home/backup-push`, shell `/usr/sbin/nologin`; one
  group only; `L` (locked) as the second word of `passwd -S`.
- `/home/backup-push`: `drwxr-xr-x root root`.
- Inside `.ssh`: `.` and `..` `drwxr-xr-x root root`; `backup-lab-push`
  `-rw------- backup-push backup-push`; `backup-lab-push.pub`, `config` and
  `known_hosts` `-rw-r--r-- root root`.
- The same fingerprint as `ssh-keygen` printed, ending with
  `backup-push@toolkit-lab (ED25519)`.

**Permission tests.**

```bash
# ghaith must NOT read the private key (test only, never print it)
test -r /home/backup-push/.ssh/backup-lab-push && echo "STOP: ghaith can read the key" || echo "ok: ghaith cannot read the key"
# backup-push must read it
sudo -u backup-push test -r /home/backup-push/.ssh/backup-lab-push && echo "ok: backup-push can read the key" || echo "STOP: backup-push cannot read the key"
# backup-push must NOT change whom it trusts, or add files
sudo -u backup-push touch /home/backup-push/.ssh/known_hosts; echo "exit=$?"
sudo -u backup-push touch /home/backup-push/.ssh/probe; echo "exit=$?"
# backup-push has no shell
sudo -u backup-push -i; echo "exit=$?"
```

`test -r`, not `cat`: if a mistake made the key readable, `cat` would print a
secret on screen.

Expected: `ok: ghaith cannot read the key`; `ok: backup-push can read the
key`; `Permission denied` and `exit=1` twice; `This account is currently not
available.` and `exit=1`.

**Connection tests.** The key is not on backup-lab yet, so it must be
refused, and refused the right way.

```bash
sudo -u backup-push ssh -G backup-lab | grep -E '^(hostname|user|identityfile|userknownhostsfile) '
# The key is not on backup-lab yet: refused, with no host key question
sudo -u backup-push ssh backup-lab true; echo "exit=$?"
# Without the pinned file, the host is refused, not asked about
sudo -u backup-push ssh -o UserKnownHostsFile=/dev/null backup-lab true; echo "exit=$?"
```

- `ssh -G` prints the settings ssh will use, without connecting.
- The second proves four things: the settings were read, the host key was
  accepted with no question, nothing waited for a human, and the key was
  offered but is not accepted yet.
- The third proves the pinned file is the only reason the host is trusted.

Expected:
- Four lines (in ssh's own order): `user backup-recv`,
  `hostname 192.168.122.239`,
  `identityfile /home/backup-push/.ssh/backup-lab-push`,
  `userknownhostsfile /home/backup-push/.ssh/known_hosts`.
- `backup-recv@192.168.122.239: Permission denied (publickey).` and
  `exit=255`, with no host key question or warning.
- `No ED25519 host key is known for 192.168.122.239 and you have requested
  strict checking.`, `Host key verification failed.` and `exit=255`.

---

## Recorded on the first build

| Item | Value |
|---|---|
| `backup-push` | uid `999`, gid `988` |
| Push key (ED25519) | `SHA256:GXDf9TC+HKdZyCYk4RnOab8SeM/TDxG850fH8Ia+evQ` |
| Pinned backup-lab host key | `SHA256:GmRNAr03qErfN+K005wUjqFKpSiZVTtpZCpbRBdYuZc` |
| rsync | `3.2.7-1ubuntu1.5` |

## Lessons

- Never trust a host key from the network alone: compare it with a
  fingerprint taken at the console, and put the check inside the command that
  installs it.
- Test a secret file with `test -r`, never `cat`.
- `ssh -G host` shows the settings ssh will use, without connecting.
- A service account needs no shell: `/usr/sbin/nologin` refuses even
  `sudo -i`.
- The ssh client accepts a `config` and a `known_hosts` owned by root (not
  writable by others), but the private key must belong to the account that
  uses it.
- For automation: `BatchMode yes` and `StrictHostKeyChecking yes`. Fail
  instead of asking.
- uid and gid numbers belong to each machine: `backup-push` and `backup-recv`
  both got `999`/`988` by chance. SSH logs in by name, not by number.
