# Prime Agent

Verified for crewmate and scout work and LOCAL secondmate work on 2026-08-08 with Prime Agent 0.7.1, with exit, interrupt, and control kinds re-verified on 2026-08-17 with 0.7.2.
Remote secondmates are not verified for this adapter and the remote spawn allowlist refuses `prime-agent`.
The executable owners remain `../../../bin/fm-harness.sh`, `../../../bin/fm-spawn.sh`, `../../../bin/fm-control-lib.sh`, and `../../../bin/fm-prime-agent-lib.sh`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `prime-agent` is resolved from `PATH`; its Node bundle sets the exact process name `prime-agent` for the client, detached daemon supervisor, and session worker. |
| Launch | `../../../bin/fm-spawn.sh` launches one positional encoded brief with `prime-agent`, clears inherited `CLAUDECODE` and `GROK_AGENT`, and stamps `FM_PI_HARNESS=prime-agent`; it adds provider, model, effort, and Prime Agent autonomous-gate flags only when those axes are selected. |
| Model flag | `--model <model>` or `--model <provider>/<model>`; discover current support with `prime-agent model list [search]` rather than assuming a model namespace. |
| Provider | `--provider <provider>` is supported by the Prime Agent launch path and is recorded independently from harness identity. |
| Autonomy | Prime Agent has no permission gate, so no `--yolo` flag is needed; Firstmate's separate `--autonomous-gate` options own bounded completion runs. |
| Trust | Project-local extensions auto-load without a trust gate; an unexercised first-run onboarding screen may still be controlled by Prime Agent's own settings. |
| Control kinds | The verified adapter supports crewmates, scouts, and LOCAL secondmates, while remote secondmates remain refused. |
| Marker | `PI_CODING_AGENT=true` establishes only the Pi family; `PRIME_AGENT_CODING_AGENT_DIR`, `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1`, and `FM_PI_HARNESS=prime-agent` disambiguate Prime Agent. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; all five shared values are emitted by `fm-spawn.sh` and were accepted by the verified Prime Agent CLI. |
| Skill invocation | `/skill:<skill>`, for example `/skill:no-mistakes`; the bare `/<skill>` form is not a Prime Agent command. |
| Exit command | `/quit` exits the client pane but leaves the detached daemon session live, so `fm-control.sh` uses this command and `fm-prime-agent-lib.sh` owns directory-scoped retirement. |
| Interrupt | Single Escape cancels the running turn and leaves the agent at its composer without restoring the cancelled prompt, so the control plane sends no clear key. |
| Composer | The bare `>` glyph is trusted as a composer only inside the verified Prime Agent background surface; an unstructured bare `>` remains unknown or a dead shell and is never an injection target. |
| Extension | `-e <path>` loads an explicit extension, and Prime Agent auto-discovers project-local `.prime/agent/extensions/` without a project-trust gate; it does not discover `.pi/extensions/`. |
| Busy state | Under Herdr, Prime Agent's built-in reporter supplies busy and idle state, so the crewmate extension written by `fm-spawn.sh` touches only the task turn-end notification marker and never seeds a firstmate busy record. |
| Autonomous gates | Repeatable `--autonomous-gate` implies `--autonomous` for ship and scout tasks, with defaults of 24 continuations, 96 turns, 500000 tokens, 14400000 ms, 5 retries, and 900000 ms; the spawn refuses these gates for secondmates and no-mistakes ships. |
| Resume | `prime-agent --resume <session-uuid>`, `-c` or `--continue`, and `prime-agent attach <agent>` are native resume shapes, while deterministic Firstmate recovery uses relaunch. |

## Launch and extensions

A crewmate or scout loads the active home's `state/<id>.prime-ext.ts` extension, which listens only for `turn_end` and touches the task turn-end notification marker.
A local secondmate loads both its provisioned home's `.prime/agent/extensions/fm-primary-turnend-guard.ts` and `.prime/agent/extensions/fm-primary-prime-watch.ts`.
The primary pair auto-discovers from `.prime/agent/extensions/`, and `../../../bin/fm-session-start.sh` reports when either loaded marker is missing or stale.
The primary turn-end extension reconstructs logical-run settle from `agent_end` because Prime Agent has no `agent_settled` event, while the watcher extension owns the `fm_watch_arm_prime` tool and its successor arm lifecycle.
The Prime Agent extension API has no `registerEntryRenderer`, so the Pi Calm extension and custom tool rendering are not loaded under this adapter.

## Detached daemon and local secondmates

Each root Prime Agent session runs in a detached worker under one per-user supervisor, and closing the client or sending `/quit` can leave that worker live with its launch directory as `cwd`.
`../../../bin/fm-prime-agent-lib.sh` lists sessions by exact directory binding and stops only sessions whose `cwd` is the task worktree or local secondmate home or a path below it.
Never use `prime-agent shutdown`, because one supervisor serves the whole user and that command would stop unrelated Firstmate and user sessions.
`../../../bin/fm-spawn.sh --secondmate` retires resident Prime Agent sessions bound to the local home before relaunching it, and refuses the relaunch if strict retirement cannot prove success.
Prime Agent is LOCAL-secondmate-only in the current implementation; remote secondmate spawning excludes it and accepts only the separately verified remote adapters.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
Its own `PRIME_AGENT_CODING_AGENT_DIR`, `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1`, and launch-boundary `FM_PI_HARNESS=prime-agent` markers disambiguate it when paired with the Pi-family marker.
`../../../bin/fm-harness.sh` checks those Prime markers before `CLAUDECODE` and the unmarked Pi result, while explicit `FM_PI_HARNESS=pi` or `pi-signed` stays authoritative for those identities.
The ancestry fallback matches the exact `prime-agent` process name or a Prime Agent path in a Node command's arguments.

## Composer and primary supervision

Prime Agent's shell-style `>` prompt is a dead-shell hazard, so `../../../bin/fm-composer-lib.sh` promotes it only after the styled background surface proves the composer container.
The Herdr adapter additionally requires the current foreground process and native agent identity to be Prime Agent; the shell returned after `/quit` must not inherit the composer verdict.
The shared ghost stripper removes Prime Agent's dark truecolor start hints from ANSI captures, while a plain capture degrades to unknown when the verified surface cannot be proven.
The tmux reader has no equivalent native Prime Agent identity arm, so an unproven mid-turn composer remains unknown rather than accepting unsafe input.
The primary watcher protocol is `../../../docs/supervision-protocols/prime-agent.md`, and its turn-end and pre-tool hooks are wired through the tracked `.prime/agent/extensions/` pair.
