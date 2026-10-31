# nettotalizer

This context describes the language for measuring network bytes moved by one wrapped command over its lifetime.

## Language

**Measured command**:
The command invoked through nettotalizer whose network bytes are measured while preserving its stdin, stdout, stderr, and exit code.
_Avoid_: Wrapped command when referring to the domain concept

**Measured command lifecycle**:
The lifetime of a wrapped command as observed by nettotalizer, from launch setup through measurement adapter attachment, command release, signal forwarding, command exit, and measurement shutdown.
_Avoid_: Gated command lifecycle, wrapper lifecycle

**Network summary**:
The stderr report emitted after a measured command exits, containing total, received, and sent byte counts.
_Avoid_: Metrics output, report blob

**Process-scoped count**:
A network summary derived only from the measured command's process tree — Linux tcp/udp kretprobes, macOS nettop samples. The scoped, honest number: it counts socket payload bytes for the command and its descendants, and nothing else.
_Avoid_: Exact count, true total

**Interface delta estimate**:
A network summary derived from the before/after byte delta of the default interface, rather than from the measured command's process tree. Includes unrelated host traffic, so it is always reported with a warning. It is the BSD backend's only measurement and the macOS backend's fallback when process samples visibly undercount received bytes.
_Avoid_: Interface count, raw delta
