const logger = require("firebase-functions/logger");
const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { DocumentProcessorServiceClient } = require("@google-cloud/documentai");

admin.initializeApp();

const documentAIClient = new DocumentProcessorServiceClient();
const PARSER_VERSION = "docai-v7-2026-03-06";

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
  const totals = parseTotalsFromLines(lines);

  const merchantName =
    firstEntityText(entities, ["supplier_name", "merchant_name"]) || detectMerchantFromLines(lines);
  const tax = normalizeAmount(firstEntityText(entities, ["total_tax_amount", "tax"])) || "";
  const tip = normalizeAmount(firstEntityText(entities, ["tip_amount", "tip"])) || "";

  const lineItems = entities.filter((entity) => entity.type === "line_item");
  const entityItems = lineItems
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

      return { name: cleanItemName(name), quantity, price };
    })
    .filter(Boolean);

  const layout = classifyReceiptLayout(lines, lineItems.length);
  const candidates = [
    { name: "entity", items: aggregateItems(entityItems) },
    { name: "paired-lines", items: parseItemsFromLines(lines) },
    { name: "single-line", items: parseItemsInline(lines) },
    { name: "raw-text", items: parseItemsFromRawText(rawText) },
  ];
  const scoredCandidates = candidates.map((candidate) => ({
    name: candidate.name,
    items: candidate.items,
    score: scoreCandidate(candidate.items, lines, layout),
  }));
  const bestCandidate = scoredCandidates.reduce((best, current) =>
    current.score > best.score ? current : best
  , { name: "none", items: [], score: -1 });
  const items = bestCandidate.items;

  const taxFromLines = parseTaxFromLines(lines);
  const taxFromRawText = parseTaxFromRawText(rawText);
  const taxFromTotals = deriveTaxFromTotals(totals);
  const normalizedTax = tax || taxFromTotals || taxFromLines || taxFromRawText;

  const parseMode = `${layout.kind}->${bestCandidate.name}`;

  return {
    merchantName,
    tax: normalizedTax,
    tip,
    items,
    debug: {
      parserVersion: PARSER_VERSION,
      parseMode,
      layoutKind: layout.kind,
      entityCount: entities.length,
      lineItemEntityCount: lineItems.length,
      lineCount: lines.length,
      itemCount: items.length,
      candidateScores: scoredCandidates.map((candidate) => ({
        name: candidate.name,
        score: candidate.score,
        itemCount: candidate.items.length,
      })),
      lineContent: lines.slice(0, 220),
      rawTextPreview: rawText.slice(0, 2400),
      totals,
      taxSource: tax
        ? "entity"
        : (taxFromTotals ? "totals_diff" : (taxFromLines ? "lines" : (taxFromRawText ? "raw_text" : "none"))),
    },
  };
}

function classifyReceiptLayout(lines, lineItemEntityCount) {
  const stopAt = lines.findIndex((line) => /subtotal|^total\b/i.test(String(line)));
  const window = stopAt >= 0 ? lines.slice(0, stopAt) : lines;
  const priceOnlyCount = window.filter((line) => /^[0-9]+\.[0-9]{2}\s*[A-Z]?$/.test(String(line).trim())).length;
  const upcOnlyCount = window.filter((line) => /^\d{6,14}$/.test(String(line).trim())).length;
  const inlineItemCount = window.filter((line) =>
    /^(.+?)\s+(?:\d{6,14}\s+)?([0-9]+\.[0-9]{2})\s*[A-Z]?$/.test(String(line).trim())
  ).length;

  if (lineItemEntityCount >= 3) return { kind: "entity-rich", priceOnlyCount, upcOnlyCount, inlineItemCount };
  if (priceOnlyCount >= 3 && upcOnlyCount >= 3) return { kind: "paired-lines", priceOnlyCount, upcOnlyCount, inlineItemCount };
  if (inlineItemCount >= 5) return { kind: "single-line", priceOnlyCount, upcOnlyCount, inlineItemCount };
  return { kind: "mixed", priceOnlyCount, upcOnlyCount, inlineItemCount };
}

