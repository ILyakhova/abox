# ADR-0003: Retrieval architecture — vector store, graph, or both

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** abox maintainers
- **Related:** [ADR-0001](./0001-text-embedding-model.md), [ADR-0002](./0002-embedding-runtime-in-cluster.md), [LAB4 graph evaluation](../../lab4/graph-evaluation.md), [LAB4 embedding evaluation](../../lab4/evaluation.md)

## Context

abox ships two stores and one agent that uses both. `retrieval-agent` queries Qdrant
through `qdrant-mcp` for document content and Neo4j through `neo4j-mcp` for relationships,
choosing between them on an instruction in its system prompt:

> Pick the store by the shape of the question, not by habit.

ADR-0001 and ADR-0002 decide what the embeddings are and where they run. Neither decides
whether the second store is worth its cost, and the pairing had never been measured. Two
questions were open:

1. Does the graph answer anything vector search cannot, or is it a convenience?
2. Does the selection rule actually work? It is an instruction, not a constraint — nothing
   prevents an agent from reaching for semantic search on a counting question.

## Decision

**1. Keep both stores. The graph is not optional for relationship questions.**

**2. The division of labour stands as the shipped prompt states it.** Vector search for
what an object says or configures; the graph for questions about references between
objects — how many, which are unused, what breaks if, what two things have in common.

**3. Ingest must populate both stores in the same run, and must be idempotent.** This is
the part that is not yet true and is the main work this ADR creates.

**4. Any agent given only one store must say which questions it cannot answer.** A
vector-only agent asked a counting question does not fail; it answers confidently about the
subset it retrieved.

## Evidence

Measured in LAB4 as a controlled comparison: two agents, identical model, identical
collection, identical retrieval discipline, differing only in whether the Neo4j tools were
present. Six relationship-shaped questions. Full protocol and transcripts in
[`lab4/graph-evaluation.md`](../../lab4/graph-evaluation.md).

| | vector only | vector + graph |
|---|---|---|
| exact | 1 of 6 | 5 of 6 |
| wrong | 2 | 0 |
| tokens, "which agent delegates to k8s-agent" | 1,178,890 | 62,454 |
| tokens, "is anything unreferenced" | 2,313,311 | 33,448 |

**Both wrong answers were confident.** Asked how many agents use a given ModelConfig, the
vector-only arm said two; the answer is four. Asked which MCP servers are unused, it named
one that is in use. In both cases it cited metadata and gave no indication of a partial
view. The failure is structural rather than occasional: vector search answers *how many of
these are among the documents I retrieved* and presents it as *how many there are*.

**The cost difference is nineteen-fold and sixty-nine-fold.** Every vector search returns
whole documents, and the conversation is re-sent on each round, so a question needing
several searches compounds into a million tokens of context. A Cypher query returns a list
of names. Vector retrieval pays for the volume of text that must be read; the graph pays
once, at ingest, for structure.

**The selection rule held six times out of six.** The graph-equipped agent used Cypher
alone on the four pure relationship questions and reached for vector search only where
document content was genuinely needed. This was the open question about the shipped design
and the answer is favourable — on this corpus, with this model.

**The honest counterweight.** Asked what two agents have in common, the vector-only arm
read both manifests and produced a correct, detailed comparison from a single search. At
fourteen documents a language model can hold what it retrieves and do the graph's work
itself. That is true while the text fits, and the token figures above are what fitting
costs. The graph's advantage is expected to widen with corpus size, but this lab cannot
demonstrate that.

## Why ingest must become idempotent and simultaneous

Two defects observed during LAB4, neither of them about retrieval quality:

**The stores drifted.** The vector collection was built at 18:03 and described
`retrieval-agent-nomic` as using `qdrant-mcp`. That was true then and false by the time it
was asked, the agent having been repointed at a different server that evening. The graph,
built the next morning, was correct. **Neither store reports its own age.** A vector hit
carries no timestamp, loses no confidence, and looks exactly like a current answer.

**Storing is not idempotent.** The vector ingest produced fifteen documents for fourteen
objects — one object stored twice, by an agent whose own prompt states the rule it broke.
Because a second ingest appends rather than replaces, re-indexing is an event to be avoided
rather than a routine, which is precisely what causes drift.

These are the same problem from two directions. Re-ingest has to be cheap and safe before
freshness can be maintained, and both stores have to be rebuilt together or answers must
carry the age of the data behind them. A content hash on `vector_store` closes the first
half.

## Consequences

- `retrieval-agent` keeps both stores. The pairing is justified by measurement rather than
  assumed.
- Any single-store retrieval agent — including the LAB4 arms — is understood to be an
  instrument for a specific measurement, not a model for production use.
- Ingest work is created: content-hash idempotency on `vector_store`, and a single ingest
  path that populates Qdrant and Neo4j together.
- The selection rule remains an instruction and therefore remains a risk. It held on six
  questions with one model; it is not enforced by anything, and a model change is reason to
  re-check it.
- The corpus is built from live cluster objects, so it can answer what is configured and
  never why — comments do not survive `kubectl apply`. Indexing the repository is a
  different corpus, and adding it is a separate decision.

## Re-evaluation triggers

1. The corpus exceeds roughly a thousand objects → re-run the comparison; the vector arm's
   ability to reason over retrieved text should degrade first.
2. The agent model changes → re-check that store selection still works, since nothing
   enforces it.
3. Ingest becomes idempotent → re-run both LAB4 experiments on freshly rebuilt stores, with
   the drift removed.
4. A question type appears that neither store serves well → revisit, rather than forcing it
   into one of them.

## Limits of the evidence

Fourteen objects, six questions, one run each. The standing benchmark rule in ADR-0001 —
roughly 200 gold queries against roughly 10K distractors — applies here too and is not
close to met. Two of the six questions are additionally not clean comparisons: the graph
held four objects the collection did not, which favours it on exactly the questions asking
what is unreferenced.

One structural caveat: **the graph was built by the same model that was then tested on
it.** Correct answers show the graph matches what that model understood at ingest time, not
that the graph is correct. It was spot-checked against `kubectl` here and matched, which is
weaker than verification.
