const logger = require("firebase-functions/logger");
const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { DocumentProcessorServiceClient } = require("@google-cloud/documentai");

admin.initializeApp();

const documentAIClient = new DocumentProcessorServiceClient();

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

  const merchantName = firstEntityText(entities, ["supplier_name", "merchant_name"]) || "";
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
    items = parseItemsFromRawText(document?.text || "");
  }

  return {
    merchantName,
    tax: tax || parseTaxFromRawText(document?.text || ""),
    tip,
    items,
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

  const stopAt = lines.findIndex((line) => /subtotal|^total\b/i.test(line));
  const window = stopAt >= 0 ? lines.slice(0, stopAt) : lines;

  const noise = /(st#|op#|te#|tr#|approval|ref\s*#|trans|payment|service|validation|thank you|visa|debit|terminal|change due|items sold)/i;
  const out = [];
  const seen = new Set();

  for (const line of window) {
    if (noise.test(line)) continue;
    const m = line.match(/^(.+?)\s+(?:\d{6,14}\s+)?([0-9]+\.[0-9]{2})\s*[A-Z]?$/);
    if (!m) continue;
    const name = m[1].replace(/\b\d{6,14}\b/g, "").replace(/\s{2,}/g, " ").trim();
    const price = normalizeAmount(m[2]);
    if (!name || !price) continue;
    const sig = `${name.toLowerCase()}|${price}`;
    if (seen.has(sig)) continue;
    seen.add(sig);
    out.push({ name, quantity: 1, price });
    if (out.length >= 25) break;
  }

  return out;
}
