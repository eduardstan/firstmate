#!/usr/bin/env bash
# Behavior tests for the prime-agent (Prime Agent) adapter: Pi-family harness
# disambiguation, the crewmate and secondmate launch shapes, composer
# classification of its bare `>` prompt, and retirement of its DETACHED daemon
# session by both callers that need it (teardown, and secondmate relaunch).
#
# Two properties here are safety boundaries rather than conveniences, and both
# are driven from BOTH directions so neither case can go quietly vacuous:
#   - prime-agent exports the same PI_CODING_AGENT=true as pi, so detection has
#     to split the family on a second signal and must still answer `pi` when no
#     such signal is present.
#   - prime-agent's composer prompt glyph is a plain `>`, which the fleet-wide
#     composer rule treats as a DEAD SHELL on an unstructured row. It may read
#     as an empty agent composer only inside a real composer container.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-prime-agent-harness)

# --- detection --------------------------------------------------------------

detect() {  # <env assignment>...
  env -u CLAUDECODE -u GROK_AGENT -u FM_PI_HARNESS \
    -u PRIME_AGENT_CODING_AGENT_DIR -u PRIME_AGENT_INTERNAL_DAEMON_WORKER \
    "$@" "$HARNESS"
}

test_detection_splits_the_pi_family() {
  local out

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent)
  [ "$out" = prime-agent ] || fail "FM_PI_HARNESS=prime-agent did not select prime-agent (got '$out')"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/home/x/.prime/agent)
  [ "$out" = prime-agent ] || fail "prime-agent's own tool-subprocess marker did not select it (got '$out')"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_INTERNAL_DAEMON_WORKER=1)
  [ "$out" = prime-agent ] || fail "prime-agent's daemon-worker marker did not select it (got '$out')"

  # The other direction: the SAME PI_CODING_AGENT marker with no prime-agent
  # signal must still be pi, or every existing Pi worker would be relabelled.
  out=$(detect PI_CODING_AGENT=true)
  [ "$out" = pi ] || fail "unmarked Pi-family ancestry stopped resolving to pi (got '$out')"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$out" = pi-signed ] || fail "pi-signed selection regressed (got '$out')"

  # FM_PI_HARNESS is subject to the SAME supervisor inheritance as CLAUDECODE:
  # a supervisor first started from a pi-signed worker hands it to every later
  # prime-agent worker. The per-tool-call vendor marker must therefore outrank
  # it too, or that worker reports itself as a Pi it is not.
  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = prime-agent ] \
    || fail "an inherited FM_PI_HARNESS outranked prime-agent's own marker (got '$out')"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi PRIME_AGENT_INTERNAL_DAEMON_WORKER=1 CLAUDECODE=1)
  [ "$out" = prime-agent ] \
    || fail "an inherited launch stamp plus CLAUDECODE outranked the daemon-worker marker (got '$out')"

  # An empty marker value is not a marker.
  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=)
  [ "$out" = pi ] || fail "an empty prime-agent marker was treated as present (got '$out')"

  # prime-agent's resident worker inherits the long-lived daemon supervisor's
  # environment, so a CLAUDECODE captured by that supervisor reaches every
  # later prime-agent tool subprocess and no launch-side clear can remove it.
  # The vendor marker must therefore outrank it.
  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/x CLAUDECODE=1)
  [ "$out" = prime-agent ] \
    || fail "an inherited CLAUDECODE outranked prime-agent's own marker (got '$out')"

  # The other direction, so the precedence flip is not a blanket one: a lone
  # stale PRIME_AGENT_* with no Pi-family marker must not relabel claude.
  out=$(detect CLAUDECODE=1 PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = claude ] \
    || fail "a stale prime-agent marker alone outranked claude (got '$out')"

  out=$(detect CLAUDECODE=1)
  [ "$out" = claude ] || fail "claude detection regressed (got '$out')"

  pass "detection splits prime-agent from pi without relabelling unmarked Pi or claude sessions"
}

