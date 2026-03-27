# syntax=docker/dockerfile:1.7
# =============================================================================
# LiteParse – parameterisable Docker image
# =============================================================================
#
# Build arguments (all have sensible defaults):
#
#   NODE_VERSION        Node.js major version                  (default: 22)
#   LITEPARSE_VERSION   npm package version tag                (default: latest)
#   TESSERACT_LANGS     Space- or comma-separated ISO 639-3    (default: "")
#                       language codes to pre-bake into the
#                       image, e.g. "eng fra deu jpn chi_sim"
#   INCLUDE_LIBREOFFICE Install LibreOffice for Office-doc     (default: false)
#                       conversion (docx, xlsx, pptx, …)
#   INCLUDE_IMAGEMAGICK Install ImageMagick for image-file     (default: false)
#                       conversion (jpg, png, gif, …)
#   INCLUDE_API_SERVER  Bundle the Fastify REST API wrapper    (default: false)
#
# Flavour presets (achieved via build args):
#
#   base   – PDF parsing only; Tesseract.js downloads models from CDN at runtime
#   ocr    – base + pre-baked Tesseract language models (no CDN calls at runtime)
#   full   – ocr + LibreOffice + ImageMagick (all formats)
#   api    – full + Fastify HTTP server on :3000
#
# Usage examples:
#   docker build -t liteparse:base .
#   docker build --build-arg TESSERACT_LANGS="eng fra" -t liteparse:ocr .
#   docker build --build-arg INCLUDE_LIBREOFFICE=true \
#                --build-arg INCLUDE_IMAGEMAGICK=true \
#                --build-arg TESSERACT_LANGS="eng" \
#                -t liteparse:full .
#   docker run --rm -v "$PWD:/data" liteparse:base parse /data/document.pdf
# =============================================================================

ARG NODE_VERSION=22
ARG LITEPARSE_VERSION=latest
ARG TESSERACT_LANGS=""
ARG INCLUDE_LIBREOFFICE=false
ARG INCLUDE_IMAGEMAGICK=false
ARG INCLUDE_API_SERVER=false

# -----------------------------------------------------------------------------
# Stage 1 – tessdata-downloader
# Downloads and decompresses Tesseract.js language model files at build time.
# When TESSERACT_LANGS is empty the /tessdata directory will be empty and the
# COPY in the final stage becomes a no-op, so the base flavour has zero cost.
#
# LiteParse reads process.env.TESSDATA_PREFIX and passes it to Tesseract.js as
# both langPath and cachePath with gzip:false, meaning it expects plain
# .traineddata files in that directory rather than compressed downloads.
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS tessdata-downloader

ARG TESSERACT_LANGS

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tessdata

# Normalise commas to spaces, then download + decompress each language model.
# curl -f makes the build fail loudly on HTTP errors (e.g. unknown lang code).
RUN if [ -n "${TESSERACT_LANGS}" ]; then \
        langs=$(echo "${TESSERACT_LANGS}" | tr ',' ' '); \
        for lang in ${langs}; do \
            echo "==> Downloading tessdata for language: ${lang}"; \
            curl -fsSL \
                "https://cdn.jsdelivr.net/npm/@tesseract.js-data/${lang}/4.0.0_best_int/${lang}.traineddata.gz" \
                | gunzip > "${lang}.traineddata" \
            && echo "    -> ${lang}.traineddata OK"; \
        done; \
    else \
        echo "TESSERACT_LANGS is empty – skipping tessdata download (base flavour)."; \
    fi

# -----------------------------------------------------------------------------
# Stage 2 – api-server-deps
# Installs the Fastify API server's Node dependencies in an isolated stage so
# they are only included when INCLUDE_API_SERVER=true.
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS api-server-deps

WORKDIR /app
COPY api-server/package.json ./
# Install only direct dependencies (fastify, adm-zip, etc.).
# Remove any auto-installed @llamaindex/liteparse — it is provided globally
# at runtime via NODE_PATH=/usr/local/lib/node_modules.
RUN npm install --omit=dev \
    && rm -rf node_modules/@llamaindex \
    && npm cache clean --force