function scoreCandidate(items, lines, layout) {
  if (!items.length) return 0;
  const stopAt = lines.findIndex((line) => /subtotal|^total\b/i.test(String(line)));
  const window = stopAt >= 0 ? lines.slice(0, stopAt) : lines;

  let score = 0;
  score += Math.min(40, items.length * 2);
  score += items.reduce((sum, item) => sum + Math.min(3, Number(item.quantity || 1)), 0);

  const namesWithLetters = items.filter((item) => /[a-z]/i.test(String(item.name))).length;
  score += namesWithLetters;

  const noisyItems = items.filter((item) => !looksLikeItemName(item.name)).length;
  score -= noisyItems * 5;

  const uniqueNames = new Set(items.map((item) => String(item.name || "").toLowerCase())).size;
  score += Math.min(10, uniqueNames);

  if (layout.kind === "paired-lines") {
    const priceOnlyCount = layout.priceOnlyCount || 0;
    if (priceOnlyCount >= 3) score += 8;
  }
  if (layout.kind === "single-line") {
    const inlineItemCount = layout.inlineItemCount || 0;
    if (inlineItemCount >= 5) score += 8;
  }

  const subtotalIndex = window.findIndex((line) => /subtotal/i.test(String(line)));
  if (subtotalIndex >= 0 && items.length > 0) score += 4;

  return score;
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
  const totals = parseTotalsFromLines(lines);
  const collectedTaxes = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = String(lines[i] || "");
    if (!/tax/i.test(line)) continue;

    // Case 1: "TAX ... 4.59"
    const inline = line.match(/([0-9]+\.[0-9]{2})\s*$/);
    if (inline) {
      const value = Number(inline[1]);
      if (!Number.isNaN(value)) collectedTaxes.push(value);
      continue;
    }

    // Case 2: split lines: "TAX 1" then "6.750 %" then "4.59"
    const candidates = [];
    for (let lookahead = i + 1; lookahead <= Math.min(i + 3, lines.length - 1); lookahead += 1) {
      const look = String(lines[lookahead] || "");
      const matches = look.match(/[0-9]+\.[0-9]{2}/g) || [];
      for (const raw of matches) {
        const value = Number(raw);
        if (!Number.isNaN(value) && value < 1) continue; // skip percentage-like values e.g. 0.0675
        candidates.push(value);
      }
    }
    if (candidates.length === 1) {
      collectedTaxes.push(candidates[0]);
      continue;
    }
    if (candidates.length > 1) {
      const plausible = candidates.filter((value) => {
        if (totals.subtotal > 0) return value < totals.subtotal * 0.35;
        if (totals.total > 0) return value < totals.total * 0.35;
        return true;
      });
      const source = plausible.length ? plausible : candidates;
      const chosen = source.reduce((min, value) => (value < min ? value : min), source[0]);
      collectedTaxes.push(chosen);
    }
  }
  const unique = Array.from(new Set(collectedTaxes.map((value) => value.toFixed(2)))).map(Number);
  if (!unique.length) return "";
  const sum = unique.reduce((acc, value) => acc + value, 0);
  return normalizeAmount(sum.toFixed(2));
}

function parseItemsFromLines(lines) {
  const stopAt = lines.findIndex((line) => /subtotal|^total\b/i.test(String(line)));
  const window = stopAt >= 0 ? lines.slice(0, stopAt) : lines;
  const noise = /(st#|op#|te#|tr#|approval|ref\s*#|trans|payment|service|validation|thank you|visa|debit|terminal|change due|items sold|manager|customer copy|subtotal|^total\b|tax\b|tip\b|gratuity|balance due|save money|live better|^\(|bluebell|new philadelphia|walmart|^\*+$|^[\-–—]$|^check:|^opened:|^order:|^order type:|^name:|^server:|pay with cash|^saved\b|^cartwheel\b|redcard savings|health-beauty-cosmetics|^home$|^grocery$|^cleaning supplies$|expires)/i;
  const bySig = new Map();

  // Pass 1: robust grouped parsing for tokenized lines
  for (let i = 0; i < window.length; i += 1) {
    const line = String(window[i] || "").trim();
    if (!line || noise.test(line)) continue;
    if (isQuantitySummaryLine(line)) continue;

    // Ignore UPC-only and price-only lines as candidate names
    if (/^\d{6,14}$/.test(line)) continue;
    if (/^[0-9]+\.[0-9]{2}\s*[A-Z]?$/.test(line)) continue;

    // Case A: same-line item + price.
    const sameLine = parseInlineItemLine(line);
    if (sameLine) {
      const sig = `${sameLine.name.toLowerCase()}|${sameLine.price}`;
      const existing = bySig.get(sig);
      if (existing) {
        existing.quantity += sameLine.quantity;
      } else {
        bySig.set(sig, sameLine);
      }
      if (bySig.size >= 60) break;
      continue;
    }

    // Case B: name line with nearby price line.
    let foundPrice = "";
    let foundPriceLine = "";
    let consumedUntil = i;
    for (let j = i + 1; j <= Math.min(i + 3, window.length - 1); j += 1) {
      const candidate = String(window[j] || "").trim();
      if (noise.test(candidate) || isQuantitySummaryLine(candidate)) continue;
      const priceFromCandidate = extractPriceFromLine(candidate);
      if (priceFromCandidate) {
        foundPrice = priceFromCandidate;
        foundPriceLine = candidate;
        consumedUntil = j;
        break;
      }
    }

    if (!foundPrice) continue;

    const cleanedName = cleanItemName(line);
    if (!cleanedName || !looksLikeItemName(cleanedName)) continue;
    const quantity = extractQuantityFromLine(line);
    if (shouldRejectPairedItemCandidate(cleanedName, foundPrice, foundPriceLine)) continue;

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
      if (isQuantitySummaryLine(line)) continue;
      const parsed = parseInlineItemLine(String(line));
      if (!parsed) continue;
      const sig = `${parsed.name.toLowerCase()}|${parsed.price}`;
      const existing = bySig.get(sig);
      if (existing) {
        existing.quantity += parsed.quantity;
      } else {
        bySig.set(sig, parsed);
      }
      if (bySig.size >= 60) break;
    }
  }

  return Array.from(bySig.values());
}

