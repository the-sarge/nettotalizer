# nettotalizer

`nettotalizer` is like `time(1)` for network bytes — wrap any command and find out
how much data it moved.

In:

```sh
nettotalizer curl -sS -o /dev/null https://example.com/file.tar.gz
nettotalizer git fetch
```
Out:

```text
total 6.1KB
received 5.3KB
sent 831B
```
The wrapped command keeps its normal stdin, stdout, stderr, and exit code; the
network summary is written to stderr so stdout remains usable in pipelines.

## Why nettotalizer?

`nettotalizer` is meant to sit next to tools like `time`. The `time` utility is
simple and crazy useful: put it in front of a command and it gives you back elapsed time and CPU. But it doesn't give you _elapsed network traffic_.

That's the gap `nettotalizer` tries to fill. It cannot be as exact as `time`,
because per-process network accounting depends on platform-specific tracing and
sampling rather than one clean portable process counter. Still, it gets you into
the right ballpark with a similar interface.

The name doesn't exactly roll off the tongue, but it's trying to be literal. A flow _meter_ measures throughput rate (volume over time; eg Mbps), and plenty of tools
already do that. A flow _totalizer_ measures total transferred volume. That's what 
`nettotalizer` tries to do for your wrapped command.

## How it works

**macOS** has no simple, stable, unprivileged event stream for per-process
socket byte accounting. The macOS backend works around this with three tricks:

- It stages the wrapped command in a tiny Bash shim that blocks on a FIFO,
  so the command's PID is captured before any network I/O can begin.
- Once the sampler is attached, the wrapper opens the FIFO and the shim
  `exec`s the real command in the same PID — no attach race.
- Every ~ 100 ms it walks the live process tree (including descendants found
  via `pgrep -P`) and asks `nettop` for a one-shot CSV snapshot of every PID.

If process-scoped totals look suspiciously low compared with the default
interface's byte counters during the same window, the macOS backend falls back
to the interface delta and prints a warning. The fallback is useful for fast
downloaders like Homebrew that spawn short-lived helpers, but it is an
estimate that can include unrelated system traffic.

**Linux** uses `bpftrace` to attach `kretprobes` on the kernel's socket
send/receive paths — `tcp_sendmsg`, `tcp_recvmsg`, `udp_sendmsg`, `udp_recvmsg`,
plus their IPv6 counterparts. A `sched_process_fork` tracepoint maintains a
set of descendants forked after tracing starts, so any child the wrapped
command spawns is counted too. The wrapped command itself runs unprivileged;
only `bpftrace` is invoked under `sudo`.

**FreeBSD, NetBSD, and OpenBSD** do not expose one common unprivileged
per-process network byte counter equivalent to Linux's `bpftrace` path or
macOS's `nettop` process summaries. On those systems, `nettotalizer` takes a
default-interface byte-counter snapshot with `netstat` immediately before and
after the wrapped command, then reports the delta. This is useful as an
estimate, but it includes any unrelated traffic on that interface during the
same window, and `nettotalizer` prints a warning to make that explicit.

## Requirements

`nettotalizer` is a Bash script for macOS, Linux, FreeBSD, NetBSD, and OpenBSD.
It doesn't need a newer Bash than the shamefully old version that Apple still
includes with macOS. On the BSDs, install Bash first if it is not already
available.

On macOS, it uses the system `nettop` command and polls the wrapped process tree.

