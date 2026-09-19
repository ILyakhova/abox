# ADR-0004: Agent memory — a snapshot corpus and a notes map over MCP

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** abox maintainers
- **Related:** [ADR-0001](./0001-text-embedding-model.md), [ADR-0003](./0003-retrieval-architecture.md), [LAB5 evaluation](../../lab5/evaluation.md)

## Context

ADR-0003 decided how abox *retrieves*: a vector store for content, a graph for
relationships, both populated by an ingest run. It left a question open that the
word "retrieval" hides — an agent that retrieves has no memory of the
conversation it is having, or of any earlier one.

`xray-memory` answers a different question from Qdrant and Neo4j. It serves a
**pre-built snapshot** over MCP and, with `server.writable: true`, gives the
agent a second map it writes into: `remember` stores a note, `recall` reads
notes back, `forget` removes one. The corpus is what the agent knows; the notes
are what it remembers.

LAB5 built a corpus for it and measured an agent against it. Full protocol,
transcripts and cost in [`lab5/evaluation.md`](../../lab5/evaluation.md).

## Decision

**1. Agent memory in abox is two maps, not one store.** A read-only corpus built
by an ingest step, and a writable `session` map the agent owns. They are reached
through the same MCP server and must be kept distinct in the agent's prompt,
because nothing in the tool names distinguishes them.

**2. The corpus is built from selected fields, never from whole objects, and
values are redacted on the way in by key name.**

**3. The notes map must not share a volume with the corpus.** Not satisfied by
the current chart; see below.

**4. The MCP endpoint stays cluster-internal.** It is unauthenticated, it writes,
and its notes are shared across every client that reaches it.

**5. Voice and avatar front-ends are deferred**, with no work started. See
"Deferred".

## Evidence

One agent, twelve questions, over a corpus of the cluster's own kagent topology
— the same subject LAB4 measured through Qdrant and Neo4j, which makes this a
third arm rather than an isolated result.

All twelve were answered correctly. The useful findings are the ones that
survived correct answers.

**Set questions were answered by selecting a set.** Asked how many agents exist,
the agent called `search_graph` with `kind: "Agent"` and `limit: 100` — the whole
set, not a ranked page of it. This is the class of question LAB4's vector-only
arm got wrong while sounding right, reporting "how many of these are among the
five I retrieved" as "how many there are". The mechanism exists here and the
agent used it.

It used it because the prompt says to. Mechanism selection rests on an
instruction that nothing enforces, exactly as store selection does in ADR-0003.
One model, one corpus, one run.

**Snapshot staleness was handled and then volunteered.** Asked about an object
present in the cluster and absent from the snapshot, the agent named the absence
and separated "not in the snapshot" from "does not exist". Four questions later
it added the caveat unprompted, where nothing had asked for it.

**Memory crossed conversations.** A question asked in a fresh chat with no
history was answered from notes alone, in one `recall` call, for 22,888 tokens.

**Cost sits between LAB4's two arms.** Eleven of the twelve questions cost
between 11K and 217K tokens; one cost 475K. LAB4's vector-only arm spent 1.17M
and 2.31M on comparable questions, its graph arm 62K and 33K. Tool-call count
predicts cost poorly — the cost is in what a call returns, and `get_graph_node`
returns a whole node.

### Against the other arms

