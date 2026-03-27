# =============================================================================
# LiteParse – Makefile
# =============================================================================
#
# Configurable variables (override on the command line):
#
#   NODE_VERSION       Node.js major version           (default: 22)
#   VERSION            liteparse npm package version   (default: latest)
#   LANGS              Tesseract language codes        (default: eng)
#   REGISTRY           Image registry prefix           (default: empty)
#   DOCUMENTS_DIR      Host directory to mount at /data for run targets
#
# Examples:
#   make base
#   make ocr LANGS="eng fra deu jpn"
#   make full LANGS="eng"
#   make api LANGS="eng"
#   make all
#   make multi-arch REGISTRY=ghcr.io/yourorg/
#   make run-base FILE=report.pdf
#   make run-api
# =============================================================================

NODE_VERSION  ?= 22
VERSION       ?= latest
LANGS         ?= eng
REGISTRY      ?=
DOCUMENTS_DIR ?= $(PWD)
API_PORT      ?= 3000
OCR_PORT      ?= 8080

IMAGE_PREFIX  := $(if $(REGISTRY),$(REGISTRY)/,)

.PHONY: all base ocr full api ocr-sidecar multi-arch \
        run-base run-ocr run-full run-api run-ocr-sidecar \
        test test-base test-ocr test-full test-api fixtures \
        clean clean-volumes help

# Default: build all four main flavours
all: base ocr full api

## base: Node $(NODE_VERSION) + liteparse; Tesseract downloads models at runtime
base:
	docker build \
	    --build-arg NODE_VERSION=$(NODE_VERSION) \
	    --build-arg LITEPARSE_VERSION=$(VERSION) \
	    --build-arg TESSERACT_LANGS="" \
	    --build-arg INCLUDE_LIBREOFFICE=false \
	    --build-arg INCLUDE_IMAGEMAGICK=false \
	    --tag $(IMAGE_PREFIX)liteparse:base \
	    --tag $(IMAGE_PREFIX)liteparse:$(VERSION)-base \
	    .

## ocr: base + pre-baked Tesseract models (use LANGS= to specify languages)
ocr:
	docker build \
	    --build-arg NODE_VERSION=$(NODE_VERSION) \
	    --build-arg LITEPARSE_VERSION=$(VERSION) \
	    --build-arg TESSERACT_LANGS="$(LANGS)" \
	    --build-arg INCLUDE_LIBREOFFICE=false \
	    --build-arg INCLUDE_IMAGEMAGICK=false \
	    --tag $(IMAGE_PREFIX)liteparse:ocr \
	    --tag $(IMAGE_PREFIX)liteparse:$(VERSION)-ocr \
	    .

## full: ocr + LibreOffice + ImageMagick (all formats supported)
full:
	docker build \
	    --build-arg NODE_VERSION=$(NODE_VERSION) \
	    --build-arg LITEPARSE_VERSION=$(VERSION) \
	    --build-arg TESSERACT_LANGS="$(LANGS)" \
	    --build-arg INCLUDE_LIBREOFFICE=true \
	    --build-arg INCLUDE_IMAGEMAGICK=true \
	    --tag $(IMAGE_PREFIX)liteparse:full \
	    --tag $(IMAGE_PREFIX)liteparse:$(VERSION)-full \
	    --tag $(IMAGE_PREFIX)liteparse:latest \
	    .

## api: full + Fastify REST API server bundled; start with run-api
api: full
	docker tag $(IMAGE_PREFIX)liteparse:full $(IMAGE_PREFIX)liteparse:api
	docker tag $(IMAGE_PREFIX)liteparse:full $(IMAGE_PREFIX)liteparse:$(VERSION)-api

## ocr-sidecar: build the EasyOCR Python sidecar image
ocr-sidecar:
	docker build \
	    --tag $(IMAGE_PREFIX)liteparse-ocr-sidecar:latest \
	    ocr-server/

