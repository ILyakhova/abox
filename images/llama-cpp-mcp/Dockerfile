# chadsten/llama-cpp-mcp is not published to npm (registry.npmjs.org 404s), and
# the repo ships no dist/ and no prepare script, so `npx github:...` does not
# build either. Build it from the tag.
#
# Built and pushed by .github/workflows/llama-cpp-mcp-image.yaml.

ARG NODE_IMAGE=node:22-alpine

FROM ${NODE_IMAGE} AS build
ARG REF=v0.1.1
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch ${REF} https://github.com/chadsten/llama-cpp-mcp.git . \
 && npm ci \
 && npm run build \
 && npm prune --omit=dev

FROM ${NODE_IMAGE}
WORKDIR /app
COPY --from=build /src/package.json ./
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/dist ./dist
USER 65532:65532
ENTRYPOINT ["node", "/app/dist/index.js"]
