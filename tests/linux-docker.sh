#!/usr/bin/env bash
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
image=${NETTOTALIZER_TEST_IMAGE:-ubuntu:24.04}

fail() {
  echo "not ok - $*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker not found"

docker run --rm -i --privileged --pid=host \
  -v "$repo_root:/work:ro" \
  -w /work \
  "$image" \
  bash -s <<'EOF'
set -u

fail() {
  echo "not ok - $*" >&2
  exit 1
}

ok() {
  echo "ok - $*"
}

assert_eq() {
  expected=$1
  actual=$2
  label=$3

  if [ "$actual" != "$expected" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_nonzero_net_summary() {
  summary=$1
  label=$2

  printf '%s\n' "$summary" | grep -q 'net:' ||
    fail "$label: summary missing net marker: $summary"

  if printf '%s\n' "$summary" | grep -Eq 'net:.*0B.*0B'; then
    fail "$label: expected nonzero network bytes, got: $summary"
  fi
}

export DEBIAN_FRONTEND=noninteractive
apt-get update >/tmp/nettotalizer-apt-update.log ||
  fail "apt-get update failed; see /tmp/nettotalizer-apt-update.log in container"
apt-get install -y --no-install-recommends bpftrace curl ca-certificates \
  >/tmp/nettotalizer-apt-install.log ||
  fail "apt-get install failed; see /tmp/nettotalizer-apt-install.log in container"

mountpoint -q /sys/kernel/tracing ||
  mount -t tracefs tracefs /sys/kernel/tracing ||
  fail "mount tracefs failed"

bash -n ./nettotalizer || fail "bash syntax check failed"
ok "bash syntax"

direct_summary=$(./nettotalizer curl -sS -o /dev/null https://example.com \
  2>&1 >/tmp/nettotalizer-direct.stdout)
direct_rc=$?
assert_eq 0 "$direct_rc" "direct curl exit code"
assert_eq "" "$(cat /tmp/nettotalizer-direct.stdout)" "direct curl stdout"
assert_nonzero_net_summary "$direct_summary" "direct curl"
ok "direct curl"

child_summary=$(./nettotalizer bash -lc 'curl -sS -o /dev/null https://example.com; sleep 1' \
  2>&1 >/tmp/nettotalizer-child.stdout)
child_rc=$?
assert_eq 0 "$child_rc" "child curl exit code"
assert_eq "" "$(cat /tmp/nettotalizer-child.stdout)" "child curl stdout"
assert_nonzero_net_summary "$child_summary" "child curl"
ok "child curl"

failing_summary=$(./nettotalizer bash -lc 'exit 42' \
  2>&1 >/tmp/nettotalizer-failing.stdout)
failing_rc=$?
assert_eq 42 "$failing_rc" "failing command exit code"
assert_eq "" "$(cat /tmp/nettotalizer-failing.stdout)" "failing command stdout"
printf '%s\n' "$failing_summary" | grep -q 'net:' ||
  fail "failing command summary missing net marker: $failing_summary"
ok "wrapped exit code"
EOF
