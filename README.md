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
12. **msmtp SMTP client** — *opt-in via `--msmtp`*. Installs `msmtp`/`msmtp-mta` via apt if missing, then writes a per-user `~/.msmtprc` (mode 0600) from the `MSMTP_*` values in `.env`. Optionally also writes `/root/.msmtprc` for cron/systemd, and optionally sends a one-shot test email to verify the config end-to-end.

The script is **idempotent** — re-running it won't break anything.

> **v1.1.0 breaking change**: the `--install-defaults / -p` flag was renamed to `--install-packages / -i`. The `-p` short flag is now used by `--prompt`. Update any scripts or documentation that referenced the old flag.

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
| `--msmtp` | `-m` | Configure msmtp SMTP client (install if missing, write `~/.msmtprc`) |
| `--no-msmtp` | | Skip msmtp configuration |

### Selection rules

- **No section flag given** → ALL sections run (matches the original behaviour).
- **Any section flag given** → ONLY those sections run, minus any `--no-X` exclusions. For example `--swap --no-fail2ban` runs only swap.
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
| `MSMTP_ENABLED` | `true` = configure msmtp (install if missing, write `~/.msmtprc`) | blank | yes (when running msmtp section) |
| `MSMTP_HOST` | SMTP server hostname | blank | yes |
| `MSMTP_PORT` | SMTP port (typically `587` for STARTTLS, `465` for SMTPS) | `587` | no |
| `MSMTP_USER` | SMTP auth username | blank | yes |
| `MSMTP_FROM` | `From:` address; defaults to `MSMTP_USER` if blank | blank | no |
| `MSMTP_PASSWORD_FILE` | path to file containing the SMTP password (one line) — used only in `--non-interactive` mode; see [Password handling](#password-handling) | blank | yes (when `--non-interactive`) |
| `MSMTP_ROOT_CONFIG` | `true` = also write `/root/.msmtprc` for cron/systemd | blank | no |
| `MSMTP_TEST_EMAIL_TO` | send a one-shot test email to this address after config | blank | no |
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

When `MSMTP_ENABLED=true` **or** when `--msmtp / -m` is passed, the script configures `msmtp` so that the server (and its users) can send mail directly via an external SMTP relay — useful for `cron`, `systemd` timer reports (like [server-report-script](https://github.com/luozongbao/server-report-script)), `at` jobs, and ad-hoc alerting.

### What the section does

1. **Installs** `msmtp` and `msmtp-mta` via `apt-get` if they are not already present. `apt-get install` is skipped silently when both packages are already installed.
2. **Writes `~/.msmtprc`** for `TARGET_USER` using the `MSMTP_*` values from `.env`. File permissions are `0600`, owner is the target user.
3. **Optionally writes `/root/.msmtprc`** when `MSMTP_ROOT_CONFIG=true` — needed for cron jobs and systemd timers that run as root and need their own SMTP config (cron can't read another user's `~/.msmtprc`).
4. **Optionally sends a test email** when `MSMTP_TEST_EMAIL_TO` is set to a valid `addr@host` — verifies the full TLS/auth path end-to-end after the config is written.

### Auto-detect / opt-in gate

This section is **explicit opt-in**: it is a no-op (does not prompt) unless `MSMTP_ENABLED=true` or `--msmtp` is passed. This is intentional — without the gate, a host that already has `msmtp` installed (e.g. pulled in by `cron` or some Debian metapackage) would still hit interactive prompts if `.env` had blank `MSMTP_*` values.

### Required .env keys

For interactive runs, the only required key is:

```bash
MSMTP_ENABLED=true
MSMTP_HOST=smtp.example.com
MSMTP_USER=alerts@example.com
MSMTP_FROM=alerts@example.com   # optional, defaults to MSMTP_USER
```

The password is **never** read from `.env` — see [Password handling](#password-handling) below.

If `MSMTP_ENABLED=true` but any of `MSMTP_HOST` / `MSMTP_USER` is blank, the script prompts interactively (unless `--non-interactive` is set, in which case it fails fast).

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

### Password handling

There is no `MSMTP_PASSWORD` key in `.env` by design. The password is supplied via one of two paths:

**Interactive mode (default)** — the section prompts silently, then prompts again to confirm. Mismatch → re-prompt, loop until match or you abort with Ctrl-C:

```
  SMTP password: ********
  Confirm password: ********
```

No echo on the terminal; the password only lives in a local Bash variable inside the function, and is `unset` immediately after `~/.msmtprc` is written (via a `trap ... RETURN`).

**Non-interactive mode (`--non-interactive`)** — point `MSMTP_PASSWORD_FILE` at a path that contains the password on a single line:

```bash
MSMTP_PASSWORD_FILE=/root/.msmtp.password
```

The file should be:

- Outside the repo (so it can't accidentally end up in git)
- Mode `0400` or `0600`, owned by the user running `setup.sh` (usually root)
- One line of password, no quoting, no trailing whitespace matters

The section reads the first non-empty line, writes it into `~/.msmtprc`, then immediately `unset`s the local variable. The file itself is **not** modified or deleted — rotate the password by updating the file and re-running `setup.sh`.

Example setup:

```bash
sudo install -m 0400 -o root -g root /dev/null /root/.msmtp.password
sudo $EDITOR /root/.msmtp.password     # paste the password, save, exit
echo 'MSMTP_PASSWORD_FILE=/root/.msmtp.password' >> /path/to/.env
sudo ./setup.sh --msmtp --non-interactive
```

### Re-running behavior

The section overwrites `~/.msmtprc` on every run with the current `.env` values, so changing `MSMTP_PASSWORD` (after rotating it with your provider) and re-running `setup.sh` picks up the new credential with no manual edit. If the file does not exist before the run, it is created with mode `0600`; if it does exist, mode and ownership are re-applied (it may have been edited by hand — `setup.sh` will reset them, which is intentional).

If `apt-get install msmtp` fails (e.g. no network to the Debian mirror), the section aborts before touching any config files, so a half-installed state cannot happen.

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
