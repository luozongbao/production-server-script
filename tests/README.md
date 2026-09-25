# Tests

Regression tests for `setup.sh`. These are pure bash, no dependencies, no
root, no network — safe to run anywhere.

## Run all tests

```bash
bash tests/run-all.sh
```

Pass `--verbose` to see each individual test case:

```bash
bash tests/run-all.sh --verbose
```

Exit code: `0` if all pass, `1` if any fail. Suitable for CI.

## Run a single test

```bash
bash tests/test_env_or_prompt.sh --verbose
```

## Conventions for adding a new test

1. Create `tests/test_<name>.sh`
2. First line: `#!/usr/bin/env bash`
3. Set `set -uo pipefail` (NOT `-e` — tests use `assert_eq` which returns
   non-zero from a function on purpose; we don't want `-e` to abort)
4. Exit `0` on success, non-zero on failure
5. Print `Results: N passed, N failed` as the last line so `run-all.sh`
   output is consistent

The `run-all.sh` wrapper auto-discovers any `test_*.sh` file in this
directory — no registration step needed.

## Why we test

The two tests in `test_env_or_prompt.sh` cover bugs that previously
slipped through code review:

1. **`env_or_prompt` stdout capture** — the function must print the value
   on stdout and the "from .env" status on stderr, otherwise
   `var=$(env_or_prompt ...)` captures the status line into `$var`.
2. **Caller-side argument shape** — `env_or_prompt KEY DEFAULT [LABEL]`
   requires the env key as the 1st arg, not a human-friendly label.
   We static-grep the call sites in `setup.sh` to enforce this.

Without these tests, both bugs regressed silently during refactors.