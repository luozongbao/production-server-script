---
name: add-setup-section
description: 'Add, rename, or remove a provisioning section in setup.sh. Use when adding a new section to the production-server-script, adding a CLI flag, wiring a new .env key, or changing which sections run in RUN ALL vs selective mode. Covers the 9 touch points that must change together, the idempotency and output conventions, and the required test + docs updates.'
argument-hint: 'section name or feature to add (e.g. "netplan", "postgresql")'
user-invocable: true
---

# Add a section to setup.sh

`setup.sh` provisions an Ubuntu/Debian server. Sections are dispatched from a fixed
registry, so a new section is **not** one function — it is a coordinated edit across
several places. Missing any one of them produces a section that silently never runs.

## When to Use

- Adding a new provisioning section (e.g. `netplan`, `postgresql`, `chrony`)
- Renaming an existing section id or changing its CLI flag
- Changing the opt-in / default-on status of a section
- Adding a new `.env` key that a section reads

## The 9 touch points

Do these in order. Each has a grep anchor so you can find it without relying on line numbers.

| # | What | Anchor in `setup.sh` |
|---|---|---|
| 1 | Section id in the canonical ordered list | `SECTIONS=(` |
| 2 | Opt-in list (only if the section must not run by default) | `OPT_IN_SECTIONS=(` |
| 3 | Required `.env` key mapping | `required_keys_for_section()` |
| 4 | The `section_*` function itself | new `section_<name>() {` |
| 5 | Dispatch call (execution order) | `run_section <name> section_<name>` near the bottom |
| 6 | CLI flag arms in the parser | `while (( $# > 0 ))` → `case "$1"` |
| 7 | Summary block counters | the `# Summary` block at the end of the file |
| 8 | Config template | `.env.example` |
| 9 | User docs | `README.md` (flag table + `.env` table) and `RELEASE.md` |

Also add a **matching `case` arm in `required_keys_for_section`** (step 3) even for
default-on sections — it has no default branch, so an omitted arm silently means
"no required key", which is wrong for opt-in sections.

## Naming rules

- Section id is kebab-case (`install-defaults`, `ssh-harden`, `server-report`).
- Function is `section_<name>` in snake_case. The mapping is not 1:1 and that is fine:
  `prompt` → `section_bashrc`, `install-defaults` → `section_install_defaults`.
  Follow the existing convention; don't rename existing ones to "fix" it.
- Flags: `--<id>` plus `--no-<id>`; a short flag only if it doesn't collide.
  Short flags currently in use: `-t -n -f -k -s -b -u -r -i -p -m -R -y -h`.
- Section ids and `--no-<id>` flags must match exactly, or `--no-X` will not remove `X`.

## Writing the section function

```bash
section_newthing() {
  section "New Thing"

  local thing_value
  thing_value="$(env_or_prompt "NEW_THING_VALUE" "default" "NEW_THING_VALUE (label)")" \
    || return 1

  info "current state: $thing_value"

  # idempotency check first — bail out early if already in the desired state
  if already_configured; then
    ok "New Thing already configured"
    return 0
  fi

  some_write_command || { err "failed to write New Thing config"; return 1; }

  ok "New Thing configured"
}
```

Rules that are easy to get wrong:

- **`env_or_prompt KEY [DEFAULT] [LABEL]`** — the first argument is the literal `.env` key, not a human label. The label is the *third* argument. Passing a label first silently ignores the `.env` value. (`tests/test_env_or_prompt.sh` statically audits every call site.)
- **`set -e` is inert inside section functions.** `run_section` invokes them as `if "$@"; then`, and bash suspends `errexit` in condition context. Check return codes explicitly: `cmd || { err "..."; return 1; }`.
- **End with `ok "..."`.** A function whose last statement is `[[ cond ]] && cmd` returns 1 when the condition is false, which falsely marks the section as failed.
- **Output helpers** — `section` (header), `ok`, `info`, `warn`, `err`. All print to stdout.
- **Never invoke `sudo`** from inside a section. The script is already root, and a nested `sudo` leaves upstream installers with an empty `$SUDO_USER`. Pass it inline: `SUDO_USER="$TARGET_USER" "$some/install.sh"`.
- **Idempotency is mandatory** — the script is re-run on live servers. Reuse the existing idioms:
  - marker string + `grep -qF` (as `section_fail2ban` does with `Managed by production-server-script`)
  - existence check before writing
  - `find "$dir" -mindepth 1 -delete` then re-populate (as `section_server_report` does)
  - `cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"` before overwriting (as `section_msmtp` does)
  - leave a user's pre-existing file alone unless it carries our marker
- **Per-user writes target `$TARGET_USER`**, not `$HOME` — the script runs as root but
  writes into the invoking user's home (`~/.bashrc`, `~/.ssh/authorized_keys`, `~/.msmtprc`).
  Use `install -m 0600 -o "$TARGET_USER" -g "$TARGET_USER"` for secret files.

## Opt-in vs default-on

Default-on sections run on every `sudo ./setup.sh`. Anything that mutates sources
lists, installs many packages, rewrites every user's `.bashrc`, or talks to the
network should be **opt-in**: add the id to `OPT_IN_SECTIONS` and give it a required
`.env` key in `required_keys_for_section`. In RUN ALL mode an opt-in section whose
key is blank is skipped silently — it never prompts to enable itself.

`msmtp` is a deliberate exception: it runs in RUN ALL by default.

## Verify

```bash
bash -n setup.sh                 # syntax
bash tests/run-all.sh            # existing suite must still pass
```

Then confirm the wiring by hand:

```bash
bash setup.sh --help                                  # flag is advertised
sudo ./setup.sh --newthing                            # selective mode: only the new section runs
sudo ./setup.sh --no-newthing                         # RUN ALL minus the new section
sudo ./setup.sh --newthing --non-interactive          # fails with exit 2 listing the missing .env key
```

In selective mode, opt-in sections do **not** auto-enable from `.env` — the flag is required.

## Then

1. Add a regression test — use the `write-setup-test` skill.
2. Update `.env.example` with the new key (commented, with its default).
3. Update `README.md`: the flag table, the `.env` table, and the "Runs unconditionally /
   runs only if its required `.env` key is set" table.
4. Add a `RELEASE.md` entry. New sections are minor bumps; new flags are minor;
   pure bug fixes are patch.
5. Cut a tag `v.<major>.<minor>.<patch>` when releasing.
