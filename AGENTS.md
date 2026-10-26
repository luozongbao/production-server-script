# AGENTS.md

`setup.sh` is a single-artifact, root-run provisioning script for Ubuntu/Debian hosts.
Everything ships in one file; `tests/` is a pure-bash regression harness.

| Path | Role |
|---|---|
| `setup.sh` | The artifact — CLI parsing, `.env` loading, 13 `section_*` functions, dispatch, summary |
| `.env.example` | Config template — the canonical list of `.env` keys |
| `tests/test_*.sh` | Regression tests, auto-discovered by `tests/run-all.sh` |
| `README.md` | User-facing docs — flags, `.env` table, selection rules, SSH-key workflow |
| `RELEASE.md` | Changelog — update it with every user-visible change |

**Read [README.md](README.md) for flag and `.env` semantics, and [tests/README.md](tests/README.md) for the test harness.**
This file only records what an agent cannot infer by reading the code.

---

## Commands

```bash
bash -n setup.sh                 # syntax check — parses only, does not execute, safe as non-root
bash tests/run-all.sh            # full suite — exit 0 = all pass, 1 = any fail
bash tests/run-all.sh --verbose  # per-assertion output
bash tests/test_env_or_prompt.sh --verbose   # a single test file
```

No build step, no CI config, no dependency manifest, no `shellcheck` in the repo.
The suite must stay runnable with **no root, no network, no installed packages** — it is CI-safe as-is.

---

## Architecture

- **Two invocation modes.** RUN ALL (no section flags) runs every default section plus any opt-in section whose required `.env` key is set. Selective mode (any `--<section>` or `--no-<section>` flag) runs **only** the named sections; opt-in sections do **not** auto-enable from `.env` in this mode.
- **`is_enabled` is the single decision point** for what runs: `--no-X` always wins → else the CLI enable list (selective mode) → else, for opt-in sections, "required `.env` key is non-empty" → else default-on.
- **Three lists must stay in sync** when you add or rename a section: `SECTIONS` (canonical ordered ids), `OPT_IN_SECTIONS` (opt-in ids only), and the `run_section` calls at the bottom of the file (execution order). `required_keys_for_section` needs a matching `case` arm too.
- **Value resolution** is `env_or_prompt KEY [DEFAULT] [LABEL]` → precedence is **CLI flag > `.env` value > interactive prompt > built-in default**.
- **`TARGET_USER`** (`${SUDO_USER:-$(logname 2>/dev/null || echo root)}`) is the target of every per-user write — `~/.ssh/authorized_keys`, `~/.bashrc`, `~/.msmtprc`. It is defined partway down `setup.sh`; nothing above that point can use it.
- **`.env` is not shell.** `load_env_file` parses `KEY=value` lines into an associative array. It never sources, evals, or expands.

---

## Conventions

- `set -euo pipefail` at the top of `setup.sh`. **Read the gotcha below — it is inert inside section functions.**
- Bash 4.4+ target (Ubuntu/Debian): `declare -A`, `[[ =~ ]]`, and `${var@Q}` are all available.
- Always double-quote expansions, and use the `:-` default form for associative-array reads: `"${ENV[KEY]:-}"`.
- Logging helpers `section` / `ok` / `info` / `warn` / `err` all print to **stdout** (not stderr).
- A section body starts with `section "Human Title"`, then `info` for state, `ok` for success, `warn` for "nothing to do", `err` for failure. **End with `ok "..."`** so the function's last command returns 0.
- Failures use explicit checks — `cmd || { err "..."; return 1; }` — never a bare `set -e` assumption.
- **Idempotency is a hard requirement.** Re-running `setup.sh` must not break anything. Reuse the existing idioms: marker string + `grep -qF` (fail2ban, `.bashrc` block), existence checks, `find -mindepth 1 -delete` to refresh in place, `cp -a` timestamped backups (msmtp), and *leave a user's file alone unless it carries our marker*.
- Section ids and function names are not always the same (`prompt` → `section_bashrc`, `install-defaults` → `section_install_defaults`). Match the existing mapping, don't "fix" it.

---

## Gotchas — silent-failure traps

