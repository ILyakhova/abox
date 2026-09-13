# llama.cpp server with nomic-embed-text-v1.5 baked into the image.
#
# Modelled on the reference repo's charts/triageagent/chat-sidecar/Dockerfile, which
# bakes a chat GGUF the same way. Two differences: the model here is the
# EMBEDDING one and is served with --embeddings, and nomic-embed-text-v1.5 is a
# public repo, so unlike the gated gemma weights there is no HF_TOKEN build
# secret and no license to accept.
#
# Why bake instead of fetching at pod start:
#   - no HuggingFace egress when the pod starts, which matters on Codespaces
#     where egress is broken until `make fix-egress` runs
#   - no 274MB re-download on every reschedule or scale-up; it ships in a layer
#     and the kubelet caches it like any other image
#   - reproducible and pinnable by digest
#
# Built and pushed by .github/workflows/nomic-embed-image.yaml.

ARG LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server-b10920

# ── fetch stage ─────────────────────────────────────────────────────────────
# Pinned to the BUILDER's native platform. The download is just a file and is
# platform-agnostic, so there is no reason to run it under qemu -- doing so puts
# a 274MB curl through the emulator and OOMs small builder VMs. Only the runtime
# stage below is built per-arch.
FROM --platform=$BUILDPLATFORM curlimages/curl:8.11.0 AS fetch

# f16, not one of the Q* quants. Quantization perturbs the embedding vectors,
# and the point of this image is to land in the same vector space as the vLLM
# backend serving the same model.
ARG HF_REPO=nomic-ai/nomic-embed-text-v1.5-GGUF
ARG HF_FILE=nomic-embed-text-v1.5.f16.gguf

WORKDIR /models
RUN curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused \
      -o /models/model.gguf \
      "https://huggingface.co/${HF_REPO}/resolve/main/${HF_FILE}" \
    && test -s /models/model.gguf

# ── runtime stage ───────────────────────────────────────────────────────────
FROM ${LLAMA_IMAGE}
COPY --from=fetch /models/model.gguf /models/model.gguf

# Inherit the upstream ENTRYPOINT (the llama-server binary) -- do NOT override
# it, the path varies between image variants.
#
# These args mirror the production llama.cpp embedder sidecar exactly. --ctx-size 16384
# over --parallel 8 is 2048 tokens per slot, nomic's full window; --ubatch-size
# must be at least a slot because a pooled embedding has to fit in one
# micro-batch, which makes it the real per-request ceiling rather than
# --ctx-size. The Deployment overrides these anyway; this is a standalone default.
CMD ["--host", "0.0.0.0", "--port", "8090", "--embeddings", \
     "--ctx-size", "16384", "--ubatch-size", "2048", \
     "--model", "/models/model.gguf", "--parallel", "8"]
