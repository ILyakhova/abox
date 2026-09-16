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

### What the ingest actually built

18 nodes, 27 relationships.

| kind | n | | rel | n |
|---|---|---|---|---|
| Agent | 10 | | USES_TOOL | 12 |
| MCPServer | 4 | | USES_MODEL | 10 |
| ModelConfig | 2 | | DELEGATES_TO | 5 |
| RemoteMCPServer | 2 | | | |

`abox-nomic` still holds 21 points, unchanged, so arm G respected its toolset and
wrote nothing to the vector store.

### The graph holds more than the collection does

18 objects against 14. The difference is two `RemoteMCPServer`s — the verbatim
ingest instruction for the first experiment never named that kind — plus
`qdrant-mcp-fixed` and `retrieval-agent-graph`, neither of which existed when the
vectors were indexed.

**Arm G therefore has an advantage in coverage as well as in structure**, and it
lands squarely on questions 3 and 6, which ask what is *not* referenced. Arm N
cannot name an object it never indexed, and arm G can.

This cannot be equalised. Re-indexing the vectors would duplicate the collection
and invalidate the first experiment, whose results are already recorded. So it is
recorded as a known bias instead: **questions 3 and 6 are not clean comparisons,
and a win for arm G on either of them is partly an artefact of corpus drift.**
Questions 1, 2, 4 and 5 concern objects both stores hold and are unaffected.

The underlying point is worth keeping regardless of this lab. Two stores
populated at different times drift apart, and nothing in either reports the
drift. A hybrid retrieval design needs its stores ingested together or it
silently answers from two different versions of the world.

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
| 1 | **wrong** — said 2 (6 searches) | **exact** — said 4, named them (5 calls) | graph + vector | truth is 4; N counted what its five results happened to contain |
| 2 | **partial** — 2 of 5 (2 searches) | **exact** — all 5, plus transitive impact via `DELEGATES_TO` (5 calls) | graph only | G used no vector search at all, which the protocol registered as correct |
| 3 | **wrong** — named `qdrant-mcp-official`, which `retrieval-agent-official` uses (8 searches) | **exact** — none are unused, listed every server with its users (5 calls) | graph only | see the staleness finding below; N's corpus predates the cluster it describes |
| 4 | **reasoned** — rich, correct comparison from 1 search | **exact** — same substance, 4 calls, each fact labelled by store | graph + vector | the registered outcome that narrows the graph's claim; see below |
| 5 | **exact** — 5 searches, **1,178,890 tokens** | **exact** — 2 calls, **62,454 tokens** | graph only | same answer, 19× the cost; see below |
| 6 | **partial** — incomplete list, 8 searches, **2,313,311 tokens** | **exact** — all 8, correctly excluding `promql-agent`, 2 calls, **33,448 tokens** | graph only | 69× the cost for a worse answer |

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

## The stores drifted, and neither one said so

Question 3 turned up something the question was not asking about.

Arm N stated that `qdrant-mcp` is used by `retrieval-agent` **and
`retrieval-agent-nomic`**. That was true when the vectors were indexed, at 18:03.
It stopped being true later the same evening, when `retrieval-agent-nomic` was
repointed at `qdrant-mcp-fixed` to get past the `structuredContent` defect. The
cluster confirms the current state:

```
retrieval-agent                 qdrant-mcp neo4j-mcp
retrieval-agent-nomic           qdrant-mcp-fixed
```

The graph was built today and is current. The collection is a snapshot of a
cluster that no longer exists.

**Neither store reports this.** Arm N answered fluently, cited metadata, and was
describing a configuration that had been replaced hours earlier. There is no
staleness signal in a vector hit — no timestamp in the answer, nothing that
degrades, no confidence penalty. A correct-looking answer from a stale corpus is
indistinguishable from a correct answer.

This is the more serious half of the finding recorded above about the graph
holding more objects than the collection. That one was an artefact of how this
lab was built. This one is structural: **any RAG corpus starts drifting from the
cluster the moment ingest finishes**, and a hybrid design with two stores
ingested at different times drifts in two directions at once.

