# Development Journal

**Append-only. New entries go at the END of this file.**

Oldest entry first, most recent entry last.

---

## Measured command lifecycle landed - 2026-06-18 03:37 EDT

**Main:** `c873030b8798`
**Actor:** Codex

### Summary

Merged PR #1 to deepen the measured command lifecycle in `nettotalizer`.

### Completed

- Added `CONTEXT.md` glossary entries for measured command, measured command lifecycle, and network summary.
- Centralized gated launch, adapter readiness, command release, signal forwarding, adapter shutdown, and exit-code preservation behind a measured command lifecycle module.
- Migrated Linux `bpftrace` tracing and macOS `nettop` sampling onto lifecycle adapter hooks.
- Added smoke coverage for Linux readiness gating, tracer failure, stdin preservation, closed stdin, sudo fallback cleanup, pre-ready signal cleanup, macOS sampler failure, sampler timeout cleanup, pre-release sampling, fallback baseline timing, fallback byte parsing, and BSD interface deltas.
- Opened follow-up issue #2 for the non-blocking interrupted-wait exit-status race.

### Validation

- `bash -n ./nettotalizer tests/smoke.sh tests/macos.sh tests/linux.sh tests/linux-docker.sh`
- `git diff --check`
- `tests/smoke.sh`
- `tests/macos.sh`

### Next

- Resolve issue #2: preserve measured command exit status after an interrupted `wait`.

---

## Testable measurement modules — PR 1 (main guard) landed - 2026-06-18 19:13 EDT

**Main:** `cdcb54e9c142`
**Actor:** Claude Opus 4.8 (1M context)

**Summary**

Landed PR #4, the first of four behavior-preserving refactors making `nettotalizer`'s measurement logic unit-testable. The script can now be sourced without running dispatch, so the measurement parsers (extracted in later PRs) become directly testable.

**Completed**

- `main()` guard: dispatch runs only under `[[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]`; `set -u` moved inside `main()` so sourcing does not leak `nounset` into a caller shell.
- `tests/unit.sh` (new): sources the script and characterizes the sourceability contract, `prog` resolution, nounset preservation, direct/stdin `--help`, and `format_bytes`.
- `CONTEXT.md`: named the measurement-quality dichotomy — **Process-scoped count** and **Interface delta estimate**.
- `README.md`: documents `bash tests/unit.sh` (added during review).
- `docs/superpowers/plans/2026-06-18-testable-measurement-modules.md`: full 4-PR plan of record.

**Decisions**

- RAS `review-fix` caught a Medium regression: piped execution (`cat nettotalizer | bash -s`) crashed on unbound `BASH_SOURCE[0]`. Fixed by defaulting the guard and treating an empty source path as direct execution.
- Two non-blocking findings deferred to follow-up issues per the non-blocking-on-low/nit policy: #5 (wire `tests/unit.sh` into the local test gate) and #6 (clear positional parameters before sourcing). Both tracked in OmniFocus.

**Validation**

- `bash -n nettotalizer`, `bash tests/unit.sh`, `bash tests/smoke.sh` — all green on `main` after squash-merge (`cdcb54e`).
- macOS only on this host; real Linux/BSD paths remain covered by `smoke.sh` fakes.

**Next**

- PR 2: extract `parse_nettop_samples` / `parse_bpftrace_totals`.
- PR 3: unify the interface reader (`parse_interface_bytes`) + `clamped_delta`.
- PR 4: extract `should_use_interface_fallback`.

---

## Testable measurement modules — PR 2 (sampler parsers) landed - 2026-06-18 19:23 EDT

**Main:** `d5a69d05e2c3`
**Actor:** Claude Opus 4.8 (1M context)

**Summary**

Landed PR #7, the second refactor: the two sampler-output reducers now live in named pure functions that read stdin, so they are unit-testable with canned text instead of fake `nettop`/`bpftrace` processes.

**Completed**

