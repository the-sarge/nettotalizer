# Testable Measurement Modules Plan

## Context

`nettotalizer` currently keeps startup dispatch, platform orchestration, and measurement parsing in one executable Bash script. The smoke tests protect end-to-end behavior with fake platform tools, but the parser logic is hard to unit-test directly while sourcing the script runs dispatch immediately.

## Goal

Refactor the measurement logic into small sourceable Bash functions while preserving command-line behavior, stderr output, stdin/stdout/stderr passthrough, exit-code passthrough, signal cleanup, and all existing macOS/Linux/BSD fake-platform smoke coverage.

## Sequence

1. Add a `main()` guard, introduce `tests/unit.sh`, and name the measurement-quality concepts in `CONTEXT.md`.
2. Extract macOS `nettop` sample parsing into functions that can be fed canned sampler rows.
3. Extract Linux `bpftrace` output parsing into functions that can be fed canned tracer output.
4. Extract BSD interface byte parsing and delta handling into functions that can be fed canned route/netstat output.

## Guardrails

Each PR should be behavior-preserving and keep the existing smoke tests passing. Unit tests should characterize extracted pure logic first; broader lifecycle behavior remains covered by `tests/smoke.sh` fakes until a future change needs deeper integration coverage.
