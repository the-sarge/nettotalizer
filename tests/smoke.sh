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