What follows for abox: ingest needs to be re-runnable and idempotent, so it can
be routine rather than an event — which is the same conclusion the duplicate in
`evaluation.md` pointed at, arrived at from the other side. Either both stores
are rebuilt together, or answers need to carry the age of the data they came
from.

## The cost difference is a factor of nineteen

Question 5 was answered correctly by both arms. The kagent UI reports token usage
per chat, and both were asked in a fresh chat:

| | searches | tokens |
|---|---|---|
| Arm N, vector only | 5 | **1,178,890** |
| Arm G, graph | 2 | **62,454** |

Same question, same answer, nineteen times the cost.

The mechanism is not subtle. Every `vector_find` returns five full manifests —
chunks of up to 7000 characters — and the whole conversation is re-sent on each
round, so five rounds of retrieval compound into roughly a million tokens of
context. A Cypher query returns a list of names.

Stated generally: **vector retrieval pays for the volume of text that has to be
read; a graph pays for structure computed once at ingest.** On relationship
questions that is not a difference in quality, it is a difference in order of
magnitude of cost.

This reframes the result of question 4. Arm N answered that one well by reasoning
over retrieved text — but "the language model can do the graph's job" is only
true while the text fits and somebody is willing to pay for it. Here it fit, and
the bill was 1.2M tokens for a question whose answer is four names.

Worth checking against a real corpus before generalising: these figures are one
observation each, on fourteen documents, and the graph's advantage should widen
rather than narrow as the corpus grows.

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

## Results

Six questions. Arm G was exact on five and correct-but-expensive on the sixth.
Arm N was exact on one, reasoned its way to a good answer on one, partial on two
and wrong on two.

| | Arm N (vector only) | Arm G (vector + graph) |
|---|---|---|
| exact | 1 | 5 |
| reasoned / partial | 3 | 1 |
| wrong | 2 | 0 |
| tokens, q5 | 1,178,890 | 62,454 |
| tokens, q6 | 2,313,311 | 33,448 |

**Both of arm N's wrong answers were confident.** It did not say it was unsure,
did not flag a partial view, and cited metadata while doing it. That is the
failure mode worth taking away: on a counting or set question, vector retrieval
answers *"how many of these are among the five documents I happened to
retrieve"* and presents it as *"how many there are."* Nothing in the answer marks
the difference.

**The cost gap is the concrete result.** Nineteen times on question 5, sixty-nine
times on question 6, in both cases for an answer that was no better and once
worse. Vector retrieval pays for the volume of text it must read; the graph pays
once, at ingest, for structure.

**Question 4 is the honest counterweight.** Asked what two agents have in common,
arm N read both manifests and produced a correct, detailed comparison from a
single search. At this corpus size the language model can hold what it retrieves
and do the graph's work itself. That holds while the text fits — and the token
figures above are what "fits" costs.

**The store selection rule worked.** Arm G used `read-cypher` alone on the four
relationship questions and reached for `vector_find` only where document content
was actually needed. That was registered beforehand as the open question about
the shipped design, since the choice rests entirely on an instruction in the
system prompt. It held on six of six.

**Two of the six are not clean.** Questions 3 and 6 ask what is *not* referenced,
and the graph holds four objects the collection does not. Arm G's wins there are
partly corpus drift rather than capability. Its answers were nevertheless correct
against the live cluster, which arm N's were not.

### What this says about abox

The shipped `retrieval-agent` has both stores, and this is the evidence that the
pairing is doing real work rather than adding a component. The two lab arms in
`evaluation.md` deliberately had no graph, which made them a fair test of
embeddings and an unfair picture of the shipped design — arm N's showing here is
what the embedding comparison looked like with one hand tied.

It also says the graph is not optional for a certain class of question. "How
many", "which are unused", "what breaks if" are not hard vector queries; they are
the wrong shape for vector search entirely, and the failure is silent.

## What this cannot show

The same limits as the first experiment, plus one.

Fourteen objects and six questions. The standing benchmark rule in ADR-0001 asks
for three orders of magnitude more, and that rule applies here too.

The added limit: **the graph was built by the same language model being tested.**
If arm G answers a relationship question correctly, that shows the graph it built
matches what it understood at ingest time — not that the graph is correct.
Verifying that needs the Cypher output checked against `kubectl`, which the
ingest checks above do only in aggregate.
