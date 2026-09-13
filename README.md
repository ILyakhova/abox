# abox

> One command. Full AI infrastructure.

`make run` gives you a local Kubernetes cluster with everything an AI project needs: an AI-aware API gateway, an agent runtime, observability, distributed tracing, and an eval harness — ready to use.

## What's included

| Component | Role |
|---|---|
| **agentgateway v2.2.1** | AI-aware API gateway (Gateway API–native, MCP-aware) |
| **kagent 0.10.1** | Kubernetes-native AI agent framework |
| **Qdrant 1.19.1** | Vector database for retrieval |
| **llm-d v0.3.17** | Distributed inference serving — vLLM + InferencePool/EPP, serving `nomic-embed-text-v1.5` |
| **llama.cpp** | Second, lightweight embeddings backend — same model as f16 GGUF |
| **Arize Phoenix 12.0.10** | LLM observability — tracing, evals, prompt playground |
| **Flux CD 2.x** | GitOps/GitLessOps operator — keeps the cluster in sync with OCI artifacts |
| **KinD** | Local Kubernetes (1 control-plane + 2 workers) - can be any k8s |
| **cloud-provider-kind** | LoadBalancer support so gateway gets a real IP for local development |

## Quickstart

```bash
make run
```

That's it. Installs OpenTofu and k9s, provisions the cluster, bootstraps Flux, and reconciles all components. When it finishes:

```bash
kubectl get gateway,httproute -A        # gateway is up
kubectl get agents -n kagent            # agent runtime is up
kubectl get svc -n agentgateway-system  # grab the LoadBalancer IP
```

Point your AI app at the gateway IP on port 80.

## How it works

```
make run  →  scripts/setup.sh
  → tofu apply (bootstrap/)
      → KinD cluster
      → Flux Operator + FluxInstance   via the upstream flux-operator-bootstrap module
      → ResourceSetInputProvider   polls oci://ghcr.io/den-vasyliev/abox/releases
      → ResourceSet                creates OCIRepository + 2 Kustomizations
          → releases/crds/    gateway-api-crds, agentgateway-crds, kagent-crds
          → releases/         agentgateway (Gateway + GatewayClass)
                              kagent (agent runtime + HTTPRoute)
```

Everything after the cluster is **gitless GitOps via OCI**: no Git polling, no deploy keys. CI publishes `releases/` as an OCI artifact on every version tag. The cluster reconciles from that artifact automatically.

## Releasing

```bash
make push   # bumps patch version, tags, pushes → CI publishes OCI artifact → cluster reconciles
```

> **Note:** RSIP tag sorting is lexicographic. If the patch version would exceed 9, bump the minor instead: `git tag vX.Y+1.0`.

## Directory layout

| Path | Purpose |
|---|---|
| `bootstrap/` | OpenTofu: KinD + Flux bootstrap (operator, instance, RSIP, ResourceSet) |
| `bootstrap/flux-instance.yaml` | `FluxInstance` applied by the bootstrap Job |
| `releases/crds/` | CRD HelmReleases: gateway-api, agentgateway, kagent, inference-extension |
| `releases/` | App HelmReleases + Gateway + HTTPRoutes |
| `images/nomic-embed/` | Dockerfile baking nomic-embed-text-v1.5 into llama.cpp server |
| `scripts/setup.sh` | Full setup script (`make run`) |
| `.github/workflows/flux-push.yaml` | CI: publish `releases/` as OCI artifact on `v*` tags |

## Embeddings: two backends

Two OpenAI-compatible `/v1/embeddings` endpoints serving the same model
(`nomic-ai/nomic-embed-text-v1.5`), so llm-d can be evaluated against a plain
single-process server.

| | backend | in-cluster | via gateway |
|---|---|---|---|
| #1 | llm-d — vLLM behind an InferencePool + endpoint picker | `llm-d-embedding.llm-d:8000` | `http://<gw-ip>/llmd/v1/embeddings` |
| #2 | llama.cpp — one `llama-server --embeddings` pod | `llama-cpp-embeddings.llama-cpp:8090` | `http://<gw-ip>/llamacpp/v1/embeddings` |

The llama.cpp backend runs a **prebuilt image with the model baked in**
(`images/nomic-embed/`), so nothing is pulled from HuggingFace at pod start.
```
ghcr.io/den-vasyliev/abox/nomic-embed:v1.18.1-4ccc0ff
```

It is already published and public, so nothing has to be built to run this.
Two properties of it are worth knowing:

- **amd64 only** — a single manifest, not an index. Fine on Codespaces and any
  x86 node; it will not run natively on an arm64 Mac.
- Its baked `CMD` is only `--host/--port/--embeddings/--model`. The
  `--ctx-size`, `--ubatch-size` and `--parallel` values live on the Deployment
  and are **not** defaults — without them llama.cpp serves a single slot at a
  much smaller context.

To rebuild it, or to get an arm64 build, `images/nomic-embed/Dockerfile` builds
a multi-arch f16 equivalent from public sources:

```bash
gh workflow run "Build nomic-embed image"     # linux/amd64 + linux/arm64
```

A newly built package is **private on first push** and the kind nodes carry no
pull secret, so make it public or the pod sits in `ImagePullBackOff`.

Its args and resources are a production llama.cpp embedder sidecar's, verbatim.

