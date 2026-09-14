#!/usr/bin/env bash
# Opt-in live Prime Agent 0.9.4 adapter regression in an isolated Herdr lab.
# It drives the production spawn-generated extension against a real Prime Agent
# process and never touches the shared default Herdr session or daemon.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRIME_AGENT_LIVE_E2E prime-agent herdr jq

LAB_HELPER=${HERDR_LAB_HELPER:-/home/eduard/Dropbox/Projects/firstmate/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "FM_PRIME_AGENT_LIVE_E2E=1 but the Herdr lab helper is not executable: $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-prime-agent-lib.sh
. "$ROOT/bin/fm-prime-agent-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-prime-agent-live.XXXXXX")
PRIMARY_PROJECT="$LAB/primary-project"
PRIMARY_HOME="$LAB/primary-home"
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WT="$LAB/worktree"
ID=prime-agent-live
FAKEBIN=
LAUNCH_LOG="$LAB/launch.log"
SESSION=$("$LAB_HELPER" name prime-adapter-solid)
PANE=
PRIMARY_PANE=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$PANE" ]; then
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" escape >/dev/null 2>&1 || true
    "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" '/quit' >/dev/null 2>&1 || true
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null 2>&1 || true
  fi
  fm_prime_agent_stop_sessions_under "$WT" >/dev/null 2>&1 || true
  "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT

fm_test_spawn_home "$HOME_DIR" prime-agent
fm_git_worktree "$PROJECT" "$WT" "wt-prime-agent-live"
fm_test_spawn_brief "$HOME_DIR" "$ID" 'Run the requested live adapter checks and reply with PRIME_AGENT_BOOT_OK.'
FAKEBIN=$(make_spawn_fakebin "$LAB/fake" prime-agent)
# Fake tmux lets production fm-spawn render the exact extension and busy record.
# The real process is launched below in the isolated Herdr pane instead.
out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" "$PROJECT" \
  --harness prime-agent --provider openai-codex --model gpt-5.6-terra --effort low \
  --mode direct-PR --yolo off 2>&1) || fail "production spawn generation failed: $out"
[ -f "$HOME_DIR/state/$ID.prime-ext.ts" ] || fail "production spawn did not generate the Prime Agent extension"
LAUNCH=$(sed "s#'$FAKEBIN/prime-agent'#'/home/eduard/.local/bin/prime-agent'#" "$LAUNCH_LOG")
[ "$LAUNCH" != "$(cat "$LAUNCH_LOG")" ] || fail "could not replace the fake Prime Agent executable in the generated launch"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab"
WS=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$WT" --label prime-agent-live --no-focus) \
  || fail "could not create isolated Herdr workspace"
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$LAUNCH" >/dev/null \
  || fail "could not launch the generated Prime Agent command"

for i in $(seq 1 120); do
  screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -q 'version  v0.9.4' \
    && printf '%s\n' "$screen" | grep -q 'GPT-5.6 Terra'; then
    break
  fi
  sleep 0.5
done
printf '%s\n' "$screen" | grep -q 'version  v0.9.4' || fail "Prime Agent 0.9.4 did not render its startup screen"
case "$screen" in
  *"GPT-5.6 Terra"*"low"*) : ;;
  *) fail "generated launch did not render the selected model and thinking level; launch=$LAUNCH screen=$screen" ;;
esac
pass "Prime Agent 0.9.4 rendered the production model/provider/thinking launch"

for i in $(seq 1 120); do
  [ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "idle prime-ext" ] && break
  sleep 0.5
done
[ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "idle prime-ext" ] \
  || fail "generated Prime Agent extension did not settle the launch turn"
[ -f "$HOME_DIR/state/$ID.turn-ended" ] || fail "generated Prime Agent extension did not write turn-end notification"
pass "Prime Agent 0.9.4 loaded the production extension and settled its first turn"

send() {
  "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$1" >/dev/null || return 1
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null || return 1
}
wait_busy() {
  local i
  for i in $(seq 1 80); do
    [ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "busy prime-ext" ] && return 0
    sleep 0.5
  done
  return 1
}
wait_idle() {
  local i
  for i in $(seq 1 100); do
    [ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "idle prime-ext" ] && return 0
    sleep 0.5
  done
  return 1
}
send 'Run the shell command sleep 12, then reply with exactly PRIME_AGENT_SLEEP_OK.' || fail "could not submit the busy probe"
wait_busy || fail "generated Prime Agent extension did not report busy during a real tool call"
agent_busy=$("$LAB_HELPER" run "$SESSION" agent get "$PANE")
printf '%s\n' "$agent_busy" | jq -e '.result.agent.agent_status == "working"' >/dev/null \
  || fail "Herdr did not report working during the real busy probe: $agent_busy"
