# LAB4 — evaluating agentic retrieval across two embedding models

Same questions, same corpus, two agents. The only intended difference is how
text becomes a vector.

| Arm | Agent | MCP server | Model | Dims | Context |
|---|---|---|---|---|---|
| **N** | `retrieval-agent` | `qdrant-mcp` | nomic-embed-text-v1.5 | 768 | 2048 |
| **M** | `retrieval-agent-official` | `qdrant-mcp-official` | all-MiniLM-L6-v2 | 384 | **256** |

## Corpus

kagent's own custom resources in namespace `kagent`: every `Agent`,
`ModelConfig` and `MCPServer`. Roughly a dozen objects, varying from a few
lines to well over a hundred.

That spread is the point. `retrieval-agent`'s manifest carries an ~80-line
system prompt; `neo4j-mcp`'s is under 30 lines. If the 256-token window
matters, it will show up on the long ones and not the short ones.

## Ingest — run this verbatim in both agents

Do **not** rely on each agent's own prompt to decide what to store. The two
prompts differ (one says "prose", the other says "the whole manifest"), and
left alone they would store different text — which would make this a
comparison of prompts, not of models.

Paste the same instruction into both chats:

> Ingest these objects from namespace kagent, storing the full YAML of each,
> one call per object: all Agents, all ModelConfigs, all MCPServers. Put name,
> namespace and kind in the metadata. Do not summarise.

Then confirm both collections actually received comparable content:

```bash
for c in abox-nomic abox-minilm; do
  printf '%-14s ' "$c"
  kubectl -n qdrant exec deploy/qdrant -- \
    curl -s "http://localhost:6333/collections/$c" \
    | grep -o '"points_count":[0-9]*'
done
```

**If the counts differ by more than one or two, stop and re-ingest.** A
comparison across different corpora measures nothing.

## Questions

Four kinds, deliberately. Ask each in a fresh chat in both agents.

### A. Exact term — the question uses words that appear in the manifest

Both arms should get these. They establish that ingest worked at all; a miss
here means something is broken, not that a model is weak.

1. Which MCP server connects to `bolt://neo4j.neo4j:7687`?
2. Which ModelConfig uses the Gemini provider?
3. What collection does the official Qdrant MCP server write to?

### B. Paraphrase — same meaning, different words

This is what embeddings are actually for. Keyword search would fail all three.

4. Which component talks to the graph database?
5. What is set up to store and search vectors?
6. Which agent answers questions about Helm?

### C. Deep in a long manifest — past the 256-token window

The discriminating set. These answers sit far inside `retrieval-agent`'s and
`qdrant-mcp-official`'s manifests. ADR-0001 predicts arm M truncates and
therefore cannot see them.

7. Which agent is instructed never to create a relationship from a node to itself?
8. Which agent must call `get-schema` before reporting that something is missing?
9. Which MCP server is given a 2Gi memory limit, and what reason is recorded for it?
10. Which agent is told that storing is not idempotent?

### D. Negative control — not in the corpus

Tests honesty, not retrieval. The correct answer is "it is not in the
collection". Anything confidently invented is a failure regardless of how
plausible it sounds.

11. Which agent uses Anthropic Claude?
12. What is the Postgres password for kagent?

## Recording results

| # | Kind | Arm N (nomic) | Arm M (MiniLM) | Note |
|---|---|---|---|---|
| 1 | exact | | | |
| 2 | exact | | | |
| 3 | exact | | | |
| 4 | paraphrase | | | |
| 5 | paraphrase | | | |
| 6 | paraphrase | | | |
| 7 | deep | | | |
| 8 | deep | | | |
| 9 | deep | | | |
| 10 | deep | | | |
| 11 | negative | | | |
| 12 | negative | | | |

Mark each cell:

- **hit** — named the right object
- **partial** — right object among several, or right answer without naming the source
- **miss** — wrong object, or said it could not find it when it is there
- **invented** — produced an answer with no support in the collection (only meaningful for D)

A **miss** in section C is the expected result for arm M and is not a defect in
the model; it is the 256-token window doing what it does. A **miss** in section
A is a broken setup.

## What a result would mean

**If M loses on C and ties on A and B** — ADR-0001's reasoning holds: the
context window, not the MTEB score, is what disqualifies all-MiniLM-L6-v2 for
document-sized chunks.

**If M loses everywhere** — the gap is larger than context alone and the
384-dim space is genuinely weaker on this corpus.

**If M holds its own throughout** — ADR-0001 was too confident, and the entry
rejecting all-MiniLM must be corrected the way the llm-d claims in ADR-0002
were. Chunk size, not model size, would then be the thing that matters, and a
lighter model becomes defensible for short chunks.

**If both lose on D** — the finding is about neither model. It says the prompt
does not hold the agent to its sources, which is a bigger problem than either
embedder.

## Cost side, recorded separately

Retrieval quality is not the only axis, and the two servers differ
architecturally: one loads the model into its own process, the other calls an
HTTP service.

| | `qdrant-mcp` | `qdrant-mcp-official` |
|---|---|---|
| Where embedding happens | out-of-process, `llama-cpp-embeddings` | in-process, fastembed |
| Memory limit that works | 256Mi | 2Gi (upstream records 256Mi being OOMKilled) |
| **Measured memory** | **53 MiB** | **510 MiB** |
| First call | | 7914 ms |
| Subsequent calls | | 3 ms |
| Extra dependency | an embeddings service | none |

Nearly ten times apart, and the 510 MiB explains the OOMKill upstream recorded:
it is double the 256Mi limit that holds the other server comfortably.

The comparison is not finished at that line, though, and reading it as "the
official server costs 10× the memory" would be wrong. `qdrant-mcp` is small
because it does not embed — it calls `llama-cpp-embeddings`, which has a
footprint of its own that this column does not show:

| | in-process | out-of-process |
|---|---|---|
| `qdrant-mcp-official` | 510 MiB | — |
| `qdrant-mcp` | 53 MiB | + `llama-cpp-embeddings` (measure separately) |

The real difference is not the total, it is **whether the cost amortises**. The
in-process model is carried by every instance: a second MCP server, a third,
an ingestion job, each pays its own 510 MiB. The out-of-process model is paid
once and shared by every consumer — which is also what makes it a dependency
that can be down, be a version behind, or be pointed at the wrong endpoint.

At one consumer the in-process design is simpler and probably cheaper. The
crossover comes with the second.

The first-call cost is the model being pulled from HuggingFace and loaded into
ONNX. It is paid once per pod start, which makes it a restart cost rather than
a per-query one — worth stating plainly so it is not mistaken for query
latency. It does mean that after any restart the first user waits eight
seconds, and on a cluster where pods move, that is not rare.
