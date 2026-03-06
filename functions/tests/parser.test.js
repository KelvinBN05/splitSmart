const test = require('node:test');
const assert = require('node:assert/strict');

const parser = require('../index.js').__test__;

const targetLines = [
  '03/06/2016 05:25 PM EXPIRES 06/04/16',
  'CLEANING SUPPLIES',
  'UPUP HOUSEH T $1.94',
  'OREO COOKIE FC $5.98',
  '2 @ $2.99 ea',
  'NATVAL ENER FC $5.89',
  'MOTTS FRTSN FC $1.50',
  'Cartwheel MfrCpn $0.50-',
  'MOTTS FRTSN FC $4.50↓',
  '3 @ $1.50 ea',
  'Saved $1.71 off $6.21',
  'V8',
  'FC $4.19',
  'CHOBANI',
  'FC $1.00',
  'CHOBANI',
  'FC $1.00',
  'CHOBANI',
  'FC $1.00',
  'CHOBANI',
  'FC $2.00',
  '2 @ $1.00 ea',
  'SUBTOTAL $246.00',
  'T=MO TAX 8.4750',
  '151.37 $12.83',
  'C=MO TAX',
  '5.4750% on $83.08',
  '$4.55',
  'TOTAL $251.83',
  'Your REDcard Savings $11.55-',
];

const restaurantLines = [
  'la Cabaña',
  'La Cabana - Venice',
  '738 Rose Ave',
  'Venice, CA 90291',
  'Check: 1',
  '1 Dos Tacos (Brunch)',
  '18.00',
  '1 6. Taco y Enchilada (Super Combo)21.95',
  '1 Brunch Reg Lime Margarita',
  '12.75',
  'Subtotal',
  '52.70',
  'Sales Tax',
  '5.01',
  'Total',
  '57.71',
];

test('detectMerchantFromLines infers Target brand from redcard/cartwheel context', () => {
  assert.equal(parser.detectMerchantFromLines(targetLines), 'Target');
});

test('parseTotalsFromLines extracts subtotal and total', () => {
  const totals = parser.parseTotalsFromLines(targetLines);
  assert.equal(totals.subtotal, 246);
  assert.equal(totals.total, 251.83);
});

test('deriveTaxFromTotals returns cent-rounded difference', () => {
  assert.equal(parser.deriveTaxFromTotals({ subtotal: 246, total: 251.83 }), '5.83');
});

test('parseTaxFromLines handles multi-line tax sections', () => {
  assert.equal(parser.parseTaxFromLines(targetLines), '10.02');
  assert.equal(parser.parseTaxFromLines(restaurantLines), '5.01');
});

test('parseItemsFromLines ignores promo summary rows and keeps nearby price pairs', () => {
  const items = parser.parseItemsFromLines(targetLines);
  assert(items.find((item) => item.name === 'V8' && item.price === '4.19'));
  assert(!items.some((item) => item.name.includes('Saved')));
  assert(!items.some((item) => item.name.includes('Cartwheel')));
  assert(!items.some((item) => item.name.includes('2 @ $')));
});

test('parseItemsFromLines aggregates duplicate lines into quantity', () => {
  const items = parser.parseItemsFromLines(targetLines);
  const chobaniOneDollar = items.find((item) => item.name === 'CHOBANI' && item.price === '1');
  assert(chobaniOneDollar);
  assert.equal(chobaniOneDollar.quantity, 3);
});

test('classifyReceiptLayout identifies paired-line mixed receipts', () => {
  const layout = parser.classifyReceiptLayout(targetLines, 0);
  assert.equal(layout.kind, 'mixed');
});

test('parseItemsFromRawText parses text fallback path', () => {
  const text = targetLines.join('\n');
  const items = parser.parseItemsFromRawText(text);
  assert(items.length > 0);
  assert(items.some((item) => item.name.includes('OREO COOKIE')));
});

test('mapReceiptFromDocumentAI composes merchant, tax and items from lines', () => {
  const mapped = parser.mapReceiptFromDocumentAI({
    text: targetLines.join('\n'),
    pages: [{ lines: [] }],
    entities: [],
  });

  assert.equal(mapped.merchantName, 'Target');
  assert.equal(mapped.tax, '5.83');
  assert(mapped.items.length > 4);
  assert.equal(mapped.debug.taxSource, 'totals_diff');
});

test('restaurant receipt parsing keeps core menu items and tax', () => {
  const mapped = parser.mapReceiptFromDocumentAI({
    text: restaurantLines.join('\n'),
    pages: [{ lines: [] }],
    entities: [],
  });

  assert.equal(mapped.tax, '5.01');
  assert(mapped.items.some((item) => item.price === '18'));
  assert(mapped.items.some((item) => item.price === '21.95'));
  assert(mapped.items.some((item) => item.price === '12.75'));
});
