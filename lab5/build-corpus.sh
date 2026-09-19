#!/bin/bash
# LAB5 — build the abox agent-topology corpus for xray-memory from the live
# cluster.
#
# Output is the JSON `xray-memory servicemap` consumes. Its -help documents only
# {name, calls, called_by}; probing the binary showed it also reads:
#
#   kind   -> the node's Kind (otherwise everything is "Service")
#   text   -> the node's Content, which is the text that gets EMBEDDED
#   attrs  -> the node's Attrs, which search_graph can select with attr=key=value
#             and sort with order=key[:desc]
#
# Without those three the map is a graph of bare names: structurally correct and
# semantically empty, because there is nothing for a query to match against.
#
# An Agent "calls" its ModelConfig, every MCP server in its toolset, and every
# agent it delegates to. called_by is computed as the inverse rather than read,
# so the two directions cannot disagree.
set -euo pipefail
W=${1:-/tmp/xray-build}
mkdir -p "$W"

kubectl -n kagent get agents.kagent.dev            -o json > "$W/agents.json"
kubectl -n kagent get mcpservers.kagent.dev        -o json > "$W/mcp.json"
kubectl -n kagent get remotemcpservers.kagent.dev  -o json > "$W/rmcp.json"
kubectl -n kagent get modelconfigs.kagent.dev      -o json > "$W/mc.json"

# --- edges -------------------------------------------------------------------
jq -r '
  .items[]
  | .metadata.name as $n
  | [ (.spec.declarative.modelConfig // empty)
    , (.spec.declarative.tools[]? | .mcpServer.name // empty)
    , (.spec.declarative.tools[]? | .agent.name // empty)
    ]
  | .[] | "\($n)\t\(.)"
' "$W/agents.json" | sort -u > "$W/edges.tsv"

# --- nodes -------------------------------------------------------------------
# Content is written for a reader, not for a schema: the first line names the
# object, the rest is what a question about it would actually use. The system
# prompt is included because it is where an agent's purpose is really written --
# the description field is one sentence and rarely enough.
jq -c '
  .items[] | {
    name: .metadata.name,
    kind: "Agent",
    text: ([ "Agent \(.metadata.name) in namespace \(.metadata.namespace)."
           , (.spec.description // "")
           , "Model configuration: \(.spec.declarative.modelConfig // "none")."
           , "Tools: \([.spec.declarative.tools[]? | .mcpServer.name // .agent.name] | join(", "))."
           , (.spec.declarative.systemMessage // "")
           ] | map(select(length > 0)) | join("\n")),
    attrs: {
      namespace: .metadata.namespace,
      model: (.spec.declarative.modelConfig // "none"),
      tools: ([.spec.declarative.tools[]?] | length | tostring),
      managed: (if .metadata.labels["kustomize.toolkit.fluxcd.io/name"] then "flux" else "manual" end)
    }
  }' "$W/agents.json" > "$W/nodes.ndjson"

jq -c '
  .items[] | {
    name: .metadata.name,
    kind: "MCPServer",
    text: ([ "MCPServer \(.metadata.name) in namespace \(.metadata.namespace)."
           , "Transport: \(.spec.transportType // "unknown")."
           , "Image: \(.spec.deployment.image // "none"), command: \(.spec.deployment.cmd // "default")."
           , "Environment: \([.spec.deployment.env // {} | to_entries[] | "\(.key)=\(.value)"] | join(", "))."
           , "Memory limit: \(.spec.deployment.resources.limits.memory // "unset")."
           ] | join("\n")),
    attrs: {
      namespace: .metadata.namespace,
      transport: (.spec.transportType // "unknown"),
      memory: (.spec.deployment.resources.limits.memory // "unset")
    }
  }' "$W/mcp.json" >> "$W/nodes.ndjson"

jq -c '
  .items[] | {
    name: .metadata.name,
    kind: "RemoteMCPServer",
    text: ([ "RemoteMCPServer \(.metadata.name) in namespace \(.metadata.namespace)."
           , "URL: \(.spec.url // "unset"), protocol: \(.spec.protocol // "unset")."
           , "Description: \(.spec.description // "none")."
           ] | join("\n")),
    attrs: { namespace: .metadata.namespace, protocol: (.spec.protocol // "unset") }
  }' "$W/rmcp.json" >> "$W/nodes.ndjson"

jq -c '
  .items[] | {
    name: .metadata.name,
    kind: "ModelConfig",
    text: ([ "ModelConfig \(.metadata.name) in namespace \(.metadata.namespace)."
           , "Provider: \(.spec.provider // "unknown"), model: \(.spec.model // "unknown")."
           , "API key comes from secret \(.spec.apiKeySecret // "none") key \(.spec.apiKeySecretKey // "none")."
           ] | join("\n")),
    attrs: {
      namespace: .metadata.namespace,
      provider: (.spec.provider // "unknown"),
      model: (.spec.model // "unknown")
    }
  }' "$W/mc.json" >> "$W/nodes.ndjson"

# Anything referenced but never declared still deserves a node, or the edge is
# lost. None exist today; this keeps that true rather than assumed.
cut -f2 "$W/edges.tsv" | sort -u > "$W/targets.txt"
jq -r '.name' "$W/nodes.ndjson" | sort -u > "$W/declared.txt"
comm -23 "$W/targets.txt" "$W/declared.txt" | while read -r orphan; do
  [ -n "$orphan" ] || continue
  jq -nc --arg n "$orphan" '{name:$n, kind:"Unknown",
    text:"Referenced by an agent but not declared in namespace kagent.",
    attrs:{namespace:"kagent"}}' >> "$W/nodes.ndjson"
done

# --- assemble ----------------------------------------------------------------
jq -s --rawfile edges "$W/edges.tsv" '
  ($edges | split("\n") | map(select(length > 0) | split("\t"))) as $E
  | map(. + { calls:     ($E | map(select(.[0] == .name)) | map(.[1]) | unique)
            , called_by: ($E | map(select(.[1] == .name)) | map(.[0]) | unique) })
' "$W/nodes.ndjson" > "$W/abox-topology.json" 2>/dev/null || {
  # jq cannot see the outer .name from inside the inner map(); do it per node.
  jq -s --rawfile edges "$W/edges.tsv" '
    ($edges | split("\n") | map(select(length > 0) | split("\t"))) as $E
    | map( . as $node
         | $node + { calls:     ($E | map(select(.[0] == $node.name) | .[1]) | unique)
                   , called_by: ($E | map(select(.[1] == $node.name) | .[0]) | unique) })
  ' "$W/nodes.ndjson" > "$W/abox-topology.json"
}

echo "nodes: $(jq 'length' "$W/abox-topology.json"), edges: $(wc -l < "$W/edges.tsv")"
jq -r '.[] | "\(.kind)\t\(.name)\t->\(.calls|length) <-\(.called_by|length)\t\(.text|length)ch"' \
  "$W/abox-topology.json" | column -t
