#!/usr/bin/env bash
# Behavior tests for the prime-agent (Prime Agent) adapter: Pi-family harness
# disambiguation and the crewmate/scout launch shape.
#
# Detection here is a safety boundary rather than a convenience, and it is
# driven from BOTH directions so neither case can go quietly vacuous:
# prime-agent exports the same PI_CODING_AGENT=true as pi, so detection has to
# split the family on a second signal and must still answer `pi` when no such
# signal is present, and `claude` when a stale prime-agent marker appears with
# no Pi-family marker at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
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
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$log" \
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
    --model gpt-5.6-luna --effort low) && status=0 || status=$?
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
  assert_contains "$launch" "--model 'gpt-5.6-luna'" "model flag missing"
  assert_contains "$launch" "--thinking 'low'" "effort did not map onto --thinking"

  assert_grep 'harness=prime-agent' "$home/state/$id.meta" "meta does not record the harness"
  # Deliberately NOT armed: the crew extension carries only the turn-end wake
  # touch, so there is no firstmate writer that could ever clear a seeded busy
  # record.
  assert_absent "$home/state/$id.busy-gen" \
    "spawn armed a busy record prime-agent has no writer to clear"

  pass "prime-agent crewmate spawn loads its own extension and stamps its identity"
}

test_detection_splits_the_pi_family
test_spawn_crewmate_launch_shape
