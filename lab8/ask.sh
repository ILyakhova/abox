#!/bin/bash
# LAB8 — ask a kagent agent one question over A2A, print answer, tools, state.
# usage: lab8/ask.sh <agent> "<question>"
#
# Each call is a fresh conversation, so each produces one trace.
set -uo pipefail
AGENT=${1:?agent name}
Q=${2:?question}
kubectl -n kagent port-forward svc/kagent-controller 18083:8083 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -s -o /dev/null localhost:18083/health && break; sleep 1; done
OUT=/tmp/ask-$AGENT.json
jq -n --arg q "$Q" '{jsonrpc:"2.0", id:"1", method:"message/send",
  params:{message:{role:"user", messageId:(now|tostring), parts:[{kind:"text", text:$q}]}}}' \
| curl -s -m 300 "localhost:18083/api/a2a/kagent/$AGENT/" -H 'Content-Type: application/json' -d @- > "$OUT"
jq -r '.error.message // empty' "$OUT"
echo "== answer =="
jq -r '[.result.artifacts[]?.parts[]? | select(.kind=="text") | .text] | join("\n")' "$OUT"
echo "== tool calls =="
jq -r '[.result.history[]?.parts[]? | select(.kind=="data") | .data.name // empty] | unique | join(", ")' "$OUT"
echo "== state =="
jq -r '.result.status.state // "?"' "$OUT"
# a failed task carries its reason here, not in the artifacts
jq -r 'select(.result.status.state=="failed") | [.result.status.message.parts[]?.text] | join(" ")' "$OUT" | cut -c1-400
