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
3. **llm-d** — the Kubernetes-native distributed inference stack (vLLM + Inference Gateway
   + Endpoint Picker), which abox is unusually well-positioned for because agentgateway is
   already the gateway.

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

In other words, **the gateway half of llm-d is already installed.** What blocks it is the
workload and the hardware, not the integration:

**Workload mismatch.** llm-d's value is KV-cache-aware routing, tiered prefix caching, and
prefill/decode disaggregation. An embedding model is a **single-pass encoder: no KV cache,
no decode phase, no prefix to reuse across requests.** Every headline llm-d optimisation is
inapplicable to this workload. llm-d v0.9's documented scope is decoder-based transformer
LLMs; embedding and pooling models are not one of its well-lit paths.

**Hardware mismatch.** llm-d targets accelerators — NVIDIA, AMD, TPU. abox is CPU-only
KinD. Running vLLM on CPU under llm-d to serve a 137M-parameter encoder is strictly worse
on every axis than a 140 MiB `llama-server` process.

**Operational weight.** InferencePool, the Endpoint Picker, the Router, vLLM model servers
and the Inference Extension CRDs are a large surface to add to a sandbox whose entire
premise is `make run` finishing on a laptop.

## Adoption triggers for llm-d

Adopt when any of these holds — the second is the realistic one:

1. A GPU node is available to the cluster.
2. **A generative model is added to abox.** This is the natural trigger: llm-d serves
   chat/completions where its caching and disaggregation actually pay off, while
   `llama-server` keeps serving embeddings, both behind the one agentgateway. The two
   runtimes coexist; the seam between them is the OpenAI wire format.
3. More than one model needs per-model routing, prioritisation, or token-based rate
   limiting — agentgateway can apply those policies against an InferencePool backend.
4. vLLM pooling/embedding models become a supported llm-d well-lit path, which would make
   trigger 2 collapse into a single runtime.

The migration path is already sketched in the cluster ToDo so that adoption is a
substitution behind a stable URL rather than a redesign.

## Consequences

- We accept **two inference runtimes** in the eventual steady state (llama.cpp for
  encoders, vLLM/llm-d for decoders). This is a deliberate trade: a single runtime would
  mean running vLLM on CPU today, which costs more than the inconsistency does.
- Consumers must address the embedder by **Service DNS or gateway URL**, never by pod IP,
  so that replacing the backing implementation with an InferencePool later is invisible to
  them.
- The HTTPRoute for `/v1/embeddings` coexists with kagent's catch-all `/` rule on the same
  Gateway. Gateway API resolves this by longest-prefix precedence, so the embeddings route
  wins without any change to `releases/kagent.yaml`. This is load-bearing and is called out
  in the ToDo.
- `ghcr.io/ggml-org/llama.cpp:server` is a floating tag. CODEBASE.md forbids unpinned
  references, so the Deployment must pin an immutable digest.
