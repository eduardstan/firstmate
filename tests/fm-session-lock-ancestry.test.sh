#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-prime-agent-lib.sh" "$dir/bin/fm-prime-agent-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
  # A lab checkout carries only the copied dependency set, so a lib that grew a
  # new sibling must not start writing sourcing errors into the hook output the
  # session reads.
  assert_no_grep 'No such file or directory' "$dir/state/hook.out" \
    "the hook wrote a missing-dependency error into its own output"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# prime-agent's session runs in a DETACHED daemon worker, so the pid the lock
# records outlives the pane and an explicit /quit. An in-place restart - what
# bin/fm-session-start.sh and the supervision protocol both tell the operator
# to do - therefore meets a live `prime-agent` process holding its own home's
# lock. Liveness for this harness has to mean "a session someone is still
# attached to", which is what the vendor's own attachedClients count answers.
test_abandoned_prime_agent_worker_never_blocks_its_home() {
  local dir fakebin lockbin old new out status lock_after case_id sessions start elapsed
  dir="$TMP_ROOT/prime-detached-worker"
  fakebin=$(fm_fakebin "$dir/bin")
  lockbin="$dir/worker-bin"
  mkdir -p "$dir/state" "$lockbin"
  # Two REAL processes named prime-agent: the abandoned worker the lock still
  # names, and this restart's worker. `kill -0` must genuinely succeed for both,
  # so the reclaim can only come from the attachment answer.
  cp "$(command -v sleep)" "$lockbin/prime-agent"
  "$lockbin/prime-agent" 120 & old=$!
  "$lockbin/prime-agent" 120 & new=$!
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  $old:comm=|$new:comm=) printf '%s\n' prime-agent ;;
  $old:args=|$new:args=) printf '%s\n' 'prime-agent' ;;
  $old:ppid=|$new:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' $new ;;
esac
SH
  chmod +x "$fakebin/ps"

  # One worker hosts every session it forked, all stamped with its own pid, and
  # a subagent child never has a client. `attached-behind-subagent` puts such a
  # zero-client child FIRST in the listing, so a verdict read off one arbitrary
  # entry would hand this home's lock away while its operator is still working.
  # `mid-turn-detached` and `unknown-activity` are the other half of the same
  # question: a pane that died mid-turn leaves NO client attached while the
  # worker keeps writing the home, so client count alone would invite a second
  # writer into the same worktree.
  # The listing carries TWO session shapes under one worker pid, and the cases
  # below use both as the daemon renders them: a RESIDENT session publishes
  # every activity flag and an activeSessionId, while a persisted non-resident
  # RLM child publishes neither the activeSessionId nor the three active-only
  # flags and is idle by construction.
  local idle busy passive
  idle='"activeSessionId":"a1","isSessionActive":false,"isStreaming":false,"isCompacting":false,"isRunningTools":false,"isBashRunning":false,"hasRunningRlmChildren":false,"unfinishedActionCount":0'
  busy='"activeSessionId":"a1","isSessionActive":true,"isStreaming":true,"isCompacting":false,"isRunningTools":true,"isBashRunning":false,"hasRunningRlmChildren":false,"unfinishedActionCount":1'
  passive='"lifecycle":"archived","activity":"idle","isSessionActive":false,"isStreaming":false,"isCompacting":false,"unfinishedActionCount":0'
  for case_id in abandoned abandoned-behind-passive-subagent attached attached-behind-subagent \
    mid-turn-detached unknown-activity no-resident-session wedged-daemon; do
    case "$case_id" in
      abandoned) sessions="{\"id\":\"s1\",\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":0,$idle}" ;;
      abandoned-behind-passive-subagent)
        # The quit worker still lists the subagent its root session once forked.
        # That row can never prove anything about the operator's session, so it
        # must not keep the home read-only forever.
        sessions="{\"id\":\"sub\",\"rlmDepth\":1,\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":0,$passive},{\"id\":\"root\",\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":0,$idle}"
        ;;
      attached) sessions="{\"id\":\"s1\",\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":1,$idle}" ;;
      attached-behind-subagent)
        sessions="{\"id\":\"sub\",\"kind\":\"subagent\",\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":0,$idle},{\"id\":\"root\",\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":1,$idle}"
        ;;
      mid-turn-detached)
        sessions="{\"id\":\"root\",\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":0,$busy}"
        ;;
      unknown-activity)
        sessions='{"id":"s1","activeSessionId":"a1","cwd":"/x","workerPid":OLD,"attachedClients":0}'
        ;;
      no-resident-session)
        sessions="{\"id\":\"sub\",\"rlmDepth\":1,\"cwd\":\"/x\",\"workerPid\":OLD,\"attachedClients\":0,$passive}"
        ;;
      wedged-daemon) sessions= ;;
    esac
    cat > "$fakebin/prime-agent" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = list ]; then
  if [ "$case_id" = wedged-daemon ]; then
    # A daemon socket that never answers: the bound, not the answer, has to end
    # this call, or every lock acquisition inherits the daemon's wedge.
    sleep 60
  fi
  printf '{"sessions":[%s]}\n' '$(printf '%s' "${sessions//OLD/$old}")'
