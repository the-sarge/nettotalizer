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

cat >"$tmpdir/bin/mkfifo" <<'EOF'
#!/usr/bin/env sh
if [ "${NETTOTALIZER_FAKE_MKFIFO_FAIL:-0}" = 1 ]; then
  exit 1
fi

PATH=/usr/bin:/bin:/usr/sbin:/sbin exec mkfifo "$@"
EOF
chmod +x "$tmpdir/bin/mkfifo" || fail "chmod fake mkfifo failed"

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
  slow-ready)
    printf '%s\n' "$$" >"${NETTOTALIZER_FAKE_TRACER_PID_FILE:?}"
    trap 'exit 0' INT TERM
    while :; do
      sleep 0.1
    done
    printf 'NETTOTALIZER_READY\n'
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

assert_pre_ready_signal_cleanup() {
  local signal=$1
  local expected_status=$2
  local tracer_pid_file wrapper_pid children rc pid timeout_file watchdog_pid

  tracer_pid_file="$tmpdir/slow-tracer-$signal.pid"
  timeout_file="$tmpdir/slow-wrapper-$signal.timeout"
  rm -f "$tracer_pid_file"
  rm -f "$timeout_file"

  command -v perl >/dev/null 2>&1 ||
    fail "perl not found for signal-disposition smoke helper"

  # Bash starts background jobs with SIGINT ignored. Reset it before execing the
  # wrapper so this probe exercises nettotalizer's INT trap.
  NETTOTALIZER_FAKE_UNAME=Linux \
    NETTOTALIZER_FAKE_BPFTRACE_MODE=slow-ready \
    NETTOTALIZER_FAKE_TRACER_PID_FILE="$tracer_pid_file" \
    PATH="$tmpdir/bin:$PATH" \
    perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV; die "exec failed: $!\n"' \
      ./nettotalizer sh -c 'sleep 30' \
    >"$tmpdir/linux-$signal.out" 2>"$tmpdir/linux-$signal.err" &
  wrapper_pid=$!

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$tracer_pid_file" ] && break
    sleep 0.1
  done
  [ -s "$tracer_pid_file" ] || fail "slow tracer did not start for $signal"

  children=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    children=$(pgrep -P "$wrapper_pid" 2>/dev/null || true)
    [ "$(printf '%s\n' "$children" | sed '/^$/d' | wc -l | tr -d ' ')" -ge 2 ] && break
    sleep 0.1
  done

  kill "-$signal" "$wrapper_pid" 2>/dev/null || true
  (
    sleep 5
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      : >"$timeout_file"
      kill -TERM "$wrapper_pid" 2>/dev/null || true
      sleep 0.5
      kill -KILL "$wrapper_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!
  wait "$wrapper_pid"
  rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  [ ! -e "$timeout_file" ] || fail "pre-ready $signal wrapper did not exit"
  assert_eq "$expected_status" "$rc" "pre-ready $signal exit code"

  for pid in $children "$(cat "$tracer_pid_file")"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      fail "pre-ready $signal leaked process $pid"
    fi
  done
  ok "Linux pre-ready $signal cleans up tracer and gated command"
}

assert_pre_ready_signal_cleanup INT 130
assert_pre_ready_signal_cleanup TERM 143

cat >"$tmpdir/bin/nettop" <<'EOF'
#!/usr/bin/env sh
case "${NETTOTALIZER_FAKE_NETTOP_MODE:-ready}" in
  fail)
    exit 5
    ;;
  ready)
    printf ',bytes_in,bytes_out,\n'
    printf 'bash.%s,0,0,\n' "$$"
    ;;
  ready-after-pre-release-traffic)
    : >"${NETTOTALIZER_FAKE_PRE_READY_TRAFFIC_FILE:?}"
    printf ',bytes_in,bytes_out,\n'
    printf 'bash.%s,0,0,\n' "$$"
    ;;
  slow-ready)
    printf '%s\n' "$$" >"${NETTOTALIZER_FAKE_NETTOP_PID_FILE:?}"
    trap 'exit 0' HUP INT TERM
    while :; do
      sleep 0.1
    done
    ;;
  *)
    printf 'unexpected fake nettop mode: %s\n' "$NETTOTALIZER_FAKE_NETTOP_MODE" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmpdir/bin/nettop" || fail "chmod fake nettop failed"

