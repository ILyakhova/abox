# LAB7 — OTel, MLflow and Phoenix on the same GenAI traces

Three observability stacks, one agent, identical spans. What each one makes of
them.

## Method: one input, three destinations

Pointing the agent at one backend at a time would give each a different set of
requests, and any difference found could then be a difference in traffic rather
than in the tool. So [`fanout-collector.yaml`](./fanout-collector.yaml) receives
OTLP from the agent and copies every span to all three:

```
Astronomy Shop agent ──► fanout-collector.lab7 ──┬──► otel-collector.otel-demo ──► Jaeger
                                                 ├──► otel-collector.mlflow ──► MLflow
                                                 └──► phoenix-svc.phoenix (OTLP direct)
```

The comparison below is of the same trace id — `e58869ed…` — read from each.

## Getting anything in at all

None of the three worked out of the box, and each failed differently. This is a
result in its own right: the difficulty is not in the UIs.

| | What happened | Where it was visible |
|---|---|---|
| **Jaeger** (via the demo's collector) | worked | — |
| **MLflow** | the bridge collector accepted the spans and got **HTTP 403** forwarding them | only in the bridge collector's log |
| **Phoenix** | rejected the export with `rpc error: code = Unauthenticated` | only in the fan-out collector's log |

**MLflow's 403 is a Host check.** `mlflow server --allowed-hosts` defaults to
"localhost + private IPs", and the collector posts to
`mlflow-mlflow.mlflow.svc.cluster.local:5000` — a DNS name, not an IP. The
deployed release carries no `--allowed-hosts` flag at all. Three commits on the
branch are chasing this, none of them in the artifact the cluster reconciles.

Adding the flag restarted MLflow into a crash loop: four workers behind a 1s
probe timeout never answer `/health` in time. Two later upstream commits arrive
at `workers=1` and a looser probe, which is what made it stable here.

**Phoenix is the only one of the three that authenticates its ingest endpoint.**
That is a real difference in posture, not a configuration detail: traces carry
prompts and responses, and the other two accept them from anything that can
reach the port.

## kagent agents emit nothing, and cannot be made to

Before using the demo's agent, the obvious subject was one of abox's own. Every
kagent agent ships with `OTEL_TRACING_ENABLED=false`, and `kagent-tools` points
at `http://host.docker.internal:4317`, a docker-compose default that does not
resolve from a pod. So abox ships Phoenix for LLM observability and sends it
nothing.

The Agent CRD has `spec.declarative.deployment.env`, which looks like the way to
fix that. It is not:

```
OTEL_TRACING_ENABLED=true      <- ours, from the CR
...
OTEL_TRACING_ENABLED=false     <- the controller's, appended after
```

The controller appends its own environment **after** the user's, and Kubernetes
keeps the last value when a name repeats. Patching the Deployment directly does
not help either — the controller restores the duplicate immediately. The field
exists and has no effect.

> **Corrected in LAB8.** The controller's value is not fixed: it is copied from
> ConfigMap `kagent-controller`, rendered from the chart's
> `otel.tracing.enabled`. Patching the ConfigMap and restarting the controller
> turns tracing on for every agent — see `lab8/enable-tracing.sh`. What this
> section says about the CRD field stands; "cannot be made to" does not.

## The same trace, three ways

The agent was switched from its placeholder LLM to Gemini through its
OpenAI-compatible endpoint, so these are real calls with real token counts.

### Jaeger — everything is there, nothing is understood

The span list is complete and correctly nested:

```
POST /prompt → ChatLLM.chat → execute_task model → LangGraph.workflow
             → invoke_agent LangGraph → astronomy_shop_agent_workflow.workflow
```

and every GenAI attribute is present as a tag:

```
gen_ai.input.messages      gen_ai.output.messages      gen_ai.system_instructions
gen_ai.request.model       gen_ai.response.model       gen_ai.response.finish_reasons
gen_ai.usage.input_tokens  gen_ai.usage.output_tokens  gen_ai.tool.definitions
gen_ai.agent.name          gen_ai.task.input           gen_ai.task.output
```

**Nothing is lost.** What is missing is meaning: to Jaeger these are opaque
strings on a span. It cannot tell you which span was an LLM call, cannot total
tokens across a trace, cannot show a prompt as a conversation. Ask "what did this
agent spend today" and Jaeger has every number and no way to add them up.

### MLflow — one row per call, with an outcome

```
tr-e58869ed…  state=OK     dur=4.212s  svc=agent
tr-66ed1833…  state=ERROR  dur=2.479s  svc=agent
tr-faeda7df…  state=ERROR  dur=0.537s  svc=agent
```

The unit is the **trace**, not the span, and it carries a state. That matches how
an LLM call is actually thought about — one request, succeeded or failed, this
long — and the failures are visible without opening anything.

A trace read while still open reports `state=IN_PROGRESS` with `duration=0s`.
The same eventual-consistency trap LAB6 found in Jaeger, wearing different
clothes.

### Phoenix — the spans are classified

```
ChatLLM.chat                            kind=llm      tokens=801   3836ms
LangGraph.workflow                      kind=agent    tokens=0     3890ms
invoke_agent LangGraph                  kind=agent    tokens=0     3900ms
POST /prompt                            kind=unknown  tokens=0     4212ms
POST /prompt http send                  kind=unknown  tokens=0     0.03ms
```

Phoenix is the only one that **reads** the GenAI semantics rather than storing
them. It knows which span is the model call, which are agent steps, and which are
plain HTTP, and it extracts the token count onto the span. The failed call shows
`tokens=0` on its `ChatLLM.chat`, so cost is attributed only where it was
actually incurred.

## Where each one belongs

| | Unit | GenAI awareness | Auth on ingest | Best at |
|---|---|---|---|---|
| **OTel + Jaeger** | span | none — attributes are opaque tags | no | *where* time went across services; the only one that sees the non-LLM half of the system |
| **MLflow** | trace | container-level: status, duration, service | no | *did this call work*, and comparing runs |
| **Phoenix** | span, typed | span kind, token accounting, prompt/response as conversation | **yes** | *what the model was asked and what it cost* |

They are not three implementations of one thing. Jaeger answers a distributed
systems question, Phoenix answers an LLM question, and MLflow sits between them
with the experiment-tracking framing it came from.

**The practical reading for abox:** Phoenix is the right home for agent
telemetry and is currently fed nothing. The demo's collector already runs a
`gen_ai_normalizer`, so the conversion layer exists. What is missing is a way to
turn tracing on for a kagent agent — which today requires changing the chart,
because the CRD field that looks like it would do it does not.

## What this does not settle

One agent, one model, a handful of calls, one run each. No throughput, no
retention, no cost at volume, and no look at Phoenix's evaluation features or
MLflow's experiment tracking — both of which are the reason those tools exist and
neither of which a trace comparison touches.

Every fix applied here was a hand patch to a Flux-managed deployment: MLflow's
`--allowed-hosts`, its worker count and probes, and the demo agent's model and
endpoint. All of it reverts on the next reconcile. Nothing in `lab7/` ships.
