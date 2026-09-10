# Problems I Hit and How I Solved Them

Every problem here actually happened. I wrote each one down the day it happened,
because a week later I would only remember that "something went wrong."

### 1. The error message told me the solution to a problem I did not have

First command of the project. `virt-install` said:

```
Must specify storage creation parameters for non-existent path
'/var/home/null/isos/ubuntu-24.04.3-live-server-amd64.iso'
```

I read it as a missing argument at first. There was no missing argument. The file
was not there. That was the whole problem.

The tool was telling me what it would need *if* I wanted it to create storage at
that path, instead of just saying the file was not found. Two different messages,
and it picked the less useful one.

There was a second reason it could not find the file. The command said `24.04.3`
and the ISO I had downloaded was `24.04.4`. I had copied the command and not read
the filename in it.

**Fix:** moved the ISO to `/var/lib/libvirt/images/` and corrected the filename.

**Lesson:** read what the tool actually checked, not what it suggests. And when I
copy a command from anywhere, compare the paths and filenames against my own
system first. One digit in a point release number is enough to break it.

### 2. My SSH hardening was one filename away from doing nothing

Ubuntu ships its own SSH config fragment. It does the exact opposite of what I
wanted:

```bash
$ ls /etc/ssh/sshd_config.d/
10-hardening.conf  50-cloud-init.conf

$ sudo cat /etc/ssh/sshd_config.d/50-cloud-init.conf
PasswordAuthentication yes
```

In `sshd_config`, **the first value found wins**, and files in that directory are
read in alphabetical order.

The obvious name for a hardening file is something like `99-hardening.conf`,
because a higher number sounds like higher priority. Here it is the opposite.
A `99-` file is read after `50-cloud-init.conf`, so my `PasswordAuthentication no`
would have been thrown away without a single warning. The file would look perfect.
The server would keep accepting passwords. I would have moved on thinking the box
was hardened.

I named it `10-hardening.conf`, and then verified the result instead of trusting
the file:

```bash
$ sudo sshd -T | grep -Ei 'passwordauth|permitrootlogin|kbdinteractive'
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
```

`sshd -T` prints the final configuration after every include is merged, so it
shows what the daemon will actually use, not what I typed.

**Lesson:** editing a config file is not the same as changing behaviour. Before I
believe a change worked, I need a command that reads the effective state back to
me. For SSH that command is `sshd -T`.

### 3. Being denied is the test that passes

After disabling password login, I logged in with my key and it worked. For about
five seconds I considered that a successful test.

It is not. It only proves my key works. It says nothing about whether passwords
are still accepted. So I tested the thing I actually wanted to be broken:

```bash
$ ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no ghaith@192.168.122.x
ghaith@192.168.122.x: Permission denied (publickey).

$ ssh toolkit-lab 'echo OK'
OK
```

`Permission denied` is the good result here. That took a second to get used to.

**Lesson:** for a security change, both tests are needed. The thing I want blocked
must fail, and the thing I want allowed must still work. If I only test the happy
path, a setting that did nothing looks exactly like a setting that worked.

### 4. sudo built me a config file I was not allowed to read

I created my SSH client config with `sudo vim ~/.ssh/config`. The path was right.
The content was right. The file came out owned by `root:root` with mode `600`, so
my own user could not read a single line of it.

SSH does not complain about this. When it cannot open the user config file, it
skips it silently and carries on. So my `IdentityFile` line never applied, SSH
fell back to the default key names that do not exist on this machine, offered
nothing at all, and GitHub replied:

```
git@github.com: Permission denied (publickey).
```

I checked the key. I checked it again. The key was fine.

The answer was sitting on the GitHub key page the whole time: the key was listed
as **"Never used"**. Not rejected. Never used. It had never left the machine.

**Fix:**

```bash
sudo chown "$USER:$USER" ~/.ssh/config
chmod 600 ~/.ssh/config
```

Note the second command has no `sudo`. Once I own the file, I do not need it.

**Lesson:** if I need `sudo` to edit a file inside my own home directory, the
ownership is already wrong, and that is the real problem. `sudo` hid the symptom
and created a worse one. Also, `ssh -v` lists which config files were read and
which keys were offered. That would have turned guessing into two lines of output.

### 5. I ran git on the wrong machine

I created `.gitignore` and `LICENSE`, ran `git add`, and got:

```
fatal: not a git repository (or any parent up to mount point /var)
```

The files were fine. I was on the wrong machine.

I had opened a second terminal on my host earlier and never went back to the SSH
session. I was typing into an old directory with the same name that was never a
repo. The whole time I thought I was deeply focused on the task. I was focused on
the task and completely unaware of where I was doing it.

**Fix:** copied the files over with `scp`, then deleted the copy on the host so
only one directory exists.

**Lesson:** the shell prompt tells me which machine I am on, and I should read it
before running a command instead of after the error. This is also why I gave the
VM a hostname that matches its libvirt domain name. Two directories with the same
name on two machines is how you end up editing a file and wondering why nothing
changed.

