# Measured Command SIGINT Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a command measured by `nettotalizer` receive `SIGINT` (Ctrl-C and forwarded INT) instead of silently ignoring it (issue #13).

**Architecture:** `run_command_background_gated` launches the gated runner asynchronously (`&`) in a non-job-control shell. POSIX forces async children to set `SIGINT`/`SIGQUIT` to `SIG_IGN`, and that ignored disposition survives `exec` into the measured command — so neither a terminal Ctrl-C nor nettotalizer's `forward_int` trap reaches it. A non-interactive shell cannot reset a signal that was ignored on entry (`trap -` is a no-op), so the fix hands off through `perl` — which restores the default `INT`/`QUIT` disposition at the syscall layer and `exec`s the real command — keeping it in the **wrapper's own process group**. When `perl` is unavailable the runner `exec`s directly (degraded: measurement still works, INT stays ignored as it does today). A measured-`SIGINT` smoke regression plus a process-group invariant guard cover it.

**Tech Stack:** Bash 3.2+ (single-file POSIX-leaning script), `tests/smoke.sh` (process-fake integration harness), `tests/unit.sh` (pure-function units). macOS dev host. `perl` (already required by the smoke suite; now a *soft* runtime dependency for the SIGINT fix, with graceful degradation).

## Global Constraints

- Single-file script `nettotalizer` (`#!/usr/bin/env bash`); must keep working on bash 3.2.57 (macOS system bash). One line, verbatim.
- The fix uses `perl` as a **soft** dependency only: if `perl` is absent the measured command still runs and is still measured; only the SIGINT reset is skipped (current `main` behavior). No *hard* new dependency on the measured path.
- The fix must **not** change the measured command's process group or terminal-foreground semantics (see approach history).
- Local gate is `bash tests/unit.sh && bash tests/smoke.sh`; both must be green before commit.
- Follow the repo's per-PR ritual (branch → TDD → push → PR → RAS loop in background → merge → dev-journal → OmniFocus). This plan covers the code+test for ONE PR.

### Approach history (why perl, not `set -m`)

The first implementation used scoped job control (`set -m` … `&` … `set +m`). It delivered SIGINT, but RAS review revealed a serious consequence: `set -m` places the measured command in a **separate process group**, which controls terminal access and signal delivery. A measured command reading the controlling terminal then stops on `SIGTTIN`; Ctrl-C/Ctrl-Z and process-tree signalling all change. The auto-fixer tried to *manage* the new process group (terminal foreground handoff via `perl`/`tcsetpgrp`, process-group forwarding, Ctrl-Z handling, PTY tests) and ballooned to ~1900 lines across two new dependencies without converging. Abandoned. The chosen `perl` shim resets the signal **without** creating a new process group, so the entire terminal/job-control surface is untouched.

### Rejected alternatives (verified empirically)

