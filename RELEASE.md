# Release Notes

## Version 1.1.1 — server-report-script version bump

Patch release pinning the default `SERVER_REPORT_SCIPT_LINK` in `.env.example` to a newer upstream tag of `luozongbao/server-report-script`. No script, flag, or behavior changes — only the default URL changed.

### What's Changed

- `.env.example` — `SERVER_REPORT_SCIPT_LINK` updated from the previous default tag to `https://github.com/luozongbao/server-report-script/archive/refs/tags/v.2.1.0.zip`.
- Users who already pinned their own URL in `.env` are unaffected; only the example default moved.
- `setup.sh` and `README.md` references to the historical `v.2.0` default were left intact for traceability — they describe what shipped in v1.1.0, not the current default.

### Upgrade Notes (v1.1.0 → v1.1.1)

- Pull `.env.example` and compare against your `.env` — if you never set `SERVER_REPORT_SCIPT_LINK` yourself, your next fresh `.env` will pick up the new default. Existing `.env` files keep whatever you already had.
- No other config keys, flags, or scripts changed. Re-running `setup.sh` with your existing `.env` behaves identically to v1.1.0.

---

## Version 1.1.0 — Prompt, msmtp, and server-report installer

Three new sections ship in this release: a customizable colored shell prompt, an `msmtp` SMTP client configurator, and an opt-in installer for the maintainer's `luozongbao/server-report-script` companion tool. Netplan (#010) was deferred to a future release.

### Sections (13)

| # | Section | Flag | Short | Default |
|---|---|---|---|---|
| 1 | Timezone | `--timezone` | `-t` | runs |
| 2 | Hostname | `--hostname NAME` | `-n` | runs |
| 3 | Firewall (UFW) | `--firewall` | `-f` | runs |
| 4 | SSH key install | `--ssh-key` | `-k` | runs |
| 5 | Swap | `--swap` | `-s` | runs |
| 6 | fail2ban | `--fail2ban` | `-b` | runs |
| 7 | SSH hardening (advisory) | `--ssh-harden` | — | runs |
| 8 | apt update + upgrade | `--apt-upgrade` | `-u` | runs |
| 9 | Add 3rd-party APT repos | `--add-repo` | `-r` | **opt-in** |
| 10 | Install baseline packages | `--install-packages` | `-i` | **opt-in** |
| 11 | Custom shell prompt | `--prompt` | `-p` | runs |
| 12 | msmtp SMTP client | `--msmtp` | `-m` | runs |
| 13 | `server-report-script` installer | `--server-report` | `-R` | **opt-in** |

> **Breaking change (v1.1.0):** the `--install-defaults` / `-p` flag was renamed to `--install-packages` / `-i` because `-p` is now used by `--prompt`. Update any scripts or documentation that referenced the old flag.

### What's New

#### Issue #009 — Customizable colored PS1 prompt

- New `prompt` section appends a guarded, idempotent PS1 block to `TARGET_USER`'s `~/.bashrc`, wrapped in `# >>> production-server-script:PROMPT >>>` / `# <<< production-server-script:PROMPT <<<` markers so re-runs replace the block in place instead of appending duplicates.
- Built-in default PS1 uses a single `\D{...}` call (1 fork per prompt redraw, not 3) and `git symbolic-ref --short HEAD` (works on repos with zero commits, no stray `)` outside git dirs, no embedded newlines).
- `PROMPT_PS1_TEMPLATE` in `.env` lets you override the PS1 string with your own ANSI escapes; leave blank to use the built-in default.
- `PROMPT_ENABLED=false` in `.env` removes an existing block on next run.
- Block guarded by `PROMPT_OVERRIDE` so `source ~/.bashrc` doesn't override your in-session changes.

#### Issue #011 — `luozongbao/server-report-script` installer

- New opt-in `server-report` section pulls a GitHub release zip from the literal URL in `SERVER_REPORT_SCIPT_LINK` (default: `https://github.com/luozongbao/server-report-script/archive/refs/tags/v.2.0.zip`).
- **No GitHub API call, no `git clone`** — works on hosts that can reach `github.com` but NOT `api.github.com` (common on China-region networks).
- **URL scheme guard** — only `^https://github\.com/` URLs are accepted; malformed `.env` values exit non-zero **before** any `curl` touches disk.
- Extracts to `/opt/server-report-script/` (idempotent — directory is recreated in place on re-install).
- Hands off to the upstream `sudo install.sh`, which is itself idempotent and owns all `/usr/local/bin/` placement (`{auth,attack,memory}-report.sh` at mode `0755`, `lib/` under `/usr/local/share/`, `/etc/server-report-script.env` seeded at mode `0600`).
- `setup.sh` does **not** symlink anything into `/usr/local/bin/` itself — that's the upstream installer's job, and the upstream mode `0755` install is what the upstream recipes expect.

> **Spelling note:** the env key is `SERVER_REPORT_SCIPT_LINK` — the "R" is missing from "SCRIPT". This typo was preserved verbatim from the original implementation choice. Rename freely in your own `.env`.

