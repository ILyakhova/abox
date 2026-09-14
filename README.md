# abox

> One command. Full AI infrastructure.

`make run` gives you a local Kubernetes cluster with everything an AI project needs: an AI-aware API gateway, an agent runtime, observability, distributed tracing, and an eval harness — ready to use.

## What's included

| Component | Role |
|---|---|
| **agentgateway v2.2.1** | AI-aware API gateway (Gateway API–native, MCP-aware) |
| **kagent 0.10.1** | Kubernetes-native AI agent framework |
| **nomic-embed-text-v1.5** | Text embeddings, served by llama.cpp on `/v1/embeddings` ([ADR](./docs/adr/0001-text-embedding-model.md)) |
| **Qdrant 1.19.1** | Vector database for retrieval |
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
| `releases/crds/` | CRD HelmReleases: gateway-api, agentgateway, kagent |
| `releases/` | App HelmReleases + Gateway + HTTPRoutes |
| `scripts/setup.sh` | Full setup script (`make run`) |
| `.github/workflows/flux-push.yaml` | CI: publish `releases/` as OCI artifact on `v*` tags |
| `docs/adr/` | Architecture decision records |
| `docs/todo/` | Executable runbooks for the decisions in `docs/adr/` |

## Adding components

1. Put CRD charts in `releases/crds/` as HelmReleases.
2. Put app charts in `releases/` as HelmReleases.
3. Run `make push` — the cluster reconciles automatically.

The CRD kustomization runs first (`wait: true`), apps run after (`dependsOn: releases-crds`). This ordering is enforced by Flux and must be preserved.

## Troubleshooting

### The cluster breaks after a Codespace restart

Two symptoms, one cause. On Codespaces — and any host carrying both iptables backends —
Docker's legacy `FORWARD` policy is `DROP`, which blackholes every user-defined bridge,
the `kind` network included. `make run` repairs this before provisioning, but the repair is
an iptables policy Docker resets on every start: it does **not** survive a stop/resume, and
`make apply` does not re-apply it.

Pulls fail, because the nodes cannot reach a registry:

```
Failed to pull image: dial tcp: lookup registry-1.docker.io on 172.18.0.1:53: i/o timeout
```

Pods also crash-loop, because traffic between pods on different nodes traverses the same
`FORWARD` chain — so in-cluster DNS times out as well:

```
lookup kagent-postgresql.kagent.svc on 10.96.0.10:53: i/o timeout
```

The second one reads like a database outage and is not: `10.96.0.10` is the CoreDNS
ClusterIP, and the service being looked up is usually running fine. A workload whose
startup depends on another service — migrations, for example — dies here.

Recover in this order:

```bash
make fix-egress                                    # prints "egress OK" per node
kubectl -n <ns> rollout restart deploy/<name>      # for anything that crash-looped
```

The restart is required. A pod already in `CrashLoopBackOff` will not come back on its own
in any useful time: the backoff stretches to five minutes and the container fails again on
each attempt. Pods merely stuck in `ImagePullBackOff` do recover by themselves once a retry
lands on a working network.

This takes out every registry and every cross-node connection at once, so it is not a
Docker Hub rate limit, and switching images will not help.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Notable changes are recorded in
[CHANGELOG.md](./CHANGELOG.md).

## License

Apache 2.0 — see [LICENSE](./LICENSE).
