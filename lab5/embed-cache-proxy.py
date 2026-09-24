"""Caching proxy for /v1/embeddings, for machines where the embedder is slow.

`servicemap` sends one request per node, all at once, each with a hard 30s
client timeout and no flag to raise it. On the WSL2 machine this lab runs on,
the local nomic embedder manages ~90 tokens/s on long inputs, so the
1400-1900-token agent nodes time out and the build fails.

The proxy forwards each input to the embedder with no timeout, caches the
vector by exact input text, and keeps working after the client gives up. Run
servicemap twice: the first run fails but fills the cache, the second is
answered from it. Vectors come from the same embedder, unchanged, so the
snapshot fingerprint is the one make-map.sh would produce.

Used by make-map-cached.sh. Listens on :8091, forwards to :8090.
"""
import json
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:8090"
cache = {}
lock = threading.Lock()


def embed_one(model, text):
    with lock:
        if text in cache:
            return cache[text]
    body = json.dumps({"model": model, "input": [text]}).encode()
    req = urllib.request.Request(UPSTREAM + "/v1/embeddings", body,
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        vec = json.load(r)["data"][0]["embedding"]
    with lock:
        cache[text] = vec
    print(f"embedded {len(text)} chars, cache={len(cache)}", flush=True)
    return vec


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with urllib.request.urlopen(UPSTREAM + self.path, timeout=30) as r:
            data = r.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        inputs = req["input"] if isinstance(req["input"], list) else [req["input"]]
        hits = sum(1 for t in inputs if t in cache)
        print(f"request: {len(inputs)} inputs, {hits} cached", flush=True)
        vecs = [embed_one(req.get("model", ""), t) for t in inputs]
        out = {"object": "list", "model": req.get("model", ""),
               "data": [{"object": "embedding", "index": i, "embedding": v}
                        for i, v in enumerate(vecs)],
               "usage": {"prompt_tokens": 0, "total_tokens": 0}}
        data = json.dumps(out).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            print("client gone; vectors kept in cache", flush=True)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", 8091), H).serve_forever()
