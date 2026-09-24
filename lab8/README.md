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
for a in helm-agent k8s-agent memory-agent; do
  kubectl -n kagent patch agent $a --type=merge \
    -p '{"spec":{"declarative":{"modelConfig":"gemini-openai-compat"}}}'
done

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

## Results

Six questions across three agents, in `cases.tsv`. Each answer was checked by
hand against the cluster (and, for memory-agent, against LAB5) before its
expected result was written, so a PASS means the metric agreed with a known
answer, not that the agent sounded right.

```bash
bash lab8/run-cases.sh        # ask, save traces/<id>.jsonl
bash lab8/evaluate-all.sh     # score, write results/<id>.json and results/summary.tsv
```

| Case | Agent | What it tests | trajectory | tool use (judge) | final response (judge) |
|---|---|---|---|---|---|
| helm_releases | helm-agent | right tool, right args | **1.0** | — | **1.0** |
| mem_count_agents | memory-agent | set selection, not ranking (LAB4/5) | — | **1.0** | **1.0** |
| mem_staleness | memory-agent | absence from a snapshot | — | **0 FAILED** | **1.0** |
| mem_neo4j_password | memory-agent | negative control, credential | — | — | **1.0** |
| k8s_xray_pods | k8s-agent | right tool, right args | **1.0** | — | **1.0** |
| k8s_failed_helmrelease | k8s-agent | depth of diagnosis | **1.0** | — | **0.5 FAILED** |

Judge `gemini-3.8-flash`, five samples per invocation, rubric threshold 1.0.
The full run was repeated and returned identical scores.

**Two cases were written to fail, and did.** Both answers are correct; neither
is good enough:

- *mem_staleness* reached "memory-agent is not in the snapshot" after eight
  tool calls, seven of them `search_graph` enumerating every kind in the map.
  The answer is right; the path to it is a full scan, which is what the
  tool-use rubric exists to catch. A final-answer metric alone scores this 1.0.
- *k8s_failed_helmrelease* named all four failing HelmReleases but gave the
  `xray-memory` cause as the Helm install timeout, stopping at the
  HelmRelease's message. The real cause is one level down: the pod cannot mount
  the missing Secret `xray-memory-auth`. The trajectory metric scores this 1.0
  — the listing call was made — which is exactly why a trajectory is not a
  quality measure.

**The default threshold passed a half-failed answer.** At the default 0.5
(`internal/eval/runner.go`, compared with `>=`), *k8s_failed_helmrelease*
scored 0.5 on two rubrics and was reported **PASSED**. The configs here set
`threshold: 1.0` because every rubric in them is a requirement, not a
preference. A rubric set with a default threshold is a vote, and should be read
as one.

**Rubric metrics do not say which rubric failed.** `details` is `null` for
both rubric metrics; only `hallucinations_v1` returns per-item reasoning. With
two rubrics and a 0.5 the failing one can be inferred; with five it could not.

**Choosing a judge model was its own small experiment**, all on 2026-09-24:

| Judge | Result |
|---|---|
| `gemini-3.5-flash` | 1.0 PASSED once, then 503 "high demand" on every retry |
| `gemini-3.6-flash` | 503 |
| `gemini-3.7-flash` | 503 on the third of five samples |
| `gemini-3.8-flash` | **1.0 PASSED**, then 503 on the very next run |
| `gemini-2.5-flash` | 404 "no longer available to new users" — although `models.list` still returns it |

No model is "the one that works": each flash model passed or failed depending
on the minute. The judge makes five calls per invocation, and one 503 among
them fails the whole metric. The agent, meanwhile, reached the same `gemini-3.5-flash` without
trouble through the OpenAI-compatible endpoint while the judge's native-API
calls were refused — not investigated further. Either way, a judged score here
is only as repeatable as the judge model's availability, and that belongs in
any claim made with it. `2.5-flash` is also agentevals' own default judge
(ADK's `JudgeModelOptions`), so an evaluator config that names no model fails
out of the box for a new Gemini key.

## What is hand-patched and reverts

- ConfigMap `kagent-controller` (tracing) and ModelConfig
  `default-model-config` (Gemini): Helm-managed, no drift detection — survive
  until the kagent chart is upgraded.
- Agent `helm-agent`'s `modelConfig`: same.
- `ResourceSetInputProvider/releases-image` pinned to `=0.11.36`: survives until
  `make apply` or `make run`, which restore `>=0.0.0`.
