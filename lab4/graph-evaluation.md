# LAB4, second experiment — what the graph adds

A separate question from the embedding comparison in
[`evaluation.md`](evaluation.md), and deliberately run separately. That one asked
which embedding model ranks better; this one asks what a second store buys on top
of vector retrieval.

They could not be combined. A graph in one arm of the embedding comparison would
have won questions for reasons that have nothing to do with embeddings, and the
result would have looked like a verdict on the model.

| Arm | Agent | Stores |
|---|---|---|
| **N** | `retrieval-agent-nomic` | vector only — `abox-nomic` |
| **G** | `retrieval-agent-graph` | the same `abox-nomic`, plus Neo4j |

Everything else is held constant: same ModelConfig, same vector server, same
collection, same retrieval discipline. Arm G's prompt adds the graph rules from
the shipped `retrieval-agent`, because the shipped design is what is under
evaluation.

## Arm G does not re-index the vectors

The collection is shared with arm N and already populated. `vector_store` is
withheld from arm G's toolset entirely: storing is not idempotent, and a second
ingest would leave every object duplicated — invalidating results already
recorded in `evaluation.md`.

Arm G's ingest builds the graph only.

## Ingest

Neo4j starts empty; confirmed before the run:

```bash
kubectl -n neo4j exec sts/neo4j -- cypher-shell -u neo4j -p abox-neo4j \
  "MATCH (n) RETURN count(n) AS nodes;"
```

Then, in a fresh chat with `retrieval-agent-graph`:

> Build the graph for namespace kagent: all Agents, all ModelConfigs, all
> MCPServers, all RemoteMCPServers. Model the references between them. Do not
> write to the vector store.

Check what it built before asking anything:

```bash
kubectl -n neo4j exec sts/neo4j -- cypher-shell -u neo4j -p abox-neo4j \
  "MATCH (n) RETURN labels(n)[0] AS kind, count(*) AS n ORDER BY n DESC;"
kubectl -n neo4j exec sts/neo4j -- cypher-shell -u neo4j -p abox-neo4j \
  "MATCH ()-[r]->() RETURN type(r) AS rel, count(*) AS n ORDER BY n DESC;"
```

Expect roughly sixteen nodes — the fourteen indexed objects plus the two
RemoteMCPServers the vector corpus omitted — and `USES_MODEL` edges from every
Agent, `USES_TOOL` edges to the MCP servers, `DELEGATES_TO` where an Agent lists
another Agent as a tool.

**If node count is far below sixteen, or there are no relationships, stop.** An
empty or partial graph makes arm G a slower copy of arm N, and the comparison
measures the ingest rather than the design.

## Questions

Relationship-shaped, deliberately. These are the questions vector search cannot
answer — not because the text is missing, but because the answer is a computation
over references rather than a similarity between documents.

1. How many agents use `gemini-gemini-3-5-flash`?
2. Which agents would break if `kagent-tool-server` were removed?
3. Which MCP servers are not used by any agent?
4. What do `retrieval-agent` and `retrieval-agent-official` have in common?
5. Which agent delegates to `k8s-agent`, and which does not?
6. Is there any object that nothing references?

Ask each in a fresh chat in both arms.

Question 4 is the interesting one. Vector search will find both manifests easily
— they are textually similar and both are in the collection. "What they have in
common" is still not a thing it can answer, because commonality is set
intersection over edges, not proximity in a vector space. If arm N answers it by
reading both manifests and comparing them itself, that is worth recording as a
distinct outcome: the language model doing the graph's job over retrieved text.

## Recording results

| # | Arm N (vector only) | Arm G (vector + graph) | Store G used | Note |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |

Mark each:

- **exact** — the right answer, complete
- **partial** — right in part, or right without being able to show why
- **reasoned** — arrived at by the language model comparing retrieved text rather
  than by querying the store that was built for it
- **refused** — said it could not answer from what it has
- **wrong** — an answer that is not true of the cluster

Record which store arm G used for each. **Choosing the wrong store is itself a
result**, and one of the things this experiment is for: the prompt tells it to
pick by the shape of the question, and whether that instruction actually works is
not obvious.

## Pre-registered expectations

**Questions 1, 3, 5 and 6: arm G should win outright.** Counting, finding
unreferenced objects, and enumerating edges are graph operations. Arm N should
refuse them or answer by exhaustively reading everything it can retrieve — and
its vector search returns five results, so on a corpus of fourteen it cannot see
the whole set in one go. A confident answer from arm N on question 3 or 6 is
more likely to be wrong than right, and should be checked against the cluster
rather than believed.

**Question 2 needs both stores.** Find what references `kagent-tool-server`, then
say what those objects are. If arm G answers it with one Cypher query and no
vector search, that is correct behaviour and worth noting — the graph carries
enough.

**Question 4 is the discriminating one.** If arm N answers it well by reasoning
over retrieved text, the graph's value narrows considerably: at this corpus size
the language model can hold everything it retrieves and do the comparison itself.
The graph's advantage would then be a claim about scale, not about capability —
and this corpus is far too small to demonstrate scale.

**The result that would matter most** is arm G using the wrong store. It has an
explicit rule for choosing, written in the shipped agent's own words. If it
reaches for `vector_find` on a counting question, then the shipped design depends
on an instruction the model does not reliably follow, and that is a finding about
the design rather than about either store.

## What this cannot show

The same limits as the first experiment, plus one.

Fourteen objects and six questions. The standing benchmark rule in ADR-0001 asks
for three orders of magnitude more, and that rule applies here too.

The added limit: **the graph was built by the same language model being tested.**
If arm G answers a relationship question correctly, that shows the graph it built
matches what it understood at ingest time — not that the graph is correct.
Verifying that needs the Cypher output checked against `kubectl`, which the
ingest checks above do only in aggregate.
