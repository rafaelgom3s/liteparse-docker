# LiteParse API Reference

The `liteparse:api` Docker image bundles a [Fastify](https://fastify.dev/) HTTP server that wraps the LiteParse Node.js library. It exposes document parsing over HTTP, suitable for microservice architectures and tool integrations.

**Base URL:** `http://localhost:3000` (configurable via `PORT` env var)

**OpenAPI spec:** Available at [`GET /openapi.yaml`](#get-openapiyaml) when the server is running, and as a static file at [`api-server/openapi.yaml`](openapi.yaml) in this repository.

---

## Table of contents

- [Starting the server](#starting-the-server)
- [Endpoints](#endpoints)
  - [GET /health](#get-health)
  - [GET /openapi.yaml](#get-openapiyaml)
  - [POST /parse](#post-parse)
  - [POST /batch-parse](#post-batch-parse)
- [Query parameters](#query-parameters)
- [Response formats](#response-formats)
- [Error handling](#error-handling)
- [Environment variables](#environment-variables)
- [Examples](#examples)

---

## Starting the server

```bash
# Using docker compose (recommended)
docker compose --profile api up

# Using docker run
docker run --rm -p 3000:3000 \
  --entrypoint node \
  -v "$PWD:/data" \
  liteparse:api /app-src/server.js

# Using make
make run-api
```

---

## Endpoints

### `GET /health`

Liveness probe. Use for Docker health checks, Kubernetes probes, or load balancer checks.

**Request:**

```bash
curl http://localhost:3000/health
```

**Response:** `200 OK`

```json
{
  "status": "ok"
}
```

---

### `GET /openapi.yaml`

Returns the OpenAPI 3.0 specification for this API as YAML. Compatible with Swagger UI, Postman, and other OpenAPI tooling.

**Request:**

```bash
curl http://localhost:3000/openapi.yaml
```

**Response:** `200 OK` — `text/yaml`

```yaml
openapi: 3.0.3
info:
  title: LiteParse API
  ...
```

---

### `POST /parse`

Parse a single uploaded document and return the extracted text or structured JSON.

**Content-Type:** `multipart/form-data`

**Form fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `file` | binary | yes | The document file to parse. Max 500 MB. |

**Query parameters:** See [Query parameters](#query-parameters).

#### Example: plain text output

```bash
curl -F "file=@report.pdf" http://localhost:3000/parse
```

**Response:** `200 OK` — `text/plain; charset=utf-8`

```
Quarterly Report — Q4 2025

Revenue increased by 12% year-over-year, driven primarily by
expansion in the APAC region...
```

#### Example: JSON output with bounding boxes

```bash
curl -F "file=@report.pdf" "http://localhost:3000/parse?format=json"
```

**Response:** `200 OK` — `application/json`

```json
{
  "pages": [
    {
      "page": 1,
      "width": 612,
      "height": 792,
      "items": [
        {
          "text": "Quarterly Report — Q4 2025",
          "x": 72,
          "y": 48,
          "width": 350.5,
          "height": 24
        },
        {
          "text": "Revenue increased by 12% year-over-year...",
          "x": 72,
          "y": 96,
          "width": 468,
          "height": 14
        }
      ]
    }
  ]
}
```

#### Example: parse specific pages with OCR

```bash
curl -F "file=@scanned-document.pdf" \
  "http://localhost:3000/parse?format=json&targetPages=1-3&ocrLanguage=fra&dpi=300"
```

#### Example: parse a DOCX file (requires `full` or `api` image)

```bash
curl -F "file=@proposal.docx" "http://localhost:3000/parse?format=json"
```

#### Example: use an external OCR server

```bash
curl -F "file=@scan.pdf" \
  "http://localhost:3000/parse?ocrServerUrl=http://ocr-sidecar:8080"
```

#### Error: no file uploaded

```bash
curl -X POST http://localhost:3000/parse
```

**Response:** `400 Bad Request`

```json
{
  "error": "No file uploaded. Send a multipart/form-data request with a \"file\" field."
}
```

---

### `POST /batch-parse`

Parse all documents inside an uploaded ZIP archive. Returns a ZIP archive containing one output file per input document.

**Content-Type:** `multipart/form-data`

**Form fields:**

| Field | Type | Required | Description |
|---|---|---|---|
| `file` | binary | yes | A ZIP archive containing documents to parse. Max 500 MB. |

**Query parameters:** See [Query parameters](#query-parameters). Parameters apply to all documents in the batch.

**Output ZIP structure:**

- `<original-name>.txt` or `<original-name>.json` — parsed result per document
- `<original-name>.error.txt` — error message for documents that failed to parse

Failed documents do **not** abort the batch. An error file is included in the output instead.

#### Example: batch parse PDFs as text

```bash
# Create a ZIP of documents
zip documents.zip report.pdf invoice.pdf memo.pdf

# Batch parse
curl -F "file=@documents.zip" http://localhost:3000/batch-parse -o results.zip

# Inspect results
unzip -l results.zip
# Archive:  results.zip
#   Length      Date    Time    Name
# ---------  ---------- -----   ----
#      1842  2026-03-27 12:00   report.pdf.txt
#       923  2026-03-27 12:00   invoice.pdf.txt
#      2105  2026-03-27 12:00   memo.pdf.txt
```

#### Example: batch parse as JSON

```bash
curl -F "file=@documents.zip" "http://localhost:3000/batch-parse?format=json" -o results.zip

unzip -l results.zip
# Archive:  results.zip
#   Length      Date    Time    Name
# ---------  ---------- -----   ----
#     12045  2026-03-27 12:00   report.pdf.json
#      5821  2026-03-27 12:00   invoice.pdf.json
#     15332  2026-03-27 12:00   memo.pdf.json
```

#### Example: batch with mixed success

If the ZIP contains an unsupported file alongside valid PDFs:

```bash
unzip -l results.zip
# report.pdf.txt
# broken-file.xyz.error.txt      ← error message, not a parse result
# invoice.pdf.txt
```

---

## Query parameters

All query parameters apply to both `POST /parse` and `POST /batch-parse`.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `format` | `text` \| `json` | `text` | Output format. `text` returns plain extracted text. `json` returns structured data with bounding boxes and page-level items. |
| `ocrLanguage` | string | `eng` | ISO 639-3 language code for OCR processing. Used when scanned images are detected. See [language codes](#common-ocr-language-codes). |
| `noOcr` | `true` \| `false` | `false` | Skip OCR entirely. Faster for text-native PDFs without scanned images. |
| `targetPages` | string | _(all)_ | Page range to parse. Comma-separated pages and ranges: `1`, `1-5`, `1-3,7,10-12`. |
| `dpi` | integer | `150` | Rendering resolution in DPI (72–600). Higher values improve OCR accuracy but increase processing time and memory usage. |
| `ocrServerUrl` | string (URL) | _(env)_ | URL of an external OCR server. Overrides the `OCR_SERVER_URL` environment variable for this request. |

### Common OCR language codes

| Code | Language |
|---|---|
| `eng` | English |
| `fra` | French |
| `deu` | German |
| `spa` | Spanish |
| `ita` | Italian |
| `por` | Portuguese |
| `jpn` | Japanese |
| `kor` | Korean |
| `chi_sim` | Chinese (Simplified) |
| `chi_tra` | Chinese (Traditional) |
| `ara` | Arabic |
| `hin` | Hindi |
| `rus` | Russian |

Full list: [Tesseract language codes](https://tesseract-ocr.github.io/tessdoc/Data-Files-in-different-versions.html)

---

## Response formats

### Text format (`format=text`)

**Content-Type:** `text/plain; charset=utf-8`

Returns the full document text as a single string. Pages are separated by newlines. No structural metadata is included.

### JSON format (`format=json`)

**Content-Type:** `application/json`

Returns structured data with page-level items, each containing text and bounding box coordinates.

**Schema:**

```
{
  "pages": [
    {
      "page": <int>,        // 1-based page number
      "width": <float>,     // page width in PDF points (1pt = 1/72 inch)
      "height": <float>,    // page height in PDF points
      "items": [
        {
          "text": <string>,  // extracted text
          "x": <float>,     // left offset (PDF points, origin top-left)
          "y": <float>,     // top offset (PDF points, origin top-left)
          "width": <float>, // bounding box width
          "height": <float> // bounding box height
        }
      ]
    }
  ]
}
```

**Coordinate system:**
- Origin: top-left corner of the page
- Units: PDF points (1 point = 1/72 inch)
- To convert to pixels: `pixel = point * (DPI / 72)`

---

## Error handling

The API uses standard HTTP status codes.

| Code | Meaning | When |
|---|---|---|
| `200` | Success | Document parsed successfully |
| `400` | Bad Request | No file uploaded, or invalid request body |
| `500` | Internal Server Error | Parse failure, unsupported format, or server error |

Error responses are always JSON:

```json
{
  "error": "Human-readable error message describing what went wrong."
}
```

For `POST /batch-parse`, individual document failures do **not** return an error status. Instead, the response ZIP includes `<filename>.error.txt` files for each failed document while still returning `200` for the batch overall.

---

## Environment variables

These variables configure the server at startup.

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | HTTP port to listen on |
| `OCR_SERVER_URL` | _(unset)_ | Default external OCR server URL. Can be overridden per-request via the `ocrServerUrl` query parameter. Set this when running alongside the EasyOCR sidecar. |
| `TESSDATA_PREFIX` | `/tessdata` | Directory containing pre-baked Tesseract `.traineddata` files. Set automatically in Docker images. |
| `HOME` | `/home/liteparse` | Home directory. LibreOffice writes its user profile here. |
| `TMPDIR` | `/tmp/liteparse` | Scratch directory for temporary file conversions. |
| `NODE_PATH` | `/usr/local/lib/node_modules` | Allows the API server to find the globally-installed `@llamaindex/liteparse` package. |

---

## Examples

### Parse a PDF and pipe to jq

```bash
curl -sF "file=@report.pdf" "http://localhost:3000/parse?format=json" | jq '.pages[0].items[:3]'
```

### Parse and save output to a file

```bash
curl -sF "file=@report.pdf" http://localhost:3000/parse -o report.txt
```

### Parse with the EasyOCR sidecar

```bash
# Start the full stack
docker compose --profile api up -d

# Parse using the sidecar for OCR (auto-configured via OCR_SERVER_URL)
curl -F "file=@scanned.pdf" "http://localhost:3000/parse?format=json"
```

### Batch parse with wget

```bash
wget --post-file=documents.zip \
  --header="Content-Type: multipart/form-data; boundary=---" \
  "http://localhost:3000/batch-parse" -O results.zip
```

### Python (requests)

```python
import requests

# Single file
with open("report.pdf", "rb") as f:
    resp = requests.post(
        "http://localhost:3000/parse",
        files={"file": ("report.pdf", f, "application/pdf")},
        params={"format": "json", "noOcr": "true"},
    )
    result = resp.json()
    for page in result["pages"]:
        for item in page["items"]:
            print(f"[{item['x']:.0f},{item['y']:.0f}] {item['text']}")
```

### JavaScript (fetch)

```javascript
const form = new FormData();
form.append('file', fs.createReadStream('report.pdf'));

const res = await fetch('http://localhost:3000/parse?format=json', {
  method: 'POST',
  body: form,
});
const { pages } = await res.json();
console.log(`Parsed ${pages.length} pages`);
```

### Health check in a script

```bash
if curl -sf http://localhost:3000/health > /dev/null; then
  echo "LiteParse API is ready"
else
  echo "LiteParse API is not responding"
  exit 1
fi
```
