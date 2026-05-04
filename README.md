# nettotalizer

`nettotalizer` wraps a command and reports how many network bytes it transferred.
The wrapped command keeps its normal stdin, stdout, stderr, and exit code; the
network summary is written to stderr so stdout remains usable in pipelines.

```sh
nettotalizer curl -sS -o /dev/null https://example.com/file.tar.gz
nettotalizer git fetch
```

Example summary:

```text
[net:     ↓1.2MB ↑45KB]
```

## Requirements

`nettotalizer` is a Bash script for macOS and Linux.

On macOS, it uses the system `nettop` command and polls the wrapped process tree.

On Linux, it uses `bpftrace` to trace socket send and receive activity.
`bpftrace` must be installed and able to access kernel tracing facilities:

```sh
# Debian/Ubuntu
sudo apt-get install bpftrace

# Rocky/RHEL/Fedora
sudo dnf install bpftrace
```

If the script is not already running as root, only `bpftrace` is run through
`sudo`; the wrapped command still runs as the original user. On a fresh host, the
first measured command can take a few extra seconds while `bpftrace` compiles and
attaches its probes.

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

## Testing

Run the local smoke tests:

```sh
tests/smoke.sh
```

Run the Linux integration test in Docker:

```sh
tests/linux-docker.sh
```

The Docker test uses a privileged Linux container with the host PID namespace so
`bpftrace` can observe the wrapped process and descendants. The script handles
the container setup, including installing `bpftrace` and mounting `tracefs`, but
equivalent manual Docker runs need `--privileged`, `--pid=host`, and tracefs
mounted at `/sys/kernel/tracing` when it is not already mounted.

## How It Works

macOS does not provide a simple, stable, unprivileged event stream for
per-process socket byte accounting. The macOS backend starts the command behind
a small gate, starts `nettop` sampling, then releases the command and repeatedly
samples the visible process tree. If process samples obviously undercount
received bytes, it may fall back to the default network interface byte delta and
prints a warning when doing so.

Linux uses `bpftrace` to observe socket send and receive kernel return values for
the wrapped process and descendants forked after tracing starts.

## Limitations

`nettotalizer` reports socket payload bytes, not complete interface bytes.
Protocol headers, retransmits, and lower-level link overhead are not included in
the process-scoped totals.

The macOS backend is polling-based, so very short-lived child processes can
finish between samples. The interface fallback is useful for fast downloaders,
but it is an estimate and can include unrelated system traffic.

The Linux backend depends on `bpftrace` and kernel probes. It does not cover raw
sockets, `AF_PACKET`, or other nonstandard network paths.

Unsupported platforms run the wrapped command unmeasured after printing a
warning.
