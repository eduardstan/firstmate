#!/usr/bin/env bash
# fm-prime-agent-lib.sh - the ONE owner of retiring prime-agent's detached
# daemon sessions.
#
# prime-agent runs every root session in a detached daemon worker under one
# per-user supervisor. Closing the pane detaches the client, and so does an
# explicit `/quit`: both leave the worker running, holding its launch directory
# as cwd and a lease on its transcript (verified 2026-08-08 on prime-agent
# 0.7.1 - a torn-down task's session was still `lifecycle=live` on that
# worktree, and a quit session stayed `live` too). Killing the endpoint
# therefore does NOT end the agent.
#
# Two callers need the same retirement, which is why it lives here rather than
# in either of them:
#   - bin/fm-teardown.sh, before its generic leaked-process reaper, so the
#     worker ends through prime-agent instead of being SIGTERMed out from under
#     its own lease and journals.
#   - bin/fm-spawn.sh --secondmate, before relaunching a prime-agent home, so a
#     worker abandoned by a dead pane cannot keep holding that home's session
#     lock and force every relaunch into read-only mode.
#
# Selection is by the session's recorded cwd: the task worktree or secondmate
# home itself, or a path inside it. Deliberately never `prime-agent shutdown`,
# which stops the captain's own sessions and every other home's workers too -
# the daemon is fleet-wide, one supervisor per user.
#
# `prime-agent status` is deliberately NOT consulted: it marks even a live
# session's forkserver `stale`, so that word is not a health signal.
#
# Sourcing: set -u and set -e safe. Every failure path is a silent no-op, so a
# missing binary, missing jq, a hit timeout, or a refused stop never blocks the
# caller.

FM_PRIME_AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F fm_run_timed >/dev/null 2>&1 \
  && [ -r "$FM_PRIME_AGENT_LIB_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$FM_PRIME_AGENT_LIB_DIR/fm-timeout-lib.sh"
fi

# Every prime-agent CLI call goes through here, BOUNDED. `list` makes the
# supervisor refresh every worker's summaries and sync agent peers before it
# answers, so an unbounded call would let a wedged daemon socket stall whichever
# caller asked - including bin/fm-lock.sh, and therefore session start. A hit
# bound is just another unknown: the callers below already fail safe on one.
fm_prime_agent_cli() {  # <arg>...
  local bound=${FM_PRIME_AGENT_CLI_TIMEOUT:-5}
  case "$bound" in ''|*[!0-9]*|0) bound=5 ;; esac
  if declare -F fm_run_timed >/dev/null 2>&1; then
    fm_run_timed "$bound" prime-agent "$@"
  else
    prime-agent "$@"
  fi
}

# fm_prime_agent_stop_sessions_under <directory> [label-stream]
# Stops each prime-agent session whose cwd is <directory> or inside it.
# Prints one line per stopped session to stderr.
fm_prime_agent_stop_sessions_under() {  # <directory>
  local dir=$1 resolved ids id
  [ -n "$dir" ] || return 0
  command -v prime-agent >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  resolved=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || resolved=$dir
  ids=$(fm_prime_agent_cli list --json 2>/dev/null \
    | jq -r --arg dir "$resolved" '
        .sessions // []
        | map(select((.cwd // "") == $dir or ((.cwd // "") | startswith($dir + "/"))))
        | map(select((.lifecycle // "") != "stopped"))
        | .[].id // empty' 2>/dev/null) || return 0
  while IFS= read -r id; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    echo "prime-agent: stopping detached session $id bound to $resolved" >&2
    fm_prime_agent_cli stop "$id" >/dev/null 2>&1 || true
  done <<EOF
$ids
EOF
}

# fm_prime_agent_worker_abandoned <pid>
# True (0) only when <pid> is a prime-agent DAEMON SESSION WORKER that no client
# is attached to any more.
#
# The session lock records the harness ancestor pid, which for prime-agent is
# that worker rather than the client, and the worker outlives both the pane and
# an explicit /quit. Liveness of the pid alone therefore cannot answer "is a
# firstmate session still running here?": after an in-place restart the previous
# worker is still a live `prime-agent` process while its session has no operator
# at all, and the new session would be refused its own home's lock forever.
#
# `attachedClients` is the vendor's own count of live client connections to the
# session (dist bundle: `attachedClients: activeSession.clients.size`), so zero
# is exactly "no client is driving this session". Every unknown - no binary, no
# jq, an unparseable listing, a hit timeout, or a pid that is not a session
# worker at all - answers 1 (NOT abandoned), so the caller keeps its existing
# refusal and this never widens who may take a lock.
#
# One worker hosts MANY sessions and every one of them carries that worker's
# pid, including subagent/RLM children no client ever attaches to. The verdict
# is therefore the MAXIMUM client count across all of the worker's sessions:
# "abandoned" means no client is attached to any of them, so a single
# zero-client child can never speak for a session an operator is still driving.
fm_prime_agent_worker_abandoned() {  # <pid>
  local pid=$1 clients
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  command -v prime-agent >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  clients=$(fm_prime_agent_cli list --json 2>/dev/null \
    | jq -r --arg pid "$pid" '
        .sessions // []
        | map(select(((.workerPid // "") | tostring) == $pid))
        | if length == 0 then empty else (map(.attachedClients // 0) | max) end' 2>/dev/null) || return 1
  case "$clients" in ''|*[!0-9]*) return 1 ;; esac
  [ "$clients" -eq 0 ]
}