On Linux, it uses [`bpftrace`](https://github.com/bpftrace/bpftrace) to trace
socket send and receive activity.
`bpftrace` must be installed and able to access kernel tracing facilities:

```sh
# Debian/Ubuntu
sudo apt-get install bpftrace

# RHEL/Fedora/Rocky
sudo dnf install bpftrace
```

If the script is not already running as root, only `bpftrace` is run through
`sudo`; the wrapped command still runs as the original user. On a fresh host, the
first measured command can take a few extra seconds while `bpftrace` compiles and
attaches its probes.

On FreeBSD, NetBSD, and OpenBSD, it uses base-system `route` and `netstat`
commands to read the default interface's byte counters.

## Installation

Clone the repository and put the executable somewhere on your `PATH`:

```sh
git clone git@github.com:the-sarge/nettotalizer.git
cd nettotalizer
chmod +x nettotalizer
cp nettotalizer ~/.local/bin/nettotalizer
```

If `~/.local/bin` is not already on your `PATH`, add it in your shell profile.

## Usage

```sh
nettotalizer <command> [args...]
```

The command's exit code is preserved:

```sh
nettotalizer curl -fL https://example.com/file.tar.gz -o file.tar.gz
echo $?
```

The summary is written to stderr, so stdout can still be redirected or piped:

```sh
nettotalizer curl -sS https://example.com/data.json | jq .
```

Summary output follows the same label-then-value shape as `time -p`:

```text
total 6.1KB
received 5.3KB
sent 831B
```

If you want to combine `nettotalizer` with `time`, you should wrap `nettotalizer` with `time`, and not the other way around:

```sh
time -p nettotalizer curl -fL https://example.com/file.tar.gz -o file.tar.gz
```
```text
total 433.6MB
received 414.5MB
sent 19.1MB
real 57.27
user 7.90
sys 4.08
```

## Testing

Local smoke tests:

```sh
tests/smoke.sh
```

Linux integration test in Docker:

```sh
tests/linux-docker.sh
```

The Docker test uses a privileged Linux container with the host PID namespace so
`bpftrace` can observe the wrapped process and descendants. The script handles
the container setup, including installing `bpftrace` and mounting `tracefs`, but
equivalent manual Docker runs need `--privileged`, `--pid=host`, and tracefs
mounted at `/sys/kernel/tracing` when it is not already mounted.

Native Linux integration test:

```sh
tests/linux.sh
```

The native Linux test expects `bpftrace` and `curl` to already be installed. If
it is not run as root, it also needs passwordless or cached `sudo` credentials so
`nettotalizer` can run the tracer.

Run the macOS integration test on a Mac:

```sh
tests/macos.sh
```

The BSD backend is covered by the smoke tests with fake `route` and `netstat`
output. To try it on a real BSD host, run a normal measured command and expect a
warning that the result is an interface-delta estimate:

```sh
nettotalizer curl -sS -o /dev/null https://example.com
```

## Limitations

On macOS and Linux, `nettotalizer` reports socket payload bytes, not complete
interface bytes. Protocol headers, retransmits, and lower-level link overhead
are not included in those process-scoped totals. The BSD backend is different:
it reports default-interface byte deltas.

On **macOS**, the backend is polling-based:

- Commands shorter than ~ 1 second can finish before `nettop`'s first sample.
  When this happens, `nettotalizer` prints a `no samples captured` warning
  and reports zero — better that than a silent zero with no explanation.
- Very short-lived child processes can fork and exit between 100 ms polls,
  in which case their bytes go unobserved by `nettop`. The interface-delta
  fallback often catches these cases, at the cost of including unrelated
  system traffic in the estimate.

On **Linux**, the `bpftrace` backend depends on kernel probes. It does not
cover raw sockets, `AF_PACKET`, or other nonstandard network paths. It also
misses any I/O the wrapped command performs before `bpftrace` attaches —
typically only a few hundred milliseconds, but not zero.

On **FreeBSD, NetBSD, and OpenBSD**, results are interface-byte deltas rather
than process-scoped socket totals. They can include unrelated host traffic
during the wrapped command's runtime, and they can miss traffic that leaves
through another interface because of VPNs, jails, routing tables, or split
routing.

Unsupported platforms run the wrapped command unmeasured after printing a
warning.

## What this isn't

`nettotalizer` is not a network monitor or a packet sniffer. It measures one
command's bytes-transferred over its lifetime, then exits. For continuous
monitoring of a host or interface, use tools like `iftop`, `bmon`, or
`nethogs`.

## License

MIT. See [LICENSE](LICENSE).

## Thanks

I appreciate everyone who has contributed to building this amazing world of compute we all now benefit from, and maybe especially those who pioneered free/open source, early Unix/BSD, and the BBS glory days. 
