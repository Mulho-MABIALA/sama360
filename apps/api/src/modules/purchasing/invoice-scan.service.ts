import { Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { TenantContext } from '../../shared/auth/auth.types';
import { env } from '../../shared/config/env';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { LlmClient, LlmUnavailableError } from '../assistant/llm';
import { detectImage } from '../files/image';
import {
  CatalogItem,
  cleanScan,
  Confidence,
  INVOICE_SYSTEM,
  INVOICE_TOOL,
  matchLine,
  matchSupplier,
  normLabel,
} from './invoice-scan';

/** Taille maximale d'une photo envoyée au modèle (l'API refuse au-delà de 5 Mo). */
const MAX_BYTES = 4_500_000;

export interface ScanResult {
  readable: boolean;
  supplier: { id: string | null; name: string | null; phone: string | null };
  number: string | null;
  date: string | null;
  total: number | null;
  linesTotal: number;
  lines: {
    label: string;
    quantity: number;
    unitCost: number;
    total: number;
    productId: string | null;
    confidence: Confidence;
    candidates: { id: string; name: string; unit: string; cost: number; price: number }[];
  }[];
  remaining: number;
}

/**
 * Facture fournisseur en photo : le modèle lit, on contrôle et on rapproche du catalogue.
 * Rien n'est enregistré ici : le commerçant vérifie, puis l'achat est créé par la route habituelle.
 * La photo n'est pas conservée.
 */
@Injectable()
export class InvoiceScanService {
  private readonly log = new Logger('InvoiceScan');

  constructor(
    private readonly dbs: DbService,
    private readonly llm: LlmClient,
  ) {}

  async scan(t: TenantContext, data: Buffer): Promise<ScanResult> {
    if (env().ASSISTANT_PROVIDER === 'off') {
      throw new AppError(
        'SCAN_UNAVAILABLE',
        'La lecture des factures n’est pas encore activée. Saisissez l’achat à la main.',
        503,
      );
    }
    const image = detectImage(data);
    if (!image) throw new AppError('VALIDATION_FAILED', 'Envoyez une photo (JPEG, PNG ou WebP)', 422);
    if (data.length > MAX_BYTES)
      throw new AppError('PAYLOAD_TOO_LARGE', 'Photo trop lourde : reprenez-la ou réduisez-la', 413);

    const limit = env().SCAN_DAILY_LIMIT;
    const used = await this.dbs.withTenant(t.businessId, async (tx) => {
      const r = await tx.execute(sql`
        INSERT INTO core.assistant_usage (business_id, day, scans) VALUES (${t.businessId}, current_date, 1)
        ON CONFLICT (business_id, day) DO UPDATE SET scans = core.assistant_usage.scans + 1
        RETURNING scans`);
      return Number((r.rows[0] as { scans: number }).scans);
    });
    if (used > limit) {
      await this.refund(t.businessId);
      throw new AppError('SCAN_LIMIT', `Limite de ${limit} factures par jour atteinte. Réessayez demain.`, 429);
    }

    let raw: unknown;
    try {
      const res = await this.llm.complete({
        system: INVOICE_SYSTEM,
        model: env().SCAN_MODEL,
        maxTokens: 4096,
        timeoutMs: 90_000,
        tools: [INVOICE_TOOL as unknown as { name: string; description: string; input_schema: object }],
        toolChoice: { type: 'tool', name: INVOICE_TOOL.name },
        messages: [
          {
            role: 'user',
            content: [
              { type: 'image', source: { type: 'base64', media_type: image.mime, data: data.toString('base64') } },
              { type: 'text', text: 'Lis cette facture fournisseur.' },
            ],
          },
        ],
      });
      const block = res.content.find((b) => b.type === 'tool_use' && b.name === INVOICE_TOOL.name);
      raw = block?.type === 'tool_use' ? block.input : undefined;
    } catch (e) {
      await this.refund(t.businessId);
      if (e instanceof LlmUnavailableError) {
        this.log.warn(e.message);
        throw new AppError('SCAN_UNAVAILABLE', 'Lecture impossible pour le moment. Réessayez dans un instant.', 503);
      }
      throw e;
    }

    const scan = cleanScan(raw);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const catalog = await this.catalog(tx);
      const suppliers = (
        await tx.execute(sql`
          SELECT id, name, phone FROM contacts.contacts
          WHERE deleted_at IS NULL AND type IN ('supplier', 'both') ORDER BY updated_at DESC LIMIT 2000`)
      ).rows as { id: string; name: string; phone: string | null }[];
      const supplierId = matchSupplier({ name: scan.supplierName, phone: scan.supplierPhone }, suppliers);
      const aliases = new Map<string, string>();
      if (supplierId) {
        const rows = (
          await tx.execute(
            sql`SELECT label_norm, product_id FROM purchasing.item_aliases WHERE supplier_id = ${supplierId}`,
          )
        ).rows as { label_norm: string; product_id: string }[];
        for (const r of rows) aliases.set(r.label_norm, r.product_id);
      }
      const byId = new Map(catalog.map((p) => [p.id, p]));
      const lines = scan.lines.map((l) => {
        const m = matchLine(l.label, catalog, aliases);
        return {
          ...l,
          productId: m.productId,
          confidence: m.confidence,
          candidates: m.candidates.map((id) => {
            const p = byId.get(id)!;
            return { id, name: p.name, unit: p.unit, cost: p.cost, price: p.price };
          }),
        };
      });
      return {
        readable: scan.readable,
        supplier: {
          id: supplierId,
          name: supplierId ? suppliers.find((s) => s.id === supplierId)!.name : scan.supplierName,
          phone: scan.supplierPhone,
        },
        number: scan.number,
        date: scan.date,
        total: scan.total,
        linesTotal: lines.reduce((s, l) => s + l.total, 0),
        lines,
        remaining: Math.max(0, limit - used),
      };
    });
  }

  private async catalog(tx: Tx) {
    const rows = (
      await tx.execute(sql`
        SELECT id, name, barcode, sku, unit, cost, price FROM catalog.products
        WHERE deleted_at IS NULL AND type = 'product' ORDER BY updated_at DESC LIMIT 5000`)
    ).rows as unknown as (CatalogItem & { unit: string; cost: string | number; price: string | number })[];
    return rows.map((r) => ({ ...r, cost: Number(r.cost), price: Number(r.price) }));
  }

  /** Une lecture qui échoue côté IA ne compte pas dans la limite du jour. */
  private refund(businessId: string) {
    return this.dbs.withTenant(businessId, (tx) =>
      tx.execute(sql`UPDATE core.assistant_usage SET scans = greatest(0, scans - 1) WHERE day = current_date`),
    );
  }
}

/** Retient « ce libellé chez ce fournisseur = ce produit » (appelé à la création de l'achat). */
export async function rememberAliases(
  tx: Tx,
  businessId: string,
  supplierId: string,
  lines: { scanLabel?: string | null; productId: string }[],
) {
  for (const l of lines) {
    if (!l.scanLabel) continue;
    const norm = normLabel(l.scanLabel);
    if (!norm) continue;
    await tx.execute(sql`
      INSERT INTO purchasing.item_aliases (business_id, supplier_id, label_norm, product_id)
      VALUES (${businessId}, ${supplierId}, ${norm}, ${l.productId})
      ON CONFLICT (business_id, supplier_id, label_norm) DO UPDATE SET product_id = excluded.product_id, updated_at = now()`);
  }
}
