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

## What the control question caught

Question 1 is a control: both arms use words that appear verbatim in the
manifest, so both should hit, and a miss means a broken setup rather than a weak
model. On the first run **arm N missed it and arm M hit it** — the opposite of
what ADR-0001 predicts, and the reason the protocol says to stop there.

The cause was not the embedding model. `qdrant-mcp` declares an `outputSchema`
with a required `body` on every tool but populated only `Content`, leaving
`structuredContent` at the zero value of its result struct — `{"body":""}`.
kagent honours the declared schema, so it read an empty string. The server's own
log shows what it actually returned for the query `neo4j`:

```
"content":[{"type":"text","text":"[{... \"name\":\"neo4j-mcp\" ..., \"score\":0.61983657}, ...]"}],
"structuredContent":{"body":""}
```

The search was correct. nomic ranked the right manifest first at 0.62. The
payload was right there in `Content`. The agent received the empty
`structuredContent`, and said, accurately from where it sat, that the collection
held nothing.

Nothing about this failed loudly. HTTP 200, a well-formed response, no error in
any log, and an agent whose answer read as a reasonable retrieval miss. This is
the same failure shape as the rope-scaling defect in ADR-0001: a configuration
that returns well-formed, useless results and reports success.

**The result it would have produced.** Without the control, the eleven remaining
questions would have run with arm N blind. all-MiniLM-L6-v2 would have won
nearly all of them, and the conclusion — written into ADR-0001 as a correction,
with a results table behind it — would have been that the rejected model
outperforms the chosen one. The evidence would have looked strong and been
worthless.

Fixed in `mcp/qdrant-mcp/internal/tools/embeddings.go` by populating both halves
of the result, rebuilt as `qdrant-mcp:lab4`, and run from
`lab4/qdrant-mcp-fixed.yaml` because the shipped MCPServer is Flux-managed.
After the fix arm N answers question 1 correctly.

The defect is in the shipped server, not in lab scaffolding: `vector_find` has
been returning nothing to every agent in the cluster for as long as the tool has
existed, and the shipped `retrieval-agent` has a graph to fall back on, which is
plausibly why nobody noticed.

## Recording results

| # | Kind | Arm N (nomic) | Arm M (MiniLM) | Note |
|---|---|---|---|---|
| 1 | exact | hit | hit | arm N missed before the structuredContent fix; both hit after |
| 2 | exact | hit | hit | both named `gemini-gemini-3-5-flash` and quoted metadata |
| 3 | exact | hit | hit | both named `abox-minilm` and quoted the env var |
| 4 | paraphrase | hit | hit | both named `neo4j-mcp` and also `retrieval-agent` as its consumer |
| 5 | paraphrase | hit | hit | N named both MCP servers; M named `qdrant-mcp` plus the agents using it |
| 6 | paraphrase | hit | hit | both named `helm-agent` and quoted its description |
| 7 | deep | hit | hit | both quoted the rule verbatim — but at unequal `k`, see below; re-run pending |
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

## The arms were not searching at the same depth

Found on question 7, the first question of the discriminating set, when both
arms hit and arm M quoted a rule from line ~70 of an ~80-line system prompt —
far past its 256-token window.

The explanation is not that MiniLM saw it. `qdrant-mcp-official` was configured
here with `QDRANT_SEARCH_LIMIT: "10"`, while `vector_find` defaults to
`limit = 5`. The collection holds fourteen documents.

| | candidates returned | share of a 14-document corpus |
|---|---|---|
| Arm M | 10 | 71% |
| Arm N | 5 points, and chunks share documents — often 3–4 distinct ones | ~25% |

At `k = 10` of 14, ranking barely has to work: the right document lands in the
result set almost regardless of how well it was embedded. And the truncation
only ever affected the *embedding* — Qdrant stores the full text in the payload,
so once a document is returned the language model reads all of it. That is how a
256-token model quoted line 70 exactly.

Recall at different `k` is not a property of a model. It was a mistake in the
setup, and it is mine: the limit was written into `qdrant-mcp-official.yaml`
without checking what the other server defaults to.

Sections A and B are unaffected — both arms hit everything, so no ranking
information was at stake. Question 7 has to be re-run at equal depth, along with
the rest of section C.

The fix is to lower the official server to `QDRANT_SEARCH_LIMIT: "5"` rather
than raise ours: it needs no prompt change, and a smaller `k` is the more
demanding test of ranking.

### A residual asymmetry, stated rather than fixed

Equal `k` still does not make the arms equivalent. Arm N's five slots are
*chunks*, and several chunks can belong to one document, so it may see fewer
distinct documents than arm M does at the same number. This favours arm M and is
not removed by matching the limit — it is inherent to comparing a chunking
pipeline with one that does not chunk.

### And the corpus is too small to settle anything

Fourteen documents against twelve questions. ADR-0001's own standing benchmark
rule asks for roughly 200 gold queries against roughly 10K distractors before a
retrieval path is trusted, and this is three orders of magnitude short of that
on both axes. Whatever comes out of these twelve questions is directional. It
can reveal a broken pipeline — it already has, twice — but it cannot overturn
ADR-0001 on its own, and the ADR entry should say so.

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
