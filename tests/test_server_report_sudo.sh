#!/usr/bin/env bash
#
# Regression test for the server-report section's installer invocation.
#
# Bug fixed: setup.sh's server-report section was calling
#     sudo "$install_dir/install.sh"
# from a root shell. Because sudo only sets $SUDO_USER when a non-root
# user invokes it, the child process had no $SUDO_USER — and upstream's
# install.sh could not determine the invoking user, so it skipped the
# per-user config seeding (warned: "Cannot determine invoking user").
#
# The fix: invoke install.sh directly (setup.sh is already root) and pass
# SUDO_USER=$TARGET_USER inline so upstream can find the user.
#
# This test is a static audit — it grep's setup.sh and verifies:
#   1. The server-report section does NOT contain a `sudo ` invocation
#      of install.sh.
#   2. The server-report section DOES pass SUDO_USER=$TARGET_USER inline.
#
# Usage:
#   bash tests/test_server_report_sudo.sh
#   bash tests/test_server_report_sudo.sh --verbose
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../setup.sh"

VERBOSE="false"
[[ "${1:-}" == "--verbose" ]] && VERBOSE="true"

if [[ ! -f "$SETUP_SH" ]]; then
  echo "FAIL: $SETUP_SH not found" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_TESTS=()

assert() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    [[ "$VERBOSE" == "true" ]] && echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$label")
    echo "  FAIL: $label" >&2
    echo "    expected: $expected" >&2
    echo "    actual:   $actual" >&2
  fi
}

# ---------------------------------------------------------------------------
# Extract the section_server_report function body from setup.sh.
# ---------------------------------------------------------------------------
func_body=$(awk '
  /^section_server_report\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$SETUP_SH")

if [[ -z "$func_body" ]]; then
  echo "FAIL: could not locate section_server_report() in $SETUP_SH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: must NOT contain a real `sudo "$install_dir/install.sh"` invocation.
# Filter out lines that are comments or inside err/echo strings — those are
# documentation, not actual invocations. A real invocation starts (after
# leading whitespace) with `sudo "` and is a bare command.
# ---------------------------------------------------------------------------
actual_invocation=0
while IFS= read -r line; do
  # Strip leading whitespace
  stripped="${line#"${line%%[![:space:]]*}"}"
  # Skip pure comments
  case "$stripped" in
    \#*) continue ;;
  esac
  # Real invocation: starts with `sudo "` (no `err`/`echo`/etc. before)
  case "$stripped" in
    sudo\ *)
      actual_invocation=$((actual_invocation + 1))
      echo "    matched line: $line" >&2
      ;;
  esac
done < <(grep -nE 'sudo[[:space:]]+"?\$\{?install_dir\}?/install\.sh"?' <<< "$func_body")

if (( actual_invocation == 0 )); then
  assert "server-report: no 'sudo install.sh' invocation (root shell loses SUDO_USER)" \
    "0 real invocations" "0 real invocations"
else
  assert "server-report: no 'sudo install.sh' invocation (root shell loses SUDO_USER)" \
    "$actual_invocation real invocations" "0 real invocations"
fi

# ---------------------------------------------------------------------------
# Test 2: must contain `SUDO_USER="$TARGET_USER"` (or equivalent) inline
# before the install.sh call, so upstream can determine the invoking user.
# ---------------------------------------------------------------------------
if grep -qE 'SUDO_USER="\$TARGET_USER"[[:space:]]+"?\$\{?install_dir\}?/install\.sh"?' <<< "$func_body"; then
  assert "server-report: passes SUDO_USER=\$TARGET_USER inline to install.sh" "found" "found"
else
  assert "server-report: passes SUDO_USER=\$TARGET_USER inline to install.sh" "not found" "found"
fi

# ---------------------------------------------------------------------------
# Test 3: the SUDO_USER assignment must come BEFORE the install.sh invocation
# (i.e. it must be an inline env-var prefix, not set after).
# Verify by checking line order.
# ---------------------------------------------------------------------------
sudo_user_line=$(grep -nE 'SUDO_USER=' <<< "$func_body" | head -1 | cut -d: -f1)
install_call_line=$(grep -nE 'install\.sh"[[:space:]]*$|install\.sh"$' <<< "$func_body" | head -1 | cut -d: -f1)
if [[ -n "$sudo_user_line" ]] && [[ -n "$install_call_line" ]] \
   && (( sudo_user_line < install_call_line )); then
  assert "server-report: SUDO_USER assignment precedes install.sh call" "ok" "ok"
else
  assert "server-report: SUDO_USER assignment precedes install.sh call" \
    "sudo_user_line=$sudo_user_line install_call_line=$install_call_line" \
    "ok"
fi

# ---------------------------------------------------------------------------
# Test 4: the function comment must mention WHY we don't use sudo
# (defensive documentation — future refactors won't reintroduce the bug
# without realizing it).
# ---------------------------------------------------------------------------
if grep -qiE 'do not.*sudo|sudo.*lose|lose.*sudo_user|sudo_user.*empty' <<< "$func_body"; then
  assert "server-report: comment explains why sudo is avoided" "found" "found"
else
  assert "server-report: comment explains why sudo is avoided" "not found" "found"
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