# liteparse-docker

Parameterisable Docker build for [LiteParse](https://developers.llamaindex.ai/liteparse/) — the local, open-source document parser by [LlamaIndex](https://www.llamaindex.ai/).

A single `Dockerfile` produces multiple image **flavours** via build arguments, ranging from a minimal PDF-only container to a full multi-format parser with pre-baked OCR models, a REST API, and an optional high-accuracy OCR sidecar.

---

## Table of contents

- [Flavours](#flavours)
- [Quick start](#quick-start)
- [Usage without volume mounts](#usage-without-volume-mounts)
- [Build arguments](#build-arguments)
- [Makefile targets](#makefile-targets)
- [docker-compose profiles](#docker-compose-profiles)
- [Multi-arch builds](#multi-arch-builds)
- [REST API server](#rest-api-server)
- [API documentation](#api-documentation)
- [EasyOCR sidecar](#easyocr-sidecar)
- [Testing](#testing)
- [CI/CD](#cicd)
- [Architecture decisions](#architecture-decisions)
- [Credits](#credits)

---

## Flavours

| Tag | Pre-baked OCR | LibreOffice | ImageMagick | Approx. size |
|---|:---:|:---:|:---:|---|
| `liteparse:base` | — (CDN on first use) | — | — | ~350 MB |
| `liteparse:ocr` | ✓ configurable langs | — | — | +~20 MB/lang |
| `liteparse:full` | ✓ configurable langs | ✓ | ✓ | ~2 GB |
| `liteparse:api` | ✓ configurable langs | ✓ | ✓ | ~2 GB |
| `liteparse-ocr-sidecar` | EasyOCR (Python) | — | — | ~3 GB |

**base** — PDF parsing only. Tesseract.js language models are downloaded from jsDelivr CDN on first use. Requires internet at parse time if OCR is needed.

**ocr** — Same as base, but Tesseract.js `.traineddata` files are baked into the image at build time. Works fully offline after pulling. Languages are chosen at build time via `TESSERACT_LANGS`.

**full** — Adds LibreOffice (for `.docx`, `.xlsx`, `.pptx`, `.odt`, …) and ImageMagick (for `.jpg`, `.png`, `.gif`, `.tiff`, …) on top of the ocr flavour. All formats that LiteParse supports work out of the box.

**api** — Identical image to full, but started with a Fastify HTTP server that wraps the LiteParse Node.js API. Exposes `POST /parse`, `POST /batch-parse`, and `GET /health` on port 3000.

**liteparse-ocr-sidecar** — Standalone EasyOCR Python server. Implements LiteParse's [external OCR server protocol](https://developers.llamaindex.ai/liteparse/). Use it alongside any of the above images for higher accuracy OCR compared to bundled Tesseract.js.

---

## Quick start

```bash
# Build the base image
make base

# Parse a PDF
docker run --rm -v "$PWD:/data" liteparse:base parse /data/report.pdf

# Parse and get JSON output
docker run --rm -v "$PWD:/data" liteparse:base parse /data/report.pdf --format json

# Screenshot page 1
docker run --rm -v "$PWD:/data" liteparse:base screenshot /data/report.pdf --target-pages "1" -o /data/screenshots
```

---

## Usage without volume mounts

LiteParse supports reading from **stdin** via `-`, and writes parsed output to **stdout**. This means you can pipe files directly into the container and capture the results — no `-v` volume mount needed.

### Pipe a file in, get text out

```bash
# Redirect a file into the container via stdin
docker run --rm -i liteparse:base parse --no-ocr - < report.pdf

# Same thing using cat + pipe
cat report.pdf | docker run --rm -i liteparse:base parse --no-ocr -
```

> **Note:** The `-i` flag (`--interactive`) is required to keep stdin open.

### Pipe in, get JSON out, save to a file

```bash
docker run --rm -i liteparse:base parse --format json --no-ocr - < report.pdf > report.json
```

### Combine with other tools

```bash
# Parse and extract text items with jq
docker run --rm -i liteparse:base parse --format json --no-ocr - < report.pdf 2>/dev/null \
  | jq '.pages[].textItems[].text'

# Parse a remote PDF without saving it locally
curl -sL https://example.com/report.pdf \
  | docker run --rm -i liteparse:base parse --no-ocr -
```

> **Tip:** LiteParse writes processing logs to stderr. Add `2>/dev/null` to suppress them when piping stdout into other tools.

### When you still need volume mounts

Stdin piping works for **single-file parsing** with text or JSON output. You still need `-v` mounts for:

- **`batch-parse`** — reads from and writes to directories
- **`screenshot`** — writes image files to an output directory
- Processing multiple files in a loop (though you can pipe each one individually)

### Shell alias for seamless usage

To use `lit` as if it were installed locally:

```bash
# Add to your ~/.bashrc or ~/.zshrc
lit() {
  if [ -t 0 ] && [ -n "$1" ] && [ -f "$1" ]; then
    # File argument provided — pipe it via stdin automatically
    local file="$1"; shift
    docker run --rm -i liteparse:base parse "$@" - < "$file"
  elif [ ! -t 0 ]; then
    # Data is being piped in
    docker run --rm -i liteparse:base "$@"
  else
    # No file, no pipe — pass through (e.g. --help, --version)
    docker run --rm liteparse:base "$@"
  fi
}
```

Then use it like a local command:

```bash
lit report.pdf --format json --no-ocr
lit --version
cat scan.pdf | lit parse --format json -
```

---

## Build arguments

All arguments have defaults and can be combined freely.

| Argument | Default | Description |
|---|---|---|
| `NODE_VERSION` | `22` | Node.js major version |
| `LITEPARSE_VERSION` | `latest` | `@llamaindex/liteparse` npm version tag |
| `TESSERACT_LANGS` | `""` | Space- or comma-separated [ISO 639-3](https://en.wikipedia.org/wiki/ISO_639-3) language codes to pre-bake. E.g. `"eng fra deu jpn chi_sim"` |
| `INCLUDE_LIBREOFFICE` | `false` | Install LibreOffice for Office-document conversion |
| `INCLUDE_IMAGEMAGICK` | `false` | Install ImageMagick + Ghostscript for image-file conversion |

### Direct `docker build` examples

```bash
# base
docker build -t liteparse:base .

# ocr – English + French pre-baked
docker build \
  --build-arg TESSERACT_LANGS="eng fra" \
  -t liteparse:ocr .

# full – all formats, English OCR pre-baked
docker build \
  --build-arg TESSERACT_LANGS="eng" \
  --build-arg INCLUDE_LIBREOFFICE=true \
  --build-arg INCLUDE_IMAGEMAGICK=true \
  -t liteparse:full .

# Pin a specific liteparse version on Node 20
docker build \
  --build-arg NODE_VERSION=20 \
  --build-arg LITEPARSE_VERSION=1.3.1 \
  -t liteparse:1.3.1-base .
```

### Container usage

The image entrypoint is `lit`. Pass subcommands and flags directly:

```bash
# Parse
docker run --rm -v "$PWD:/data" liteparse:full parse /data/invoice.docx --format json

# Batch parse a directory
docker run --rm -v "$PWD:/data" liteparse:full batch-parse /data/input /data/output

# Disable OCR (faster, text-native PDFs only)
docker run --rm -v "$PWD:/data" liteparse:base parse /data/report.pdf --no-ocr

# Use a specific OCR language
docker run --rm -v "$PWD:/data" liteparse:ocr parse /data/doc.pdf --ocr-language fra

# Point to an external OCR server
docker run --rm -v "$PWD:/data" \
  liteparse:full parse /data/scan.pdf \
  --ocr-server-url http://localhost:8080
```

---

## Makefile targets

```
make base                        Build base image
make ocr LANGS="eng fra jpn"     Build ocr image (specify languages)
make full LANGS="eng"            Build full image
make api LANGS="eng"             Build api image (alias of full + retag)
make ocr-sidecar                 Build the EasyOCR sidecar image
make all                         Build base + ocr + full + api

make run-base FILE=report.pdf    docker run liteparse:base parse /data/report.pdf
make run-ocr  FILE=scan.pdf LANG=fra
make run-full FILE=invoice.docx
make run-api                     docker compose --profile api up
make run-ocr-sidecar             docker compose --profile ocr-sidecar up

make multi-arch REGISTRY=ghcr.io/yourorg/   buildx push amd64+arm64

make clean                       Remove local liteparse images
make clean-volumes               Remove EasyOCR model volume
make help                        List all targets
```

Overridable variables: `NODE_VERSION`, `VERSION`, `LANGS`, `REGISTRY`, `DOCUMENTS_DIR`, `API_PORT`, `OCR_PORT`.

---

## docker-compose profiles

```bash
# Build and run a specific flavour
docker compose --profile base       build
docker compose --profile ocr        build
docker compose --profile full       build
docker compose --profile api        build
docker compose --profile api        up        # starts REST API on :3000
docker compose --profile ocr-sidecar up       # starts EasyOCR on :8080
```

Environment variables (set in shell or `.env`):

| Variable | Default | Description |
|---|---|---|
| `TESSERACT_LANGS` | `eng` | Languages for ocr/full/api images |
| `LITEPARSE_VERSION` | `latest` | npm version tag |
| `NODE_VERSION` | `22` | Node.js version |
| `REGISTRY` | _(empty)_ | Image registry prefix |
| `DOCUMENTS_DIR` | `$PWD` | Host directory mounted at `/data` |
| `API_PORT` | `3000` | Host port for the REST API |
| `OCR_SIDECAR_PORT` | `8080` | Host port for the EasyOCR sidecar |
| `OCR_SERVER_URL` | _(empty)_ | OCR sidecar URL forwarded to liteparse |
| `OCR_LANGS` | `en` | Languages loaded by EasyOCR sidecar |
| `CUDA_VISIBLE_DEVICES` | _(empty)_ | GPU index for EasyOCR; CPU if unset |

---

## Multi-arch builds

Images are published for `linux/amd64` and `linux/arm64` (Apple Silicon, ARM servers) using Docker Buildx.

```bash
# One-time setup: create a multi-platform builder
docker buildx create --name liteparse-builder --use --bootstrap

# Build and push all flavours
REGISTRY=ghcr.io/yourorg LANGS="eng fra" make multi-arch

# Build a single target
REGISTRY=ghcr.io/yourorg docker buildx bake full --push

# Verify manifests
docker buildx imagetools inspect ghcr.io/yourorg/liteparse:full
```

The `docker-bake.hcl` file defines all targets. Variables (`REGISTRY`, `NODE_VERSION`, `LITEPARSE_VERSION`, `TESSERACT_LANGS`) can be overridden via environment or `--set`.

> **Note:** On Apple Silicon, add `--platform linux/amd64` when building single-arch images locally if you need the amd64 variant for deployment.

---

## REST API server

The `api` flavour starts a [Fastify](https://fastify.dev/) HTTP server bundled inside the full image. For the full endpoint reference with request/response schemas and client examples, see **[`api-server/README.md`](api-server/README.md)**. The [OpenAPI 3.0 spec](api-server/openapi.yaml) is also served at `GET /openapi.yaml`.

### Endpoints

#### `GET /health`
Liveness probe. Returns `{"status": "ok"}`.

#### `POST /parse`
Parse a single document.

**Request:** `multipart/form-data` with a `file` field.

**Query parameters:**

| Parameter | Default | Description |
|---|---|---|
| `format` | `text` | `text` or `json` |
| `ocrLanguage` | `eng` | ISO 639-3 OCR language |
| `noOcr` | `false` | Set `true` to skip OCR |
| `targetPages` | _(all)_ | Page range, e.g. `1-5,10` |
| `dpi` | `150` | Rendering resolution |
| `ocrServerUrl` | _(env)_ | Override OCR sidecar URL |

**Example:**
```bash
curl -F "file=@report.pdf" "http://localhost:3000/parse?format=json&ocrLanguage=eng"
```

#### `POST /batch-parse`
Parse all documents inside a ZIP archive. Returns a ZIP of results.

```bash
# Create a zip of documents
zip documents.zip *.pdf *.docx

# Batch parse
curl -F "file=@documents.zip" "http://localhost:3000/batch-parse?format=json" \
  -o results.zip
```

### Running

```bash
# With docker compose
docker compose --profile api up

# Standalone (requires liteparse:full image built)
docker run --rm \
  --entrypoint node \
  -p 3000:3000 \
  -v "$PWD:/data" \
  -e OCR_SERVER_URL=http://host.docker.internal:8080 \
  liteparse:full /app-src/server.js
```

---

## API documentation

Full API reference with request/response examples, error codes, and client code snippets:

- **[`api-server/README.md`](api-server/README.md)** — complete endpoint reference with curl, Python, and JavaScript examples
- **[`api-server/openapi.yaml`](api-server/openapi.yaml)** — [OpenAPI 3.0](https://www.openapis.org/) specification (importable into Swagger UI, Postman, Redoc, etc.)

The spec is also served by the running API at `GET /openapi.yaml`:

```bash
# Fetch the spec from a running container
curl http://localhost:3000/openapi.yaml

# Import into Swagger Editor for interactive exploration
# Open https://editor.swagger.io and paste the URL or YAML content
```

---

## EasyOCR sidecar

A Python [FastAPI](https://fastapi.tiangolo.com/) server that provides higher-accuracy OCR compared to bundled Tesseract.js. Supports GPU acceleration and a wide range of languages.

### Protocol

LiteParse's external OCR protocol: `POST /ocr` with a `multipart/form-data` image field. Returns a JSON array:

```json
[
  { "text": "Invoice #1042", "bbox": [12, 34, 210, 58], "confidence": 0.9871 }
]
```

### Running

```bash
# Start the sidecar
docker compose --profile ocr-sidecar up

# Test it
curl -F "image=@page.png" http://localhost:8080/ocr | jq .

# Use it with liteparse
docker run --rm -v "$PWD:/data" liteparse:full \
  parse /data/scan.pdf --ocr-server-url http://host.docker.internal:8080
```

### GPU acceleration

```bash
# Enable GPU (set CUDA_VISIBLE_DEVICES in .env or shell)
CUDA_VISIBLE_DEVICES=0 docker compose --profile ocr-sidecar up
```

EasyOCR model files are cached in the `liteparse_easyocr-models` Docker volume and reused across container restarts. Remove the volume with `make clean-volumes` to force a re-download.

### Supported languages

EasyOCR supports 80+ languages. Set `OCR_LANGS` to a comma-separated list of [EasyOCR language codes](https://www.jaided.ai/easyocr/):

```bash
OCR_LANGS=en,fr,de,ja docker compose --profile ocr-sidecar up
```

---

## Testing

The test suite validates each flavour with progressive checks. The same scripts run locally and in CI.

### Running tests locally

```bash
# Test a single flavour (builds it first)
make test-base
make test-ocr
make test-full
make test-api

# Test all flavours
make test

# Or run tests against an already-built image
bash tests/test-flavour.sh base
```

### What the tests check

| Check | base | ocr | full | api |
|---|:---:|:---:|:---:|:---:|
| **Smoke** | | | | |
| Image exists | ✓ | ✓ | ✓ | ✓ |
| `lit --version` | ✓ | ✓ | ✓ | ✓ |
| `lit --help` | ✓ | ✓ | ✓ | ✓ |
| **PDF parsing** | | | | |
| Parse → text (content match) | ✓ | ✓ | ✓ | ✓ |
| Parse → JSON (pages, items, bbox) | ✓ | ✓ | ✓ | ✓ |
| Multi-page PDF (3 pages) | ✓ | ✓ | ✓ | ✓ |
| `--target-pages` page selection | ✓ | ✓ | ✓ | ✓ |
| **OCR** | | | | |
| `.traineddata` files pre-baked | — | ✓ | ✓ | ✓ |
| `eng.traineddata` present | — | ✓ | ✓ | ✓ |
| `TESSDATA_PREFIX` set | — | ✓ | ✓ | ✓ |
| **Multi-format** | | | | |
| LibreOffice installed | — | — | ✓ | ✓ |
| ImageMagick installed | — | — | ✓ | ✓ |
| Parse DOCX → text (content match) | — | — | ✓ | ✓ |
| Parse PNG → exits cleanly | — | — | ✓ | ✓ |
| Parse PNG → valid JSON | — | — | ✓ | ✓ |
| **API server** | | | | |
| `/health` responds `{"status":"ok"}` | — | — | — | ✓ |
| `GET /openapi.yaml` (spec + content-type) | — | — | — | ✓ |
| `POST /parse` text format | — | — | — | ✓ |
| `POST /parse` JSON + bbox fields | — | — | — | ✓ |
| `POST /parse` multipage (3 pages) | — | — | — | ✓ |
| `POST /parse` targetPages filter | — | — | — | ✓ |
| `POST /parse` DOCX file | — | — | — | ✓ |
| `POST /parse` PNG file | — | — | — | ✓ |
| `POST /parse` no file → 400 + error body | — | — | — | ✓ |
| `POST /batch-parse` → ZIP response | — | — | — | ✓ |
| `POST /batch-parse` JSON format | — | — | — | ✓ |
| `POST /batch-parse` no file → 400 | — | — | — | ✓ |
| Unknown route → 404 | — | — | — | ✓ |
| **Security** | | | | |
| Runs as non-root user | ✓ | ✓ | ✓ | ✓ |
| HOME writable | ✓ | ✓ | ✓ | ✓ |
| TMPDIR writable | ✓ | ✓ | ✓ | ✓ |
| NODE_PATH set | ✓ | ✓ | ✓ | ✓ |

### Test fixtures

Fixtures are generated by `tests/generate-fixtures.sh` (wraps `tests/generate-fixtures.js`). Requires Node.js on the host. Generated files are gitignored — they are created on-the-fly before tests run.

| Fixture | Format | Purpose |
|---|---|---|
| `hello.pdf` | PDF | Single page, 3 text lines, includes special characters |
| `multipage.pdf` | PDF | 3 pages, used for page-count and `--target-pages` tests |
| `hello.docx` | DOCX | 3 paragraphs, tests LibreOffice conversion (full/api) |
| `hello.png` | PNG | 200x60 synthetic image, tests ImageMagick pipeline (full/api) |
| `batch.zip` | ZIP | Contains hello.pdf + multipage.pdf, tests `POST /batch-parse` |

First run installs `pdf-lib` and `docx` into `tests/node_modules/` (also gitignored).

---

## CI/CD

Images are hosted on **GitHub Container Registry (GHCR)** — free and unlimited for public repositories, with no pull rate limits.

### Workflows

#### `ci.yml` — Build, test, publish

| Trigger | Builds | Tests | Publishes to GHCR |
|---|:---:|:---:|:---:|
| Pull request | ✓ | ✓ | — |
| Push to `main` | ✓ | ✓ | ✓ (multi-arch) |
| Manual dispatch | ✓ | ✓ | optional |
| Called by upstream-watch | ✓ | ✓ | ✓ |

The build matrix runs all four flavours (base, ocr, full, api) in parallel. The OCR sidecar is built and smoke-tested in a separate job.

Multi-arch images (`linux/amd64` + `linux/arm64`) are pushed only after **all** tests pass. Build layers are cached via GitHub Actions cache (`type=gha`).

#### `upstream-watch.yml` — Auto-detect new LiteParse releases

Runs daily at 06:17 UTC. Queries `registry.npmjs.org` for the latest `@llamaindex/liteparse` version and compares against `.liteparse-version` in the repo.

When a new version is detected:

```
 npm registry  ──→  upstream-watch  ──→  opens PR  ──→  CI runs  ──→  merge  ──→  publish
 (new version)      (daily cron)        (version bump)  (build+test)  (manual/   (multi-arch
                                                         all pass     auto)       to GHCR)
```

1. Creates a `deps/liteparse-<version>` branch with the updated `.liteparse-version`
2. Opens a PR targeting `main`, which triggers CI
3. CI builds and tests all flavours with the new version
4. If all tests pass, the PR can be merged (auto-merge enabled if the repo allows it)
5. Merging to `main` triggers the publish job — only tested images reach GHCR

This guarantees that **no untested version is ever published**.

### Version tracking

The file `.liteparse-version` at the repo root tracks the currently-pinned LiteParse version. CI reads this file to determine which version to build. The upstream-watch workflow updates it via PR.

### Image tags published to GHCR

For version `1.3.1`:

```
ghcr.io/<owner>/liteparse:base
ghcr.io/<owner>/liteparse:1.3.1-base
ghcr.io/<owner>/liteparse:ocr
ghcr.io/<owner>/liteparse:1.3.1-ocr
ghcr.io/<owner>/liteparse:full
ghcr.io/<owner>/liteparse:1.3.1-full
ghcr.io/<owner>/liteparse:latest          (points to full)
ghcr.io/<owner>/liteparse:1.3.1           (points to full)
ghcr.io/<owner>/liteparse:api
ghcr.io/<owner>/liteparse:1.3.1-api
ghcr.io/<owner>/liteparse-ocr-sidecar:latest
```

---

## Architecture decisions

### Single Dockerfile with build args

Rather than maintaining separate Dockerfiles per flavour, a single `Dockerfile` uses `ARG`-guarded `if [ ... ]` shell conditionals inside `RUN` layers. This keeps the build logic in one place and makes it trivial to compose arbitrary combinations of features without combinatorial explosion.

All optional `apt-get install` calls share a single `RUN apt-get update` layer, avoiding the well-known cache-invalidation anti-pattern of splitting update and install across layers.

### Multi-stage build for Tesseract model files

A dedicated `tessdata-downloader` stage (based on `debian:bookworm-slim`) downloads and decompresses Tesseract.js `.traineddata` files from the jsDelivr CDN using `curl`. The final image then `COPY --from=tessdata-downloader`s the results into `/tessdata`.

When `TESSERACT_LANGS=""` (the base flavour), the downloader stage produces an empty directory and the `COPY` is a no-op — the base image pays zero cost for this stage.

This approach keeps build tools (`curl`) out of the final image and isolates all network I/O at build time, so runtime containers can operate fully offline.

### `TESSDATA_PREFIX` as the integration point

LiteParse reads `process.env.TESSDATA_PREFIX` and passes it to Tesseract.js as both `langPath` and `cachePath` with `gzip: false`, meaning it expects plain `.traineddata` files in that directory. Setting `ENV TESSDATA_PREFIX=/tessdata` in the image means:

- **ocr/full/api**: models are in `/tessdata` → zero CDN calls at parse time.
- **base**: `/tessdata` is empty → Tesseract.js falls back to CDN download on first use.

### Debian Bookworm base (not Alpine)

LibreOffice depends on `glibc`. Building it on Alpine's `musl` is impractical. The `node:22-bookworm-slim` base image also satisfies `sharp`'s pre-built native binaries (which target `linux-x64-glibc`), avoiding any native compilation during the build.

### LibreOffice: targeted package selection

Instead of the full `libreoffice` metapackage (which pulls in X11 client libraries, Java, and desktop themes), only the writer, calc, impress, draw, base-core, and nogui packages are installed. This avoids several hundred megabytes of unnecessary dependencies.

Debian's default ImageMagick `policy.xml` blocks PDF operations. A targeted `sed` replacement relaxes the `PDF` coder policy to `read|write` so that LiteParse can use ImageMagick in its conversion pipeline.

### API server bundled, entrypoint overridden

The Fastify REST server (`api-server/`) is included in every image (its footprint is ~15 MB of `node_modules`). The default `ENTRYPOINT ["lit"]` is overridden to `node /app-src/server.js` in the docker-compose `api` profile and in the Makefile `run-api` target.

`NODE_PATH=/usr/local/lib/node_modules` lets the api-server `require('@llamaindex/liteparse')` without re-installing the package, since it is already globally installed by the main `npm install -g` step.

### Multi-arch via buildx bake

`docker-bake.hcl` declares targets for `linux/amd64` and `linux/arm64`. A single `make multi-arch` command builds and pushes all four flavours for both architectures using `docker buildx bake`. The EasyOCR sidecar is also included as a bake target.

---

## Credits

LiteParse is created and maintained by [LlamaIndex](https://www.llamaindex.ai/) (run-llama).

- **Documentation:** https://developers.llamaindex.ai/liteparse/
- **GitHub:** https://github.com/run-llama/liteparse
- **npm package:** [@llamaindex/liteparse](https://www.npmjs.com/package/@llamaindex/liteparse)

This repository contains only Docker packaging. All document parsing functionality is provided by LiteParse under its original license.

**Third-party components used in the sidecar and tooling:**

| Component | Purpose | License |
|---|---|---|
| [EasyOCR](https://github.com/JaidedAI/EasyOCR) | High-accuracy OCR engine | Apache 2.0 |
| [Tesseract.js](https://github.com/naptha/tesseract.js) | Bundled OCR (via liteparse) | Apache 2.0 |
| [LibreOffice](https://www.libreoffice.org/) | Office-document conversion | MPL 2.0 |
| [ImageMagick](https://imagemagick.org/) | Image-file conversion | ImageMagick License |
| [Fastify](https://fastify.dev/) | REST API framework | MIT |
| [FastAPI](https://fastapi.tiangolo.com/) | OCR sidecar framework | MIT |
