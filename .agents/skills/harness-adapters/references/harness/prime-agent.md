# Prime Agent

This slice registers and detects Prime Agent as a distinct Pi-family harness.
Launch, supervision, control, and teardown behavior land in the following adapter slices.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
The launch-boundary marker `FM_PI_HARNESS=prime-agent` is what disambiguates it when paired with the Pi-family marker, the same Firstmate-owned mechanism `FM_PI_HARNESS=pi-signed` uses for the signed wrapper.
Prime Agent's own `PRIME_AGENT_CODING_AGENT_DIR` and `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1` are session-wide inherited values and are deliberately not detection evidence: an unmarked Prime Agent session stays Pi-family.
`../../../bin/fm-harness.sh` checks the Prime Agent marker before `CLAUDECODE` and the unmarked Pi result, and after the cursor, gemini, rovo, and omp marker arms.
Those four therefore keep their identity when one of them is started by hand inside a Prime Agent session.
grok is deliberately not among them: `GROK_AGENT=1` is already tested after the unmarked Pi result, so a grok session started inside any Pi-family session has always resolved to that family, and reordering it belongs outside this slice.
An explicit `FM_PI_HARNESS=pi` or `FM_PI_HARNESS=pi-signed` is therefore what a Pi or Pi-signed session carries, and neither is ever relabelled.
The marker without `PI_CODING_AGENT=true` is ignored, so it cannot relabel a Claude or unrelated process.
The marker can itself leak into a Claude pane of the same session, so when `CLAUDECODE=1` is present it is a precedence override rather than evidence, the same boundary `FM_OMP_HARNESS=omp` uses: the verdict is `prime-agent` only when a `prime-agent` process sits within eight parents, and otherwise falls through to `claude`.
With `CLAUDECODE` absent the marker stands alone and no ancestry is required.
Prime Agent does not clear the values it exports, so `../../../bin/fm-spawn.sh` clears `PRIME_AGENT_CODING_AGENT_DIR` and `PRIME_AGENT_INTERNAL_DAEMON_WORKER` at the launch boundary alongside the cursor and gemini markers, keeping a worker's inherited environment free of them for the slices that will read them.

Detection was verified against Prime Agent 0.9.1 on Linux, with earlier checks against 0.7.1 and 0.7.2.

## Scope of this slice

This slice detects Prime Agent from the explicit `FM_PI_HARNESS=prime-agent` launch marker only, which `../../../bin/fm-spawn.sh` establishes at every prime-agent crewmate and scout launch boundary, so a firstmate-launched worker identifies itself and a Prime Agent PRIMARY still resolves as Pi-family exactly as it did before.
Ambient auto-detection of that primary, and a prime-agent secondmate, arrive with the supervision slices that give the value a supervision model, a supervision snippet, and the primary supervision extensions; a secondmate spawn is refused here rather than launched unsupervised.
