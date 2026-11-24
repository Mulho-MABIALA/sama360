import { readableOnWhite } from '../../shared/color';
import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { FilesService } from '../files/files.service';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { COUNTRIES, CountryCode, countryOf, payHint, tenantCountry } from '../../shared/countries';
import { normalizePhone } from '../../shared/phone';
import { catalogUnitPrice } from '../sales/pricing';
import { fcfa, SalesService } from '../sales/sales.service';

export type ShopOrderStatus = 'new' | 'confirmed' | 'ready' | 'delivering' | 'completed' | 'cancelled';
export type PayMethod =
  'cash' | 'wave' | 'orange_money' | 'free_money' | 'mtn_momo' | 'moov_money' | 'airtel_money' | 'card';

/** Étapes possibles depuis chaque statut. */
export const TRANSITIONS: Record<ShopOrderStatus, ShopOrderStatus[]> = {
  new: ['confirmed', 'cancelled'],
  confirmed: ['ready', 'delivering', 'completed', 'cancelled'],
  ready: ['delivering', 'completed', 'cancelled'],
  delivering: ['completed', 'cancelled'],
  completed: [],
  cancelled: [],
};

export const STATUS_LABELS: Record<ShopOrderStatus, string> = {
  new: 'Nouvelle',
  confirmed: 'Confirmée',
  ready: 'Prête',
  delivering: 'En livraison',
  completed: 'Livrée',
  cancelled: 'Annulée',
};

export function canMove(from: ShopOrderStatus, to: ShopOrderStatus, mode: 'pickup' | 'delivery'): boolean {
  if (to === 'delivering' && mode !== 'delivery') return false;
  return TRANSITIONS[from].includes(to);
}

export interface SettingsInput {
  enabled?: boolean;
  title?: string | null;
  tagline?: string | null;
  description?: string | null;
  whatsapp?: string | null;
  pickup?: boolean;
  delivery?: boolean;
  deliveryFee?: number;
  deliveryZone?: string | null;
  minOrder?: number;
}

export interface PlaceOrderInput {
  id: string;
  customerName: string;
  customerPhone: string;
  mode: 'pickup' | 'delivery';
  address?: string | null;
  note?: string | null;
  items: { productId: string; quantity: number }[];
}

type Row = Record<string, unknown>;

export interface ShopSettings {
  enabled: boolean;
  title: string | null;
  /** Phrase d'accroche en grand sur la couverture. */
  tagline: string | null;
  coverFileId: string | null;
  description: string | null;
  whatsapp: string | null;
  pickup: boolean;
  delivery: boolean;
  deliveryFee: number;
  deliveryZone: string | null;
  minOrder: number;
}
const year = () => new Date().getUTCFullYear();
const MAX_SHOWN_STOCK = 99;

