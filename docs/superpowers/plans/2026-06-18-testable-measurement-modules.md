# Testable Measurement Modules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `nettotalizer`'s measurement number-crunching directly unit-testable by extracting the inline parsers and decision logic into small pure functions behind a main guard, without changing the tool's observable behavior.

**Architecture:** `nettotalizer` stays a single executable bash file. A main guard lets the file be `source`d (so each function is reachable by a test) while running identically when executed. Four deepening refactors — main guard, sampler-output parsers, a unified interface-byte reader, and a pure fallback decision — each land as one behavior-preserving PR, with the existing `tests/smoke.sh` as the regression net and a new `tests/unit.sh` proving each extracted interface.

**Tech Stack:** Bash (`set -u`, no `set -e`), `awk` for arithmetic and parsing, POSIX `netstat`/`route`/`nettop`/`bpftrace` as platform tools (faked in tests). GitHub via `gh`, `ras` for review, OmniFocus via the `omnifocus-cli` skill.

## Global Constraints

- **Single file** — `nettotalizer` remains one executable bash script. No `lib/` split.
- **Behavior-preserving** — every PR keeps `bash tests/smoke.sh` green (it exercises the macOS path, faked-Linux path, and faked-BSD path). The stderr summary (`total`/`received`/`sent`), exit-code passthrough, stdin/stdout/stderr passthrough, and all warning strings stay byte-identical.
- **Shell** — bash with `set -u`; do not introduce `set -e` or `pipefail`. Arithmetic that can be fractional goes through `awk` (bash has no floats).
- **No new runtime dependencies** — only tools already used per platform.
- **Pure functions read stdin** — extracted parsers consume their input on stdin and print results to stdout, so tests can pipe canned text. No fake processes for unit tests.
- **TDD where appropriate** — for every new function: write the failing unit test, watch it fail, extract minimal code, watch it pass, then confirm `smoke.sh` still passes.

---

## Per-PR Definition of Done (every PR runs these, in order)

This ritual applies to **all four PRs**. Each PR is a fresh branch off `main`, merged before the next begins.

1. **Branch off latest main:** `git checkout main && git pull --ff-only && git checkout -b <branch>`
2. **Implement the PR's tasks TDD:** each task is red → green → `bash tests/smoke.sh` green → `git commit`.
3. **Push:** `git push -u origin <branch>`
4. **Open PR:** `gh pr create --base main --title "<title>" --body "<body>"`. The body ends with:
   ```
   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```
5. **RAS review loop:** invoke the **ras-review-loop** skill on the PR (it prefers the first-class `ras review-fix <PR#>` for this same-repo PR). Iterate review → fix → verify → review until **no blocking findings** remain.
   - **Blocking = critical / high / medium.** These must be fixed (or explicitly dismissed with reason) before merge.
   - **Non-blocking = low / nit.** Do **not** block merge. For each, `gh issue create --title "<finding>" --body "<context + PR link>" --label "follow-up"`, then add the same as an OmniFocus task (step 8). Record the issue number in the PR thread.
6. **Merge:** `gh pr merge <PR#> --squash --delete-branch`
7. **Dev journal:** invoke the **append-dev-journal** skill to record the PR (evidence: PR number, merge commit, what changed, `smoke.sh`/`unit.sh` results). **Do NOT run `ras` for this step.**
8. **OmniFocus:** via the **omnifocus-cli** skill — mark this PR's task complete, and add a task for each follow-up issue created in step 5 (title mirrors the GitHub issue, note links the issue URL).

**OmniFocus setup (do once, at the start of PR 1):** create a project `nettotalizer — testable measurement modules` containing one task per PR below ("PR1: main guard", "PR2: sampler parsers", "PR3: interface reader", "PR4: fallback decision").

---

## File Structure

