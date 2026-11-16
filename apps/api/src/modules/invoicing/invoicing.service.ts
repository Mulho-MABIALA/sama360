import { HttpStatus, Injectable } from '@nestjs/common';
import { and, asc, eq, inArray, isNull, sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import {
  contacts,
  documentLines,
  documents,
  DocumentKind,
  invoicePayments,
  products,
  users,
} from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { InventoryService } from '../inventory/inventory.service';
import { LineInput, priceSale, PricingError } from '../sales/pricing';

export interface DocumentLineInput {
  productId?: string | null;
  name?: string;
  description?: string | null;
  quantity: number;
  unitPrice?: number;
  discount?: number;
}

export interface DocumentInput {
  id?: string;
  kind: DocumentKind;
  customerId: string;
  lines: DocumentLineInput[];
  discount?: number;
  issueDate?: string;
  dueDate?: string | null;
  note?: string | null;
}

export interface PaymentInput {
  id?: string;
  amount: number;
  method: string;
  reference?: string | null;
  paidAt?: Date;
}

const PREFIX: Record<DocumentKind, string> = { quote: 'DEV', invoice: 'FAC' };
const today = () => new Date().toISOString().slice(0, 10);
export const addDays = (day: string, n: number) =>
  new Date(new Date(`${day}T00:00:00Z`).getTime() + n * 86_400_000).toISOString().slice(0, 10);

/** Statut d'une facture selon ce qui a été payé. */
export function invoiceStatus(total: number, paid: number): 'unpaid' | 'partial' | 'paid' {
  if (paid >= total) return 'paid';
  return paid > 0 ? 'partial' : 'unpaid';
}

@Injectable()
export class InvoicingService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly inventory: InventoryService,
  ) {}

  /** Crée un devis ou une facture. Idempotent si le mobile fournit l'identifiant. */
  async create(businessId: string, userId: string, input: DocumentInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      if (input.id) {
        const existing = await this.findFull(tx, input.id);
        if (existing) return { created: false, document: existing };
      }
      await this.assertCustomer(tx, input.customerId);
      const totals = await this.price(tx, input.lines, input.discount ?? 0);

      const id = input.id ?? newId();
      const issueDate = input.issueDate ?? today();
      const dueDate =
        input.dueDate !== undefined ? input.dueDate : input.kind === 'quote' ? addDays(issueDate, 30) : null;
      if (dueDate && dueDate < issueDate) {
        throw new AppError('VALIDATION_FAILED', 'L’échéance précède la date du document', 422);
      }
      await this.insertDocument(tx, {
        id,
        businessId,
        userId,
        kind: input.kind,
        customerId: input.customerId,
        issueDate,
        dueDate,
        note: input.note ?? null,
        totals,
        sourceId: null,
      });
      return { created: true, document: (await this.findFull(tx, id))! };
    });
  }

  /** Modifie un devis tant qu'il n'est pas transformé en facture. Une facture ne se modifie pas. */
  async updateQuote(businessId: string, id: string, input: Omit<DocumentInput, 'id' | 'kind'>) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const doc = await this.lock(tx, id);
      if (doc.kind !== 'quote' || doc.status === 'invoiced') {
        throw new AppError(
          'DOCUMENT_LOCKED',
          doc.kind === 'invoice'
            ? 'Une facture émise ne se modifie pas : annulez-la et créez-en une nouvelle'
            : 'Ce devis est déjà transformé en facture',
          HttpStatus.CONFLICT,
        );
      }
      await this.assertCustomer(tx, input.customerId);
      const totals = await this.price(tx, input.lines, input.discount ?? 0);
      const issueDate = input.issueDate ?? doc.issueDate;
      const dueDate = input.dueDate !== undefined ? input.dueDate : doc.dueDate;
      await tx.delete(documentLines).where(eq(documentLines.documentId, id));
      await tx.insert(documentLines).values(this.lineRows(businessId, id, totals.lines));
      await tx
        .update(documents)
        .set({
          customerId: input.customerId,
          issueDate,
          dueDate,
          note: input.note ?? null,
          subtotal: totals.subtotal,
          discount: totals.discount,
          total: totals.total,
          status: 'pending',
          updatedAt: new Date(),
        })
        .where(eq(documents.id, id));
      return (await this.findFull(tx, id))!;
    });
  }

  /** Le client accepte ou refuse le devis. */
  async setQuoteStatus(businessId: string, id: string, status: 'accepted' | 'declined' | 'pending') {
    return this.dbs.withTenant(businessId, async (tx) => {
      const doc = await this.lock(tx, id);
      if (doc.kind !== 'quote') throw new AppError('VALIDATION_FAILED', 'Seul un devis peut être accepté ou refusé', 422);
      if (doc.status === 'invoiced') {
        throw new AppError('DOCUMENT_LOCKED', 'Ce devis est déjà transformé en facture', HttpStatus.CONFLICT);
      }
      await tx.update(documents).set({ status, updatedAt: new Date() }).where(eq(documents.id, id));
      return (await this.findFull(tx, id))!;
    });
  }

  /** Transforme un devis en facture (une seule fois : renvoie la facture existante sinon). */
  async convert(businessId: string, userId: string, quoteId: string, input: { dueDate?: string | null }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const quote = await this.lock(tx, quoteId);
      if (quote.kind !== 'quote') throw new AppError('VALIDATION_FAILED', 'Seul un devis se transforme en facture', 422);
      const [already] = await tx
        .select({ id: documents.id })
        .from(documents)
        .where(eq(documents.sourceId, quoteId))
        .limit(1);
      if (already) return { created: false, document: (await this.findFull(tx, already.id))! };
      if (quote.status === 'declined') {
        throw new AppError('DOCUMENT_LOCKED', 'Ce devis a été refusé : remettez-le en attente avant de facturer', 409);
      }

      const lines = await tx
        .select()
        .from(documentLines)
        .where(eq(documentLines.documentId, quoteId))
        .orderBy(asc(documentLines.position));
      const id = newId();
      const issueDate = today();
      await this.insertDocument(tx, {
        id,
        businessId,
        userId,
        kind: 'invoice',
        customerId: quote.customerId,
        issueDate,
        dueDate: input.dueDate ?? null,
        note: quote.note,
        sourceId: quoteId,
        totals: {
          subtotal: quote.subtotal,
          discount: quote.discount,
          total: quote.total,
          lines: lines.map((l) => ({
            productId: l.productId,
            name: l.name,
            description: l.description,
            quantity: l.quantity,
            unitPrice: l.unitPrice,
            unitCost: l.unitCost,
            discount: l.discount,
            total: l.total,
            trackStock: l.trackStock,
          })),
        },
      });
      await tx.update(documents).set({ status: 'invoiced', updatedAt: new Date() }).where(eq(documents.id, quoteId));
      return { created: true, document: (await this.findFull(tx, id))! };
    });
  }

  /** Paiement d'une facture (idempotent par identifiant). */
  async addPayment(businessId: string, userId: string, invoiceId: string, input: PaymentInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      if (input.id) {
        const [p] = await tx.select().from(invoicePayments).where(eq(invoicePayments.id, input.id)).limit(1);
        if (p) return { created: false, document: (await this.findFull(tx, p.documentId))! };
      }
      const doc = await this.lock(tx, invoiceId);
      if (doc.kind !== 'invoice') throw new AppError('VALIDATION_FAILED', 'Un paiement s’enregistre sur une facture', 422);
      if (doc.status === 'cancelled') {
        throw new AppError('DOCUMENT_LOCKED', 'Cette facture est annulée', HttpStatus.CONFLICT);
      }
      const due = doc.total - doc.paid;
      if (input.amount > due) {
        throw new AppError('PAYMENT_EXCEEDS_DUE', `Le montant dépasse le reste à payer (${due} F)`, 422, { due });
      }
      await tx.insert(invoicePayments).values({
        id: input.id ?? newId(),
        businessId,
        documentId: invoiceId,
        method: input.method,
        amount: input.amount,
        reference: input.reference ?? null,
        paidAt: input.paidAt ?? new Date(),
        createdBy: userId,
      });
      const paid = doc.paid + input.amount;
      await tx
        .update(documents)
        .set({ paid, status: invoiceStatus(doc.total, paid), updatedAt: new Date() })
        .where(eq(documents.id, invoiceId));
      return { created: true, document: (await this.findFull(tx, invoiceId))! };
    });
  }

  /** Annule une facture sans paiement : la marchandise revient en stock, le devis redevient facturable. */
  async cancel(businessId: string, userId: string, invoiceId: string, reason: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const doc = await this.lock(tx, invoiceId);
      if (doc.kind !== 'invoice') throw new AppError('VALIDATION_FAILED', 'Seule une facture s’annule', 422);
      if (doc.status === 'cancelled') {
        throw new AppError('DOCUMENT_LOCKED', 'Cette facture est déjà annulée', HttpStatus.CONFLICT);
      }
      if (doc.paid > 0) {
        throw new AppError(
          'INVOICE_HAS_PAYMENTS',
          'Cette facture a déjà reçu des paiements : elle ne peut pas être annulée',
          HttpStatus.CONFLICT,
          { paid: doc.paid },
        );
      }
      await tx
        .update(documents)
        .set({ status: 'cancelled', cancelledAt: new Date(), cancelReason: reason, sourceId: null, updatedAt: new Date() })
        .where(eq(documents.id, invoiceId));
      if (doc.sourceId) {
        await tx.update(documents).set({ status: 'accepted', updatedAt: new Date() }).where(eq(documents.id, doc.sourceId));
      }
      const lines = await tx.select().from(documentLines).where(eq(documentLines.documentId, invoiceId));
      if (doc.warehouseId && lines.some((l) => l.trackStock)) {
        await this.outbox.record(tx, {
          type: 'invoice.cancelled',
          businessId,
          aggregateId: invoiceId,
          actorId: userId,
          payload: {
            invoiceId,
            number: doc.number,
            warehouseId: doc.warehouseId,
            items: lines.map((l) => ({
              productId: l.productId,
              quantity: l.quantity,
              unitCost: l.unitCost,
              trackStock: l.trackStock,
            })),
          },
        });
      }
      return (await this.findFull(tx, invoiceId))!;
    });
  }

  // ---------- lecture ----------

  async findFull(tx: Tx, id: string) {
    const [doc] = await tx.select().from(documents).where(eq(documents.id, id)).limit(1);
    if (!doc) return null;
    const [lines, payments, customer, author, related] = await Promise.all([
      tx.select().from(documentLines).where(eq(documentLines.documentId, id)).orderBy(asc(documentLines.position)),
      tx.select().from(invoicePayments).where(eq(invoicePayments.documentId, id)).orderBy(asc(invoicePayments.paidAt)),
      tx
        .select({
          id: contacts.id,
          name: contacts.name,
          phone: contacts.phone,
          email: contacts.email,
          address: contacts.address,
        })
        .from(contacts)
        .where(eq(contacts.id, doc.customerId))
        .limit(1),
      tx.select({ fullName: users.fullName }).from(users).where(eq(users.id, doc.createdBy)).limit(1),
      // Devis → facture créée ; facture → devis d'origine
      doc.kind === 'quote'
        ? tx
            .select({ id: documents.id, number: documents.number })
            .from(documents)
            .where(eq(documents.sourceId, id))
            .limit(1)
        : doc.sourceId
          ? tx
              .select({ id: documents.id, number: documents.number })
              .from(documents)
              .where(eq(documents.id, doc.sourceId))
              .limit(1)
          : Promise.resolve([]),
    ]);
    const { businessId: _b, warehouseId: _w, ...rest } = doc;
    return {
      ...rest,
      due: doc.total - doc.paid,
      overdue: isOverdue(doc),
      customer: customer[0] ?? null,
      createdByName: author[0]?.fullName ?? null,
      invoice: doc.kind === 'quote' ? (related[0] ?? null) : null,
      quote: doc.kind === 'invoice' ? (related[0] ?? null) : null,
      lines: lines.map(({ businessId: _x, documentId: _d, unitCost: _c, ...l }) => l),
      payments: payments.map(({ businessId: _x, documentId: _d, ...p }) => p),
    };
  }

  // ---------- interne ----------

  private async insertDocument(
    tx: Tx,
    d: {
      id: string;
      businessId: string;
      userId: string;
      kind: DocumentKind;
      customerId: string;
      issueDate: string;
      dueDate: string | null;
      note: string | null;
      sourceId: string | null;
      totals: {
        subtotal: number;
        discount: number;
        total: number;
        lines: (LineInput & { total: number; description?: string | null })[];
      };
    },
  ) {
    const number = await this.nextNumber(tx, d.businessId, d.kind, Number(d.issueDate.slice(0, 4)));
    const isInvoice = d.kind === 'invoice';
    const warehouseId = isInvoice ? await this.inventory.defaultWarehouse(tx, d.businessId) : null;
    await tx.insert(documents).values({
      id: d.id,
      businessId: d.businessId,
      kind: d.kind,
      number,
      status: isInvoice ? invoiceStatus(d.totals.total, 0) : 'pending',
      customerId: d.customerId,
      issueDate: d.issueDate,
      dueDate: d.dueDate,
      subtotal: d.totals.subtotal,
      discount: d.totals.discount,
      total: d.totals.total,
      note: d.note,
      warehouseId,
      sourceId: d.sourceId,
      createdBy: d.userId,
    });
    await tx.insert(documentLines).values(this.lineRows(d.businessId, d.id, d.totals.lines));

    // Une facture émise fait sortir la marchandise (comme une vente)
    if (isInvoice && warehouseId && d.totals.lines.some((l) => l.trackStock)) {
      await this.outbox.record(tx, {
        type: 'invoice.issued',
        businessId: d.businessId,
        aggregateId: d.id,
        actorId: d.userId,
        payload: {
          invoiceId: d.id,
          number,
          customerId: d.customerId,
          warehouseId,
          total: d.totals.total,
          items: d.totals.lines.map((l) => ({
            productId: l.productId,
            quantity: l.quantity,
            unitCost: l.unitCost,
            trackStock: l.trackStock,
          })),
        },
      });
    }
  }

  private lineRows(
    businessId: string,
    documentId: string,
    lines: (LineInput & { total: number; description?: string | null })[],
  ) {
    return lines.map((l, i) => ({
      id: newId(),
      businessId,
      documentId,
      position: i + 1,
      productId: l.productId,
      name: l.name,
      description: l.description ?? null,
      quantity: l.quantity,
      unitPrice: l.unitPrice,
      unitCost: l.unitCost,
      discount: l.discount,
      total: l.total,
      trackStock: l.trackStock,
    }));
  }

  /** Prix des lignes : produits du catalogue (nom, prix et coût de référence) ou lignes libres. */
  private async price(tx: Tx, input: DocumentLineInput[], discount: number) {
    const ids = [...new Set(input.map((l) => l.productId).filter((x): x is string => !!x))];
    const catalog = ids.length
      ? await tx
          .select({
            id: products.id,
            name: products.name,
            price: products.price,
            cost: products.cost,
            trackStock: products.trackStock,
          })
          .from(products)
          .where(and(inArray(products.id, ids), isNull(products.deletedAt)))
      : [];
    const byId = new Map(catalog.map((p) => [p.id, p]));
    const lines = input.map((l, i) => {
      if (l.productId) {
        const p = byId.get(l.productId);
        if (!p) throw new AppError('NOT_FOUND', `Produit introuvable (ligne ${i + 1})`, HttpStatus.NOT_FOUND);
        return {
          productId: p.id,
          name: l.name?.trim() || p.name,
          description: l.description ?? null,
          quantity: l.quantity,
          unitPrice: l.unitPrice ?? p.price,
          unitCost: p.cost,
          discount: l.discount ?? 0,
          trackStock: p.trackStock,
        };
      }
      if (!l.name || l.unitPrice === undefined) {
        throw new AppError('VALIDATION_FAILED', `Ligne ${i + 1} : désignation et prix requis`, 422);
      }
      return {
        productId: null,
        name: l.name,
        description: l.description ?? null,
        quantity: l.quantity,
        unitPrice: l.unitPrice,
        unitCost: 0,
        discount: l.discount ?? 0,
        trackStock: false,
      };
    });
    try {
      const t = priceSale(lines, discount);
      return { ...t, lines: t.lines.map((l, i) => ({ ...l, description: lines[i].description })) };
    } catch (e) {
      if (e instanceof PricingError) throw new AppError('VALIDATION_FAILED', e.message, 422);
      throw e;
    }
  }

  private async lock(tx: Tx, id: string) {
    const [doc] = await tx.select().from(documents).where(eq(documents.id, id)).for('update').limit(1);
    if (!doc) throw AppError.notFound('Document');
    return doc;
  }

  private async assertCustomer(tx: Tx, customerId: string) {
    const [c] = await tx
      .select({ id: contacts.id, type: contacts.type, deletedAt: contacts.deletedAt })
      .from(contacts)
      .where(eq(contacts.id, customerId))
      .limit(1);
    if (!c || c.deletedAt) throw AppError.notFound('Client');
    if (c.type === 'supplier') throw new AppError('VALIDATION_FAILED', 'Ce contact est un fournisseur', 422);
  }

  private async nextNumber(tx: Tx, businessId: string, kind: DocumentKind, year: number): Promise<string> {
    const res = await tx.execute(sql`
      INSERT INTO invoicing.sequences (business_id, key, year, last_value) VALUES (${businessId}, ${kind}, ${year}, 1)
      ON CONFLICT (business_id, key, year) DO UPDATE SET last_value = invoicing.sequences.last_value + 1
      RETURNING last_value`);
    const n = (res.rows[0] as { last_value: number }).last_value;
    return `${PREFIX[kind]}-${year}-${String(n).padStart(4, '0')}`;
  }
}

/** Facture en retard : échéance passée et pas entièrement payée. */
export function isOverdue(
  doc: { kind: string; status: string; dueDate: string | null },
  day = new Date().toISOString().slice(0, 10),
): boolean {
  return doc.kind === 'invoice' && (doc.status === 'unpaid' || doc.status === 'partial') && !!doc.dueDate && doc.dueDate < day;
}