### 6. Not every "noisy" command has a flag to make it quiet

`systemctl --failed` prints a header row and a "N loaded units listed" footer
even when nothing failed, so counting lines with `wc -l` gave a wrong number in
both directions. `systemctl` has `--no-legend` for exactly this, and once I
used it, every remaining line was a real failed unit.

I assumed the same trick would exist everywhere. It did, for `ss` --
`--no-header` strips its column row the same way. It did not for `df`. GNU
coreutils never merged a header-suppress flag for it; a 2012 patch proposing
`--without-header` was turned down by the maintainer, who suggested `tail -n +2`
instead. So that is what `check_disk_usage()` uses.

**Fix:** use `--no-legend` / `--no-header` when a command documents one;
fall back to `tail -n +2` when it does not.

**Lesson:** commands from the same general ecosystem do not automatically share
conventions. Check each one instead of assuming the last one's flag carries over.

### 7. My exit code comment was a promise I had not kept yet

`hostaudit.sh`'s header comment said `Exit: 0` if every check passes, `1` if
one reports a problem. The first version's check functions only printed a
`WARN` line -- none of them actually signalled failure back to the caller. The
very first real run hit a genuine problem (`auditd` not active) and still
exited `0`, because nothing was propagating that failure upward.

Each check now ends with `return 0` or `return 1`, and the main script
collects them:

```bash
problems=0
check_failed_services || problems=$(( problems + 1 ))
```

I almost wrote `(( problems++ ))` again -- the exact same trap from
`checkfile.sh`: it evaluates to the pre-increment value, which is `0` on the
very first failure, and `set -e` treats that as a command failing.

Separately, `zombie_count=$(ps -eo stat | grep -c '^Z')` had the same shape of
bug: `grep -c` exits `1` when it matches nothing, even though it still prints
`0`. Under `set -e`, the totally normal "no zombies" case would have killed the
script. Fixed with `|| true`.

**Fix:** every check function returns `0`/`1` explicitly; the caller aggregates
with `problems=$(( problems + 1 ))`; `grep -c` is guarded with `|| true`.

**Lesson:** a comment describing exit codes is not enforced by anything. It is
only true if every code path actually returns those values. And any command
that can signal "found nothing" via a non-zero exit code needs the same `set -e`
guard as an external script's return code.

### 8. A status command that hides everything when you need it most

`sudo ufw status` (verbose or not) prints nothing but `Status: inactive`
while the firewall is off -- even though rules I had already added with
`ufw allow` were sitting there, queued. I expected to see them listed
before enabling; they were not. `ufw` only reports the running ruleset
once it is active, by design.

**Fix:** `sudo ufw show added` lists queued rules regardless of
active/inactive state, formatted as the exact commands that created them.
That is the command to check before `ufw enable`, not `ufw status`.

**Lesson:** enabling a firewall over the only remote path to a box needs
an independent test, not "the current session is still open." After
`ufw enable`, opening a brand-new SSH connection from the host -- not
trusting the existing session -- is what actually confirmed the rule
worked. Same principle as #3.

### 9. An unguarded command was one bad restart away from taking down the whole check

`watch_service()` called `systemctl restart "$svc"` directly, with no
guard. Under `set -e`, if a restart ever failed, that line would kill
`service-watch.sh` immediately -- before it reached the `log_error` line
already written to handle exactly that case, and before it could check
the remaining services in the array.

I tested it before trusting it: added a made-up service name
(`definitely-not-a-real-service`) to the array so `restart` was
guaranteed to fail, with zero risk to anything real. Without a guard,
that one entry would have stopped the whole run.

**Fix:** `systemctl restart "$svc" || true`. The very next line already
re-checks the service with `is-active`, so the exit code from `restart`
itself was never needed -- only that a failure not kill the script.

**Lesson:** the same `set -e` trap keeps showing up in a new shape --
`checkfile.sh`'s external exit code, `grep -c`'s "found nothing" exit 1,
and now a command that changes real system state. Any command that can
fail needs a guard *before* it runs for real, not after something breaks.

### 10. Editing an existing script in vim silently discarded earlier sections

**Symptom:** After adding the `mktemp`/`trap`/`tar` section to `backup.sh`, running
the script failed with a cascade of `command not found` errors (`require_cmd`, `die`,
`log_info`) and `mkdir: cannot create directory ''`.

**Cause:** The vim edit replaced the entire file content instead of appending to it.
The resulting file contained only the newly added section -- the shebang,
`set -euo pipefail`, the `source lib/common.sh` line, and the whole `getopts` block
were gone. Without `common.sh` sourced, none of the shared logging/guard functions
existed; without `getopts` having run, `$dest` was empty, which is why `mkdir`
received an empty string as its argument.

**Fix:** Rewrote the file from scratch in a single paste rather than trying to patch
the missing pieces back in. After any non-trivial edit to an existing script, run
`cat -n script.sh` on the full file (not just `tail`) before executing it, to confirm
every earlier section survived the edit.

