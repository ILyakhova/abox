# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are the `v*` tags that CI publishes as OCI artifacts to
`oci://ghcr.io/den-vasyliev/abox/releases`; the cluster reconciles from those.

## [Unreleased]

### Added

- **ADR-0001 — text embedding model selection**
  ([docs/adr/0001-text-embedding-model.md](docs/adr/0001-text-embedding-model.md)).
  Selects `nomic-ai/nomic-embed-text-v1.5` as the default text embedding model, served as
  `Q8_0` GGUF at 768 dimensions with an 8192-token context and mean pooling. Chosen for the
  size-to-quality ratio on CPU-only KinD (137M parameters, ~140 MiB, MTEB 62.28), the 8k
  context, Matryoshka Representation Learning, an Apache-2.0 licence, and first-class GGUF
  builds. Records the alternatives — OpenAI `text-embedding-3-small`, `bge-m3`,
  `Qwen3-Embedding`, `all-MiniLM-L6-v2`, `nomic-embed-text-v2-moe` — with the conditions
  under which each displaces the default.

  The ADR also establishes a **standing benchmark rule**: MTEB is a directional signal
  only, and any embedding-backed retrieval path must be validated on its own corpus before
  reaching users (~200 gold queries against ~10K distractor chunks; track Recall@K, MRR,
  nDCG@10, hard-miss rate). Evidence: on a Ukrainian legal corpus, Qwen3-Embedding-8B
  reached Recall@5 93.1% against OpenAI's 78.3%, and 3072 dimensions scored *worse* than
  2048 — a result that is not predictable from any leaderboard. Phoenix is the place to
  run it.

- **ADR-0002 — in-cluster embedding runtime**
  ([docs/adr/0002-embedding-runtime-in-cluster.md](docs/adr/0002-embedding-runtime-in-cluster.md)).
  Scopes three deployment shapes rather than picking one: a shared Deployment + Service as
  the abox default, the sidecar shape for ingestion and eval Jobs only, and llm-d deferred
  with explicit adoption triggers.

  llm-d is deferred rather than rejected. The integration is already half-present —
  agentgateway has first-class Gateway API Inference Extension support, and kgateway 2.2
  removed the inference path that did not go through agentgateway — but an embedding model
  is a single-pass encoder with no KV cache and no decode phase, so KV-cache-aware routing
  and prefill/decode disaggregation buy nothing, and llm-d targets accelerators that KinD
  does not have. The realistic trigger is adding a *generative* model to abox.

- **ToDo — run the model locally with llama.cpp**
  ([docs/todo/embeddings-local-llama-cpp.md](docs/todo/embeddings-local-llama-cpp.md)).
  Agent-executable runbook producing a callable OpenAI-compatible `/v1/embeddings`
  endpoint on `localhost:8088`, via Docker (recommended), a native binary, or Ollama
  (fallback). Covers the mandatory task-prefix contract (`search_document:` /
  `search_query:` / `clustering:` / `classification:`), client-side Matryoshka truncation
  with the required L2 re-normalization, and a two-stage Qdrant collection layout.

  Acceptance is a **semantic** test, not a liveness check: a cosine-similarity assertion
  that a related document outscores an unrelated one. Wrong pooling returns well-formed,
  useless vectors, and a 768-length array proves nothing on its own.

- **ToDo — run the model in the cluster (sidecar and llm-d)**
  ([docs/todo/embeddings-cluster-sidecar-llmd.md](docs/todo/embeddings-cluster-sidecar-llmd.md)).
  Part A: a shared Deployment + Service in an `embeddings` namespace, reached through the
  existing `agentgateway-external` Gateway. Part B: a native sidecar
  (`initContainers` + `restartPolicy: Always`) for ingestion Jobs. Part C: the llm-d
  migration path, written out so future adoption is a substitution behind a stable URL.

  The manifests are written against CODEBASE.md §Forbidden Patterns: namespace declared in
  the same Kustomization as the workload, a ReferenceGrant for the cross-namespace
  HTTPRoute, and the image pinned by digest because `ghcr.io/ggml-org/llama.cpp:server` is
  a floating tag. The `/v1/embeddings` route coexists with kagent's catch-all `/` by
  Gateway API longest-prefix precedence, so `releases/kagent.yaml` is untouched.

  Part A opens with a **fork prerequisites** step covering three failure modes that are
  silent rather than loud. `bootstrap/variables.tf` defaults `oci_registry` to the upstream
  registry while CI derives its push target from `${{ github.repository }}`, so a fork
  publishes to its own namespace but its cluster keeps reconciling upstream's artifact —
  `flux get all` stays green and the fork's own changes never arrive. A freshly created
  fork also carries no `v*` tags, which makes the version arithmetic in `make push`
  generate a malformed tag, and the first GHCR publish creates a private package the
  `OCIRepository` cannot pull.

  Resource limits are sized for a 2-core / 8 GB Codespace, the usual host for this sandbox:
  the embedder is capped at 1 CPU and 1 GiB rather than 2 and 2 GiB, since the node already
  carries three KinD nodes plus agentgateway, kagent with postgres, qdrant and phoenix, and
  a 2-CPU limit would let it starve the control plane. The startup probe budget is widened
  to 10 minutes to match, because a CPU-capped embedder loads slowly on a busy node.