# --- spawn ------------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_EXISTING_WINDOW"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> -> case_dir|home|proj|wt|fakebin|id
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="prime-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <launch-log> <args>...
  local home=$1 proj=$2 wt=$3 fakebin=$4 log=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_NICE=0 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$log" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_crewmate_launch_shape() {
  local case_dir home proj wt fakebin id log out status launch ext
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case launch)
  log="$case_dir/launch.log"
  : > "$log"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --scout --harness prime-agent \
    --provider openai-codex --model gpt-5.6-luna --effort low \
    --autonomous-gate 'bin/fm-lint.sh' \
    --autonomous-gate 'tests/fm-prime-agent-harness.test.sh' \
    --autonomous-max-continuations 30 --autonomous-max-turns 120 \
    --autonomous-max-tokens 600000 --autonomous-timeout-ms 18000000 \
    --autonomous-gate-retries 7 --autonomous-gate-timeout-ms 1200000) && status=0 || status=$?
  expect_code 0 "$status" "prime-agent scout spawn failed: $out"

  launch=$(grep -F 'prime-agent' "$log" | tail -1)
  [ -n "$launch" ] || fail "no prime-agent launch command was sent to the pane"

  ext="$home/state/$id.prime-ext.ts"
  assert_present "$ext" "spawn did not write the prime-agent extension"
  # The launch must load the extension file the spawn actually wrote: a path
  # disagreement would silently leave the pane with no busy source at all.
  assert_contains "$launch" "-e '$ext'" "launch does not load the extension spawn wrote"
  # The launch-boundary identity marker is what lets a tool subprocess tell
  # prime-agent apart from pi (see test_detection_splits_the_pi_family).
  assert_contains "$launch" 'FM_PI_HARNESS=prime-agent' "launch does not stamp the Pi-family identity"
  # A foreign primary marker left in the backend daemon's stored environment
  # outranks the whole Pi family in bin/fm-harness.sh, so the launch must clear
  # it or the crewmate reports itself as that other harness.
  assert_contains "$launch" 'env -u CLAUDECODE -u GROK_AGENT' \
    "launch does not clear foreign primary harness markers"
  assert_not_contains "$launch" '-u FM_PI_HARNESS' \
    "launch clears the very identity marker it just set"
  assert_contains "$launch" "--provider 'openai-codex'" "provider flag missing"
  assert_contains "$launch" "--model 'gpt-5.6-luna'" "model flag missing"
  assert_contains "$launch" "--thinking 'low'" "effort did not map onto --thinking"
  assert_contains "$launch" "--autonomous --autonomous-gate 'bin/fm-lint.sh' --autonomous-gate 'tests/fm-prime-agent-harness.test.sh'" \
    "repeatable gates did not imply autonomous mode in order"
  assert_contains "$launch" "--autonomous-max-continuations '30' --autonomous-max-turns '120' --autonomous-max-tokens '600000' --autonomous-timeout-ms '18000000' --autonomous-gate-retries '7' --autonomous-gate-timeout-ms '1200000'" \
    "explicit autonomous limits did not reach prime-agent"

  assert_grep 'harness=prime-agent' "$home/state/$id.meta" "meta does not record the harness"
  assert_grep 'provider=openai-codex' "$home/state/$id.meta" "meta does not record the provider"
  [ "$(grep -c '^autonomous_gate=' "$home/state/$id.meta")" -eq 2 ] \
    || fail "meta does not record both autonomous gates"
  assert_grep 'autonomous_max_continuations=30' "$home/state/$id.meta" "meta does not record the continuation limit"
  assert_grep 'autonomous_max_turns=120' "$home/state/$id.meta" "meta does not record the turn limit"
  assert_grep 'autonomous_max_tokens=600000' "$home/state/$id.meta" "meta does not record the token limit"
  assert_grep 'autonomous_timeout_ms=18000000' "$home/state/$id.meta" "meta does not record the wall-clock limit"
  assert_grep 'autonomous_gate_retries=7' "$home/state/$id.meta" "meta does not record gate retries"
  assert_grep 'autonomous_gate_timeout_ms=1200000' "$home/state/$id.meta" "meta does not record gate timeout"
  # Deliberately NOT armed: prime-agent's own built-in Herdr reporter already
  # publishes pane state, so there is no firstmate writer that could ever clear
  # a seeded busy record.
  assert_absent "$home/state/$id.busy-gen" \
    "spawn armed a busy record prime-agent has no writer to clear"

  pass "prime-agent crewmate spawn loads its own extension and stamps its identity"
}

