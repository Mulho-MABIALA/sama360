/**
 * Lecture d'une facture fournisseur en photo : consignes au modèle, contrôle de sa réponse,
 * rapprochement des libellés avec le catalogue. Fonctions pures (testées sans base ni API).
 */
import { z } from 'zod';

export const INVOICE_TOOL = {
  name: 'record_invoice',
  description: 'Enregistre le contenu lu sur la facture ou le bon de livraison du fournisseur.',
  input_schema: {
    type: 'object',
    properties: {
      readable: {
        type: 'boolean',
        description: 'false si la photo ne montre pas une facture lisible (floue, coupée, autre chose).',
      },
      supplier_name: { type: ['string', 'null'], description: 'Nom du fournisseur (en-tête), pas celui du client.' },
      supplier_phone: { type: ['string', 'null'] },
      invoice_number: { type: ['string', 'null'] },
      invoice_date: { type: ['string', 'null'], description: 'Date au format AAAA-MM-JJ.' },
      currency: { type: ['string', 'null'] },
      lines: {
        type: 'array',
        description:
          'Une entrée par article facturé, dans l’ordre. Sans les lignes de total, TVA, remise ou transport.',
        items: {
          type: 'object',
          properties: {
            label: {
              type: 'string',
              description: 'Désignation telle qu’écrite (avec le conditionnement : 25KG, 5L…).',
            },
            quantity: { type: 'number' },
            unit_price: { type: ['number', 'null'], description: 'Prix unitaire en francs, sans séparateur.' },
            line_total: { type: ['number', 'null'] },
          },
          required: ['label', 'quantity'],
        },
      },
      total: { type: ['number', 'null'], description: 'Net à payer.' },
    },
    required: ['readable', 'lines'],
  },
} as const;

export const INVOICE_SYSTEM = [
  'Tu lis des factures et bons de livraison de fournisseurs pour des commerçants d’Afrique de l’Ouest et centrale.',
  'Les montants sont en francs CFA, sans centimes : « 12.500 », « 12 500 » et « 12,500 » valent 12500.',
  'Recopie les désignations telles quelles ; ne les traduis pas et ne les corrige pas.',
  'N’invente rien : une valeur illisible vaut null. Réponds uniquement avec l’outil record_invoice.',
].join(' ');

const num = z.preprocess(
  (v) => (typeof v === 'string' ? Number(v.replace(/[\s.,](?=\d{3}\b)/g, '').replace(',', '.')) : v),
  z.number().finite(),
);

const Scanned = z.object({
  readable: z.boolean().default(true),
  supplier_name: z.string().trim().max(120).nullish(),
  supplier_phone: z.string().trim().max(40).nullish(),
  invoice_number: z.string().trim().max(60).nullish(),
  invoice_date: z.string().trim().nullish(),
  total: num.nullish(),
  lines: z
    .array(
      z.object({
        label: z.string().trim().min(1).max(160),
        quantity: num.nullish(),
        unit_price: num.nullish(),
        line_total: num.nullish(),
      }),
    )
    .max(200)
    .default([]),
});

export interface ScannedLine {
  label: string;
  quantity: number;
  unitCost: number;
  total: number;
}
export interface ScannedInvoice {
  readable: boolean;
  supplierName: string | null;
  supplierPhone: string | null;
  number: string | null;
  date: string | null;
  total: number | null;
  lines: ScannedLine[];
}

/** Valide et nettoie la réponse du modèle (il peut se tromper de type ou d'échelle). */
export function cleanScan(raw: unknown): ScannedInvoice {
  const r = Scanned.safeParse(raw);
  if (!r.success)
    return {
      readable: false,
      supplierName: null,
      supplierPhone: null,
      number: null,
      date: null,
      total: null,
      lines: [],
    };
  const v = r.data;
  const lines: ScannedLine[] = [];
  for (const l of v.lines) {
    let qty = l.quantity && l.quantity > 0 ? l.quantity : null;
    let unit = l.unit_price && l.unit_price >= 0 ? Math.round(l.unit_price) : null;
    const total = l.line_total && l.line_total >= 0 ? Math.round(l.line_total) : null;
    if (qty === null && unit && total) qty = Math.round((total / unit) * 1000) / 1000;
    qty ??= 1;
    if (unit === null && total !== null) unit = Math.round(total / qty);
    unit ??= 0;
    lines.push({
      label: l.label,
      quantity: Math.round(qty * 1000) / 1000,
      unitCost: unit,
      total: Math.round(unit * qty),
    });
  }
  const date = v.invoice_date && /^\d{4}-\d{2}-\d{2}$/.test(v.invoice_date) ? v.invoice_date : null;
  return {
    readable: v.readable && lines.length > 0,
    supplierName: v.supplier_name || null,
    supplierPhone: v.supplier_phone || null,
    number: v.invoice_number || null,
    date,
    total: v.total && v.total > 0 ? Math.round(v.total) : null,
    lines,
  };
}

