/**
 * Enveloppe commune de tous les événements de domaine Sama360.
 * Un événement décrit un fait passé ; son payload ne contient que des
 * identifiants et les valeurs nécessaires aux abonnés.
 */
export interface DomainEvent<T extends string = string, P = unknown> {
  id: string; // UUID v7
  type: T; // ex. 'business.created'
  version: number; // version du schéma de payload
  businessId: string; // tenant
  aggregateId: string; // id de l'entité concernée
  actorId?: string | null; // utilisateur à l'origine
  occurredAt: string; // ISO 8601
  payload: P;
}

// ---------- Socle ----------

export type BusinessCreated = DomainEvent<
  'business.created',
  { businessId: string; ownerId: string; name: string; category: string | null }
>;

export type MemberInvited = DomainEvent<
  'member.invited',
  { membershipId: string; userId: string; phone: string; roleKey: string; invitedBy: string }
>;

export type ContactCreated = DomainEvent<
  'contact.created',
  { contactId: string; type: 'customer' | 'supplier' | 'both'; name: string; phone: string | null }
>;

export type ProductUpdated = DomainEvent<
  'product.updated',
  { productId: string; price: number; cost: number; published: boolean }
>;

// ---------- Ventes et stock ----------

export interface SaleLine {
  productId: string | null;
  quantity: number;
  unitCost: number;
  trackStock: boolean;
}

export type SaleCompleted = DomainEvent<
  'sale.completed',
  {
    saleId: string;
    number: string;
    customerId: string | null;
    warehouseId: string;
    items: SaleLine[];
    total: number;
    paid: number;
    due: number; // > 0 = vente (partiellement) à crédit
  }
>;

export type SaleVoided = DomainEvent<
  'sale.voided',
  { saleId: string; number: string; customerId: string | null; warehouseId: string; items: SaleLine[]; due: number }
>;

export type CustomerRepaymentRecorded = DomainEvent<
  'customer.repayment_recorded',
  { entryId: string; customerId: string; amount: number; method: string }
>;

/** Ajustement manuel du carnet de crédit (reprise d'une ancienne dette, remise de dette). */
export type CustomerBalanceAdjusted = DomainEvent<
  'customer.balance_adjusted',
  { entryId: string; customerId: string; amount: number; reason: string }
>;

/** Marchandise reçue d'un fournisseur : elle est entrée en stock dans la même transaction. */
export type PurchaseReceived = DomainEvent<
  'purchase.received',
  { orderId: string; receiptId: string; number: string; supplierId: string; total: number; complete: boolean }
>;

/** Paiement à un fournisseur. */
export type SupplierPaymentRecorded = DomainEvent<
  'supplier.payment_recorded',
  { paymentId: string; orderId: string; supplierId: string; amount: number; method: string }
>;

/** Commande passée sur la boutique en ligne. */
export type ShopOrderPlaced = DomainEvent<
  'shop.order_placed',
  { orderId: string; number: string; total: number; customerName: string; customerPhone: string; mode: string }
>;

/** Changement de statut d'une commande en ligne (confirmée, prête, livrée, annulée…). */
export type ShopOrderStatusChanged = DomainEvent<
  'shop.order_status_changed',
  { orderId: string; number: string; from: string; to: string; saleId: string | null }
>;

/** Facture émise : la marchandise sort du stock. */
export type InvoiceIssued = DomainEvent<
  'invoice.issued',
  { invoiceId: string; number: string; customerId: string; warehouseId: string; items: SaleLine[]; total: number }
>;

/** Facture annulée : la marchandise revient en stock. */
export type InvoiceCancelled = DomainEvent<
  'invoice.cancelled',
  { invoiceId: string; number: string; warehouseId: string; items: SaleLine[] }
>;

export type StockLow = DomainEvent<
  'stock.low',
  { productId: string; warehouseId: string; name: string; onHand: number; threshold: number }
>;

export type ExpenseRecorded = DomainEvent<
  'expense.recorded',
  { expenseId: string; amount: number; category: string }
>;

/** Table de correspondance type → événement, utilisée pour typer émetteurs et abonnés. */
export interface EventMap {
  'business.created': BusinessCreated;
  'member.invited': MemberInvited;
  'contact.created': ContactCreated;
  'product.updated': ProductUpdated;
  'sale.completed': SaleCompleted;
  'sale.voided': SaleVoided;
  'customer.repayment_recorded': CustomerRepaymentRecorded;
  'customer.balance_adjusted': CustomerBalanceAdjusted;
  'purchase.received': PurchaseReceived;
  'supplier.payment_recorded': SupplierPaymentRecorded;
  'shop.order_placed': ShopOrderPlaced;
  'shop.order_status_changed': ShopOrderStatusChanged;
  'invoice.issued': InvoiceIssued;
  'invoice.cancelled': InvoiceCancelled;
  'stock.low': StockLow;
  'expense.recorded': ExpenseRecorded;
}

export type EventType = keyof EventMap;
export type PayloadOf<T extends EventType> = EventMap[T]['payload'];