test_gated_spawn_supplies_long_horizon_defaults() {
  local case_dir home proj wt fakebin id log out status launch meta
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case gate-defaults)
  log="$case_dir/launch.log"
  : > "$log"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --scout --harness prime-agent \
    --autonomous-gate 'bin/fm-lint.sh') && status=0 || status=$?
  expect_code 0 "$status" "prime-agent gated scout spawn failed: $out"

  launch=$(grep -F 'prime-agent' "$log" | tail -1)
  assert_contains "$launch" "--autonomous-max-continuations '24'" "gated launch inherited Prime's small continuation default"
  assert_contains "$launch" "--autonomous-max-turns '96'" "gated launch inherited Prime's small turn default"
  assert_contains "$launch" "--autonomous-max-tokens '500000'" "gated launch inherited Prime's small token default"
  assert_contains "$launch" "--autonomous-timeout-ms '14400000'" "gated launch inherited Prime's short timeout default"
  assert_contains "$launch" "--autonomous-gate-retries '5'" "gated launch did not receive Firstmate's retry default"
  assert_contains "$launch" "--autonomous-gate-timeout-ms '900000'" "gated launch did not receive Firstmate's gate timeout default"
  meta="$home/state/$id.meta"
  assert_grep 'autonomous_max_continuations=24' "$meta" "meta does not record the resolved continuation default"
  assert_grep 'autonomous_max_turns=96' "$meta" "meta does not record the resolved turn default"
  assert_grep 'autonomous_max_tokens=500000' "$meta" "meta does not record the resolved token default"
  assert_grep 'autonomous_timeout_ms=14400000' "$meta" "meta does not record the resolved timeout default"
  assert_grep 'autonomous_gate_retries=5' "$meta" "meta does not record the resolved retry default"
  assert_grep 'autonomous_gate_timeout_ms=900000' "$meta" "meta does not record the resolved gate timeout default"

  pass "a gated prime-agent spawn receives explicit long-horizon limits"
}

test_gate_limits_require_positive_integers() {
  local case_dir home proj wt fakebin id log out status bad flag
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case invalid-gate-limits)
  log="$case_dir/launch.log"
  : > "$log"
  for flag in --autonomous-gate-retries --autonomous-gate-timeout-ms; do
    for bad in 0 -1 nope; do
      out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
        "$id" "$proj" --scout --harness prime-agent --autonomous-gate 'bin/fm-lint.sh' \
        "$flag" "$bad") && status=0 || status=$?
      [ "$status" -ne 0 ] || fail "$flag accepted invalid value '$bad'"
      assert_contains "$out" "$flag requires a positive integer" \
        "$flag reported the wrong validation error for '$bad'"
    done
  done
  pass "gate retry and timeout limits require positive integers"
}

test_provider_reaches_pi_which_also_exposes_the_axis() {
  local case_dir home proj wt fakebin id log out status launch
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case provider-pi)
  log="$case_dir/launch.log"
  : > "$log"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --scout --harness pi \
    --provider openai-codex --model openai-codex/gpt-5.6-sol) && status=0 || status=$?
  expect_code 0 "$status" "Pi spawn with a provider failed: $out"

  launch=$(grep -F ' pi ' "$log" | tail -1)
  assert_contains "$launch" "--provider 'openai-codex'" "Pi launch dropped a provider flag its CLI exposes"
  assert_grep 'provider=openai-codex' "$home/state/$id.meta" "meta does not record the provider for Pi"

  pass "the provider axis reaches every harness whose CLI exposes it, not just prime-agent"
}

test_provider_is_recorded_but_omitted_for_an_unsupported_harness() {
  local case_dir home proj wt fakebin id log out status launch
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case provider-omitted)
  log="$case_dir/launch.log"
  : > "$log"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --scout --harness claude \
    --provider openai-codex --model sonnet) && status=0 || status=$?
  expect_code 0 "$status" "Claude spawn with recorded provider axis failed: $out"

  launch=$(grep -F 'claude ' "$log" | tail -1)
  assert_not_contains "$launch" '--provider' "Claude launch guessed a provider flag its CLI does not expose"
  assert_contains "$launch" "--model 'sonnet'" "the supported model axis stopped reaching Claude"
  assert_grep 'provider=openai-codex' "$home/state/$id.meta" "unsupported harness meta dropped the provider axis"

  pass "unsupported harnesses record the provider axis without receiving it"
}

