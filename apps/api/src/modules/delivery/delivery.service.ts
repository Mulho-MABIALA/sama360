import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { CountryCode, tenantCountry } from '../../shared/countries';
import { normalizePhone } from '../../shared/phone';
import { ShopService } from '../shop/shop.service';
import { canMoveDelivery, DELIVERY_LABELS, DeliveryStatus } from './delivery';

type Row = Record<string, unknown>;
const n = (v: unknown) => Number(v ?? 0);

export interface CourierInput {
  name: string;
  phone?: string | null;
  vehicle?: 'moto' | 'voiture' | 'velo' | 'pied';
  active?: boolean;
}

export interface DeliveryInput {
  orderId?: string | null;
  customerName?: string | null;
  customerPhone?: string | null;
  address?: string | null;
  note?: string | null;
  fee?: number;
  amountToCollect?: number;
  courierId?: string | null;
}

@Injectable()
export class DeliveryService {
  constructor(
    private readonly dbs: DbService,
    private readonly shop: ShopService,
  ) {}

  // ------------------------------------------------------------ livreurs

  private courierDto(r: Row) {
    return {
      id: String(r.id),
      name: String(r.name),
      phone: (r.phone as string | null) ?? null,
      vehicle: String(r.vehicle),
      active: r.active === true,
    };
  }