fi
exit 0
SH
    chmod +x "$fakebin/prime-agent"
    printf '%s\n' "$old" > "$dir/state/.lock"
    start=$(date +%s)
    out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_PRIME_AGENT_CLI_TIMEOUT=2 \
      "$ROOT/bin/fm-lock.sh" 2>&1) && status=0 || status=$?
    elapsed=$(( $(date +%s) - start ))
    lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
    case "$case_id" in
      abandoned|abandoned-behind-passive-subagent)
        expect_code 0 "$status" "an in-place restart was refused its own home's lock ($case_id): $out"
        [ "$lock_after" = "$new" ] \
          || fail "the restarted session did not take the lock ($case_id): expected $new, got $lock_after"
        ;;
      wedged-daemon)
        [ "$elapsed" -lt 30 ] || fail "a wedged prime-agent daemon stalled lock acquisition for ${elapsed}s"
        expect_code 1 "$status" "an unanswerable daemon must leave the recorded holder standing"
        [ "$lock_after" = "$old" ] || fail "an unreadable listing was treated as an abandoned worker"
        ;;
      *)
        expect_code 1 "$status" "a worker that is still live lost its home's lock ($case_id)"
        [ "$lock_after" = "$old" ] || fail "a live holder's lock was overwritten ($case_id)"
        assert_contains "$out" "another live firstmate session holds the lock" \
          "the live-holder refusal changed shape"
        ;;
    esac
  done
  kill "$old" "$new" 2>/dev/null || true
  wait "$old" "$new" 2>/dev/null || true
  pass "session-lock: only an idle unattended prime-agent worker is reclaimable; attached or working ones keep the lock"
}

# The lock lib is sourced by hooks and other libs, several of which are written
# without nounset, so sourcing it must hand the caller's shell flags back
# exactly as it found them.
test_sourcing_the_lock_lib_leaves_shell_flags_alone() {
  local before after
  before=$(bash -c 'echo "$-"')
  after=$(bash -c '. "$0"; echo "$-"' "$LIB")
  [ "$before" = "$after" ] \
    || fail "sourcing the session-lock lib changed the caller's shell flags: '$before' -> '$after'"
  bash -c 'set -u; . "$0"; case $- in *u*) ;; *) exit 1 ;; esac' "$LIB" \
    || fail "sourcing the session-lock lib cleared a caller's own nounset"
  pass "session-lock: sourcing the lib has no side effect on the caller's shell flags"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_abandoned_prime_agent_worker_never_blocks_its_home
test_sourcing_the_lock_lib_leaves_shell_flags_alone
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
