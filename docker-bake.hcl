# =============================================================================
# LiteParse – docker buildx bake file
# =============================================================================
#
# Builds multi-architecture images (linux/amd64 + linux/arm64) using
# Docker Buildx.  Requires a buildx builder with multi-platform support:
#
#   docker buildx create --name liteparse-builder --use --bootstrap
#
# Usage:
#   # Build all flavours for both architectures (and push to registry):
#   REGISTRY=ghcr.io/yourorg docker buildx bake --push
#
#   # Build a single target locally (no push, loads into docker):
#   docker buildx bake base --load
#
#   # Override languages at bake time:
#   TESSERACT_LANGS="eng fra deu" docker buildx bake ocr --push
#
# Variables (set via env or --set):
#   REGISTRY          Image registry prefix, e.g. "ghcr.io/yourorg/"
#   NODE_VERSION      Node.js major version           (default: 22)
#   LITEPARSE_VERSION npm package version tag         (default: latest)
#   TESSERACT_LANGS   Space-separated language codes  (default: eng)
# =============================================================================

variable "REGISTRY" {
  default = ""
}

variable "NODE_VERSION" {
  default = "22"
}

variable "LITEPARSE_VERSION" {
  default = "latest"
}

variable "TESSERACT_LANGS" {
  default = "eng"
}

# Shared configuration inherited by all targets
target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  args = {
    NODE_VERSION      = NODE_VERSION
    LITEPARSE_VERSION = LITEPARSE_VERSION
  }
}

# -----------------------------------------------------------------------------
# base – PDF parsing only; no pre-baked OCR models
# -----------------------------------------------------------------------------
target "base" {
  inherits = ["_common"]
  args = {
    TESSERACT_LANGS     = ""
    INCLUDE_LIBREOFFICE = "false"
    INCLUDE_IMAGEMAGICK = "false"
  }
  tags = [
    "${REGISTRY}liteparse:base",
    "${REGISTRY}liteparse:${LITEPARSE_VERSION}-base",
  ]
}

# -----------------------------------------------------------------------------
# ocr – base + pre-baked Tesseract language models
# -----------------------------------------------------------------------------
target "ocr" {
  inherits = ["_common"]
  args = {
    TESSERACT_LANGS     = TESSERACT_LANGS
    INCLUDE_LIBREOFFICE = "false"
    INCLUDE_IMAGEMAGICK = "false"
  }
  tags = [
    "${REGISTRY}liteparse:ocr",
    "${REGISTRY}liteparse:${LITEPARSE_VERSION}-ocr",
  ]
}

# -----------------------------------------------------------------------------
# full – ocr + LibreOffice + ImageMagick
# -----------------------------------------------------------------------------
target "full" {
  inherits = ["_common"]
  args = {
    TESSERACT_LANGS     = TESSERACT_LANGS
    INCLUDE_LIBREOFFICE = "true"
    INCLUDE_IMAGEMAGICK = "true"
  }
  tags = [
    "${REGISTRY}liteparse:full",
    "${REGISTRY}liteparse:${LITEPARSE_VERSION}-full",
    # "latest" points to the fully-featured image
    "${REGISTRY}liteparse:latest",
  ]
}

# -----------------------------------------------------------------------------
# api – full + Fastify REST API server
# The image is identical to full; the docker-compose api profile overrides the
# entrypoint to node /app-src/server.js.  Tagged separately for clarity.
# -----------------------------------------------------------------------------
target "api" {
  inherits = ["_common"]
  args = {
    TESSERACT_LANGS     = TESSERACT_LANGS
    INCLUDE_LIBREOFFICE = "true"
    INCLUDE_IMAGEMAGICK = "true"
  }
  tags = [
    "${REGISTRY}liteparse:api",
    "${REGISTRY}liteparse:${LITEPARSE_VERSION}-api",
  ]
}

# -----------------------------------------------------------------------------
# ocr-sidecar – EasyOCR Python server
# -----------------------------------------------------------------------------
target "ocr-sidecar" {
  context    = "./ocr-server"
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags = [
    "${REGISTRY}liteparse-ocr-sidecar:latest",
  ]
}

# Default group: build all targets
group "default" {
  targets = ["base", "ocr", "full", "api", "ocr-sidecar"]
}
