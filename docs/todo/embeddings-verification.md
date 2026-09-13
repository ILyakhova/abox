# Verification: embeddings service

Copy-pasteable acceptance suite for the in-cluster embedding service. Run it after a fresh
deploy, after an image or model bump, and after any change to
[`releases/embeddings.yaml`](../../releases/embeddings.yaml).

Expected values are from the run on 2026-09-13 (KinD in a 2-core Codespace, `Q8_0`,
`--pooling mean`, `--rope-freq-scale 0.25`). Related decisions:
[ADR-0001](../adr/0001-text-embedding-model.md),
[ADR-0002](../adr/0002-embedding-runtime-in-cluster.md).

> Run these where the cluster is. In a Codespaces sandbox that is the Codespace, not your
> workstation.

## Setup

```bash
kubectl config current-context      # expect: kind-abox

GW=$(kubectl get svc -n agentgateway-system \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
echo "gateway: $GW"
```

An empty `$GW` means `cloud-provider-kind` is not running — the Gateway has no external IP
and checks 3 onward cannot work.

## 1. Rollout

```bash
kubectl -n embeddings rollout status deploy/embeddings --timeout=10m
```

Expect `deployment "embeddings" successfully rolled out`.

First run is slow: the initContainer pulls ~140 MiB of weights, then the llama.cpp image
pulls. Watch the download with
`kubectl -n embeddings logs -l app=embeddings -c fetch-model`.

If it sits in `Init:ImagePullBackOff`, check the pull error before changing anything:

```bash
kubectl -n embeddings describe pod -l app=embeddings | tail -25
```

`i/o timeout` on a DNS lookup means the node has no egress — the nested-Docker firewall
problem. Fix it with `make fix-egress`, then
`kubectl -n embeddings rollout restart deploy/embeddings`. This blackholes *every* registry,
so it is not a Docker Hub problem and switching images will not help.

## 2. Context is not silently capped

The check that catches the highest-cost silent failure: a capped context truncates
documents at index time and never raises an error.

```bash
kubectl -n embeddings logs deploy/embeddings | grep -iE "n_ctx_slot|capping"
```

Expect exactly one line, with **no** `capping` line alongside it:

```
srv load_model: initializing, n_slots = 4, n_ctx_slot = 8192, kv_unified = 'true'
```

`n_ctx_slot = 2730` means the pod is running `--rope-freq-scale 0.75`. See ADR-0001 — the
value on the model card caps the context at `2048 / 0.75`, not the advertised 8192.

## 3. Gateway route is accepted

```bash
kubectl get httproute -n embeddings embeddings \
  -o jsonpath='{.status.parents[0].conditions}' | jq .
```

Expect `Accepted=True` and `ResolvedRefs=True`.

`ResolvedRefs=False` points at the ReferenceGrant: the route lives in `embeddings` and its
`parentRef` crosses into `agentgateway-system`.

## 4. Callable through the gateway

Use the gateway, not a port-forward. A port-forward bypasses agentgateway and proves
nothing about routing.

```bash
curl -s "http://$GW/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"nomic","input":["search_query: hello"]}' | jq '.data[0].embedding | length'
```

Expect `768`.

## 5. kagent's catch-all route still works

`/v1/embeddings` and kagent's `/` share one Gateway and are resolved by longest-prefix
precedence. This confirms the new route did not shadow the old one.

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://$GW/"
```

Expect `200`.

## 6. The vectors are meaningful

768 numbers prove the server answered, not that it embedded correctly. Wrong pooling
returns well-formed, useless vectors that pass every check above.

```bash
curl -s "http://$GW/v1/embeddings" -H 'Content-Type: application/json' -d '{"model":"m","input":[
 "search_query: What is the capital of France?",
 "search_document: Paris is the capital and most populous city of France.",
 "search_document: The mitochondrion is the powerhouse of the cell."]}' > /tmp/e.json

python3 -c "
import json,math
v=[d['embedding'] for d in sorted(json.load(open('/tmp/e.json'))['data'],key=lambda x:x['index'])]
dot=lambda a,b:sum(p*q for p,q in zip(a,b))
c=lambda a,b:dot(a,b)/(math.sqrt(dot(a,a))*math.sqrt(dot(b,b)))
print('related  ',round(c(v[0],v[1]),4)); print('unrelated',round(c(v[0],v[2]),4))
"
```

Expect:

```
related   0.8209
unrelated 0.4379
```

These must match the local run — same model, same flags, same numbers. A drift means the
pod is not running the configuration you think it is. Scores sitting close together, or
both near 0.99, point at `--pooling` first.

## 7. Batching

```bash
curl -s "http://$GW/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"m","input":["search_document: one","search_document: two"]}' | jq '.data | length'
```

Expect `2`.

## Recorded results — 2026-09-13

| Check | Result |
|---|---|
| Rollout | successfully rolled out |
| `n_ctx_slot` | 8192, no capping |
| HTTPRoute | `Accepted=True`, `ResolvedRefs=True` |
| Gateway IP | `172.18.0.5` |
| `/v1/embeddings` dimensions | 768 |
| kagent `/` | 200 |
| Semantic margin | 0.8209 / 0.4379 |

## Not verified here

- **Nothing is indexed yet.** Qdrant holds no collections and Phoenix has no traces, so
  both UIs are empty by design. They become meaningful after an ingestion run — see Part B
  of the [cluster runbook](./embeddings-cluster-sidecar-llmd.md#part-b--sidecar-for-ingestion--eval-jobs).
- **The llama.cpp web UI is inert.** `--embeddings` disables generation, so the chat page
  the server serves on `:8080` will not answer. That is expected, not a fault.
- **Retrieval quality on a real corpus.** Check 6 is one sentence pair — it detects a
  broken configuration, nothing more. ADR-0001 requires a gold-standard benchmark on the
  target corpus before any of this reaches users.