| File | Responsibility | PRs that touch it |
|---|---|---|
| `nettotalizer` | The tool. Gains a main guard and five extracted functions; two backend functions shrink; one duplicate parser is deleted. | 1, 2, 3, 4 |
| `tests/unit.sh` | New. Sources `nettotalizer` and exercises each pure function with canned input. | 1 (create), 2, 3, 4 (extend) |
| `CONTEXT.md` | Domain glossary. Gains two terms naming the measurement-quality dichotomy. | 1 |
| `docs/DEV-JOURNAL.md` | Appended once per PR via the append-dev-journal skill. | 1, 2, 3, 4 |

---

## PR 1 — Make the script unit-testable (main guard + harness + vocabulary)

**Branch:** `refactor/main-guard-test-harness`
**Why first:** every later PR depends on the script being sourceable. This PR adds no measurement logic — it only relocates startup behind a guard and stands up the test harness.

**Files:**
- Modify: `nettotalizer` (remove the early arg `case`; wrap dispatch in `main()` behind a `BASH_SOURCE` guard)
- Create: `tests/unit.sh`
- Modify: `CONTEXT.md` (add two terms)

**Interfaces:**
- Produces: a sourceable `nettotalizer` — `source ./nettotalizer` defines every function and returns 0 without running dispatch or printing usage. `main "$@"` runs only on direct execution.

- [ ] **Step 1: Write the failing test — `tests/unit.sh` harness + sourceability**

```bash
#!/usr/bin/env bash
# Unit tests for the pure modules inside nettotalizer.
#
# These source the script instead of executing it, so each extracted module can
# be exercised through its own interface with canned input — no fake nettop,
# netstat, or bpftrace processes required. Sourcing is only possible because the
# dispatch is behind a main guard; the first test pins that contract.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() { echo "not ok - $*" >&2; exit 1; }
ok()   { echo "ok - $*"; }

assert_eq() {
  local expected=$1 actual=$2 label=$3
  if [ "$actual" != "$expected" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

# Keystone: the script is sourceable without running dispatch.
src_out=$( ( source "$repo_root/nettotalizer" ) 2>&1 )
src_rc=$?
assert_eq 0 "$src_rc" "sourcing nettotalizer does not run dispatch"
if printf '%s\n' "$src_out" | grep -q 'Usage:'; then
  fail "sourcing nettotalizer printed usage (main guard missing)"
fi
ok "script is sourceable without running"

# Load the modules under test for everything below.
source "$repo_root/nettotalizer"

# format_bytes is already pure; characterize it now that it is reachable.
assert_eq "0B"      "$(format_bytes 0)"          "format_bytes: zero"
assert_eq "1023B"   "$(format_bytes 1023)"       "format_bytes: sub-KB boundary"
assert_eq "1.0KB"   "$(format_bytes 1024)"       "format_bytes: KB boundary"
assert_eq "1.5KB"   "$(format_bytes 1536)"       "format_bytes: fractional KB"
assert_eq "1.0MB"   "$(format_bytes 1048576)"    "format_bytes: MB boundary"
assert_eq "1.00GB"  "$(format_bytes 1073741824)" "format_bytes: GB boundary"
ok "format_bytes"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/unit.sh && bash tests/unit.sh`
Expected: FAIL — `sourcing nettotalizer does not run dispatch: expected '0', got '64'` (sourcing currently runs the early arg `case`, which calls `usage` and exits 64).

- [ ] **Step 3: Remove the early arg `case` from `nettotalizer`**

Replace:
```bash
  exit 64
}

case "${1:-}" in
  ""|-h|--help) usage ;;
esac

# Render integer byte counts compactly. Bash has no portable floating point, so
```
With:
```bash
  exit 64
}

# Render integer byte counts compactly. Bash has no portable floating point, so
```

- [ ] **Step 4: Wrap dispatch in `main()` behind a guard**

