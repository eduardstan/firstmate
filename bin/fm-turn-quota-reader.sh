#!/usr/bin/env bash
# Primary session turn-end quota instrumentation reader.
# Reads state/quota-turns.log and prints summary statistics.
#
# PROXY DISCLAIMER: The state fingerprint recorded here is a cheap, deterministic
# proxy metric of fleet state. It CANNOT prove a turn was useless - a turn that
# answered the captain changes nothing on disk. It must be described and treated
# as a proxy everywhere.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_FILE="${FM_QUOTA_LOG_OVERRIDE:-$STATE/quota-turns.log}"

for arg in "$@"; do
  case "$arg" in
    --log=*) LOG_FILE="${arg#*=}" ;;
    --log) shift; LOG_FILE="${1:-$LOG_FILE}" ;;
    -h|--help)
      echo "usage: $(basename "$0") [--log=<path>]"
      exit 0
      ;;
  esac
done

if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
  echo "No turn quota log records found at $LOG_FILE."
  exit 0
fi

awk -F '\t' '
BEGIN {
  total_turns = 0
  unchanged_turns = 0
  changed_turns = 0

  c5_first = -1; c5_prev = -1; c5_total_delta = 0; c5_valid = 0
  c7_first = -1; c7_prev = -1; c7_total_delta = 0; c7_valid = 0
  g_first = -1; g_prev = -1; g_total_delta = 0; g_valid = 0
}

NF >= 4 {
  total_turns++
  wake_kind = $2
  fp_changed = $4 + 0

  if (fp_changed == 0) {
    unchanged_turns++
  } else {
    changed_turns++
  }

  wake_count[wake_kind]++
  if (fp_changed == 0) {
    wake_unchanged[wake_kind]++
  } else {
    wake_changed[wake_kind]++
  }

  # Claude 5h
  if (NF >= 5 && $5 != "absent" && $5 ~ /^[0-9]+(\.[0-9]+)?$/) {
    v = $5 + 0
    c5_valid++
    if (c5_first < 0) c5_first = v
    if (c5_prev >= 0) {
      d = (v >= c5_prev) ? (v - c5_prev) : v
      c5_total_delta += d
      wake_c5_delta[wake_kind] += d
    }
    c5_prev = v
  }

  # Claude 7d
  if (NF >= 6 && $6 != "absent" && $6 ~ /^[0-9]+(\.[0-9]+)?$/) {
    v = $6 + 0
    c7_valid++
    if (c7_first < 0) c7_first = v
    if (c7_prev >= 0) {
      d = (v >= c7_prev) ? (v - c7_prev) : v
      c7_total_delta += d
      wake_c7_delta[wake_kind] += d
    }
    c7_prev = v
  }

  # Gemini
  if (NF >= 8 && $8 != "absent" && $8 ~ /^[0-9]+(\.[0-9]+)?$/) {
    v = $8 + 0
    g_valid++
    if (g_first < 0) g_first = v
    if (g_prev >= 0) {
      d = (v >= g_prev) ? (v - g_prev) : v
      g_total_delta += d
      wake_g_delta[wake_kind] += d
    }
    g_prev = v
  }
}

END {
  if (total_turns == 0) {
    print "No valid turn quota records."
    exit 0
  }

  noop_ratio = (unchanged_turns / total_turns) * 100.0
  changed_ratio = (changed_turns / total_turns) * 100.0

  print "=== Firstmate Turn Quota Report ==="
  print "NOTICE: Proxy state fingerprint metric used below cannot prove a turn was useless (e.g. answering the captain changes nothing on disk)."
  print ""
  printf "Total turns: %d\n", total_turns
  printf "Proxy no-op (fingerprint unchanged): %d (%.1f%%)\n", unchanged_turns, noop_ratio
  printf "Proxy changed (fingerprint changed):   %d (%.1f%%)\n", changed_turns, changed_ratio
  print ""

  print "--- Quota Consumed per Turn ---"
  if (c5_valid > 0) {
    c5_per_turn = c5_total_delta / total_turns
    c5_per_changed = (changed_turns > 0) ? (c5_total_delta / changed_turns) : 0
    printf "Claude 5-hour:  total delta %.2f%% | %.2f%% / turn | %.2f%% / changed turn\n", c5_total_delta, c5_per_turn, c5_per_changed
  } else {
    print "Claude 5-hour:  absent"
  }

  if (c7_valid > 0) {
    c7_per_turn = c7_total_delta / total_turns
    c7_per_changed = (changed_turns > 0) ? (c7_total_delta / changed_turns) : 0
    printf "Claude 7-day:   total delta %.2f%% | %.2f%% / turn | %.2f%% / changed turn\n", c7_total_delta, c7_per_turn, c7_per_changed
  } else {
    print "Claude 7-day:   absent"
  }

  if (g_valid > 0) {
    g_per_turn = g_total_delta / total_turns
    g_per_changed = (changed_turns > 0) ? (g_total_delta / changed_turns) : 0
    printf "Gemini / agy:   total delta %.2f%% | %.2f%% / turn | %.2f%% / changed turn\n", g_total_delta, g_per_turn, g_per_changed
  } else {
    print "Gemini / agy:   absent"
  }

  print ""
  print "--- Breakdown by Wake Kind ---"
  printf "%-12s %-8s %-16s %-16s\n", "WAKE KIND", "TURNS", "NO-OP (UNCHANGED)", "CLAUDE 5H DELTA"
  for (w in wake_count) {
    w_total = wake_count[w]
    w_unchanged = wake_unchanged[w] + 0
    w_pct = (w_total > 0) ? (w_unchanged / w_total * 100.0) : 0
    w_c5 = wake_c5_delta[w] + 0
    printf "%-12s %-8d %d (%.1f%%)         %.2f%%\n", w, w_total, w_unchanged, w_pct, w_c5
  }
}
' "$LOG_FILE"
