'use strict';

const fs = require('fs');
const path = require('path');
const { PDFDocument, StandardFonts, rgb } = require('pdf-lib');
const docx = require('docx');
const zlib = require('zlib');

const FIXTURES_DIR = path.join(__dirname, 'fixtures');
fs.mkdirSync(FIXTURES_DIR, { recursive: true });

// ---------------------------------------------------------------------------
// hello.pdf — single-page PDF with "Hello LiteParse" rendered in Helvetica
// ---------------------------------------------------------------------------
async function generatePdf() {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const page = doc.addPage([612, 792]); // US Letter

  page.drawText('Hello LiteParse', {
    x: 72,
    y: 700,
    size: 24,
    font,
    color: rgb(0, 0, 0),
  });

  page.drawText('This is a test document for validating PDF parsing.', {
    x: 72,
    y: 660,
    size: 12,
    font,
    color: rgb(0, 0, 0),
  });

  page.drawText('Line three with special characters: é à ü ñ ß', {
    x: 72,
    y: 640,
    size: 12,
    font,
    color: rgb(0, 0, 0),
  });

  const bytes = await doc.save();
  const outPath = path.join(FIXTURES_DIR, 'hello.pdf');
  fs.writeFileSync(outPath, bytes);
  console.log(`Created: ${outPath} (${bytes.length} bytes)`);
}

// ---------------------------------------------------------------------------
// multipage.pdf — 3-page PDF for targetPages testing
// ---------------------------------------------------------------------------
async function generateMultipagePdf() {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);

  for (let i = 1; i <= 3; i++) {
    const page = doc.addPage([612, 792]);
    page.drawText(`Page ${i} of 3`, {
      x: 72,
      y: 700,
      size: 24,
      font,
      color: rgb(0, 0, 0),
    });
    page.drawText(`Content on page ${i}. This is test data for batch and page-range parsing.`, {
      x: 72,
      y: 660,
      size: 12,
      font,
      color: rgb(0, 0, 0),
    });
  }

  const bytes = await doc.save();
  const outPath = path.join(FIXTURES_DIR, 'multipage.pdf');
  fs.writeFileSync(outPath, bytes);
  console.log(`Created: ${outPath} (${bytes.length} bytes)`);
}

// ---------------------------------------------------------------------------
// hello.docx — single-page DOCX with "Hello LiteParse"
// Requires LibreOffice in the container to be converted for parsing.
// ---------------------------------------------------------------------------
async function generateDocx() {
  const doc = new docx.Document({
    sections: [
      {
        children: [
          new docx.Paragraph({
            children: [
              new docx.TextRun({
                text: 'Hello LiteParse',
                bold: true,
                size: 48, // half-points → 24pt
              }),
            ],
          }),
          new docx.Paragraph({
            children: [
              new docx.TextRun({
                text: 'This is a test DOCX document for validating multi-format support.',
                size: 24,
              }),
            ],
          }),
          new docx.Paragraph({
            children: [
              new docx.TextRun({
                text: 'LibreOffice converts this to PDF before LiteParse processes it.',
                size: 24,
              }),
            ],
          }),
        ],
      },
    ],
  });

  const buffer = await docx.Packer.toBuffer(doc);
  const outPath = path.join(FIXTURES_DIR, 'hello.docx');
  fs.writeFileSync(outPath, buffer);
  console.log(`Created: ${outPath} (${buffer.length} bytes)`);
}

// ---------------------------------------------------------------------------
// hello.png — minimal valid 100x40 PNG with a dark rectangle on white
//
// This is a programmatic PNG (no canvas/native deps needed). It won't contain
// real text glyphs, so OCR tests against it should expect either empty output
// or verify only that LiteParse processes image files without crashing.
//
// For real OCR integration tests, use a pre-made scanned image instead.
// ---------------------------------------------------------------------------
function generatePng() {
  const width = 200;
  const height = 60;

  // Build raw pixel rows: white background with a dark rectangle in the center.
  // Each row is: filter-byte (0 = None) + width * 3 bytes (RGB).
  const rawRows = [];
  for (let y = 0; y < height; y++) {
    const row = Buffer.alloc(1 + width * 3);
    row[0] = 0; // filter: None
    for (let x = 0; x < width; x++) {
      const offset = 1 + x * 3;
      // Draw a dark block roughly in the center (simulates text-like content)
      const inBlock =
        (x >= 20 && x < 180 && y >= 10 && y < 18) ||
        (x >= 20 && x < 180 && y >= 24 && y < 32) ||
        (x >= 20 && x < 180 && y >= 38 && y < 46);
      if (inBlock) {
        row[offset] = 30;     // R
        row[offset + 1] = 30; // G
        row[offset + 2] = 30; // B
      } else {
        row[offset] = 255;
        row[offset + 1] = 255;
        row[offset + 2] = 255;
      }
    }
    rawRows.push(row);
  }

  const rawData = Buffer.concat(rawRows);
  const compressed = zlib.deflateSync(rawData);

  // PNG signature
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  function makeChunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const typeBuffer = Buffer.from(type, 'ascii');
    const crcInput = Buffer.concat([typeBuffer, data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(crcInput), 0);
    return Buffer.concat([len, typeBuffer, data, crc]);
  }

  // CRC32 (standard PNG CRC)
  function crc32(buf) {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) {
      c ^= buf[i];
      for (let j = 0; j < 8; j++) {
        c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
      }
    }
    return (c ^ 0xffffffff) >>> 0;
  }

  // IHDR: width, height, bit-depth(8), color-type(2=RGB), compression(0), filter(0), interlace(0)
  const ihdrData = Buffer.alloc(13);
  ihdrData.writeUInt32BE(width, 0);
  ihdrData.writeUInt32BE(height, 4);
  ihdrData[8] = 8;  // bit depth
  ihdrData[9] = 2;  // color type: RGB
  ihdrData[10] = 0; // compression
  ihdrData[11] = 0; // filter
  ihdrData[12] = 0; // interlace

  const ihdr = makeChunk('IHDR', ihdrData);
  const idat = makeChunk('IDAT', compressed);
  const iend = makeChunk('IEND', Buffer.alloc(0));

  const png = Buffer.concat([signature, ihdr, idat, iend]);
  const outPath = path.join(FIXTURES_DIR, 'hello.png');
  fs.writeFileSync(outPath, png);
  console.log(`Created: ${outPath} (${png.length} bytes)`);
}

