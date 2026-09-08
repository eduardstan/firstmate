#!/usr/bin/env bash
# Behavior tests for Prime Agent registration and Pi-family harness detection.
#
# Prime Agent exports the same PI_CODING_AGENT marker as Pi, so the tests drive
# both sides of that boundary and preserve Pi and Claude detection when Prime
# Agent markers are absent or stale.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"

detect() {  # <env assignment>...
  env -u CLAUDECODE -u GROK_AGENT -u FM_PI_HARNESS -u PI_CODING_AGENT \
    -u PRIME_AGENT_CODING_AGENT_DIR -u PRIME_AGENT_INTERNAL_DAEMON_WORKER \
    "$@" "$HARNESS"
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

test_detection_splits_the_pi_family
