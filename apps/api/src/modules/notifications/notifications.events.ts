import { Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { BusinessCreated, MemberInvited, SaleVoided, ShopOrderPlaced, StockLow } from '@sama360/contracts';
import type { Tx } from '../../shared/db/db.service';
import { OnDomainEvent } from '../../shared/events/on-domain-event.decorator';
import { dayKey, francs, NotificationsService } from './notifications.service';

/**
 * Transforme les événements métier en notifications dans l'app (cloche de l'accueil).
 * Les envois hors de l'app (push, WhatsApp Business, SMS) viendront avec les fournisseurs.
 */
@Injectable()
export class NotificationEventHandlers {
  private readonly logger = new Logger('Notifications');

  constructor(private readonly notifications: NotificationsService) {}

  @OnDomainEvent('business.created')
  async welcome(event: BusinessCreated, tx: Tx): Promise<void> {
    await this.notifications.push(tx, event.businessId, {
      kind: 'welcome',
      title: `Bienvenue sur Sama360, ${event.payload.name}`,
      body: 'Ajoutez vos produits, puis faites votre première vente depuis la caisse.',
      link: '/stock',
      audience: 'sales:read',
      dedupeKey: 'welcome',
      createdAt: new Date(event.occurredAt),
    });
  }

  @OnDomainEvent('member.invited')
  async inviteMember(event: MemberInvited): Promise<void> {
    this.logger.log(`[invitation] ${event.payload.phone} → rôle ${event.payload.roleKey}`);
  }

  /** Un produit passe sous son seuil : une notification par produit et par jour. */
  @OnDomainEvent('stock.low')
  async stockLow(event: StockLow, tx: Tx): Promise<void> {
    const p = event.payload;
    await this.notifications.push(tx, event.businessId, {
      kind: 'stock_low',
      title: p.onHand <= 0 ? `Rupture : ${p.name}` : `Stock bas : ${p.name}`,
      body:
        p.onHand <= 0
          ? 'Plus aucune unité en stock. Pensez à recommander.'
          : `Il en reste ${p.onHand} (seuil d’alerte : ${p.threshold}).`,
      link: `/products/${p.productId}`,
      audience: 'inventory:read',
      dedupeKey: `stock_low:${p.productId}:${dayKey(new Date(event.occurredAt))}`,
      createdAt: new Date(event.occurredAt),
    });
  }

  @OnDomainEvent('shop.order_placed')
  async shopOrder(event: ShopOrderPlaced, tx: Tx): Promise<void> {
    const p = event.payload;
    await this.notifications.push(tx, event.businessId, {
      kind: 'shop_order',
      title: `Nouvelle commande ${p.number}`,
      body: `${p.customerName} · ${francs(p.total)} · ${p.mode === 'delivery' ? 'à livrer' : 'retrait en boutique'}`,
      link: `/shop/orders/${p.orderId}`,
      audience: 'sales:read',
      dedupeKey: `shop_order:${p.orderId}`,
      createdAt: new Date(event.occurredAt),
    });
  }

  /** Une vente annulée est signalée aux gérants (sauf à celui qui l'a annulée). */
  @OnDomainEvent('sale.voided')
  async saleVoided(event: SaleVoided, tx: Tx): Promise<void> {
    const p = event.payload;
    const who = event.actorId
      ? (
          (await tx.execute(sql`SELECT full_name FROM core.users WHERE id = ${event.actorId}`)).rows[0] as
            { full_name: string | null } | undefined
        )?.full_name
      : null;
    await this.notifications.push(tx, event.businessId, {
      kind: 'sale_voided',
      title: `Vente ${p.number} annulée`,
      body: who ? `Annulée par ${who}. La marchandise est revenue en stock.` : 'La marchandise est revenue en stock.',
      link: `/sales/${p.saleId}`,
      audience: 'sales:void',
      actorId: event.actorId ?? null,
      dedupeKey: `sale_voided:${p.saleId}`,
      createdAt: new Date(event.occurredAt),
    });
  }
}
