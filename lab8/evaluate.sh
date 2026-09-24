#!/bin/bash
# LAB8 — score a trace file with agentevals' API.
# usage: lab8/evaluate.sh <trace.jsonl> <eval_set.json|-> <config.json>
#
# Through the API rather than `agentevals run`: the CLI only reads Jaeger
# JSON, while POST /api/evaluate auto-detects the OTLP JSONL that
# collect-trace.sh writes.
set -uo pipefail
TRACE=${1:?trace}; ES=${2:?eval set or -}; CFG=${3:?config}
kubectl -n agentevals port-forward svc/agentevals-go 18001:8001 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -s -o /dev/null localhost:18001/api/health && break; sleep 1; done
ARGS=(-F "trace_files=@$TRACE" -F "config=<$CFG")
[ "$ES" != "-" ] && ARGS+=(-F "eval_set_file=@$ES")
OUT=/tmp/agentevals-last-result.json
curl -s -m 600 localhost:18001/api/evaluate "${ARGS[@]}" > "$OUT"
jq -r '.error // empty' "$OUT"
jq -r '(.data.traceResults // .traceResults // [])[] |
  "trace \(.traceId) invocations=\(.numInvocations)\(if (.conversionWarnings // []) | length > 0 then " warnings=" + (.conversionWarnings | join("; ")) else "" end)",
  (.metricResults[] | "  \(.metricName)  score=\(.score)  \(.evalStatus)  [\(.evaluatorKind)\(if .judgeModel then " " + .judgeModel else "" end)]\(if .error then "  ERROR: " + .error else "" end)")' "$OUT"
