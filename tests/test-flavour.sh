#!/usr/bin/env bash
# =============================================================================
# Test a LiteParse Docker image flavour.
#
# Usage:
#   ./tests/test-flavour.sh <flavour>
#
# Where <flavour> is one of: base, ocr, full, api
#
# The script expects the image to already be built (e.g. via `make <flavour>`).
# It will also generate test fixtures if they don't exist yet.
#
# Exit code 0 = all tests passed, non-zero = at least one test failed.
# =============================================================================
set -euo pipefail

FLAVOUR="${1:?Usage: $0 <flavour> (base|ocr|full|api)}"
IMAGE="liteparse:${FLAVOUR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# Colours (disabled when not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; BOLD=''; RESET=''
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${RESET} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${RESET} $1: $2"; }

# ---------------------------------------------------------------------------
# Setup: generate fixtures if needed
# ---------------------------------------------------------------------------
if [ ! -f "${FIXTURES_DIR}/hello.pdf" ] || \
   [ ! -f "${FIXTURES_DIR}/multipage.pdf" ] || \
   [ ! -f "${FIXTURES_DIR}/hello.docx" ] || \
   [ ! -f "${FIXTURES_DIR}/hello.png" ] || \
   [ ! -f "${FIXTURES_DIR}/batch.zip" ]; then
  echo "Generating test fixtures..."
  bash "${SCRIPT_DIR}/generate-fixtures.sh"
fi

echo -e "\n${BOLD}Testing flavour: ${FLAVOUR}${RESET}"
echo "Image: ${IMAGE}"
echo "---"

# ---------------------------------------------------------------------------
# 1. Smoke tests: image exists and lit runs
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}[1. Smoke tests]${RESET}"

# Use `docker images -q` instead of `docker image inspect` because Docker
# Desktop with containerd image store can fail inspect on valid images.
if [ -n "$(docker images -q "${IMAGE}" 2>/dev/null)" ]; then
  pass "image exists"
else
  fail "image exists" "image ${IMAGE} not found — run 'make ${FLAVOUR}' first"
  echo -e "\n${RED}Cannot continue without the image. Aborting.${RESET}"
  exit 1
fi

VERSION_OUTPUT=$(docker run --rm "${IMAGE}" --version 2>&1) || true
if echo "${VERSION_OUTPUT}" | grep -qiE '[0-9]+\.[0-9]+'; then
  pass "lit --version (${VERSION_OUTPUT})"
else
  fail "lit --version" "unexpected output: ${VERSION_OUTPUT}"
fi

HELP_OUTPUT=$(docker run --rm "${IMAGE}" --help 2>&1) || true
if echo "${HELP_OUTPUT}" | grep -qi 'parse\|usage\|command'; then
  pass "lit --help"
else
  fail "lit --help" "no recognisable help output"
fi

# ---------------------------------------------------------------------------
# 2. PDF parse tests
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}[2. PDF parse tests]${RESET}"

# --- hello.pdf: text output ---
PARSE_TEXT=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/hello.pdf --no-ocr 2>&1) || true
if echo "${PARSE_TEXT}" | grep -q "Hello LiteParse"; then
  pass "parse hello.pdf → text contains 'Hello LiteParse'"
else
  fail "parse hello.pdf (text)" "expected 'Hello LiteParse', got: $(echo "${PARSE_TEXT}" | head -5)"
fi

# --- hello.pdf: second line ---
if echo "${PARSE_TEXT}" | grep -q "test document"; then
  pass "parse hello.pdf → text contains 'test document'"
else
  fail "parse hello.pdf (second line)" "expected 'test document' in output"
fi

# --- hello.pdf: JSON output ---
PARSE_JSON=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/hello.pdf --no-ocr --format json 2>&1) || true
if echo "${PARSE_JSON}" | grep -q '"pages"'; then
  pass "parse hello.pdf --format json → has 'pages' key"
else
  fail "parse hello.pdf (json)" "expected JSON with 'pages', got: $(echo "${PARSE_JSON}" | head -5)"
fi

# --- hello.pdf: JSON contains text items ---
if echo "${PARSE_JSON}" | grep -q '"text"'; then
  pass "parse hello.pdf --format json → has 'text' items"
