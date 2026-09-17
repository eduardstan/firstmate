#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. The --handled form
# reads that exact token from the acknowledged inbox record, so the model does
# not have to retype it. This helper is optional: a plain echo of a status line
# that includes the same corr token is equally valid (bin/fm-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --handled <handled-msg> <verb> <note...>
#   fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
#   fm-secondmate-report.sh --doc --handled <handled-msg> <verb> <doc-path> <note...>
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --handled state/parent-route/mate.inbox/handled/001.msg done "audit clean"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <verb> <corr_id> <note...>
  fm-secondmate-report.sh --handled <handled-msg> <verb> <note...>
  fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
  fm-secondmate-report.sh --doc --handled <handled-msg> <verb> <doc-path> <note...>
EOF
  exit 2
}

DOC_MODE=0
HANDLED_RECORD=
while :; do
  case "${1:-}" in
    --doc)
      DOC_MODE=1
      shift
      ;;
    --handled)
      [ $# -ge 2 ] || usage
      HANDLED_RECORD=$2
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$HANDLED_RECORD" ]; then
  [ $# -ge 2 ] || usage
  VERB=$1
  shift
  CORR=
else
  [ $# -ge 2 ] || usage
  VERB=$1
  CORR=$2
  shift 2
fi
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
if [ -z "$HANDLED_RECORD" ]; then
  case "$CORR" in
    [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
    *)
      echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
      exit 1
      ;;
  esac
fi

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

if [ -n "$HANDLED_RECORD" ]; then
  case "$HANDLED_RECORD" in
    /*) RECORD_PATH=$HANDLED_RECORD ;;
    *) RECORD_PATH="$HOME_DIR/$HANDLED_RECORD" ;;
  esac
  RECORD_PATH=$(CDPATH='' cd -- "$(dirname "$RECORD_PATH")" 2>/dev/null && pwd -P)/$(basename "$RECORD_PATH") \
    || { echo "error: handled message path is unavailable: $HANDLED_RECORD" >&2; exit 1; }
  STATE_REAL=$(CDPATH='' cd -- "$STATE_DIR" 2>/dev/null && pwd -P) \
    || { echo "error: state directory is unavailable: $STATE_DIR" >&2; exit 1; }
  case "$RECORD_PATH" in
    "$STATE_REAL"/*.inbox/handled/*.msg|"$STATE_REAL"/*/*.inbox/handled/*.msg) ;;
    *) echo "error: handled message must be under an inbox handled directory: $HANDLED_RECORD" >&2; exit 1 ;;
  esac
  [ -f "$RECORD_PATH" ] && [ ! -L "$RECORD_PATH" ] \
    || { echo "error: handled message is unavailable or unsafe: $HANDLED_RECORD" >&2; exit 1; }
  CORR=$(fm_pending_reply_extract_corr "$(cat "$RECORD_PATH")")
  case "$CORR" in
    [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
    *) echo "error: handled message does not contain one full correlation token" >&2; exit 1 ;;
  esac
fi

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (%s via-helper)\n' "$VERB" "$token" "$NOTE" "$DOC_PATH" >> "$DESTINATION"
  else
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$DOC_PATH" >> "$DESTINATION"
  fi
else
  NOTE=$*
  printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$NOTE" >> "$DESTINATION"
fi