Replace the file's final block:
```bash
case "$(uname -s)" in
  Darwin)                    run_macos "$@" ;;
  Linux)                     run_linux "$@" ;;
  FreeBSD|NetBSD|OpenBSD)    run_bsd "$@" ;;
  *)
    echo "$prog: unsupported platform $(uname -s); running unmeasured" >&2
    exec "$@"
    ;;
esac
```
With:
```bash
# Parse arguments and dispatch to the platform backend. Kept in a function so the
# script can be sourced (for unit tests) without selecting a backend or running a
# command; only direct execution crosses the main guard below.
main() {
  case "${1:-}" in
    ""|-h|--help) usage ;;
  esac

  case "$(uname -s)" in
    Darwin)                    run_macos "$@" ;;
    Linux)                     run_linux "$@" ;;
    FreeBSD|NetBSD|OpenBSD)    run_bsd "$@" ;;
    *)
      echo "$prog: unsupported platform $(uname -s); running unmeasured" >&2
      exec "$@"
      ;;
  esac
}

# Run dispatch only when executed directly. When this file is sourced, the guard
# is false, so the functions above are defined without any of them running.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 5: Run tests to verify green**

Run: `bash -n nettotalizer && bash tests/unit.sh`
Expected: PASS — `ok - script is sourceable without running`, `ok - format_bytes`.

- [ ] **Step 6: Confirm executed behavior unchanged**

Run: `bash tests/smoke.sh`
Expected: every line `ok - ...`, exit 0 (help exit code 64, unsupported-platform passthrough, all macOS/Linux/BSD fakes still pass).

- [ ] **Step 7: Add the two domain terms to `CONTEXT.md`**

After the `**Network summary**` block, insert:
```markdown

**Process-scoped count**:
A network summary derived only from the measured command's process tree — Linux tcp/udp kretprobes, macOS nettop samples. The scoped, honest number: it counts socket payload bytes for the command and its descendants, and nothing else.
_Avoid_: Exact count, true total

**Interface delta estimate**:
A network summary derived from the before/after byte delta of the default interface, rather than from the measured command's process tree. Includes unrelated host traffic, so it is always reported with a warning. It is the BSD backend's only measurement and the macOS backend's fallback when process samples visibly undercount received bytes.
_Avoid_: Interface count, raw delta
```

- [ ] **Step 8: Commit**

```bash
git add nettotalizer tests/unit.sh CONTEXT.md
git commit -m "refactor: add main guard so nettotalizer is unit-testable

Move dispatch into main() behind a BASH_SOURCE guard so the script can be
sourced by tests without running. Add tests/unit.sh and name the two
measurement strategies in CONTEXT.md."
```

- [ ] **Step 9: Run the Per-PR Definition of Done** (push, PR, ras-review-loop, merge, dev-journal, OmniFocus).

---

## PR 2 — Extract the sampler-output parsers (candidate #1)

**Branch:** `refactor/extract-sampler-parsers`

**Files:**
- Modify: `nettotalizer` (add `parse_nettop_samples`, `parse_bpftrace_totals`; rewire `run_macos` and `run_linux`)
- Modify: `tests/unit.sh` (append parser tests)

**Interfaces:**
- Consumes: a sourceable `nettotalizer` (PR 1).
- Produces:
  - `parse_nettop_samples` — reads nettop CSV snapshots on stdin, prints `"<samples> <rx> <tx>"`. `samples` counts data rows (0 means the process tree finished between polls).
  - `parse_bpftrace_totals` — reads bpftrace END output on stdin, prints `"<rx> <tx>"`; missing values are 0.

- [ ] **Step 1: Write the failing tests** — append to `tests/unit.sh`:

```bash

# ---------------------------------------------------------------------------
# parse_bpftrace_totals: bpftrace END output -> "rx tx"
# ---------------------------------------------------------------------------
out=$(printf 'NETTOTALIZER_READY\nNETTOTALIZER_RX 2048\nNETTOTALIZER_TX 512\n' | parse_bpftrace_totals)
assert_eq "2048 512" "$out" "bpftrace totals: basic rx/tx"

out=$(printf 'NETTOTALIZER_RX 10\nNETTOTALIZER_RX 2048\nNETTOTALIZER_TX 1\nNETTOTALIZER_TX 512\n' | parse_bpftrace_totals)
assert_eq "2048 512" "$out" "bpftrace totals: last value wins"