test_no_mistakes_refuses_duplicate_gate_ownership() {
  local case_dir home proj wt fakebin id log out status
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case no-mistakes-gate)
  log="$case_dir/launch.log"
  : > "$log"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --harness prime-agent --mode no-mistakes --yolo off \
    --autonomous-gate 'bin/fm-lint.sh') && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "no-mistakes spawn accepted a harness-level autonomous gate"
  assert_contains "$out" 'no-mistakes pipeline owns its own gates and branch custody' \
    "gate refusal did not name duplicate gate ownership and branch custody"
  assert_absent "$home/state/$id.meta" "refused no-mistakes gate still published task metadata"

  pass "no-mistakes refuses duplicate harness-level gate ownership before spawn"
}

test_help_lists_prime_launch_axes() {
  local out
  out=$("$SPAWN" --help)
  for flag in --provider --autonomous-gate --autonomous-max-continuations \
    --autonomous-max-turns --autonomous-max-tokens --autonomous-timeout-ms \
    --autonomous-gate-retries --autonomous-gate-timeout-ms; do
    assert_contains "$out" "$flag" "spawn help omitted $flag"
  done
  pass "spawn help documents the provider and autonomous gate axes"
}

test_secondmate_launch_loads_both_primary_extensions() {
  local case_dir home proj wt fakebin id log out status launch subhome calls
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case secondmate)
  log="$case_dir/launch.log"
  : > "$log"
  subhome="$case_dir/subhome"
  mkdir -p "$subhome/state" "$subhome/config" "$subhome/projects" "$subhome/bin" "$subhome/data"
  printf '# scratch secondmate home\n' > "$subhome/AGENTS.md"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'scratch charter\n' > "$subhome/data/charter.md"

  # A prime-agent session still bound to this home from a dead pane. The lock
  # this home writes records that detached worker's pid, so a relaunch that
  # left it running would land read-only forever.
  calls="$case_dir/prime-calls.log"
  : > "$calls"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
if [ "\${1:-}" = list ]; then
  printf '{"sessions":[{"id":"stale1","activeSessionId":"stale1","lifecycle":"live","cwd":"%s"},{"id":"other1","activeSessionId":"other1","lifecycle":"live","cwd":"%s"}]}\n' \\
    '$subhome' '$case_dir/elsewhere'
fi
exit 0
SH
  chmod +x "$fakebin/prime-agent"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$subhome" --harness prime-agent --secondmate) && status=0 || status=$?
  expect_code 0 "$status" "prime-agent secondmate spawn failed: $out"

  launch=$(grep -F 'prime-agent' "$log" | tail -1)
  [ -n "$launch" ] || fail "no prime-agent secondmate launch command was sent to the pane"
  assert_contains "$launch" "-e '$subhome/.prime/agent/extensions/fm-primary-turnend-guard.ts'" \
    "secondmate launch does not load the turn-end guard extension"
  assert_contains "$launch" "-e '$subhome/.prime/agent/extensions/fm-primary-prime-watch.ts'" \
    "secondmate launch does not load the watcher extension"
  # The crew turn-end extension belongs to a crewmate, not a primary.
  assert_not_contains "$launch" '.prime-ext.ts' \
    "secondmate launch loaded the per-task crew extension"
  # A secondmate's task metadata is owned by the PARENT home, not the child.
  assert_grep 'kind=secondmate' "$home/state/$id.meta" "secondmate meta was not published"
  assert_grep 'harness=prime-agent' "$home/state/$id.meta" "secondmate meta does not record the harness"

  assert_grep 'stop stale1' "$calls" \
    "relaunch left the detached worker bound to this home running, which would hold its session lock"
  assert_no_grep 'stop other1' "$calls" "relaunch stopped a session bound to another directory"
  assert_no_grep 'shutdown' "$calls" "relaunch used the fleet-wide prime-agent shutdown"

  pass "prime-agent secondmate launches with both primary extensions and retires the home's stale worker"
}

