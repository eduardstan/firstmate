Mode: prime-agent extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the prime-agent primary auto-loaded both project extensions; if not, restart `prime-agent` with `-e __FM_PRIME_TURNEND_EXT__ -e __FM_PRIME_EXT__`.
   prime-agent auto-discovers `.prime/agent/extensions/` with no trust gate, so the restart is only needed when discovery itself was disabled.
3. First cycle only: make the one required `fm_watch_arm_prime` call.
   Use `/fm-watch-arm-prime` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through the bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_prime` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live prime-agent process, and owns every later successor launch.
6. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`, reload) retires only the prior generation; call `fm_watch_arm_prime` once for the first cycle of the replacement session without restarting prime-agent.
   The generation-owner contract lives in `.prime/agent/extensions/fm-primary-prime-watch.ts`.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_prime` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_prime`, and restart prime-agent with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, and a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PRIME_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_PRIME_TURNEND_EXT__`.
The watcher extension lives at `__FM_PRIME_EXT__`.
Both are tracked, project-local `.prime/agent/extensions/*.ts` files that prime-agent auto-discovers; `bin/fm-session-start.sh` reports when the running session has not loaded both required extensions.

One prime-agent-specific fact this protocol depends on: prime-agent has no `agent_settled` event, so the turn-end guard reconstructs the settle from `agent_end`, holding through an auto-retry grace window and skipping an end that has queued messages behind it.
A guard follow-up therefore arrives at the end of a logical run, not at every inner tool loop.
