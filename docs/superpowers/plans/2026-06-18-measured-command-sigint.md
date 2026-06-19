# Measured Command SIGINT Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a command measured by `nettotalizer` receive `SIGINT` (Ctrl-C and forwarded INT) instead of silently ignoring it (issue #13).

**Architecture:** `run_command_background_gated` launches the gated runner asynchronously (`&`) in a non-job-control shell. POSIX forces async children to set `SIGINT`/`SIGQUIT` to `SIG_IGN`, and that ignored disposition survives `exec` into the measured command — so neither a terminal Ctrl-C nor nettotalizer's `forward_int` trap reaches it. The fix enables job control (`set -m`) **only** for that one launch, so the shim is never auto-ignored, then restores `set +m` immediately after capturing the PID (so the sampler/tracer adapters keep ignoring INT as intended). A measured-`SIGINT` smoke regression mirrors the existing measured-`TERM` test.

**Tech Stack:** Bash 3.2+ (single-file POSIX-leaning script), `tests/smoke.sh` (process-fake integration harness), `tests/unit.sh` (pure-function units). macOS dev host.

## Global Constraints

- Single-file script `nettotalizer` (`#!/usr/bin/env bash`); must keep working on bash 3.2.57 (macOS system bash). One line, verbatim.
- No new runtime dependencies. The fix must be shell-native (the issue's suggested `perl` and `trap -` approaches are rejected — see "Rejected alternatives" below).
- Local gate is `bash tests/unit.sh && bash tests/smoke.sh`; both must be green before commit.
- Follow the repo's per-PR ritual (branch → TDD → push → PR → RAS loop in background → merge → dev-journal → OmniFocus). This plan covers the code+test for ONE PR.

### Rejected alternatives (do not re-derive — already verified empirically this session)

- **`trap - INT QUIT` in the shim before `exec` (the issue's suggested fix): DOES NOT WORK.** POSIX XCU: a signal ignored on entry to a non-interactive shell "cannot be trapped or reset." On bash 3.2 it is a silent no-op; the child still ignored INT (`rc=0`, no trap fired). Verified directly.
- **`perl -e '$SIG{INT}="DEFAULT"; exec @ARGV'` shim: works, but adds a hard `perl` dependency to every measured command's critical path — a portability regression for a script with macOS/Linux/BSD backends. Rejected. (Note: `tests/smoke.sh` legitimately uses this `perl` trick at the *test-harness* level to reset INT for the wrapper process itself; that is unrelated and stays.)
- **Narrow `set -m` (chosen): works, no noise, no dependency.** Verified: delivers INT to the measured child (`TRAPPED, rc=42`), no job-control notification on stderr because `set +m` is restored before the job is reaped, and non-interactive bash prints no job-start line.

---

### Task 1: Restore default SIGINT/SIGQUIT for the measured command + INT regression test

**Files:**
- Modify: `nettotalizer:109-144` (`run_command_background_gated` — add scoped `set -m`/`set +m`)
- Modify: `nettotalizer:220-221` (stale comment in `stop_measured_command_before_release`)
- Test: `tests/smoke.sh:437` (add the `INT` call to the existing `assert_measured_signal_preserves_exit_code` helper)

**Interfaces:**
- Consumes: the existing `assert_measured_signal_preserves_exit_code <signal> <expected_code>` helper (`tests/smoke.sh:387-435`). It backgrounds `perl … ./nettotalizer sh -c 'printf r>"$1"; trap "exit $2" <signal>; while :; do sleep 0.1; done'`, waits for the ready file, sends `kill -<signal> <wrapper_pid>`, and asserts the wrapper exits with `<expected_code>` (not 130/143) within a 5s watchdog.
- Produces: no new functions or signatures. `run_command_background_gated` keeps its contract (sets global `cmd_pid`); the only change is the measured command now starts with default INT/QUIT disposition.

- [ ] **Step 1: Write the failing test**

In `tests/smoke.sh`, immediately after the existing line (`tests/smoke.sh:437`):

```bash
assert_measured_signal_preserves_exit_code TERM 42
```

add:

```bash
# Regression for #13: a forwarded SIGINT must reach the measured command. With
# the bug, async-job INT is SIG_IGN and survives exec, so the child loops
# forever and the helper's 5s watchdog fires (timeout -> fail). A distinct exit
# code (47, not 130 and not TERM's 42) proves it is the child's deliberate code.
assert_measured_signal_preserves_exit_code INT 47
```

- [ ] **Step 2: Run the test to verify it fails (RED)**

Run: `bash tests/smoke.sh`

Expected: FAIL at the new assertion. Because the measured child ignores the forwarded INT, the wrapper hangs, the 5s watchdog creates the timeout file, and the helper aborts with `measured INT wrapper did not exit` (non-zero exit). Confirm you see that message — that is the bug reproduced end-to-end through the real script.

- [ ] **Step 3: Apply the production fix**

In `nettotalizer`, edit `run_command_background_gated`. The existing function (`nettotalizer:109-144`) ends with:

```bash
  bash -c '
    gate=$1
    shift

    stdin_open=0
    if { exec 9<&0; } 2>/dev/null; then
      stdin_open=1
    fi

    IFS= read -r _ < "$gate"

    if [ "$stdin_open" -eq 1 ]; then
      exec 0<&9 9<&-
    else
      exec 0<&-
    fi

    exec "$@"
  ' \
    "$prog-runner" "$gate" "$@" <&0 &

  cmd_pid=$!
}
```

Add a `set -m` immediately before `bash -c '` (with the explanatory comment) and a `set +m` immediately after `cmd_pid=$!`, so the block becomes:

```bash
  # Enable job control just for this launch. A non-job-control shell forces
  # SIGINT/SIGQUIT to SIG_IGN in async (&) children, and that ignored
  # disposition survives `exec` into the measured command -- so Ctrl-C and a
  # forwarded SIGINT would never reach it (issue #13). `trap -` cannot undo a
  # signal ignored on entry to a non-interactive shell, but under job control
  # the shim is never auto-ignored in the first place; `set -m` also restores
  # the SIGQUIT default. Restore `set +m` right after capturing the PID so the
  # sampler/tracer adapters launched next keep ignoring SIGINT as intended.
  set -m
  bash -c '
    gate=$1
    shift

    stdin_open=0
    if { exec 9<&0; } 2>/dev/null; then
      stdin_open=1
    fi

    IFS= read -r _ < "$gate"

    if [ "$stdin_open" -eq 1 ]; then
      exec 0<&9 9<&-
    else
      exec 0<&-
    fi

    exec "$@"
  ' \
    "$prog-runner" "$gate" "$@" <&0 &

  cmd_pid=$!
  set +m
}
```

- [ ] **Step 4: Fix the now-stale comment in the pre-release abort path**

In `nettotalizer`, `stop_measured_command_before_release` (`nettotalizer:214-225`) currently reads:

```bash
  kill "-$signal" "$cmd_pid" 2>/dev/null || true
  # The gated bash runner can ignore SIGINT before it has exec'd the command.
  # This path runs only before release, so force the shim down and reap it.
  kill -TERM "$cmd_pid" 2>/dev/null || true
```

The "can ignore SIGINT" claim is false after the fix (the shim now starts with default INT). Replace the two comment lines with:

```bash
  kill "-$signal" "$cmd_pid" 2>/dev/null || true
  # Before release the live process is the gated shim, not the measured command.
  # The forwarded signal alone may not bring every shim/platform down promptly,
  # so escalate to SIGTERM then SIGKILL and reap it. (Runs only before release.)
  kill -TERM "$cmd_pid" 2>/dev/null || true
```

- [ ] **Step 5: Run the test to verify it passes (GREEN)**

Run: `bash tests/smoke.sh`

Expected: PASS, including `ok measured INT preserves child exit code` and `ok measured TERM preserves child exit code`. No `measured INT wrapper did not exit` and no `[1]+ ...` job-control noise on stderr.

- [ ] **Step 6: Run the full local gate**

Run: `bash tests/unit.sh && bash tests/smoke.sh`

Expected: both suites green (non-zero exit only on failure). The unit suite is unchanged — this fix is a signal-disposition/integration concern with no pure logic to unit-test, so coverage lives in `smoke.sh` (the same split used for the #2 race fix: smoke = contract guard).

- [ ] **Step 7: Mutation-check the new test**

Temporarily neutralize the fix to confirm the new test actually guards it:

```bash
# Comment out the `set -m` line in run_command_background_gated, then:
bash tests/smoke.sh   # MUST fail at the INT assertion (watchdog timeout)
# Restore the `set -m` line, then:
bash tests/smoke.sh   # MUST pass again
```

Expected: smoke fails with the fix removed (proving the test is load-bearing) and passes with it restored. Use `git diff` to confirm the only remaining change is the intended fix + test + comment.

- [ ] **Step 8: (Optional) Confirm the regression is not flaky**

Run: `for i in 1 2 3; do bash tests/smoke.sh >/dev/null && echo "run $i ok" || echo "run $i FAIL"; done`

Expected: three `ok` lines. The helper's 5s watchdog and 50×0.1s ready poll give wide timing margin, matching the existing stable TERM test.

- [ ] **Step 9: Commit**

```bash
git add nettotalizer tests/smoke.sh
git commit -m "fix: deliver SIGINT to measured command via scoped job control (#13)"
```

---

## Self-Review

**1. Spec coverage (issue #13):**
- "Reset SIGINT/SIGQUIT to default before the measured command runs" → Task 1 Step 3 (`set -m` restores both INT and QUIT defaults for the shim; survives `exec`). ✓
- "Add a measured-SIGINT smoke regression (the INT analogue of the measured-TERM test)" → Task 1 Step 1 (`assert_measured_signal_preserves_exit_code INT 47`). ✓
- The issue's *suggested* `trap -` fix is explicitly rejected with evidence in "Rejected alternatives" — the implemented fix differs from the suggestion and the plan says why. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to" placeholders. Every code step shows the exact code. ✓

**3. Type consistency:** No new functions/signatures introduced. The existing helper name `assert_measured_signal_preserves_exit_code` and the global `cmd_pid` are used verbatim as defined in the current source. ✓

## Notes / housekeeping (outside this PR's task)

- There is an untracked plan file from the previous session, `docs/superpowers/plans/2026-06-18-followups-2-5-6-9.md`. It is unrelated to #13. When branching for this PR, either commit it separately or leave it untracked (back it up before `git pull --ff-only` if RAS later commits a path collision — see the session gotchas). Do not fold it into the #13 commit.
- After merge: dev-journal entry (do NOT run `ras` for that step) and OmniFocus completion of the `nettotalizer: ... (#13)` task, per the standing workflow.