#### Issue #012 — msmtp SMTP client

- New `msmtp` section runs in **RUN ALL** by default (skip with `--no-msmtp`; run in selective mode with `--msmtp / -m`).
- Installs `msmtp` + `msmtp-mta` via apt if missing; validates `MSMTP_HOST` / `MSMTP_USER` from `.env` (exits non-zero with a clear "set these keys" message if blank — no silent partial config).
- `MSMTP_FROM` defaults to `MSMTP_USER` when blank. `MSMTP_PORT` defaults to `587`.
- **Password handling** — prompted interactively via `read -s` (no echo), confirmed by a second `read -s` prompt; mismatches and empty input re-prompt in a loop; the local `pass` variable is `unset` via `trap ... RETURN` as soon as `~/.msmtprc` is written. **Password is never stored in `.env`** by design.
- **No unattended setup path** — section refuses to run when stdin is not a TTY (clear error rather than silently producing a broken config).
- **Existing `~/.msmtprc` handling** — interactive binary choice `[o]verwrite (default) / [a]bort`. Overwrite creates a timestamped `.msmtprc.bak.YYYYMMDD-HHMMSS` backup first. **No merge option** (deciding what to keep vs. discard from an existing config is bug-prone — see `issues/012.md`).
- Written file mode `0600`, owner `$TARGET_USER` (msmtp refuses to run with looser permissions).

### Configuration (.env additions)

| Variable | Purpose | Default | Required (when section runs) |
|---|---|---|---|
| `PROMPT_ENABLED` | `true` = install managed PS1 block into `~/.bashrc` | `true` | yes (when running prompt section) |
| `PROMPT_PS1_TEMPLATE` | custom PS1 string with ANSI escapes; blank = built-in default | blank | no |
| `SERVER_REPORT_SCIPT_LINK` | full `https://github.com/...` release-zip URL | upstream `v.2.0` tag | yes (when running server-report section) |
| `MSMTP_HOST` | SMTP server hostname | blank | yes (when running msmtp section) |
| `MSMTP_PORT` | SMTP port (typically `587` for STARTTLS, `465` for SMTPS) | `587` | no |
| `MSMTP_USER` | SMTP auth username | blank | yes (when running msmtp section) |
| `MSMTP_FROM` | `From:` address; defaults to `MSMTP_USER` if blank | blank | no |

### Trigger model summary

| Section | RUN ALL | Flag | `--no-X` |
|---|---|---|---|
| timezone, hostname, firewall, ssh-key, swap, fail2ban, ssh-harden, apt-upgrade, **msmtp** | runs | `--timezone` / `--firewall` / etc. | disables |
| **add-repo**, **install-packages**, **prompt**, **server-report** | runs only if required `.env` key set | `--add-repo` / `--install-packages` / `--prompt` / `--server-report` | disables |
| opt-in sections (when `.env` key is blank) | skipped silently | required to run | n/a |

In **selective mode** (any section flag passed), opt-in sections do **not** auto-enable from `.env` — pass the flag explicitly.

### Safety Guarantees (v1.1.0 additions)

- **`prompt` is idempotent** — block markers + `awk` rewrite replace the existing block in place; no duplicates, no drift.
- **`server-report` URL scheme is validated** — only `^https://github\.com/` is accepted; section exits non-zero before any `curl` call on a malformed value.
- **`server-report` extraction** — directory is recreated in place (re-runs overwrite predictably), but `/usr/local/bin/` symlinks are owned by the upstream installer, not `setup.sh`.
- **`msmtp` never overwrites silently** — non-interactive + existing `.msmtprc` aborts non-zero rather than clobbering a hand-tuned file.
- **`msmtp` password is never persisted** in `.env`; the only path is an interactive `read -s` prompt cleared from the shell's scope via `trap` on section return.
- **`msmtp` produces mode `0600`** — owned by `TARGET_USER` — which is the only mode msmtp will accept.
- **Strict exit codes preserved**: `0` = success, `1` = unexpected error, `2` = validation/config error.

### Tested On

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12 (bookworm)

Other systemd Debian-family distros should work but are untested.

### Upgrade Notes (v1.0 → v1.1.0)

- **Breaking**: `--install-defaults / -p` renamed to `--install-packages / -i`. Update any wrapper scripts or docs.
- If upgrading in place, copy `.env.example` over `.env` and re-merge your custom values (new keys: `PROMPT_*`, `SERVER_REPORT_SCIPT_LINK`, `MSMTP_*`).
- The `prompt` section will install into `TARGET_USER`'s `~/.bashrc` by default — set `PROMPT_ENABLED=false` in `.env` before re-running if you don't want it.
- The `msmtp` section will prompt for your SMTP password the first time it runs. Have it ready, or pass `--no-msmtp` on the first run and enable later.

### Deferred