Four approaches have now been measured on this subject: vector-only with two
different embedders (N, M), vector plus graph (G), and the snapshot corpus here
(X). The side-by-side table is in
[`lab5/evaluation.md`](../../lab5/evaluation.md#cross-arm-comparison); it was
added after review pointed out that the arms had been named across three
experiments and never compared in one place.

What it supports: **set and count questions are the only ones that separate
them.** Every arm answered plain retrieval and paraphrase correctly. Arm N was
wrong twice on questions whose answer is a whole set, while G and X were exact by
two different mechanisms — Cypher and `kind` selection. Cost spans two orders of
magnitude and does not track quality: arm N spent 2.31M tokens on a worse answer
than arm G gave for 33K.

What it does not support: a benchmark of stores. The arms ran against corpora
that resembled each other rather than one frozen corpus, and arm X's nodes were
written as prose *for* retrieval where the others held whole manifests.

## Encryption is not access control

Asked for the Neo4j password, the agent returned it in plaintext. The corpus was
age-encrypted at the time and it made no difference at all.

This is worth stating as a rule rather than an incident: **encryption protects a
snapshot from whoever pulls the image or reads the volume; it does nothing about
whoever asks the agent.** The retrieval path is not the file path. An encrypted
map that recites its contents on request is protected in no sense that matters,
and the MCP endpoint in front of it has no authentication.

The cause was in the ingest script, which copied MCPServer `env` into node text
as `key=value`. `neo4j-mcp` carries `NEO4J_MCP_PASSWORD` as a plain field, so the
rule this repository already had — never ingest `Secret` — did not apply.

That is precisely the finding ADR-0003 recorded: *a kind-based exclusion list is
not a control over credentials in plain fields; scanning values is.* The script
was written a week after that sentence, by people who had written it, and did
not apply it. A rule in an ADR is not a control either.

**So: redact on the way in, by key name, in the ingest step.** There is no way
back out — a corpus is embedded, copied into an image, and served; nothing
downstream can unsay it.

## Freshness and retention are in conflict in the current chart

`snapshots.seed` copies only files the volume does not already hold
(`overwrite: false`). A map therefore cannot be replaced in place: shipping a
new corpus means deleting the claim. The `session` notes live on that same
claim.

Rebuilding the corpus during LAB5 destroyed the agent's memory, and not by
mistake — **the deployment as configured cannot hold both a current corpus and a
persistent memory.** ADR-0003's staleness argument pushes toward rebuilding
often; this pushes the other way, and nothing reports the loss.

Two ways out, neither in the chart today: copy `session.graph.gob.gz` off the
claim and back around a rebuild, or give the notes their own volume. The second
is the right shape — they have different lifecycles and different sensitivity —
and it is the work this ADR creates.

## The notes map is shared, not per-agent

`recall` returned a note written earlier by a raw MCP client rather than by the
agent. `session` is one server-side store, shared by every client that can reach
`/mcp`, and that endpoint is unauthenticated.

This is useful — it is how memory survives a pod restart or a second agent — and
it is a hazard: anything anyone writes becomes every agent's memory, and an
agent will present it as its own recollection. Keep the endpoint
cluster-internal, and treat a note as it would be treated if any agent could
have written it, because any of them could.

## Consequences

- Ingest gains a redaction step. It is not optional and not a lint rule.
- A second volume for the notes map, or a documented copy-out/copy-in around
  every corpus rebuild.
- The corpus is a photograph. Agents reading it must say so when a question
  turns on something that may have changed — this held here, and it rests on the
  prompt.
- The MCP endpoint gets no HTTPRoute. If it ever needs one, authentication comes
  first, because the same endpoint writes memory.
- The comparison in LAB5 is not clean and should not be quoted as one: the
  corpora differ slightly from LAB4's, and the nodes here were written as prose
  *for* retrieval where LAB4 stored whole manifests. Some of the result is the
  corpus, not the store.

## Deferred

**Avatar and voice front-ends.** Both were optional in the exercise and neither
was started. They are interface work over the memory decided here rather than
changes to it: a voice agent delegating to kagent agents over A2A, and an avatar
rendering a conversation. Nothing in this ADR blocks them, and nothing in them
would change it. Revisit when there is a reason beyond novelty — a user who
cannot type, or a demo that needs to be watched rather than read.

## Re-evaluation triggers

1. The notes map gets its own volume → re-run LAB5's section D across a corpus
   rebuild, which currently cannot be done.
2. The agent model changes → re-check that set selection is still reached for;
   nothing enforces it.
3. The corpus grows past roughly a thousand nodes → re-measure cost;
   `get_graph_node` returning whole nodes is what pays for the answers.
4. The MCP endpoint is exposed outside the cluster for any reason →
   authentication and per-client note scoping become prerequisites, not
   improvements.

## Limits of the evidence

Twelve questions, fifteen nodes, one agent, one model, one run each. ADR-0001's
standing benchmark rule — roughly 200 gold queries against roughly 10K
distractors — applies here as it does everywhere else in this repository, and is
not close to met.

One caveat particular to this lab: the corpus was written by the same people who
wrote the questions, and written as prose intended to be searched. That flatters
retrieval quality in a way a corpus found in the wild would not.
