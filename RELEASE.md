# Release Notes

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

### Next Steps

- v1.1: logrotate + sysctl tuning sections
- v1.2: split into `lib/sections/*.sh` for maintainability (script is now ~980 lines)
- v2.0: remote/orchestration mode (run on many hosts via SSH)