else
  fail "parse hello.pdf (json items)" "no 'text' items in JSON output"
fi

# --- hello.pdf: JSON has bounding box fields ---
if echo "${PARSE_JSON}" | grep -qE '"x"|"y"|"width"|"height"'; then
  pass "parse hello.pdf --format json → has bounding box fields"
else
  fail "parse hello.pdf (bbox)" "no bounding box fields in JSON output"
fi

# --- hello.pdf: JSON page count = 1 ---
PAGE_COUNT=$(echo "${PARSE_JSON}" | grep -o '"page"' | wc -l | tr -d ' ')
if [ "${PAGE_COUNT}" = "1" ]; then
  pass "parse hello.pdf → JSON has exactly 1 page"
else
  fail "parse hello.pdf (page count)" "expected 1 page, got ${PAGE_COUNT}"
fi

# --- multipage.pdf: text output ---
MP_TEXT=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/multipage.pdf --no-ocr 2>&1) || true
if echo "${MP_TEXT}" | grep -q "Page 1 of 3" && echo "${MP_TEXT}" | grep -q "Page 3 of 3"; then
  pass "parse multipage.pdf → text contains pages 1 and 3"
else
  fail "parse multipage.pdf (text)" "expected 'Page 1 of 3' and 'Page 3 of 3'"
fi

# --- multipage.pdf: JSON page count = 3 ---
MP_JSON=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/multipage.pdf --no-ocr --format json 2>&1) || true
MP_PAGE_COUNT=$(echo "${MP_JSON}" | grep -o '"page"' | wc -l | tr -d ' ')
if [ "${MP_PAGE_COUNT}" = "3" ]; then
  pass "parse multipage.pdf → JSON has exactly 3 pages"
else
  fail "parse multipage.pdf (page count)" "expected 3, got ${MP_PAGE_COUNT}"
fi

# --- multipage.pdf: targetPages selects subset ---
TP_JSON=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/multipage.pdf --no-ocr --format json --target-pages "1,3" 2>&1) || true
if echo "${TP_JSON}" | grep -q "Page 1 of 3" && echo "${TP_JSON}" | grep -q "Page 3 of 3"; then
  pass "parse multipage.pdf --target-pages '1,3' → contains pages 1 and 3"
else
  fail "parse multipage.pdf (target-pages)" "expected pages 1 and 3 in output"
fi

# ---------------------------------------------------------------------------
# 3. OCR tests (ocr, full, api flavours)
# ---------------------------------------------------------------------------
if [[ "${FLAVOUR}" == "ocr" || "${FLAVOUR}" == "full" || "${FLAVOUR}" == "api" ]]; then
  echo -e "\n${BOLD}[3. OCR tests]${RESET}"

  # --- tessdata files pre-baked ---
  TESSDATA_FILES=$(docker run --rm --entrypoint ls "${IMAGE}" /tessdata/ 2>&1) || true
  if echo "${TESSDATA_FILES}" | grep -q '\.traineddata'; then
    pass "tessdata pre-baked (found .traineddata files in /tessdata/)"
  else
    fail "tessdata pre-baked" "no .traineddata files in /tessdata/"
  fi

  # --- TESSDATA_PREFIX env var ---
  TESSDATA_PREFIX_VAL=$(docker run --rm --entrypoint sh "${IMAGE}" -c 'echo $TESSDATA_PREFIX' 2>&1) || true
  if [ "${TESSDATA_PREFIX_VAL}" = "/tessdata" ]; then
    pass "TESSDATA_PREFIX=/tessdata"
  else
    fail "TESSDATA_PREFIX" "expected '/tessdata', got '${TESSDATA_PREFIX_VAL}'"
  fi

  # --- eng.traineddata exists specifically ---
  if echo "${TESSDATA_FILES}" | grep -q 'eng\.traineddata'; then
    pass "eng.traineddata present"
  else
    fail "eng.traineddata" "English model not found in /tessdata/"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Multi-format tests (full, api flavours)
