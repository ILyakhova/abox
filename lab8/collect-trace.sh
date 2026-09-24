#!/bin/bash
# LAB8 — pull the newest agent trace out of agentevals as one OTLP JSONL file.
# usage: lab8/collect-trace.sh <out.jsonl>
#
# Two things this works around, both found on 2026-09-24:
#
# 1. agentevals groups spans into sessions by gen_ai.conversation.id, not by
#    trace id. kagent's controller-side spans (POST /api/a2a/..., a bare
#    invoke_agent) carry no conversation id, so one trace lands in two
#    sessions. The agent-side session's root has its parent in the other one,
#    so it never completes and live invocation extraction never runs.
#
# 2. kagent writes invoke_agent twice per request -- once in the controller,
#    once in the agent -- and agentevals turns each into an invocation, so a
#    one-question trace scores as two ("actual and expected invocation lists
#    differ in length (2 vs 1)"). Only the spans that carry a conversation id
#    are kept; that drops the controller half and leaves one invocation.
set -uo pipefail
OUT=${1:?output file}
kubectl -n agentevals port-forward svc/agentevals-go 18001:8001 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 20); do curl -s -o /dev/null localhost:18001/api/health && break; sleep 1; done
sleep 5   # spans arrive after the answer does; LAB6 learned that the hard way
S=$(curl -s localhost:18001/api/streaming/sessions)
CONV=$(echo "$S" | jq -r '[.data[] | select(.sessionId|startswith("otlp-")|not)] | sort_by(.startedAt) | last | .sessionId')
echo "conversation session: $CONV"
curl -s localhost:18001/api/streaming/get-trace -H 'Content-Type: application/json' -d "{\"session_id\":\"$CONV\"}" \
  | jq -r '.data.traceContent' | grep -v '^$' \
  | jq -c 'select([.attributes[]? | select(.key=="gen_ai.conversation.id")] | length > 0)' > "$OUT"
echo "spans: $(wc -l < "$OUT")"
# Without these two attributes agentevals extracts zero invocations. The
# Gemini provider never writes them -- see modelconfig-gemini-openai.yaml.
n=$(jq -s '[.[] | select(.name|startswith("generate_content")) | select([.attributes[]?.key] | index("gcp.vertex.agent.llm_request"))] | length' "$OUT")
echo "generate_content spans with llm_request: $n"
[ "$n" -gt 0 ] || echo "WARNING: no conversation content in this trace; it cannot be scored"
