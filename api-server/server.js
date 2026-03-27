import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { LiteParse } from '@llamaindex/liteparse';
import AdmZip from 'adm-zip';
import Fastify from 'fastify';
import multipart from '@fastify/multipart';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.PORT ?? '3000', 10);
const OCR_SERVER_URL = process.env.OCR_SERVER_URL ?? undefined;

// Load the OpenAPI spec at startup (served at GET /openapi.yaml).
const OPENAPI_SPEC_PATH = path.join(__dirname, 'openapi.yaml');
let openapiSpec = '';
try {
  openapiSpec = fs.readFileSync(OPENAPI_SPEC_PATH, 'utf-8');
} catch {
  // Spec file may not exist outside the Docker image — not fatal.
}

const app = Fastify({ logger: true });
app.register(multipart, { limits: { fileSize: 500 * 1024 * 1024 } }); // 500 MB

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Save a multipart file part to a temp file and return its path.
 * The caller is responsible for unlinking the file when done.
 */
async function saveTempFile(part) {
  const ext = path.extname(part.filename ?? '') || '.bin';
  const tmpPath = path.join(os.tmpdir(), `liteparse-${Date.now()}-${Math.random().toString(36).slice(2)}${ext}`);
  await fs.promises.writeFile(tmpPath, await part.toBuffer());
  return tmpPath;
}

/**
 * Build a LiteParse config object from query-string parameters.
 */
function buildConfig(query) {
  return {
    ocrEnabled: query.noOcr !== 'true',
    ocrLanguage: query.ocrLanguage ?? 'eng',
    ocrServerUrl: OCR_SERVER_URL ?? query.ocrServerUrl,
    json: query.format === 'json',
    dpi: query.dpi ? parseInt(query.dpi, 10) : 150,
    targetPages: query.targetPages ?? undefined,
  };
}

// ---------------------------------------------------------------------------
// GET /health – liveness probe
// ---------------------------------------------------------------------------
app.get('/health', async (_req, reply) => {
  reply.send({ status: 'ok' });
});

// ---------------------------------------------------------------------------
// GET /openapi.yaml – serve the OpenAPI 3.0 specification
// ---------------------------------------------------------------------------
app.get('/openapi.yaml', async (_req, reply) => {
  if (!openapiSpec) {
    return reply.status(404).send({ error: 'OpenAPI spec not found.' });
  }
  reply.header('Content-Type', 'text/yaml; charset=utf-8').send(openapiSpec);
});

// ---------------------------------------------------------------------------
// POST /parse – parse a single uploaded document
//
// Request:  multipart/form-data with a single file field named "file"
// Query params:
//   format        "json" | "text"  (default: text)
//   ocrLanguage   ISO 639-3 code   (default: eng)
//   noOcr         "true" | "false" (default: false)
//   targetPages   page range e.g. "1-5,10"
//   dpi           rendering DPI    (default: 150)
//   ocrServerUrl  external OCR server URL (overrides OCR_SERVER_URL env)
//
// Response: parsed result as JSON (format=json) or plain text (format=text)
// ---------------------------------------------------------------------------
app.post('/parse', async (req, reply) => {
  const parts = req.parts();
  let tmpPath = null;

  for await (const part of parts) {
    if (part.type === 'file') {
      tmpPath = await saveTempFile(part);
      break;
    }
  }

  if (!tmpPath) {
    return reply.status(400).send({ error: 'No file uploaded. Send a multipart/form-data request with a "file" field.' });
  }

  try {
    const config = buildConfig(req.query);
    const parser = new LiteParse(config);
    const result = await parser.parse(tmpPath);

    if (config.json) {
      reply.header('Content-Type', 'application/json').send(result.json ?? result);
    } else {
      reply.header('Content-Type', 'text/plain; charset=utf-8').send(result.text ?? '');
    }
  } finally {
    fs.unlink(tmpPath, () => {});
  }
});

// ---------------------------------------------------------------------------
// POST /batch-parse – parse all documents inside an uploaded ZIP archive
//
// Request:  multipart/form-data with a single ZIP file field named "file"
// Query params: same as /parse
//
// Response: ZIP archive containing one output file per input document.
//           Output filenames: <original-name>.txt or <original-name>.json
// ---------------------------------------------------------------------------
app.post('/batch-parse', async (req, reply) => {
  const parts = req.parts();
  let tmpZipPath = null;

  for await (const part of parts) {
    if (part.type === 'file') {
      tmpZipPath = await saveTempFile(part);
      break;
    }
  }

  if (!tmpZipPath) {
    return reply.status(400).send({ error: 'No file uploaded. Send a ZIP archive with a "file" field.' });
  }

  const workDir = path.join(os.tmpdir(), `liteparse-batch-${Date.now()}`);
  await fs.promises.mkdir(workDir, { recursive: true });

  try {
    const zip = new AdmZip(tmpZipPath);
    const entries = zip.getEntries().filter(e => !e.isDirectory);

    const config = buildConfig(req.query);
    const parser = new LiteParse(config);

    const resultZip = new AdmZip();

    await Promise.all(entries.map(async (entry) => {
      const entryPath = path.join(workDir, entry.name);
      await fs.promises.writeFile(entryPath, entry.getData());

      try {
        const result = await parser.parse(entryPath);
        const outName = config.json
          ? `${entry.name}.json`
          : `${entry.name}.txt`;
        const outContent = config.json
          ? JSON.stringify(result.json ?? result, null, 2)
          : (result.text ?? '');
        resultZip.addFile(outName, Buffer.from(outContent, 'utf-8'));
      } catch (err) {
        // Include error file for failed entries instead of aborting the batch.
        resultZip.addFile(`${entry.name}.error.txt`, Buffer.from(String(err), 'utf-8'));
      }
    }));

    const outBuffer = resultZip.toBuffer();
    reply
      .header('Content-Type', 'application/zip')
      .header('Content-Disposition', 'attachment; filename="results.zip"')
      .send(outBuffer);
  } finally {
    fs.unlink(tmpZipPath, () => {});
    fs.rm(workDir, { recursive: true, force: true }, () => {});
  }
});

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------
app.listen({ port: PORT, host: '0.0.0.0' }, (err) => {
  if (err) {
    app.log.error(err);
    process.exit(1);
  }
});
