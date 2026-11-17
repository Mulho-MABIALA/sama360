/** Documents : catégories et calculs purs (testés sans base). */
export const DOCUMENT_CATEGORIES = ['admin', 'supplier_invoice', 'contract', 'delivery', 'receipt', 'other'] as const;
export type DocumentCategory = (typeof DOCUMENT_CATEGORIES)[number];

/** Rappel avant l'échéance (bail, assurance, autorisation…). */
export const EXPIRY_WARNING_DAYS = 30;

/** Jours avant l'échéance (négatif : dépassée). null sans date. */
export function daysUntil(expiresOn: string | null, today = new Date()): number | null {
  if (!expiresOn) return null;
  const t = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  const [y, m, d] = expiresOn.split('-').map(Number);
  return Math.round((Date.UTC(y, m - 1, d) - t) / 86_400_000);
}

/** « expiré », « bientôt » (≤ 30 j) ou null. */
export function expiryStatus(days: number | null): 'expired' | 'soon' | null {
  if (days === null) return null;
  if (days < 0) return 'expired';
  return days <= EXPIRY_WARNING_DAYS ? 'soon' : null;
}

/** Nom de fichier lisible et sûr pour le téléchargement : « Bail boutique.pdf ». */
export function downloadName(title: string, mime: string): string {
  const ext =
    mime === 'application/pdf' ? 'pdf' : mime === 'image/png' ? 'png' : mime === 'image/webp' ? 'webp' : 'jpg';
  const base = title
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^A-Za-z0-9 _.-]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
  return `${base || 'document'}.${ext}`;
}