/** Boutique en ligne : catalogue public, commandes des clients et leur suivi par le commerçant. */
@Injectable()
export class ShopService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly sales: SalesService,
    private readonly files: FilesService,
  ) {}

  // ------------------------------------------------------------------ public

  /** Entreprise d'une boutique ouverte (abonnement Pro en cours), d'après son adresse (slug). Sinon 404. */
  async resolve(slug: string): Promise<{
    id: string;
    name: string;
    phone: string | null;
    address: string | null;
    city: string | null;
    logoFileId: string | null;
    brandColor: string | null;
    country: CountryCode;
  }> {
    const [b] = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT id, name, phone, address, city, logo_file_id, brand_color, country FROM core.businesses
          WHERE slug = ${slug.toLowerCase()} AND deleted_at IS NULL AND suspended_at IS NULL
            AND EXISTS (SELECT 1 FROM core.subscriptions s WHERE s.business_id = core.businesses.id
                        AND s.plan = 'pro' AND s.current_period_end > now())`),
      )
    ).rows as Row[];
    if (!b) throw AppError.notFound('Boutique');
    return {
      id: b.id as string,
      name: b.name as string,
      phone: (b.phone as string) ?? null,
      address: (b.address as string) ?? null,
      city: (b.city as string) ?? null,
      logoFileId: (b.logo_file_id as string) ?? null,
      brandColor: b.brand_color ? readableOnWhite(b.brand_color as string) : null,
      country: countryOf(b.country as string).code,
    };
  }

  /** Vitrine publique : réglages, catégories et produits publiés avec leur disponibilité. */
  async storefront(slug: string) {
    const b = await this.resolve(slug);
    return this.dbs.withTenant(b.id, async (tx) => {
      const settings = await this.settingsRow(tx);
      if (!settings.enabled) throw AppError.notFound('Boutique');
      const products = (
        await tx.execute(sql`
          SELECT p.id, p.name, p.price, p.unit, p.category_id, p.image_file_ids[1] AS image_file_id, p.track_stock,
                 p.wholesale_price, p.wholesale_min_qty, coalesce(sum(sl.on_hand), 0) AS on_hand
          FROM catalog.products p
          LEFT JOIN inventory.stock_levels sl ON sl.product_id = p.id
          WHERE p.published AND p.deleted_at IS NULL
          GROUP BY p.id ORDER BY lower(p.name)`)
      ).rows as Row[];
      const usedCategories = new Set(products.map((p) => p.category_id).filter(Boolean));
      const booking = (await tx.execute(sql`SELECT online_enabled FROM sales.booking_settings`)).rows[0] as
        Row | undefined;
      const categories = (await tx.execute(sql`SELECT id, name FROM catalog.categories ORDER BY position, lower(name)`))
        .rows as Row[];
      return {
        shop: {
          slug: slug.toLowerCase(),
          name: settings.title || b.name,
          businessName: b.name,
          tagline: settings.tagline,
          coverFileId: settings.coverFileId,
          description: settings.description,
          whatsapp: settings.whatsapp ?? b.phone,
          address: [b.address, b.city].filter(Boolean).join(', ') || null,
          logoFileId: b.logoFileId,
          brandColor: b.brandColor,
          pickup: settings.pickup,
          delivery: settings.delivery,
          deliveryFee: settings.deliveryFee,
          deliveryZone: settings.deliveryZone,
          minOrder: settings.minOrder,
          // Réservation en ligne ouverte : lien « Prendre rendez-vous » sur la vitrine
          booking: booking?.online_enabled === true,
          // Pays : exemple de numéro et moyens de paiement affichés sur la page
          country: b.country,
          phoneExample: COUNTRIES[b.country].example,
          payHint: payHint(COUNTRIES[b.country]),
        },
        categories: categories.filter((c) => usedCategories.has(c.id)).map((c) => ({ id: c.id, name: c.name })),
        products: products.map((p) => {
          const tracked = p.track_stock as boolean;
          const onHand = Number(p.on_hand);
          return {
            id: p.id,
            name: p.name,
            price: Number(p.price),
            unit: p.unit,
            categoryId: p.category_id ?? null,
            imageFileId: p.image_file_id ?? null,
            wholesalePrice: p.wholesale_price === null ? null : Number(p.wholesale_price),
            wholesaleMinQty: p.wholesale_min_qty === null ? null : Number(p.wholesale_min_qty),
            available: !tracked || onHand > 0,
            // Quantité maximale commandable (le stock exact n'est pas affiché au public)
            maxQuantity: tracked ? Math.max(0, Math.min(MAX_SHOWN_STOCK, Math.floor(onHand))) : MAX_SHOWN_STOCK,
          };
        }),
      };
    });
  }

  /** Commande d'un client sur la page publique. Idempotente sur l'identifiant envoyé par la page. */
  async place(slug: string, input: PlaceOrderInput) {
    const b = await this.resolve(slug);
    const phone = normalizePhone(input.customerPhone, b.country);
    if (!phone) throw new AppError('PHONE_INVALID', 'Numéro de téléphone invalide', 422);
    return this.dbs.withTenant(b.id, async (tx) => {
      const existing = await this.findOrder(tx, input.id);
      if (existing) return { created: false, order: this.publicView(existing) };

      const settings = await this.settingsRow(tx);
      if (!settings.enabled) throw AppError.notFound('Boutique');
      if (input.mode === 'delivery' && !settings.delivery) {
        throw new AppError('VALIDATION_FAILED', 'Cette boutique ne livre pas : choisissez le retrait', 422);
      }
      if (input.mode === 'pickup' && !settings.pickup) {
        throw new AppError(
          'VALIDATION_FAILED',
          'Cette boutique ne propose pas le retrait : choisissez la livraison',
          422,
        );
      }
      if (input.mode === 'delivery' && !(input.address ?? '').trim()) {
        throw new AppError('VALIDATION_FAILED', 'Indiquez l’adresse de livraison', 422);
      }

      const ids = [...new Set(input.items.map((i) => i.productId))];
      if (ids.length !== input.items.length) {
        throw new AppError('VALIDATION_FAILED', 'Un produit apparaît plusieurs fois', 422);
      }
      const found = (
        await tx.execute(sql`
          SELECT p.id, p.name, p.price, p.wholesale_price, p.wholesale_min_qty, p.track_stock,
                 coalesce((SELECT sum(on_hand) FROM inventory.stock_levels sl WHERE sl.product_id = p.id), 0) AS on_hand
          FROM catalog.products p
          WHERE p.id IN (${sql.join(
            ids.map((i) => sql`${i}`),
            sql`, `,
          )}) AND p.published AND p.deleted_at IS NULL`)
      ).rows as Row[];
      const byId = new Map(found.map((p) => [p.id as string, p]));
      const lines = input.items.map((it) => {
        const p = byId.get(it.productId);
        if (!p) throw new AppError('NOT_FOUND', 'Un produit n’est plus disponible : actualisez la page', 404);
        if (p.track_stock && Number(p.on_hand) < it.quantity) {
          const left = Math.max(0, Math.floor(Number(p.on_hand)));
          throw new AppError(
            'VALIDATION_FAILED',
            left === 0 ? `« ${p.name} » n’est plus en stock` : `« ${p.name} » : ${left} disponible(s) seulement`,
            422,
            { productId: p.id, available: left },
          );
        }
        const unitPrice = catalogUnitPrice(
          {
            price: Number(p.price),
            wholesalePrice: p.wholesale_price === null ? null : Number(p.wholesale_price),
            wholesaleMinQty: p.wholesale_min_qty === null ? null : Number(p.wholesale_min_qty),
          },
          it.quantity,
        );
        return {
          productId: p.id as string,
          name: p.name as string,
          quantity: it.quantity,
          unitPrice,
          total: Math.round(it.quantity * unitPrice),
        };
      });
      const subtotal = lines.reduce((s, l) => s + l.total, 0);
      if (subtotal < settings.minOrder) {
        throw new AppError('VALIDATION_FAILED', `Commande minimum : ${fcfa(settings.minOrder)}`, 422, {
          minOrder: settings.minOrder,
        });
      }
      const deliveryFee = input.mode === 'delivery' ? settings.deliveryFee : 0;
      const contactId = await this.contactFor(tx, b.id, input.customerName.trim(), phone);
      const number = await this.nextNumber(tx, b.id);

      await tx.execute(sql`
        INSERT INTO shop.orders
          (id, business_id, number, status, customer_name, customer_phone, contact_id, mode, address, note,
           subtotal, delivery_fee, total)
        VALUES (${input.id}, ${b.id}, ${number}, 'new', ${input.customerName.trim()}, ${phone}, ${contactId},
                ${input.mode}, ${input.mode === 'delivery' ? input.address!.trim() : null}, ${input.note?.trim() || null},
                ${subtotal}, ${deliveryFee}, ${subtotal + deliveryFee})`);
      for (const [i, l] of lines.entries()) {
        await tx.execute(sql`
          INSERT INTO shop.order_lines (id, business_id, order_id, position, product_id, name, quantity, unit_price, total)
          VALUES (${newId()}, ${b.id}, ${input.id}, ${i}, ${l.productId}, ${l.name}, ${l.quantity}, ${l.unitPrice}, ${l.total})`);
      }
      await this.outbox.record(tx, {
        type: 'shop.order_placed',
        businessId: b.id,
        aggregateId: input.id,
        actorId: null,
        payload: {
          orderId: input.id,
          number,
          total: subtotal + deliveryFee,
          customerName: input.customerName.trim(),
          customerPhone: phone,
          mode: input.mode,
        },
      });
      return { created: true, order: this.publicView((await this.findOrder(tx, input.id))!) };
    });
  }

  /** Suivi de commande pour le client (l'identifiant n'est pas devinable). */
  async track(slug: string, orderId: string) {
    const b = await this.resolve(slug);
    return this.dbs.withTenant(b.id, async (tx) => {
      const o = await this.findOrder(tx, orderId);
      if (!o) throw AppError.notFound('Commande');
      return this.publicView(o);
    });
  }

  // ------------------------------------------------------------------ commerçant

  overview(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const settings = await this.settingsRow(tx);
      const [b] = (await tx.execute(sql`SELECT slug FROM core.businesses WHERE id = ${businessId}`)).rows as Row[];
      const [stats] = (
        await tx.execute(sql`
          SELECT count(*) FILTER (WHERE status = 'new')::int AS new_orders,
                 count(*) FILTER (WHERE status IN ('confirmed', 'ready', 'delivering'))::int AS open_orders,
                 count(*) FILTER (WHERE status = 'completed' AND completed_at >= date_trunc('month', now()))::int AS month_orders,
                 coalesce(sum(total) FILTER (WHERE status = 'completed' AND completed_at >= date_trunc('month', now())), 0)::bigint AS month_revenue
          FROM shop.orders`)
      ).rows as Row[];
      const [p] = (
        await tx.execute(sql`
          SELECT count(*) FILTER (WHERE published)::int AS published, count(*)::int AS total
          FROM catalog.products WHERE deleted_at IS NULL`)
      ).rows as Row[];
      return {
        slug: b.slug,
        path: `/s/${b.slug}`,
        settings,
        stats: {
          newOrders: Number(stats.new_orders),
          openOrders: Number(stats.open_orders),
          monthOrders: Number(stats.month_orders),
          monthRevenue: Number(stats.month_revenue),
          publishedProducts: Number(p.published),
          totalProducts: Number(p.total),
        },
      };
    });
  }

  saveSettings(businessId: string, input: SettingsInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const current = await this.settingsRow(tx);
      const next: ShopSettings = {
        ...current,
        ...(Object.fromEntries(Object.entries(input).filter(([, v]) => v !== undefined)) as Partial<typeof current>),
      };
      if (input.whatsapp !== undefined && input.whatsapp !== null && input.whatsapp !== '') {
        const p = normalizePhone(input.whatsapp, await tenantCountry(tx, businessId));
        if (!p) throw new AppError('PHONE_INVALID', 'Numéro WhatsApp invalide', 422);
        next.whatsapp = p;
      } else if (input.whatsapp === '') {
        next.whatsapp = null;
      }
      // Textes vides : effacés
      for (const k of ['title', 'tagline', 'description', 'deliveryZone'] as const) if (next[k] === '') next[k] = null;
      if (!next.pickup && !next.delivery) {
        throw new AppError('VALIDATION_FAILED', 'Proposez au moins le retrait en boutique ou la livraison', 422);
      }
      await tx.execute(sql`
        INSERT INTO shop.settings
          (business_id, enabled, title, tagline, description, whatsapp, pickup, delivery, delivery_fee, delivery_zone, min_order, updated_at)
        VALUES (${businessId}, ${next.enabled}, ${next.title}, ${next.tagline}, ${next.description}, ${next.whatsapp}, ${next.pickup},
                ${next.delivery}, ${next.deliveryFee}, ${next.deliveryZone}, ${next.minOrder}, now())
        ON CONFLICT (business_id) DO UPDATE SET
          enabled = EXCLUDED.enabled, title = EXCLUDED.title, tagline = EXCLUDED.tagline, description = EXCLUDED.description,
          whatsapp = EXCLUDED.whatsapp, pickup = EXCLUDED.pickup, delivery = EXCLUDED.delivery,
          delivery_fee = EXCLUDED.delivery_fee, delivery_zone = EXCLUDED.delivery_zone,
          min_order = EXCLUDED.min_order, updated_at = now()`);
      return this.settingsRow(tx);
    });
  }

  /** Image de couverture de la vitrine (remplace l'ancienne). */
  setCover(businessId: string, userId: string, data: Buffer) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [before] = (await tx.execute(sql`SELECT cover_file_id FROM shop.settings`)).rows as Row[];
      const saved = await this.files.saveImage(tx, { businessId, kind: 'shop-cover', data, createdBy: userId });
      await tx.execute(sql`
        INSERT INTO shop.settings (business_id, cover_file_id, updated_at) VALUES (${businessId}, ${saved.id}, now())
        ON CONFLICT (business_id) DO UPDATE SET cover_file_id = EXCLUDED.cover_file_id, updated_at = now()`);
      if (before?.cover_file_id) await this.files.remove(tx, before.cover_file_id as string);
      return this.settingsRow(tx);
    });
  }

  removeCover(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [before] = (await tx.execute(sql`SELECT cover_file_id FROM shop.settings`)).rows as Row[];
      if (before?.cover_file_id) {
        await tx.execute(sql`UPDATE shop.settings SET cover_file_id = NULL, updated_at = now()`);
        await this.files.remove(tx, before.cover_file_id as string);
      }
      return this.settingsRow(tx);
    });
  }

  /** Publie ou retire des produits de la boutique (tous si [productIds] est absent). */
  publish(businessId: string, input: { productIds?: string[]; published: boolean }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const ids = input.productIds;
      const res = await tx.execute(sql`
        UPDATE catalog.products SET published = ${input.published}, updated_at = now(), version = version + 1
        WHERE deleted_at IS NULL AND published <> ${input.published}
          ${
            ids
              ? sql`AND id IN (${sql.join(
                  ids.map((i) => sql`${i}`),
                  sql`, `,
                )})`
              : sql``
          }
        RETURNING id`);
      return { updated: res.rows.length };
    });
  }

  orders(businessId: string, q: { filter: 'new' | 'open' | 'done' | 'all'; limit: number; offset: number }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const filter =
        q.filter === 'new'
          ? sql`WHERE status = 'new'`
          : q.filter === 'open'
            ? sql`WHERE status IN ('new', 'confirmed', 'ready', 'delivering')`
            : q.filter === 'done'
              ? sql`WHERE status IN ('completed', 'cancelled')`
              : sql``;
      const rows = (
        await tx.execute(sql`
          SELECT o.*, (SELECT count(*)::int FROM shop.order_lines l WHERE l.order_id = o.id) AS line_count
          FROM shop.orders o ${filter}
          ORDER BY o.created_at DESC, o.id DESC LIMIT ${q.limit + 1} OFFSET ${q.offset}`)
      ).rows as Row[];
      return {
        data: rows.slice(0, q.limit).map((r) => this.summary(r)),
        nextOffset: rows.length > q.limit ? q.offset + q.limit : null,
      };
    });
  }

  order(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const o = await this.findOrder(tx, id);
      if (!o) throw AppError.notFound('Commande');
      return o;
    });
  }

  /**
   * Fait avancer une commande. « completed » enregistre la vente (stock, caisse, crédit
   * éventuel) avec l'identifiant de la commande : un renvoi ne crée pas deux ventes.
   */
  async setStatus(
    businessId: string,
    userId: string,
    id: string,
    input: { status: ShopOrderStatus; reason?: string | null; payment?: { method: PayMethod; amount: number } | null },
  ) {
    const before = await this.order(businessId, id);
    const from = before.status as ShopOrderStatus;
    if (from === input.status) return before;
    if (!canMove(from, input.status, before.mode as 'pickup' | 'delivery')) {
      throw new AppError(
        'DOCUMENT_LOCKED',
        `Une commande « ${STATUS_LABELS[from].toLowerCase()} » ne peut pas passer à « ${STATUS_LABELS[input.status].toLowerCase()} »`,
        409,
      );
    }

    let saleId: string | null = null;
    if (input.status === 'completed') {
      const paid = input.payment?.amount ?? before.total;
      if (paid > before.total) {
        throw new AppError('OVERPAYMENT', 'Le montant payé dépasse le total de la commande', 422);
      }
      const items = before.lines.map((l) => ({ productId: l.productId, quantity: l.quantity, unitPrice: l.unitPrice }));
      const extra = before.deliveryFee > 0 ? [{ name: 'Livraison', quantity: 1, unitPrice: before.deliveryFee }] : [];
      const { sale } = await this.sales.create(businessId, userId, {
        id,
        customerId: before.contactId,
        items: [...items, ...extra],
        payments: paid > 0 ? [{ method: input.payment?.method ?? 'cash', amount: paid }] : [],
        note: `Commande en ligne ${before.number}`,
      });
      saleId = sale.id;
    }

    return this.dbs.withTenant(businessId, async (tx) => {
      const [locked] = (await tx.execute(sql`SELECT status FROM shop.orders WHERE id = ${id} FOR UPDATE`)).rows as {
        status: ShopOrderStatus;
      }[];
      if (locked.status !== from) {
        throw new AppError('CONFLICT', 'La commande vient d’être modifiée : actualisez', 409);
      }
      await tx.execute(sql`
        UPDATE shop.orders SET status = ${input.status}, updated_at = now(),
          confirmed_at = CASE WHEN ${input.status} = 'confirmed' THEN now() ELSE confirmed_at END,
          completed_at = CASE WHEN ${input.status} = 'completed' THEN now() ELSE completed_at END,
          cancelled_at = CASE WHEN ${input.status} = 'cancelled' THEN now() ELSE cancelled_at END,
          cancel_reason = CASE WHEN ${input.status} = 'cancelled' THEN ${input.reason ?? null} ELSE cancel_reason END,
          sale_id = coalesce(${saleId}::uuid, sale_id)
        WHERE id = ${id}`);
      await this.outbox.record(tx, {
        type: 'shop.order_status_changed',
        businessId,
        aggregateId: id,
        actorId: userId,
        payload: { orderId: id, number: before.number, from, to: input.status, saleId },
      });
      return (await this.findOrder(tx, id))!;
    });
  }

  // ------------------------------------------------------------------ interne

  /** Réglages de la boutique ; fermée si le module « shop » n'est pas activé pour l'entreprise. */
  private async settingsRow(tx: Tx): Promise<ShopSettings> {
    const [s] = (
      await tx.execute(sql`
        SELECT st.*, EXISTS (SELECT 1 FROM core.module_activations m WHERE m.module = 'shop' AND m.enabled) AS module_on
        FROM (SELECT 1) one LEFT JOIN shop.settings st ON true LIMIT 1`)
    ).rows as Row[];
    const moduleOn = s?.module_on as boolean;
    if (s && s.business_id === null) {
      return {
        enabled: false,
        title: null,
        tagline: null,
        coverFileId: null,
        description: null,
        whatsapp: null,
        pickup: true,
        delivery: true,
        deliveryFee: 0,
        deliveryZone: null,
        minOrder: 0,
      };
    }
    return {
      enabled: s ? (s.enabled as boolean) && moduleOn : false,
      title: (s?.title as string) ?? null,
      tagline: (s?.tagline as string) ?? null,
      coverFileId: (s?.cover_file_id as string) ?? null,
      description: (s?.description as string) ?? null,
      whatsapp: (s?.whatsapp as string) ?? null,
      pickup: s ? (s.pickup as boolean) : true,
      delivery: s ? (s.delivery as boolean) : true,
      deliveryFee: s ? Number(s.delivery_fee) : 0,
      deliveryZone: (s?.delivery_zone as string) ?? null,
      minOrder: s ? Number(s.min_order) : 0,
    };
  }

  /** Client de l'annuaire retrouvé par son téléphone, ou créé. */
  private async contactFor(tx: Tx, businessId: string, name: string, phone: string): Promise<string> {
    const [c] = (
      await tx.execute(sql`
        SELECT id, type FROM contacts.contacts WHERE phone = ${phone} AND deleted_at IS NULL
        ORDER BY (type = 'customer') DESC, created_at LIMIT 1`)
    ).rows as { id: string; type: string }[];
    if (c) {
      if (c.type === 'supplier') {
        await tx.execute(sql`UPDATE contacts.contacts SET type = 'both', updated_at = now() WHERE id = ${c.id}`);
      }
      return c.id;
    }
    const id = newId();
    await tx.execute(sql`
      INSERT INTO contacts.contacts (id, business_id, type, name, phone, notes)
      VALUES (${id}, ${businessId}, 'customer', ${name}, ${phone}, 'Client de la boutique en ligne')`);
    await this.outbox.record(tx, {
      type: 'contact.created',
      businessId,
      aggregateId: id,
      actorId: null,
      payload: { contactId: id, type: 'customer', name, phone },
    });
    return id;
  }

  private async nextNumber(tx: Tx, businessId: string): Promise<string> {
    const y = year();
    const res = await tx.execute(sql`
      INSERT INTO shop.sequences (business_id, key, year, last_value) VALUES (${businessId}, 'order', ${y}, 1)
      ON CONFLICT (business_id, key, year) DO UPDATE SET last_value = shop.sequences.last_value + 1
      RETURNING last_value`);
    const n = (res.rows[0] as { last_value: number }).last_value;
    return `CMD-${y}-${String(n).padStart(4, '0')}`;
  }

  private summary(r: Row) {
    return {
      id: r.id as string,
      number: r.number as string,
      status: r.status as ShopOrderStatus,
      customerName: r.customer_name as string,
      customerPhone: r.customer_phone as string,
      mode: r.mode as 'pickup' | 'delivery',
      total: Number(r.total),
      lineCount: Number(r.line_count ?? 0),
      createdAt: r.created_at as Date,
    };
  }

  private async findOrder(tx: Tx, id: string) {
    const [o] = (await tx.execute(sql`SELECT * FROM shop.orders WHERE id = ${id}`)).rows as Row[];
    if (!o) return null;
    const lines = (
      await tx.execute(sql`
        SELECT l.id, l.product_id, l.name, l.quantity, l.unit_price, l.total, p.image_file_ids[1] AS image_file_id, p.unit
        FROM shop.order_lines l LEFT JOIN catalog.products p ON p.id = l.product_id
        WHERE l.order_id = ${id} ORDER BY l.position`)
    ).rows as Row[];
    return {
      ...this.summary({ ...o, line_count: lines.length }),
      contactId: (o.contact_id as string) ?? null,
      address: (o.address as string) ?? null,
      note: (o.note as string) ?? null,
      subtotal: Number(o.subtotal),
      deliveryFee: Number(o.delivery_fee),
      saleId: (o.sale_id as string) ?? null,
      confirmedAt: (o.confirmed_at as Date) ?? null,
      completedAt: (o.completed_at as Date) ?? null,
      cancelledAt: (o.cancelled_at as Date) ?? null,
      cancelReason: (o.cancel_reason as string) ?? null,
      lines: lines.map((l) => ({
        id: l.id as string,
        productId: l.product_id as string,
        name: l.name as string,
        unit: (l.unit as string) ?? 'pièce',
        quantity: Number(l.quantity),
        unitPrice: Number(l.unit_price),
        total: Number(l.total),
        imageFileId: (l.image_file_id as string) ?? null,
      })),
    };
  }

  /** Ce que le client voit de sa commande (pas de lien vers l'annuaire ni la vente). */
  private publicView(o: NonNullable<Awaited<ReturnType<ShopService['findOrder']>>>) {
    return {
      id: o.id,
      number: o.number,
      status: o.status,
      statusLabel: STATUS_LABELS[o.status],
      customerName: o.customerName,
      mode: o.mode,
      address: o.address,
      subtotal: o.subtotal,
      deliveryFee: o.deliveryFee,
      total: o.total,
      createdAt: o.createdAt,
      lines: o.lines.map((l) => ({ name: l.name, quantity: l.quantity, unitPrice: l.unitPrice, total: l.total })),
    };
  }
}
