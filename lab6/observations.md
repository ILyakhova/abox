# LAB6 — the OpenTelemetry demo, from an o11y point of view

Questions and observations from running the demo in abox, not a summary of its
documentation. The architecture is described upstream:
<https://opentelemetry.io/docs/demo/architecture/>.

Deployed from `feat/otel-demo` the intended way — merged, `make apply`, and the
cluster repointed at `releases-otel-demo`. Nothing here was hand-applied, unlike
LAB4 and LAB5, because that branch actually has a published artifact.

## What arrived

The chart brings its own observability stack as subcharts, all enabled by
default: **Jaeger** for traces, **Prometheus** for metrics, **OpenSearch** for
logs, **Grafana** as the front end, and an **OpenTelemetry Collector** every
service reports to. Roughly twenty application services in Go, Java, Python,
.NET, Rust and JavaScript, each instrumented in its own language's idiom.

That self-sufficiency is the first thing worth noticing, and it is a question
rather than a compliment.

## Observation 1 — abox now has two observability stacks that do not know about each other

abox already ships **Phoenix** for LLM observability. The demo brings Prometheus,
Jaeger, OpenSearch and Grafana. Nothing connects them.

So the cluster has:

| Stack | Watches | Sees the other? |
|---|---|---|
| Phoenix | LLM calls from kagent agents | no |
| Demo's Collector → Jaeger/Prometheus/OpenSearch | the demo's microservices | no |

An agent asking "why is checkout slow" would have to look in one place, and
"why did the retrieval agent burn 2M tokens" in another. Neither view contains
the other's spans.

This is the question the optional third task really asks: not "can kagent be
added to the o11y system", but **which one**, and what it costs to have chosen
wrong.

## Observation 2 — the demo is built for docker-compose, and Kubernetes changes it silently

Two differences, both found in the branch's own manifest comments rather than in
the upstream documentation:

**The load generator has no web UI by default.** The chart pins
`LOCUST_HEADLESS: "true"`, where docker-compose sets `false`. Upstream's
screenshots of a Locust UI are therefore docker-compose-only. The branch
overrides it and adds a `service.port`, because the chart renders no Service for
that component at all — no `.service` block, no `.ports`.

**The demo cannot be put behind the existing gateway.** `frontend-proxy` is a
single Envoy entrypoint that owns the root path, and `/` on that listener is
already kagent's UI. A Gateway API `URLRewrite` rewrites the inbound request
path only — the Next.js frontend still serves absolute asset paths, and
frontend-proxy's routing is baked into its image with no envoy config in the
chart to extend. Access is by port-forward:

```bash
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
kubectl port-forward -n otel-demo svc/load-generator 8089:8089
```

The observation underneath both: **a reference deployment is a claim about an
environment, not about a product.** The demo demonstrates OpenTelemetry on
docker-compose. On Kubernetes it demonstrates something slightly different, and
nothing in it says so.

## Questions to answer by using it

Recorded before looking, so the answers are not fitted to what turned up.

1. **Where does a trace stop?** A checkout request crosses five languages. Does
   context propagate the whole way, or does the trace break at a queue, a gRPC
   boundary, or a service whose instrumentation is manual?
2. **What does the Collector cost?** It is a pod every service reports to. What
   is its resident set, and what happens to traces when it is saturated — drop,
   backpressure, or silent loss?
3. **Is sampling on?** If so, at what rate, and would an incident be visible in
   what survives it?
4. **Do the three signals join up?** Given a slow trace in Jaeger, can the
   matching logs in OpenSearch and metrics in Prometheus be reached without
   copying an ID by hand?
5. **What does a failure look like?** The demo ships feature flags that inject
   faults. Which of the three signals notices first, and which one actually
   names the cause?
6. **What is not instrumented?** The gaps are the interesting part — a service,
   a dependency, or a hop with no spans at all.

## Answers

31 pods, 29 services. Everything below was read from Jaeger's API and the
collector's own config rather than clicked through a UI, so the numbers are
reproducible.

### 1. Where does a trace stop?

Not at language or protocol boundaries. A checkout trace carries **130 spans
across 12 services** — cart, checkout, currency, email, flagd, frontend,
frontend-proxy, load-generator, payment, product-catalog, quote, shipping — in
Go, Java, .NET, Python, Rust and JavaScript. Context propagates the whole way.

It stops at **Kafka**, and that turns out to be by design rather than by defect.
`accounting` and `fraud-detection` consume the `orders` topic and appear in
traces of their own, 2–3 spans each. But their spans carry a reference:

```
op=orders receive   refs=CHILD_OF->e95335f85986, FOLLOWS_FROM->5122e82e9492
op=orders process   refs=CHILD_OF->b5d453c37acf, FOLLOWS_FROM->5122e82e9492
```

`FOLLOWS_FROM` is a **span link**, and following it lands exactly on the
130-span checkout trace that published the order. That is correct OpenTelemetry
semantics for messaging: a consumer may process a batch drawn from many traces,
so making it a child of one of them would be a lie.