test_secondmate_relaunch_refuses_failed_retirement() {
  local case_dir home proj wt fakebin id log out status subhome calls
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case retirement-failure)
  log="$case_dir/launch.log"
  : > "$log"
  subhome="$case_dir/subhome"
  mkdir -p "$subhome/state" "$subhome/config" "$subhome/projects" "$subhome/bin" "$subhome/data"
  printf '# scratch secondmate home\n' > "$subhome/AGENTS.md"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'scratch charter\n' > "$subhome/data/charter.md"
  calls="$case_dir/prime-calls.log"
  : > "$calls"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
if [ "\${1:-}" = list ]; then
  printf '{"sessions":[{"id":"stale1","activeSessionId":"stale1","lifecycle":"live","cwd":"%s"}]}\n' '$subhome'
fi
if [ "\${1:-}" = stop ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/prime-agent"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$subhome" --harness prime-agent --secondmate) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "prime-agent secondmate relaunched after retirement failed"
  assert_contains "$out" "refusing secondmate relaunch" \
    "failed retirement did not produce the relaunch refusal"
  assert_grep 'stop stale1' "$calls" "strict retirement did not attempt the resident session stop"
  assert_no_grep 'prime-agent' "$log" "failed retirement still delivered a second prime-agent launch"

  pass "prime-agent secondmate relaunch fails closed on retirement failure"
}

test_secondmate_launch_succeeds_without_daemon() {
  local case_dir home proj wt fakebin id log out status subhome
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case no-daemon)
  log="$case_dir/launch.log"
  : > "$log"
  subhome="$case_dir/subhome"
  mkdir -p "$subhome/state" "$subhome/config" "$subhome/projects" "$subhome/bin" "$subhome/data"
  printf '# scratch secondmate home\n' > "$subhome/AGENTS.md"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'scratch charter\n' > "$subhome/data/charter.md"
  cat > "$fakebin/prime-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/prime-agent"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$subhome" --harness prime-agent --secondmate) && status=0 || status=$?
  expect_code 0 "$status" "prime-agent secondmate spawn failed without a daemon: $out"
  assert_grep 'prime-agent' "$log" "prime-agent secondmate was not launched without a daemon"

  pass "prime-agent secondmate launch treats an absent daemon as nothing to retire"
}

test_duplicate_secondmate_spawn_preserves_live_worker() {
  local case_dir home proj wt fakebin id log out status subhome calls
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case duplicate-secondmate)
  log="$case_dir/launch.log"
  : > "$log"
  subhome="$case_dir/subhome"
  mkdir -p "$subhome/state" "$subhome/config" "$subhome/projects" "$subhome/bin" "$subhome/data"
  printf '# scratch secondmate home\n' > "$subhome/AGENTS.md"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'scratch charter\n' > "$subhome/data/charter.md"
  calls="$case_dir/prime-calls.log"
  : > "$calls"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
if [ "\${1:-}" = list ]; then
  printf '{"sessions":[{"id":"live1","activeSessionId":"live1","lifecycle":"live","cwd":"%s"}]}\n' '$subhome'
fi
exit 0
SH
  chmod +x "$fakebin/prime-agent"

  out=$(FM_FAKE_EXISTING_WINDOW="fm-$id" run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$subhome" --harness prime-agent --secondmate) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "duplicate prime-agent secondmate spawn unexpectedly succeeded"
  assert_contains "$out" "window firstmate:fm-$id already exists" \
    "duplicate secondmate spawn did not reach endpoint validation"
  assert_no_grep 'stop live1' "$calls" "duplicate spawn stopped the live secondmate worker before refusing"

  pass "duplicate secondmate spawn preserves the live prime-agent worker"
}

test_primary_extensions_ignore_inline_child_sessions() {
  local fixture plugin home out status
  fixture="$TMP_ROOT/primary-session-scope"
  plugin="$fixture/.prime/agent/extensions/fm-primary-turnend-guard.ts"
  home="$fixture/home"
  mkdir -p "$fixture/.prime/agent/extensions" "$fixture/.pi/extensions/lib" "$fixture/bin" "$home/state"
  # Copying a source that is not there leaves the fixture half-built, and the
  # node run then fails as a bare exit 1 that names nothing. Say which tracked
  # file the checkout is missing instead.
  for src in .prime/agent/extensions/fm-primary-turnend-guard.ts \
    .pi/extensions/lib/fm-operational-input.ts bin/fm-operational-input.sh; do
    [ -f "$ROOT/$src" ] || fail "this checkout is missing the tracked fixture source $src"
  done
  cp "$ROOT/.prime/agent/extensions/fm-primary-turnend-guard.ts" "$plugin"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$fixture/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/fm-operational-input.sh"
  cat > "$fixture/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'sessionstart %s\n' "$*" >> "${FM_EVENT_LOG:?}"
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_EVENT_LOG:?}"
printf 'recover watcher\n' >&2
exit 2
SH
  cat > "$fixture/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'cd-check %s\n' "$*" >> "${FM_EVENT_LOG:?}"