- **`trap - INT QUIT` in the shim (the issue's suggested fix): DOES NOT WORK.** POSIX: a signal ignored on entry to a non-interactive shell "cannot be trapped or reset." Silent no-op on bash 3.2.57; the child still ignored INT.
- **Scoped `set -m` (job control): works for the signal, but changes the measured command's process group** → SIGTTIN on terminal reads, terminal foreground/Ctrl-Z semantics change, large downstream complexity. Rejected (see approach history).
- **No-dependency parent-trap tricks** (`trap handler INT` / `trap - INT` in the parent before `&`): do not work — bash 3.2 still forces `SIG_IGN` on the async child regardless of parent trap state.

## File Structure

- `nettotalizer` — `run_command_background_gated`: prepend a `perl` reset shim to the exec'd argv when `perl` is present.
- `tests/smoke.sh` — measured-`SIGINT` delivery regression + process-group invariant guard.

---

### Task 1: Reset SIGINT/SIGQUIT for the measured command without changing its process group

**Files:**
- Modify: `nettotalizer` — `run_command_background_gated` (perl reset prefix)
- Test: `tests/smoke.sh` — INT delivery regression + process-group guard

**Interfaces:**
- Consumes: the existing `assert_measured_signal_preserves_exit_code <signal> <code>` helper.
- Produces: no new functions. `run_command_background_gated` keeps its contract (sets global `cmd_pid`); the measured command now starts with default INT/QUIT disposition, in the wrapper's process group.

- [ ] **Step 1: Write the failing INT delivery test**

In `tests/smoke.sh`, after `assert_measured_signal_preserves_exit_code TERM 42`:

```bash
# Regression for #13: a forwarded SIGINT must reach the measured command. With
# the bug, async-job INT is SIG_IGN and survives exec, so the child loops
# forever and the helper's 5s watchdog fires (timeout -> fail). A distinct exit
# code (47, not 130 and not TERM's 42) proves it is the child's deliberate code.
assert_measured_signal_preserves_exit_code INT 47
```

- [ ] **Step 2: Run smoke to verify RED** — `bash tests/smoke.sh`; expect `not ok - measured INT wrapper did not exit` (watchdog timeout).

- [ ] **Step 3: Apply the perl reset shim**

In `run_command_background_gated`, immediately before the `bash -c '` launch (after the existing stdin comment), add:

```bash
  if command -v perl >/dev/null 2>&1; then
    set -- perl -e '$SIG{INT}="DEFAULT"; $SIG{QUIT}="DEFAULT"; exec { $ARGV[0] } @ARGV; warn "$ARGV[0]: $!\n"; exit($! == 2 ? 127 : 126)' -- "$@"
  fi
```

with an explanatory comment. The block form `exec { $ARGV[0] } @ARGV` execs directly (never via a shell), matching `exec "$@"`; the `warn`/`exit` line mirrors bash's command-not-found (127) / not-executable (126) exit codes. Do **not** add `set -m`.

- [ ] **Step 4: Add the process-group invariant guard** (after the INT test):

```bash
NETTOTALIZER_FAKE_UNAME=Darwin \
  NETTOTALIZER_FAKE_NETTOP_MODE=ready \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'printf "%s %s\n" "$$" "$(ps -o pgid= -p $$ | tr -d " ")"' \
  >"$tmpdir/measured-pgid.out" 2>"$tmpdir/measured-pgid.err"
rc=$?
assert_eq 0 "$rc" "measured process-group probe exit code"
measured_pid=$(awk 'NR==1{print $1}' "$tmpdir/measured-pgid.out")
measured_pgid=$(awk 'NR==1{print $2}' "$tmpdir/measured-pgid.out")
# PID == PGID would mean the command is its own group leader (the set -m regression).
[ "$measured_pid" != "$measured_pgid" ] || fail "measured command is its own process-group leader"
ok "measured command shares the wrapper process group (no SIGTTIN regression)"
```

- [ ] **Step 5: Verify GREEN** — `bash tests/unit.sh && bash tests/smoke.sh`; both green, including `ok - measured INT preserves child exit code` and `ok - measured command shares the wrapper process group`.

- [ ] **Step 6: Mutation-check** — temporarily replace the perl shim with `set -m` (the rejected approach); confirm the process-group guard fails (PID == PGID); restore. Then temporarily delete the perl shim entirely; confirm the INT delivery test fails (timeout); restore.

- [ ] **Step 7: Commit**

```bash
git add nettotalizer tests/smoke.sh
git commit -m "fix: deliver SIGINT to measured command via perl signal reset (#13)"
```

---

## Self-Review

**1. Spec coverage (issue #13):** SIGINT now reaches the measured command (Step 3); regression test (Step 1); process-group guard ensures the fix has no terminal-foreground side effect (Step 4). The issue's suggested `trap -` is rejected with evidence. ✓
**2. Placeholder scan:** every code step shows exact code. ✓
**3. Type consistency:** no new functions; existing helper/globals used verbatim. ✓

## Notes / housekeeping (outside this PR's task)

- The unrelated untracked `2026-06-18-followups-2-5-6-9.md` plan stays out of this commit.
- RAS retained a forensics worktree under `.ras/` from the abandoned `set -m` approach; leave it unless cleaning up deliberately.
- True PTY/terminal-read coverage (interactive `read </dev/tty`) is **not** included — a portable shell PTY test needs `python3`/`expect`, which we declined to add. The process-group invariant guard (Step 4) covers the actual regression vector (a separate process group) without that dependency; documented as a known test-coverage limitation.
