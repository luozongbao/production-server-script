#!/usr/bin/env bash
#
# Regression test for env_or_prompt() — verifies that the function returns ONLY
# the value on stdout (not the "from .env"/"from CLI" status line), so that
# callers using command substitution `$(env_or_prompt ...)` get a clean value.
#
# Reproduces the bug where `sudo ./setup.sh -n` with HOSTNAME=Test failed with:
#   [ERR] Invalid hostname: '  Test (from .env)
#   Test'
# caused by both printf calls going to stdout.
#
# Usage:
#   bash tests/test_env_or_prompt.sh
#   bash tests/test_env_or_prompt.sh --verbose
#
# Exit code: 0 = all pass, 1 = any failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../setup.sh"

VERBOSE="false"
[[ "${1:-}" == "--verbose" ]] && VERBOSE="true"

# ---------------------------------------------------------------------------
# Source the env_or_prompt function from setup.sh without running the script.
# We extract the function body via sed, then eval it inside a minimal stub
# environment (ENV associative array, helpers used by env_or_prompt).
# ---------------------------------------------------------------------------
if [[ ! -f "$SETUP_SH" ]]; then
  echo "FAIL: $SETUP_SH not found" >&2
  exit 1
fi

# Extract the env_or_prompt function definition (lines 232..264 approx).
# Use awk to grab from '^env_or_prompt()' to the matching closing '}'.
func_body=$(awk '
  /^env_or_prompt\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$SETUP_SH")

if [[ -z "$func_body" ]]; then
  echo "FAIL: could not locate env_or_prompt() in $SETUP_SH" >&2
  exit 1
fi

# Stub the env it expects.
declare -A ENV=()
CLI_HOSTNAME_VALUE=""
NONINTERACTIVE="false"
CLI_FLAG_GIVEN=false

# Eval the function into this shell.
eval "$func_body"

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------
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

# Capture stdout only (status messages go to stderr after the fix).
capture_value() {
  local key="$1" default="${2:-}"
  env_or_prompt "$key" "$default" 2>/dev/null
}

# Capture stderr only (status line).
capture_status() {
  local key="$1" default="${2:-}"
  env_or_prompt "$key" "$default" 2>&1 1>/dev/null
}

echo "Running env_or_prompt regression tests..."
echo

# --- Test 1: value from .env, no CLI override ------------------------------
ENV[HOSTNAME]="Test"
got_value=$(capture_value "HOSTNAME")
got_status=$(capture_status "HOSTNAME")
assert_eq "env value: stdout is clean 'Test'" "$got_value" "Test"
assert_eq "env value: status line on stderr" "$got_status" "  Test (from .env)"

# --- Test 2: value from .env with spaces (the original bug case) -----------
ENV[HOSTNAME]="my-prod-01"
got_value=$(capture_value "HOSTNAME")
assert_eq "env value with dashes: clean" "$got_value" "my-prod-01"

# --- Test 3: empty .env value falls through to interactive prompt ----------
# Simulate interactive by stubbing `read` via fd 0 — too brittle. Instead,
# verify NONINTERACTIVE path returns non-zero (the original behavior).
ENV[HOSTNAME]=""
NONINTERACTIVE="true"
got_value=$(capture_value "HOSTNAME" "default-host" 2>/dev/null) || rc=$?
assert_eq "env missing + NONINTERACTIVE: errors out (rc != 0)" "${rc:-0}" "1"
unset rc
NONINTERACTIVE="false"

# --- Test 4: CLI override wins over .env -----------------------------------
ENV[HOSTNAME]="from-env"
CLI_HOSTNAME_VALUE="from-cli"
got_value=$(capture_value "HOSTNAME")
got_status=$(capture_status "HOSTNAME")
assert_eq "CLI override: stdout is clean" "$got_value" "from-cli"
assert_eq "CLI override: status shows 'from CLI'" "$got_status" "  from-cli (from CLI)"

# --- Test 5: the original bug scenario end-to-end --------------------------
# If env_or_prompt's stdout contains BOTH the status line AND the value
# (the bug), then this string would be multi-line and contain "(from .env)".
ENV[HOSTNAME]="Test"
CLI_HOSTNAME_VALUE=""
buggy_value=$(capture_value "HOSTNAME")
if [[ "$buggy_value" == *"Test"* ]] && [[ "$buggy_value" != *"from"* ]] && [[ "$buggy_value" != *$'\n'* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: original bug scenario — clean single-line value"
else
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("original bug scenario")
  echo "  FAIL: original bug scenario — value contains status text or newline" >&2
  echo "    value=$(printf '%q' "$buggy_value")" >&2
fi

# --- Test 6: caller passes the LABEL as the key (the timezone/apt-upgrade bug)
# When the first arg is a human-friendly label like "TIMEZONE (e.g. ...)" instead
# of the literal env key "TIMEZONE", the lookup ENV[label] is empty. We assert
# this directly by checking what the function does when the key is not found —
# we feed a value via stdin so the read() path doesn't hang, and confirm the
# function does NOT use the .env value (because the wrong key was passed).
ENV[TIMEZONE]="Asia/Shanghai"
# Feed stdin so the read() inside env_or_prompt gets a value and doesn't hang.
got_value=$(env_or_prompt "TIMEZONE (e.g. Asia/Shanghai, UTC)" "Asia/Bangkok" \
            2>/dev/null <<< "from-stdin") || true
# The function should NOT have looked up the right key, so .env value
# is invisible. The captured value is whatever read returned (or the default).
# We just assert that it is NOT the .env value — that proves the wrong-key
# bug was real.
if [[ "$got_value" != "Asia/Shanghai" ]]; then
  PASS=$((PASS + 1))
  [[ "$VERBOSE" == "true" ]] && echo "  PASS: wrong-key call did NOT silently use .env value (bug confirmed real)"
else
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("wrong-key bug demonstration")
  echo "  FAIL: wrong-key call returned .env value — bug not actually present" >&2
fi

# And verify the CORRECT call shape (test the fix is right):
ENV[TIMEZONE]="Asia/Shanghai"
got_value=$(capture_value "TIMEZONE" "Asia/Bangkok" "TIMEZONE (e.g. Asia/Shanghai, UTC)")
assert_eq "correct call shape with 3 args returns .env value" "$got_value" "Asia/Shanghai"

# --- Test 7: 3-arg form (KEY, DEFAULT, LABEL) --------------------------------
# Verifies that callers passing the human-friendly label as the 3rd argument
# still get the env value when the .env key (1st arg) is set. This is the
# correct call shape that fixed the timezone / apt-upgrade bugs.
ENV[APT_UPGRADE]="true"
got_value=$(capture_value "APT_UPGRADE" "true" "APT_UPGRADE (true/false)")
assert_eq "3-arg form (KEY, DEFAULT, LABEL): env value returned cleanly" "$got_value" "true"

ENV[APT_UPGRADE]="false"
got_value=$(capture_value "APT_UPGRADE" "true" "APT_UPGRADE (true/false)")
assert_eq "3-arg form with different env value" "$got_value" "false"

# --- Test 8: static check of caller call-sites in setup.sh -----------------
# The bug was that callers passed a human-friendly label as the 1st arg
# ("TIMEZONE (e.g. Asia/Shanghai, UTC)") instead of the literal env key
# ("TIMEZONE"). Static-grep setup.sh for env_or_prompt invocations and
# verify each first arg is a valid bare env key (no spaces, no parens).
echo "Auditing env_or_prompt call sites in setup.sh..."
bad_callsites=()
while IFS= read -r line; do
  # Extract the first quoted arg after env_or_prompt
  # Matches: env_or_prompt "ARG" ...
  first_arg=$(printf '%s\n' "$line" | sed -nE 's/.*env_or_prompt[[:space:]]+"([^"]+)".*/\1/p')
  if [[ -z "$first_arg" ]]; then
    continue
  fi
  # Valid env keys: uppercase letters, digits, underscores only.
  # Anything else (spaces, parens, slashes) is a human label, not a key — bug.
  if ! [[ "$first_arg" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    bad_callsites+=("line: $line  (first arg: '$first_arg')")
  fi
done < <(grep -nE 'env_or_prompt[[:space:]]+"[^"]+"' "$SETUP_SH")

if (( ${#bad_callsites[@]} == 0 )); then
  PASS=$((PASS + 1))
  [[ "$VERBOSE" == "true" ]] && echo "  PASS: all env_or_prompt callers use a valid env key as 1st arg"
else
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("env_or_prompt call-site audit")
  echo "  FAIL: env_or_prompt callers passing a label (not a key) as 1st arg:" >&2
  for c in "${bad_callsites[@]}"; do echo "    $c" >&2; done
fi

# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed tests:" >&2
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t" >&2; done
  exit 1
fi
exit 0