SH
  cat > "$fixture/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm-check %s\n' "$*" >> "${FM_EVENT_LOG:?}"
SH
  chmod +x "$fixture/bin/"*.sh
  : > "$fixture/events.log"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$home/state" FM_EVENT_LOG="$fixture/events.log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let followups = 0;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
  sendUserMessage: async () => { followups += 1; },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const parentCtx = { sessionManager: {}, hasPendingMessages: () => false };
const childCtx = { sessionManager: {}, hasPendingMessages: () => false };

await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, parentCtx);
await handlers.get("session_start")?.({ type: "session_start", reason: "new" }, childCtx);
await handlers.get("session_compact")?.({ type: "session_compact" }, childCtx);
await handlers.get("tool_call")?.({ type: "tool_call", toolName: "bash", input: { command: "pwd" } }, childCtx);
await handlers.get("agent_start")?.({ type: "agent_start" }, parentCtx);
await handlers.get("agent_end")?.({ type: "agent_end", messages: [] }, childCtx);
if (followups !== 0) throw new Error("an inline child agent_end ran the parent's settle guard");
await handlers.get("agent_end")?.({ type: "agent_end", messages: [] }, parentCtx);
if (followups !== 1) throw new Error(`the parent settle guard sent ${followups} follow-ups`);
await handlers.get("tool_call")?.({ type: "tool_call", toolName: "bash", input: { command: "pwd" } }, parentCtx);

const rows = readFileSync(process.env.FM_EVENT_LOG, "utf8").trim().split("\n");
if (rows.filter((row) => row.startsWith("sessionstart ")).length !== 1) {
  throw new Error(`inline child lifecycle invoked session-start delivery: ${rows.join(" | ")}`);
}
if (rows.filter((row) => row === "guard").length !== 1) {
  throw new Error(`settle guard invocation count was not parent-scoped: ${rows.join(" | ")}`);
}
if (rows.filter((row) => row.startsWith("cd-check ")).length !== 1 || rows.filter((row) => row.startsWith("arm-check ")).length !== 1) {
  throw new Error(`tool checks were not parent-scoped: ${rows.join(" | ")}`);
}
EOF
  )
  status=$?
  expect_code 0 "$status" "prime-agent primary extensions must ignore inline child sessions"
  [ -z "$out" ] || fail "prime-agent primary session-scope test printed output: $out"

  pass "prime-agent primary extensions ignore inline child sessions"
}

# --- composer safety rule ----------------------------------------------------

classify_content() {  # <bordered> <content>
  bash -c '. "$1"; fm_composer_classify_content "$2" "$3"' \
    _ "$ROOT/bin/fm-composer-lib.sh" "$1" "$2"
}

test_bare_prompt_stays_a_dead_shell() {
  local out
  # prime-agent's prompt glyph inside a proven composer container reads empty,
  # which is what makes a mid-turn steer verifiable.
  out=$(classify_content 1 '>')
  [ "$out" = empty ] || fail "'>' inside a composer container did not read empty (got '$out')"
  out=$(classify_content 1 '> half-typed steer')
  [ "$out" = pending ] || fail "typed text in a prime-agent composer did not read pending (got '$out')"
  # The safety rule itself: the same glyph on an unstructured row is a login
  # shell, never an injection target. Adding this adapter must not relax it.
  out=$(classify_content 0 '>')
  [ "$out" = unknown ] || fail "a bare '>' shell prompt became an injection target (got '$out')"

  pass "prime-agent's '>' composer reads empty only inside a proven container"
}

# --- teardown ----------------------------------------------------------------

