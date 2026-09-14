# Prime Agent

This reference covers Prime Agent detection, crewmate/scout and local secondmate launch, semantic busy state, and control mechanics.
The active empirical record is [`docs/verification/prime-agent.md`](../../../../../docs/verification/prime-agent.md).
Remote secondmates remain outside the verified boundary.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
The launch-boundary marker `FM_PI_HARNESS=prime-agent` disambiguates it when paired with the Pi-family marker.
Prime Agent's own `PRIME_AGENT_CODING_AGENT_DIR` and `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1` are inherited session values, not detection evidence.
`../../../bin/fm-harness.sh` checks the Prime Agent marker before `CLAUDECODE` and the unmarked Pi result and after the cursor, gemini, rovo, and omp marker arms.
Those four keep their identity when started by hand inside a Prime Agent session.
With `CLAUDECODE=1`, the marker selects Prime Agent only when a real `prime-agent` process sits within eight parents.
Without `CLAUDECODE`, the marker is sufficient once the Pi-family marker is present.
A marker without `PI_CODING_AGENT=true` is ignored.
The Prime Agent launch clears `CLAUDECODE` and `GROK_AGENT` and uses the shared launch prefix to clear cursor and Gemini markers.
An unmarked Prime Agent session remains Pi-family by design.
Detection and launch markers were verified live against Prime Agent 0.9.4.

## Launch and busy state

`../../../bin/fm-spawn.sh` launches a Prime Agent crewmate or scout with one encoded brief, `--provider`, `--model`, `--thinking`, and `-e state/<task-id>.prime-ext.ts`.
The generated extension writes the semantic busy record on `agent_start`, clears it on `agent_end`, and touches the turn-end notification marker on `turn_end`.
Prime Agent 0.9.4 has no `agent_settled` event, so `agent_end` is the adapter's logical prompt boundary.
`bin/fm-busy-lib.sh` trusts the generated `prime-ext` source only for a recorded Prime Agent task.
The extension is written outside the project and is removed by cleanup and harness relaunch wiring.
A local secondmate launch loads `.prime/agent/extensions/fm-primary-turnend-guard.ts` and `.prime/agent/extensions/fm-primary-prime-watch.ts` from its own home.
The primary protocol is [`docs/supervision-protocols/prime-agent.md`](../../../../../docs/supervision-protocols/prime-agent.md).
The local secondmate launch and both primary extension paths were verified in the isolated Herdr trial.

## Control

Prime Agent uses the Pi-family control table.
A single `Escape` interrupts a running turn and leaves the composer empty without a clear key.
`/quit` exits the Prime Agent process and leaves the detached daemon worker for directory-bound retirement.
Relaunch starts a fresh Prime Agent client in the same pane and directory rather than claiming an unverified pane-resume contract.
Prime Agent 0.9.4 control behavior was verified live in Herdr.
`../../../bin/fm-spawn.sh --help` owns executable preflight and rejects a missing `prime-agent` before task publication.
`../../../bin/fm-prime-agent-lib.sh` owns detached-worker listing and retirement for cleanup and secondmate relaunch.

## Scope

Prime Agent is verified for crewmate, scout, and local secondmate work.
Remote secondmates remain refused because remote readiness has no Prime Agent verification.
The primary-session protocol is tracked and its extension behavior is covered by the Prime Agent supervision tests.
Prime Agent's native RPC, RLM, and agent-messaging features are not Firstmate control-plane replacements.
