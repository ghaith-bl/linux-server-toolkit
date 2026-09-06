# linux-server-toolkit

A small set of Bash scripts that monitor and maintain a Linux server, scheduled with systemd timers.

> Status: work in progress. I am building this step by step and writing down what I learn, including the parts where I was wrong.

## The Problem This Solves

A small server does not tell you when something goes wrong. A disk fills up, a
service stops at 3 AM, or someone tries to brute force SSH, and nobody notices
until a user complains the next morning.

Tools like Prometheus or Nagios solve this well, but they are heavy for one or
two servers, and they hide the basics behind a dashboard. I wanted to understand
what is actually being checked.

This toolkit does the basic job with plain Bash and systemd, which are already
installed on every Linux server. No agent, no database, no extra packages.

It checks system health, watches services and restarts them if they stop, reads
`auth.log` for failed SSH logins, and takes backups that clean up after
themselves. All settings live in one config file.

## Architecture

<!-- TODO: update this diagram as the scripts get written -->

```
        systemd timers
              |
              v
    +---------------------+
    |      scripts/       |
    |  health-check.sh    |
    |  service-watch.sh   |
    |  log-analyzer.sh    |
    |  backup.sh          |
    +----------+----------+
               |
      +--------+--------+
      |                 |
      v                 v
 lib/common.sh   config/toolkit.conf
 logging          thresholds
 colors           paths
 error handling   service list
      |
      v
 /var/log/toolkit/
```

Nothing runs on a schedule by itself. systemd timers start the scripts, the
scripts read their settings from the config file, and everything they do is
written to a log file and to stdout.

## Features

<!-- TODO: fill in after each script is finished -->

## Installation

<!-- TODO: after install.sh is written -->

## Usage

<!-- TODO: real commands with real output, not made up examples -->

## Configuration

<!-- TODO: explain every option in config/toolkit.conf -->

## Problems I Hit and How I Solved Them

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



- `set -e` kills the script when `checkfile.sh` exits non-zero on purpose.
  Use `cmd || rc=$?` — the `||` disables `set -e` and captures the code.
- Reset `rc=0` before each call, or a passing file inherits the previous
  file's exit code.
- `(( n++ ))` returns failure when `n` is 0, which kills the script under
  `set -e` — on the first *passing* file. Use `n=$(( n + 1 ))`.
- Test files in `/tmp` disappear after a reboot. Moved them to
  `~/lab/fixtures` with a script to rebuild them.

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

## What I Learned

<!-- TODO: keep adding as I go -->

- `/var/log/auth.log` is owned by `syslog:adm` with mode `640`. My user is in the
  `adm` group, so scripts can read it without `sudo`. Least privilege by default.
  This will matter when I write the systemd unit: running as a normal user will
  need `SupplementaryGroups=adm`.
- I chose the normal Ubuntu Server install over "minimized". The minimized image
  drops packages meant for automated images, including `rsyslog`. Without
  `rsyslog` there is no `/var/log/auth.log` at all, which would have broken the
  whole log analyzer before I wrote a line of it.
- I installed none of the featured snaps. Every package added by the installer is
  a hidden assumption that is written down nowhere. The goal is that `install.sh`
  sets up everything on a clean system.
- The repo lives on the VM, not on my laptop. These scripts read
  `/var/log/auth.log` and call `systemctl` on Ubuntu services. My laptop runs
  Fedora Silverblue, so none of them could actually be tested there. The VM is
  disposable because every commit is pushed to GitHub.
- Most of my time so far went to things being silently ignored rather than things
  failing loudly. A config file that is skipped, a key that is never offered, a
  directory that is not the one I think it is. Verification is not paranoia here,
  it is the only way to know.

## Roadmap

<!-- TODO: any idea that is out of scope goes here, not into the code -->

## License

MIT. See [LICENSE](LICENSE).