### Verified

The local runbook was executed end to end against `ghcr.io/ggml-org/llama.cpp:server`
(digest `sha256:cbcdcb52…33ff4`) with the `Q8_0` GGUF. The server reached `/health` in
about six seconds on CPU, `/v1/embeddings` returned 768-dimension unit-length vectors,
batching returned one vector per input, and the semantic acceptance test separated a
related document from an unrelated one by a margin of 0.3829 (0.8209 against 0.4379).
Truncating to 256 dimensions held the ranking at a margin of 0.4036, so the Matryoshka
path works as ADR-0001 assumes.

Running it caught a defect in the documented flags, which is the reason the runbook exists.
**The model card's `--rope-freq-scale 0.75` does not give you the advertised 8192-token
context — it gives you 2730.** The GGUF reports `n_ctx_train = 2048` and llama.cpp caps a
slot at `n_ctx_train / rope_freq_scale`, then logs `the slot context (8192) exceeds the
training context of the model (2730) - capping` and carries on. Anyone copying the model
card verbatim indexes truncated documents and never sees an error. `0.25` yields the full
8192; inputs of 3520 and 5934 tokens were confirmed to embed cleanly, and the semantic
margin did not degrade (0.3829 at `0.25` against 0.3596 at `0.75`). ADR-0001 and both
runbooks were corrected.

A second hypothesis was tested and rejected rather than documented: the context is *not*
divided across parallel slots. The server defaults to four slots with `kv_unified = true`
and each one gets the full 8192, so `--parallel 1` would cost concurrency for no gain and
is deliberately absent from the commands.

- **`releases/embeddings.yaml`** — llama.cpp serving `nomic-embed-text-v1.5` in an
  `embeddings` namespace, reached through the existing `agentgateway-external` Gateway on
  `/v1/embeddings`, with the weights cached in a PVC by an initContainer. Added to
  `releases/kustomization.yaml` only after the deployment was verified in a live cluster —
  see below.

- **ToDo — verification suite**
  ([docs/todo/embeddings-verification.md](docs/todo/embeddings-verification.md)).
  Seven copy-pasteable checks with the expected values recorded from the run, to be
  repeated after an image or model bump. It leads with the context check, since a capped
  context truncates documents at index time without ever raising an error, and it ends by
  stating what it does *not* cover — one sentence pair detects a broken configuration, not
  retrieval quality on a real corpus.

### Verified in cluster

Deployed to KinD in a 2-core Codespace and checked end to end: rollout completed,
`n_ctx_slot = 8192` with no capping, the HTTPRoute reported `Accepted=True` and
`ResolvedRefs=True`, `/v1/embeddings` through the gateway at `172.18.0.5` returned 768
dimensions, and kagent's catch-all `/` still returned 200 — confirming the longest-prefix
precedence the route depends on.

The semantic test through the gateway returned **0.8209 related against 0.4379 unrelated,
identical to the local run**. Same model, same flags, same numbers on different hardware,
which is the evidence that the configuration is reproducible rather than incidentally
working.

One failure was worth recording. The first rollout stalled in `Init:ImagePullBackOff`, and
the pull error was a DNS `i/o timeout` from the node rather than a registry rejection —
the nested-Docker egress blackhole that `scripts/fix-egress.sh` exists for, which reported
`legacy FORWARD policy is DROP, which blackholes user-defined Docker bridges` and cleared
it. The tempting read was a Docker Hub rate limit, which would have led to swapping the
initContainer image; that would have fixed nothing, since the blackhole takes out every
registry including the one serving the main image.

### Notes

`releases/embeddings.yaml` is now in `releases/kustomization.yaml` and will ship in the
next OCI artifact. Publishing it was gated on the verification above, per CODEBASE.md.

A fork still needs the `oci_registry` override from the cluster runbook before `make push`
means anything: without it the cluster reconciles the upstream artifact and reports Ready
while ignoring the fork's own releases entirely.

### Preparation cost

Recorded for planning purposes — what it cost to produce the four documents above.

Source material reviewed: the llama.cpp site, the `nomic-ai/nomic-embed-text-v1.5` and
`-GGUF` model cards, the llama.cpp server reference, a write-up on Matryoshka embeddings
for faster vector search, the llm-d architecture proposal, the agentgateway inference
routing docs, and a Ukrainian-language case study on embedding selection for a legal-domain
RAG system (the source of the benchmark rule in ADR-0001).

| Stage | Tokens (approx.) |
|---|---|
| Repository familiarisation | 54,600 |
| Reviewing source material — 6 page fetches, 4 searches | 32,900 |
| Writing the ADRs, ToDos, and this changelog | 27,500 |
| Verification — YAML validation via `yq`, cluster and git state | 5,600 |
| **Total** | **~120,600** |

Quota consumed on a Claude Pro plan: **16% of the 5-hour session budget, 11% of the 7-day
budget.** Models used: Claude Sonnet 5 for repository familiarisation, Claude Opus 5 for
the research and drafting.

The token figures are reconstructed from context-budget markers rather than billing, and
the counter reset when the model was switched mid-task, so treat them as an estimate. The
quota percentages are read directly from the client's usage panel and are the more reliable
of the two.
