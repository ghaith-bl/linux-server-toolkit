# Problems I Hit

Each one happened. One line each: the problem, then the fix.

## v1

1. `virt-install` blamed storage parameters; the ISO was simply not at that path, and its name was off by one digit. -> Moved the ISO and fixed the name; read what the tool actually checked.
2. Ubuntu's `50-cloud-init.conf` turned SSH passwords back on: in `sshd_config.d` the first value wins. -> Named my file `10-hardening.conf`; checked the result with `sudo sshd -T`.
3. A login with my key looked like proof that passwords were off. -> Tested the blocked path too: a password login must be refused.
4. `~/.ssh/config` made with `sudo vim` was owned by root, and SSH skipped it silently. -> `chown` back to me; `ssh -v` shows which files were read.
5. `git add` failed: I was on the host, not the VM. -> Read the prompt before the command.
6. `systemctl --failed | wc -l` counted the header and footer. -> `--no-legend` where it exists, `tail -n +2` where it does not.
7. `hostaudit.sh` exited 0 when a check failed: the checks only printed a warning. -> Every check returns 0 or 1, and the caller counts them.
8. `ufw status` showed nothing before `ufw enable`. -> `ufw show added` lists the rules; a new SSH session tested the firewall before trusting it.
9. Under `set -e`, a failed `systemctl restart` would have killed `service-watch.sh` mid-run. -> `|| true`, then re-check with `is-active`.
10. A vim edit replaced the whole of `backup.sh`. -> Rewrote it; `cat -n` on the whole file before running it.
11. `status=203/EXEC`: `backup.sh` had no execute bit. -> `chmod +x`; `203` means systemd could not start the file at all.
12. A crash-loop limit was in the README but never built in `service-watch.sh`. -> Built it (a counter in `/var/lib`); re-read the plan before closing a version.
13. Catch-up runs after boot failed with no output in the journal. -> Nothing wrong in the script; `journalctl -b` shows the current boot only.
14. `service-watch.sh` restarted SSH that was working: SSH is socket-activated. -> Check `TriggeredBy` first; restart the socket when it is the socket that is down.

Smaller traps in Bash:

- `set -e` kills the script on a planned non-zero exit. -> `cmd || rc=$?`, with `rc=0` reset before each call.
- `(( n++ ))` fails when `n` is 0. -> `n=$(( n + 1 ))`.
- `read -ra` fails without a trailing newline. -> `|| true`.
- `cmd | while read` runs in a subshell and loses its arrays. -> `done < <(cmd)`.
- Extracting by position (`awk '{print $N}'`) breaks when the word count changes. -> Extract by shape with `grep -oE`.
- Test files in `/tmp` vanish after a reboot. -> `~/lab/fixtures`, rebuilt by `tests/make-fixtures.sh`.

## v2

1. Disk commands once ran on the wrong VM (no damage). -> Every command that changes something checks `hostname` first.
2. A fix block ran on the test VM instead of the host: a `hostname` line at the top of a block guards nothing. -> The guard goes inside each command.
3. The shell expands `*` and `>>` before `sudo` runs: `sudo cmd >> file` fails, and a `*` in a root-only folder finds nothing. -> Full file names, and `| sudo tee -a`.
4. `~` is not expanded inside `user-data=~/...`. -> `$HOME`.
5. `man rrsync` says `-rw`; the program says `-wo`. -> `rrsync -help` is the reference, not the manual.
6. `vim ~/.ssh/config` opened the real file, and a test block was pasted into it. -> Test machines get their own ssh config, used with `ssh -F`.
7. An incomplete download broke a whole batch (no damage). -> The checksum check sits inside the copy command.
8. A rebuilt VM kept its MAC but got a new address: it asks with a new DHCP identity, and a power-off does not give the old lease back. -> `bootstrap.sh` stops at two leases; a rebuild waits until the old lease is gone (up to an hour).
9. `ssh-keyscan` returned two lines: since OpenSSH 9.8 its comment goes to standard output. -> `grep -v '^#'`; `-q` does not exist before 9.8.
10. A test key said "saved with the new passphrase" with an empty passphrase. -> `ssh-keygen -y -P ''` tells whether a key has one, without printing it.
11. An Enter pressed during the long wait answered the passphrase prompt. -> Press no key while `bootstrap.sh` waits.
12. Under `set -e`, a failed `$(...)` inside another command's argument gives an empty value and the script goes on. -> Read values into variables first.
13. A user unit's log lines were not always linked to the unit in the journal. -> A unit's result is read from `Result` and `ExecMainStatus`.
14. `gpg --verify` starts `keyboxd` and leaves it running, with a lock in `~/.gnupg`. -> Accepted: it is the only trace the image check leaves.
15. The guide said the first boot installed cloud-init 26.1; it was already in the image. -> Checked on the machine and corrected.

## v2.1

1. Disk quotas were considered for the limit on `incoming`; the cloud image's kernel has no `quota_v2` module. -> Checked with `modinfo` before building on it; the limit moved to v4.
2. A send failed with rsync exit 12, not the usual 255: `No route to host`, `backup-lab` was off. -> Read the unit's full log, not only the exit code; nothing was marked as sent, and the next run sent both pairs.
3. `curl` read the CI result seconds after the push: `total_count: 0`. -> Wait a minute before reading it.

## v2.2

1. `backup-lab` ran without a firewall from v2.0: no step, and nothing in the template, ever turned `ufw` on, and `systemctl is-enabled ufw` still said `enabled`. -> `sudo ufw status` is the check; the template now applies the policy at the first boot.
2. The firewall log held 12 refused packets after two test connections: every retry of a refused TCP connection is logged. -> Count the different destinations, not the lines.
3. The count of the CIS results printed `faillt` and `passlt`: `oscap` writes a carriage return after each label of its text output. -> `tr -d '\r'` before counting.