function shouldRejectPairedItemCandidate(name, price, priceLine) {
  const amount = Number(price || 0);
  const rawPriceLine = String(priceLine || "").trim();
  const upperName = String(name || "").toUpperCase();

  // Target-style hardgoods lines can appear as:
  //   BISSELL
  //   I $129.99
  // Keep these out of grocery split defaults.
  if (/^[TI]\s*\$?[0-9]+\.[0-9]{2}\s*$/.test(rawPriceLine) && amount >= 25) {
    return true;
  }

  // One-token all-caps name with unusually high price from paired lines
  // is likely a bad pairing in receipt OCR fallback.
  if (/^[A-Z0-9-]{5,}$/.test(upperName) && amount >= 80) {
    return true;
  }

  return false;
}

function parseItemsInline(lines) {
  const stopAt = lines.findIndex((line) => /subtotal|^total\b/i.test(String(line)));
  const window = stopAt >= 0 ? lines.slice(0, stopAt) : lines;
  const out = [];

  for (const raw of window) {
    const line = String(raw || "").trim();
    if (!line) continue;
    if (isQuantitySummaryLine(line)) continue;
    if (!looksLikePotentialItemLine(line)) continue;

    const parsed = parseInlineItemLine(line);
    if (!parsed) continue;
    out.push(parsed);
  }

  return aggregateItems(out);
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

  return aggregateItems(Array.from(bySig.values()));
}

function looksLikeItemName(name) {
  const lower = String(name || "").toLowerCase();
  if (lower.length < 2) return false;
  if (!/[a-z]/i.test(lower)) return false;
  if (
    /(st#|op#|te#|tr#|approval|ref\s*#|trans|payment|service|validation|visa|debit|terminal|items sold|manager|customer copy|subtotal|^total\b|tax\b|tip\b|gratuity|balance due|check:|opened:|order:|order type:|name:|server:|table\s+\d+|pay with cash|^saved\b|^cartwheel\b|redcard savings|expires|health-beauty-cosmetics)/i.test(
      lower
    )
  ) {
    return false;
  }
  // Drop fragments that are just department flags and currency markers.
  if (/^(fc|t|i)\s*\$?$/.test(lower)) return false;
  return true;
}

