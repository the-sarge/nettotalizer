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

assert_contains() {
  local needle=$1 haystack=$2 label=$3
  if ! printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
    fail "$label: expected output to contain '$needle', got '$haystack'"
  fi
}

# Keystone: the script is sourceable without running dispatch.
src_out=$( ( set --; source "$repo_root/nettotalizer" ) 2>&1 )
src_rc=$?
assert_eq 0 "$src_rc" "sourcing nettotalizer does not run dispatch"
if printf '%s\n' "$src_out" | grep -q 'Usage:'; then
  fail "sourcing nettotalizer printed usage (main guard missing)"
fi
ok "script is sourceable without running"

# Load the modules under test for everything below. Clear positional parameters
# first as defense-in-depth: the main guard already blocks sourced dispatch
# today, so this only guards against a future guard or top-level-arg change
# leaking a stray harness arg into dispatch.
set --
source "$repo_root/nettotalizer"
assert_eq "nettotalizer" "$prog" "sourcing sets prog from nettotalizer path"
ok "sourced prog name"

nounset_state=$(bash -c 'set +u; source "$1"; set -o | awk "/^nounset[[:space:]]/ { print \$2 }"' _ "$repo_root/nettotalizer")
assert_eq "off" "$nounset_state" "sourcing nettotalizer preserves caller nounset state"
ok "sourcing preserves nounset state"

direct_help_out=$("$repo_root/nettotalizer" --help 2>&1)
direct_help_rc=$?
assert_eq 64 "$direct_help_rc" "direct --help exits with usage status"
assert_contains "Usage: nettotalizer <command> [args...]" "$direct_help_out" "direct --help prints nettotalizer usage"
ok "direct help"

stdin_help_out=$(cat "$repo_root/nettotalizer" | bash -s -- --help 2>&1)
stdin_help_rc=$?
assert_eq 64 "$stdin_help_rc" "stdin --help exits with usage status"
assert_contains "Usage:" "$stdin_help_out" "stdin --help prints usage"
ok "stdin help"

# format_bytes is already pure; characterize it now that it is reachable.
assert_eq "0B"      "$(format_bytes 0)"          "format_bytes: zero"
assert_eq "1023B"   "$(format_bytes 1023)"       "format_bytes: sub-KB boundary"
assert_eq "1.0KB"   "$(format_bytes 1024)"       "format_bytes: KB boundary"
assert_eq "1.5KB"   "$(format_bytes 1536)"       "format_bytes: fractional KB"
assert_eq "1.0MB"   "$(format_bytes 1048576)"    "format_bytes: MB boundary"
assert_eq "1.00GB"  "$(format_bytes 1073741824)" "format_bytes: GB boundary"
ok "format_bytes"

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

out=$(printf '%s\n' ',bytes_in,bytes_out,' 'bash.123,100,200,' ',bytes_in,bytes_out,' 'curl.123,150,250,' | parse_nettop_samples)
assert_eq "2 150 250" "$out" "nettop samples: dedupes exec rename, keeps max"

out=$(printf '%s\n' ',bytes_in,bytes_out,' | parse_nettop_samples)
assert_eq "0 0 0" "$out" "nettop samples: header-only reports zero samples"

# A zero-byte data row is still a sample: samples=1 must differ from samples=0,
# because run_macos warns only when nothing was sampled at all.
out=$(printf '%s\n' ',bytes_in,bytes_out,' 'bash.123,0,0,' | parse_nettop_samples)
assert_eq "1 0 0" "$out" "nettop samples: zero-byte row still counts as sampled"

# Columns are discovered by header name, not position: a swapped header still maps
# rx/tx correctly.
out=$(printf '%s\n' ',bytes_out,bytes_in,' 'curl.456,400,300,' | parse_nettop_samples)
assert_eq "1 300 400" "$out" "nettop samples: maps columns by header, not position"
ok "parse_nettop_samples"

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

# When an address-family row precedes the <Link#...> row with different counters,
# the Link row must win (preserves the historical macOS selection).
macos_reordered=$(printf '%s\n' \
  'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll' \
  'en0 1500 192.168.1/24 192.168.1.5 10 0 9999 20 0 8888 0' \
  'en0 1500 <Link#5> 00:11:22:33:44:55 10 0 1000 20 0 2000 0')
out=$(printf '%s\n' "$macos_reordered" | parse_interface_bytes en0)
assert_eq "1000 2000" "$out" "interface bytes: prefers the Link row over address-family rows"

macos_utun=$(printf '%s\n' \
  'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll' \
  'utun0 1380 <Link#23> 10 0 132072 20 0 6096 0')
