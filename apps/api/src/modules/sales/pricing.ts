/**
 * Calcul des montants d'une vente. Fonction pure : aucun accès base.
 * Tous les montants sont des entiers FCFA ; les prix sont TTC (la TVA détaillée
 * relève du module facturation).
 */
export interface LineInput {
  productId: string | null;
  name: string;
  quantity: number;
  unitPrice: number;
  unitCost: number;
  discount: number;
  trackStock: boolean;
  serials?: string[] | null;
  warrantyUntil?: string | null;
}

export interface PricedLine extends LineInput {
  total: number;
}

export interface SaleTotals {
  lines: PricedLine[];
  subtotal: number;
  discount: number;
  total: number;
  costTotal: number;
}

export class PricingError extends Error {}

export function priceSale(lines: LineInput[], saleDiscount = 0): SaleTotals {
  if (lines.length === 0) throw new PricingError('La vente doit contenir au moins un article');
  const priced = lines.map((l) => {
    const gross = Math.round(l.quantity * l.unitPrice);
    if (l.discount > gross) throw new PricingError(`Réduction supérieure au montant de « ${l.name} »`);
    return { ...l, total: gross - l.discount };
  });
  const subtotal = priced.reduce((s, l) => s + l.total, 0);
  if (saleDiscount > subtotal) throw new PricingError('Réduction supérieure au montant de la vente');
  const costTotal = priced.reduce((s, l) => s + Math.round(l.quantity * l.unitCost), 0);
  return { lines: priced, subtotal, discount: saleDiscount, total: subtotal - saleDiscount, costTotal };
}

/** Bénéfice brut = chiffre d'affaires − coût d'achat des articles vendus. */
export function grossMargin(total: number, costTotal: number): number {
  return total - costTotal;
}

/**
 * Prix unitaire d'un produit du catalogue : le prix saisi s'il y en a un,
 * sinon le prix de gros dès la quantité minimale, sinon le prix normal.
 */
export function catalogUnitPrice(
  p: { price: number; wholesalePrice?: number | null; wholesaleMinQty?: number | null },
  quantity: number,
  explicit?: number,
): number {
  if (explicit !== undefined) return explicit;
  if (p.wholesalePrice != null && p.wholesaleMinQty != null && quantity >= p.wholesaleMinQty) return p.wholesalePrice;
  return p.price;
}
