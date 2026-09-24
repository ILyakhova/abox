#!/bin/bash
# LAB8 — turn kagent agent tracing on, pointed at agentevals, and pin the
# release bundle so nothing reverts it mid-lab.
#
# LAB7 recorded that kagent agents "emit nothing and cannot be made to". That
# was wrong about the cause. OTEL_TRACING_ENABLED=false comes from the kagent
# chart's otel.tracing.enabled value, rendered into ConfigMap
# kagent-controller; the controller copies its OTEL_* keys into every agent
# Deployment. LAB7 tried the Agent CR's deployment.env, which the controller
# overrides -- the ConfigMap is where the setting actually lives.
#
# The ConfigMap is Helm-managed. The kagent HelmRelease has no driftDetection,
# so this survives until the chart is next upgraded -- which is why the input
# provider is pinned below. `make apply` / `make run` undo both.
set -euo pipefail

# 1. pin the bundle to what is deployed now (it polls for the newest tag every 5m)
cur=$(kubectl -n flux-system get resourcesetinputprovider releases-image -o json | jq -r '.status.exportedInputs[0].tag')
kubectl -n flux-system patch resourcesetinputprovider releases-image --type=merge \
  -p "{\"spec\":{\"filter\":{\"semver\":\"=$cur\"}}}"
echo "releases pinned to $cur"

# 2. tracing on, to agentevals' OTLP/gRPC receiver
#    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT gates whether the
#    OpenAI/Anthropic/Bedrock/Ollama adapters put prompt and response text on
#    the spans. It is read as "on unless literally false", but set it
#    explicitly: this is the switch that makes traces carry conversation
#    content, and it should be visible that it was thrown.
kubectl -n kagent patch configmap kagent-controller --type=merge -p '{"data":{
  "OTEL_TRACING_ENABLED": "true",
  "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://agentevals-go.agentevals.svc.cluster.local:4317",
  "OTEL_EXPORTER_OTLP_TRACES_INSECURE": "true",
  "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "grpc",
  "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT": "15000",
  "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "true"}}'

# 3. the controller re-renders every agent Deployment on restart
kubectl -n kagent rollout restart deploy/kagent-controller
kubectl -n kagent rollout status deploy/kagent-controller --timeout=180s
echo "tracing enabled; agents restart as the controller reconciles them"
