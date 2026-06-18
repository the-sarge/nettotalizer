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
