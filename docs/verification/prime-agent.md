# Verification: the prime-agent crewmate/scout and secondmate adapter

Active empirical facts for firstmate's Prime Agent adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/prime-agent.md`](../../.agents/skills/harness-adapters/references/harness/prime-agent.md); this record owns how they were established and what remains unproven.

## Subject

| Field | Value |
|---|---|
| Version | `prime-agent 0.9.4` |
| Verified | 2026-09-14 |
| Binary | `/home/eduard/.local/bin/prime-agent` |
| Platform | Linux x86_64 |
| Backend | Herdr 0.8.2, in an isolated non-`default` lab session created only through `bin/fm-herdr-lab.sh` |
| Provider and model | `openai-codex` and `gpt-5.6-terra` |

Every Herdr command below ran through the named lab helper with a trailing `--session` argument.
The helper's fleet-state tripwire reported the same running `default` session before provisioning and after teardown.
The shared Prime Agent daemon was inspected read-only and was not stopped, restarted, upgraded, or reconfigured.

## Detection and launch flags

The live launch used the same marker and flags that Firstmate emits:

```
$ env -u CLAUDECODE -u GROK_AGENT PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent prime-agent --model gpt-5.6-terra --provider openai-codex --thinking low
```

Herdr's process inspection returned the exact foreground identity:

```
{"process_info":{"foreground_processes":[{"argv":["prime-agent"],"name":"prime-agent"}],"pane_id":"w2:p1"}}
```

The live worker rendered the following startup fields:

```
version  v0.9.4
model    gpt-5.6-terra
← agents/resume  GPT-5.6 Terra • low  ? for shortcuts
```

An extension captured the launch environment with these values:

```
PI_CODING_AGENT=true
FM_PI_HARNESS=prime-agent
PRIME_AGENT_INTERNAL_DAEMON_WORKER=1
PRIME_AGENT_CODING_AGENT_DIR=/home/eduard/.prime/agent
```

The Prime Agent daemon status was read with `prime-agent status --json` and reported `version: 0.9.4`, `protocolVersion: 7`, `status: current`, `isDefault: true`, and `hasTrackedWorkers: true`.

## Extension loading and trust

A fresh lab project containing `.prime/agent/extensions/auto.ts` wrote its load marker without an explicit `-e` flag.
The same launch showed no trust prompt and reached the Prime Agent composer.
A worker extension supplied with `-e <absolute-path>` also loaded and received `session_start`, `agent_start`, `turn_end`, and `agent_end` callbacks.
The extension load and callback evidence was recorded as JSON lines:

```
{"name":"loaded","value":{"pi":"true","fm":"prime-agent","daemon":"1","dir":"/home/eduard/.prime/agent"}}
{"name":"session_start","value":{"type":"session_start","reason":"startup"}}
{"name":"agent_start","value":{"type":"agent_start"}}
{"name":"turn_end","value":{"type":"turn_end","turnIndex":0}}
{"name":"agent_end","value":{"type":"agent_end"}}
```

This verifies the 0.9.4 extension surface and the absence of a trust stop for project-local `.prime/agent/extensions/` discovery.

## Busy and idle state

A prompt that asked the model to run `sleep 15` changed Herdr's native agent state from `idle` to `working` while the tool was running.
The same pane returned to `idle` after the turn completed and rendered the requested response.
The decisive live reads were:

```
{"agent":{"agent":"prime-agent","agent_status":"working","cwd":".../.prime-live-lab","pane_id":"w2:p1"}}
{"agent":{"agent":"prime-agent","agent_status":"idle","cwd":".../.prime-live-lab","pane_id":"w2:p1"}}
```

The 0.9.4 extension callbacks also showed `agent_start` before the long turn and `agent_end` after it.
The adapter's semantic busy-state extension uses those two callbacks and leaves `turn_end` as a notification only.

## Interrupt, quit, and relaunch

A second `sleep 30` prompt reached `agent_status=working`.
One `Escape` sent through `bin/fm-herdr-lab.sh run ... pane send-keys ... escape` changed the native state to `done` and rendered `Operation aborted` without completing the requested response.

Sending `/quit` followed by Enter returned Herdr's process inspection to a lone `/bin/bash` pane:

```
{"process_info":{"foreground_processes":[{"argv":["/bin/bash"],"name":"bash"}],"pane_id":"w2:p1"}}
```

Launching the same command again in that pane rendered `version v0.9.4`, `model gpt-5.6-terra`, and an idle composer.
The relaunch reused the same Herdr pane and project directory.

## Detached daemon session retirement

The Prime Agent client created a detached daemon worker while the Herdr pane was active.
The launch environment reported `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1` and the daemon's `status --json` reported tracked workers.
After `/quit`, the Herdr pane had no Prime Agent process in its foreground process list while the daemon session remained registered.
The adapter's retirement path is exercised by `fm-prime-agent-lib.sh` against the exact project directory during task cleanup and secondmate relaunch; the shared daemon itself was never stopped.

## Scope and remaining boundaries

The live evidence covers the crewmate/scout launch, local secondmate launch surface, marker export, launch flags, project-local extension discovery, explicit extension loading, busy and idle callbacks, Escape, `/quit`, relaunch, and detached-worker behavior on Prime Agent 0.9.4.
Remote secondmates remain outside this evidence and are still refused by the remote readiness allowlist.
Pane resume and fork are not claimed because Firstmate uses deterministic relaunch for Prime Agent.
No RPC backend, RLM control-plane replacement, or upstream repository operation was tested or changed.

## Refreshing this record

Run the portable adapter and busy-state suites, then run the opt-in live guard after a Prime Agent or Herdr upgrade:

```
bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-harness.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-quota-choose.test.sh tests/fm-spawn-dispatch-profile.test.sh
FM_PRIME_AGENT_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-prime-agent-signals-live-e2e.test.sh
```