# ---------------------------------------------------------------------------
if [[ "${FLAVOUR}" == "full" || "${FLAVOUR}" == "api" ]]; then
  echo -e "\n${BOLD}[4. Multi-format tests]${RESET}"

  # --- LibreOffice installed ---
  SOFFICE_CHECK=$(docker run --rm --entrypoint sh "${IMAGE}" -c 'which soffice 2>/dev/null && soffice --version 2>&1 || echo "NOT_FOUND"') || true
  if echo "${SOFFICE_CHECK}" | grep -qi 'libreoffice'; then
    pass "soffice installed ($(echo "${SOFFICE_CHECK}" | tail -1))"
  else
    fail "soffice installed" "LibreOffice not found"
  fi

  # --- ImageMagick installed ---
  CONVERT_CHECK=$(docker run --rm --entrypoint sh "${IMAGE}" -c 'which convert 2>/dev/null && convert --version 2>&1 | head -1 || echo "NOT_FOUND"') || true
  if echo "${CONVERT_CHECK}" | grep -qi 'imagemagick'; then
    pass "convert installed ($(echo "${CONVERT_CHECK}" | tail -1))"
  else
    fail "convert installed" "ImageMagick not found"
  fi

  # --- Parse DOCX ---
  DOCX_TEXT=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/hello.docx --no-ocr 2>&1) || true
  if echo "${DOCX_TEXT}" | grep -q "Hello LiteParse"; then
    pass "parse hello.docx → text contains 'Hello LiteParse'"
  else
    fail "parse hello.docx" "expected 'Hello LiteParse', got: $(echo "${DOCX_TEXT}" | head -5)"
  fi

  # --- Parse DOCX: secondary content ---
  if echo "${DOCX_TEXT}" | grep -q "multi-format support"; then
    pass "parse hello.docx → text contains 'multi-format support'"
  else
    fail "parse hello.docx (secondary)" "expected 'multi-format support' in output"
  fi

  # --- Parse PNG (image processing test) ---
  # The PNG is a programmatic image without real text, so we just verify
  # that LiteParse processes it without crashing and produces some output.
  PNG_EXIT=0
  PNG_OUTPUT=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/hello.png --no-ocr 2>&1) || PNG_EXIT=$?
  if [ "${PNG_EXIT}" -eq 0 ]; then
    pass "parse hello.png → exits cleanly (code 0)"
  else
    fail "parse hello.png" "non-zero exit code ${PNG_EXIT}: $(echo "${PNG_OUTPUT}" | head -3)"
  fi

  # --- Parse PNG: JSON format ---
  PNG_JSON_EXIT=0
  PNG_JSON=$(docker run --rm -v "${FIXTURES_DIR}:/data:ro" "${IMAGE}" parse /data/hello.png --no-ocr --format json 2>&1) || PNG_JSON_EXIT=$?
  if [ "${PNG_JSON_EXIT}" -eq 0 ] && echo "${PNG_JSON}" | grep -q '"pages"'; then
    pass "parse hello.png --format json → valid JSON with 'pages'"
  else
    fail "parse hello.png (json)" "exit=${PNG_JSON_EXIT}, output: $(echo "${PNG_JSON}" | head -3)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. API server tests (api flavour only)
