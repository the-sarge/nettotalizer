#!/usr/bin/env bash
# =============================================================================
# nettotalizer — wrap a command and report the network bytes it transferred.
# -----------------------------------------------------------------------------
# Usage:    nettotalizer <command> [args...]
# Example:  nettotalizer curl -sO https://example.com/file.tar.gz
#
# Platforms:
#   macOS  — uses `nettop -p PID`. No privileges required.
#   Linux  — uses `bpftrace` with kprobes on tcp/udp send/recv. Requires
#            root (will re-exec under sudo if available).
#
# Output goes to stderr in the same style as the precmd status hook:
#   [net:     ↓1.2MB ↑45KB]
#
# The wrapped command's stdout, stderr, stdin, and exit code are passed
# through unchanged.
#
# Known limitations (read these before trusting the numbers):
#
#   * On macOS, nettop is per-PID and does NOT follow children. If your
#     command forks helpers that do the actual networking (e.g. `git push`
#     spawning `ssh`, browsers spawning render processes), their traffic
#     is missed. For curl/wget/most HTTP clients this is fine.
#
#   * On Linux, the bpftrace script DOES follow fork() and tracks
#     descendants, but only instruments tcp_sendmsg / tcp_recvmsg /
#     udp_sendmsg / udp_recvmsg. Raw sockets, AF_PACKET, and similarly
#     exotic transports are not counted. QUIC-over-UDP works fine.
#
#   * The command is launched in the background so we can capture its PID
#     before starting the monitor. That detaches it from the controlling
#     TTY, so interactive programs (vim, less, ssh login shells) won't
#     work correctly. This tool is aimed at non-interactive network
#     commands; if you need to wrap an interactive one, look into pty
#     wrappers like `script(1)` or `expect`.
#
#   * Short commands (< ~100ms) may finish before the monitor attaches.
#     bpftrace has a small startup latency (BPF program compile + load),
#     and nettop's first sample takes one sample interval. Numbers for
#     very fast commands are approximate.
# =============================================================================

set -u

# -----------------------------------------------------------------------------
# Usage / arg check
# -----------------------------------------------------------------------------
usage() {
  sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//;$d' >&2
  exit 64
}

case "${1:-}" in
  ""|-h|--help) usage ;;
esac

# -----------------------------------------------------------------------------
# format_bytes — render an integer byte count as human-readable text,
# matching the format used by the precmd hook so output is consistent.
#
#   < 1 KB     "873B"
#   < 1 MB     "12.4KB"
#   < 1 GB     "5.2MB"
#   >= 1 GB    "1.34GB"
#
# Uses awk for the float math because bash 3.2 (the version shipped on
# macOS) has no native floating point. awk handles it cleanly and is on
# every system we care about.
# -----------------------------------------------------------------------------
format_bytes() {
  local b=$1
  if   [ "$b" -lt 1024 ];        then printf '%dB' "$b"
  elif [ "$b" -lt 1048576 ];     then awk -v x="$b" 'BEGIN{printf "%.1fKB", x/1024}'
  elif [ "$b" -lt 1073741824 ];  then awk -v x="$b" 'BEGIN{printf "%.1fMB", x/1048576}'
  else                                awk -v x="$b" 'BEGIN{printf "%.2fGB", x/1073741824}'
  fi
}

# -----------------------------------------------------------------------------
# print_summary — emit the [net: ↓RX ↑TX] line on stderr in the same ANSI
# style as the precmd status block (label dim, value bright, default fg).
# Stderr because the wrapped command may be piping its stdout somewhere.
# -----------------------------------------------------------------------------
print_summary() {
  local rx=$1 tx=$2
  printf '\033[39m[\033[2mnet:\033[22m     ↓%s ↑%s]\033[0m\n' \
    "$(format_bytes "$rx")" "$(format_bytes "$tx")" >&2
}

