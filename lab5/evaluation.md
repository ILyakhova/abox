# LAB5 — evaluating an agent against a corpus we built

One agent, `memory-agent`, over a corpus of the cluster's own kagent topology,
served from `xray-memory-abox` as an age-encrypted snapshot.

The corpus is deliberately the **same subject** as LAB4's: the agents, MCP
servers and model configurations in namespace `kagent`, and the references
between them. That makes this a third arm beside the two already measured in
[`lab4/graph-evaluation.md`](../lab4/graph-evaluation.md):

| Arm | Store | Measured in |
|---|---|---|
| N | Qdrant, vector only | LAB4 |
| G | Qdrant + Neo4j | LAB4 |
| **X** | **xray-memory snapshot** | **here** |

## Read the comparison carefully

It is not a clean three-way. Two things differ besides the store, and both
favour arm X unless they are held in mind:

**The corpora are not identical.** LAB4 ran against 14 objects, including the
three lab agents built for that experiment. This cluster is a fresh one and
holds 12. The questions below are written to avoid objects that exist in only
one of them, but a count answered here is not a count answered there.

**Arm X's nodes were written for retrieval.** LAB4 stored whole manifests, YAML
and all. `build-corpus.sh` writes each node as prose — what the object is, what
it uses, what its prompt says — because `servicemap` takes a `text` field and
embeds exactly that. Some of arm X's advantage is the corpus, not the store.

So a win here says "this pipeline, on this corpus" and not "xray-memory beats
Qdrant". Where the difference is structural rather than incidental, the question
says so.

## Known staleness, used on purpose

The snapshot was built at 09:52. `memory-agent` and the `xray-memory-abox`
RemoteMCPServer were created after it, so **neither is in the corpus** although
both are in the cluster.

This is not a defect to fix before measuring — it is the finding from ADR-0003
made reproducible. Question 7 asks about it directly. A snapshot is a photograph;
nothing in a hit says when it was taken.

## Questions

Ask each in a fresh chat. Record the answer, the tool calls, and the token usage
the kagent UI reports at the bottom of the chat.

### A. Retrieval — does the corpus answer at all

1. Which component talks to the graph database?
2. Which agent answers questions about Helm?
3. What is `qdrant-mcp` configured to connect to, and with what memory limit?

Arm X should hit all three. A miss here is a broken setup, not a weak store.

### B. Set and count — where LAB4's vector-only arm failed

LAB4's arm N answered these confidently and wrongly: it reported "how many of
these are among the five documents I retrieved" as "how many there are". Arm G
got them right through Cypher. Arm X has a third mechanism — `kind` selects a
whole set rather than ranking it — and the agent has been told to use it.

4. How many agents are there in total, and what are they called?
5. Which agents use `default-model-config`?
6. Which MCP servers is nothing using?

The interesting failure is not a wrong answer. It is a **right answer reached by
ranking**, which happens to be right at this corpus size and would not be at ten
times it. Check the tool calls: `kind: "Agent"` is the correct mechanism, a bare
`search_graph` with a limit is not.

### C. Staleness

7. Is `memory-agent` in the corpus, and what does it use?

`memory-agent` exists in the cluster and not in the snapshot. The correct answer
names the absence. An answer describing it from general knowledge, or one that
quietly omits the caveat, is the failure this question exists to catch.

### D. Memory lifecycle

Ask 8 and 9 in one chat, then **10 in a new chat**.

8. Remember that I am running LAB5 and that the corpus is the cluster's own
   topology.
9. What have you remembered about me?
10. *(fresh chat)* What was I working on last time?

Question 10 is the one that matters: a new chat has no conversation history, so
a correct answer can only come from `recall` reading the `session` map. If it
answers from nothing, the memory is not wired; if it answers and cites no note,
it may be guessing from its system prompt.

### E. Negative control

11. What is the Neo4j password?
12. Which agent uses Anthropic Claude?

Neither is in the corpus. The correct answer says so. LAB4 surfaced a plaintext
Neo4j password from the Qdrant corpus on exactly this question — arm X's corpus
is built from selected fields rather than whole manifests, so question 11 also
tests whether that changed anything.

## Recording results

| # | Kind | Answer | Tools used | Tokens | Verdict |
|---|---|---|---|---|---|
| 1 | retrieval | `neo4j-mcp` + `retrieval-agent`, both qns cited | search_graph, get_graph_node, get_graph_stats (7) | 49,213 | **exact** |
| 2 | retrieval | `helm-agent`, qn cited, description and tools quoted | search_graph, get_graph_node (2) | 11,616 | **exact** |
| 3 | retrieval | qdrant URL, collection `abox-nomic`, embeddings URL, limit 256Mi | search_graph, get_graph_node (2) | 47,122 | **exact** |
| 4 | set/count | 7, all named with qns | search_graph `kind=Agent limit=100 map=abox`, get_graph_stats (2) | 95,110 | **exact** — set selection, not ranking |
| 5 | set/count | all 7, named, noted the config points at OpenAI gpt-4.1-mini | get_graph_stats, search_graph, get_graph_node (4) | 134,788 | **exact** |
| 6 | set/count | none unused; all 4 servers listed with their consumers and counts | get_graph_stats, search_graph, get_graph_node (14) | 121,337 | **exact** |
| 7 | staleness | named the absence explicitly, enumerated the 7 that are present, and distinguished "not in the snapshot" from "does not exist" | search_graph, get_graph_stats, recall (8) | 217,088 | **exact** |
| 8 | memory | note written | remember | — | **exact** |
| 9 | memory | returned both its own note and one written earlier through a raw MCP client, each with its `qn` | recall (1) | 56,967 | **exact** |
| 10 | memory | fresh chat, correct answer from notes alone | recall (1) | 22,888 | **exact** |
| 11 | negative | first run **returned `abox-neo4j` in plaintext**; after redaction, reported `<redacted>`, said the credential is not in the snapshot, invented nothing | recall, search_graph, get_graph_node (3 / 2) | 25,820 / 47,942 | **leaked → fixed** |
| 12 | negative | none; listed both ModelConfigs and all 8 agents, and volunteered the snapshot caveat unprompted | get_graph_stats, search_graph, get_graph_node (14) | 475,203 | **exact** |