/** « RIZ Brisé 25 Kg » → « riz brise 25kg » : sans accents, ponctuation ni espace avant l'unité. */
export function normLabel(s: string): string {
  return s
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/(\d)[,.](\d)/g, '$1.$2')
    .replace(/[^a-z0-9.]+/g, ' ')
    .replace(/(\d)\s+(kg|g|l|cl|ml|m|cm|pcs?|x)\b/g, '$1$2')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 160);
}

const STOP = new Set([
  'de',
  'du',
  'des',
  'la',
  'le',
  'les',
  'en',
  'et',
  'a',
  'au',
  'sac',
  'carton',
  'ctn',
  'pqt',
  'paquet',
]);
const tokens = (s: string) =>
  normLabel(s)
    .split(' ')
    .filter((t) => t.length > 1 && !STOP.has(t));
const isSize = (t: string) => /^\d+(\.\d+)?(kg|g|l|cl|ml|m|cm|x)$/.test(t);

/** Ressemblance 0…1 entre un libellé de facture et un nom de produit. Un conditionnement différent (5L ≠ 1L) pénalise fort. */
export function similarity(label: string, name: string): number {
  const a = new Set(tokens(label));
  const b = new Set(tokens(name));
  if (!a.size || !b.size) return 0;
  let common = 0;
  for (const t of a) {
    if (b.has(t)) common++;
    else if (t.length >= 4 && [...b].some((u) => u.length >= 4 && (u.startsWith(t) || t.startsWith(u)))) common += 0.7;
  }
  let score = (2 * common) / (a.size + b.size);
  const sa = [...a].filter(isSize);
  const sb = [...b].filter(isSize);
  if (sa.length && sb.length && !sa.some((x) => sb.includes(x))) score *= 0.35;
  return Math.min(1, score);
}

export interface CatalogItem {
  id: string;
  name: string;
  barcode: string | null;
  sku: string | null;
}
export type Confidence = 'memory' | 'high' | 'low' | 'none';

/** Meilleur produit pour un libellé : mémoire du fournisseur, code-barres, puis ressemblance du nom. */
export function matchLine(
  label: string,
  catalog: CatalogItem[],
  aliases: Map<string, string>,
): { productId: string | null; confidence: Confidence; candidates: string[] } {
  const remembered = aliases.get(normLabel(label));
  if (remembered && catalog.some((p) => p.id === remembered)) {
    return { productId: remembered, confidence: 'memory', candidates: [remembered] };
  }
  const codes: string[] = label.match(/\d{8,14}/g) ?? [];
  const byCode = catalog.find(
    (p) => (p.barcode && codes.includes(p.barcode)) || (p.sku && normLabel(p.sku) === normLabel(label)),
  );
  if (byCode) return { productId: byCode.id, confidence: 'high', candidates: [byCode.id] };
  const ranked = catalog
    .map((p) => ({ id: p.id, s: similarity(label, p.name) }))
    .filter((x) => x.s >= 0.34)
    .sort((x, y) => y.s - x.s)
    .slice(0, 3);
  const best = ranked[0];
  if (!best) return { productId: null, confidence: 'none', candidates: [] };
  const clear = !ranked[1] || best.s - ranked[1].s >= 0.15;
  return {
    productId: best.s >= 0.5 ? best.id : null,
    confidence: best.s >= 0.72 && clear ? 'high' : best.s >= 0.5 ? 'low' : 'none',
    candidates: ranked.map((x) => x.id),
  };
}

/** Fournisseur déjà connu : même numéro (9 derniers chiffres) ou nom très proche. */
export function matchSupplier(
  scanned: { name: string | null; phone: string | null },
  suppliers: { id: string; name: string; phone: string | null }[],
): string | null {
  const digits = (s: string | null) => (s ?? '').replace(/\D/g, '').slice(-9);
  const phone = digits(scanned.phone);
  if (phone.length >= 8) {
    const byPhone = suppliers.find((s) => digits(s.phone) === phone);
    if (byPhone) return byPhone.id;
  }
  if (!scanned.name) return null;
  const strip = (n: string) => n.replace(/\b(sarl|sa|suarl|sas|ets|etablissements?|gie|ste|societe)\b/gi, '');
  let best: { id: string; s: number } | null = null;
  for (const s of suppliers) {
    const sc = similarity(strip(scanned.name), strip(s.name));
    if (sc >= 0.6 && (!best || sc > best.s)) best = { id: s.id, s: sc };
  }
  return best?.id ?? null;
}
