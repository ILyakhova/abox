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
  and prefill/decode disaggregation buy nothing. What remains is replica scheduling, which
  is worth nothing at one replica. The realistic trigger is adding a *generative* model.

  The ADR originally gave two further reasons — that llm-d does not serve embedding models,
  and that it requires accelerators — and a correction dated 2026-09-14 records that both
  are false, along with a third assumption that llm-d implies vLLM. An `llm-d-embedding`
  model service was observed running on a CPU KinD node, fronting `llama-server` on a GGUF.
  The decision is unchanged; its justification is now the narrower and correct one.

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

### LAB4 — agentic retrieval across two embedding models

Two agents over the same corpus, differing in their embedding model: the abox
`qdrant-mcp` (nomic-embed-text-v1.5, 768 dims, chunked, out-of-process) against
the official `mcp-server-qdrant` (all-MiniLM-L6-v2, 384 dims, in-process
fastembed). Twelve questions in four sections — exact term, paraphrase, content
deep inside long manifests, and negative controls. Protocol, transcripts and
results: [lab4/evaluation.md](lab4/evaluation.md).

Nothing in `lab4/` ships. This cluster reconciles the upstream OCI artifact, so
the objects are applied by hand and the shipped manifests are untouched.

**The result corrects ADR-0001 without changing its decision.** That ADR
rejected all-MiniLM-L6-v2 because a 256-token context would put long documents
out of reach. It does not: truncation applies to the embedding, Qdrant returns
the full text, and the language model reads the rest. The MiniLM arm quoted a
rule from line ~70 of an ~80-line prompt. What measurement did show is a
consistent ranking cost — two to three times the searches to reach the same
documents, and one question where it reached only half the answer. The
rejection stands; the reason in the ADR has been replaced with the measured one.

**Two findings that are not about embeddings at all, and matter more.**

`vector_find` had never returned anything to any agent. Every tool in
`qdrant-mcp` declares an `outputSchema` with a required `body` but populated
only `Content`, leaving `structuredContent` at `{"body":""}`. kagent honours the
declared schema and read an empty string. Asked "neo4j", the server ranked the
right manifest first at score 0.62, put the payload in `Content`, returned HTTP
200 — and the agent answered, accurately from where it sat, that the collection
was empty. No error was logged anywhere. Fixed in
`mcp/qdrant-mcp/internal/tools/embeddings.go`.

This was caught only because the protocol opens with a control question whose
answer both arms must find. On the first run the nomic arm missed it and the
MiniLM arm hit it — the opposite of the prediction — and the protocol says a
miss there means a broken setup rather than a weak model. Without that rule the
remaining eleven questions would have run with one arm blind, and ADR-0001 would
have been corrected in the wrong direction on the strength of a serialisation
bug.

The second: **a plaintext credential is in the corpus.** Both agents are
instructed never to ingest `Secret`, and both obeyed. It made no difference —
`neo4j-mcp` carries `NEO4J_MCP_PASSWORD: abox-neo4j` as a plain field in its
spec, which is exactly the kind of object the corpus is built from, and a
negative-control question surfaced it unprompted. Excluding kinds is not a
control over credentials; scanning values is. `neo4j-mcp` should take its
password from a Secret reference.

A third, smaller: **the cluster cannot tell you why.** One question asked for a
reason recorded in a YAML comment. Comments do not survive being applied, so no
comment from any manifest has ever been in the collection. A RAG corpus built
from live objects answers what is configured and never the rationale; indexing
the manifests from git is a different corpus, not a tidier version of this one.

Three defects in the experiment's own design were found and recorded rather than
quietly fixed: the arms initially searched at different depths (`k` of 10 against
5 over a 14-document corpus, which made ranking nearly irrelevant for one side);
the shipped `retrieval-agent` is pinned to a ModelConfig with a placeholder key,
which would have turned the comparison into GPT against Gemini had the key
worked; and the two pipelines differ in chunking as well as in model, which the
results cannot separate.

- **ADR-0003 — retrieval architecture**
  ([docs/adr/0003-retrieval-architecture.md](docs/adr/0003-retrieval-architecture.md)).
  Keeps both stores and records why, from measurement rather than assumption. A second
  LAB4 experiment held everything constant between two agents and varied only whether the
  Neo4j tools were present: same model, same collection, same retrieval discipline, six
  relationship-shaped questions.

  The graph-equipped arm was exact on five of six. The vector-only arm was exact on one and
  **wrong on two — confidently both times**, citing metadata and flagging nothing. That is
  the structural finding: vector search answers *how many of these are among the documents
  I retrieved* and presents it as *how many there are*. Asked how many agents use a given
  ModelConfig it said two, where the answer is four.

  The cost difference is the concrete result: **62,454 tokens against 1,178,890** on one
  question and **33,448 against 2,313,311** on another, in both cases for an answer that
  was no better and once worse. Vector retrieval pays for the volume of text it must read;
  the graph pays once, at ingest, for structure.

  The counterweight is recorded too. Asked what two agents have in common, the vector-only
  arm read both manifests and produced a correct detailed comparison from a single search.
  At fourteen documents the language model does the graph's work itself — while the text
  fits, and the figures above are what fitting costs.

  The shipped design's store-selection rule — an instruction in the system prompt, enforced
  by nothing — held six times out of six. That was the open question about the design.

  The ADR also creates work rather than only recording a decision. The two stores were
  observed to have **drifted**: the collection still described an agent's configuration as
  it had been hours earlier, and no vector hit carries an age. Combined with vector storage
  not being idempotent — the ingest produced fifteen documents for fourteen objects —
  re-indexing is an event to be avoided rather than a routine, which is what causes the
  drift in the first place. A content hash on `vector_store` and a single ingest path that
  populates both stores together are the remedies named.