```bash
GW=$(kubectl get svc -n agentgateway-system -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')

curl -s "$GW/llmd/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"nomic-ai/nomic-embed-text-v1.5","input":"search_document: hello"}' | jq '.data[0].embedding | length'

curl -s "$GW/llamacpp/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"nomic-embed-text","input":"search_document: hello"}' | jq '.data[0].embedding | length'
```

Both return **768 dims** — neither truncates. Clients that want nomic's 256-dim
Matryoshka vectors do that reduction themselves. nomic also expects a
`search_document:` / `search_query:` task prefix on the input, as above.

Same model does not mean identical vectors: different kernels and quantization
move them slightly, so don't mix output from both into one collection.

### What to watch when evaluating

llm-d's cost here is startup and footprint; its benefit only shows up under
concurrency and as models are added.

```bash
kubectl get pods -n llm-d -n llama-cpp                       # readiness gap on first boot
kubectl get inferencepool,inferenceobjective -n llm-d        # pool + EPP wiring
kubectl logs -n llm-d deploy/llm-d-pool-epp                  # endpoint picker decisions
kubectl top pod -n llm-d; kubectl top pod -n llama-cpp       # steady-state cost
```

- **Startup**: vLLM re-downloads the weights from HuggingFace on every container
  start — there is no cache volume. llama.cpp pulls its image once and the model
  is already in it. Expect llm-d to be far slower to first Ready.
- **Footprint** is the headline number. Measured on the pods these are modelled
  on, both idle, serving the same model:

  | | CPU | memory (idle) |
  |---|---|---|
  | vLLM (`llm-d` on the reference cluster) | 139m | **2452Mi** |
  | llama.cpp (production llama.cpp embedder) | 1m | **~75Mi** |

  Two things drive that gap, and neither is the model — nomic-embed-text-v1.5 is
  a 137M-param BERT.

  **vLLM runs three Python processes, each importing torch.** Measured inside
  the container: `VLLM::Worker` 1294MiB, API server 621MiB, `EngineCore`
  491MiB. The API server holds *no model at all* and still costs 621MiB — that
  is the floor for "Python with torch imported", paid three times over before a
  single weight loads.

  **The weights are held differently.** vLLM loads a 522MB float32 safetensors
  into anonymous memory: private, dirty, unreclaimable, not shared across those
  three processes. llama.cpp mmaps a 274MB f16 GGUF straight from the image
  layer — file-backed, clean, evictable — so most of it doesn't count toward
  the working set at all.

  Treat the 75Mi as a floor, not a steady state: it is an idle pod whose weight
  pages have gone inactive. Under sustained load they become active and count
  again, toward llama.cpp's own startup projection of 236MiB. So the fair
  comparison is roughly **236MiB vs 2.4Gi — about 10x, not 30x.**

  Requests here are set from these measurements. Don't starve the vLLM pod
  below ~2.5Gi; it will OOMKill on load.

- **The Rust frontend is on** (`VLLM_USE_RUST_FRONTEND=1`). It replaces the
  Python API server — the 621MiB process above — leaving the engine and the ZMQ
  boundary untouched. Upstream reports ~837 req/s vs ~162 for the Python
  frontend on preprocess-heavy work, and embeddings are the extreme case of
  that: tokenization dominates, the forward pass through a 137M-param BERT is
  trivial. Two things worth measuring here, since the 2560Mi request was set
  before it was enabled:

  ```bash
  kubectl top pod -n llm-d --containers          # did the ~620MiB actually go?
  kubectl exec -n llm-d deploy/llm-d-embedding-llm-d-modelservice-decode -c vllm \
    -- sh -c 'for p in /proc/[0-9]*; do awk "/^Name:|^VmRSS:/{printf \"%s \", \$2}END{print \"\"}" $p/status; done | sort -k2 -rn | head'
  ```

  If the API server process is gone, the memory request can come down. It does
  **not** fall back — vLLM raises `FileNotFoundError` if the `vllm-rs` binary is
  absent — so re-check it is present before bumping the image tag.
- **Concurrency**: llama.cpp is fixed at 8 slots (`--parallel 8`). vLLM batches
  continuously — this is where it should pull ahead.
- **Scaling out**: raising `decode.replicas` puts real work in front of the EPP.
  At one replica the endpoint picker has nothing to choose between.

Note the `/llmd/v1/embeddings` route goes **straight to the decode Service**,
bypassing the EPP, and only the catch-all `/llmd` rule routes through the pool —
the same split the reference deployment uses. The EPP's scorers are built for decode/prefill
generation traffic, not a single-shot embed.

### Codespaces

Both backends pull from HuggingFace at pod start, so fix egress **before**
`make run` or every image and model pull times out:

```bash
make fix-egress
```

A default 2-core/8GB Codespace is tight — the three kind nodes are containers
sharing that one host. vLLM is sized to fit it (`releases/llmd.yaml`); raise the
requests/limits if you run somewhere with real headroom.

## Adding components

1. Put CRD charts in `releases/crds/` as HelmReleases.
2. Put app charts in `releases/` as HelmReleases.
3. Run `make push` — the cluster reconciles automatically.

The CRD kustomization runs first (`wait: true`), apps run after (`dependsOn: releases-crds`). This ordering is enforced by Flux and must be preserved.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Apache 2.0 — see [LICENSE](./LICENSE).