1. **`set -e` does not work inside section functions.** `run_section` calls them as `if "$@"; then`, and bash suspends `errexit` for everything in a condition context — including the function body. A failing command inside a section will **not** abort the script; the section keeps going and may report success. Check every return code explicitly.
2. **A function whose last statement is `[[ cond ]] && cmd` returns 1 when the condition is false**, which marks the section as failed even though nothing broke.
3. **Section failures never change the process exit code.** The script exits `0` even when sections failed; the Summary prints `Failed sections:`. Any CI wrapper must grep stdout for that string. Exit codes are: `0` success (or `--help`), `1` not-root / `systemctl` missing / bad CLI arg, `2` non-interactive preflight failure (missing or invalid `.env` values).
4. **Never call `sudo` from inside `setup.sh`.** The script is already root; `sudo` only sets `$SUDO_USER` when a *non-root* user invokes it, so a nested `sudo` leaves upstream installers with an empty `$SUDO_USER` and silently skips per-user config seeding. Pass it inline instead: `SUDO_USER="$TARGET_USER" "$install_dir/install.sh"`. `tests/test_server_report_sudo.sh` enforces this.
5. **`env_or_prompt` stdout/stderr split is load-bearing.** The **value** goes to stdout with no trailing newline; the status line (`  VALUE (from .env)`) goes to stderr. Never capture it with `2>&1`. The first argument must be the literal `.env` key (matching `^[A-Z_][A-Z0-9_]*$`) — passing a human label there silently ignores the `.env` value. `tests/test_env_or_prompt.sh` enforces both.
6. **`SERVER_REPORT_SCIPT_LINK` has a typo on purpose** — the "R" is missing from "SCRIPT". It is the shipped key name. Do not rename it.
7. **`load_env_file` quirks.** `#` truncates the line at the *first* `#` anywhere (a `#` inside a value is silently dropped); only one leading and one trailing space are stripped; only one pair of surrounding quotes is removed; keys must be uppercase.
8. **`DEFAULT_PACKAGES` comments are per-token.** Only a standalone `#` token is skipped — `unzip zip # my comment` will try to install `my` and `comment`.
9. **`ufw --force reset` wipes every existing UFW rule** (including user-defined ones) whenever `FIREWALL_APPLY=true`. There is no merge mode — call this out if you touch that section.
10. **The msmtp password is never read from `.env`** (no `MSMTP_PASSWORD` key exists, by design). The section requires a TTY and refuses to run non-interactively.

### Known live bug (do not assume it works)

`sudo ./setup.sh --hostname web01` **fails with exit 1**. The `-n|--hostname)` parser arm matches `--hostname` first, so the later `--hostname)` arm is dead code and `web01` falls through to "Unexpected positional arg". Only the `--hostname=web01` form sets the value. The `README.md` and the `setup.sh` header docblock both still advertise the broken space-separated form. Fix the parser (or the docs) — but don't build on the space form.

---

## Testing

Tests live in `tests/test_*.sh` and are auto-discovered by `tests/run-all.sh` — no registration step. See [tests/README.md](tests/README.md) for the conventions, and the `write-setup-test` skill for the harness mechanics.

**One constraint is not in `tests/README.md`:** tests never `source setup.sh` (that would execute it). They slice the function under test out with `awk` and `eval` it into a stub environment. Therefore **any function under test must be top-level, declared as `name() {` at column 0, and closed by a lone `}` at column 0.** Reformatting a function body breaks the harness.

---

## Workflow

- Branch off `dev` (`dev` carries all work; `main` is stale at the initial commit). Feature branches are named after the issue or feature, e.g. `009-custom-prompt`, `bug-install-server-report-script`.
- Commit messages are imperative sentences describing the change: `Fix timezone and hostname handling in env_or_prompt function; add regression tests`.
- Release tags are `v.<major>.<minor>.<patch>` (`v.1.0.0`, `v.1.1.0`, `v.1.1.1` exist). `RELEASE.md` documents `v1.2.0` but no `v.1.2.0` tag has been cut yet.
- Update `README.md` (flags, `.env` table) and `RELEASE.md` together with any user-visible change. `.env.example` is the source of truth for new config keys.
