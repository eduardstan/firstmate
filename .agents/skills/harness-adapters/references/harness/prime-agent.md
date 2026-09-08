# Prime Agent

This slice registers and detects Prime Agent as a distinct Pi-family harness.
Launch, supervision, control, and teardown behavior land in the following adapter slices.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
Its own `PRIME_AGENT_CODING_AGENT_DIR`, `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1`, and launch-boundary `FM_PI_HARNESS=prime-agent` markers disambiguate it when paired with the Pi-family marker.
`../../../bin/fm-harness.sh` checks Prime Agent markers before `CLAUDECODE` and the unmarked Pi result, and after the cursor, gemini, rovo, and omp marker arms.
Those four therefore keep their identity when one of them is started by hand inside a Prime Agent session.
grok is deliberately not among them: `GROK_AGENT=1` is already tested after the unmarked Pi result, so a grok session started inside any Pi-family session has always resolved to that family, and reordering it belongs outside this slice.
An explicit `FM_PI_HARNESS=pi` or `FM_PI_HARNESS=pi-signed` remains authoritative when stale Prime Agent markers are inherited.
A Prime Agent marker without `PI_CODING_AGENT=true` is ignored, so it cannot relabel a Claude or unrelated process.
The ancestry fallback matches the exact `prime-agent` process name.
Prime Agent does not clear the markers it exports, so `../../../bin/fm-spawn.sh` clears `PRIME_AGENT_CODING_AGENT_DIR` and `PRIME_AGENT_INTERNAL_DAEMON_WORKER` at the launch boundary alongside the cursor and gemini markers: a worker launched from a multiplexer that stored a Prime Agent environment keeps its own identity.

Detection was verified against Prime Agent 0.9.1 on Linux, with earlier checks against 0.7.1 and 0.7.2.

## Interim behavior for a Prime Agent home

This slice is detection only, so a home whose primary is Prime Agent now resolves `prime-agent` where it previously resolved `pi`, and the Pi-family paths behind that value do not exist yet.
`../../../bin/fm-spawn.sh` has no `prime-agent` launch template, so a crew or secondmate spawn with `config/crew-harness` absent or `default` aborts with `no launch template for harness 'prime-agent'`.
`fm_supervision_model` (`../../../bin/fm-wake-lib.sh`) returns `persistent` rather than `extension`, `../../../bin/fm-supervision-instructions.sh` renders `unknown.md` rather than `pi.md`, and the pi-gated startup steps in `../../../bin/fm-session-start.sh` (lease sweep, branch-outcome startup replay, Pi extension checks) no longer run.
Until the launch slice lands, pin `config/crew-harness` to `pi` and export `FM_SUPERVISION_MODEL=extension` to keep the behavior such a home had before this slice.
