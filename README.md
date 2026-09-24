# Production Server Setup Script

A single Bash script that brings a fresh Ubuntu/Debian server to a sane production baseline:

1. **Timezone** — set via `timedatectl`, verifies NTP sync
2. **Hostname** — set via `hostnamectl`, updates `/etc/hosts`
3. **Firewall** — UFW with default-deny inbound + SSH/HTTP/HTTPS open + any extras from `.env`
4. **SSH key** — install your existing public key for passwordless login
5. **Swap** — optional swapfile at `/swapfile` with sensible swappiness
6. **fail2ban** — install and enable the SSH jail with configurable bantime/findtime/maxretry
7. **SSH hardening** — *advisory only*; prints recommended `sshd_config` and the manual commands to apply them safely

The script is **idempotent** — re-running it won't break anything.

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
| `NONINTERACTIVE` | `true` = skip all prompts, fail on missing | `false` | — |

> **Note on SSH key storage:** the preferred approach is to put your key in a separate file named `ssh_key.pub` in the same directory — no quoting headaches, and easy to `.gitignore`. The script uses `ssh_key.pub` if it exists, then falls back to `SSH_PUBLIC_KEY` in `.env`, then prompts.

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
