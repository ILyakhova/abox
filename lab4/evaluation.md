# LAB4 — evaluating agentic retrieval across two embedding models

Same questions, same corpus, two agents. The only intended difference is how
text becomes a vector.

| Arm | Agent | MCP server | Model | Dims | Context |
|---|---|---|---|---|---|
| **N** | `retrieval-agent-nomic` | `qdrant-mcp` | nomic-embed-text-v1.5 | 768 | 2048 |
| **M** | `retrieval-agent-official` | `qdrant-mcp-official` | all-MiniLM-L6-v2 | 384 | **256** |

Both agents run on the same ModelConfig, `gemini-gemini-3-5-flash`, and carry
the same system prompt word for word — only the tool names differ, because the
two MCP servers name their tools differently.

### Why arm N is not the shipped `retrieval-agent`

The first attempt used it, and it returned `401 Unauthorized` from
`api.openai.com`: the agent is pinned to `default-model-config`, the ModelConfig
the kagent chart creates, which carries a placeholder API key. The kagent UI
showed "Gemini (gemini-3-5-flash)" in the header while the request went to
OpenAI, so the header is not evidence of anything — the error is.

The failure was useful. Had the shipped agent held a working OpenAI key, it
would have answered, and the experiment would have compared **GPT against
Gemini** while reporting the result as nomic against MiniLM. Nothing in the
results table would have exposed that. The 401 is what forced the language
model to become a controlled variable instead of an unexamined one.

### What this does not measure

Vectors only. Neither arm has the Neo4j tools the shipped `retrieval-agent`
carries, and that is deliberate.

A graph would answer several of the questions below for reasons that have
nothing to do with embeddings. Give arm N a graph and it wins section C — but
we would not know whether that came from the 2048-token window or simply from
having a second store that does no semantic search at all. The variable under
test has to be the embedder, so the graph comes out of both arms.

The consequence is worth stating plainly, because it limits what the result can
claim: this measures **vector retrieval quality when the embedding model
changes**, not the quality of hybrid retrieval in abox. The shipped agent
queries both stores and will behave better than arm N in normal use. Whether
the graph earns its keep is a separate question, and this lab does not answer
it.

## Corpus

kagent's own custom resources in namespace `kagent`: every `Agent`,
`ModelConfig` and `MCPServer`. Roughly a dozen objects, varying from a few
lines to well over a hundred.

That spread is the point. `retrieval-agent`'s manifest carries an ~80-line
system prompt; `neo4j-mcp`'s is under 30 lines. If the 256-token window
matters, it will show up on the long ones and not the short ones.

## Ingest — run this verbatim in both agents

The two agents now carry the same prompt, so this is belt and braces rather
than a correction — but state the task explicitly anyway, so the transcript
records that both arms were given identical instructions and neither was left
to infer the corpus for itself.

Paste the same instruction into both chats:

> Ingest these objects from namespace kagent, storing the full YAML of each,
> one call per object: all Agents, all ModelConfigs, all MCPServers. Put name,
> namespace and kind in the metadata. Do not summarise.

Qdrant is a StatefulSet, and its image has no `curl`, so reach it by
port-forward and use the client's own:

```bash
kubectl -n qdrant port-forward svc/qdrant 6333:6333 >/dev/null 2>&1 &
sleep 3
count() {
  for c in abox-nomic abox-minilm; do
    printf '%-14s ' "$c"
    curl -s "http://localhost:6333/collections/$c" \
      | grep -o '"points_count":[0-9]*' || echo "not found"
  done
}
```

### Empty both collections first

Run `count` **before** ingesting. Neither server's store operation is
idempotent — it appends, it does not replace — so ingesting over existing
points leaves the old corpus mixed with the new one.

On the first run this mattered: the collections held 20 and 14 points from
earlier sessions. Ingesting on top would have produced 20+N against 14+N, and
the evaluation would have compared two different corpora while reporting it as
a comparison of two models.

```bash
for c in abox-nomic abox-minilm; do
  curl -s -X DELETE "http://localhost:6333/collections/$c"; echo " <- $c"
done
```

Delete both even when only one is dirty, so the two arms start from the same
state. The servers recreate them on first write.

Then ingest, then run `count` again.

### Points are not documents — the servers chunk differently

The first run came back 21 against 14 and looked like a broken ingest. It was
not. `qdrant-mcp` **splits a document into chunks and stores one point per
chunk**; its payload carries `chunk`, `chunks` and a shared `doc` id. The
official server does not chunk at all — one `qdrant-store` call is one point.

So `points_count` is not comparable between the arms. Count distinct documents
on the nomic side instead:

```bash
curl -s -X POST "http://localhost:6333/collections/abox-nomic/points/scroll" \
  -H 'Content-Type: application/json' \
  -d '{"limit":100,"with_payload":["doc"],"with_vector":false}' \
  | grep -o '"doc":"[^"]*"' | sort -u | wc -l
```

and confirm the two collections hold the same objects by name:

```bash
for c in abox-nomic abox-minilm; do
  echo "== $c"
  curl -s -X POST "http://localhost:6333/collections/$c/points/scroll" \
    -H 'Content-Type: application/json' \
    -d '{"limit":100,"with_payload":true,"with_vector":false}' \
    | grep -o '"name":"[^"]*"' | sort -u
done
```

On this run both returned the same 14 names. **If the name lists differ, stop
and re-ingest.** A comparison across different corpora measures nothing.

### What chunking does to the prediction

This has to be recorded before the results, not after, because it changes what
a section C failure would mean.

ADR-0001 rejected all-MiniLM-L6-v2 on its 256-token context. The implicit
assumption was that a long manifest is embedded as one vector and everything
past the window is lost. That assumption holds for arm M — the official server
hands the whole document to fastembed in one piece.

It does not hold for arm N. `qdrant-mcp` chunks first, so no single embedding
call ever sees more than a chunk, and the 2048-token context is not what saves
it. **Chunking is.**

The consequence is that these two arms differ in two ways, not one: the
embedding model *and* whether the ingest path chunks. A section C loss for arm
M therefore cannot be attributed to the model alone. The honest reading would
be that the packaged pipeline built around nomic handles long documents and the
packaged pipeline built around MiniLM does not — which is a real, useful finding
about the two servers, but a weaker claim than "nomic is the better embedder".

Separating the two would need a third arm: the official server with a chunking
ingest, or `qdrant-mcp` pointed at a 256-token model. That is out of scope here
and is named as further work rather than quietly ignored.

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
