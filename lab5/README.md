# LAB5 — an agent-memory corpus built by hand

Everything here is applied by hand. This cluster reconciles the upstream OCI
artifact, so nothing in `lab5/` ships, and the names are distinct from
`releases/xray-memory.yaml` so the two cannot collide when a `v*` tag is finally
cut from `feat/xray-memory`.

Decision and findings: [ADR-0004](../docs/adr/0004-agent-memory.md).
Protocol and results: [evaluation.md](./evaluation.md).

## Why the corpus is ours rather than the shipped one

The maps image carries `xray.graph.gob.gz` and `harness.graph.gob.gz`, and both
are age-encrypted to a recipient whose private identity this repository does not
have. An encrypted map found with no key is skipped at load, so serving them
would have meant serving nothing.

The published server image also cannot build a code graph — it has no
Tree-sitter parser (`rebuild with CGO_ENABLED=1`), which rules out live source
parsing. What it can do is `servicemap`, which builds a catalog map from JSON
with no parsing at all. That is the path these scripts take, and it is the same
one the shipped `harness` map was built with.

## Order of operations

```bash
# 1. an age identity of our own, and a Secret in the cluster
bash lab5/keygen.sh

# 2. the corpus, from the live cluster's kagent objects
bash lab5/build-corpus.sh

# 3. embed it, encrypt it, pack it as a seed image, load it into KinD
bash lab5/make-map.sh

# 4. serve it
kubectl apply -f lab5/xray-memory-abox.yaml

# 5. a ModelConfig with a real key, then the agent
kubectl -n kagent create secret generic gemini-gemini-3-5-flash \
  --from-literal=GEMINI_API_KEY=<your key>
kubectl apply -f lab5/modelconfig-gemini.yaml -f lab5/memory-agent.yaml
```

Steps 2 and 3 are re-runnable; step 4 is not, and that is the problem below.

## Things that cost time, recorded so they cost it once

**`servicemap` reads more than its `-help` documents.** The help says
`{name, calls, called_by}`. It also reads `kind`, `text` and `attrs` — the node's
type, the text that actually gets embedded, and attributes that `search_graph`
can select with `attr=` and sort with `order=`. Without them every node is a
bare `Service` with nothing for a query to match.

**The same image is not the same embedder.** The chart's sidecar runs
`--ctx-size 16384 --ubatch-size 2048 --parallel 8`; the image's own `CMD` leaves
`--ubatch-size` at 512, which rejects a ~1400-token node outright with a 500.
The flags are part of the fingerprint and the snapshot header does not record
them.

**Model name is checked loosely.** `servicemap` labels the model `nomic` by
default, the chart's server calls it `nomic-embed-text`, and the server loads the
map anyway on the strength of matching dimensions — logging "assuming same
model". True here; it would look identical for a different 256-dim model whose
vectors do not line up. `make-map.sh` spells the label out.

**`keygen` must run as your own uid.** It writes mode 0600, so a key created by
the image's uid 65532 cannot afterwards be read, moved or chmod'ed by the person
whose key it is.

**Updating the corpus destroys the notes.** `seed` will not overwrite a file the
volume already holds, so replacing a map means deleting the claim — and
`session.graph.gob.gz` is on that claim. Copy it off and back if the notes
matter. ADR-0004 treats this as work to do, not a footnote.

**Encryption is not access control.** The corpus was encrypted throughout and
the agent still read a credential out of it on request. Redaction happens in
`build-corpus.sh`, on the way in, by key name — after the fact there is no way
back.
