# Verification: the Prime Agent crewmate/scout adapter

Active empirical facts for firstmate's Prime Agent adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/prime-agent.md`](../../.agents/skills/harness-adapters/references/harness/prime-agent.md); this record owns how they were established and what remains unproven.

## Subject

| Field | Value |
|---|---|
| Version | `prime-agent 0.9.4` |
| Verified | 2026-09-14 |
| Branch | `fm/fm-upstream-prime-one-pr`, rebuilt from current upstream `main` |
| Binary | resolved with `command -v prime-agent` |
| Platform | Linux x86_64 |
| Backend | Herdr 0.8.2, in an isolated non-`default` lab session created only through `bin/fm-herdr-lab.sh` |
| Provider and model | `openai-codex` and a configured Prime Agent model |

The live guard is opt-in because it submits real prompts.
Every Herdr command in the guard runs through `HERDR_LAB_HELPER`, which defaults to `$ROOT/bin/fm-herdr-lab.sh`.
The shared Prime Agent daemon is not stopped, restarted, upgraded, or reconfigured.

## Detection and launch flags

The production launch was rendered by `bin/fm-spawn.sh` with the explicit Prime Agent marker and provider-qualified profile.
The launch clears inherited foreign markers and passes the provider, model, thinking level, encoded brief, and generated extension.
The live guard resolves the executable with `command -v prime-agent` and checks a numeric version banner and a non-empty model field without depending on a personal path or a model-specific screen string.
Herdr process inspection identified the foreground process as `prime-agent`.
The launch reached the Prime Agent composer without a trust stop.

## Extension loading and busy state

The production-generated extension loaded in the isolated Herdr workspace.
The live guard confirmed the initial turn settled to `idle prime-ext` and created the turn-end notification marker.
A real tool call changed the adapter classification to `busy prime-ext`.
The Herdr agent record simultaneously reported `agent_status=working`.
After the tool call completed, the adapter classification returned to `idle prime-ext`.
The extension uses `agent_start` for busy state and holds `agent_end` idle publication for a short grace window when the last assistant message stopped with an error or when pending messages are queued.
A retry start cancels the held error timer.
`turn_end` remains a notification touch and never fabricates idle state.
The portable regression drives normal completion, error grace, retry, pending-message, and stale-generation cases in `tests/fm-busy-adapter-wiring.test.sh`.

## Supervised task path

The production task path is owned by these commands and is covered by the deterministic spawn and control suites:

```
bin/fm-spawn.sh <task-id> <project-dir> --mode direct-PR --yolo off --harness prime-agent --provider openai-codex --model <model> --effort low
FM_HOME=<home> bin/fm-send.sh <task-id> "Read the instructions and continue the task."
FM_HOME=<home> bin/fm-control.sh <task-id> interrupt
FM_HOME=<home> bin/fm-control.sh <task-id> exit
FM_HOME=<home> bin/fm-control.sh <task-id> relaunch --harness prime-agent --model <model> --effort low --note "Continue from the durable instructions."
```

`tests/fm-spawn-dispatch-profile.test.sh` verifies the generated production launch and the Prime Agent secondmate refusal before endpoint or metadata publication.
`tests/fm-control.test.sh` verifies the Pi-family interrupt, exit, and relaunch mechanics and the Prime Agent capability refusal for secondmates.
The live guard uses direct Herdr input for vendor behavior so it can isolate the Prime Agent process without creating a real task record.
The live guard therefore does not claim an end-to-end `fm-send` or `fm-control` vendor run.

## Interrupt, exit, and relaunch

A real long-running Prime Agent turn reached Herdr's `working` state.
One Escape cancelled the turn and rendered `Operation aborted`.
Sending `/quit` followed by Enter returned the pane to its shell.
Launching the generated command again in the same pane rendered a numeric version banner and returned to the composer.
The live guard confirmed detached Prime Agent worker retirement for the temporary project directory after the final quit.

## Scope and still unproven

The live evidence covers the crewmate/scout launch, marker export, provider-qualified flags, project extension loading, semantic busy and idle behavior, Escape, `/quit`, relaunch, and detached-worker retirement on Prime Agent 0.9.4.
Prime Agent secondmate launches remain refused because its primary supervision protocol is not wired into the session-start renderer and has not been verified end to end.
Remote secondmates remain outside this evidence.
Primary-session supervision, pane resume, fork, RPC, RLM, and agent-messaging control-plane replacement are not claimed.

## Refreshing this record

Run the portable adapter and busy-state suites, then run the opt-in live guard after a Prime Agent or Herdr upgrade:

```
bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-harness.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-quota-choose.test.sh tests/fm-spawn-dispatch-profile.test.sh
FM_PRIME_AGENT_LIVE_E2E=1 bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-signals-live-e2e.test.sh
```

The live guard reports seven `ok` lines and ends with `FM_TEST_SUMMARY total=1 failed=0` when the installed tools and provider are available.

## Current branch evidence

On 2026-09-14, the rebuilt branch passed the targeted adapter suites with `FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0`.
The exact command was `bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-harness.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-quota-choose.test.sh tests/fm-spawn-dispatch-profile.test.sh`.
On 2026-09-14, the isolated live guard passed with `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0`.
The exact command was `HERDR_LAB_HELPER='/home/eduard/Dropbox/Projects/firstmate/bin/fm-herdr-lab.sh' FM_PRIME_AGENT_LIVE_E2E=1 bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-signals-live-e2e.test.sh`.