function looksLikePotentialItemLine(line) {
  const lower = String(line || "").toLowerCase();
  if (!lower) return false;
  if (/^\d{6,14}$/.test(lower)) return false;
  if (/^[0-9]+\.[0-9]{2}\s*[a-z]?$/.test(lower)) return false;
  if (/(approval|ref\s*#|trans|payment|service|validation|visa|debit|terminal|items sold|customer copy|subtotal|^total\b|tax\b|tip\b|gratuity|balance due)/i.test(lower)) {
    return false;
  }
  return true;
}

function cleanItemName(name) {
  return String(name || "")
    .replace(/^\s*\d+\s+(?=[A-Za-z])/g, "")
    .replace(/^\s*\d+\s*[xX]\s+/g, "")
    .replace(/\bqty[:\s]*\d+\b/gi, "")
    .replace(/\b(?:FC|T|I)\s*\$$/i, "")
    .replace(/\b(?:FC|T|I)\b/gi, "")
    .replace(/\[$/g, "")
    .replace(/↓/g, "")
    .replace(/\$[0-9]+\.[0-9]{2}\s*$/g, "")
    .replace(/\b\d{6,14}\b/g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function aggregateItems(items) {
  const bySig = new Map();
  for (const item of items || []) {
    const name = cleanItemName(item?.name || "");
    const price = normalizeAmount(item?.price || "");
    const quantity = Math.max(1, parseInt(item?.quantity, 10) || 1);
    if (!name || !price || !looksLikeItemName(name)) continue;
    const sig = `${name.toLowerCase()}|${price}`;
    const existing = bySig.get(sig);
    if (existing) {
      existing.quantity += quantity;
    } else {
      bySig.set(sig, { name, quantity, price });
    }
  }
  return Array.from(bySig.values());
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
  const joined = lines.join(" ").toLowerCase();
  if (/\bredcard\b/.test(joined) || /\bcartwheel\b/.test(joined)) return "Target";
  for (const raw of lines.slice(0, 12)) {
    const line = String(raw || "").trim();
    if (!line) continue;
    if (line.length <= 2) continue;
    if (/\b\d{2}\/\d{2}\/\d{2,4}\b/.test(line)) continue;
    if (/\b\d{1,2}:\d{2}\s*(am|pm)\b/i.test(line)) continue;
    if (/^\d+$/.test(line)) continue;
    if (/(save money|live better|manager|st#|op#|te#|tr#|bluebell|new philadelphia|\(\s*\d{3}\s*\)|check:|opened:|order:|server:|name:)/i.test(line)) continue;
    if (line.length > 48) continue;
    return line.replace(/[®Ⓡ]/g, "").trim();
  }
  return "";
}

function parseInlineItemLine(line) {
  const value = String(line || "").trim();
  if (!value) return null;

  const price = extractPriceFromLine(value);
  if (!price) return null;

  const namePart = value.replace(/(?:[A-Z]{1,3}\s*)?\$?[0-9]+\.[0-9]{2}\s*[A-Z]?\s*$/, "").trim();
  const name = cleanItemName(namePart);
  if (!name || !price || !looksLikeItemName(name)) return null;

  return { name, quantity: extractQuantityFromLine(value), price };
}

function extractPriceFromLine(line) {
  const value = String(line || "").trim();
  if (!value) return "";
  const match = value.match(/(?:[A-Z]{1,3}\s*)?\$?([0-9]+\.[0-9]{2})\s*[A-Z]?\s*[↓-]?\s*$/);
  if (!match) return "";
  return normalizeAmount(match[1]);
}

function isQuantitySummaryLine(line) {
  const value = String(line || "").trim().toLowerCase();
  if (!value) return false;
  if (/^\d+\s*@\s*\$?\d+\.\d{2}\s*ea$/.test(value)) return true;
  if (/^\d+\s*x\s*\$?\d+\.\d{2}$/.test(value)) return true;
  return false;
}

function parseTotalsFromLines(lines) {
  let subtotal = 0;
  let total = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const line = String(lines[i] || "");
    const subtotalMatch = line.match(/subtotal[^0-9]*([0-9]+\.[0-9]{2})/i);
    if (subtotalMatch) subtotal = Number(subtotalMatch[1]) || subtotal;
    const totalMatch = line.match(/^total[^0-9]*([0-9]+\.[0-9]{2})/i);
    if (totalMatch) total = Number(totalMatch[1]) || total;
    if (/subtotal/i.test(line) && i + 1 < lines.length) {
      const next = String(lines[i + 1] || "").match(/([0-9]+\.[0-9]{2})\s*$/);
      if (next) subtotal = Number(next[1]) || subtotal;
    }
    if (/^total\b/i.test(line) && i + 1 < lines.length) {
      const next = String(lines[i + 1] || "").match(/([0-9]+\.[0-9]{2})\s*$/);
      if (next) total = Number(next[1]) || total;
    }
  }
  return { subtotal, total };
}

function deriveTaxFromTotals(totals) {
  const subtotal = Number(totals?.subtotal || 0);
  const total = Number(totals?.total || 0);
  if (!(subtotal > 0 && total > 0 && total >= subtotal)) return "";
  const diff = Number((total - subtotal).toFixed(2));
  if (diff < 0) return "";
  return normalizeAmount(diff.toFixed(2));
}

exports.__test__ = {
  mapReceiptFromDocumentAI,
  parseItemsFromLines,
  parseItemsFromRawText,
  parseTaxFromLines,
  parseTotalsFromLines,
  detectMerchantFromLines,
  classifyReceiptLayout,
  deriveTaxFromTotals,
};
