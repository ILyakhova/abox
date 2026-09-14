# ADR-0001: Text embedding model for abox

- **Status:** Accepted
- **Date:** 2026-09-13
- **Deciders:** abox maintainers
- **Related:** [ADR-0002](./0002-embedding-runtime-in-cluster.md), [ToDo: local runtime](../todo/embeddings-local-llama-cpp.md), [context vs concurrency](../embeddings-context-and-concurrency.md)

## Context

abox ships Qdrant (vector database) and Arize Phoenix (LLM observability), but nothing in
the sandbox turns text into vectors. Qdrant is an empty store. Every retrieval path a user
would build on abox — kagent tool retrieval, an eval corpus in Phoenix — currently has to
reach a hosted embedding API. kagent's `providers.default: openAI` makes that explicit.

That has three costs: a network dependency in a sandbox whose selling point is "one
command, runs locally", a per-token bill, and user text leaving the machine.

Constraints that bound the choice:

| Constraint | Consequence |
|---|---|
| KinD on a laptop or Codespaces, no GPU | CPU inference is the baseline, not a fallback |
| 1 control-plane + 2 workers in Docker | Model resident set has to be measured in hundreds of MiB, not GiB |
| Flux reconciles from an OCI artifact | Model and runtime must be pinnable and declarative |
| Reached through agentgateway (Gateway API) | The runtime needs a plain HTTP service, ideally OpenAI-shaped |
| Repo is Apache 2.0 | Model licence must be permissive and non-gated |

## Decision

The default text embedding model for abox is **`nomic-ai/nomic-embed-text-v1.5`**, served
as GGUF via **llama.cpp `llama-server`** behind its OpenAI-compatible `/v1/embeddings`
endpoint.

Default operating point:

| Parameter | Value |
|---|---|
| Quantization | `Q8_0` (~140 MiB) |
| Embedding dimensions | 768 (full) |
| Context | 8192 tokens, YaRN RoPE scaling |
| Pooling | `mean` |
| Matryoshka truncation | opt-in, 256 dims for the shortlist stage |

## Rationale

**Size-to-quality ratio.** 137M parameters, MTEB 62.28 at 768 dims. The Q8_0 GGUF is
~140 MiB on disk. It runs on a KinD worker next to everything else abox already deploys.
Nothing in the 100M class that beats it on MTEB also gives us 8k context.

**8192-token context.** Long enough to embed a whole document chunk without aggressive
splitting. Most models in this size class cap at 512 tokens, which forces a chunking
strategy on the user before they have a corpus to tune it against.

**Matryoshka Representation Learning.** The model is trained so that truncated prefixes of
the vector remain valid embeddings:

| Dimensions | MTEB | Relative size |
|---|---|---|
| 768 | 62.28 | 100% |
| 512 | 61.96 | 67% |
| 256 | 61.04 | 33% |
| 128 | 59.34 | 17% |
| 64 | 56.10 | 8% |

Losing 1.24 MTEB points for a 3× smaller index is what makes two-stage adaptive retrieval
possible with a *single* model and a single forward pass: shortlist on 256-dim vectors,
rescore the candidates on the full 768. Published numbers for that pattern put p50 latency
at 18 ms against 32 ms for single-stage 768-dim search — a 44% reduction — with recall
essentially unchanged. We get the option for free; see ADR-0002 and the Qdrant collection
layout in the local runtime ToDo.

**Apache 2.0, not gated.** Redistributable, no HuggingFace token in the bootstrap path.

**First-class GGUF.** `nomic-ai/nomic-embed-text-v1.5-GGUF` publishes 15 quantizations
(Q2_K at 48 MiB through F32 at 262 MiB). No conversion step enters our pipeline.

**Independently corroborated.** A separate deployment reached this repository later, solving
the same problem against the same constraints, and had settled on the same model at the same
quantization — confirmed from its server metadata rather than its labels. That is not proof
the choice is right for any given corpus, and the benchmark rule below still stands, but it
does say the reasoning above is not idiosyncratic. The two differ in tuning, which is
compared in [context vs concurrency](../embeddings-context-and-concurrency.md).

**OpenAI wire format.** Served by `llama-server`, the endpoint is a drop-in for
`text-embedding-3-small`. Moving a project from the hosted API to the local model is a
base-URL change, and moving back is the same change in reverse. That keeps the decision
cheap to reverse, which matters given the caveat below.

## Consequences