out=$(printf 'NETTOTALIZER_READY\n' | parse_bpftrace_totals)
assert_eq "0 0" "$out" "bpftrace totals: missing values are zero"
ok "parse_bpftrace_totals"

# ---------------------------------------------------------------------------
# parse_nettop_samples: accumulated nettop CSV snapshots -> "samples rx tx"
# ---------------------------------------------------------------------------
out=$(printf '%s\n' ',bytes_in,bytes_out,' 'bash.123,100,200,' 'curl.456,300,400,' | parse_nettop_samples)
assert_eq "2 400 600" "$out" "nettop samples: sums distinct PIDs"

# Same PID re-sampled after exec rename: key by PID, keep cumulative max.
out=$(printf '%s\n' ',bytes_in,bytes_out,' 'bash.123,100,200,' ',bytes_in,bytes_out,' 'curl.123,150,250,' | parse_nettop_samples)
assert_eq "2 150 250" "$out" "nettop samples: dedupes exec rename, keeps max"

# Header only: zero data rows must report zero samples (drives no-sample warning).
out=$(printf '%s\n' ',bytes_in,bytes_out,' | parse_nettop_samples)
assert_eq "0 0 0" "$out" "nettop samples: header-only reports zero samples"
ok "parse_nettop_samples"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/unit.sh`
Expected: FAIL — `parse_bpftrace_totals: command not found`.

- [ ] **Step 3: Add `parse_bpftrace_totals`** — insert immediately after `linux_measurement_stop()` (before `run_linux()`):

```bash
parse_bpftrace_totals() {
  # Reduce bpftrace's END output (on stdin) to "rx tx". Use the last printed
  # values in case bpftrace emits multiple lines around shutdown. Missing values
  # intentionally collapse to 0 so a measurement failure does not change the
  # wrapped command's exit status.
  awk '
    /^NETTOTALIZER_RX / { rx = $2 }
    /^NETTOTALIZER_TX / { tx = $2 }
    END { printf "%d %d\n", rx + 0, tx + 0 }
  '
}
```

- [ ] **Step 4: Rewire `run_linux`** — replace:
```bash
  # Use the last printed values in case bpftrace emits multiple lines around
  # shutdown. Missing values intentionally collapse to 0 so measurement failure
  # does not change the wrapped command's exit status.
  rx=$(awk '/^NETTOTALIZER_RX / { value = $2 } END { print value + 0 }' "$bt_out")
  tx=$(awk '/^NETTOTALIZER_TX / { value = $2 } END { print value + 0 }' "$bt_out")

  print_summary "${rx:-0}" "${tx:-0}"
```
With:
```bash
  read -r rx tx <<<"$(parse_bpftrace_totals <"$bt_out")"

  print_summary "${rx:-0}" "${tx:-0}"
```

- [ ] **Step 5: Add `parse_nettop_samples`** — insert immediately after `macos_measurement_stop()` (before `run_macos()`):

```bash
parse_nettop_samples() {
  # Reduce accumulated nettop CSV snapshots (on stdin) to "samples rx tx".
  #
  #   * nettop emits a header for each -L 1 invocation; discover columns from
  #     headers instead of assuming a fixed layout.
  #   * Data rows are keyed by "process-name.PID". Strip the trailing ".PID" and
  #     key by PID so the same process is not double-counted when the gated bash
  #     shim execs into the real command and the displayed name changes.
  #   * Counters are cumulative per process, so the largest observed rx/tx value
  #     for each PID is that PID's best final total.
  #   * samples counts data rows. A zero sample count differs from a sampled
  #     process with true 0B traffic, so the caller warns only in the former case.
  awk -F',' '
    /bytes_in|bytes_out/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "bytes_in") in_col = i
        if ($i == "bytes_out") out_col = i
      }
      next
    }

    in_col && out_col && $1 != "" {
      samples++
      key = $1
      if (match(key, /\.[0-9]+$/)) {
        key = substr(key, RSTART + 1)
      }
      seen[key] = 1
      rx = $in_col + 0
      tx = $out_col + 0

      if (rx > max_rx[key]) max_rx[key] = rx
      if (tx > max_tx[key]) max_tx[key] = tx
    }

    END {
      for (key in seen) {
        total_rx += max_rx[key]
        total_tx += max_tx[key]
      }
      printf "%d %d %d\n", samples + 0, total_rx + 0, total_tx + 0
    }
  '
}
```

- [ ] **Step 6: Rewire `run_macos`** — replace the whole inline parse block (the `# Parse the accumulated CSV snapshots.` comment through the closing `' "$nt_out")`) with:
```bash
  # Reduce the accumulated CSV snapshots to "samples rx tx".
  rx_tx=$(parse_nettop_samples <"$nt_out")

  read -r samples rx tx <<<"$rx_tx"
```

