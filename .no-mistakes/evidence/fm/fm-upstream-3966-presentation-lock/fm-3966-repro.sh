#!/usr/bin/env bash
# Upstream firstmate #3966 reproduction / verification harness.
#   usage: fm-3966-repro.sh <checkout-root> <label> <outdir>
# Stages the exact field condition (a status-presentation lock whose recorded
# owner is gone but whose pid the OS recycled onto an unrelated live process)
# and runs that checkout's bin/fm-wake-drain.sh over a queued wake.
set -u
ROOT=$1; LABEL=$2; OUT=$3
TOOLS=${FM_3966_TOOLS:-$ROOT}   # checkout used only to MINT the fixture token
mkdir -p "$OUT/$LABEL"
work="$OUT/$LABEL"
state="$work/state"; mkdir -p "$state"
tangle="$work/tangle"; mkdir -p "$tangle"
status="$state/task.status"
lock="$state/.status-presentation-lock"
owner="$lock.owner.recycled"

printf 'needs-decision [key=fixture]: recycled owner must not wedge the drain\n' > "$status"
FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append signal task.status "signal: $2"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$status" >/dev/null

sleep 300 & impostor=$!
mkdir "$owner"
printf '%s\n' "$impostor" > "$owner/pid"
if [ "${FM_3966_TOKEN:-yes}" = yes ]; then
  tok=$(bash -c '. "$1"; fm_pid_start_token "$2"' _ "$TOOLS/bin/fm-wake-lib.sh" "$impostor")
  case "$tok" in
    *-starttime=*) printf '%s=1\n' "${tok%%=*}" ;;
    *) printf 'Tue Sep  8 06:41:08 2020\n' ;;
  esac > "$owner/pid-start"
fi
ln -s "$owner" "$lock"

echo "### [$LABEL] checkout: $ROOT"
echo "### staged owner dir: $(ls "$owner" | tr '\n' ' ')  (recorded pid $impostor is a LIVE unrelated process)"
start=$(date +%s)
FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$tangle" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=10 \
  "$ROOT/bin/fm-wake-drain.sh" > "$work/drain.out" 2> "$work/drain.err"
rc=$?
elapsed=$(( $(date +%s) - start ))
kill "$impostor" 2>/dev/null; wait "$impostor" 2>/dev/null
echo "### drain exit=$rc  wall=${elapsed}s"
echo "--- stdout ---"; cat "$work/drain.out"
echo "--- stderr ---"; cat "$work/drain.err"
echo
