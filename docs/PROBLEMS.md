# Problems I Hit and How I Solved Them

Every problem here actually happened. I wrote each one down the day it
happened, because a week later I would only remember that "something went
wrong."

### 1. The error message pointed at the wrong problem

**Problem:** `virt-install` said it needed storage creation parameters for a
non-existent path.

**Cause:** No missing argument. The ISO was simply not at that path. On top of
that, the command I had copied said `24.04.3` and my file was `24.04.4`.

**Fix:** Moved the ISO to `/var/lib/libvirt/images/` and corrected the name.

**Lesson:** Read what the tool actually checked, not what it suggests. And
compare copied commands against my own filenames first -- one digit is enough.

### 2. My SSH hardening was one filename away from doing nothing

**Problem:** Ubuntu ships `/etc/ssh/sshd_config.d/50-cloud-init.conf` with
`PasswordAuthentication yes` -- the opposite of what I wanted.

**Cause:** In `sshd_config` the **first** value found wins, and that directory
is read in alphabetical order. A file named `99-hardening.conf` would be read
*after* `50-cloud-init.conf` and silently ignored.

**Fix:** Named it `10-hardening.conf`, then checked the result with
`sudo sshd -T`, which prints the merged config the daemon really uses.

**Lesson:** Editing a config file is not the same as changing behaviour. I need
a command that reads the effective state back to me.

### 3. Being denied is the test that passes

**Problem:** After disabling password login I logged in with my key, and almost
called that a successful test.

**Cause:** It only proves the key works. It says nothing about whether passwords
are still accepted.

**Fix:** Tested the thing I wanted broken:
`ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ...`
Got `Permission denied`, which is the good result here.

**Lesson:** A security change needs both tests -- the blocked thing must fail,
the allowed thing must still work.

### 4. sudo built me a config file I could not read

**Problem:** `git push` failed with `Permission denied (publickey)`, and GitHub
listed my key as "Never used". The key had never left the machine.

**Cause:** I created `~/.ssh/config` with `sudo vim`, so it came out
`root:root` mode `600`. SSH skips an unreadable user config silently, so my
`IdentityFile` line never applied.

**Fix:** `sudo chown "$USER:$USER" ~/.ssh/config` then `chmod 600` (no sudo --
once I own it I do not need it).

**Lesson:** Needing sudo for a file in my own home means the ownership is
already wrong. `ssh -v` lists which config files were read and which keys were
offered.

### 5. I ran git on the wrong machine

**Problem:** `git add` returned `fatal: not a git repository`.

**Cause:** I was on my host, not the VM. Same directory name, different
machine, and I never noticed the switch.

**Fix:** `scp`'d the files over and deleted the host copy.

**Lesson:** The prompt says which machine I am on. Read it before the command,
not after the error.

### 6. Not every noisy command has a quiet flag

**Problem:** `systemctl --failed | wc -l` gave wrong counts -- it prints a
header and a footer even when nothing failed.

**Cause:** I assumed the same flag would exist everywhere. `systemctl` has
`--no-legend` and `ss` has `--no-header`, but `df` has neither. A 2012 patch
proposing `--without-header` for `df` was rejected; the maintainer suggested
`tail -n +2`.

**Fix:** Use the documented flag where one exists, `tail -n +2` where none
does.

**Lesson:** Commands from the same ecosystem do not share conventions
automatically. Check each one.

### 7. My exit code comment was a promise I had not kept

**Problem:** `hostaudit.sh`'s header said it exits 1 on a problem. The first
real run found `auditd` inactive and still exited 0.

**Cause:** The check functions only printed a `WARN` line. None of them
returned failure to the caller.

**Fix:** Every check ends with `return 0` or `return 1`, and the caller
aggregates with `problems=$(( problems + 1 ))`. Also guarded
`grep -c '^Z'` with `|| true` -- it exits 1 when it matches nothing, even
though it prints `0`.

**Lesson:** A comment about exit codes is enforced by nothing. It is only true
if every path actually returns those values.

### 8. A status command that hides everything when you need it most

**Problem:** `sudo ufw status` printed only `Status: inactive`, even though I
had already added rules with `ufw allow`.

**Cause:** `ufw` only reports the running ruleset once it is active, by design.

**Fix:** `sudo ufw show added` lists queued rules in either state. That is the
command to run before `ufw enable`.

**Lesson:** Enabling a firewall over my only remote path needs an independent
test. After `ufw enable` I opened a brand-new SSH connection instead of
trusting the session I already had. Same idea as #3.

### 9. An unguarded command could have killed the whole check

**Problem:** `watch_service()` called `systemctl restart "$svc"` with no guard.
Under `set -e` a failed restart would kill the script immediately -- before the
`log_error` line written to handle that exact case, and before the remaining
services were checked.

**Cause:** `set -e` exits on any unguarded command that returns non-zero.

**Fix:** `systemctl restart "$svc" || true`. The next line re-checks with
`is-active` anyway, so the restart's own exit code was never needed. Tested by
adding a made-up service name to the array so the restart was guaranteed to
fail.