## multi-arch: build and push all targets for linux/amd64 + linux/arm64
## Requires: docker buildx create --name liteparse-builder --use --bootstrap
multi-arch:
	REGISTRY=$(REGISTRY) \
	NODE_VERSION=$(NODE_VERSION) \
	LITEPARSE_VERSION=$(VERSION) \
	TESSERACT_LANGS="$(LANGS)" \
	docker buildx bake --push

# ---------------------------------------------------------------------------
# Run targets
# ---------------------------------------------------------------------------

## run-base FILE=<path>: parse a document with the base image
run-base:
	@[ -n "$(FILE)" ] || (echo "Usage: make run-base FILE=path/to/document.pdf" && exit 1)
	docker run --rm \
	    -v "$(DOCUMENTS_DIR):/data" \
	    $(IMAGE_PREFIX)liteparse:base \
	    parse /data/$(FILE)

## run-ocr FILE=<path> [LANG=eng]: parse with pre-baked OCR models
run-ocr:
	@[ -n "$(FILE)" ] || (echo "Usage: make run-ocr FILE=path/to/document.pdf [LANG=eng]" && exit 1)
	docker run --rm \
	    -v "$(DOCUMENTS_DIR):/data" \
	    $(IMAGE_PREFIX)liteparse:ocr \
	    parse /data/$(FILE) $(if $(LANG),--ocr-language $(LANG),)

## run-full FILE=<path>: parse any supported format with the full image
run-full:
	@[ -n "$(FILE)" ] || (echo "Usage: make run-full FILE=path/to/document.docx" && exit 1)
	docker run --rm \
	    -v "$(DOCUMENTS_DIR):/data" \
	    $(IMAGE_PREFIX)liteparse:full \
	    parse /data/$(FILE)

## run-api: start the Fastify REST API on port $(API_PORT)
run-api:
	docker compose --profile api up

## run-ocr-sidecar: start the EasyOCR sidecar on port $(OCR_PORT)
run-ocr-sidecar:
	docker compose --profile ocr-sidecar up

# ---------------------------------------------------------------------------
# Tests — same scripts used locally and in CI
# ---------------------------------------------------------------------------

## fixtures: generate test fixture files (tests/fixtures/)
fixtures:
	bash tests/generate-fixtures.sh

## test-base: build base image then run tests
test-base: base fixtures
	bash tests/test-flavour.sh base

## test-ocr: build ocr image then run tests
test-ocr: ocr fixtures
	bash tests/test-flavour.sh ocr

## test-full: build full image then run tests
test-full: full fixtures
	bash tests/test-flavour.sh full

## test-api: build api image then run tests
test-api: api fixtures
	bash tests/test-flavour.sh api

## test: build and test all flavours
test: test-base test-ocr test-full test-api

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

## clean: remove all local liteparse images
clean:
	-docker rmi \
	    $(IMAGE_PREFIX)liteparse:base \
	    $(IMAGE_PREFIX)liteparse:ocr \
	    $(IMAGE_PREFIX)liteparse:full \
	    $(IMAGE_PREFIX)liteparse:api \
	    $(IMAGE_PREFIX)liteparse:latest \
	    $(IMAGE_PREFIX)liteparse-ocr-sidecar:latest \
	    2>/dev/null || true

## clean-volumes: remove the EasyOCR model volume (forces model re-download)
clean-volumes:
	docker volume rm liteparse_easyocr-models 2>/dev/null || true

## help: list available targets
help:
	@echo "LiteParse Docker build targets:"
	@echo ""
	@grep -E '^## ' Makefile | sed 's/^## /  /'
	@echo ""
	@echo "Variables:"
	@echo "  NODE_VERSION=$(NODE_VERSION)  VERSION=$(VERSION)  LANGS=$(LANGS)"
	@echo "  REGISTRY=$(REGISTRY)  DOCUMENTS_DIR=$(DOCUMENTS_DIR)"