- `parse_nettop_samples` — nettop CSV snapshots → `"samples rx tx"` (header discovery, PID-keyed dedupe across the exec rename, cumulative max).
- `parse_bpftrace_totals` — bpftrace END output → `"rx tx"` (last value wins, missing → 0).
- `run_macos`/`run_linux` call the parsers instead of embedding awk.
- Unit coverage: distinct-PID sum, exec-rename dedupe, header-only zero-sample, zero-byte sampled row (`1 0 0`), and header-order independence.

**Decisions**

- RAS `review-fix` found no blocking issues. Two non-blocking test-coverage gaps (zero-byte sampled row, swapped `bytes_out`/`bytes_in` header) were fixed inline rather than deferred — they complete this PR's own deliverable and are cheap/in-area, which the review-loop policy endorses.

**Validation**

- `bash -n nettotalizer`, `bash tests/unit.sh`, `bash tests/smoke.sh` — green on `main` after squash-merge (`d5a69d0`).

**Next**

- PR 3: unify the interface reader (`parse_interface_bytes`, header-from-right) + `clamped_delta`.

---

## Testable measurement modules — PR 3 (unified interface reader) landed - 2026-06-18 19:39 EDT

**Main:** `e6fab9978d37`
**Actor:** Claude Opus 4.8 (1M context)

**Summary**

Landed PR #8, the third refactor: the two divergent `netstat` interface-byte parsers are now one `parse_interface_bytes`, and both before/after delta sites share `clamped_delta`. One duplicate parser deleted.

**Completed**

- `parse_interface_bytes <iface>` — locates `Ibytes`/`Obytes` by header name addressed from the right edge, so one rule spans the macOS and BSD dialects and addressless (VPN/`utun`) rows; prefers the `<Link#...>` row.
- `clamped_delta <before> <after>` — `max(0, after-before)` in one place; used by the macOS fallback and the BSD backend.
- `interface_bytes`/`bsd_interface_bytes` reduced to thin wrappers preserving their not-found contracts (macOS `0 0`, BSD empty/nonzero).
- Unit coverage: macOS standard, Link-row-preference (reordered rows), addressless `utun`, realistic BSD column layout, absent interface, and `clamped_delta`.

**Decisions**

- RAS `review-fix` found no blocking issues but flagged a **latent regression**: the unified parser had dropped the original `<Link#...>` row selection (taking the first matching row instead). Restored the Link-row preference inline — keeping the PR behavior-preserving — and added a discriminating row-selection test plus a realistic BSD fixture.
- Deferred direct not-found tests for the thin wrappers to follow-up issue #9.

**Validation**

- `bash -n nettotalizer`, `bash tests/unit.sh`, `bash tests/smoke.sh` — green on `main` after squash-merge (`e6fab99`).

**Next**

- PR 4 (final): extract `should_use_interface_fallback`.

---

## Testable measurement modules — PR 4 (fallback decision) landed; effort complete - 2026-06-18 19:48 EDT

**Main:** `4cec3698dc1e`
**Actor:** Claude Opus 4.8 (1M context)

**Summary**

Landed PR #10, the final refactor: the macOS "trust the interface delta" policy is now `should_use_interface_fallback`, a pure predicate over two numbers. This completes the four-PR effort — `run_macos`/`run_linux` are now thin orchestration over tested pure modules.

**Completed**

- `should_use_interface_fallback <process_rx> <delta_rx>` — the three-threshold decision as a side-effect-free predicate; `run_macos` calls it instead of inlining the condition.
- Unit truth table including a 2x-isolating case and strict `-gt` boundary cases (64KB floor, `process+64KB` margin, `2x` guard) that kill `-gt`→`-ge` mutants.
- De-duplicated the threshold rationale — it now lives only in the predicate; `run_macos` points to it.

**Decisions**

- RAS `review-fix` found no blocking issues. Three non-blocking findings (2x-isolating test, strict-boundary tests, duplicated comment) were fixed inline — they complete the predicate's own coverage/quality.
- Transient GitHub mergeability lag after the fix push required a short poll before squash-merge; no conflict.

**Validation**