**The operational consequence is the finding.** An operator looking at the
checkout trace sees `orders publish` and then nothing. Accounting and fraud
detection are one hop away and in a different trace, reachable only by knowing
that span links exist and going to find them. The data is complete; the default
path through it is not.

### A trace read too early is indistinguishable from a broken trace

Worth its own heading because it cost time and would cost it again.

The first checkout trace fetched showed **29 spans across 2 services** — only
`checkout`'s own client spans, with no server spans from cart, product-catalog,
currency or payment. That reads exactly like broken context propagation.

The same trace ID, queried minutes later: **130 spans, 12 services.** Nothing was
broken. Spans arrive asynchronously, and Jaeger serves whatever has landed.

There is no marker on a partial trace saying it is partial. The lesson is not
about this demo: **a distributed trace is eventually consistent, and "eventually"
has no indicator.** Any conclusion drawn from a trace fetched seconds after the
request is unsafe.

### 2. What does the collector cost, and what does it drop?

It is a **DaemonSet, two pods**, one per worker — not a single central
collector. Memory is requested and limited at **400Mi each**, and the pipeline
begins with `memory_limiter`, so saturation refuses new data at the receiver
rather than growing the heap. Back-pressure, not silent loss — at the collector.
What the *instrumented process* does when the collector refuses is a separate
question this run did not answer.

### 3. Is sampling on?

**No.** The pipeline holds `memory_limiter`, `batch`, `k8s_attributes`,
`resourcedetection`, `resource`, two `transform` processors, one `filter` and
`gen_ai_normalizer`. There is no `probabilistic_sampler` and no `tail_sampling`.

Every trace is kept, which is why a full 130-span trace exists for every
checkout. That is a demo's choice and not a deployment's: it is the reason the
demo is legible, and the first thing that would have to change under real load.

### 4. Do the signals join up?

Better than by correlation — by construction, for two of them. `span_metrics`
appears as an **exporter in the traces pipeline and a receiver in the metrics
pipeline**: the RED metrics in Prometheus are *derived from the spans*, not
collected independently. There is no possibility of them disagreeing about
request counts or latencies.

Logs go to OpenSearch through their own pipeline, with `k8s_attributes`
attaching pod, node, deployment and namespace to every record — so the join to
traces is by resource attributes, which is a convention rather than a guarantee.

There are **four** signals here, not three: a `profiles` pipeline exports to
`firepit`. Continuous profiling sits beside traces, metrics and logs, and the
architecture page does not prepare you for it.

### 5. What does sanitisation actually sanitise?

Not what the name suggests, and this is worth correcting because the word
invites the wrong assumption.

- `transform/sanitize_spans` rewrites raw paths into route templates —
  `/api/products/12345` becomes `/api/products/{productId}` — and normalises
  span names to semconv 1.37.0.
- `transform/sanitize_logs` renames one attribute key.
- `filter/sanitize_profiles` drops `containerd-shim-*` noise.

This is **cardinality and naming hygiene, not credential redaction**. Nothing
here would have stopped LAB5's leak. The route templating is security-adjacent —
identifiers stay out of metric labels — but that is a side effect.

The gap is worth naming: the reference deployment for observability ships no
processor that removes secrets from telemetry, and telemetry is exactly where
secrets end up.

### 6. What is not instrumented?

Jaeger knows **18 services** out of 29. The infrastructure absences are expected
— Jaeger, Prometheus, Grafana, OpenSearch do not trace themselves here.

The interesting absences were `agent`, `mcp` and `chatbot`: the demo's own AI
components. **They are instrumented and simply had no traffic.** Their
deployments carry `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT` and
`TRACELOOP_BASE_URL` — Traceloop being OpenLLMetry, which is precisely the source
the collector's `gen_ai_normalizer` is configured to read.

Recording this as "not instrumented" would have been a wrong conclusion from a
correct observation, and absence in a trace store never distinguishes the two by
itself.

## What this means for the optional third task

The demo already carries the bridge that adding kagent to observability would
need, and it is unconnected at both ends.

- The collector's traces pipeline runs `gen_ai_normalizer` with
  `sources: [openllmetry]`, which converts OpenLLMetry-shaped GenAI telemetry
  into OTel semantic conventions.
- Its receivers include plain `otlp`, on `otel-collector.otel-demo:4317/4318`.
- abox's own LLM observability is **Phoenix**, in a different namespace, with no
  connection to any of it.

So the cluster now has two observability stacks that cannot see each other, and
the real question the optional task poses is not "can kagent be added" but
**which stack owns LLM telemetry, and what the other one loses by not having
it**. An agent investigating "why is checkout slow" and an agent investigating
"why did retrieval burn 2M tokens" currently look in different places, and
neither view contains the other's spans.

That is a decision, not a wiring exercise, and it belongs in an ADR rather than
in a manifest.
