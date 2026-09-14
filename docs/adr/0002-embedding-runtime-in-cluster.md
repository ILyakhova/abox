# ADR-0002: In-cluster embedding runtime — shared Service, sidecar, or llm-d

- **Status:** Accepted
- **Date:** 2026-09-13
- **Deciders:** abox maintainers
- **Related:** [ADR-0001](./0001-text-embedding-model.md), [ToDo: cluster runtime](../todo/embeddings-cluster-sidecar-llmd.md), [context vs concurrency](../embeddings-context-and-concurrency.md)

## Context

ADR-0001 selects `nomic-embed-text-v1.5` served by `llama-server`. This ADR decides *how
that process is scheduled* inside the abox cluster.

Three shapes are on the table:

1. **Shared Service** — one Deployment, one ClusterIP, many consumers.
2. **Sidecar** — the embedder runs as an extra container inside each consumer's pod.
3. **llm-d** — the Kubernetes-native distributed inference stack (Inference Gateway +
   Endpoint Picker over a model service, most often vLLM but not necessarily), which abox is
   unusually well-positioned for because agentgateway is already the gateway.

These are not mutually exclusive, and the decision below assigns each a scope rather than
picking one winner.

## Decision

**1. The abox default is a shared Deployment + Service** in an `embeddings` namespace,
exposed through the existing `agentgateway-external` Gateway via HTTPRoute plus a
ReferenceGrant, following the same pattern as `releases/kagent.yaml`.

**2. The sidecar shape is supported and documented for batch ingestion and eval Jobs
only** — as a native sidecar (an `initContainer` with `restartPolicy: Always`), not as the
serving path.

**3. llm-d is deferred**, with explicit adoption triggers recorded below. This is a "not
yet for this workload", not a rejection of the technology.

## Why not sidecar as the default serving path

- **Weights are per-pod.** Q8_0 is 140 MiB on disk, but the resident set at 8192 context
  with a full batch is roughly 400–600 MiB. Every replica of every consumer pays that
  again. kagent alone would carry a copy.
- **No independent scaling.** Embedding load is bursty and shaped like ingestion; consumer
  load is interactive and shaped like traffic. Coupling them means scaling the wrong thing.
- **Startup cost per consumer.** Each pod must obtain the weights (init download or a baked
  image) and load the model before it is ready.
- **No shared warm cache.** Repeated queries across replicas re-do work that a shared
  service would have hot.
- **Upgrades fan out.** Changing the model means redeploying every consumer instead of one
  Deployment.

## Why sidecar is nevertheless right for ingestion and eval Jobs

- One-shot and high-throughput: no network hop, no HTTPRoute, no ReferenceGrant, no
  contention with the interactive path.
- The memory cost is temporary — the pod exits when the Job finishes.
- **It pins the embedder version to the job that used it.** A re-index cannot silently run
  against a different model revision than the one it was benchmarked with. Mixing vectors
  produced by two model versions inside one Qdrant collection is a silent correctness bug:
  distances stay numerically valid and the results are simply wrong. Making the ingestion
  Job carry its own embedder makes that failure structurally impossible.

## Why llm-d is deferred

The architectural fit is real, and worth stating plainly because it is the reason this is
"deferred" rather than "rejected":

- abox already runs **agentgateway**, which has first-class Gateway API Inference Extension
  support. An HTTPRoute reaches a pool through
  `backendRefs: [{group: inference.networking.k8s.io, kind: InferencePool}]`, and the pool
  delegates scheduling via `endpointPickerRef: {group: llm-d.ai, kind: EndpointPicker}`.
- agentgateway + llm-d + the Inference Extension is a documented, supported combination.
  kgateway 2.2 removed the inference path that did *not* go through agentgateway, so
  agentgateway is the intended data plane for exactly this.

In other words, **the gateway half of llm-d is already installed.** What makes it not worth
adding for this workload is the value it would return, not any barrier to running it:

**The optimisations do not apply.** llm-d's value is KV-cache-aware routing, tiered prefix
caching, and prefill/decode disaggregation. An embedding model is a **single-pass encoder:
no KV cache, no decode phase, no prefix to reuse across requests.** Every headline llm-d
optimisation is inapplicable here. What remains is replica scheduling through the Endpoint
Picker — real, but only once there is more than one replica to schedule between.

**Operational weight.** InferencePool, the Endpoint Picker, the model service and the
Inference Extension CRDs are a large surface next to a single `llama-server` process, in a
sandbox whose premise is `make run` finishing on a laptop.

### Correction, 2026-09-14

This section previously gave two further reasons, and observation has since falsified both.
They are recorded rather than deleted, because a decision that rests on a wrong premise
should not be allowed to look well-founded in hindsight.

| Claimed | Observed |
|---|---|
| "embedding and pooling models are not one of its well-lit paths" | an `llm-d-embedding` model service runs in this very cluster |
| "llm-d targets accelerators — NVIDIA, AMD, TPU" | it runs on a 2-core CPU KinD node |
| implied throughout: llm-d means vLLM | its model service here fronts **llama.cpp**, serving `model.gguf`; `/props` answers, which vLLM does not expose |

The observed deployment serves the same `nomic-embed-text-v1.5` at `Q8_0` as the plain
Deployment beside it, at the same 2048 × 8 slots, behind an `InferencePool` and an EPP
started with `--pool-group inference.networking.k8s.io`.

So llm-d is not vLLM-only, does not require an accelerator, and does serve encoders. The
decision above stands, but on the narrower ground that it buys nothing for this workload —
not on the false ground that it could not be done.

## Adoption triggers for llm-d

Adopt when any of these holds — the first is the realistic one:

1. **A generative model is added to abox.** The natural trigger: llm-d's caching and
   disaggregation only pay off where there is a decode phase to optimise.
2. **The embedder needs more than one replica.** This is what the Endpoint Picker actually
   buys an encoder. One replica behind a scheduler is a scheduler with nothing to decide.
3. More than one model needs per-model routing, prioritisation, or token-based rate
   limiting — agentgateway can apply those policies against an InferencePool backend.

A GPU node used to be listed here. It is not a trigger: the deployment observed on
2026-09-14 runs on CPU. It would raise the payoff of trigger 1, nothing more.

The migration path is already sketched in the cluster ToDo so that adoption is a
substitution behind a stable URL rather than a redesign.

## Consequences

- Adopting llm-d later does **not** force a second inference engine. Its model service can
  front `llama-server` on a GGUF — that is what the deployment observed on 2026-09-14 does —
  so llm-d is a scheduling and routing layer that can be added above the runtime already
  chosen here, rather than a replacement for it. The earlier version of this ADR assumed
  llm-d implied vLLM and treated the split as an accepted cost; there is no such cost.
- Consumers must address the embedder by **Service DNS or gateway URL**, never by pod IP,
  so that replacing the backing implementation with an InferencePool later is invisible to
  them.
- The HTTPRoute for `/v1/embeddings` coexists with kagent's catch-all `/` rule on the same
  Gateway. Gateway API resolves this by longest-prefix precedence, so the embeddings route
  wins without any change to `releases/kagent.yaml`. This is load-bearing and is called out
  in the ToDo.
- `ghcr.io/ggml-org/llama.cpp:server` is a floating tag. CODEBASE.md forbids unpinned
  references, so the Deployment must pin an immutable digest.
