# qdrant-mcp

MCP tools over a Qdrant collection, embedding through any OpenAI-compatible
`/v1/embeddings` endpoint.

Replaces [`mcp-server-qdrant`](https://github.com/qdrant/mcp-server-qdrant),
whose `EmbeddingProviderType` enum has exactly one member, `FASTEMBED`, so it
always runs onnxruntime inside its own pod. Loading the f32 nomic ONNX put that
over a 2Gi limit and it was OOMKilled repeatedly. This server sends the text to
an endpoint instead, so the vectors it writes land in the same space the rest of
the cluster serves.

## Tools

| tool | what it does |
|---|---|
| `qdrant_store` | embed text and upsert it into the collection, with metadata |
| `qdrant_find` | embed a query and return the nearest points |
| `llama_embed` | `/v1/embeddings` directly, no Qdrant involved |
| `llama_health` | upstream readiness |
| `llama_props` | llama.cpp `/props` |
| `llama_models` | `/v1/models` |
| `llama_tokenize` | llama.cpp `/tokenize` |
| `llama_chat` | `/v1/chat/completions` |

The `llama_*` names are historical. `llama_embed`, `llama_health`, `llama_models`
and `llama_chat` are plain OpenAI-compatible calls and work against any such
server; `llama_props` and `llama_tokenize` are llama.cpp's own endpoints and
error elsewhere. `llama_chat` returns 501 whenever the configured endpoint was
started with `--embeddings`, which has no generation head.

`qdrant_store` applies nomic's `search_document:` prefix and `qdrant_find` the
`search_query:` one, chunks input longer than `EMBEDDING_MAX_INPUT_CHARS`, and
creates the collection on first write sized from the vector the server actually
returned.

## Configuration

| env | default | |
|---|---|---|
| `EMBEDDINGS_BASE_URL` | `http://llama-cpp-embeddings.llama-cpp:8090` | any OpenAI-compatible server |
| `EMBEDDINGS_MODEL` | | sent as `model`; required by Vertex, routed on by llm-d, ignored by llama.cpp |
| `EMBEDDINGS_API_KEY` | | `Authorization: Bearer` header; leave unset in-cluster |
| `EMBEDDINGS_TIMEOUT_SECONDS` | `120` | |
| `EMBEDDINGS_DOCUMENT_PREFIX` | `search_document: ` | set empty for a model without instruction prefixes |
| `EMBEDDINGS_QUERY_PREFIX` | `search_query: ` | as above |
| `QDRANT_URL` | `http://qdrant.qdrant:6333` | REST API, not gRPC |
| `QDRANT_COLLECTION` | `abox` | created on first write; the manifest sets `abox-nomic` |
| `EMBEDDING_MAX_INPUT_CHARS` | `7000` | longer input is chunked, 200-char overlap |

`LLAMA_BASE_URL` and `LLAMA_TIMEOUT_SECONDS` are the pre-rename spellings and
are still read, after the `EMBEDDINGS_*` ones.

### Routing to a different backend

```yaml
# standalone llama.cpp (the default)
EMBEDDINGS_BASE_URL: http://llama-cpp-embeddings.llama-cpp:8090

# llm-d, which routes on the model name
EMBEDDINGS_BASE_URL: http://llm-d-embedding.llm-d:8000
EMBEDDINGS_MODEL: nomic-ai/nomic-embed-text-v1.5

# Vertex AI's OpenAI-compatible endpoint
EMBEDDINGS_BASE_URL: https://<region>-aiplatform.googleapis.com/v1/projects/<p>/locations/<region>/endpoints/openapi
EMBEDDINGS_MODEL: text-embedding-005
EMBEDDINGS_API_KEY: <access token>
EMBEDDINGS_DOCUMENT_PREFIX: ""
EMBEDDINGS_QUERY_PREFIX: ""
```

Vectors from different backends do not mix. Dimensions differ, and even the same
model under a different runtime moves the vectors enough to matter -- point a new
`QDRANT_COLLECTION` at a new backend rather than writing into the existing one.

## Development

Scaffolded with [`kmcp`](https://github.com/kagent-dev/kmcp).

```bash
go build ./... && go test ./...
go run ./cmd/server                 # stdio
go run ./cmd/server -http :8080     # streamable HTTP
```

The deployed copy is `releases/mcp-servers.yaml`, which pins the image tag.
`.github/workflows/qdrant-mcp-image.yaml` builds and pushes it on any change
under `mcp/qdrant-mcp/`; the tag is hardcoded there, so bump both together.
