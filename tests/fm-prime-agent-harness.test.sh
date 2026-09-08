#!/usr/bin/env bash
# Behavior tests for Prime Agent registration and Pi-family harness detection.
#
# Prime Agent exports the same PI_CODING_AGENT marker as Pi, so the tests drive
# both sides of that boundary and preserve Pi and Claude detection when Prime
# Agent markers are absent or stale. They also pin the precedence floor: the
# Prime Agent split sits below the cursor, gemini, rovo, and omp marker arms, and
# above the CLAUDECODE fast path. grok is deliberately out of scope - GROK_AGENT=1
# is tested after the unmarked Pi result already, so grok started inside any
# Pi-family session has always resolved to that family, and reordering it is
# broader than this slice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-prime-agent-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# bin/fm-harness.sh reads verified ENV markers before ancestry, and a suite run
# from inside one of those harnesses inherits its marker, which outranks
# everything these cases set up: with an ambient CURSOR_AGENT=1 every assertion
# below would resolve "cursor". Drop every foreign marker so the asserted
# verdict does not depend on which harness launched the suite; each case states
# the marker it means to test.
scrubbed() {  # <env assignment>... <command> [arg]...
  env -u CLAUDECODE -u GROK_AGENT -u FM_PI_HARNESS -u PI_CODING_AGENT \
    -u PRIME_AGENT_CODING_AGENT_DIR -u PRIME_AGENT_INTERNAL_DAEMON_WORKER \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
    -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
    "$@"
}

detect() {  # <env assignment>...
  scrubbed "$@" "$HARNESS"
}

# A process whose kernel-recorded identity is the bare name under test: a
# SYMLINK to the system shell, never a copy (a copied platform binary fails
# macOS code signing), which is what `ps -o comm=` reports on both platforms.
# Every `-c` body ends in a no-op so bash does not exec-optimize the single
# command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in prime-agent prime-agent-helper omp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

test_detection_splits_the_pi_family() {
  local out

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent)
  [ "$out" = prime-agent ] || fail "the Prime Agent launch marker selected '$out'"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/home/x/.prime/agent)
  [ "$out" = prime-agent ] || fail "the Prime Agent tool marker selected '$out'"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_INTERNAL_DAEMON_WORKER=1)
  [ "$out" = prime-agent ] || fail "the Prime Agent daemon marker selected '$out'"

  # The same Pi-family marker without a Prime Agent signal must remain Pi.
  out=$(detect PI_CODING_AGENT=true)
  [ "$out" = pi ] || fail "unmarked Pi detection changed to '$out'"

  # An explicit Pi identity wins over stale Prime Agent values inherited from a
  # shared supervisor environment.
  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = pi ] || fail "explicit Pi detection was relabelled '$out'"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed PRIME_AGENT_INTERNAL_DAEMON_WORKER=1)
  [ "$out" = pi-signed ] || fail "explicit Pi-signed detection was relabelled '$out'"

  # A resident Prime Agent worker can inherit CLAUDECODE from its supervisor.
  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/x CLAUDECODE=1)
  [ "$out" = prime-agent ] || fail "Prime Agent detection lost to inherited Claude marker"

  # Prime-specific values are ignored without the Pi-family marker.
  out=$(detect CLAUDECODE=1 PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = claude ] || fail "a stale Prime Agent marker changed Claude detection to '$out'"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=)
  [ "$out" = pi ] || fail "an empty Prime Agent marker changed Pi detection to '$out'"

  pass "Prime Agent detection splits its Pi-family marker without relabelling Pi or Claude"
}

# cursor, gemini, and rovo do NOT scrub the environment they are started in, so
# one of them launched by hand inside a Prime Agent session carries the
# Pi-family and PRIME_AGENT_* markers alongside its own. Their markers are tested
# above the Prime Agent split and must keep winning; the split itself outranks
# the CLAUDECODE fast path only.
test_cursor_gemini_and_rovo_outrank_the_prime_agent_split() {
  local out case_ expected marker
  for case_ in \
    cursor:CURSOR_AGENT=1 \
    cursor:CURSOR_INVOKED_AS=cursor-agent \
    gemini:GEMINI_CLI=1 \
    rovo:ATLASSIAN_AGENT_TYPE=rovo \
    rovo:ROVODEV_CLI=1; do
    expected=${case_%%:*}
    marker=${case_#*:}
    out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/x "$marker")
    [ "$out" = "$expected" ] || fail "$marker inside a Prime Agent session detected '$out', not '$expected'"
  done
  pass "fm-harness: the cursor, gemini, and rovo markers outrank inherited Prime Agent markers"
}

# The marker layer is a fast path only: a Prime Agent hook or helper process can
# carry no PI_CODING_AGENT at all, which is what the ancestry arm is for. It is
# anchored, so a longer name that merely starts with prime-agent never claims
# the identity.
test_ancestry_identifies_prime_agent_without_markers() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(scrubbed PATH="$bin:$BASE_PATH" "$bin/prime-agent" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = prime-agent ] || fail "a markerless process named prime-agent detected '$out'"

  # Reparent the decoy's child before detection so an ambient Prime Agent
  # process cannot supply a real outer ancestor after the fixture marker is
  # scrubbed. The child writes its result before the polling shell reads it.
  local decoy_out="$TMP_ROOT/decoy.out"
  : > "$decoy_out"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  scrubbed PATH="$bin:$BASE_PATH" "$bin/prime-agent-helper" -c '("$1" >"$2") &' _ \
    "$HARNESS" "$decoy_out"
  for _ in $(seq 1 100); do
    [ -s "$decoy_out" ] && break
    sleep 0.05
  done
  out=$(cat "$decoy_out")
  [ "$out" != prime-agent ] || fail "prime-agent-helper merely starts with prime-agent and must not detect as prime-agent"

  # omp needs a real omp ancestor for its own marker, so the precedence check
  # that env markers alone cannot make belongs here.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(scrubbed FM_OMP_HARNESS=omp PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/x \
    PATH="$bin:$BASE_PATH" "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "an omp session started inside a Prime Agent session detected '$out', not omp"

  pass "fm-harness: prime-agent is identified by anchored ancestry when no marker survives"
}

test_detection_splits_the_pi_family
test_cursor_gemini_and_rovo_outrank_the_prime_agent_split
test_ancestry_identifies_prime_agent_without_markers