wait_idle || fail "generated Prime Agent extension did not report idle after the real tool call"
pass "Prime Agent 0.9.4 agent_start/agent_end wiring reports busy and idle"

send 'Run the shell command sleep 20, then reply with exactly PRIME_AGENT_CANCELLED_NO.' || fail "could not submit interrupt probe"
wait_busy || fail "interrupt probe never became busy"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" escape >/dev/null || fail "could not send Escape"
wait_idle || fail "Prime Agent did not settle after Escape"
screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200)
printf '%s\n' "$screen" | grep -q 'Operation aborted' || fail "Escape did not abort the Prime Agent turn: $screen"
pass "Prime Agent 0.9.4 cancels a running turn with one Escape"

send '/quit' || fail "could not submit /quit"
for i in $(seq 1 60); do
  info=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null || true)
  printf '%s\n' "$info" | jq -e '.result.process_info.foreground_processes[0].name == "bash"' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s\n' "$info" | jq -e '.result.process_info.foreground_processes[0].name == "bash"' >/dev/null \
  || fail "Prime Agent /quit did not return the pane to bash"
pass "Prime Agent 0.9.4 exits cleanly and leaves the detached worker for retirement"

"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$LAUNCH" >/dev/null \
  || fail "could not relaunch Prime Agent in the same pane"
for i in $(seq 1 120); do
  screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  printf '%s\n' "$screen" | grep -q 'version  v0.9.4' && break
  sleep 0.5
done
printf '%s\n' "$screen" | grep -q 'version  v0.9.4' || fail "Prime Agent did not relaunch in the same pane"
pass "Prime Agent 0.9.4 relaunches in the same Herdr pane"

# A secondmate is itself a firstmate primary, so verify the two tracked primary
# extensions load in an isolated secondmate-shaped home before enabling it.
mkdir -p "$PRIMARY_PROJECT" "$PRIMARY_HOME/state" "$PRIMARY_HOME/config" "$PRIMARY_HOME/data" "$PRIMARY_HOME/projects"
cp -a "$ROOT/.prime" "$ROOT/.pi" "$ROOT/bin" "$ROOT/AGENTS.md" "$PRIMARY_PROJECT/"
printf '%s\n' "$$" > "$PRIMARY_HOME/state/.lock"
PRIMARY_WS=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PRIMARY_PROJECT" --label prime-secondmate-live --no-focus) \
  || fail "could not create isolated secondmate-shaped Herdr workspace"
PRIMARY_PANE=$(printf '%s' "$PRIMARY_WS" | jq -er '.result.root_pane.pane_id') \
  || fail "secondmate-shaped workspace did not return a pane id"
PRIMARY_CMD="FM_HOME='$PRIMARY_HOME' FM_ROOT_OVERRIDE='$PRIMARY_PROJECT' FM_STATE_OVERRIDE='$PRIMARY_HOME/state' FM_DATA_OVERRIDE='$PRIMARY_HOME/data' FM_CONFIG_OVERRIDE='$PRIMARY_HOME/config' bash -lc 'printf %s \"\$\$\" > \"$PRIMARY_HOME/state/.lock\"; exec env -u CLAUDECODE -u GROK_AGENT -u PI_CODING_AGENT -u FM_PI_HARNESS prime-agent --model gpt-5.6-terra --provider openai-codex --thinking low -e \"$PRIMARY_PROJECT/.prime/agent/extensions/fm-primary-turnend-guard.ts\" -e \"$PRIMARY_PROJECT/.prime/agent/extensions/fm-primary-prime-watch.ts\"'"
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$PRIMARY_CMD" >/dev/null \
  || fail "could not launch the secondmate-shaped Prime Agent primary"
for i in $(seq 1 100); do
  [ -f "$PRIMARY_HOME/state/.prime-turnend-extension-loaded" ] \
    && [ -f "$PRIMARY_HOME/state/.prime-watch-extension-loaded" ] && break
  sleep 0.5
done
[ -f "$PRIMARY_HOME/state/.prime-turnend-extension-loaded" ] \
  || fail "Prime Agent primary turn-end extension did not load in the secondmate-shaped home"
[ -f "$PRIMARY_HOME/state/.prime-watch-extension-loaded" ] \
  || fail "Prime Agent primary watcher extension did not load in the secondmate-shaped home"
pass "Prime Agent 0.9.4 loads both primary supervision extensions for a local secondmate"
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" '/quit' >/dev/null || true
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null || true
fm_prime_agent_stop_sessions_under "$PRIMARY_PROJECT" >/dev/null 2>&1 || true