// ---------------------------------------------------------------------------
// batch.zip — ZIP containing hello.pdf + multipage.pdf for batch-parse tests
// Built using Node's built-in zlib (no additional deps).
// ---------------------------------------------------------------------------
function generateBatchZip() {
  // Minimal ZIP implementation — just enough for two stored (uncompressed) entries.
  const files = [
    { name: 'hello.pdf', path: path.join(FIXTURES_DIR, 'hello.pdf') },
    { name: 'multipage.pdf', path: path.join(FIXTURES_DIR, 'multipage.pdf') },
  ];

  const entries = files.map(f => ({
    name: Buffer.from(f.name, 'utf-8'),
    data: fs.readFileSync(f.path),
  }));

  const parts = [];
  const centralDir = [];
  let offset = 0;

  for (const entry of entries) {
    // CRC32
    let c = 0xffffffff;
    for (let i = 0; i < entry.data.length; i++) {
      c ^= entry.data[i];
      for (let j = 0; j < 8; j++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
    }
    const crc = (c ^ 0xffffffff) >>> 0;

    // Local file header
    const lfh = Buffer.alloc(30);
    lfh.writeUInt32LE(0x04034b50, 0);  // signature
    lfh.writeUInt16LE(20, 4);           // version needed
    lfh.writeUInt16LE(0, 6);            // flags
    lfh.writeUInt16LE(0, 8);            // compression: stored
    lfh.writeUInt16LE(0, 10);           // mod time
    lfh.writeUInt16LE(0, 12);           // mod date
    lfh.writeUInt32LE(crc, 14);
    lfh.writeUInt32LE(entry.data.length, 18);  // compressed size
    lfh.writeUInt32LE(entry.data.length, 22);  // uncompressed size
    lfh.writeUInt16LE(entry.name.length, 26);  // filename length
    lfh.writeUInt16LE(0, 28);                  // extra field length

    // Central directory entry
    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);   // signature
    cd.writeUInt16LE(20, 4);            // version made by
    cd.writeUInt16LE(20, 6);            // version needed
    cd.writeUInt16LE(0, 8);             // flags
    cd.writeUInt16LE(0, 10);            // compression: stored
    cd.writeUInt16LE(0, 12);            // mod time
    cd.writeUInt16LE(0, 14);            // mod date
    cd.writeUInt32LE(crc, 16);
    cd.writeUInt32LE(entry.data.length, 20);
    cd.writeUInt32LE(entry.data.length, 24);
    cd.writeUInt16LE(entry.name.length, 28);
    cd.writeUInt16LE(0, 30);            // extra field length
    cd.writeUInt16LE(0, 32);            // comment length
    cd.writeUInt16LE(0, 34);            // disk number
    cd.writeUInt16LE(0, 36);            // internal attrs
    cd.writeUInt32LE(0, 38);            // external attrs
    cd.writeUInt32LE(offset, 42);       // local header offset

    centralDir.push(Buffer.concat([cd, entry.name]));
    parts.push(lfh, entry.name, entry.data);
    offset += lfh.length + entry.name.length + entry.data.length;
  }

  const cdBuf = Buffer.concat(centralDir);
  const cdOffset = offset;

  // End of central directory
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);              // disk number
  eocd.writeUInt16LE(0, 6);              // cd disk number
  eocd.writeUInt16LE(entries.length, 8);  // cd entries on disk
  eocd.writeUInt16LE(entries.length, 10); // total cd entries
  eocd.writeUInt32LE(cdBuf.length, 12);
  eocd.writeUInt32LE(cdOffset, 16);
  eocd.writeUInt16LE(0, 20);             // comment length

  const zip = Buffer.concat([...parts, cdBuf, eocd]);
  const outPath = path.join(FIXTURES_DIR, 'batch.zip');
  fs.writeFileSync(outPath, zip);
  console.log(`Created: ${outPath} (${zip.length} bytes)`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
(async () => {
  await generatePdf();
  await generateMultipagePdf();
  await generateDocx();
  generatePng();
  generateBatchZip();
  console.log(`\nAll fixtures generated in ${FIXTURES_DIR}/`);
})().catch(err => {
  console.error(err);
  process.exit(1);
});
