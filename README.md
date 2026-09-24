# Production Server Setup Script

A single Bash script that brings a fresh Ubuntu/Debian server to a sane production baseline:

1. **Timezone** — set via `timedatectl`, verifies NTP sync
2. **Hostname** — set via `hostnamectl`, updates `/etc/hosts`
3. **Firewall** — UFW with default-deny inbound + SSH/HTTP/HTTPS open + any extras from `.env`
4. **SSH key** — install your existing public key for passwordless login
5. **Swap** — optional swapfile at `/swapfile` with sensible swappiness
6. **fail2ban** — install and enable the SSH jail with configurable bantime/findtime/maxretry
7. **SSH hardening** — *advisory only*; prints recommended `sshd_config` and the manual commands to apply them safely
8. **apt update + upgrade** — runs `apt-get update && apt-get upgrade` (and optional `autoremove`) to bring the system up to date
9. **Add 3rd-party APT repositories** — *opt-in via `--add-repo`*. Adds repositories from `APT_REPOSITORIES`, then runs `apt update`. Does **not** run upgrade.
10. **Install baseline server packages** — *opt-in via `--install-packages`*. Installs the package list from `DEFAULT_PACKAGES` in `.env` (skip already-installed). Comment out packages you don't want.
11. **Custom shell prompt** — *opt-in via `--prompt`*. Appends a guarded, idempotent colored PS1 block to `~/.bashrc` showing date/time, user@host, working directory, and (inside git repos) the current branch. The PS1 template is user-configurable via `PROMPT_PS1_TEMPLATE` in `.env`; leave blank to use the built-in default.
12. **msmtp SMTP client** — runs in **RUN ALL** by default (skip with `--no-msmtp`; run in selective mode with `--msmtp / -m`). Installs `msmtp`/`msmtp-mta` via apt if missing, prompts for the SMTP password interactively, then writes a per-user `~/.msmtprc` (mode 0600) from the `MSMTP_*` values in `.env`.
13. **`luozongbao/server-report-script`** — *opt-in via `--server-report`*. Downloads the GitHub release zip at `SERVER_REPORT_SCIPT_LINK`, extracts to `/opt/server-report-script/`, then runs the upstream `sudo install.sh` (which handles `/usr/local/bin/{auth,attack,memory}-report.sh` placement, `lib/` under `/usr/local/share/`, and `/etc/server-report-script.env` seeding). No GitHub API call — works on hosts that can reach `github.com` but not `api.github.com`.

The script is **idempotent** — re-running it won't break anything.

> **v1.1.0 breaking change**: the `--install-defaults / -p` flag was renamed to `--install-packages / -i`. The `-p` short flag is now used by `--prompt`. Update any scripts or documentation that referenced the old flag.

