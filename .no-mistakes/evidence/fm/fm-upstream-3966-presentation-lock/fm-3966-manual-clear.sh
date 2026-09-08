#!/usr/bin/env bash
# #3966, operator remedy: a lock owner directory written by an OLDER build (pid
# only, no start token) whose pid was recycled cannot be proven gone, so the
# drain must hand the operator a manual clear they can paste verbatim.
set -u
ROOT=$1; LABEL=$2; OUT=$3
work="$OUT/$LABEL-manual-clear"; state="$work/state"; tangle="$work/tangle"
mkdir -p "$state" "$tangle"
status="$state/task.status"; lock="$state/.status-presentation-lock"; owner="$lock.owner.legacy"
printf 'needs-decision [key=fixture]: manual clear must strand nothing\n' > "$status"
FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append signal task.status "signal: $2"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$status" >/dev/null
sleep 300 & impostor=$!
mkdir "$owner"; printf '%s\n' "$impostor" > "$owner/pid"   # legacy shape: pid only
ln -s "$owner" "$lock"
echo "### [$LABEL] legacy stranded lock, owner pid $impostor recycled onto a live process"
FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$tangle" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
  "$ROOT/bin/fm-wake-drain.sh" > "$work/1.out" 2> "$work/1.err"
echo "--- drain stdout ---"; cat "$work/1.out"
clear_cmd=$(sed -n 's/^.*clear it with //p' "$work/1.out" | head -1); clear_cmd=${clear_cmd%%. *}; clear_cmd=${clear_cmd%.}
kill "$impostor" 2>/dev/null; wait "$impostor" 2>/dev/null
if [ -z "$clear_cmd" ]; then echo "### advisory printed NO manual clear command"; exit 0; fi
echo "### operator pastes exactly what the advisory printed:"
echo "\$ $clear_cmd"
bash -c "$clear_cmd" && echo "### exit=0"
echo "### lock symlink left behind? $([ -e "$lock" ] || [ -L "$lock" ] && echo YES || echo no)"
echo "### owner directory stranded in state/? $(ls -d "$state"/.status-presentation-lock.owner.* 2>/dev/null || echo none)"
echo "### re-drain after the printed clear:"
FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$tangle" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=2 \
  "$ROOT/bin/fm-wake-drain.sh" > "$work/2.out" 2> "$work/2.err"
cat "$work/2.out"
