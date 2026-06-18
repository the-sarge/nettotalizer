#!/usr/bin/env bash
# Unit tests for the pure tool-output parsers.
#
# These tests source `nettotalizer` so they can call its parser functions
# directly with canned fixtures, instead of running the live nettop/bpftrace/
# netstat tools. That is only possible because the script guards its top-level
# dispatch behind a BASH_SOURCE check, so sourcing defines functions without
# running anything.
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

cd "$repo_root" || fail "cd repo root failed"

# Sourcing must define the parser functions WITHOUT executing the platform
# dispatch (which would otherwise call usage/exec and terminate this test).
# shellcheck disable=SC1091
source ./nettotalizer
ok "source without executing dispatch"

# parse_nettop_csv keys rows by PID, keeps the max cumulative counter per PID,
# sums across PIDs, and emits "samples rx tx".
nettop_fixture=$(
  cat <<'CSV'
,bytes_in,bytes_out,
curl.4567,1000,200,
curl.4567,1500,250,
helper.4568,400,50,
CSV
)
assert_eq "3 1900 300" \
  "$(printf '%s\n' "$nettop_fixture" | parse_nettop_csv)" \
  "parse_nettop_csv sums max-per-PID counters"
ok "parse_nettop_csv"

# parse_bpftrace_output reads the RX/TX marker lines and emits "rx tx".
bpftrace_fixture=$(
  cat <<'BT'
NETTOTALIZER_READY
NETTOTALIZER_RX 5300
NETTOTALIZER_TX 831
BT
)
assert_eq "5300 831" \
  "$(printf '%s\n' "$bpftrace_fixture" | parse_bpftrace_output)" \
  "parse_bpftrace_output reads marker lines"
ok "parse_bpftrace_output"

# parse_interface_bytes selects the <Link#...> row for the given interface from
# macOS `netstat -ibn` output and emits "rx tx" (Ibytes Obytes).
netstat_macos_fixture=$(
  cat <<'NS'
Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
en0   1500  <Link#11>     a4:83:e7:00:00:00    100     0       5300       80     0        831     0
en0   1500  192.168.1/24  192.168.1.5          100     0       5300       80     0        831     0
NS
)
assert_eq "5300 831" \
  "$(printf '%s\n' "$netstat_macos_fixture" | parse_interface_bytes en0)" \
  "parse_interface_bytes picks the Link row"
ok "parse_interface_bytes"

# parse_bsd_interface_bytes discovers the Ibytes/Obytes columns from the header
# and emits "rx tx" for the named interface.
netstat_bsd_fixture=$(
  cat <<'NS'
Name Mtu Network Address Ibytes Obytes
em0 1500 <Link#1> 00:11:22:33:44:55 4200 2600
NS
)
assert_eq "4200 2600" \
  "$(printf '%s\n' "$netstat_bsd_fixture" | parse_bsd_interface_bytes em0)" \
  "parse_bsd_interface_bytes reads header columns"
ok "parse_bsd_interface_bytes"

echo "ok - all parser tests passed"
