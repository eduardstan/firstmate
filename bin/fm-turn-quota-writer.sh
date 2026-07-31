#!/usr/bin/env bash
# Primary session turn-end quota instrumentation writer.
# Appends exactly one tab-separated record per primary-session turn end to
# state/quota-turns.log.
#
# PROXY DISCLAIMER: The state fingerprint recorded here is a cheap, deterministic
# proxy metric of fleet state. It CANNOT prove a turn was useless - a turn that
# answered the captain changes nothing on disk. It must be described and treated
# as a proxy everywhere.
#
# Error contract: this writer must never block, delay, or fail a turn. All errors
# are caught, written to state/.turn-quota-error.log, and swallowed with exit 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_FILE="${FM_QUOTA_LOG_OVERRIDE:-$STATE/quota-turns.log}"
ERR_LOG="$STATE/.turn-quota-error.log"
CACHE_FILE="$STATE/.turn-quota-cache.json"
MAX_LOG_LINES=10000

log_err() {
  printf '%s [error] %s\n' "$(date +%s)" "$1" >> "$ERR_LOG" 2>/dev/null || true
}

record_turn_quota() {
  local wake_kind fp fp_changed last_fp
  local claude_5h="absent" claude_7d="absent" claude_gen_at="absent"
  local gemini_used="absent" gemini_gen_at="absent"
  local cache_fresh=0 cache_mtime=0 now=0 parsed=0
  local epoch record line_count usage_json parsed_gemini
  local c_5h c_7d c_gen g_used g_gen

  # Verify primary scope
  if [ -f "$SCRIPT_DIR/fm-primary-scope-lib.sh" ]; then
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  fi

  # Determine wake kind from durable state
  wake_kind="captain"
  if [ -f "$STATE/.turn-wake-kind" ]; then
    raw_kind=$(cat "$STATE/.turn-wake-kind" 2>/dev/null || true)
    case "$raw_kind" in
      signal|stale|check|heartbeat|captain) wake_kind="$raw_kind" ;;
      *) wake_kind="captain" ;;
    esac
  fi

  # Compute proxy fingerprint of fleet state
  fp=$(
    # shellcheck disable=SC2012
    meta_stat=$(ls -l --full-time "$STATE"/*.meta 2>/dev/null | awk '{print $5, $6, $7, $9}' || true)
    backlog_hash=$(sha256sum "$FM_HOME/data/backlog.md" 2>/dev/null | awk '{print $1}' || echo "no-backlog")
    head_rev=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || echo "no-head")
    printf '%s\n%s\n%s\n' "$meta_stat" "$backlog_hash" "$head_rev" | sha256sum 2>/dev/null | awk '{print $1}' | cut -c1-16
  )
  [ -n "$fp" ] || fp="0000000000000000"

  # Check if fingerprint changed from last record
  fp_changed=1
  if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
    last_fp=$(tail -n 1 "$LOG_FILE" 2>/dev/null | awk -F '\t' '{print $3}' || true)
    if [ "$last_fp" = "$fp" ]; then
      fp_changed=0
    fi
  fi

  # Query quota-axi if available
  if command -v quota-axi >/dev/null 2>&1; then
    cache_fresh=0
    if [ -f "$CACHE_FILE" ]; then
      cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
      now=$(date +%s)
      if [ $((now - cache_mtime)) -lt 15 ]; then
        cache_fresh=1
      fi
    fi
    if [ "$cache_fresh" -eq 0 ]; then
      timeout 3s quota-axi --json > "$CACHE_FILE.tmp" 2>/dev/null && mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null || true
    fi
    if [ -f "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
      parsed=$(jq -r '
        .generatedAt as $gen |
        (.providers[]? | select(.provider=="claude")) as $c |
        (($c.windows[]? | select(.id=="five_hour") | .percentUsed) // "absent") as $h5 |
        (($c.windows[]? | select(.id=="seven_day") | .percentUsed) // "absent") as $d7 |
        "\($h5)\t\($d7)\t\($gen // "absent")"
      ' "$CACHE_FILE" 2>/dev/null || true)
      if [ -n "$parsed" ]; then
        IFS=$'\t' read -r c_5h c_7d c_gen <<< "$parsed"
        [ -n "$c_5h" ] && claude_5h="$c_5h"
        [ -n "$c_7d" ] && claude_7d="$c_7d"
        [ -n "$c_gen" ] && claude_gen_at="$c_gen"
      fi
    fi
  fi

  # Query antigravity-usage if available (explicit absent marker if absent)
  if command -v antigravity-usage >/dev/null 2>&1; then
    usage_json=$(timeout 3s antigravity-usage --json 2>/dev/null || true)
    if [ -n "$usage_json" ]; then
      parsed_gemini=$(printf '%s' "$usage_json" | jq -r '
        .timestamp as $ts |
        ([.models[]? | select(.modelId | contains("gemini")) | .remainingPercentage] | first) as $rem |
        if $rem == null then "absent\tabsent"
        else
          (if $rem <= 1.0 then (1.0 - $rem) * 100.0 else (100.0 - $rem) end) as $used |
          "\($used)\t\($ts // "absent")"
        end
      ' 2>/dev/null || true)
      if [ -n "$parsed_gemini" ]; then
        IFS=$'\t' read -r g_used g_gen <<< "$parsed_gemini"
        [ -n "$g_used" ] && gemini_used="$g_used"
        [ -n "$g_gen" ] && gemini_gen_at="$g_gen"
      fi
    fi
  fi

  epoch=$(date +%s)
  record=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$epoch" "$wake_kind" "$fp" "$fp_changed" \
    "$claude_5h" "$claude_7d" "$claude_gen_at" \
    "$gemini_used" "$gemini_gen_at")

  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s\n' "$record" >> "$LOG_FILE" 2>/dev/null || log_err "failed writing to log file"

  # Bound log size
  if [ -f "$LOG_FILE" ]; then
    line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$line_count" -gt "$MAX_LOG_LINES" ]; then
      tail -n 5000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
    fi
  fi

  # Reset wake kind marker to captain after recording
  printf 'captain\n' > "$STATE/.turn-wake-kind" 2>/dev/null || true
}

(record_turn_quota) || exit 0