**Lesson:** The same `set -e` trap keeps returning in new shapes. Any command
that can fail needs a guard *before* it runs for real.

### 10. A vim edit silently discarded the rest of the file

**Problem:** After editing `backup.sh` the script failed with a wall of
`command not found` (`require_cmd`, `die`, `log_info`) and
`mkdir: cannot create directory ''`.

**Cause:** The edit replaced the whole file instead of appending. The shebang,
`set -euo pipefail`, the `source lib/common.sh` line and the entire `getopts`
block were gone -- which is why `$dest` was empty.

**Fix:** Rewrote the file from scratch in one paste. After any non-trivial
edit, run `cat -n script.sh` on the whole file before executing it.

**Lesson:** A wall of `command not found` from library functions means the
`source` line itself is missing. Check the top of the file, not the line the
error points to.

### 11. A missing execute bit looks nothing like a script error

**Problem:** `systemctl --user start backup.service` failed instantly with
`status=203/EXEC` and no script output at all.

**Cause:** `backup.sh` was `-rw-rw-r--`. It was written from scratch that day
and `chmod +x` was forgotten; the older scripts already had it.

**Fix:** `chmod +x scripts/backup.sh`.

**Lesson:** `203/EXEC` means systemd could not launch the file -- completely
different from the script running and exiting non-zero. Check `ls -l` on
`scripts/` before wiring anything to systemd.

### 12. The README documented a feature that was never built

**Problem:** Re-reading `README.md` during the v1 review surfaced a "Remaining
for v1" item: `service-watch.sh` had no limit on restart attempts, so a real
crash loop would be restarted forever with no escalation.

**Cause:** It was written down as a known gap and never revisited. Later
sessions assumed the scope list was already satisfied.

**Fix:** Added a restart counter persisted in
`/var/lib/linux-server-toolkit/service-watch/<service>.count` (not under the
repo -- the script runs as root, and root-owned files in a user's home is the
trap from #4). After 3 consecutive failures it stops trying and reports a
likely crash loop. Tested by adding a nonexistent service and running four
times: attempts 1-3 tried and failed, run 4 skipped the restart entirely.

**Lesson:** A documented scope item is not a built one. Re-read the planning
document in full before closing a phase.

### 13. A unit that failed with no output, only at boot

**Problem:** `log-analyzer.service` ran unattended twice and both runs logged
`status=1/FAILURE` with zero script output. The same unit run by hand printed
everything, with the same exit code. It later happened to `hostaudit.service`
too, so it is not specific to one script.

**Cause:** Those were catch-up runs fired by `Persistent=true` right after
boot, and from a *previous* boot -- visible as a `-- Boot <id> --` separator
and a different user-manager PID. The output from that window never reached the
journal; the exit code did.

**Fix:** Nothing in the script -- `exit 1` was correct and intentional. What
changed is how I read the journal: `journalctl --user -u <unit>` spans boots,
`journalctl --user -b -u <unit>` limits it to the current one.

**Lesson:** An exit code with no output is not proof the script ran and failed.
It can also mean the run happened where output was not captured. A catch-up run
is the least observable run a timer ever makes.

### 14. A guard in the right place, asking the wrong question

**Problem:** `service-watch.sh` reported `ssh is not running` and restarted it,
on a machine where SSH was working and port 22 was served the whole time.

**Cause:** Ubuntu has shipped OpenSSH socket-activated since 22.10. Here
`ssh.service` is `disabled` and `ssh.socket` holds the port, so an idle service
is the correct state. Every earlier test ran from an active SSH session -- my
own connection had started the service, so the check always looked right.

**Fix:** `systemctl show <svc> -p TriggeredBy --value` names the units that
activate a service on demand, and is empty for an ordinary one. Inactive is
only a fault when there are no triggers, or when every trigger is down too --
and then the trigger is what gets restarted, since restarting the service
would not restore the listener. All five paths were tested for real.

**Lesson:** #9 was a missing guard. This guard was present and correct and
still raised a false alarm, because the question was wrong. A monitor that
cries wolf every boot hides the one real failure it exists to catch.

## Smaller traps, collected

From `checkfile.sh` and `checkmany.sh`, and the ones I keep almost repeating:

- `set -e` kills the script when `checkfile.sh` exits non-zero on purpose.
  Use `cmd || rc=$?` -- `||` disables `set -e` and captures the code.
- Reset `rc=0` before each call, or a passing file inherits the previous
  file's exit code.
- `(( n++ ))` returns failure when `n` is 0, which kills the script under
  `set -e` -- on the first *passing* file. Use `n=$(( n + 1 ))`.
- `read -ra arr <<< "$string"` returns non-zero without a trailing newline;
  guard it with `|| true`. An empty string gives zero fields, not one empty
  field, so `${#arr[@]}` is a clean empty test.
- Test files in `/tmp` disappear after a reboot. Moved them to
  `~/lab/fixtures` with a script to rebuild them.

---

Most of my time went to things being silently ignored rather than failing
loudly. A config file that is skipped, a key that is never offered, a directory
that is not the one I think it is. Verification is not paranoia here, it is the
only way to know.
