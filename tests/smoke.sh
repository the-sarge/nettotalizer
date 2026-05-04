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

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/nettotalizer-smoke.XXXXXX") ||
  fail "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

cd "$repo_root" || fail "cd repo root failed"

bash -n ./nettotalizer || fail "bash syntax check failed"
ok "bash syntax"

./nettotalizer --help >"$tmpdir/help.out" 2>&1
rc=$?
assert_eq 64 "$rc" "help exit code"
grep -q 'Usage: nettotalizer <command> \[args...\]' "$tmpdir/help.out" ||
  fail "help output missing usage"
ok "help output"

mkdir -p "$tmpdir/bin" || fail "mkdir failed"
cat >"$tmpdir/bin/uname" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
  -s) printf '%s\n' TestOS ;;
  *) printf '%s\n' TestOS ;;
esac
EOF
chmod +x "$tmpdir/bin/uname" || fail "chmod fake uname failed"

PATH="$tmpdir/bin:$PATH" ./nettotalizer bash -c 'exit 42' \
  >"$tmpdir/exit.out" 2>"$tmpdir/exit.err"
rc=$?
assert_eq 42 "$rc" "wrapped exit code"
grep -q 'unsupported platform TestOS' "$tmpdir/exit.err" ||
  fail "unsupported platform warning missing"
ok "wrapped exit code"

PATH="$tmpdir/bin:$PATH" ./nettotalizer sh -c 'printf "%s\n" hello' \
  >"$tmpdir/stdout.out" 2>"$tmpdir/stdout.err"
rc=$?
assert_eq 0 "$rc" "stdout preservation exit code"
assert_eq hello "$(cat "$tmpdir/stdout.out")" "stdout preservation"
ok "stdout preservation"