**Task prefixes are part of the data contract, not a tuning knob.** The model requires an
instruction prefix on every input: `search_document:` when indexing, `search_query:` when
querying, `clustering:`, `classification:` elsewhere. Omitting or mismatching them degrades
recall *silently* — no error, just worse results. This has to be enforced in ingestion and
query code, never left to the caller.

**Truncation is client-side.** `llama-server` always returns the full 768-dim vector.
Matryoshka truncation means slicing the first N components **and re-normalizing to unit
L2 length**. Skipping the re-normalization breaks cosine distance. No flag in llama.cpp
does this.

**Q8_0 is the floor, not Q4.** Retrieval is more sensitive to small vector perturbations
than chat generation is. Q4_K_M saves 59 MiB against Q8_0 — a rounding error in this
cluster — in exchange for an unvalidated recall regression. Not worth it.

**The 8192 context is not what you get by default, and the model card's own flags do not
deliver it.** The GGUF reports `n_ctx_train = 2048`; the 8192 figure is reached by RoPE
scaling, and llama.cpp caps a slot at `n_ctx_train / rope_freq_scale`. The model card's
llama.cpp invocation passes `--rope-freq-scale 0.75`, which yields `2048 / 0.75 = 2730` and
a silent cap well short of the advertised context. `0.25` yields the full 8192. Verified
against the runtime — see the [local runbook](../todo/embeddings-local-llama-cpp.md#2-option-a--docker-recommended).
Anyone copying the model card verbatim will index truncated documents and never see an
error.

**The model is English-first.** This is the largest limitation and the reason for the rule
below.

## The benchmark obligation

This ADR selects a *default*, not an answer. The distinction is load-bearing, and the
Yustai case study (RAG over Ukrainian legal texts) is the evidence:

- Qwen3-Embedding-8B reached Recall@5 of **93.1%** against OpenAI `text-embedding-3-small`
  at **78.3%** on that corpus — a 14.8 point gap. Hard misses (no hit in top-50) fell from
  19.2% to 6.4%. Neither ranking is predictable from MTEB.
- Testing **3072 dims performed worse than 2048** — a dimension falling between Matryoshka
  training breakpoints. "More dimensions is better" is false, and the right dimension is an
  empirical question about your corpus.
- The winning embedder retrieved well enough that the **reranker became unnecessary**,
  removing a component, its latency, and its per-query cost.
- Exact search agreed with HNSW on 99.6% of results, proving the failures were embedding
  quality rather than index approximation.
- Total cost of the entire benchmark: **under $0.50.**

Therefore, as a standing rule for anything built on abox:

> Before an embedding-backed retrieval path is put in front of users, benchmark it on your
> own corpus. Roughly 200 LLM-generated gold queries against ~10K distractor chunks is
> documented as statistically sufficient. Track Recall@K, MRR, nDCG@10 and hard-miss rate.
> Treat MTEB as a directional signal only.

Phoenix is already in the stack; it is where that benchmark should run and be stored.

## Alternatives considered

| Option | Verdict |
|---|---|
| **OpenAI `text-embedding-3-small`** (status quo) | Needs a key and egress, text leaves the machine, per-token cost, cannot run offline. Also the losing baseline in the Yustai benchmark. Retained as a comparison baseline, rejected as the default. |
| **`BAAI/bge-m3`** | Genuinely multilingual (100+ languages including Ukrainian), 8192 context, multi-vector retrieval. But 568M parameters, ~2.2 GB at F16 — roughly 4× the memory and latency of nomic on CPU. **This is the designated escape hatch the moment the corpus is not English.** |
| **`Qwen3-Embedding-0.6B / 4B / 8B`** | 8B won the Yustai benchmark decisively and supports Matryoshka. 8B is GPU territory; 0.6B is plausible on CPU. Strongest candidate to displace nomic once abox has a GPU path. |
| **`all-MiniLM-L6-v2`** | 22M parameters and very fast, but a 256-token context and MTEB ~56 with no Matryoshka. Context is too short for document chunks. |
| **`nomic-embed-text-v2-moe`** | Multilingual MoE successor with better language coverage. 475M total parameters and MoE routing is less well-trodden in llama.cpp. Tracked as the likely next revision of this ADR. |

## Re-evaluation triggers

Revisit this ADR when any of the following becomes true:

1. The target corpus is not predominantly English → evaluate `bge-m3` and `nomic-embed-text-v2-moe`.
2. A GPU node joins the cluster → evaluate `Qwen3-Embedding`.
3. A benchmark on the target corpus shows Recall@5 below 85%.
4. llama.cpp gains server-side Matryoshka truncation → drop the client-side slicing code.