# =============================================================================
# macOS implementation: nettop
# -----------------------------------------------------------------------------
# Strategy:
#   1. Background the wrapped command, capture its PID.
#   2. Start nettop in plain-text print mode tracking that PID, writing
#      cumulative byte counts to a temp file at a 0.5s sample interval.
#   3. Forward SIGINT/SIGTERM so Ctrl+C kills the wrapped command, not
#      the wrapper.
#   4. Wait for the command to exit, capture its exit code.
#   5. Pause briefly so nettop catches one final sample, then kill it.
#   6. Parse the temp file: scan all data lines, take the maximum
#      bytes_in / bytes_out values seen (counters are monotonic, so the
#      last good reading is the largest).
# =============================================================================
run_macos() {
  if ! command -v nettop >/dev/null 2>&1; then
    echo "nettotalizer: nettop not found on PATH" >&2
    exec "$@"
  fi

  local nt_out
  nt_out=$(mktemp -t nettotalizer) || { echo "nettotalizer: mktemp failed" >&2; exec "$@"; }
  trap 'rm -f "$nt_out"' EXIT

  # Background the command. Stdin redirection from /dev/tty if available
  # gives interactive-ish commands a fighting chance — they still won't
  # have proper job control, but at least keystrokes flow through.
  if [ -t 0 ]; then
    "$@" </dev/tty &
  else
    "$@" &
  fi
  local cmd_pid=$!

  # Start nettop:
  #   -P             plain-text print mode (no curses)
  #   -x             non-interactive, suppress repainting
  #   -s 0.5         sample every 500ms
  #   -p PID         track only this process
  #   -J bytes_in,bytes_out
  #                  output only the columns we need (reduces parsing
  #                  noise; nettop still emits a time column too)
  # Stderr is muted; nettop chatters about exiting cleanly otherwise.
  nettop -P -x -s 0.5 -p "$cmd_pid" -J bytes_in,bytes_out \
    >"$nt_out" 2>/dev/null &
  local nt_pid=$!

  # Forward signals so the user's Ctrl+C reaches the wrapped command.
  # We don't trap on the wrapper itself — let the signal kill us
  # naturally after we've forwarded it.
  trap 'kill -INT  "$cmd_pid" 2>/dev/null' INT
  trap 'kill -TERM "$cmd_pid" 2>/dev/null' TERM

  wait "$cmd_pid"
  local exit_code=$?

  # Give nettop one more sample interval to capture final bytes before
  # the kernel reaps the process and nettop loses sight of it.
  sleep 0.6
  kill "$nt_pid" 2>/dev/null
  wait "$nt_pid" 2>/dev/null

  # Parse: counters in nettop are cumulative, so the maximum value seen
  # for each direction is what we want. We split on commas and pull the
  # two numeric columns. The exact column positions vary by macOS
  # version — this scan-for-maxima approach is robust to that.
  local rx=0 tx=0
  if [ -s "$nt_out" ]; then
    read -r rx tx <<EOF
$(awk -F',' '
  # Skip blank lines and any line containing a non-numeric "bytes" header.
  /bytes_in|bytes_out/ { next }
  NF < 2              { next }
  {
    # Walk all fields, treat any pair of large integers as candidates.
    # The last two numeric fields on a data line are bytes_in, bytes_out.
    n_in = 0; n_out = 0
    for (i = NF; i >= 1; i--) {
      if ($i ~ /^[0-9]+$/) {
        if (n_out == 0)      { n_out = $i + 0 }
        else if (n_in == 0)  { n_in  = $i + 0; break }
      }
    }
    if (n_in  > max_in)  max_in  = n_in
    if (n_out > max_out) max_out = n_out
  }
  END { printf "%d %d\n", max_in+0, max_out+0 }
' "$nt_out")
EOF
  fi

  print_summary "${rx:-0}" "${tx:-0}"
  exit "$exit_code"
}

# =============================================================================
# Linux implementation: bpftrace
# -----------------------------------------------------------------------------
# Strategy:
#   1. If not root, re-exec under sudo (kprobes need CAP_SYS_ADMIN/CAP_BPF).
#   2. Background the wrapped command, capture its PID.
#   3. Run bpftrace with -p PID (auto-terminate when the PID dies) and
#      pass the PID as the script's $1 positional argument.
#   4. Inside the script: hook sched_process_fork to maintain a map of
#      descendants, then sum send/recv bytes for any tracked PID.
#   5. END block prints "nettotalizer_RX <n>\nnettotalizer_TX <n>" so the
#      shell can grep it out cleanly.
# =============================================================================
run_linux() {
  if ! command -v bpftrace >/dev/null 2>&1; then
    echo "nettotalizer: bpftrace not found (apt/dnf install bpftrace)" >&2
    exec "$@"
  fi

  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      # --preserve-env=PATH so user-installed bpftrace under ~/.local/bin
      # still resolves; everything else stays sanitized for safety.
      exec sudo --preserve-env=PATH "$0" "$@"
    fi
    echo "nettotalizer: bpftrace requires root on Linux (sudo not available)" >&2
    exec "$@"
  fi

  # The bpftrace program. $1 is the target PID, passed positionally below.
  #
  # Tracking model:
  #   @kids[pid] — set of PIDs we consider "ours". We seed it via the
  #                fork tracepoint when a tracked parent forks; the
  #                target PID itself is matched directly by `pid == $1`
  #                rather than added to the map (keeps init simple).
  #
  #   @rx / @tx — running totals. kretprobe variants give us the actual
  #                bytes transferred (retval), not just what was requested.
  local bt_script='
tracepoint:sched:sched_process_fork
/args->parent_pid == $1 || @kids[args->parent_pid]/
{
  @kids[args->child_pid] = 1;
}

kretprobe:tcp_sendmsg /retval > 0 && (pid == $1 || @kids[pid])/
{
  @tx += retval;
}

kretprobe:tcp_recvmsg /retval > 0 && (pid == $1 || @kids[pid])/
{
  @rx += retval;
}

kretprobe:udp_sendmsg /retval > 0 && (pid == $1 || @kids[pid])/
{
  @tx += retval;
}

kretprobe:udp_recvmsg /retval > 0 && (pid == $1 || @kids[pid])/
{
  @rx += retval;
}

END {
  printf("nettotalizer_RX %lu\n", @rx);
  printf("nettotalizer_TX %lu\n", @tx);
  clear(@kids); clear(@rx); clear(@tx);
}
'

  local bt_out
  bt_out=$(mktemp -t nettotalizer.XXXXXX) || { echo "nettotalizer: mktemp failed" >&2; exec "$@"; }
  trap 'rm -f "$bt_out"' EXIT

  # Background the command before bpftrace attaches. There's a small
  # window here where early network I/O could be missed — typically
  # tens of ms while bpftrace compiles and loads its program. For most
  # network commands the actual transfer happens after DNS/TCP setup,
  # well past this window.
  if [ -t 0 ]; then
    "$@" </dev/tty &
  else
    "$@" &
  fi
  local cmd_pid=$!

  # bpftrace -p auto-exits when the PID dies; positional arg becomes $1
  # in the script. Output goes to bt_out; errors are kept on stderr.
  bpftrace -q -e "$bt_script" -p "$cmd_pid" "$cmd_pid" >"$bt_out" &
  local bt_pid=$!

  trap 'kill -INT  "$cmd_pid" 2>/dev/null' INT
  trap 'kill -TERM "$cmd_pid" 2>/dev/null' TERM

  wait "$cmd_pid"
  local exit_code=$?
  wait "$bt_pid" 2>/dev/null

  local rx tx
  rx=$(awk '/^nettotalizer_RX/ {print $2; exit}' "$bt_out")
  tx=$(awk '/^nettotalizer_TX/ {print $2; exit}' "$bt_out")

  print_summary "${rx:-0}" "${tx:-0}"
  exit "$exit_code"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) run_macos "$@" ;;
  Linux)  run_linux "$@" ;;
  *)
    echo "nettotalizer: unsupported platform $(uname -s); running command unmeasured" >&2
    exec "$@"
    ;;
esac
