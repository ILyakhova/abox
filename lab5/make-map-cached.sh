#!/bin/bash
# LAB5 — make-map.sh for a machine where the embedder is too slow for
# servicemap's hard 30s per-request timeout. Same inputs, same flags, same
# output; the only difference is embed-cache-proxy.py between servicemap and
# the embedder, and servicemap run natively so it can reach the proxy.
#
# Why this exists and when it was needed: see "Things that cost time" in
# README.md. Use make-map.sh first; fall back to this when it fails with
# "context deadline exceeded (Client.Timeout exceeded while awaiting headers)".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-/tmp/xray-build}
EMBED_IMG=ghcr.io/den-vasyliev/abox/nomic-embed:v1.18.1-4ccc0ff
XRAY_IMG=ghcr.io/den-vasyliev/abox/xray-memory:v1.23.66-61e4eaa
BIN=/tmp/xray-memory-bin
KEYDIR="$HOME/.config/xray-memory"

# the embedder, exactly as make-map.sh starts it
if ! curl -sf http://localhost:8090/health >/dev/null 2>&1; then
  docker rm -f nomic-embed >/dev/null 2>&1 || true
  docker run -d --name nomic-embed -p 8090:8090 "$EMBED_IMG" \
    --host 0.0.0.0 --port 8090 --embeddings --model /models/model.gguf \
    --ctx-size 16384 --ubatch-size 2048 --parallel 8 >/dev/null
  until curl -sf http://localhost:8090/health >/dev/null 2>&1; do sleep 2; done
fi

# the servicemap binary, out of the same image make-map.sh runs
if [ ! -x "$BIN" ]; then
  id=$(docker create "$XRAY_IMG")
  docker cp "$id":/ko-app/xray-memory "$BIN"
  docker rm "$id" >/dev/null
  chmod +x "$BIN"
fi

python3 "$HERE/embed-cache-proxy.py" > /tmp/embed-cache-proxy.log 2>&1 &
PROXY=$!
trap 'kill $PROXY 2>/dev/null' EXIT
until curl -sf http://localhost:8091/health >/dev/null 2>&1; do sleep 1; done

N=$(jq length "$W/abox-topology.json")
build() {
  "$BIN" servicemap \
    -in "$W/abox-topology.json" -snapshot-dir "$W" -label abox \
    -embedding-endpoint http://localhost:8091 \
    -embedding-model nomic-embed-text \
    -snapshot-recipient "$(cat "$KEYDIR/recipient.txt")" \
    -summary 'the abox agent topology: which kagent agents exist, what each one is for, which MCP servers and model configuration each uses, which agents delegate to which, and what nothing references'
}

# First run is expected to time out; the proxy keeps embedding behind it.
for attempt in 1 2 3 4 5; do
  if build; then break; fi
  echo "attempt $attempt timed out; waiting for the proxy to fill its cache ($N nodes)"
  for i in $(seq 1 60); do
    grep -q "cache=$N\$" /tmp/embed-cache-proxy.log && break
    sleep 5
  done
done
[ -f "$W/abox.graph.gob.gz" ] || { echo "no snapshot written"; exit 1; }

# from here on, identical to make-map.sh
echo "=== header"
cp "$KEYDIR/snapshot.key" "$W/snapshot.key"
chmod 644 "$W/snapshot.key"
docker run --rm -v "$W":/data "$XRAY_IMG" dump /data/abox.graph.gob.gz -header -snapshot-key /data/snapshot.key
rm -f "$W/snapshot.key"

cat > "$W/Dockerfile" <<'DOCKER'
FROM scratch
COPY abox.graph.gob.gz /maps/abox.graph.gob.gz
DOCKER
docker build -q -t abox-maps:lab5 "$W"
kind load docker-image abox-maps:lab5 --name abox
echo "=== abox-maps:lab5 loaded onto the cluster nodes"