- [ ] **Step 7: Run unit + smoke**

Run: `bash -n nettotalizer && bash tests/unit.sh && bash tests/smoke.sh`
Expected: PASS — `ok - parse_bpftrace_totals`, `ok - parse_nettop_samples`, and every `smoke.sh` line `ok`.

- [ ] **Step 8: Commit**

```bash
git add nettotalizer tests/unit.sh
git commit -m "refactor: extract nettop and bpftrace output parsers

Move the inline awk reducers out of run_macos/run_linux into
parse_nettop_samples and parse_bpftrace_totals, each reading stdin so they
can be unit-tested with canned text instead of fake processes."
```

- [ ] **Step 9: Run the Per-PR Definition of Done.**

---

## PR 3 — Unify the interface-byte reader + shared delta (candidate #2)

**Branch:** `refactor/unify-interface-reader`

**Files:**
- Modify: `nettotalizer` (add `parse_interface_bytes`, `clamped_delta`; replace `interface_bytes` and `bsd_interface_bytes` with thin wrappers; rewire the macOS fallback delta and BSD delta)
- Modify: `tests/unit.sh` (append reader + delta tests)

**Interfaces:**
- Consumes: a sourceable `nettotalizer` (PR 1).
- Produces:
  - `parse_interface_bytes <iface>` — reads `netstat -ib` output on stdin, prints `"<rx> <tx>"` for `<iface>`, exits 1 (no output) if absent. Locates `Ibytes`/`Obytes` by header name addressed from the right edge, so it spans the macOS and BSD `netstat` dialects and addressless (VPN) rows.
  - `clamped_delta <before> <after>` — prints `max(0, after - before)`.
  - `interface_bytes <iface>` (macOS wrapper) and `bsd_interface_bytes <iface>` (BSD wrapper) keep their existing call signatures and not-found contracts (`"0 0"` for macOS, empty for BSD).

- [ ] **Step 1: Write the failing tests** — append to `tests/unit.sh`:

