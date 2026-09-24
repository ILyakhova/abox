#!/bin/bash
# LAB8 — score every case that has a trace, and write results/summary.tsv.
# usage: lab8/evaluate-all.sh [id ...]
#
# Judge calls get 503 "high demand" often enough that one retry is not
# enough (see README.md), so a case whose only failures are 503s is retried
# up to five times, 30s apart. Anything else is reported as it came back.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/results"
SUM="$HERE/results/summary.tsv"
[ -f "$SUM" ] || printf 'id\tmetric\tscore\tstatus\tkind\tattempts\n' > "$SUM"
tail -n +2 "$HERE/cases.tsv" | while IFS=$'\t' read -r id agent question; do
  [ -n "$id" ] || continue
  if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$id"; then continue; fi
  T="$HERE/traces/$id.jsonl"; C="$HERE/configs/$id.json"; E="$HERE/evalsets/$id.json"
  [ -f "$T" ] && [ -f "$C" ] || { echo "skip $id (no trace or config)"; continue; }
  [ -f "$E" ] || E=-
  for attempt in 1 2 3 4 5; do
    echo "################ $id (attempt $attempt)"
    bash "$HERE/evaluate.sh" "$T" "$E" "$C" < /dev/null
    cp /tmp/agentevals-last-result.json "$HERE/results/$id.json"
    errs=$(jq -r '[(.data.traceResults // [])[].metricResults[] | select(.error) | .error] | .[]' "$HERE/results/$id.json")
    [ -z "$errs" ] && break
    echo "$errs" | grep -qv 'Error 503' && break   # a non-503 error will not go away by waiting
    sleep 30
  done
  grep -v "^$id	" "$SUM" > "$SUM.tmp" && mv "$SUM.tmp" "$SUM"
  jq -r --arg id "$id" --arg a "$attempt" '(.data.traceResults // [])[].metricResults[] |
    [$id, .metricName, (.score|tostring), .evalStatus, .evaluatorKind, $a] | @tsv' "$HERE/results/$id.json" >> "$SUM"
done
echo; column -t -s $'\t' "$SUM"
