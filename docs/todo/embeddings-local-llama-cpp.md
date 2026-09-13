# ToDo: run nomic-embed-text-v1.5 locally with llama.cpp

Agent-executable runbook. Implements [ADR-0001](../adr/0001-text-embedding-model.md).

**Goal:** a locally running, callable embedding endpoint at `http://localhost:8088`
speaking the OpenAI `/v1/embeddings` wire format, returning 768-dim vectors that pass a
semantic sanity check.

**Definition of done:** every box in [§7](#7-definition-of-done) is ticked. Do not report
success on "the container started" — §5 is the acceptance test.

---

## 1. Prerequisites

- [ ] Docker running (`docker info`). This is the recommended path — it matches what the
      cluster will run, so a working local command translates directly to ADR-0002.
- [ ] `curl` and `jq` available.
- [ ] ~500 MiB free disk for the model cache.
- [ ] Port `8088` free (`8080` is deliberately avoided — kagent's UI uses it).

No GPU required. This model runs on CPU.

---

## 2. Option A — Docker (recommended)

```bash
mkdir -p "$HOME/.cache/llama.cpp"

docker run -d --name abox-embeddings \
  -p 8088:8080 \
  -v "$HOME/.cache/llama.cpp:/root/.cache/llama.cpp" \
  ghcr.io/ggml-org/llama.cpp:server \
    -hf nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0 \
    --embeddings \
    --pooling mean \
    -c 8192 -b 8192 -ub 8192 \
    --rope-scaling yarn --rope-freq-scale 0.25 \
    --host 0.0.0.0 --port 8080
```

Flag-by-flag, because each one is load-bearing:

| Flag | Why |
|---|---|
| `-hf <repo>:Q8_0` | Pulls the GGUF from HuggingFace and caches it. `Q8_0` per ADR-0001 — do not drop to Q4 for retrieval. |
| `--embeddings` | Puts the server in embedding-only mode. Without it `/v1/embeddings` is not served. |
| `--pooling mean` | `nomic-embed-text-v1.5` is a BERT-style encoder trained with mean pooling. `last` is for decoder-based embedders (e.g. `nomic-embed-code`) and produces silently wrong vectors here. |
| `-c 8192` | Full context. `-b`/`-ub` are raised to match so a single 8k input is not split across batches. |
| `--rope-scaling yarn --rope-freq-scale 0.25` | Unlocks the 8192 context. **Not the value on the model card** — see the note below. |
| `--host 0.0.0.0` | Required to reach the server from outside the container. |

> **Why `0.25` and not the `0.75` the model card prints.** The GGUF advertises
> `n_ctx_train = 2048`, and llama.cpp caps a slot's usable context at
> `n_ctx_train / rope_freq_scale`. With the card's `0.75` that is `2048 / 0.75 = 2730`, and
> the server silently caps you there — you ask for 8192, you get 2730:
>
> ```
> srv load_model: the slot context (8192) exceeds the training context of the model (2730) - capping
> ```
>
> `0.25` gives `2048 / 0.25 = 8192`, which is the number the model card advertises
> everywhere else. Verified on this image: inputs of 3520 and 5934 tokens embed cleanly at
> `0.25` and would have been truncated at `0.75`, and the semantic margin in §5 does not
> degrade (0.3829 at `0.25` against 0.3596 at `0.75`).
>
> `--parallel` is deliberately **not** set. The server defaults to 4 slots with
> `kv_unified = true`, and each slot gets the full 8192 — the context is not divided.
> Forcing `--parallel 1` only costs concurrency.

- [ ] Container is running: `docker ps --filter name=abox-embeddings`
- [ ] Weights downloaded and model loaded (first start takes a minute or two):
      `docker logs -f abox-embeddings` until it prints that the server is listening.

## 2b. Option B — native binary

Only if Docker is unavailable. Note the cluster path in ADR-0002 uses the container image,
so prefer Option A.

```bash
brew install llama.cpp          # macOS
# or build: cmake -B build && cmake --build build --config Release -j

llama-server -hf nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0 \
  --embeddings --pooling mean \
  -c 8192 -b 8192 -ub 8192 \
  --rope-scaling yarn --rope-freq-scale 0.25 \
  --host 127.0.0.1 --port 8088
```

## 2c. Option C — Ollama (fallback)

Acceptable if llama.cpp cannot be used. Ollama also exposes an OpenAI-compatible
`/v1/embeddings`, so the rest of this runbook applies with the base URL changed.

```bash
ollama pull nomic-embed-text        # this is nomic-embed-text-v1.5
ollama serve                        # serves on :11434

curl -s http://localhost:11434/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text","input":["search_query: What is TSNE?"]}' \
  | jq '.data[0].embedding | length'
```

Caveats to carry forward:

- Ollama does **not** add task prefixes for you either — §4 still applies in full.
- Ollama picks its own quantization and context defaults; they are not the ADR-0001
  operating point and are harder to pin. This is why it is the fallback and not the
  recommendation.

---

## 3. Verify the endpoint is callable

- [ ] Health returns `ok` (it returns HTTP 503 while the model is still loading):

```bash
curl -s http://localhost:8088/health | jq .
# {"status":"ok"}
```

- [ ] The OpenAI-shaped endpoint answers with a 768-dim vector:

```bash
curl -s http://localhost:8088/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text-v1.5","input":["search_query: What is TSNE?"]}' \
  | jq '.data[0].embedding | length'
# 768
```

- [ ] Batching works (send several inputs, get several vectors back):

```bash
curl -s http://localhost:8088/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text-v1.5",
       "input":["search_document: first","search_document: second"]}' \
  | jq '.data | length'
# 2
```

---

## 4. The task-prefix contract (do not skip)

`nomic-embed-text-v1.5` requires an instruction prefix on **every** input. A wrong or
missing prefix does not raise an error — it quietly costs recall.

| Prefix | Use for |
|---|---|
| `search_document: ` | Text being indexed into the vector store |
| `search_query: ` | A user's question at query time |
| `clustering: ` | Grouping semantically similar texts |
| `classification: ` | Features for a classifier |

- [ ] Prefixing is implemented **inside** the ingestion/query helper, not left to callers.

```python
def embed(texts: list[str], *, task: str = "search_document") -> list[list[float]]:
    payload = {"model": "nomic-embed-text-v1.5",
               "input": [f"{task}: {t}" for t in texts]}
    r = requests.post("http://localhost:8088/v1/embeddings", json=payload, timeout=60)
    r.raise_for_status()
    return [d["embedding"] for d in r.json()["data"]]
```

---

## 5. Acceptance test — the vectors must be *meaningful*

A 768-length array proves the server responded, not that it embedded correctly. Wrong
pooling produces well-formed, useless vectors. This test catches that.

- [ ] Run it; the related pair must score materially higher than the unrelated pair.

```python
import numpy as np, requests

URL = "http://localhost:8088/v1/embeddings"

def embed(texts):
    r = requests.post(URL, json={"model": "nomic-embed-text-v1.5", "input": texts}, timeout=60)
    r.raise_for_status()
    return np.array([d["embedding"] for d in r.json()["data"]], dtype=np.float32)

def cos(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))

q, rel, unrel = embed([
    "search_query: What is the capital of France?",
    "search_document: Paris is the capital and most populous city of France.",
    "search_document: The mitochondrion is the powerhouse of the cell.",
])

print(f"related:   {cos(q, rel):.4f}")
print(f"unrelated: {cos(q, unrel):.4f}")
assert cos(q, rel) > cos(q, unrel) + 0.15, "pooling or prefixes are wrong"
print("OK")
```

Measured on the exact command in §2 (`Q8_0`, `--pooling mean`, `--rope-freq-scale 0.25`):

```
related   (Paris/France):   0.8209
unrelated (mitochondrion):  0.4379
margin:                     0.3829
```

If the two scores sit close together, or both land near 0.99, re-check `--pooling mean`
first — `last` pooling on this encoder returns well-formed vectors that do not separate.

The server already returns unit-length vectors (`--embd-normalize` defaults to Euclidean),
so a measured norm of `1.000000` is expected and the cosine denominator is a formality.

---

## 6. Matryoshka truncation and the Qdrant layout

Only needed when wiring retrieval; the endpoint is already usable without it.

`llama-server` always returns 768 dims. Truncation is client-side, and **re-normalization
is mandatory** — slicing a unit vector leaves it non-unit, which breaks cosine distance.

```python
def truncate(v, dim=256):
    v = np.asarray(v[:dim], dtype=np.float32)
    return v / np.linalg.norm(v)
```

On the §5 pair, truncating to 256 dims held the ranking and did not narrow the gap —
related 0.8330, unrelated 0.4293, margin 0.4036 against 0.3829 at full width. That is one
sentence pair, not evidence about your corpus; it only shows the mechanism works.

For two-stage adaptive retrieval, store both widths as named vectors in one Qdrant
collection — shortlist on the indexed 256-dim vector, rescore candidates on the stored
768-dim one. `m: 0` stores `full` without building an HNSW graph for it:

```bash
curl -X PUT http://localhost:6333/collections/abox_docs \
  -H 'Content-Type: application/json' -d '{
    "vectors": {
      "small": {"size": 256, "distance": "Cosine"},
      "full":  {"size": 768, "distance": "Cosine", "hnsw_config": {"m": 0}}
    }
  }'
```

- [ ] Truncated vectors are re-normalized.
- [ ] The dimension actually used was validated on the target corpus — ADR-0001 records a
      case where 3072 dims scored *worse* than 2048. Do not assume 256 is right for your data.

---

## 7. Definition of done

- [ ] `/health` returns `{"status":"ok"}`
- [ ] `/v1/embeddings` returns a 768-element vector for a single input
- [ ] Batch input returns one vector per input
- [ ] The §5 acceptance test prints `OK`
- [ ] Task prefixes are applied in code, not by callers
- [ ] The exact `docker run` command used is recorded in the project so it is reproducible
- [ ] If truncation is in use: vectors are re-normalized after slicing

## Teardown

```bash
docker rm -f abox-embeddings
```

## Next

Deploy the same model into the cluster:
[ToDo: cluster runtime](./embeddings-cluster-sidecar-llmd.md).
