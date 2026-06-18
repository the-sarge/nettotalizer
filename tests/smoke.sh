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
printf '%s\n' "${NETTOTALIZER_FAKE_UNAME:-TestOS}"
EOF
chmod +x "$tmpdir/bin/uname" || fail "chmod fake uname failed"

cat >"$tmpdir/bin/id" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
  exit 0
fi

exec /usr/bin/id "$@"
EOF
chmod +x "$tmpdir/bin/id" || fail "chmod fake id failed"

NETTOTALIZER_FAKE_UNAME=TestOS PATH="$tmpdir/bin:$PATH" ./nettotalizer bash -c 'exit 42' \
  >"$tmpdir/exit.out" 2>"$tmpdir/exit.err"
rc=$?
assert_eq 42 "$rc" "wrapped exit code"
grep -q 'unsupported platform TestOS' "$tmpdir/exit.err" ||
  fail "unsupported platform warning missing"
ok "wrapped exit code"

NETTOTALIZER_FAKE_UNAME=TestOS PATH="$tmpdir/bin:$PATH" ./nettotalizer sh -c 'printf "%s\n" hello' \
  >"$tmpdir/stdout.out" 2>"$tmpdir/stdout.err"
rc=$?
assert_eq 0 "$rc" "stdout preservation exit code"
assert_eq hello "$(cat "$tmpdir/stdout.out")" "stdout preservation"
ok "stdout preservation"

cat >"$tmpdir/bin/bpftrace" <<'EOF'
#!/usr/bin/env sh
case "${NETTOTALIZER_FAKE_BPFTRACE_MODE:-ready}" in
  ready)
    : >"${NETTOTALIZER_FAKE_READY_FILE:?}"
    printf 'NETTOTALIZER_READY\n'
    sleep 0.1
    printf 'NETTOTALIZER_RX 2048\n'
    printf 'NETTOTALIZER_TX 512\n'
    ;;
  fail-before-ready)
    exit 7
    ;;
  *)
    printf 'unexpected fake bpftrace mode: %s\n' "$NETTOTALIZER_FAKE_BPFTRACE_MODE" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmpdir/bin/bpftrace" || fail "chmod fake bpftrace failed"

ready_file="$tmpdir/bpftrace-ready"
NETTOTALIZER_FAKE_UNAME=Linux \
  NETTOTALIZER_FAKE_BPFTRACE_MODE=ready \
  NETTOTALIZER_FAKE_READY_FILE="$ready_file" \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'test -f "$1" || exit 66; printf "%s\n" linux-ready' sh "$ready_file" \
  >"$tmpdir/linux-ready.out" 2>"$tmpdir/linux-ready.err"
rc=$?
assert_eq 0 "$rc" "Linux ready-gated exit code"
assert_eq linux-ready "$(cat "$tmpdir/linux-ready.out")" "Linux ready-gated stdout"
tail -n 3 "$tmpdir/linux-ready.err" | grep -q '^total 2.5KB$' ||
  fail "Linux ready-gated total summary mismatch"
tail -n 3 "$tmpdir/linux-ready.err" | grep -q '^received 2.0KB$' ||
  fail "Linux ready-gated received summary mismatch"
tail -n 3 "$tmpdir/linux-ready.err" | grep -q '^sent 512B$' ||
  fail "Linux ready-gated sent summary mismatch"
ok "Linux command waits for tracer readiness"

NETTOTALIZER_FAKE_UNAME=Linux \
  NETTOTALIZER_FAKE_BPFTRACE_MODE=fail-before-ready \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'printf "%s\n" linux-unmeasured; exit 42' \
  >"$tmpdir/linux-fail.out" 2>"$tmpdir/linux-fail.err"
rc=$?
assert_eq 42 "$rc" "Linux failed tracer preserves exit code"
assert_eq linux-unmeasured "$(cat "$tmpdir/linux-fail.out")" "Linux failed tracer stdout"
grep -q 'bpftrace exited before command start; running unmeasured' "$tmpdir/linux-fail.err" ||
  fail "Linux failed tracer warning missing"
if tail -n 3 "$tmpdir/linux-fail.err" | grep -Eq '^(total|received|sent) '; then
  fail "Linux failed tracer should not print a measured summary"
fi
ok "Linux tracer failure runs unmeasured"

cat >"$tmpdir/bin/route" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  "-n get default")
    printf '   interface: em0\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmpdir/bin/route" || fail "chmod fake route failed"

cat >"$tmpdir/bin/netstat" <<EOF
#!/usr/bin/env sh
state='$tmpdir/netstat-state'
count=\$(cat "\$state" 2>/dev/null || printf '0')
count=\$((count + 1))
printf '%s\n' "\$count" >"\$state"

if [ "\$count" -eq 1 ]; then
  rx=1000
  tx=2000
else
  rx=4200
  tx=2600
fi

cat <<NETSTAT
Name Mtu Network Address Ibytes Obytes
em0 1500 <Link#1> 00:11:22:33:44:55 \$rx \$tx
NETSTAT
EOF
chmod +x "$tmpdir/bin/netstat" || fail "chmod fake netstat failed"

for os in FreeBSD NetBSD OpenBSD; do
  rm -f "$tmpdir/netstat-state"
  NETTOTALIZER_FAKE_UNAME=$os PATH="$tmpdir/bin:$PATH" \
    ./nettotalizer sh -c 'printf "%s\n" bsd' \
    >"$tmpdir/bsd.out" 2>"$tmpdir/bsd.err"
  rc=$?
  assert_eq 0 "$rc" "$os exit code"
  assert_eq bsd "$(cat "$tmpdir/bsd.out")" "$os stdout preservation"
  grep -q 'BSD backend uses em0 interface delta estimate' "$tmpdir/bsd.err" ||
    fail "$os estimate warning missing"
  tail -n 3 "$tmpdir/bsd.err" | grep -q '^total 3.7KB$' ||
    fail "$os total summary mismatch"
  tail -n 3 "$tmpdir/bsd.err" | grep -q '^received 3.1KB$' ||
    fail "$os received summary mismatch"
  tail -n 3 "$tmpdir/bsd.err" | grep -q '^sent 600B$' ||
    fail "$os sent summary mismatch"
  ok "$os interface delta"
done
