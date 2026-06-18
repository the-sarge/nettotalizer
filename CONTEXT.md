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