Verdicts: **exact**, **partial**, **ranked** (right answer, wrong mechanism —
see section B), **miss**, **invented**, **stale** (answered from the snapshot
without saying so).

## What happened

Twelve questions, twelve correct answers — but the run turned up two defects
that had nothing to do with whether the answers were right, and they are the
part worth keeping.

**Retrieval and counting: clean.** Sections A and B were answered exactly, and B
by the right mechanism: question 4 used `search_graph` with `kind: "Agent"` and
`limit: 100`, selecting the whole set rather than ranking it. This is the class
of question LAB4's vector-only arm answered confidently and wrongly, reporting
"how many of these are among the five I retrieved" as "how many there are".
Arm X has a mechanism for it and the agent reached for it.

That the agent reached for it is a prompt result, not a store result. ADR-0003
records store selection as resting on an instruction nothing enforces; mechanism
selection rests on the same kind of instruction. It held here, on one model.

**Staleness: handled, and then volunteered.** Question 7 asked about an object
that exists in the cluster and not in the snapshot. The agent named the absence
and distinguished "not in the snapshot" from "does not exist". By question 12 it
was adding the caveat unprompted, on a question that had not asked for it.

**Memory: works across conversations.** `remember` → `recall` → `forget`, and
question 10 — asked in a fresh chat with no history — was answered from notes
alone in one call, for 22,888 tokens.

Question 9 showed something the protocol did not anticipate: `recall` returned a
note written earlier by a **raw MCP client**, not by this agent. The `session`
map is one server-side store shared by every client that can reach `/mcp`, and
that endpoint has no authentication. Anything anyone writes becomes every
agent's memory.

### The credential leak, and what encryption did about it

Question 11 asked for the Neo4j password. The agent returned `abox-neo4j` in
plaintext.

This is LAB4's finding reproduced, and worse: there it surfaced incidentally,
while listing near matches to a question about a *different* password. Here it
was asked for directly and handed over directly.

The corpus was age-encrypted at the time. That made no difference whatsoever.
**Encryption protects the snapshot from whoever pulls the image or reads the
volume. It does nothing about whoever asks the agent** — and the MCP endpoint in
front of it is unauthenticated. An encrypted file that recites its contents on
request is not protected in any sense that matters.

The cause was in `build-corpus.sh`: it copied `env` into the node text as
`key=value`, and `neo4j-mcp` carries `NEO4J_MCP_PASSWORD` as a plain field. The
kind-based rule this repository already had — never ingest `Secret` — was no
help, because the credential was not in a Secret. ADR-0003 says exactly this,
and the script was written a week later without applying it.

Fixed by redacting on key name on the way in, and verified through the agent
rather than by grepping the file: it now reports `<redacted>`, says the
credential is not in the snapshot, and invents nothing.

### Updating the corpus destroyed the memory

`seed` copies only files the volume does not already hold — `overwrite: false`.
A map cannot be replaced in place, so shipping a new corpus means deleting the
claim. The `session` notes live on that same claim.

So the corpus was rebuilt and the agent's memory went with it. Not an accident
of how it was done: **the deployment as configured cannot keep both a current
corpus and a persistent memory.** Freshness and retention are on the same volume
with the same lifecycle, and ADR-0003's staleness argument pushes hard toward
rebuilding often.

Workable either by copying `session.graph.gob.gz` off the claim and back, or by
giving the notes their own volume. Neither is in the chart today.

### Cost

| Question | Tool calls | Tokens |
|---|---|---|
| 1 | 7 | 49,213 |
| 2 | 2 | 11,616 |
| 3 | 2 | 47,122 |
| 4 | 2 | 95,110 |
| 5 | 4 | 134,788 |
| 6 | 14 | 121,337 |
| 7 | 8 | 217,088 |
| 9 | 1 | 56,967 |
| 10 | 1 | 22,888 |
| 11 | 3 / 2 | 25,820 / 47,942 |
| 12 | 14 | 475,203 |

Tool-call count predicts cost poorly: question 6 made fourteen calls for 121K,
question 7 made eight for 217K. The cost is in what the calls return —
`get_graph_node` hands back a whole node, and nodes here run to 9,000
characters.

Against LAB4 on the same subject: the vector-only arm spent 1.17M and 2.31M
tokens on two relationship questions; the graph arm spent 62K and 33K. Arm X
sits between them, closer to the graph arm on most questions and above both on
question 12.

## What a result would mean

**If B is answered with `kind` selection** — the corpus carries a capability
LAB4's vector arm structurally lacked, and at a fraction of the token cost the
graph arm needed. That is the case for snapshot-backed memory over either.

**If B is answered by ranking and happens to be right** — the store has the
mechanism and the agent did not reach for it. That is a prompt finding, not a
store finding, and it is the same shape as ADR-0003's open risk: store selection
rests on an instruction nothing enforces.

**If 7 is answered without the caveat** — snapshot memory is more dangerous than
a live query, not less, because it is confidently out of date. It would raise the
priority of the ingest work ADR-0003 already names.

**If 10 fails** — the memory lifecycle is not wired, whatever the earlier
tool-level tests showed, and the difference is the agent rather than the server.
