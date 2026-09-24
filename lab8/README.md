# LAB8 — scoring kagent agents with agentevals

Hand-applied, like lab4/5/7: the cluster reconciles the upstream artifact and
nothing in `lab8/` ships.

The tool is [triageagent-dev/evals](https://github.com/triageagent-dev/evals),
a Go port of `agentevals`: it scores agent behaviour from OpenTelemetry traces
without re-running anything. Built here from commit `54107cf`; there is no
published image.

## Order of operations

```bash
# 1. build the image and load it onto the nodes
git clone https://github.com/triageagent-dev/evals /tmp/evals
git -C /tmp/evals checkout 54107cf
docker build -t agentevals-go:lab8 /tmp/evals
kind load docker-image agentevals-go:lab8 --name abox

# 2. the judge key -- copied from kagent's Secret (lab5), not typed again
kubectl create namespace agentevals
kubectl -n kagent get secret gemini-gemini-3-5-flash -o json \
  | jq '{apiVersion:"v1",kind:"Secret",type:"Opaque",
         metadata:{name:"agentevals-judge",namespace:"agentevals"},
         data:{GEMINI_API_KEY:.data.GEMINI_API_KEY}}' | kubectl apply -f -

# 3. serve it
kubectl apply -f lab8/agentevals.yaml

# 4. pin the release bundle, turn agent tracing on
bash lab8/enable-tracing.sh

# 5. a model adapter that writes conversation content into spans
kubectl apply -f lab8/modelconfig-gemini-openai.yaml
kubectl -n kagent patch agent helm-agent --type=merge \
  -p '{"spec":{"declarative":{"modelConfig":"gemini-openai-compat"}}}'

# 6. one question -> one trace -> one score
bash lab8/ask.sh helm-agent "What Helm releases are installed in the cluster?"
bash lab8/collect-trace.sh /tmp/helm.jsonl
bash lab8/evaluate.sh /tmp/helm.jsonl lab8/evalsets/helm_releases.json lab8/configs/helm_releases.json
```

`default-model-config` also has to point at a working model, or every
chart-shipped agent answers 401 with the placeholder OpenAI key. It was
patched to Gemini for this lab, the same patch as on 2026-09-14.

## What it took to get one score out

Four things stood between a running agent and a number. None of them was in
agentevals' README, and each looked like something else at first.

**1. Tracing is a chart value, not an Agent field — LAB7 was wrong about the
cause.** LAB7 concluded that kagent agents "emit nothing and cannot be made to"
because the controller overrides `deployment.env`. The override is real, but
the value it writes comes from ConfigMap `kagent-controller`, rendered from the
chart's `otel.tracing.enabled`. Patching the ConfigMap and restarting the
controller turns tracing on for every agent. `enable-tracing.sh`.

**2. The Gemini provider writes no conversation content into spans.** Its
`generate_content` spans carry model, tokens and finish reasons, and no
`gcp.vertex.agent.llm_request`/`llm_response` — which is exactly what
agentevals rebuilds the conversation from. Result: `invocations=0`, "no
converter-compatible ADK LLM descendants". In kagent 0.10.1 only the OpenAI,
Anthropic, Bedrock and Ollama adapters call the telemetry helper
(`go/adk/pkg/models/*.go`); `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT`
cannot help a provider that never writes the attribute. Fixed by reaching
Gemini through its OpenAI-compatible endpoint:
`modelconfig-gemini-openai.yaml`. Tool calls work through it — the
`thought_signature` failure LAB7 hit was the demo app's client, not the
endpoint.

**3. One trace becomes two sessions.** agentevals groups spans by
`gen_ai.conversation.id`; kagent's controller-side spans have none. The agent
half never completes, so live evaluation never runs. Scored as files instead.
`collect-trace.sh`.

**4. One question becomes two invocations.** kagent emits `invoke_agent` in the
controller and again in the agent; each becomes an invocation, and a
one-question eval set then fails with "2 vs 1". `collect-trace.sh` keeps only
the agent's spans.

And one that is not a defect: **trajectory compares arguments literally.**
`helm-agent` calls `helm_list_releases` with `{"all_namespaces":"true"}` — a
string. An eval set expecting `{}` scores 0, which is the metric doing its job.

## Results so far

| Agent | Question | `tool_trajectory_avg_score` | `rubric_based_final_response_quality_v1` |
|---|---|---|---|
| helm-agent | What Helm releases are installed? | **1.0 PASSED** | **1.0 PASSED** once; then 503 from the judge (Gemini "high demand") on 3.5 and 3.6 |

The judge makes five calls per invocation, so a transient 503 on any of them
fails the metric. That is a property of running an LLM judge against a shared
free-tier model, and it belongs in any claim about how repeatable these scores
are.

## What is hand-patched and reverts

- ConfigMap `kagent-controller` (tracing) and ModelConfig
  `default-model-config` (Gemini): Helm-managed, no drift detection — survive
  until the kagent chart is upgraded.
- Agent `helm-agent`'s `modelConfig`: same.
- `ResourceSetInputProvider/releases-image` pinned to `=0.11.36`: survives until
  `make apply` or `make run`, which restore `>=0.0.0`.
