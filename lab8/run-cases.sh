#!/bin/bash
# LAB8 — ask every question in cases.tsv (or only the ids given), and save
# each agent-side trace to traces/<id>.jsonl for scoring.
# usage: lab8/run-cases.sh [id ...]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/traces"
tail -n +2 "$HERE/cases.tsv" | while IFS=$'\t' read -r id agent question; do
  [ -n "$id" ] || continue
  if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$id"; then continue; fi
  echo "################ $id ($agent)"
  bash "$HERE/ask.sh" "$agent" "$question" < /dev/null
  bash "$HERE/collect-trace.sh" "$HERE/traces/$id.jsonl" < /dev/null
  echo "-- tool calls with args:"
  jq -r 'select(.name|startswith("execute_tool")) | "   \(.name|sub("execute_tool ";""))  \([.attributes[] | select(.key=="gcp.vertex.agent.tool_call_args") | .value.stringValue] | join(""))"' \
    "$HERE/traces/$id.jsonl"
done
