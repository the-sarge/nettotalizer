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