- **ADR-0004 — agent memory**
  ([docs/adr/0004-agent-memory.md](docs/adr/0004-agent-memory.md)).
  ADR-0003 decided how abox retrieves; it left open that an agent which retrieves
  still remembers nothing. `xray-memory` serves a pre-built snapshot over MCP and,
  when writable, gives the agent a second map it writes into — the corpus is what
  it knows, the notes are what it remembers.

  LAB5 built a corpus by hand and measured an agent against it: the cluster's own
  kagent topology, which is the same subject LAB4 measured through Qdrant and
  Neo4j, so this is a third arm rather than an isolated result. Twelve questions,
  twelve correct answers — and the findings that matter are the ones that survived
  being right.

  **Counting worked, by the right mechanism.** Asked how many agents exist, the
  agent selected the whole set (`kind: "Agent"`) instead of ranking a page of it.
  That is the class of question LAB4's vector-only arm answered confidently and
  wrongly. It reached for the mechanism because the prompt says to, which is
  ADR-0003's open risk appearing in a second place.

  **Encryption turned out not to be access control.** Asked for the Neo4j
  password, the agent returned it in plaintext while the corpus was age-encrypted
  throughout. Encryption protects a snapshot from whoever pulls the image; it does
  nothing about whoever asks the agent, and the MCP endpoint has no
  authentication. The cause was an ingest script copying `env` as `key=value` —
  and `neo4j-mcp` holds `NEO4J_MCP_PASSWORD` as a plain field, so the
  never-ingest-`Secret` rule did not apply. **ADR-0003 had already recorded that a
  kind-based exclusion list is not a control; the script was written a week later
  and did not apply it.** Redaction now happens on the way in, by key name, and
  was verified through the agent rather than by grepping the file.

  **Freshness and retention are in conflict in the chart.** `seed` will not
  overwrite a file the volume already holds, so replacing a corpus means deleting
  the claim — and the notes live on that claim. Rebuilding the corpus during the
  lab destroyed the agent's memory. The deployment as configured cannot hold both
  a current corpus and a persistent memory, and nothing reports the loss.

  **The notes map is shared, not per-agent.** `recall` returned a note written
  earlier by a raw MCP client. One server-side store, every client that reaches
  `/mcp`, no authentication — useful for surviving restarts, hazardous because an
  agent presents whatever it finds there as its own recollection.

  Voice and avatar front-ends were optional in the exercise and are deferred with
  no work started; they are interface work over this decision rather than changes
  to it.

### Cost

Recorded per day and cumulatively, for planning.

| Date | Work | Tokens (approx.) |
|---|---|---|
| 2026-09-13 | Source material, ADR-0001 and ADR-0002, the runbooks, the local run that found the rope defect | 120,600 |
| 2026-09-14 | Cluster deployment and verification, the egress blackhole, the upstream graph-RAG discovery, diagrams, correcting ADR-0002 | 127,400 |
| 2026-09-15 | LAB4 — merging `feat/llmd-embeddings`, rebuild on Kubernetes 1.37, the official Qdrant MCP arm, the evaluation protocol | 88,000 |
| 2026-09-15 (evening) | Running LAB4: the `structuredContent` defect, the search-depth correction, twelve questions through two agents, ADR-0001 corrected | 68,000 |
| 2026-09-16 | Closing the task list, the graph arm, six relationship questions, ADR-0003 | 47,000 |
| 2026-09-19 | LAB5 — local cluster on WSL2, xray-memory, the corpus, encryption, twelve questions, ADR-0004 | 96,000 |
| | **Cumulative** | **~547,000** |

Day one's figure breaks down as roughly 54,600 on reading the repository, 32,900 on source
material (six page fetches and four searches), 27,500 on writing, and 5,600 on verification.

Source material reviewed on day one: the llama.cpp site, the `nomic-ai/nomic-embed-text-v1.5`
and `-GGUF` model cards, the llama.cpp server reference, a write-up on Matryoshka embeddings
for faster vector search, the llm-d architecture proposal, the agentgateway inference routing
docs, and a Ukrainian-language case study on embedding selection for a legal-domain RAG
system — the source of the benchmark rule in ADR-0001.

Day three's first session is the cheapest of the four despite covering the most ground:
nothing was spent re-establishing where things live or what had already been decided. The
evening session cost most of a day's budget again, and almost none of it went on the
experiment as planned. Two false starts and three design defects absorbed it — which is
the honest shape of running something rather than designing it, and the reason the two
most useful findings exist at all.

Models: Claude Sonnet 5 for the initial read of the repository, Claude Opus 5 for everything
after.

**On the figures.** They are reconstructed from context-budget markers, not billing, and the
counter resets between turns, so each day is a sum of per-turn deltas rather than a reading
off a meter. Treat them as ±10–15%. A quota reading taken partway through day one showed 16%
of the 5-hour session budget and 11% of the 7-day budget on a Claude Pro plan; that is a
point measurement, not a total, and is not comparable to the table above.
