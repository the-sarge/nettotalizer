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

[ "$(uname -s)" = Darwin ] || fail "macOS required"
command -v nettop >/dev/null 2>&1 || fail "nettop not found"
command -v curl >/dev/null 2>&1 || fail "curl not found"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nettotalizer-macos.XXXXXX") ||
  fail "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

cd "$repo_root" || fail "cd repo root failed"

bash -n ./nettotalizer || fail "bash syntax check failed"
ok "bash syntax"

direct_summary=$(./nettotalizer curl -sS -o /dev/null https://example.com \
  2>"$tmpdir/direct.err" >"$tmpdir/direct.out")
direct_rc=$?
assert_eq 0 "$direct_rc" "direct curl exit code"
assert_eq "" "$(cat "$tmpdir/direct.out")" "direct curl stdout"
direct_summary=$(tail -n 3 "$tmpdir/direct.err")
assert_summary "$direct_summary" "direct curl"
ok "direct curl"

failing_summary=$(./nettotalizer bash -lc 'exit 42' \
  2>"$tmpdir/failing.err" >"$tmpdir/failing.out")
failing_rc=$?
assert_eq 42 "$failing_rc" "failing command exit code"
assert_eq "" "$(cat "$tmpdir/failing.out")" "failing command stdout"
failing_summary=$(tail -n 3 "$tmpdir/failing.err")
assert_summary "$failing_summary" "failing command"
ok "wrapped exit code"