test_teardown_stops_the_detached_session() {
  local case_dir home proj wt fakebin id log out status calls other
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case teardown)
  log="$case_dir/launch.log"
  : > "$log"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --scout --harness prime-agent) && status=0 || status=$?
  expect_code 0 "$status" "prime-agent spawn failed: $out"
  assert_present "$home/state/$id.prime-ext.ts" "spawn did not write the extension"

  # A fake prime-agent whose session list contains BOTH this task's worktree
  # and another home's, so the selection is proven to discriminate rather than
  # stopping whatever it finds.
  calls="$case_dir/prime-calls.log"
  other="$case_dir/someone-elses-worktree"
  : > "$calls"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
if [ "\${1:-}" = list ]; then
  printf '{"sessions":[{"id":"mine01","lifecycle":"live","cwd":"%s"},{"id":"theirs9","lifecycle":"live","cwd":"%s"}]}\n' \\
    '$wt' '$other'
fi
if [ "\${1:-}" = stop ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/prime-agent"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "prime-agent teardown failed"

  assert_grep 'stop mine01' "$calls" "teardown did not stop the session bound to this worktree"
  assert_no_grep 'stop theirs9' "$calls" "teardown stopped another worktree's session"
  # `shutdown` would stop the captain's own sessions and every other home's
  # workers: one supervisor serves the whole user.
  assert_no_grep 'shutdown' "$calls" "teardown used the fleet-wide prime-agent shutdown"
  assert_absent "$home/state/$id.prime-ext.ts" "the prime-agent extension survived teardown"

  pass "teardown stops only this worktree's prime-agent session and removes its extension"
}

test_teardown_stops_a_secondmate_homes_detached_session() {
  local case_dir home proj wt fakebin id log out status calls subhome other
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case teardown-secondmate)
  log="$case_dir/launch.log"
  : > "$log"
  subhome="$case_dir/subhome"
  other="$case_dir/someone-elses-home"
  mkdir -p "$subhome/state" "$subhome/config" "$subhome/projects" "$subhome/bin" "$subhome/data"
  printf '# scratch secondmate home\n' > "$subhome/AGENTS.md"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'scratch charter\n' > "$subhome/data/charter.md"

  calls="$case_dir/prime-calls.log"
  : > "$calls"
  cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$calls'
if [ "\${1:-}" = list ]; then
  printf '{"sessions":[{"id":"inhome","lifecycle":"live","cwd":"%s"},{"id":"theirs9","lifecycle":"live","cwd":"%s"}]}\n' \\
    '$subhome' '$other'
fi
exit 0
SH
  chmod +x "$fakebin/prime-agent"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$subhome" --harness prime-agent --secondmate) && status=0 || status=$?
  expect_code 0 "$status" "prime-agent secondmate spawn failed: $out"

  # Only the teardown's own calls, so the relaunch retirement cannot be
  # mistaken for this one.
  : > "$calls"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "prime-agent secondmate teardown failed"

  # The home is returned to the pool or removed here, so a worker still holding
  # it as cwd would follow the worktree into its next task.
  assert_grep 'stop inhome' "$calls" \
    "secondmate teardown left the detached worker bound to the removed home running"
  assert_no_grep 'stop theirs9' "$calls" "secondmate teardown stopped another home's session"
  assert_no_grep 'shutdown' "$calls" "secondmate teardown used the fleet-wide prime-agent shutdown"

  pass "teardown of a secondmate home retires the prime-agent worker bound to it"
}

test_detection_splits_the_pi_family
test_spawn_crewmate_launch_shape
test_gated_spawn_supplies_long_horizon_defaults
test_gate_limits_require_positive_integers
test_provider_reaches_pi_which_also_exposes_the_axis
test_provider_is_recorded_but_omitted_for_an_unsupported_harness
test_no_mistakes_refuses_duplicate_gate_ownership
test_help_lists_prime_launch_axes
test_secondmate_launch_loads_both_primary_extensions
test_secondmate_relaunch_refuses_failed_retirement
test_secondmate_launch_succeeds_without_daemon
test_duplicate_secondmate_spawn_preserves_live_worker
test_primary_extensions_ignore_inline_child_sessions
test_bare_prompt_stays_a_dead_shell
test_teardown_stops_the_detached_session
test_teardown_stops_a_secondmate_homes_detached_session