# -----------------------------------------------------------------------------
# Stage 3 – final image
# -----------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS final

# OCI image metadata — https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="liteparse-docker" \
      org.opencontainers.image.description="Parameterised Docker images for LiteParse document parser" \
      org.opencontainers.image.url="https://github.com/rafaelgom3s/liteparse-docker" \
      org.opencontainers.image.source="https://github.com/rafaelgom3s/liteparse-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Rafael Gomes"

ARG LITEPARSE_VERSION
ARG TESSERACT_LANGS
ARG INCLUDE_LIBREOFFICE
ARG INCLUDE_IMAGEMAGICK
ARG INCLUDE_API_SERVER

# --- System dependencies ------------------------------------------------------
# All optional deps are guarded by shell conditionals inside a single RUN layer
# to avoid separate apt-get update calls across layers (a cache-invalidation
# anti-pattern).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
    && if [ "${INCLUDE_LIBREOFFICE}" = "true" ]; then \
           apt-get install -y --no-install-recommends \
               libreoffice-nogui \
               python3; \
       fi \
    && if [ "${INCLUDE_IMAGEMAGICK}" = "true" ]; then \
           apt-get install -y --no-install-recommends \
               imagemagick \
               ghostscript; \
           # Debian's default ImageMagick policy blocks PDF/PS operations.
           # Relax the policy so liteparse can use ImageMagick for PDFs.
           if [ -f /etc/ImageMagick-6/policy.xml ]; then \
               sed -i \
                   's/<policy domain="coder" rights="none" pattern="PDF" \/>/<policy domain="coder" rights="read|write" pattern="PDF" \/>/' \
                   /etc/ImageMagick-6/policy.xml; \
           fi; \
       fi \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- Install liteparse globally -----------------------------------------------
RUN npm install -g @llamaindex/liteparse@${LITEPARSE_VERSION} \
    && npm cache clean --force

# --- Tesseract language models ------------------------------------------------
RUN mkdir -p /tessdata
COPY --from=tessdata-downloader /tessdata /tessdata

# --- Optional API server ------------------------------------------------------
COPY api-server/server.js /app-src/server.js
COPY api-server/package.json /app-src/package.json
COPY api-server/openapi.yaml /app-src/openapi.yaml
COPY --from=api-server-deps /app/node_modules /app-src/node_modules

# Symlink the globally-installed @llamaindex/liteparse into the api-server's
# node_modules so ESM resolution finds it (ESM ignores NODE_PATH).
RUN mkdir -p /app-src/node_modules/@llamaindex \
    && ln -s /usr/local/lib/node_modules/@llamaindex/liteparse \
             /app-src/node_modules/@llamaindex/liteparse

# --- Non-root user ------------------------------------------------------------
RUN useradd -m -s /bin/bash -d /home/liteparse liteparse \
    && mkdir -p /tmp/liteparse \
    && chown -R liteparse:liteparse \
        /tmp/liteparse \
        /home/liteparse \
        /tessdata \
        /app-src

USER liteparse
WORKDIR /data

# --- Environment variables ----------------------------------------------------
# TESSDATA_PREFIX: when the directory contains .traineddata files, Tesseract.js
# uses them without any CDN download.  When the directory is empty (base
# flavour) Tesseract.js falls back to downloading models on first use.
ENV TESSDATA_PREFIX=/tessdata

# LibreOffice needs a writable HOME for its user profile.
ENV HOME=/home/liteparse

# Scratch space for intermediate file conversions.
ENV TMPDIR=/tmp/liteparse

# Allow api-server/server.js to require globally-installed @llamaindex/liteparse
# without duplicating it in the local node_modules.
ENV NODE_PATH=/usr/local/lib/node_modules

# --- Entrypoint ---------------------------------------------------------------
# When INCLUDE_API_SERVER=true, override ENTRYPOINT at runtime with:
#   docker run --entrypoint node liteparse:api /app-src/server.js
# Or use the docker-compose / Makefile targets which handle this automatically.
ENTRYPOINT ["lit"]
CMD ["--help"]
