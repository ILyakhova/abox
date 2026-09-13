# ToDo: run the embedding model in the cluster — shared Service, sidecar, llm-d

Agent-executable runbook. Implements [ADR-0002](../adr/0002-embedding-runtime-in-cluster.md).

Three parts, in order of when you need them:

- **[Part A](#part-a--shared-deployment--service-default)** — shared Deployment + Service. The abox default. Do this one.
- **[Part B](#part-b--sidecar-for-ingestion--eval-jobs)** — sidecar, scoped to ingestion/eval Jobs.
- **[Part C](#part-c--llm-d-deferred)** — llm-d. Deferred; written out so adoption is a substitution, not a redesign.

> Read [CODEBASE.md](../../CODEBASE.md) §Forbidden Patterns first. The manifests below are
> written to satisfy it; if you change them, re-check against that list.
>
> Run every `kubectl` step **on the host where the cluster actually runs** — for a
> Codespaces-based sandbox that is the Codespace, not your workstation. A local
> `kubectl` pointing at `docker-desktop` will report failures that have nothing to do
> with these manifests.

---

## Part A — shared Deployment + Service (default)

### A0. Fork prerequisites (once per fork)

Skip this step only when working in the upstream repository. Three things differ in a fork,
and each one breaks the publish path quietly rather than loudly.

**The cluster polls the upstream registry.** `bootstrap/variables.tf` defaults
`oci_registry` to `oci://ghcr.io/den-vasyliev/abox`. CI is already fork-aware — the
workflow builds the artifact URL from `${{ github.repository }}` — but the
ResourceSetInputProvider running in your cluster is not. Until it is overridden, your
cluster reconciles *upstream's* artifact: `flux get all` reports everything Ready and your
own changes never arrive. Override it locally (`*.tfvars` is gitignored, so this stays out
of version control):

```hcl
# bootstrap/terraform.tfvars
oci_registry = "oci://ghcr.io/<your-github-user>/abox"
```

then re-apply with `make apply`.

**A fresh fork has no tags.** `make push` reads the newest `v*` tag and increments the
patch. With no tags at all the version components resolve to empty strings and the
generated tag is malformed. Create the first one by hand:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

**The GHCR package is created private.** The first publish creates a private package, and
the `OCIRepository` cannot pull it without an imagePullSecret. Make it public under the
package settings on GitHub, or add a pull secret to `flux-system`.

- [ ] `oci_registry` points at your own fork, and `make apply` has been re-run.
- [ ] At least one `v*` tag exists on the fork.
- [ ] The GHCR package is pullable by the cluster.

### A1. Pin the image digest

`ghcr.io/ggml-org/llama.cpp:server` is a floating tag, which CODEBASE.md forbids. Resolve
it to an immutable digest and use that.

```bash
docker pull ghcr.io/ggml-org/llama.cpp:server
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/ggml-org/llama.cpp:server
# ghcr.io/ggml-org/llama.cpp@sha256:<digest>
```

- [ ] Digest recorded and substituted into the manifest below.

### A2. Create `releases/embeddings.yaml`

Conventions this manifest is obeying, each of which is a `[critical]` in
[REVIEW.md](../../REVIEW.md):

- The `Namespace` is declared **in this file**, in `releases/` — not in `releases/crds/`.
  The two are separate Flux Kustomizations and the CRD one does not run in the same
  reconcile.
- The HTTPRoute targets a Gateway in `agentgateway-system`, so a **ReferenceGrant** in the
  `embeddings` namespace is mandatory or the route is silently rejected.
- No `dependsOn` is needed: this introduces no HelmRelease and no new CRDs, and the
  `releases` Kustomization already depends on `releases-crds` for the Gateway API types.
- Image pinned by digest.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: embeddings
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache
  namespace: embeddings
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embeddings
  namespace: embeddings
spec:
  replicas: 1
  selector:
    matchLabels:
      app: embeddings
  template:
    metadata:
      labels:
        app: embeddings
    spec:
      # Fetch the GGUF once into the PVC. Keeping the download out of the main
      # container means a pod restart does not re-pull 140 MiB.
      initContainers:
      - name: fetch-model
        image: curlimages/curl:8.11.1
        command:
        - sh
        - -c
        - |
          set -eu
          f=/models/nomic-embed-text-v1.5.Q8_0.gguf
          [ -s "$f" ] && exit 0
          curl -fL -o "$f.tmp" \
            https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf
          mv "$f.tmp" "$f"
        volumeMounts:
        - name: models
          mountPath: /models
      containers:
      - name: llama-server
        image: ghcr.io/ggml-org/llama.cpp@sha256:REPLACE_WITH_DIGEST
        args:
        - -m
        - /models/nomic-embed-text-v1.5.Q8_0.gguf
        - --embeddings
        - --pooling
        - mean
        - -c
        - "8192"
        - -b
        - "8192"
        - -ub
        - "8192"
        - --rope-scaling
        - yarn
        - --rope-freq-scale
        - "0.75"
        - --host
        - 0.0.0.0
        - --port
        - "8080"
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: models
          mountPath: /models
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          # Sized for a 2-core / 8 GB Codespace, which is where this sandbox
          # usually runs. That host is already carrying three KinD nodes plus
          # agentgateway, kagent with its postgres, qdrant and phoenix, so
          # cpu: "2" would let the embedder claim the whole machine and starve
          # the control plane. Raise both on a larger host.
          limits:
            cpu: "1"
            memory: 1Gi
        # /health returns 503 until weights are loaded. The budget is generous for
        # the same reason releases/phoenix.yaml widened its startup probe: KinD is
        # slow, and a tight probe restarts the container before it ever binds.
        # 10 minutes, because a CPU-capped embedder on a busy node loads slowly.
        startupProbe:
          httpGet: {path: /health, port: http}
          periodSeconds: 5
          failureThreshold: 120
        readinessProbe:
          httpGet: {path: /health, port: http}
          periodSeconds: 10
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: model-cache
---
apiVersion: v1
kind: Service
metadata:
  name: embeddings
  namespace: embeddings
spec:
  selector:
    app: embeddings
  ports:
  - name: http
    port: 8080
    targetPort: http
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: embeddings
  namespace: embeddings
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: embeddings
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: embeddings
  namespace: embeddings
spec:
  parentRefs:
  - name: agentgateway-external
    namespace: agentgateway-system
  rules:
  # kagent already claims '/' on this Gateway. Gateway API resolves overlapping
  # prefixes by longest match, so '/v1/embeddings' wins here without touching
  # releases/kagent.yaml. Shortening this prefix would break that.
  - matches:
    - path:
        type: PathPrefix
        value: /v1/embeddings
    backendRefs:
    - name: embeddings
      namespace: embeddings
      port: 8080
```

- [ ] File created at `releases/embeddings.yaml`.
- [ ] `embeddings.yaml` added to the `resources:` list in `releases/kustomization.yaml`.

### A3. Verify before publishing

CODEBASE.md forbids pushing without a green reconcile — a broken release goes to GHCR and
is picked up automatically.

```bash
kubectl apply -k releases/                       # dry run against the live cluster first
kubectl -n embeddings rollout status deploy/embeddings --timeout=10m
kubectl get httproute -n embeddings embeddings -o jsonpath='{.status.parents[0].conditions}' | jq .
```

- [ ] Deployment is Available.
- [ ] HTTPRoute shows `Accepted=True` **and** `ResolvedRefs=True`. If `ResolvedRefs` is
      False, the ReferenceGrant is the first thing to check.

In-cluster call:

```bash
kubectl -n embeddings run curl --rm -it --image=curlimages/curl:8.11.1 --restart=Never -- \
  curl -s http://embeddings.embeddings.svc.cluster.local:8080/v1/embeddings \
    -H 'Content-Type: application/json' \
    -d '{"model":"nomic","input":["search_query: hello"]}'
```

Through the gateway:

```bash
GW=$(kubectl get svc -n agentgateway-system -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
curl -s "http://$GW/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"nomic","input":["search_query: hello"]}' | jq '.data[0].embedding | length'
# 768
```

- [ ] Both calls return 768 dims.
- [ ] Run the semantic acceptance test from the
      [local ToDo §5](./embeddings-local-llama-cpp.md#5-acceptance-test--the-vectors-must-be-meaningful)
      against the cluster URL. A 768-length array is not proof of correctness.

### A4. Publish

- [ ] `flux get all -A` shows everything Ready.
- [ ] `make push`. Remember the lexicographic tag rule: if the patch would exceed 9, tag
      `vX.Y+1.0` by hand instead.
- [ ] Update the component table in [README.md](../../README.md).

---

## Part B — sidecar, for ingestion / eval Jobs

Scope per ADR-0002: batch Jobs only, never the serving path. The payoff is that the Job
pins its own embedder version, so a re-index cannot silently use a different model than the
one the corpus was benchmarked against.

Use a **native sidecar** — an `initContainer` with `restartPolicy: Always`. This is the
mechanism that makes sidecars work in a `Job`: the container starts before the main
container, and the kubelet terminates it when the main container exits, so the Job can
actually reach `Complete`. A plain second entry under `containers:` never terminates and
the Job hangs forever.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: corpus-ingest
  namespace: embeddings
spec:
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
      - name: fetch-model
        image: curlimages/curl:8.11.1
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          curl -fL -o /models/model.gguf \
            https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf
        volumeMounts:
        - {name: models, mountPath: /models}

      # Native sidecar: restartPolicy Always inside initContainers.
      - name: embedder
        image: ghcr.io/ggml-org/llama.cpp@sha256:REPLACE_WITH_DIGEST
        restartPolicy: Always
        args:
        - -m
        - /models/model.gguf
        - --embeddings
        - --pooling
        - mean
        - -c
        - "8192"
        - -b
        - "8192"
        - -ub
        - "8192"
        - --rope-scaling
        - yarn
        - --rope-freq-scale
        - "0.75"
        - --host
        - 127.0.0.1
        - --port
        - "8080"
        volumeMounts:
        - {name: models, mountPath: /models}
        # The main container must not start querying before weights are loaded.
        startupProbe:
          httpGet: {path: /health, port: 8080}
          periodSeconds: 5
          failureThreshold: 120
        # Same Codespace sizing as Part A. A batch Job can afford more CPU than
        # the serving path when the node has headroom -- raise the limit if the
        # ingest is slow and nothing else is contending for the cores.
        resources:
          requests: {cpu: 500m, memory: 512Mi}
          limits:   {cpu: "1",  memory: 1Gi}

      containers:
      - name: ingest
        image: <your-ingestion-image>   # pin by digest
        env:
        # localhost: same pod, no Service, no HTTPRoute, no network hop.
        - {name: EMBEDDINGS_URL, value: "http://127.0.0.1:8080/v1/embeddings"}
        - {name: QDRANT_URL,     value: "http://qdrant.qdrant.svc.cluster.local:6333"}
      volumes:
      - name: models
        emptyDir: {}
```

- [ ] `restartPolicy: Always` is on the `embedder` entry **under `initContainers`**.
- [ ] The embedder binds `127.0.0.1`, not `0.0.0.0` — it must not be reachable from outside
      the pod.
- [ ] `startupProbe` present, so the ingest container cannot race the model load.
- [ ] The Job reaches `Complete` (`kubectl get job -n embeddings corpus-ingest`). If it
      hangs at 1 running pod with the work finished, the sidecar was declared in
      `containers:` rather than `initContainers:`.
- [ ] The model revision used is recorded alongside the Qdrant collection. Vectors from two
      model versions in one collection is a silent correctness bug.

---

## Part C — llm-d (deferred)

Do **not** implement this now. ADR-0002 records why: an embedding model is a single-pass
encoder with no KV cache and no decode phase, so every llm-d optimisation is inapplicable,
and llm-d expects accelerators that KinD does not have.

Execute this part only when an [adoption trigger](../adr/0002-embedding-runtime-in-cluster.md#adoption-triggers-for-llm-d)
fires — realistically, when a **generative** model is added to abox.

### C1. Preconditions

- [ ] A GPU-capable node is available, or the target model is small enough to be honest
      about on CPU.
- [ ] The workload is a decoder LLM (chat/completions), not an embedder.

### C2. Install the Inference Extension CRDs

These are CRDs, so per CODEBASE.md they belong in **`releases/crds/`**, not `releases/`,
and the app manifests in `releases/` must declare `dependsOn` on them.

```bash
kubectl apply -f \
  https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.5.0/manifests.yaml
```

- [ ] Packaged as a HelmRelease or pinned Kustomization under `releases/crds/`.
- [ ] Added to `releases/crds/kustomization.yaml`.
- [ ] Version pinned explicitly — never `latest`.

Gateway API itself is already installed by `releases/crds/gateway-api-crds.yaml`.

### C3. Deploy llm-d and point agentgateway at the pool

abox already runs agentgateway with `gatewayClassName: agentgateway`, which is exactly the
data plane llm-d expects — kgateway 2.2 removed the non-agentgateway inference path. No
Gateway change is needed; the existing `agentgateway-external` is reused.

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: llm
  namespace: llm-d
spec:
  selector:
    matchLabels:
      app: vllm-llm
  targetPorts:
  - name: http
    port: 8000
  endpointPickerRef:
    group: llm-d.ai
    kind: EndpointPicker
    name: llm-epp
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm
  namespace: llm-d
spec:
  parentRefs:
  - name: agentgateway-external
    namespace: agentgateway-system
  rules:
  - matches:
    - path: {type: PathPrefix, value: /v1/chat/completions}
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: llm
```

- [ ] `Namespace` declared in the same file, in `releases/`.
- [ ] A **ReferenceGrant** exists in the `llm-d` namespace, mirroring the one in Part A and
      in `releases/kagent.yaml` — the HTTPRoute's `parentRef` crosses into
      `agentgateway-system`. The `InferencePool` backend itself is in the route's own
      namespace here, so it needs no grant; move the pool and that changes.
- [ ] The path prefix does not collide with `/v1/embeddings` or kagent's `/`.
- [ ] `dependsOn` points at the Inference Extension CRD release.

### C4. What does *not* change

- [ ] `/v1/embeddings` keeps being served by `llama-server` from Part A. The two runtimes
      coexist behind the one gateway; the seam is the OpenAI wire format.
- [ ] Consumers keep addressing the gateway URL or Service DNS, so this substitution is
      invisible to them. That is the whole reason ADR-0002 forbids addressing pods directly.
