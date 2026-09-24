# Bringing the sandbox back up

Written after LAB7, when the cluster was stopped to free the machine. It runs on
WSL2 + Docker Desktop, not Codespaces.

## The short version

```bash
# in the Ubuntu terminal
cd /mnt/c/Users/iryna/abox
make run                     # ~10-15 min: KinD, Flux, then the release bundle
kind get kubeconfig --name abox > /mnt/c/Users/iryna/.kube/abox.config
```

`make fix-egress` is not needed here — the nested-Docker blackhole is a
Codespaces problem. `make tools` is not needed either; everything is installed.

Run `make run` yourself, in the Ubuntu terminal: it reinstalls OpenTofu with
`sudo` and stops at a password prompt, so it hangs silently when started from a
non-interactive shell.

## Before `make run`: is there a half-destroyed cluster?

Stopping Docker in the middle of `make down` leaves the KinD nodes alive and the
OpenTofu state empty — found 2026-09-24, with Flux objects gone, two namespaces
stuck in `Terminating`, and no PVCs. `setup.sh` handles the opposite mismatch
(state names a cluster kind does not have) but not this one, and `tofu apply`
then fails with "already exists".

```bash
kind get clusters                 # abox listed?
cd bootstrap && tofu state list   # ...and the state empty?
kind delete cluster --name abox   # then remove it by hand before make run
```

## After `make run`: two Secrets nothing will create for you

Since `releases-otel-demo:0.11.36` the bundle carries components whose
credentials are not in it. Without them Flux does not merely leave one component
red — it blocks everything behind it.

**`ngrok-operator-credentials` blocks the whole platform.** `releases-crds` has
`wait: true` and lists the ngrok HelmRelease among its health checks, so until
ngrok is healthy `releases` never starts: no kagent, no Phoenix, no otel-demo.
The error is `health check failed ... HelmRelease/ngrok-operator/ngrok-operator
status: 'InProgress'`. Needs an ngrok API key (dashboard → API Keys) and the
authtoken (→ Authtokens):

```bash
read -s -p "API key: " NGROK_API_KEY; echo
read -s -p "Authtoken: " NGROK_AUTHTOKEN; echo
echo "api=${#NGROK_API_KEY} token=${#NGROK_AUTHTOKEN}"   # both must be > 0
kubectl -n ngrok-operator create secret generic ngrok-operator-credentials \
  --from-literal=API_KEY="$NGROK_API_KEY" --from-literal=AUTHTOKEN="$NGROK_AUTHTOKEN"
unset NGROK_API_KEY NGROK_AUTHTOKEN
```

Paste those lines **one at a time**. Pasted as a block, `read` takes the next
pasted line as its input and the Secret is created with empty values — which
Kubernetes accepts without a word.

**`agentgateway-llm-secrets` blocks `releases` from going Ready.**
`GEMINI_API_KEY` is the real Gemini key; `TRIAGE_LLM_KEY` is not an external
credential but the key clients present to the gateway itself, so it can be
generated:

```bash
read -s -p "Gemini key: " GEMINI_KEY; echo
kubectl -n agentgateway-system create secret generic agentgateway-llm-secrets \
  --from-literal=GEMINI_API_KEY="$GEMINI_KEY" \
  --from-literal=TRIAGE_LLM_KEY="$(openssl rand -hex 24)"
unset GEMINI_KEY
```

The gateway's config names `gemini-2.5-flash`, which is retired, so calls
through it will fail until upstream changes that.

**Four things stay red and are expected to.** `triage-agent`, `triage-core` and
`triage-ui` pull private GHCR packages (`ghcr-credentials`,
`triage-ghcr-pull`); the upstream `xray-memory` wants the author's snapshot key
and `xray-memory-auth`. None of them is used by the labs, and because of them
the `releases` Kustomization reports not Ready while everything else works.

**HelmReleases that timed out on the first pull stay Failed** after their
workloads become healthy. Ask for a retry rather than waiting an hour:

```bash
T=$(date +%s)
kubectl -n kagent annotate helmrelease kagent --overwrite \
  reconcile.fluxcd.io/requestedAt="$T" reconcile.fluxcd.io/resetAt="$T"
```

## Avast breaks every TLS connection to the cluster and to registries

Avast's Web Shield re-signs HTTPS with "Avast Web/Mail Shield Untrusted Root".
Two symptoms, same cause:

- Lens and Windows `kubectl`: `x509: certificate signed by unknown authority`
  against `127.0.0.1:<port>`, while the same kubeconfig works from WSL.
- Flux inside the cluster: the same x509 error pulling from `ghcr.io`. Not
  confirmed by reading the certificate — it went away the moment Avast was
  stopped, which is strong evidence rather than proof.

Stopping Avast fixes both, and it comes back on every reboot. The lasting fix is
an exception for `https://127.0.0.1` or turning off its HTTPS scanning.

