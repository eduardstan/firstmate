#!/usr/bin/env bash
# #3966, retire path: bin/fm-classify-lib.sh's status_retire_presentation_task
# takes the same status-presentation lock. Same stranded recycled-pid owner.
set -u
ROOT=$1; LABEL=$2; OUT=$3
TOOLS=${FM_3966_TOOLS:-$ROOT}
work="$OUT/$LABEL-retire"; state="$work/state"; mkdir -p "$state"
lock="$state/.status-presentation-lock"; owner="$lock.owner.recycled"
printf 'note: retire fixture\n' > "$state/held.status"
sleep 300 & impostor=$!
mkdir "$owner"; printf '%s\n' "$impostor" > "$owner/pid"
tok=$(bash -c '. "$1"; fm_pid_start_token "$2"' _ "$TOOLS/bin/fm-wake-lib.sh" "$impostor")
case "$tok" in *-starttime=*) printf '%s=1\n' "${tok%%=*}" ;; *) printf 'Tue Sep  8 06:41:08 2020\n' ;; esac > "$owner/pid-start"
ln -s "$owner" "$lock"
echo "### [$LABEL] retire against a stranded lock whose owner pid $impostor was recycled"
start=$(date +%s)
timeout 45 env "FM_STATE_OVERRIDE=$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=5 bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-classify-lib.sh"
  status_retire_presentation_task "$STATE" held
' _ "$ROOT" > "$work/retire.out" 2> "$work/retire.err"
rc=$?
elapsed=$(( $(date +%s) - start ))
kill "$impostor" 2>/dev/null; wait "$impostor" 2>/dev/null
if [ "$rc" -eq 124 ]; then
  echo "### retire NEVER RETURNED (killed by a 45s external timeout) - unbounded spin"
else
  echo "### retire exit=$rc wall=${elapsed}s"
fi
echo "### held.status still present after retire? $([ -e "$state/held.status" ] && echo YES-not-retired || echo no-retired)"
echo "--- stderr ---"; cat "$work/retire.err"
echo