# ---------------------------------------------------------------------------
if [[ "${FLAVOUR}" == "api" ]]; then
  echo -e "\n${BOLD}[5. API server tests]${RESET}"

  CONTAINER_NAME="liteparse-api-test-$$"
  API_PORT=13000
  API_BASE="http://localhost:${API_PORT}"

  # Start the API server in background
  docker run --rm -d \
    --name "${CONTAINER_NAME}" \
    --entrypoint node \
    -p "${API_PORT}:3000" \
    -v "${FIXTURES_DIR}:/data:ro" \
    "${IMAGE}" /app-src/server.js &>/dev/null

  # Wait for the server to be ready (up to 30s)
  READY=false
  for i in $(seq 1 30); do
    if curl -sf "${API_BASE}/health" &>/dev/null; then
      READY=true
      break
    fi
    sleep 1
  done

  if ! ${READY}; then
    fail "API server startup" "server did not respond within 30s"
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -10 || true
    docker stop "${CONTAINER_NAME}" &>/dev/null 2>&1 || true
  else
    pass "API server starts and /health responds"

    # --- GET /health: response body ---
    HEALTH_BODY=$(curl -sf "${API_BASE}/health" 2>&1) || true
    if echo "${HEALTH_BODY}" | grep -q '"ok"'; then
      pass "GET /health → {\"status\":\"ok\"}"
    else
      fail "GET /health body" "unexpected: ${HEALTH_BODY}"
    fi

    # --- GET /openapi.yaml ---
    SPEC_RESPONSE=$(curl -sf "${API_BASE}/openapi.yaml" 2>&1) || true
    if echo "${SPEC_RESPONSE}" | grep -q "openapi:"; then
      pass "GET /openapi.yaml → returns OpenAPI spec"
    else
      fail "GET /openapi.yaml" "expected spec, got: $(echo "${SPEC_RESPONSE}" | head -3)"
    fi

    # --- GET /openapi.yaml: content type ---
    SPEC_CT=$(curl -sf -o /dev/null -w '%{content_type}' "${API_BASE}/openapi.yaml" 2>&1) || true
    if echo "${SPEC_CT}" | grep -qi 'yaml'; then
      pass "GET /openapi.yaml → Content-Type contains 'yaml'"
    else
      fail "GET /openapi.yaml Content-Type" "expected yaml, got: ${SPEC_CT}"
    fi

    # --- GET /openapi.yaml: has endpoint definitions ---
    if echo "${SPEC_RESPONSE}" | grep -q '/parse:' && echo "${SPEC_RESPONSE}" | grep -q '/batch-parse:'; then
      pass "GET /openapi.yaml → contains /parse and /batch-parse paths"
    else
      fail "GET /openapi.yaml paths" "missing /parse or /batch-parse in spec"
    fi

    # --- POST /parse: text format ---
    PARSE_TEXT_API=$(curl -sf -F "file=@${FIXTURES_DIR}/hello.pdf" \
      "${API_BASE}/parse?noOcr=true" 2>&1) || true
    if echo "${PARSE_TEXT_API}" | grep -q "Hello LiteParse"; then
      pass "POST /parse (text) → contains 'Hello LiteParse'"
    else
      fail "POST /parse (text)" "expected 'Hello LiteParse', got: $(echo "${PARSE_TEXT_API}" | head -3)"
    fi

    # --- POST /parse: json format ---
    PARSE_JSON_API=$(curl -sf -F "file=@${FIXTURES_DIR}/hello.pdf" \
      "${API_BASE}/parse?format=json&noOcr=true" 2>&1) || true
    if echo "${PARSE_JSON_API}" | grep -q '"pages"'; then
      pass "POST /parse (json) → has 'pages' key"
    else
      fail "POST /parse (json)" "expected JSON with 'pages', got: $(echo "${PARSE_JSON_API}" | head -3)"
    fi

    # --- POST /parse: json has bounding boxes ---
    if echo "${PARSE_JSON_API}" | grep -qE '"x"|"y"|"width"|"height"'; then
      pass "POST /parse (json) → has bounding box fields"
    else
      fail "POST /parse (json bbox)" "no bounding box fields in response"
    fi

    # --- POST /parse: json content matches ---
    if echo "${PARSE_JSON_API}" | grep -q "Hello LiteParse"; then
      pass "POST /parse (json) → text content matches 'Hello LiteParse'"
    else
      fail "POST /parse (json content)" "expected 'Hello LiteParse' in JSON response"
    fi

    # --- POST /parse: multipage PDF ---
    MP_PARSE_JSON=$(curl -sf -F "file=@${FIXTURES_DIR}/multipage.pdf" \
      "${API_BASE}/parse?format=json&noOcr=true" 2>&1) || true
    MP_API_PAGES=$(echo "${MP_PARSE_JSON}" | grep -o '"page"' | wc -l | tr -d ' ')
    if [ "${MP_API_PAGES}" = "3" ]; then
      pass "POST /parse multipage.pdf → 3 pages"
    else
      fail "POST /parse multipage" "expected 3 pages, got ${MP_API_PAGES}"
    fi

    # --- POST /parse: targetPages ---
    TP_PARSE_JSON=$(curl -sf -F "file=@${FIXTURES_DIR}/multipage.pdf" \
      "${API_BASE}/parse?format=json&noOcr=true&targetPages=2" 2>&1) || true
    if echo "${TP_PARSE_JSON}" | grep -q "Page 2 of 3"; then
      pass "POST /parse targetPages=2 → contains 'Page 2 of 3'"
    else
      fail "POST /parse targetPages" "expected 'Page 2 of 3' in output"
    fi

    # --- POST /parse: DOCX file ---
    DOCX_PARSE=$(curl -sf -F "file=@${FIXTURES_DIR}/hello.docx" \
      "${API_BASE}/parse?noOcr=true" 2>&1) || true
    if echo "${DOCX_PARSE}" | grep -q "Hello LiteParse"; then
      pass "POST /parse hello.docx → contains 'Hello LiteParse'"
    else
      fail "POST /parse hello.docx" "expected 'Hello LiteParse', got: $(echo "${DOCX_PARSE}" | head -3)"
    fi

    # --- POST /parse: PNG file ---
    PNG_PARSE_EXIT=0
    PNG_PARSE=$(curl -sf -o /dev/null -w '%{http_code}' -F "file=@${FIXTURES_DIR}/hello.png" \
      "${API_BASE}/parse?noOcr=true" 2>&1) || PNG_PARSE_EXIT=$?
    if [ "${PNG_PARSE}" = "200" ]; then
      pass "POST /parse hello.png → HTTP 200"
    else
      fail "POST /parse hello.png" "expected 200, got HTTP ${PNG_PARSE} (exit ${PNG_PARSE_EXIT})"
    fi

    # --- POST /parse: error on missing file ---
    # Sending without multipart Content-Type returns 406 from Fastify's
    # multipart plugin. Sending multipart with no file field returns 400
    # from our handler. Both are valid "no file" rejections.
    ERR_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_BASE}/parse" 2>&1) || true
    if [ "${ERR_STATUS}" = "400" ] || [ "${ERR_STATUS}" = "406" ]; then
      pass "POST /parse (no body) → HTTP ${ERR_STATUS}"
    else
      fail "POST /parse (no body)" "expected 400 or 406, got ${ERR_STATUS}"
    fi

    # --- POST /parse: multipart with no file field → 400 ---
    ERR_MULTIPART_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
      -F "notafile=hello" "${API_BASE}/parse" 2>&1) || true
    ERR_MULTIPART_BODY=$(curl -s -F "notafile=hello" "${API_BASE}/parse" 2>&1) || true
    if [ "${ERR_MULTIPART_STATUS}" = "400" ]; then
      pass "POST /parse (no file field) → HTTP 400"
    else
      fail "POST /parse (no file field)" "expected 400, got ${ERR_MULTIPART_STATUS}"
    fi

    if echo "${ERR_MULTIPART_BODY}" | grep -q '"error"'; then
      pass "POST /parse (no file field) → response has 'error' field"
    else
      fail "POST /parse (no file field body)" "expected 'error' field in response"
    fi

    # --- POST /batch-parse: returns ZIP ---
    BATCH_STATUS=$(curl -sf -o /tmp/liteparse-batch-result-$$.zip -w '%{http_code}' \
      -F "file=@${FIXTURES_DIR}/batch.zip" "${API_BASE}/batch-parse?noOcr=true" 2>&1) || true
    if [ "${BATCH_STATUS}" = "200" ]; then
      pass "POST /batch-parse → HTTP 200"
    else
      fail "POST /batch-parse" "expected 200, got ${BATCH_STATUS}"
    fi

    # --- POST /batch-parse: response Content-Type ---
    BATCH_CT=$(curl -sf -o /dev/null -w '%{content_type}' \
      -F "file=@${FIXTURES_DIR}/batch.zip" "${API_BASE}/batch-parse?noOcr=true" 2>&1) || true
    if echo "${BATCH_CT}" | grep -qi 'zip'; then
      pass "POST /batch-parse → Content-Type contains 'zip'"
    else
      fail "POST /batch-parse Content-Type" "expected zip, got: ${BATCH_CT}"
    fi

    # --- POST /batch-parse: result ZIP contains expected files ---
    if [ -f "/tmp/liteparse-batch-result-$$.zip" ]; then
      BATCH_FILES=$(unzip -l "/tmp/liteparse-batch-result-$$.zip" 2>/dev/null | grep -c '\.txt\|\.json' || true)
      if [ "${BATCH_FILES}" -ge 2 ]; then
        pass "POST /batch-parse → result ZIP contains ${BATCH_FILES} output files"
      else
        fail "POST /batch-parse (contents)" "expected ≥2 output files, found ${BATCH_FILES}"
      fi
      rm -f "/tmp/liteparse-batch-result-$$.zip"
    fi

    # --- POST /batch-parse: json format ---
    BATCH_JSON_STATUS=$(curl -sf -o /tmp/liteparse-batch-json-$$.zip -w '%{http_code}' \
      -F "file=@${FIXTURES_DIR}/batch.zip" "${API_BASE}/batch-parse?format=json&noOcr=true" 2>&1) || true
    if [ "${BATCH_JSON_STATUS}" = "200" ]; then
      BATCH_JSON_FILES=$(unzip -l "/tmp/liteparse-batch-json-$$.zip" 2>/dev/null | grep -c '\.json' || true)
      if [ "${BATCH_JSON_FILES}" -ge 2 ]; then
        pass "POST /batch-parse format=json → result ZIP contains ${BATCH_JSON_FILES} JSON files"
      else
        fail "POST /batch-parse json (contents)" "expected ≥2 .json files, found ${BATCH_JSON_FILES}"
      fi
    else
      fail "POST /batch-parse json" "expected 200, got ${BATCH_JSON_STATUS}"
    fi
    rm -f "/tmp/liteparse-batch-json-$$.zip"

    # --- POST /batch-parse: error on missing file ---
    BATCH_ERR_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_BASE}/batch-parse" 2>&1) || true
    if [ "${BATCH_ERR_STATUS}" = "400" ] || [ "${BATCH_ERR_STATUS}" = "406" ]; then
      pass "POST /batch-parse (no body) → HTTP ${BATCH_ERR_STATUS}"
    else
      fail "POST /batch-parse (no body)" "expected 400 or 406, got ${BATCH_ERR_STATUS}"
    fi

    # --- GET unknown route → 404 ---
    NOT_FOUND_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE}/nonexistent" 2>&1) || true
    if [ "${NOT_FOUND_STATUS}" = "404" ]; then
      pass "GET /nonexistent → HTTP 404"
    else
      fail "GET /nonexistent" "expected 404, got ${NOT_FOUND_STATUS}"
    fi

    # Cleanup
    docker stop "${CONTAINER_NAME}" &>/dev/null 2>&1 || true
  fi
