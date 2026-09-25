#!/usr/bin/env bash
#
# Run all tests in this directory. Each test_*.sh file is expected to:
#   - exit 0 on success
#   - exit non-zero on failure
#   - be self-contained (no setup required)
#
# Usage:
#   bash tests/run-all.sh           # quiet — show only summary
#   bash tests/run-all.sh --verbose # pass --verbose through to each test
#
# Exit code: 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE_FLAG="${1:-}"

PASS=0
FAIL=0
FAILED_FILES=()

# Discover test files: test_*.sh, sorted
shopt -s nullglob
test_files=("$SCRIPT_DIR"/test_*.sh)
shopt -u nullglob

if (( ${#test_files[@]} == 0 )); then
  echo "No test files found in $SCRIPT_DIR (expected test_*.sh)" >&2
  exit 1
fi

echo "Running ${#test_files[@]} test file(s)..."
echo

for f in "${test_files[@]}"; do
  name="$(basename "$f")"
  if bash "$f" $VERBOSE_FLAG; then
    PASS=$((PASS + 1))
    echo "  [OK]   $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_FILES+=("$name")
    echo "  [FAIL] $name"
  fi
  echo
done

echo "============================"
echo "Test files: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  echo "Failed:"
  for f in "${FAILED_FILES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0