import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Chariow (chariow.dev) : page de paiement hébergée (Wave, Orange Money, MoMo, carte…)
 * et Pulses (webhooks) signés pour confirmer les ventes.
 */

export interface ChariowCheckoutInput {
  productId: string;
  email: string;
  firstName: string;
  lastName: string;
  phone: { number: string; countryCode: string };
  redirectUrl?: string;
  metadata: Record<string, string>;
  customerIp?: string;
}

export interface ChariowCheckoutResult {
  /** payment : rediriger vers checkoutUrl ; completed : déjà payé (prix 0) ; already_purchased */
  step: string;
  checkoutUrl: string | null;
  saleId: string | null;
  message: string | null;
}

export class ChariowError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

/** Nom en deux parties (Chariow demande prénom et nom, 50 caractères chacun). */
export function splitName(full: string | null | undefined, fallback: string): { first: string; last: string } {
  const parts = (full ?? '').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return { first: fallback.slice(0, 50), last: fallback.slice(0, 50) };
  if (parts.length === 1) return { first: parts[0].slice(0, 50), last: parts[0].slice(0, 50) };
  return { first: parts[0].slice(0, 50), last: parts.slice(1).join(' ').slice(0, 50) };
}

export async function createCheckout(
  baseUrl: string,
  apiKey: string,
  input: ChariowCheckoutInput,
  fetchImpl: typeof fetch = fetch,
): Promise<ChariowCheckoutResult> {
  const res = await fetchImpl(`${baseUrl.replace(/\/$/, '')}/checkout`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({
      product_id: input.productId,
      email: input.email,
      first_name: input.firstName,
      last_name: input.lastName,
      phone: { number: input.phone.number, country_code: input.phone.countryCode },
      ...(input.redirectUrl ? { redirect_url: input.redirectUrl } : {}),
      ...(input.customerIp ? { customer_ip: input.customerIp } : {}),
      custom_metadata: input.metadata,
    }),
    signal: AbortSignal.timeout(20_000),
  });
  const body = (await res.json().catch(() => ({}))) as {
    message?: string;
    data?: { step?: string; message?: string; payment?: { checkout_url?: string }; purchase?: { id?: string } };
  };
  if (!res.ok) throw new ChariowError(body.message ?? `Chariow a répondu ${res.status}`, res.status);
  const d = body.data ?? {};
  return {
    step: d.step ?? 'unknown',
    checkoutUrl: d.payment?.checkout_url ?? null,
    saleId: d.purchase?.id ?? null,
    message: d.message ?? null,
  };
}

/** Signature d'un Pulse : en-tête x-chariow-signature = "sha256=" + HMAC-SHA256(corps brut, secret) en hexadécimal. */
export function verifyPulseSignature(raw: Buffer, header: string | undefined, secret: string): boolean {
  if (!header || !raw?.length) return false;
  const given = header.trim().replace(/^sha256=/, '');
  const expected = createHmac('sha256', secret).update(raw).digest('hex');
  const a = Buffer.from(given, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Ce dont on a besoin dans un Pulse de vente. */
export interface PulseSale {
  event: string;
  saleId: string | null;
  productId: string | null;
  metadata: Record<string, unknown>;
  amount: number | null;
  currency: string | null;
}

export function readPulse(payload: unknown): PulseSale {
  const p = (payload ?? {}) as Record<string, any>;
  const sale = (p.sale ?? p.data?.sale ?? {}) as Record<string, any>;
  const product = (p.product ?? sale.product ?? {}) as Record<string, any>;
  const pay = (sale.payment ?? {}) as Record<string, any>;
  const amountOf = (v: unknown): number | null => {
    if (typeof v === 'number') return v;
    if (v && typeof v === 'object' && 'value' in (v as object)) return Number((v as { value: unknown }).value) || null;
    if (typeof v === 'string' && v.trim() !== '') return Number(v) || null;
    return null;
  };
  const currencyOf = (v: unknown): string | null =>
    v && typeof v === 'object' && 'currency' in (v as object) ? String((v as { currency: unknown }).currency) : null;
  return {
    event: String(p.event ?? p.type ?? ''),
    saleId: (sale.id as string) ?? null,
    productId: (product.id as string) ?? (sale.product_id as string) ?? null,
    metadata: (sale.custom_metadata ?? p.custom_metadata ?? {}) as Record<string, unknown>,
    amount: amountOf(pay.amount) ?? amountOf(sale.amount),
    currency: currencyOf(pay.amount) ?? currencyOf(sale.amount) ?? (sale.currency as string) ?? null,
  };
}