**Lesson:** A wall of `command not found` errors from functions defined in a sourced
library is a strong signal that the `source` line itself is missing or never ran --
check the top of the file first, not the line the error points to.

### 11. New script missing execute permission caused `status=203/EXEC` under systemd

**Symptom:** After wiring `backup.sh` to a user timer, running it manually with
`systemctl --user start backup.service` failed immediately with
`Main PID: ... (code=exited, status=203/EXEC)`, with no script output in the journal
at all.

**Cause:** `203/EXEC` means systemd itself could not execute the file -- the script
never actually started. `ls -l` confirmed `backup.sh` was `-rw-rw-r--` (no execute
bit), while every other script in `scripts/` was `-rwxr-xr-x` or similar. Since
`backup.sh` was freshly written from scratch that day, `chmod +x` was simply
forgotten -- the older scripts already had it set from earlier sessions.

**Fix:** `chmod +x scripts/backup.sh`, then re-ran `systemctl --user start
backup.service` -- it succeeded (`status=0/SUCCESS`).

**Lesson:** `203/EXEC` is a distinct systemd failure mode from a script's own
non-zero exit code -- it means the binary/script couldn't be launched at all, not
that it ran and failed. Worth checking `ls -l` on the whole `scripts/` directory
after adding any new script and before wiring it to systemd, rather than assuming
execute permission carried over.

### 12. README documented a v1 requirement that was never actually built

**Symptom:** While preparing the final v1 review, re-reading `README.md`
(rather than working from memory) surfaced a "Remaining for v1" item:
`service-watch.sh` had no limit on restart attempts, so a service stuck in a
real crash loop would be restarted silently forever with no escalation. This
had been documented since `service-watch.sh` was first written, but never
implemented.

**Cause:** The item was written down as a known gap at the time and never
revisited, since later sessions focused on the remaining v1 scripts and
assumed the README's own scope list was already satisfied.

**Fix:** Added a restart-attempt counter to `service-watch.sh`, persisted
between runs in `/var/lib/linux-server-toolkit/service-watch/<service>.count`
(not under the repo -- the script always runs as root via `require_root`, and
writing root-owned files into a normal user's home directory is the same trap
already documented in NOTES.md). After `MAX_RESTARTS` (3) consecutive failed
restarts, the script stops attempting and reports the service as a likely
crash loop instead of retrying forever. Tested against a real crash loop by
temporarily adding a nonexistent service to `SERVICES` and running the script
four times in a row: attempts 1-3 each tried `systemctl restart` and failed;
the 4th run skipped the restart attempt entirely and reported the crash-loop
message.

**Lesson:** A documented scope item is not the same as a built one. Before
closing out a phase, re-read the actual planning document in full rather than
relying on memory of what got done -- a stale TODO is easy to miss when
attention has moved to newer work.



### 13. A unit that failed with no output at all, only at boot

**Symptom:** `log-analyzer.service` ran twice unattended (03:04 and 04:00) and
both runs showed `status=1/FAILURE` in the journal with **zero** script output --
no `INFO scanning...`, no error line, nothing. The same unit run manually in a
normal session printed every log line as expected, with the same exit code.

**Cause:** Not a script bug. The unattended runs were catch-up runs fired by
`Persistent=true` immediately after boot, on a *previous* boot -- visible as a
`-- Boot <id> --` separator in the journal, and as a different user-manager PID
(`systemd[933]` then vs `systemd[890]` now). Script output from that window did
not make it into the journal; the exit code did.

**Fix:** None needed for the script -- `exit 1` was correct and intentional (an
IP had crossed the SSH-attempt threshold). What changed is how the journal is
read: `journalctl --user -u <unit>` spans boots, so runs from different boots
sit next to each other and look like the same session unless the `-- Boot --`
separator is noticed. `journalctl --user -b -u <unit>` limits it to the current
boot.

**Lesson:** an exit code without accompanying output is not proof the script ran
and failed -- it can also mean the run happened in a window where output was not
being captured. Check the boot separator and the manager PID before concluding
anything about the script itself. And a catch-up run triggered by `Persistent=`
is the least observable run a timer will ever make, which is exactly when
observability matters most.



## Smaller traps, collected

These came out of `checkfile.sh` and `checkmany.sh` and did not need a full
entry of their own, but they are the ones I keep almost repeating:

- `set -e` kills the script when `checkfile.sh` exits non-zero on purpose.
  Use `cmd || rc=$?` -- the `||` disables `set -e` and captures the code.
- Reset `rc=0` before each call, or a passing file inherits the previous
  file's exit code.
- `(( n++ ))` returns failure when `n` is 0, which kills the script under
  `set -e` -- on the first *passing* file. Use `n=$(( n + 1 ))`.
- Test files in `/tmp` disappear after a reboot. Moved them to
  `~/lab/fixtures` with a script to rebuild them.

---

Most of my time so far went to things being silently ignored rather than
things failing loudly. A config file that is skipped, a key that is never
offered, a directory that is not the one I think it is. Verification is not
paranoia here, it is the only way to know.