out=$(printf '%s\n' "$macos_utun" | parse_interface_bytes utun0)
assert_eq "132072 6096" "$out" "interface bytes: addressless macOS VPN row"

# Realistic BSD layout: packet/error/drop columns surround the byte columns, so
# the right-edge offset has to skip the trailing Opkts/Oerrs/Obytes/Coll group.
bsd=$(printf '%s\n' \
  'Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll' \
  'em0 1500 <Link#1> 00:11:22:33:44:55 100 0 0 4200 200 0 2600 0')
out=$(printf '%s\n' "$bsd" | parse_interface_bytes em0)
assert_eq "4200 2600" "$out" "interface bytes: realistic BSD layout"

out=$(printf '%s\n' "$bsd" | parse_interface_bytes wg0); rc=$?
assert_eq "" "$out" "interface bytes: absent interface yields no output"
assert_eq 1 "$rc" "interface bytes: absent interface yields nonzero status"
ok "parse_interface_bytes"

# ---------------------------------------------------------------------------
# interface_bytes / bsd_interface_bytes wrappers: not-found contracts differ
# (macOS returns "0 0"; BSD returns empty + nonzero). Stub netstat to drive them.
# ---------------------------------------------------------------------------
netstat() {
  printf '%s\n' \
    'Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll' \
    'en0 1500 <Link#5> 00:11:22:33:44:55 10 0 1000 20 0 2000 0'
}
assert_eq "1000 2000" "$(interface_bytes en0)" "interface_bytes wrapper: present interface"
assert_eq "0 0" "$(interface_bytes wg0)" "interface_bytes wrapper: absent interface -> 0 0"
unset -f netstat

netstat() {
  # Honor -I <iface> so the wrapper's argument passing is part of the contract:
  # if bsd_interface_bytes stopped passing -I "$iface", this stub emits nothing
  # and the present-interface assertion below fails.
  local want=
  while [ $# -gt 0 ]; do
    case $1 in
      -I) want=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ "$want" = em0 ] || return 0
  printf '%s\n' \
    'Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll' \
    'em0 1500 <Link#1> 00:11:22:33:44:55 100 0 0 4200 200 0 2600 0'
}
assert_eq "4200 2600" "$(bsd_interface_bytes em0)" "bsd_interface_bytes wrapper: present interface"
wrap_out=$(bsd_interface_bytes wg0); wrap_rc=$?
assert_eq "" "$wrap_out" "bsd_interface_bytes wrapper: absent interface -> empty"
assert_eq 1 "$wrap_rc" "bsd_interface_bytes wrapper: absent interface -> nonzero status"
unset -f netstat
ok "interface byte wrappers"

# ---------------------------------------------------------------------------
# clamped_delta: after-before, floored at zero (counters can reset/wrap).
# ---------------------------------------------------------------------------
assert_eq 500 "$(clamped_delta 1000 1500)" "clamped delta: normal increase"
assert_eq 0 "$(clamped_delta 1500 1000)" "clamped delta: decrease floored to zero"
assert_eq 0 "$(clamped_delta 4200 4200)" "clamped delta: no change is zero"
ok "clamped_delta"

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

# Isolate the 2x guard: delta beats process by >64KB but is not >2x -> keep.
should_use_interface_fallback 200000 350000 && r=use || r=keep
assert_eq keep "$r" "fallback: delta beats process by >64KB but not 2x -> keep process"

# Strict boundaries: the absolute 64KB floor, the +64KB margin, and the 2x guard
# all use -gt, so the threshold value itself must not trigger fallback.
should_use_interface_fallback 0 65536 && r=use || r=keep
assert_eq keep "$r" "fallback: exactly 64KB does not cross the floor"
should_use_interface_fallback 0 65537 && r=use || r=keep
assert_eq use "$r" "fallback: one byte over 64KB crosses the floor"

should_use_interface_fallback 10000 75536 && r=use || r=keep
assert_eq keep "$r" "fallback: exactly process+64KB does not cross the margin"
should_use_interface_fallback 10000 75537 && r=use || r=keep
assert_eq use "$r" "fallback: one byte over process+64KB crosses the margin"

should_use_interface_fallback 100000 200000 && r=use || r=keep
assert_eq keep "$r" "fallback: exactly 2x process rx does not cross the guard"
should_use_interface_fallback 100000 200001 && r=use || r=keep
assert_eq use "$r" "fallback: one byte over 2x process rx crosses the guard"
ok "should_use_interface_fallback"
