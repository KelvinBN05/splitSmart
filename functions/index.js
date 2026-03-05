const logger = require("firebase-functions/logger");
const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { DocumentProcessorServiceClient } = require("@google-cloud/documentai");

admin.initializeApp();

const documentAIClient = new DocumentProcessorServiceClient();
const PARSER_VERSION = "docai-v4-2026-03-05";

exports.processOCRJob = functions.firestore
  .document("users/{userId}/ocrJobs/{jobId}")
  .onCreate(async (snapshot) => {
  const jobRef = snapshot.ref;
  const data = snapshot.data() || {};
  const imagePath = data.imagePath;
  const documentAIConfig = (functions.config() && functions.config().document_ai) || {};
  const projectID = documentAIConfig.project_id || process.env.DOCUMENT_AI_PROJECT_ID || process.env.GCLOUD_PROJECT;
  const location = documentAIConfig.location || process.env.DOCUMENT_AI_LOCATION || "us";
  const processorID = documentAIConfig.processor_id || process.env.DOCUMENT_AI_PROCESSOR_ID || "";

  if (!imagePath) {
    await jobRef.set(
      {
        status: "failed",
        errorMessage: "Missing imagePath on OCR job.",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    return;
  }

  if (!projectID || !processorID) {
    await jobRef.set(
      {
        status: "failed",
        errorMessage:
          "Document AI is not configured. Set DOCUMENT_AI_PROJECT_ID and DOCUMENT_AI_PROCESSOR_ID.",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    return;
  }

  await jobRef.set(
    {
      status: "processing",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  try {
    const bucket = admin.storage().bucket();
    const [bytes] = await bucket.file(imagePath).download();

    const processorName = `projects/${projectID}/locations/${location}/processors/${processorID}`;
    const [result] = await documentAIClient.processDocument({
      name: processorName,
      rawDocument: {
        content: bytes.toString("base64"),
        mimeType: "image/jpeg",
      },
    });

    const parsed = mapReceiptFromDocumentAI(result.document);

    await jobRef.set(
      {
        status: "completed",
        result: parsed,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  } catch (error) {
    logger.error("Document AI OCR failed", error);
    await jobRef.set(
      {
        status: "failed",
        errorMessage: error.message || "Document AI processing failed.",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
});

function mapReceiptFromDocumentAI(document) {
  const entities = document?.entities || [];
  const lines = extractLinesFromDocument(document);
  const rawText = String(document?.text || "");

  const merchantName =
    firstEntityText(entities, ["supplier_name", "merchant_name"]) || detectMerchantFromLines(lines);
  const tax = normalizeAmount(firstEntityText(entities, ["total_tax_amount", "tax"])) || "";
  const tip = normalizeAmount(firstEntityText(entities, ["tip_amount", "tip"])) || "";

  const lineItems = entities.filter((entity) => entity.type === "line_item");
  let items = lineItems
    .map((lineItem) => {
      const props = lineItem.properties || [];
      const name =
        firstEntityText(props, ["line_item/description", "description", "line_item/name", "name"]) || "";
      const quantityRaw = firstEntityText(props, ["line_item/quantity", "quantity"]) || "1";
      const priceRaw =
        firstEntityText(props, ["line_item/amount", "line_item/unit_price", "amount", "unit_price"]) || "";

      const quantity = Math.max(1, parseInt(quantityRaw, 10) || 1);
      const price = normalizeAmount(priceRaw);
      if (!name || !price) return null;

      return { name, quantity, price };
    })
    .filter(Boolean);

  // Fallback: some processors return sparse entities; parse from raw OCR text.
  if (!items.length) {
    items = parseItemsFromLines(lines);
  }
  if (!items.length) {
    items = parseItemsFromRawText(rawText);
  }

  const taxFromLines = parseTaxFromLines(lines);
  const taxFromRawText = parseTaxFromRawText(rawText);
  const normalizedTax = tax || taxFromLines || taxFromRawText;

  const parseMode = lineItems.length
    ? (items.length ? "entity+fallback" : "entity-only")
    : (items.length ? "text-fallback" : "no-items");

  return {
    merchantName,
    tax: normalizedTax,
    tip,
    items,
    debug: {
      parserVersion: PARSER_VERSION,
      parseMode,
      entityCount: entities.length,
      lineItemEntityCount: lineItems.length,
      lineCount: lines.length,
      itemCount: items.length,
      lineContent: lines.slice(0, 220),
      rawTextPreview: rawText.slice(0, 2400),
      taxSource: tax
        ? "entity"
        : (taxFromLines ? "lines" : (taxFromRawText ? "raw_text" : "none")),
    },
  };
}

function firstEntityText(entities, types) {
  for (const type of types) {
    const match = entities.find((entity) => entity.type === type);
    const text = match?.mentionText?.trim();
    if (text) return text;
  }
  return "";
}

function normalizeAmount(raw) {
  if (!raw) return "";
  const cleaned = String(raw).replace(/[$,\s]/g, "");
  if (!/^\d+(\.\d{1,2})?$/.test(cleaned)) return "";
  const value = Number(cleaned);
  if (Number.isNaN(value)) return "";
  return value.toString();
}

function extractLinesFromDocument(document) {
  const fullText = String(document?.text || "");
  const lines = [];

  const pages = document?.pages || [];
  for (const page of pages) {
    const pageLines = page.lines || [];
    for (const line of pageLines) {
      const value = textFromLayout(line.layout, fullText).trim();
      if (value) lines.push(value);
    }
  }

  if (lines.length) return lines;

  return fullText
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function textFromLayout(layout, fullText) {
  const anchor = layout?.textAnchor;
  const segments = anchor?.textSegments || [];
  if (!segments.length) return "";

  let out = "";
  for (const segment of segments) {
    const start = Number(segment.startIndex || 0);
    const end = Number(segment.endIndex || 0);
    if (Number.isNaN(start) || Number.isNaN(end) || end <= start) continue;
    out += fullText.slice(start, end);
  }
  return out;
}

function parseTaxFromLines(lines) {
  for (let i = 0; i < lines.length; i += 1) {
    const line = String(lines[i] || "");
    if (!/tax/i.test(line)) continue;

    // Case 1: "TAX ... 4.59"
    const inline = line.match(/([0-9]+\.[0-9]{2})\s*$/);
    if (inline) return normalizeAmount(inline[1]);

    // Case 2: split lines: "TAX 1" then "6.750 %" then "4.59"
    for (let lookahead = i + 1; lookahead <= Math.min(i + 3, lines.length - 1); lookahead += 1) {
      const m = String(lines[lookahead] || "").match(/([0-9]+\.[0-9]{2})\s*$/);
      if (!m) continue;
      const value = Number(m[1]);
      if (!Number.isNaN(value) && value < 1) continue; // skip percentage-like values e.g. 0.0675
      return normalizeAmount(m[1]);
    }
  }
  return "";
}

function parseItemsFromLines(lines) {
  const stopAt = lines.findIndex((line) => /subtotal|^total\b/i.test(String(line)));
  const window = stopAt >= 0 ? lines.slice(0, stopAt) : lines;
  const noise = /(st#|op#|te#|tr#|approval|ref\s*#|trans|payment|service|validation|thank you|visa|debit|terminal|change due|items sold|manager|customer copy|subtotal|^total\b|tax\b|tip\b|gratuity|balance due|save money|live better|^\(|bluebell|new philadelphia|walmart|^\*+$|^[\-–—]$)/i;
  const bySig = new Map();

  // Pass 1: robust grouped parsing for tokenized lines
  for (let i = 0; i < window.length; i += 1) {
    const line = String(window[i] || "").trim();
    if (!line || noise.test(line)) continue;

    // Ignore UPC-only and price-only lines as candidate names
    if (/^\d{6,14}$/.test(line)) continue;
    if (/^[0-9]+\.[0-9]{2}\s*[A-Z]?$/.test(line)) continue;

    // Candidate item name line. Look ahead for a nearby price line.
    let foundPrice = "";
    let consumedUntil = i;
    for (let j = i + 1; j <= Math.min(i + 3, window.length - 1); j += 1) {
      const candidate = String(window[j] || "").trim();
      const priceMatch = candidate.match(/^([0-9]+\.[0-9]{2})\s*[A-Z]?$/);
      if (priceMatch) {
        foundPrice = normalizeAmount(priceMatch[1]);
        consumedUntil = j;
        break;
      }
    }

    if (!foundPrice) continue;

    const cleanedName = cleanItemName(line);
    if (!cleanedName || !looksLikeItemName(cleanedName)) continue;
    const quantity = extractQuantityFromLine(line);

    const sig = `${cleanedName.toLowerCase()}|${foundPrice}`;
    const existing = bySig.get(sig);
    if (existing) {
      existing.quantity += quantity;
    } else {
      bySig.set(sig, { name: cleanedName, quantity, price: foundPrice });
    }
    i = consumedUntil;
    if (bySig.size >= 60) break;
  }

  // Pass 2: fallback for any line that already has name + price on same row
  if (!bySig.size) {
    for (const line of window) {
      if (noise.test(line)) continue;
      const m = String(line).match(/^(.+?)\s+(?:\d{6,14}\s+)?([0-9]+\.[0-9]{2})\s*[A-Z]?$/);
      if (!m) continue;

      const name = cleanItemName(m[1]);
      const price = normalizeAmount(m[2]);
      if (!name || !price || !looksLikeItemName(name)) continue;
      const quantity = extractQuantityFromLine(name);
      const sig = `${name.toLowerCase()}|${price}`;
      const existing = bySig.get(sig);
      if (existing) {
        existing.quantity += quantity;
      } else {
        bySig.set(sig, { name, quantity, price });
      }
      if (bySig.size >= 60) break;
    }
  }

  return Array.from(bySig.values());
}

function parseTaxFromRawText(text) {
  const lines = String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  for (const line of lines) {
    if (!/tax/i.test(line)) continue;
    const m = line.match(/([0-9]+\.[0-9]{2})\s*$/);
    if (m) return normalizeAmount(m[1]);
  }
  return "";
}

function parseItemsFromRawText(text) {
  const lines = String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const parsedFromLines = parseItemsFromLines(lines);
  if (parsedFromLines.length) return parsedFromLines;

  // Fallback when OCR text is effectively a single long line.
  const normalized = String(text || "").replace(/\s+/g, " ").trim();
  if (!normalized) return [];

  const bySig = new Map();
  const pattern = /(.+?)\s+(?:\d{6,14}\s+)?([0-9]+\.[0-9]{2})\s*[A-Z]?\b/g;
  let match;
  while ((match = pattern.exec(normalized)) !== null) {
    const rawName = String(match[1] || "")
      .replace(/\b\d{6,14}\b/g, "")
      .replace(/\s{2,}/g, " ")
      .trim();
    const price = normalizeAmount(match[2]);
    if (!rawName || !price || !looksLikeItemName(rawName)) continue;
    const sig = `${rawName.toLowerCase()}|${price}`;
    const quantity = extractQuantityFromLine(rawName);
    const existing = bySig.get(sig);
    if (existing) {
      existing.quantity += quantity;
    } else {
      bySig.set(sig, { name: rawName, quantity, price });
    }
    if (bySig.size >= 60) break;
  }

  return Array.from(bySig.values());
}

function looksLikeItemName(name) {
  const lower = String(name || "").toLowerCase();
  if (lower.length < 2) return false;
  if (!/[a-z]/i.test(lower)) return false;
  if (/(st#|op#|te#|tr#|approval|ref\s*#|trans|payment|service|validation|visa|debit|terminal|items sold|manager|customer copy|subtotal|^total\b|tax\b|tip\b|gratuity|balance due)/i.test(lower)) {
    return false;
  }
  return true;
}

function cleanItemName(name) {
  return String(name || "")
    .replace(/^\s*\d+\s*[xX]\s+/g, "")
    .replace(/\bqty[:\s]*\d+\b/gi, "")
    .replace(/\b\d{6,14}\b/g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function extractQuantityFromLine(line) {
  const value = String(line || "");
  const patterns = [/^\s*(\d+)\s*[xX]\s+/, /\bqty[:\s]*(\d+)\b/i];
  for (const pattern of patterns) {
    const match = value.match(pattern);
    if (!match) continue;
    const qty = Number(match[1]);
    if (!Number.isNaN(qty) && qty > 0) return Math.min(99, Math.floor(qty));
  }
  return 1;
}

function detectMerchantFromLines(lines) {
  for (const raw of lines.slice(0, 12)) {
    const line = String(raw || "").trim();
    if (!line) continue;
    if (/^\d+$/.test(line)) continue;
    if (/(save money|live better|manager|st#|op#|te#|tr#|bluebell|new philadelphia|\(\s*\d{3}\s*\))/i.test(line)) continue;
    if (line.length > 48) continue;
    return line.replace(/[®Ⓡ]/g, "").trim();
  }
  return "";
}