## What will be different

**The API server port changes on every cluster creation.** Lens will show the
old cluster unreachable until the kubeconfig above is re-exported. That looks
like a broken cluster and is not.

**Do not run `make apply` on its own** unless the artifact the branch points at
actually exists. `bootstrap/variables.tf` currently targets
`releases-otel-demo`, which is published — but a future branch merge may point it
somewhere empty, and then Flux has nothing to reconcile. Check first:

```bash
docker manifest inspect ghcr.io/den-vasyliev/abox/releases-otel-demo:0.11.36
```

**The cluster updates itself.** The ResourceSetInputProvider polls the registry
every five minutes and takes the newest `v*` tag, so the bundle may have moved on
since. That is how `mlflow` and `triage` appeared between LAB6 and LAB7 without
anyone asking.

**After a Windows reboot** Docker Desktop does not start by itself, and WSL
reports `docker` as not found until it does. Once it is up the KinD containers
restart on their own, keep their API port, and the cluster comes back with its
volumes. Pods left from before the reboot sit in `Unknown`, and anything that
failed to pull meanwhile sits in `ImagePullBackOff`; deleting them lets their
Deployments start fresh ones.

## What will be lost

Everything on a PersistentVolume. KinD's local-path volumes live inside the
nodes, and `make down` deletes the nodes.

- **The xray-memory corpus and the agent's notes** — the `session` map with
  whatever `remember` wrote. Rebuild with `lab5/build-corpus.sh` and
  `lab5/make-map.sh`; the age identity survives in `~/.config/xray-memory/` and
  is what makes the old snapshot readable, so keep it.
- **Qdrant collections** (`abox-nomic`, `abox-minilm`) — re-ingest per
  `lab4/evaluation.md`.
- **Neo4j graph** — rebuild per `lab5` / `lab4/graph-evaluation.md`.
- **Phoenix and MLflow traces.**

## What has to be redone by hand

Nothing in `lab4/`, `lab5/` or `lab7/` ships: the cluster reconciles the upstream
artifact, not this fork. After `make run`:

```bash
# LAB5 — the corpus and the agent
bash lab5/keygen.sh                       # skips if the identity already exists
bash lab5/build-corpus.sh
bash lab5/make-map.sh                     # on "context deadline exceeded": make-map-cached.sh
kubectl apply -f lab5/xray-memory-abox.yaml
kubectl -n kagent create secret generic gemini-gemini-3-5-flash \
  --from-literal=GEMINI_API_KEY=<key>
kubectl apply -f lab5/modelconfig-gemini.yaml -f lab5/memory-agent.yaml

# LAB4 — the comparison arms, only if rerunning that lab
docker build -t qdrant-mcp:lab4 mcp/qdrant-mcp && kind load docker-image qdrant-mcp:lab4 --name abox
kubectl apply -f lab4/qdrant-mcp-fixed.yaml -f lab4/retrieval-agent-nomic.yaml

# LAB7 — the fan-out collector
kubectl -n lab7 create secret generic phoenix-ingest --from-literal=api-key='<phoenix system key>'
kubectl apply -f lab7/fanout-collector.yaml
```

The Phoenix system key is created in its UI (Settings → API Keys) and shown once.

### The LAB7 patches that do not survive

These were hand patches to Flux-managed deployments and revert on the next
reconcile. Redo them only if rerunning LAB7:

```bash
# MLflow: allow the cluster DNS name through its Host check, and stop it
# crash-looping on a 1s probe with four workers
kubectl -n mlflow patch deploy mlflow-mlflow --type=json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--allowed-hosts=*"}]'
# then workers=1 and timeoutSeconds=10 on both probes -- see lab7/comparison.md

# the demo agent, pointed at a working model
kubectl -n otel-demo set env deploy/agent \
  OTEL_COLLECTOR_NAME=fanout-collector.lab7 \
  LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai/ \
  LLM_MODEL=gemini-3.6-flash USE_VCR=False
```

`gemini-2.5-flash` is retired; the API says to use `gemini-3.6-flash`. Tool
calls still fail against Gemini 3 — it requires a `thought_signature` the demo's
OpenAI-shaped client does not send — so plain questions work and tool-using ones
do not.

## Local files that are not in git

Excluded through `.git/info/exclude`, so they exist only on this machine and
will not come back from a clone:

- `abox-embeddings-notes.md`
- `docs/adr/uk/` — the Ukrainian ADR translations
- `~/.config/xray-memory/snapshot.key` — the age identity; without it the
  encrypted corpus cannot be opened

## Stopping it again

```bash
cd /mnt/c/Users/iryna/abox && make down
```

Docker Desktop can then be quit. Stopping Docker without `make down` leaves the
KinD containers on disk; they restart with Docker but the cluster usually needs
`make down && make run` anyway once the node IPs move.
