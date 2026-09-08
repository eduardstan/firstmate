# Prime Agent

This slice registers and detects Prime Agent as a distinct Pi-family harness.
Launch, supervision, control, and teardown behavior land in the following adapter slices.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
Its own `PRIME_AGENT_CODING_AGENT_DIR`, `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1`, and launch-boundary `FM_PI_HARNESS=prime-agent` markers disambiguate it when paired with the Pi-family marker.
`../../../bin/fm-harness.sh` checks Prime Agent markers before `CLAUDECODE` and the unmarked Pi result.
An explicit `FM_PI_HARNESS=pi` or `FM_PI_HARNESS=pi-signed` remains authoritative when stale Prime Agent markers are inherited.
A Prime Agent marker without `PI_CODING_AGENT=true` is ignored, so it cannot relabel a Claude or unrelated process.
The ancestry fallback matches the exact `prime-agent` process name.

Detection was verified against Prime Agent 0.9.1 on Linux, with earlier checks against 0.7.1 and 0.7.2.