```bash

# ---------------------------------------------------------------------------
# parse_interface_bytes: locate Ibytes/Obytes by header, counted from the right
# so one rule spans macOS, addressless macOS VPN rows, and BSD layouts.
# ---------------------------------------------------------------------------
macos_std=$(printf '%s\n' \
  'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll' \
  'lo0 16384 <Link#1> 100 0 5000 100 0 5000 0' \
  'en0 1500 <Link#5> 00:11:22:33:44:55 10 0 1000 20 0 2000 0' \
  'en0 1500 192.168.1/24 192.168.1.5 10 0 1000 20 0 2000 0')
out=$(printf '%s\n' "$macos_std" | parse_interface_bytes en0)
assert_eq "1000 2000" "$out" "interface bytes: macOS standard row"
out=$(printf '%s\n' "$macos_std" | parse_interface_bytes lo0)
assert_eq "5000 5000" "$out" "interface bytes: selects the named interface"

macos_utun=$(printf '%s\n' \
  'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll' \
  'utun0 1380 <Link#23> 10 0 132072 20 0 6096 0')
out=$(printf '%s\n' "$macos_utun" | parse_interface_bytes utun0)
assert_eq "132072 6096" "$out" "interface bytes: addressless macOS VPN row"

bsd=$(printf '%s\n' \
  'Name Mtu Network Address Ibytes Obytes' \
  'em0 1500 <Link#1> 00:11:22:33:44:55 4200 2600')
out=$(printf '%s\n' "$bsd" | parse_interface_bytes em0)
assert_eq "4200 2600" "$out" "interface bytes: BSD compact layout"

out=$(printf '%s\n' "$bsd" | parse_interface_bytes wg0); rc=$?
assert_eq "" "$out" "interface bytes: absent interface yields no output"
assert_eq 1 "$rc" "interface bytes: absent interface yields nonzero status"
ok "parse_interface_bytes"

# ---------------------------------------------------------------------------
# clamped_delta: after-before, floored at zero (counters can reset/wrap).
# ---------------------------------------------------------------------------
assert_eq 500 "$(clamped_delta 1000 1500)" "clamped delta: normal increase"
assert_eq 0 "$(clamped_delta 1500 1000)" "clamped delta: decrease floored to zero"
assert_eq 0 "$(clamped_delta 4200 4200)" "clamped delta: no change is zero"
ok "clamped_delta"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/unit.sh`
Expected: FAIL — `parse_interface_bytes: command not found`.

- [ ] **Step 3: Replace the two readers** — replace the entire `interface_bytes()` and `bsd_interface_bytes()` block with:

```bash
parse_interface_bytes() {
  local iface=$1

  # Reduce netstat -ib output (on stdin) to "rx tx" for one interface, exiting
  # nonzero when it is absent. The Ibytes/Obytes columns are found by header name
  # but addressed from the right edge, so one rule spans the differing trailing
  # columns of the macOS and BSD netstat dialects and survives rows that omit a
  # leading Address column (macOS VPN/utun interfaces). These counters include all
  # traffic on the interface, not just the wrapped command, which is why callers
  # emit an explicit warning.
  awk -v iface="$iface" '
    /Ibytes/ && /Obytes/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "Ibytes") ib = NF - i
        if ($i == "Obytes") ob = NF - i
      }
      have_header = 1
      next
    }

    have_header && $1 == iface {
      printf "%d %d\n", $(NF - ib) + 0, $(NF - ob) + 0
      found = 1
      exit
    }

    END {
      if (!found) exit 1
    }
  '
}

clamped_delta() {
  # after - before, floored at zero. Interface counters can reset or wrap across
  # the measurement window, so a negative delta is reported as no traffic rather
  # than a misleading huge number.
  local before=$1 after=$2 delta
  delta=$((after - before))
  [ "$delta" -lt 0 ] && delta=0
  printf '%d\n' "$delta"
}

interface_bytes() {
  # macOS reader: netstat -ibn lists every interface; the parser selects ours.
  # Returns "0 0" when the interface is absent so the fallback baseline stays
  # well-defined.
  netstat -ibn | parse_interface_bytes "$1" || printf '0 0\n'
}

bsd_interface_bytes() {
  # BSD reader: the same counters via the per-interface display. Empty output
  # signals "not found", which the caller treats as unmeasured.
  netstat -ibn -I "$1" 2>/dev/null | parse_interface_bytes "$1"
}
```

- [ ] **Step 4: Route the macOS fallback delta through `clamped_delta`** — in `run_macos`, replace:
```bash
    iface_rx_delta=$((iface_rx_after - ${iface_rx_before:-0}))
    iface_tx_delta=$((iface_tx_after - ${iface_tx_before:-0}))
    [ "$iface_rx_delta" -lt 0 ] && iface_rx_delta=0
    [ "$iface_tx_delta" -lt 0 ] && iface_tx_delta=0
```
With:
```bash
    iface_rx_delta=$(clamped_delta "${iface_rx_before:-0}" "$iface_rx_after")
    iface_tx_delta=$(clamped_delta "${iface_tx_before:-0}" "$iface_tx_after")
```

