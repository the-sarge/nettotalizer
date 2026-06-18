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
