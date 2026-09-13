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

The manifest below already carries the digest resolved on 2026-09-13
(`sha256:cbcdcb52…33ff4`, the multi-arch manifest-list digest, so it is architecture
independent). Re-resolve only when deliberately moving the image forward.

- [ ] Digest in the manifest matches what `docker pull` reports, or was updated on purpose.

### A2. Review `releases/embeddings.yaml`

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

The manifest itself lives at [`releases/embeddings.yaml`](../../releases/embeddings.yaml).
Read it there. It was inlined in this document while it was still a proposal; now that the
file exists, a second copy here would only drift from it.

- [ ] After any edit, `releases/embeddings.yaml` still satisfies the four conventions above.
- [ ] It is listed under `resources:` in `releases/kustomization.yaml`. That listing is what
      puts it into the OCI artifact, so add it only once A3 passes.

### A3. Verify before publishing

CODEBASE.md forbids pushing without a green reconcile — a broken release goes to GHCR and
is picked up automatically.

This step pulls two images the cluster has never seen, so confirm the nodes still have
egress first. The repair `make run` applied does not survive a Codespace stop/resume, and
this is the cheapest moment to find that out:

```bash
make fix-egress      # no-op if the policy is already permissive
```

Apply **only the new file**. `kubectl apply -k releases/` would also re-apply the
HelmReleases that Flux owns, which makes the two writers fight over the same objects.

```bash
kubectl apply -f releases/embeddings.yaml
kubectl -n embeddings rollout status deploy/embeddings --timeout=10m
kubectl get httproute -n embeddings embeddings \
  -o jsonpath='{.status.parents[0].conditions}' | jq .
```

The first rollout waits on the initContainer pulling 140 MiB from HuggingFace, so give it
the full timeout before concluding anything is wrong. `kubectl -n embeddings logs -l
app=embeddings -c fetch-model` shows the download.

Then run the full suite — it covers the rollout, the context cap, the route conditions, the
call through the gateway, kagent's untouched catch-all, and the semantic check, each with
the value it should return:

**→ [Verification suite](./embeddings-verification.md)**

- [ ] Every check in that runbook passes. A 768-length array on its own proves the server
      answered, not that it embedded correctly.

### A4. Publish

Only after A3 is green. A broken release published to GHCR is reconciled automatically.

- [ ] `embeddings.yaml` added to `resources:` in `releases/kustomization.yaml`.
- [ ] `flux get all -A` shows everything Ready.
- [ ] `make push`. Remember the lexicographic tag rule: if the patch would exceed 9, tag
      `vX.Y+1.0` by hand instead.
- [ ] Component table in [README.md](../../README.md) lists the new service.

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
        # Resolved 2026-09-13 by the command in A1; re-resolve to move the image forward.
        image: ghcr.io/ggml-org/llama.cpp@sha256:cbcdcb52d484e08e23bfc0135afa5beadd2d540513bbb7c65b233231fa033ff4
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
        # 0.25, not the 0.75 the model card prints: llama.cpp caps a slot at
        # n_ctx_train / rope_freq_scale, and this GGUF reports n_ctx_train = 2048,
        # so 0.75 silently caps the context at 2730 instead of 8192.
        - --rope-freq-scale
        - "0.25"
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
