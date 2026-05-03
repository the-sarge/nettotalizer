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
#            root for bpftrace; will prompt for sudo if needed. The
#            wrapped command itself runs unprivileged.
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
#     descendants, but only instruments the standard tcp/udp (v4 and v6)
#     send/recv kernel paths. Raw sockets, AF_PACKET, and similarly
#     exotic transports are not counted. QUIC-over-UDP works fine.
#
#   * The command is launched in the background so we can capture its PID
#     before starting the monitor. That detaches it from the controlling
#     TTY, so interactive programs (vim, less, ssh login shells) won't
#     work correctly. This tool is aimed at non-interactive network
#     commands; if you need to wrap an interactive one, look into pty
#     wrappers like `script(1)` or `expect`.
#
#   * Short commands (< ~1s on macOS, < ~100ms on Linux) may finish
#     before the monitor sees them. macOS nettop's `-s` flag only accepts
#     integer seconds, so the minimum sample interval is 1s. Numbers for
#     very fast commands are approximate or zero.
# =============================================================================

set -u

prog=${0##*/}

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
# format_bytes — render an integer byte count as human-readable text.
# Uses awk for the float math because bash 3.2 (the version shipped on
# macOS) has no native floating point.
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
# style as the precmd status block. Stderr because the wrapped command
# may be piping its stdout somewhere.
# -----------------------------------------------------------------------------
print_summary() {
  local rx=${1:-0} tx=${2:-0}
  printf '\033[39m[\033[2mnet:\033[22m     ↓%s ↑%s]\033[0m\n' \
    "$(format_bytes "$rx")" "$(format_bytes "$tx")" >&2
}

# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
tmpfile() {
  mktemp "${TMPDIR:-/tmp}/nettotalizer.XXXXXX"
}

# Background the wrapped command. Stdin redirection from /dev/tty (if
# available) gives interactive-ish commands a fighting chance; they still
# don't have proper job control but at least keystrokes flow through.
# Sets `cmd_pid` in the caller's scope (bash dynamic scoping).
run_command_background() {
  if [ -t 0 ] && [ -r /dev/tty ]; then
    "$@" </dev/tty &
  else
    "$@" &
  fi
  cmd_pid=$!
}

# A trap can wake `wait` while the child is still alive. Loop until the
# child is actually gone so the caller gets the real exit status.
wait_for_command() {
  local rc
  while true; do
    wait "$cmd_pid"
    rc=$?
    kill -0 "$cmd_pid" 2>/dev/null || return "$rc"
  done
}

forward_int()  { [ -n "${cmd_pid:-}" ] && kill -INT  "$cmd_pid" 2>/dev/null; }
forward_term() { [ -n "${cmd_pid:-}" ] && kill -TERM "$cmd_pid" 2>/dev/null; }

# =============================================================================
# macOS implementation: nettop
# -----------------------------------------------------------------------------
# Strategy:
#   1. Background the wrapped command, capture its PID.
#   2. Repeatedly run nettop in single-sample CSV mode (`-L 1`) in a loop
#      while the command is alive, appending to a temp file.
#   3. Forward SIGINT/SIGTERM so Ctrl+C reaches the wrapped command.
#   4. Wait for the command to exit, capture its exit code.
#   5. Parse the CSV: read column positions from the header row, then
#      take the maximum bytes_in / bytes_out seen across all samples
#      (counters are monotonic, so the last good reading is the largest).
#
# Why one-shot samples in a loop instead of `nettop -L 0`: in infinite
# logging mode, nettop block-buffers stdout and the buffered tail can be
# lost when the process is signalled after the command finishes. Each
# `-L 1` invocation runs to completion and flushes naturally.
# =============================================================================
run_macos() {
  if ! command -v nettop >/dev/null 2>&1; then
    echo "$prog: nettop not found; running unmeasured" >&2
    exec "$@"
  fi

  local nt_out sampler_pid cmd_pid exit_code rx_tx rx tx

  nt_out=$(tmpfile) || { echo "$prog: mktemp failed; running unmeasured" >&2; exec "$@"; }
  trap 'rm -f "$nt_out" 2>/dev/null' EXIT

  run_command_background "$@"

  # nettop flags:
  #   -P             per-process summary (one row per pid, not per socket)
  #   -x             extended numeric output (raw bytes)
  #   -n             skip DNS/service-name lookups (faster, less noise)
  #   -L 1           CSV logging mode, one sample then exit
  #   -s 1           sample interval (must be integer seconds)
  #   -p PID         track only this process
  #   -J ...         request these specific columns
  (
    while kill -0 "$cmd_pid" 2>/dev/null; do
      nettop -n -P -x -L 1 -s 1 -p "$cmd_pid" -J bytes_in,bytes_out \
        >>"$nt_out" 2>/dev/null || true
      sleep 1
    done
  ) &
  sampler_pid=$!

  trap forward_int  INT
  trap forward_term TERM

  wait_for_command
  exit_code=$?

  wait "$sampler_pid" 2>/dev/null || true

  # Parse CSV: discover column indices from the header, then track the
  # max byte counter seen on data rows. Header looks like:
  #   ,bytes_in,bytes_out,
  # `samples` counts data rows so we can warn when none were captured
  # (e.g. command exited before nettop's first 1s sample).
  rx_tx=$(awk -F',' '
    /bytes_in|bytes_out/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "bytes_in")  in_col  = i
        if ($i == "bytes_out") out_col = i
      }
      next
    }
    in_col && out_col && $1 != "" {
      samples++
      rx = $in_col + 0; tx = $out_col + 0
      if (rx > max_rx) max_rx = rx
      if (tx > max_tx) max_tx = tx
    }
    END { printf "%d %d %d\n", samples + 0, max_rx + 0, max_tx + 0 }
  ' "$nt_out")

  read -r samples rx tx <<<"$rx_tx"

  if [ "${samples:-0}" -eq 0 ]; then
    echo "$prog: no samples captured (command finished before nettop's 1s sample tick)" >&2
  fi

  print_summary "${rx:-0}" "${tx:-0}"
  exit "$exit_code"
}

