"""
LiteParse OCR Sidecar – EasyOCR HTTP server

Implements the LiteParse external OCR server protocol:
  POST /ocr  multipart/form-data with an "image" file field
             Returns JSON: {"text": str, "bbox": [x1, y1, x2, y2], "confidence": float}

Also provides:
  GET /health  liveness probe → {"status": "ok"}
"""

from __future__ import annotations

import io
import logging
import os
from contextlib import asynccontextmanager
from typing import Any

import easyocr
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from PIL import Image

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ocr-server")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("PORT", "8080"))

# Comma-separated EasyOCR language codes, e.g. "en,fr,de"
_raw_langs = os.environ.get("OCR_LANGS", "en")
OCR_LANGS: list[str] = [lang.strip() for lang in _raw_langs.split(",") if lang.strip()]

# GPU: set CUDA_VISIBLE_DEVICES to a device index to enable; empty → CPU
_cuda = os.environ.get("CUDA_VISIBLE_DEVICES", "")
USE_GPU = bool(_cuda)

# ---------------------------------------------------------------------------
# Application lifespan – load EasyOCR reader once at startup
# ---------------------------------------------------------------------------

reader: easyocr.Reader | None = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global reader
    logger.info("Loading EasyOCR model for languages: %s (GPU=%s)", OCR_LANGS, USE_GPU)
    reader = easyocr.Reader(OCR_LANGS, gpu=USE_GPU)
    logger.info("EasyOCR model ready.")
    yield
    reader = None


app = FastAPI(title="LiteParse OCR Sidecar", lifespan=lifespan)

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/ocr")
async def ocr(image: UploadFile = File(...)) -> JSONResponse:
    """
    Accept an image file and return OCR results compatible with LiteParse's
    external OCR server protocol.

    LiteParse expects each result item to have:
      - text:       recognized string
      - bbox:       [x1, y1, x2, y2]  (top-left, bottom-right pixel coords)
      - confidence: float 0.0–1.0
    """
    if reader is None:
        raise HTTPException(status_code=503, detail="OCR reader not initialized")

    raw = await image.read()
    try:
        pil_image = Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Cannot decode image: {exc}") from exc

    # EasyOCR returns: list of ([tl, tr, br, bl], text, confidence)
    # where each corner is [x, y].
    results: list[Any] = reader.readtext(pil_image)  # type: ignore[arg-type]

    items = []
    for corners, text, confidence in results:
        xs = [pt[0] for pt in corners]
        ys = [pt[1] for pt in corners]
        bbox = [min(xs), min(ys), max(xs), max(ys)]  # [x1, y1, x2, y2]
        items.append({"text": text, "bbox": bbox, "confidence": round(float(confidence), 4)})

    return JSONResponse(content=items)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run("server:app", host="0.0.0.0", port=PORT, log_level="info")