- `bash -n nettotalizer`, `bash tests/unit.sh`, `bash tests/smoke.sh` — green on `main` after squash-merge (`4cec369`).

**Outcome**

- Four behavior-preserving PRs (#4, #7, #8, #10) landed: main guard + five extracted modules (`parse_nettop_samples`, `parse_bpftrace_totals`, `parse_interface_bytes`, `clamped_delta`, `should_use_interface_fallback`), one duplicate parser deleted, `tests/unit.sh` added.
- Open follow-ups: #5, #6 (PR 1 test infra), #9 (PR 3 wrapper not-found tests).

---

## Follow-ups — test-suite hardening (#5, #6, #9) landed - 2026-06-18 21:50 EDT

**Main:** `6c35105e20c4`
**Actor:** Claude Opus 4.8 (1M context)

**Summary**

Closed the test-hardening follow-ups #5, #6, #9 in one PR (#11). Test-only; no production change.

**Completed**

- #9 — direct unit tests for the thin wrappers' not-found contracts (`interface_bytes <absent>` → `0 0`; `bsd_interface_bytes <absent>` → empty + nonzero), driven by a stubbed `netstat` shell function.
- #6 — clear positional parameters (`set --`) before both `source` sites in `tests/unit.sh`.
- #5 — `tests/smoke.sh` now runs `bash tests/unit.sh` immediately after the syntax check, so the local gate covers the sourceable contract and all extracted modules.

**Decisions**

- RAS `review-fix` found no blocking issues. Two Info-level findings were fixed inline: the BSD wrapper stub now honors `-I <iface>` (so dropping that argument is caught — verified by a mutation check that fails the present-interface assertion), and the `set --` comment was reworded as defense-in-depth rather than fixing a currently-reachable dispatch leak (the main guard already blocks sourced dispatch).

**Validation**

- `bash tests/unit.sh`, `bash tests/unit.sh spurious-arg`, `bash tests/smoke.sh` (now runs unit first) — green on `main` after squash-merge (`6c35105`).

**Next**

- Follow-up PR 2: fix #2 (`wait_for_command` exit-status race).

---

## Follow-up — preserve exit status after interrupted wait (#2) landed - 2026-06-18 22:44 EDT

**Main:** `ed9e91d4c3fb`
**Actor:** Claude Opus 4.8 (1M context)

**Summary**

Fixed #2: `wait_for_command` could return a forwarded signal's status (`130`/`143`) instead of the measured command's real exit code in a narrow interrupted-wait race.

**Completed**

- `wait_for_command` now records whether a forwarding trap interrupted `wait` (a flag set in `forward_int`/`forward_term`, visible via bash dynamic scoping). When the child is gone, that flag is set, and the first status is `>128`, it runs one recovery `wait` and accepts the real reaped status verbatim.
- Deterministic unit tests (mocked `wait`/`kill`) for the recovery path (genuine `127` and a distinctive `42`), the normal-reap path, and the `forward_int`/`forward_term` flag (mutation-verified). Measured-`TERM` smoke contract guard.

**Decisions**

- RAS `review-fix` caught a real bug in the first attempt: the `127` sentinel was ambiguous — bash returns `127` both for a child exiting `127` and for `wait` on an already-reaped PID — so a genuine `127` in the race would be discarded. Reworked to the signal-seen flag (the approach the review recommended). Three follow-up low findings (distinctive non-sentinel test value, trap-handler unit coverage, comment accuracy) were fixed inline.
- **Discovery, filed as #13:** while building the regression I confirmed a separate pre-existing bug — a measured command launched via the async gated runner inherits `SIGINT` ignored (POSIX async-job semantics across `exec`), so Ctrl-C cannot interrupt it and the INT-forward path is a no-op. Repro and suggested fix in #13; kept out of scope here.

**Validation**

- `bash -n nettotalizer`, `bash tests/unit.sh`, `bash tests/smoke.sh` — green on `main` after squash-merge (`ed9e91d`).

**Outcome**

- Follow-ups #2, #5, #6, #9 all closed. New follow-up #13 (SIGINT inheritance) open and tracked.
