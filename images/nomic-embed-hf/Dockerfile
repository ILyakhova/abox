# HF-format weights for nomic-embed-text-v1.5, as a scratch image.
#
# Consumed by releases/llmd.yaml as a Kubernetes image volume (KEP-4639), so
# vLLM never contacts HuggingFace at pod start. The image carries only the
# weights -- no OS, no runtime -- and the volume mount exposes them directly at
# modelArtifacts.mountPath.
#
# Deliberately not the GGUF image in ../nomic-embed: that one is for llama.cpp.
# vLLM needs safetensors plus the tokenizer/config.

FROM --platform=$BUILDPLATFORM alpine:3.22 AS fetch

ARG MODEL_REPO=nomic-ai/nomic-embed-text-v1.5
# Pinned so a rebuild cannot silently pick up different weights.
ARG MODEL_REV=e9b6763023c676ca8431644204f50c2b100d9aab

RUN apk add --no-cache curl
WORKDIR /out
RUN for f in config.json model.safetensors tokenizer.json tokenizer_config.json \
             special_tokens_map.json vocab.txt; do \
      curl -fsSL --retry 3 -o "$f" \
        "https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REV}/$f"; \
    done && ls -la /out

# config.json's auto_map points at nomic-ai/nomic-bert-2048, which would make
# transformers fetch modelling code at runtime. vLLM 0.29 registers
# NomicBertModel natively, so llmd.yaml omits --trust-remote-code and the
# auto_map is never read. The modelling .py files are therefore not baked in.
FROM scratch
COPY --from=fetch /out/ /