fi

# ---------------------------------------------------------------------------
# 6. Security tests
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}[6. Security tests]${RESET}"

WHOAMI=$(docker run --rm --entrypoint whoami "${IMAGE}" 2>&1) || true
if [ "${WHOAMI}" = "liteparse" ]; then
  pass "runs as non-root user (liteparse)"
else
  fail "non-root user" "expected 'liteparse', got '${WHOAMI}'"
fi

# --- HOME is writable ---
HOME_WRITABLE=$(docker run --rm --entrypoint sh "${IMAGE}" -c 'touch $HOME/.test && echo "writable" || echo "readonly"' 2>&1) || true
if [ "${HOME_WRITABLE}" = "writable" ]; then
  pass "HOME directory is writable"
else
  fail "HOME writable" "HOME directory is not writable"
fi

# --- TMPDIR is writable ---
TMPDIR_WRITABLE=$(docker run --rm --entrypoint sh "${IMAGE}" -c 'touch $TMPDIR/.test && echo "writable" || echo "readonly"' 2>&1) || true
if [ "${TMPDIR_WRITABLE}" = "writable" ]; then
  pass "TMPDIR is writable"
else
  fail "TMPDIR writable" "TMPDIR is not writable"
fi

# --- NODE_PATH is set ---
NODE_PATH_VAL=$(docker run --rm --entrypoint sh "${IMAGE}" -c 'echo $NODE_PATH' 2>&1) || true
if echo "${NODE_PATH_VAL}" | grep -q 'node_modules'; then
  pass "NODE_PATH set (${NODE_PATH_VAL})"
else
  fail "NODE_PATH" "expected path containing 'node_modules', got '${NODE_PATH_VAL}'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
echo -e "\n---"
echo -e "${BOLD}Results (${FLAVOUR}):${RESET} ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}, ${TOTAL} total"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
