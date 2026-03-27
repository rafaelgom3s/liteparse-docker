# =============================================================================
# LiteParse OCR Sidecar – EasyOCR HTTP server
# =============================================================================
#
# Provides a POST /ocr endpoint that accepts image files and returns OCR
# results in the format expected by LiteParse's external OCR server protocol:
#
#   { "text": "...", "bbox": [x1, y1, x2, y2], "confidence": 0.98 }
#
# Point liteparse at this server with:
#   lit parse document.pdf --ocr-server-url http://localhost:8080
#
# Environment variables:
#   OCR_LANGS            Comma-separated language codes for EasyOCR
#                        (default: en). E.g. "en,fr,de"
#   CUDA_VISIBLE_DEVICES CUDA GPU index for GPU acceleration (e.g. "0").
#                        Omit or leave empty to use CPU.
#   PORT                 HTTP port to listen on (default: 8080)
# =============================================================================

FROM python:3.11-slim-bookworm

# System deps: libGL (OpenCV), libglib2.0 (glib), curl (healthcheck)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies
# easyocr pulls in torch (CPU build), torchvision, opencv-python-headless.
# We pin torch CPU-only to keep the image small (~2 GB vs ~5 GB for CUDA).
# For GPU builds, override with the appropriate CUDA torch wheel.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# EasyOCR model files are downloaded to /root/.EasyOCR on first use.
# Mount a named volume at that path to persist models across restarts.
VOLUME ["/root/.EasyOCR"]

COPY server.py /app/server.py

WORKDIR /app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "server.py"]
