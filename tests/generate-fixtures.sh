#!/usr/bin/env bash
# =============================================================================
# Generate test fixture files for LiteParse container tests.
#
# Requires: node (>=18)
# Outputs:  tests/fixtures/hello.pdf
#           tests/fixtures/multipage.pdf
#           tests/fixtures/hello.docx
#           tests/fixtures/hello.png
#           tests/fixtures/batch.zip
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install fixture-generation dependencies (pdf-lib, docx)
if [ ! -d "${SCRIPT_DIR}/node_modules" ]; then
  echo "Installing fixture dependencies..."
  (cd "${SCRIPT_DIR}" && npm install --no-audit --no-fund --silent)
fi

# Generate all fixtures
node "${SCRIPT_DIR}/generate-fixtures.js"
