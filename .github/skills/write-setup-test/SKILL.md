---
name: write-setup-test
description: 'Write a regression test for setup.sh in tests/. Use when adding a test, testing a shell function from setup.sh, guarding a bug fix against regression, or auditing call sites in setup.sh statically. Covers the test harness contract, the function-extraction idiom, and the static-audit pattern.'
argument-hint: 'what to test (function name, bug, or section id)'
user-invocable: true
---

# Write a regression test for setup.sh

The suite is pure bash: no root, no network, no dependencies. It exists because the
bugs it guards were **silent** — `setup.sh` itself never errored, only the downstream
result was wrong.

## When to Use

- Guarding a bug fix so it cannot regress silently
- Testing the behavior of a single `setup.sh` function
- Statically auditing how `setup.sh` calls something (call-site shape, forbidden patterns)
- Any new section that warrants a regression test

## The harness contract

`tests/run-all.sh` auto-discovers `tests/test_*.sh` — **no registration step**.
Each test file must:

1. Start with `#!/usr/bin/env bash`
2. Use `set -uo pipefail` — **not** `-e`. The assert helpers deliberately return
   non-zero from inside a function; `-e` would abort the whole file on the first failure.
3. Support `--verbose` as `$1`
4. Track `PASS` / `FAIL` counters and a `FAILED_TESTS` array
5. Print `Results: N passed, N failed` as the final line
6. `exit 0` on success, `exit 1` on failure

`run-all.sh` runs each file and prints `Test files: N passed, N failed`; it exits
`1` if any file fails. This output format is what CI reads — keep it stable.

## Boilerplate

```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../setup.sh"

VERBOSE="false"
[[ "${1:-}" == "--verbose" ]] && VERBOSE="true"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    [[ "$VERBOSE" == "true" ]] && echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$label")
    echo "  FAIL: $label" >&2
    echo "    expected: $(printf '%q' "$expected")" >&2
    echo "    actual:   $(printf '%q' "$actual")" >&2
  fi
}

# ... assertions ...

echo
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed tests:" >&2
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t" >&2; done
  exit 1
fi
exit 0
```

## Two testing styles

### 1. Behavioral — extract the function and call it

**Never `source setup.sh`** — that would execute the entire script (and the root check).
Instead, slice the function out with `awk` and `eval` it into a stub environment:

```bash
func_body=$(awk '
  /^env_or_prompt\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$SETUP_SH")

declare -A ENV=()
CLI_HOSTNAME_VALUE=""
NONINTERACTIVE="false"
CLI_FLAG_GIVEN=false
eval "$func_body"
```

> **Hard constraint:** the function under test must be **top-level**, declared as
> `name() {` at column 0, and closed by a **lone `}` at column 0**. The `awk` matcher
> anchors on exactly that shape. Reformatting a function (e.g. indenting the closing
> brace, or moving it into a subshell) silently breaks the extraction — the test
> fails with "command not found" rather than a useful message.

Stub only the globals the function actually touches, then assert on stdout/stderr separately:

```bash
capture_value()  { env_or_prompt "$1" "${2:-}" 2>/dev/null; }        # stdout only
capture_status() { env_or_prompt "$1" "${2:-}" 2>&1 1>/dev/null; }   # stderr only
```

This is how the stdout/stderr split gets tested — `env_or_prompt` must put the value
on stdout and the status line on stderr, or `var=$(env_or_prompt ...)` captures the
status text into `$var`.

### 2. Static audit — grep the call sites

Use this when the bug is *how* `setup.sh` calls something, not what the function returns.

```bash
# every env_or_prompt call site's first argument must look like an .env key
mapfile -t callsites < <(sed -nE 's/.*env_or_prompt[[:space:]]+"([^"]+)".*/\1/p' "$SETUP_SH")
for c in "${callsites[@]}"; do
  if ! [[ "$c" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    bad+=("$c")
  fi
done
```

Other useful static assertions:

- **A forbidden pattern is gone.** e.g. no line whose first non-space token is `sudo`
  followed by the installer path.
- **A required pattern is present**, e.g. `SUDO_USER="$TARGET_USER"` appears.
- **Ordering matters.** e.g. the `SUDO_USER=` assignment must appear *before* the
  `install.sh` call — compare line numbers, not just presence.
- **A comment still explains the decision.** `test_server_report_sudo.sh` asserts the
  explanatory comment is still present, so nobody "simplifies" the fix away.

## Asserting on a whole file

```bash
assert_eq "setup.sh has no syntax errors" "$(bash -n "$SETUP_SH" 2>&1; echo $?)" "0"
assert_contains "usage advertises --newthing" "$(grep -c -- '--newthing' "$SETUP_SH")" "1"
```

`bash -n` is safe — it parses without executing, so it works as a non-root user.

## Choosing what to assert

Prefer assertions that would have caught the original bug:

- Assert on the **exact** value, not "output is non-empty".
- For a stdout/stderr contract, assert **both** sides — that the value is on stdout
  *and* that the status line is not.
- For a static audit, assert on the **count** of violations (`0`) so a new bad call
  site is caught, not just the one you know about.
- Cover the negative case too: the value must be *absent* from the other stream.

## Verify

```bash
bash tests/test_newthing.sh --verbose   # single file
bash tests/run-all.sh --verbose         # whole suite
```

Both must exit `0`. Then confirm the test actually guards something: temporarily
reintroduce the bug in `setup.sh`, re-run, and watch the test fail. A test that
passes against the buggy code guards nothing.

## Naming and layout

- `tests/test_<name>.sh` — `<name>` describes the subject (`env_or_prompt`, `server_report_sudo`).
- Keep each file self-contained: no shared helper library, no sourcing between test files.
- No root, no network, no package installation, no writes outside `/tmp`.