- [ ] **Step 5: Route the BSD delta through `clamped_delta`** — in `run_bsd`, replace:
```bash
  rx=$((rx_after - rx_before))
  tx=$((tx_after - tx_before))
  [ "$rx" -lt 0 ] && rx=0
  [ "$tx" -lt 0 ] && tx=0
```
With:
```bash
  rx=$(clamped_delta "$rx_before" "$rx_after")
  tx=$(clamped_delta "$tx_before" "$tx_after")
```

- [ ] **Step 6: Run unit + smoke**

Run: `bash -n nettotalizer && bash tests/unit.sh && bash tests/smoke.sh`
Expected: PASS — `ok - parse_interface_bytes`, `ok - clamped_delta`, and the macOS-standard, macOS-addressless (`utun`), and FreeBSD/NetBSD/OpenBSD `smoke.sh` cases all `ok`.

- [ ] **Step 7: Commit**

```bash
git add nettotalizer tests/unit.sh
git commit -m "refactor: unify interface-byte reader and delta math

Replace the two divergent netstat parsers with one parse_interface_bytes
that locates Ibytes/Obytes from the right edge (dialect- and addressless-
safe), behind thin macOS/BSD wrappers, and route both delta sites through
clamped_delta."
```

- [ ] **Step 8: Run the Per-PR Definition of Done.**

---

## PR 4 — Extract the fallback decision (candidate #3)

**Branch:** `refactor/extract-fallback-decision`

**Files:**
- Modify: `nettotalizer` (add `should_use_interface_fallback`; rewire the `run_macos` fallback condition)
- Modify: `tests/unit.sh` (append decision truth-table tests)

**Interfaces:**
- Consumes: a sourceable `nettotalizer` (PR 1).
- Produces: `should_use_interface_fallback <process_rx> <delta_rx>` — exits 0 (use the interface delta) when `delta_rx > 65536` **and** `delta_rx > process_rx + 65536` **and** (`process_rx == 0` **or** `delta_rx > 2 * process_rx`); exits 1 otherwise. No output, no side effects.

- [ ] **Step 1: Write the failing tests** — append to `tests/unit.sh`:

```bash

# ---------------------------------------------------------------------------
# should_use_interface_fallback: prefer the interface delta only when process
# samples clearly undercounted received bytes.
# ---------------------------------------------------------------------------
should_use_interface_fallback 0 70000 && r=use || r=keep
assert_eq use "$r" "fallback: zero process rx, large interface delta -> use"

should_use_interface_fallback 0 1000 && r=use || r=keep
assert_eq keep "$r" "fallback: small interface delta -> keep process"

should_use_interface_fallback 100000 250000 && r=use || r=keep
assert_eq use "$r" "fallback: interface delta more than doubles process rx -> use"

should_use_interface_fallback 100000 150000 && r=use || r=keep
assert_eq keep "$r" "fallback: interface delta within margin -> keep process"
ok "should_use_interface_fallback"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/unit.sh`
Expected: FAIL — `should_use_interface_fallback: command not found` (the `&&`/`||` makes `r=keep`, so the first assertion fails with `expected 'use', got 'keep'`).

- [ ] **Step 3: Add `should_use_interface_fallback`** — insert immediately before `run_macos()` (next to `parse_nettop_samples` from PR 2):

```bash
should_use_interface_fallback() {
  # Decide whether the interface delta should replace the process-scoped count.
  # Thresholds are intentionally blunt:
  #   * require >64KB interface RX so ordinary background chatter does not flip
  #     tiny commands into fallback mode;
  #   * require the interface delta to beat process RX by >64KB; and
  #   * if process RX is nonzero, require the interface delta to be >2x process
  #     RX so good process data is not replaced for small differences.
  local process_rx=$1 delta_rx=$2

  [ "$delta_rx" -gt 65536 ] &&
    [ "$delta_rx" -gt $((process_rx + 65536)) ] &&
    { [ "$process_rx" -eq 0 ] || [ "$delta_rx" -gt $((process_rx * 2)) ]; }
}
```