# =============================================================================
# Linux implementation: bpftrace
# -----------------------------------------------------------------------------
# Strategy:
#   1. Authenticate sudo upfront if not already root. Only bpftrace runs
#      privileged; the wrapped command stays as the original user.
#   2. Background the wrapped command, capture its PID.
#   3. Run bpftrace with -p PID and pass the PID as the script's $1.
#   4. Inside the script: hook sched_process_fork to track descendants,
#      then sum send/recv bytes across tcp/udp (v4 and v6) for any
#      tracked PID.
#   5. END block prints "NETTOTALIZER_RX <n>\nNETTOTALIZER_TX <n>" so
#      the shell can grep it out cleanly.
# =============================================================================
run_linux() {
  if ! command -v bpftrace >/dev/null 2>&1; then
    echo "$prog: bpftrace not found (apt/dnf install bpftrace); running unmeasured" >&2
    exec "$@"
  fi

  local bt_out bt_pid cmd_pid exit_code rx tx sudo_cmd

  bt_out=$(tmpfile) || { echo "$prog: mktemp failed; running unmeasured" >&2; exec "$@"; }
  trap 'rm -f "$bt_out" 2>/dev/null' EXIT

  sudo_cmd=
  if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "$prog: bpftrace requires root and sudo is unavailable; running unmeasured" >&2
      exec "$@"
    fi
    # Authenticate before launching the measured command so sudo prompt
    # latency doesn't skew timing, and so the wrapped command itself
    # runs as the original user, not root.
    if ! sudo -v; then
      echo "$prog: sudo authentication failed; running unmeasured" >&2
      exec "$@"
    fi
    sudo_cmd=sudo
  fi

  run_command_background "$@"

  # bpftrace program. $1 is the target PID, passed positionally below.
  #
  # Tracking model:
  #   @kids[pid]  set of descendants we consider "ours". Seeded via the
  #               fork tracepoint when a tracked parent forks.
  #   @rx / @tx   running totals. kretprobes give actual bytes transferred
  #               (retval), not just what was requested.
  local bt_script='
tracepoint:sched:sched_process_fork
/args->parent_pid == $1 || @kids[args->parent_pid]/
{
  @kids[args->child_pid] = 1;
}

kretprobe:tcp_sendmsg /retval > 0 && (pid == $1 || @kids[pid])/
{ @tx += retval; }

kretprobe:tcp_recvmsg /retval > 0 && (pid == $1 || @kids[pid])/
{ @rx += retval; }

kretprobe:udp_sendmsg /retval > 0 && (pid == $1 || @kids[pid])/
{ @tx += retval; }

kretprobe:udp_recvmsg /retval > 0 && (pid == $1 || @kids[pid])/
{ @rx += retval; }

kretprobe:udpv6_sendmsg /retval > 0 && (pid == $1 || @kids[pid])/
{ @tx += retval; }

kretprobe:udpv6_recvmsg /retval > 0 && (pid == $1 || @kids[pid])/
{ @rx += retval; }

END {
  printf("NETTOTALIZER_RX %lu\n", @rx);
  printf("NETTOTALIZER_TX %lu\n", @tx);
  clear(@kids); clear(@rx); clear(@tx);
}
'

  # -p ties bpftrace to the command lifetime on versions that support
  # auto-exit. We still send SIGINT after wait so END reliably prints.
  $sudo_cmd bpftrace -q -e "$bt_script" -p "$cmd_pid" "$cmd_pid" >"$bt_out" &
  bt_pid=$!

  trap forward_int  INT
  trap forward_term TERM

  wait_for_command
  exit_code=$?

  kill -INT "$bt_pid" 2>/dev/null || true
  wait "$bt_pid" 2>/dev/null || true

  rx=$(awk '/^NETTOTALIZER_RX / { v = $2 } END { print v + 0 }' "$bt_out")
  tx=$(awk '/^NETTOTALIZER_TX / { v = $2 } END { print v + 0 }' "$bt_out")

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
    echo "$prog: unsupported platform $(uname -s); running unmeasured" >&2
    exec "$@"
    ;;
esac
