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
# missing binary, missing jq, or a refused stop never blocks the caller.

# fm_prime_agent_stop_sessions_under <directory> [label-stream]
# Stops each prime-agent session whose cwd is <directory> or inside it.
# Prints one line per stopped session to stderr.
fm_prime_agent_stop_sessions_under() {  # <directory>
  local dir=$1 resolved ids id
  [ -n "$dir" ] || return 0
  command -v prime-agent >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  resolved=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || resolved=$dir
  ids=$(prime-agent list --json 2>/dev/null \
    | jq -r --arg dir "$resolved" '
        .sessions // []
        | map(select((.cwd // "") == $dir or ((.cwd // "") | startswith($dir + "/"))))
        | map(select((.lifecycle // "") != "stopped"))
        | .[].id // empty' 2>/dev/null) || return 0
  while IFS= read -r id; do
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    echo "prime-agent: stopping detached session $id bound to $resolved" >&2
    prime-agent stop "$id" >/dev/null 2>&1 || true
  done <<EOF
$ids
EOF
}
