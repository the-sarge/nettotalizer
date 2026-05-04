#!/usr/bin/env bash
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

fail() {
  echo "not ok - $*" >&2
  exit 1
}

ok() {
  echo "ok - $*"
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3

  if [ "$actual" != "$expected" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_summary() {
  local summary=$1
  local label=$2

  printf '%s\n' "$summary" | grep -Eq '^total [^ ]+$' ||
    fail "$label: summary missing total line: $summary"
  printf '%s\n' "$summary" | grep -Eq '^received [^ ]+$' ||
    fail "$label: summary missing received line: $summary"
  printf '%s\n' "$summary" | grep -Eq '^sent [^ ]+$' ||
    fail "$label: summary missing sent line: $summary"
}

assert_nonzero_net_summary() {
  local summary=$1
  local label=$2

  assert_summary "$summary" "$label"

  if printf '%s\n' "$summary" | grep -Eq '^total 0B$'; then
    fail "$label: expected nonzero network bytes, got: $summary"
  fi
}

[ "$(uname -s)" = Linux ] || fail "Linux required"
command -v bpftrace >/dev/null 2>&1 || fail "bpftrace not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"

sudo_cmd=
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || fail "sudo not found"
  sudo -n true >/dev/null 2>&1 ||
    fail "passwordless sudo or cached sudo credentials required"
  sudo_cmd=sudo
fi

tracepoint_available() {
  $sudo_cmd test -d /sys/kernel/tracing/events/sched/sched_process_fork 2>/dev/null
}

if ! tracepoint_available; then
  $sudo_cmd mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true
fi
tracepoint_available || fail "sched_process_fork tracepoint not available"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nettotalizer-linux.XXXXXX") ||
  fail "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

cd "$repo_root" || fail "cd repo root failed"

bash -n ./nettotalizer || fail "bash syntax check failed"
ok "bash syntax"

direct_summary=$(./nettotalizer curl -sS -o /dev/null https://example.com \
  2>&1 >"$tmpdir/direct.out")
direct_rc=$?
assert_eq 0 "$direct_rc" "direct curl exit code"
assert_eq "" "$(cat "$tmpdir/direct.out")" "direct curl stdout"
assert_nonzero_net_summary "$direct_summary" "direct curl"
ok "direct curl"

child_summary=$(./nettotalizer bash -lc 'curl -sS -o /dev/null https://example.com; sleep 1' \
  2>&1 >"$tmpdir/child.out")
child_rc=$?
assert_eq 0 "$child_rc" "child curl exit code"
assert_eq "" "$(cat "$tmpdir/child.out")" "child curl stdout"
assert_nonzero_net_summary "$child_summary" "child curl"
ok "child curl"

failing_summary=$(./nettotalizer bash -lc 'exit 42' \
  2>&1 >"$tmpdir/failing.out")
failing_rc=$?
assert_eq 42 "$failing_rc" "failing command exit code"
assert_eq "" "$(cat "$tmpdir/failing.out")" "failing command stdout"
assert_summary "$failing_summary" "failing command"
ok "wrapped exit code"