- **Issue #010 (Netplan)** — deferred to a future release. The design spec lives in `issues/010.md` and is not yet implemented; applying the wrong netplan config bricks remote access, so the design needs more validation before shipping. Track via the issue file.

### Known Limitations (v1.1.0)

- All v1.0 limitations carry forward (APT-only, no `apt-add-repository` PPA support, single-host).
- `msmtp` cannot be configured non-interactively by design — for unattended provisioning, write `/home/$TARGET_USER/.msmtprc` directly via your configuration-management tool of choice.
- `prompt` section writes a fixed built-in default if `PROMPT_PS1_TEMPLATE` is blank; admins wanting a heavily customized PS1 must set the template in `.env`.

---

## Version 1.0 — First Stable Release

The first production-ready release of the production server setup script. After multiple iterations and validation, all core sections are stable, idempotent, and composable via CLI flags.

### Sections (10)

| # | Section | Flag | Short | Default |
|---|---|---|---|---|
| 1 | Timezone | `--timezone` | `-t` | runs |
| 2 | Hostname | `--hostname NAME` | `-n` | runs |
| 3 | Firewall (UFW) | `--firewall` | `-f` | runs |
| 4 | SSH key install | `--ssh-key` | `-k` | runs |
| 5 | Swap | `--swap` | `-s` | runs |
| 6 | fail2ban | `--fail2ban` | `-b` | runs |
| 7 | SSH hardening (advisory) | `--ssh-harden` | `-h`* | runs |
| 8 | apt update + upgrade | `--apt-upgrade` | `-u` | runs |
| 9 | Add 3rd-party APT repos | `--add-repo` | `-r` | **opt-in** |
| 10 | Install baseline packages | `--install-defaults` | `-p` | **opt-in** |

> Note: `-h` is shared between `--ssh-harden` and `--help`. Use the long form to disambiguate.

### Flags

- **No section flag** → run all default-on sections
- **Any section flag given** → only those sections run (plus `--no-X` exclusions)
- **Opt-in sections** (`add-repo`, `install-defaults`) only run when explicitly enabled via flag, or when their required `.env` key is set
- **`--non-interactive` / `-y`** → skip all prompts, fail fast (exit 2) on missing required values
- **`--help`** → show usage

### Precedence

```
CLI flag  >  .env value  >  interactive prompt  >  built-in default
```

### Configuration

All configurable values live in `.env` (template in `.env.example`). Variables include:

- `TIMEZONE`, `HOSTNAME`, `FIREWALL_APPLY`, `FIREWALL_EXTRA_PORTS`
- `SSH_PUBLIC_KEY` (or `ssh_key.pub` sibling file)
- `SWAP_SIZE_MB`, `FAIL2BAN_ENABLED`, `FAIL2BAN_BANTIME/FINDTIME/MAXRETRY`
- `APT_UPGRADE`, `APT_AUTOREMOVE`, `APT_REPOSITORIES`
- `DEFAULT_PACKAGES` (25 curated packages across archive, diagnostics, editor, mail, security)
- `NONINTERACTIVE`

### What's New Since v0.x

- Added 3 new sections: `add-repo`, `apt-upgrade`, `install-defaults`
- Full CLI parser with short + long flags, enable/disable semantics
- Section registry with `is_enabled()` dispatch
- Auto-detect non-interactive mode from `.env` completeness
- Opt-in sections for operations that shouldn't run by default
- `SECTIONS` array as single source of truth (no more drift between Plan / auto-detect / preflight loops)
- Bug fix: `install-defaults` now correctly considered for auto non-interactive detection
- Removed dead code (`cli_value()` helper)
- 32 flag combinations validated

### Safety Guarantees

- **Idempotent**: every section can be re-run safely
- **SSH hardening is advisory only** — never auto-applies `PasswordAuthentication no` (prevents lockout)
- **fail2ban respects user-managed files** — checks for marker comment before overwriting `/etc/fail2ban/jail.local`
- **Validation runs before any system change** in non-interactive mode (exit 2 on bad input)
- **Strict exit codes**: `0` = success, `1` = unexpected error, `2` = validation/config error (orchestration tools can distinguish)

### Tested On

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12 (bookworm)

Other systemd Debian-family distros should work but are untested.

### Known Limitations

- APT-based only (no RPM/Yum support)
- `apt-add-repository` (PPA-style) not supported; use `APT_REPOSITORIES` instead with `name|url|suite|components|key_url` format
- No remote/config management integration (Ansible, etc.) — single-host script only

### Upgrade Notes

No migration needed — first release. Copy `.env.example` to `.env`, customize, then run `sudo ./setup.sh`.

### Next Steps (planned at time of v1.0 release)

- v1.1: logrotate + sysctl tuning sections
- v1.2: split into `lib/sections/*.sh` for maintainability (script is now ~980 lines)
- v2.0: remote/orchestration mode (run on many hosts via SSH)

> **Historical note:** v1.1.0 actually shipped three other sections instead (`prompt` / `msmtp` / `server-report`). See the v1.1.0 entry above for what landed.