  couriers(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) =>
      ((await tx.execute(sql`SELECT * FROM sales.couriers ORDER BY active DESC, lower(name)`)).rows as Row[]).map((r) =>
        this.courierDto(r),
      ),
    );
  }

  private phone(v: string | null | undefined, country: CountryCode) {
    if (!v) return null;
    const p = normalizePhone(v, country);
    if (!p) throw new AppError('PHONE_INVALID', 'Numéro de téléphone invalide', 422);
    return p;
  }

  addCourier(businessId: string, input: CourierInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const id = newId();
      await tx.execute(sql`INSERT INTO sales.couriers (id, business_id, name, phone, vehicle)
        VALUES (${id}, ${businessId}, ${input.name}, ${this.phone(input.phone, await tenantCountry(tx, businessId))}, ${input.vehicle ?? 'moto'})`);
      return this.courierDto((await tx.execute(sql`SELECT * FROM sales.couriers WHERE id = ${id}`)).rows[0] as Row);
    });
  }

  updateCourier(businessId: string, id: string, input: Partial<CourierInput>) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const cur = (await tx.execute(sql`SELECT * FROM sales.couriers WHERE id = ${id}`)).rows[0] as Row | undefined;
      if (!cur) throw AppError.notFound('Livreur');
      await tx.execute(sql`UPDATE sales.couriers SET
        name = ${input.name ?? String(cur.name)},
        phone = ${input.phone === undefined ? ((cur.phone as string) ?? null) : this.phone(input.phone, await tenantCountry(tx, businessId))},
        vehicle = ${input.vehicle ?? String(cur.vehicle)},
        active = ${input.active ?? cur.active === true}
        WHERE id = ${id}`);
      return this.courierDto((await tx.execute(sql`SELECT * FROM sales.couriers WHERE id = ${id}`)).rows[0] as Row);
    });
  }

  // ------------------------------------------------------------ courses

  private dto(r: Row) {
    return {
      id: String(r.id),
      orderId: (r.order_id as string | null) ?? null,
      orderNumber: (r.order_number as string | null) ?? null,
      customerName: String(r.customer_name),
      customerPhone: (r.customer_phone as string | null) ?? null,
      address: String(r.address),
      note: (r.note as string | null) ?? null,
      courierId: (r.courier_id as string | null) ?? null,
      courierName: (r.courier_name as string | null) ?? null,
      courierPhone: (r.courier_phone as string | null) ?? null,
      fee: n(r.fee),
      amountToCollect: n(r.amount_to_collect),
      status: String(r.status) as DeliveryStatus,
      statusLabel: DELIVERY_LABELS[String(r.status) as DeliveryStatus],
      failureReason: (r.failure_reason as string | null) ?? null,
      settled: r.settled === true,
      createdAt: new Date(String(r.created_at)).toISOString(),
      deliveredAt: r.delivered_at ? new Date(String(r.delivered_at)).toISOString() : null,
    };
  }

  private select = sql`SELECT d.*, c.name AS courier_name, c.phone AS courier_phone, o.number AS order_number
    FROM sales.deliveries d
    LEFT JOIN sales.couriers c ON c.id = d.courier_id
    LEFT JOIN shop.orders o ON o.id = d.order_id`;

  private async find(tx: Tx, id: string) {
    const r = (await tx.execute(sql`${this.select} WHERE d.id = ${id}`)).rows[0] as Row | undefined;
    if (!r) throw AppError.notFound('Livraison');
    return r;
  }

  /** Tableau de bord : commandes en ligne à livrer, courses, argent chez chaque livreur. */
  board(businessId: string, view: 'active' | 'done') {
    return this.dbs.withTenant(businessId, async (tx) => {
      const toAssign = (
        await tx.execute(sql`
          SELECT o.id, o.number, o.customer_name, o.customer_phone, o.address, o.total, o.delivery_fee, o.status
          FROM shop.orders o
          WHERE o.mode = 'delivery' AND o.status IN ('confirmed', 'ready')
            AND NOT EXISTS (SELECT 1 FROM sales.deliveries d WHERE d.order_id = o.id
                            AND d.status IN ('pending', 'assigned', 'picked', 'delivered'))
          ORDER BY o.created_at`)
      ).rows as Row[];
      const items = (
        await tx.execute(sql`${this.select}
          WHERE ${view === 'active' ? sql`d.status IN ('pending', 'assigned', 'picked', 'failed')` : sql`d.status IN ('delivered', 'cancelled')`}
          ${view === 'done' ? sql`AND d.created_at >= now() - interval '30 days'` : sql``}
          ORDER BY ${view === 'active' ? sql`d.created_at` : sql`coalesce(d.delivered_at, d.updated_at) DESC`} LIMIT 200`)
      ).rows as Row[];
      const owed = (
        await tx.execute(sql`
          SELECT c.id, c.name, c.phone, sum(d.amount_to_collect)::bigint AS owed, count(*)::int AS deliveries
          FROM sales.deliveries d JOIN sales.couriers c ON c.id = d.courier_id
          WHERE d.status = 'delivered' AND NOT d.settled AND d.amount_to_collect > 0
          GROUP BY c.id ORDER BY sum(d.amount_to_collect) DESC`)
      ).rows as Row[];
      return {
        toAssign: toAssign.map((o) => ({
          orderId: String(o.id),
          number: String(o.number),
          customerName: String(o.customer_name),
          customerPhone: String(o.customer_phone),
          address: (o.address as string) ?? '',
          total: n(o.total),
          deliveryFee: n(o.delivery_fee),
        })),
        items: items.map((r) => this.dto(r)),
        withCouriers: owed.map((r) => ({
          courierId: String(r.id),
          name: String(r.name),
          phone: (r.phone as string | null) ?? null,
          owed: n(r.owed),
          deliveries: n(r.deliveries),
        })),
      };
    });
  }

  private async assertCourier(tx: Tx, id: string) {
    const c = (await tx.execute(sql`SELECT active FROM sales.couriers WHERE id = ${id}`)).rows[0] as Row | undefined;
    if (!c) throw AppError.notFound('Livreur');
    if (c.active !== true) throw new AppError('VALIDATION_FAILED', 'Ce livreur n’est plus actif', 422);
  }

  /**
   * Nouvelle course : d'une commande en ligne (client, adresse, montant repris) ou notée à la main.
   * Le montant à encaisser est payé au livreur à la livraison.
   */
  create(businessId: string, userId: string, input: DeliveryInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      let v: Omit<DeliveryInput, 'customerName' | 'address'> & { customerName: string; address: string } = {
        ...input,
        customerName: input.customerName ?? '',
        address: input.address ?? '',
      };
      if (input.orderId) {
        const o = (await tx.execute(sql`SELECT * FROM shop.orders WHERE id = ${input.orderId} FOR UPDATE`)).rows[0] as
          Row | undefined;
        if (!o) throw AppError.notFound('Commande');
        if (o.mode !== 'delivery' || !['confirmed', 'ready', 'delivering'].includes(String(o.status))) {
          throw new AppError('VALIDATION_FAILED', 'Confirmez d’abord la commande (livraison à domicile)', 422);
        }
        const busy = (
          await tx.execute(sql`SELECT 1 FROM sales.deliveries WHERE order_id = ${input.orderId}
            AND status IN ('pending', 'assigned', 'picked', 'delivered')`)
        ).rows[0];
        if (busy) throw new AppError('CONFLICT', 'Cette commande a déjà une livraison en cours', 409);
        v = {
          ...v,
          customerName: String(o.customer_name),
          customerPhone: String(o.customer_phone),
          address: String(o.address ?? ''),
          note: input.note ?? ((o.note as string) || null),
          fee: Number(o.delivery_fee),
          amountToCollect: input.amountToCollect ?? Number(o.total),
        };
      }
      if (!v.customerName.trim()) throw new AppError('VALIDATION_FAILED', 'Indiquez le nom du client', 422);
      if (!v.address.trim()) throw new AppError('VALIDATION_FAILED', 'Indiquez l’adresse de livraison', 422);
      if (input.courierId) await this.assertCourier(tx, input.courierId);
      const id = newId();
      await tx.execute(sql`
        INSERT INTO sales.deliveries (id, business_id, order_id, customer_name, customer_phone, address, note, courier_id,
          fee, amount_to_collect, status, assigned_at, created_by)
        VALUES (${id}, ${businessId}, ${input.orderId ?? null}, ${v.customerName.trim()}, ${this.phone(v.customerPhone, await tenantCountry(tx, businessId))},
          ${v.address.trim()}, ${v.note ?? null}, ${input.courierId ?? null}, ${v.fee ?? 0}, ${v.amountToCollect ?? 0},
          ${input.courierId ? 'assigned' : 'pending'}, ${input.courierId ? sql`now()` : null}, ${userId})`);
      return this.dto(await this.find(tx, id));
    });
  }

  /**
   * Fait avancer une course. Pour une commande en ligne : « en route » passe la commande en livraison,
   * « livrée » la termine (vente enregistrée, payée du montant encaissé par le livreur).
   */
  async update(
    businessId: string,
    userId: string,
    id: string,
    input: {
      status?: DeliveryStatus;
      courierId?: string | null;
      failureReason?: string | null;
      amountToCollect?: number;
    },
  ) {
    const before = await this.dbs.withTenant(businessId, (tx) => this.find(tx, id));
    const from = String(before.status) as DeliveryStatus;
    let to = input.status ?? from;
    if (input.courierId && (from === 'pending' || from === 'failed')) to = input.status ?? 'assigned';
    if (to !== from && !canMoveDelivery(from, to)) {
      throw new AppError(
        'DOCUMENT_LOCKED',
        `Une livraison « ${DELIVERY_LABELS[from].toLowerCase()} » ne peut pas passer à « ${DELIVERY_LABELS[to].toLowerCase()} »`,
        409,
      );
    }
    if (to === 'assigned' && !input.courierId && !before.courier_id) {
      throw new AppError('VALIDATION_FAILED', 'Choisissez un livreur', 422);
    }
    const amount = input.amountToCollect ?? n(before.amount_to_collect);
    const orderId = before.order_id as string | null;

    // Commande en ligne : on la fait avancer avec elle (la vente est créée par la boutique)
    if (orderId && to !== from) {
      const order = await this.shop.order(businessId, orderId);
      if (to === 'picked' && (order.status === 'confirmed' || order.status === 'ready')) {
        await this.shop.setStatus(businessId, userId, orderId, { status: 'delivering' });
      }
      if (to === 'delivered' && order.status !== 'completed') {
        if (amount > order.total) {
          throw new AppError('OVERPAYMENT', 'Le montant encaissé dépasse le total de la commande', 422);
        }
        if (order.status === 'confirmed' || order.status === 'ready') {
          await this.shop.setStatus(businessId, userId, orderId, { status: 'delivering' });
        }
        await this.shop.setStatus(businessId, userId, orderId, {
          status: 'completed',
          payment: { method: 'cash', amount },
        });
      }
    }

    return this.dbs.withTenant(businessId, async (tx) => {
      if (input.courierId) await this.assertCourier(tx, input.courierId);
      await tx.execute(sql`
        UPDATE sales.deliveries SET
          status = ${to},
          courier_id = ${input.courierId === undefined ? ((before.courier_id as string) ?? null) : input.courierId},
          amount_to_collect = ${amount},
          failure_reason = ${to === 'failed' ? (input.failureReason ?? null) : null},
          assigned_at = CASE WHEN ${to} = 'assigned' AND ${from} <> 'assigned' THEN now() ELSE assigned_at END,
          picked_at = CASE WHEN ${to} = 'picked' THEN now() ELSE picked_at END,
          delivered_at = CASE WHEN ${to} = 'delivered' THEN now() ELSE delivered_at END,
          settled = CASE WHEN ${to} = 'delivered' AND ${amount} = 0 THEN true ELSE settled END,
          updated_at = now()
        WHERE id = ${id}`);
      return this.dto(await this.find(tx, id));
    });
  }

  /** Le livreur a remis l'argent encaissé : toutes ses courses livrées sont soldées. */
  settle(businessId: string, courierId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const r = (
        await tx.execute(sql`
          UPDATE sales.deliveries SET settled = true, settled_at = now(), updated_at = now()
          WHERE courier_id = ${courierId} AND status = 'delivered' AND NOT settled
          RETURNING amount_to_collect`)
      ).rows as Row[];
      return { deliveries: r.length, amount: r.reduce((s, x) => s + n(x.amount_to_collect), 0) };
    });
  }
}
