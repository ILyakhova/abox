#!/bin/bash
# LAB5 — turn the corpus JSON into a snapshot and pack it as a seed image.
#
# The embedder has to be the one the cluster will serve with: model, dims and
# maxInputChars are the snapshot's FINGERPRINT, and a map whose fingerprint does
# not match is skipped at load. So this runs the same nomic-embed image the
# chart mounts as a sidecar.
#
# -embedding-model is set explicitly to nomic-embed-text. servicemap defaults
# the label to "nomic" while the chart's server defaults to "nomic-embed-text",
# and the server then logs:
#
#   snapshot embed-model label differs from server (dims match; assuming same model)
#
# It loads the map anyway, on the strength of the dimensions alone. Here that
# assumption is true -- it is literally the same image -- but it would be just as
# true-looking with a different 256-dim model and a vector space that does not
# line up. Matching the label removes the guess.
set -euo pipefail
W=${1:-/tmp/xray-build}
EMBED_IMG=ghcr.io/den-vasyliev/abox/nomic-embed:v1.18.1-4ccc0ff
XRAY_IMG=ghcr.io/den-vasyliev/abox/xray-memory:v1.23.66-61e4eaa

# The flags are not optional and not tuning. The image's own CMD leaves
# --ubatch-size at 512, and a 4k-character node comes to ~1400 tokens, which
# llama.cpp refuses outright:
#
#   input (1418 tokens) is too large to process. increase the physical batch
#   size (current batch size: 512)
#
# These are the chart's sidecar defaults, so the map is built by an embedder
# configured exactly like the one that will serve queries against it.
if ! curl -sf http://localhost:8090/health >/dev/null 2>&1; then
  echo "starting the embedder on :8090"
  docker rm -f nomic-embed >/dev/null 2>&1 || true
  docker run -d --name nomic-embed -p 8090:8090 "$EMBED_IMG" \
    --host 0.0.0.0 --port 8090 --embeddings --model /models/model.gguf \
    --ctx-size 16384 --ubatch-size 2048 --parallel 8 >/dev/null
  until curl -sf http://localhost:8090/health >/dev/null 2>&1; do sleep 2; done
fi

# Encrypt to our own recipient when lab5/keygen.sh has made one. A snapshot is
# gzip over gob, so anything in it is readable with `strings` by whoever can
# pull the image -- the shipped maps are encrypted for exactly that reason. This
# corpus holds nothing private, but the `session` map written beside it will,
# and the two share a directory.
RECIPIENT_FILE="$HOME/.config/xray-memory/recipient.txt"
ENC=()
if [ -f "$RECIPIENT_FILE" ]; then
  ENC=(-snapshot-recipient "$(cat "$RECIPIENT_FILE")")
  echo "encrypting to $(cat "$RECIPIENT_FILE")"
fi

# the image runs as uid 65532 and has to write the snapshot here
chmod 777 "$W"
docker run --rm --add-host=host.docker.internal:host-gateway -v "$W":/data "$XRAY_IMG" \
  servicemap \
    -in /data/abox-topology.json \
    -snapshot-dir /data \
    -label abox \
    -embedding-endpoint http://host.docker.internal:8090 \
    -embedding-model nomic-embed-text \
    "${ENC[@]}" \
    -summary 'the abox agent topology: which kagent agents exist, what each one is for, which MCP servers and model configuration each uses, which agents delegate to which, and what nothing references'

echo "=== header"
KEYARG=()
[ -f "$HOME/.config/xray-memory/snapshot.key" ] && {
  cp "$HOME/.config/xray-memory/snapshot.key" "$W/snapshot.key"
  chmod 644 "$W/snapshot.key"
  KEYARG=(-snapshot-key /data/snapshot.key)
}
docker run --rm -v "$W":/data "$XRAY_IMG" dump /data/abox.graph.gob.gz -header "${KEYARG[@]}"
rm -f "$W/snapshot.key"

cat > "$W/Dockerfile" <<'DOCKER'
FROM scratch
COPY abox.graph.gob.gz /maps/abox.graph.gob.gz
DOCKER
docker build -q -t abox-maps:lab5 "$W"
kind load docker-image abox-maps:lab5 --name abox
echo "=== abox-maps:lab5 loaded onto the cluster nodes"