> **Two invocation modes** — see [Selection rules](#selection-rules) below:
>
> - **RUN ALL mode** (`sudo ./setup.sh`, no flags) runs every default section plus any opt-in section whose required `.env` key is set. Opt-in sections whose required key is missing are quietly skipped.
> - **Selective mode** (one or more `--<section>` flags) runs **only** the sections you named, minus any `--no-X` exclusions. Opt-in sections do **not** auto-enable from `.env` in this mode — pass the flag explicitly.

---

## Requirements

- Ubuntu or Debian (systemd-based)
- Run as root: `sudo ./setup.sh`

## Quick Start — interactive

```bash
sudo ./setup.sh
```

You'll be prompted for any value not provided via `.env`.

## Quick Start — with `.env` (recommended)

```bash
cp .env.example .env
# edit .env — fill in TIMEZONE, HOSTNAME, SWAP_SIZE_MB, etc.

# (optional) drop your public key here:
cp ~/.ssh/id_ed25519.pub ./ssh_key.pub

sudo ./setup.sh
```

Any variable left blank in `.env` will trigger an interactive prompt at run time.

## Quick Start — with CLI flags (selective sections)

You can run only specific sections instead of the full sweep:

```bash
sudo ./setup.sh --swap                   # only create swap
sudo ./setup.sh --swap --firewall        # swap + firewall
sudo ./setup.sh --hostname web01 --swap  # override hostname, run only swap
sudo ./setup.sh --no-fail2ban            # everything except fail2ban
sudo ./setup.sh --non-interactive        # skip prompts, fail fast on missing values
```

### CLI flags

| Flag | Short | Effect |
|---|---|---|
| `--timezone` | `-t` | Run the timezone section |
| `--no-timezone` | | Skip the timezone section |
| `--hostname NAME` | `-n` | Run the hostname section; `NAME` overrides `.env`/HOSTNAME |
| `--no-hostname` | | Skip the hostname section |
| `--firewall` | `-f` | Run the firewall section |
| `--no-firewall` | | Skip the firewall section |
| `--ssh-key` | `-k` | Run the SSH-key installation section |
| `--no-ssh-key` | | Skip the SSH-key section |
| `--swap` | `-s` | Run the swap section |
| `--no-swap` | | Skip the swap section |
| `--fail2ban` | `-b` | Run the fail2ban section |
| `--no-fail2ban` | | Skip the fail2ban section |
| `--ssh-harden` | | Run the SSH-hardening advisory section |
| `--no-ssh-harden` | | Skip the SSH-hardening advisory section |
| `--non-interactive` | `-y` | Skip all prompts; fail fast on missing required values |
| `--help` | `-h` | Show usage |
| `--apt-upgrade` | `-u` | Run `apt update` + `apt upgrade` |
| `--no-apt-upgrade` | | Skip `apt update` + `apt upgrade` |
| `--add-repo` | `-r` | Add 3rd-party repos from `APT_REPOSITORIES`, then `apt update` |
| `--no-add-repo` | | Skip add-repo |
| `--install-packages` | `-i` | Install baseline packages from `DEFAULT_PACKAGES` |
| `--no-install-packages` | | Skip install-packages |
| `--prompt` | `-p` | Install managed colored PS1 block into `~/.bashrc` |
| `--no-prompt` | | Skip prompt customization |
| `--msmtp` | `-m` | Configure msmtp SMTP client (install if missing, write `~/.msmtprc`). Runs in RUN ALL by default; this flag is for selective invocations. |
| `--no-msmtp` | | Skip msmtp configuration (override the RUN ALL default) |
| `--server-report` | `-R` | Pull + install `luozongbao/server-report-script` from a GitHub release zip. Opt-in. | `-r` is taken by `--add-repo`. |
| `--no-server-report` | | Skip server-report install |

### Selection rules

The script has **two invocation modes**. Every invocation is one or the other.

#### 1. RUN ALL mode — `sudo ./setup.sh` (no section flags)

This is what you run on a fresh server. Every **default** section runs in order, **plus** any opt-in section whose required `.env` key is present. Opt-in sections whose required key is missing are silently skipped (the script never prompts you to enable them — they stay off).

| Runs unconditionally | Runs only if its required `.env` key is set |
|---|---|
| timezone, hostname, firewall, ssh-key, swap, fail2ban, ssh-harden, apt-upgrade, msmtp | add-repo (`APT_REPOSITORIES`), install-defaults (`DEFAULT_PACKAGES`), prompt (`PROMPT_ENABLED`), server-report (`SERVER_REPORT_SCIPT_LINK`) |

You can subtract any default section without leaving RUN ALL mode by adding `--no-<taskname>`. For example `sudo ./setup.sh --no-msmtp` runs everything except msmtp; `sudo ./setup.sh --no-msmtp --no-prompt` runs everything except msmtp and the prompt block. `--no-X` flags on sections that aren't even running are harmless.

> **Why are `add-repo`, `install-defaults`, and `prompt` opt-in?** These mutate sources lists, install dozens of packages, or rewrite every user's `~/.bashrc` — all things you don't want done automatically on every host. You opt them in either by setting the relevant `.env` key (RUN ALL picks it up) or by passing the flag explicitly (selective mode).

#### 2. Selective mode — `sudo ./setup.sh --<taskname> [...]`

When **any** `--<section>` or `--no-<section>` flag is passed, the script switches out of RUN ALL and runs **only** the explicitly-enabled sections, minus any `--no-X` removals. For example:

```bash
sudo ./setup.sh --swap                                  # swap only
sudo ./setup.sh --swap --firewall                       # swap + firewall
sudo ./setup.sh --hostname web01 --swap                 # only swap, with hostname override
sudo ./setup.sh --no-fail2ban --no-msmtp                # every default except fail2ban + msmtp
```

In selective mode, **opt-in sections do not auto-enable from `.env`** — pass the flag explicitly if you want them. For example `sudo ./setup.sh --add-repo` runs only `add-repo`, even when `APT_REPOSITORIES` is set (which would have triggered it in RUN ALL mode).

Passing `--no-<section>` without its positive counterpart is allowed and behaves as "all defaults except X". For example `sudo ./setup.sh --no-msmtp` is the recipe for "full RUN ALL minus msmtp" without leaving RUN ALL mode.

#### Common to both modes

- **`--no-<taskname>` always wins.** Whether you're in RUN ALL or selective mode, `--no-firewall` removes firewall from the active set, period.
- **`--non-interactive` / `-y`** skips all interactive prompts. In RUN ALL mode it auto-detects whether every required key is present in `.env` and turns itself on; pass `-y` to force it on (the script will exit with code `2` listing missing keys).
- **Precedence** (highest to lowest): `CLI flag > .env value > interactive prompt > built-in default`. The `--hostname NAME` flag wins over `.env`'s `HOSTNAME`.
- **Auto-detect non-interactive**: if you pass any section flag *and* `.env` contains every required value for those sections, the script runs non-interactively without needing `-y`. Pass `-y` to force non-interactive even with missing values (the script exits with code `2` and lists them).

### Configured via `.env`

| Variable | Purpose | Default | Required (when `NONINTERACTIVE=true`) |
|---|---|---|---|
| `TIMEZONE` | IANA tz name (e.g. `Asia/Shanghai`) | prompts | yes |
| `HOSTNAME` | new hostname | prompts | yes |
| `FIREWALL_APPLY` | `true`/`false` — apply UFW rules | prompts | yes |
| `FIREWALL_EXTRA_PORTS` | comma-separated, e.g. `5432/tcp,8080/tcp` | none | no |
| `SSH_PUBLIC_KEY` | full public key line (see note below) | prompts | yes (or `ssh_key.pub`) |
| `SSH_PUBLIC_KEY_APPEND` | auto-append to existing `authorized_keys` | prompts | no |
| `SWAP_SIZE_MB` | size of `/swapfile` in MB, `0` to skip | `0` | yes |
| `FAIL2BAN_ENABLED` | install + enable fail2ban | `true` | yes |
| `FAIL2BAN_BANTIME` | ban duration, e.g. `1h`, `30m`, `1d` | `1h` | no |
| `FAIL2BAN_FINDTIME` | counter window, e.g. `10m`, `1h` | `10m` | no |
| `FAIL2BAN_MAXRETRY` | failures before ban | `5` | no |
| `APT_UPGRADE` | `true` = run `apt-get update && apt-get upgrade -y` | `true` | yes |
| `APT_AUTOREMOVE` | `true` = also run `apt-get autoremove -y` | `false` | no |
| `APT_REPOSITORIES` | `name\|url[|suite|components|key_url];...` | none | no |
| `DEFAULT_PACKAGES` | space-separated package list (comment with `#`) | rich default | no |
| `PROMPT_ENABLED` | `true` = install managed PS1 block into `~/.bashrc` | `true` | yes (when running prompt section) |
| `PROMPT_PS1_TEMPLATE` | custom PS1 string with ANSI escapes; blank = built-in default | blank | no |
| `SERVER_REPORT_SCIPT_LINK` | full URL to a GitHub release zip (https://github.com/...) — `setup.sh` downloads + extracts to `/opt/server-report-script/` then runs `sudo install.sh` (the upstream installer handles `/usr/local/bin/` placement) | default URL pinned to upstream's `v.2.0` tag | yes (when running server-report section) |
| `MSMTP_HOST` | SMTP server hostname | blank | yes (when running msmtp section) |
| `MSMTP_PORT` | SMTP port (typically `587` for STARTTLS, `465` for SMTPS) | `587` | no |
| `MSMTP_USER` | SMTP auth username | blank | yes (when running msmtp section) |
| `MSMTP_FROM` | `From:` address; defaults to `MSMTP_USER` if blank | blank | no |
| `NONINTERACTIVE` | `true` = skip all prompts, fail on missing | `false` | — |

> **Note on SSH key storage:** the preferred approach is to put your key in a separate file named `ssh_key.pub` in the same directory — no quoting headaches, and easy to `.gitignore`. The script uses `ssh_key.pub` if it exists, then falls back to `SSH_PUBLIC_KEY` in `.env`, then prompts.

## SSH Key Workflow (the important part)

The script intentionally does **not** auto-disable password authentication, because doing so without a working key would lock you out.

### Step 1 — On your local machine, generate a key (if you don't already have one)

```bash
ssh-keygen -t ed25519 -C "you@your-machine"
```

This creates `~/.ssh/id_ed25519` (private — **never share**) and `~/.ssh/id_ed25519.pub` (public — safe to share).

### Step 2 — Either drop the key into `ssh_key.pub` or paste it inline

Option A — separate file (preferred):

```bash
cp ~/.ssh/id_ed25519.pub /path/to/production-server-script/ssh_key.pub
```

Option B — inline in `.env`:

```bash
SSH_PUBLIC_KEY="ssh-ed25519 AAAA...rest-of-key... you@your-machine"
```

The script installs it to `~/<your-user>/.ssh/authorized_keys` with correct permissions (`700` on `.ssh`, `600` on `authorized_keys`).

### Step 3 — Verify key-based login works **before** disabling passwords

In a **new terminal** (do not close the current one):

```bash
ssh your-user@server-ip
```

If it logs you in without asking for a password, you're good.

### Step 4 — Manually apply the SSH hardening (commands printed by the script)

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

The `sshd -t` step validates the config before reloading — if it errors, nothing is restarted and you're not locked out.

### Step 5 — Verify again, in yet another new terminal

```bash
ssh your-user@server-ip
```

Then test that password auth is actually rejected:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no your-user@server-ip
```

That should fail with `Permission denied (publickey)`.

---

## Why "advisory only" for SSH hardening?

Auto-applying `PasswordAuthentication no` is the #1 cause of "I locked myself out of my server" stories. The script:

- Always installs the key first (or tells you how)
- Verifies an `authorized_keys` exists before suggesting changes
- Prints the exact `sed` commands instead of running them
- Validates with `sshd -t` (dry-run) before any reload
- Keeps your current session untouched

You stay in control of the lock-out boundary.

---

## What the firewall does

| Port | Protocol | Purpose |
|------|----------|---------|
| 22   | TCP      | SSH |
| 80   | TCP      | HTTP (redirect to HTTPS is up to you) |
| 443  | TCP      | HTTPS |
| *from `FIREWALL_EXTRA_PORTS`* | TCP | any extras you need |

Default policy: **deny incoming, allow outgoing**. All other inbound traffic is dropped. To open more ports later:

```bash
sudo ufw allow 5432/tcp comment 'PostgreSQL'
```

## Re-running

Safe. Timezone/hostname sections detect no-ops. UFW reset is only run if you confirm. SSH key section appends nothing if a key is already present. Swap is only created when no swap file exists.

## Swap

When `SWAP_SIZE_MB` is set in `.env` (e.g. `2048`), the script:

- Creates `/swapfile` of that size (via `fallocate`, falls back to `dd`)
- Sets permissions to `600`, formats it as swap, and activates it
- Adds an `/etc/fstab` entry for persistence across reboots
- Sets `vm.swappiness=10` (server-friendly — avoids swap thrashing)

Skip by leaving `SWAP_SIZE_MB` blank or set to `0`.

## fail2ban

When `FAIL2BAN_ENABLED=true` (default), the script:

- Installs `fail2ban` if missing (idempotent — skips if present)
- Writes `/etc/fail2ban/jail.local` (overrides `jail.conf` without touching distro files)
- Sets the `[sshd]` jail to `enabled = true`, `mode = aggressive`, `backend = systemd`
- Applies `FAIL2BAN_BANTIME` / `FAIL2BAN_FINDTIME` / `FAIL2BAN_MAXRETRY` from `.env`
- Enables and starts/reloads the service

If `/etc/fail2ban/jail.local` already exists and is **not** managed by this script (no marker comment), the script leaves it untouched — your existing config wins.

## Custom shell prompt

When `PROMPT_ENABLED=true` (default) **or** when `--prompt / -p` is passed, the script appends a managed, guarded PS1 block to `TARGET_USER`'s `~/.bashrc`.

### Default prompt

Renders as (inside a git repo):

```
26-09-24 19:09 web@host:~/projects/production-server-script (dev)$
```

Components left to right: gray date+time · green user@host · blue cwd · yellow git branch in parens · `$` (or `#` for root).

Outside a git repo, the `(branch)` segment disappears cleanly — no stray `)`, no embedded newline.

### Customizing the PS1

Set `PROMPT_PS1_TEMPLATE` in `.env` to a PS1 string with ANSI escapes. The default template (uncomment to use as a starting point):

```bash
# Example: copy + edit this in .env
# PROMPT_PS1_TEMPLATE='\[\033[1;90m\]\D{%y-%m-%d %H:%M}\[\033[0m\] \[\033[1;32m\]\u@\h\[\033[0m\]:\[\033[1;34m\]\w\[\033[0;33m\]$(b=$(git symbolic-ref --short HEAD 2>/dev/null); [[ -n "$b" ]] && printf " (%s)" "$b")\[\033[0m\]\$ '
```

**Tips:**

- Wrap ANSI escape codes in `\[ \]` so bash counts them as zero-width (otherwise line wrapping breaks).
- Use a **single** `\D{...}` call instead of multiple — each `\D{}` forks `date(1)`.
- Wrap git branch subshells in `printf` (not `echo`) and gate with `[[ -n "$var" ]] && printf` — otherwise PS1 injects newlines or stray characters.
- Use `git symbolic-ref --short HEAD` instead of `git branch` — the latter returns empty on repos with zero commits.

### Re-running behavior

The block is wrapped in `# >>> production-server-script:PROMPT >>>` / `# <<< production-server-script:PROMPT <<<` markers, so re-running `setup.sh` **replaces** the block in place instead of appending duplicates. Editing `PROMPT_PS1_TEMPLATE` and re-running picks up the new template.

Inside the block, a `PROMPT_OVERRIDE` guard ensures PS1 is set **once per shell** — so if you source `~/.bashrc` again, the managed block won't override your own changes made during the session.

To remove the block entirely, set `PROMPT_ENABLED=false` in `.env` and re-run.

## msmtp SMTP client

The script configures `msmtp` so that the server (and its users) can send mail directly via an external SMTP relay — useful for `cron`, `systemd` timer reports (like [server-report-script](https://github.com/luozongbao/server-report-script)), `at` jobs, and ad-hoc alerting. This section runs in **RUN ALL** by default — skip it with `--no-msmtp`, or invoke it on its own with `--msmtp / -m`.

### What the section does

1. **Installs** `msmtp` and `msmtp-mta` via `apt-get` if they are not already present.
2. **Validates required `.env` keys** (`MSMTP_HOST`, `MSMTP_USER`). If either is blank the section exits non-zero with a clear "set these keys in `.env`" message — no partial state is left behind.
3. **Prompts for the SMTP password** silently (`read -s`) and asks you to type it twice. Mismatch → re-prompt loop. The password never lives anywhere on disk except inside the generated `~/.msmtprc`.
4. **Asks `[o]verwrite / [a]bort`** when `~/.msmtprc` already exists. Default is overwrite; choosing overwrite creates a timestamped backup first (`.msmtprc.bak.YYYYMMDD-HHMMSS`). Merge was deliberately not implemented — see [Existing `~/.msmtprc` handling](#existing-msmtprc-handling).
5. **Writes a fresh `~/.msmtprc`** for `TARGET_USER` using the `.env` values plus the password you just typed. File permissions are `0600`, owner is the target user.

### Trigger model

There is no `MSMTP_ENABLED` flag. Instead:

- `sudo ./setup.sh` (no flags) — RUN ALL — **msmtp section runs**.
- `sudo ./setup.sh --msmtp` — only the msmtp section runs (everything else skipped).
- `sudo ./setup.sh --no-msmtp` — msmtp section skipped, everything else runs.
- `sudo ./setup.sh --msmtp --non-interactive` — fails fast: the section requires an interactive TTY for the password prompt.

### Required .env keys

Two keys are required when the section runs (`MSMTP_FROM` and `MSMTP_PORT` are optional):

```bash
MSMTP_HOST=smtp.example.com
MSMTP_USER=alerts@example.com
# optional:
MSMTP_PORT=587
MSMTP_FROM=alerts@example.com
```

The password is **never** read from `.env` — see [Password handling](#password-handling). If `MSMTP_HOST` or `MSMTP_USER` is blank when the section runs, the script exits non-zero with:

```
✗ missing required .env keys: MSMTP_HOST MSMTP_USER
✗ set them in .env and re-run, or pass --no-msmtp to skip this section
```

### Generated `~/.msmtprc`

```bash
# Managed by production-server-script — do not edit by hand.
# To update, edit MSMTP_* values in .env and re-run setup.sh.
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        default
host           smtp.example.com
port           587
from           alerts@example.com
user           alerts@example.com
password       app-password-here
```

`TLS` is on by default with `tls_starttls` (so port `587` works). For port `465` (SMTPS), switch to `tls_starttls off` — the section does **not** auto-detect port-to-TLS-mode mapping. If you need SMTPS, edit the generated `~/.msmtprc` after install, or add an `MSMTP_TLS_STARTTLS` knob in a future version.

### Security notes

- The SMTP password is written **in plaintext** to `~/.msmtprc` (msmtp's standard format). This is the only way msmtp can read it. The file is `chmod 600` so only the owning user can read it.
- The password is **never** stored in `.env` — see [Password handling](#password-handling). This avoids the dual-storage problem (same plaintext in two places) and removes the need to `chmod 600 .env`.
- For Gmail, use an [App Password](https://myaccount.google.com/apppasswords), not your account password. For SendGrid, Mailgun, etc., use the provider's "SMTP credential", not the API key.
- The script refuses to run the section non-interactively. If you need unattended setup, see [Unattended setup](#unattended-setup) below.

### Password handling

The password is supplied via exactly one path: an interactive prompt at section-run time. There is no `MSMTP_PASSWORD` or `MSMTP_PASSWORD_FILE` key in `.env` by design — putting a plaintext credential in `.env` is a footgun (file checked into git by accident, copied around in backups, etc.).

```
  SMTP password: ********
  Confirm password: ********
```

- No echo on the terminal.
- A mismatch re-prompts (loop until match or Ctrl-C).
- An empty first entry re-prompts (no empty passwords).
- The password only lives in a local Bash variable inside the function, and is `unset` immediately after `~/.msmtprc` is written (via `trap 'unset pass' RETURN`).
- The script fails fast with a clear error if stdin is not a TTY (e.g. piped from `echo` or run under `sudo --non-interactive`).

### Existing `~/.msmtprc` handling

If `/home/$TARGET_USER/.msmtprc` exists when the section starts, the script asks:

```
  /home/$TARGET_USER/.msmtprc already exists. [o]verwrite / [a]bort [o]:
```

- `[o]verwrite` (default) — creates a timestamped backup (`~/.msmtprc.bak.YYYYMMDD-HHMMSS`) with `cp -a` (preserves mode/owner), then writes a fresh config from current `.env` values.
- `[a]bort` — exits cleanly, the existing file is left untouched. Useful when you have a hand-tuned `~/.msmtprc` that you don't want `setup.sh` to clobber.

There is no "merge" option. Deciding what to keep and what to discard from an existing config is bug-prone (different field names, comments you want preserved, etc.) and the script's design is: the source of truth is `.env`, the output is fully regenerated every run.

### Unattended setup

If you need to provision the server without a human at the terminal, the section's hard requirement is a TTY. Options:

- **Run `setup.sh` with a TTY** (e.g. `script -qc "sudo ./setup.sh --msmtp" /dev/null` or a CI runner with `tty: true`) and pipe the password via `expect`.
- **Skip the section in unattended mode**, then write `/home/$TARGET_USER/.msmtprc` directly with your configuration-management tool of choice (Ansible, Salt, cloud-init, etc.).

### Re-running behavior

The section overwrites `~/.msmtprc` on every run with the current `.env` values + the password you typed, so rotating the SMTP password with your provider and re-running `setup.sh` picks up the new credential with no manual edit.

If `apt-get install msmtp` fails (e.g. no network to the Debian mirror), the section aborts before touching any config files, so a half-installed state cannot happen.

## `luozongbao/server-report-script` installer

A companion utility the maintainer also runs on every server to collect
diagnostics and report them. `setup.sh` ships an **opt-in** section that pulls
the upstream release zip, extracts it to `/opt/server-report-script/`, then
runs **the upstream `install.sh`** which handles all the placement work
itself (scripts at `/usr/local/bin/`, `lib/` under
`/usr/local/share/`, seeded `/etc/server-report-script.env`). See
[luozongbao/server-report-script](https://github.com/luozongbao/server-report-script).

This section is **opt-in** — it never runs on a bare `sudo ./setup.sh`. Either
pass `--server-report / -R`, or set `SERVER_REPORT_SCIPT_LINK` in `.env` and
the section auto-enables in RUN ALL mode.

> **Spelling note** — the env key is `SERVER_REPORT_SCIPT_LINK` (with the "R"
> missing from "SCRIPT"). That name was chosen during the implementation of
> issue #011 and is preserved here verbatim. Rename freely in your own `.env`
> if you maintain this config long-term.

### Trigger model

| Invocation | `server-report` runs? |
|---|---|
| `sudo ./setup.sh` (RUN ALL, no flags) with `SERVER_REPORT_SCIPT_LINK` set in `.env` | yes |
| `sudo ./setup.sh` with `SERVER_REPORT_SCIPT_LINK` blank | **no** — section skipped silently |
| `sudo ./setup.sh --server-report` / `-R` | yes |
| `sudo ./setup.sh --no-server-report` | no |
| `sudo ./setup.sh --server-report --non-interactive` with `SERVER_REPORT_SCIPT_LINK` blank | **no** — fails fast with exit 2 |

### What the section does

1. **Downloads** the GitHub release zip from the **literal URL** you put in `SERVER_REPORT_SCIPT_LINK` (default: `https://github.com/luozongbao/server-report-script/archive/refs/tags/v.2.0.zip`). No `git clone`, no GitHub API call — this works on hosts that can reach `github.com` but NOT `api.github.com` (common on China-region networks).
2. **Extracts** to `/opt/server-report-script/`. Re-runs overwrite the directory in place; the directory itself is preserved so its owner / perms don't churn.
3. **Hands off to the upstream installer** — runs `sudo /opt/server-report-script/install.sh`. That installer is idempotent (safe to re-run) and produces:
   - `/usr/local/bin/{auth,attack,memory}-report.sh` — `0755`
   - `/usr/local/share/server-report-script/lib/` — `0644`
   - `/etc/server-report-script.env` — `0600` (seeded from `.env.example` only if missing; pass `sudo /opt/server-report-script/install.sh --force` to overwrite)
4. **`setup.sh` does NOT symlink anything into `/usr/local/bin/` itself** — that's the upstream installer's job, and the resulting file mode `0755` install is what the upstream recipes expect (each script resolves its `lib/common.sh` lookup through a 4-tier chain that includes `/usr/local/share/...`).

### `.env` keys

```bash
# Full URL to a GitHub release zip. The section does NOT construct this
# for you — whatever you put here is exactly what gets downloaded. Pick
# a tag from https://github.com/luozongbao/server-report-script/tags.
SERVER_REPORT_SCIPT_LINK=https://github.com/luozongbao/server-report-script/archive/refs/tags/v.2.0.zip
```

The default in `.env.example` points at upstream's `v.2.0` tag. To pin to a
newer or older release, paste a different zip URL (right-click → "Copy link
address" on the **Source code (zip)** asset in the GitHub releases UI).

> **URL scheme guard** — only `https://github.com/...` is accepted. A
> malformed `.env` value (e.g. `http://`, `file://`, a custom scheme, or a
> non-GitHub host) exits non-zero with a clear "Invalid
> `SERVER_REPORT_SCIPT_LINK`" message **before** any `curl` call — the
> section never downloads from an arbitrary host.

### Re-running behavior

The section is fully idempotent:

- `/opt/server-report-script/` is emptied in place (the directory itself is
  preserved so its owner / perms don't change) and re-populated from the
  latest extracted zip contents.
- The upstream `install.sh` is itself idempotent — re-running it does not
  duplicate or damage the `/usr/local/bin/`, `/usr/local/share/`, or
  `/etc/server-report-script.env` placements. To force-overwrite an existing
  `/etc/server-report-script.env` after you edited it manually, run
  `sudo /opt/server-report-script/install.sh --force`.

### Failure modes

- **Bad URL** (e.g. 404, or a `SERVER_REPORT_SCIPT_LINK` that's not an
  `https://github.com/...` URL) → `curl` fails, the section prints the URL
  and a hint to verify it, then `rm -rf $tmpdir` and exits non-zero. **No
  partial install** — `/opt/server-report-script/` is not touched unless
  the download succeeds.
- **Upstream `install.sh` exits non-zero** → the section warns and exits
  non-zero with the exact `sudo` re-run command to finish manually. The
  `/opt/server-report-script/` checkout is already on disk, so the manual
  re-run is a one-liner.
- **Missing `SERVER_REPORT_SCIPT_LINK` in `NONINTERACTIVE` mode** →
  `exit 2` with a clear message. No interactive prompt for the URL in
  unattended runs (it's a deploy-time decision).

### Network-restriction compatibility

The section downloads from `https://github.com/...` — the same origin your
browser would hit — and never touches `api.github.com`. To verify it works
on a host where the API is blocked:

```bash
# This MUST work for the section to work:
curl -fsSL -o /dev/null "$(awk -F= '/^SERVER_REPORT_SCIPT_LINK=/ {print $2}' .env)"

# This is NOT contacted:
curl -fsSL -o /dev/null https://api.github.com/repos/luozongbao/server-report-script/releases
```

---

## NONINTERACTIVE mode

Set `NONINTERACTIVE=true` for CI / cloud-init / fully unattended runs. The script:

1. Refuses to start if any *required* variable in `.env` is empty (lists them and exits with code 2).
2. Validates every value up-front (`TIMEZONE` against `timedatectl list-timezones`, `HOSTNAME` against RFC 1123, port specs against `<n>[/tcp|udp]` with 1-65535, numeric ranges) **before** making any system changes.
3. Defaults `ask()` prompts to `N` unless the prompt's default is `Y`.
4. Skips the SSH key interactive paste — requires `ssh_key.pub` or `SSH_PUBLIC_KEY`.

Validation failures exit with code `2` (distinct from `1` = unexpected error) so orchestration tools can tell them apart.

## Tested on

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12 (bookworm)

Other systemd Debian-family distros should work but are untested.