- [ ] **Step 4: Rewire the `run_macos` fallback condition** — replace:
```bash
    if [ "$iface_rx_delta" -gt 65536 ] &&
      [ "$iface_rx_delta" -gt $((${rx:-0} + 65536)) ] &&
      { [ "${rx:-0}" -eq 0 ] || [ "$iface_rx_delta" -gt $((${rx:-0} * 2)) ]; }; then
      rx=$iface_rx_delta
      tx=$iface_tx_delta
      fallback_used=1
    fi
```
With:
```bash
    if should_use_interface_fallback "${rx:-0}" "$iface_rx_delta"; then
      rx=$iface_rx_delta
      tx=$iface_tx_delta
      fallback_used=1
    fi
```

- [ ] **Step 5: Run unit + smoke**

Run: `bash -n nettotalizer && bash tests/unit.sh && bash tests/smoke.sh`
Expected: PASS — `ok - should_use_interface_fallback`, and the macOS fallback `smoke.sh` cases (`utun` interface delta, pre-ready traffic ignored, no-sample warning) all `ok`.

- [ ] **Step 6: Commit**

```bash
git add nettotalizer tests/unit.sh
git commit -m "refactor: extract macOS fallback decision

Lift the three-threshold 'trust the interface delta' policy out of
run_macos into should_use_interface_fallback, a pure predicate over two
numbers, so the heuristic is testable without driving the whole macOS path."
```

- [ ] **Step 7: Run the Per-PR Definition of Done.**

---

## Self-Review

**1. Spec coverage:**
- Keystone (main guard) → PR 1. ✓
- Candidate #1 (parsers) → PR 2. ✓
- Candidate #2 (unified reader + delta) → PR 3. ✓
- Candidate #3 (fallback decision) → PR 4. ✓
- CONTEXT.md domain terms → PR 1, Step 7. ✓
- Branch + multiple PRs + TDD + per-PR ras-review-loop (non-blocking nits → follow-up issues) + merge + dev-journal (no ras) + OmniFocus (incl. follow-up issues) → Per-PR Definition of Done. ✓

**2. Placeholder scan:** No `TBD`/`TODO`/"add error handling"/"similar to Task N". Every code step shows complete code; every run step shows the command and expected result. ✓

**3. Type/name consistency:** `parse_nettop_samples` → `"samples rx tx"` (3 fields, consumed by `read -r samples rx tx`). `parse_bpftrace_totals`/`parse_interface_bytes` → `"rx tx"` (2 fields). `clamped_delta before after`. `should_use_interface_fallback process_rx delta_rx`. macOS fallback feeds `should_use_interface_fallback "${rx:-0}" "$iface_rx_delta"` — `iface_rx_delta` now comes from `clamped_delta` (PR 3), so PR 4's input is well-defined. Wrapper names `interface_bytes`/`bsd_interface_bytes` keep their existing call sites in `macos_measurement_before_release`, `run_macos`, and `run_bsd`. ✓

---

## Notes & risks

- **Ordering:** PR 3 must precede PR 4 (both edit the `run_macos` fallback region; PR 4's input `iface_rx_delta` is produced by PR 3's `clamped_delta`). PR 2 is independent of PR 3/4 but listed second for reviewer flow.
- **Coverage honesty:** `tests/unit.sh` and `tests/smoke.sh` run fully on macOS. The real Linux (`tests/linux.sh`, `tests/linux-docker.sh`) and BSD paths are **not** run here — `smoke.sh`'s fakes are the safety net for those. This is unchanged from today and worth a line in each dev-journal entry.
- **Merge style:** plan uses `--squash`. If the repo prefers merge commits, swap to `gh pr merge <PR#> --merge --delete-branch`.
- **Pre-existing issue #2** (*"Preserve measured command exit status after interrupted wait"*) is unrelated to this refactor; leave it untouched.