assert_macos_pre_ready_signal_cleanup() {
  local signal=$1
  local expected_status=$2
  local nettop_pid_file wrapper_pid rc timeout_file watchdog_pid pid

  nettop_pid_file="$tmpdir/slow-nettop-$signal.pid"
  timeout_file="$tmpdir/slow-macos-wrapper-$signal.timeout"
  rm -f "$nettop_pid_file"
  rm -f "$timeout_file"

  command -v perl >/dev/null 2>&1 ||
    fail "perl not found for signal-disposition smoke helper"

  # Bash starts background jobs with SIGINT ignored. Reset it before execing the
  # wrapper so this probe exercises nettotalizer's INT trap.
  NETTOTALIZER_FAKE_UNAME=Darwin \
    NETTOTALIZER_FAKE_NETTOP_MODE=slow-ready \
    NETTOTALIZER_FAKE_NETTOP_PID_FILE="$nettop_pid_file" \
    PATH="$tmpdir/bin:$PATH" \
    perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV; die "exec failed: $!\n"' \
      ./nettotalizer sh -c 'sleep 30' \
    >"$tmpdir/macos-$signal.out" 2>"$tmpdir/macos-$signal.err" &
  wrapper_pid=$!

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$nettop_pid_file" ] && break
    sleep 0.1
  done
  [ -s "$nettop_pid_file" ] || fail "slow nettop did not start for $signal"

  kill "-$signal" "$wrapper_pid" 2>/dev/null || true
  (
    sleep 5
    if kill -0 "$wrapper_pid" 2>/dev/null; then
      : >"$timeout_file"
      kill -TERM "$wrapper_pid" 2>/dev/null || true
      sleep 0.5
      kill -KILL "$wrapper_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!
  wait "$wrapper_pid"
  rc=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  [ ! -e "$timeout_file" ] || fail "macOS pre-ready $signal wrapper did not exit"
  assert_eq "$expected_status" "$rc" "macOS pre-ready $signal exit code"

  pid=$(cat "$nettop_pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "macOS pre-ready $signal leaked nettop process $pid"
  fi

  ok "macOS pre-ready $signal cleans up active nettop"
}

assert_macos_pre_ready_signal_cleanup INT 130
assert_macos_pre_ready_signal_cleanup TERM 143

NETTOTALIZER_FAKE_UNAME=Darwin \
  NETTOTALIZER_FAKE_NETTOP_MODE=fail \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'printf "%s\n" macos-unmeasured; exit 37' \
  >"$tmpdir/macos-fail.out" 2>"$tmpdir/macos-fail.err"
rc=$?
assert_eq 37 "$rc" "macOS failed sampler preserves exit code"
assert_eq macos-unmeasured "$(cat "$tmpdir/macos-fail.out")" "macOS failed sampler stdout"
grep -q 'macOS sampler exited before command start; running unmeasured' "$tmpdir/macos-fail.err" ||
  fail "macOS failed sampler warning missing"
if tail -n 3 "$tmpdir/macos-fail.err" | grep -Eq '^(total|received|sent) '; then
  fail "macOS failed sampler should not print a measured summary"
fi
ok "macOS sampler failure runs unmeasured"

leak_tmpdir="$tmpdir/leak-tmp"
mkdir -p "$leak_tmpdir" || fail "mkdir leak tmpdir failed"
NETTOTALIZER_FAKE_UNAME=Darwin \
  NETTOTALIZER_FAKE_MKFIFO_FAIL=1 \
  TMPDIR="$leak_tmpdir" \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'printf "%s\n" fifo-fallback; exit 33' \
  >"$tmpdir/fifo-fallback.out" 2>"$tmpdir/fifo-fallback.err"
rc=$?
assert_eq 33 "$rc" "mkfifo fallback preserves exit code"
assert_eq fifo-fallback "$(cat "$tmpdir/fifo-fallback.out")" "mkfifo fallback stdout"
grep -q 'mkfifo failed; running unmeasured' "$tmpdir/fifo-fallback.err" ||
  fail "mkfifo fallback warning missing"
if tail -n 3 "$tmpdir/fifo-fallback.err" | grep -Eq '^(total|received|sent) '; then
  fail "mkfifo fallback should not print a measured summary"
fi
if find "$leak_tmpdir" -name 'nettotalizer.*' -print -quit | grep -q .; then
  fail "mkfifo fallback leaked nettotalizer temp files"
fi
ok "lifecycle init fallback cleans up temp files"

cat >"$tmpdir/bin/route" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  "-n get default")
    printf '   interface: %s\n' "${NETTOTALIZER_FAKE_ROUTE_IFACE:-em0}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmpdir/bin/route" || fail "chmod fake route failed"

cat >"$tmpdir/bin/netstat" <<'EOF'
#!/usr/bin/env sh
if [ -e "${NETTOTALIZER_FAKE_PRE_READY_TRAFFIC_FILE:?}" ]; then
  rx=201000
  tx=302000
else
  rx=1000
  tx=2000
fi

cat <<NETSTAT
Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
em0 1500 <Link#1> 00:11:22:33:44:55 10 0 $rx 20 0 $tx 0
NETSTAT
EOF
chmod +x "$tmpdir/bin/netstat" || fail "chmod fake macOS netstat failed"

pre_ready_traffic_file="$tmpdir/macos-pre-ready-traffic"
rm -f "$pre_ready_traffic_file"
NETTOTALIZER_FAKE_UNAME=Darwin \
  NETTOTALIZER_FAKE_NETTOP_MODE=ready-after-pre-release-traffic \
  NETTOTALIZER_FAKE_PRE_READY_TRAFFIC_FILE="$pre_ready_traffic_file" \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'printf "%s\n" macos-no-network' \
  >"$tmpdir/macos-pre-ready.out" 2>"$tmpdir/macos-pre-ready.err"
rc=$?
assert_eq 0 "$rc" "macOS pre-ready interface traffic exit code"
assert_eq macos-no-network "$(cat "$tmpdir/macos-pre-ready.out")" \
  "macOS pre-ready interface traffic stdout"
[ -e "$pre_ready_traffic_file" ] ||
  fail "macOS fake sampler did not simulate pre-release interface traffic"
if grep -q 'process samples undercounted received bytes' "$tmpdir/macos-pre-ready.err"; then
  fail "macOS fallback included pre-release interface traffic"
fi
tail -n 3 "$tmpdir/macos-pre-ready.err" | grep -q '^total 0B$' ||
  fail "macOS pre-ready interface traffic total summary mismatch"
tail -n 3 "$tmpdir/macos-pre-ready.err" | grep -q '^received 0B$' ||
  fail "macOS pre-ready interface traffic received summary mismatch"
tail -n 3 "$tmpdir/macos-pre-ready.err" | grep -q '^sent 0B$' ||
  fail "macOS pre-ready interface traffic sent summary mismatch"
ok "macOS fallback ignores pre-release interface traffic"

cat >"$tmpdir/bin/netstat" <<EOF
#!/usr/bin/env sh
state='$tmpdir/macos-utun-netstat-state'
count=\$(cat "\$state" 2>/dev/null || printf '0')
count=\$((count + 1))
printf '%s\n' "\$count" >"\$state"

if [ "\$count" -eq 1 ]; then
  rx=1000
  tx=2000
else
  rx=132072
  tx=6096
fi

cat <<NETSTAT
Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
utun0 1380 <Link#23> 10 0 \$rx 20 0 \$tx 0
NETSTAT
EOF
chmod +x "$tmpdir/bin/netstat" || fail "chmod fake macOS utun netstat failed"

rm -f "$tmpdir/macos-utun-netstat-state"
NETTOTALIZER_FAKE_UNAME=Darwin \
  NETTOTALIZER_FAKE_ROUTE_IFACE=utun0 \
  NETTOTALIZER_FAKE_NETTOP_MODE=ready \
  PATH="$tmpdir/bin:$PATH" \
  ./nettotalizer sh -c 'printf "%s\n" macos-utun-fallback' \
  >"$tmpdir/macos-utun.out" 2>"$tmpdir/macos-utun.err"
rc=$?
assert_eq 0 "$rc" "macOS addressless interface fallback exit code"
assert_eq macos-utun-fallback "$(cat "$tmpdir/macos-utun.out")" \
  "macOS addressless interface fallback stdout"
grep -q 'process samples undercounted received bytes; using utun0 interface delta' \
  "$tmpdir/macos-utun.err" ||
  fail "macOS addressless interface fallback warning missing"
tail -n 3 "$tmpdir/macos-utun.err" | grep -q '^total 132.0KB$' ||
  fail "macOS addressless interface fallback total summary mismatch"
tail -n 3 "$tmpdir/macos-utun.err" | grep -q '^received 128.0KB$' ||
  fail "macOS addressless interface fallback received summary mismatch"
tail -n 3 "$tmpdir/macos-utun.err" | grep -q '^sent 4.0KB$' ||
  fail "macOS addressless interface fallback sent summary mismatch"
ok "macOS fallback parses addressless interface byte columns"

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
